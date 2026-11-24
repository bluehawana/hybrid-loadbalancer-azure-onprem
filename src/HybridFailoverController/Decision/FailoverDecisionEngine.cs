using HybridFailoverController.Configuration;
using HybridFailoverController.Control;
using HybridFailoverController.Haproxy;
using HybridFailoverController.Health;
using HybridFailoverController.Metrics;
using HybridFailoverController.SelfHeal;
using HybridFailoverController.Signals;

namespace HybridFailoverController.Decision;

/// <summary>
/// Per-service failover state machine. HAProxy handles reactive dead-server detection on its
/// own; this engine adds the predictive layer — it shifts to Azure when the on-prem host is
/// trending toward failure or overloaded, and shifts back once on-prem is stably healthy again.
/// </summary>
public sealed class FailoverDecisionEngine(
    HealthProbe healthProbe,
    PrometheusSignalSource signals,
    HaproxyRuntimeClient haproxy,
    ReleasePipelineTrigger pipeline,
    FailoverMetrics metrics,
    ControlState control,
    ILogger<FailoverDecisionEngine> logger)
{
    private sealed class Runtime
    {
        public FailoverState State = FailoverState.Healthy;
        public int ConsecutiveFailures;
        public DateTimeOffset? DegradedSince;
        public DateTimeOffset? HealthySince;
        public DateTimeOffset? TroubleSince;    // first sign of primary trouble, for failover timing
        public DateTimeOffset? RecoverySince;   // primary healthy again, for recovery timing
    }

    private readonly Dictionary<string, Runtime> _state = new();

    public async Task EvaluateAsync(ServiceTarget svc, double elapsedSeconds, CancellationToken ct)
    {
        var rt = _state.TryGetValue(svc.Name, out var existing)
            ? existing
            : _state[svc.Name] = new Runtime();

        var probe = await healthProbe.CheckAsync(svc.Primary.HealthUrl, ct);
        var cpu = await signals.QueryScalarAsync(svc.Signals.CpuPercent, ct);
        var mem = await signals.QueryScalarAsync(svc.Signals.MemoryPercent, ct);
        var latency = await signals.QueryScalarAsync(svc.Signals.LatencyP95Ms, ct) ?? probe.LatencyMs;

        // Continuously verify the Azure standby so we never fail over to a dead escape hatch.
        // If no backup health URL is configured we can't verify it, so assume ready (1).
        var backupHealthy = true;
        if (!string.IsNullOrWhiteSpace(svc.Backup.HealthUrl))
            backupHealthy = (await healthProbe.CheckAsync(svc.Backup.HealthUrl, ct)).Healthy;
        metrics.BackupHealthy.WithLabels(svc.Name).Set(backupHealthy ? 1 : 0);

        // True customer-facing reachability: probe the load balancer's own front door.
        // 200 through HAProxy => a backend (on-prem OR Azure) is serving; 503/timeout => service down.
        if (!string.IsNullOrWhiteSpace(svc.Service.HealthUrl))
        {
            var reachable = (await healthProbe.CheckAsync(svc.Service.HealthUrl, ct)).Healthy;
            metrics.ServiceReachable.WithLabels(svc.Name).Set(reachable ? 1 : 0);
        }

        metrics.PrimaryHealthy.WithLabels(svc.Name).Set(probe.Healthy ? 1 : 0);
        if (cpu is not null) metrics.PrimaryCpuPercent.WithLabels(svc.Name).Set(cpu.Value);
        if (mem is not null) metrics.PrimaryMemoryPercent.WithLabels(svc.Name).Set(mem.Value);
        metrics.PrimaryLatencyMs.WithLabels(svc.Name).Set(latency);

        rt.ConsecutiveFailures = probe.Healthy ? 0 : rt.ConsecutiveFailures + 1;

        var t = svc.Thresholds;
        var dead = rt.ConsecutiveFailures >= t.FailAfterConsecutiveFailures;
        var overloaded =
            (cpu is not null && cpu >= t.CpuDegradedPercent) ||
            (mem is not null && mem >= t.MemoryDegradedPercent) ||
            latency >= t.LatencyP95DegradedMs;

        var now = DateTimeOffset.UtcNow;
        metrics.ManualMode.WithLabels(svc.Name).Set(control.Manual ? 1 : 0);

        // Manual mode: the controller only monitors and recommends; a human moves traffic via
        // the /control endpoints. HAProxy still keeps its own last-resort reactive failover for a
        // fully dead primary — that safety net is intentional and stays on in both modes.
        if (control.Manual)
        {
            await HandleManualAsync(svc, rt, probe, dead, overloaded, backupHealthy, now, elapsedSeconds, ct);
            return;
        }

        // Stamp the first moment the primary shows trouble, so we can measure how long
        // the failover actually took (detection + shift) for the benchmark.
        if (rt.State is FailoverState.Healthy && (dead || overloaded) && rt.TroubleSince is null)
            rt.TroubleSince = now;

        switch (rt.State)
        {
            case FailoverState.Healthy:
                if (dead)
                    await FailOverAsync(svc, rt, "primary_dead", backupHealthy, ct);
                else if (overloaded)
                {
                    rt.State = FailoverState.Degraded;
                    rt.DegradedSince = now;
                    logger.LogWarning("{Service} degraded (cpu={Cpu}% mem={Mem}% p95={Latency}ms)",
                        svc.Name, cpu, mem, latency);
                }
                break;

            case FailoverState.Degraded:
                if (dead)
                    await FailOverAsync(svc, rt, "primary_dead", backupHealthy, ct);
                else if (!overloaded)
                {
                    rt.State = FailoverState.Healthy;
                    rt.DegradedSince = null;
                    rt.TroubleSince = null;
                }
                else if (rt.DegradedSince is { } since && (now - since).TotalSeconds >= t.DegradedSustainSeconds)
                {
                    // Only abandon a still-responding primary if the standby is actually ready to take over.
                    if (backupHealthy)
                        await FailOverAsync(svc, rt, "primary_overloaded", backupHealthy, ct);
                    else
                        logger.LogError("{Service} overloaded past the sustain window, but the Azure backup is NOT healthy - staying on the primary rather than draining to a dead standby.", svc.Name);
                }
                break;

            case FailoverState.FailedOver:
                if (probe.Healthy && !overloaded)
                {
                    rt.State = FailoverState.Recovering;
                    rt.HealthySince = now;
                    rt.RecoverySince = now;
                }
                else
                {
                    rt.HealthySince = null;
                    rt.RecoverySince = null;
                }
                break;

            case FailoverState.Recovering:
                if (!probe.Healthy || overloaded)
                {
                    rt.State = FailoverState.FailedOver;
                    rt.HealthySince = null;
                }
                else if (rt.HealthySince is { } since && (now - since).TotalSeconds >= t.RecoveryStableSeconds)
                    await RecoverAsync(svc, rt, ct);
                break;
        }

        var onAzure = rt.State is FailoverState.FailedOver or FailoverState.Recovering;
        metrics.FailoverActive.WithLabels(svc.Name).Set(onAzure ? 1 : 0);
        if (onAzure)
            metrics.AzureActiveSeconds.WithLabels(svc.Name).Inc(elapsedSeconds);

        metrics.State.WithLabels(svc.Name).Set((int)rt.State);
    }

    private async Task HandleManualAsync(
        ServiceTarget svc, Runtime rt, ProbeResult probe,
        bool dead, bool overloaded, bool backupHealthy,
        DateTimeOffset now, double elapsedSeconds, CancellationToken ct)
    {
        var onAzure = rt.State is FailoverState.FailedOver or FailoverState.Recovering;

        // Surface what autopilot would do right now, without acting on it.
        var recommendation =
            !onAzure && (dead || overloaded) ? OperatorCommand.Failover :
            onAzure && probe.Healthy && !overloaded ? OperatorCommand.Failback :
            OperatorCommand.None;
        control.Recommendation[svc.Name] = recommendation;
        metrics.ActionRecommended.WithLabels(svc.Name).Set((int)recommendation);

        switch (control.Dequeue(svc.Name))
        {
            case OperatorCommand.Failover when !onAzure:
                rt.TroubleSince ??= now;
                await FailOverAsync(svc, rt, "manual_operator", backupHealthy, ct);
                break;
            case OperatorCommand.Failback when onAzure && probe.Healthy:
                rt.RecoverySince ??= now;
                await RecoverAsync(svc, rt, ct);
                break;
            case OperatorCommand.Failback:
                logger.LogWarning("{Service} manual failback ignored: on-prem primary is not healthy yet.", svc.Name);
                break;
        }

        var stillOnAzure = rt.State is FailoverState.FailedOver or FailoverState.Recovering;
        metrics.FailoverActive.WithLabels(svc.Name).Set(stillOnAzure ? 1 : 0);
        if (stillOnAzure)
            metrics.AzureActiveSeconds.WithLabels(svc.Name).Inc(elapsedSeconds);
        metrics.State.WithLabels(svc.Name).Set((int)rt.State);
    }

    private async Task FailOverAsync(ServiceTarget svc, Runtime rt, string reason, bool backupHealthy, CancellationToken ct)
    {
        await haproxy.DrainAsync(svc.HaproxyBackend, svc.PrimaryServer, ct);
        rt.State = FailoverState.FailedOver;
        rt.DegradedSince = null;
        metrics.FailoverEvents.WithLabels(svc.Name, reason).Inc();

        // A dead primary must still fail over, but if the standby is also down there is no healthy
        // target left - surface it loudly so the alert pipeline pages instead of failing silently.
        if (!backupHealthy)
        {
            metrics.FailoverEvents.WithLabels(svc.Name, "no_healthy_backup").Inc();
            logger.LogCritical("{Service} failed over but the Azure backup is NOT healthy - service may be unavailable until a target recovers.", svc.Name);
        }

        if (rt.TroubleSince is { } troubleSince)
        {
            var seconds = (DateTimeOffset.UtcNow - troubleSince).TotalSeconds;
            metrics.LastFailoverSeconds.WithLabels(svc.Name).Set(seconds);
            metrics.FailoverDuration.WithLabels(svc.Name).Observe(seconds);
            logger.LogError("{Service} FAILED OVER to Azure backup in {Seconds:F1}s ({Reason})", svc.Name, seconds, reason);
        }
        else
            logger.LogError("{Service} FAILED OVER to Azure backup ({Reason})", svc.Name, reason);

        rt.TroubleSince = null;

        // Repair the on-prem DC in the background so we can fall back to the cheap option.
        if (reason == "primary_dead")
            await pipeline.TriggerAsync(svc, reason, ct);
    }

    private async Task RecoverAsync(ServiceTarget svc, Runtime rt, CancellationToken ct)
    {
        await haproxy.ReadyAsync(svc.HaproxyBackend, svc.PrimaryServer, ct);
        rt.State = FailoverState.Healthy;
        rt.HealthySince = null;
        metrics.FailoverEvents.WithLabels(svc.Name, "recovered_to_onprem").Inc();

        if (rt.RecoverySince is { } recoverySince)
            metrics.LastRecoverySeconds.WithLabels(svc.Name)
                .Set((DateTimeOffset.UtcNow - recoverySince).TotalSeconds);
        rt.RecoverySince = null;

        logger.LogInformation("{Service} RECOVERED to on-prem primary", svc.Name);
    }
}
