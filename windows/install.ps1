<#
.SYNOPSIS
    Installe le collecteur et le plugin de licences Oracle sur Windows.

.DESCRIPTION
    Voie d'installation principale, pour Windows Server 2008 R2 et
    au-dela (PowerShell 2.0 ou superieur).

    A executer dans une console PowerShell elevee.

    Depose les scripts, la table de correspondance et le SQL, cree le
    repertoire de cache, et enregistre une tache planifiee quotidienne.

    Les serveurs SANS PowerShell utilisable -- Windows Server 2003, ou
    2008 reste en PowerShell 1.0 -- passent par windows\install.cmd, qui
    deploie la variante VBScript.
#>
param(
    [string] $InstallDir = 'C:\Program Files\oracle-licensing',
    [string] $DataDir    = 'C:\ProgramData\oracle-licensing',
    [string] $OracleUser = '',
    [switch] $SkipTask
)

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $src

Write-Output '== Repertoires'
foreach ($d in @($InstallDir, $DataDir, (Join-Path $DataDir 'cache'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

Write-Output '== Scripts'
Copy-Item (Join-Path $src 'check_oracle_licensing.ps1')     $InstallDir -Force
Copy-Item (Join-Path $src 'oracle_licensing_collector.ps1') $InstallDir -Force
Copy-Item (Join-Path $root 'sql\collect_licensing.sql')     $InstallDir -Force

Write-Output '== Donnees de reference'
Copy-Item (Join-Path $root 'etc\licensable-features.map') $DataDir -Force
Copy-Item (Join-Path $root 'etc\structural-evidence.map') $DataDir -Force

# La configuration porte la declaration contractuelle : on ne l'ecrase
# jamais lors d'une mise a jour.
$conf = Join-Path $DataDir 'oracle-licensing.conf'
if (Test-Path $conf) {
    Write-Output "   configuration existante conservee : $conf"
    Copy-Item (Join-Path $root 'etc\oracle-licensing.conf.example') "$conf.example" -Force
} else {
    Copy-Item (Join-Path $root 'etc\oracle-licensing.conf.example') $conf -Force
    Write-Output '   configuration initiale deposee -- A RENSEIGNER : LICENSED_OPTIONS'
}

if (-not $SkipTask) {
    Write-Output '== Tache planifiee'
    $collector = Join-Path $InstallDir 'oracle_licensing_collector.ps1'
    # schtasks plutot que les applets ScheduledTask, absentes avant
    # Windows Server 2012.
    $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$collector`""
    $args = @('/Create', '/F', '/TN', 'OracleLicensingCollector',
              '/TR', $action, '/SC', 'DAILY', '/ST', '03:17')
    if ($OracleUser) { $args += @('/RU', $OracleUser) }
    else             { $args += @('/RU', 'SYSTEM') }
    & schtasks.exe @args
    Write-Output '   tache OracleLicensingCollector creee (quotidienne, 03h17)'
}

Write-Output @"

Installation terminee.

Etapes suivantes :
  1. Renseignez la declaration contractuelle dans
     $conf
     (LICENSED_OPTIONS et LICENSED_PROCESSORS, depuis vos bons de
     commande Oracle -- pas depuis ce qui est observe en base).
  2. Le compte executant la tache doit appartenir au groupe local
     ORA_DBA, faute de quoi la connexion "/ as sysdba" echouera.
  3. Lancez une premiere collecte :
     & '$InstallDir\oracle_licensing_collector.ps1' -Trace
  4. Verifiez le rendu :
     & '$InstallDir\check_oracle_licensing.ps1' -Sid <SID> -Mode inventory -Detail
  5. Fusionnez windows\nsclient-oracle-licensing.ini dans nsclient.ini
     (la version PowerShell, PAS le fichier -vbs), puis redemarrez
     NSClient++.
"@
