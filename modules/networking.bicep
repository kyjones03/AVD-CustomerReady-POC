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
param deployPrivateEndpoints bool = false
param peSubnetName string = 'snet-pe-poc'
param peSubnetPrefix string = '10.0.1.0/24'

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

var avdSubnet = {
  name: subnetName
  properties: {
    addressPrefix: subnetPrefix
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// PE subnets do not require NSG rules; privateEndpointNetworkPolicies
// must be Disabled (the default) on the subnet for PEs to be created.
var peSubnet = {
  name: peSubnetName
  properties: {
    addressPrefix: peSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
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
    subnets: deployPrivateEndpoints ? [avdSubnet, peSubnet] : [avdSubnet]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetId string = vnet.properties.subnets[0].id
output subnetName string = vnet.properties.subnets[0].name
output nsgId string = nsg.id
output peSubnetId string = deployPrivateEndpoints ? vnet.properties.subnets[1].id : ''
