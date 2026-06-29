# Azure App Service Repro Tool

A multi-framework web application that simulates the most common customer-reported Azure App Service issues for **reproduction, diagnosis, and training** purposes.

Live across five isolated apps — .NET 8, Python 3.11/Flask, and Java 17/Spring Boot — on both Windows and Linux App Service.

Source: [github.com/Cypheratom/azure-appservice-repro-tool](https://github.com/Cypheratom/azure-appservice-repro-tool)

---

## Supported Environments

| App | Framework | OS | URL pattern |
|-----|-----------|-----|-------------|
| `reprobot-dotnet-win-<suffix>` | .NET 8 (ASP.NET Core) | Windows | `https://reprobot-dotnet-win-<suffix>.azurewebsites.net` |
| `reprobot-dotnet-lnx-<suffix>` | .NET 8 (ASP.NET Core) | Linux   | `https://reprobot-dotnet-lnx-<suffix>.azurewebsites.net` |
| `reprobot-python-lnx-<suffix>` | Python 3.11 / Flask  | Linux   | `https://reprobot-python-lnx-<suffix>.azurewebsites.net` |
| `reprobot-java-lnx-<suffix>`   | Java 17 / Spring Boot | Linux  | `https://reprobot-java-lnx-<suffix>.azurewebsites.net`  |
| `reprobot-java-win-<suffix>`   | Java 17 / Spring Boot | Windows | `https://reprobot-java-win-<suffix>.azurewebsites.net` |

## Simulated Scenarios

| Endpoint | Description | Key Parameters |
|----------|-------------|----------------|
| `GET /slow` | Blocks the thread / process for N ms | `?delay=5000` |
| `GET /cpu` | Saturates all CPUs for N seconds | `?duration=30` |
| `GET /memory` | Allocates and **holds** N MB in memory | `?mb=300` |
| `GET /memory/free` | Releases all held memory allocations | — |
| `GET /latency` | Sequential artificial delays (simulates slow downstream) | `?requests=50&latency=200` |
| `GET /error/5xx` | Returns HTTP 500 / 502 / 503 / 504 | `?code=500` |
| `GET /error/4xx` | Returns HTTP 400 / 401 / 403 / 404 / 429 | `?code=404` |
| `GET /storage` | Writes and reads temp files (local storage I/O) | `?mb=50&files=10` |
| `GET /storage/clean` | Deletes all temp files written by `/storage` | — |
| `GET /restart` | Forces the process to exit — App Service restarts it | — |
| `GET /threadpool` | Queues blocking tasks to starve the thread pool (.NET) | `?threads=20&duration=20` |
| `GET /memleak` | Slowly grows a static list (simulated managed memory leak) | `?iterations=100&size=1000` |
| `GET /memleak/reset` | Clears the leak list and forces GC | — |
| `GET /gc` | Rapid LOH allocations to stress the GC (.NET only) | `?duration=30` |
| `GET /snat` | Opens many outbound TCP connections to simulate SNAT exhaustion | `?connections=100&holdMs=5000` |
| `GET /startup-fail` | Triggers an immediate process crash — app enters a container restart loop | — |
| `GET /startup-fail/recover` | Re-enables normal startup so the app recovers | — |
| `GET /oom` | Allocates a large memory block to trigger OOM / low-memory kill | `?mb=512` |
| `GET /info` | Returns runtime / environment info as JSON | — |
| `GET /health` | Simple health-check endpoint | — |

---

## How It Works

Each scenario is implemented identically across .NET, Python, and Java unless noted.

### `/slow` — Thread / Process Blocking

Calls `Thread.Sleep` (.NET / Java) or `time.sleep` (Python) **on the request-handling thread** for the requested duration before returning.

- **Effect:** Each blocked request occupies one worker thread. Under concurrent load this exhausts the thread pool, queueing subsequent requests and increasing latency.
- **Diagnose with:** App Insights *Performance* → Request duration; *Diagnose & Solve → High Request Duration*.

---

### `/cpu` — CPU Saturation

Runs CPU-bound spin loops in parallel across all logical cores (`Parallel.For` / `multiprocessing` / Java threads) for the requested number of seconds.

- **Effect:** 100 % CPU on every vCore. Drains burstable-tier CPU credits, triggers scaling alerts, and increases costs on consumption plans.
- **Diagnose with:** Azure Monitor *CPU Percentage*; App Insights *Performance Counters*; Kudu *Process Explorer*.

---

### `/memory` — Heap Pressure & Hold

Allocates a byte buffer of the requested size and keeps a **static reference** to it, preventing the garbage collector from reclaiming the memory.

- **Effect:** Committed memory grows and stays elevated. On Linux, the cgroup limit may trigger an OOM kill. On Windows, heavy paging causes latency spikes.
- **Release:** `GET /memory/free` clears the reference list and triggers a full GC.
- **Diagnose with:** App Insights *Live Metrics → Memory*; Kudu *Process Explorer*; `az webapp log` for OOM events.

---

### `/latency` — Downstream Latency Simulation

Fires N sequential HTTP requests to a configurable slow endpoint without connection reuse, each delayed by the requested number of milliseconds.

- **Effect:** Models a slow dependency (database, downstream API). Each in-flight request holds a thread and an outbound connection, making SNAT exhaustion easier to trigger at scale.
- **Diagnose with:** App Insights *Dependencies* blade; *End-to-end transaction* view.

---

### `/threadpool` — Thread Pool Starvation (.NET only)

Queues N synchronous `Task.Run` work items that each sleep for the requested duration, saturating the .NET CLR thread pool.

- **Effect:** New async work cannot be scheduled; ASP.NET Core starts returning HTTP 503. This is the canonical symptom of `Task.Result` / `.Wait()` blocking calls inside async code paths.
- **Diagnose with:** App Insights *Failed requests*; Kudu *Process Explorer → Threads*; Windows Event Log.

---

### `/memleak` — Managed Memory Leak

Repeatedly appends byte arrays to a static list on every request. The list is never trimmed during normal operation.

- **Effect:** Gen2 heap grows steadily across requests. After sustained load the app becomes unresponsive or is recycled by App Service health checks.
- **Reset:** `GET /memleak/reset` clears the list and forces GC.
- **Diagnose with:** App Insights *Memory Working Set* trend over time; `dotnet-dump` / heap dump analysis.

---

### `/gc` — GC Pressure (.NET only)

Rapidly allocates and discards large arrays above the 85 KB LOH threshold, forcing frequent Gen2 collections and LOH compaction.

- **Effect:** CPU time rises; request latency spikes during GC stop-the-world pauses; Gen2 heap grows unpredictably.
- **Diagnose with:** App Insights *Performance Counters → % Time in GC*; CLR Event Trace / PerfView.

---

### `/snat` — SNAT Port Exhaustion

Opens the requested number of outbound TCP connections to distinct remote ports **without connection pooling or reuse**, and holds each connection open for `holdMs`.

- **Effect:** SNAT port allocations on the App Service front-end are consumed. Once the ~128-port/minute SNAT allocation rate is exceeded, new outbound connections time out or are refused.
- **Diagnose with:** Azure Monitor *SNAT Connection Count*; App Insights *Dependency failures*; *Diagnose & Solve → SNAT Port Exhaustion*.

---

### `/oom` — OOM Kill (Linux)

Allocates one contiguous block large enough to exceed the Linux cgroup memory limit in a single operation.

- **Effect:** The Linux OOM killer sends `SIGKILL` to the process. App Service detects the exit and schedules a container restart.
- **Diagnose with:** Kudu *Container logs*; *Diagnose & Solve → Container Issues*.

---

### `/error/5xx` and `/error/4xx` — HTTP Status Code Simulation

Returns exactly the requested HTTP status code with a descriptive body, without any server-side work.

- **Effect:** Triggers Application Insights failure sampling, alert rules, and availability test failures for specific status codes.
- **Diagnose with:** App Insights *Failures* blade → Response codes.

---

### `/storage` — Local Storage I/O

Writes and reads files of the requested size in the App Service local temp directory (`/tmp` on Linux, `%TEMP%` on Windows).

- **Effect:** Tests local I/O throughput, file quota limits, and storage behaviour under pressure. Files are not shared across scale-out instances.
- **Clean up:** `GET /storage/clean`.

---

### `/restart` — Forced Process Exit

Calls `Environment.Exit(1)` (.NET), `sys.exit(1)` (Python), or `System.exit(1)` (Java).

- **Effect:** The process terminates immediately. App Service (ANCM on Windows, container supervisor on Linux) detects the exit and starts a new process. Models an unhandled-exception crash.
- **Diagnose with:** App Insights *Availability*; Windows Event Log event 1010 (ANCM).

---

### `/startup-fail` — ANCM Startup Failure & Auto-Recovery

This is the most complex scenario; it covers ANCM rapid-fail protection, container restart loops, and multiple recovery paths including a Kudu WebJob that operates while the app is completely down.

#### Trigger mechanism

`GET /startup-fail`:
1. Writes a UTC-timestamp flag file to `wwwroot/startup-fail.flag`.
2. Schedules `Environment.Exit(1)` 600 ms later so the HTTP response is fully sent before the process exits.

#### Crash loop

On every subsequent cold-start the **startup check** runs before Kestrel binds any ports:

```
if flag exists AND age < 30 s → throw InvalidOperationException
```

- **Windows (ANCM in-process):** The exception prevents Kestrel from starting. ANCM returns **HTTP 500.30** (In-Process Start Failure) for every incoming request. After five rapid consecutive failures, **ANCM rapid-fail protection** activates and stops retrying — the app stays down until something external intervenes.
- **Linux (container):** `Environment.Exit(1)` exits the container. App Service enters a **container restart loop** with exponential back-off, visible in Kudu *Container logs* and *Diagnose & Solve → Container Issues*.

#### Recovery paths

All paths converge on the same two steps: **delete the flag file**, then **signal the host to start a fresh worker**. They differ in who performs those steps and under what conditions.

| Path | When to use | How it works |
|---|---|---|
| **Browser auto-poll** | App restarts within the 30 s TTL window | Trigger page counts down 30 s, then polls `GET /startup-fail/recover?ack=1` every 5 s; auto-redirects to the dashboard the moment the app responds |
| **App self-heal** | Flag age ≥ 30 s and app is retrying startup | Startup check detects an expired flag, deletes it, and continues normally — no external action needed |
| **Manual recover** | App is reachable (before ANCM rapid-fail activates) | `GET /startup-fail/recover` — deletes the flag and returns HTTP 200 |
| **Continuous WebJob** | Windows only; Always On must be enabled | Polls `startup-fail.flag` every **2 s**; once age ≥ 32 s it deletes the flag then bounces ANCM via `app_offline.htm` (see below) |
| **Triggered WebJob** | Windows only; app is down; SCM Basic Auth must be enabled | `POST` to the Kudu triggered-job endpoint; performs immediate flag deletion + ANCM bounce |

#### ANCM bounce via `app_offline.htm`

Both WebJobs use the same mechanism to force ANCM to spin up a fresh in-process worker:

1. **Write** `wwwroot/app_offline.htm` → ANCM drains the current in-process worker and returns HTTP 503 during drain.
2. **Wait 1 s** for the drain to complete.
3. **Delete** `app_offline.htm` → ANCM treats the removal as a new-start signal, **independent of the rapid-fail counter**, and starts a clean worker process.

This reliably recovers the app even when ANCM rapid-fail protection has already stopped retrying.

#### Timing

| Parameter | Value |
|---|---|
| Flag TTL (crash window) | 30 s |
| Continuous WebJob poll interval | 2 s |
| WebJob TTL threshold | 32 s |
| ANCM drain wait | 1 s |
| Post-recovery cooldown | 10 s |
| **Worst-case total (auto)** | **~35 s** |

---

## Deployment

### Requirements

> ⚠️ **Everything below must be satisfied before `deploy.ps1` will succeed.**
> The script runs a pre-flight check and exits early if a required tool is missing.

| Requirement | Why it is needed | Verify |
|---|---|---|
| **Azure CLI ≥ 2.50** | Provisions infrastructure; deploys code via `az webapp deploy` | `az --version` |
| **.NET 8 SDK** | Builds the ASP.NET Core app with `dotnet publish` | `dotnet --version` |
| **Maven 3.x** | Packages the Java Spring Boot fat-JAR with `mvn package` | `mvn -version` |
| **PowerShell 7+** | Required to run `deploy.ps1` | `pwsh --version` |
| **Azure subscription** | Contributor or Owner on the target subscription | `az account show` |
| **App Service Plan ≥ B1** | Free/D1 tiers lack Always On and App Insights codeless attach | Set via `skuName=B1` in Bicep |
| **Always On enabled** | Keeps the continuous WebJob alive so startup-fail auto-recovery works | Portal → Configuration → General settings |
| **SCM Basic Auth Publishing Credentials** | Required for the Kudu triggered WebJob endpoint (manual startup-fail recovery while app is down) | Portal → Configuration → General settings → SCM Basic Auth |

> Maven is optional — Java apps are skipped automatically if `mvn` is not found on `$PATH`.
> Python 3.11+ is only needed for local development.

### Deploy everything (PowerShell)

```powershell
cd infra
.\deploy.ps1
```

Override defaults:

```powershell
.\deploy.ps1 -SubscriptionId "<your-subscription-id>" `
             -TenantId       "<your-tenant-id>" `
             -ResourceGroup  "rg-reproapp" `
             -Location       "westeurope" `
             -Suffix         "demo01"
```

### Deploy infrastructure only (Bicep)

```bash
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file infra/main.bicep \
  --parameters location=westeurope suffix=demo01
```

## App Service Plan Tiers

The default deployment uses the **Basic (B1)** tier, which is required for
**Always On** and **Application Insights** auto-instrumentation.

> ℹ️ If you want a lower-cost option for short repros, you can pass `F1`/`Free`
> to the Bicep parameters. Note that Free tier is limited to
> **60 CPU-minutes/day**, does not support Always On, and cannot use
> Application Insights codeless attach.

```bash
# Free tier (limited — not recommended for sustained repros)
az deployment group create \
  --resource-group <rg> \
  --template-file infra/main.bicep \
  --parameters suffix=demo01 skuName=F1 skuTier=Free
```

## Monitoring

Every app is automatically configured with:

| Setting | Value |
|---------|-------|
| **Application Insights** | Shared instance `repro-ai-<suffix>`, codeless auto-instrumentation |
| **Always On** | Enabled (keeps workers warm, avoids cold-start bias) |
| **App Logging** | Filesystem, Error level, 90-day retention |
| **Web Server Logging** | Filesystem, 35 MB quota, 90-day retention |
| **Failed Request Tracing** | Enabled |

## Local Development

### .NET
```bash
cd dotnet/ReproApp
dotnet run
# Open http://localhost:5000
```

### Python
```bash
cd python
pip install -r requirements.txt
python app.py
# Open http://localhost:8000
```

### Java
```bash
cd java
mvn spring-boot:run
# Open http://localhost:8080
```

## Project Structure

```
repro-app/
├── dotnet/
│   └── ReproApp/
│       ├── Program.cs          # All simulation endpoints
│       ├── ReproApp.csproj
│       └── web.config          # IIS hosting config (Windows)
├── python/
│   ├── app.py                  # Flask app with all simulation endpoints
│   └── requirements.txt
├── java/
│   ├── pom.xml
│   └── src/main/java/com/reproapp/
│       ├── ReproApplication.java
│       ├── DashboardController.java   # HTML dashboard
│       └── ReproController.java       # All simulation endpoints
└── infra/
    ├── main.bicep              # All-in-one IaC (5 apps + App Insights)
    ├── windows.bicep           # Windows plan module
    ├── linux.bicep             # Linux plan module
    └── deploy.ps1              # End-to-end build + deploy script
```