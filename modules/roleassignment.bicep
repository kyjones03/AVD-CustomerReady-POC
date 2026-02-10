// ──────────────────────────────────────────────
// Role Assignment Module — AVD Service Principal
// Desktop Virtualization Power On Contributor
// Desktop Virtualization Power On Off Contributor
// ──────────────────────────────────────────────

// AVD Service Principal (well-known ID)
param avdServicePrincipalId string = '7e4875e1-a13b-4d6e-8fb9-116478ee919d'

// Role definitions
var powerOnContributorRoleId = '489581de-a3bd-480d-9518-53dea7416b33'
var powerOnOffContributorRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, avdServicePrincipalId, powerOnContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnContributorRoleId)
    principalId: avdServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource powerOnOffRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, avdServicePrincipalId, powerOnOffContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnOffContributorRoleId)
    principalId: avdServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = roleAssignment.id
output powerOnOffRoleAssignmentId string = powerOnOffRoleAssignment.id
