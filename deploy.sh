#!/usr/bin/env bash
# ================================================================
# Deploy Azure Static Web App + Front Door via Bicep
# ================================================================

set -e

RG_NAME="RG_PUEBLITO_STATIC_PRD"
LOCATION="mexicocentral"

echo "🔹 Checking Azure login..."
az account show >/dev/null 2>&1 || az login

echo "🔹 Ensuring resource group exists..."
az group create --name "$RG_NAME" --location "$LOCATION"

echo "🚀 Deploying Bicep template..."
az deployment group create \
  --name deployStaticWebApp \
  --resource-group "$RG_NAME" \
  --template-file main.bicep \
  --parameters @parameters.json

echo "✅ Deployment completed successfully."
