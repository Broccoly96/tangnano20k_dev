@echo off
setlocal

set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..") do set ROOT_DIR=%%~fI

if exist "%ROOT_DIR%\.venv\Scripts\python.exe" (
  set PYTHON_BIN=%ROOT_DIR%\.venv\Scripts\python.exe
) else (
  set PYTHON_BIN=python
)

"%PYTHON_BIN%" "%ROOT_DIR%\11_app\uart_log_tool\uart_log_tool.py" %*
