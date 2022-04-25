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
	[string] $sourceVM
)

# ------------------------------------------------------
# Remove VMs from Availability Zone
# ------------------------------------------------------

Function Get-DiskInfos([Boolean] $IsOSDisk, [object] $SourceDisk ) {

	# ------------------------------------------------------
	# Get VM Disks Infos
	# ------------------------------------------------------

	$diskname = $disk.Name
	$diskOSType = "None"
	$diskLun = "None"
	$diskIsWAEnabled = "False"

	if ($IsOSDisk) {
		$diskOSType = $disk.OsType.ToString()
	}
	else {
		$diskLun = $disk.Lun.ToString()
	}

	if($null -ne $disk.WriteAcceleratorEnabled) { 
		$diskIsWAEnabled = $disk.WriteAcceleratorEnabled.ToString()
	}

	return @{DiskName = $diskname; DiskOSType = $diskOSType; DiskType = $disk.ManagedDisk.StorageAccountType.ToString(); DiskLun = $diskLun; DiskSize = $disk.DiskSizeGB.ToString(); DiskCaching = $disk.Caching.ToString(); DiskWAEnabled = $diskIsWAEnabled} 
}
	
Function Write-VMDisksSnapshot ([string]$ResourceGroup, [Object]$VirtualMachine) {
	
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

	$diskInfos = Get-DiskInfos -IsOSDisk $true -SourceDisk $disk
    $snapshot = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy  -Tag $diskInfos

	$snapshotsInfo += $snapshotAlias + '_' + $vm.Name + '_OS'

	$snapItem = New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotsInfo[0] -ResourceGroupName $ResourceGroup 

	# ------------------------------------------------------
	# DATA Disks
	# ------------------------------------------------------
	$disks = $VirtualMachine.StorageProfile.DataDisks | Sort-Object Lun

	$index = 1

	foreach ($disk in $disks) {

		$snapshotsInfo += $snapshotAlias + '_' + $vm.Name + '_DATA_Lun_' + $disk.Lun 

		$diskInfos = Get-DiskInfos -IsOSDisk $false -SourceDisk $disk
		$snapshot = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -Tag $diskInfos

		$snapItem = New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotsInfo[$index] -ResourceGroupName $ResourceGroup 

		$index++
	}

	return $snapshotsInfo
}

Function Write-DiskFromSnapshot ([string] $Location, [string] $ResourceGroupSnapshot, [string] $ResourceGroupTarget, [string[]] $SnapshotsInfo) 
{
	# ---------------------------------------------------------------------------------
	# Create Managed Disk from Snapshot
	# ---------------------------------------------------------------------------------

	[System.Collections.ArrayList]$disks = @{}

	# ------------------------------------------------------
	
	$index = 0;
	foreach ($snapName in $snapshotsInfo) {
		$snapshot = Get-AzSnapshot -ResourceGroupName $ResourceGroupSnapshot -SnapshotName $snapshotsInfo[$index]

		if ($index -eq 0) {
			$diskConfig = New-AzDiskConfig -SkuName $snapshot.Tags["DiskType"] -Location $Location -CreateOption Copy -SourceResourceId $snapshot.Id `
				-OsType $snapshot.Tags["DiskOSType"] -DiskSizeGB $snapshot.Tags["DiskSize"]  
		} else {
			$diskConfig = New-AzDiskConfig -SkuName $snapshot.Tags["DiskType"] -Location $Location -CreateOption Copy -SourceResourceId $snapshot.Id `
				-DiskSizeGB $snapshot.Tags["DiskSize"]  
		
		}

		$disks += New-AzDisk -Disk $diskConfig -ResourceGroupName $ResourceGroupTarget -DiskName $snapshot.Tags["DiskName"]
		$disks[$index].Tags.Add("DiskCaching", $snapshot.Tags["DiskCaching"])
		$disks[$index].Tags.Add("DiskWAEnabled", $snapshot.Tags["DiskWAEnabled"])
		$disks[$index].Tags.Add("DiskLun", $snapshot.Tags["DiskLun"])
		
		$index++;
	}

	return $disks
}
Function Remove-AllVirualMachineDisks ([string] $ResourceGroup, [object] $VirtualMachine) 
{

	$VirtualMachine.StorageProfile.OsDisk
	Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $VirtualMachine.StorageProfile.OsDisk.Name -Force;

	$disks = $VirtualMachine.StorageProfile.DataDisks
	if ($disks.Count -gt 0) {
		foreach ($disk in $disks) {
			Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name -Force;
		}
	}
}

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
	
	$pathARM = ".\" + $vm_source.Name + ".json"
	Export-AzResourceGroup -ResourceGroupName  $sourceRG -SkipAllParameterization -Resource @($vm_source.Id) -Path $pathARM -Force 
	
	Write-Host -ForegroundColor Green  "The ARM Template path for the original Virtual Machine" $vm_source.Name "path is" $pathARM 
	
	# ----------------------------------------------------------------------------------
	# Create all VM disks snapshot in target Resouce Group ($targetRG)
	# 
	# Note: This func will collect information from the orginal disk settings
	# and copy them in the disk snapshot tags! 
	# Please be sure that all req. disk settings are copied over to the snapshot tags. 
	# Based on that information the new disks will be created
	#
	# Return: $snapshotInfo - list of the Azure Snapshot Resource names
	# ----------------------------------------------------------------------------------
	Write-Host -ForegroundColor Green  "Creating Virtual Machine disks snapshots!"
	$snapshotInfo = Write-VMDisksSnapshot -ResourceGroup $targetRG -VirtualMachine $vm_source

	# -------------------------------------------------------------------
	# Delete Source VM 
	#
	# Note: All disks marked >Delete with VM< will be also removed
	# -------------------------------------------------------------------
	#Write-Host -ForegroundColor Green  "Deleting Virtual Machine!"
	Remove-AzVM -ResourceGroupName $sourceRG -Name $sourceVM -Force   
	#Write-Host -ForegroundColor Green  "Virtual Machine deleted!"
	# -------------------------------------------------------------------
	# Delete other resources...
	#
	# Note: Please remove disks (if they are not already removed)
	# -------------------------------------------------------------------

	# ... your >Delete other resources...< script is going to be... here!
	# e.g. Remove old disks...
	Write-Host -ForegroundColor Green  "Deleting all Virtual Machine disks!"
	Remove-AllVirualMachineDisks -ResourceGroup $sourceRG -VirtualMachine $vm_source
	Write-Host -ForegroundColor Green  "All Virtual Machine disks deleted!"

	# -------------------------------------------------------------------
	# Create new disks from the snapshots 
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
		# Availability Zone - Remove
		# ----------------------------------------------------------------------------------------------
		$templateVM.resources.Get(0).Zones = $null

		# ----------------------------------------------------------------------------------------------
		# Modify original VM template 
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

