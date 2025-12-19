param location string = resourceGroup().location
param namePrefix string = 'ragdemo'

@allowed([
  'default'
  'highDensity'
])
param searchHostingMode string = 'default'

@allowed([
  // Back-compat (mapped to the standard tiers below)
  'S1'
  'S2'
  'S3'

  // Azure AI Search SKU names
  'free'
  'basic'
  'standard'
  'standard2'
  'standard3'
  'storage_optimized_l1'
  'storage_optimized_l2'
])
param searchSku string = 'standard'

var resolvedSearchSku = toLower(searchSku)
var searchSkuName = resolvedSearchSku == 's1' ? 'standard' : resolvedSearchSku == 's2' ? 'standard2' : resolvedSearchSku == 's3' ? 'standard3' : resolvedSearchSku

@minLength(2)
param searchName string = toLower('${namePrefix}-search-${uniqueString(resourceGroup().id)}')

@minLength(2)
param openaiName string = toLower('${namePrefix}-openai-${uniqueString(resourceGroup().id)}')

@minLength(3)
param storageName string = toLower('${namePrefix}st${uniqueString(resourceGroup().id)}')

// Deployment names (what you reference in Search + app config)
param chatDeploymentName string = 'chat'
param embedDeploymentName string = 'embeddings'

// IMPORTANT: set these to models available in your region/tenant.
param chatModelName string
param chatModelVersion string
param embedModelName string
param embedModelVersion string

resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchName
  location: location
  sku: { name: searchSkuName }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: searchHostingMode
  }
}

resource oai 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openaiName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: openaiName
    publicNetworkAccess: 'Enabled'
  }
}

resource chatDeploy 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  name: '${oai.name}/${chatDeploymentName}'
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: chatModelVersion
    }
    scaleSettings: { scaleType: 'Standard' }
  }
}

resource embedDeploy 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  name: '${oai.name}/${embedDeploymentName}'
  properties: {
    model: {
      format: 'OpenAI'
      name: embedModelName
      version: embedModelVersion
    }
    scaleSettings: { scaleType: 'Standard' }
  }
}

resource st 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource kbContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${st.name}/default/kb-docs'
  properties: { publicAccess: 'None' }
}

output location string = location
output searchServiceName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'

output openaiAccountName string = oai.name
output openaiEndpoint string = oai.properties.endpoint
output chatDeployment string = chatDeploymentName
output embedDeployment string = embedDeploymentName

output storageAccountName string = st.name
output storageContainerName string = 'kb-docs'
