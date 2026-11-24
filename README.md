# Hybrid Failover Load Balancer (on-prem + Azure)

A load balancer that does **not** live in the same room as the servers it protects.

Traffic stays on the cheap, already-paid-for **on-prem server** while it is healthy. When
that server is dying, overloaded, or dead, traffic **automatically shifts to an Azure VM**,
the on-prem service gets restarted, and once on-prem is stably healthy again traffic
**shifts back** and the Azure side goes idle. No 2:30 AM page to restart a service by hand.

## Why

Most load balancer setups are logically right and physically wrong: the load balancer sits
on the same server, or on another server in the same server room, as the backends. If the
room loses power, network, or cooling, everything behind that one door is gone, load
balancer included. Two boxes in one room are still **one failure domain**.

This project puts the pieces in different failure domains:

| Piece | Where it runs | Example address |
|---|---|---|
| Primary (real service) | On-prem server room | `192.168.10.20:443` |
| Backup (same service) | Azure VM, different network and site | `10.20.0.10:443` |
| Load balancer + controller | Kubernetes in the cloud (outside the server room) | `webapp.example.com` |

Three goals drive the design:

- **Availability** - keep the uptime promised to customers (e.g. 99.7 % per year allows
  about 26 hours of downtime in total; one bad night in a server room can eat most of it).
- **Economy** - on-prem carries the load almost all of the time. Azure is a temporary
  backup, not a second full production site, and the dashboard shows what it cost.
- **Reliability** - the thing that decides where traffic goes must survive the failure it
  is supposed to handle.

## How it works

```
Clients ──> Ingress/Route ──> HAProxy (cloud) ──> on-prem primary  192.168.10.20  (normal)
                                   │            └─> Azure VM backup  10.20.0.10     (on failover)
                                   ▲
                   Failover controller (.NET) probes health, reads Prometheus signals,
                   and drives HAProxy over its runtime socket
```

- **HAProxy** (data plane) - one backend per service with the on-prem host as primary and
  the Azure VM as the `backup` server. Handles *reactive* dead-server detection on its own.
- **Failover controller** (`src/HybridFailoverController`, .NET 8) - the *predictive* brain.
  It polls on-prem health + CPU/memory/latency from Prometheus and:
  - shifts to Azure **before** a host dies (sustained high CPU/memory/latency),
  - shifts to Azure the moment health checks fail,
  - triggers a **restart pipeline** to repair the on-prem service (self-heal),
  - shifts **back** to on-prem once it is stably healthy for a recovery window,
  - exports failover + **cost** metrics for Grafana.
- **Manual / autopilot** - `manualmode.bat` makes the controller only recommend;
  `failover.bat` / `failback.bat` move traffic by hand; `autopilot.bat` hands control back.

> **Status of the Azure VM lifecycle:** the controller continuously health-checks the
> backup and moves traffic to and from it. Starting the VM on failover and deallocating it
> after fall-back is done by the demo scripts today (scaling the backup up/down) and is the
> next piece to move into the controller.

### Failover state machine

`Healthy → Degraded → FailedOver → Recovering → Healthy`

Thresholds are per-service in `deploy/base/config/services.yaml`.

### What runs on the Azure VM (warm standby)

A common question: *is the Azure VM a proxy, or does it run the service?*

- **HAProxy is the only proxy** (it runs in ARO). It never does the work — it just
  forwards each request to whichever backend is healthy (on-prem **or** the Azure VM).
- **The Azure VM is a warm standby that runs the real web app** — same HTTPS
  `:443`, same `/health/ready` — so on failover it genuinely serves traffic. It is **not**
  a proxy (forwarding to a dead on-prem would be pointless).

Analogy: HAProxy = the receptionist who routes the call; on-prem = Office A; the Azure VM =
Office B, which must be a real, equipped copy (same app, config, and data) to do the work.

The VM can serve **if** two conditions hold:

1. **The app can run on the VM** — the same web app (installed or containerized),
   listening on `:443` with `/health/ready`.
2. **It can reach its data + dependencies from Azure** — database, file shares, licenses, any
   other services it calls.

How hard that is depends on how self-contained the app is:

| The app is… | Standby effort |
|---|---|
| **Stateless + reads a shared DB** reachable from Azure | **Easy** — install the app on the VM, point it at the same DB. True hot copy. |
| **Stateful / depends on on-prem-only** things (local shares, other services, hardware/licenses) | **Harder** — those dependencies must be reachable from Azure, or the data replicated. A project of its own. |

> This load balancer decides **when** to fail over. **Provisioning the standby app and keeping
> its data in sync is a separate piece of work** — check the app's data model before
> sizing the VM. In test, `azure-mock` (traefik/whoami) stands in for the real service.

## Layout

```
src/HybridFailoverController/   .NET 8 controller (the coded load-balancer brain)
deploy/base/                 HAProxy + controller pod, service, kustomize base
  config/haproxy.cfg         HAProxy data plane (primary + backup servers)
  config/services.yaml       Per-service failover config (the template to copy)
deploy/overlays/prod/        prod: namespace, Route, 2 replicas
monitoring/dashboards/       Grafana dashboard (state, health, cost comparison)
monitoring/rules/            Prometheus alert rules
Dockerfile                   Controller image
```

## Metrics (Prometheus)

| Metric | Meaning |
|---|---|
| `hybridlb_failover_state` | 0 Healthy / 1 Degraded / 2 FailedOver / 3 Recovering |
| `hybridlb_failover_active` | 1 while serving from Azure |
| `hybridlb_primary_healthy` | on-prem health check result |
| `hybridlb_backup_healthy` | Azure backup (escape hatch) health check result |
| `hybridlb_primary_cpu_percent` / `_memory_percent` / `_latency_ms` | on-prem load signals |
| `hybridlb_failover_events_total{reason}` | failover / recovery transitions |
| `hybridlb_azure_active_seconds_total` | Azure time used → cost comparison |

## Dashboards (red / green at a glance)

Two Grafana dashboards ship in `monitoring/dashboards/`. Import either one in Grafana
(**Dashboards → New → Import → upload JSON**) and pick your Prometheus datasource.

**`hybridlb-failover-demo.json`** - the one to put on a wall screen or show in a demo:

| Panel | Green | Red / other |
|---|---|---|
| Service (what the customer sees) | **UP** - reachable through the load balancer, on-prem *or* Azure | **DOWN** - both sides are gone |
| Service availability % | at or above the 99.7 % target (100 % through a clean failover) | below target |
| Serving from | on-prem | blue = Azure |
| On-prem node | healthy | red = failing health checks |
| Azure standby | ready to take traffic | red = the escape hatch itself is broken |
| Timelines | unbroken green bar = customers were served the whole time | red gap = real outage |

The point of the demo: kill the on-prem service and watch **On-prem node** go red while
**Service** stays green and availability stays at 100 %.

**`hybridlb-failover.json`** - the operations view: failover state, on-prem CPU / memory /
latency, failover count, on-prem uptime %, Azure hours used and estimated Azure cost
(set the `vm_hourly_cost` variable to your VM's hourly price).

The service label in the demo dashboard queries is `webapp`; change it if you rename the
service in `services.yaml`. With grafana-operator you can publish the dashboard from Git
instead, see `monitoring/grafana/hybridlb-failover-dashboard.yaml`.

## Testing & durability (proof it recovers within seconds)

Two scripts in `benchmark/` prove the failover works — not just once, but every time.

**Single failover benchmark** — one real outage, timed end to end:

```powershell
kubectl -n hybridlb-test port-forward svc/hybrid-loadbalancer 8080:8080   # terminal 1
./benchmark/Invoke-FailoverBenchmark.ps1 `                        # terminal 2
    -LbUrl https://webapp-lb.apps.example.com/ `
    -MetricsUrl http://localhost:8080/metrics
```

**Durability / resilience suite** — repeated and varied failure patterns; passes only if
the service comes back up within seconds *every* time and fall-back causes *no* downtime:

```powershell
./benchmark/Invoke-DurabilityTest.ps1 `
    -LbUrl https://webapp-lb.apps.example.com/ `
    -MetricsUrl http://localhost:8080/metrics
```

It runs three scenarios and restores the primary on exit (even on Ctrl-C):

| Scenario | What it proves |
|---|---|
| Sudden death ×N | Kill the primary, time recovery to Azure, repair, confirm zero-downtime fall-back. |
| Flapping ×N | Rapid kill/recover cycles never leave the controller stuck. |
| Sustained outage | Hold the primary down and confirm the service keeps serving from Azure. |

Failover events are gated on **time-to-up ≤ target** (default 15 s); fall-back is gated on
**client downtime ≈ 0** — the 30-ish-second recovery hold is by design (waits for on-prem to
be stably healthy before draining back, to avoid flapping) and involves no outage.

**Measured on the test cluster with mock backends:** 13/13 steps passed. Every failover brought the
service up in **6.5–6.6 s** (client outage ~3.2 s); fall-back caused **0 s** downtime.

## The one-month trial

The Grafana dashboard shows on-prem uptime %, Azure hours used, estimated Azure cost
(set the `vm_hourly_cost` variable), and failover counts. After a month of real data,
you can decide: **stay on-prem, go hybrid, or go cloud** — on evidence, not guesses.

## Onboard another service

1. Add a `backend` to `deploy/base/config/haproxy.cfg` with `server onprem ...` and
   `server azurevm ... backup`.
2. Add a service block to `deploy/base/config/services.yaml` (health URL + thresholds +
   Prometheus queries for that host's `windows_exporter` instance).
3. Add a Route in `deploy/overlays/prod/` for the service hostname.
4. Import the Grafana dashboard / add the alert rule — done.

## Configure it for your own environment

The repo ships with example addresses only: `192.168.10.20` (on-prem primary) and
`10.20.0.10` (Azure VM backup). Replace them with yours in four steps.

### 1. Find your on-prem server address

Run this **on the on-prem server** that hosts the service:

```powershell
# Windows
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
```

```bash
# Linux
hostname -I
```

Pick the address on the network your cluster can route to (ask your network team if the
server has several NICs). If you only know the DNS name: `nslookup your-server-name`.

### 2. Find your Azure VM address

```bash
# private IP (use this when the cluster reaches the VM over VNet peering / VPN / ExpressRoute)
az vm show -d -g <resource-group> -n <vm-name> --query privateIps -o tsv

# public IP (only if the VM is reached over the internet - lock it down with an NSG)
az vm show -d -g <resource-group> -n <vm-name> --query publicIps -o tsv
```

Or in the Azure portal: **Virtual machines → your VM → Overview → Networking**.

### 3. Prove both are reachable from where the load balancer runs

The load balancer must reach both sides from **outside** the server room, so test from a
pod in the cluster, not from your laptop:

```bash
kubectl run nettest --rm -it --image=curlimages/curl --restart=Never -- \
  sh -c 'curl -sk -o /dev/null -w "onprem %{http_code}\n" https://<ONPREM_IP>:443/health/ready; \
         curl -sk -o /dev/null -w "azure  %{http_code}\n" https://<AZURE_VM_IP>:443/health/ready'
```

Both should print `200`. If your app has no `/health/ready`, use any URL that returns 200
only when the service can really serve requests.

### 4. Put the addresses in

| File | What to change |
|---|---|
| `deploy/base/config/haproxy.cfg` | `server onprem <ONPREM_IP>:443` and `server azurevm <AZURE_VM_IP>:443 backup` |
| `deploy/base/config/services.yaml` | `primary.healthUrl`, `backup.healthUrl`, and the `instance="<ONPREM_IP>:9182"` label in the Prometheus queries |
| `deploy/overlays/prod/ingress.yaml` | your public hostname and TLS secret name |
| `deploy/base/kustomization.yaml` | your container registry for the controller image |

Then `kubectl kustomize deploy/overlays/prod` to preview and apply.

### Using an AI coding tool? Paste this prompt

Open this repo in Claude Code, Copilot, Cursor or similar and paste (fill in the brackets):

```text
Configure this hybrid failover load balancer for my environment.

- On-prem primary server: <ONPREM_IP>, service on port <PORT>, health endpoint <PATH>
- Azure VM backup: <AZURE_VM_IP>, same port and health endpoint
- Public hostname for the service: <HOSTNAME>, TLS secret: <SECRET_NAME>
- Container registry for the controller image: <REGISTRY>
- Prometheus URL: <PROMETHEUS_URL>; windows_exporter/node_exporter instance label
  for the on-prem server: <INSTANCE_LABEL>

Replace the example addresses 192.168.10.20 and 10.20.0.10 everywhere they appear in
deploy/base/config/haproxy.cfg and deploy/base/config/services.yaml, update the ingress
host and the image registry, and keep the on-prem server as primary and the Azure VM as
`backup`. Do not change thresholds or the state machine. When done, run
`kubectl kustomize deploy/overlays/prod`, show me the rendered diff, and list anything
that still contains a placeholder. Do not apply anything to a cluster.
```

Never commit real addresses, hostnames, tokens or pull secrets to a public fork - keep
them in a private overlay or in cluster secrets.

## Build & deploy

```powershell
# Controller
dotnet build src/HybridFailoverController/HybridFailoverController.csproj

# Image
docker build -t youracr.azurecr.io/hybrid-loadbalancer-controller:0.1.0 .

# Manifests (preview)
kubectl kustomize deploy/overlays/prod
```

> Placeholders to replace before real use: the on-prem address (`192.168.10.20`) and the Azure
> VM address (`10.20.0.10`) in
> `haproxy.cfg` / `services.yaml`, the `windows_exporter` instance labels, the Route
> hostname, and the TLS secret name.

## License

MIT - see [LICENSE](LICENSE). Use it, fork it, adapt it to your own environment.
