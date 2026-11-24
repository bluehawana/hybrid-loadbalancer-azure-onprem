using System.Net.Sockets;
using System.Text;
using HybridFailoverController.Configuration;

namespace HybridFailoverController.Haproxy;

/// <summary>Drives HAProxy live over its runtime API socket (no reload needed).</summary>
public sealed class HaproxyRuntimeClient(ServicesConfig config, ILogger<HaproxyRuntimeClient> logger)
{
    private readonly HaproxyOptions _options = config.Haproxy;

    public Task DrainAsync(string backend, string server, CancellationToken ct) =>
        SetServerStateAsync(backend, server, "drain", ct);

    public Task ReadyAsync(string backend, string server, CancellationToken ct) =>
        SetServerStateAsync(backend, server, "ready", ct);

    public async Task SetServerStateAsync(string backend, string server, string state, CancellationToken ct)
    {
        var response = await SendAsync($"set server {backend}/{server} state {state}", ct);
        logger.LogInformation("HAProxy set {Backend}/{Server} -> {State}: {Response}",
            backend, server, state, response.Trim());
    }

    public async Task<string> SendAsync(string command, CancellationToken ct)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(_options.RuntimeHost, _options.RuntimePort, ct);
        await using var stream = client.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes(command + "\n"), ct);
        using var reader = new StreamReader(stream, Encoding.ASCII);
        return await reader.ReadToEndAsync(ct);
    }
}
