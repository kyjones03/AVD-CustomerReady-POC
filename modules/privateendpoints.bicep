// ──────────────────────────────────────────────
// Private Endpoints Module
// Deploys private DNS zones, VNet links, private
// endpoints, and DNS zone groups for Key Vault
// and the FSLogix Storage Account (file sub-resource).
//
// Scope: networkRg — co-located with the VNet so
// VNet links resolve correctly for all VMs on the VNet.
// ──────────────────────────────────────────────

param location string
param vnetId string
param peSubnetId string

// Key Vault
param kvName string
param kvId string

// Storage (FSLogix)
param storageAccountName string
param storageAccountId string

// ── Private DNS Zone — Key Vault ──
resource kvDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

resource kvDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: kvDnsZone
  name: '${kvName}-vnetlink'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// ── Private DNS Zone — Azure Files ──
resource fileDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

resource fileDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: fileDnsZone
  name: '${storageAccountName}-vnetlink'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// ── Private Endpoint — Key Vault ──
resource kvPrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: 'pe-${kvName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${kvName}-connection'
        properties: {
          privateLinkServiceId: kvId
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource kvPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: kvPrivateEndpoint
  name: 'kvDnsZoneGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: kvDnsZone.id
        }
      }
    ]
  }
}

// ── Private Endpoint — Storage (file) ──
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: 'pe-${storageAccountName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-connection'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource storagePeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: storagePrivateEndpoint
  name: 'storageDnsZoneGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file-core-windows-net'
        properties: {
          privateDnsZoneId: fileDnsZone.id
        }
      }
    ]
  }
}
