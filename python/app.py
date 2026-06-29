"""
Azure App Service Repro Tool – Python / Flask
Simulates common customer-reported App Service issues.
"""

import gc
import os
import sys
import time
import math
import uuid
import threading
import tempfile
import psutil
import platform
from datetime import datetime, timezone
from flask import Flask, request, jsonify, render_template_string

app = Flask(__name__)

# ─────────────────────── shared state ────────────────────────
_held_memory: list[bytes] = []
_mem_lock = threading.Lock()
_leak_list: list[bytes] = []

# ─────────────────────── helpers ─────────────────────────────

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _clamp(val, lo, hi):
    return max(lo, min(hi, int(val)))

# ─────────────────────── DASHBOARD ───────────────────────────

DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <title>Azure App Service Repro Tool – Python</title>
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
    <span class="badge badge-fw">Python {{ py_version }} / Flask</span>
    <span class="badge badge-os">{{ os_name }}</span>
    <span class="badge badge-env">Simulates common customer-reported issues</span>
  </div>
  <div class="grid">
    <div class="card">
      <h3>🐢 Slow Response</h3><p>Block with <code>time.sleep()</code><br/>Param: <code>?delay=5000</code> (ms)</p>
      <a class="btn warn" href="/slow?delay=5000" target="_blank">5 s</a>
      <a class="btn warn" href="/slow?delay=30000" target="_blank">30 s</a>
      <details class="how"><summary>How it works</summary><p><code>time.sleep(delay / 1000)</code> blocks the WSGI worker thread for the full duration. On Gunicorn the worker is entirely occupied; other requests must wait for a free worker or timeout.</p></details>
    </div>
    <div class="card">
      <h3>🔥 High CPU</h3><p>Spin a tight math loop.<br/>Param: <code>?duration=30</code> (s)</p>
      <a class="btn danger" href="/cpu?duration=30" target="_blank">30 s</a>
      <details class="how"><summary>How it works</summary><p>Spawns <code>cpu_count()</code> daemon threads each spinning <code>math.sqrt()</code> until a stop event fires — saturating all CPU cores for <code>duration</code> seconds.</p></details>
    </div>
    <div class="card">
      <h3>💾 High Memory</h3><p>Allocate bytes and hold them.<br/>Param: <code>?mb=200</code></p>
      <a class="btn danger" href="/memory?mb=200" target="_blank">200 MB</a>
      <a class="btn" href="/memory/free" target="_blank">Free</a>
      <details class="how"><summary>How it works</summary><p>Allocates <code>bytearray(mb × 1 MB)</code>, writes every 4 KB page to commit physical RAM, then holds it in a module-level list. Python GC cannot reclaim while the list holds a reference. <code>/memory/free</code> clears and collects.</p></details>
    </div>
    <div class="card">
      <h3>⏱ High Latency</h3><p>Sequential async-like delays.<br/>Param: <code>?requests=50&latency=200</code></p>
      <a class="btn warn" href="/latency?requests=50&latency=200" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Runs <code>requests</code> sequential <code>time.sleep(latency ms)</code> calls. Total response time ≈ requests × latency ms — simulates cascading upstream delays.</p></details>
    </div>
    <div class="card">
      <h3>💥 HTTP 5xx</h3><p>Return a 5xx status code.</p>
      <a class="btn danger" href="/error/5xx?code=500" target="_blank">500</a>
      <a class="btn danger" href="/error/5xx?code=502" target="_blank">502</a>
      <a class="btn danger" href="/error/5xx?code=503" target="_blank">503</a>
      <details class="how"><summary>How it works</summary><p>Flask <code>return jsonify(...), code</code> writes the exact HTTP status line — reverse proxies, CDNs, and Application Gateway all see the real code.</p></details>
    </div>
    <div class="card">
      <h3>🚫 HTTP 4xx</h3><p>Return a 4xx status code.</p>
      <a class="btn warn" href="/error/4xx?code=404" target="_blank">404</a>
      <a class="btn warn" href="/error/4xx?code=401" target="_blank">401</a>
      <a class="btn warn" href="/error/4xx?code=429" target="_blank">429</a>
      <details class="how"><summary>How it works</summary><p>Same as 5xx — Flask writes the exact HTTP status line. Useful for auth, rate-limiting, or routing issues in upstream middleware.</p></details>
    </div>
    <div class="card">
      <h3>📁 Storage I/O</h3><p>Write &amp; read temp files.<br/>Param: <code>?mb=50&files=10</code></p>
      <a class="btn" href="/storage?mb=50&files=10" target="_blank">Trigger</a>
      <a class="btn" href="/storage/clean" target="_blank">Clean</a>
      <details class="how"><summary>How it works</summary><p>Writes <code>files</code> random-content binary files of ≈(mb÷files) MB each to a temp directory, then reads them all back. Useful for diagnosing disk I/O bottlenecks or storage quota issues.</p></details>
    </div>
    <div class="card">
      <h3>♻️ Restart</h3><p>Force <code>sys.exit(1)</code> – App Service restarts.</p>
      <a class="btn danger" href="/restart" target="_blank">Restart</a>
      <details class="how"><summary>How it works</summary><p>Calls <code>os._exit(1)</code> from a daemon thread after 500 ms (so the HTTP response is sent first). App Service detects the exit and automatically restarts the process.</p></details>
    </div>
    <div class="card">
      <h3>📈 Memory Leak</h3><p>Grow a module-level list.<br/>Param: <code>?iterations=100&size=1000</code></p>
      <a class="btn danger" href="/memleak?iterations=100&size=1000" target="_blank">Trigger</a>
      <a class="btn" href="/memleak/reset" target="_blank">Reset</a>
      <details class="how"><summary>How it works</summary><p>Appends <code>bytes(size)</code> objects to a module-level list <code>_leak_list</code>. Python GC cannot collect while the list holds a reference — simulates unbounded caches, event queues, or log buffers. <code>/memleak/reset</code> clears and collects.</p></details>
    </div>
    <div class="card">
      <h3>&#127760; SNAT Exhaustion</h3><p>Open many outbound TCP connections to consume SNAT ports (limit ~128/instance).<br/>Param: <code>?connections=100&holdMs=5000</code></p>
      <a class="btn warn" href="/snat?connections=100&holdMs=5000" target="_blank">100 connections</a>
      <a class="btn danger" href="/snat?connections=200&holdMs=10000" target="_blank">200 connections</a>
      <details class="how"><summary>How it works</summary><p>Opens <code>connections</code> TCP sockets via <code>socket.create_connection()</code> to an external host and holds them for <code>holdMs</code> ms. Each consumes one SNAT port. App Service default: ≈128 SNAT ports per instance; exhaustion causes <code>ConnectionRefusedError</code>.</p></details>
    </div>
    {% if os_name == 'Linux' %}
    <div class="card">
      <h3>&#x1F433; Container Startup Failure</h3><p>Force process exit (code 1) &ndash; App Service enters a restart loop.<br/><em>Check Container logs in Diagnose &amp; Solve</em></p>
      <a class="btn danger" href="/startup-fail" target="_blank">Trigger</a>
      <details class="how"><summary>How it works</summary><p>Calls <code>os._exit(1)</code> in a daemon thread after 300 ms (so the response is sent first). App Service detects exit code 1 and enters a container restart loop. Check <em>Container logs</em> in Diagnose &amp; Solve for details.</p></details>
    </div>
    <div class="card">
      <h3>&#x1F9E0; OOM / Low Memory</h3><p>Allocate until OOM killer fires or MemoryError is raised.<br/>Param: <code>?mb=512</code></p>
      <a class="btn danger" href="/oom?mb=512" target="_blank">512 MB</a>
      <a class="btn danger" href="/oom?mb=1024" target="_blank">1 GB</a>
      <details class="how"><summary>How it works</summary><p>Allocates <code>bytearray</code> in 50 MB chunks touching every 4 KB page. When the cgroup limit is hit, the Linux OOM killer fires; otherwise Python raises <code>MemoryError</code>. All memory is freed in <code>finally</code> after the response.</p></details>
    </div>
    {% endif %}
    <div class="card">
      <h3>&#128202; App Info</h3><p>Show runtime / environment info.</p>
      <a class="btn" href="/info" target="_blank">View</a>
      <a class="btn" href="/health" target="_blank">Health</a>
    </div>
  </div>
  <footer style="text-align:center;margin-top:24px;padding:12px 0;font-size:.78rem;color:#888">
    Maintained by <a href="mailto:jofernandes@microsoft.com" style="color:#0078d4;text-decoration:none">jofernandes@microsoft.com</a><br/>
    <a href="https://github.com/Cypheratom/azure-appservice-repro-tool" target="_blank" style="color:#0078d4;text-decoration:none">&#x1F4E6; github.com/Cypheratom/azure-appservice-repro-tool</a>
  </footer>
</body>
</html>
"""


@app.route("/")
def index():
    return render_template_string(
        DASHBOARD_HTML,
        os_name=platform.system(),
        py_version=f"{sys.version_info.major}.{sys.version_info.minor}",
    )


# ─────────────────────── HEALTH ──────────────────────────────

@app.route("/health")
def health():
    return jsonify(status="healthy", timestamp=_now())


# ─────────────────────── INFO ────────────────────────────────

@app.route("/info")
def info():
    proc = psutil.Process(os.getpid())
    return jsonify(
        machineName=platform.node(),
        pid=os.getpid(),
        framework=f"Python {sys.version}",
        os=platform.platform(),
        processorCount=os.cpu_count(),
        workingSetMB=proc.memory_info().rss // 1024 // 1024,
        timestamp=_now(),
        appName="ReproApp-Python",
    )


# ─────────────────────── SLOW ────────────────────────────────

@app.route("/slow")
def slow():
    delay = _clamp(request.args.get("delay", 5000), 100, 120_000)
    time.sleep(delay / 1000.0)
    return jsonify(message=f"Responded after {delay} ms", timestamp=_now())


# ─────────────────────── HIGH CPU ────────────────────────────

def _cpu_worker(stop_event):
    x = 0.0
    while not stop_event.is_set():
        x += math.sqrt(x * 3.14159 + 1)


@app.route("/cpu")
def cpu():
    duration = _clamp(request.args.get("duration", 30), 1, 300)
    cpus = os.cpu_count() or 1
    stop = threading.Event()
    workers = [threading.Thread(target=_cpu_worker, args=(stop,)) for _ in range(cpus)]
    for w in workers:
        w.daemon = True
        w.start()
    time.sleep(duration)
    stop.set()
    for w in workers:
        w.join(timeout=2)
    return jsonify(message=f"CPU stress {duration} s on {cpus} threads", timestamp=_now())


# ─────────────────────── HIGH MEMORY ─────────────────────────

@app.route("/memory")
def memory():
    mb = _clamp(request.args.get("mb", 200), 1, 1500)
    buf = bytearray(mb * 1024 * 1024)
    for i in range(0, len(buf), 4096):
        buf[i] = 1
    with _mem_lock:
        _held_memory.append(bytes(buf))
    total = sum(len(b) for b in _held_memory) // 1024 // 1024
    return jsonify(message=f"Allocated {mb} MB", totalHeldMB=total, timestamp=_now())


@app.route("/memory/free")
def memory_free():
    with _mem_lock:
        count = len(_held_memory)
        _held_memory.clear()
    gc.collect()
    return jsonify(message=f"Released {count} allocations", timestamp=_now())


# ─────────────────────── LATENCY ─────────────────────────────

@app.route("/latency")
def latency():
    n       = _clamp(request.args.get("requests", 50), 1, 500)
    lat_ms  = _clamp(request.args.get("latency", 200), 10, 10_000)
    start   = time.perf_counter()
    for _ in range(n):
        time.sleep(lat_ms / 1000.0)
    elapsed = int((time.perf_counter() - start) * 1000)
    return jsonify(
        message=f"{n} calls × {lat_ms} ms",
        totalElapsedMs=elapsed,
        timestamp=_now(),
    )


# ─────────────────────── 5XX ERRORS ──────────────────────────

_5xx_messages = {
    500: "Internal Server Error – simulated",
    501: "Not Implemented",
    502: "Bad Gateway",
    503: "Service Unavailable – overloaded",
    504: "Gateway Timeout",
}


@app.route("/error/5xx")
def error_5xx():
    code = _clamp(request.args.get("code", 500), 500, 599)
    if code not in _5xx_messages:
        code = 500
    return jsonify(code=code, message=_5xx_messages[code], timestamp=_now()), code


# ─────────────────────── 4XX ERRORS ──────────────────────────

_4xx_messages = {
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    408: "Request Timeout",
    409: "Conflict",
    429: "Too Many Requests – rate limit exceeded",
}


@app.route("/error/4xx")
def error_4xx():
    code = _clamp(request.args.get("code", 404), 400, 499)
    if code not in _4xx_messages:
        code = 404
    return jsonify(code=code, message=_4xx_messages[code], timestamp=_now()), code


# ─────────────────────── STORAGE I/O ─────────────────────────

_STORAGE_DIR = os.path.join(tempfile.gettempdir(), "reproapp_storage")
os.makedirs(_STORAGE_DIR, exist_ok=True)


@app.route("/storage")
def storage():
    mb    = _clamp(request.args.get("mb", 50), 1, 500)
    files = _clamp(request.args.get("files", 5), 1, 50)
    chunk_size = (mb * 1024 * 1024) // files
    data  = os.urandom(chunk_size)
    start = time.perf_counter()
    written = []
    for _ in range(files):
        path = os.path.join(_STORAGE_DIR, f"repro_{uuid.uuid4().hex}.bin")
        with open(path, "wb") as f:
            f.write(data)
        written.append(path)
    total_read = 0
    for p in written:
        with open(p, "rb") as f:
            total_read += len(f.read())
    elapsed = int((time.perf_counter() - start) * 1000)
    return jsonify(
        message=f"Wrote & read {files} files",
        totalWrittenMB=mb,
        totalReadMB=total_read // 1024 // 1024,
        elapsedMs=elapsed,
        timestamp=_now(),
    )


@app.route("/storage/clean")
def storage_clean():
    deleted = 0
    for f in os.listdir(_STORAGE_DIR):
        os.remove(os.path.join(_STORAGE_DIR, f))
        deleted += 1
    return jsonify(message=f"Deleted {deleted} temp files", timestamp=_now())


# ─────────────────────── RESTART ─────────────────────────────

@app.route("/restart")
def restart():
    def _exit():
        time.sleep(0.5)
        os._exit(1)
    threading.Thread(target=_exit, daemon=True).start()
    return jsonify(message="App restarting – App Service will bring it back", timestamp=_now())


# ─────────────────────── MEMORY LEAK ─────────────────────────

@app.route("/memleak")
def memleak():
    iterations = _clamp(request.args.get("iterations", 100), 1, 10_000)
    size       = _clamp(request.args.get("size", 1000), 100, 100_000)
    for _ in range(iterations):
        _leak_list.append(b"\x00" * size)
    approx_mb = len(_leak_list) * size // 1024 // 1024
    return jsonify(
        message=f"Added {iterations} objects × {size} bytes",
        totalObjects=len(_leak_list),
        approxLeakedMB=approx_mb,
        timestamp=_now(),
    )


@app.route("/memleak/reset")
def memleak_reset():
    _leak_list.clear()
    gc.collect()
    return jsonify(message="Leak list cleared", timestamp=_now())


# ─────────────────────── SNAT EXHAUSTION ────────────────────

@app.route("/snat")
def snat():
    import socket as _socket
    connections = _clamp(request.args.get("connections", 100), 1, 500)
    host        = request.args.get("host", "microsoft.com")
    port        = _clamp(request.args.get("port", 443), 1, 65535)
    hold_ms     = _clamp(request.args.get("holdMs", 5000), 500, 60000)
    opened, failed, first_error, socks = 0, 0, None, []
    for _ in range(connections):
        try:
            s = _socket.create_connection((host, port), timeout=5)
            socks.append(s)
            opened += 1
        except Exception as e:
            failed += 1
            if first_error is None: first_error = str(e)
            if failed >= 3: break
    time.sleep(hold_ms / 1000.0)
    for s in socks:
        try: s.close()
        except: pass
    return jsonify(
        opened=opened, failed=failed, firstError=first_error, heldMs=hold_ms,
        message=f"SNAT pressure: {opened} opened, {failed} failed" if failed else f"Opened and held {opened} TCP connections",
        snatLimit="Azure App Service: ~128 SNAT ports per instance by default",
        timestamp=_now()
    )


# ─────────────────────── CONTAINER STARTUP FAILURE ───────────

@app.route("/startup-fail")
def startup_fail():
    def _crash():
        time.sleep(0.3)
        import sys
        print("[REPROAPP] Simulated container startup failure", file=sys.stderr, flush=True)
        os._exit(1)
    threading.Thread(target=_crash, daemon=True).start()
    return jsonify(
        message="Container will exit with code 1 - App Service will attempt restart",
        note="Check Container logs in Diagnose & Solve for startup failure details",
        timestamp=_now()
    )


# ─────────────────────── OOM / LOW MEMORY ────────────────────

@app.route("/oom")
def oom():
    mb     = _clamp(request.args.get("mb", 512), 100, 4096)
    chunks = []
    allocated = 0
    try:
        while allocated < mb:
            chunk_mb = min(50, mb - allocated)
            buf = bytearray(chunk_mb * 1024 * 1024)
            for i in range(0, len(buf), 4096): buf[i] = 0xFF
            chunks.append(buf)
            allocated += chunk_mb
        return jsonify(
            message=f"Allocated {allocated} MB – OOM killer may fire if near container memory limit",
            allocatedMB=allocated,
            note="Memory released after this response – use /memory to hold it",
            timestamp=_now()
        )
    except MemoryError as e:
        return jsonify(
            message=f"MemoryError after {allocated} MB – system memory exhausted",
            allocatedMB=allocated, error=str(e), timestamp=_now()
        ), 503
    finally:
        chunks.clear()


# ─────────────────────── ENTRY POINT ─────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    app.run(host="0.0.0.0", port=port)
