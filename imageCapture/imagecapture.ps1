<# This script is to capture an image of an existing virtual machine for AVD by snapshotting the source VM, deploying a temp VM, running sysprep, and generalizing the image into an image definition to be hosted to an Azure Compute Gallery.
#>

# Variables (update as needed)
$resourceGroup = "rg-avd-core-poc" # Resource group where the source VM is located
$sourceVMName = "avdtemplate01" # Name of the source VM to capture image from
$tempVMName = "$sourceVMName-tmp"
$testVMName = "$sourceVMName-tst"  # New test VM name
$tempNicName = "$tempVMName-nic"    # Define temp NIC name early
$snapshotName = "$sourceVMName-osdisk-snap"
$location = "eastus2"        # Azure region
$galleryName = "acgavdpoc" # Azure Compute Gallery name
$imageDefName = "imgdef-$sourceVMName"
$imageVersion = "1.0.0"     # Image version
$imgpublisher = "Contoso" # Example publisher name
$imgoffer = "ContosoAVDImage"    # Example offer name
$imgsku = "ContosoAVDPersonal"  # Example SKU name
$galleryResourceGroup = $resourceGroup # or set to another RG if needed
$vmGeneration = "V2"  # Set to "V1" if using Gen1 VMs, otherwise "V2" for Gen2 VMs

# Test VM configuration
$testVMSize = "Standard_D2ads_v6"  # Smaller size for testing
$adminUsername = "testadmin"
$adminPassword = "TempTest123!"  # Change this!

# 1. Get source VM and OS disk
$sourceVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $sourceVMName

# Determine VM Generation - check multiple sources for reliability
if ($sourceVM.HyperVGeneration) {
    $vmGeneration = $sourceVM.HyperVGeneration
    Write-Output "Source VM HyperV Generation detected from VM object: '$vmGeneration'"
} else {
    # Fallback: check the image reference to infer generation
    Write-Output "HyperVGeneration not available on deallocated VM, attempting inference from image..."
    
    # Try to get the gallery image definition if VM was created from one
    $vmTags = $sourceVM.Tags
    if ($vmTags -and $vmTags['ImageDefinition']) {
        $imageDef = Get-AzGalleryImageDefinition -Name $vmTags['ImageDefinition'] -GalleryName $vmTags['GalleryName'] -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
        if ($imageDef.HyperVGeneration) {
            $vmGeneration = $imageDef.HyperVGeneration
            Write-Output "Source VM Generation inferred from image definition: '$vmGeneration'"
        }
    }
    
    # If still not found, use default
    Write-Output "Using default VM Generation: '$vmGeneration'"
}

# Determine Security Type
$securityType = $sourceVM.SecurityProfile.SecurityType
if (-not $securityType) {
    $securityType = "Standard"
}
Write-Output "Source VM properties detected: Generation '$vmGeneration', SecurityType '$securityType'"


# Check if VM is deallocated, if not, deallocate it
$vmStatus = (Get-AzVM -ResourceGroupName $resourceGroup -Name $sourceVMName -Status).Statuses | Where-Object { $_.Code -like 'PowerState/*' }
if ($vmStatus.DisplayStatus -ne 'VM deallocated') {
    Write-Output "Source VM '$sourceVMName' is not in a deallocated state. Deallocating now..."
    Stop-AzVM -ResourceGroupName $resourceGroup -Name $sourceVMName -Force -NoWait
    # Wait for deallocation
    do {
        Start-Sleep -Seconds 15
        $vmStatus = (Get-AzVM -ResourceGroupName $resourceGroup -Name $sourceVMName -Status).Statuses | Where-Object { $_.Code -like 'PowerState/*' }
        Write-Output "Waiting for VM to deallocate. Current state: $($vmStatus.DisplayStatus)"
    } while ($vmStatus.DisplayStatus -ne 'VM deallocated')
    Write-Output "VM is now deallocated."
}

$osDiskId = $sourceVM.StorageProfile.OsDisk.ManagedDisk.Id

# 2. Create snapshot of OS disk
Write-Output "Creating snapshot of OS disk..."
$snapshotConfig = New-AzSnapshotConfig -SourceUri $osDiskId -Location $location -CreateOption Copy
$snapshot = New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $resourceGroup
$snapshot.Name

# 3. Create managed disk from snapshot
Write-Output "Creating managed disk from snapshot..."
$diskName = "$tempVMName-osdisk"
$diskConfig = New-AzDiskConfig -AccountType Standard_LRS -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id
$osDisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName $diskName
$osDisk.Name

# 4. Deploy temp VM from managed disk
Write-Output "Deploying temporary VM from managed disk..."
$tempVMConfig = New-AzVMConfig -VMName $tempVMName -VMSize $sourceVM.HardwareProfile.VmSize
$tempVMConfig = Set-AzVMOSDisk -VM $tempVMConfig -ManagedDiskId $osDisk.Id -CreateOption Attach -Windows

# Use same VNet/subnet as source VM
# Get source VM's NIC and VNet/subnet info
$sourceNic = Get-AzNetworkInterface -ResourceGroupName $resourceGroup | Where-Object { $_.VirtualMachine.Id -eq $sourceVM.Id }
if (-not $sourceNic) {
    Write-Error "Source VM NIC not found."
    exit 1
}
$ipConfig = $sourceNic.IpConfigurations[0]
$subnetId = $ipConfig.Subnet.Id

# Create new NIC for temp VM
Write-Output "Creating network interface for temporary VM..."
$tempNicName = "$tempVMName-nic"
$tempNic = New-AzNetworkInterface -Name $tempNicName -ResourceGroupName $resourceGroup -Location $location -SubnetId $subnetId
$tempNic.Name

# Attach new NIC to temp VM config
$tempVMConfig = Add-AzVMNetworkInterface -VM $tempVMConfig -Id $tempNic.Id

New-AzVM -ResourceGroupName $resourceGroup -Location $location -VM $tempVMConfig

# 5. Run Sysprep on temp VM
# During this step, if it takes longer than 2-3 minutes, access the VM via Bastion and check the sysprep process errors in C:\Windows\System32\Sysprep\Panther\setupact.log and setuperr.log
Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $tempVMName -CommandId 'RunPowerShellScript' -ScriptString 'Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" -ArgumentList "/oobe /generalize /shutdown"'
Write-Output "Waiting for VM to stop after sysprep..."
do {
    Start-Sleep -Seconds 15
    $vmStatus = (Get-AzVM -ResourceGroupName $resourceGroup -Name $tempVMName -Status).Statuses | Where-Object { $_.Code -like 'PowerState/*' }
    Write-Output "Current state: $($vmStatus.DisplayStatus)"
} while ($vmStatus.DisplayStatus -ne 'VM stopped')

# 6. Generalize the VM
Set-AzVM -ResourceGroupName $resourceGroup -Name $tempVMName -Generalized

# 7. Create image definition in Azure Compute Gallery (if not exists)
if (-not (Get-AzGallery -ResourceGroupName $galleryResourceGroup -Name $galleryName -ErrorAction SilentlyContinue)) {
    New-AzGallery -ResourceGroupName $galleryResourceGroup -Name $galleryName -Location $location
}

#set security features based on the source VM
$features = @()
if ($securityType -eq "TrustedLaunch") {
    $features += @{Name="SecurityType"; Value=$securityType}
    $features += @{Name="DiskControllerTypes"; Value="SCSI, NVMe"}
}

if (-not (Get-AzGalleryImageDefinition -ResourceGroupName $galleryResourceGroup -GalleryName $galleryName -Name $imageDefName -ErrorAction SilentlyContinue)) {
    $imageDefParams = @{
        ResourceGroupName = $galleryResourceGroup
        GalleryName       = $galleryName
        Name              = $imageDefName
        Location          = $location
        OsType            = 'Windows'
        OsState           = 'Generalized'
        Publisher         = $imgpublisher
        Offer             = $imgoffer
        Sku               = $imgsku
        HyperVGeneration  = $vmGeneration
        Architecture      = 'x64'
    }
    if ($features.Count -gt 0) {
        $imageDefParams['Feature'] = $features
    }
    New-AzGalleryImageDefinition @imageDefParams
    Write-Output "Created new image definition: $imageDefName in gallery: $galleryName"
}
# 8. Create image version from generalized VM
New-AzGalleryImageVersion -ResourceGroupName $galleryResourceGroup `
    -GalleryName $galleryName -GalleryImageDefinitionName $imageDefName `
    -GalleryImageVersionName $imageVersion `
    -Location $location `
    -SourceImageVMId (Get-AzVM -ResourceGroupName $resourceGroup -Name $tempVMName).Id

Write-Output "Image capture and gallery version creation complete."

# 8a. Create a test VM from the captured image to validate it works
Write-Output "Creating test VM from captured image..."

try {
    # Get the image definition and version
    Write-Output "Getting image definition from gallery..."
    $imageDefinition = Get-AzGalleryImageDefinition -ResourceGroupName $galleryResourceGroup -GalleryName $galleryName -Name $imageDefName
    $imageVersionObj = Get-AzGalleryImageVersion -ResourceGroupName $galleryResourceGroup -GalleryName $galleryName -GalleryImageDefinitionName $imageDefName -Name $imageVersion.Name
    
    if (-not $imageDefinition -or -not $imageVersionObj) {
        throw "Could not find image definition or version in gallery"
    }
    
    Write-Output "Found image: $($imageDefinition.Name) version $($imageVersionObj.Name)"
    
    # Create credentials for test VM
    $securePassword = ConvertTo-SecureString $adminPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($adminUsername, $securePassword)
    
    # Create test VM configuration with security settings matching the image
    $testVMConfigParams = @{
        VMName = $testVMName
        VMSize = $testVMSize
    }
    if ($securityType -eq 'TrustedLaunch') {
        $testVMConfigParams['SecurityType'] = $securityType
        if ($sourceVM.SecurityProfile.UefiSettings.SecureBootEnabled) {
            $testVMConfigParams['EnableSecureBoot'] = $true
        }
        if ($sourceVM.SecurityProfile.UefiSettings.VTpmEnabled) {
            $testVMConfigParams['EnableVtpm'] = $true
        }
    }
    $testVMConfig = New-AzVMConfig @testVMConfigParams
    
    $testVMConfig = Set-AzVMOperatingSystem -VM $testVMConfig -Windows -ComputerName $testVMName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
    
    # Set the source image for the test VM
    $testVMConfig = Set-AzVMSourceImage -VM $testVMConfig -Id $imageVersionObj.Id

    # Get network configuration - try from temp VM first, then source VM
    $networkInterface = $null
    $subnetId = $null
    
    # Try to get network info from temp VM (if it still exists)
    $tempNicExists = Get-AzNetworkInterface -Name $tempNicName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
    if ($tempNicExists) {
        $networkInterface = $tempNicExists
        $subnetId = $networkInterface.IpConfigurations[0].Subnet.Id
        Write-Output "Using network config from temp VM NIC"
    } else {
        # Fallback: get fresh source VM info
        $sourceVMFresh = Get-AzVM -ResourceGroupName $resourceGroup -Name $sourceVMName
        $sourceNic = Get-AzNetworkInterface -ResourceGroupName $resourceGroup | Where-Object { $_.VirtualMachine.Id -eq $sourceVMFresh.Id }
        if ($sourceNic) {
            $subnetId = $sourceNic.IpConfigurations[0].Subnet.Id
            Write-Output "Using network config from source VM NIC"
        }
    }
    
    if (-not $subnetId) {
        throw "Could not determine subnet ID for test VM network configuration"
    }
    
    # Create new NIC for test VM
    $testNicName = "$testVMName-nic"
    $testNic = New-AzNetworkInterface -Name $testNicName -ResourceGroupName $resourceGroup -Location $location -SubnetId $subnetId
    $testVMConfig = Add-AzVMNetworkInterface -VM $testVMConfig -Id $testNic.Id
    
    # Create the test VM
    New-AzVM -ResourceGroupName $resourceGroup -Location $location -VM $testVMConfig -Verbose
    
    Write-Output "Test VM '$testVMName' created successfully from captured image!"
    
    # Wait for VM to be running
    Write-Output "Waiting for test VM to be in running state..."
    do {
        Start-Sleep -Seconds 10
        $vmStatus = (Get-AzVM -ResourceGroupName $resourceGroup -Name $testVMName -Status).Statuses | Where-Object { $_.Code -like 'PowerState/*' }
        Write-Output "Test VM status: $($vmStatus.DisplayStatus)"
    } while ($vmStatus.DisplayStatus -ne 'VM running')
    
    # Optional: Run a simple validation command
    Write-Output "Running validation test on test VM..."
    $validationResult = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $testVMName -CommandId 'RunPowerShellScript' -ScriptString 'Get-ComputerInfo | Select-Object OsName, OsOperatingSystemSKU, OsVersion, OsTotalVisibleMemorySize | ConvertTo-Json'
    
    if ($validationResult.Value[0].Code -eq 'ComponentStatus/StdOut/succeeded') {
        Write-Output "✅ Test VM validation successful!"
        Write-Output "System Info: $($validationResult.Value[0].Message)"
    } else {
        Write-Warning "⚠️ Test VM validation returned warnings, but VM is running"
    }
    
    # Prompt user for cleanup decision
    $cleanupChoice = Read-Host "Test VM created successfully. Do you want to clean it up now? (y/n)"
    
    if ($cleanupChoice -eq 'y' -or $cleanupChoice -eq 'Y') {
        Write-Output "Cleaning up test VM..."
        
        # Stop and remove test VM
        Stop-AzVM -ResourceGroupName $resourceGroup -Name $testVMName -Force
        Remove-AzVM -ResourceGroupName $resourceGroup -Name $testVMName -Force
        
        # Remove test VM NIC
        Remove-AzNetworkInterface -Name $testNicName -ResourceGroupName $resourceGroup -Force
        
        # Remove test VM OS disk
        $testVMDisks = Get-AzDisk -ResourceGroupName $resourceGroup | Where-Object { $_.Name -like "*$testVMName*" }
        foreach ($disk in $testVMDisks) {
            Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $disk.Name -Force
        }
        
        Write-Output "✅ Test VM cleanup completed."
    } else {
        Write-Output "Test VM '$testVMName' left running for manual testing."
        Write-Output "Remember to clean it up when done: Stop-AzVM and Remove-AzVM"
    }
    
} catch {
    Write-Error "Failed to create test VM: $($_.Exception.Message)"
    Write-Output "Image capture was successful, but test VM creation failed."
}

# 9. Clean up temp resources (original cleanup)
Write-Output "Cleaning up temporary resources..."
Remove-AzVM -ResourceGroupName $resourceGroup -Name $tempVMName -Force
Remove-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName $snapshotName -Force
Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName -Force
Remove-AzNetworkInterface -Name $tempNicName -ResourceGroupName $resourceGroup -Force

Write-Output "🎉 Image capture process completed successfully!"
Write-Output "Image available in gallery: $galleryName/$imageDefName version $imageVersion"