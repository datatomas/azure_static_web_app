#!/usr/bin/env bash
# ================================================================
# Deploy Azure Static Web App + Front Door via Bicep
# ================================================================

set -e

: "${RG:?Set RG in ~/.env (resource group)}"
: "${REGION:?Set REGION in ~/.env (e.g. mexicocentral)}"


echo "🔹 Checking Azure login..."
az account show >/dev/null 2>&1 || az login

echo "🔹 Ensuring resource group exists..."
az group create --name "$RG" --location "$REGION"

echo "🚀 Deploying Bicep template..."
az deployment group create \
  --name deployStaticWebApp \
  --resource-group "$RG" \
  --template-file static_storage_afd.bicep \
  --parameters @static_storage_afd_params.json

echo "✅ Deployment completed successfully."
