@echo off
REM ============================================================================
REM  Hybrid Failover demo - MANUAL trigger : failback.bat
REM  Operator-commanded return to on-prem. Controller readies the primary and
REM  moves traffic back off Azure on your command.
REM ============================================================================
setlocal enabledelayedexpansion
title Hybrid Failover - MANUAL failback to on-prem
color 0B

set "CTRL=http://localhost:8080"
set "LB=https://webapp-lb.apps.example.com/"

echo.
echo   Sending operator command: FAILBACK (Azure -^> on-prem)...
curl.exe -s -m 5 -X POST "%CTRL%/control/failback?service=webapp"
echo.
echo   Waiting for the controller to move traffic back to on-prem...
echo.
call :wait_backend onprem "on-prem primary"
echo.
curl.exe -s -m 3 "%CTRL%/control/status"
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> NOW in GRAFANA: Failover state = On-prem (green). Round trip done, no outage.
color 07
echo.
pause
exit /b 0

:wait_backend
set "MATCH=%~1"
set "LABEL=%~2"
set /a tries=0
:wb_loop
set "BACKEND=none"
for /f "tokens=2 delims= " %%h in ('curl -k -s -m 3 %LB% 2^>nul ^| findstr /i "Hostname"') do set "BACKEND=%%h"
echo     [probe !tries!] served by: !BACKEND!
echo !BACKEND! | findstr /i "%MATCH%" >nul && goto wb_done
set /a tries+=1
if !tries! geq 30 ( echo     ...still waiting for %LABEL%; continuing. & goto wb_done )
timeout /t 1 /nobreak >nul
goto wb_loop
:wb_done
echo   ==^> now serving from %LABEL%: !BACKEND!
goto :eof
