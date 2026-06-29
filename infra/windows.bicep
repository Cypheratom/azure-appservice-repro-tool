// Windows App Service Plan + .NET 8 and Java 17 web apps
param location string = 'westeurope'
param suffix   string = 'demo01'
param skuName  string = 'B1'
param skuTier  string = 'Basic'

resource planWindows 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'plan-repro-win-${suffix}'
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  kind: 'windows'
  properties: {
    reserved: false
  }
}

resource dotnetWin 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-dotnet-win-${suffix}'
  location: location
  kind: 'app'
  properties: {
    serverFarmId: planWindows.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      alwaysOn: true           // requires Basic B1 or higher
      use32BitWorkerProcess: true
      appSettings: [
        { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
        { name: 'REPROAPP_FRAMEWORK',     value: 'dotnet-windows' }
      ]
      metadata: [
        { name: 'CURRENT_STACK', value: 'dotnet' }
      ]
    }
  }
}

// ─────────────────────────────── Java 17 on WINDOWS ──────────────────────────

resource javaWin 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-java-win-${suffix}'
  location: location
  kind: 'app'
  properties: {
    serverFarmId: planWindows.id
    httpsOnly: true
    siteConfig: {
      javaVersion: '17'
      javaContainer: 'JAVA'
      javaContainerVersion: 'SE'
      alwaysOn: true
      use32BitWorkerProcess: false
      appSettings: [
        { name: 'REPROAPP_FRAMEWORK',             value: 'java-windows' }
        { name: 'JAVA_OPTS',                      value: '-Xms128m -Xmx512m' }
      ]
    }
  }
}

// ─────────────────────────────── APP SERVICE LOGS ────────────────────────────
// Filesystem logging: Error level, 35 MB / 90-day web server logs, FRT enabled.

var logsConfig = {
  applicationLogs: {
    fileSystem: { level: 'Error', retentionInDays: 90 }
  }
  httpLogs: {
    fileSystem: { retentionInDays: 90, retentionInMb: 35, enabled: true }
  }
  failedRequestsTracing:  { enabled: true }
  detailedErrorMessages:  { enabled: true }
}

resource dotnetWinLogs 'Microsoft.Web/sites/config@2023-01-01' = { parent: dotnetWin; name: 'logs'; properties: logsConfig }
resource javaWinLogs   'Microsoft.Web/sites/config@2023-01-01' = { parent: javaWin;   name: 'logs'; properties: logsConfig }

// ─────────────────────────────── OUTPUTS ─────────────────────────────────────

output dotnetWindowsName string = dotnetWin.name
output dotnetWindowsUrl  string = 'https://${dotnetWin.properties.defaultHostName}'
output javaWindowsName   string = javaWin.name
output javaWindowsUrl    string = 'https://${javaWin.properties.defaultHostName}'
