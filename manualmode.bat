@echo off
REM ============================================================================
REM  Hybrid Failover demo : manualmode.bat
REM  Flips the controller back to MANUAL (operator-triggered) live, no redeploy.
REM ============================================================================
setlocal
title Hybrid Failover - switch to MANUAL
color 0B
set "CTRL=http://localhost:8080"

echo.
echo   Switching controller to MANUAL (operator-triggered failover)...
curl.exe -s -m 5 -X POST "%CTRL%/control/mode/manual"
echo.
echo.
curl.exe -s -m 3 "%CTRL%/control/status"
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> Manual ON (hybridlb_manual_mode = 1). Use  failover.bat / failback.bat  to move traffic.
color 07
echo.
pause
exit /b 0
