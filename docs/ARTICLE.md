#NewYearNewProject No.11 — A load balancer that is not in the room

Most teams I meet know how a load balancer works. Health check, two backends, traffic goes to the one that answers.
Then I look at where they put it.
On the same server as the service. Or on another server in the same room, behind the same power feed and the same internet line.
That protects you from one thing: a process crashing. Not from the electricity going, the uplink going, or the cooling going. When the room is gone, both backends are gone, and so is the thing that was supposed to choose between them.
Two servers in one room are one failure domain.

Say you promise customers 99.7% uptime per year. That is about 26 hours of downtime. For the whole year. One bad night in a server room spends a large part of it.
So I built it the other way around.

1 — The on-prem server stays primary. It is already paid for.
2 — An Azure VM runs the same service as backup. Different site, different network, different power.
3 — The load balancer (HAProxy) and a small .NET controller run in the cloud, outside the server room.
Number 3 is what most setups get wrong. The thing that decides where traffic goes must survive the failure it is deciding about.

When on-prem goes down
The controller checks the service every 10 seconds and reads CPU, memory and latency from Prometheus.
Three failed checks in a row, so within 30 seconds, or sustained overload, and all traffic moves to Azure automatically. One HAProxy command. No restart, no DNS wait.
At the same moment it triggers a restart of the on-prem service. No developer is woken up, and most customers never notice.
On-prem must then stay healthy for a full recovery window before traffic drains back, so a flapping server does not drag customers with it. Then Azure goes idle again.

I timed it on a test cluster with mock backends: 13 of 13 steps passed. Traffic was on Azure 6.5 seconds after the primary died. Falling back caused 0 seconds of downtime.

Why not run everything twice? Because then you pay twice. Azure here is a temporary backup, and the controller counts every second served from it, so Grafana shows uptime next to what it cost.
The wall dashboard is red and green only: kill on-prem, its tile turns red, the service tile stays green, availability stays at 100%.

Not finished: starting and deallocating the Azure VM is still a script in my test setup. Moving it into the controller is next.

The README shows how to find your on-prem IP and your Azure VM IP, test both from the cluster, and put them in two config files. There is a ready prompt if you use an AI coding tool.

HAProxy · .NET 8 · Kubernetes · Prometheus · Grafana · Azure
MIT-licensed repo 👇
https://github.com/bluehawana/hybrid-loadbalancer-azure-onprem

If your load balancer and your servers share a door, check what happens when that door closes.

#LoadBalancer #HighAvailability #Azure #HybridCloud #HAProxy #DevOps #SRE #BuildInPublic
