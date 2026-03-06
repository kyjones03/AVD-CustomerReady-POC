#Requires -Version 5.1
<#
.SYNOPSIS
    Tests the VM_Size_Family.csv lookup and checks live quota for a given VM size.
.DESCRIPTION
    1. Reads VMSizes\VM_Size_Family.csv to resolve the quota family and vCPU count for
       the requested VM size.
    2. Calls 'az vm list-usage' to retrieve the current quota usage for that family in
       the target region.
    3. Reports whether enough vCPUs are available for the deployment.
.PARAMETER VmSize
    The ARM VM size to check, e.g. Standard_D4s_v5.
.PARAMETER Location
    The Azure region to check quota in, e.g. eastus2.
.PARAMETER RequiredVcpus
    Override the vCPU count from the CSV. Leave blank to use the CSV value.
.EXAMPLE
    .\Test-VMQuota.ps1 -VmSize Standard_D4s_v5 -Location eastus2
.EXAMPLE
    .\Test-VMQuota.ps1 -VmSize Standard_D8s_v3 -Location westus2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VmSize,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [int]$RequiredVcpus = 0
)

$ErrorActionPreference = 'Stop'
$csvPath = Join-Path $PSScriptRoot "VM_Size_Family.csv"

# ==========================================================
# 1. Load and parse the CSV  (skip comment lines starting #)
# ==========================================================
if (-not (Test-Path $csvPath)) {
    Write-Host "ERROR: CSV not found at $csvPath" -ForegroundColor Red
    exit 1
}

$rows = Get-Content $csvPath |
    Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } |
    ConvertFrom-Csv

Write-Host "CSV loaded: $($rows.Count) entries" -ForegroundColor Cyan

# Case-insensitive lookup
$entry = $rows | Where-Object { $_.Size -ieq $VmSize } | Select-Object -First 1

if (-not $entry) {
    Write-Host ""
    Write-Host "RESULT: '$VmSize' was NOT found in the CSV." -ForegroundColor Yellow
    Write-Host "  Families known in CSV:" -ForegroundColor Gray
    $rows | Select-Object -ExpandProperty Family -Unique | Sort-Object | ForEach-Object {
        Write-Host "    $_" -ForegroundColor Gray
    }
    exit 1
}

$familyName  = $entry.Family
$csvVcpus    = [int]$entry.vCPUs
$neededVcpus = if ($RequiredVcpus -gt 0) { $RequiredVcpus } else { $csvVcpus }

Write-Host ""
Write-Host "VM Size    : $($entry.Size)"    -ForegroundColor White
Write-Host "Family     : $familyName"         -ForegroundColor White
Write-Host "vCPUs req  : $neededVcpus"         -ForegroundColor White
Write-Host "Region     : $Location"            -ForegroundColor White
Write-Host ""

# ==========================================================
# 2. Verify Azure CLI login
# ==========================================================
Write-Host "Checking Azure CLI login... " -NoNewline
try {
    $null = az account show --output json 2>$null | ConvertFrom-Json
    Write-Host "OK" -ForegroundColor Green
}
catch {
    Write-Host "NOT LOGGED IN" -ForegroundColor Red
    Write-Host "Run 'az login' first."
    exit 1
}

# ==========================================================
# 3. Query quota via az vm list-usage (no extension required)
# ==========================================================
Write-Host "Querying quota for family '$familyName' in '$Location'..." -ForegroundColor Yellow

$usageJson = az vm list-usage `
    --location $Location `
    --query "[?name.value=='$familyName']" `
    --output json 2>$null

if (-not $usageJson -or $usageJson -eq '[]') {
    Write-Host ""
    Write-Host "WARNING: No quota entry found for family '$familyName' in '$Location'." -ForegroundColor Yellow
    Write-Host "  Possible causes:"
    Write-Host "    - The family name in the CSV may be incorrect for this region."
    Write-Host "    - The VM family is not available in '$Location'."
    Write-Host ""
    Write-Host "Listing all families that contain 'standard' in '$Location' for reference:" -ForegroundColor Gray
    az vm list-usage --location $Location `
        --query "[?contains(name.value, 'standard') && starts_with(name.value, 'standardD')].{Family:name.value, Current:currentValue, Limit:limit}" `
        --output table 2>$null
    exit 1
}

$usageEntry  = $usageJson | ConvertFrom-Json | Select-Object -First 1
$currentUsed = [int]$usageEntry.currentValue
$limit       = [int]$usageEntry.limit
$available   = $limit - $currentUsed

# ==========================================================
# 4. Report
# ==========================================================
Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  Quota Check Results" -ForegroundColor Cyan
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  Family       : $($usageEntry.name.localizedValue)"
Write-Host "  Quota limit  : $limit vCPUs"
Write-Host "  Currently in : $currentUsed vCPUs"
Write-Host "  Available    : $available vCPUs"
Write-Host "  Need         : $neededVcpus vCPUs"
Write-Host ""

if ($limit -eq 0) {
    Write-Host "  STATUS: NO QUOTA — this family has 0 quota in $Location." -ForegroundColor Red
    Write-Host "  Submit a quota increase request in the Azure portal." -ForegroundColor Yellow
    exit 2
}
elseif ($available -ge $neededVcpus) {
    Write-Host "  STATUS: SUFFICIENT QUOTA" -ForegroundColor Green
    Write-Host "  $available vCPUs available, $neededVcpus needed. Deployment can proceed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "  STATUS: INSUFFICIENT QUOTA" -ForegroundColor Red
    Write-Host "  Only $available vCPUs available; $neededVcpus needed." -ForegroundColor Red
    Write-Host "  Consider:" -ForegroundColor Yellow
    Write-Host "    - Choosing a smaller VM size" -ForegroundColor Yellow
    Write-Host "    - Requesting a quota increase in the Azure portal" -ForegroundColor Yellow
    Write-Host "    - Deploying in a different region" -ForegroundColor Yellow
    exit 2
}
