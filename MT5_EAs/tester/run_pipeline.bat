@echo off
REM Walk-forward pipeline wrapper. Needs Python 3.8+ on PATH (no extra packages).
REM Usage: run_pipeline.bat [stage] [--only EA1_MACrossover_ATR ...] [--dry-run] [--force]
REM Stages: windows, generate, run-is, select, run-oos, report, all (default: all)
REM Close the MT5 terminal first: the tester cannot start while it is already open.

setlocal
cd /d "%~dp0"
set STAGE=%1
if "%STAGE%"=="" set STAGE=all
if not "%~1"=="" shift
python wf_pipeline.py %STAGE% %1 %2 %3 %4 %5 %6 %7 %8 %9
endlocal
