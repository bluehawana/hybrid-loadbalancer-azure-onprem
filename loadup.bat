@echo off
REM ============================================================================
REM  Hybrid Failover demo : loadup.bat
REM  Move live traffic ONTO the Azure standby, on your command (manual failover).
REM  On-prem stays healthy - a planned, zero-outage switch. Traffic HOLDS on
REM  Azure until you run rollbacktoprem.bat.
REM ============================================================================
setlocal enabledelayedexpansion
title Hybrid Failover - loadup (move traffic to Azure)
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
echo   LOAD UP - move live traffic onto the Azure standby (you command it)
echo ============================================================================
echo   Namespace : %NS%
echo   Grafana   : %GRAFANA%
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

echo   Scaling %BACKUP% (Azure warm standby) up to 1 replica...
kubectl -n %NS% scale deployment/%BACKUP% --replicas=1 >nul
kubectl -n %NS% rollout status deployment/%BACKUP% --timeout=120s
REM NOTE: we intentionally do NOT touch on-prem here - nothing revives it behind your back.

echo.
echo   Starting metrics port-forward in a side window (leave it open for all 3 steps)...
start "HybridLB metrics port-forward" cmd /c "kubectl -n %NS% port-forward svc/%SVC% 8080:8080"
timeout /t 4 /nobreak >nul

echo.
echo   Commanding the controller to move live traffic to Azure...
curl.exe -s -m 5 -X POST "http://localhost:8080/control/failover?service=webapp"
echo.
echo   Watching traffic move to the Azure standby...
echo.
call :wait_backend azure "Azure standby"
echo.
echo   Controller metrics (state: 0=on-prem 2=on-Azure ; primary 1=UP 0=DOWN):
call :show_metrics
echo.
echo ----------------------------------------------------------------------------
color 0A
echo   ^>^> NOW in GRAFANA: Failover state = On Azure, On-prem primary = UP.
echo      Planned switch, zero outage. Traffic HOLDS on Azure (manual mode).
echo      Take questions - then run  rollbacktoprem.bat  to return to on-prem.
color 07
echo.
pause
exit /b 0

REM ---------------------------------------------------------------------------
:show_backend
set "BACKEND=unknown"
for /f "tokens=2 delims= " %%h in ('curl -k -s -m 3 %LB% 2^>nul ^| findstr /i "Hostname"') do set "BACKEND=%%h"
echo     served by: !BACKEND!
goto :eof

:show_metrics
curl -s -m 3 %METRICS% 2>nul | findstr /i "hybridlb_failover_state hybridlb_primary_healthy hybridlb_backup_healthy hybridlb_last_failover_seconds hybridlb_last_recovery_seconds" 2>nul
if errorlevel 1 echo     (metrics not reachable yet - the port-forward window may still be starting)
goto :eof

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
