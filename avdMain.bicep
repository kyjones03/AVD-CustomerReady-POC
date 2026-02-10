// ══════════════════════════════════════════════════════════
// Azure Virtual Desktop — Proof of Concept Orchestrator
// Subscription-scoped deployment that wires all modules
// ══════════════════════════════════════════════════════════
targetScope = 'subscription'

// ── General ──
param location string = 'eastus2'

// ── Resource Group names ──
param coreRgName string = 'rg-avd-core-poc'
param networkRgName string = 'rg-avd-network-poc'
param monitorRgName string = 'rg-avd-monitor-poc'

// ── Networking ──
param deployNetworking bool = true
param vnetName string = 'vnet-avd-poc'
param vnetAddressSpace string = '10.0.0.0/16'
param subnetName string = 'snet-avd-poc'
param subnetPrefix string = '10.0.0.0/24'
param nsgName string = 'nsg-avd-poc'
param dnsServers array = []

// Brownfield existing resource references
param existingSubnetId string = ''
param existingVnetId string = ''

// ── Key Vault ──
param deployKeyVault bool = true
param keyVaultName string = ''

@secure()
param vmAdminPassword string

param currentUserObjectId string = ''

// ── AVD Core ──
param hostPoolType string = 'Personal'
param hostPoolName string = 'hp-avd-poc'
param appGroupName string = 'ag-avd-poc'
param workspaceName string = 'ws-avd-poc'
param workspaceFriendlyName string = 'AVD POC Workspace'

// ── Compute ──
param deployTemplateVm bool = true
param vmSize string = 'Standard_D4s_v5'
param vmAdminUsername string = 'avdadmin'
param vmImagePublisher string = 'MicrosoftWindowsDesktop'
param vmImageOffer string = 'windows-11'
param vmImageSku string = 'win11-23h2-ent'
param enableTrustedLaunch bool = true
param vmName string = 'avdtemplate01'

// ── Storage ──
param deployStorage bool = true
param storageAccountName string = ''
param fslogixShareName string = 'fslogixprofiles'
param enableAadKerberosAuth bool = true

// ── Gallery ──
param galleryName string = 'acgavdpoc'

// ── Monitoring ──
param deployMonitoring bool = true
param logAnalyticsName string = ''
param deployDcr bool = true

// ── Optional features ──
param deployDomain bool = false
param deployBastion bool = false
param domainVmSize string = 'Standard_D2s_v5'
param domainVmName string = 'avddc01'
param dcPrivateIpAddress string = '10.0.0.4'

// ── Registration token base time ──
param baseTime string = utcNow()

// ══════════════════════════════════════════════════════════
// Computed names — uniqueString guarantees global uniqueness
// ══════════════════════════════════════════════════════════
var uniqueSuffix = uniqueString(subscription().subscriptionId, coreRgName)
var effectiveKeyVaultName = !empty(keyVaultName) ? keyVaultName : 'kv${uniqueSuffix}'
var effectiveStorageAccountName = !empty(storageAccountName) ? storageAccountName : 'sa${uniqueSuffix}'
var effectiveLogAnalyticsName = !empty(logAnalyticsName) ? logAnalyticsName : 'la${uniqueSuffix}'
var publicIpName = 'pip${uniqueSuffix}'

// ══════════════════════════════════════════════════════════
// Resource Groups (idempotent — safe for brownfield)
// ══════════════════════════════════════════════════════════
resource coreRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: coreRgName
  location: location
}

resource networkRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: networkRgName
  location: location
}

resource monitorRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: monitorRgName
  location: location
}

// ══════════════════════════════════════════════════════════
// Module Deployments
// ══════════════════════════════════════════════════════════

// ── Networking (greenfield only) ──
module networking 'modules/networking.bicep' = if (deployNetworking) {
  scope: networkRg
  name: 'networkingDeployment'
  params: {
    location: location
    vnetName: vnetName
    vnetAddressSpace: vnetAddressSpace
    subnetName: subnetName
    subnetPrefix: subnetPrefix
    nsgName: nsgName
    dnsServers: dnsServers
    deployBastion: deployBastion
  }
}

// ── Key Vault (greenfield only) ──
module keyVaultModule 'modules/keyvault.bicep' = if (deployKeyVault) {
  scope: coreRg
  name: 'keyVaultDeployment'
  params: {
    location: location
    keyVaultName: effectiveKeyVaultName
    vmAdminPassword: vmAdminPassword
    currentUserObjectId: currentUserObjectId
  }
}

// ── AVD Core (always deployed) ──
module avdCore 'modules/avdcore.bicep' = {
  scope: coreRg
  name: 'avdCoreDeployment'
  params: {
    location: location
    hostPoolName: hostPoolName
    hostPoolType: hostPoolType
    appGroupName: appGroupName
    workspaceName: workspaceName
    workspaceFriendlyName: workspaceFriendlyName
    deployStorage: deployStorage
    storageAccountName: effectiveStorageAccountName
    fslogixShareName: fslogixShareName
    enableAadKerberosAuth: enableAadKerberosAuth
    galleryName: galleryName
    deployTemplateVm: deployTemplateVm
    vmName: vmName
    vmSize: vmSize
    vmAdminUsername: vmAdminUsername
    vmAdminPassword: vmAdminPassword
    vmImagePublisher: vmImagePublisher
    vmImageOffer: vmImageOffer
    vmImageSku: vmImageSku
    enableTrustedLaunch: enableTrustedLaunch
    subnetId: deployNetworking ? networking!.outputs.subnetId : existingSubnetId
    publicIpName: publicIpName
    deployPublicIp: !deployBastion
    baseTime: baseTime
  }
  dependsOn: [
    keyVaultModule
    roleAssignment
  ]
}

// ── Monitoring (greenfield only) ──
module monitoring 'modules/monitor.bicep' = if (deployMonitoring) {
  scope: monitorRg
  name: 'monitoringDeployment'
  params: {
    location: location
    logAnalyticsName: effectiveLogAnalyticsName
    deployDcr: deployDcr
  }
}

// ── Domain Controller (optional) ──
module domainController 'modules/domain.bicep' = if (deployDomain) {
  scope: coreRg
  name: 'domainControllerDeployment'
  params: {
    location: location
    vmName: domainVmName
    vmSize: domainVmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    subnetId: deployNetworking ? networking!.outputs.subnetId : existingSubnetId
    privateIpAddress: dcPrivateIpAddress
  }
}

// ── Bastion (optional — Developer SKU) ──
module bastionModule 'modules/bastion.bicep' = if (deployBastion) {
  scope: networkRg
  name: 'bastionDeployment'
  params: {
    location: location
    vnetId: deployNetworking ? networking!.outputs.vnetId : existingVnetId
  }
}

// ── Role Assignment — AVD Power On + Power On Off Contributor ──
module roleAssignment 'modules/roleassignment.bicep' = {
  scope: coreRg
  name: 'roleAssignmentDeployment'
}

// ══════════════════════════════════════════════════════════
// Outputs
// ══════════════════════════════════════════════════════════
output coreResourceGroupName string = coreRg.name
output networkResourceGroupName string = networkRg.name
output monitorResourceGroupName string = monitorRg.name
output hostPoolName string = avdCore.outputs.hostPoolName
output scalingPlanName string = avdCore.outputs.scalingPlanName
output registrationTokenExpiry string = avdCore.outputs.registrationTokenExpiry
output workspaceName string = avdCore.outputs.workspaceName
output templateVmName string = avdCore.outputs.vmName
output publicIpAddress string = avdCore.outputs.publicIpAddress
output keyVaultUri string = deployKeyVault ? keyVaultModule!.outputs.keyVaultUri : ''
output keyVaultName string = deployKeyVault ? keyVaultModule!.outputs.keyVaultName : ''
output storageAccountName string = avdCore.outputs.storageAccountName
output galleryId string = avdCore.outputs.galleryId
