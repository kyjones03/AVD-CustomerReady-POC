#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive deployment wrapper for Azure Virtual Desktop Proof of Concept.
.DESCRIPTION
    Collects deployment parameters through an interactive prompt experience and deploys
    an AVD environment using Azure Bicep templates. Supports both greenfield (net-new)
    and brownfield (existing infrastructure) deployment flows.
.NOTES
    Prerequisites: Azure CLI 2.50+, Bicep CLI 0.20+, PowerShell 5.1+
.EXAMPLE
    .\Deploy-AVD.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

# ==========================================================
# Helper Functions
# ==========================================================

function Write-Banner {
    param([string]$Text)
    $line = '=' * 70
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$line`n" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Text)
    Write-Host "`n--- $Text ---`n" -ForegroundColor Yellow
}

function Read-PromptWithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    $displayDefault = if ($Default) { " [$Default]" } else { "" }
    $value = Read-Host "$Prompt$displayDefault"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Format-IsoDuration {
    # Converts an ISO 8601 duration string (e.g. "PT1M48.5S") returned by the ARM
    # operations API into a human-readable mm:ss string.
    param([string]$IsoDuration)
    try {
        $ts = [System.Xml.XmlConvert]::ToTimeSpan($IsoDuration)
        return '{0:mm\:ss}' -f $ts
    }
    catch {
        return $IsoDuration
    }
}

function Invoke-VMQuotaCheck {
    <#
    .SYNOPSIS
        Looks up the quota family for a VM size and checks available vCPU quota.
    .OUTPUTS
        Hashtable: Checked, Sufficient, Available, Needed, Family, WarningMessage
    #>
    param(
        [string]$VmSize,
        [string]$Location,
        [string]$CsvPath
    )

    $result = @{
        Checked        = $false
        Sufficient     = $true   # default safe - non-fatal if CSV miss
        Available      = 0
        Needed         = 0
        Family         = ''
        WarningMessage = ''
    }

    # -- CSV lookup --
    if (-not (Test-Path $CsvPath)) {
        $result.WarningMessage = "Size map CSV not found at '$CsvPath' - quota check skipped."
        return $result
    }

    $rows = Get-Content $CsvPath |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } |
        ConvertFrom-Csv

    $entry = $rows | Where-Object { $_.Size -ieq $VmSize } | Select-Object -First 1

    if (-not $entry) {
        $result.WarningMessage = "'$VmSize' not found in size map - quota check skipped. Verify manually if needed."
        return $result
    }

    $result.Checked = $true
    $result.Family  = $entry.Family
    $result.Needed  = [int]$entry.vCPUs

    # -- Live quota query --
    try {
        $usageJson = az vm list-usage `
            --location $Location `
            --query "[?name.value=='$($entry.Family)']" `
            --output json 2>$null

        if (-not $usageJson -or $usageJson -eq '[]') {
            $result.WarningMessage = "No quota entry for family '$($entry.Family)' in '$Location' - check skipped."
            $result.Checked = $false
            return $result
        }

        $usageEntry      = $usageJson | ConvertFrom-Json | Select-Object -First 1
        $result.Available = [int]$usageEntry.limit - [int]$usageEntry.currentValue
        $result.Sufficient = ($result.Available -ge $result.Needed)
    }
    catch {
        $result.WarningMessage = "Quota query failed: $($_.Exception.Message) - check skipped."
        $result.Checked = $false
    }

    return $result
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )
    $defaultText = if ($Default) { "Y/n" } else { "y/N" }
    $value = Read-Host "$Prompt [$defaultText]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value -match '^[Yy]'
}

function Read-Selection {
    param(
        [string]$Prompt,
        [string[]]$Options,
        [int]$Default = 1
    )
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i + 1 -eq $Default) { " *" } else { "" }
        Write-Host "  [$($i + 1)] $($Options[$i])$marker"
    }
    $value = Read-Host "Selection [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return [int]$value
}

function Read-ListSelection {
    param(
        [string]$Prompt,
        [array]$Items,
        [string]$DisplayProperty,
        [string]$Default
    )
    if ($Items.Count -eq 0) { return $null }
    Write-Host $Prompt
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $display = if ($DisplayProperty) { $Items[$i].$DisplayProperty } else { $Items[$i] }
        Write-Host "  [$($i + 1)] $display"
    }
    Write-Host ""
    $value = Read-PromptWithDefault "Select (number) or enter a name" $Default
    if ($value -match '^\d+$' -and [int]$value -ge 1 -and [int]$value -le $Items.Count) {
        return $Items[[int]$value - 1]
    }
    return $value
}

# ==========================================================
# Prerequisites Check
# ==========================================================

function Test-Prerequisites {
    Write-Banner "Azure Virtual Desktop - POC Deployment"
    Write-Section "Prerequisites Check"

    # Check Azure CLI
    Write-Host "Checking Azure CLI... " -NoNewline
    try {
        $azVersion = az version --output json 2>$null | ConvertFrom-Json
        Write-Host "v$($azVersion.'azure-cli')" -ForegroundColor Green
    }
    catch {
        Write-Host "NOT FOUND" -ForegroundColor Red
        Write-Host "Please install Azure CLI: https://docs.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    }

    # Check Bicep
    Write-Host "Checking Bicep CLI... " -NoNewline
    try {
        $bicepVersion = az bicep version 2>&1
        Write-Host "$bicepVersion" -ForegroundColor Green
    }
    catch {
        Write-Host "NOT FOUND - installing..." -ForegroundColor Yellow
        az bicep install
    }

    # Check login
    Write-Host "Checking Azure login... " -NoNewline
    try {
        $account = az account show --output json 2>$null | ConvertFrom-Json
        Write-Host "Logged in as $($account.user.name)" -ForegroundColor Green
    }
    catch {
        Write-Host "Not logged in" -ForegroundColor Yellow
        Write-Host "Launching Azure login..."
        az login --output none
        $account = az account show --output json | ConvertFrom-Json
    }

    # Display and confirm subscription
    Write-Host "`nCurrent Subscription:" -ForegroundColor White
    Write-Host "  Name: $($account.name)"
    Write-Host "  ID:   $($account.id)"

    $useSub = Read-YesNo "Use this subscription?" $true
    if (-not $useSub) {
        Write-Host ""
        az account list --output table
        Write-Host ""
        $subId = Read-Host "Enter subscription ID"
        az account set --subscription $subId
        $account = az account show --output json | ConvertFrom-Json
        Write-Host "Switched to: $($account.name)" -ForegroundColor Green
    }

    # Get current user object ID for RBAC
    $currentUserObjectId = ""
    try {
        $currentUserObjectId = az ad signed-in-user show --query id -o tsv 2>$null
    }
    catch {
        Write-Host "  Could not retrieve user object ID (RBAC assignment will be skipped)" -ForegroundColor Yellow
    }

    return @{
        SubscriptionId      = $account.id
        SubscriptionName    = $account.name
        TenantId            = $account.tenantId
        CurrentUserObjectId = $currentUserObjectId
    }
}

# ==========================================================
# Parameter Collection
# ==========================================================

function Get-DeploymentParameters {
    param([hashtable]$Context)

    $params = @{}

    # -- Deployment Path --
    Write-Section "Deployment Path"
    $pathChoice = Read-Selection "Select deployment path:" @(
        "Greenfield  - Deploy all resources from scratch"
        "Brownfield  - Use existing networking/identity infrastructure"
    ) 1
    $isGreenfield = ($pathChoice -eq 1)
    $params.isGreenfield = $isGreenfield

    # -- General --
    Write-Section "General Settings"
    $params.location = Read-PromptWithDefault "Azure region" "eastus2"

    # -- Resource Groups --
    Write-Section "Resource Groups"
    if ($isGreenfield) {
        $params.coreRgName    = Read-PromptWithDefault "Core resource group name" "rg-avd-core-poc"
        $params.networkRgName = Read-PromptWithDefault "Networking resource group name" "rg-avd-network-poc"
        $params.monitorRgName = Read-PromptWithDefault "Monitoring resource group name" "rg-avd-monitor-poc"
    }
    else {
        Write-Host "Fetching existing resource groups..." -ForegroundColor Yellow
        $existingRgs = @(az group list --query "[].name" -o json 2>$null | ConvertFrom-Json)

        if ($existingRgs -and $existingRgs.Count -gt 0) {
            $selectedCore = Read-ListSelection "`nExisting Resource Groups:" $existingRgs $null "rg-avd-core-poc"
            $params.coreRgName = if ($selectedCore -is [string]) { $selectedCore } else { $selectedCore }

            $selectedNet = Read-ListSelection "`nSelect Networking RG:" $existingRgs $null "rg-avd-network-poc"
            $params.networkRgName = if ($selectedNet -is [string]) { $selectedNet } else { $selectedNet }

            $selectedMon = Read-ListSelection "`nSelect Monitoring RG:" $existingRgs $null "rg-avd-monitor-poc"
            $params.monitorRgName = if ($selectedMon -is [string]) { $selectedMon } else { $selectedMon }
        }
        else {
            $params.coreRgName    = Read-PromptWithDefault "Core resource group name" "rg-avd-core-poc"
            $params.networkRgName = Read-PromptWithDefault "Networking resource group name" "rg-avd-network-poc"
            $params.monitorRgName = Read-PromptWithDefault "Monitoring resource group name" "rg-avd-monitor-poc"
        }
    }

    # -- Networking --
    Write-Section "Networking"
    $params.deployNetworking = $isGreenfield
    $params.existingSubnetId = ''
    $params.existingVnetId = ''

    if ($isGreenfield) {
        $params.vnetName        = Read-PromptWithDefault "Virtual Network name" "vnet-avd-poc"
        $params.vnetAddressSpace = Read-PromptWithDefault "VNet address space" "10.0.0.0/16"
        $params.subnetName      = Read-PromptWithDefault "Subnet name" "snet-avd-poc"
        $params.subnetPrefix    = Read-PromptWithDefault "Subnet prefix" "10.0.0.0/24"
        $params.nsgName         = Read-PromptWithDefault "NSG name" "nsg-avd-poc"

        Write-Host ""
        Write-Host "  WARNING: Default NSG rule allows RDP from ANY source (*)." -ForegroundColor Red
        Write-Host "  Scope the source IP to your network for production use." -ForegroundColor Red

        $customDns = Read-YesNo "`nConfigure custom DNS servers?" $false
        if ($customDns) {
            $dnsInput = Read-Host "Enter DNS server IPs (comma-separated)"
            $params.dnsServers = @($dnsInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        else {
            $params.dnsServers = @()
        }
    }
    else {
        Write-Host "Fetching existing Virtual Networks..." -ForegroundColor Yellow
        $existingVnets = @(az network vnet list --query "[].{Name:name, ResourceGroup:resourceGroup, Address:addressSpace.addressPrefixes[0]}" -o json 2>$null | ConvertFrom-Json)

        if ($existingVnets -and $existingVnets.Count -gt 0) {
            Write-Host "`nExisting Virtual Networks:"
            for ($i = 0; $i -lt $existingVnets.Count; $i++) {
                Write-Host "  [$($i + 1)] $($existingVnets[$i].Name)  (RG: $($existingVnets[$i].ResourceGroup), Space: $($existingVnets[$i].Address))"
            }
            $vnetIdx = Read-Host "`nSelect VNet (number)"
            $selectedVnet = $existingVnets[[int]$vnetIdx - 1]

            # Get subnets
            $existingSubnets = @(az network vnet subnet list `
                --resource-group $selectedVnet.ResourceGroup `
                --vnet-name $selectedVnet.Name `
                --query "[].{Name:name, Prefix:addressPrefix, Id:id}" -o json | ConvertFrom-Json)

            if ($existingSubnets -and $existingSubnets.Count -gt 0) {
                Write-Host "`nSubnets in $($selectedVnet.Name):"
                for ($i = 0; $i -lt $existingSubnets.Count; $i++) {
                    Write-Host "  [$($i + 1)] $($existingSubnets[$i].Name) ($($existingSubnets[$i].Prefix))"
                }
                $subnetIdx = Read-Host "Select subnet (number)"
                $params.existingSubnetId = $existingSubnets[[int]$subnetIdx - 1].Id
            }

            $params.existingVnetId = az network vnet show `
                --resource-group $selectedVnet.ResourceGroup `
                --name $selectedVnet.Name `
                --query id -o tsv
        }
        else {
            Write-Host "No existing VNets found. Will create new networking." -ForegroundColor Yellow
            $params.deployNetworking = $true
            $params.vnetName         = Read-PromptWithDefault "Virtual Network name" "vnet-avd-poc"
            $params.vnetAddressSpace = Read-PromptWithDefault "VNet address space" "10.0.0.0/16"
            $params.subnetName       = Read-PromptWithDefault "Subnet name" "snet-avd-poc"
            $params.subnetPrefix     = Read-PromptWithDefault "Subnet prefix" "10.0.0.0/24"
            $params.nsgName          = Read-PromptWithDefault "NSG name" "nsg-avd-poc"
            $params.dnsServers       = @()
        }
    }

    # -- AVD Configuration --
    Write-Section "AVD Configuration"
    $poolTypeChoice = Read-Selection "Host pool type:" @(
        "Personal  (Persistent desktop assignment)"
        "Pooled    (Shared desktops)"
    ) 1
    $params.hostPoolType          = if ($poolTypeChoice -eq 1) { 'Personal' } else { 'Pooled' }
    # SKU recommendation tracks pool type: personal desktops use the enterprise image,
    # pooled desktops use the multi-session AVD-optimised image.
    $recommendedSku = if ($params.hostPoolType -eq 'Personal') { 'win11-24h2-ent' } else { 'win11-24h2-avd' }
    $params.hostPoolName          = Read-PromptWithDefault "Host pool name" "hp-avd-poc"
    $params.appGroupName          = Read-PromptWithDefault "Application group name" "ag-avd-poc"
    $params.workspaceName         = Read-PromptWithDefault "Workspace name" "ws-avd-poc"
    $params.workspaceFriendlyName = Read-PromptWithDefault "Workspace friendly name" "AVD POC Workspace"

    # -- Compute / Image Selection --
    Write-Section "Compute Configuration"

    $params.deployTemplateVm = $true
    if (-not $isGreenfield) {
        $params.deployTemplateVm = Read-YesNo "Build a new template VM?" $true
    }

    if ($params.deployTemplateVm) {
        Write-Host "Fetching available Windows 11 image offers for '$($params.location)'..." -ForegroundColor Yellow
        $offers = @(az vm image list-offers `
            --location $params.location `
            --publisher MicrosoftWindowsDesktop `
            --query "[?contains(name, 'windows-11')].name" -o json 2>$null | ConvertFrom-Json)

        if ($offers -and $offers.Count -gt 0) {
            Write-Host "`nAvailable Windows 11 Offers:"
            for ($i = 0; $i -lt $offers.Count; $i++) {
                Write-Host "  [$($i + 1)] $($offers[$i])"
            }
            $offerIdx      = Read-PromptWithDefault "`nSelect offer (number)" "1"
            $selectedOffer = $offers[[int]$offerIdx - 1]
            $params.vmImageOffer = $selectedOffer

            Write-Host "`nFetching SKUs for '$selectedOffer'..." -ForegroundColor Yellow
            $skus = @(az vm image list-skus `
                --location $params.location `
                --publisher MicrosoftWindowsDesktop `
                --offer $selectedOffer `
                --query "[].name" -o json 2>$null | ConvertFrom-Json)

            if ($skus -and $skus.Count -gt 0) {
                # Find the 1-based index of the recommended SKU; fall back to 1 if not listed.
                $recommendedSkuIdx = '1'
                for ($i = 0; $i -lt $skus.Count; $i++) {
                    if ($skus[$i] -eq $recommendedSku) { $recommendedSkuIdx = ($i + 1).ToString(); break }
                }
                Write-Host "`nAvailable SKUs:  (* = recommended for $($params.hostPoolType))"
                for ($i = 0; $i -lt $skus.Count; $i++) {
                    $marker = if ($skus[$i] -eq $recommendedSku) { ' *' } else { '' }
                    Write-Host "  [$($i + 1)] $($skus[$i])$marker"
                }
                $skuIdx           = Read-PromptWithDefault "`nSelect SKU (number)" $recommendedSkuIdx
                $params.vmImageSku = $skus[[int]$skuIdx - 1]
            }
            else {
                $params.vmImageSku = Read-PromptWithDefault "Image SKU" $recommendedSku
            }
        }
        else {
            Write-Host "  Could not fetch image list. Using defaults." -ForegroundColor Yellow
            $params.vmImageOffer = Read-PromptWithDefault "Image offer" "windows-11"
            $params.vmImageSku   = Read-PromptWithDefault "Image SKU" $recommendedSku
        }
        $params.vmImagePublisher = 'MicrosoftWindowsDesktop'
        $params.vmName           = Read-PromptWithDefault "Template VM name" "avdtemplate01"

        # -- VM size + quota check loop --
        $quotaCsvPath = Join-Path $scriptDir "VMSizes\VM_Size_Family.csv"
        $quotaResult  = $null
        do {
            $params.vmSize = Read-PromptWithDefault "VM size" "Standard_D4s_v5"

            Write-Host "  Checking quota for '$($params.vmSize)' in '$($params.location)'..." -ForegroundColor Yellow
            $quotaResult = Invoke-VMQuotaCheck -VmSize $params.vmSize -Location $params.location -CsvPath $quotaCsvPath

            if (-not $quotaResult.Checked) {
                # CSV miss or API failure - advisory only, not a hard gate
                Write-Host "  NOTE: $($quotaResult.WarningMessage)" -ForegroundColor Yellow
                break
            }

            if ($quotaResult.Sufficient) {
                Write-Host "  Quota OK - $($quotaResult.Available) vCPUs available, $($quotaResult.Needed) needed ($($quotaResult.Family))." -ForegroundColor Green
                break
            }

            # Insufficient quota - present options
            Write-Host ""
            Write-Host "  INSUFFICIENT QUOTA" -ForegroundColor Red
            Write-Host "  Family    : $($quotaResult.Family)" -ForegroundColor Red
            Write-Host "  Available : $($quotaResult.Available) vCPUs" -ForegroundColor Red
            Write-Host "  Needed    : $($quotaResult.Needed) vCPUs" -ForegroundColor Red
            Write-Host ""
            $quotaChoice = Read-Selection "How would you like to proceed?" @(
                "Choose a different VM size"
                "Proceed anyway  (I will request a quota increase)"
                "Exit"
            ) 1
            if ($quotaChoice -eq 2) {
                Write-Host "  Proceeding with insufficient quota at user request." -ForegroundColor Yellow
                break
            }
            if ($quotaChoice -eq 3) {
                Write-Host "Deployment cancelled." -ForegroundColor Yellow
                exit 0
            }
            # choice 1 - loop back to re-prompt
        } while (-not $quotaResult.Sufficient)

        $params.quotaResult      = $quotaResult
        $params.vmAdminUsername  = Read-PromptWithDefault "VM admin username" "avdadmin"
        $params.enableTrustedLaunch = Read-YesNo "Enable Trusted Launch (Secure Boot + vTPM)?" $true
    }
    else {
        Write-Host "  Skipping template VM creation." -ForegroundColor Yellow
        # Set defaults so Bicep params are satisfied (VM won't be deployed)
        $params.vmImagePublisher = 'MicrosoftWindowsDesktop'
        $params.vmImageOffer     = 'windows-11'
        $params.vmImageSku       = $recommendedSku
        $params.vmName           = 'avdtemplate01'
        $params.vmSize           = 'Standard_D4s_v5'
        $params.vmAdminUsername   = 'avdadmin'
        $params.enableTrustedLaunch = $true
    }

    # -- Storage --
    Write-Section "Storage Configuration"

    $params.deployStorage = $true
    if (-not $isGreenfield) {
        $useExistingSa = Read-YesNo "Use an existing Storage Account?" $false
        if ($useExistingSa) {
            Write-Host "Fetching existing Storage Accounts..." -ForegroundColor Yellow
            $existingSas = @(az storage account list `
                --query "[].{Name:name, RG:resourceGroup, Kind:kind, SKU:sku.name}" -o json 2>$null | ConvertFrom-Json)

            if ($existingSas -and $existingSas.Count -gt 0) {
                Write-Host "`nExisting Storage Accounts:"
                for ($i = 0; $i -lt $existingSas.Count; $i++) {
                    Write-Host "  [$($i + 1)] $($existingSas[$i].Name)  (RG: $($existingSas[$i].RG), Kind: $($existingSas[$i].Kind))"
                }
                $saIdx = Read-Host "Select Storage Account (number)"
                $selectedSa = $existingSas[[int]$saIdx - 1]
                $params.existingStorageAccountName = $selectedSa.Name
                $params.existingStorageAccountRg = $selectedSa.RG
                $params.deployStorage = $false
                Write-Host "  Using existing storage account '$($selectedSa.Name)'." -ForegroundColor Green
            }
            else {
                Write-Host "  No existing storage accounts found. Will create new." -ForegroundColor Yellow
            }
        }
    }

    if ($params.deployStorage) {
        $params.storageAccountName  = Read-PromptWithDefault "Storage account name (blank = auto-generated)" ""
        $params.fslogixShareName    = Read-PromptWithDefault "FSLogix share name" "fslogixprofiles"
        $params.enableAadKerberosAuth = Read-YesNo "Enable AAD Kerberos auth for Azure Files?" $true
    }
    else {
        $params.storageAccountName    = ''
        $params.fslogixShareName      = 'fslogixprofiles'
        $params.enableAadKerberosAuth = $true
    }

    # -- Security --
    Write-Section "Security Configuration"

    # Key Vault - brownfield asks first
    $params.deployKeyVault = $true
    if (-not $isGreenfield) {
        $useExistingKv = Read-YesNo "Use an existing Key Vault?" $false
        if ($useExistingKv) {
            Write-Host "Fetching existing Key Vaults..." -ForegroundColor Yellow
            $existingKvs = @(az keyvault list --query "[].{Name:name, RG:resourceGroup}" -o json 2>$null | ConvertFrom-Json)

            if ($existingKvs -and $existingKvs.Count -gt 0) {
                Write-Host "`nExisting Key Vaults:"
                for ($i = 0; $i -lt $existingKvs.Count; $i++) {
                    Write-Host "  [$($i + 1)] $($existingKvs[$i].Name)  (RG: $($existingKvs[$i].RG))"
                }
                $kvIdx = Read-Host "Select Key Vault (number)"
                $selectedKv = $existingKvs[[int]$kvIdx - 1]
                $params.existingKeyVaultName = $selectedKv.Name
                $params.existingKeyVaultRg = $selectedKv.RG
                $params.deployKeyVault = $false
            }
            else {
                Write-Host "  No existing Key Vaults found. Will create new." -ForegroundColor Yellow
            }
        }
    }

    # New Key Vault name (only if creating new)
    if ($params.deployKeyVault) {
        $params.keyVaultName = Read-PromptWithDefault "Key Vault name (blank = auto-generated)" ""
    }
    else {
        $params.keyVaultName = ''
    }

    # Admin password
    Write-Host "`nEnter the VM admin password (stored in Key Vault):" -ForegroundColor Yellow
    $securePassword  = Read-Host -AsSecureString "  Admin password"
    $confirmPassword = Read-Host -AsSecureString "  Confirm password"

    $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPassword)
    $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
    $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)

    if ($plain1 -ne $plain2) {
        Write-Host "Passwords do not match. Exiting." -ForegroundColor Red
        exit 1
    }
    $params.vmAdminPassword = $plain1
    $plain2 = $null

    # Store password in existing Key Vault if brownfield
    if (-not $params.deployKeyVault -and $params.existingKeyVaultName) {
        Write-Host "Storing admin password in existing Key Vault '$($params.existingKeyVaultName)'..." -ForegroundColor Yellow
        try {
            az keyvault secret set `
                --vault-name $params.existingKeyVaultName `
                --name 'AVDAdminPassword' `
                --value $params.vmAdminPassword `
                --output none 2>$null
            Write-Host "  Password stored successfully." -ForegroundColor Green
        }
        catch {
            Write-Host "  WARNING: Could not store password in Key Vault. You may need to add it manually." -ForegroundColor Red
        }
    }

    # -- Monitoring --
    Write-Section "Monitoring Configuration"
    $params.deployMonitoring = $true

    if (-not $isGreenfield) {
        $useExistingLa = Read-YesNo "Use an existing Log Analytics workspace?" $false
        if ($useExistingLa) {
            Write-Host "Fetching existing Log Analytics workspaces..." -ForegroundColor Yellow
            $existingLas = @(az monitor log-analytics workspace list `
                --query "[].{Name:name, RG:resourceGroup}" -o json 2>$null | ConvertFrom-Json)

            if ($existingLas -and $existingLas.Count -gt 0) {
                Write-Host "`nExisting Workspaces:"
                for ($i = 0; $i -lt $existingLas.Count; $i++) {
                    Write-Host "  [$($i + 1)] $($existingLas[$i].Name)  (RG: $($existingLas[$i].RG))"
                }
                $laIdx = Read-Host "Select workspace (number)"
                $selectedLa = $existingLas[[int]$laIdx - 1]
                $params.existingLogAnalyticsName = $selectedLa.Name
                $params.existingLogAnalyticsRg = $selectedLa.RG
                $laId = az monitor log-analytics workspace show `
                    --workspace-name $selectedLa.Name `
                    --resource-group $selectedLa.RG `
                    --query id -o tsv 2>$null
                if ($laId) { $params.existingLogAnalyticsWorkspaceId = $laId.Trim() }
                $params.deployMonitoring = $false
            }
        }
    }

    if ($params.deployMonitoring) {
        $params.logAnalyticsName = Read-PromptWithDefault "Log Analytics workspace name (blank = auto-generated)" ""
        $params.deployDcr        = Read-YesNo "Deploy Data Collection Rule (performance counters)?" $true
    }

    # -- Optional Features --
    Write-Section "Optional Features"
    $params.deployDomain = Read-YesNo "Deploy a Domain Controller VM?" $false
    if ($params.deployDomain) {
        $params.domainVmSize = Read-PromptWithDefault "Domain Controller VM size" "Standard_D2s_v5"
    }

    $params.deployBastion = Read-YesNo "Deploy Azure Bastion (Developer SKU)?" $false

    # -- Private Endpoints --
    Write-Host ""
    $params.deployPrivateEndpoints = Read-YesNo "Deploy Private Endpoints for Key Vault and FSLogix Storage?" $false
    if ($params.deployPrivateEndpoints) {
        Write-Host ""
        Write-Host "  Private endpoints will:" -ForegroundColor Yellow
        Write-Host "    - Add a dedicated PE subnet to the VNet" -ForegroundColor Yellow
        Write-Host "    - Lock Key Vault and Storage to deny all public network access" -ForegroundColor Yellow
        Write-Host "    - Create private DNS zones for vaultcore and file sub-resources" -ForegroundColor Yellow
        Write-Host ""
        if ($params.deployNetworking) {
            $params.peSubnetName       = Read-PromptWithDefault "PE subnet name" "snet-pe-poc"
            $params.peSubnetPrefix     = Read-PromptWithDefault "PE subnet prefix" "10.0.1.0/24"
            $params.existingPeSubnetId = ''
        }
        else {
            Write-Host "  Brownfield: provide the existing subnet resource ID for private endpoints."
            $params.existingPeSubnetId = Read-Host "  Existing PE subnet resource ID"
            $params.peSubnetName       = 'snet-pe-poc'
            $params.peSubnetPrefix     = '10.0.1.0/24'
        }
    }
    else {
        $params.peSubnetName        = 'snet-pe-poc'
        $params.peSubnetPrefix      = '10.0.1.0/24'
        $params.existingPeSubnetId  = ''
    }

    # Carry forward context
    $params.currentUserObjectId = $Context.CurrentUserObjectId

    return $params
}

# ==========================================================
# Deployment Execution
# ==========================================================

function Start-AVDDeployment {
    param([hashtable]$Params)

    Write-Banner "Deployment Summary"

    Write-Host "  Deployment Path:    $(if ($Params.isGreenfield) { 'Greenfield' } else { 'Brownfield' })"
    Write-Host "  Location:           $($Params.location)"
    Write-Host "  Core RG:            $($Params.coreRgName)"
    Write-Host "  Network RG:         $($Params.networkRgName)"
    Write-Host "  Monitor RG:         $($Params.monitorRgName)"
    Write-Host "  Host Pool:          $($Params.hostPoolName) ($($Params.hostPoolType))"
    Write-Host "  Template VM:        $(if ($Params.deployTemplateVm) { "$($Params.vmSize) - $($Params.vmImageOffer)/$($Params.vmImageSku)" } else { 'Skipped (existing)' })"
    if ($Params.deployTemplateVm -and $Params.quotaResult) {
        $qr = $Params.quotaResult
        if (-not $qr.Checked) {
            Write-Host "  VM Quota:           [SKIPPED - $($qr.WarningMessage)]" -ForegroundColor Yellow
        } elseif ($qr.Sufficient) {
            Write-Host "  VM Quota:           $($qr.Family) - $($qr.Available) available / $($qr.Needed) needed  OK" -ForegroundColor Green
        } else {
            Write-Host "  VM Quota:           $($qr.Family) - $($qr.Available) available / $($qr.Needed) needed  [WARNING - proceeding at user request]" -ForegroundColor Yellow
        }
    }
    Write-Host "  Storage:            $(if ($Params.deployStorage) { 'New' } else { "Existing ($($Params.existingStorageAccountName))" })"
    Write-Host "  Key Vault:          $(if ($Params.deployKeyVault) { 'New' } else { "Existing ($($Params.existingKeyVaultName))" })"
    Write-Host "  Trusted Launch:     $($Params.enableTrustedLaunch)"
    Write-Host "  Domain Controller:  $($Params.deployDomain)"
    Write-Host "  Azure Bastion:      $($Params.deployBastion)"
    Write-Host "  Private Endpoints:  $($Params.deployPrivateEndpoints)"
    Write-Host ""

    $confirm = Read-YesNo "Proceed with deployment?" $true
    if (-not $confirm) {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }

    Write-Section "Deploying Resources"

    $deploymentName = "avd-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $templateFile   = Join-Path $scriptDir "avdMain.bicep"

    # Build inline parameters for az deployment
    $azParams = @(
        "location=$($Params.location)"
        "coreRgName=$($Params.coreRgName)"
        "networkRgName=$($Params.networkRgName)"
        "monitorRgName=$($Params.monitorRgName)"
        "deployNetworking=$($Params.deployNetworking.ToString().ToLower())"
        "hostPoolType=$($Params.hostPoolType)"
        "hostPoolName=$($Params.hostPoolName)"
        "appGroupName=$($Params.appGroupName)"
        "workspaceName=$($Params.workspaceName)"
        "workspaceFriendlyName=$($Params.workspaceFriendlyName)"
        "vmSize=$($Params.vmSize)"
        "vmName=$($Params.vmName)"
        "vmAdminUsername=$($Params.vmAdminUsername)"
        "vmAdminPassword=$($Params.vmAdminPassword)"
        "vmImagePublisher=$($Params.vmImagePublisher)"
        "vmImageOffer=$($Params.vmImageOffer)"
        "vmImageSku=$($Params.vmImageSku)"
        "enableTrustedLaunch=$($Params.enableTrustedLaunch.ToString().ToLower())"
        "deployStorage=$($Params.deployStorage.ToString().ToLower())"
        "fslogixShareName=$($Params.fslogixShareName)"
        "enableAadKerberosAuth=$($Params.enableAadKerberosAuth.ToString().ToLower())"
        "deployKeyVault=$($Params.deployKeyVault.ToString().ToLower())"
        "deployMonitoring=$($Params.deployMonitoring.ToString().ToLower())"
        "deployTemplateVm=$($Params.deployTemplateVm.ToString().ToLower())"
        "deployDomain=$($Params.deployDomain.ToString().ToLower())"
        "deployBastion=$($Params.deployBastion.ToString().ToLower())"
        "deployPrivateEndpoints=$($Params.deployPrivateEndpoints.ToString().ToLower())"
    )

    # Conditional parameters
    if ($Params.storageAccountName)  { $azParams += "storageAccountName=$($Params.storageAccountName)" }
    if ($Params.keyVaultName)        { $azParams += "keyVaultName=$($Params.keyVaultName)" }
    if ($Params.logAnalyticsName)    { $azParams += "logAnalyticsName=$($Params.logAnalyticsName)" }
    if ($Params.existingLogAnalyticsWorkspaceId) { $azParams += "existingLogAnalyticsWorkspaceId=$($Params.existingLogAnalyticsWorkspaceId)" }
    if ($Params.currentUserObjectId) { $azParams += "currentUserObjectId=$($Params.currentUserObjectId)" }
    if ($Params.existingSubnetId)    { $azParams += "existingSubnetId=$($Params.existingSubnetId)" }
    if ($Params.existingVnetId)      { $azParams += "existingVnetId=$($Params.existingVnetId)" }

    if ($Params.deployDomain -and $Params.domainVmSize) {
        $azParams += "domainVmSize=$($Params.domainVmSize)"
    }
    if ($Params.deployMonitoring -and $null -ne $Params.deployDcr) {
        $azParams += "deployDcr=$($Params.deployDcr.ToString().ToLower())"
    }
    if ($Params.deployNetworking) {
        if ($Params.vnetName)         { $azParams += "vnetName=$($Params.vnetName)" }
        if ($Params.vnetAddressSpace) { $azParams += "vnetAddressSpace=$($Params.vnetAddressSpace)" }
        if ($Params.subnetName)       { $azParams += "subnetName=$($Params.subnetName)" }
        if ($Params.subnetPrefix)     { $azParams += "subnetPrefix=$($Params.subnetPrefix)" }
        if ($Params.nsgName)          { $azParams += "nsgName=$($Params.nsgName)" }
    }
    if ($Params.dnsServers -and $Params.dnsServers.Count -gt 0) {
        $dnsJson = $Params.dnsServers | ConvertTo-Json -Compress
        $azParams += "dnsServers=$dnsJson"
    }
    if ($Params.deployPrivateEndpoints) {
        if ($Params.peSubnetName)       { $azParams += "peSubnetName=$($Params.peSubnetName)" }
        if ($Params.peSubnetPrefix)     { $azParams += "peSubnetPrefix=$($Params.peSubnetPrefix)" }
        if ($Params.existingPeSubnetId) { $azParams += "existingPeSubnetId=$($Params.existingPeSubnetId)" }
    }

    # Build --parameters arguments
    $paramString = ($azParams | ForEach-Object { "--parameters `"$_`"" }) -join " "

    $noWaitCmd = "az deployment sub create --no-wait --location `"$($Params.location)`" --template-file `"$templateFile`" $paramString --name `"$deploymentName`" --output json"

    Write-Host "Deployment: $deploymentName" -ForegroundColor Cyan
    Write-Host "Starting deployment...`n" -ForegroundColor Yellow

    try {
        # Start deployment asynchronously
        Invoke-Expression $noWaitCmd 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Deployment command failed to start (exit code $LASTEXITCODE)."
        }

        # Poll for progress
        $result = Watch-DeploymentProgress -DeploymentName $deploymentName

        $provisioningState = $result.properties.provisioningState
        $succeeded = $provisioningState -eq 'Succeeded'

        $errorMsg = ''
        if (-not $succeeded) {
            $errorMsg = $result.properties.error | ConvertTo-Json -Depth 5 2>$null
            if (-not $errorMsg) { $errorMsg = "Provisioning state: $provisioningState" }
        }

        return @{
            Success        = $succeeded
            DeploymentName = $deploymentName
            Result         = $result
            Error          = $errorMsg
            Params         = $Params
        }
    }
    catch {
        # Try to fetch deployment status for partial results
        $partialResult = $null
        try {
            $partialJson = az deployment sub show --name $deploymentName --output json 2>$null
            if ($partialJson) { $partialResult = $partialJson | ConvertFrom-Json }
        } catch {}

        return @{
            Success        = $false
            DeploymentName = $deploymentName
            Result         = $partialResult
            Error          = $_.Exception.Message
            Params         = $Params
        }
    }
}

# ==========================================================
# Deployment Progress Polling
# ==========================================================

function Watch-DeploymentProgress {
    param(
        [string]$DeploymentName,
        [int]$PollIntervalSeconds = 3
    )

    $startTime = Get-Date
    $terminalStates = @('Succeeded', 'Failed', 'Canceled')
    $previousLineCount = 0

    while ($true) {
        $elapsed = (Get-Date) - $startTime
        $elapsedStr = '{0:mm\:ss}' -f $elapsed

        # Get overall deployment status
        $deployJson = az deployment sub show --name $DeploymentName --output json 2>$null
        if (-not $deployJson) {
            Write-Host "  Waiting for deployment to register..." -ForegroundColor Yellow
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
        $deploy = $deployJson | ConvertFrom-Json
        $overallState = $deploy.properties.provisioningState

        # Get per-operation status
        $opsJson = az deployment operation sub list --name $DeploymentName --output json 2>$null
        $ops = @()
        if ($opsJson) {
            $ops = @($opsJson | ConvertFrom-Json)
        }

        # Clear previous output by moving cursor up
        if ($previousLineCount -gt 0) {
            for ($i = 0; $i -lt $previousLineCount; $i++) {
                [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                Write-Host (' ' * [Console]::WindowWidth) -NoNewline
                [Console]::SetCursorPosition(0, [Console]::CursorTop)
            }
        }

        # Build status display
        $lines = @()

        $stateColor = switch ($overallState) {
            'Succeeded' { 'Green' }
            'Failed'    { 'Red' }
            'Canceled'  { 'Yellow' }
            default     { 'Cyan' }
        }

        $lines += "  Deployment: $DeploymentName    [$overallState - $elapsedStr]"
        $lines += ""
        $lines += "  {0,-40} {1,-15} {2}" -f 'Operation', 'Status', 'Duration'
        $lines += "  $('-' * 70)"

        foreach ($op in $ops) {
            $resourceName = ''
            if ($op.properties.targetResource -and $op.properties.targetResource.resourceName) {
                $resourceName = $op.properties.targetResource.resourceName
            }
            elseif ($op.properties.targetResource -and $op.properties.targetResource.id) {
                $resourceName = ($op.properties.targetResource.id -split '/')[-1]
            }
            else {
                continue
            }

            $opState = $op.properties.provisioningState
            $opDuration = '-'
            if ($op.properties.duration) {
                # Completed operation - ARM reports the true wall-clock duration as ISO 8601
                $opDuration = Format-IsoDuration $op.properties.duration
            }
            elseif ($op.properties.timestamp) {
                # In-progress - timestamp is when the op was accepted; show live elapsed
                $opStart   = [DateTime]::Parse($op.properties.timestamp).ToUniversalTime()
                $opElapsed = (Get-Date).ToUniversalTime() - $opStart
                if ($opElapsed.TotalSeconds -gt 0) {
                    $opDuration = '{0:mm\:ss}' -f $opElapsed
                }
            }

            $lines += "  {0,-40} {1,-15} {2}" -f $resourceName, $opState, $opDuration
        }

        $lines += ""
        $previousLineCount = $lines.Count

        # Print all lines
        foreach ($line in $lines) {
            if ($line -eq $lines[0]) {
                Write-Host $line -ForegroundColor $stateColor
            }
            elseif ($line -match 'Succeeded') {
                Write-Host $line -ForegroundColor Green
            }
            elseif ($line -match 'Failed') {
                Write-Host $line -ForegroundColor Red
            }
            elseif ($line -match 'Running|Accepted') {
                Write-Host $line -ForegroundColor Cyan
            }
            else {
                Write-Host $line
            }
        }

        # Check if deployment is done
        if ($overallState -in $terminalStates) {
            break
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    # Return final deployment result
    $finalJson = az deployment sub show --name $DeploymentName --output json 2>$null
    return ($finalJson | ConvertFrom-Json)
}

# ==========================================================
# Post-Deployment Summary
# ==========================================================

function Show-DeploymentSummary {
    param([hashtable]$DeploymentResult)

    Write-Banner "Deployment Results"

    if ($DeploymentResult.Success) {
        Write-Host "  Status: " -NoNewline
        Write-Host "SUCCEEDED" -ForegroundColor Green
    }
    else {
        Write-Host "  Status: " -NoNewline
        Write-Host "FAILED" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Error:" -ForegroundColor Red
        Write-Host "  $($DeploymentResult.Error)" -ForegroundColor Red
    }

    # Show whatever outputs are available (works for both full success and partial failure)
    $outputs = $null
    if ($DeploymentResult.Result) {
        $outputs = $DeploymentResult.Result.properties.outputs
    }

    Write-Host "`n  Resource Groups:" -ForegroundColor White
    Write-Host "    Core:       $($DeploymentResult.Params.coreRgName)"
    Write-Host "    Networking: $($DeploymentResult.Params.networkRgName)"
    Write-Host "    Monitoring: $($DeploymentResult.Params.monitorRgName)"

    if ($outputs) {
        if ($outputs.hostPoolName -or $outputs.workspaceName) {
            Write-Host "`n  AVD Resources:" -ForegroundColor White
            if ($outputs.hostPoolName)     { Write-Host "    Host Pool:      $($outputs.hostPoolName.value)" }
            if ($outputs.scalingPlanName)  { Write-Host "    Scaling Plan:   $($outputs.scalingPlanName.value)" }
            if ($outputs.workspaceName)    { Write-Host "    Workspace:      $($outputs.workspaceName.value)" }
            if ($outputs.registrationTokenExpiry) {
                Write-Host "    Token Expiry: $($outputs.registrationTokenExpiry.value)"
            }
        }

        if ($outputs.templateVmName -or $outputs.publicIpAddress) {
            Write-Host "`n  Compute:" -ForegroundColor White
            if ($outputs.templateVmName)  { Write-Host "    Template VM:  $($outputs.templateVmName.value)" }
            if ($outputs.publicIpAddress) { Write-Host "    Public IP:    $($outputs.publicIpAddress.value)" }
        }

        if ($outputs.keyVaultUri -and $outputs.keyVaultUri.value) {
            Write-Host "`n  Security:" -ForegroundColor White
            Write-Host "    Key Vault URI:  $($outputs.keyVaultUri.value)"
            Write-Host "    Key Vault Name: $($outputs.keyVaultName.value)"
        }
        elseif ($DeploymentResult.Params.existingKeyVaultName) {
            Write-Host "`n  Security (existing):" -ForegroundColor White
            Write-Host "    Key Vault: $($DeploymentResult.Params.existingKeyVaultName)  (RG: $($DeploymentResult.Params.existingKeyVaultRg))"
        }

        if ($outputs.storageAccountName -and $outputs.storageAccountName.value) {
            Write-Host "`n  Storage:" -ForegroundColor White
            Write-Host "    Account: $($outputs.storageAccountName.value)"
        }
        elseif ($DeploymentResult.Params.existingStorageAccountName) {
            Write-Host "`n  Storage (existing):" -ForegroundColor White
            Write-Host "    Account: $($DeploymentResult.Params.existingStorageAccountName)  (RG: $($DeploymentResult.Params.existingStorageAccountRg))"
        }

        if ($outputs.privateEndpointsDeployed -and $outputs.privateEndpointsDeployed.value -eq $true) {
            Write-Host "`n  Private Endpoints:" -ForegroundColor White
            Write-Host "    Key Vault and FSLogix Storage are network-isolated."
            Write-Host "    DNS: privatelink.vaultcore.azure.net / privatelink.file.core.windows.net"
        }
    }

    # Show existing Log Analytics workspace if brownfield
    if ($DeploymentResult.Params.existingLogAnalyticsName) {
        Write-Host "`n  Monitoring (existing):" -ForegroundColor White
        Write-Host "    Log Analytics: $($DeploymentResult.Params.existingLogAnalyticsName)  (RG: $($DeploymentResult.Params.existingLogAnalyticsRg))"
    }

    # Registration token (only attempt if deployment succeeded)
    if ($DeploymentResult.Success) {
        Write-Host "`n  Registration Token:" -ForegroundColor White
        $tokenError = $null
        $regJson = az desktopvirtualization hostpool retrieve-registration-token `
            --name $DeploymentResult.Params.hostPoolName `
            --resource-group $DeploymentResult.Params.coreRgName `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0 -and $regJson) {
            try {
                $regInfo = $regJson | ConvertFrom-Json
                if ($regInfo.token) {
                    Write-Host "    Token:"
                    Write-Host "    $($regInfo.token)" -ForegroundColor Gray
                    if ($regInfo.expirationTime) {
                        Write-Host "    Expires: $($regInfo.expirationTime)"
                    }
                    Write-Host "    Use this token to register session hosts to the pool."
                }
                else {
                    $tokenError = "Token property was empty in response."
                }
            }
            catch {
                $tokenError = "Could not parse token response."
            }
        }
        else {
            $tokenError = ($regJson | Out-String).Trim()
        }

        if ($tokenError) {
            Write-Host "    Could not retrieve token: $tokenError" -ForegroundColor Yellow
            Write-Host "    Retrieve manually:" -ForegroundColor Yellow
            Write-Host "    az desktopvirtualization hostpool retrieve-registration-token --name $($DeploymentResult.Params.hostPoolName) --resource-group $($DeploymentResult.Params.coreRgName)"
        }
    }

    # Portal links
    $subId = (az account show --query id -o tsv)
    Write-Host "`n  Portal Links:" -ForegroundColor White
    Write-Host "    Core:       https://portal.azure.com/#@/resource/subscriptions/$subId/resourceGroups/$($DeploymentResult.Params.coreRgName)"
    Write-Host "    Network:    https://portal.azure.com/#@/resource/subscriptions/$subId/resourceGroups/$($DeploymentResult.Params.networkRgName)"
    Write-Host "    Monitor:    https://portal.azure.com/#@/resource/subscriptions/$subId/resourceGroups/$($DeploymentResult.Params.monitorRgName)"

    if (-not $DeploymentResult.Success) {
        Write-Host "`n  Troubleshoot with:" -ForegroundColor Yellow
        Write-Host "    az deployment sub show --name $($DeploymentResult.DeploymentName) --query properties.error"
    }

    Write-Host ""
}

# ==========================================================
# Main
# ==========================================================

try {
    $context = Test-Prerequisites
    $params  = Get-DeploymentParameters -Context $context
    $result  = Start-AVDDeployment -Params $params
    Show-DeploymentSummary -DeploymentResult $result
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
finally {
    # Clear sensitive data from memory
    if ($params -and $params.ContainsKey('vmAdminPassword')) {
        $params.vmAdminPassword = $null
    }
}
