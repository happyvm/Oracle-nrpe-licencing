<#
.SYNOPSIS
    Collecteur de conformite des licences Oracle (Windows).

.DESCRIPTION
    Equivalent Windows de bin/oracle_licensing_collector.sh. Interroge
    chaque instance Oracle locale et l'inventaire materiel, puis depose
    un cache plat lu ensuite par check_oracle_licensing.ps1.

    A planifier une a deux fois par jour via le Planificateur de taches.
    La collecte peut durer des dizaines de secondes : c'est pour cela
    qu'elle est separee du plugin NRPE.

    COMPATIBILITE
    Ecrit pour PowerShell 2.0 (Windows Server 2008 R2 et au-dela).
    Get-WmiObject est employe plutot que Get-CimInstance, absent avant
    PowerShell 3.0. Sur PowerShell 6 et superieur, Get-WmiObject a ete
    supprime : le script bascule alors sur Get-CimInstance.

    Windows Server 2003 n'embarque aucun PowerShell ; voir
    docs/compatibility.md.

    Aucune ecriture en base. Aucun mot de passe : l'authentification
    "/ as sysdba" repose sur l'appartenance au groupe local ORA_DBA.
#>
param(
    [string] $ConfigFile = 'C:\ProgramData\oracle-licensing\oracle-licensing.conf',
    [string] $CacheDir   = 'C:\ProgramData\oracle-licensing\cache',
    [string] $SqlFile    = 'C:\Program Files\oracle-licensing\collect_licensing.sql',
    [string[]] $Sid      = @(),
    [int]    $SqlTimeout = 120,
    [string] $CoreFactor = '',
    [switch] $DryRun,
    [switch] $Trace
)

$ErrorActionPreference = 'Continue'
$ScriptVersion = '1.1.0'

function Write-Trace([string] $Message) {
    if ($Trace) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }
}
function Write-Warn([string] $Message) {
    [Console]::Error.WriteLine("oracle_licensing_collector: " + $Message)
}

# ---------------------------------------------------------------------
# Configuration : meme fichier que la variante Unix, analyse a la main.
# ---------------------------------------------------------------------
$ExcludeSids = @()
if (Test-Path $ConfigFile) {
    foreach ($line in (Get-Content $ConfigFile)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $t.Substring(0, $eq).Trim()
        $v = $t.Substring($eq + 1).Trim().Trim('"').Trim("'")
        switch ($k) {
            'CACHE_DIR_WIN'   { if ($CacheDir -eq 'C:\ProgramData\oracle-licensing\cache') { $CacheDir = $v } }
            'SQL_FILE_WIN'    { if ($SqlFile  -eq 'C:\Program Files\oracle-licensing\collect_licensing.sql') { $SqlFile = $v } }
            'SQLPLUS_TIMEOUT' { if ($SqlTimeout -eq 120) { $n = 0; if ([int]::TryParse($v, [ref] $n)) { $SqlTimeout = $n } } }
            'CORE_FACTOR'     { if (-not $CoreFactor) { $CoreFactor = $v } }
            'EXCLUDE_SIDS'    { $ExcludeSids = @($v -split '[ ,]+' | Where-Object { $_ -ne '' }) }
        }
    }
}

# ---------------------------------------------------------------------
# Acces WMI compatible PowerShell 2.0 comme 7.
# Get-WmiObject a disparu en PowerShell 6 ; Get-CimInstance n'existe pas
# avant la 3.0. On choisit selon ce qui est reellement disponible.
# ---------------------------------------------------------------------
function Get-WmiCompat([string] $Class) {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        return Get-CimInstance -ClassName $Class -ErrorAction SilentlyContinue
    }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        return Get-WmiObject -Class $Class -ErrorAction SilentlyContinue
    }
    return $null
}

# ---------------------------------------------------------------------
# Inventaire CPU
#
# C'est ce qui justifie la collecte locale : la facturation Oracle porte
# sur les coeurs physiques du serveur -- voire de tout le cluster en
# virtualisation dite "soft partitioning" -- alors qu'une interrogation
# distante ne verrait que ce que l'hyperviseur expose a l'invite.
# ---------------------------------------------------------------------
function Get-HostCpuBlock {
    $lines = @()
    $sockets = 0; $cores = 0; $threads = 0; $model = 'unknown'; $reliable = 1

    $procs = @(Get-WmiCompat 'Win32_Processor')
    if ($procs -and $procs.Count -gt 0) {
        # Une instance Win32_Processor par processeur physique installe.
        $sockets = $procs.Count
        $model   = $procs[0].Name
        foreach ($p in $procs) {
            # NumberOfCores est absent avant Windows Server 2003 SP2.
            if ($p.NumberOfCores)             { $cores   += [int]$p.NumberOfCores }
            if ($p.NumberOfLogicalProcessors) { $threads += [int]$p.NumberOfLogicalProcessors }
        }
    }

    if ($threads -eq 0) {
        $cs = @(Get-WmiCompat 'Win32_ComputerSystem')
        if ($cs -and $cs.Count -gt 0 -and $cs[0].NumberOfLogicalProcessors) {
            $threads = [int]$cs[0].NumberOfLogicalProcessors
        }
    }

    # Dernier recours : un thread pour un coeur. Sous-estime des que
    # l'hyperthreading est actif, donc signale comme non fiable.
    if ($cores -eq 0) {
        $cores = $threads
        $reliable = 0
        if ($sockets -eq 0) { $sockets = 0 }
    }

    # Virtualisation, deduite du constructeur et du modele exposes.
    $virt = 'none'
    $cs = @(Get-WmiCompat 'Win32_ComputerSystem')
    if ($cs -and $cs.Count -gt 0) {
        $mk = ("" + $cs[0].Manufacturer + " " + $cs[0].Model)
        if     ($mk -match 'VMware')                  { $virt = 'vmware' }
        elseif ($mk -match 'Virtual Machine|Hyper-V') { $virt = 'microsoft' }
        elseif ($mk -match 'VirtualBox|innotek')      { $virt = 'oracle' }
        elseif ($mk -match 'QEMU|KVM')                { $virt = 'kvm' }
        elseif ($mk -match 'Xen')                     { $virt = 'xen' }
        elseif ($mk -match 'Parallels')               { $virt = 'parallels' }
    }

    # Table des facteurs de coeur Oracle : 0,5 en x86_64 multicoeur.
    # Windows ne tourne que sur x86/x64 dans ce perimetre.
    $factor = '0.5'
    if ($CoreFactor) { $factor = $CoreFactor }

    # Oracle arrondit toujours a l'entier superieur.
    $required = [int][Math]::Ceiling([double]$cores * [double]$factor)

    $lines += "KV|host.name|$($env:COMPUTERNAME)"
    $lines += "KV|host.arch|$($env:PROCESSOR_ARCHITECTURE)"
    $lines += "KV|host.cpu.model|$model"
    $lines += "KV|host.cpu.sockets|$sockets"
    $lines += "KV|host.cpu.cores|$cores"
    $lines += "KV|host.cpu.threads|$threads"
    $lines += "KV|host.cpu.reliable|$reliable"
    $lines += "KV|host.virt|$virt"
    $lines += "KV|host.core_factor|$factor"
    $lines += "KV|host.processor_licenses|$required"
    return $lines
}

# ---------------------------------------------------------------------
# Decouverte des instances
#
# Deux sources complementaires, car leur disposition a change :
#   - HKLM\SOFTWARE\ORACLE\HOME<n>  : Oracle 9i et 10g
#   - HKLM\SOFTWARE\ORACLE\KEY_<nom>: Oracle 10g et suivants
# Les services OracleService<SID> completent la liste et donnent l'etat
# de demarrage, equivalent du processus pmon sous Unix.
# ---------------------------------------------------------------------
function Get-OracleInstances {
    $found = @{}

    foreach ($root in @('HKLM:\SOFTWARE\ORACLE', 'HKLM:\SOFTWARE\Wow6432Node\ORACLE')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $leaf = Split-Path $key.Name -Leaf
            if ($leaf -notmatch '^(KEY_|HOME\d+$)') { continue }
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            $home = $props.ORACLE_HOME
            $sid  = $props.ORACLE_SID
            if (-not $home -or -not (Test-Path $home)) { continue }
            if ($sid) { $found[$sid] = $home }
        }
    }

    # Les services nomment le SID, ce que le registre omet parfois quand
    # plusieurs instances partagent un ORACLE_HOME.
    foreach ($svc in @(Get-WmiCompat 'Win32_Service')) {
        if ($svc.Name -notmatch '^OracleService(.+)$') { continue }
        $svcSid = $Matches[1]
        if ($found.ContainsKey($svcSid)) { continue }
        # Rattacher au premier ORACLE_HOME connu, faute de mieux.
        foreach ($h in $found.Values) { $found[$svcSid] = $h; break }
    }

    return $found
}

function Test-InstanceRunning([string] $InstanceSid) {
    $svc = Get-Service -Name ("OracleService" + $InstanceSid) -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $false }
    return ($svc.Status -eq 'Running')
}

# ---------------------------------------------------------------------
# Interrogation d'une instance
#
# sqlplus est lance avec un delai maximal : une base gelee ne doit pas
# immobiliser la collecte de tout le serveur.
# ---------------------------------------------------------------------
function Invoke-SqlPlus([string] $InstanceSid, [string] $OracleHome) {
    $sqlplus = Join-Path $OracleHome 'bin\sqlplus.exe'
    if (-not (Test-Path $sqlplus)) {
        Write-Warn ("{0} : sqlplus introuvable dans {1}\bin" -f $InstanceSid, $OracleHome)
        return $null
    }

    $tmpIn  = [System.IO.Path]::GetTempFileName()
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()

    # Le fichier d'entree porte la connexion puis l'appel du script.
    Set-Content -Path $tmpIn -Encoding ASCII -Value @(
        'CONNECT / AS SYSDBA'
        ('@"' + $SqlFile + '"')
    )

    $env:ORACLE_SID  = $InstanceSid
    $env:ORACLE_HOME = $OracleHome
    $env:NLS_LANG    = 'AMERICAN_AMERICA.AL32UTF8'

    $result = $null
    try {
        # cmd /c permet la redirection de l'entree standard, que
        # Start-Process ne sait pas alimenter directement en 2.0.
        $cmdLine = ('/c ""{0}" -S -L /nolog < "{1}""' -f $sqlplus, $tmpIn)
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine `
                    -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr `
                    -NoNewWindow -PassThru

        if (-not $proc.WaitForExit($SqlTimeout * 1000)) {
            Write-Warn ("{0} : delai de {1} s depasse" -f $InstanceSid, $SqlTimeout)
            try { $proc.Kill() } catch { }
            return $null
        }

        $out = @()
        if (Test-Path $tmpOut) { $out = @(Get-Content $tmpOut) }

        # sqlplus signale les erreurs Oracle dans le flux, pas toujours
        # par son code retour : on inspecte le texte.
        $errLines = @($out | Where-Object { $_ -match '^(ORA|SP2|TNS)-[0-9]+' })
        if ($errLines.Count -gt 0) {
            $notOpen = @($out | Where-Object { $_ -match '^(ORA-01219|ORA-01507|ORA-01034)' })
            if ($notOpen.Count -gt 0) {
                # Base non ouverte : le rapport reste exploitable pour
                # l'identite et V$OPTION.
                Write-Warn ("{0} : base non ouverte ({1}), collecte partielle" -f $InstanceSid, $errLines[0])
            } else {
                Write-Warn ("{0} : {1}" -f $InstanceSid, $errLines[0])
                $hasName = @($out | Where-Object { $_ -match '^KV\|db\.name\|' })
                if ($hasName.Count -eq 0) { return $null }
            }
        }

        # On ne conserve que les enregistrements structures.
        $result = @($out | Where-Object { $_ -match '^(KV|OPT|FEAT|HWM)\|' })
    } finally {
        foreach ($f in @($tmpIn, $tmpOut, $tmpErr)) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    }
    return $result
}

# ---------------------------------------------------------------------
# Ecriture du cache
#
# Ecriture dans un fichier temporaire puis remplacement : Move-Item -Force
# s'appuie sur MoveFileEx, dont le remplacement est atomique sur un meme
# volume NTFS. Le plugin ne peut donc jamais lire un cache a moitie ecrit.
# ---------------------------------------------------------------------
function Write-CacheFile([string] $InstanceSid, [string[]] $Content) {
    $target = Join-Path $CacheDir ($InstanceSid + '.dat')
    $tmp    = $target + '.tmp'
    try {
        Set-Content -Path $tmp -Value $Content -Encoding ASCII
        Move-Item -Path $tmp -Destination $target -Force
        Write-Trace ("{0} : cache ecrit dans {1}" -f $InstanceSid, $target)
        return $true
    } catch {
        Write-Warn ("{0} : ecriture du cache impossible -- {1}" -f $InstanceSid, $_.Exception.Message)
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# =====================================================================
if (-not (Test-Path $SqlFile)) {
    Write-Warn ("script SQL illisible : {0}" -f $SqlFile)
    exit 2
}
if (-not $DryRun -and -not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

$UnixEpoch = New-Object System.DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
$hostBlock = Get-HostCpuBlock
$instances = Get-OracleInstances

if ($instances.Count -eq 0) {
    Write-Warn 'aucune instance Oracle trouvee dans le registre ni parmi les services'
    exit 2
}
Write-Trace ("{0} instance(s) a traiter" -f $instances.Count)

$ok = 0; $ko = 0
foreach ($instanceSid in @($instances.Keys)) {
    if ($Sid.Count -gt 0 -and -not ($Sid -contains $instanceSid)) {
        Write-Trace ("{0} ignore (hors -Sid)" -f $instanceSid); continue
    }
    if ($ExcludeSids -contains $instanceSid) {
        Write-Trace ("{0} ignore (EXCLUDE_SIDS)" -f $instanceSid); continue
    }

    $oracleHome = $instances[$instanceSid]
    $running    = Test-InstanceRunning $instanceSid
    Write-Trace ("{0} : demarree={1} home={2}" -f $instanceSid, $running, $oracleHome)

    $nowEpoch = [int]((Get-Date).ToUniversalTime() - $UnixEpoch).TotalSeconds
    $header = @(
        '# oracle-licensing cache v1 -- NE PAS EDITER'
        "KV|collect.version|$ScriptVersion"
        "KV|collect.epoch|$nowEpoch"
        ("KV|collect.date|" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
        "KV|inst.sid|$instanceSid"
        "KV|inst.oracle_home|$oracleHome"
        ("KV|inst.running|" + $(if ($running) { '1' } else { '0' }))
    )

    if (-not $running) {
        # Instance a l'arret : on publie quand meme une fiche pour que le
        # plugin distingue "arretee" de "jamais collectee".
        $content = $header + $hostBlock + @('KV|collect.status|instance_down')
        $ko++
    } else {
        $dbBlock = Invoke-SqlPlus $instanceSid $oracleHome
        if ($null -ne $dbBlock -and $dbBlock.Count -gt 0) {
            $content = $header + $hostBlock + $dbBlock + @('KV|collect.status|ok')
            $ok++
        } else {
            $content = $header + $hostBlock + @('KV|collect.status|query_failed')
            $ko++
        }
    }

    if ($DryRun) { $content | ForEach-Object { Write-Output $_ } }
    elseif (-not (Write-CacheFile $instanceSid $content)) { $ko++ }
}

Write-Trace ("termine : {0} succes, {1} echec(s)" -f $ok, $ko)
if ($ok -gt 0 -and $ko -eq 0) { exit 0 }
if ($ok -gt 0)                { exit 1 }
exit 2
