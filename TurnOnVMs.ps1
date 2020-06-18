#requires -Modules ThreadJob
<#
.SYNOPSIS
 Start VMs as part of an Update Management deployment

.DESCRIPTION
  This is an update of the Updatemanagement scripts found in runbook gallery. This script is intended to be run as a part of Update Management Pre/Post scripts. 
  It requires a RunAs account.
  This script will ensure all Azure VMs in the Update Deployment are running so they recieve updates.
  This script will store the names of machines that were started in an Automation variable so only those machines
  are turned back off when the deployment is finished (UpdateManagement-TurnOffVMs.ps1)
  If the VM is a WVD Spring 2020 Release session host and the Hostpool object is in the same resource group, it will also enable the drain mode set by the Turn on VM Script

.PARAMETER SoftwareUpdateConfigurationRunContext
  This is a system variable which is automatically passed in by Update Management during a deployment.

#>

param(
    [string]$SoftwareUpdateConfigurationRunContext
)


#region BoilerplateAuthentication
#This requires a RunAs account
$ServicePrincipalConnection = Get-AutomationConnection -Name 'AzureRunAsConnection'

Add-AzAccount `
    -ServicePrincipal `
    -TenantId $ServicePrincipalConnection.TenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint

$AzureContext = Select-AzSubscription -SubscriptionId $ServicePrincipalConnection.SubscriptionID
#endregion BoilerplateAuthentication


#If you wish to use the run context, it must be converted from JSON
$context = ConvertFrom-Json  $SoftwareUpdateConfigurationRunContext
$vmIds = $context.SoftwareUpdateConfigurationSettings.AzureVirtualMachines
$runId = "PrescriptContext" + $context.SoftwareUpdateConfigurationRunId
Write-Output " context : $($context.Value)"
if (!$vmIds) 
{
    #Workaround: Had to change JSON formatting
    $Settings = ConvertFrom-Json $context.SoftwareUpdateConfigurationSettings
    #Write-Output "List of settings: $Settings"
    $VmIds = $Settings.AzureVirtualMachines
    #Write-Output "Azure VMs: $VmIds"
    if (!$vmIds) 
    {
        Write-Output "No Azure VMs found"
        return
    }
}

#https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Find-WhoAmI
# In order to prevent asking for an Automation Account name and the resource group of that AA,
# search through all the automation accounts in the subscription 
# to find the one with a job which matches our job ID
$AutomationResource = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts

foreach ($Automation in $AutomationResource)
{
    $Job = Get-AzAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
    if (!([string]::IsNullOrEmpty($Job)))
    {
        $ResourceGroup = $Job.ResourceGroupName
        $AutomationAccount = $Job.AutomationAccountName
        break;
    }
}

#This is used to store the state of VMs
New-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $runId -Value "" -Encrypted $false

$updatedMachines = @()
$startableStates = "stopped" , "stopping", "deallocated", "deallocating"
$jobIDs= New-Object System.Collections.Generic.List[System.Object]

#Parse the list of VMs and start those which are stopped
#Azure VMs are expressed by:
# subscription/$subscriptionID/resourcegroups/$resourceGroup/providers/microsoft.compute/virtualmachines/$name
$vmIds | ForEach-Object {
    $vmId =  $_
    
    $split = $vmId -split "/";
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];
    Write-Output ("Subscription Id: " + $subscriptionId)
    $mute = Select-AzSubscription -Subscription $subscriptionId

    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status 

    #Query the state of the VM to see if it's already running or if it's already started
    $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
    if($state -in $startableStates) {
        Write-Output "Starting '$($name)' ..."
        #Store the VM we started so we remember to shut it down later
        $updatedMachines += $vmId
        try {
            $HostPool = Get-AzWvdHostPool -ResourceGroupName $rg 
            Write-Output " Host Pools found : $($HostPool.ToJsonString())"
            $HostPool | ForEach-Object {
                $SessionHost =  Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $_.Name
                Write-Output " Session Host Found : $($SessionHost.ToJsonString())"
                foreach( $sh in $SessionHost ){
                    $SessionHostName = $sh.Name.Split('/')[1]
                    Write-Output " Session Host Name : $($SessionHostName)"
                    $VMName = $SessionHostName.Split(".")[0]
                    if( $SessionHostName.ToLower().Contains($name.ToLower()) ) {
                        $DrainMode = Update-AzWvdSessionHost -Name $SessionHostName -HostPoolName $_.Name -ResourceGroupName $rg -AllowNewSession:$false
                        Write-Output " Drain mode successful: $($DrainMode.ToJsonString())"
                    }
                }
            }
        }
        catch {
            Write-Output "Exception processing WVD Session hosts: $($_.exception.message)"
        }
        $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname) Start-AzVM -ResourceGroupName $resource -Name $vmname} -ArgumentList $rg,$name
        $jobIDs.Add($newJob.Id)
    }else {
        Write-Output ($name + ": no action taken. State: " + $state) 
    }
}

$updatedMachinesCommaSeperated = $updatedMachines -join ","
#Wait until all machines have finished starting before proceeding to the Update Deployment
$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish starting..."
    Wait-Job -Id $jobsList
}

foreach($id in $jobsList)
{
    $job = Get-Job -Id $id
    if ($job.Error)
    {
        Write-Output $job.Error
    }

}

Write-output $updatedMachinesCommaSeperated
#Store output in the automation variable
Set-AzAutomationVariable -Name $runId -Value $updatedMachinesCommaSeperated -Encrypted $false -ResourceGroupName $rg -AutomationAccountName $AutomationAccount
