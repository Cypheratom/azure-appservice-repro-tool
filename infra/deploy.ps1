#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys the Azure App Service Repro Tool to Azure.

.DESCRIPTION
    Creates App Service Plans (Windows + Linux, Basic B1) and five web apps,
    then builds and deploys each app:
      - .NET 8 on Windows
      - .NET 8 on Linux
      - Python 3.11 on Linux
      - Java 17 (Spring Boot) on Linux
      - Java 17 (Spring Boot) on Windows

.PARAMETER SubscriptionId
    Azure Subscription ID (required).

.PARAMETER TenantId
    Azure Tenant ID (required).

.PARAMETER ResourceGroup
    Resource group name. Default: rg-reproapp

.PARAMETER Location
    Azure region. Default: westeurope

.PARAMETER Suffix
    Unique suffix for globally unique app names. Default: demo01

.EXAMPLE
    .\deploy.ps1 -SubscriptionId "<guid>" -TenantId "<guid>"
    .\deploy.ps1 -SubscriptionId "<guid>" -TenantId "<guid>" -Suffix "abc123"
#>
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$ResourceGroup  = "rg-reproapp",
    [string]$Location       = "westeurope",
    [string]$Suffix         = "demo01"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot

# ─────────────────────────────── HELPERS ─────────────────────────────────────

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Success([string]$msg) {
    Write-Host "    ✓ $msg" -ForegroundColor Green
}

function Invoke-AzCli {
    param([string[]]$Args)
    $result = az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Args -join ' ') failed:`n$result"
    }
    return $result
}

# ─────────────────────────────── PRE-FLIGHT ──────────────────────────────────

Write-Step "Pre-flight checks"

# Verify az CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
}

# Verify dotnet is available
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet CLI is not installed. Install from https://dot.net"
}

# Verify mvn is available
if (-not (Get-Command mvn -ErrorAction SilentlyContinue)) {
    Write-Warning "Maven (mvn) not found — Java app deployment will be skipped."
    $skipJava = $true
} else {
    $skipJava = $false
}

Write-Success "All required tools found"

# ─────────────────────────────── LOGIN & SUBSCRIPTION ────────────────────────

Write-Step "Setting Azure subscription"
Invoke-AzCli @("account", "set", "--subscription", $SubscriptionId) | Out-Null
Write-Success "Subscription set: $SubscriptionId"

# ─────────────────────────────── RESOURCE GROUP ──────────────────────────────

Write-Step "Ensuring resource group: $ResourceGroup"
$rgExists = az group exists --name $ResourceGroup --subscription $SubscriptionId
if ($rgExists.Trim() -eq "false") {
    Invoke-AzCli @("group", "create", "--name", $ResourceGroup, "--location", $Location, "--subscription", $SubscriptionId) | Out-Null
    Write-Success "Created resource group"
} else {
    Write-Success "Resource group already exists"
}

# ─────────────────────────────── BICEP DEPLOY ────────────────────────────────

Write-Step "Deploying infrastructure via Bicep"
$bicepFile = Join-Path $ScriptDir "main.bicep"

$deployOutput = Invoke-AzCli @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--subscription",   $SubscriptionId,
    "--template-file",  $bicepFile,
    "--parameters",     "location=$Location",
    "--parameters",     "suffix=$Suffix",
    "--output",         "json"
)

$deploy = $deployOutput | ConvertFrom-Json
$outputs = $deploy.properties.outputs

$dotnetWinName  = $outputs.dotnetWindowsName.value
$dotnetLnxName  = $outputs.dotnetLinuxName.value
$pythonLnxName  = $outputs.pythonLinuxName.value
$javaLnxName    = $outputs.javaLinuxName.value
$javaWinName    = $outputs.javaWindowsName.value

Write-Success "Infrastructure deployed"
Write-Host "    .NET Windows  : https://$($outputs.dotnetWindowsUrl.value)"
Write-Host "    .NET Linux    : https://$($outputs.dotnetLinuxUrl.value)"
Write-Host "    Python Linux  : https://$($outputs.pythonLinuxUrl.value)"
Write-Host "    Java Linux    : https://$($outputs.javaLinuxUrl.value)"
Write-Host "    Java Windows  : https://$($outputs.javaWindowsUrl.value)"

# ─────────────────────────────── BUILD & DEPLOY .NET ─────────────────────────

Write-Step "Building .NET 8 app"
$dotnetDir = Join-Path $ScriptDir "..\dotnet\ReproApp"
Push-Location $dotnetDir
try {
    dotnet publish -c Release -o "$ScriptDir/../.artifacts/dotnet" --nologo -q
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
    Write-Success "Build succeeded"

    # Zip the output
    $zipPath = Join-Path $ScriptDir "../.artifacts/dotnet.zip"
    Compress-Archive -Path "$ScriptDir/../.artifacts/dotnet/*" -DestinationPath $zipPath -Force
    Write-Success "Artifact zipped: $zipPath"

    Write-Step "Deploying .NET app to Windows ($dotnetWinName)"
    Invoke-AzCli @(
        "webapp", "deploy",
        "--resource-group", $ResourceGroup,
        "--name",           $dotnetWinName,
        "--src-path",       $zipPath,
        "--type",           "zip",
        "--subscription",   $SubscriptionId
    ) | Out-Null
    Write-Success "Deployed to $dotnetWinName"

    Write-Step "Deploying .NET app to Linux ($dotnetLnxName)"
    Invoke-AzCli @(
        "webapp", "deploy",
        "--resource-group", $ResourceGroup,
        "--name",           $dotnetLnxName,
        "--src-path",       $zipPath,
        "--type",           "zip",
        "--subscription",   $SubscriptionId
    ) | Out-Null
    Write-Success "Deployed to $dotnetLnxName"
}
finally {
    Pop-Location
}

# ─────────────────────────────── BUILD & DEPLOY PYTHON ───────────────────────

Write-Step "Packaging Python app"
$pythonDir = Join-Path $ScriptDir "..\python"
$pyZipPath = Join-Path $ScriptDir "../.artifacts/python.zip"

Compress-Archive -Path "$pythonDir/*" -DestinationPath $pyZipPath -Force
Write-Success "Python artifact zipped: $pyZipPath"

Write-Step "Deploying Python app to Linux ($pythonLnxName)"
Invoke-AzCli @(
    "webapp", "deploy",
    "--resource-group", $ResourceGroup,
    "--name",           $pythonLnxName,
    "--src-path",       $pyZipPath,
    "--type",           "zip",
    "--subscription",   $SubscriptionId
) | Out-Null
Write-Success "Deployed to $pythonLnxName"

# ─────────────────────────────── BUILD & DEPLOY JAVA ─────────────────────────

if ($skipJava) {
    Write-Warning "Skipping Java deployment (Maven not found)"
} else {
    Write-Step "Building Java (Spring Boot) app"
    $javaDir = Join-Path $ScriptDir "..\java"
    Push-Location $javaDir
    try {
        mvn package -DskipTests -q
        if ($LASTEXITCODE -ne 0) { throw "mvn package failed" }
        $jarPath = (Get-ChildItem -Path "target" -Filter "*.jar" -Exclude "*sources*" | Select-Object -First 1).FullName
        Write-Success "Build succeeded: $jarPath"

        Write-Step "Deploying Java app to Linux ($javaLnxName)"
        Invoke-AzCli @(
            "webapp", "deploy",
            "--resource-group", $ResourceGroup,
            "--name",           $javaLnxName,
            "--src-path",       $jarPath,
            "--type",           "jar",
            "--subscription",   $SubscriptionId
        ) | Out-Null
        Write-Success "Deployed to $javaLnxName"

        Write-Step "Deploying Java app to Windows ($javaWinName)"
        Invoke-AzCli @(
            "webapp", "deploy",
            "--resource-group", $ResourceGroup,
            "--name",           $javaWinName,
            "--src-path",       $jarPath,
            "--type",           "jar",
            "--subscription",   $SubscriptionId
        ) | Out-Null
        Write-Success "Deployed to $javaWinName"
    }
    finally {
        Pop-Location
    }
}
# ─────────────────────────────── POST-DEPLOY CONFIGURATION ──────────────────────
# Applied to every web app after code deployment:
#   - B1 tier (Always On requires Basic+)
#   - Always On enabled
#   - Application Insights linked
#   - App Service Logs: App logging filesystem/Error, Web server filesystem
#     35 MB quota, 90-day retention, Failed request tracing ON

Write-Step "Enabling Always On, App Insights, and App Service Logs"

$allAppNames = @($dotnetWinName, $dotnetLnxName, $pythonLnxName, $javaLnxName, $javaWinName)

# --- Scale App Service Plans to B1 (required for Always On) ---
$plansSeen = @{}
foreach ($appName in $allAppNames) {
    $planId   = az webapp show -g $ResourceGroup -n $appName --subscription $SubscriptionId --query "appServicePlanId" -o tsv
    $planName = $planId.Split('/')[-1]
    if (-not $plansSeen[$planName]) {
        $plansSeen[$planName] = $true
        Invoke-AzCli @("appservice", "plan", "update", "-n", $planName, "-g", $ResourceGroup, "--subscription", $SubscriptionId, "--sku", "B1") | Out-Null
        Write-Success "Plan $planName scaled to B1"
    }
}

# --- Create Application Insights (shared, one per deployment) ---
$aiName = "$ResourceGroup-ai"
$aiExists = az monitor app-insights component show --app $aiName -g $ResourceGroup --subscription $SubscriptionId --query "name" -o tsv 2>\$null
if (-not $aiExists) {
    Invoke-AzCli @("monitor", "app-insights", "component", "create", "--app", $aiName, "-g", $ResourceGroup, "--subscription", $SubscriptionId, "-l", $Location, "--kind", "web") | Out-Null
    Write-Success "Application Insights created: $aiName"
} else {
    Write-Success "Application Insights already exists: $aiName"
}
$aiConn = az monitor app-insights component show --app $aiName -g $ResourceGroup --subscription $SubscriptionId --query "connectionString" -o tsv

# --- Per-app settings ---
foreach ($appName in $allAppNames) {
    # Always On
    Invoke-AzCli @("webapp", "config", "set", "-g", $ResourceGroup, "-n", $appName, "--subscription", $SubscriptionId, "--always-on", "true") | Out-Null

    # App Service Logs: Application logging filesystem/Error, web server filesystem 35 MB / 90 days, failed request tracing
    Invoke-AzCli @(
        "webapp", "log", "config",
        "-g", $ResourceGroup, "-n", $appName, "--subscription", $SubscriptionId,
        "--application-logging", "filesystem",
        "--level",              "error",
        "--web-server-logging", "filesystem",
        "--web-server-quota",   "35",
        "--web-server-retention", "90",
        "--failed-request-tracing",  "true",
        "--detailed-error-messages", "true"
    ) | Out-Null

    # Application Insights
    Invoke-AzCli @(
        "webapp", "config", "appsettings", "set",
        "-g", $ResourceGroup, "-n", $appName, "--subscription", $SubscriptionId,
        "--settings",
        "APPLICATIONINSIGHTS_CONNECTION_STRING=$aiConn",
        "ApplicationInsightsAgent_EXTENSION_VERSION=~3",
        "XDT_MicrosoftApplicationInsights_Mode=recommended"
    ) | Out-Null

    Write-Success "$appName — Always On, Logs, App Insights configured"
}
# ─────────────────────────────── SUMMARY ─────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║         Azure App Service Repro Tool — Deployed! 🚀          ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  .NET 8 / Windows  : https://$($dotnetWinName).azurewebsites.net" -ForegroundColor White
Write-Host "║  .NET 8 / Linux    : https://$($dotnetLnxName).azurewebsites.net" -ForegroundColor White
Write-Host "║  Python / Linux    : https://$($pythonLnxName).azurewebsites.net" -ForegroundColor White
Write-Host "║  Java   / Linux    : https://$($javaLnxName).azurewebsites.net" -ForegroundColor WhiteWrite-Host "║  Java   / Windows  : https://$($javaWinName).azurewebsites.net" -ForegroundColor WhiteWrite-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  Each app exposes:                                           ║" -ForegroundColor White
Write-Host "║    /slow        /cpu          /memory   /latency             ║" -ForegroundColor White
Write-Host "║    /error/5xx   /error/4xx   /storage  /restart             ║" -ForegroundColor White
Write-Host "║    /memleak     /threadpool  /gc        /snat                ║" -ForegroundColor White
Write-Host "║    /startup-fail  /oom         /info                        ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
