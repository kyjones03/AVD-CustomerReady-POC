# Azure Virtual Desktop — Proof of Concept Deployment

> **Disclaimer:** This project is an independent community contribution and is **not** affiliated with, endorsed by, or associated with any official Microsoft accelerators or programs. It is provided as-is, with no warranties or guarantees. Use at your own discretion.

An interactive, IaC-driven solution to deploy a **customer-ready Azure Virtual Desktop environment** using **Azure Bicep** and **PowerShell**. Supports both **greenfield** (net-new) and **brownfield** (existing infrastructure) flows.

---

## Features

- **Interactive deployment** — guided PowerShell experience with sensible defaults
- **Greenfield & Brownfield** — deploy everything from scratch or leverage existing VNet / Key Vault / Storage / Log Analytics
- **Live progress tracking** — real-time status table with accurate per-operation durations sourced directly from the ARM operations API
- **Modular Bicep templates** — clean, subscription-scoped infrastructure as code
- **Scaling plan** — auto-created and linked to the host pool (Personal or Pooled); skipped for Regional scope deployments
- **Security-first** — Key Vault integration, Trusted Launch, RBAC authorization, no secrets in source
- **AVD diagnostics** — diagnostic settings automatically configured on the Host Pool, Application Group, and Workspace, sending logs to the Log Analytics Workspace
- **Private endpoints** — optional network isolation for Key Vault and FSLogix Storage Account with private DNS auto-registration
- **Bastion-aware** — skips public IP and uses blank NSG when Bastion is enabled
- **Image picker** — dynamically lists available Windows 11 offers and SKUs from your region; default SKU is automatically matched to pool type (`win11-24h2-ent` for Personal, `win11-24h2-avd` for Pooled)
- **Quota pre-flight** — checks available vCPU quota for the chosen VM size before deployment starts, with an interactive retry loop if quota is insufficient
- **Deployment scope selection** — choose Geographical (default, metadata distributed across paired Azure regions) or Regional [PREVIEW] (all metadata in a single region for data residency needs)
- **Secure credential entry** — admin password confirmation loops until both entries match before proceeding

---

## Prerequisites

| Requirement | Minimum Version |
|---|---|
| Azure CLI | 2.50+ |
| Bicep CLI | 0.20+ (auto-installed if missing) |
| PowerShell | 7.x recommended; 5.1 fully supported (all JSON parsing is PS5-safe) |
| Azure Subscription | Contributor role at subscription scope for resource deployment |
| Azure Subscription | Owner, Role-Based Access Administrator, or User Access Administrator at subscription or resource group scope for AVD service principal role assignment |
| Azure AD | Permissions to register apps (if using AAD Kerberos for storage) |

### Required Resource Providers

The following resource providers must be registered on the target subscription before deployment. Unregistered providers will cause ARM to reject individual module deployments mid-run.

| Provider | Used For |
|---|---|
| `Microsoft.DesktopVirtualization` | Host pools, application groups, workspaces, scaling plans |
| `Microsoft.Compute` | Virtual machines, Azure Compute Gallery, VM extensions |
| `Microsoft.Network` | VNet, subnets, NSG, NICs, Public IPs, Bastion, Private Endpoints |
| `Microsoft.KeyVault` | Key Vault and secrets |
| `Microsoft.Storage` | Storage Account for FSLogix profile shares |
| `Microsoft.OperationalInsights` | Log Analytics Workspace |
| `Microsoft.Insights` | Data Collection Rules and DCR associations |
| `Microsoft.Authorization` | RBAC role assignments |
| `Microsoft.Quota` | Enables quota querying capabilities  |

To register all providers in one step:

```powershell
$providers = @(
    'Microsoft.DesktopVirtualization',
    'Microsoft.Compute',
    'Microsoft.Network',
    'Microsoft.KeyVault',
    'Microsoft.Storage',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.Authorization'
)
foreach ($rp in $providers) {
    az provider register --namespace $rp --wait
    Write-Host "Registered $rp" -ForegroundColor Green
}
```

> **Note:** Provider registration is idempotent — re-running against an already-registered provider is safe. Registration typically takes 1–3 minutes per provider.

---

## Quick Start

```powershell
# 1. Clone the repo and navigate to it
cd AVD-CustomerReady

# 2. Run the interactive deployment
.\Deploy-AVD.ps1

# 3. Follow the on-screen prompts
```

The script will:
1. Verify prerequisites (Azure CLI, Bicep, login status)
2. Ask you to choose **Greenfield** or **Brownfield**
3. Collect all parameters with sensible defaults
4. Prompt for a VM admin password — the confirmation prompt loops until both entries match
5. Let you pick a Windows 11 image from your region
6. Deploy asynchronously with a **live progress table** showing per-resource status
7. Display a summary with resource names, registration token, portal links, and any errors

---

## Project Structure

```
├── avdMain.bicep                  # Orchestrator — subscription scope
├── avdParams.bicepparam           # Default parameter values (reference only)
├── modules/
│   ├── networking.bicep           # VNet, Subnets (AVD + PE), NSG
│   ├── keyvault.bicep             # Key Vault + secrets + RBAC + optional network ACLs
│   ├── avdcore.bicep              # Host pool, scaling plan, app group, workspace, storage, gallery, VM, diagnostic settings
│   ├── monitor.bicep              # Log Analytics + Data Collection Rule (perf counters → Azure Monitor Metrics)
│   ├── domain.bicep               # Domain controller (conditional)
│   ├── bastion.bicep              # Azure Bastion Developer SKU (conditional)
│   ├── roleassignment.bicep       # AVD service principal role assignments
│   └── privateendpoints.bicep     # Private DNS zones, VNet links, PEs for KV + Storage (conditional)
├── VMSizes/
│   ├── VM_Size_Family.csv         # ARM size → quota family + vCPU count mapping (General Compute D-series)
│   └── Test-VMQuota.ps1           # Standalone quota check script for ad-hoc validation
├── imageCapture/
│   └── imagecapture.ps1           # Image capture & gallery versioning workflow
├── Deploy-AVD.ps1                 # Interactive PowerShell deployment wrapper
├── .gitignore
└── README.md                      # This file
```

---

## Deployment Paths

### Greenfield — Deploy Everything

All resources are created from scratch:

- 3 Resource Groups (core, networking, monitoring)
- Virtual Network, AVD Subnet, NSG
- Key Vault with VM admin secret
- AVD Host Pool, Scaling Plan, Application Group, Workspace
- Diagnostic Settings on Host Pool, Application Group, and Workspace → Log Analytics
- Storage Account with FSLogix profile share
- Azure Compute Gallery
- Template VM with Public IP and NIC
- Log Analytics Workspace + Data Collection Rule
- Role Assignments (Power On Contributor + Power On Off Contributor)
- *(Optional)* Domain Controller VM
- *(Optional)* Azure Bastion (Developer SKU — skips PIP, uses blank NSG)
- *(Optional)* Private Endpoints for Key Vault and FSLogix Storage (dedicated PE subnet, private DNS zones)

### Brownfield — Leverage Existing Infrastructure

You're prompted to select or enter existing:

| Existing Resource | Selection Method |
|---|---|
| Resource Groups | Pick from list or enter name |
| Virtual Network / Subnet | Pick from list |
| Key Vault | Pick from list |
| Storage Account | Pick from list |
| Log Analytics Workspace | Pick from list (resource ID resolved automatically for diagnostics) |
| Template VM | Option to skip building a new VM |

When existing resources are provided, the corresponding Bicep module is skipped. Admin passwords are stored in the selected existing Key Vault automatically.

---

## Deployment Scope

The deployment scope controls where Azure Virtual Desktop host pool metadata is stored. You are prompted to choose at the start of deployment.

| Option | Behaviour |
|---|---|
| **Geographical** *(default)* | Metadata distributed across paired Azure regions within the same geography — the standard, most resilient option |
| **Regional** *(preview)* | Metadata stored entirely within the selected Azure region — for strict data residency requirements |

> **Preview notice:** Regional host pools are currently in public preview and have specific limitations — notably, scaling plans are not supported and will be skipped automatically. Review the [Regional host pools documentation](https://learn.microsoft.com/en-us/azure/virtual-desktop/regional-host-pools) before selecting this option. The deployment script surfaces this reminder inline when Regional is chosen.

---

## Resources Deployed

| Resource | Module | When Deployed |
|---|---|---|
| Resource Groups (3) | `avdMain.bicep` | Always (idempotent) |
| Role Assignments (2) | `roleassignment.bicep` | Always (before AVD core) |
| NSG, VNet, AVD Subnet | `networking.bicep` | Greenfield only |
| PE Subnet | `networking.bicep` | When private endpoints enabled |
| Key Vault + Secret | `keyvault.bicep` | Greenfield only |
| Host Pool + Scaling Plan | `avdcore.bicep` | Always (Scaling Plan skipped for Regional scope) |
| Application Group + Workspace | `avdcore.bicep` | Always |
| Diagnostic Settings (Host Pool, App Group, Workspace) | `avdcore.bicep` | When a Log Analytics Workspace is available |
| Storage Account (FSLogix) | `avdcore.bicep` | Greenfield only (skippable) |
| Azure Compute Gallery | `avdcore.bicep` | Always |
| Template VM + NIC | `avdcore.bicep` | Optional (skippable in brownfield) |
| Public IP | `avdcore.bicep` | Only when no Bastion |
| Log Analytics Workspace | `monitor.bicep` | Greenfield only |
| Data Collection Rule (perf → Azure Monitor Metrics) | `monitor.bicep` | Optional |
| Domain Controller VM | `domain.bicep` | Optional |
| Azure Bastion | `bastion.bicep` | Optional |
| Private DNS Zones + VNet Links | `privateendpoints.bicep` | When private endpoints enabled |
| Private Endpoints (KV + Storage) | `privateendpoints.bicep` | When private endpoints enabled |

---

## Live Deployment Progress

The deployment runs asynchronously and displays a live-updating status table. Duration values for completed operations are sourced from the ARM operations API (`properties.duration`) — the same timestamps shown in the Azure portal. In-progress operations show a live elapsed counter.

```
  Deployment: avd-poc-20260305-152207    [Succeeded - 03:33]

  Operation                                Status          Duration
  ──────────────────────────────────────────────────────────────────────
  rg-avd-core-poc                          Succeeded       -
  rg-avd-network-poc                       Succeeded       -
  roleAssignmentDeployment                 Succeeded       00:00
  networkingDeployment                     Succeeded       00:27
  keyVaultDeployment                       Succeeded       00:27
  avdCoreDeployment                        Succeeded       01:48
  privateEndpointsDeployment               Succeeded       02:15
```

Statuses are color-coded: **green** = Succeeded, **cyan** = Running/Accepted, **red** = Failed.

---

When selecting the template VM image, the recommended SKU is automatically matched to the host pool type chosen earlier in the flow:

| Host Pool Type | Recommended SKU | Notes |
|---|---|---|
| Personal | `win11-24h2-ent` | Single-session Windows 11 Enterprise |
| Pooled | `win11-24h2-avd` | Multi-session Windows 11 Enterprise for AVD |

The recommended SKU is pre-selected as the default in the SKU list and marked with `*`. Any other SKU in the list can still be chosen.

---

## VM Quota Pre-flight Check

After the VM size is entered, the deployment script automatically checks whether sufficient vCPU quota is available in the target region before proceeding.

### How it works

1. The chosen VM size is looked up in `VMSizes/VM_Size_Family.csv` to resolve its quota family name and vCPU requirement.
2. `az vm list-usage` is queried for that family in the selected region.
3. Available vCPUs (limit − current usage) are compared against the requirement.

### Outcomes

| Result | Behaviour |
|---|---|
| Sufficient quota | Green confirmation line; continues to next prompt |
| Insufficient quota | Shows family / available / needed in red; offers: choose different size, proceed anyway, or exit |
| Size not in CSV | Warning displayed; offers: choose different size, proceed anyway, or exit |
| API / CLI error | Warning displayed; offers: choose different size, proceed anyway, or exit |

The quota result is echoed in the pre-deployment summary so the operator has a clear record before confirming.

### Standalone test script

`VMSizes/Test-VMQuota.ps1` can be used independently for ad-hoc checks without running a full deployment:

```powershell
# Check a specific size in a region
.\VMSizes\Test-VMQuota.ps1 -VmSize Standard_D4s_v5 -Location eastus2

# Check if enough quota exists for two VMs of the same size
.\VMSizes\Test-VMQuota.ps1 -VmSize Standard_D8s_v5 -Location eastus2 -RequiredVcpus 16
```

Exit codes: `0` = sufficient, `1` = CSV miss or CLI error, `2` = quota too low.

### Extending the size map

`VMSizes/VM_Size_Family.csv` currently covers all General Compute D-series families (Dv2 through Dv5, AMD, Arm/Ampere, and Confidential variants). To add additional families (E-series, B-series, etc.), append rows following the same `Size,Family,vCPUs` format. Lines beginning with `#` are treated as comments.

---

## Image SKU Defaults

| Practice | Detail |
|---|---|
| **No secrets in source** | Admin passwords collected via `Read-Host -AsSecureString` and passed as `@secure()` Bicep parameters |
| **Key Vault** | Stores VM admin password; RBAC authorization enabled; soft delete with 90-day retention |
| **Private endpoints** | Optional: Key Vault and FSLogix Storage network-isolated with `defaultAction: Deny` + private DNS zones (`privatelink.vaultcore.azure.net`, `privatelink.file.core.windows.net`) |
| **Trusted Launch** | Secure Boot + vTPM enabled by default on all VMs |
| **NSG** | Default allows RDP from `*`; operator warning displayed only when `*` is used — suppressed when a specific IP or CIDR is entered; blank NSG when Bastion is enabled |
| **No Public IP with Bastion** | Template VM skips public IP when Bastion provides secure access |
| **RBAC** | Key Vault Secrets Officer for deploying user; Power On Contributor + Power On Off Contributor for AVD service principal |

---

## Manual Deployment

If you prefer to deploy without the interactive wrapper:

```powershell
az deployment sub create `
  --location eastus2 `
  --template-file avdMain.bicep `
  --parameters vmAdminPassword='<your-password>' `
  --name "avd-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
```

Override any default with `--parameters key=value`. See `avdParams.bicepparam` for the full parameter list.

---

## Naming Conventions

| Resource Type | Pattern | Example |
|---|---|---|
| Resource Group | `rg-avd-{function}-poc` | `rg-avd-core-poc` |
| Virtual Network | `vnet-avd-poc` | `vnet-avd-poc` |
| Subnet | `snet-avd-poc` | `snet-avd-poc` |
| NSG | `nsg-avd-poc` | `nsg-avd-poc` |
| Host Pool | `hp-avd-poc` | `hp-avd-poc` |
| Scaling Plan | `{hostpool}-scaling` | `hp-avd-poc-scaling` |
| Application Group | `ag-avd-poc` | `ag-avd-poc` |
| Workspace | `ws-avd-poc` | `ws-avd-poc` |
| Storage Account | `sa{uniqueString}` | `sa2hfx7...` |
| Key Vault | `kv{uniqueString}` | `kv2hfx7...` |
| Compute Gallery | `acgavdpoc` | `acgavdpoc` |
| Log Analytics | `la{uniqueString}` | `la2hfx7...` |
| Public IP | `pip{uniqueString}` | `pip2hfx7...` |
| VM | `avdtemplate01` | `avdtemplate01` |

Names requiring global uniqueness use `uniqueString()` to avoid collisions.

---

## Future Enhancements

- Image capturing with regional image replication via Azure Compute Gallery
- Automated session host provisioning from golden image with AD and Entra ID join capabilities
- Storage Account AD join provisioning
- Scaling plan schedule configurations
- CI/CD pipeline (GitHub Actions)
- Expand `VM_Size_Family.csv` to cover B-series, E-series, F-series, and N-series families

---

## License

This project is licensed under the [MIT License](LICENSE).

