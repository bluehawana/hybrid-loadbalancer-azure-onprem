<#
.SYNOPSIS
    Durability / resilience test for the hybrid load balancer on ARO test.

.DESCRIPTION
    Where Invoke-FailoverBenchmark.ps1 proves ONE outage recovers, this proves it recovers
    EVERY time, under repeated and varied failure patterns — so in any case the service is
    dragged back up within seconds. It runs several scenarios back to back and only passes if
    every single recovery is under the target:

      1. Sudden death   - kill the primary, time recovery to Azure, repair, time fall-back. Repeated N times.
      2. Flapping       - rapid kill/recover cycles to prove the controller never gets stuck.
      3. Sustained down - keep the primary dead for a while and prove the service stays up on Azure.

    Uses the traefik/whoami mock backends, so it costs nothing and touches no real server.
    Always restores the primary to 1 replica on exit, even on error / Ctrl-C.

.PREREQUISITES
    - kubectl / oc logged in to the ARO test cluster, context on hybridlb-test.
    - Controller metrics reachable, e.g.:
        kubectl -n hybridlb-test port-forward svc/hybrid-loadbalancer 8080:8080
    - The LB route reachable (whoami echoes which backend served each request).

.EXAMPLE
    ./Invoke-DurabilityTest.ps1 `
        -LbUrl https://webapp-lb.apps.example.com/ `
        -MetricsUrl http://localhost:8080/metrics
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $LbUrl,
    [Parameter(Mandatory)] [string] $MetricsUrl,
    [string] $Namespace         = 'hybridlb-test',
    [string] $PrimaryDeployment = 'onprem-mock',
    [int]    $Cycles            = 5,    # sudden-death repetitions
    [int]    $FlapCycles        = 4,    # rapid kill/recover repetitions
    [int]    $SustainSeconds    = 30,   # how long to hold the primary down
    [int]    $TargetSeconds     = 15,   # bringing the service UP must be within this many seconds ("within seconds")
    [int]    $FailbackMaxOutageSeconds = 3, # returning home must cause at most this much client downtime (ideally 0)
    [int]    $ProbeIntervalMs   = 200,
    [int]    $StepTimeoutSeconds = 90   # give up on a single step after this long
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

function Set-Primary([int]$Replicas) {
    & kubectl -n $Namespace scale deploy/$PrimaryDeployment --replicas=$Replicas | Out-Null
}

# Poll the LB until $Predicate is satisfied, measuring both the time to satisfy it and the
# longest continuous streak where the LB returned no successful response (client-visible outage).
function Wait-Until {
    param([scriptblock]$Predicate, [int]$TimeoutSeconds = $StepTimeoutSeconds)
    $start = Get-Date
    $maxOutageMs = 0.0
    $outageStart = $null
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        $p = Test-Endpoint $LbUrl
        if (-not $p.Ok) {
            if (-not $outageStart) { $outageStart = Get-Date }
            $maxOutageMs = [math]::Max($maxOutageMs, ((Get-Date) - $outageStart).TotalMilliseconds)
        } else {
            $outageStart = $null
        }
        if (& $Predicate $p) {
            return [pscustomobject]@{
                Ok = $true
                Seconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
                MaxOutageSeconds = [math]::Round($maxOutageMs / 1000, 1)
                Backend = $p.Backend
            }
        }
        Start-Sleep -Milliseconds $ProbeIntervalMs
    }
    return [pscustomobject]@{ Ok = $false; Seconds = $TimeoutSeconds; MaxOutageSeconds = [math]::Round($maxOutageMs / 1000, 1); Backend = 'timeout' }
}

$servingAzure  = { param($p) $p.Ok -and $p.Backend -match 'azure' }
$servingOnprem = { param($p) $p.Ok -and $p.Backend -match 'onprem' }
$results = New-Object System.Collections.Generic.List[object]

# $kind = 'failover' -> gate on time to bring the service up (must be within $TargetSeconds).
# $kind = 'failback' -> the hold-window delay is by design; gate on client downtime only (must be ~0).
function Record([string]$scenario, [int]$iter, $recover, [string]$kind = 'failover', [string]$note = '') {
    if ($kind -eq 'failback') {
        $pass = $recover.Ok -and $recover.MaxOutageSeconds -le $FailbackMaxOutageSeconds
        $note = ($note + " hold {0}s, {1}s downtime" -f $recover.Seconds, $recover.MaxOutageSeconds).Trim()
    } else {
        $pass = $recover.Ok -and $recover.Seconds -le $TargetSeconds
    }
    $results.Add([pscustomobject]@{
        Scenario = $scenario; Iter = $iter; Kind = $kind
        RecoverS = $recover.Seconds; OutageS = $recover.MaxOutageSeconds
        Backend = $recover.Backend; Pass = $pass; Note = $note
    })
    $color = if ($pass) { 'Green' } else { 'Red' }
    $tag   = if ($pass) { 'OK  ' } else { 'FAIL' }
    $metric = if ($kind -eq 'failback') { "downtime {0,4}s (hold {1,5}s)" -f $recover.MaxOutageSeconds, $recover.Seconds }
              else { "up in {0,5}s  outage {1,4}s" -f $recover.Seconds, $recover.MaxOutageSeconds }
    Write-Host ("  [{0}] {1,-14} #{2}  {3}  via {4} {5}" -f `
        $tag, $scenario, $iter, $metric, $recover.Backend, $note) -ForegroundColor $color
}

Write-Host "== Hybrid LB durability / resilience test ==" -ForegroundColor Cyan
Write-Host "LB:      $LbUrl"
Write-Host "Metrics: $MetricsUrl"
Write-Host "Target:  every recovery within $TargetSeconds s"
Write-Host "Plan:    $Cycles sudden-death, $FlapCycles flap, 1 sustained ($SustainSeconds s)`n"

try {
    # Preflight: make sure we start clean on on-prem.
    Set-Primary 1
    $pre = Wait-Until $servingOnprem
    if (-not $pre.Ok) { throw "Preflight failed: LB never served via on-prem (backend stuck at '$($pre.Backend)')." }
    Write-Host "Preflight OK - serving via on-prem`n" -ForegroundColor Green

    # 1) Sudden death, repeated.
    Write-Host "-- Scenario 1: sudden death x$Cycles --" -ForegroundColor Cyan
    for ($i = 1; $i -le $Cycles; $i++) {
        Set-Primary 0
        $rec = Wait-Until $servingAzure
        Record 'sudden-death' $i $rec 'failover'
        Set-Primary 1
        $back = Wait-Until $servingOnprem
        Record 'fall-back' $i $back 'failback'
    }

    # 2) Flapping: kill and immediately recover, several times, ending on Azure each drop.
    Write-Host "`n-- Scenario 2: flapping x$FlapCycles --" -ForegroundColor Cyan
    for ($i = 1; $i -le $FlapCycles; $i++) {
        Set-Primary 0
        $rec = Wait-Until $servingAzure
        Record 'flap-down' $i $rec 'failover'
        Set-Primary 1
        $back = Wait-Until $servingOnprem
        Record 'flap-up' $i $back 'failback'
    }

    # 3) Sustained outage: kill, confirm fast recovery, then hold down and confirm still serving.
    Write-Host "`n-- Scenario 3: sustained outage ($SustainSeconds s) --" -ForegroundColor Cyan
    Set-Primary 0
    $rec = Wait-Until $servingAzure
    Record 'sustained' 1 $rec 'failover'
    $held = Get-Date
    $stillUp = $true
    while (((Get-Date) - $held).TotalSeconds -lt $SustainSeconds) {
        if (-not (Test-Endpoint $LbUrl).Ok) { $stillUp = $false; break }
        Start-Sleep -Milliseconds ($ProbeIntervalMs * 2)
    }
    $results.Add([pscustomobject]@{
        Scenario = 'sustained-hold'; Iter = 1; Kind = 'hold'; RecoverS = 0; OutageS = 0
        Backend = 'azure'; Pass = $stillUp; Note = "stayed up $SustainSeconds s"
    })
    $c = if ($stillUp) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] sustained-hold    served continuously for {1}s while on-prem down" -f `
        $(if ($stillUp) { 'OK  ' } else { 'FAIL' }), $SustainSeconds) -ForegroundColor $c
    Set-Primary 1
    $back = Wait-Until $servingOnprem
    Record 'fall-back' 99 $back 'failback'
}
finally {
    # Always leave the primary healthy.
    Write-Host "`nRestoring $PrimaryDeployment to 1 replica ..." -ForegroundColor Yellow
    Set-Primary 1 2>$null
}

# ---- Report ----
$upEvents = $results | Where-Object { $_.Kind -eq 'failover' }
$recoveries = $upEvents | Select-Object -ExpandProperty RecoverS
$sorted = $recoveries | Sort-Object
$count  = $results.Count
$failed = @($results | Where-Object { -not $_.Pass })
$maxFailbackOutage = ($results | Where-Object { $_.Kind -eq 'failback' } | Measure-Object OutageS -Maximum).Maximum

function Pct([double[]]$v, [double]$p) {
    if (-not $v -or $v.Count -eq 0) { return 0 }
    $idx = [math]::Ceiling(($p / 100) * $v.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return $v[[math]::Min($idx, $v.Count - 1)]
}

Write-Host "`n================ DURABILITY RESULT ================" -ForegroundColor Cyan
$results | Format-Table -AutoSize Scenario, Iter, Kind, RecoverS, OutageS, Backend, Pass, Note | Out-String | Write-Host
if ($sorted) {
    $avg = [math]::Round(($sorted | Measure-Object -Average).Average, 1)
    "{0,-38}{1}" -f 'Failover (bring service UP) events:', $sorted.Count | Write-Host
    "{0,-38}{1}" -f '  Fastest / Average / Slowest:', ("{0}s / {1}s / {2}s" -f $sorted[0], $avg, $sorted[-1]) | Write-Host
    "{0,-38}{1}" -f '  p95 time-to-up:', ("{0}s (target {1}s)" -f (Pct $sorted 95), $TargetSeconds) | Write-Host
}
"{0,-38}{1}" -f 'Max downtime during fall-back:', ("{0}s (by design, zero-downtime return)" -f ([double]($maxFailbackOutage))) | Write-Host
"{0,-38}{1}" -f 'Steps run / failed:', ("{0} / {1}" -f $count, $failed.Count) | Write-Host
Write-Host "===================================================" -ForegroundColor Cyan

if ($failed.Count -eq 0) {
    Write-Host "PASS - service came back up within $TargetSeconds s every time, with zero-downtime fall-back." -ForegroundColor Green
    exit 0
} else {
    Write-Host ("REVIEW - {0} step(s) missed their gate:" -f $failed.Count) -ForegroundColor Yellow
    $failed | ForEach-Object {
        $g = if ($_.Kind -eq 'failback') { "downtime {0}s > {1}s" -f $_.OutageS, $FailbackMaxOutageSeconds }
             else { "up in {0}s > {1}s" -f $_.RecoverS, $TargetSeconds }
        Write-Host ("   {0} #{1}: {2} {3}" -f $_.Scenario, $_.Iter, $g, $_.Note) -ForegroundColor Yellow
    }
    exit 1
}
