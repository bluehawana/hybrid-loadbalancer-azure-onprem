@echo off
REM ============================================================================
REM  Hybrid Failover Load Balancer - live demo runner
REM  Walks the room through a real outage in hybridlb-test, pausing so you can switch
REM  to Grafana/Splunk at each step. Nothing is faked: it really kills the
REM  on-prem mock and the controller drags the service back up on Azure.
REM ============================================================================
setlocal enabledelayedexpansion
title Hybrid Failover - Live Demo
color 0B

REM ---- settings (change here if names/URLs differ) ----
set "NS=hybridlb-test"
set "PRIMARY=onprem-mock"
set "BACKUP=azure-mock"
set "SVC=hybrid-loadbalancer"
set "LB=https://webapp-lb.apps.example.com/"
set "METRICS=http://localhost:8080/metrics"
set "GRAFANA=https://grafana.example.com  (dashboard: Hybrid Failover Load Balancer)"

echo.
echo ============================================================================
echo   HYBRID FAILOVER - LIVE DEMO
echo   On-prem dies  -^>  load balancer drags the service onto Azure in seconds
echo ============================================================================
echo   Namespace : %NS%
echo   LB URL    : %LB%
echo   Grafana   : %GRAFANA%
echo ============================================================================
echo.

REM ---- connectivity check ----
kubectl -n %NS% get deploy %PRIMARY% >nul 2>&1
if errorlevel 1 (
  color 0C
  echo [ERROR] Cannot reach %NS%. Log in first, e.g.:
  echo         oc login --web https://api.cluster.example.com:6443
  echo.
  pause
  exit /b 1
)

REM ============================================================================
echo [STAGE 0]  PREPARATION - warm up the Azure standby
echo ----------------------------------------------------------------------------
echo   Scaling %BACKUP% (Azure warm standby) up to 1 replica...
kubectl -n %NS% scale deployment/%BACKUP% --replicas=1 >nul
echo   Waiting for %BACKUP% to be ready...
kubectl -n %NS% rollout status deployment/%BACKUP% --timeout=120s
echo   Ensuring on-prem primary is up...
kubectl -n %NS% scale deployment/%PRIMARY% --replicas=1 >nul
kubectl -n %NS% rollout status deployment/%PRIMARY% --timeout=120s

echo.
echo   Starting metrics port-forward in a side window (best effort)...
start "HybridLB metrics port-forward" cmd /c "kubectl -n %NS% port-forward svc/%SVC% 8080:8080"
timeout /t 4 /nobreak >nul

echo.
echo   Current backend serving the LB:
call :show_backend
echo.
echo   Controller metrics (state: 0=on-prem 2=on-Azure ; primary 1=UP 0=DOWN):
call :show_metrics
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> NOW: open GRAFANA and show the BASELINE - all GREEN (on-prem UP, state On-prem).
color 0B
echo.
pause

REM ============================================================================
echo.
echo [STAGE 1]  KILL THE ON-PREM SERVER  (the 2:30 AM incident)
echo ----------------------------------------------------------------------------
echo   Scaling %PRIMARY% to 0 replicas - this is a real outage of the on-prem host...
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
echo   ^>^> NOW: switch to GRAFANA / SPLUNK and show them:
echo        - On-prem primary health  = DOWN (red)
echo        - Failover state          = On Azure
echo        - Recovery time stat      ~ 6 seconds
echo      The SERVICE IS STILL UP (served from Azure). No one was paged.
color 0B
echo.
pause

REM ============================================================================
echo.
echo [STAGE 2]  RECOVER THE ON-PREM SERVER
echo ----------------------------------------------------------------------------
echo   Scaling %PRIMARY% back to 1 - on-prem is repaired...
kubectl -n %NS% scale deployment/%PRIMARY% --replicas=1 >nul
kubectl -n %NS% rollout status deployment/%PRIMARY% --timeout=120s
echo   Waiting for the load balancer to drain traffic BACK to on-prem
echo   (it holds a short stability window first, on purpose)...
echo.
call :wait_backend onprem "on-prem primary"
echo.
call :show_metrics
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> NOW: in GRAFANA the state returns to On-prem (green). Full round trip done.
color 0B
echo.
pause

REM ============================================================================
echo.
echo [STAGE 3]  CLEANUP
echo ----------------------------------------------------------------------------
set "CLEANUP="
set /p "CLEANUP=Scale the Azure standby (%BACKUP%) back to 0 to save cost? [Y/N] "
if /i "%CLEANUP%"=="Y" (
  echo   Scaling %BACKUP% back to 0...
  kubectl -n %NS% scale deployment/%BACKUP% --replicas=0 >nul
) else (
  echo   Leaving %BACKUP% running.
)

echo   Closing the metrics port-forward window...
taskkill /fi "WINDOWTITLE eq HybridLB metrics port-forward*" /f >nul 2>&1

echo.
color 0A
echo ============================================================================
echo   DEMO COMPLETE - on-prem died, service stayed up on Azure, then fell back.
echo ============================================================================
color 07
pause
exit /b 0

REM ============================================================================
REM  Subroutines
REM ============================================================================

:show_backend
set "BACKEND=unknown"
for /f "tokens=2 delims= " %%h in ('curl -k -s -m 3 %LB% 2^>nul ^| findstr /i "Hostname"') do set "BACKEND=%%h"
echo     served by: !BACKEND!
goto :eof

:show_metrics
curl -s -m 3 %METRICS% 2>nul | findstr /i "hybridlb_failover_state hybridlb_primary_healthy hybridlb_backup_healthy hybridlb_last_failover_seconds hybridlb_last_recovery_seconds" 2>nul
if errorlevel 1 echo     (metrics not reachable - is the port-forward window open?)
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
