# Azure Update Management scripts
 These scripts are to be used as pre/post scripts in Azure Update management service. They provide functionality to turn on VMs for updating them and then turning them off.

**Pre-requisites:**<br>
Requires Azure VMs that are initialized in Azure Update Management service.<br>
WVD Spring Release 2020 objects(if any) such as hostpools are required to be in the same resource group as their respective Session host VMs.

**Steps: **<br>

 * Create two runbooks for Turning on VMs and Turning off VMs.
 * Copy the content from files in this repository to respective runbooks and publish them
 * Create a deployment schedule for updates.
 * In the options, select the VMs to be included in the deployment.
 * Under Pre-scripts + Post-scripts, select the turning on script and set it as Pre-script.
 * Similarly select the turning off scripts as Post-script.
 * Select remainder of the options as required and save.

<p>Next time the update deployment is triggered, it will first turn on all the VMs which are either stopped, stopping, deallocated or deallocating as part of the Pre-script.<br>
During this execution, it will try to find if there are any hostpools in the resource group and sets the drain mode to On if the VM it is turning on is a part of the hostpool. It will then store the VMs in a Automation Variable.<br>
After the update, the Post-script will turn off the VMs that are previously turned on by the Pre-script.<br>
During this execution, the script will only target the VMs that were turned on by the Pre-script, set the drain mode to Off if they are session hosts to a particular hostpool in the same resource group while turning them off.<br> </P>

**Happy updating/patching!!**