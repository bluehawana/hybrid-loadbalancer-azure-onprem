using System.Globalization;
using System.Text.Json;
using HybridFailoverController.Configuration;

namespace HybridFailoverController.Signals;

/// <summary>Reads on-prem host trends (CPU/mem/latency) from in-cluster Prometheus.</summary>
public sealed class PrometheusSignalSource(
    IHttpClientFactory httpClientFactory,
    ServicesConfig config,
    ILogger<PrometheusSignalSource> logger)
{
    private readonly string _baseUrl = config.Prometheus.BaseUrl.TrimEnd('/');

    public async Task<double?> QueryScalarAsync(string? promql, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(promql))
            return null;

        var client = httpClientFactory.CreateClient();
        var url = $"{_baseUrl}/api/v1/query?query={Uri.EscapeDataString(promql)}";

        try
        {
            using var response = await client.GetAsync(url, ct);
            response.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));

            var result = doc.RootElement.GetProperty("data").GetProperty("result");
            if (result.GetArrayLength() == 0)
                return null;

            var raw = result[0].GetProperty("value")[1].GetString();
            return double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                ? value
                : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            logger.LogWarning("Prometheus query failed ({Query}): {Message}", promql, ex.Message);
            return null;
        }
    }
}
