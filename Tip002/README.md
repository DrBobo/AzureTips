
## #002 - Move VM out of Availability Zone

## 🚨 Disclaimer
The opinions expressed herein are my own personal opinions and do not represent my employer’s view in any way.

THE SCRIPTS ARE PROVIDED AS IS WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.


## 🌐 Important Links 

[Overview Availability zones](https://docs.microsoft.com/en-us/azure/availability-zones/az-overview#availability-zones)

[Azure services that support availability zones](https://docs.microsoft.com/en-us/azure/availability-zones/az-region)

## 📢Note
IMPORTANT Before you execute the scripts, make sure to first backup your VM and test it on the test VMs. Make sure that test VMs have the same configuration as productive VMs. That means they should have the same VM SKU, disk types, disk numbers and sizes, same number of NIC cards, same subscription etc. 


## 🤔 The issue we are trying to solve
If by any chance you get into a situation where you want to move VM out of Availability Zone you've probably discovered that you can't do something like this in the Azure portal, and also there are no an easy way with the PowerShell or the Azure CLI too.


## 💪 A possible solution
The steps I'm describing here are also reflected in the powershell script and provided as separated PowerShell functions. My goal is to explain to you the steps you need to take if you want to move VM out of Availability Zone and how you can do it using the PowerShell. It is very important that you understand the whole script and whether it fully or only partially reflects to your landscape. 
Check the [list](https://docs.microsoft.com/en-us/azure/availability-zones/az-region) of  Azure services that support Availability Zones!

Step 1.
Get the details from the VM to be moved out of Availability Zone, and create the ARM Template from that VM.

Step 2. 
Move all VM disks from Availability Zones! We will first make a snapshot of all disks on the VM! The disk snapshots are created in Target ResourceGroup. If you want to clean Target ResourceGroup later you have to do it yourself. Currently script is not doing that!

Step 3.
Creating new Managed Disks from the snapshots and copying all orginal disk settings back to thew newly created Managed Disks.

Step 4.
Create new VM out of modified ARM Template and "attaching" NIC and the disks!

📢Note: The current script implementation doesn't copy all VM settings from old VM to the new VM!

📢Note: By creating a new VM, the VM gets a new VM ID! Some software vendors use the VM ID as the HW key to generate software licenses. Check your software vendor documentation and follow the instructions to reactivate the licenses.

## 🚀 Example

.\'Move VM out From AZone.ps1' -subscriptionName 'Subscription Name' -location 'Azure Region Name' -sourceRG 'Source Resource Group' -targetRG 'Target Resource Group' -sourceVM 'The Virtual Machine Name'
