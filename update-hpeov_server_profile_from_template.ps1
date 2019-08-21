<#
  .SYNOPSIS
  Updates an HPE OneView Server Profile for a OneView-managed server running VMware ESXi to be in compliance with the Server Profile Template. Generally this is used to install a new firmware baseline but can be used for any reason to bring a server profile in to compliance with its template.

  .DESCRIPTION
  Checks if the server profile template is non-compliant. If so, put the host in Maintenance Mode in VMware, then schedule downtime in Opsview and shutdown the host. When the host is powered off, update the server profile to be in compliance with its server profile template. Once compliant, boot the host. When it has reconnected to vCenter, exit maintenance mode and delete the downtime in Opsview.

  .PARAMETER vCenterServer
  vCenter Server address or hostname
  .PARAMETER vCenterUser
  vCenter Server username
  .PARAMETER vCenterPassword
  vCenter Server password for username
  .PARAMETER HPEOVHostname
  HPE OpenView hostname
  .PARAMETER HPEOVUser
  HPE OpenView username
  .PARAMETER HPEOVPassword
  HPE OpenView password for username
  .PARAMETER ESXiHost
  Name of ESXi host as displayed within vCenter
  
  .EXAMPLE
  .\update-hpeov_server_profile_from_template.ps1 -vCenterServer vcenter.local -vCenterUser "administrator@vsphere.local" -vCenterPassword "password" -HPEOVHostname hpeov.local -HPEOVUser administrator -HPEOVPassword password -ESXiHost esxi01.local

  Use -verbose flag for more detailed output during script execution.
  
  .NOTES
  This script requires a reasonably modern version of the PowerCLI module to be installed from Powershell Gallery as well as HPOneView:
  install-module HPOneView.420 -allowClobber

  Expects the name of the ESXi host as displayed in vCenter to be the entire host FQDN (Example: esxi01.local)
  Assumes the server profile name in OneView is the ESXi hostname (not FQDN) (Example: esxi01)
  Configure the following User-configurable variables within the script:
  - $OpsviewURL : URL of Opsview. Example: https://opsview.local
  - $OpsviewHostPrefix : Prefix for host objects in Opsview, if any
  - $OpsviewUsername : Username for Opsview user with permission to set downtime on the host object
  - $OpsviewPassword : Password for Opsview user
#>

[cmdletbinding()]
Param (
  [parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Address")][string]$vCenterServer,
  [parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter User")][string]$vCenterUser,
  [parameter(Mandatory = $true, Position = 2, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Password")][string]$vCenterPassword,
  [parameter(Mandatory = $true, Position = 3, ValueFromPipelineByPropertyName = $true, HelpMessage = "HPE OneView Hostname")][string]$HPEOVHostname,
  [parameter(Mandatory = $true, Position = 4, ValueFromPipelineByPropertyName = $true, HelpMessage = "HPE OneView Username")][string]$HPEOVUser,
  [parameter(Mandatory = $true, Position = 5, ValueFromPipelineByPropertyName = $true, HelpMessage = "HPE OneView Password")][string]$HPEOVPassword,
  [parameter(Mandatory = $true, Position = 6, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi host")][string]$ESXiHost
)

Start-Transcript

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Get-Module -Name VMware* -ListAvailable | Import-Module
import-module HPOneView.420

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session -Confirm:$false | Out-Null

# User-configurable variables
$OpsviewURL="https://opsview.local"
$OpsviewHostPrefix="MH-"
$OpsviewUsername="automation"
$OpsviewPassword="password"


function Main {

  $vCenterCredential = New-Object -TypeName System.Management.Automation.PSCredential ($vCenterUser, (ConvertTo-SecureString $vCenterPassword -AsPlainText -Force))
  Write-Verbose -Message "$(Get-Date -Format G) Authenticating to vCenter $vCenterServer"
  try {
      $vCenterSession = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential -Force
  }
  catch {
      Write-Warning -Message "$_"
      Write-Error -Category AuthenticationError -Message "Failed to authenticate to vCenter $vCenterServer as user $vCenterUser. Exiting."
      exit 1
  }

  # Could not get this to work
  #$HPEOVCredential = New-Object -TypeName System.Management.Automation.PSCredential ($HPEOVUser, (ConvertTo-SecureString $HPEOVPassword -AsPlainText -Force))
  Write-Verbose -Message "$(Get-Date -Format G) Authenticating to HPE OneView $HPEOVHostname"
  try {
      #$HPEOVSession = Connect-HPOVMgmt -Hostname $HPEOVHostname -Credential $HPEOVCredential -Force
      $HPEOVSession = Connect-HPOVMgmt -Hostname $HPEOVHostname -UserName $HPEOVUser -Password $HPEOVPassword
  }
  catch {
      Write-Warning -Message "$_"
      Write-Error -Category AuthenticationError -Message "Failed to authenticate to HPE OneView $HPEOVHostname as user $HPEOVUser. Exiting."
      exit 1
  }

  $serverProfile = Get-HPOVServerProfile -Name $ESXiHost.Split('.')[0]
  if ($serverProfile.templateCompliance -eq "NonCompliant") {

    # Put host in maintenance mode
    Write-Host "$(Get-Date -Format G) Profile is NonCompliant, putting host $ESXiHost in maintenance mode to update compliance."
    $vmhost = get-vmhost $ESXiHost
    set-vmhost -vmhost $vmhost -State Maintenance -Evacuate:$true -Confirm:$false
    
    # Schedule downtime for host
    # Based on https://github.com/schindlerd/opsview-add-host/blob/master/opsview-add-host.ps1
    $OpsviewHostObj = $OpsviewHostPrefix + $ESXiHost.Split('.')[0]
    Write-Verbose -Message "$(Get-Date -Format G) Scheduling downtime in Opsview for host $OpsviewHostObj"

    $urlauth = $OpsviewURL + "/rest/login"
    $urldowntime = $OpsviewURL + "/rest/downtime?hst.hostname=" + $OpsviewHostPrefix + "-" + $ESXiHost.Split('.')[0]
    $creds = '{"username":"' + $OpsviewUsername + '","password":"' + $OpsviewPassword + '"}'
    $bytes1 = [System.Text.Encoding]::ASCII.GetBytes($creds)
    $web1 = [System.Net.WebRequest]::Create($urlauth)
    $web1.Method = "POST"
    $web1.ContentLength = $bytes1.Length
    $web1.ContentType = "application/json"
    $web1.ServicePoint.Expect100Continue = $false
    $stream1 = $web1.GetRequestStream()
    $stream1.Write($bytes1,0,$bytes1.Length)
    $stream1.Close()
    $reader1 = New-Object System.IO.Streamreader -ArgumentList $web1.GetResponse().GetResponseStream()
    $token1 = $reader1.ReadToEnd()
    $reader1.Close()
    $token1=$token1.Replace("{`"token`":`"", "")
    $token1=$token1.Replace("`"}", "")
    $downtimeData='{"comment":"server profile compliance","endtime":"+1d","starttime":"now"}'
    $bytes2 = [System.Text.Encoding]::ASCII.GetBytes($downtimeData)
    $web2 = [System.Net.WebRequest]::Create($urldowntime)
    $web2.Method = "POST"
    $web2.ContentLength = $bytes2.Length
    $web2.ContentType = "application/json"
    $web2.ServicePoint.Expect100Continue = $false
    $web2.Headers.Add("X-Opsview-Username",$OpsviewUsername)
    $web2.Headers.Add("X-Opsview-Token",$token1);
    $stream2 = $web2.GetRequestStream()
    $stream2.Write($bytes2,0,$bytes2.Length)
    $stream2.Close()
    $reader2 = New-Object System.IO.Streamreader -ArgumentList $web2.GetResponse().GetResponseStream()
    $output2 = $reader2.ReadToEnd()
    $reader2.Close()
    Write-Host $output2

    # Shutdown host, wait for power off
    if ((get-vmhost $vmhost).ConnectionState -eq "Maintenance") { 
      Write-Host "$(Get-Date -Format G) Shutting down host $ESXiHost"
      Stop-VMHost -VMHost $vmhost -Confirm:$false
      Write-Verbose -Message "$(Get-Date -Format G) Waiting 30 secs for host to power off"
      Start-Sleep -Seconds 30

      $serverReady = $false

      if (($serverProfile | Get-HPOVServer).powerState -eq "Off") {
        $serverReady = $true
      }
      else {
        Write-Verbose -Message "$(Get-Date -Format G) Host has not powered off yet, waiting another 15 secs"
        Start-Sleep -Seconds 15
        if (($serverProfile | Get-HPOVServer).powerState -eq "Off") {
          $serverReady = $true
        }
      }

      # Update server profile, wait for completion
      if ($serverReady) {
      
        Write-Host "$(Get-Date -Format G) Updating server profile to be compliant with template. If a new firmware baseline was selected, this could take over 30 minutes."
        $serverProfile | Update-HPOVServerProfile -confirm:$false -Async | Wait-HPOVTaskComplete -Timeout (New-TimeSpan -Minutes 35)

        $serverProfile = Get-HPOVServerProfile -Name $ESXiHost.Split('.')[0]
        if ($serverProfile.templateCompliance -eq "Compliant") {
          # Power on host, exit maintenance mode
          Write-Host "$(Get-Date -Format G) Server profile is now compliant, powering-on host $ESXiHost"
          $serverProfile | Start-HPOVServer

          Write-Verbose -Message "$(Get-Date -Format G) Waiting 300 secs for host to boot"
          Start-Sleep -Seconds 300

          $vmhost = get-vmhost $ESXiHost

          $hostReady = $false
          
          if ($vmhost.ConnectionState -eq "Maintenance") {
            $hostReady = $true
          }
          else {
            Write-Verbose -Message "$(Get-Date -Format G) Host not up yet, waiting another 60 secs for host to boot"
            Start-sleep -seconds 60
            $vmhost = get-vmhost $ESXiHost
            if ($vmhost.ConnectionState -eq "Maintenance") {
              $hostReady = $true
            }
            else {
              Write-Error -Category ResourceUnavailable -Message "Host has not re-connected to vCenter. Investigate. Exiting."
            }
          }

          if ($hostReady) {
            Write-Host "$(Get-Date -Format G) Exiting maintenance mode"
            set-vmhost -vmhost $vmhost -State Connected

            # Delete downtime (technically, this deletes *all* downtime present for the host - current & future)
            Write-Verbose -Message "$(Get-Date -Format G) Removing Opsview Downtime"
            $web2 = [System.Net.WebRequest]::Create($urldowntime)
            $web2.Method = "DELETE"
            $web2.ContentLength = $bytes2.Length
            $web2.ContentType = "application/json"
            $web2.ServicePoint.Expect100Continue = $false
            $web2.Headers.Add("X-Opsview-Username",$OpsviewUsername)
            $web2.Headers.Add("X-Opsview-Token",$token1);
            $stream2 = $web2.GetRequestStream()
            $stream2.Write($bytes2,0,$bytes2.Length)
            $stream2.Close()
            $reader2 = New-Object System.IO.Streamreader -ArgumentList $web2.GetResponse().GetResponseStream()
            $output2 = $reader2.ReadToEnd()
            $reader2.Close()
            Write-Host $output2
          }
        }
        else {
          Write-Error -Category ResourceUnavailable -Message "Host is still not compliant after updating profile. Review. Exiting."
        }
      }
      else {
        Write-Error -Category ResourceUnavailable -Message "Host has not powered off. Exiting."
      }
    }
    else {
      Write-Error -Category ResourceUnavailable -Message "Host not in maintenance mode. Exiting."
    } 
  }
  else {
    Write-Host "$(Get-Date -Format G) Server profile is already compliant with template. Exiting."
  }
  $vCenterSession | disconnect-viserver -confirm:$false 
  $HPEOVSession | Disconnect-HPOVMgmt
}


# Clear any lingering connections from previous runs or manual authentications
try {
  Disconnect-VIServer * -force -confirm:$false -ErrorAction Continue
}
catch {
  
}
try {
  Disconnect-HPOVMgmt
}
catch {

}

# Main engine start
Write-Host "$(Get-Date -Format G) Started" 

Main

Write-Host "$(Get-Date -Format G) Done"
