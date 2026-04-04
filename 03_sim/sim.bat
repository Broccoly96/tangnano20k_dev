@echo off
rem --------------------------------------------------------------------------
rem Legacy wrapper for ModelSim simulation (deprecated).
rem
rem This script now forwards all arguments to sim.py, which implements the
rem actual flow (argument parsing, recompile, openwave, log level, plusargs).
rem Keeping this wrapper avoids touching existing workflows that still call
rem "sim.bat ..." directly.
rem --------------------------------------------------------------------------

setlocal
set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%" >nul

rem If Python Launcher (py) is available, prefer it; otherwise fall back to python.
where py >nul 2>&1
if %ERRORLEVEL%==0 (
  py sim.py %*
) else (
  python sim.py %*
)

set "EXIT_CODE=%ERRORLEVEL%"
popd >nul
exit /b %EXIT_CODE%
