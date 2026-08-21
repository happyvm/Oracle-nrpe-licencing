<#
.SYNOPSIS
    Plugin NRPE de controle de conformite des licences Oracle (Windows).

.DESCRIPTION
    Equivalent Windows de bin/check_oracle_licensing.sh. Ne se connecte
    PAS a la base : il lit le cache produit par
    oracle_licensing_collector.ps1, et repond donc en quelques dizaines
    de millisecondes.

    COMPATIBILITE
    Ecrit pour PowerShell 2.0, afin de couvrir Windows Server 2008 R2 et
    au-dela sans installation prealable. Sont donc evites :
      - [pscustomobject] et [ordered]   (PowerShell 3.0)
      - Get-CimInstance                 (PowerShell 3.0)
      - l'operateur -in                 (PowerShell 3.0)
      - Get-Content -Raw                (PowerShell 3.0)
      - les operateurs ?? et ?.         (PowerShell 7)

    Windows Server 2003 n'embarque aucun PowerShell : il faut y installer
    manuellement PowerShell 2.0 (disponible pour 2003 SP2). Cette version
    est en fin de support depuis juillet 2015 ; voir docs/compatibility.md.

    La logique reproduit celle de lib/licensing_eval.awk. Les deux
    moteurs sont compares sur les memes jeux de reference par
    tests/run_parity_tests.sh, afin qu'ils ne divergent pas.

.NOTES
    Codes retour Nagios : 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
#>
param(
    [string] $Sid,
    [string] $Mode = 'options',
    [string] $WarnThreshold,
    [string] $CritThreshold,
    [string] $LicensedOptions,
    [string] $LicensedProcessors,
    [int]    $MaxCacheAge = 93600,
    [switch] $IgnoreHistorical,
    [switch] $Detail,
    [string] $CacheDir   = 'C:\ProgramData\oracle-licensing\cache',
    [string] $MapFile    = 'C:\ProgramData\oracle-licensing\licensable-features.map',
    [string] $ConfigFile = 'C:\ProgramData\oracle-licensing\oracle-licensing.conf',
    [switch] $ShowVersion
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.1.0'

$OK = 0; $WARNING = 1; $CRITICAL = 2; $UNKNOWN = 3

# Les fonctions de mode ecrivent leur rapport sur stdout et deposent
# leur verdict ici. Ne JAMAIS faire "$rc = Invoke-ModeX" : PowerShell
# capturerait le rapport dans $rc au lieu de l'afficher.
$script:ExitCode = $UNKNOWN

function Exit-Unknown([string] $Message) {
    Write-Output ("UNKNOWN - {0}" -f $Message)
    exit 3
}

if ($ShowVersion) { Write-Output ("check_oracle_licensing.ps1 {0}" -f $ScriptVersion); exit 0 }

# ---------------------------------------------------------------------
# Configuration
#
# Le fichier est partage avec la variante Unix : syntaxe CLE="valeur".
# On l'analyse a la main plutot que de l'executer -- un fichier de
# configuration ne doit jamais etre du code executable sous Windows.
# ---------------------------------------------------------------------
function Read-ConfigFile([string] $Path) {
    $cfg = @{}
    if (-not (Test-Path $Path)) { return $cfg }
    foreach ($line in (Get-Content $Path)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $t.Substring(0, $eq).Trim()
        $val = $t.Substring($eq + 1).Trim()
        if ($val.Length -ge 2) {
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $cfg[$key] = $val
    }
    return $cfg
}

$cfg = Read-ConfigFile $ConfigFile

# Un argument explicite prime toujours sur la configuration.
if (-not $LicensedOptions    -and $cfg.ContainsKey('LICENSED_OPTIONS'))    { $LicensedOptions    = $cfg['LICENSED_OPTIONS'] }
if (-not $LicensedProcessors -and $cfg.ContainsKey('LICENSED_PROCESSORS')) { $LicensedProcessors = $cfg['LICENSED_PROCESSORS'] }
if ($cfg.ContainsKey('CACHE_DIR_WIN') -and $CacheDir -eq 'C:\ProgramData\oracle-licensing\cache') { $CacheDir = $cfg['CACHE_DIR_WIN'] }
if ($cfg.ContainsKey('MAX_CACHE_AGE') -and $MaxCacheAge -eq 93600) {
    $parsed = 0
    if ([int]::TryParse($cfg['MAX_CACHE_AGE'], [ref] $parsed)) { $MaxCacheAge = $parsed }
}

if (-not $Sid) { Exit-Unknown 'parametre -Sid obligatoire' }

$CacheFile = Join-Path $CacheDir ($Sid + '.dat')
if (-not (Test-Path $CacheFile)) {
    Exit-Unknown ("cache absent ou illisible : {0} (le collecteur a-t-il tourne ?)" -f $CacheFile)
}
if (-not (Test-Path $MapFile)) {
    Exit-Unknown ("table de correspondance illisible : {0}" -f $MapFile)
}

# ---------------------------------------------------------------------
# Chargement du cache
# ---------------------------------------------------------------------
$KV       = @{}
$OPTV     = @{}
$FeatUsed = @{}; $FeatDet = @{}; $FeatLast = @{}; $FeatFirst = @{}; $FeatAux = @{}
$HWM      = @{}
$NFeat    = 0

foreach ($line in (Get-Content $CacheFile)) {
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $f = $line -split '\|'
    if ($f.Length -lt 3) { continue }
    switch ($f[0]) {
        'KV'   { $KV[$f[1]]   = $f[2] }
        'OPT'  { $OPTV[$f[1]] = $f[2] }
        'HWM'  { $HWM[$f[1]]  = $f[2] }
        'FEAT' {
            if ($f.Length -lt 7) { continue }
            $FeatUsed[$f[1]]  = $f[2]
            $FeatDet[$f[1]]   = $f[3]
            $FeatLast[$f[1]]  = $f[4]
            $FeatFirst[$f[1]] = $f[5]
            $FeatAux[$f[1]]   = $f[6]
            $NFeat++
        }
    }
}

function Get-KV([string] $Key, [string] $Default) {
    if ($KV.ContainsKey($Key) -and $KV[$Key] -ne '') { return $KV[$Key] }
    return $Default
}

function Get-KVInt([string] $Key) {
    $v = Get-KV $Key '0'
    $n = 0
    if ([int]::TryParse($v, [ref] $n)) { return $n }
    return 0
}

$DbName     = Get-KV 'db.name' $Sid
$Edition    = Get-KV 'db.edition' 'UNKNOWN'
$DbVersion  = Get-KV 'inst.version' '0'
$VMajor     = Get-KVInt 'db.version_major'
$CStatus    = Get-KV 'collect.status' 'unknown'
$CEpoch     = Get-KVInt 'collect.epoch'

$UnixEpoch = New-Object System.DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
$NowEpoch  = [int]((Get-Date).ToUniversalTime() - $UnixEpoch).TotalSeconds
$Age = $NowEpoch - $CEpoch

# Capacite de collecte : absente des caches produits par une version
# anterieure du collecteur, auquel cas on se rabat sur la version majeure.
if ($KV.ContainsKey('collect.cap.feature_usage') -and $KV['collect.cap.feature_usage'] -ne '') {
    $CapUsage = ($KV['collect.cap.feature_usage'] -eq '1')
} else {
    $CapUsage = ($VMajor -eq 0 -or $VMajor -ge 10)
}

# ---------------------------------------------------------------------
# Table de correspondance : meme fichier que la variante Unix.
# ---------------------------------------------------------------------
$Rules = @()
foreach ($line in (Get-Content $MapFile)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $f = $t -split '\|'
    if ($f.Length -ne 6) { continue }
    $rule = New-Object PSObject
    $rule | Add-Member NoteProperty Pattern  $f[0]
    $rule | Add-Member NoteProperty Option   $f[1]
    $rule | Add-Member NoteProperty Editions $f[2]
    $rule | Add-Member NoteProperty MinAux   ([int]$f[3])
    $rule | Add-Member NoteProperty FreeFrom $f[4]
    $rule | Add-Member NoteProperty Note     $f[5]
    $Rules += $rule
}
if ($Rules.Length -eq 0) { Exit-Unknown 'table de correspondance vide ou illisible' }

# ---------------------------------------------------------------------
# Comparaison de versions Oracle : "19.22.0.0.0" >= "12.2" vaut vrai.
# [version] plafonne a quatre composants, d'ou une comparaison manuelle.
# ---------------------------------------------------------------------
function Test-VersionGe([string] $A, [string] $B) {
    $x = $A -split '\.'
    $y = $B -split '\.'
    $k = [Math]::Max($x.Length, $y.Length)
    for ($i = 0; $i -lt $k; $i++) {
        $u = 0; $v = 0
        if ($i -lt $x.Length) { [void][int]::TryParse($x[$i], [ref] $u) }
        if ($i -lt $y.Length) { [void][int]::TryParse($y[$i], [ref] $v) }
        if ($u -gt $v) { return $true }
        if ($u -lt $v) { return $false }
    }
    return $true
}

function Test-IsLicensed([string] $Option) {
    if (-not $LicensedOptions) { return $false }
    $want = $Option.Trim().ToLower()
    foreach ($have in ($LicensedOptions -split ',')) {
        if ($have.Trim().ToLower() -eq $want) { return $true }
    }
    return $false
}

function Format-Age([int] $Seconds) {
    if ($Seconds -lt 3600)   { return ("{0} min" -f [int]($Seconds / 60)) }
    if ($Seconds -lt 172800) { return ("{0} h"   -f [int]($Seconds / 3600)) }
    return ("{0} j" -f [int]($Seconds / 86400))
}

function Join-SortedKeys($Table) {
    if ($Table.Count -eq 0) { return '' }
    return (($Table.Keys | Sort-Object) -join ',')
}

# =====================================================================
# Mode "options"
# =====================================================================
function Invoke-ModeOptions {
    # Oracle 9i n'expose aucune source d'usage des options :
    # DBA_FEATURE_USAGE_STATISTICS n'apparait qu'en 10.1. Conclure a la
    # conformite serait un mensonge ; on le dit.
    if (-not $CapUsage) {
        Write-Output ("UNKNOWN - {0}/{1} ({2} {3}): controle d'usage impossible, DBA_FEATURE_USAGE_STATISTICS n'existe qu'a partir d'Oracle 10.1|unlicensed_now=U unlicensed_past=U cache_age={4}s;;{5};0" -f `
            $DbName, $Sid, $Edition, $DbVersion, $Age, $MaxCacheAge)
        Write-Output "Sur cette version, seuls les modes inventory (options liees au binaire)"
        Write-Output "et sessions sont exploitables. Ne declarez pas ce service dans Centreon"
        Write-Output "pour les bases 9i : il resterait UNKNOWN en permanence."
        $script:ExitCode = $UNKNOWN; return
    }

    $violNow = @{}; $violPast = @{}; $covered = @{}; $freed = @{}; $wrongEdition = @{}
    $detail  = @{}

    foreach ($feature in $FeatDet.Keys) {
        $det = 0
        [void][int]::TryParse($FeatDet[$feature], [ref] $det)
        if ($det -le 0) { continue }

        $matched = $null
        foreach ($r in $Rules) {
            # -match est insensible a la casse par defaut, comme le
            # tolower() applique des deux cotes dans la version awk.
            if ($feature -match $r.Pattern) { $matched = $r; break }
        }
        if ($null -eq $matched) { continue }

        $opt  = $matched.Option
        $used = $FeatUsed[$feature].ToUpper()
        $aux  = 0
        [void][int]::TryParse($FeatAux[$feature], [ref] $aux)

        # Seuil AUX_COUNT : Multitenant n'est facturable qu'au-dela
        # d'une PDB, l'usage en deca est inclus dans l'edition.
        if ($matched.MinAux -gt 0 -and $aux -le $matched.MinAux) { continue }

        # Feature devenue gratuite dans cette version.
        if ($matched.FreeFrom -ne '-' -and (Test-VersionGe $DbVersion $matched.FreeFrom)) {
            $freed[$opt] = 1
            continue
        }

        $first = $FeatFirst[$feature]; if (-not $first) { $first = '-' }
        $last  = $FeatLast[$feature];  if (-not $last)  { $last  = '-' }
        $noteTxt = ''
        if ($matched.Note -ne '') { $noteTxt = ' ; ' + $matched.Note }
        $entry = "`n    - {0} (usages={1}, en cours={2}, depuis={3}, dernier={4}{5})" -f `
                 $feature, $det, $used, $first, $last, $noteTxt
        if ($detail.ContainsKey($opt)) { $detail[$opt] = $detail[$opt] + $entry }
        else                           { $detail[$opt] = $entry }

        # Option non vendable dans cette edition : anomalie structurelle
        # qu'aucun bon de commande ne peut regulariser.
        if ($matched.Editions -ne 'ALL' -and $Edition -ne 'UNKNOWN' -and
            (',' + $matched.Editions + ',').IndexOf(',' + $Edition + ',') -lt 0) {
            $wrongEdition[$opt] = 1
            continue
        }

        if (Test-IsLicensed $opt)  { $covered[$opt]  = 1 }
        elseif ($used -eq 'TRUE')  { $violNow[$opt]  = 1 }
        else                       { $violPast[$opt] = 1 }
    }

    # Une option deja en infraction courante ne doit pas etre recomptee.
    foreach ($o in @($violNow.Keys))      { $violPast.Remove($o) }
    foreach ($o in @($wrongEdition.Keys)) { $violNow.Remove($o); $violPast.Remove($o); $covered.Remove($o) }

    $nNow  = $violNow.Count
    $nPast = $violPast.Count
    if ($IgnoreHistorical) { $nPast = 0 }
    $nCov  = $covered.Count
    $nEdt  = $wrongEdition.Count

    $status = $OK; $label = 'OK'
    if ($nEdt -gt 0 -or $nNow -gt 0) { $status = $CRITICAL; $label = 'CRITICAL' }
    elseif ($nPast -gt 0)            { $status = $WARNING;  $label = 'WARNING' }

    # Un cache perime rend le verdict caduc, sans masquer une infraction
    # deja constatee.
    $stale = ''
    if ($Age -gt $MaxCacheAge) {
        $stale = " [cache perime: {0}]" -f (Format-Age $Age)
        if ($status -eq $OK) { $status = $WARNING; $label = 'WARNING' }
    }

    $parts = @()
    if ($nEdt  -gt 0) { $parts += ("{0} option(s) incompatible(s) avec l'edition {1}: {2}" -f $nEdt, $Edition, (Join-SortedKeys $wrongEdition)) }
    if ($nNow  -gt 0) { $parts += ("{0} option(s) non licenciee(s) en cours d'utilisation: {1}" -f $nNow, (Join-SortedKeys $violNow)) }
    if ($nPast -gt 0) { $parts += ("{0} option(s) non licenciee(s) avec usage historique: {1}" -f $nPast, (Join-SortedKeys $violPast)) }
    if ($parts.Length -eq 0) { $parts += ("aucune derive detectee sur {0} option(s) declaree(s)" -f $nCov) }

    Write-Output ("{0} - {1}/{2} ({3} {4}): {5}{6}|unlicensed_now={7};;1;0 unlicensed_past={8};1;;0 wrong_edition={9};;1;0 licensed_used={10};;;0 cache_age={11}s;;{12};0" -f `
        $label, $DbName, $Sid, $Edition, $DbVersion, ($parts -join '; '), $stale, `
        $nNow, $nPast, $nEdt, $nCov, $Age, $MaxCacheAge)

    if ($Detail -or $status -ne $OK) {
        if ($nEdt  -gt 0) { Write-Group "Options incompatibles avec l'edition installee :" $wrongEdition $detail }
        if ($nNow  -gt 0) { Write-Group "Options utilisees SANS licence declaree :" $violNow $detail }
        if ($nPast -gt 0) { Write-Group "Options non licenciees, usage historique uniquement :" $violPast $detail }
        if ($Detail -and $nCov -gt 0) { Write-Group "Options couvertes par la declaration :" $covered $detail }
        if ($Detail -and $freed.Count -gt 0) {
            Write-Output ("Features payantes par le passe, incluses en {0} : {1}" -f $DbVersion, (Join-SortedKeys $freed))
        }
    }
    $script:ExitCode = $status; return
}

function Write-Group([string] $Title, $Table, $DetailMap) {
    Write-Output $Title
    foreach ($k in ($Table.Keys | Sort-Object)) {
        $d = ''
        if ($DetailMap.ContainsKey($k)) { $d = $DetailMap[$k] }
        Write-Output ("  {0}{1}" -f $k, $d)
    }
}

# =====================================================================
# Mode "processors"
#
# ceil(coeurs physiques x facteur de coeur). En virtualisation dite
# "soft partitioning" (VMware, Hyper-V), Oracle considere que tout hote
# ou la VM peut migrer doit etre licencie : le chiffre est un PLANCHER.
# =====================================================================
function Invoke-ModeProcessors {
    $cores    = Get-KVInt 'host.cpu.cores'
    $sockets  = Get-KVInt 'host.cpu.sockets'
    $factor   = Get-KV 'host.core_factor' '1.0'
    $required = Get-KVInt 'host.processor_licenses'
    $virt     = Get-KV 'host.virt' 'none'
    $reliable = Get-KV 'host.cpu.reliable' '1'

    $status = $OK; $label = 'OK'
    $msg = "{0} licence(s) Processor requise(s) ({1} coeurs x facteur {2}, {3} socket(s))" -f `
           $required, $cores, $factor, $sockets

    if ($LicensedProcessors) {
        $held = 0
        [void][int]::TryParse($LicensedProcessors, [ref] $held)
        if ($required -gt $held) {
            $status = $CRITICAL; $label = 'CRITICAL'
            $msg += ", {0} detenue(s) -- deficit de {1}" -f $held, ($required - $held)
        } else {
            $msg += ", {0} detenue(s)" -f $held
        }
    } else {
        $msg += ', aucune declaration de reference'
    }

    # SE2 est plafonnee a 2 sockets ; SE1 et SE l'etaient a 2 et 4.
    if ($Edition -eq 'SE2' -and $sockets -gt 2) {
        $status = $CRITICAL; $label = 'CRITICAL'
        $msg += " ; SE2 limitee a 2 sockets, {0} detectes" -f $sockets
    } elseif ($Edition -eq 'SE1' -and $sockets -gt 2) {
        $status = $CRITICAL; $label = 'CRITICAL'
        $msg += " ; SE1 limitee a 2 sockets, {0} detectes" -f $sockets
    } elseif ($Edition -eq 'SE' -and $sockets -gt 4) {
        $status = $CRITICAL; $label = 'CRITICAL'
        $msg += " ; SE limitee a 4 sockets, {0} detectes" -f $sockets
    }

    if ($reliable -ne '1') {
        if ($status -eq $OK) { $status = $WARNING; $label = 'WARNING' }
        $msg += ' ; comptage de coeurs non fiable (WMI indisponible)'
    }

    if ($virt -ne 'none' -and $virt -ne 'kvm-guest') {
        $msg += " ; hyperviseur '{0}' detecte : verifier la regle de licence du cluster" -f $virt
        if ($status -eq $OK) { $status = $WARNING; $label = 'WARNING' }
    }

    Write-Output ("{0} - {1}/{2}: {3}|processor_licenses={4};;{5};0 cpu_cores={6};;;0 cpu_sockets={7};;;0 cache_age={8}s;;{9};0" -f `
        $label, $DbName, $Sid, $msg, $required, $LicensedProcessors, $cores, $sockets, $Age, $MaxCacheAge)
    $script:ExitCode = $status; return
}

# =====================================================================
# Mode "sessions"
# =====================================================================
function Invoke-ModeSessions {
    $instHwm = Get-KVInt 'license.sessions_highwater'
    $histHwm = 0
    if ($HWM.ContainsKey('SESSIONS')) { [void][int]::TryParse($HWM['SESSIONS'], [ref] $histHwm) }
    $current = Get-KVInt 'license.sessions_current'
    $maxs    = Get-KVInt 'license.sessions_max'
    $procs   = Get-KVInt 'host.processor_licenses'
    $nupFloor = $procs * 25

    # V$LICENSE.sessions_highwater repart de zero a chaque redemarrage de
    # l'instance ; DBA_HIGH_WATER_MARK_STATISTICS conserve le pic
    # historique. Retenir le plus eleve des deux.
    $peak = $instHwm
    if ($histHwm -gt $peak) { $peak = $histHwm }

    $status = $OK; $label = 'OK'
    $msg = "high-water mark {0} session(s), {1} en cours" -f $peak, $current
    if ($maxs -gt 0) { $msg += ", plafond sessions_max={0}" -f $maxs }
    if ($histHwm -gt $instHwm) {
        $msg += " (pic historique {0} > pic depuis demarrage {1})" -f $histHwm, $instHwm
    }
    $msg += " ; plancher NUP contractuel: {0} (25 x {1} Processor)" -f $nupFloor, $procs

    if ($CritThreshold) {
        $c = 0; [void][int]::TryParse($CritThreshold, [ref] $c)
        if ($peak -ge $c) { $status = $CRITICAL; $label = 'CRITICAL' }
    }
    if ($status -eq $OK -and $WarnThreshold) {
        $w = 0; [void][int]::TryParse($WarnThreshold, [ref] $w)
        if ($peak -ge $w) { $status = $WARNING; $label = 'WARNING' }
    }

    Write-Output ("{0} - {1}/{2}: {3}|sessions_highwater={4};{5};{6};0 sessions_current={7};;;0 sessions_hwm_instance={8};;;0 nup_floor={9};;;0" -f `
        $label, $DbName, $Sid, $msg, $peak, $WarnThreshold, $CritThreshold, $current, $instHwm, $nupFloor)
    $script:ExitCode = $status; return
}

# =====================================================================
# Mode "freshness"
# =====================================================================
function Invoke-ModeFreshness {
    $status = $OK; $label = 'OK'
    $msg = "derniere collecte il y a {0} ({1}), statut={2}" -f `
           (Format-Age $Age), (Get-KV 'collect.date' 'inconnue'), $CStatus

    if ($CEpoch -eq 0) {
        $status = $UNKNOWN; $label = 'UNKNOWN'
        $msg = 'horodatage de collecte absent du cache'
    } elseif ($Age -gt ($MaxCacheAge * 2)) {
        $status = $CRITICAL; $label = 'CRITICAL'
    } elseif ($Age -gt $MaxCacheAge) {
        $status = $WARNING; $label = 'WARNING'
    }

    if ($CStatus -eq 'instance_down') {
        if ($status -eq $OK) { $status = $WARNING; $label = 'WARNING' }
        $msg += ' (instance arretee lors de la derniere collecte)'
    } elseif ($CStatus -eq 'query_failed') {
        $status = $CRITICAL; $label = 'CRITICAL'
        $msg += " (l'interrogation SQL a echoue)"
    }

    Write-Output ("{0} - {1}/{2}: {3}|cache_age={4}s;{5};{6};0" -f `
        $label, $DbName, $Sid, $msg, $Age, $MaxCacheAge, ($MaxCacheAge * 2))
    $script:ExitCode = $status; return
}

# =====================================================================
# Mode "inventory"
# =====================================================================
function Invoke-ModeInventory {
    $nopt = 0
    foreach ($k in $OPTV.Keys) { if ($OPTV[$k].ToUpper() -eq 'TRUE') { $nopt++ } }

    Write-Output ("OK - {0}/{1}: {2} {3}, {4}, {5} coeurs/{6} sockets, {7} option(s) liee(s), {8} feature(s) tracee(s)|linked_options={7};;;0 tracked_features={8};;;0 processor_licenses={9};;;0 cache_age={10}s;;;0" -f `
        $DbName, $Sid, $Edition, $DbVersion, (Get-KV 'db.role' '-'), `
        (Get-KVInt 'host.cpu.cores'), (Get-KVInt 'host.cpu.sockets'), `
        $nopt, $NFeat, (Get-KVInt 'host.processor_licenses'), $Age)

    Write-Output ("Hote          : {0} ({1}, {2})" -f (Get-KV 'host.name' '-'), (Get-KV 'host.cpu.model' '-'), (Get-KV 'host.virt' 'none'))
    Write-Output ("Base          : {0} / DBID {1} / role {2} / mode {3}" -f $DbName, (Get-KV 'db.dbid' '-'), (Get-KV 'db.role' '-'), (Get-KV 'db.open_mode' '-'))
    Write-Output ("ORACLE_HOME   : {0}" -f (Get-KV 'inst.oracle_home' '-'))
    Write-Output ("RAC           : {0} instance(s)" -f (Get-KV 'db.rac_instances' '1'))
    Write-Output ("Multitenant   : CDB={0}, {1} PDB utilisateur" -f (Get-KV 'db.cdb' 'NO'), (Get-KVInt 'db.pdb_count'))
    Write-Output ("Facteur coeur : {0} -> {1} licence(s) Processor" -f (Get-KV 'host.core_factor' '-'), (Get-KVInt 'host.processor_licenses'))

    # Sur les versions anterieures a 10.1, l'absence de controle d'usage
    # doit apparaitre : c'est une limite structurelle, pas un defaut de
    # collecte.
    if (-not $CapUsage) {
        Write-Output ("Usage options : INDISPONIBLE sur Oracle {0} (requiert 10.1+)" -f $DbVersion)
    }

    if ($Detail) {
        Write-Output 'Options liees au binaire (V$OPTION = TRUE) :'
        foreach ($k in ($OPTV.Keys | Sort-Object)) {
            if ($OPTV[$k].ToUpper() -eq 'TRUE') { Write-Output ("  - {0}" -f $k) }
        }
    }
    $script:ExitCode = $OK; return
}

# =====================================================================
switch ($Mode) {
    'options'    { Invoke-ModeOptions }
    'processors' { Invoke-ModeProcessors }
    'sessions'   { Invoke-ModeSessions }
    'freshness'  { Invoke-ModeFreshness }
    'inventory'  { Invoke-ModeInventory }
    default {
        Write-Output ("UNKNOWN - mode inconnu : {0} (options|processors|sessions|freshness|inventory)" -f $Mode)
        $script:ExitCode = $UNKNOWN
    }
}
exit $script:ExitCode
