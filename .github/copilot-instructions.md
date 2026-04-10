# Copilot Instructions — AVD-CustomerReady

## Architecture

This is an Azure Virtual Desktop proof-of-concept deployment tool consisting of two layers:

1. **Interactive PowerShell wrapper** (`Deploy-AVD.ps1`) — collects parameters via guided prompts, performs pre-flight checks (prerequisites, VM quota), and invokes the Bicep deployment with a live progress table sourced from the ARM operations API.
2. **Modular Bicep templates** — subscription-scoped orchestrator (`avdMain.bicep`) that conditionally wires 8 resource-group-scoped modules:

| Module | Resources | Condition |
|---|---|---|
| `networking.bicep` | VNet, Subnets, NSG | Greenfield (`deployNetworking`) |
| `keyvault.bicep` | Key Vault + secret + RBAC | Greenfield (`deployKeyVault`) |
| `avdcore.bicep` | Host Pool, Scaling Plan, App Group, Workspace, Storage, Gallery, VM, Diagnostics | Always |
| `monitor.bicep` | Log Analytics + Data Collection Rule | Greenfield (`deployMonitoring`) |
| `domain.bicep` | Domain Controller VM | Optional (`deployDomain`) |
| `bastion.bicep` | Azure Bastion (Developer SKU) | Optional (`deployBastion`) |
| `roleassignment.bicep` | AVD service principal RBAC (Power On + Power On Off Contributor) | Always (before avdcore) |
| `privateendpoints.bicep` | Private DNS zones, VNet links, PEs for KV + Storage | Optional (`deployPrivateEndpoints`) |

**Greenfield vs. Brownfield** is controlled by `deploy*` boolean parameters. When `false`, the corresponding module is skipped and existing resource IDs (`existing*Id` params) are used instead.

## Deployment Commands

```powershell
# Interactive deployment (primary workflow)
.\Deploy-AVD.ps1

# Manual deployment (bypass interactive wrapper)
az deployment sub create `
  --location eastus2 `
  --template-file avdMain.bicep `
  --parameters vmAdminPassword='<password>' `
  --name "avd-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Validate Bicep without deploying
az bicep build --file avdMain.bicep

# Standalone VM quota check
.\VMSizes\Test-VMQuota.ps1 -VmSize Standard_D4s_v5 -Location eastus2
```

## Key Conventions

### Bicep

- **Scope**: `avdMain.bicep` targets `subscription`; all modules target `resourceGroup` and are scoped via `scope: <rg>` in the orchestrator.
- **Global uniqueness**: Resources requiring globally unique names (Key Vault, Storage, Log Analytics, Public IP) use `uniqueString(subscription().subscriptionId, coreRgName)` as a suffix. If a user provides an explicit name, it takes precedence over the generated default.
- **Secrets**: Passwords are `@secure()` params — never store in parameter files or source. The deploying user's password is collected via `Read-Host -AsSecureString`.
- **Conditional deployment**: Use `deploy*` bool params to toggle modules; pair with `existing*Id` string params for brownfield references. Use the `!` (safe-dereference) operator when accessing outputs from conditional modules (e.g., `networking!.outputs.subnetId`).
- **Resource Group layout**: Three RGs — core (`rg-avd-core-poc`), networking (`rg-avd-network-poc`), monitoring (`rg-avd-monitor-poc`).

### Naming

| Resource Type | Pattern |
|---|---|
| Resource Group | `rg-avd-{function}-poc` |
| VNet / Subnet / NSG | `vnet-avd-poc` / `snet-avd-poc` / `nsg-avd-poc` |
| Host Pool / App Group / Workspace | `hp-avd-poc` / `ag-avd-poc` / `ws-avd-poc` |
| Scaling Plan | `{hostPoolName}-scaling` |
| Globally unique resources | `{prefix}{uniqueString}` (e.g., `kv2hfx7...`, `sa2hfx7...`) |

### PowerShell (`Deploy-AVD.ps1`)

- **Compatibility**: Must work on PowerShell 5.1 and 7.x. All JSON parsing uses PS5-safe patterns (pipe to `ConvertFrom-Json`, avoid `-AsHashtable`).
- **Helper functions**: `Read-PromptWithDefault`, `Read-YesNo`, `Read-Selection`, `Read-ListSelection` provide consistent interactive UX with bracket-delimited defaults.
- **Quota pre-flight**: `Invoke-VMQuotaCheck` maps VM size → quota family via `VMSizes/VM_Size_Family.csv` and queries `az vm list-usage`. Non-fatal — proceeds with a warning on CSV miss or API error.
- **Live progress table**: Polls ARM operations API during async deployment; durations come from `properties.duration` (ISO 8601, parsed by `Format-IsoDuration`).

### VM Quota CSV (`VMSizes/VM_Size_Family.csv`)

Format: `Size,Family,vCPUs`. Lines starting with `#` are comments. Currently covers General Compute D-series. To add new families, append rows matching the existing format. Note: Azure v6 quota family names differ from v5 — Intel uses `Standard` prefix with mixed-case (e.g., `StandardDsv6Family`), AMD uses `standard` prefix with lowercase (e.g., `standardDav6Family`).

## Security Constraints

- RBAC authorization on Key Vault (no access policies).
- Trusted Launch (Secure Boot + vTPM) enabled by default on all VMs.
- Bastion mode skips Public IP and uses a blank NSG.
- Private endpoints set `defaultAction: Deny` on Key Vault and Storage when enabled.
