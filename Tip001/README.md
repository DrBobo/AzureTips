

## #001 - Move VM from VM size (with/without) temp disk to the VM Size (with/without)

## 🚨 Disclaimer
The opinions expressed herein are my own personal opinions and do not represent my employer’s view in any way.

THE SCRIPTS ARE PROVIDED AS IS WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.


## 🌐 Important Links 

[Azure VM sizes with no local temporary disk](https://docs.microsoft.com/en-us/azure/virtual-machines/azure-vms-no-temp-disk?msclkid=84c91efdd10511ecaec6d6790d915e24)

## 📢Note
IMPORTANT Before you execute the scripts, make sure to first backup your VM and test it on the test VMs. Make sure that test VMs have the same configuration as productive VMs. That means they should have the same VM SKU, disk types, disk numbers and sizes, same number of NIC cards, same subscription etc. 


## 🤔 The issue we are trying to solve
You must have already come across Azure VMs and sometimes a little confusing Azure VM names naming convention. If you don't pay attention you may try to create a VM with a Primary Disk on a VM that does not support Primary Disk ... or you may get a VM without Temorary storage even you thought temp storage is always defined on Azure VMs. Exactly that, what I mentioned last, I would like to explain to you what it is all about and how to change the VM Size from VM Size with temp storage to VM Size without temp storage and vice versa.


## 💪 A possible solution
The steps I'm describing here are also reflected in the powershell script and provided as separated PowerShell functions. My goal is to explain to you the steps you need to take if you want to change VM with temp storage to the VM without temp storage and vice versa.
It is very important that you understand the whole script and whether it fully or only partially reflects to your landscape. 
Check the [Can I resize a VM size that has a local temp disk to a VM size with no local temp disk?](https://docs.microsoft.com/en-us/azure/virtual-machines/azure-vms-no-temp-disk#can-i-resize-a-vm-size-that-has-a-local-temp-disk-to-a-vm-size-with-no-local-temp-disk---) 

Step 1.
Get the details from the VM (with/without temp disk) to be resized to new VM Size (with/without temp disk), and create the ARM Template from that VM.

Step 2. 
We will first make a snapshot of all disks on the VM! The disk snapshots are created in Target ResourceGroup. If you want to clean Target ResourceGroup later you have to do it yourself. Currently script is not doing that!

Step 3.
Creating new Managed Disks from the snapshots and copying all orginal disk settings back to thew newly created Managed Disks.

Step 4.
Create new VM with new VM Size out of modified ARM Template and "attaching" NIC and the disks!

📢Note: The current script implementation doesn't copy all VM settings from old VM to the new VM!

📢Note: By creating a new VM, the VM gets a new VM ID! Some software vendors use the VM ID as the HW key to generate software licenses. Check your software vendor documentation and follow the instructions to reactivate the licenses.

## 🚀 Example

Move-VM-TempDisk.ps1 -subscriptionName 'Subscription Name' -location 'Azure Region Name' -sourceRG 'Source Resource Group' -targetRG 'Target Resource Group' -sourceVM 'The Virtual Machine Name' -targetVMSize 'new VM Size'
