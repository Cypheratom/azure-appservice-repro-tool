package com.reproapp;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.http.MediaType;

@RestController
public class DashboardController {

    @GetMapping(value = "/", produces = MediaType.TEXT_HTML_VALUE)
    public String dashboard() {
        String osName    = System.getProperty("os.name", "Unknown");
        String javaVer   = "Java " + System.getProperty("java.version", "17");
        boolean isLinux  = osName.toLowerCase().contains("linux");
        String linuxCards = isLinux ? """
    <div class="card">
      <h3>&#x1F433; Container Startup Failure</h3>
      <p>Force process exit (code 1) &ndash; App Service enters a restart loop.<br/><em>Check Container logs in Diagnose &amp; Solve</em></p>
      <a class="btn danger" href="/startup-fail" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Calls <code>System.exit(1)</code> from a background thread after 500 ms (so the response returns first). App Service detects exit code 1 and enters a container restart loop. Check <em>Container logs</em> in Diagnose &amp; Solve.</p></details>
    </div>
    <div class="card">
      <h3>&#x1F9E0; OOM / Low Memory</h3>
      <p>Allocate until OOM killer fires or JVM throws OutOfMemoryError.<br/>Param: <code>?mb=512</code></p>
      <a class="btn danger" href="/oom?mb=512" target="_blank">512 MB</a>
      <a class="btn danger" href="/oom?mb=1024" target="_blank">1 GB</a>
      <details class="how"><summary>How it works</summary><p>Allocates <code>byte[]</code> in 50 MB chunks touching every page to force JVM heap commitment. Throws <code>OutOfMemoryError</code> when the heap limit is hit; on Linux the OOM killer may fire for native memory. All chunks are freed in <code>finally</code>.</p></details>
    </div>
""" : "";
        return """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Azure App Service Repro Tool – Java</title>
  <style>
    body { font-family:'Segoe UI',sans-serif; background:#f0f2f5; margin:0; padding:24px; }
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
           background:#0078d4; color:#fff; cursor:pointer; font-size:.9rem; text-decoration:none; margin:2px; }
    .btn:hover{ background:#005a9e; }
    .btn.danger { background:#c50f1f; }
    .btn.warn   { background:#f7630c; }
    details.how { margin-top:10px; padding-top:8px; border-top:1px solid #f0f0f0; }
    details.how summary { cursor:pointer; font-size:.76rem; color:#999; user-select:none; }
    details.how summary:hover { color:#666; }
    details.how p { margin:6px 0 0; font-size:.76rem; color:#777; line-height:1.5; }
    details.how code { font-size:.73rem; background:#f0f2f5; padding:1px 4px; border-radius:3px; color:#0078d4; }
  </style>
</head>
<body>
  <h1>🔧 Azure App Service Repro Tool</h1>
  <div class="sub">
    <span class="badge badge-fw">%s / Spring Boot</span>
    <span class="badge badge-os">%s</span>
    <span class="badge badge-env">Simulates common customer-reported issues</span>
  </div>
  <div class="grid">

    <div class="card">
      <h3>🐢 Slow Response</h3>
      <p><code>Thread.sleep()</code> blocks the handler thread.<br/>Param: <code>?delay=5000</code> (ms)</p>
      <a class="btn warn" href="/slow?delay=5000" target="_blank">5 s</a>
      <a class="btn warn" href="/slow?delay=30000" target="_blank">30 s</a>
      <details class="how"><summary>How it works</summary><p><code>Thread.sleep(delay)</code> blocks the Spring MVC handler thread for the full duration. The servlet container’s thread-pool thread is entirely occupied — reproducing a slow-upstream or long-polling scenario.</p></details>
    </div>

    <div class="card">
      <h3>🔥 High CPU</h3>
      <p>Spin math workload across all available processors.<br/>Param: <code>?duration=30</code> (s)</p>
      <a class="btn danger" href="/cpu?duration=30" target="_blank">30 s</a>
      <details class="how"><summary>How it works</summary><p>Submits one <code>Runnable</code> per <code>Runtime.getRuntime().availableProcessors()</code>, each spinning <code>Math.sqrt()</code> in a tight loop — saturating all CPU cores for <code>duration</code> seconds.</p></details>
    </div>

    <div class="card">
      <h3>💾 High Memory</h3>
      <p>Allocate and hold large byte arrays in the JVM heap.<br/>Param: <code>?mb=300</code></p>
      <a class="btn danger" href="/memory?mb=300" target="_blank">300 MB</a>
      <a class="btn" href="/memory/free" target="_blank">Free</a>
      <details class="how"><summary>How it works</summary><p>Allocates <code>byte[mb × 1 MB]</code> arrays held in a synchronized <code>heldMemory</code> list. JVM GC cannot collect while the list holds a strong reference. <code>/memory/free</code> clears the list and hints GC.</p></details>
    </div>

    <div class="card">
      <h3>⏱ High Latency</h3>
      <p>Sequential <code>Thread.sleep()</code> calls in a loop.<br/>Param: <code>?requests=50&amp;latency=200</code></p>
      <a class="btn warn" href="/latency?requests=50&latency=200" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Runs <code>requests</code> sequential <code>Thread.sleep(latency)</code> calls — total response time ≈ requests × latency ms. Simulates cascading upstream delays.</p></details>
    </div>

    <div class="card">
      <h3>💥 HTTP 5xx Errors</h3>
      <p>Return a specific 5xx status code.</p>
      <a class="btn danger" href="/error/5xx?code=500" target="_blank">500</a>
      <a class="btn danger" href="/error/5xx?code=502" target="_blank">502</a>
      <a class="btn danger" href="/error/5xx?code=503" target="_blank">503</a>
      <details class="how"><summary>How it works</summary><p>Returns <code>ResponseEntity.status(code).body(...)</code> — Spring MVC writes the exact HTTP status line so reverse proxies, CDNs, and Application Gateway see the real code.</p></details>
    </div>

    <div class="card">
      <h3>🚫 HTTP 4xx Errors</h3>
      <p>Return a specific 4xx status code.</p>
      <a class="btn warn" href="/error/4xx?code=404" target="_blank">404</a>
      <a class="btn warn" href="/error/4xx?code=401" target="_blank">401</a>
      <a class="btn warn" href="/error/4xx?code=429" target="_blank">429</a>
      <details class="how"><summary>How it works</summary><p>Same as 5xx — <code>ResponseEntity.status(code)</code> with the caller-chosen code. Useful for auth, rate-limiting, or routing issues in upstream middleware.</p></details>
    </div>

    <div class="card">
      <h3>📁 Storage I/O</h3>
      <p>Write &amp; read temp files on the local disk.<br/>Param: <code>?mb=50&amp;files=5</code></p>
      <a class="btn" href="/storage?mb=50&files=5" target="_blank">Trigger</a>
      <a class="btn" href="/storage/clean" target="_blank">Clean</a>
      <details class="how"><summary>How it works</summary><p>Writes <code>files</code> binary temp files × (mb÷files) MB each to a temp directory, then reads them all back and measures throughput. Useful for diagnosing disk I/O bottlenecks or storage quota issues.</p></details>
    </div>

    <div class="card">
      <h3>♻️ App Restart</h3>
      <p>Call <code>System.exit(1)</code> – App Service auto-restarts the process.</p>
      <a class="btn danger" href="/restart" target="_blank">Restart</a>
      <details class="how"><summary>How it works</summary><p>Calls <code>System.exit(1)</code> from a background thread after 500 ms (so the HTTP response is sent first). App Service detects the exit and automatically restarts the process.</p></details>
    </div>

    <div class="card">
      <h3>🧵 Thread Pool Saturation</h3>
      <p>Queue blocking tasks to saturate the thread pool.<br/>Param: <code>?threads=20&amp;duration=20</code></p>
      <a class="btn danger" href="/threadpool?threads=20&duration=20" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Submits <code>threads</code> tasks to an <code>ExecutorService</code>, each calling <code>Thread.sleep(duration s)</code>. With all TP threads occupied, Spring MVC request processing stalls — reproducing thread-pool saturation and request queuing.</p></details>
    </div>

    <div class="card">
      <h3>📈 Memory Leak</h3>
      <p>Accumulate unreleased byte arrays (simulated Java heap leak).<br/>Param: <code>?iterations=100&amp;size=1000</code></p>
      <a class="btn danger" href="/memleak?iterations=100&size=1000" target="_blank">Trigger</a>
      <a class="btn" href="/memleak/reset" target="_blank">Reset</a>
      <details class="how"><summary>How it works</summary><p>Appends <code>byte[]</code> arrays to a <code>static leakList</code>. JVM GC cannot collect while the list holds a strong reference — simulates classloader leaks, static caches, or unbounded event queues. <code>/memleak/reset</code> clears it.</p></details>
    </div>

    <div class="card">
      <h3>&#127760; SNAT Exhaustion</h3>
      <p>Open many outbound TCP connections to consume SNAT ports (limit ~128/instance).<br/>Param: <code>?connections=100&amp;holdMs=5000</code></p>
      <a class="btn warn" href="/snat?connections=100&holdMs=5000" target="_blank">100 connections</a>
      <a class="btn danger" href="/snat?connections=200&holdMs=10000" target="_blank">200 connections</a>
      <details class="how"><summary>How it works</summary><p>Opens <code>connections</code> <code>Socket.connect()</code> connections to an external host and holds them for <code>holdMs</code> ms. Each consumes one SNAT port. App Service default: ≈128 SNAT ports per instance; exhaustion causes <code>SocketException</code>.</p></details>
    </div>

    %s
    <div class="card">
      <h3>&#128202; App Info</h3>
      <p>Show JVM / OS info and heap counters.</p>
      <a class="btn" href="/info" target="_blank">View</a>
      <a class="btn" href="/health" target="_blank">Health</a>
      <a class="btn" href="/actuator/health" target="_blank">Actuator</a>
    </div>

  </div>
  <div style="font-size:.78rem;color:#888;margin-top:20px;padding-top:12px;border-top:1px solid #ddd;">
    App: <strong id="appName"></strong> &nbsp;|&nbsp;
    Host: <strong id="host"></strong> &nbsp;|&nbsp;
    PID: <strong id="pid"></strong>
    <script>
      fetch('/info').then(r=>r.json()).then(d=>{
        document.getElementById('appName').textContent = d.appName || 'ReproApp-Java';
        document.getElementById('host').textContent    = d.machineName || '-';
        document.getElementById('pid').textContent     = d.pid || '-';
      }).catch(()=>{});
    </script>
  </div>
  <footer style="text-align:center;margin-top:24px;padding:12px 0;font-size:.78rem;color:#888">
    Maintained by <a href="mailto:jofernandes@microsoft.com" style="color:#0078d4;text-decoration:none">jofernandes@microsoft.com</a><br/>
    <a href="https://github.com/Cypheratom/azure-appservice-repro-tool" target="_blank" style="color:#0078d4;text-decoration:none">&#x1F4E6; github.com/Cypheratom/azure-appservice-repro-tool</a>
  </footer>
</body>
</html>
""".formatted(javaVer, osName, linuxCards);
    }
}
