package com.reproapp;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.io.*;
import java.net.*;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

@RestController
public class ReproController {

    // ──────────────────── shared state ────────────────────────────
    private final List<byte[]>   heldMemory = Collections.synchronizedList(new ArrayList<>());
    private final List<byte[]>   leakList   = Collections.synchronizedList(new ArrayList<>());
    private static final Path    STORAGE_DIR;

    static {
        try {
            STORAGE_DIR = Files.createTempDirectory("reproapp_storage");
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    // ──────────────────── HEALTH ───────────────────────────────────

    @GetMapping("/health")
    public Map<String, Object> health() {
        return Map.of("status", "healthy", "timestamp", Instant.now());
    }

    // ──────────────────── INFO ─────────────────────────────────────

    @GetMapping("/info")
    public Map<String, Object> info() {
        MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
        return Map.of(
            "machineName",    getHostName(),
            "pid",            ProcessHandle.current().pid(),
            "framework",      "Java " + System.getProperty("java.version") + " / Spring Boot",
            "os",             System.getProperty("os.name") + " " + System.getProperty("os.version"),
            "processorCount", Runtime.getRuntime().availableProcessors(),
            "heapUsedMB",     mem.getHeapMemoryUsage().getUsed() / 1024 / 1024,
            "heapMaxMB",      mem.getHeapMemoryUsage().getMax()  / 1024 / 1024,
            "timestamp",      Instant.now(),
            "appName",        "ReproApp-Java"
        );
    }

    // ──────────────────── SLOW ─────────────────────────────────────

    @GetMapping("/slow")
    public Map<String, Object> slow(@RequestParam(defaultValue = "5000") int delay)
            throws InterruptedException {
        delay = clamp(delay, 100, 120_000);
        Thread.sleep(delay);
        return Map.of("message", "Responded after " + delay + " ms", "timestamp", Instant.now());
    }

    // ──────────────────── HIGH CPU ─────────────────────────────────

    @GetMapping("/cpu")
    public Map<String, Object> cpu(@RequestParam(defaultValue = "30") int duration)
            throws InterruptedException {
        duration = clamp(duration, 1, 300);
        int cpus = Runtime.getRuntime().availableProcessors();
        ExecutorService exec = Executors.newFixedThreadPool(cpus);
        long deadline = System.currentTimeMillis() + duration * 1000L;
        AtomicLong counter = new AtomicLong(0);
        for (int i = 0; i < cpus; i++) {
            exec.submit(() -> {
                double x = 0;
                while (System.currentTimeMillis() < deadline) {
                    x += Math.sqrt(counter.incrementAndGet() * Math.PI);
                }
            });
        }
        exec.shutdown();
        exec.awaitTermination(duration + 5, TimeUnit.SECONDS);
        return Map.of(
            "message",   "CPU stress " + duration + " s on " + cpus + " threads",
            "timestamp", Instant.now()
        );
    }

    // ──────────────────── HIGH MEMORY ──────────────────────────────

    @GetMapping("/memory")
    public Map<String, Object> memory(@RequestParam(defaultValue = "300") int mb) {
        mb = clamp(mb, 1, 1500);
        byte[] buf = new byte[mb * 1024 * 1024];
        // Touch all pages
        for (int i = 0; i < buf.length; i += 4096) buf[i] = 1;
        heldMemory.add(buf);
        long totalHeld = heldMemory.stream().mapToLong(b -> b.length).sum() / 1024 / 1024;
        return Map.of(
            "message",    "Allocated " + mb + " MB",
            "totalHeldMB", totalHeld,
            "timestamp",  Instant.now()
        );
    }

    @GetMapping("/memory/free")
    public Map<String, Object> memoryFree() {
        int count = heldMemory.size();
        heldMemory.clear();
        System.gc();
        return Map.of("message", "Released " + count + " allocations", "timestamp", Instant.now());
    }

    // ──────────────────── LATENCY ───────────────────────────────────

    @GetMapping("/latency")
    public Map<String, Object> latency(
            @RequestParam(defaultValue = "50")  int requests,
            @RequestParam(defaultValue = "200") int latency) throws InterruptedException {
        requests = clamp(requests, 1, 500);
        latency  = clamp(latency, 10, 10_000);
        long start = System.currentTimeMillis();
        for (int i = 0; i < requests; i++)
            Thread.sleep(latency);
        return Map.of(
            "message",        requests + " calls × " + latency + " ms",
            "totalElapsedMs", System.currentTimeMillis() - start,
            "timestamp",      Instant.now()
        );
    }

    // ──────────────────── 5XX ERRORS ───────────────────────────────

    @GetMapping("/error/5xx")
    public ResponseEntity<Map<String, Object>> error5xx(@RequestParam(defaultValue = "500") int code) {
        int status = (code >= 500 && code <= 599) ? code : 500;
        Map<String, String> messages = new HashMap<>();
        messages.put("500", "Internal Server Error – simulated");
        messages.put("501", "Not Implemented");
        messages.put("502", "Bad Gateway");
        messages.put("503", "Service Unavailable – overloaded");
        messages.put("504", "Gateway Timeout");
        String msg = messages.getOrDefault(String.valueOf(status), "Server Error");
        return ResponseEntity.status(status).body(Map.of(
            "code", status, "message", msg, "timestamp", Instant.now()
        ));
    }

    // ──────────────────── 4XX ERRORS ───────────────────────────────

    @GetMapping("/error/4xx")
    public ResponseEntity<Map<String, Object>> error4xx(@RequestParam(defaultValue = "404") int code) {
        int status = (code >= 400 && code <= 499) ? code : 404;
        Map<String, String> messages = new HashMap<>();
        messages.put("400", "Bad Request");
        messages.put("401", "Unauthorized");
        messages.put("403", "Forbidden");
        messages.put("404", "Not Found");
        messages.put("408", "Request Timeout");
        messages.put("409", "Conflict");
        messages.put("429", "Too Many Requests");
        String msg = messages.getOrDefault(String.valueOf(status), "Client Error");
        return ResponseEntity.status(status).body(Map.of(
            "code", status, "message", msg, "timestamp", Instant.now()
        ));
    }

    // ──────────────────── STORAGE I/O ──────────────────────────────

    @GetMapping("/storage")
    public Map<String, Object> storage(
            @RequestParam(defaultValue = "50") int mb,
            @RequestParam(defaultValue = "5")  int files) throws IOException {
        mb    = clamp(mb, 1, 500);
        files = clamp(files, 1, 50);
        int chunkSize = (mb * 1024 * 1024) / files;
        byte[] data = new byte[chunkSize];
        new Random().nextBytes(data);
        long start = System.currentTimeMillis();
        List<Path> written = new ArrayList<>();
        for (int i = 0; i < files; i++) {
            Path p = STORAGE_DIR.resolve("repro_" + UUID.randomUUID() + ".bin");
            Files.write(p, data);
            written.add(p);
        }
        long totalRead = 0;
        for (Path p : written) totalRead += Files.readAllBytes(p).length;
        return Map.of(
            "message",        "Wrote & read " + files + " files",
            "totalWrittenMB", mb,
            "totalReadMB",    totalRead / 1024 / 1024,
            "elapsedMs",      System.currentTimeMillis() - start,
            "timestamp",      Instant.now()
        );
    }

    @GetMapping("/storage/clean")
    public Map<String, Object> storageClean() throws IOException {
        long deleted = 0;
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(STORAGE_DIR)) {
            for (Path p : stream) { Files.delete(p); deleted++; }
        }
        return Map.of("message", "Deleted " + deleted + " temp files", "timestamp", Instant.now());
    }

    // ──────────────────── RESTART ───────────────────────────────────

    @GetMapping("/restart")
    public Map<String, Object> restart() {
        new Thread(() -> {
            try { Thread.sleep(500); } catch (InterruptedException ignored) {}
            System.exit(1);
        }).start();
        return Map.of("message", "App restarting – App Service will bring it back", "timestamp", Instant.now());
    }

    // ──────────────────── MEMORY LEAK ──────────────────────────────

    @GetMapping("/memleak")
    public Map<String, Object> memleak(
            @RequestParam(defaultValue = "100") int iterations,
            @RequestParam(defaultValue = "1000") int size) {
        iterations = clamp(iterations, 1, 10_000);
        size       = clamp(size, 100, 100_000);
        for (int i = 0; i < iterations; i++) leakList.add(new byte[size]);
        long approxMB = (long) leakList.size() * size / 1024 / 1024;
        return Map.of(
            "message",       "Added " + iterations + " objects × " + size + " bytes",
            "totalObjects",  leakList.size(),
            "approxLeakedMB", approxMB,
            "timestamp",     Instant.now()
        );
    }

    @GetMapping("/memleak/reset")
    public Map<String, Object> memleakReset() {
        leakList.clear();
        System.gc();
        return Map.of("message", "Leak list cleared", "timestamp", Instant.now());
    }

    // ──────────────────── THREAD POOL ──────────────────────────────

    @GetMapping("/threadpool")
    public Map<String, Object> threadPool(
            @RequestParam(defaultValue = "20") int threads,
            @RequestParam(defaultValue = "20") int duration) {
        threads  = clamp(threads, 1, 200);
        duration = clamp(duration, 1, 120);
        ExecutorService exec = Executors.newCachedThreadPool();
        for (int i = 0; i < threads; i++) {
            final int d = duration;
            exec.submit(() -> {
                try { Thread.sleep(d * 1000L); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            });
        }
        exec.shutdown();
        return Map.of(
            "message",  "Queued " + threads + " blocking tasks for " + duration + " s",
            "timestamp", Instant.now()
        );
    }

    // ──────────────────── SNAT EXHAUSTION ──────────────────

    @GetMapping("/snat")
    public ResponseEntity<Map<String, Object>> snat(
            @RequestParam(defaultValue = "100") int connections,
            @RequestParam(defaultValue = "microsoft.com") String host,
            @RequestParam(defaultValue = "443") int port,
            @RequestParam(defaultValue = "5000") int holdMs) throws InterruptedException {
        connections = clamp(connections, 1, 500);
        holdMs      = clamp(holdMs, 500, 60_000);
        int opened = 0, failed = 0;
        String firstError = null;
        List<Socket> sockets = new ArrayList<>();
        for (int i = 0; i < connections; i++) {
            try {
                Socket s = new Socket();
                s.connect(new InetSocketAddress(host, port), 5000);
                sockets.add(s);
                opened++;
            } catch (Exception e) {
                failed++;
                if (firstError == null) firstError = e.getMessage();
                if (failed >= 3) break;
            }
        }
        Thread.sleep(holdMs);
        for (Socket s : sockets) try { s.close(); } catch (Exception ignored) {}
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("opened", opened); r.put("failed", failed); r.put("firstError", firstError);
        r.put("heldMs", holdMs);
        r.put("message", failed > 0
            ? "SNAT pressure: " + opened + " opened, " + failed + " failed"
            : "Opened and held " + opened + " outbound TCP connections");
        r.put("snatLimit", "Azure App Service: ~128 SNAT ports per instance by default");
        r.put("timestamp", Instant.now());
        return ResponseEntity.ok(r);
    }

    // ──────────────────── CONTAINER STARTUP FAILURE ─────────

    @GetMapping("/startup-fail")
    public Map<String, Object> startupFail() {
        new Thread(() -> {
            try { Thread.sleep(300); } catch (InterruptedException ignored) {}
            System.err.println("[REPROAPP] Simulated container startup failure");
            Runtime.getRuntime().halt(1);
        }).start();
        return Map.of(
            "message",   "Container will exit with code 1 – App Service will attempt restart",
            "note",      "Check Container logs in Diagnose & Solve for startup failure details",
            "timestamp", Instant.now()
        );
    }

    // ──────────────────── OOM / LOW MEMORY ───────────────────

    @GetMapping("/oom")
    public ResponseEntity<Map<String, Object>> oom(@RequestParam(defaultValue = "512") int mb) {
        mb = clamp(mb, 100, 4096);
        int allocated = 0;
        List<byte[]> chunks = new ArrayList<>();
        try {
            while (allocated < mb) {
                int chunkMb = Math.min(50, mb - allocated);
                byte[] buf  = new byte[chunkMb * 1024 * 1024];
                for (int i = 0; i < buf.length; i += 4096) buf[i] = 1;
                chunks.add(buf);
                allocated += chunkMb;
            }
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("message", "Allocated " + allocated + " MB – OOM killer may fire if near container memory limit");
            r.put("allocatedMB", allocated);
            r.put("note", "Memory released after this response – use /memory to hold it");
            r.put("timestamp", Instant.now());
            return ResponseEntity.ok(r);
        } catch (OutOfMemoryError e) {
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("message", "OutOfMemoryError after " + allocated + " MB");
            r.put("allocatedMB", allocated);
            r.put("timestamp", Instant.now());
            return ResponseEntity.status(503).body(r);
        } finally {
            chunks.clear();
            System.gc();
        }
    }

    // ──────────────────── helpers ────────────────────────────────

    private static int clamp(int v, int lo, int hi) { return Math.max(lo, Math.min(hi, v)); }

    private static String getHostName() {
        try { return java.net.InetAddress.getLocalHost().getHostName(); }
        catch (Exception e) { return "unknown"; }
    }
}
