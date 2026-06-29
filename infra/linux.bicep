// Linux App Service Plan + .NET 8 / Python 3.11 / Java 17 web apps
param location string = 'westeurope'
param suffix   string = 'demo01'
param skuName  string = 'B1'
param skuTier  string = 'Basic'

resource planLinux 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'plan-repro-linux-${suffix}'
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource dotnetLinux 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-dotnet-lnx-${suffix}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: planLinux.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true           // requires Basic B1 or higher
      appSettings: [
        { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
        { name: 'REPROAPP_FRAMEWORK',     value: 'dotnet-linux' }
      ]
    }
  }
}

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
        { name: 'REPROAPP_FRAMEWORK',            value: 'python-linux' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
      ]
    }
  }
}

resource javaLinux 'Microsoft.Web/sites@2023-01-01' = {
  name: 'reprobot-java-lnx-${suffix}'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: planLinux.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'JAVA|17-java17'
      alwaysOn: true
      appSettings: [
        { name: 'REPROAPP_FRAMEWORK',             value: 'java-linux' }
        { name: 'JAVA_OPTS',                      value: '-Xms128m -Xmx512m' }
        { name: 'PORT',                           value: '8080' }
      ]
    }
  }
}

output dotnetLinuxName string = dotnetLinux.name
output dotnetLinuxUrl  string = 'https://${dotnetLinux.properties.defaultHostName}'
output pythonLinuxName string = pythonLinux.name
output pythonLinuxUrl  string = 'https://${pythonLinux.properties.defaultHostName}'
output javaLinuxName   string = javaLinux.name
output javaLinuxUrl    string = 'https://${javaLinux.properties.defaultHostName}'

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

resource dotnetLinuxLogs 'Microsoft.Web/sites/config@2023-01-01' = { parent: dotnetLinux; name: 'logs'; properties: logsConfig }
resource pythonLinuxLogs 'Microsoft.Web/sites/config@2023-01-01' = { parent: pythonLinux; name: 'logs'; properties: logsConfig }
resource javaLinuxLogs   'Microsoft.Web/sites/config@2023-01-01' = { parent: javaLinux;   name: 'logs'; properties: logsConfig }
