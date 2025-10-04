# 🌐 Azure Static Web App Deployment (Bicep)

This repository contains the **Bicep infrastructure-as-code template** for deploying the **A Static Web App** to Azure.  
It automates provisioning of the following:

- Static Web App backed by Azure Storage (Static Website enabled)
- Azure Front Door with custom domain + HTTPS + WAF
- Private Endpoint for Storage (Blob + Web)
- Private DNS Zones for `privatelink.blob.core.windows.net`
- Network Security Groups for subnets
- Integration with an existing VNet and WAF Policy

---

## 🧩 Repository structure

| File | Purpose |
|------|----------|
| `main.bicep` | Core Bicep template defining all resources |
| `parameters.json` | Deployment parameters (editable) |
| `deploy.sh` | CLI script to deploy the stack |
| `README.md` | Documentation (this file) |

---

## ⚙️ Prerequisites

- Azure CLI ≥ 2.60  
- Logged in: `az login`  
- Target subscription set:  
  ```bash
  az account set --subscription "<your-subscription-id>"
