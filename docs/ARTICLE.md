#NewYearNewProject No.11 — A load balancer that is not in the room

Most teams I meet know how a load balancer works. Health check, two backends, traffic goes to the one that answers.
Then I look at where they put it.
The load balancer runs on the same server as the service. Or on another server in the same rack, in the same server room, behind the same power feed and the same internet line.
That setup protects you from one thing: a process crashing. It does not protect you from the electricity going, the uplink going, the cooling going, or someone restarting the wrong switch. When the room is gone, both backends are gone, and so is the thing that was supposed to choose between them.
Two servers in one room are one failure domain. A load balancer inside that room does not change it.

The number that matters
Say you promise customers 99.7% uptime per year. It sounds generous until you do the arithmetic: 0.3% of 8,760 hours is about 26 hours. For the whole year. One bad night in a server room, with someone woken at 2:30 AM to restart a service by hand, spends a large part of that budget.
So I built it the other way around.

Three pieces, three places
1 — The on-prem server stays primary. It is already paid for, and it carries the load nearly all of the time.
2 — An Azure VM runs the same service as backup. Different site, different network, different power.
3 — The load balancer (HAProxy) and a small .NET controller run in the cloud, outside the server room.
Number 3 is the part most setups get wrong. The thing that decides where traffic goes must survive the failure it is deciding about.

What happens when on-prem goes down
The controller probes the on-prem service every 10 seconds and reads CPU, memory and latency from Prometheus.
Three failed checks, or sustained overload, and it moves all traffic to the Azure VM. One HAProxy runtime command. No restart, no DNS change to wait for.
At the same moment it triggers a restart pipeline for the on-prem service. Nobody is paged to do it.
When on-prem answers again, traffic does not jump straight back. On-prem has to stay healthy for a full recovery window first (5 minutes by default). Otherwise a flapping server drags your customers back and forth with it.
Then traffic drains back to on-prem and the Azure side goes idle again.
Healthy → Degraded → FailedOver → Recovering → Healthy. Four states. That is the whole brain.

Does it work? I timed it.
Test cluster, mock backends, three scenarios: sudden death, flapping, sustained outage. 13 of 13 steps passed.
Traffic was on Azure 6.5 seconds after the primary died. Clients saw about 3 seconds of errors. Falling back caused 0 seconds of downtime.

Why not just run everything twice
Because then you pay twice. Here Azure is a temporary backup, not a second production site.
The controller counts every second served from Azure, so one Grafana dashboard shows uptime next to what the backup actually cost. After a month you decide with data instead of opinions: stay on-prem, stay hybrid, or move.

Three things I learned building it
- Check the backup all the time, not only on the day you need it. Failing over to a dead VM is worse than not failing over.
- The safety net must watch itself. If the controller stops reporting, that is an alert, not silence.
- Keep a manual mode. Some teams want a human to press the button at first. The controller then only recommends, and autopilot is one command away.

What is not finished: traffic switching, self-heal and fall-back are automatic today. Starting the Azure VM on failover and deallocating it after fall-back is still a script in my test setup. Moving that into the controller is next.

---
How to do it yourself — full guide in the README
Find your on-prem server's IP (one PowerShell line).
Find your Azure VM's IP (one az command).
Test from inside the cluster that both answer on the health endpoint.
Put the two addresses into haproxy.cfg and services.yaml.
If you use an AI coding tool, there is a ready prompt in the README. Fill in the brackets and paste.

HAProxy · .NET 8 · Kubernetes · Prometheus · Grafana · Azure
MIT-licensed repo 👇
https://github.com/bluehawana/hybrid-loadbalancer-azure-onprem

If your load balancer and your servers share a door, check what happens when that door closes.

#LoadBalancer #HighAvailability #Azure #HybridCloud #HAProxy #DevOps #SRE #BuildInPublic
