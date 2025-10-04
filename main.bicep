
// ============================================================================
// Pueblito Posada Infra (Mexico Central) — v1
// Everything Bicep. Assumes only the external DNS domains already exist.
// Creates: VNet (+NSGs), Storage (static website, private-only), Private Endpoints
// (+ Private DNS zones + VNet links), optional Jump VM, and an Azure Front Door
// Std/Prem SKELETON ready for Private Link + multi-domain routing.
// ============================================================================

targetScope = 'resourceGroup'

// -----------------------
// Parameters (edit values at deploy time; keep names neutral)
// -----------------------
@description('All resources (except globally-scoped ones like AFD) use this Azure region.')
param location string = 'mexicocentral'

@description('Virtual network name.')
param vnetName string

@description('VNet address space. Adjust if you already have IP plan.')
param vnetCidr string = '10.40.0.0/16'

@description('Subnets to create. Each will get its own NSG with baseline rules. Mark one as the PE subnet.')
param subnets array = [
  // Jump/bastion/admin subnet (example)
  {
    name: 'snet-jump'
    prefix: '10.40.10.0/24'
    isPrivateEndpointSubnet: false
    // OPTIONAL: set a CIDR to allow SSH to jump from Internet. Use your own IP/CIDR.
    allowSshFrom: '0.0.0.0/0'
  }
  // Private Endpoint subnet (no NVA, disable PE network policies)
  {
    name: 'snet-pe'
    prefix: '10.40.20.0/24'
    isPrivateEndpointSubnet: true
  }
]

@description('Storage account name (lowercase, 3-24). Static website + private endpoints are configured.')
@minLength(3)
@maxLength(24)
param storageName string

@description('Index document for static website.')
param staticIndex string = 'index.html'

@description('404 document path for static website.')
param static404 string = '404.html'

@description('Create a small Linux jump VM in the "jump" subnet?')
param createJumpVm bool = false

@description('Jump VM name (if createJumpVm=true).')
param jumpVmName string = 'vm-jump-01'

@description('Admin username for the jump VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for the jump VM (ssh-rsa/ecdsa/ed25519).')
param adminSshPublicKey string = ''

// ---------- Azure Front Door (Std/Prem) skeleton params ----------
@description('AFD profile name (Standard_AzureFrontDoor). Location is always Global.')
param afdProfileName string = 'afd-pueblito'

@description('AFD endpoint name (host becomes <name>.z01.azurefd.net).')
param afdEndpointName string = 'afd-endpoint-01'

@description('AFD origin group name.')
param afdOriginGroupName string = 'og-storage'

@description('AFD origin name (points at Storage Static Website endpoint).')
param afdOriginName string = 'orig-storage-web'

@description('AFD route name (with HTTP->HTTPS redirect).')
param afdRouteName string = 'route-static-https'

@description('AFD rule set name (example: add security headers).')
param afdRuleSetName string = 'ruleset-sec-headers'

@description('Custom domains to attach to AFD later. Keep empty to skip. Example: ["hotelespueblitoboyacense.com","hotelespueblitoboyacense.co"]')
param afdCustomDomains array = []

// -----------------------
// Locals
// -----------------------
var tags = {
  workload: 'pueblito-posada'
  env: 'prod'
}

var peSubnetName = first([for s in subnets: s.name if (bool(s.isPrivateEndpointSubnet))])
var jumpSubnetName = length([for s in subnets: s if (!bool(s.isPrivateEndpointSubnet))]) > 0 ? first([for s in subnets: s.name if (!bool(s.isPrivateEndpointSubnet))]) : 'snet-jump'

// -----------------------
// Networking: NSGs (one per subnet) + VNet/Subnets
// -----------------------
resource nsgs 'Microsoft.Network/networkSecurityGroups@2023-09-01' = [for s in subnets: {
  name: 'nsg-${vnetName}-${s.name}'
  location: location
  tags: tags
  properties: {
    securityRules: union(
      // Baseline allow VNet traffic, allow Azure LB probe
      [
        {
          name: 'Allow-VNet-Inbound'
          properties: {
            description: 'Allow intra-VNet traffic'
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            destinationAddressPrefix: 'VirtualNetwork'
            access: 'Allow'
            priority: 200
            direction: 'Inbound'
          }
        }
        {
          name: 'Allow-LB-Probe'
          properties: {
            description: 'Allow Azure Load Balancer probe traffic'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '65535'
            sourceAddressPrefix: 'AzureLoadBalancer'
            destinationAddressPrefix: '*'
            access: 'Allow'
            priority: 210
            direction: 'Inbound'
          }
        }
      ],
      // Optional SSH allow for jump subnet if allowSshFrom is provided
      (contains(s, 'allowSshFrom') && !empty(string(s.allowSshFrom))) ? [
        {
          name: 'Allow-SSH-From-Admin'
          properties: {
            description: 'Allow SSH to jump subnet from specified CIDR'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: string(s.allowSshFrom)
            destinationAddressPrefix: '*'
            access: 'Allow'
            priority: 220
            direction: 'Inbound'
          }
        }
      ] : []
    )
  }
}]

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetCidr
      ]
    }
    subnets: [for s in subnets: {
      name: s.name
      properties: {
        addressPrefix: s.prefix
        privateEndpointNetworkPolicies: bool(s.isPrivateEndpointSubnet) ? 'Disabled' : 'Enabled'
        // For PE subnets, also recommended to disable privateLinkServiceNetworkPolicies
        privateLinkServiceNetworkPolicies: 'Disabled'
        networkSecurityGroup: {
          id: resourceId('Microsoft.Network/networkSecurityGroups', 'nsg-${vnetName}-${s.name}')
        }
      }
    }]
  }
}

// -----------------------
// Storage Account (private only) + Static Website
// -----------------------
resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
    }
    accessTier: 'Hot'
  }
}

// Enable Static Website (native resource)
resource staticSite 'Microsoft.Storage/storageAccounts/staticWebsite@2023-01-01' = {
  name: '${sa.name}/default'
  properties: {
    enabled: true
    indexDocument: staticIndex
    errorDocument404Path: static404
  }
}

// -----------------------
// Private DNS zones + VNet links (blob + web for static sites)
// -----------------------
resource pdzBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
  tags: tags
}

resource pdzWeb 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.web.core.windows.net'
  location: 'global'
  tags: tags
}

resource pdzBlobLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${pdzBlob.name}/${vnet.name}-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource pdzWebLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${pdzWeb.name}/${vnet.name}-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// -----------------------
// Private Endpoints (blob + web) in PE subnet + zone groups wiring
// -----------------------
var peSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, peSubnetName)

resource peBlob 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'sa-blob-pls'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: [
            'blob'
          ]
          requestMessage: 'PE for Storage Blob'
        }
      }
    ]
  }
}

resource peBlobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: '${peBlob.name}/default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-zone'
        properties: {
          privateDnsZoneId: pdzBlob.id
        }
      }
    ]
  }
}

resource peWeb 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageName}-web'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'sa-web-pls'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: [
            'web'
          ]
          requestMessage: 'PE for Storage Static Website'
        }
      }
    ]
  }
}

resource peWebDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: '${peWeb.name}/default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'web-zone'
        properties: {
          privateDnsZoneId: pdzWeb.id
        }
      }
    ]
  }
}

// -----------------------
// Optional: Jump VM (Ubuntu) in jump subnet
// -----------------------
@description('Public IP for jump VM (disabled by default).')
param createJumpPublicIp bool = false

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (createJumpVm && createJumpPublicIp) {
  name: '${jumpVmName}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = if (createJumpVm) {
  name: '${jumpVmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, jumpSubnetName)
          }
          publicIPAddress: createJumpPublicIp ? {
            id: pip.id
          } : null
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (createJumpVm) {
  name: jumpVmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    osProfile: {
      computerName: jumpVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        diskSizeGB: 64
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// -----------------------
// Azure Front Door (Standard_AzureFrontDoor) — SKELETON
// NOTE: This section provisions a functional profile + endpoint + origin group
// and a route with HTTP->HTTPS redirect. You will likely need to tweak
// the Private Link binding on the Origin to point to the storage "web" endpoint.
// -----------------------

resource afdProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: afdProfileName
  location: 'Global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  tags: tags
}

resource afdEndpoint 'Microsoft.Cdn/profiles/endpoints@2023-05-01' = {
  name: '${afdProfile.name}/${afdEndpointName}'
  location: 'Global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}

// Origin group (simple health probe)
resource afdOg 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  name: '${afdProfile.name}/${afdOriginGroupName}'
  properties: {
    sessionAffinityState: 'Disabled'
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 120
    }
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 0
    }
  }
}

// Origin (Storage Static Website host).
// IMPORTANT: To lock origin privately, set up AFD Private Link to the Storage "web" subresource.
// That requires "privateLink" settings on the origin which may vary by API version.
// This skeleton uses public connectivity (works end-to-end), while your Storage stays private
// to the VNet via PE; if you want AFD-only access, switch to Private Link after first deploy.
resource afdOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  name: '${afdProfile.name}/${afdOg.name}/${afdOriginName}'
  properties: {
    hostName: '${storageName}.web.core.windows.net'
    originHostHeader: '${storageName}.web.core.windows.net'
    httpPort: 80
    httpsPort: 443
    // TODO: Add "privateLink" block for Storage "web" subresource if you want private origin.
    // Example shape (verify properties in your subscription API version):
    // privateLink: {
    //   privateLinkResourceId: sa.id
    //   location: location
    //   requestMessage: 'AFD->Storage(web)'
    // }
  }
}

// Route (HTTP->HTTPS redirect; attach to endpoint)
resource afdRoute 'Microsoft.Cdn/profiles/routes@2023-05-01' = {
  name: '${afdProfile.name}/${afdRouteName}'
  properties: {
    originGroup: {
      id: afdOg.id
    }
    patternsToMatch: [
      '/*'
    ]
    endpointIds: [
      afdEndpoint.id
    ]
    httpsRedirect: 'Enabled' // This enforces http->https
    forwardingProtocol: 'HttpsOnly'
    supportedProtocols: [
      'Http'
      'Https'
    ]
    linkToDefaultDomain: 'Enabled' // keeps <endpoint>.azurefd.net usable
    // If you add custom domains later, associate them here via "customDomains" property.
  }
}

// Optional: RuleSet to add a couple of security headers on responses
resource afdRuleSet 'Microsoft.Cdn/profiles/ruleSets@2023-05-01' = {
  name: '${afdProfile.name}/${afdRuleSetName}'
}

resource afdRule 'Microsoft.Cdn/profiles/ruleSets/rules@2023-05-01' = {
  name: '${afdProfile.name}/${afdRuleSet.name}/add-sec-headers'
  properties: {
    order: 1
    conditions: [] // always apply
    actions: [
      {
        name: 'ModifyResponseHeader'
        parameters: {
          headerAction: 'Overwrite'
          headerName: 'Strict-Transport-Security'
          value: 'max-age=31536000; includeSubDomains; preload'
        }
      }
      {
        name: 'ModifyResponseHeader'
        parameters: {
          headerAction: 'Overwrite'
          headerName: 'X-Content-Type-Options'
          value: 'nosniff'
        }
      }
    ]
  }
}

// Attach the RuleSet to the Route
resource afdRouteUpdate 'Microsoft.Cdn/profiles/routes@2023-05-01' existing = {
  name: '${afdProfile.name}/${afdRouteName}'
}
resource attachRuleSet 'Microsoft.Cdn/profiles/routes@2023-05-01' = {
  name: '${afdProfile.name}/${afdRouteName}'
  properties: {
    originGroup: {
      id: afdOg.id
    }
    patternsToMatch: [
      '/*'
    ]
    endpointIds: [
      afdEndpoint.id
    ]
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    supportedProtocols: [
      'Http'
      'Https'
    ]
    linkToDefaultDomain: 'Enabled'
    ruleSets: [
      {
        id: afdRuleSet.id
      }
    ]
  }
  dependsOn: [
    afdRule
  ]
}

// -----------------------
// Outputs
// -----------------------
output storageStaticWebEndpoint string = 'https://${storageName}.z13.web.core.windows.net'
output privateBlobDnsZone string = pdzBlob.name
output privateWebDnsZone string = pdzWeb.name
output afdDefaultHost string = '${afdEndpointName}.z01.azurefd.net'