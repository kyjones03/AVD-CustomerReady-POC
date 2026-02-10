// ──────────────────────────────────────────────
// AVD Core Module — Host Pool, App Group, Workspace,
//   Storage, Gallery, Public IP, NIC, Template VM
// ──────────────────────────────────────────────

param location string

// AVD
param hostPoolName string
param hostPoolType string = 'Personal'
param preferredAppGroupType string = 'Desktop'
param appGroupName string
param workspaceName string
param workspaceFriendlyName string = 'AVD POC Workspace'

// Storage
param deployStorage bool = true
param storageAccountName string
param fslogixShareName string = 'fslogixprofiles'
param enableAadKerberosAuth bool = true

// Gallery
param galleryName string = 'acgavdpoc'

// VM
param deployTemplateVm bool = true
param vmName string = 'avdtemplate01'
param vmSize string
param vmAdminUsername string

@secure()
param vmAdminPassword string

param vmImagePublisher string = 'MicrosoftWindowsDesktop'
param vmImageOffer string = 'windows-11'
param vmImageSku string = 'win11-23h2-ent'
param enableTrustedLaunch bool = true
param osDiskSizeGb int = 128

// Networking
param subnetId string
param publicIpName string
param deployPublicIp bool = true

// Registration token timestamp
param baseTime string = utcNow()

// ── Host Pool ──
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: hostPoolName
  location: location
  properties: {
    hostPoolType: hostPoolType
    loadBalancerType: hostPoolType == 'Personal' ? 'Persistent' : 'BreadthFirst'
    preferredAppGroupType: preferredAppGroupType == 'Desktop' ? 'Desktop' : 'RemoteApp'
    personalDesktopAssignmentType: hostPoolType == 'Personal' ? 'Automatic' : null
    startVMOnConnect: true
    validationEnvironment: true
    registrationInfo: {
      registrationTokenOperation: 'Update'
      expirationTime: dateTimeAdd(baseTime, 'P30D')
    }
  }
}

// ── Scaling Plan ──
resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2023-09-05' = {
  name: '${hostPoolName}-scaling'
  location: location
  properties: {
    hostPoolType: hostPoolType
    friendlyName: '${hostPoolName} Scaling Plan'
    timeZone: 'Eastern Standard Time'
    exclusionTag: 'excludeFromScaling'
    schedules: []
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPool.id
        scalingPlanEnabled: true
      }
    ]
  }
}

// ── Application Group ──
resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: appGroupName
  location: location
  properties: {
    applicationGroupType: preferredAppGroupType == 'Desktop' ? 'Desktop' : 'RemoteApp'
    hostPoolArmPath: hostPool.id
  }
}

// ── Workspace ──
resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: workspaceName
  location: location
  properties: {
    friendlyName: workspaceFriendlyName
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

// ── Storage Account (FSLogix) ──
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = if (deployStorage) {
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    azureFilesIdentityBasedAuthentication: enableAadKerberosAuth ? {
      directoryServiceOptions: 'AADKERB'
    } : null
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = if (deployStorage) {
  parent: storageAccount
  name: 'default'
}

resource fslogixShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = if (deployStorage) {
  parent: fileService
  name: fslogixShareName
  properties: {
    shareQuota: 100
    enabledProtocols: 'SMB'
  }
}

// ── Azure Compute Gallery ──
resource gallery 'Microsoft.Compute/galleries@2023-07-03' = {
  name: galleryName
  location: location
  properties: {}
}

// ── Public IP (skipped when Bastion is deployed) ──
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (deployTemplateVm && deployPublicIp) {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// ── NIC ──
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = if (deployTemplateVm) {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: deployPublicIp ? {
            id: publicIp!.id
          } : null
        }
      }
    ]
  }
}

// ── Template VM ──
resource templateVm 'Microsoft.Compute/virtualMachines@2024-03-01' = if (deployTemplateVm) {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: vmImagePublisher
        offer: vmImageOffer
        sku: vmImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGb
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic!.id
        }
      ]
    }
    securityProfile: enableTrustedLaunch ? {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    } : null
  }
}

// ── Outputs ──
output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
output scalingPlanName string = scalingPlan.name
output registrationTokenExpiry string = dateTimeAdd(baseTime, 'P30D')
output appGroupId string = appGroup.id
output workspaceId string = workspace.id
output workspaceName string = workspace.name
output storageAccountId string = deployStorage ? storageAccount!.id : ''
output storageAccountName string = deployStorage ? storageAccount!.name : ''
output galleryId string = gallery.id
output vmId string = deployTemplateVm ? templateVm!.id : ''
output vmName string = deployTemplateVm ? templateVm!.name : ''
output publicIpAddress string = (deployTemplateVm && deployPublicIp) ? publicIp!.properties.ipAddress : ''
