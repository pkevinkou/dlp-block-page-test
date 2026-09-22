@echo off
setlocal EnableExtensions

REM === Forcepoint One Endpoint (DLP) - install / repair ===
REM Run as SYSTEM via a GPO Computer Startup script, or manually as admin.
REM Skips when the install is complete. Reinstalls over the top when it is not:
REM a matching InstallVersion does not mean the product works, so the key files
REM are checked as well. Running the package again repairs a broken install.
REM A reboot is required after install for DLP Endpoint to work fully.
REM NOTE: this file must be saved with CRLF line endings. With LF-only endings
REM       cmd.exe cannot find the GOTO labels ("batch label not found - End").

REM ---- Settings ----
set "SRC=\\FILESERVER\Forcepoint"
set "PKG_X64=FORCEPOINT-ONE-ENDPOINT-x64.exe"
set "PKG_X86=FORCEPOINT-ONE-ENDPOINT-x32.exe"
set "TARGET_VER=26.04.5771"
set "XPSWD="
set "WORKDIR=%ProgramData%\Forcepoint"

REM Files that must exist for the install to count as complete.
REM Space separated, relative to the install path, no spaces in the names.
REM DSEMain.dll is the file that failed to load on the broken endpoint.
set "REQFILES=wepsvc.exe DSEMain.dll EndpointClassifier.exe"
REM ------------------

set "LOGDIR=%WORKDIR%\log"
if not exist "%LOGDIR%" md "%LOGDIR%" 2>nul
set "LOGFILE=%LOGDIR%\Install-F1E_%COMPUTERNAME%.log"
call :Log "----- start -----"

REM ---- Client OS only (skip servers) ----
set "OSTYPE="
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v InstallationType 2^>nul ^| find "InstallationType"') do set "OSTYPE=%%b"
if /I not "%OSTYPE%"=="Client" (
    call :Log "Skip: not a client OS (InstallationType=%OSTYPE%)"
    goto :End
)

REM ---- Pick package by architecture ----
set "ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=%PROCESSOR_ARCHITEW6432%"
set "PKG="
if /I "%ARCH%"=="AMD64" set "PKG=%PKG_X64%"
REM if /I "%ARCH%"=="x86" set "PKG=%PKG_X86%"

if not defined PKG (
    call :Log "Skip: unsupported architecture (%ARCH%)"
    goto :End
)
call :Log "Architecture %ARCH% -> %PKG%"

REM ---- Decide: skip or install ----
call :GetRegVal InstallVersion INSTVER
call :GetRegVal InstallPath INSTPATH

if not defined INSTVER (
    call :Log "Not installed. Installing %TARGET_VER%."
    goto :DoInstall
)
if /I not "%INSTVER%"=="%TARGET_VER%" (
    call :Log "Installed %INSTVER%, target %TARGET_VER%. Installing."
    goto :DoInstall
)
if not defined INSTPATH (
    call :Log "Version %INSTVER% but no InstallPath in registry. Repairing."
    goto :DoInstall
)

call :CheckFiles "%INSTPATH%" MISSING
if not "%MISSING%"=="0" (
    call :Log "Version %INSTVER% but %MISSING% file(s) missing. Repairing."
    goto :DoInstall
)

call :Log "Install complete at %INSTVER%. Nothing to do."
goto :End

REM ---- Get installer ----
:DoInstall
if not exist "%WORKDIR%" md "%WORKDIR%" 2>nul
if not exist "%SRC%\%PKG%" (
    call :Log "ERROR: source not reachable -> %SRC%\%PKG%"
    goto :End
)
copy /y "%SRC%\%PKG%" "%WORKDIR%\%PKG%" >nul
if errorlevel 1 (
    call :Log "ERROR: copy failed -> %SRC%\%PKG%"
    goto :End
)

REM ---- Install ----
set "XARG="
if defined XPSWD set "XARG= XPSWDPXY=%XPSWD%"
set "MSILOG=%LOGDIR%\msi_%COMPUTERNAME%.log"
call :Log "Installing %PKG%"
"%WORKDIR%\%PKG%" /v"/qn /norestart /l*v \"%MSILOG%\"%XARG%"
set "RC=%ERRORLEVEL%"

if "%RC%"=="0"    ( call :Log "Done (rc=0). Reboot required."          & goto :Verify )
if "%RC%"=="3010" ( call :Log "Done (rc=3010). Reboot required."       & goto :Verify )
if "%RC%"=="1641" ( call :Log "Done (rc=1641). Installer will reboot." & goto :Verify )
call :Log "ERROR: install failed rc=%RC% (see %MSILOG%)"
goto :End

REM ---- Confirm the key files landed ----
:Verify
del /f /q "%WORKDIR%\%PKG%" 2>nul
call :GetRegVal InstallPath INSTPATH
if not defined INSTPATH (
    call :Log "WARNING: no InstallPath in registry after install."
    goto :End
)
call :CheckFiles "%INSTPATH%" MISSING
if not "%MISSING%"=="0" (
    call :Log "WARNING: %MISSING% file(s) still missing. Check AV interference."
    goto :End
)
call :Log "Verified: all required files present."
goto :End


REM ================= subroutines =================

:GetRegVal
REM %1 = registry value name, %2 = name of the variable to receive it
setlocal
set "_v="
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Websense\Agent" /v %~1 2^>nul ^| find "%~1"') do set "_v=%%b"
if not defined _v for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Websense\Agent" /v %~1 /reg:64 2^>nul ^| find "%~1"') do set "_v=%%b"
if not defined _v for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Websense\Agent" /v %~1 /reg:32 2^>nul ^| find "%~1"') do set "_v=%%b"
if not defined _v for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Forcepoint\Agent" /v %~1 2^>nul ^| find "%~1"') do set "_v=%%b"
endlocal & set "%~2=%_v%"
goto :eof

:CheckFiles
REM %1 = install path, %2 = name of the variable to receive the missing count
setlocal EnableDelayedExpansion
set "_p=%~1"
if not "!_p:~-1!"=="\" set "_p=!_p!\"
set /a _n=0
for %%f in (%REQFILES%) do (
    if not exist "!_p!%%f" (
        set /a _n+=1
        call :Log "  missing: %%f"
    )
)
endlocal & set "%~2=%_n%"
goto :eof

:Log
REM Delayed expansion keeps characters such as > and & in the message literal.
REM Without it, "->" in a message is parsed as output redirection and silently
REM overwrites a file named after the rest of the text.
set "_msg=%~1"
setlocal EnableDelayedExpansion
echo [%DATE% %TIME%] !_msg!
>>"%LOGFILE%" echo [%DATE% %TIME%] !_msg!
endlocal
goto :eof

:End
call :Log "----- end -----"
endlocal
exit /b 0
