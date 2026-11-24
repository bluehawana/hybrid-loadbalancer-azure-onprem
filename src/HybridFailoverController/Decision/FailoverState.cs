namespace HybridFailoverController.Decision;

public enum FailoverState
{
    Healthy = 0,    // serving from the on-prem primary
    Degraded = 1,   // on-prem over thresholds, watching before shifting
    FailedOver = 2, // traffic drained to the Azure backup
    Recovering = 3  // on-prem healthy again, waiting for a stable window before shifting back
}
