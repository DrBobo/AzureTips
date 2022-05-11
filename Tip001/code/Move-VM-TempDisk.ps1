param (
	#--------------------------------------------------------------
	# essential parameters
	#--------------------------------------------------------------
	# parameter is always mandatory
	[Parameter(Mandatory=$True)]
	[string] $subscriptionName,

	[Parameter(Mandatory=$True)]
	[string] $location,
	 
	[Parameter(Mandatory=$True)]
	[string] $sourceRG,
	 
	[Parameter(Mandatory=$True)]
	[string] $targetRG,
	 
	[Parameter(Mandatory=$True)]
	[string] $sourceVM,

	[Parameter(Mandatory=$True)]
	[string] $targetVMSize
)

# ------------------------------------------------------
# Remove VMs from Availability Zone
# ------------------------------------------------------

Function Get-DiskInfos([Boolean] $IsOSDisk, [object] $SourceDisk ) {

	# ------------------------------------------------------
	# Get VM Disks Infos
	# ------------------------------------------------------

	$diskname = $SourceDisk.Name
	$diskOSType = "None"
	$diskLun = "None"
	$diskIsWAEnabled = "False"

	if ($IsOSDisk) {
		$diskOSType = $SourceDisk.OsType.ToString()
	}
	else {
		$diskLun = $SourceDisk.Lun.ToString()
	}

	if($null -ne $SourceDisk.WriteAcceleratorEnabled) { 
		$diskIsWAEnabled = $SourceDisk.WriteAcceleratorEnabled.ToString()
	}

	return @{DiskName = $diskname; DiskOSType = $diskOSType; DiskType = $SourceDisk.ManagedDisk.StorageAccountType.ToString(); DiskLun = $diskLun; DiskSize = $SourceDisk.DiskSizeGB.ToString(); `
					DiskCaching = $SourceDisk.Caching.ToString(); DiskWAEnabled = $diskIsWAEnabled; DiskDeleteWithVM = $SourceDisk.DeleteOption.ToString()} 
}
	
Function Write-VMDisksSnapshot ([string]$ResourceGroup, [Object]$VirtualMachine, [int] $targetDiskType, [bool] $force) {
	
	# ------------------------------------------------------
	# Create VM Disks Snapshot
	# ------------------------------------------------------

	$snapshotAlias = 'snap' + (Get-Date).Ticks.ToString()
	$snapshotsInfo = @()
	$location = $VirtualMachine.Location

	# ------------------------------------------------------
	# OS Disk
	# ------------------------------------------------------
	
	$disk = $VirtualMachine.StorageProfile.OsDisk

	if ($force -eq $true -or $disk.DiskDeleteOption -eq "Delete") {
		$diskInfos = Get-DiskInfos -IsOSDisk $true -SourceDisk $disk
		$snapshot = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy  -Tag $diskInfos

		$snapshotsName = $snapshotAlias + '_' + $vm.Name + '_OS'

		New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotsName -ResourceGroupName $ResourceGroup > $null

		$snapshotsInfo += [pscustomobject]@{SnapshotName = $snapshotsName; DiskName = $disk.Name}
	}
	
	# ------------------------------------------------------
	# DATA Disks
	# ------------------------------------------------------
	
	$disks = $VirtualMachine.StorageProfile.DataDisks | Sort-Object Lun

	$index = 1

	foreach ($disk in $disks) {

		if ($force -eq $true -or $disk.DiskDeleteOption -eq "Delete") {
			$snapshotsName = $snapshotAlias + '_' + $vm.Name + '_DATA_Lun_' + $disk.Lun

			$diskInfos = Get-DiskInfos -IsOSDisk $false -SourceDisk $disk
			$snapshot = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -Tag $diskInfos

			New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotsName -ResourceGroupName $ResourceGroup > $null

			$snapshotsInfo += [pscustomobject]@{SnapshotName = $snapshotsName; DiskName = $disk.Name}
		}
		$index++
	}
	return $snapshotsInfo
}

Function Write-DiskFromSnapshot ([string] $Location, [string] $ResourceGroupSnapshot, [string] $ResourceGroupTarget, [pscustomobject[]] $SnapshotsInfo) {
	# ---------------------------------------------------------------------------------
	# Create Managed Disk from Snapshot
	# ---------------------------------------------------------------------------------

	[System.Collections.ArrayList]$disks = @{}

	# ------------------------------------------------------
	
	$index = 0;
	foreach ($snapName in $snapshotsInfo) {
		$snapshot = Get-AzSnapshot -ResourceGroupName $ResourceGroupSnapshot -SnapshotName $snapName.SnapshotName

		if ($index -eq 0) {
			$diskConfig = New-AzDiskConfig -SkuName $snapshot.Tags["DiskType"] -Location $Location -CreateOption Copy -SourceResourceId $snapshot.Id `
				-OsType $snapshot.Tags["DiskOSType"] -DiskSizeGB $snapshot.Tags["DiskSize"] 
		} else {
			$diskConfig = New-AzDiskConfig -SkuName $snapshot.Tags["DiskType"] -Location $Location -CreateOption Copy -SourceResourceId $snapshot.Id `
				-DiskSizeGB $snapshot.Tags["DiskSize"]  
		
		}

		$disks += New-AzDisk -Disk $diskConfig -ResourceGroupName $ResourceGroupTarget -DiskName $snapshot.Tags["DiskName"]		
		$index++;
	}

	return $disks
}

Function Remove-VirualMachineDisks ([string] $ResourceGroup, [pscustomobject[]] $snapshotsInfo) 
{
	foreach ($snapName in $snapshotsInfo) {
		Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $snapName.DiskName -Force;
	}
}


# ------------------------------------------------------
# Running Script
# ------------------------------------------------------


# ------------------------------------------------------
# Running in the right Subscription?
# ------------------------------------------------------
Write-Host -ForegroundColor Green  "Setting default subscription!"
$subscription = Get-AzSubscription -SubscriptionName $SubscriptionName
if (-Not $Subscription) {
    Write-Host -ForegroundColor Red  "Sorry, it seems you are not connected to Azure or don't have access to the subscription. Please use Connect-AzAccount to connect."
    exit
}

# If you want to be sure that you are running in the right subscription, 
# please uncomment the line below
# Select-AzSubscription -Subscription $SubscriptionName -Force

# -------------------------------------------------------------
# If not exists - Create new Resource Group for Disk Snapshots
# -------------------------------------------------------------

try {
	$rt_Target = Get-AzResourceGroup -Name $targetRG -Location $location
} catch {
}

if ($null -eq $rt_Target) {
	Write-Host -ForegroundColor Green  "Creating target resource group!"
	$rt_Target = New-AzResourceGroup -Name $targetRG -Location $location
}

try {

	# ----------------------------------------------------------------
	# Checks...		
	# ----------------------------------------------------------------
	
	if($sourceRG -eq $targetRG) {
		Write-Host -ForegroundColor Red  "Source and target resource groups are the same. Please use different resource groups."
		exit
	}

	Write-Host -ForegroundColor Red  "This script will recreate the VM!"
	Write-Host -ForegroundColor Red  "It is receomended to first backup your VM!"
	Write-Host -ForegroundColor Green  "Are you sure you want to continue? (y/n)"
	$answer = Read-Host  -Force
	if ($answer -ne "y") {
		Write-Host -ForegroundColor Green  "Exiting..."
		exit
	}

	# ----------------------------------------------------------------
	# Get the details from the VM to be recreated
	# ----------------------------------------------------------------
	Write-Host -ForegroundColor Green  "Getting Virtual Machine Configuration!"
	
	$vm_source = Get-AzVM -ResourceGroupName $sourceRG -Name $sourceVM

	Write-Host -ForegroundColor Green  "Create the ARM Template out of Virtual Machine" $vm_source.Name "!"
	
	# ----------------------------------------------------------------
	# Get the ARM Template for the VM to be recreated
	# ----------------------------------------------------------------
	$pathARM = ".\" + $vm_source.Name + ".json"
	Export-AzResourceGroup -ResourceGroupName  $sourceRG -SkipAllParameterization -Resource @($vm_source.Id) -Path $pathARM -Force 
	
	Write-Host -ForegroundColor Green  "The ARM Template path from the original Virtual Machine" $vm_source.Name "path is" $pathARM 
	
	# ----------------------------------------------------------------------------------
	# Create VM disks snapshots in target Resouce Group ($targetRG)
	# 
	# Note: This func will collect information from the orginal disk settings
	# and copy them in the disk snapshot tags! 
	# Please be sure that all req. disk settings are copied over to the snapshot tags. 
	# Based on that information the new disks will be created
	#
	# Return: $snapshotInfo - list of the Azure Snapshot Resource names
	# ----------------------------------------------------------------------------------
	Write-Host -ForegroundColor Green  "Creating Virtual Machine disks snapshots!"
	$snapshotInfo = Write-VMDisksSnapshot -ResourceGroup $targetRG -VirtualMachine $vm_source -force $true

	# -------------------------------------------------------------------
	# Delete Source VM 
	#
	# Note: All disks marked >Delete with VM< will be also removed
	# -------------------------------------------------------------------
	Write-Host -ForegroundColor Green  "Deleting Virtual Machine!"
	Remove-AzVM -ResourceGroupName $sourceRG -Name $sourceVM -Force   
	Write-Host -ForegroundColor Green  "Virtual Machine deleted!"
	
	# -------------------------------------------------------------------
	# Delete other resources...
	#
	# Note: Remove disks for which we created the snapshots
	# -------------------------------------------------------------------

	Write-Host -ForegroundColor Green  "Deleting Virtual Machine OS disk!"
	Remove-VirualMachineDisks -ResourceGroup $sourceRG -SnapshotsInfo $snapshotInfo
	Write-Host -ForegroundColor Green  "Virtual Machine OS disk deleted!"

	# -------------------------------------------------------------------
	# Create new disks from the snapshots (if any)
	# -------------------------------------------------------------------
	Write-Host -ForegroundColor Green  "Creating Managed Disks out of snapshots!"
	$disks = Write-DiskFromSnapshot -Location $location -ResourceGroupSnapshot $targetRG -ResourceGroupTarget $sourceRG -SnapshotsInfo $snapshotInfo -ZoneVM $zoneVM

	# ----------------------------------------------------------------------------------------------
	# CREATE Virtual Machine (VM) 
	#
	# Note: In this example not all VM properties are copied over from old to the new VM!
	# Please implement an additional mapping if necessery
	# ----------------------------------------------------------------------------------------------

	Write-Host -ForegroundColor Green  "Starting with creating new Virtual Machine" $vm_source.Name "steps..."
	
	Write-Host -ForegroundColor Green  "Prepare the ARM Template for new Virtual Machine" $vm_source.Name"!"

	$templateVM = Get-Content $pathARM -Raw | ConvertFrom-Json  -Depth 20

	try {
		# ----------------------------------------------------------------------------------------------
		# Change the VM Size
		# ----------------------------------------------------------------------------------------------
		$templateVM.resources.Get(0).properties.hardwareProfile.vmSize = $targetVMSize
		
		# ----------------------------------------------------------------------------------------------
		# Modify original VM template 
		#
		# Original VM ARM Template is prepared for creating a new VM, so we need to 
		# modify that template to be able to create the new VM but attach the existing disks 
		# and existing NIC, and not create new ones.
		# ----------------------------------------------------------------------------------------------
		$templateVM.resources.Get(0).properties.osProfile = $null
		$templateVM.resources.Get(0).properties.storageProfile.osDisk.createOption = "Attach"
		$templateVM.resources.Get(0).properties.storageProfile.imageReference = $null
	} catch {}

	$pathARM = ".\" + $vm_source.Name + "_New.json"
	ConvertTo-Json -InputObject $templateVM -Depth 10 | Out-File $pathARM -Encoding UTF8 -Force
	Write-Host -ForegroundColor Green  "The ARM Template path for the NEW Virtual Machine" $vm_source.Name" path is" $pathARM 

	Write-Host -ForegroundColor Green  "Deploying ARM Template for new Virtual Machine" $vm_source.Name"!"

	$deploymentName = "Deployment_" + $vm_source.Name
	New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $sourceRG -TemplateFile $pathARM 
	Write-Host -ForegroundColor Green  "The Virtual Machine" $vm_source.Name "successfully created and started!"

} catch {
	Write-Host -ForegroundColor Red -BackgroundColor White  $PSItem.Exception.Message
}	

