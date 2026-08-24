' =====================================================================
' check_oracle_licensing.vbs
'
' Plugin NRPE de controle de conformite des licences Oracle (Windows).
'
' POURQUOI UNE VARIANTE VBSCRIPT
'
' Windows Server 2003 n'embarque aucun PowerShell, et l'installer sur
' un parc existant n'est pas toujours envisageable. Windows Script Host
' est en revanche present nativement de Windows 2000 a Server 2025.
'
' Second avantage, valable sur tout le parc : PowerShell exige souvent
' un "-ExecutionPolicy Bypass" que les strategies de groupe interdisent,
' la ou cscript s'execute sans amenagement.
'
' Reserve : Microsoft a annonce en 2023 la depreciation de VBScript.
' Le langage reste livre jusqu'a Server 2025, puis deviendra une
' fonctionnalite a la demande. La variante PowerShell est conservee pour
' cette echeance, et pour les serveurs ou WSH est desactive par
' durcissement.
'
' La logique reproduit celle de lib/licensing_eval.awk et de
' check_oracle_licensing.ps1. Les trois moteurs sont compares sur les
' memes jeux de reference par tests/run_parity_tests.sh.
'
' Appel :
'   cscript //NoLogo //B check_oracle_licensing.vbs /Sid:ORCL /Mode:options
'
' Codes retour Nagios : 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
' =====================================================================

Option Explicit

Const SCRIPT_VERSION = "1.1.0"
Const OK_ = 0
Const WARNING_ = 1
Const CRITICAL_ = 2
Const UNKNOWN_ = 3

' --- Etat global -----------------------------------------------------
Dim gKV, gOPT, gFeatUsed, gFeatDet, gFeatLast, gFeatFirst, gFeatAux, gHWM
Dim gNFeat
Dim gRulePat, gRuleOpt, gRuleEds, gRuleAux, gRuleFree, gRuleNote, gNRules
Dim gDbName, gEdition, gDbVersion, gVMajor, gCStatus, gCEpoch, gAge, gCapUsage

Dim oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")

Set gKV       = CreateObject("Scripting.Dictionary")
Set gOPT      = CreateObject("Scripting.Dictionary")
Set gFeatUsed = CreateObject("Scripting.Dictionary")
Set gFeatDet  = CreateObject("Scripting.Dictionary")
Set gFeatLast = CreateObject("Scripting.Dictionary")
Set gFeatFirst= CreateObject("Scripting.Dictionary")
Set gFeatAux  = CreateObject("Scripting.Dictionary")
Set gHWM      = CreateObject("Scripting.Dictionary")
gNFeat = 0
gNRules = 0

' =====================================================================
' Utilitaires
' =====================================================================

Sub Fail(sMessage)
    WScript.Echo "UNKNOWN - " & sMessage
    WScript.Quit UNKNOWN_
End Sub

' VBScript n'a pas d'operateur ternaire.
Function IIfStr(bCond, sYes, sNo)
    If bCond Then IIfStr = sYes Else IIfStr = sNo
End Function

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
        ' Une valeur aberrante ne doit pas faire echouer le controle.
        On Error Resume Next
        ToLong = CLng(sDigits)
        If Err.Number <> 0 Then ToLong = 0
        On Error GoTo 0
    End If
End Function

' Epoque Unix en UTC.
'
' Now() rend l'heure locale : sans correction du fuseau, l'age du cache
' serait fausse de plusieurs heures et le controle de fraicheur
' basculerait a tort. Le decalage vient de WMI ; a defaut on suppose UTC
' et on le signale par une valeur de repli.
Function UtcNowEpoch()
    Dim tzMinutes, objWMI, colItems, objItem, nLocal

    ' Une date VBScript est un nombre de jours depuis le 30/12/1899 :
    ' la difference se calcule donc par arithmetique pure, sans passer
    ' par DateDiff. Le resultat est identique et ne depend d'aucune
    ' fonction optionnelle du moteur de script.
    '
    ' L'heure locale est calculee d'abord, pour qu'un echec de WMI ne
    ' puisse jamais laisser la fonction sans resultat.
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
    ' Une source secondaire indisponible ne doit jamais interrompre le
    ' controle : a defaut de decalage connu, on suppose UTC.
    If Err.Number <> 0 Then tzMinutes = 0
    Err.Clear
    On Error GoTo 0

    UtcNowEpoch = nLocal - (tzMinutes * 60)
End Function

' Comparaison de versions Oracle : "19.22.0.0.0" >= "12.2" vaut vrai.
' Les composants absents comptent pour zero.
Function VersionGe(sA, sB)
    Dim x, y, n, i, u, v
    x = Split(sA & "", ".")
    y = Split(sB & "", ".")
    n = UBound(x)
    If UBound(y) > n Then n = UBound(y)
    For i = 0 To n
        u = 0 : v = 0
        If i <= UBound(x) Then u = ToLong(x(i))
        If i <= UBound(y) Then v = ToLong(y(i))
        If u > v Then VersionGe = True  : Exit Function
        If u < v Then VersionGe = False : Exit Function
    Next
    VersionGe = True
End Function

Function FormatAge(nSeconds)
    If nSeconds < 3600 Then
        FormatAge = CStr(Int(nSeconds / 60)) & " min"
    ElseIf nSeconds < 172800 Then
        FormatAge = CStr(Int(nSeconds / 3600)) & " h"
    Else
        FormatAge = CStr(Int(nSeconds / 86400)) & " j"
    End If
End Function

' Tri par insertion : Scripting.Dictionary ne trie pas ses cles, et le
' volume attendu se compte en dizaines d'entrees.
Function SortedKeys(oDict)
    Dim arr, i, j, tmp
    arr = oDict.Keys
    If UBound(arr) < 0 Then
        SortedKeys = arr
        Exit Function
    End If
    For i = 1 To UBound(arr)
        tmp = arr(i)
        j = i - 1
        Do While j >= 0
            If arr(j) > tmp Then
                arr(j + 1) = arr(j)
                j = j - 1
            Else
                Exit Do
            End If
        Loop
        arr(j + 1) = tmp
    Next
    SortedKeys = arr
End Function

' Concatenation explicite plutot que Join : la fonction native existe
' depuis VBScript 5.0, mais s'en passer garde ce moteur executable sur
' les implementations partielles de Windows Script Host, et donc
' testable en dehors de Windows.
Function JoinSorted(oDict)
    Dim aKeys, i, s
    JoinSorted = ""
    If oDict.Count = 0 Then Exit Function
    aKeys = SortedKeys(oDict)
    s = ""
    For i = 0 To UBound(aKeys)
        If i > 0 Then s = s & ","
        s = s & aKeys(i)
    Next
    JoinSorted = s
End Function

' =====================================================================
' Chargement des fichiers
' =====================================================================

' Le fichier de configuration est partage avec les variantes Unix et
' PowerShell : syntaxe CLE="valeur". Il est analyse, jamais execute.
Function ReadConfig(sPath)
    Dim oCfg, oFile, sLine, nEq, sKey, sVal
    Set oCfg = CreateObject("Scripting.Dictionary")
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

Sub LoadCache(sPath)
    Dim oFile, sLine, f
    Set oFile = oFSO.OpenTextFile(sPath, 1, False)
    Do Until oFile.AtEndOfStream
        sLine = oFile.ReadLine
        If Len(sLine) > 0 And Left(sLine, 1) <> "#" Then
            f = Split(sLine, "|")
            If UBound(f) >= 2 Then
                Select Case f(0)
                    Case "KV"  : gKV(f(1))  = f(2)
                    Case "OPT" : gOPT(f(1)) = f(2)
                    Case "HWM" : gHWM(f(1)) = f(2)
                    Case "FEAT"
                        If UBound(f) >= 6 Then
                            gFeatUsed(f(1))  = f(2)
                            gFeatDet(f(1))   = f(3)
                            gFeatLast(f(1))  = f(4)
                            gFeatFirst(f(1)) = f(5)
                            gFeatAux(f(1))   = f(6)
                            gNFeat = gNFeat + 1
                        End If
                End Select
            End If
        End If
    Loop
    oFile.Close
End Sub

Sub LoadRules(sPath)
    Dim oFile, sLine, f, n
    ' VBScript n'a pas de tableau dynamique commode : on dimensionne
    ' large puis on redimensionne une fois la lecture terminee.
    ReDim gRulePat(512), gRuleOpt(512), gRuleEds(512)
    ReDim gRuleAux(512), gRuleFree(512), gRuleNote(512)
    n = 0
    Set oFile = oFSO.OpenTextFile(sPath, 1, False)
    Do Until oFile.AtEndOfStream
        sLine = Trim(oFile.ReadLine)
        If Len(sLine) > 0 And Left(sLine, 1) <> "#" Then
            f = Split(sLine, "|")
            If UBound(f) = 5 Then
                gRulePat(n)  = f(0)
                gRuleOpt(n)  = f(1)
                gRuleEds(n)  = f(2)
                gRuleAux(n)  = ToLong(f(3))
                gRuleFree(n) = f(4)
                gRuleNote(n) = f(5)
                n = n + 1
            End If
        End If
    Loop
    oFile.Close
    gNRules = n
End Sub

Function GetKV(sKey, sDefault)
    If gKV.Exists(sKey) Then
        If Len(gKV(sKey)) > 0 Then
            GetKV = gKV(sKey)
            Exit Function
        End If
    End If
    GetKV = sDefault
End Function

Function GetKVLong(sKey)
    GetKVLong = ToLong(GetKV(sKey, "0"))
End Function

' =====================================================================
' Arguments
' =====================================================================
Dim gSid, gMode, gWarn, gCrit, gLicOptions, gLicProcessors
Dim gMaxCacheAge, gIgnoreHistorical, gDetail
Dim gCacheDir, gMapFile, gConfigFile, gNowOverride
Dim oArgs, oCfg

' Les arguments nommes sont analyses a la main plutot que via
' WScript.Arguments.Named : la syntaxe "/Cle:valeur" reste celle attendue
' sous Windows, mais le comportement devient identique partout, y compris
' sous les implementations partielles de WSH ou .Named est absent. Cela
' rend aussi ce plugin executable hors de Windows, donc testable.
Function ParseArgs()
    Dim oParsed, i, sArg, nColon, sKey, sVal
    Set oParsed = CreateObject("Scripting.Dictionary")
    oParsed.CompareMode = 1                  ' insensible a la casse
    For i = 0 To WScript.Arguments.Count - 1
        sArg = WScript.Arguments.Item(i)
        If Left(sArg, 1) = "/" Then
            sArg = Mid(sArg, 2)
            nColon = InStr(sArg, ":")
            If nColon > 0 Then
                sKey = Left(sArg, nColon - 1)
                sVal = Mid(sArg, nColon + 1)
            Else
                sKey = sArg
                sVal = ""
            End If
            oParsed(sKey) = sVal
        End If
    Next
    Set ParseArgs = oParsed
End Function

Function ArgValue(oParsed, sKey)
    If oParsed.Exists(sKey) Then ArgValue = oParsed(sKey) Else ArgValue = ""
End Function

Set oArgs = ParseArgs()

If oArgs.Exists("Version") Then
    WScript.Echo "check_oracle_licensing.vbs " & SCRIPT_VERSION
    WScript.Quit 0
End If

gSid           = ArgValue(oArgs, "Sid")
gMode          = ArgValue(oArgs, "Mode")
gWarn          = ArgValue(oArgs, "Warning")
gCrit          = ArgValue(oArgs, "Critical")
gLicOptions    = ArgValue(oArgs, "LicensedOptions")
gLicProcessors = ArgValue(oArgs, "LicensedProcessors")
gCacheDir      = ArgValue(oArgs, "CacheDir")
gMapFile       = ArgValue(oArgs, "MapFile")
gConfigFile    = ArgValue(oArgs, "ConfigFile")
gNowOverride   = ArgValue(oArgs, "NowEpoch")
gIgnoreHistorical = oArgs.Exists("IgnoreHistorical")
gDetail           = oArgs.Exists("Detail")

If Len(gMode) = 0 Then gMode = "options"
If Len(gCacheDir) = 0   Then gCacheDir   = "C:\ProgramData\oracle-licensing\cache"
If Len(gMapFile) = 0    Then gMapFile    = "C:\ProgramData\oracle-licensing\licensable-features.map"
If Len(gConfigFile) = 0 Then gConfigFile = "C:\ProgramData\oracle-licensing\oracle-licensing.conf"

gMaxCacheAge = 93600
If oArgs.Exists("MaxCacheAge") Then gMaxCacheAge = ToLong(ArgValue(oArgs, "MaxCacheAge"))

' Un argument explicite prime toujours sur la configuration.
Set oCfg = ReadConfig(gConfigFile)
If Len(gLicOptions) = 0    And oCfg.Exists("LICENSED_OPTIONS")    Then gLicOptions    = oCfg("LICENSED_OPTIONS")
If Len(gLicProcessors) = 0 And oCfg.Exists("LICENSED_PROCESSORS") Then gLicProcessors = oCfg("LICENSED_PROCESSORS")
If oCfg.Exists("MAX_CACHE_AGE") And Not oArgs.Exists("MaxCacheAge") Then
    If ToLong(oCfg("MAX_CACHE_AGE")) > 0 Then gMaxCacheAge = ToLong(oCfg("MAX_CACHE_AGE"))
End If
If oCfg.Exists("CACHE_DIR_WIN") And Not oArgs.Exists("CacheDir") Then gCacheDir = oCfg("CACHE_DIR_WIN")

If Len(gSid) = 0 Then Fail "parametre /Sid: obligatoire"

Dim sCacheFile
sCacheFile = gCacheDir
If Right(sCacheFile, 1) <> "\" And Right(sCacheFile, 1) <> "/" Then sCacheFile = sCacheFile & "\"
sCacheFile = sCacheFile & gSid & ".dat"

If Not oFSO.FileExists(sCacheFile) Then
    Fail "cache absent ou illisible : " & sCacheFile & " (le collecteur a-t-il tourne ?)"
End If
If Not oFSO.FileExists(gMapFile) Then
    Fail "table de correspondance illisible : " & gMapFile
End If

LoadCache sCacheFile
LoadRules gMapFile

gDbName    = GetKV("db.name", gSid)
gEdition   = GetKV("db.edition", "UNKNOWN")
gDbVersion = GetKV("inst.version", "0")
gVMajor    = GetKVLong("db.version_major")
gCStatus   = GetKV("collect.status", "unknown")
gCEpoch    = GetKVLong("collect.epoch")

' /NowEpoch: permet de rejouer un cache a une date donnee -- utile en
' diagnostic, et indispensable pour comparer les moteurs entre eux.
If Len(gNowOverride) > 0 Then
    gAge = ToLong(gNowOverride) - gCEpoch
Else
    gAge = UtcNowEpoch() - gCEpoch
End If

' Capacite de collecte : absente des caches produits par une version
' anterieure du collecteur, auquel cas on se rabat sur la version majeure.
If gKV.Exists("collect.cap.feature_usage") Then
    gCapUsage = (gKV("collect.cap.feature_usage") = "1")
Else
    gCapUsage = (gVMajor = 0 Or gVMajor >= 10)
End If

Function IsLicensed(sOption)
    Dim parts, i, sWant
    IsLicensed = False
    If Len(gLicOptions) = 0 Then Exit Function
    sWant = LCase(Trim(sOption))
    parts = Split(gLicOptions, ",")
    For i = 0 To UBound(parts)
        If LCase(Trim(parts(i))) = sWant Then
            IsLicensed = True
            Exit Function
        End If
    Next
End Function

' =====================================================================
' Mode "options" : detection de derive de conformite.
'
' Regroupement par OPTION et non par feature : on achete une option, pas
' une feature.
'
'   CRITICAL  option non detenue et en cours d'utilisation, ou option
'             inutilisable dans l'edition installee
'   WARNING   option non detenue dont l'usage est seulement historique
'   OK        usage couvert, ou feature devenue gratuite dans la version
' =====================================================================
Function ModeOptions()
    Dim oViolNow, oViolPast, oCovered, oFreed, oWrongEd, oDetail
    Dim aFeat, i, r, sFeature, nDet, sUsed, nAux, nMatched
    Dim oRe, sOpt, sNote, sFirst, sLast, sEntry
    Dim nNow, nPast, nCov, nEdt, nStatus, sLabel, sStale, sMsg
    Dim aKeys, k

    ' Oracle 9i n'expose aucune source d'usage des options :
    ' DBA_FEATURE_USAGE_STATISTICS n'apparait qu'en 10.1. Conclure a la
    ' conformite serait un mensonge ; on le dit.
    If Not gCapUsage Then
        WScript.Echo "UNKNOWN - " & gDbName & "/" & gSid & " (" & gEdition & " " & gDbVersion & _
            "): controle d'usage impossible, DBA_FEATURE_USAGE_STATISTICS n'existe qu'a partir d'Oracle 10.1" & _
            "|unlicensed_now=U unlicensed_past=U cache_age=" & gAge & "s;;" & gMaxCacheAge & ";0"
        WScript.Echo "Sur cette version, seuls les modes inventory (options liees au binaire)"
        WScript.Echo "et sessions sont exploitables. Ne declarez pas ce service dans Centreon"
        WScript.Echo "pour les bases 9i : il resterait UNKNOWN en permanence."
        ModeOptions = UNKNOWN_
        Exit Function
    End If

    Set oViolNow  = CreateObject("Scripting.Dictionary")
    Set oViolPast = CreateObject("Scripting.Dictionary")
    Set oCovered  = CreateObject("Scripting.Dictionary")
    Set oFreed    = CreateObject("Scripting.Dictionary")
    Set oWrongEd  = CreateObject("Scripting.Dictionary")
    Set oDetail   = CreateObject("Scripting.Dictionary")

    Set oRe = CreateObject("VBScript.RegExp")
    oRe.IgnoreCase = True
    oRe.Global = False

    aFeat = gFeatDet.Keys
    For i = 0 To UBound(aFeat)
        sFeature = aFeat(i)
        nDet = ToLong(gFeatDet(sFeature))
        If nDet > 0 Then

            nMatched = -1
            For r = 0 To gNRules - 1
                oRe.Pattern = gRulePat(r)
                If oRe.Test(sFeature) Then
                    nMatched = r
                    Exit For
                End If
            Next

            If nMatched >= 0 Then
                sOpt  = gRuleOpt(nMatched)
                sUsed = UCase(gFeatUsed(sFeature))
                nAux  = ToLong(gFeatAux(sFeature))

                ' Seuil AUX_COUNT : Multitenant n'est facturable qu'au-dela
                ' d'une PDB, l'usage en deca est inclus dans l'edition.
                If gRuleAux(nMatched) > 0 And nAux <= gRuleAux(nMatched) Then
                    ' rien : usage inclus
                ElseIf gRuleFree(nMatched) <> "-" And VersionGe(gDbVersion, gRuleFree(nMatched)) Then
                    ' Feature devenue gratuite dans cette version.
                    oFreed(sOpt) = 1
                Else
                    sFirst = gFeatFirst(sFeature)
                    If Len(sFirst) = 0 Then sFirst = "-"
                    sLast = gFeatLast(sFeature)
                    If Len(sLast) = 0 Then sLast = "-"
                    sNote = ""
                    If Len(gRuleNote(nMatched)) > 0 Then sNote = " ; " & gRuleNote(nMatched)

                    sEntry = vbLf & "    - " & sFeature & " (usages=" & nDet & _
                             ", en cours=" & sUsed & ", depuis=" & sFirst & _
                             ", dernier=" & sLast & sNote & ")"
                    If oDetail.Exists(sOpt) Then
                        oDetail(sOpt) = oDetail(sOpt) & sEntry
                    Else
                        oDetail(sOpt) = sEntry
                    End If

                    ' Option non vendable dans cette edition : anomalie
                    ' structurelle qu'aucun bon de commande ne regularise.
                    If gRuleEds(nMatched) <> "ALL" And gEdition <> "UNKNOWN" And _
                       InStr("," & gRuleEds(nMatched) & ",", "," & gEdition & ",") = 0 Then
                        oWrongEd(sOpt) = 1
                    ElseIf IsLicensed(sOpt) Then
                        oCovered(sOpt) = 1
                    ElseIf sUsed = "TRUE" Then
                        oViolNow(sOpt) = 1
                    Else
                        oViolPast(sOpt) = 1
                    End If
                End If
            End If
        End If
    Next

    ' Une option deja en infraction courante ne doit pas etre recomptee.
    aKeys = oViolNow.Keys
    For i = 0 To UBound(aKeys)
        If oViolPast.Exists(aKeys(i)) Then oViolPast.Remove aKeys(i)
    Next
    aKeys = oWrongEd.Keys
    For i = 0 To UBound(aKeys)
        If oViolNow.Exists(aKeys(i))  Then oViolNow.Remove aKeys(i)
        If oViolPast.Exists(aKeys(i)) Then oViolPast.Remove aKeys(i)
        If oCovered.Exists(aKeys(i))  Then oCovered.Remove aKeys(i)
    Next

    nNow = oViolNow.Count
    nPast = oViolPast.Count
    If gIgnoreHistorical Then nPast = 0
    nCov = oCovered.Count
    nEdt = oWrongEd.Count

    nStatus = OK_ : sLabel = "OK"
    If nEdt > 0 Or nNow > 0 Then
        nStatus = CRITICAL_ : sLabel = "CRITICAL"
    ElseIf nPast > 0 Then
        nStatus = WARNING_ : sLabel = "WARNING"
    End If

    ' Un cache perime rend le verdict caduc, sans masquer une infraction
    ' deja constatee.
    sStale = ""
    If gAge > gMaxCacheAge Then
        sStale = " [cache perime: " & FormatAge(gAge) & "]"
        If nStatus = OK_ Then nStatus = WARNING_ : sLabel = "WARNING"
    End If

    sMsg = ""
    If nEdt > 0 Then
        sMsg = sMsg & nEdt & " option(s) incompatible(s) avec l'edition " & gEdition & ": " & JoinSorted(oWrongEd)
    End If
    If nNow > 0 Then
        If Len(sMsg) > 0 Then sMsg = sMsg & "; "
        sMsg = sMsg & nNow & " option(s) non licenciee(s) en cours d'utilisation: " & JoinSorted(oViolNow)
    End If
    If nPast > 0 Then
        If Len(sMsg) > 0 Then sMsg = sMsg & "; "
        sMsg = sMsg & nPast & " option(s) non licenciee(s) avec usage historique: " & JoinSorted(oViolPast)
    End If
    If Len(sMsg) = 0 Then
        sMsg = "aucune derive detectee sur " & nCov & " option(s) declaree(s)"
    End If

    WScript.Echo sLabel & " - " & gDbName & "/" & gSid & " (" & gEdition & " " & gDbVersion & "): " & _
        sMsg & sStale & "|unlicensed_now=" & nNow & ";;1;0 unlicensed_past=" & nPast & _
        ";1;;0 wrong_edition=" & nEdt & ";;1;0 licensed_used=" & nCov & _
        ";;;0 cache_age=" & gAge & "s;;" & gMaxCacheAge & ";0"

    If gDetail Or nStatus <> OK_ Then
        If nEdt > 0  Then EchoGroup "Options incompatibles avec l'edition installee :", oWrongEd, oDetail
        If nNow > 0  Then EchoGroup "Options utilisees SANS licence declaree :", oViolNow, oDetail
        If nPast > 0 Then EchoGroup "Options non licenciees, usage historique uniquement :", oViolPast, oDetail
        If gDetail And nCov > 0 Then EchoGroup "Options couvertes par la declaration :", oCovered, oDetail
        If gDetail And oFreed.Count > 0 Then
            WScript.Echo "Features payantes par le passe, incluses en " & gDbVersion & " : " & JoinSorted(oFreed)
        End If
    End If

    ModeOptions = nStatus
End Function

Sub EchoGroup(sTitle, oTable, oDetail)
    Dim aKeys, i, sDet
    WScript.Echo sTitle
    aKeys = SortedKeys(oTable)
    For i = 0 To UBound(aKeys)
        sDet = ""
        If oDetail.Exists(aKeys(i)) Then sDet = oDetail(aKeys(i))
        WScript.Echo "  " & aKeys(i) & sDet
    Next
End Sub

' =====================================================================
' Mode "processors"
'
' ceil(coeurs physiques x facteur de coeur). En virtualisation dite
' "soft partitioning", Oracle considere que tout hote ou la VM peut
' migrer doit etre licencie : le chiffre est un PLANCHER.
' =====================================================================
Function ModeProcessors()
    Dim nCores, nSockets, sFactor, nRequired, sVirt, sReliable
    Dim nStatus, sLabel, sMsg, nHeld

    nCores    = GetKVLong("host.cpu.cores")
    nSockets  = GetKVLong("host.cpu.sockets")
    sFactor   = GetKV("host.core_factor", "1.0")
    nRequired = GetKVLong("host.processor_licenses")
    sVirt     = GetKV("host.virt", "none")
    sReliable = GetKV("host.cpu.reliable", "1")

    nStatus = OK_ : sLabel = "OK"
    sMsg = nRequired & " licence(s) Processor requise(s) (" & nCores & _
           " coeurs x facteur " & sFactor & ", " & nSockets & " socket(s))"

    If Len(gLicProcessors) > 0 Then
        nHeld = ToLong(gLicProcessors)
        If nRequired > nHeld Then
            nStatus = CRITICAL_ : sLabel = "CRITICAL"
            sMsg = sMsg & ", " & nHeld & " detenue(s) -- deficit de " & (nRequired - nHeld)
        Else
            sMsg = sMsg & ", " & nHeld & " detenue(s)"
        End If
    Else
        sMsg = sMsg & ", aucune declaration de reference"
    End If

    ' SE2 est plafonnee a 2 sockets ; SE1 et SE l'etaient a 2 et 4.
    If gEdition = "SE2" And nSockets > 2 Then
        nStatus = CRITICAL_ : sLabel = "CRITICAL"
        sMsg = sMsg & " ; SE2 limitee a 2 sockets, " & nSockets & " detectes"
    ElseIf gEdition = "SE1" And nSockets > 2 Then
        nStatus = CRITICAL_ : sLabel = "CRITICAL"
        sMsg = sMsg & " ; SE1 limitee a 2 sockets, " & nSockets & " detectes"
    ElseIf gEdition = "SE" And nSockets > 4 Then
        nStatus = CRITICAL_ : sLabel = "CRITICAL"
        sMsg = sMsg & " ; SE limitee a 4 sockets, " & nSockets & " detectes"
    End If

    If sReliable <> "1" Then
        If nStatus = OK_ Then nStatus = WARNING_ : sLabel = "WARNING"
        sMsg = sMsg & " ; comptage de coeurs non fiable (WMI indisponible)"
    End If

    If sVirt <> "none" And sVirt <> "kvm-guest" Then
        sMsg = sMsg & " ; hyperviseur '" & sVirt & "' detecte : verifier la regle de licence du cluster"
        If nStatus = OK_ Then nStatus = WARNING_ : sLabel = "WARNING"
    End If

    WScript.Echo sLabel & " - " & gDbName & "/" & gSid & ": " & sMsg & _
        "|processor_licenses=" & nRequired & ";;" & gLicProcessors & ";0 cpu_cores=" & nCores & _
        ";;;0 cpu_sockets=" & nSockets & ";;;0 cache_age=" & gAge & "s;;" & gMaxCacheAge & ";0"
    ModeProcessors = nStatus
End Function

' =====================================================================
' Mode "sessions"
' =====================================================================
Function ModeSessions()
    Dim nInstHwm, nHistHwm, nPeak, nCurrent, nMaxs, nProcs, nNupFloor
    Dim nStatus, sLabel, sMsg

    nInstHwm = GetKVLong("license.sessions_highwater")
    nHistHwm = 0
    If gHWM.Exists("SESSIONS") Then nHistHwm = ToLong(gHWM("SESSIONS"))
    nCurrent  = GetKVLong("license.sessions_current")
    nMaxs     = GetKVLong("license.sessions_max")
    nProcs    = GetKVLong("host.processor_licenses")
    nNupFloor = nProcs * 25

    ' V$LICENSE.sessions_highwater repart de zero a chaque redemarrage de
    ' l'instance ; DBA_HIGH_WATER_MARK_STATISTICS conserve le pic
    ' historique. Retenir le plus eleve des deux.
    nPeak = nInstHwm
    If nHistHwm > nPeak Then nPeak = nHistHwm

    nStatus = OK_ : sLabel = "OK"
    sMsg = "high-water mark " & nPeak & " session(s), " & nCurrent & " en cours"
    If nMaxs > 0 Then sMsg = sMsg & ", plafond sessions_max=" & nMaxs
    If nHistHwm > nInstHwm Then
        sMsg = sMsg & " (pic historique " & nHistHwm & " > pic depuis demarrage " & nInstHwm & ")"
    End If
    sMsg = sMsg & " ; plancher NUP contractuel: " & nNupFloor & " (25 x " & nProcs & " Processor)"

    If Len(gCrit) > 0 Then
        If nPeak >= ToLong(gCrit) Then nStatus = CRITICAL_ : sLabel = "CRITICAL"
    End If
    If nStatus = OK_ And Len(gWarn) > 0 Then
        If nPeak >= ToLong(gWarn) Then nStatus = WARNING_ : sLabel = "WARNING"
    End If

    WScript.Echo sLabel & " - " & gDbName & "/" & gSid & ": " & sMsg & _
        "|sessions_highwater=" & nPeak & ";" & gWarn & ";" & gCrit & _
        ";0 sessions_current=" & nCurrent & ";;;0 sessions_hwm_instance=" & nInstHwm & _
        ";;;0 nup_floor=" & nNupFloor & ";;;0"
    ModeSessions = nStatus
End Function

' =====================================================================
' Mode "freshness"
' =====================================================================
Function ModeFreshness()
    Dim nStatus, sLabel, sMsg
    nStatus = OK_ : sLabel = "OK"
    sMsg = "derniere collecte il y a " & FormatAge(gAge) & " (" & _
           GetKV("collect.date", "inconnue") & "), statut=" & gCStatus

    If gCEpoch = 0 Then
        nStatus = UNKNOWN_ : sLabel = "UNKNOWN"
        sMsg = "horodatage de collecte absent du cache"
    ElseIf gAge > gMaxCacheAge * 2 Then
        nStatus = CRITICAL_ : sLabel = "CRITICAL"
    ElseIf gAge > gMaxCacheAge Then
        nStatus = WARNING_ : sLabel = "WARNING"
    End If

    If gCStatus = "instance_down" Then
        If nStatus = OK_ Then nStatus = WARNING_ : sLabel = "WARNING"
        sMsg = sMsg & " (instance arretee lors de la derniere collecte)"
    ElseIf gCStatus = "query_failed" Then
        nStatus = CRITICAL_ : sLabel = "CRITICAL"
        sMsg = sMsg & " (l'interrogation SQL a echoue)"
    End If

    WScript.Echo sLabel & " - " & gDbName & "/" & gSid & ": " & sMsg & _
        "|cache_age=" & gAge & "s;" & gMaxCacheAge & ";" & (gMaxCacheAge * 2) & ";0"
    ModeFreshness = nStatus
End Function

' =====================================================================
' Mode "inventory"
' =====================================================================
Function ModeInventory()
    Dim nOpt, aKeys, i
    nOpt = 0
    aKeys = gOPT.Keys
    For i = 0 To UBound(aKeys)
        If UCase(gOPT(aKeys(i))) = "TRUE" Then nOpt = nOpt + 1
    Next

    WScript.Echo "OK - " & gDbName & "/" & gSid & ": " & gEdition & " " & gDbVersion & ", " & _
        GetKV("db.role", "-") & ", " & GetKVLong("host.cpu.cores") & " coeurs/" & _
        GetKVLong("host.cpu.sockets") & " sockets, " & nOpt & " option(s) liee(s), " & _
        gNFeat & " feature(s) tracee(s)" & _
        "|linked_options=" & nOpt & ";;;0 tracked_features=" & gNFeat & _
        ";;;0 processor_licenses=" & GetKVLong("host.processor_licenses") & _
        ";;;0 cache_age=" & gAge & "s;;;0"

    WScript.Echo "Hote          : " & GetKV("host.name", "-") & " (" & _
        GetKV("host.cpu.model", "-") & ", " & GetKV("host.virt", "none") & ")"
    WScript.Echo "Base          : " & gDbName & " / DBID " & GetKV("db.dbid", "-") & _
        " / role " & GetKV("db.role", "-") & " / mode " & GetKV("db.open_mode", "-")
    WScript.Echo "ORACLE_HOME   : " & GetKV("inst.oracle_home", "-")
    WScript.Echo "RAC           : " & GetKV("db.rac_instances", "1") & " instance(s)"
    WScript.Echo "Multitenant   : CDB=" & GetKV("db.cdb", "NO") & ", " & _
        GetKVLong("db.pdb_count") & " PDB utilisateur"
    WScript.Echo "Facteur coeur : " & GetKV("host.core_factor", "-") & " -> " & _
        GetKVLong("host.processor_licenses") & " licence(s) Processor"

    ' Sur les versions anterieures a 10.1, l'absence de controle d'usage
    ' doit apparaitre : c'est une limite structurelle, pas un defaut de
    ' collecte.
    If Not gCapUsage Then
        WScript.Echo "Usage options : INDISPONIBLE sur Oracle " & gDbVersion & " (requiert 10.1+)"
    End If

    If gDetail Then
        WScript.Echo "Options liees au binaire (V$OPTION = TRUE) :"
        aKeys = SortedKeys(gOPT)
        For i = 0 To UBound(aKeys)
            If UCase(gOPT(aKeys(i))) = "TRUE" Then WScript.Echo "  - " & aKeys(i)
        Next
    End If
    ModeInventory = OK_
End Function

' =====================================================================
Dim gRc
Select Case LCase(gMode)
    Case "options"    : gRc = ModeOptions()
    Case "processors" : gRc = ModeProcessors()
    Case "sessions"   : gRc = ModeSessions()
    Case "freshness"  : gRc = ModeFreshness()
    Case "inventory"  : gRc = ModeInventory()
    Case Else
        WScript.Echo "UNKNOWN - mode inconnu : " & gMode & " (options|processors|sessions|freshness|inventory)"
        gRc = UNKNOWN_
End Select
WScript.Quit gRc
