#requires -Modules ThreadJob
<#
.SYNOPSIS
 Stop VMs that were started as part of an Update Management deployment

.DESCRIPTION
  This is an update of the Updatemanagement scripts found in runbook gallery. This script is intended to be run as a part of Update Management Pre/Post scripts. 
  It requires a RunAs account.
  This script will turn off all Azure VMs that were started as part of TurnOnVMs.ps1.
  It retrieves the list of VMs that were started from an Automation Account variable.
  If the VM is a WVD Spring 2020 Release session host and the Hostpool object is in the same resource group, it will also disable the drain mode set by the Turn on VM Script

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
$runId = "PrescriptContext" + $context.SoftwareUpdateConfigurationRunId


#Retrieve the automation variable, which we named using the runID from our run context. 
#See: https://docs.microsoft.com/en-us/azure/automation/automation-variables#activities


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
$variable = Get-AutomationVariable -Name $runId
if (!$variable) 
{
    Write-Output "No machines to turn off"
    return
}
Write-Output "variable: $($variable.Value)"
$vmIds = $variable -split ","
$stoppableStates = "starting", "running"
$jobIDs= New-Object System.Collections.Generic.List[System.Object]

Write-Output "VMids: $($vmIds.Value)"

#This script can run across subscriptions, so we need unique identifiers for each VMs
#Azure VMs are expressed by:
# subscription/$subscriptionID/resourcegroups/$resourceGroup/providers/microsoft.compute/virtualmachines/$name
$vmIds | ForEach-Object {
    Write-Output "vmids: $($vmIds.Value)"
    $vmId =  $_
    Write-Output "vmid : $($vmId.Value)"
    $split = $vmId -split "/";
    Write-Output "split : $($split.Value)"
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];
    Write-Output ("Subscription Id: " + $subscriptionId)
    $mute = Select-AzSubscription -Subscription $subscriptionId

    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status 

    $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
    if($state -in $stoppableStates) {
        Write-Output "Stopping '$($name)' ..."
        
        $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname) Stop-AzVM -ResourceGroupName $resource -Name $vmname -Force} -ArgumentList $rg,$name 
        $jobIDs.Add($newJob.Id)
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
                        $DrainMode = Update-AzWvdSessionHost -Name $SessionHostName -HostPoolName $_.Name -ResourceGroupName $rg -AllowNewSession:$true
                        Write-Output " Drain mode successful: $($DrainMode.ToJsonString())"
                    }
                }
            }
        }
        catch {
            Write-Output "Exception processing WVD Session hosts: $($_.exception.message)"
        }
    }else {
        Write-Output ($name + ": already stopped. State: " + $state) 
    }
}
#Wait for all machines to finish stopping so we can include the results as part of the Update Deployment
$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish stopping..."
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
#Clean up our variables:
Remove-AzAutomationVariable -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup -name $runID
