@echo off
rem =====================================================================
rem  install.cmd
rem
rem  Installe le collecteur et le plugin de licences Oracle sur Windows,
rem  SANS PowerShell.
rem
rem  Destine en premier lieu a Windows Server 2003, qui n'embarque aucun
rem  PowerShell, mais utilisable sur toute version : batch et Windows
rem  Script Host sont presents de Windows 2000 a Server 2025.
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

rem Racine du depot : le repertoire parent de ce script.
set SRC=%~dp0..

echo == Verification de l'environnement
cscript //NoLogo //B "%~dp0checkenv.vbs" 2>nul
if errorlevel 1 (
    echo    ERREUR : Windows Script Host indisponible ou desactive.
    echo    Ce mode d'installation en depend. Verifiez la strategie de
    echo    groupe, ou utilisez windows\install.ps1 avec PowerShell.
    exit /b 1
)
echo    Windows Script Host : disponible

echo == Repertoires
if not exist "%INSTALL_DIR%"       mkdir "%INSTALL_DIR%"
if not exist "%DATA_DIR%"          mkdir "%DATA_DIR%"
if not exist "%DATA_DIR%\cache"    mkdir "%DATA_DIR%\cache"

echo == Scripts
copy /Y "%SRC%\windows\check_oracle_licensing.vbs"     "%INSTALL_DIR%\" >nul
copy /Y "%SRC%\windows\oracle_licensing_collector.vbs" "%INSTALL_DIR%\" >nul
copy /Y "%SRC%\sql\collect_licensing.sql"              "%INSTALL_DIR%\" >nul

rem Les variantes PowerShell sont deposees aussi : elles ne servent que
rem si WSH vient a etre desactive, ou apres le retrait de VBScript.
if exist "%SRC%\windows\check_oracle_licensing.ps1" (
    copy /Y "%SRC%\windows\check_oracle_licensing.ps1"     "%INSTALL_DIR%\" >nul
    copy /Y "%SRC%\windows\oracle_licensing_collector.ps1" "%INSTALL_DIR%\" >nul
)

echo == Donnees de reference
copy /Y "%SRC%\etc\licensable-features.map" "%DATA_DIR%\" >nul

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
echo Installation terminee.
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
echo   5. Fusionnez windows\nsclient-oracle-licensing.ini dans nsclient.ini,
echo      puis redemarrez NSClient++.

endlocal
