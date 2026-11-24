using Prometheus;

namespace HybridFailoverController.Metrics;

public sealed class FailoverMetrics
{
    private static readonly string[] ServiceLabel = { "service" };

    public readonly Gauge FailoverActive = Prometheus.Metrics.CreateGauge(
        "hybridlb_failover_active", "1 when traffic is served from the Azure backup, 0 when on the on-prem primary.", ServiceLabel);

    public readonly Gauge PrimaryHealthy = Prometheus.Metrics.CreateGauge(
        "hybridlb_primary_healthy", "1 when the on-prem primary health check passes, 0 otherwise.", ServiceLabel);

    public readonly Gauge BackupHealthy = Prometheus.Metrics.CreateGauge(
        "hybridlb_backup_healthy", "1 when the Azure backup health check passes, 0 otherwise (the escape hatch is verified continuously).", ServiceLabel);

    public readonly Gauge ServiceReachable = Prometheus.Metrics.CreateGauge(
        "hybridlb_service_reachable", "1 when the service answers through the load balancer's own endpoint (customer-facing reachability), 0 when the LB returns no healthy backend. Independent of which node serves.", ServiceLabel);

    public readonly Gauge PrimaryCpuPercent = Prometheus.Metrics.CreateGauge(
        "hybridlb_primary_cpu_percent", "On-prem primary CPU utilization percent.", ServiceLabel);

    public readonly Gauge PrimaryMemoryPercent = Prometheus.Metrics.CreateGauge(
        "hybridlb_primary_memory_percent", "On-prem primary memory utilization percent.", ServiceLabel);

    public readonly Gauge PrimaryLatencyMs = Prometheus.Metrics.CreateGauge(
        "hybridlb_primary_latency_ms", "On-prem primary probe latency in milliseconds.", ServiceLabel);

    public readonly Gauge State = Prometheus.Metrics.CreateGauge(
        "hybridlb_failover_state", "0=Healthy 1=Degraded 2=FailedOver 3=Recovering.", ServiceLabel);

    public readonly Gauge ManualMode = Prometheus.Metrics.CreateGauge(
        "hybridlb_manual_mode", "1 when failover is operator-triggered (manual), 0 when autonomous (autopilot).", ServiceLabel);

    public readonly Gauge ActionRecommended = Prometheus.Metrics.CreateGauge(
        "hybridlb_action_recommended", "Manual mode: what autopilot would do now. 0=none 1=failover 2=failback.", ServiceLabel);

    public readonly Counter FailoverEvents = Prometheus.Metrics.CreateCounter(
        "hybridlb_failover_events_total", "Count of failover/recovery transitions by reason.",
        new CounterConfiguration { LabelNames = new[] { "service", "reason" } });

    public readonly Counter AzureActiveSeconds = Prometheus.Metrics.CreateCounter(
        "hybridlb_azure_active_seconds_total", "Seconds served from the Azure backup, for cost comparison.", ServiceLabel);

    public readonly Gauge LastFailoverSeconds = Prometheus.Metrics.CreateGauge(
        "hybridlb_last_failover_seconds", "Seconds from first sign of primary trouble to traffic shifted to Azure.", ServiceLabel);

    public readonly Histogram FailoverDuration = Prometheus.Metrics.CreateHistogram(
        "hybridlb_failover_duration_seconds", "Distribution of failover times (trouble detected -> shifted).",
        new HistogramConfiguration
        {
            LabelNames = ServiceLabel,
            Buckets = Histogram.ExponentialBuckets(1, 2, 8) // 1s .. 128s
        });

    public readonly Gauge LastRecoverySeconds = Prometheus.Metrics.CreateGauge(
        "hybridlb_last_recovery_seconds", "Seconds from on-prem becoming healthy to traffic shifted back.", ServiceLabel);

    public readonly Counter SelfHealTriggers = Prometheus.Metrics.CreateCounter(
        "hybridlb_selfheal_triggers_total", "Count of self-heal restart-pipeline triggers by result.",
        new CounterConfiguration { LabelNames = new[] { "service", "result" } });
}
