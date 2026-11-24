namespace HybridFailoverController.Configuration;

public sealed class ServicesConfig
{
    // "auto" = autonomous failover (autopilot); "manual" = operator-triggered via /control endpoints.
    public string Mode { get; set; } = "auto";
    public int PollIntervalSeconds { get; set; } = 10;
    public PrometheusOptions Prometheus { get; set; } = new();
    public HaproxyOptions Haproxy { get; set; } = new();
    public AzureDevOpsOptions AzureDevOps { get; set; } = new();
    public List<ServiceTarget> Services { get; set; } = new();
}

public sealed class PrometheusOptions
{
    public string BaseUrl { get; set; } = "http://prometheus.monitoring.svc:9090";
}

public sealed class HaproxyOptions
{
    public string RuntimeHost { get; set; } = "127.0.0.1";
    public int RuntimePort { get; set; } = 9999;
}

// Self-heal: trigger the on-prem "restart services" release when a primary
// is dead, replacing the 2:30am manual pipeline run.
public sealed class AzureDevOpsOptions
{
    public bool Enabled { get; set; } = false;
    public string OrgUrl { get; set; } = "https://dev.azure.com/your-org";
    public string Project { get; set; } = "your-project";
    public int ReleaseDefinitionId { get; set; } = 1; // "restart services"
    public string PatEnvVar { get; set; } = "AZDO_PAT";
    public int MinIntervalSeconds { get; set; } = 600; // debounce repeated restarts
}

public sealed class ServiceTarget
{
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";

    // HAProxy backend + server names this controller drives via the runtime API.
    public string HaproxyBackend { get; set; } = "";
    public string PrimaryServer { get; set; } = "onprem";
    public string BackupServer { get; set; } = "azurevm";

    public EndpointProbe Primary { get; set; } = new();
    public EndpointProbe Backup { get; set; } = new();
    // The load balancer's own front door - probing this measures true customer reachability
    // (200 through HAProxy = some backend is serving; 503 = service down), regardless of node.
    public EndpointProbe Service { get; set; } = new();
    public Thresholds Thresholds { get; set; } = new();
    public SignalQueries Signals { get; set; } = new();

    // Auto-trigger the restart pipeline for this service when its primary is dead.
    public bool SelfHeal { get; set; } = false;
    public int? SelfHealDefinitionId { get; set; }
}

public sealed class EndpointProbe
{
    public string HealthUrl { get; set; } = "";
}

public sealed class Thresholds
{
    public int FailAfterConsecutiveFailures { get; set; } = 3;
    public double CpuDegradedPercent { get; set; } = 85;
    public double MemoryDegradedPercent { get; set; } = 85;
    public double LatencyP95DegradedMs { get; set; } = 2000;
    public int DegradedSustainSeconds { get; set; } = 60;
    public int RecoveryStableSeconds { get; set; } = 300;
}

public sealed class SignalQueries
{
    public string? CpuPercent { get; set; }
    public string? MemoryPercent { get; set; }
    public string? LatencyP95Ms { get; set; }
}
