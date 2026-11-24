using System.Diagnostics;

namespace HybridFailoverController.Health;

public sealed record ProbeResult(bool Healthy, double LatencyMs);

public sealed class HealthProbe(IHttpClientFactory httpClientFactory, ILogger<HealthProbe> logger)
{
    public async Task<ProbeResult> CheckAsync(string url, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(url))
            return new ProbeResult(false, 0);

        var client = httpClientFactory.CreateClient("insecure");
        client.Timeout = TimeSpan.FromSeconds(5);

        var sw = Stopwatch.StartNew();
        try
        {
            using var response = await client.GetAsync(url, ct);
            sw.Stop();
            return new ProbeResult(response.IsSuccessStatusCode, sw.Elapsed.TotalMilliseconds);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            sw.Stop();
            logger.LogWarning("Health probe failed for {Url}: {Message}", url, ex.Message);
            return new ProbeResult(false, sw.Elapsed.TotalMilliseconds);
        }
    }
}
