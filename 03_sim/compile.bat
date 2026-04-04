@echo off
setlocal
set SCRIPT_DIR=%~dp0
pushd "%SCRIPT_DIR%"

call "%SCRIPT_DIR%set_vsim_path.bat"

set WORK_LIB_DIR=%SCRIPT_DIR%work
set SIMLIB_ROOT=%SCRIPT_DIR%..\04_simlib

if not exist "%WORK_LIB_DIR%" (
  echo [compile] Creating work library at "%WORK_LIB_DIR%"
  vlib "%WORK_LIB_DIR%"
)
vmap work "%WORK_LIB_DIR%"

for %%L in (gw1n gw2a) do (
  if exist "%SIMLIB_ROOT%\%%L" (
    vmap %%L "%SIMLIB_ROOT%\%%L"
  )
)

echo [compile] Compiling sources from vlog.f
vsim -c -l compile.log -do "if {[catch {vlog -sv -work work -f vlog.f} result]} {puts $result; quit -code 1} else {quit -code 0}"
set EXIT_CODE=%ERRORLEVEL%

popd
exit /b %EXIT_CODE%
