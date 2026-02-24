// ══════════════════════════════════════════════════════════
// Default Parameter Values — Reference Only
// Secrets must be supplied at deployment time via CLI prompt
// ══════════════════════════════════════════════════════════
using 'avdMain.bicep'

// General
param location = 'eastus2'

// Resource Groups
param coreRgName = 'rg-avd-core-poc'
param networkRgName = 'rg-avd-network-poc'
param monitorRgName = 'rg-avd-monitor-poc'

// Networking
param deployNetworking = true
param vnetName = 'vnet-avd-poc'
param vnetAddressSpace = '10.0.0.0/16'
param subnetName = 'snet-avd-poc'
param subnetPrefix = '10.0.0.0/24'
param nsgName = 'nsg-avd-poc'
param dnsServers = []
param existingSubnetId = ''
param existingVnetId = ''

// Key Vault
param deployKeyVault = true
param keyVaultName = ''
param currentUserObjectId = ''

// AVD
param hostPoolType = 'Personal'
param hostPoolName = 'hp-avd-poc'
param appGroupName = 'ag-avd-poc'
param workspaceName = 'ws-avd-poc'
param workspaceFriendlyName = 'AVD POC Workspace'

// Compute
param deployTemplateVm = true
param vmSize = 'Standard_D4s_v5'
param vmAdminUsername = 'avdadmin'
param vmAdminPassword = '' // to be provided at deployment time
param vmImagePublisher = 'MicrosoftWindowsDesktop'
param vmImageOffer = 'windows-11'
param vmImageSku = 'win11-23h2-avd'
param enableTrustedLaunch = true
param vmName = 'avdtemplate01'

// Storage
param deployStorage = true
param storageAccountName = ''
param fslogixShareName = 'fslogixprofiles'
param enableAadKerberosAuth = true

// Gallery
param galleryName = 'acgavdpoc'

// Monitoring
param deployMonitoring = true
param logAnalyticsName = ''
param deployDcr = true

// Optional features
param deployDomain = false
param deployBastion = false
param domainVmSize = 'Standard_D2s_v5'
param domainVmName = 'avddc01'
param dcPrivateIpAddress = '10.0.0.4'

// IMPORTANT: vmAdminPassword must be provided at deployment time
// Do NOT store passwords in this file
// param vmAdminPassword = '<PROVIDE AT RUNTIME>'
