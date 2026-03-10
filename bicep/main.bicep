// TD SYNNEX | Azure CSP Cost Reporting – core storage (resource group scope)
// Creates: Storage Account, Blob Container, and Role Assignment for managed identity

targetScope = 'resourceGroup'

@description('Storage account name (must be globally unique, lowercase, 3–24 chars).')
param storageAccountName string

@description('Azure region. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Blob container name for cost exports.')
param containerName string = 'cost-exports'

@description('Allow public access on blobs (false for security).')
param allowBlobPublicAccess bool = false

@description('Principal ID of the managed identity that needs write access (leave empty to skip role assignment).')
param exportManagedIdentityPrincipalId string = ''

@description('Tags to apply to all resources.')
param tags object = {}

// ── Storage Account ──────────────────────────────────────────────────────────

resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  tags: tags
  properties: {
    allowBlobPublicAccess: allowBlobPublicAccess
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    allowSharedKeyAccess: true // required for Cost Management SAS fallback
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  name: 'default'
  parent: sa
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: containerName
  parent: blobService
  properties: {
    publicAccess: 'None'
    metadata: { purpose: 'azure-cost-management-exports' }
  }
}

// ── Role Assignment: Storage Blob Data Contributor ───────────────────────────
// Grants the export managed identity write access to the container.
// Only deployed when exportManagedIdentityPrincipalId is provided.

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(exportManagedIdentityPrincipalId)) {
  name: guid(sa.id, exportManagedIdentityPrincipalId, storageBlobDataContributorRoleId)
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: exportManagedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output storageAccountResourceId string = sa.id
output storageAccountName string = sa.name
output containerName string = container.name
