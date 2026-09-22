@echo off
setlocal EnableExtensions

REM === Forcepoint One Endpoint (DLP) - install / repair, with SEP control ===
REM Run as SYSTEM via a GPO Computer Startup script, or manually as admin.
REM Skips when the install is complete. Reinstalls over the top when it is not:
REM a matching InstallVersion does not mean the product works, so the key files
REM are checked as well. Running the package again repairs a broken install.
REM
REM Symantec Endpoint Protection is stopped before the install and started again
REM afterwards, whether the install succeeded or not. The installer is fetched
REM BEFORE SEP is stopped, so a bad source never leaves SEP down.
REM
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

REM ---- Symantec Endpoint Protection ----
REM Leave SEP_SMC empty to skip SEP handling entirely.
set "SEP_SMC=C:\Program Files\Symantec\Symantec Endpoint Protection\smc.exe"

REM Client password, only needed when SEP is configured to require one for
REM stopping the service. Leave empty when no password is set.
REM WARNING: a GPO startup script lives in SYSVOL, which every domain user can
REM read. Do NOT put a real password here for a GPO deployment - disable the
REM protection from SEPM instead, and keep this for manual admin runs only.
set "SEP_PWD="

REM Seconds to wait after smc -stop before starting the install.
set "SEP_WAIT=15"
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

REM ---- Fetch the installer first, so a bad source never leaves SEP down ----
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

REM ---- Stop SEP, install, start SEP again no matter what happened ----
call :StopSEP
call :RunInstall RC
call :StartSEP

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

:StopSEP
REM smc return codes: 0 ok, -1 no admin rights, -2 bad parameter,
REM                   -3 service not installed, -4 service not running.
set "SEPDOWN="
if not defined SEP_SMC (
    call :Log "SEP: handling disabled (SEP_SMC empty)."
    goto :eof
)
if not exist "%SEP_SMC%" (
    call :Log "SEP: smc.exe not found, skipping."
    goto :eof
)
call :Log "SEP: stopping."
call :Smc stop SEPRC
if "%SEPRC%"=="0" (
    set "SEPDOWN=1"
    call :Log "SEP: stopped. Waiting %SEP_WAIT%s."
    call :Sleep %SEP_WAIT%
    goto :eof
)
if "%SEPRC%"=="-4" (
    set "SEPDOWN=1"
    call :Log "SEP: already stopped."
    goto :eof
)
if "%SEPRC%"=="-1" call :Log "SEP: stop failed, no admin rights (rc=-1)."
if "%SEPRC%"=="-2" call :Log "SEP: stop failed, bad parameter or wrong password (rc=-2)."
if "%SEPRC%"=="-3" call :Log "SEP: client service not installed (rc=-3)."
if not "%SEPRC%"=="-1" if not "%SEPRC%"=="-2" if not "%SEPRC%"=="-3" call :Log "SEP: stop failed (rc=%SEPRC%)."
call :Log "SEP: continuing with SEP running - the install may fail."
goto :eof

:StartSEP
if not defined SEPDOWN goto :eof
call :Log "SEP: starting."
call :Smc start SEPRC
if "%SEPRC%"=="0" (
    call :Log "SEP: started."
    goto :eof
)
call :Log "WARNING: SEP failed to start (rc=%SEPRC%). Start it manually."
goto :eof

:Smc
REM %1 = stop|start, %2 = name of the variable to receive the return code
setlocal
if defined SEP_PWD (
    "%SEP_SMC%" -p "%SEP_PWD%" -%~1
) else (
    "%SEP_SMC%" -%~1
)
set "_rc=%ERRORLEVEL%"
endlocal & set "%~2=%_rc%"
goto :eof

:RunInstall
REM %1 = name of the variable to receive the installer return code
set "XARG="
if defined XPSWD set "XARG= XPSWDPXY=%XPSWD%"
set "MSILOG=%LOGDIR%\msi_%COMPUTERNAME%.log"
call :Log "Installing %PKG%"
"%WORKDIR%\%PKG%" /v"/qn /norestart /l*v \"%MSILOG%\"%XARG%"
set "%~1=%ERRORLEVEL%"
goto :eof

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

:Sleep
REM %1 = seconds. ping is used instead of timeout, which needs a console
REM handle and fails under a GPO startup script.
setlocal
set /a _s=%~1+1
ping -n %_s% 127.0.0.1 >nul 2>&1
endlocal
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
