using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient();
var app = builder.Build();

// ── HTTP 500.30 / container-exit startup-fail simulation ────────────────────────
// If the flag file exists AND its timestamp is within the 30-second TTL, the process
// throws here before Kestrel binds → IIS returns HTTP 500.30 on Windows (ANCM
// In-Process Start Failure) / container restart loop on Linux.
// After 30 s the flag is considered expired: the app self-heals by deleting it and
// continuing normally. Manual recovery before that: /startup-fail/recover (while up)
// or the Kudu WebJob recover-startup (Windows, works while crashed).
var poisonFlag = Path.Combine(AppContext.BaseDirectory, "startup-fail.flag");
if (File.Exists(poisonFlag))
{
    var raw = File.ReadAllText(poisonFlag).Trim();
    var stillActive = DateTime.TryParse(raw, null,
        System.Globalization.DateTimeStyles.RoundtripKind, out var writtenAt)
        && DateTime.UtcNow - writtenAt < TimeSpan.FromSeconds(30);
    if (stillActive)
        throw new InvalidOperationException(
            "[REPROAPP] Simulated startup failure – flag active for " +
            $"{(int)(DateTime.UtcNow - writtenAt).TotalSeconds}s / 30s. " +
            "Auto-recovers when TTL expires, or delete 'startup-fail.flag' to recover immediately.");
    // TTL expired – self-heal
    File.Delete(poisonFlag);
}

// ─────────────────────────────── HOME / DASHBOARD ────────────────────────────

app.MapGet("/", () =>
{
    var os       = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "Windows" : "Linux";
    var fw       = RuntimeInformation.FrameworkDescription;
    var subtitle    = $"""<span class="badge badge-fw">ASP.NET Core 8</span><span class="badge badge-os">{os}</span><span class="badge badge-env">Simulates common customer-reported issues</span>""";
    var startupFailNote = os == "Windows"
        ? "Arms a 30-second flag then exits. On restart IIS returns <strong>HTTP&nbsp;500.30</strong> (ANCM In-Process Start Failure). <strong>Auto-recovers after ~30 s</strong> when the TTL expires; or trigger the Kudu WebJob below for immediate recovery while crashed."
        : "Arms a 30-second flag then exits (code&nbsp;1). App Service enters a restart loop. <strong>Auto-recovers after ~30 s</strong> when the TTL expires. Check <em>Container logs</em> in Diagnose &amp; Solve.";
    var host = app.Urls.FirstOrDefault() ?? "";
    var scmBase = $"https://{app.Configuration["WEBSITE_HOSTNAME"]?.Replace(".azurewebsites.net", ".scm.azurewebsites.net")}";
    var webJobTriggerUrl = $"{scmBase}/api/triggeredwebjobs/recover-startup/run";
    // Pre-build strings that contain literal braces so they don't conflict with raw string interpolation
    var psQuery   = "{u:publishingUserName,p:publishingPassword}";
    var psHeaders = "@{Authorization=\"Basic \"+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\"$($c.u):$($c.p)\"))}";
    var psCmd     = $"$c=az webapp deployment list-publishing-credentials -g &lt;rg&gt; -n &lt;app&gt; --query &quot;{psQuery}&quot; -o json|ConvertFrom-Json; Invoke-WebRequest -Uri &apos;{webJobTriggerUrl}&apos; -Method POST -Headers {psHeaders}";
    var webJobNote = os == "Windows" ? $"""
      <details style="margin-top:8px">
        <summary style="cursor:pointer;color:#60a5fa;font-size:.85rem">&#x1F527; Kudu WebJob recovery (works while app is crashed)</summary>
        <p style="font-size:.8rem;margin:6px 0 2px">POST to this endpoint with Basic Auth (Kudu publishing credentials):</p>
        <code style="display:block;word-break:break-all;font-size:.78rem;background:#1e293b;padding:6px 8px;border-radius:4px">{webJobTriggerUrl}</code>
        <p style="font-size:.78rem;margin:6px 0 2px">PowerShell one-liner:</p>
        <code style="display:block;word-break:break-all;font-size:.75rem;background:#1e293b;padding:6px 8px;border-radius:4px">{psCmd}</code>
      </details>
    """ : "";
    var startupFailCard = $"""
    <div class="card">
      <h3>&#x1F4A5; Startup Failure {(os == "Windows" ? "(HTTP 500.30)" : "(Container exit)")}</h3>
      <p>{startupFailNote}</p>
      <a class="btn danger" href="/startup-fail" target="_blank">Trigger Startup Fail</a>
      <a class="btn" href="/startup-fail/recover" target="_blank">&#x21A9; Recover (app must be up)</a>
      {webJobNote}
      <details class="how"><summary>How it works</summary><p>Writes <code>startup-fail.flag</code> with a UTC timestamp then calls <code>Environment.Exit(1)</code> after 600&nbsp;ms (so the HTTP response returns first). On the next cold-start, the flag check throws before Kestrel binds &rarr; ANCM returns <strong>HTTP&nbsp;500.30</strong> (Windows) or the container enters a restart loop (Linux). Flag TTL&nbsp;= 30&nbsp;s; self-heals on expiry. The trigger page auto-polls <code>/startup-fail/recover?ack=1</code> &mdash; no Kudu or external trigger needed.</p></details>
    </div>
""";
    var oomCard = os == "Linux" ? """
    <div class=\"card\">
      <h3>&#x1F9E0; OOM / Low Memory</h3>
      <p>Allocate until OOM killer fires or CLR throws OutOfMemoryException.<br/>Param: <code>?mb=512</code></p>
      <a class=\"btn danger\" href=\"/oom?mb=512\" target=\"_blank\">512 MB</a>
      <a class=\"btn danger\" href=\"/oom?mb=1024\" target=\"_blank\">1 GB</a>
      <details class=\"how\"><summary>How it works</summary><p>Allocates in 50&nbsp;MB chunks touching every 4&nbsp;KB page to force the OS to commit each page. On Linux with a cgroup memory limit, the kernel OOM killer fires; otherwise CLR throws <code>OutOfMemoryException</code>. Unlike <code>/memory</code>, all chunks are freed in the <code>finally</code> block after the response.</p></details>
    </div>
""" : "";
    var linuxCards = startupFailCard + oomCard;
    var html = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Azure App Service Repro Tool – .NET</title>
  <style>
    body { font-family: 'Segoe UI', sans-serif; background:#f0f2f5; margin:0; padding:24px; }
    h1   { color:#0078d4; margin-bottom:4px; }
    .sub  { display:flex; align-items:center; gap:8px; margin-bottom:28px; flex-wrap:wrap; }
    .badge{ display:inline-block; padding:4px 14px; border-radius:20px; font-size:.82rem; font-weight:600; letter-spacing:.02em; }
    .badge-os  { background:#e3f2fd; color:#0d47a1; border:1px solid #90caf9; }
    .badge-fw  { background:#e8f5e9; color:#1b5e20; border:1px solid #a5d6a7; }
    .badge-env { background:#fff3e0; color:#e65100; border:1px solid #ffcc80; font-weight:400; }
    .grid{ display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:16px; }
    .card{ background:#fff; border-radius:8px; padding:20px; box-shadow:0 2px 8px rgba(0,0,0,.08); }
    .card h3{ margin:0 0 8px; font-size:1rem; color:#323130; }
    .card p { margin:0 0 14px; color:#666; font-size:.85rem; }
    .btn { display:inline-block; padding:8px 16px; border:none; border-radius:4px;
           background:#0078d4; color:#fff; cursor:pointer; font-size:.9rem; text-decoration:none; }
    .btn:hover{ background:#005a9e; }
    .btn.danger { background:#c50f1f; }
    .btn.danger:hover{ background:#9e0a13; }
    .btn.warn { background:#f7630c; }
    .btn.warn:hover{ background:#c94f09; }
    .env { font-size:.78rem; color:#888; margin-top:12px; padding-top:12px; border-top:1px solid #eee; }
    details.how { margin-top:10px; padding-top:8px; border-top:1px solid #f0f0f0; }
    details.how summary { cursor:pointer; font-size:.76rem; color:#999; user-select:none; }
    details.how summary:hover { color:#666; }
    details.how p { margin:6px 0 0; font-size:.76rem; color:#777; line-height:1.5; }
    details.how code { font-size:.73rem; background:#f0f2f5; padding:1px 4px; border-radius:3px; color:#0078d4; }
  </style>
</head>
<body>
  <h1>🔧 Azure App Service Repro Tool</h1>
  <div class="sub">##SUBTITLE##</div>
  <div class="grid">

    <div class="card">
      <h3>🐢 Slow Response</h3>
      <p>Simulate a slow endpoint by blocking the thread. <br/>Param: <code>?delay=5000</code> (ms)</p>
      <a class="btn warn" href="/slow?delay=5000" target="_blank">Trigger (5 s)</a>
      <a class="btn warn" href="/slow?delay=30000" target="_blank">Trigger (30 s)</a>
      <details class="how"><summary>How it works</summary><p><code>await Task.Delay(delay)</code> holds the request open for the full duration. Async/await returns the thread to the pool while waiting, but the HTTP connection stays pending — simulating a slow upstream dependency.</p></details>
    </div>

    <div class="card">
      <h3>🔥 High CPU</h3>
      <p>Spin CPU-intensive work across all cores.<br/>Param: <code>?duration=30</code> (seconds)</p>
      <a class="btn danger" href="/cpu?duration=30" target="_blank">Trigger (30 s)</a>
      <details class="how"><summary>How it works</summary><p>Spawns one <code>Task</code> per logical CPU core (<code>Environment.ProcessorCount</code>), each spinning <code>Math.Sqrt()</code> in a tight loop until the duration elapses — saturating all cores at 100%.</p></details>
    </div>

    <div class="card">
      <h3>💾 High Memory</h3>
      <p>Allocate a large byte array and hold it.<br/>Param: <code>?mb=300</code></p>
      <a class="btn danger" href="/memory?mb=300" target="_blank">Trigger (300 MB)</a>
      <a class="btn" href="/memory/free" target="_blank">Free Memory</a>
      <details class="how"><summary>How it works</summary><p>Allocates <code>byte[mb × 1 MB]</code>, fills it with random data (touching every page so the OS commits RAM), then holds it in a static list the GC cannot collect. <code>/memory/free</code> clears the list and forces a Gen2 collection.</p></details>
    </div>

    <div class="card">
      <h3>⏱ High Latency</h3>
      <p>Add artificial async latency to every call in a loop.<br/>Param: <code>?requests=50&amp;latency=200</code></p>
      <a class="btn warn" href="/latency?requests=50&latency=200" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Runs <code>requests</code> sequential <code>await Task.Delay(latency)</code> calls. Total response time ≈ requests × latency ms — simulates cascading upstream delays or a chatty microservice with per-call overhead.</p></details>
    </div>

    <div class="card">
      <h3>💥 HTTP 5xx Errors</h3>
      <p>Return a specific 5xx status code.<br/>Param: <code>?code=500|502|503|504</code></p>
      <a class="btn danger" href="/error/5xx?code=500" target="_blank">500</a>
      <a class="btn danger" href="/error/5xx?code=502" target="_blank">502</a>
      <a class="btn danger" href="/error/5xx?code=503" target="_blank">503</a>
      <a class="btn danger" href="/error/5xx?code=504" target="_blank">504</a>
      <details class="how"><summary>How it works</summary><p>Returns <code>Results.Json(..., statusCode: code)</code>. ASP.NET Core writes the exact HTTP status line, so reverse proxies, CDNs, and Application Gateway all see the real status code.</p></details>
    </div>

    <div class="card">
      <h3>🚫 HTTP 4xx Errors</h3>
      <p>Return a specific 4xx status code.<br/>Param: <code>?code=400|401|403|404|429</code></p>
      <a class="btn warn" href="/error/4xx?code=404" target="_blank">404</a>
      <a class="btn warn" href="/error/4xx?code=401" target="_blank">401</a>
      <a class="btn warn" href="/error/4xx?code=403" target="_blank">403</a>
      <a class="btn warn" href="/error/4xx?code=429" target="_blank">429</a>
      <details class="how"><summary>How it works</summary><p>Same pattern as 5xx — <code>Results.Json</code> with the caller-chosen status code. Useful for reproducing auth, rate-limiting, or routing issues in upstream middleware.</p></details>
    </div>

    <div class="card">
      <h3>📁 Storage I/O</h3>
      <p>Write &amp; read temp files (local disk).<br/>Param: <code>?mb=50&amp;files=10</code></p>
      <a class="btn" href="/storage?mb=50&files=10" target="_blank">Trigger</a>
      <a class="btn" href="/storage/clean" target="_blank">Clean Up</a>
      <details class="how"><summary>How it works</summary><p>Writes <code>files</code> binary files of ~(mb ÷ files) MB each to a temp directory on local disk, then reads them all back and measures elapsed time. Useful for diagnosing disk I/O bottlenecks or storage quota issues.</p></details>
    </div>

    <div class="card">
      <h3>♻️ App Restart</h3>
      <p>Force the process to exit – App Service will restart it automatically.</p>
      <a class="btn danger" href="/restart" target="_blank">Restart App</a>
      <details class="how"><summary>How it works</summary><p>Fires <code>IHostApplicationLifetime.StopApplication()</code> from a background task (500 ms delay so the HTTP response is sent first). App Service detects the clean exit and automatically restarts the worker process.</p></details>
    </div>

    <div class="card">
      <h3>🧵 Thread Pool Starvation</h3>
      <p>Block thread-pool threads with sync-over-async.<br/>Param: <code>?threads=20&amp;duration=20</code></p>
      <a class="btn danger" href="/threadpool?threads=20&duration=20" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Queues <code>threads</code> work items via <code>ThreadPool.QueueUserWorkItem</code>, each calling <code>Thread.Sleep(duration s)</code> — a blocking wait. With all TP threads occupied, async continuations stall waiting for a free thread, reproducing the sync-over-async starvation pattern.</p></details>
    </div>

    <div class="card">
      <h3>📈 Memory Leak</h3>
      <p>Slowly grow a static list (simulates a managed leak).<br/>Param: <code>?iterations=100&amp;size=1000</code></p>
      <a class="btn danger" href="/memleak?iterations=100&size=1000" target="_blank">Trigger</a>
      <a class="btn" href="/memleak/reset" target="_blank">Reset</a>
      <details class="how"><summary>How it works</summary><p>Appends <code>byte[]</code> allocations to a static list the GC cannot collect — simulates unbounded event subscriptions, static caches, or grow-only buffers never trimmed. <code>/memleak/reset</code> clears the list and forces Gen2 GC.</p></details>
    </div>

    <div class="card">
      <h3>🔄 GC Pressure</h3>
      <p>Allocate &amp; release large objects rapidly to stress GC.</p>
      <a class="btn warn" href="/gc?duration=30" target="_blank">Trigger (30 s)</a>
      <details class="how"><summary>How it works</summary><p>Rapidly allocates <code>byte[85 000]</code> objects (just above the 85 KB Large Object Heap threshold) and immediately discards them. LOH objects skip Gen0/Gen1 → direct Gen2; the high rate forces frequent blocking Gen2 GC pauses, visible as CPU spikes and latency jitter.</p></details>
    </div>

    <div class="card">
      <h3>🌐 SNAT Exhaustion</h3>
      <p>Open many outbound TCP connections to consume SNAT ports (limit ~128/instance).<br/>Param: <code>?connections=100&amp;holdMs=5000</code></p>
      <a class="btn warn" href="/snat?connections=100&holdMs=5000" target="_blank">100 connections</a>
      <a class="btn danger" href="/snat?connections=200&holdMs=10000" target="_blank">200 connections</a>
      <details class="how"><summary>How it works</summary><p>Opens <code>connections</code> <code>TcpClient</code> connections to an external host and holds them open for <code>holdMs</code> ms. Each consumes one SNAT port. App Service default: ~128 SNAT ports per instance; exhaustion causes new outbound connections to fail with <code>SocketException</code>.</p></details>
    </div>

##LINUX_CARDS##
    <div class="card">
      <h3>📊 App Info</h3>
      <p>View environment, runtime info and current resource counters.</p>
      <a class="btn" href="/info" target="_blank">View Info</a>
      <a class="btn" href="/health" target="_blank">Health</a>
    </div>

  </div>
  <div class="env">
    Hostname: <strong id="hn"></strong> &nbsp;|&nbsp; PID: <strong id="pid"></strong>
    <script>
      fetch('/info').then(r=>r.json()).then(d=>{
        document.getElementById('hn').textContent = d.machineName;
        document.getElementById('pid').textContent = d.pid;
      });
    </script>
  </div>
  <footer style="text-align:center;margin-top:24px;padding:12px 0;font-size:.78rem;color:#888">
    Maintained by <a href="mailto:jofernandes@microsoft.com" style="color:#0078d4;text-decoration:none">jofernandes@microsoft.com</a><br/>
    <a href="https://github.com/Cypheratom/azure-appservice-repro-tool" target="_blank" style="color:#0078d4;text-decoration:none">&#x1F4E6; github.com/Cypheratom/azure-appservice-repro-tool</a>
  </footer>
</body>
</html>
""".Replace("##SUBTITLE##", subtitle)
       .Replace("##LINUX_CARDS##", linuxCards);
    return Results.Content(html, "text/html");
});

// ─────────────────────────────── HEALTH ──────────────────────────────────────

app.MapGet("/health", () => Results.Ok(new { status = "healthy", timestamp = DateTime.UtcNow }));

// ─────────────────────────────── INFO ────────────────────────────────────────

app.MapGet("/info", () => Results.Ok(new
{
    machineName    = Environment.MachineName,
    pid            = Environment.ProcessId,
    framework      = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
    os             = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
    processorCount = Environment.ProcessorCount,
    workingSetMB   = Process.GetCurrentProcess().WorkingSet64 / 1024 / 1024,
    gcTotalMemoryMB = GC.GetTotalMemory(false) / 1024 / 1024,
    uptime         = (DateTime.UtcNow - Process.GetCurrentProcess().StartTime.ToUniversalTime()).ToString(@"hh\:mm\:ss"),
    timestamp      = DateTime.UtcNow,
    appName        = "ReproApp-DotNet"
}));

// ─────────────────────────────── SLOW ────────────────────────────────────────
// Implementation: await Task.Delay(delay) holds the request open for `delay` ms.
// Uses async/await so the thread is returned to the pool while waiting, but the
// HTTP connection and response are deliberately kept pending the full duration.

app.MapGet("/slow", async (int delay = 5000) =>
{
    delay = Math.Clamp(delay, 100, 120_000);
    await Task.Delay(delay);
    return Results.Ok(new { message = $"Responded after {delay} ms", timestamp = DateTime.UtcNow });
});

// ─────────────────────────────── HIGH CPU ────────────────────────────────────
// Implementation: spawns one Task per logical CPU core (Environment.ProcessorCount).
// Each task spins in a tight loop calling Math.Sqrt() until `duration` seconds elapse,
// saturating all cores at 100%.

app.MapGet("/cpu", async (int duration = 30) =>
{
    duration = Math.Clamp(duration, 1, 300);
    var sw = Stopwatch.StartNew();
    var tasks = new List<Task>();
    for (int i = 0; i < Environment.ProcessorCount; i++)
    {
        tasks.Add(Task.Run(() =>
        {
            long count = 0;
            while (sw.Elapsed.TotalSeconds < duration)
            {
                count++;
                Math.Sqrt(count * 3.14159);
            }
        }));
    }
    await Task.WhenAll(tasks);
    return Results.Ok(new { message = $"CPU stress completed ({duration} s, {Environment.ProcessorCount} cores)", timestamp = DateTime.UtcNow });
});

// ─────────────────────────────── HIGH MEMORY ─────────────────────────────────
// Implementation: allocates byte[mb * 1024 * 1024], fills it with random data
// (touching every page so the OS actually commits the RAM), then stores the buffer
// in a module-level static list. GC cannot reclaim it while the list holds a reference.
// /memory/free clears the list and forces a Gen2 GC collection.

// Static list to hold allocated memory across requests
var heldMemory = new List<byte[]>();
var memLock    = new object();

app.MapGet("/memory", (int mb = 300) =>
{
    mb = Math.Clamp(mb, 1, 1500);
    var buffer = new byte[mb * 1024 * 1024];
    new Random().NextBytes(buffer);   // actually touch the pages
    lock (memLock) { heldMemory.Add(buffer); }
    var totalHeld = heldMemory.Count > 0 ? heldMemory.Sum(b => b.Length) / 1024 / 1024 : 0;
    return Results.Ok(new
    {
        message    = $"Allocated {mb} MB",
        totalHeldMB= totalHeld,
        gcTotalMB  = GC.GetTotalMemory(false) / 1024 / 1024,
        timestamp  = DateTime.UtcNow
    });
});

app.MapGet("/memory/free", () =>
{
    int freed;
    lock (memLock) { freed = heldMemory.Count; heldMemory.Clear(); }
    GC.Collect(2, GCCollectionMode.Forced);
    return Results.Ok(new { message = $"Released {freed} allocations", timestamp = DateTime.UtcNow });
});

// ─────────────────────────────── LATENCY ─────────────────────────────────────
// Implementation: runs `requests` sequential await Task.Delay(latency) calls.
// Total response time ≈ requests × latency ms, simulating cascading upstream delays
// or a chatty microservice pattern with per-call overhead.

app.MapGet("/latency", async (int requests = 50, int latency = 200) =>
{
    requests = Math.Clamp(requests, 1, 500);
    latency  = Math.Clamp(latency, 10, 10_000);
    var sw   = Stopwatch.StartNew();
    for (int i = 0; i < requests; i++)
        await Task.Delay(latency);
    return Results.Ok(new
    {
        message     = $"Completed {requests} calls each with {latency} ms latency",
        totalElapsedMs = sw.ElapsedMilliseconds,
        timestamp   = DateTime.UtcNow
    });
});

// ─────────────────────────────── 5XX ERRORS ──────────────────────────────────
// Implementation: caller specifies the desired status code via ?code=.
// Returns Results.Json(..., statusCode: code) — ASP.NET Core writes the exact
// HTTP status line so ARR, CDN, or App Gateway sees the real code.

app.MapGet("/error/5xx", (int code = 500) =>
{
    code = new[] { 500, 501, 502, 503, 504, 505 }.Contains(code) ? code : 500;
    var messages = new Dictionary<int, string>
    {
        [500] = "Internal Server Error – simulated unhandled exception",
        [501] = "Not Implemented",
        [502] = "Bad Gateway – upstream dependency unavailable",
        [503] = "Service Unavailable – simulated overload",
        [504] = "Gateway Timeout – simulated upstream timeout",
        [505] = "HTTP Version Not Supported"
    };
    return Results.Json(
        new { code, message = messages[code], timestamp = DateTime.UtcNow },
        statusCode: code);
});

// ─────────────────────────────── 4XX ERRORS ──────────────────────────────────
// Implementation: same pattern as 5xx — Results.Json with caller-chosen status code.

app.MapGet("/error/4xx", (int code = 404) =>
{
    code = new[] { 400, 401, 403, 404, 405, 408, 409, 429 }.Contains(code) ? code : 404;
    var messages = new Dictionary<int, string>
    {
        [400] = "Bad Request – invalid input parameters",
        [401] = "Unauthorized – missing or invalid credentials",
        [403] = "Forbidden – insufficient permissions",
        [404] = "Not Found – resource does not exist",
        [405] = "Method Not Allowed",
        [408] = "Request Timeout",
        [409] = "Conflict",
        [429] = "Too Many Requests – rate limit exceeded"
    };
    return Results.Json(
        new { code, message = messages[code], timestamp = DateTime.UtcNow },
        statusCode: code);
});

// ─────────────────────────────── STORAGE I/O ─────────────────────────────────
// Implementation: writes `files` binary files of ~(mb/files) MB each to a temp
// directory on the local disk, then reads them all back and measures elapsed time.
// Useful for reproducing disk I/O bottlenecks or diagnosing storage quota issues.
// /storage/clean deletes all previously written temp files.

var storageDir = Path.Combine(Path.GetTempPath(), "reproapp_storage");
Directory.CreateDirectory(storageDir);

app.MapGet("/storage", async (int mb = 50, int files = 5) =>
{
    mb    = Math.Clamp(mb, 1, 500);
    files = Math.Clamp(files, 1, 50);
    var sw      = Stopwatch.StartNew();
    var written = new List<string>();
    var data    = new byte[mb * 1024 * 1024 / files];
    new Random().NextBytes(data);

    for (int i = 0; i < files; i++)
    {
        var path = Path.Combine(storageDir, $"repro_{Guid.NewGuid():N}.bin");
        await File.WriteAllBytesAsync(path, data);
        written.Add(path);
    }

    // Read them back
    long totalRead = 0;
    foreach (var p in written)
        totalRead += (await File.ReadAllBytesAsync(p)).Length;

    return Results.Ok(new
    {
        message      = $"Wrote & read {files} files × {mb / files} MB each",
        writtenFiles = files,
        totalWrittenMB = mb,
        totalReadMB  = totalRead / 1024 / 1024,
        elapsedMs    = sw.ElapsedMilliseconds,
        timestamp    = DateTime.UtcNow
    });
});

app.MapGet("/storage/clean", () =>
{
    int deleted = 0;
    foreach (var f in Directory.GetFiles(storageDir))
    {
        File.Delete(f);
        deleted++;
    }
    return Results.Ok(new { message = $"Deleted {deleted} temp files", timestamp = DateTime.UtcNow });
});

// ─────────────────────────────── RESTART ─────────────────────────────────────
// Implementation: fires IHostApplicationLifetime.StopApplication() from a background
// Task (500 ms delay so the HTTP response can be sent first). The process exits
// cleanly; App Service detects the exit and automatically restarts the worker process.

app.MapGet("/restart", async (IHostApplicationLifetime lifetime) =>
{
    _ = Task.Run(async () =>
    {
        await Task.Delay(500);
        lifetime.StopApplication();
    });
    return Results.Ok(new { message = "App is shutting down — App Service will restart it automatically", timestamp = DateTime.UtcNow });
});

// ─────────────────────────────── THREAD POOL STARVATION ──────────────────────
// Implementation: queues `threads` work items via ThreadPool.QueueUserWorkItem,
// each calling Thread.Sleep(duration * 1000) — a synchronous (blocking) wait.
// Because TP threads are occupied, new async continuations stall waiting for a
// free thread, reproducing the sync-over-async / starvation pattern.

app.MapGet("/threadpool", (int threads = 20, int duration = 20) =>
{
    threads  = Math.Clamp(threads, 1, 200);
    duration = Math.Clamp(duration, 1, 120);
    for (int i = 0; i < threads; i++)
    {
        ThreadPool.QueueUserWorkItem(_ => Thread.Sleep(duration * 1000));
    }
    ThreadPool.GetAvailableThreads(out int worker, out int io);
    return Results.Ok(new
    {
        message           = $"Queued {threads} blocking items for {duration} s",
        availableWorkerThreads = worker,
        availableIoThreads     = io,
        timestamp         = DateTime.UtcNow
    });
});

// ─────────────────────────────── MEMORY LEAK ─────────────────────────────────
// Implementation: appends byte[] allocations to a module-level static `leakList`.
// The GC cannot collect them while the list holds a live reference, simulating
// a classic managed memory leak (e.g., event handlers, static caches, event sourcing
// buffers that are never trimmed). /memleak/reset clears the list and forces GC.

var leakList = new List<byte[]>();

app.MapGet("/memleak", (int iterations = 100, int size = 1000) =>
{
    iterations = Math.Clamp(iterations, 1, 10_000);
    size       = Math.Clamp(size, 100, 100_000);
    for (int i = 0; i < iterations; i++)
        leakList.Add(new byte[size]);
    return Results.Ok(new
    {
        message         = $"Added {iterations} objects of {size} bytes each",
        totalObjects    = leakList.Count,
        approxLeakedMB  = (long)leakList.Count * size / 1024 / 1024,
        gcTotalMB       = GC.GetTotalMemory(false) / 1024 / 1024,
        timestamp       = DateTime.UtcNow
    });
});

app.MapGet("/memleak/reset", () =>
{
    leakList.Clear();
    GC.Collect(2, GCCollectionMode.Forced);
    return Results.Ok(new { message = "Leak list cleared and GC forced", timestamp = DateTime.UtcNow });
});

// ─────────────────────────────── GC PRESSURE ─────────────────────────────────
// Implementation: rapidly allocates byte[85_000] objects (just above the 85 KB
// Large Object Heap threshold) and immediately discards them. LOH objects skip
// Gen0/Gen1 and go straight to Gen2; the high allocation rate forces frequent
// blocking Gen2 GC pauses, visible as CPU spikes and latency jitter.

app.MapGet("/gc", async (int duration = 30) =>
{
    duration = Math.Clamp(duration, 1, 120);
    var sw   = Stopwatch.StartNew();
    long allocs = 0;
    while (sw.Elapsed.TotalSeconds < duration)
    {
        var tmp = new byte[85_000]; // LOH threshold
        tmp[0] = 1;
        allocs++;
        if (allocs % 1000 == 0)
            await Task.Yield();
    }
    return Results.Ok(new
    {
        message     = $"GC pressure test for {duration} s – {allocs:N0} LOH allocs",
        gcGen0      = GC.CollectionCount(0),
        gcGen1      = GC.CollectionCount(1),
        gcGen2      = GC.CollectionCount(2),
        timestamp   = DateTime.UtcNow
    });
});

// ─────────────────────────────── SNAT EXHAUSTION ─────────────────────────────
// Implementation: opens `connections` TcpClient connections to an external host
// (default: microsoft.com:443) and holds them open for `holdMs` ms before closing.
// Each outbound connection consumes one SNAT port. Azure App Service allocates
// ~128 SNAT ports per instance by default; once exhausted new outbound connections
// fail with ECONNREFUSED / SocketException, reproducing the SNAT exhaustion pattern.

app.MapGet("/snat", async (int connections = 100, string? host = "microsoft.com", int port = 443, int holdMs = 5000) =>
{
    connections = Math.Clamp(connections, 1, 500);
    holdMs      = Math.Clamp(holdMs, 500, 60_000);
    host        = string.IsNullOrWhiteSpace(host) ? "microsoft.com" : host;

    var opened  = 0;
    var failed  = 0;
    string? firstError = null;
    var sockets = new List<System.Net.Sockets.TcpClient>();

    for (int i = 0; i < connections; i++)
    {
        try
        {
            var tcp = new System.Net.Sockets.TcpClient();
            await tcp.ConnectAsync(host!, port);
            sockets.Add(tcp);
            opened++;
        }
        catch (Exception ex)
        {
            failed++;
            firstError ??= ex.Message;
            if (failed >= 3) break;
        }
    }

    await Task.Delay(holdMs);
    foreach (var s in sockets) try { s.Close(); } catch { }

    return Results.Ok(new
    {
        message   = failed > 0
            ? $"SNAT pressure: {opened} connections opened, {failed} failed (SNAT ports may be exhausted)"
            : $"Opened and held {opened} outbound TCP connections for {holdMs} ms",
        opened, failed, firstError, heldMs = holdMs,
        snatLimit = "Azure App Service default: ~128 SNAT ports per instance",
        timestamp = DateTime.UtcNow
    });
});

// ─────────────────────────────── STARTUP FAILURE ─────────────────────────────
// Implementation (/startup-fail): writes "startup-fail.flag" to AppContext.BaseDirectory,
// then calls Environment.Exit(1) after a 400 ms delay (so the HTTP response returns first).
// On the next cold-start, the flag check at the top of Program.cs throws before the
// Kestrel listener is registered → ANCM cannot forward the request and returns HTTP 500.30
// (ANCM In-Process Start Failure) on Windows. On Linux the container exits with code 1
// and App Service enters a restart loop.
//
// Implementation (/startup-fail): writes flag + schedules Environment.Exit after 600 ms
// (enough for the HTML response to be sent), returns a countdown page.
// The page counts down 30 s (the flag TTL), then polls GET /startup-fail/recover?ack=1
// every 5 s — the moment the app comes back up the poll succeeds, the flag is deleted,
// and the browser auto-redirects to /. The browser tab IS the recovery controller;
// no Kudu WebJob or external trigger needed.
//
// Implementation (/startup-fail/recover):
//   ?ack=1  → JSON {recovered, healthy} for the browser poller
//   (none)  → HTML countdown page for manual button / direct access

app.MapGet("/startup-fail", () =>
{
    var flag = Path.Combine(AppContext.BaseDirectory, "startup-fail.flag");
    File.WriteAllText(flag, DateTime.UtcNow.ToString("o"));
    var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
    _ = Task.Run(async () =>
    {
        await Task.Delay(600);   // headroom so HTML response is fully sent first
        Console.Error.WriteLine("[REPROAPP] startup-fail.flag written – exiting to trigger startup failure");
        Environment.Exit(1);
    });
    var platform = isWindows ? "Windows · HTTP\u00a0500.30 (ANCM startup failure)" : "Linux · container exit loop";
    var css = """
    body { font-family:'Segoe UI',sans-serif; background:#0f172a; color:#e2e8f0;
           display:flex; flex-direction:column; align-items:center; justify-content:center;
           min-height:100vh; margin:0; padding:24px; box-sizing:border-box; text-align:center; }
    h2   { margin:0 0 8px; font-size:1.4rem; }
    p    { margin:0 0 6px; color:#94a3b8; font-size:.9rem; }
    small{ color:#64748b; font-size:.8rem; display:block; margin-bottom:20px; }
    code { background:#1e293b; padding:2px 6px; border-radius:4px; font-size:.84rem; color:#67e8f9; }
    .ring-wrap { position:relative; width:120px; height:120px; margin:16px 0 12px; }
    svg  { transform:rotate(-90deg); }
    .track { fill:none; stroke:#1e293b; stroke-width:10; }
    .arc   { fill:none; stroke:#ef4444; stroke-width:10; stroke-linecap:round;
             stroke-dasharray:314; stroke-dashoffset:0; transition:stroke-dashoffset 1s linear; }
    .arc.ok{ stroke:#22c55e; }
    .num   { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
             font-size:2rem; font-weight:700; color:#ef4444; }
    .num.ok{ color:#22c55e; }
    .status{ font-size:.85rem; color:#60a5fa; min-height:1.4em; margin-top:8px; }
    .dot   { animation:blink 1.2s infinite; display:inline-block; }
    @keyframes blink{ 0%,100%{opacity:1}50%{opacity:.25} }
    a { color:#60a5fa; font-size:.82rem; }
    .recover-btn { display:inline-flex; align-items:center; gap:8px; margin-top:14px;
                   padding:10px 22px; background:#1e293b; border:1.5px solid #3b82f6;
                   border-radius:8px; color:#60a5fa; font-size:.9rem; text-decoration:none; cursor:pointer; }
    .recover-btn:hover { background:#334155; }
    footer.gh { margin-top:32px; font-size:.75rem; color:#64748b; text-align:center; line-height:2; }
    footer.gh a { font-size:.75rem; }
    """;
    var js = $@"
    var total=30, left=total;
    var arc=document.getElementById('arc'), numEl=document.getElementById('num'), st=document.getElementById('st');
    var btnLeft=document.getElementById('btnLeft'), recoverBtn=document.getElementById('recoverBtn');
    arc.style.strokeDashoffset='0';
    var timer=setInterval(function(){{
        left--;
        numEl.textContent=left;
        if(btnLeft) btnLeft.textContent=left;
        arc.style.strokeDashoffset=((total-left)/total*314).toString();
        if(left<=0){{ clearInterval(timer); beginPoll(); }}
    }},1000);
    function beginPoll(){{
        numEl.innerHTML='<span style=""font-size:1.4rem"">&#x1F504;</span>';
        arc.style.stroke='#3b82f6'; arc.style.transition='none'; arc.style.strokeDashoffset='0';
        if(recoverBtn){{ recoverBtn.innerHTML='&#x1F504; Polling for recovery&hellip;'; recoverBtn.removeAttribute('href'); }}
        poll();
    }}
    function poll(){{
        st.innerHTML='Polling <code>/startup-fail/recover</code><span class=""dot"">...</span>';
        fetch('/startup-fail/recover?ack=1')
            .then(function(r){{ return r.ok ? r.json() : Promise.reject(); }})
            .then(function(){{
                arc.classList.add('ok'); numEl.classList.add('ok');
                numEl.innerHTML='&#x2705;';
                st.innerHTML='Recovered! Redirecting to dashboard&hellip;';
                if(recoverBtn) recoverBtn.innerHTML='&#x2705; Recovered! Redirecting&hellip;';
                setTimeout(function(){{ window.location.href='/'; }},1500);
            }})
            .catch(function(){{ setTimeout(poll,5000); }});
    }}
";
    var html = $"""
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Startup Failure Triggered</title>
  <style>{css}</style>
</head>
<body>
  <h2>&#x1F4A5; Startup Failure Triggered</h2>
  <p><code>{platform}</code></p>
  <small>Flag TTL: 30 s &mdash; countdown runs, then this page polls until the app recovers.</small>
  <div class="ring-wrap">
    <svg viewBox="0 0 110 110" width="120" height="120">
      <circle class="track" cx="55" cy="55" r="50"/>
      <circle class="arc" cx="55" cy="55" r="50" id="arc"/>
    </svg>
    <div class="num" id="num">30</div>
  </div>
  <div class="status" id="st">App is crashing&hellip;</div>
  <a href="/startup-fail/recover" id="recoverBtn" class="recover-btn">&#x21A9; Recover now &mdash; <span id="btnLeft">30</span>s remaining</a>
  <p style="margin-top:8px"><a href="/">&#x2302; Dashboard</a></p>
  <footer class="gh">
    Maintained by <a href="mailto:jofernandes@microsoft.com">jofernandes@microsoft.com</a><br/>
    <a href="https://github.com/Cypheratom/azure-appservice-repro-tool" target="_blank">&#x1F4E6; github.com/Cypheratom/azure-appservice-repro-tool</a>
  </footer>
  <script>{js}</script>
</body>
</html>
""";
    return Results.Content(html, "text/html");
});

app.MapGet("/startup-fail/recover", (HttpRequest req) =>
{
    var flag      = Path.Combine(AppContext.BaseDirectory, "startup-fail.flag");
    var recovered = File.Exists(flag);
    if (recovered) File.Delete(flag);

    // JSON mode for the browser poller (?ack=1)
    if (req.Query.ContainsKey("ack"))
        return Results.Json(new { recovered, healthy = true });

    var heading = recovered ? "&#x2705; Flag deleted &mdash; recovering&hellip;" : "&#x2139;&#xFE0F; No flag found &mdash; app was already healthy";
    var subtext = recovered
        ? "The <code>startup-fail.flag</code> has been deleted. The app will recover on its next restart. Redirecting to the dashboard in <strong><span id='t'>30</span>s</strong>&hellip;"
        : "Nothing to clean up. Redirecting to the dashboard in <strong><span id='t'>5</span>s</strong>&hellip;";
    var seconds = recovered ? 30 : 5;

    // CSS and JS extracted to avoid literal-brace conflicts with raw string interpolation
    var style = """
    body { font-family:'Segoe UI',sans-serif; background:#0f172a; color:#e2e8f0;
           display:flex; flex-direction:column; align-items:center; justify-content:center;
           min-height:100vh; margin:0; padding:24px; box-sizing:border-box; }
    h2   { margin:0 0 10px; font-size:1.4rem; }
    p    { margin:0 0 24px; color:#94a3b8; font-size:.95rem; text-align:center; }
    code { background:#1e293b; padding:2px 6px; border-radius:4px; font-size:.88rem; color:#67e8f9; }
    .ring-wrap { position:relative; width:120px; height:120px; margin-bottom:28px; }
    svg  { transform:rotate(-90deg); }
    .track { fill:none; stroke:#1e293b; stroke-width:10; }
    .arc   { fill:none; stroke:#3b82f6; stroke-width:10; stroke-linecap:round;
             stroke-dasharray:314; stroke-dashoffset:0; transition:stroke-dashoffset 1s linear; }
    .num   { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
             font-size:2rem; font-weight:700; color:#e2e8f0; }
    .skip  { margin-top:8px; font-size:.85rem; }
    .skip a { color:#60a5fa; text-decoration:none; }
    .skip a:hover { text-decoration:underline; }
""";
    // $@"..." (verbatim interpolated) — {{ and }} are literal braces, {seconds} is C# interpolation
    var script = $@"
    var total = {seconds}, left = total;
    var arc = document.getElementById('arc');
    var tEl = document.getElementById('t');
    arc.style.strokeDashoffset = '0';
    var timer = setInterval(function() {{
      left--;
      tEl.textContent = left;
      arc.style.strokeDashoffset = ((total - left) / total * 314).toString();
      if (left <= 0) {{ clearInterval(timer); window.location.href = '/'; }}
    }}, 1000);
";
    var html = $"""
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Recovering&hellip;</title>
  <style>{style}</style>
</head>
<body>
  <div class="ring-wrap">
    <svg viewBox="0 0 110 110" width="120" height="120">
      <circle class="track" cx="55" cy="55" r="50"/>
      <circle class="arc"   cx="55" cy="55" r="50" id="arc"/>
    </svg>
    <div class="num"><span id="t">{seconds}</span></div>
  </div>
  <h2>{heading}</h2>
  <p>{subtext}</p>
  <div class="skip"><a href="/">&#x23E9; Skip &mdash; go to dashboard now</a></div>
  <footer style="margin-top:32px;font-size:.75rem;color:#64748b;text-align:center;line-height:2">
    Maintained by <a href="mailto:jofernandes@microsoft.com" style="color:#60a5fa;text-decoration:none">jofernandes@microsoft.com</a><br/>
    <a href="https://github.com/Cypheratom/azure-appservice-repro-tool" target="_blank" style="color:#60a5fa;text-decoration:none">&#x1F4E6; github.com/Cypheratom/azure-appservice-repro-tool</a>
  </footer>
  <script>{script}</script>
</body>
</html>
""";
    return Results.Content(html, "text/html");
});

// ─────────────────────────────── OOM / LOW MEMORY ────────────────────────────
// Implementation: allocates memory in 50 MB chunks up to `mb` MB, touching every
// 4 KB page (buf[i] = 1) to force the OS to actually commit each page rather than
// lazy-mapping it. On Linux containers with a cgroup memory limit, the kernel OOM
// killer terminates the process. On CLR the GC eventually throws OutOfMemoryException.
// Unlike /memory, all chunks are released in the finally block after this response.

app.MapGet("/oom", (int mb = 512) =>
{
    mb = Math.Clamp(mb, 100, 4096);
    var chunks    = new List<byte[]>();
    var allocated = 0;
    try
    {
        while (allocated < mb)
        {
            int chunkMb = Math.Min(50, mb - allocated);
            var buf = new byte[chunkMb * 1024 * 1024];
            for (int i = 0; i < buf.Length; i += 4096) buf[i] = 1;
            chunks.Add(buf);
            allocated += chunkMb;
        }
        return Results.Ok(new
        {
            message      = $"Allocated {allocated} MB – OOM killer may fire if near the container memory limit",
            allocatedMB  = allocated,
            workingSetMB = Process.GetCurrentProcess().WorkingSet64 / 1024 / 1024,
            note         = "Memory released after this response – use /memory to hold it",
            timestamp    = DateTime.UtcNow
        });
    }
    catch (OutOfMemoryException ex)
    {
        return Results.Json(new
        {
            message     = $"OutOfMemoryException after {allocated} MB – system memory exhausted",
            allocatedMB = allocated,
            error       = ex.Message,
            timestamp   = DateTime.UtcNow
        }, statusCode: 503);
    }
    finally { chunks.Clear(); GC.Collect(); }
});

app.Run();
