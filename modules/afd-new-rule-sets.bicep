@description('AFD profile name (Standard/Premium)')
param frontDoorProfileName string

@description('Ruleset name to create (letters/digits only, must start with a letter)')
param rulesetName string

@description('Optional: endpoint name carried by shared params; not used here')
param endpointName string = ''

@description('Rewrite rules to create')
/*
Each item may contain:
{
  path: '/webLogin',                // required
  operator: 'BeginsWith'|'Equal',   // required
  order: 10,                        // required
  ruleName: 'DeliveryRuleUrlPathWebLogin', // optional
  preserveUnmatchedPath: false             // optional (default false)
}
*/
param rewriteRules array

@description('Append /index.html to destination path for each rule')
param appendIndexHtml bool = true

resource profile 'Microsoft.Cdn/profiles@2023-05-01' existing = {
  name: frontDoorProfileName
}

resource ruleset 'Microsoft.Cdn/profiles/ruleSets@2023-05-01' = {
  name: rulesetName
  parent: profile
}

// Precompute normalized paths & resolved fields (no lambdas)
var normalizedRules = [
  for (r, i) in rewriteRules: {
    name: contains(r, 'ruleName') && string(r.ruleName) != '' ? string(r.ruleName) : 'rule-${i}'
    order: int(r.order)
    operator: string(r.operator)
    path: startsWith(string(r.path), '/') ? string(r.path) : '/${string(r.path)}'
    preserve: contains(r, 'preserveUnmatchedPath') ? r.preserveUnmatchedPath : false
  }
]

resource rules 'Microsoft.Cdn/profiles/ruleSets/rules@2023-05-01' = [for nr in normalizedRules: {
  name: nr.name
  parent: ruleset
  properties: {
    order: nr.order
    conditions: [
      {
        name: 'UrlPath'
        parameters: {
          typeName: 'DeliveryRuleUrlPathMatchConditionParameters'
          matchValues: [ nr.path ]
          operator: nr.operator         // 'BeginsWith' or 'Equal'
          negateCondition: false
          transforms: []
        }
      }
    ]
    actions: [
      {
        name: 'UrlRewrite'
        parameters: {
          typeName: 'DeliveryRuleUrlRewriteActionParameters'
          sourcePattern: nr.path
          destination: appendIndexHtml ? '${nr.path}/index.html' : nr.path
          preserveUnmatchedPath: nr.preserve   // = "No" in your UI when false
        }
      }
    ]
    matchProcessingBehavior: 'Stop'
  }
}]

output endpointName_passthrough string = endpointName
