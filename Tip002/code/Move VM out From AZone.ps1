param (
	#--------------------------------------------------------------
	# essential parameters
	#--------------------------------------------------------------
	# parameter is always mandatory
	[Parameter(Mandatory=$True)]
	[int] $stepIndex,

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

Function Add-DiskToVirtualMachine([object] $VMConfig, [object[]] $Disks) 
{
	# ---------------------------------------------------------------------------------
	# Add Managed Disks to Virtual Machine
	# ---------------------------------------------------------------------------------
	$index = 0
	if ($Disks.Count -gt 0) {
		foreach ($disk in $Disks) {
			if($index -eq 0) {
				if ($disk.OsType -eq "Windows") {
					$vm_Target = Set-AzVMOSDisk -VM $vm_Target -Name $disk.Name -DiskSizeInGB $disk.DiskSizeGB -ManagedDiskId $disk.Id -CreateOption Attach -Windows -Caching $disk.Tags["DiskCaching"] 
				} else {
					$vm_Target = Set-AzVMOSDisk -VM $vm_Target -Name $disk.Name -DiskSizeInGB $disk.DiskSizeGB -ManagedDiskId $disk.Id -CreateOption Attach Linux -Caching $disk.Tags["DiskCaching"] 
				}
			}
			else {
				if ($disk.Tags["DiskWAEnabled"] -eq "False") {
					$vm_Target = Add-AzVMDataDisk -VM $vm_Target -Name $disk.Name -DiskSizeInGB $disk.DiskSizeGB -Lun $disk.Tags["DiskLun"] -ManagedDiskId $disk.Id -CreateOption Attach -Caching $disk.Tags["DiskCaching"] 
				} else {
					$vm_Target = Add-AzVMDataDisk -VM $vm_Target -Name $disk.Name -DiskSizeInGB $disk.DiskSizeGB -Lun $disk.Tags["DiskLun"] -ManagedDiskId $disk.Id -CreateOption Attach -Caching $disk.Tags["DiskCaching"] -WriteAccelerator 
				}

			}
			$index++
		}
	}
	return $VMConfig
}

Function Add-NICsToVirtualMachine ([object] $vm_source, [object] $vm_target) 
{
	# ---------------------------------------------------------------------------------
	# Add the NICs to the VM
	# ---------------------------------------------------------------------------------

	$nics = $vm_source.NetworkProfile.NetworkInterfaces

	foreach ($nic in $nics) {
		$vm_Target = Add-AzVMNetworkInterface -VM $vm_Target -Id $nic.Id
	}

	return $vm_Target
}

Function Remove-AllVirualMachineDisks ([string] $ResourceGroup, [object] $VirtualMachine) 
{

	Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $VirtualMachine.StorageProfile.OsDisk.Name -Force;

	$disks = $VirtualMachine.StorageProfile.DataDisks
	if ($disks.Count -gt 0) {
		foreach ($disk in $disks) {
			Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name -Force;
		}
	}

}

# --------------------------------------------------------------------------
#                     Remove VM from Availability Zone
#
#     BEFORE EXECUTING THIS SCRIPT PLEASE BACKUP YOUR VIRTUAL MACHINE
# --------------------------------------------------------------------------

# ------------------------------------------------------
# Running in the right Subscription?
# ------------------------------------------------------

$subscription = Get-AzSubscription -SubscriptionName $SubscriptionName
if (-Not $Subscription) {
    Write-Host -ForegroundColor Red -BackgroundColor White "Sorry, it seems you are not connected to Azure or don't have access to the subscription. Please use Connect-AzAccount to connect."
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
	$rt_Target = New-AzResourceGroup -Name $targetRG -Location $location
}

try {

	# ----------------------------------------------------------------
	# Get the details from the VM to be moved out of Availability Zone
	# ----------------------------------------------------------------

	$vm_source = Get-AzVM -ResourceGroupName $sourceRG -Name $sourceVM

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

	$snapshotInfo = Write-VMDisksSnapshot -ResourceGroup $targetRG -VirtualMachine $vm_source

	# -------------------------------------------------------------------
	# Delete Source VM 
	#
	# Note: All disks marked >Delete with VM< will be also removed
	# -------------------------------------------------------------------
	Remove-AzVM -ResourceGroupName $sourceRG -Name $sourceVM -Force   

	# -------------------------------------------------------------------
	# Delete other resources...
	#
	# Note: Please remove disks (if they are not already removed)
	# -------------------------------------------------------------------

	# ... your >Delete other resources...< script is going to be... here!
	# e.g. Remove old disks...

	Remove-AllVirualMachineDisks -ResourceGroup $sourceRG -VirtualMachine $vm_source

	# ----------------------------------------------------------------------------------------------
	# CREATE Virtual Machine (VM) 
	#
	# Note: In this example not all VM properties are copied over from old to the new VM!
	# Please implement an additional mapping if necessery
	# ----------------------------------------------------------------------------------------------

	#Initialize virtual machine configuration
	$vm_Target = New-AzVMConfig -VMName $vm_Source.Name -VMSize $vm_Source.HardwareProfile.VmSize -LicenseType $vm_Source.LicenseType

	# -------------------------------------------------------------------
	# Create new disks from the snapshots 
	# -------------------------------------------------------------------

	$disks = Write-DiskFromSnapshot -Location $location -ResourceGroupSnapshot $targetRG -ResourceGroupTarget $sourceRG -SnapshotsInfo $snapshotInfo

	# ---------------------------------------------------------------------------------
	# Add the Disks to the VM
	# ---------------------------------------------------------------------------------

	$vm_Target = Add-DiskToVirtualMachine -VMConfig $vm_Target -Disks $disks

	# ---------------------------------------------------------------------------------
	# Add the NICs to the VM
	# ---------------------------------------------------------------------------------

	$vm_Target = Add-NICsToVirtualMAchine -vm_source $vm_source -vm_target $vm_Target

	# ---------------------------------------------------------------------------------
	# Recreate the VM
	# ---------------------------------------------------------------------------------
	New-AzVM -ResourceGroupName $sourceRG -Location $vm_source.Location -VM $vm_Target #-AsJob
} catch {
	Write-Host -ForegroundColor Red -BackgroundColor White "Error: $ErrorMessage"
}	
