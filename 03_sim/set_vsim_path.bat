@echo off
setlocal enableextensions

rem --- ModelSim (Lattice OEM) のパスを一時的にPATHへ ---
set "MTI_DIR=C:\lscc\diamond\3.13\modeltech\win32loem"
set "PATH=%MTI_DIR%;%PATH%"