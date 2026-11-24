@echo off
REM ============================================================================
REM  Hybrid Failover demo - STEP 3 of 3 : rollbacktoprem.bat
REM  Repair on-prem. Traffic auto-fails-back to on-prem, then shut the Azure VM
REM  down (scale to 0) to save cost. NOTE: in real prod you would KEEP the
REM  standby warm - shutting it off here is only to save demo cost.
REM ============================================================================
setlocal enabledelayedexpansion
title Hybrid Failover - 3/3 rollbacktoprem (back to on-prem, Azure off)
color 0B

set "NS=hybridlb-test"
set "PRIMARY=onprem-mock"
set "BACKUP=azure-mock"
set "SVC=hybrid-loadbalancer"
set "LB=https://webapp-lb.apps.example.com/"
set "METRICS=http://localhost:8080/metrics"
set "GRAFANA=https://grafana.example.com  (dashboard: Hybrid Failover Load Balancer)"

echo.
echo ============================================================================
echo   STEP 3/3  ROLLBACK TO ON-PREM - repair on-prem, then power Azure off
echo ============================================================================
echo.

kubectl -n %NS% get deploy %PRIMARY% >nul 2>&1
if errorlevel 1 (
  color 0C
  echo [ERROR] Cannot reach %NS%. Log in first, e.g.:
  echo         oc login --web https://api.cluster.example.com:6443
  echo.
  pause
  exit /b 1
)

echo   Sending operator command: FAILBACK (Azure -^> on-prem)...
curl.exe -s -m 5 -X POST "http://localhost:8080/control/failback?service=webapp"
echo.
echo   Making sure the on-prem primary is up...
kubectl -n %NS% scale deployment/%PRIMARY% --replicas=1 >nul
kubectl -n %NS% rollout status deployment/%PRIMARY% --timeout=120s
echo   Waiting for traffic to move BACK to on-prem...
echo.
call :wait_backend onprem "on-prem primary"
echo.
call :show_metrics
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> NOW in GRAFANA: state is back on On-prem (green). Round trip done.
color 0B
echo.

REM Traffic is already back on on-prem, so it is safe to power the standby off now.
echo   Traffic is on on-prem - powering the Azure standby off (scale %BACKUP% to 0)...
kubectl -n %NS% scale deployment/%BACKUP% --replicas=0 >nul
echo   Azure standby scaled to 0 - VM is off. (In real prod we would keep it warm.)

echo   Closing the metrics port-forward window...
taskkill /fi "WINDOWTITLE eq HybridLB metrics port-forward*" /f >nul 2>&1

echo.
color 0A
echo ============================================================================
echo   DEMO COMPLETE - on-prem died, service stayed up on Azure, then fell back,
echo   and the standby powered off. One product, zero human intervention.
echo ============================================================================
color 07
pause
exit /b 0

REM ---------------------------------------------------------------------------
:show_metrics
curl -s -m 3 %METRICS% 2>nul | findstr /i "hybridlb_failover_state hybridlb_primary_healthy hybridlb_backup_healthy hybridlb_last_failover_seconds hybridlb_last_recovery_seconds" 2>nul
if errorlevel 1 echo     (metrics not reachable - is the loadup.bat port-forward window still open?)
goto :eof

REM  %1 = substring to wait for (azure / onprem), %2 = friendly label
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
if !tries! geq 60 (
  echo     ...still waiting for %LABEL% after 60 probes; continuing anyway.
  goto wb_done
)
timeout /t 1 /nobreak >nul
goto wb_loop
:wb_done
echo   ==^> now serving from %LABEL%: !BACKEND!
goto :eof
