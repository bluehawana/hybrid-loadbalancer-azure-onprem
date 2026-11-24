using Prometheus;
using HybridFailoverController;
using HybridFailoverController.Configuration;
using HybridFailoverController.Control;
using HybridFailoverController.Decision;
using HybridFailoverController.Haproxy;
using HybridFailoverController.Health;
using HybridFailoverController.Metrics;
using HybridFailoverController.SelfHeal;
using HybridFailoverController.Signals;

var builder = WebApplication.CreateBuilder(args);

var servicesConfigPath = builder.Configuration["ServicesConfigPath"] ?? "config/services.yaml";
var servicesConfig = ServicesConfigLoader.Load(servicesConfigPath);
builder.Services.AddSingleton(servicesConfig);
builder.Services.AddSingleton(new ControlState(
    string.Equals(servicesConfig.Mode, "manual", StringComparison.OrdinalIgnoreCase)));

builder.Services.AddHttpClient();

// On-prem and Azure endpoints use internal/self-signed certs; this client only performs
// health probes to trusted internal hosts, never carries user traffic.
builder.Services.AddHttpClient("insecure")
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
    {
        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
    });

builder.Services.AddSingleton<FailoverMetrics>();
builder.Services.AddSingleton<HaproxyRuntimeClient>();
builder.Services.AddSingleton<HealthProbe>();
builder.Services.AddSingleton<PrometheusSignalSource>();
builder.Services.AddSingleton<ReleasePipelineTrigger>();
builder.Services.AddSingleton<FailoverDecisionEngine>();
builder.Services.AddHostedService<Worker>();

var app = builder.Build();

app.MapGet("/health/live", () => Results.Text("live"));
app.MapGet("/health/ready", () => Results.Text("ready"));
app.MapMetrics(); // Prometheus scrape endpoint at /metrics

// ---- Operator control surface (manual failover + live mode switch) ----
// Optional shared secret: set HYBRIDLB_CONTROL_TOKEN to require an X-Control-Token header on
// state-changing calls. Left unset (e.g. in the mock test namespace) the endpoints are open.
var controlToken = Environment.GetEnvironmentVariable("HYBRIDLB_CONTROL_TOKEN");
bool Authorized(HttpRequest req) =>
    string.IsNullOrEmpty(controlToken) ||
    (req.Headers.TryGetValue("X-Control-Token", out var v) && v == controlToken);

app.MapGet("/control/status", (ServicesConfig cfg, ControlState ctl) => Results.Json(new
{
    mode = ctl.Manual ? "manual" : "auto",
    services = cfg.Services.Select(s => new
    {
        service = s.Name,
        recommended = (ctl.Recommendation.TryGetValue(s.Name, out var r) ? r : OperatorCommand.None)
            .ToString().ToLowerInvariant()
    })
}));

app.MapPost("/control/mode/{mode}", (string mode, HttpRequest req, ControlState ctl) =>
{
    if (!Authorized(req)) return Results.Unauthorized();
    if (mode.Equals("manual", StringComparison.OrdinalIgnoreCase)) { ctl.Manual = true; return Results.Text("mode=manual"); }
    if (mode.Equals("auto", StringComparison.OrdinalIgnoreCase) || mode.Equals("autopilot", StringComparison.OrdinalIgnoreCase))
    { ctl.Manual = false; return Results.Text("mode=auto"); }
    return Results.BadRequest("mode must be 'manual' or 'auto'");
});

app.MapPost("/control/failover", (HttpRequest req, string? service, ServicesConfig cfg, ControlState ctl) =>
    Authorized(req) ? QueueCommand(service, cfg, ctl, OperatorCommand.Failover) : Results.Unauthorized());

app.MapPost("/control/failback", (HttpRequest req, string? service, ServicesConfig cfg, ControlState ctl) =>
    Authorized(req) ? QueueCommand(service, cfg, ctl, OperatorCommand.Failback) : Results.Unauthorized());

app.Run();

static IResult QueueCommand(string? service, ServicesConfig cfg, ControlState ctl, OperatorCommand cmd)
{
    var targets = string.IsNullOrWhiteSpace(service)
        ? cfg.Services.Select(s => s.Name)
        : cfg.Services.Where(s => s.Name.Equals(service, StringComparison.OrdinalIgnoreCase)).Select(s => s.Name);
    var acted = targets.ToList();
    if (acted.Count == 0) return Results.NotFound($"no service named '{service}'");
    foreach (var name in acted) ctl.Queue(name, cmd);
    return Results.Text($"{cmd.ToString().ToLowerInvariant()} queued for: {string.Join(", ", acted)}");
}
