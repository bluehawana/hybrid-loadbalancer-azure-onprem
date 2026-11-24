<#
.SYNOPSIS
    Failover benchmark for the hybrid load balancer on ARO test.

.DESCRIPTION
    Triggers a real outage of the primary (mock on-prem) backend in hybridlb-test, then measures
    how fast the service is dragged back up via Azure — client outage, controller failover
    time, and full recovery — and checks it against a target (default 120s / "within 1-2 min").
    Uses the traefik/whoami mock backends, so it costs nothing and touches no real server.

.PREREQUISITES
    - kubectl logged in to the ARO test cluster (oc login ...), context on hybridlb-test.
    - The controller metrics reachable, e.g.:
        kubectl -n hybridlb-test port-forward svc/hybrid-loadbalancer 8080:8080
    - The LB route reachable (the whoami echo shows which backend served each request).

.EXAMPLE
    ./Invoke-FailoverBenchmark.ps1 `
        -LbUrl https://webapp-lb.apps.example.com/ `
        -MetricsUrl http://localhost:8080/metrics
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $LbUrl,
    [Parameter(Mandatory)] [string] $MetricsUrl,
    [string] $Namespace = 'hybridlb-test',
    [string] $PrimaryDeployment = 'onprem-mock',
    [int]    $TargetSeconds = 120,
    [int]    $BaselineSeconds = 3,
    [int]    $ProbeIntervalMs = 200,
    [int]    $MaxSeconds = 180
)

$ErrorActionPreference = 'Stop'

function Test-Endpoint([string]$Url) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec 3 -SkipCertificateCheck -SkipHttpErrorCheck
        $sw.Stop()
        $backend = if ($r.Content -match 'Hostname:\s*(\S+)') { $Matches[1] } else { 'unknown' }
        return [pscustomobject]@{ Ok = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400); Backend = $backend; Ms = $sw.Elapsed.TotalMilliseconds }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Backend = 'none'; Ms = $sw.Elapsed.TotalMilliseconds }
    }
}

function Get-Metric([string]$Name, [string]$Service = 'webapp') {
    try {
        $text = Invoke-WebRequest -Uri $MetricsUrl -TimeoutSec 3 -SkipCertificateCheck | Select-Object -ExpandProperty Content
        $line = $text -split "`n" | Where-Object { $_ -match "^$Name\{" -and $_ -match "service=`"$Service`"" } | Select-Object -First 1
        if ($line -and $line -match '\s([0-9eE\.\+\-]+)\s*$') { return [double]$Matches[1] }
    } catch { }
    return $null
}

Write-Host "== Hybrid failover benchmark ==" -ForegroundColor Cyan
Write-Host "LB:      $LbUrl"
Write-Host "Metrics: $MetricsUrl"
Write-Host "Target:  fully recovered within $TargetSeconds s`n"

# Preflight
$pre = Test-Endpoint $LbUrl
if (-not $pre.Ok) { throw "Preflight failed: LB not serving 200 (backend=$($pre.Backend))." }
Write-Host "Preflight OK - served by '$($pre.Backend)' in $([int]$pre.Ms) ms`n" -ForegroundColor Green

$start        = Get-Date
$tFault       = $null
$tOutageStart = $null
$tClientBack  = $null   # first success after fault (served by Azure)
$tRepair      = $null
$tFailback    = $null   # served by on-prem again
$faultInjected = $false
$repairIssued  = $false

while (((Get-Date) - $start).TotalSeconds -lt $MaxSeconds) {
    $now = Get-Date
    $elapsed = ($now - $start).TotalSeconds

    # 1) Inject the outage after the baseline window.
    if (-not $faultInjected -and $elapsed -ge $BaselineSeconds) {
        Write-Host "[$([int]$elapsed)s] Injecting outage: scaling $PrimaryDeployment to 0 ..." -ForegroundColor Yellow
        & kubectl -n $Namespace scale deploy/$PrimaryDeployment --replicas=0 | Out-Null
        $tFault = Get-Date; $faultInjected = $true
    }

    $p = Test-Endpoint $LbUrl

    if ($faultInjected -and -not $p.Ok -and -not $tOutageStart) { $tOutageStart = $now }
    if ($faultInjected -and $p.Ok -and $p.Backend -match 'azure' -and -not $tClientBack) {
        $tClientBack = $now
        Write-Host "[$([int]$elapsed)s] Service back UP via '$($p.Backend)'" -ForegroundColor Green
    }

    # 2) Once Azure is stably serving, repair on-prem to test fall-back.
    if ($tClientBack -and -not $repairIssued -and ($now - $tClientBack).TotalSeconds -ge 5) {
        Write-Host "[$([int]$elapsed)s] Repairing on-prem: scaling $PrimaryDeployment to 1 ..." -ForegroundColor Yellow
        & kubectl -n $Namespace scale deploy/$PrimaryDeployment --replicas=1 | Out-Null
        $tRepair = Get-Date; $repairIssued = $true
    }

    if ($repairIssued -and $p.Ok -and $p.Backend -match 'onprem' -and -not $tFailback) {
        $tFailback = $now
        Write-Host "[$([int]$elapsed)s] Failed back to '$($p.Backend)'" -ForegroundColor Green
        break
    }

    Start-Sleep -Milliseconds $ProbeIntervalMs
}

# Controller-reported timings (as shown in Grafana / Prometheus).
$ctrlFailover = Get-Metric 'hybridlb_last_failover_seconds'
$ctrlRecovery = Get-Metric 'hybridlb_last_recovery_seconds'

function Span($a, $b) { if ($a -and $b) { [math]::Round((($b) - ($a)).TotalSeconds, 1) } else { 'n/a' } }

$clientOutage = Span $tOutageStart $tClientBack
$totalRecover = Span $tFault       $tClientBack
$failback     = Span $tRepair      $tFailback

Write-Host "`n================ BENCHMARK RESULT ================" -ForegroundColor Cyan
"{0,-40}{1}" -f 'Client-visible outage (LB):',        "$clientOutage s"
"{0,-40}{1}" -f 'On-prem down -> up on Azure (total):', "$totalRecover s"
"{0,-40}{1}" -f 'Controller failover (metric):',        $(if ($ctrlFailover) { "$([math]::Round($ctrlFailover,1)) s" } else { 'n/a' })
"{0,-40}{1}" -f 'Controller recovery (metric):',        $(if ($ctrlRecovery) { "$([math]::Round($ctrlRecovery,1)) s" } else { 'n/a' })
"{0,-40}{1}" -f 'Fall-back to on-prem:',                "$failback s"
Write-Host "==================================================" -ForegroundColor Cyan

if ($totalRecover -ne 'n/a' -and [double]$totalRecover -le $TargetSeconds) {
    Write-Host "PASS - recovered in $totalRecover s (target $TargetSeconds s)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "REVIEW - recovery $totalRecover s vs target $TargetSeconds s" -ForegroundColor Yellow
    exit 1
}
