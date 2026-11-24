using HybridFailoverController.Configuration;
using HybridFailoverController.Decision;

namespace HybridFailoverController;

public sealed class Worker(
    ServicesConfig config,
    FailoverDecisionEngine engine,
    ILogger<Worker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = TimeSpan.FromSeconds(Math.Max(2, config.PollIntervalSeconds));
        logger.LogInformation("Failover controller started: {Count} service(s), poll every {Interval}s.",
            config.Services.Count, interval.TotalSeconds);

        var last = DateTimeOffset.UtcNow;
        using var timer = new PeriodicTimer(interval);
        do
        {
            var now = DateTimeOffset.UtcNow;
            var elapsed = (now - last).TotalSeconds;
            last = now;

            foreach (var svc in config.Services)
            {
                try
                {
                    await engine.EvaluateAsync(svc, elapsed, stoppingToken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    logger.LogError(ex, "Evaluation failed for {Service}", svc.Name);
                }
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
