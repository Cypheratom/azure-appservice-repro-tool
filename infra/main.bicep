@description('Azure region for all resources')
param location string = 'westeurope'

@description('Unique suffix to make app names globally unique')
param suffix string = 'demo01'

@description('App Service Plan SKU — Basic B1 is required for Always On and Application Insights')
param skuName string = 'B1'
param skuTier string = 'Basic'

// ─────────────────────────────── APP SERVICE PLANS ───────────────────────────

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

resource planLinux 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'plan-repro-linux-${suffix}'
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  kind: 'linux'
  properties: {
    reserved: true   // required for Linux
  }
}

// ─────────────────────────────── APPLICATION INSIGHTS ────────────────────────
// Shared instance for all five apps. The connection string is injected via
// APPLICATIONINSIGHTS_CONNECTION_STRING so the auto-instrumentation agent
// activates without any code changes.

resource appInsights 'microsoft.insights/components@2020-02-02' = {
  name: 'repro-ai-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 90
  }
}

// ─────────────────────────────── .NET 8 on WINDOWS ───────────────────────────

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
        { name: 'ASPNETCORE_ENVIRONMENT',                    value: 'Production' }
        { name: 'REPROAPP_FRAMEWORK',                        value: 'dotnet-windows' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsights.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'XDT_MicrosoftApplicationInsights_Mode',      value: 'recommended' }
      ]
      metadata: [
        { name: 'CURRENT_STACK', value: 'dotnet' }
      ]
    }
  }
}

// ─────────────────────────────── .NET 8 on LINUX ─────────────────────────────

resource dotnetLinux 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-dotnet-lnx-${suffix}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: planLinux.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      appSettings: [
        { name: 'ASPNETCORE_ENVIRONMENT',                    value: 'Production' }
        { name: 'REPROAPP_FRAMEWORK',                        value: 'dotnet-linux' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsights.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'XDT_MicrosoftApplicationInsights_Mode',      value: 'recommended' }
      ]
    }
  }
}

// ─────────────────────────────── Python 3.11 on LINUX ────────────────────────

resource pythonLinux 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-python-lnx-${suffix}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: planLinux.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      alwaysOn: true
      appCommandLine: 'gunicorn --bind=0.0.0.0 --timeout 600 --workers 2 app:app'
      appSettings: [
        { name: 'REPROAPP_FRAMEWORK',                        value: 'python-linux' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT',            value: 'true' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsights.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'XDT_MicrosoftApplicationInsights_Mode',      value: 'recommended' }
      ]
    }
  }
}

// ─────────────────────────────── Java 17 on LINUX ────────────────────────────

resource javaLinux 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-java-lnx-${suffix}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: planLinux.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'JAVA|17-java17'   // Java SE with embedded server
      alwaysOn: true
      appSettings: [
        { name: 'REPROAPP_FRAMEWORK',                        value: 'java-linux' }
        { name: 'JAVA_OPTS',                                 value: '-Xms128m -Xmx512m' }
        { name: 'PORT',                                      value: '8080' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsights.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'XDT_MicrosoftApplicationInsights_Mode',      value: 'recommended' }
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
        { name: 'REPROAPP_FRAMEWORK',                        value: 'java-windows' }
        { name: 'JAVA_OPTS',                                 value: '-Xms128m -Xmx512m' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsights.properties.ConnectionString }
        { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
        { name: 'XDT_MicrosoftApplicationInsights_Mode',      value: 'recommended' }
      ]
    }
  }
}

// ─────────────────────────────── APP SERVICE LOGS ────────────────────────────
// Applied to every app: filesystem logging at Error level, 35 MB / 90-day
// retention for web server logs, failed request tracing enabled.

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

resource dotnetWinLogs    'Microsoft.Web/sites/config@2023-01-01' = { parent: dotnetWin;    name: 'logs'; properties: logsConfig }
resource dotnetLinuxLogs  'Microsoft.Web/sites/config@2023-01-01' = { parent: dotnetLinux;  name: 'logs'; properties: logsConfig }
resource pythonLinuxLogs  'Microsoft.Web/sites/config@2023-01-01' = { parent: pythonLinux;  name: 'logs'; properties: logsConfig }
resource javaLinuxLogs    'Microsoft.Web/sites/config@2023-01-01' = { parent: javaLinux;    name: 'logs'; properties: logsConfig }
resource javaWinLogs      'Microsoft.Web/sites/config@2023-01-01' = { parent: javaWin;      name: 'logs'; properties: logsConfig }

// ─────────────────────────────── OUTPUTS ─────────────────────────────────────

output dotnetWindowsUrl  string = 'https://${dotnetWin.properties.defaultHostName}'
output dotnetLinuxUrl    string = 'https://${dotnetLinux.properties.defaultHostName}'
output pythonLinuxUrl    string = 'https://${pythonLinux.properties.defaultHostName}'
output javaLinuxUrl      string = 'https://${javaLinux.properties.defaultHostName}'
output javaWindowsUrl    string = 'https://${javaWin.properties.defaultHostName}'

output dotnetWindowsName string = dotnetWin.name
output dotnetLinuxName   string = dotnetLinux.name
output pythonLinuxName   string = pythonLinux.name
output javaLinuxName     string = javaLinux.name
output javaWindowsName   string = javaWin.name
