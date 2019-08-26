<#
  .SYNOPSIS
  Set a new password for a given local account on all ESXi hosts in a given vSphere Cluster

  .DESCRIPTION
  Set a new password for a given local account on all ESXi hosts in a given vSphere Cluster. Generally used to change the root password, but can be used for any local ESXi account. The current password for the target account must be known as this is how the script logs in to the host to set the password for the account.

  .PARAMETER vCenterServer
  vCenter Server address or hostname
  .PARAMETER vCenterUser
  vCenter Server username
  .PARAMETER vCenterPassword
  vCenter Server password for username
  .PARAMETER Cluster
  vSphere Cluster of hosts to set the new password on
  .PARAMETER ESXiUser
  ESXi local username to set new password for. Default: root
  .PARAMETER ESXiUserPasswordCurrent
  ESXi host username current password for all hosts in the given Cluster. All hosts must use the same password.
  .PARAMETER ESXiUserPasswordNew
  ESXi host username New password to set on all hosts in the given Cluster. All hosts will use the same password for given username.
  
  .EXAMPLE
  .\Set-ESXi_pass.ps1 -vCenterServer 192.168.1.2 -vCenterUser administrator@vsphere.local -vCenterPassword (ConvertTo-SecureString "myVCpassword" -AsPlainText -Force) -Cluster TestCluster -ESXiUserPasswordCurrent (ConvertTo-SecureString "hunter2" -AsPlainText -Force) -ESXiUserPasswordNew (ConvertTo-SecureString "hunter3" -AsPlainText -Force) -verbose
  
  .NOTES
  Pre-requisites:
  - This script requires a reasonably modern version of the PowerCLI module to be installed from Powershell Gallery.
  - Passwords must be passed as SecureStrings: -ESXiUserPasswordNew (ConvertTo-SecureString "hunter3" -AsPlainText -Force)

  Limitations:
  - Existing password of ESXiUser must be known
  - All hosts in the given Cluster must use the same current password for the specified ESXiUser and all hosts will have the specified ESXiUser password changed to the new specified password.
#>

[cmdletbinding()]
Param (
  [parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Address")][string]$vCenterServer,
  [parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter User")][string]$vCenterUser,
  [parameter(Mandatory = $true, Position = 2, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Password")][securestring]$vCenterPassword,
  [parameter(Mandatory = $true, Position = 3, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Cluster")][string]$Cluster,
  [parameter(Mandatory = $false, Position = 4, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi User")][string]$ESXiUser = "root",
  [parameter(Mandatory = $true, Position = 5, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi User current Password")][securestring]$ESXiUserPasswordCurrent,
  [parameter(Mandatory = $true, Position = 6, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi User new Password")][securestring]$ESXiUserPasswordNew
)

Get-Module -Name VMware* -ListAvailable | Import-Module

Set-StrictMode -Version Latest
#$ErrorActionPreference = "Stop"
#Requires -Version 5
#Requires -Modules VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

$vCenterCredential = New-Object -TypeName System.Management.Automation.PSCredential ($vCenterUser, $vCenterPassword)
$ESXiCurrentCredential = New-Object -TypeName System.Management.Automation.PSCredential ($ESXiUser, $ESXiUserPasswordCurrent)
$ESXiNewCredential = New-Object -TypeName System.Management.Automation.PSCredential ($ESXiUser, $ESXiUserPasswordNew)

Write-Verbose -Message "$(Get-Date -Format G) Authenticating to vCenter server $vCenterServer as $vCenterUser"
try {
  $vCenterSession = connect-viserver -server $vCenterServer -Credential $vCenterCredential -Force -ErrorAction Stop
}
catch {
  Write-Warning -Message "$_"
  Write-Error -Category AuthenticationError -Message "Failed to authenticate to vCenter server $vCenterServer as user $vCenterUser. Exiting."
  exit 1
}

Write-Verbose -Message "$(Get-Date -Format G) Enumerating hosts for cluster $Cluster"
try {
  $vmhosts = Get-Cluster -name $Cluster -ErrorAction Stop | Get-VMHost -ErrorAction Stop
}
catch {
  Write-Warning -Message "$_"
  Write-Error -Category AuthenticationError -Message "Failed to enumerate hosts for cluster $Cluster. Exiting."
  Disconnect-VIServer -Server $vCenterSession -confirm:$false
  exit 1
}

Write-Verbose -Message "$(Get-Date -Format G) Disconnecting from vCenter server $vCenterServer"
Disconnect-VIServer -Server $vCenterSession -confirm:$false

foreach ($vmhost in $vmhosts) {
  Write-Verbose -Message "$(Get-Date -Format G) Connecting to host $vmhost as user $ESXiUser"
  try {
    $ESXiSession = connect-viserver -server $vmhost -Credential $ESXiCurrentCredential -Force -ErrorAction Stop
  }
  catch {
    Write-Warning -Message "$_"
    Write-Error -Category AuthenticationError -Message "Failed to connect to host $vmhost as user $ESXiUser, continuing to next host."
    Continue
  }
  
  $Message = "$(Get-Date -Format G) Setting new password for user $ESXiUser on host $vmhost"
  Write-Host $Message
  Write-Verbose -Message $Message
  try {
    $ESXiUserObject = Get-VMHostAccount -Server $ESXiSession -User $ESXiUser -ErrorAction Stop
  }
  catch {
    Write-Warning -Message "$_"
    Write-Error -Category AuthenticationError -Message "Failed to get user $ESXiUser on host $vmhost, continuing to next host."
    Disconnect-VIServer -server $ESXiSession -confirm:$false
    Continue
  }
  
  try {
    $ESXiUserObject | Set-VMHostAccount -Server $ESXiSession -password $ESXiNewCredential.GetNetworkCredential().Password -Confirm:$false -ErrorAction Stop | Out-Null
  }
  catch {
    Write-Warning -Message "$_"
    Write-Error -Category AuthenticationError -Message "Failed to set new password for user $ESXiUser on host $vmhost, continuing to next host."
    Disconnect-VIServer -server $ESXiSession -confirm:$false
    Continue
  }

  Write-Verbose -Message "$(Get-Date -Format G) Disconnecting from $vmhost"
  Disconnect-VIServer -server $ESXiSession -confirm:$false
}

Write-Verbose -Message "$(Get-Date -Format G) Finished"
