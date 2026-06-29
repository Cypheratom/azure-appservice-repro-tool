$flag    = Join-Path $env:HOME "site\wwwroot\startup-fail.flag"
$offline = Join-Path $env:HOME "site\wwwroot\app_offline.htm"

# Write-Host fails in a WebJob's non-interactive PowerShell session ("The handle is invalid").
# Write-Output writes to stdout, which Kudu captures and displays in the job log correctly.
function Log([string]$msg) { Write-Output "[$(Get-Date -f 'HH:mm:ss')] $msg" }

while ($true) {
    if (Test-Path $flag) {
        try {
            $raw = (Get-Content $flag -Raw).Trim()
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($raw, [ref]$parsed)) {
                $ageSec = ([datetime]::UtcNow - $parsed.ToUniversalTime()).TotalSeconds
                if ($ageSec -ge 32) {
                    # TTL expired. Delete the flag FIRST so the next process start is clean.
                    # (ANCM rapid-fail protection can stop retrying before 30 s, so we cannot
                    # rely on the app's own self-heal code; the WebJob must remove the flag.)
                    Log "Flag TTL expired ($([int]$ageSec)s >= 30s) - deleting flag then bouncing ANCM"
                    Remove-Item $flag -Force -ErrorAction SilentlyContinue
                    Log "Flag deleted"
                    # Bounce the ANCM in-process host: writing app_offline.htm drains the worker;
                    # removing it signals ANCM to spin up a fresh (clean) worker process.
                    "Recovering..." | Out-File $offline -Encoding utf8
                    Start-Sleep -Seconds 1
                    Remove-Item $offline -Force -ErrorAction SilentlyContinue
                    Log "app_offline.htm removed - ANCM starting fresh worker"
                    Start-Sleep -Seconds 10   # wait for ANCM to start before next poll cycle
                } else {
                    $rem = [math]::Ceiling(30 - $ageSec)
                    Log "Flag active - ${rem}s until auto-recovery"
                }
            }
        } catch {
            Write-Output "[$(Get-Date -f 'HH:mm:ss')] Error: $_"
        }
    }
    Start-Sleep -Seconds 2
}
