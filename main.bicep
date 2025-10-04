// ============================================================================
// Pueblito Posada Infra (Mexico Central) — v1 (AFD Standard)
// Creates: VNet (+NSGs), Storage (static website), optional Private Endpoints
// (internal-only), AFD Standard with WAF & custom domains.
// NOTE: AFD Standard cannot use Private Link to reach the origin.
// ============================================================================

targetScope = 'resourceGroup'

// -----------------------
// Parameters
// -----------------------
@description('Deployment environment tag (e.g., dev/test/prod).')
param environment string = 'prod'

@description('Informational only. Does not change deployment scope.')
param resourceGroupName string = resourceGroup().name
 
@description('Primary custom domain (optional if using afdCustomDomains).')
param domainName string = ''

@description('Custom domains to attach to AFD (e.g., ["example.com","example.co"]).')
param afdCustomDomains array = empty(domainName) ? [] : [domainName]

@description('Name for the AFD WAF policy.')
param wafPolicyName string

@description('Reserved for future Data Factory module; not used in this template (kept to match params).')
param adfname string = ''

@description('All resources (except globally-scoped ones like AFD) use this Azure region.')
param location string

@description('Virtual network name.')
param vnetName string

@description('VNet address space. Adjust if you already have IP plan.')
param vnetCidr string = '10.40.0.0/16'

@description('Subnets to create. Each will get its own NSG with baseline rules. Mark one as the PE subnet.')
param subnets array = [
  {
    name: 'snet-jump'
    prefix: '10.40.10.0/24'
    isPrivateEndpointSubnet: false
    allowSshFrom: '0.0.0.0/0'
  }
  {
    name: 'snet-pe'
    prefix: '10.40.20.0/24'
    isPrivateEndpointSubnet: true
  }
]

@description('Storage account name (lowercase, 3-24). Static website is enabled.')
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

// ---------- Azure Front Door (Standard) ----------
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
param afdRuleSetName string = 'rulesetSecHeaders'

// -----------------------
// Locals
// -----------------------
var tags = union({
  workload: 'pueblito-posada'
  env: environment
  rg: resourceGroupName
}, empty(adfname) ? {} : { adfName: adfname })

// Use the conventional names from the default subnets above
var peSubnetName = 'snet-pe'
var jumpSubnetName = 'snet-jump'

// Build AFD custom-domain IDs from names (no resource-collection references)
var afdDomainIds = [for d in afdCustomDomains: resourceId('Microsoft.Cdn/profiles/customDomains', afdProfileName, replace(d, '.', '-'))]

// Static-website public host (keep simple/portable)
var storageWebHost = '${storageName}.web.${az.environment().suffixes.storage}'
// -----------------------
// Networking: NSGs + VNet/Subnets
// -----------------------
resource nsgs 'Microsoft.Network/networkSecurityGroups@2023-09-01' = [for s in subnets: {
  name: 'nsg-${vnetName}-${s.name}'
  location: location
  tags: tags
  properties: {
    securityRules: union(
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

// ---- VNet (must exist before PE/links) ----
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  // make sure NSGs exist before we attach them to subnets
  dependsOn: [ for n in nsgs: n ]
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetCidr ]
    }
    subnets: [for s in subnets: {
      name: s.name
      properties: {
        addressPrefix: s.prefix
        privateEndpointNetworkPolicies: s.isPrivateEndpointSubnet ? 'Disabled' : 'Enabled'
        privateLinkServiceNetworkPolicies: 'Disabled'
        networkSecurityGroup: {
          id: resourceId('Microsoft.Network/networkSecurityGroups', 'nsg-${vnetName}-${s.name}')
        }
      }
    }]
  }
}


// -----------------------
// Storage Account (public network access for AFD Standard) + Static Website
// -----------------------
resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    // AFD Standard needs public reachability to the web endpoint
    networkAcls: {
      defaultAction: 'Allow'
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

// Change ONLY the apiVersion
resource staticSite 'Microsoft.Storage/storageAccounts/staticWebsite@2019-06-01' = {
  name: 'default'
  parent: sa
  properties: {
    enabled: true
    indexDocument: staticIndex
    errorDocument404Path: static404
  }
}

// -----------------------
// (Optional/Internal) Private DNS zones + VNet links + PEs
// NOTE: These PEs are usable for internal VNet access, NOT by AFD Standard.
// -----------------------
resource pdzBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${az.environment().suffixes.storage}'
  location: 'global'
  tags: tags
}


resource pdzWeb 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.web.${az.environment().suffixes.storage}'
  location: 'global'
  tags: tags
}


// Private DNS VNet links must wait for both zone and VNet
resource pdzBlobLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${vnet.name}-link'
  parent: pdzBlob
  location: 'global'
  dependsOn: [ pdzBlob, vnet ]  // <---
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource pdzWebLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${vnet.name}-link'
  parent: pdzWeb
  location: 'global'
  dependsOn: [ pdzWeb, vnet ]  // <---
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// PEs must wait for VNet (and Storage). Web PE also waits for Static Website.
resource peBlob 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageName}-blob'
  location: location
  tags: tags
  dependsOn: [ vnet, sa ]  // <---
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'sa-blob-pls'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: [ 'blob' ]
          requestMessage: 'PE for Storage Blob'
        }
      }
    ]
  }
}

resource peWeb 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageName}-web'
  location: location
  tags: tags
  dependsOn: [ vnet, sa, staticSite ]  // <---
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'sa-web-pls'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: [ 'web' ]
          requestMessage: 'PE for Storage Static Website'
        }
      }
    ]
  }
}

resource peWebDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'default'
  parent: peWeb
  dependsOn: [ peWeb, pdzWeb ]  // <---
  properties: {
    privateDnsZoneConfigs: [
      { name: 'web-zone', properties: { privateDnsZoneId: pdzWeb.id } }
    ]
  }
}

var peSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, peSubnetName)

resource peBlob 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'sa-blob-pls'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: [ 'blob' ]
          requestMessage: 'PE for Storage Blob'
        }
      }
    ]
  }
}

resource peBlobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'default'
  parent: peBlob
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-zone'
        properties: { privateDnsZoneId: pdzBlob.id }
      }
    ]
  }
}

resource peWeb 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageName}-web'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'sa-web-pls'
        properties: {
          privateLinkServiceId: sa.id
          groupIds: [ 'web' ]
          requestMessage: 'PE for Storage Static Website'
        }
      }
    ]
  }
}

resource peWebDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'default'
  parent: peWeb
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'web-zone'
        properties: { privateDnsZoneId: pdzWeb.id }
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
          publicIPAddress: createJumpPublicIp ? { id: pip.id } : null
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
    hardwareProfile: { vmSize: 'Standard_B2s' }
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
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
  }
}

// -----------------------
// Azure Front Door (Standard_AzureFrontDoor)
// -----------------------
resource afdProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: afdProfileName
  location: 'Global'
  sku: { name: 'Standard_AzureFrontDoor' }
  tags: tags
}

// Custom domains
resource afdDomains 'Microsoft.Cdn/profiles/customDomains@2024-02-01' = [for d in afdCustomDomains: {
  name: replace(d, '.', '-')
  parent: afdProfile
  properties: {
    hostName: d
    tlsSettings: { certificateType: 'ManagedCertificate' }
  }
}]

// Endpoint (AFD-specific type)
resource afdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  name: afdEndpointName
  parent: afdProfile
  location: 'Global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}

// Origin group (under profile)
resource afdOg 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  name: afdOriginGroupName
  parent: afdProfile
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

// Origin (under origin group) - public static website host
resource afdOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  name: afdOriginName
  parent: afdOg
  properties: {
    hostName: storageWebHost
    originHostHeader: storageWebHost
    httpPort: 80
    httpsPort: 443
  }
}

// Route (under endpoint) (adds dependsOn so custom domains exist first)
resource afdRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  name: afdRouteName
  parent: afdEndpoint
  // Ensure all custom domains are created before the route references them
  dependsOn: [ for d in afdDomains: d ]
  properties: {
    originGroup: { id: afdOg.id }
    patternsToMatch: [ '/*' ]
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    supportedProtocols: [ 'Http', 'Https' ]
    linkToDefaultDomain: 'Enabled'
    customDomains: [ for id in afdDomainIds: { id: id } ]
  }
}


// Optional: RuleSet to add security headers (older API to avoid typeName warnings)
resource afdRuleSet 'Microsoft.Cdn/profiles/ruleSets@2023-05-01' = {
  name: afdRuleSetName
  parent: afdProfile
}

resource afdRule 'Microsoft.Cdn/profiles/ruleSets/rules@2023-05-01' = {
  name: 'addSecHeaders'
  parent: afdRuleSet
  properties: any({
    order: 1
    conditions: []
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
  })
}


// -----------------------
// WAF policy (Standard) + association to domains
// -----------------------
resource afdWaf 'Microsoft.Cdn/cdnWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: 'Global'
  sku: { name: 'Standard_AzureFrontDoor' }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
      defaultCustomBlockResponseStatusCode: 403
      // defaultCustomBlockResponseBody omitted to avoid base64 pattern warning
    }
    managedRules: {
      managedRuleSets: [
        { ruleSetType: 'OWASP', ruleSetVersion: '3.2' }
      ]
    }
  }
}

//afdSecPolicy (adds dependsOn so domain IDs resolve)
resource afdSecPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  name: 'waf-assoc'
  parent: afdProfile
  // Ensure AFD custom domains exist before associating WAF to them
  dependsOn: [ for d in afdDomains: d ]
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: { id: afdWaf.id }
      associations: [
        {
          domains: [ for id in afdDomainIds: { id: id } ]
          patternsToMatch: [ '/*' ]
        }
      ]
    }
  }
}

// -----------------------
// Outputs
// -----------------------
output storageStaticWebEndpoint string = 'https://${storageWebHost}'
output privateBlobDnsZone string = pdzBlob.name
output privateWebDnsZone string = pdzWeb.name
output afdDefaultHost string = afdEndpoint.properties.hostName
