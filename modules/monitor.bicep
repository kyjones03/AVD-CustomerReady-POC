// ──────────────────────────────────────────────
// Monitoring Module — Log Analytics + Data Collection Rule
// ──────────────────────────────────────────────

param location string
param logAnalyticsName string
param deployDcr bool = true
param dcrName string = 'dcr-avd-poc'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = if (deployDcr) {
  name: dcrName
  location: location
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: [
            'Microsoft-InsightsMetrics'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor Information(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
          ]
        }
      ]
    }
    destinations: {
      azureMonitorMetrics: {
        name: 'azureMonitorMetrics-default'
      }
    }
    dataFlows: [
      {
        destinations: [
          'azureMonitorMetrics-default'
        ]
        streams: [
          'Microsoft-InsightsMetrics'
        ]
      }
    ]
  }
}

output logAnalyticsId string = logAnalytics.id
output logAnalyticsName string = logAnalytics.name
output logAnalyticsWorkspaceId string = logAnalytics.properties.customerId
output dcrId string = deployDcr ? dcr.id : ''
