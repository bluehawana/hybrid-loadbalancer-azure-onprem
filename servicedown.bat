@echo off
REM ============================================================================
REM  Hybrid Failover demo - STEP 2 of 3 : servicedown.bat
REM  Kill the on-prem server. The load balancer fails over to Azure BY ITSELF.
REM  There is no manual "move to Azure" step - that IS the point of the product.
REM ============================================================================
setlocal enabledelayedexpansion
title Hybrid Failover - 2/3 servicedown (on-prem dies)
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
echo   STEP 2/3  SERVICE DOWN - kill on-prem, watch AUTOMATIC failover to Azure
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

echo   Safety check: making sure the Azure standby is up before we pull the plug...
kubectl -n %NS% scale deployment/%BACKUP% --replicas=1 >nul
kubectl -n %NS% rollout status deployment/%BACKUP% --timeout=120s

echo.
echo   Scaling %PRIMARY% to 0 replicas - this is a REAL outage of the on-prem host...
kubectl -n %NS% scale deployment/%PRIMARY% --replicas=0 >nul
echo   On-prem is going DOWN. Watching the load balancer shift traffic to Azure:
echo.
call :wait_backend azure "Azure standby"
echo.
echo   (giving the controller a few seconds to record the failover state...)
timeout /t 6 /nobreak >nul
echo   Controller-reported failover timing:
call :show_metrics
echo.
echo ----------------------------------------------------------------------------
color 0E
echo   ^>^> NOW: switch to GRAFANA / SPLUNK and show:
echo        - On-prem primary health = DOWN (red)
echo        - Failover state         = On Azure
echo        - Recovery time stat     ~ 6 seconds
echo      The SERVICE IS STILL UP (served from Azure). No human touched it.
echo      Then run  rollbacktoprem.bat  for step 3.
color 07
echo.
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
