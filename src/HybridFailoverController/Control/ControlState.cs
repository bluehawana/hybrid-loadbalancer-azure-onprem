using System.Collections.Concurrent;

namespace HybridFailoverController.Control;

public enum OperatorCommand
{
    None = 0,
    Failover = 1, // move traffic on-prem -> Azure
    Failback = 2  // move traffic Azure -> on-prem
}

/// <summary>
/// Runtime control surface shared between the HTTP /control endpoints and the decision engine.
/// In Manual mode the engine only monitors and publishes a recommendation; it shifts traffic
/// solely when an operator command is queued here. Switchable live via /control/mode so the
/// team can demo supervised failover first and flip to autopilot afterwards.
/// </summary>
public sealed class ControlState(bool manual)
{
    private volatile bool _manual = manual;
    private readonly ConcurrentDictionary<string, OperatorCommand> _commands = new();

    public bool Manual { get => _manual; set => _manual = value; }

    /// <summary>Queue an operator command for the engine to execute on its next tick.</summary>
    public void Queue(string service, OperatorCommand command) => _commands[service] = command;

    /// <summary>Take and clear the pending command for a service (None if nothing queued).</summary>
    public OperatorCommand Dequeue(string service) =>
        _commands.TryRemove(service, out var c) ? c : OperatorCommand.None;

    /// <summary>What autopilot would do right now, surfaced to the operator/dashboard.</summary>
    public ConcurrentDictionary<string, OperatorCommand> Recommendation { get; } = new();
}
