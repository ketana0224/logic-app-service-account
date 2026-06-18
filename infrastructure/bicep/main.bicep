// =============================================================================
// main.bicep
// Logic App + Service Account 方式 — クローズドネットワーク基盤一式
//
// 構成 (docs/02-Architecture.md 準拠):
//   - VNet (4 subnets: logicapp / pep / AzureFirewall / jumpbox)
//   - Route Table (rt-sendmsg-egress: 0.0.0.0/0 -> AFW)
//   - Public IP + Azure Firewall + Firewall Policy (afwp-sendmsg, OAuth/Graph allow)
//   - Log Analytics + Application Insights
//   - Key Vault (publicNetworkAccess=Disabled, RBAC 認可)
//   - Storage Account (Logic App host state)
//   - App Service Plan (WS1) + Logic App Standard (SAMI 有効)
//   - 6 Private Endpoints + 6 Private DNS Zones (+ vnet link)
//   - RBAC: Logic App SAMI -> Key Vault Secrets Officer + Storage data-plane roles
//
// scope: resourceGroup
// =============================================================================

targetScope = 'resourceGroup'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('全リソースのデプロイ先リージョン (例: eastus2 / japaneast / westus2)')
param location string = resourceGroup().location

@description('リソース名のプレフィックス / タグ用の環境識別子')
param namePrefix string = 'sendmsg'

@description('Logic App Standard のサイト名')
param logicAppName string = 'la-sendmsg-m365-connector'

@description('Key Vault 名 (グローバル一意)')
param keyVaultName string = 'kv-sendmsg-001'

@description('Storage Account 名 (グローバル一意・小文字英数字 3-24)')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stsendmsg${substring(uniqueString(resourceGroup().id), 0, 3)}'

@description('App Service Plan (WS1) 名')
param appServicePlanName string = 'asp-sendmsg-workflow'

@description('VNet 名')
param vnetName string = 'vnet-sendmsg'

@description('Azure Firewall 名')
param firewallName string = 'afw-sendmsg'

@description('Firewall Policy 名')
param firewallPolicyName string = 'afwp-sendmsg'

@description('Log Analytics ワークスペース名')
param logAnalyticsName string = 'log-sendmsg'

@description('Application Insights 名')
param appInsightsName string = 'appi-sendmsg'

@description('VNet アドレス空間')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('snet-logicapp CIDR (Logic App VNet 統合)')
param subnetLogicAppPrefix string = '10.0.1.0/27'

@description('snet-pep CIDR (Private Endpoints)')
param subnetPepPrefix string = '10.0.2.0/27'

@description('AzureFirewallSubnet CIDR (/26 以上必須)')
param subnetFirewallPrefix string = '10.0.3.0/26'

@description('snet-jumpbox CIDR')
param subnetJumpboxPrefix string = '10.0.4.0/27'

@description('共通タグ')
param tags object = {
  workload: 'logic-app-service-account'
  env: namePrefix
}

// -----------------------------------------------------------------------------
// Variables
// -----------------------------------------------------------------------------

var subnetLogicAppName = 'snet-logicapp'
var subnetPepName = 'snet-pep'
var subnetFirewallName = 'AzureFirewallSubnet'
var subnetJumpboxName = 'snet-jumpbox'
var routeTableName = 'rt-sendmsg-egress'
var firewallPublicIpName = 'pip-afw-sendmsg'

// Private DNS zones (PE 種別 -> zone 名 / groupId)
var privateDnsZoneSites = 'privatelink.azurewebsites.net'
var privateDnsZoneVault = 'privatelink.vaultcore.azure.net'
var privateDnsZoneFile = 'privatelink.file.${environment().suffixes.storage}'
var privateDnsZoneBlob = 'privatelink.blob.${environment().suffixes.storage}'
var privateDnsZoneQueue = 'privatelink.queue.${environment().suffixes.storage}'
var privateDnsZoneTable = 'privatelink.table.${environment().suffixes.storage}'

// Key Vault Secrets Officer ロール定義 ID
var roleKeyVaultSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var roleStorageAccountContributor = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var roleStorageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleStorageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleStorageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var roleStorageFileDataSmbShareContributor = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'

// -----------------------------------------------------------------------------
// Networking: Route Table
// -----------------------------------------------------------------------------

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.3.4'
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Networking: VNet + Subnets
// -----------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetLogicAppName
        properties: {
          addressPrefix: subnetLogicAppPrefix
          routeTable: {
            id: routeTable.id
          }
          delegations: [
            {
              name: 'delegation-webserverfarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: subnetPepName
        properties: {
          addressPrefix: subnetPepPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: subnetFirewallName
        properties: {
          addressPrefix: subnetFirewallPrefix
        }
      }
      {
        name: subnetJumpboxName
        properties: {
          addressPrefix: subnetJumpboxPrefix
        }
      }
    ]
  }
}

resource subnetLogicApp 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: subnetLogicAppName
}

resource subnetPep 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: subnetPepName
}

resource subnetFirewall 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: subnetFirewallName
}

// -----------------------------------------------------------------------------
// Azure Firewall + Firewall Policy (afwp-sendmsg)
// -----------------------------------------------------------------------------

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: firewallPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: firewallPolicyName
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

resource firewallPolicyRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'rcg-oauth-graph'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'app-oauth-graph'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-login-microsoftonline'
            sourceAddresses: [
              subnetLogicAppPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              // OAuth トークン エンドポイント。Firewall ルールには実 FQDN が必須のため environment() ではなくハードコードする
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'allow-graph-microsoft'
            sourceAddresses: [
              subnetLogicAppPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              'graph.microsoft.com'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'net-aad'
        priority: 110
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-aad-servicetag'
            sourceAddresses: [
              subnetLogicAppPrefix
            ]
            destinationAddresses: [
              'AzureActiveDirectory'
            ]
            destinationPorts: [
              '443'
            ]
            ipProtocols: [
              'TCP'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'app-storage'
        priority: 120
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-azure-storage-api'
            sourceAddresses: [
              subnetLogicAppPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.blob.${environment().suffixes.storage}'
              '*.file.${environment().suffixes.storage}'
              '*.queue.${environment().suffixes.storage}'
              '*.table.${environment().suffixes.storage}'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: firewallName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'afw-ipconfig'
        properties: {
          subnet: {
            id: subnetFirewall.id
          }
          publicIPAddress: {
            id: firewallPublicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [
    firewallPolicyRules
  ]
}

// -----------------------------------------------------------------------------
// Observability: Log Analytics + Application Insights
// -----------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// -----------------------------------------------------------------------------
// Key Vault (publicNetworkAccess Disabled, RBAC 認可)
// -----------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

// -----------------------------------------------------------------------------
// Storage Account (Logic App host state)
// -----------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// -----------------------------------------------------------------------------
// App Service Plan (WS1) + Logic App Standard (SAMI)
// -----------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    targetWorkerCount: 1
    maximumElasticWorkerCount: 20
    elasticScaleEnabled: true
    zoneRedundant: false
  }
}

resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: logicAppName
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: subnetLogicApp.id
    vnetRouteAllEnabled: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet'
        }
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__queueServiceUri'
          value: 'https://${storageAccount.name}.queue.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__tableServiceUri'
          value: 'https://${storageAccount.name}.table.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__fileServiceUri'
          value: 'https://${storageAccount.name}.file.${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_SKIP_CONTENTSHARE_VALIDATION'
          value: '1'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: '1'
        }
        {
          name: 'KEYVAULT_NAME'
          value: keyVaultName
        }
        {
          name: 'REFRESH_TOKEN_SECRET_NAME'
          value: 'm365-system-notify-refresh-token'
        }
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// RBAC: Logic App SAMI -> Key Vault Secrets Officer
// -----------------------------------------------------------------------------

resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, logicApp.id, roleKeyVaultSecretsOfficer)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsOfficer)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource stRoleAccountContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, logicApp.id, roleStorageAccountContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageAccountContributor)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource stRoleBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, logicApp.id, roleStorageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource stRoleQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, logicApp.id, roleStorageQueueDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageQueueDataContributor)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource stRoleTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, logicApp.id, roleStorageTableDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageTableDataContributor)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource stRoleFileDataSmbShareContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, logicApp.id, roleStorageFileDataSmbShareContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageFileDataSmbShareContributor)
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Private DNS Zones (+ VNet link)
// -----------------------------------------------------------------------------

var privateDnsZoneNames = [
  privateDnsZoneSites
  privateDnsZoneVault
  privateDnsZoneFile
  privateDnsZoneBlob
  privateDnsZoneQueue
  privateDnsZoneTable
]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zoneName in privateDnsZoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

resource privateDnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zoneName, i) in privateDnsZoneNames: {
  parent: privateDnsZones[i]
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

// -----------------------------------------------------------------------------
// Private Endpoints (6)
// -----------------------------------------------------------------------------

// 1) Logic App (sites)
resource peLogicApp 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-la-${namePrefix}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetPep.id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-la'
        properties: {
          privateLinkServiceId: logicApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource peLogicAppDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: peLogicApp
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: privateDnsZones[0].id
        }
      }
    ]
  }
}

// 2) Key Vault (vault)
resource peKeyVault 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-kv-${namePrefix}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetPep.id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-kv'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource peKeyVaultDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: peKeyVault
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: privateDnsZones[1].id
        }
      }
    ]
  }
}

// 3-6) Storage (file / blob / queue / table)
var storageGroups = [
  {
    groupId: 'file'
    peName: 'pe-st-file'
    zoneIndex: 2
  }
  {
    groupId: 'blob'
    peName: 'pe-st-blob'
    zoneIndex: 3
  }
  {
    groupId: 'queue'
    peName: 'pe-st-queue'
    zoneIndex: 4
  }
  {
    groupId: 'table'
    peName: 'pe-st-table'
    zoneIndex: 5
  }
]

resource peStorage 'Microsoft.Network/privateEndpoints@2023-09-01' = [for g in storageGroups: {
  name: g.peName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetPep.id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-st-${g.groupId}'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            g.groupId
          ]
        }
      }
    ]
  }
}]

resource peStorageDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = [for (g, i) in storageGroups: {
  parent: peStorage[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: g.groupId
        properties: {
          privateDnsZoneId: privateDnsZones[g.zoneIndex].id
        }
      }
    ]
  }
}]

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output logicAppName string = logicApp.name
output logicAppPrincipalId string = logicApp.identity.principalId
output keyVaultName string = keyVault.name
output storageAccountName string = storageAccount.name
output vnetName string = vnet.name
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output appInsightsName string = appInsights.name
