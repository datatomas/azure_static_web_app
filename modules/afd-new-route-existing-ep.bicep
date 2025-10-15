@description('AFD profile name')
param frontDoorProfileName string

@description('AFD endpoint name')
param endpointName string

@description('Route name to create')
param routeName string

@description('Origin group name')
param originGroupName string

@description('Rule set names to associate')
param ruleSetNames array = []

@description('Patterns to match')
param patternsToMatch array = ['/*']

resource profile 'Microsoft.Cdn/profiles@2023-05-01' existing = {
  name: frontDoorProfileName
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' existing = {
  name: endpointName
  parent: profile
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' existing = {
  name: originGroupName
  parent: profile
}

resource ruleSets 'Microsoft.Cdn/profiles/ruleSets@2023-05-01' existing = [for rsName in ruleSetNames: {
  name: rsName
  parent: profile
}]

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  name: routeName
  parent: endpoint
  properties: {
    originGroup: {
      id: originGroup.id
    }
    ruleSets: [for (rsName, i) in ruleSetNames: {
      id: ruleSets[i].id
    }]
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: patternsToMatch
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
}

output routeName string = route.name
output routeId string = route.id
