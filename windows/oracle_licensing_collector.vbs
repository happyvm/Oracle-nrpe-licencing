' =====================================================================
' oracle_licensing_collector.vbs
'
' Collecteur de conformite des licences Oracle (Windows Script Host).
'
' Equivalent de oracle_licensing_collector.ps1, pour les serveurs sans
' PowerShell -- Windows Server 2003 en premier lieu -- et pour ceux ou
' les strategies de groupe interdisent son execution.
'
' A planifier une a deux fois par jour :
'   schtasks /Create /TN OracleLicensingCollector /SC DAILY /ST 03:17 ^
'            /TR "cscript //NoLogo //B \"C:\Program Files\oracle-licensing\oracle_licensing_collector.vbs\""
'
' Aucune ecriture en base. Aucun mot de passe : l'authentification
' "/ as sysdba" repose sur l'appartenance au groupe local ORA_DBA.
'
' Arguments (tous optionnels) :
'   /ConfigFile:<chemin>  /CacheDir:<chemin>  /SqlFile:<chemin>
'   /Sid:<SID>            /Timeout:<secondes> /DryRun  /Trace
'
' Codes retour : 0 succes, 1 succes partiel, 2 echec total.
' =====================================================================

Option Explicit

Const SCRIPT_VERSION = "1.1.0"
Const HKEY_LOCAL_MACHINE = &H80000002

Dim oFSO, oShell
Set oFSO   = CreateObject("Scripting.FileSystemObject")
Set oShell = CreateObject("WScript.Shell")

Dim gConfigFile, gCacheDir, gSqlFile, gOnlySid, gTimeout, gDryRun, gTrace
Dim gExcludeSids, gCoreFactor

' ---------------------------------------------------------------------
' Utilitaires
' ---------------------------------------------------------------------
Sub Trace(sMsg)
    If gTrace Then WScript.Echo "[" & FormatDateTime(Now(), 4) & "] " & sMsg
End Sub

Sub Warn(sMsg)
    ' StdErr n'existe que sous cscript ; sous wscript on retombe sur la
    ' sortie standard plutot que d'echouer.
    On Error Resume Next
    WScript.StdErr.WriteLine "oracle_licensing_collector: " & sMsg
    If Err.Number <> 0 Then
        Err.Clear
        WScript.Echo "oracle_licensing_collector: " & sMsg
    End If
    On Error GoTo 0
End Sub

Function ToLong(sValue)
    Dim s, i, c, sDigits
    sDigits = ""
    s = Trim(sValue & "")
    For i = 1 To Len(s)
        c = Mid(s, i, 1)
        If c >= "0" And c <= "9" Then sDigits = sDigits & c
    Next
    If sDigits = "" Then
        ToLong = 0
    Else
        On Error Resume Next
        ToLong = CLng(sDigits)
        If Err.Number <> 0 Then ToLong = 0
        On Error GoTo 0
    End If
End Function

' Une date VBScript est un nombre de jours depuis le 30/12/1899 : la
' conversion vers l'epoque Unix se fait par arithmetique pure, sans
' dependre de DateDiff.
Function UtcNowEpoch()
    Dim tzMinutes, objWMI, colItems, objItem, nLocal
    nLocal = Int((CDbl(Now()) - CDbl(DateSerial(1970, 1, 1))) * 86400 + 0.5)
    tzMinutes = 0
    On Error Resume Next
    Set objWMI = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 Then
        If IsObject(objWMI) Then
            Set colItems = objWMI.ExecQuery("SELECT CurrentTimeZone FROM Win32_ComputerSystem")
            If Err.Number = 0 Then
                For Each objItem In colItems
                    tzMinutes = objItem.CurrentTimeZone
                Next
            End If
        End If
    End If
    If Err.Number <> 0 Then tzMinutes = 0
    Err.Clear
    On Error GoTo 0
    UtcNowEpoch = nLocal - (tzMinutes * 60)
End Function

Function ParseArgs()
    Dim oParsed, i, sArg, nColon
    Set oParsed = CreateObject("Scripting.Dictionary")
    oParsed.CompareMode = 1
    For i = 0 To WScript.Arguments.Count - 1
        sArg = WScript.Arguments.Item(i)
        If Left(sArg, 1) = "/" Then
            sArg = Mid(sArg, 2)
            nColon = InStr(sArg, ":")
            If nColon > 0 Then
                oParsed(Left(sArg, nColon - 1)) = Mid(sArg, nColon + 1)
            Else
                oParsed(sArg) = ""
            End If
        End If
    Next
    Set ParseArgs = oParsed
End Function

' Le fichier de configuration est partage avec les variantes Unix et
' PowerShell : syntaxe CLE="valeur". Il est analyse, jamais execute.
Function ReadConfig(sPath)
    Dim oCfg, oFile, sLine, nEq, sKey, sVal
    Set oCfg = CreateObject("Scripting.Dictionary")
    oCfg.CompareMode = 1
    Set ReadConfig = oCfg
    If Not oFSO.FileExists(sPath) Then Exit Function
    Set oFile = oFSO.OpenTextFile(sPath, 1, False)
    Do Until oFile.AtEndOfStream
        sLine = Trim(oFile.ReadLine)
        If Len(sLine) > 0 And Left(sLine, 1) <> "#" Then
            nEq = InStr(sLine, "=")
            If nEq > 1 Then
                sKey = Trim(Left(sLine, nEq - 1))
                sVal = Trim(Mid(sLine, nEq + 1))
                If Len(sVal) >= 2 Then
                    If (Left(sVal, 1) = """" And Right(sVal, 1) = """") Or _
                       (Left(sVal, 1) = "'" And Right(sVal, 1) = "'") Then
                        sVal = Mid(sVal, 2, Len(sVal) - 2)
                    End If
                End If
                oCfg(sKey) = sVal
            End If
        End If
    Loop
    oFile.Close
End Function

' ---------------------------------------------------------------------
' Inventaire CPU
'
' C'est ce qui justifie la collecte locale : la facturation Oracle porte
' sur les coeurs physiques du serveur -- voire de tout le cluster en
' virtualisation dite "soft partitioning" -- alors qu'une interrogation
' distante ne verrait que ce que l'hyperviseur expose a l'invite.
' ---------------------------------------------------------------------
Function HostCpuBlock()
    Dim objWMI, colProc, objProc, colCS, objCS
    Dim nSockets, nCores, nThreads, sModel, nReliable, sVirt, sFactor, nRequired
    Dim sMake, aLines, nRet

    nSockets = 0 : nCores = 0 : nThreads = 0
    sModel = "unknown" : nReliable = 1 : sVirt = "none"

    On Error Resume Next
    Set objWMI = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 And IsObject(objWMI) Then
        Set colProc = objWMI.ExecQuery("SELECT * FROM Win32_Processor")
        If Err.Number = 0 Then
            For Each objProc In colProc
                ' Une instance Win32_Processor par processeur physique.
                nSockets = nSockets + 1
                If nSockets = 1 Then sModel = objProc.Name
                ' NumberOfCores est absent avant Windows Server 2003 SP2.
                If Not IsNull(objProc.NumberOfCores) Then
                    nCores = nCores + ToLong(objProc.NumberOfCores)
                End If
                If Not IsNull(objProc.NumberOfLogicalProcessors) Then
                    nThreads = nThreads + ToLong(objProc.NumberOfLogicalProcessors)
                End If
            Next
        End If
        Err.Clear

        Set colCS = objWMI.ExecQuery("SELECT * FROM Win32_ComputerSystem")
        If Err.Number = 0 Then
            For Each objCS In colCS
                If nThreads = 0 Then nThreads = ToLong(objCS.NumberOfLogicalProcessors)
                sMake = "" & objCS.Manufacturer & " " & objCS.Model
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0

    ' Repli sur la variable d'environnement quand WMI est muet.
    If nThreads = 0 Then nThreads = ToLong(oShell.ExpandEnvironmentStrings("%NUMBER_OF_PROCESSORS%"))

    ' Dernier recours : un thread pour un coeur. Sous-estime des que
    ' l'hyperthreading est actif, donc signale comme non fiable.
    If nCores = 0 Then
        nCores = nThreads
        nReliable = 0
    End If

    ' Virtualisation, deduite du constructeur et du modele exposes.
    If InStr(1, sMake, "VMware", 1) > 0 Then
        sVirt = "vmware"
    ElseIf InStr(1, sMake, "Virtual Machine", 1) > 0 Or InStr(1, sMake, "Hyper-V", 1) > 0 Then
        sVirt = "microsoft"
    ElseIf InStr(1, sMake, "VirtualBox", 1) > 0 Or InStr(1, sMake, "innotek", 1) > 0 Then
        sVirt = "oracle"
    ElseIf InStr(1, sMake, "QEMU", 1) > 0 Or InStr(1, sMake, "KVM", 1) > 0 Then
        sVirt = "kvm"
    ElseIf InStr(1, sMake, "Xen", 1) > 0 Then
        sVirt = "xen"
    End If

    ' Table des facteurs de coeur Oracle : 0,5 en x86_64 multicoeur.
    ' Windows ne tourne que sur x86 dans ce perimetre.
    sFactor = "0.5"
    If Len(gCoreFactor) > 0 Then sFactor = gCoreFactor

    ' Oracle arrondit toujours a l'entier superieur.
    nRequired = Int(nCores * CDbl(Replace(sFactor, ",", ".")))
    If nRequired < nCores * CDbl(Replace(sFactor, ",", ".")) Then nRequired = nRequired + 1

    aLines = "KV|host.name|" & oShell.ExpandEnvironmentStrings("%COMPUTERNAME%") & vbLf & _
             "KV|host.arch|" & oShell.ExpandEnvironmentStrings("%PROCESSOR_ARCHITECTURE%") & vbLf & _
             "KV|host.cpu.model|" & sModel & vbLf & _
             "KV|host.cpu.sockets|" & nSockets & vbLf & _
             "KV|host.cpu.cores|" & nCores & vbLf & _
             "KV|host.cpu.threads|" & nThreads & vbLf & _
             "KV|host.cpu.reliable|" & nReliable & vbLf & _
             "KV|host.virt|" & sVirt & vbLf & _
             "KV|host.core_factor|" & sFactor & vbLf & _
             "KV|host.processor_licenses|" & nRequired
    HostCpuBlock = aLines
End Function

' ---------------------------------------------------------------------
' Decouverte des instances
'
' Deux dispositions de registre coexistent selon l'age de l'installation :
'   HKLM\SOFTWARE\ORACLE\HOME<n>   : Oracle 9i et 10g
'   HKLM\SOFTWARE\ORACLE\KEY_<nom> : Oracle 10g et suivants
' Les services OracleService<SID> completent la liste et donnent l'etat
' de demarrage, equivalent du processus pmon sous Unix.
' ---------------------------------------------------------------------
Function DiscoverInstances()
    Dim oReg, oFound, aRoots, r, aSubKeys, i, sPath, sHome, sSid
    Dim objWMI, colSvc, objSvc, sName, aHomes, nHomes, k

    Set oFound = CreateObject("Scripting.Dictionary")
    oFound.CompareMode = 1
    Set DiscoverInstances = oFound

    On Error Resume Next
    Set oReg = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\default:StdRegProv")
    If Err.Number <> 0 Or Not IsObject(oReg) Then
        Warn "acces au registre impossible : " & Err.Description
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If

    aRoots = Array("SOFTWARE\ORACLE", "SOFTWARE\Wow6432Node\ORACLE")
    For r = 0 To UBound(aRoots)
        aSubKeys = Null
        oReg.EnumKey HKEY_LOCAL_MACHINE, aRoots(r), aSubKeys
        If IsArray(aSubKeys) Then
            For i = 0 To UBound(aSubKeys)
                sPath = aSubKeys(i)
                If Left(UCase(sPath), 4) = "KEY_" Or Left(UCase(sPath), 4) = "HOME" Then
                    sHome = "" : sSid = ""
                    oReg.GetStringValue HKEY_LOCAL_MACHINE, aRoots(r) & "\" & sPath, "ORACLE_HOME", sHome
                    oReg.GetStringValue HKEY_LOCAL_MACHINE, aRoots(r) & "\" & sPath, "ORACLE_SID", sSid
                    If Len(sHome) > 0 And Len(sSid) > 0 Then
                        If oFSO.FolderExists(sHome) Then oFound(sSid) = sHome
                    End If
                End If
            Next
        End If
    Next

    ' Les services nomment le SID, ce que le registre omet parfois quand
    ' plusieurs instances partagent un ORACLE_HOME.
    Set objWMI = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 And IsObject(objWMI) Then
        Set colSvc = objWMI.ExecQuery("SELECT Name FROM Win32_Service WHERE Name LIKE 'OracleService%'")
        If Err.Number = 0 Then
            For Each objSvc In colSvc
                sName = objSvc.Name
                If Len(sName) > 14 Then
                    sSid = Mid(sName, 15)
                    If Not oFound.Exists(sSid) Then
                        ' Rattacher au premier ORACLE_HOME connu, faute de mieux.
                        aHomes = oFound.Items
                        nHomes = -1
                        If IsArray(aHomes) Then nHomes = UBound(aHomes)
                        If nHomes >= 0 Then oFound(sSid) = aHomes(0)
                    End If
                End If
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function InstanceIsRunning(sSid)
    Dim objWMI, colSvc, objSvc
    InstanceIsRunning = False
    On Error Resume Next
    Set objWMI = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 And IsObject(objWMI) Then
        Set colSvc = objWMI.ExecQuery( _
            "SELECT State FROM Win32_Service WHERE Name='OracleService" & sSid & "'")
        If Err.Number = 0 Then
            For Each objSvc In colSvc
                If UCase(objSvc.State) = "RUNNING" Then InstanceIsRunning = True
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function

' ---------------------------------------------------------------------
' Interrogation d'une instance
'
' La sortie de sqlplus est redirigee vers un fichier plutot que lue sur
' le flux de l'objet Exec : lire StdOut pendant que le processus tourne
' expose a un blocage des que le tampon du tube se remplit.
' ---------------------------------------------------------------------
Function QueryInstance(sSid, sHome)
    Dim sSqlPlus, sTmpSql, sTmpOut, oFile, sCmd, oExec, nWaited
    Dim sLine, sResult, bHasName, sFirstErr, bNotOpen

    QueryInstance = ""
    sSqlPlus = sHome & "\bin\sqlplus.exe"
    If Not oFSO.FileExists(sSqlPlus) Then
        Warn sSid & " : sqlplus introuvable dans " & sHome & "\bin"
        Exit Function
    End If

    sTmpSql = oFSO.GetSpecialFolder(2) & "\orlic_" & sSid & "_" & Int(Rnd() * 100000) & ".sql"
    sTmpOut = sTmpSql & ".out"

    Set oFile = oFSO.CreateTextFile(sTmpSql, True)
    oFile.WriteLine "CONNECT / AS SYSDBA"
    oFile.WriteLine "@""" & gSqlFile & """"
    oFile.Close

    ' Passage par une variable intermediaire : la double indexation
    ' oShell.Environment("PROCESS")("X") est acceptee par WSH mais reste
    ' une construction obscure, et certains moteurs la compilent mal.
    Dim oEnv
    Set oEnv = oShell.Environment("PROCESS")
    oEnv("ORACLE_SID")  = sSid
    oEnv("ORACLE_HOME") = sHome
    oEnv("NLS_LANG")    = "AMERICAN_AMERICA.AL32UTF8"

    sCmd = "cmd /c """"" & sSqlPlus & """ -S -L /nolog @""" & sTmpSql & _
           """ > """ & sTmpOut & """ 2>&1"""

    On Error Resume Next
    Set oExec = oShell.Exec(sCmd)
    If Err.Number <> 0 Then
        Warn sSid & " : lancement de sqlplus impossible -- " & Err.Description
        Err.Clear
        On Error GoTo 0
        oFSO.DeleteFile sTmpSql, True
        Exit Function
    End If
    On Error GoTo 0

    ' Une base gelee ne doit pas immobiliser la collecte du serveur.
    nWaited = 0
    Do While oExec.Status = 0
        WScript.Sleep 500
        nWaited = nWaited + 0.5
        If nWaited >= gTimeout Then
            On Error Resume Next
            oExec.Terminate
            On Error GoTo 0
            Warn sSid & " : delai de " & gTimeout & " s depasse"
            If oFSO.FileExists(sTmpSql) Then oFSO.DeleteFile sTmpSql, True
            If oFSO.FileExists(sTmpOut) Then oFSO.DeleteFile sTmpOut, True
            Exit Function
        End If
    Loop

    sResult = ""
    bHasName = False
    sFirstErr = ""
    bNotOpen = False

    If oFSO.FileExists(sTmpOut) Then
        Set oFile = oFSO.OpenTextFile(sTmpOut, 1, False)
        Do Until oFile.AtEndOfStream
            sLine = oFile.ReadLine
            ' sqlplus signale les erreurs Oracle dans le flux, pas
            ' toujours par son code retour : on inspecte le texte.
            If Left(sLine, 4) = "ORA-" Or Left(sLine, 4) = "SP2-" Or Left(sLine, 4) = "TNS-" Then
                If Len(sFirstErr) = 0 Then sFirstErr = sLine
                If Left(sLine, 9) = "ORA-01219" Or Left(sLine, 9) = "ORA-01507" _
                   Or Left(sLine, 9) = "ORA-01034" Then
                    bNotOpen = True
                End If
            End If
            If Left(sLine, 3) = "KV|" Or Left(sLine, 4) = "OPT|" _
               Or Left(sLine, 5) = "FEAT|" Or Left(sLine, 4) = "HWM|" Then
                If Len(sResult) > 0 Then sResult = sResult & vbLf
                sResult = sResult & sLine
                If Left(sLine, 11) = "KV|db.name|" Then bHasName = True
            End If
        Loop
        oFile.Close
    End If

    If oFSO.FileExists(sTmpSql) Then oFSO.DeleteFile sTmpSql, True
    If oFSO.FileExists(sTmpOut) Then oFSO.DeleteFile sTmpOut, True

    If Len(sFirstErr) > 0 Then
        If bNotOpen Then
            ' Base non ouverte : le rapport reste exploitable pour
            ' l'identite et V$OPTION.
            Warn sSid & " : base non ouverte (" & sFirstErr & "), collecte partielle"
        Else
            Warn sSid & " : " & sFirstErr
            If Not bHasName Then Exit Function
        End If
    End If

    QueryInstance = sResult
End Function

' ---------------------------------------------------------------------
' Ecriture du cache
'
' Ecriture dans un fichier temporaire puis remplacement : le plugin peut
' lire a tout instant et ne doit jamais tomber sur un cache a moitie
' ecrit.
' ---------------------------------------------------------------------
Function WriteCache(sSid, sContent)
    Dim sTarget, sTmp, oFile
    WriteCache = False
    sTarget = gCacheDir
    If Right(sTarget, 1) <> "\" Then sTarget = sTarget & "\"
    sTarget = sTarget & sSid & ".dat"
    sTmp = sTarget & ".tmp"

    On Error Resume Next
    Set oFile = oFSO.CreateTextFile(sTmp, True)
    If Err.Number <> 0 Then
        Warn sSid & " : ecriture impossible dans " & sTmp & " -- " & Err.Description
        Err.Clear : On Error GoTo 0 : Exit Function
    End If
    oFile.Write sContent & vbCrLf
    oFile.Close

    If oFSO.FileExists(sTarget) Then oFSO.DeleteFile sTarget, True
    oFSO.MoveFile sTmp, sTarget
    If Err.Number <> 0 Then
        Warn sSid & " : remplacement du cache impossible -- " & Err.Description
        Err.Clear : On Error GoTo 0 : Exit Function
    End If
    On Error GoTo 0
    Trace sSid & " : cache ecrit dans " & sTarget
    WriteCache = True
End Function

' =====================================================================
Dim oArgs, oCfg, aExcl, i
Set oArgs = ParseArgs()

gConfigFile = "C:\ProgramData\oracle-licensing\oracle-licensing.conf"
gCacheDir   = "C:\ProgramData\oracle-licensing\cache"
gSqlFile    = "C:\Program Files\oracle-licensing\collect_licensing.sql"
gOnlySid    = ""
gTimeout    = 120
gCoreFactor = ""
gDryRun     = oArgs.Exists("DryRun")
gTrace      = oArgs.Exists("Trace")

If oArgs.Exists("ConfigFile") Then gConfigFile = oArgs("ConfigFile")
Set oCfg = ReadConfig(gConfigFile)
If oCfg.Exists("CACHE_DIR_WIN")   Then gCacheDir   = oCfg("CACHE_DIR_WIN")
If oCfg.Exists("SQL_FILE_WIN")    Then gSqlFile    = oCfg("SQL_FILE_WIN")
If oCfg.Exists("SQLPLUS_TIMEOUT") Then gTimeout    = ToLong(oCfg("SQLPLUS_TIMEOUT"))
If oCfg.Exists("CORE_FACTOR")     Then gCoreFactor = oCfg("CORE_FACTOR")
Set gExcludeSids = CreateObject("Scripting.Dictionary")
gExcludeSids.CompareMode = 1
If oCfg.Exists("EXCLUDE_SIDS") Then
    aExcl = Split(Replace(oCfg("EXCLUDE_SIDS"), ",", " "), " ")
    For i = 0 To UBound(aExcl)
        If Len(Trim(aExcl(i))) > 0 Then gExcludeSids(Trim(aExcl(i))) = 1
    Next
End If

' Les arguments priment toujours sur la configuration.
If oArgs.Exists("CacheDir") Then gCacheDir = oArgs("CacheDir")
If oArgs.Exists("SqlFile")  Then gSqlFile  = oArgs("SqlFile")
If oArgs.Exists("Sid")      Then gOnlySid  = oArgs("Sid")
If oArgs.Exists("Timeout")  Then gTimeout  = ToLong(oArgs("Timeout"))
If gTimeout <= 0 Then gTimeout = 120

If Not oFSO.FileExists(gSqlFile) Then
    Warn "script SQL illisible : " & gSqlFile
    WScript.Quit 2
End If
If Not gDryRun Then
    If Not oFSO.FolderExists(gCacheDir) Then
        On Error Resume Next
        oFSO.CreateFolder gCacheDir
        If Err.Number <> 0 Then
            Warn "creation impossible : " & gCacheDir
            WScript.Quit 2
        End If
        On Error GoTo 0
    End If
End If

Dim sHostBlock, oInstances, aSids, sSid, sHome, bRunning
Dim nOk, nKo, sHeader, sContent, sDbBlock

sHostBlock = HostCpuBlock()
Set oInstances = DiscoverInstances()

If oInstances.Count = 0 Then
    Warn "aucune instance Oracle trouvee dans le registre ni parmi les services"
    WScript.Quit 2
End If
Trace oInstances.Count & " instance(s) a traiter"

nOk = 0 : nKo = 0
aSids = oInstances.Keys
For i = 0 To UBound(aSids)
    sSid = aSids(i)
    If Len(gOnlySid) > 0 And LCase(sSid) <> LCase(gOnlySid) Then
        Trace sSid & " ignore (hors /Sid)"
    ElseIf gExcludeSids.Exists(sSid) Then
        Trace sSid & " ignore (EXCLUDE_SIDS)"
    Else
        sHome = oInstances(sSid)
        bRunning = InstanceIsRunning(sSid)
        Trace sSid & " : demarree=" & bRunning & " home=" & sHome

        sHeader = "# oracle-licensing cache v1 -- NE PAS EDITER" & vbLf & _
                  "KV|collect.version|" & SCRIPT_VERSION & vbLf & _
                  "KV|collect.epoch|" & UtcNowEpoch() & vbLf & _
                  "KV|collect.date|" & Year(Now()) & "-" & Right("0" & Month(Now()), 2) & "-" & _
                      Right("0" & Day(Now()), 2) & " " & FormatDateTime(Now(), 4) & vbLf & _
                  "KV|inst.sid|" & sSid & vbLf & _
                  "KV|inst.oracle_home|" & sHome & vbLf & _
                  "KV|inst.running|" & IIfNum(bRunning, 1, 0)

        If Not bRunning Then
            ' Instance a l'arret : on publie quand meme une fiche pour
            ' que le plugin distingue "arretee" de "jamais collectee".
            sContent = sHeader & vbLf & sHostBlock & vbLf & "KV|collect.status|instance_down"
            nKo = nKo + 1
        Else
            sDbBlock = QueryInstance(sSid, sHome)
            If Len(sDbBlock) > 0 Then
                sContent = sHeader & vbLf & sHostBlock & vbLf & sDbBlock & vbLf & "KV|collect.status|ok"
                nOk = nOk + 1
            Else
                sContent = sHeader & vbLf & sHostBlock & vbLf & "KV|collect.status|query_failed"
                nKo = nKo + 1
            End If
        End If

        If gDryRun Then
            WScript.Echo sContent
        Else
            If Not WriteCache(sSid, sContent) Then nKo = nKo + 1
        End If
    End If
Next

Function IIfNum(bCond, nYes, nNo)
    If bCond Then IIfNum = nYes Else IIfNum = nNo
End Function

Trace "termine : " & nOk & " succes, " & nKo & " echec(s)"
If nOk > 0 And nKo = 0 Then WScript.Quit 0
If nOk > 0 Then WScript.Quit 1
WScript.Quit 2
