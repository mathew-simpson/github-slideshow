@echo off
REM Runs one Strategy Tester optimization via the MT5 terminal config file.
REM Usage: run_optimization.bat "C:\Program Files\MetaTrader 5\terminal64.exe" optimize_IS.ini
REM The terminal uses its local agents (one per CPU core) for genetic optimization.
REM Set agents in Terminal: Tools > Options > Strategy Tester > Local agents (set to core count).

if "%~1"=="" (
  echo Usage: %~nx0 "path\to\terminal64.exe" config.ini
  exit /b 1
)
if "%~2"=="" (
  echo Missing config file argument.
  exit /b 1
)

set TERM_EXE=%~1
set CFG=%~dpnx2

echo Launching tester with %CFG%
start "" /wait "%TERM_EXE%" /config:"%CFG%"
echo Optimization finished. Check the reports folder under the MT5 data directory.
