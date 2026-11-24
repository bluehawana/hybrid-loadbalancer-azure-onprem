@echo off
REM ============================================================================
REM  Hybrid Failover demo - MANUAL trigger : failover.bat
REM  Operator-commanded planned failover. On-prem stays healthy; the controller
REM  drains it on your command and traffic moves to Azure with ZERO outage.
REM  Requires the controller in manual mode (test overlay default).
REM ============================================================================
setlocal enabledelayedexpansion
title Hybrid Failover - MANUAL failover to Azure
color 0B

set "CTRL=http://localhost:8080"
set "LB=https://webapp-lb.apps.example.com/"

echo.
echo   Sending operator command: FAILOVER (on-prem -^> Azure)...
curl.exe -s -m 5 -X POST "%CTRL%/control/failover?service=webapp"
echo.
echo   Waiting for the controller to drain on-prem and move traffic to Azure...
echo.
call :wait_backend azure "Azure standby"
echo.
curl.exe -s -m 3 "%CTRL%/control/status"
echo.
echo ----------------------------------------------------------------------------
color 0E
echo   ^>^> NOW in GRAFANA: Failover state = On Azure, but On-prem primary = UP.
echo      No outage - this was a planned, operator-approved move.
echo      Run  failback.bat  to bring it home.
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
