<#
.SYNOPSIS
    Full deploy of the Azure App Service Repro Tool.
    Run once from a fresh PowerShell window.

.USAGE
    cd C:\repro-app
    .\deploy-all.ps1

    # Custom suffix (app names must be globally unique):
    .\deploy-all.ps1 -Suffix "abc99"

    # Upgrade from Free to Basic for sustained repros:
    .\deploy-all.ps1 -SkuName B1 -SkuTier Basic
#>
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$ResourceGroup  = "rg-reproapp",
    [string]$Location       = "westeurope",
    [string]$Suffix         = "demo01",
    [string]$SkuName        = "B1",
    [string]$SkuTier        = "Basic"
)

# Use Continue so az stderr never throws a PowerShell terminating error
$ErrorActionPreference = "Continue"

# Tracks the exit code of the last Invoke-Az call (not $LASTEXITCODE, which
# gets overwritten by PowerShell cmdlets like Where-Object inside the function)
$script:AzExitCode = 0

# Resolve repo root (script is at C:\repro-app\deploy-all.ps1)
$Root = $PSScriptRoot
if (-not (Test-Path (Join-Path $Root "dotnet"))) {
    $Root = Split-Path $PSScriptRoot -Parent
}

# ---------- helpers -----------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "---------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " STEP: $msg" -ForegroundColor Cyan
    Write-Host "---------------------------------------------------" -ForegroundColor DarkGray
}
function Write-OK([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green  }
function Write-Skip([string]$msg) { Write-Host "  [--] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "  [!!] $msg" -ForegroundColor Red    }

function Invoke-Az {
    <#  Run an az command, return stdout as a string, and store the real
        exit code in $script:AzExitCode BEFORE any PowerShell cmdlet can
        overwrite $LASTEXITCODE.  #>
    param([string[]]$Arguments)
    $result = & az @Arguments 2>&1
    $script:AzExitCode = $LASTEXITCODE   # capture NOW, before Where-Object etc.
    $stdout = @($result | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderr = @($result | Where-Object { $_ -is  [System.Management.Automation.ErrorRecord] })
    if ($stderr) { $stderr | ForEach-Object { Write-Host "  az: $_" -ForegroundColor DarkGray } }
    return ($stdout -join "`n")
}

function Ensure-AzAuth {
    <#  Silently re-authenticates if the cached token for the target subscription
        is missing or expired.  Called at the top of every step that uses az.  #>
    $probe = Invoke-Az @("account", "get-access-token",
        "--subscription", $SubscriptionId, "--query", "tokenType", "-o", "tsv")
    if ($script:AzExitCode -ne 0) {
        Write-Host "  Token expired - re-authenticating (browser will open)..." -ForegroundColor Yellow
        az login --tenant $TenantId
        if ($LASTEXITCODE -ne 0) { Write-Fail "Re-authentication failed"; exit 1 }
        az account set --subscription $SubscriptionId 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Fail "Could not set subscription after re-auth"; exit 1 }
    }
}

function Ensure-Maven {
    <#  Returns the path to mvn(.cmd).  If Maven is not on PATH, downloads
        Maven 3.9.6 into .tools\apache-maven-3.9.6\ and returns that path.  #>
    $sys = Get-Command mvn -ErrorAction SilentlyContinue
    if ($sys) { return $sys.Source }

    $mavenVer = "3.9.6"
    $mavenHome = Join-Path $Root ".tools\apache-maven-$mavenVer"
    $mvnCmd    = Join-Path $mavenHome "bin\mvn.cmd"

    if (-not (Test-Path $mvnCmd)) {
        $url = "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$mavenVer/apache-maven-$mavenVer-bin.zip"
        $zip = Join-Path $Root ".tools\maven.zip"
        New-Item -ItemType Directory -Force (Join-Path $Root ".tools") | Out-Null
        Write-Host "  Downloading Maven $mavenVer..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath (Join-Path $Root ".tools") -Force
        Remove-Item $zip -Force
        Write-OK "Maven $mavenVer ready at $mavenHome"
    }
    return $mvnCmd
}

function Deploy-WebApp {
    <#  Deploys a zip (or jar) to an App Service via Kudu using the ARM Bearer
        token.  This avoids two known failure modes:
          - az webapp deploy: needs a separate SCM-scope MSAL token (not cached)
          - Kudu Basic Auth:  disabled by policy on newer App Service instances
        The ARM Bearer token (audience https://management.azure.com/) is also
        accepted by the Kudu SCM endpoint for AAD-based authentication, and we
        already know it is valid because the Bicep deployments succeeded.  #>
    param(
        [string]$AppName,
        [string]$FilePath,
        [ValidateSet('zip','jar')][string]$Type = 'zip',
        [int]$TimeoutSec = 300
    )

    # Reuse the ARM access token - no additional MSAL scope or Basic Auth needed
    Write-Host "  Getting ARM bearer token for $AppName..." -ForegroundColor DarkGray
    $tokenJson = Invoke-Az @("account", "get-access-token",
        "--subscription", $SubscriptionId, "-o", "json")
    if ($script:AzExitCode -ne 0) {
        Write-Fail "Could not get ARM access token"
        return $false
    }
    $bearerToken = ($tokenJson | ConvertFrom-Json).accessToken

    $uri = if ($Type -eq 'jar') {
        "https://$AppName.scm.azurewebsites.net/api/publish?type=jar"
    } else {
        "https://$AppName.scm.azurewebsites.net/api/zipdeploy?isAsync=false"
    }

    $contentType = if ($Type -eq 'jar') { 'application/octet-stream' } else { 'application/zip' }
    $sizeKb = [int]((Get-Item $FilePath).Length / 1KB)
    Write-Host "  Uploading $sizeKb KB to $AppName via Kudu (bearer auth)..." -ForegroundColor DarkGray

    # Retry up to 3 times - large JARs can trigger transient connection resets
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $null = Invoke-RestMethod -Uri $uri -Method POST `
                -Headers @{ Authorization = "Bearer $bearerToken" } `
                -InFile $FilePath `
                -ContentType $contentType `
                -TimeoutSec $TimeoutSec
            return $true
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($attempt -lt 3) {
                Write-Host "  Attempt $attempt failed (HTTP $status) - retrying in 10s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 10
                # Refresh token before retry
                $tokenJson   = Invoke-Az @("account", "get-access-token", "--subscription", $SubscriptionId, "-o", "json")
                $bearerToken = ($tokenJson | ConvertFrom-Json).accessToken
            } else {
                Write-Host "  Kudu error (HTTP $status): $_" -ForegroundColor Red
                return $false
            }
        }
    }
    return $false
}

# ---------- 0: pre-flight -----------------------------------------------------

Write-Step "0 / 6  Pre-flight checks"

foreach ($tool in @("az", "dotnet")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fail "Required tool not found: $tool"
        Write-Host "    az     -> https://aka.ms/installazurecli" -ForegroundColor Yellow
        Write-Host "    dotnet -> https://dot.net"                -ForegroundColor Yellow
        exit 1
    }
    Write-OK "$tool found"
}

$hasMaven = ($null -ne (Get-Command mvn -ErrorAction SilentlyContinue))
if ($hasMaven) { Write-OK "mvn found" } else { Write-OK "mvn not in PATH - will download Maven 3.9.6 automatically" }

# ---------- 1: azure login ----------------------------------------------------

Write-Step "1 / 6  Azure login"

# Probe: attempt to get a real access token - this fails if the token is
# missing, expired, or belongs to the wrong tenant (unlike 'account show'
# which only reads local metadata and can return 0 even with a stale token)
Write-Host "  Checking for a valid token for subscription $SubscriptionId..." -ForegroundColor DarkGray
$probe = Invoke-Az @("account", "get-access-token", "--subscription", $SubscriptionId, "--query", "tokenType", "-o", "tsv")
$needsLogin = ($script:AzExitCode -ne 0) -or ([string]::IsNullOrWhiteSpace($probe))

if ($needsLogin) {
    Write-Host "  Token not found or expired - login required." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  *** Authentication required ***" -ForegroundColor Yellow
    Write-Host "  A browser window will open to complete sign-in." -ForegroundColor Yellow
    Write-Host ""

    # Interactive browser flow is required if device-code flow is blocked by CA policy.
    az login --tenant $TenantId
    if ($LASTEXITCODE -ne 0) { Write-Fail "az login failed"; exit 1 }

    Write-Host "  Login succeeded. Setting active subscription..." -ForegroundColor DarkGray
    az account set --subscription $SubscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Could not set subscription $SubscriptionId after login."
        Write-Host "  Subscriptions visible after login:" -ForegroundColor Yellow
        az account list --query "[].{Name:name, Id:id, TenantId:tenantId}" -o table
        exit 1
    }
} else {
    Write-OK "Already authenticated for subscription $SubscriptionId"
}

# Confirm active subscription
$activeId = (Invoke-Az @("account", "show", "--subscription", $SubscriptionId, "--query", "id", "-o", "tsv")).Trim()
Write-OK "Active subscription: $activeId"

# ---------- 2: resource group -------------------------------------------------

Write-Step "2 / 6  Resource group"
Ensure-AzAuth

# 'az group create' is idempotent - succeeds whether or not the group exists
Invoke-Az @("group", "create",
    "--name",         $ResourceGroup,
    "--location",     $Location,
    "--subscription", $SubscriptionId,
    "--output",       "none") | Out-Null

if ($script:AzExitCode -ne 0) {
    Write-Fail "Could not create or verify resource group: $ResourceGroup"
    exit 1
}
Write-OK "Resource group ready: $ResourceGroup ($Location)"

# ---------- 3a: bicep - windows -----------------------------------------------

Write-Step "3a / 6  Infrastructure - Windows (plan + .NET Windows app)"
Ensure-AzAuth

$bicepWin = Join-Path $Root "infra\windows.bicep"
Write-Host "  Template : $bicepWin"         -ForegroundColor DarkGray
Write-Host "  Suffix   : $Suffix"           -ForegroundColor DarkGray
Write-Host "  SKU      : $SkuTier/$SkuName" -ForegroundColor DarkGray

$winJson = Invoke-Az @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--subscription",   $SubscriptionId,
    "--template-file",  $bicepWin,
    "--parameters",     "location=$Location",
    "--parameters",     "suffix=$Suffix",
    "--parameters",     "skuName=$SkuName",
    "--parameters",     "skuTier=$SkuTier",
    "--name",           "deploy-windows-$Suffix",
    "--output",         "json"
)
if ($script:AzExitCode -ne 0) { Write-Fail "Windows Bicep deployment failed"; exit 1 }

$winOut        = ($winJson | ConvertFrom-Json).properties.outputs
$dotnetWinName = $winOut.dotnetWindowsName.value
$javaWinName   = $winOut.javaWindowsName.value
Write-OK "Windows deployment done -> https://$dotnetWinName.azurewebsites.net  |  https://$javaWinName.azurewebsites.net"

# ---------- 3b: bicep - linux -------------------------------------------------

Write-Step "3b / 6  Infrastructure - Linux (plan + .NET / Python / Java apps)"
Ensure-AzAuth

$bicepLnx = Join-Path $Root "infra\linux.bicep"
Write-Host "  Template : $bicepLnx"         -ForegroundColor DarkGray

$lnxJson = Invoke-Az @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--subscription",   $SubscriptionId,
    "--template-file",  $bicepLnx,
    "--parameters",     "location=$Location",
    "--parameters",     "suffix=$Suffix",
    "--parameters",     "skuName=$SkuName",
    "--parameters",     "skuTier=$SkuTier",
    "--name",           "deploy-linux-$Suffix",
    "--output",         "json"
)
if ($script:AzExitCode -ne 0) { Write-Fail "Linux Bicep deployment failed"; exit 1 }

$lnxOut        = ($lnxJson | ConvertFrom-Json).properties.outputs
$dotnetLnxName = $lnxOut.dotnetLinuxName.value
$pythonLnxName = $lnxOut.pythonLinuxName.value
$javaLnxName   = $lnxOut.javaLinuxName.value
Write-OK "Linux deployment done"
Write-Host "    .NET/Linux   -> https://$dotnetLnxName.azurewebsites.net" -ForegroundColor White
Write-Host "    Python/Linux -> https://$pythonLnxName.azurewebsites.net" -ForegroundColor White
Write-Host "    Java/Linux   -> https://$javaLnxName.azurewebsites.net"   -ForegroundColor White

# ---------- 4: build + deploy .net --------------------------------------------

Write-Step "4 / 6  Build + deploy .NET 8 app"
Ensure-AzAuth

$dotnetProject    = Join-Path $Root "dotnet\ReproApp\ReproApp.csproj"
$dotnetZip        = Join-Path $Root ".artifacts\dotnet.zip"

New-Item -ItemType Directory -Force (Split-Path $dotnetZip) | Out-Null

# dotnet 10 SDK passes PublishDir as a raw MSBuild positional arg (not --property:)
# which makes MSBuild see two "project files" and throw MSB1008.
# Workaround: omit -o and use the default publish output path.
# Clean bin/ and obj/ fully before publish to avoid stale MSBuild incremental-build state.
$dotnetProjectDir     = Split-Path $dotnetProject
$dotnetPublishDirPre  = Join-Path $dotnetProjectDir "bin\Release\net8.0\publish"
foreach ($dir in @("bin", "obj")) {
    $d = Join-Path $dotnetProjectDir $dir
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
}
Write-Host "  Building .NET 8 (Release)..." -ForegroundColor DarkGray
dotnet publish $dotnetProject -c Release --nologo
if ($LASTEXITCODE -ne 0) { Write-Fail "dotnet publish failed"; exit 1 }
Write-OK "Build succeeded"

# Default publish output for net8.0 is bin\Release\net8.0\publish
$dotnetPublishDir = Join-Path $dotnetProjectDir "bin\Release\net8.0\publish"

if (Test-Path $dotnetZip) { Remove-Item $dotnetZip -Force }
Compress-Archive -Path "$dotnetPublishDir\*" -DestinationPath $dotnetZip
Write-OK "Zipped: $([int]((Get-Item $dotnetZip).Length/1KB)) KB"

foreach ($appName in @($dotnetWinName, $dotnetLnxName)) {
    Write-Host "  Deploying to $appName..." -ForegroundColor DarkGray
    Ensure-AzAuth
    if (Deploy-WebApp -AppName $appName -FilePath $dotnetZip -Type zip) {
        Write-OK "Deployed -> https://$appName.azurewebsites.net"
    } else {
        Write-Fail "Deploy failed for $appName"
    }
}

# ---------- 5: deploy python --------------------------------------------------

Write-Step "5 / 6  Package + deploy Python app"
Ensure-AzAuth

$pythonDir = Join-Path $Root "python"
$pythonZip = Join-Path $Root ".artifacts\python.zip"

if (Test-Path $pythonZip) { Remove-Item $pythonZip -Force }
Compress-Archive -Path "$pythonDir\*" -DestinationPath $pythonZip
Write-OK "Zipped: $([int]((Get-Item $pythonZip).Length/1KB)) KB"

Write-Host "  Deploying to $pythonLnxName..." -ForegroundColor DarkGray
Ensure-AzAuth
if (Deploy-WebApp -AppName $pythonLnxName -FilePath $pythonZip -Type zip) {
    Write-OK "Deployed -> https://$pythonLnxName.azurewebsites.net"
} else {
    Write-Fail "Python deploy failed"
}

# ---------- 6: build + deploy java --------------------------------------------

Write-Step "6 / 6  Build + deploy Java app"
Ensure-AzAuth

$javaDir    = Join-Path $Root "java"
$javaTarget = Join-Path $javaDir "target"

# Resolve Maven (downloads 3.9.6 automatically if not on PATH)
$mvnExe = Ensure-Maven

# Clean previous build output
if (Test-Path $javaTarget) { Remove-Item $javaTarget -Recurse -Force }

Write-Host "  Building Java app (mvn package)..." -ForegroundColor DarkGray
& $mvnExe -f (Join-Path $javaDir "pom.xml") package -DskipTests --no-transfer-progress -q
if ($LASTEXITCODE -ne 0) { Write-Fail "Maven build failed"; exit 1 }

$javaJar = Get-ChildItem $javaTarget -Filter "*.jar" |
    Where-Object { $_.Name -notlike "*sources*" -and $_.Name -notlike "*javadoc*" } |
    Select-Object -First 1
if (-not $javaJar) { Write-Fail "No JAR found in $javaTarget"; exit 1 }
Write-OK "Built: $($javaJar.Name) ($([int]($javaJar.Length/1KB)) KB)"

foreach ($appName in @($javaLnxName, $javaWinName)) {
    Write-Host "  Deploying JAR to $appName..." -ForegroundColor DarkGray
    Ensure-AzAuth
    if (Deploy-WebApp -AppName $appName -FilePath $javaJar.FullName -Type jar -TimeoutSec 300) {
        Write-OK "Deployed -> https://$appName.azurewebsites.net"
    } else {
        Write-Fail "Java deploy failed for $appName"
    }
}

# ---------- summary -----------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Azure App Service Repro Tool - Deployment Complete"            -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  .NET 8 / Windows  -> https://$dotnetWinName.azurewebsites.net" -ForegroundColor White
Write-Host "  .NET 8 / Linux    -> https://$dotnetLnxName.azurewebsites.net" -ForegroundColor White
Write-Host "  Python / Linux    -> https://$pythonLnxName.azurewebsites.net" -ForegroundColor White
Write-Host "  Java   / Linux    -> https://$javaLnxName.azurewebsites.net"   -ForegroundColor White
Write-Host "  Java   / Windows  -> https://$javaWinName.azurewebsites.net"   -ForegroundColor White
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Endpoints on every app:"                                        -ForegroundColor White
Write-Host "    /           Dashboard with buttons for all scenarios"         -ForegroundColor White
Write-Host "    /slow       Slow response      ?delay=5000"                   -ForegroundColor White
Write-Host "    /cpu        High CPU           ?duration=30"                  -ForegroundColor White
Write-Host "    /memory     High memory        ?mb=300"                       -ForegroundColor White
Write-Host "    /memory/free Release held memory"                             -ForegroundColor White
Write-Host "    /latency    Artificial latency ?requests=50&latency=200"      -ForegroundColor White
Write-Host "    /error/5xx  HTTP 5xx           ?code=500|502|503|504"         -ForegroundColor White
Write-Host "    /error/4xx  HTTP 4xx           ?code=400|401|403|404|429"     -ForegroundColor White
Write-Host "    /storage    Storage I/O        ?mb=50&files=10"               -ForegroundColor White
Write-Host "    /restart    Force app restart"                                -ForegroundColor White
Write-Host "    /threadpool Thread pool starvation"                           -ForegroundColor White
Write-Host "    /memleak    Simulated memory leak"                            -ForegroundColor White
Write-Host "    /snat       SNAT exhaustion    ?connections=100&holdMs=5000"  -ForegroundColor White
Write-Host "    /startup-fail Force container crash (restart loop)"           -ForegroundColor White
Write-Host "    /oom        OOM / low memory    ?mb=512"                      -ForegroundColor White
Write-Host "    /info       Runtime / environment info"                       -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  NOTE: Free (F1) = 60 CPU-min/day limit."                       -ForegroundColor Yellow
Write-Host "  For sustained repros: .\deploy-all.ps1 -SkuName B1 -SkuTier Basic" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green

# ---------- hub page ----------------------------------------------------------

$hubPath = Join-Path $Root "index.html"
$ts      = (Get-Date).ToString("yyyy-MM-dd HH:mm")
$hub = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Azure App Service Repro Tool</title>
  <style>
    body  { font-family:'Segoe UI',sans-serif; background:#f0f2f5; margin:0; padding:24px; }
    h1   { color:#0078d4; margin-bottom:4px; }
    h2   { color:#323130; margin:32px 0 12px; font-size:1.1rem; border-bottom:2px solid #0078d4; padding-bottom:6px; }
    .sub { display:flex; align-items:center; gap:8px; margin-bottom:32px; flex-wrap:wrap; }
    .badge { display:inline-block; padding:4px 14px; border-radius:20px; font-size:.82rem; font-weight:600; }
    .badge-ts  { background:#f3f2f1; color:#605e5c; border:1px solid #d2d0ce; font-weight:400; }
    .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(320px,1fr)); gap:16px; margin-bottom:16px; }
    .card { background:#fff; border-radius:8px; padding:20px; box-shadow:0 2px 8px rgba(0,0,0,.08); }
    .card-header { display:flex; align-items:center; gap:8px; margin-bottom:12px; flex-wrap:wrap; }
    .badge-os-win { background:#e3f2fd; color:#0d47a1; border:1px solid #90caf9; }
    .badge-os-lnx { background:#e8f5e9; color:#1b5e20; border:1px solid #a5d6a7; }
    .badge-fw     { background:#fff3e0; color:#e65100; border:1px solid #ffcc80; }
    .card a.main  { display:block; font-size:1rem; font-weight:600; color:#0078d4; text-decoration:none; margin-bottom:14px; word-break:break-all; }
    .card a.main:hover { text-decoration:underline; }
    .scenarios { display:flex; flex-wrap:wrap; gap:6px; }
    .btn { display:inline-block; padding:5px 11px; border-radius:4px; font-size:.8rem; text-decoration:none; color:#fff; }
    .btn.blue   { background:#0078d4; } .btn.blue:hover   { background:#005a9e; }
    .btn.orange { background:#f7630c; } .btn.orange:hover { background:#c94f09; }
    .btn.red    { background:#c50f1f; } .btn.red:hover    { background:#9e0a13; }
    .btn.gray   { background:#605e5c; } .btn.gray:hover   { background:#3b3a39; }
  </style>
</head>
<body>
  <h1>&#x1F527; Azure App Service Repro Tool</h1>
  <div class="sub">
    <span class="badge badge-ts">Deployed $ts</span>
  </div>

  <h2>&#x1FA9F; Windows</h2>
  <div class="grid">
    <div class="card">
      <div class="card-header">
        <span class="badge badge-os-win">Windows</span>
        <span class="badge badge-fw">.NET 8 / ASP.NET Core</span>
      </div>
      <a class="main" href="https://$dotnetWinName.azurewebsites.net" target="_blank">https://$dotnetWinName.azurewebsites.net</a>
      <div class="scenarios">
        <a class="btn blue"   href="https://$dotnetWinName.azurewebsites.net/"                          target="_blank">Dashboard</a>
        <a class="btn orange" href="https://$dotnetWinName.azurewebsites.net/slow?delay=5000"           target="_blank">Slow</a>
        <a class="btn orange" href="https://$dotnetWinName.azurewebsites.net/cpu?duration=30"           target="_blank">High CPU</a>
        <a class="btn orange" href="https://$dotnetWinName.azurewebsites.net/memory?mb=300"             target="_blank">Memory</a>
        <a class="btn orange" href="https://$dotnetWinName.azurewebsites.net/snat?connections=100"      target="_blank">SNAT</a>
        <a class="btn red"    href="https://$dotnetWinName.azurewebsites.net/restart"                   target="_blank">Restart</a>
        <a class="btn gray"   href="https://$dotnetWinName.azurewebsites.net/info"                      target="_blank">Info</a>
      </div>
    </div>
    <div class="card">
      <div class="card-header">
        <span class="badge badge-os-win">Windows</span>
        <span class="badge badge-fw">Java 17 / Spring Boot</span>
      </div>
      <a class="main" href="https://$javaWinName.azurewebsites.net" target="_blank">https://$javaWinName.azurewebsites.net</a>
      <div class="scenarios">
        <a class="btn blue"   href="https://$javaWinName.azurewebsites.net/"                            target="_blank">Dashboard</a>
        <a class="btn orange" href="https://$javaWinName.azurewebsites.net/slow?delay=5000"             target="_blank">Slow</a>
        <a class="btn orange" href="https://$javaWinName.azurewebsites.net/cpu?duration=30"             target="_blank">High CPU</a>
        <a class="btn orange" href="https://$javaWinName.azurewebsites.net/memory?mb=300"               target="_blank">Memory</a>
        <a class="btn orange" href="https://$javaWinName.azurewebsites.net/snat?connections=100"        target="_blank">SNAT</a>
        <a class="btn red"    href="https://$javaWinName.azurewebsites.net/restart"                     target="_blank">Restart</a>
        <a class="btn gray"   href="https://$javaWinName.azurewebsites.net/info"                        target="_blank">Info</a>
      </div>
    </div>
  </div>

  <h2>&#x1F427; Linux</h2>
  <div class="grid">
    <div class="card">
      <div class="card-header">
        <span class="badge badge-os-lnx">Linux</span>
        <span class="badge badge-fw">.NET 8 / ASP.NET Core</span>
      </div>
      <a class="main" href="https://$dotnetLnxName.azurewebsites.net" target="_blank">https://$dotnetLnxName.azurewebsites.net</a>
      <div class="scenarios">
        <a class="btn blue"   href="https://$dotnetLnxName.azurewebsites.net/"                          target="_blank">Dashboard</a>
        <a class="btn orange" href="https://$dotnetLnxName.azurewebsites.net/slow?delay=5000"           target="_blank">Slow</a>
        <a class="btn orange" href="https://$dotnetLnxName.azurewebsites.net/cpu?duration=30"           target="_blank">High CPU</a>
        <a class="btn orange" href="https://$dotnetLnxName.azurewebsites.net/memory?mb=300"             target="_blank">Memory</a>
        <a class="btn orange" href="https://$dotnetLnxName.azurewebsites.net/snat?connections=100"      target="_blank">SNAT</a>
        <a class="btn red"    href="https://$dotnetLnxName.azurewebsites.net/startup-fail"              target="_blank">Startup Fail</a>
        <a class="btn red"    href="https://$dotnetLnxName.azurewebsites.net/oom?mb=512"                target="_blank">OOM</a>
        <a class="btn red"    href="https://$dotnetLnxName.azurewebsites.net/restart"                   target="_blank">Restart</a>
        <a class="btn gray"   href="https://$dotnetLnxName.azurewebsites.net/info"                      target="_blank">Info</a>
      </div>
    </div>
    <div class="card">
      <div class="card-header">
        <span class="badge badge-os-lnx">Linux</span>
        <span class="badge badge-fw">Python 3.11 / Flask</span>
      </div>
      <a class="main" href="https://$pythonLnxName.azurewebsites.net" target="_blank">https://$pythonLnxName.azurewebsites.net</a>
      <div class="scenarios">
        <a class="btn blue"   href="https://$pythonLnxName.azurewebsites.net/"                          target="_blank">Dashboard</a>
        <a class="btn orange" href="https://$pythonLnxName.azurewebsites.net/slow?delay=5000"           target="_blank">Slow</a>
        <a class="btn orange" href="https://$pythonLnxName.azurewebsites.net/cpu?duration=30"           target="_blank">High CPU</a>
        <a class="btn orange" href="https://$pythonLnxName.azurewebsites.net/memory?mb=300"             target="_blank">Memory</a>
        <a class="btn orange" href="https://$pythonLnxName.azurewebsites.net/snat?connections=100"      target="_blank">SNAT</a>
        <a class="btn red"    href="https://$pythonLnxName.azurewebsites.net/startup-fail"              target="_blank">Startup Fail</a>
        <a class="btn red"    href="https://$pythonLnxName.azurewebsites.net/oom?mb=512"                target="_blank">OOM</a>
        <a class="btn red"    href="https://$pythonLnxName.azurewebsites.net/restart"                   target="_blank">Restart</a>
        <a class="btn gray"   href="https://$pythonLnxName.azurewebsites.net/info"                      target="_blank">Info</a>
      </div>
    </div>
    <div class="card">
      <div class="card-header">
        <span class="badge badge-os-lnx">Linux</span>
        <span class="badge badge-fw">Java 17 / Spring Boot</span>
      </div>
      <a class="main" href="https://$javaLnxName.azurewebsites.net" target="_blank">https://$javaLnxName.azurewebsites.net</a>
      <div class="scenarios">
        <a class="btn blue"   href="https://$javaLnxName.azurewebsites.net/"                            target="_blank">Dashboard</a>
        <a class="btn orange" href="https://$javaLnxName.azurewebsites.net/slow?delay=5000"             target="_blank">Slow</a>
        <a class="btn orange" href="https://$javaLnxName.azurewebsites.net/cpu?duration=30"             target="_blank">High CPU</a>
        <a class="btn orange" href="https://$javaLnxName.azurewebsites.net/memory?mb=300"               target="_blank">Memory</a>
        <a class="btn orange" href="https://$javaLnxName.azurewebsites.net/snat?connections=100"        target="_blank">SNAT</a>
        <a class="btn red"    href="https://$javaLnxName.azurewebsites.net/startup-fail"                target="_blank">Startup Fail</a>
        <a class="btn red"    href="https://$javaLnxName.azurewebsites.net/oom?mb=512"                  target="_blank">OOM</a>
        <a class="btn red"    href="https://$javaLnxName.azurewebsites.net/restart"                     target="_blank">Restart</a>
        <a class="btn gray"   href="https://$javaLnxName.azurewebsites.net/info"                        target="_blank">Info</a>
      </div>
    </div>
  </div>
</body>
</html>
"@
[System.IO.File]::WriteAllText($hubPath, $hub, [System.Text.Encoding]::UTF8)
Write-OK "Hub page: $hubPath"
Start-Process $hubPath

# ---------- publish index.html to GitHub Pages --------------------------------
Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host " Publishing hub to GitHub Pages" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
try {
    Push-Location $Root
    git add index.html | Out-Null
    git commit -m "chore: update hub index.html [$ts]" 2>&1 | Out-Null
    git push origin master 2>&1 | Out-Null
    Write-OK "index.html pushed – live at https://cypheratom.github.io/azure-appservice-repro-tool/"
} catch {
    Write-Warning "Git push failed: $_"
} finally {
    Pop-Location
}
