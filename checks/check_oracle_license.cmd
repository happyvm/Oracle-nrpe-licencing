@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Nagios/NRPE Oracle license-risk inventory check.
rem Uses only cmd.exe + sc.exe + SQL*Plus, so PowerShell is not required.

set "SCRIPT_DIR=%~dp0"
if not defined SQL_FILE set "SQL_FILE=%SCRIPT_DIR%check_oracle_license.sql"
if not defined RULES_FILE set "RULES_FILE=%SCRIPT_DIR%..\config\oracle_license.rules"
if not defined INSTANCES_FILE set "INSTANCES_FILE=%SCRIPT_DIR%..\config\oracle_instances.conf"

set /a STATE=0
set /a INSTANCES=0
set /a QUERIED=0
set /a VIOLATIONS=0
set /a FAILURES=0

set "TMPBASE=%TEMP%\check_oracle_license_%RANDOM%_%RANDOM%"
set "DETAILS=%TMPBASE%.details"
type nul > "%DETAILS%" 2>nul

if not exist "%SQL_FILE%" (
  echo UNKNOWN - Oracle license check SQL file not found: %SQL_FILE%
  exit /b 3
)

set "HAS_CONFIG=0"
if exist "%INSTANCES_FILE%" (
  for /f "usebackq eol=# tokens=1,2,* delims=|" %%A in ("%INSTANCES_FILE%") do (
    if not "%%~A"=="" if not "%%~B"=="" set "HAS_CONFIG=1"
  )
)

if "!HAS_CONFIG!"=="1" (
  for /f "usebackq eol=# tokens=1,2,* delims=|" %%A in ("%INSTANCES_FILE%") do (
    call :CHECK_INSTANCE "%%~A" "%%~B"
  )
) else (
  for /f "tokens=2 delims=:" %%A in ('sc.exe query type^= service state^= all ^| findstr.exe /B /I /C:"SERVICE_NAME: OracleService"') do (
    set "SERVICE=%%A"
    for /f "tokens=* delims= " %%B in ("!SERVICE!") do set "SERVICE=%%B"
    if /I "!SERVICE:~0,13!"=="OracleService" (
      set "SID=!SERVICE:OracleService=!"
      call :DISCOVER_HOME "!SERVICE!" "!SID!"
    )
  )
)

if %INSTANCES% EQU 0 (
  del /q "%DETAILS%" >nul 2>&1
  echo UNKNOWN - no Oracle database instances discovered
  exit /b 3
)

if %STATE% EQU 0 set "STATUS=OK"
if %STATE% EQU 1 set "STATUS=WARNING"
if %STATE% EQU 2 set "STATUS=CRITICAL"
if %STATE% GEQ 3 set "STATUS=UNKNOWN"

echo %STATUS% - Oracle license inventory: discovered=%INSTANCES% queried=%QUERIED% violations=%VIOLATIONS% failures=%FAILURES% ^| instances=%INSTANCES% queried=%QUERIED% violations=%VIOLATIONS% failures=%FAILURES%
type "%DETAILS%"

del /q "%TMPBASE%.*" >nul 2>&1
exit /b %STATE%

:DISCOVER_HOME
set "SERVICE=%~1"
set "SID=%~2"
set "BINPATH="

for /f "tokens=2,* delims=:" %%A in ('sc.exe qc "%SERVICE%" ^| findstr.exe /I /C:"BINARY_PATH_NAME"') do set "BINPATH=%%B"
for /f "tokens=* delims= " %%A in ("!BINPATH!") do set "BINPATH=%%A"

set "X=!BINPATH!"
set "X=!X:\bin\ORACLE.EXE=|!"
set "X=!X:\BIN\ORACLE.EXE=|!"
set "X=!X:\bin\oracle.exe=|!"
set "X=!X:\Bin\Oracle.exe=|!"

set "OH="
for /f "tokens=1 delims=|" %%A in ("!X!") do set "OH=%%A"
set "OH=!OH:"=!"

if not defined OH (
  set /a INSTANCES+=1
  set /a FAILURES+=1
  call :SET_STATE UNKNOWN
  >>"%DETAILS%" echo UNKNOWN - !SID! - cannot derive ORACLE_HOME from service !SERVICE!
  goto :eof
)

if "!OH!"=="!BINPATH!" (
  set /a INSTANCES+=1
  set /a FAILURES+=1
  call :SET_STATE UNKNOWN
  >>"%DETAILS%" echo UNKNOWN - !SID! - unrecognized Oracle service path: !BINPATH!
  goto :eof
)

call :CHECK_INSTANCE "!SID!" "!OH!"
goto :eof

:CHECK_INSTANCE
set "SID=%~1"
set "OH=%~2"

if not defined SID goto :eof
if not defined OH goto :eof
if /I "%SID:~0,4%"=="+ASM" goto :eof
if /I "%SID:~0,4%"=="+APX" goto :eof

set /a INSTANCES+=1
set "SQLPLUS=%OH%\bin\sqlplus.exe"

if not exist "%SQLPLUS%" (
  set /a FAILURES+=1
  call :SET_STATE UNKNOWN
  >>"%DETAILS%" echo UNKNOWN - %SID% - sqlplus.exe not found: %SQLPLUS%
  goto :eof
)

set "ORACLE_SID=%SID%"
set "ORACLE_HOME=%OH%"
set "OLDPATH=%PATH%"
set "PATH=%ORACLE_HOME%\bin;%SystemRoot%\System32;%SystemRoot%"

set "OUT=%TMPBASE%_%SID%.out"
"%SQLPLUS%" -s "/ as sysdba" @"%SQL_FILE%" > "%OUT%" 2>&1
set "RC=%ERRORLEVEL%"

findstr.exe /L /C:"META|CHECK_COMPLETE|YES" "%OUT%" >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  set /a FAILURES+=1
  call :SET_STATE UNKNOWN
  set "ERR=SQL*Plus returned rc=%RC%"
  for /f "usebackq delims=" %%E in (`findstr.exe /B /I /C:"ORA-" /C:"SP2-" /C:"ERROR|" "%OUT%" 2^>nul`) do if "!ERR!"=="SQL*Plus returned rc=%RC%" set "ERR=%%E"
  >>"%DETAILS%" echo UNKNOWN - %SID% - !ERR!
  set "PATH=%OLDPATH%"
  goto :eof
)

set /a QUERIED+=1
set "EDITION=?"
set "VERSION=?"
set "DBNAME=?"
set "PACK=?"
set /a USED=0
set /a OPTS=0

for /f "usebackq tokens=1,2,* delims=|" %%A in ("%OUT%") do (
  if /I "%%A|%%B"=="META|EDITION" set "EDITION=%%C"
  if /I "%%A|%%B"=="META|VERSION" set "VERSION=%%C"
  if /I "%%A|%%B"=="META|DATABASE" set "DBNAME=%%C"
  if /I "%%A|%%B"=="PARAM|control_management_pack_access" set "PACK=%%C"
  if /I "%%A"=="FEATURE" set /a USED+=1
  if /I "%%A"=="OPTION" set /a OPTS+=1
)

>>"%DETAILS%" echo INFO - %SID% - db=!DBNAME! edition=!EDITION! version=!VERSION! packs=!PACK! installed_options=!OPTS! used_features=!USED!

call :CHECK_RULES "%SID%" "%OUT%"
set "PATH=%OLDPATH%"
goto :eof

:CHECK_RULES
set "SID=%~1"
set "OUT=%~2"
if not exist "%RULES_FILE%" goto :eof

for /f "usebackq eol=# tokens=1,2,* delims=|" %%A in ("%RULES_FILE%") do (
  set "SEV=%%A"
  set "SRC=%%B"
  set "PAT=%%C"

  if /I "!SEV!"=="WARNING" call :MATCH_RULE "!SEV!" "!SRC!" "!PAT!" "%SID%" "%OUT%"
  if /I "!SEV!"=="CRITICAL" call :MATCH_RULE "!SEV!" "!SRC!" "!PAT!" "%SID%" "%OUT%"
)
goto :eof

:MATCH_RULE
set "SEV=%~1"
set "SRC=%~2"
set "PAT=%~3"
set "SID=%~4"
set "OUT=%~5"
set "MATCH="

if /I "%SRC%"=="ANY" (
  for /f "usebackq delims=" %%L in (`findstr.exe /I /L /C:"%PAT%" "%OUT%" 2^>nul`) do if not defined MATCH set "MATCH=%%L"
) else (
  for /f "usebackq delims=" %%L in (`findstr.exe /B /I /L /C:"%SRC%|" "%OUT%" 2^>nul ^| findstr.exe /I /L /C:"%PAT%"`) do if not defined MATCH set "MATCH=%%L"
)

if defined MATCH (
  set /a VIOLATIONS+=1
  call :SET_STATE %SEV%
  >>"%DETAILS%" echo %SEV% - %SID% - rule [%SRC%:%PAT%] matched: !MATCH!
)
goto :eof

:SET_STATE
if /I "%~1"=="WARNING" if %STATE% LSS 1 set /a STATE=1
if /I "%~1"=="CRITICAL" if %STATE% LSS 2 set /a STATE=2
if /I "%~1"=="UNKNOWN" if %STATE% LSS 3 set /a STATE=3
goto :eof
