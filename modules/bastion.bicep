// ──────────────────────────────────────────────
// Azure Bastion Module — Developer SKU
// Deployed only when deployBastion = true
// ──────────────────────────────────────────────

param location string
param bastionName string = 'bas-avd-poc'
param vnetId string

resource bastion 'Microsoft.Network/bastionHosts@2025-05-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnetId
    }
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
