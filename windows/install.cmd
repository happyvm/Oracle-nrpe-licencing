@echo off
rem =====================================================================
rem  install.cmd
rem
rem  Installe le collecteur et le plugin de licences Oracle sur les
rem  serveurs Windows DEPOURVUS de PowerShell utilisable.
rem
rem  Deploie la variante VBScript / Windows Script Host. Elle n'est
rem  destinee qu'a Windows Server 2003, a Windows Server 2008 reste en
rem  PowerShell 1.0, et aux serveurs ou une strategie de groupe interdit
rem  l'execution de scripts PowerShell.
rem
rem  Partout ailleurs, utilisez windows\install.ps1 : PowerShell est la
rem  voie principale, et VBScript est deprecie par Microsoft depuis 2023.
rem
rem  Ce script DETECTE PowerShell et s'arrete s'il en trouve une version
rem  2.0 ou superieure -- deployer VBScript la ou il est inutile
rem  reviendrait a se lier volontairement a un langage en fin de vie.
rem  Passez /Force pour outrepasser (cas des GPO restrictives).
rem
rem  A executer depuis une invite de commandes ADMINISTRATEUR, a la
rem  racine du depot :
rem      windows\install.cmd
rem
rem  Variables surchargeables avant appel :
rem      set INSTALL_DIR=D:\oracle-licensing
rem      set DATA_DIR=D:\oracle-licensing-data
rem      set TASK_USER=DOMAINE\compte_oracle
rem =====================================================================

setlocal

set FORCE=0
if /I "%~1"=="/Force" set FORCE=1
if /I "%~1"=="-Force" set FORCE=1

if "%INSTALL_DIR%"=="" set INSTALL_DIR=C:\Program Files\oracle-licensing
if "%DATA_DIR%"==""    set DATA_DIR=C:\ProgramData\oracle-licensing
if "%TASK_USER%"==""   set TASK_USER=SYSTEM

rem Sur Windows 2003, %ProgramData% n'existe pas : on se rabat sur le
rem profil "All Users", equivalent fonctionnel sur cette version.
if not exist "%ProgramData%\" (
    if "%DATA_DIR%"=="C:\ProgramData\oracle-licensing" (
        set DATA_DIR=%ALLUSERSPROFILE%\oracle-licensing
    )
)

set SRC=%~dp0..

rem ------------------------------------------------------------------
rem  Detection de PowerShell
rem
rem  Sur PowerShell 1.0, $PSVersionTable n'existe pas : l'expression
rem  rend $null et "exit" retourne 0. Un code retour inferieur a 2
rem  signifie donc "pas de PowerShell exploitable ici".
rem ------------------------------------------------------------------
rem  Le "set" reste HORS du bloc "if" : a l'interieur, %errorlevel%
rem  serait remplace des l'analyse du bloc et vaudrait toujours 0, ce
rem  qui rendrait la detection inoperante sans rien signaler.
set PSMAJOR=0
set PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
if not exist "%PSEXE%" goto :ps_checked
"%PSEXE%" -NoProfile -Command "exit $PSVersionTable.PSVersion.Major" >nul 2>&1
set PSMAJOR=%errorlevel%
:ps_checked

if %PSMAJOR% GEQ 2 (
    if "%FORCE%"=="0" (
        echo.
        echo   PowerShell %PSMAJOR%.x est present sur ce serveur.
        echo.
        echo   La variante VBScript n'est pas necessaire ici : elle est
        echo   reservee aux serveurs qui n'ont pas de PowerShell, car le
        echo   langage est deprecie par Microsoft depuis 2023.
        echo.
        echo   Utilisez plutot, dans une console PowerShell elevee :
        echo       .\windows\install.ps1
        echo   et cote NSClient++ :
        echo       windows\nsclient-oracle-licensing.ini
        echo.
        echo   Si une strategie de groupe interdit l'execution de scripts
        echo   PowerShell sur ce serveur, relancez avec :
        echo       windows\install.cmd /Force
        echo.
        exit /b 1
    )
    echo == PowerShell %PSMAJOR%.x detecte, installation VBScript forcee
) else (
    echo == Aucun PowerShell exploitable detecte : variante VBScript appropriee
)

echo == Verification de l'environnement
cscript //NoLogo //B "%~dp0checkenv.vbs" 2>nul
if errorlevel 1 (
    echo    ERREUR : Windows Script Host indisponible ou desactive.
    echo    Ce mode d'installation en depend, et aucun PowerShell
    echo    utilisable n'a ete trouve. Ce serveur ne peut pas etre
    echo    supervise en l'etat : activez WSH, ou installez WMF 2.0.
    exit /b 1
)
echo    Windows Script Host : disponible

echo == Repertoires
if not exist "%INSTALL_DIR%"       mkdir "%INSTALL_DIR%"
if not exist "%DATA_DIR%"          mkdir "%DATA_DIR%"
if not exist "%DATA_DIR%\cache"    mkdir "%DATA_DIR%\cache"

rem Seule la variante VBScript est deposee : installer aussi les
rem scripts PowerShell sur une machine qui ne peut pas les executer
rem n'apporterait que de la confusion a la prochaine intervention.
echo == Scripts (variante VBScript)
copy /Y "%SRC%\windows\check_oracle_licensing.vbs"     "%INSTALL_DIR%\" >nul
copy /Y "%SRC%\windows\oracle_licensing_collector.vbs" "%INSTALL_DIR%\" >nul
copy /Y "%SRC%\sql\collect_licensing.sql"              "%INSTALL_DIR%\" >nul

echo == Donnees de reference
copy /Y "%SRC%\etc\licensable-features.map" "%DATA_DIR%\" >nul
copy /Y "%SRC%\etc\structural-evidence.map" "%DATA_DIR%\" >nul

rem La configuration porte la declaration contractuelle : on ne l'ecrase
rem jamais lors d'une mise a jour.
if exist "%DATA_DIR%\oracle-licensing.conf" (
    echo    configuration existante conservee
    copy /Y "%SRC%\etc\oracle-licensing.conf.example" "%DATA_DIR%\oracle-licensing.conf.example" >nul
) else (
    copy /Y "%SRC%\etc\oracle-licensing.conf.example" "%DATA_DIR%\oracle-licensing.conf" >nul
    echo    configuration initiale deposee -- A RENSEIGNER : LICENSED_OPTIONS
)

echo == Tache planifiee
schtasks /Create /F /TN OracleLicensingCollector ^
    /TR "cscript //NoLogo //B \"%INSTALL_DIR%\oracle_licensing_collector.vbs\"" ^
    /SC DAILY /ST 03:17 /RU %TASK_USER% >nul 2>&1
if errorlevel 1 (
    echo    ECHEC de la creation automatique. Creez-la a la main :
    echo      schtasks /Create /TN OracleLicensingCollector /SC DAILY /ST 03:17 ^
              /TR "cscript //NoLogo //B \"%INSTALL_DIR%\oracle_licensing_collector.vbs\""
) else (
    echo    tache OracleLicensingCollector creee ^(quotidienne, 03h17^)
)

echo.
echo Installation terminee (variante VBScript).
echo.
echo Etapes suivantes :
echo   1. Renseignez la declaration contractuelle dans
echo      %DATA_DIR%\oracle-licensing.conf
echo      ^(LICENSED_OPTIONS et LICENSED_PROCESSORS, depuis vos bons de
echo      commande Oracle -- pas depuis ce qui est observe en base^).
echo   2. Le compte executant la tache doit appartenir au groupe local
echo      ORA_DBA, sinon la connexion "/ as sysdba" echouera.
echo   3. Premiere collecte :
echo      cscript //NoLogo "%INSTALL_DIR%\oracle_licensing_collector.vbs" /Trace
echo   4. Verification :
echo      cscript //NoLogo "%INSTALL_DIR%\check_oracle_licensing.vbs" /Sid:^<SID^> /Mode:inventory /Detail
echo   5. Fusionnez windows\nsclient-oracle-licensing-VBS.ini dans
echo      nsclient.ini ^(surtout PAS la version PowerShell^), puis
echo      redemarrez NSClient++.

endlocal
