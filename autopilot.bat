@echo off
REM ============================================================================
REM  Hybrid Failover demo : autopilot.bat
REM  Flips the controller from MANUAL to AUTO (autonomous failover) live, with
REM  no redeploy. After this, servicedown.bat shows the balancer reacting by
REM  itself. Run  manualmode.bat  to switch back to operator-triggered.
REM ============================================================================
setlocal
title Hybrid Failover - switch to AUTOPILOT
color 0B
set "CTRL=http://localhost:8080"

echo.
echo   Switching controller to AUTOPILOT (autonomous failover)...
curl.exe -s -m 5 -X POST "%CTRL%/control/mode/auto"
echo.
echo.
curl.exe -s -m 3 "%CTRL%/control/status"
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> Autopilot ON. Now  servicedown.bat  will fail over automatically,
echo      with no human in the loop. (hybridlb_manual_mode = 0 in Grafana.)
color 07
echo.
pause
exit /b 0
