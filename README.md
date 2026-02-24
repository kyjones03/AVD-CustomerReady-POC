# Azure Virtual Desktop — Proof of Concept Deployment

> **Disclaimer:** This project is an independent community contribution and is **not** affiliated with, endorsed by, or associated with any official Microsoft accelerators or programs. It is provided as-is, with no warranties or guarantees. Use at your own discretion.

An interactive, IaC-driven solution to deploy a **customer-ready Azure Virtual Desktop environment** using **Azure Bicep** and **PowerShell**. Supports both **greenfield** (net-new) and **brownfield** (existing infrastructure) flows.

---

## Features

- **Interactive deployment** — guided PowerShell experience with sensible defaults
- **Greenfield & Brownfield** — deploy everything from scratch or leverage existing VNet / Key Vault / Storage / Log Analytics
- **Live progress tracking** — real-time status table showing each resource deployment as it completes
- **Modular Bicep templates** — clean, subscription-scoped infrastructure as code
- **Scaling plan** — auto-created and linked to the host pool (Personal or Pooled)
- **Security-first** — Key Vault integration, Trusted Launch, RBAC authorization, no secrets in source
- **Bastion-aware** — skips public IP and uses blank NSG when Bastion is enabled
- **Image picker** — dynamically lists available Windows 11 offers and SKUs from your region

---

## Prerequisites

| Requirement | Minimum Version |
|---|---|
| Azure CLI | 2.50+ |
| Bicep CLI | 0.20+ (auto-installed if missing) |
| PowerShell | 7.x recommended; 5.1 supported |
| Azure Subscription | Contributor role at subscription scope |
| Azure AD | Permissions to register apps (if using AAD Kerberos for storage) |

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
4. Let you pick a Windows 11 image from your region
5. Deploy asynchronously with a **live progress table** showing per-resource status
6. Display a summary with resource names, registration token, portal links, and any errors

---

## Project Structure

```
├── avdMain.bicep                  # Orchestrator — subscription scope
├── avdParams.bicepparam           # Default parameter values (reference only)
├── modules/
│   ├── networking.bicep           # VNet, Subnets, NSG (blank when Bastion enabled)
│   ├── keyvault.bicep             # Key Vault + secrets + RBAC
│   ├── avdcore.bicep              # Host pool, scaling plan, app group, workspace, storage, gallery, VM
│   ├── monitor.bicep              # Log Analytics + Data Collection Rule
│   ├── domain.bicep               # Domain controller (conditional)
│   ├── bastion.bicep              # Azure Bastion Developer SKU (conditional)
│   └── roleassignment.bicep       # AVD service principal role assignments
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
- Virtual Network, Subnet, NSG
- Key Vault with VM admin secret
- AVD Host Pool, Scaling Plan, Application Group, Workspace
- Storage Account with FSLogix profile share
- Azure Compute Gallery
- Template VM with Public IP and NIC
- Log Analytics Workspace + Data Collection Rule
- Role Assignments (Power On Contributor + Power On Off Contributor)
- *(Optional)* Domain Controller VM
- *(Optional)* Azure Bastion (Developer SKU — skips PIP, uses blank NSG)

### Brownfield — Leverage Existing Infrastructure

You're prompted to select or enter existing:

| Existing Resource | Selection Method |
|---|---|
| Resource Groups | Pick from list or enter name |
| Virtual Network / Subnet | Pick from list |
| Key Vault | Pick from list |
| Storage Account | Pick from list |
| Log Analytics Workspace | Pick from list |
| Template VM | Option to skip building a new VM |

When existing resources are provided, the corresponding Bicep module is skipped. Admin passwords are stored in the selected existing Key Vault automatically.

---

## Resources Deployed

| Resource | Module | When Deployed |
|---|---|---|
| Resource Groups (3) | `avdMain.bicep` | Always (idempotent) |
| Role Assignments (2) | `roleassignment.bicep` | Always (before AVD core) |
| NSG, VNet, Subnet | `networking.bicep` | Greenfield only |
| Key Vault + Secret | `keyvault.bicep` | Greenfield only |
| Host Pool + Scaling Plan | `avdcore.bicep` | Always |
| Application Group + Workspace | `avdcore.bicep` | Always |
| Storage Account (FSLogix) | `avdcore.bicep` | Greenfield only (skippable) |
| Azure Compute Gallery | `avdcore.bicep` | Always |
| Template VM + NIC | `avdcore.bicep` | Optional (skippable in brownfield) |
| Public IP | `avdcore.bicep` | Only when no Bastion |
| Log Analytics Workspace | `monitor.bicep` | Greenfield only |
| Data Collection Rule | `monitor.bicep` | Optional |
| Domain Controller VM | `domain.bicep` | Optional |
| Azure Bastion | `bastion.bicep` | Optional |

---

## Live Deployment Progress

The deployment runs asynchronously and displays a live-updating status table:

```
  Deployment: avd-poc-20260210-180130    [Running - 02:15]

  Operation                                Status          Duration
  ──────────────────────────────────────────────────────────────────────
  rg-avd-core-poc                          Succeeded       00:12
  rg-avd-network-poc                       Succeeded       00:08
  roleAssignmentDeployment                 Succeeded       00:25
  networkingDeployment                     Succeeded       01:02
  keyVaultDeployment                       Running         01:45
  avdCoreDeployment                        Accepted        —
```

Statuses are color-coded: **green** = Succeeded, **cyan** = Running, **red** = Failed.

---

## Security

| Practice | Detail |
|---|---|
| **No secrets in source** | Admin passwords collected via `Read-Host -AsSecureString` and passed as `@secure()` Bicep parameters |
| **Key Vault** | Stores VM admin password; RBAC authorization enabled; soft delete with 90-day retention |
| **Trusted Launch** | Secure Boot + vTPM enabled by default on all VMs |
| **NSG** | Default allows RDP from `*` (warns operator); blank NSG when Bastion is enabled |
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

## Future Enhancements (Out of Scope for V1)

- Image capturing with regional image replication via Azure Compute Gallery
- Automated session host provisioning from golden image with AD and Entra ID join capabilities
- Private endpoints for Storage & Key Vault
- Scaling plan schedule configurations
- Azure Policy assignments
- CI/CD pipeline (GitHub Actions)

---

## License

This project is licensed under the [MIT License](LICENSE).

