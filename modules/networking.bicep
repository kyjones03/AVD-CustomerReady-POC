// ──────────────────────────────────────────────
// Networking Module — VNet, Subnets, NSG
// ──────────────────────────────────────────────

param location string
param vnetName string
param vnetAddressSpace string = '10.0.0.0/16'
param subnetName string = 'snet-avd-poc'
param subnetPrefix string = '10.0.0.0/24'
param nsgName string = 'nsg-avd-poc'
param dnsServers array = []
param deployBastion bool = false

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: deployBastion ? [] : [
      {
        name: 'Allow-RDP-Inbound'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    dhcpOptions: !empty(dnsServers) ? {
      dnsServers: dnsServers
    } : null
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetId string = vnet.properties.subnets[0].id
output subnetName string = vnet.properties.subnets[0].name
output nsgId string = nsg.id
