#!/usr/bin/env bash
set -euo pipefail
set -E -o pipefail

# ===== Hardcoded defaults (fallback only) =====
DEFAULT_BICEP="/mnt/c/Users/SuarezTo/OneDrive - Unisys/Documents/GitHub/unisys_infra_repo/iac/modules/afd-new-route.bicep"
DEFAULT_PARAMS="/mnt/c/Users/SuarezTo/OneDrive - Unisys/Documents/GitHub/unisys_infra_repo/iac/params/afd-new-route-params.json"

# Prefer env vars, fallback to hardcoded
BICEP_FILE="${BICEP_FILE:-$DEFAULT_BICEP}"
PARAMS_FILE="${PARAMS_FILE:-$DEFAULT_PARAMS}"
DO_PURGE="${DO_PURGE:-false}"
DO_WHATIF="${DO_WHATIF:-false}"
# =================================================

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
need az; need jq; command -v dos2unix >/dev/null || true

# Load ~/.env (WSL-safe)
if [[ -f "$HOME/.env" ]]; then 
  dos2unix -q "$HOME/.env" 2>/dev/null || true
  set -a; . "$HOME/.env"; set +a
fi

: "${SUB:?Set SUB in ~/.env (subscription id or name)}"
RESOURCE_GROUP="${RESOURCE_GROUP:-${RG:-}}"; : "${RESOURCE_GROUP:?Set RG or RESOURCE_GROUP in ~/.env}"

[[ -f "$BICEP_FILE"  ]] || { echo "ERROR: missing bicep:  $BICEP_FILE";  exit 1; }
[[ -f "$PARAMS_FILE" ]] || { echo "ERROR: missing params: $PARAMS_FILE"; exit 1; }

# Extract params from JSON, prefer env vars
param(){ jq -re ".parameters.$1.value | select(type!=null and .!=\"\")" "$PARAMS_FILE" 2>/dev/null || echo ""; }
AFD_PROFILE="${AFD_PROFILE:-$(param frontDoorProfileName)}"
AFD_ENDPOINT="${AFD_ENDPOINT:-$(param endpointName)}"
AFD_RS_MICROSITES="${AFD_RS_MICROSITES:-$(param ruleSetNames | jq -r '.[0]?' 2>/dev/null || echo "")}"
AFD_ORIGIN_GROUP="${AFD_ORIGIN_GROUP:-$(param originGroupName)}"

LOG="$(mktemp "${TMPDIR:-/tmp}/afd_deploy_${EPOCHSECONDS:-$(date +%s)}_XXXXXX")"
exec > >(tee -a "$LOG") 2>&1

echo "================================================"
echo "Azure Front Door Generic Deployment Script"
echo "================================================"
echo "Subscription:     $SUB"
echo "Resource Group:   $RESOURCE_GROUP"
echo "Bicep File:       $BICEP_FILE"
echo "Params File:      $PARAMS_FILE"
[[ -n "$AFD_PROFILE" ]]      && echo "AFD Profile:      $AFD_PROFILE"
[[ -n "$AFD_ENDPOINT" ]]     && echo "AFD Endpoint:     $AFD_ENDPOINT"
[[ -n "$AFD_RS_MICROSITES" ]] && echo "AFD Ruleset:      $AFD_RS_MICROSITES"
[[ -n "$AFD_ORIGIN_GROUP" ]]  && echo "Origin Group:     $AFD_ORIGIN_GROUP"
echo "Do What-If:       $DO_WHATIF"
echo "Do Purge:         $DO_PURGE"
echo "================================================"
echo

trap 'code=$?; 
      if [[ $code -ne 0 ]]; then
        echo
        echo "❌ Failed (exit $code) at: $BASH_COMMAND"
        if [[ -n "${DEPLOYMENT_NAME:-}" ]]; then
          echo "==> Failed operations for $DEPLOYMENT_NAME"
          az deployment operation group list \
            -g "$RESOURCE_GROUP" \
            -n "$DEPLOYMENT_NAME" \
            -o json 2>/dev/null \
          | jq -r ".[] | select(.properties.provisioningState==\"Failed\") |
                   .properties.statusMessage |
                   (.. | .message? // empty)" 2>/dev/null || true
        fi
        echo "Log: $LOG"
      fi
     ' ERR EXIT

echo "==> az account set ($SUB)"
az account set --subscription "$SUB"

if [[ -n "$AFD_PROFILE" ]]; then
  echo "==> Checking AFD profile exists…"
  az afd profile show -g "$RESOURCE_GROUP" -n "$AFD_PROFILE" -o none
fi

if [[ -n "$AFD_ENDPOINT" && -n "$AFD_PROFILE" ]]; then
  echo "==> Checking AFD endpoint exists…"
  az afd endpoint show -g "$RESOURCE_GROUP" --profile-name "$AFD_PROFILE" -n "$AFD_ENDPOINT" -o none
fi

echo "==> Bicep compile check"
az bicep build --file "$BICEP_FILE" -o none

DEPLOYMENT_NAME="afd-deploy-$(date +%s)"

# Optional: Run what-if analysis
if [[ "$DO_WHATIF" == "true" ]]; then
  echo "==> WHAT-IF: $DEPLOYMENT_NAME"
  az deployment group what-if \
    -g "$RESOURCE_GROUP" \
    -n "$DEPLOYMENT_NAME" \
    -f "$BICEP_FILE" \
    -p @"$PARAMS_FILE" \
    --result-format FullResourcePayloads
  
  read -p "Continue with deployment? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled"
    exit 0
  fi
fi

echo "==> DEPLOY: $DEPLOYMENT_NAME"
DEPLOY_OUTPUT=$(az deployment group create \
  -g "$RESOURCE_GROUP" \
  -n "$DEPLOYMENT_NAME" \
  -f "$BICEP_FILE" \
  -p @"$PARAMS_FILE" \
  -o json 2>&1) || {
    echo "❌ Deployment failed"
    echo "$DEPLOY_OUTPUT"
    exit 1
  }

echo "$DEPLOY_OUTPUT" | jq . 2>/dev/null || echo "$DEPLOY_OUTPUT"

PROVISION_STATE=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.provisioningState' 2>/dev/null || echo "Unknown")

if [[ "$PROVISION_STATE" == "Succeeded" ]]; then
  echo "✅ Deployment succeeded"
else
  echo "⚠️  Deployment state: $PROVISION_STATE"
fi

echo "==> Outputs:"
az deployment group show \
  -g "$RESOURCE_GROUP" \
  -n "$DEPLOYMENT_NAME" \
  --query "properties.outputs" \
  -o json 2>/dev/null \
| jq -r 'to_entries[] | "\(.key): \(.value.value)"' 2>/dev/null || echo "(no outputs)"

if [[ "$DO_PURGE" == "true" && -n "$AFD_PROFILE" && -n "$AFD_ENDPOINT" ]]; then
  echo "==> Purging endpoint content: $AFD_ENDPOINT (profile: $AFD_PROFILE)"
  az afd endpoint purge \
    --resource-group "$RESOURCE_GROUP" \
    --profile-name   "$AFD_PROFILE" \
    --endpoint-name  "$AFD_ENDPOINT" \
    --content-paths "/*" || {
      echo "⚠️  Purge failed but deployment succeeded"
    }
fi

echo
echo "✅ Done. Log: $LOG"
