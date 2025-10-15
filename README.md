🌐 Azure Static Web App Deployment (Bicep)
This repository contains the **Bicep infrastructure-as-code templates** for deploying one or multiple **Azure Static Web Apps** to Azure Front Door. It automates provisioning of the following resources:
•	- Static Web App(s) backed by Azure Storage (Static Website enabled)
- Azure Front Door with custom domain + HTTPS + WAF
- Private Endpoint for Storage (Blob + Web)
- Private DNS Zones for `privatelink.blob.core.windows.net`
- Network Security Groups for subnets
- Integration with an existing VNet and WAF Policy
🧩 Repository Structure
File / Folder	Purpose
main.bicep	Core Bicep template defining all resources
params/static_storage_afd_params.json	Parameters for static storage account and AFD profile deployment
params/afd-new-rule-sets-params.json	Parameters to create shared AFD rewrite rule set
params/afd-new-route-existing-ep-<microsite>.json	Parameters for each microsite’s AFD route definition (must be customized per site)
runners/afd-generic-rn.sh	Generic runner to deploy any Azure Front Door route
runners/deploy_main_static.sh	Main deployment script that orchestrates all static sites and AFD routes
README.md	Documentation (this file)

Run from your Linux distribution:
./runners/deploy_main_static.sh "pueblitoboyacense" rg-posada-prd mexicocentral ./main.bicep ./params/static_storage_afd_params.json
⚙️ Prerequisites
•	- Azure CLI ≥ 2.60
- Logged in: `az login`
- Target subscription set:
  ```bash
  az account set --subscription "<your-subscription-id>"
  ```
🧭 Multi‑Site Support (New Feature)
The repository now supports deploying **multiple static microsites** within the same Azure Storage account and Front Door profile.
Each microsite has its own route configuration and rewrite rule for SPA fallback behavior.
### How It Works
1. Each microsite has a dedicated parameter file under `/params/` named like `afd-new-route-existing-ep-<microsite>.json`.
2. You must **customize each parameter file** to match your own microsite folder name, route name, origin group, and rule set.
   - Example: `/login-spa`, `/proyectos`, `/operaciones`.
3. The script `deploy_main_static.sh` loops through all microsite parameter files and deploys their respective Front Door routes.
4. A single Front Door rule set (e.g., `cargagpeprbmicrosites`) rewrites requests to `index.html` for SPAs.
5. A purge is triggered automatically after deployment to refresh cached content in AFD.
6. Run the script once for each microsite you add to the parameters folder.
### Example structure:
```
azure_static_web_app/
 ├── main.bicep
 ├── params/
 │   ├── static_storage_afd_params.json
 │   ├── afd-new-rule-sets-params.json
 │   ├── afd-new-route-existing-ep-loginspa.json
 │   ├── afd-new-route-existing-ep-proyectos.json
 │   └── afd-new-route-existing-ep-operaciones.json
 └── runners/
     ├── afd-generic-rn.sh
     └── deploy_main_static.sh
```

### Example command
```bash
./runners/deploy_main_static.sh
```
This command automatically deploys all microsite routes defined under `/params/` using the shared static storage and Front Door profile.

If you create additional microsites, simply add a new parameter file following the same naming pattern and rerun the script.
✅ Benefits
- Single Front Door and Storage account serve multiple SPAs
- Centralized rewrite rules and WAF policy
- Fully automated multi-route deployment
- Simplified maintenance and consistent networking setup
- Easy scalability: just drop in another param file and redeploy
