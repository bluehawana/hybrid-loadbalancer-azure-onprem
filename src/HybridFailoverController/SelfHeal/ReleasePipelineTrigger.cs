using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using HybridFailoverController.Configuration;
using HybridFailoverController.Metrics;

namespace HybridFailoverController.SelfHeal;

/// <summary>
/// Triggers an Azure DevOps classic release (e.g. "restart services") to
/// repair a dead on-prem primary — the automatic replacement for the 2:30am manual run.
/// Failover keeps customers up; this repairs on-prem so we can fail back to the cheap DC.
/// </summary>
public sealed class ReleasePipelineTrigger(
    IHttpClientFactory httpClientFactory,
    ServicesConfig config,
    FailoverMetrics metrics,
    ILogger<ReleasePipelineTrigger> logger)
{
    private readonly AzureDevOpsOptions _options = config.AzureDevOps;
    private readonly Dictionary<string, DateTimeOffset> _lastTriggered = new();

    public async Task TriggerAsync(ServiceTarget svc, string reason, CancellationToken ct)
    {
        if (!_options.Enabled || !svc.SelfHeal)
            return;

        if (_lastTriggered.TryGetValue(svc.Name, out var last) &&
            (DateTimeOffset.UtcNow - last).TotalSeconds < _options.MinIntervalSeconds)
        {
            logger.LogInformation("{Service} self-heal skipped (debounced)", svc.Name);
            return;
        }

        var pat = Environment.GetEnvironmentVariable(_options.PatEnvVar);
        if (string.IsNullOrWhiteSpace(pat))
        {
            logger.LogWarning("{Service} self-heal enabled but {EnvVar} is not set", svc.Name, _options.PatEnvVar);
            metrics.SelfHealTriggers.WithLabels(svc.Name, "no_pat").Inc();
            return;
        }

        var definitionId = svc.SelfHealDefinitionId ?? _options.ReleaseDefinitionId;
        var url = $"{_options.OrgUrl.TrimEnd('/')}/{Uri.EscapeDataString(_options.Project)}/_apis/release/releases?api-version=7.1";

        var client = httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = JsonContent.Create(new
            {
                definitionId,
                description = $"Auto self-heal: {svc.Name} primary dead ({reason})",
                isDraft = false,
                reason = "none"
            })
        };
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Basic", Convert.ToBase64String(Encoding.ASCII.GetBytes(":" + pat)));

        try
        {
            using var response = await client.SendAsync(request, ct);
            if (response.IsSuccessStatusCode)
            {
                _lastTriggered[svc.Name] = DateTimeOffset.UtcNow;
                metrics.SelfHealTriggers.WithLabels(svc.Name, "triggered").Inc();
                logger.LogWarning("{Service} self-heal: triggered release definition {Def}", svc.Name, definitionId);
            }
            else
            {
                metrics.SelfHealTriggers.WithLabels(svc.Name, "http_error").Inc();
                logger.LogError("{Service} self-heal failed: HTTP {Status}", svc.Name, (int)response.StatusCode);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            metrics.SelfHealTriggers.WithLabels(svc.Name, "exception").Inc();
            logger.LogError(ex, "{Service} self-heal request failed", svc.Name);
        }
    }
}
