<#
  .SYNOPSIS
  Applies configuration to an ESXi host

  .DESCRIPTION
  Loops through a CSV file specified by parameter HostsCSV and configures all hosts defined within the CSV file to have a common configuration outlined in the script, using parameters from the CSV file and parameters passed to this script.

  All parameters are mandatory.

  .PARAMETER vCenterServer
  vCenter Server address or hostname
  .PARAMETER vCenterUser
  vCenter Server username
  .PARAMETER vCenterPassword
  vCenter Server password for username
  .PARAMETER rootPassword
  ESXi root user password configured on all hosts (necessary to create local 'opsview' user for read-only monitoring)
  .PARAMETER monitoringUser
  Username to create on local ESXi host for monitoring purposes
  .PARAMETER monitoringPassword
  Password to set for new monitoringUser
  .PARAMETER NTPservers
  Double-quoted comma-seperated string of NTP FQDNs to use. Example: "ntp01.corp.local,ntp02.corp.local"
  .PARAMETER HostsCSV
  Path to Hosts CSV file which includes the following columns: host,vmotionIP,vmotionvlan,iSCSIIPA,iSCSIIPB,iSCSIVLAN
  All row values should be double-quoted and comma-separated. Values in the 'host' column must be entered as they are displayed in vCenter for the host
  .PARAMETER PureCSV
  Path to Pure Array CSV file containing the following column: targetIP
  Add rows for each iSCSI target IP on the array
  .PARAMETER PureHostname
  Hostname or IP of the Pure array to connect with the API
  .PARAMETER PureUser
  Username to use with Pure API. Typically 'pureuser'
  .PARAMETER PurePassword
  Password for PureUser to use with Pure API
  .PARAMETER PureHostGroup
  Pure Host Group name to add new hosts to. Recommended to be the same name as the ESX Cluster defined in vCenter. This host group will be created on the Pure if it doesn't exist already.
  
  .EXAMPLE
  .\Set-ESXi.ps1 -vCenterServer <vcenter FQDN> -vCenterUser administrator@ostvsphere.local -vCenterPassword <vcenter password> -rootPassword <ESXi root password> -NTPservers <double-quoted comma-seperated NTP FQDNs> -HostsCSV .\<cluster name>_hosts.csv -PureCSV .\<pure name>_iSCSIIPs.csv -PureHostname <pure hostname/IP> -PureUser pureuser -PurePassword <pureuser password> -PureHostGroup <Pure host group name, typically same as Cluster name>

  Use -verbose flag for more detailed output during script execution.
  
  .NOTES
  Steps performed:
  - Create Host Group on Pure array if doesn't exist already
  - Start & Enable SSH, suppress warning. If warning suppression is not desired, search for and comment out the line containing "UserVars.SuppressShellWarning"
  - Suppress the Hyperthreading warning notice as described in https://kb.vmware.com/s/article/57374. If this is not desired, search for and comment out the line containing "UserVars.SuppressHyperthreadWarning"
  - Set and enable syslog destination of vCenter server, set outbound firewall exception.
  - Set and enable network coredump destination of vCenter server IP address (obtained via DNS lookup) using the host's vmk0 interface
  - Set and enable NTP time sync, set outbound firewall exception.
  - Create a local read-only ESXi user for monitoring
  - Configure networking
  -- Set vSwitch0 MTU 9000
  -- Add vmnic1 to vSwitch0, assuming vmnic0 is already present
  -- Set vmk0 Management Network to MTU 9000
  -- Remove default "VM Network" portgroup
  -- Set vMotion interface on vmotion netstack with IP and VLAN and MTU 9000
  - Pure storage configuration
  -- Set best practices for iSCSI connectivity
  -- Path Selection Policy of Round Robin is alrady present in vSphere 6.7 so it is not set.
  -- Create new vSwitch0 port groups for iSCSI A & B on proper VLAN, set appropriate teaming policy (1 vmnic active, other vmnic unused) and MTU 9000
  -- Enable software iSCSI, configure port mappings for multi-pathing
  -- Set Pure best pratices for iSCSI adapters
  -- Add host to Pure array and join it to the Host Group on the array
  -- Add Pure iSCSI IP targets to host

  Pre-requisites:
  - This script requires a reasonably modern version of the PowerCLI module to be installed from Powershell Gallery. 
  - The PureStoragePowerShellSDK must also be installed: https://github.com/PureStorage-Connect/PowerShellSDK
  - Hosts must be licensed and in maintenance mode, otherwise they will be skipped.
  - vCenter FQDN must be resolvable by DNS from the shell where this script is running.
  - Only 1 iSCSI VLAN is assumed/set

  Troubleshooting: 
  - To re-run the script against one of a subset of hosts, make a copy of the hosts CSV file and modify it to contain only the hosts as needed.
  - Efforts have been made to catch errors so the script can continue running, but some are fatal and will need to be addressed. Script does not check if each and every item is already set, rather it tries to set them and catches failures that may indicate it is already set and moves on.

  Limitations:
  - This script does not configure dvSwitch membership or guest networking. Please manually add the host to any applicable dvSwitches after script configuration completes.
#>

[cmdletbinding()]
Param (
  [parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Address")][string]$vCenterServer,
  [parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter User")][string]$vCenterUser,
  [parameter(Mandatory = $true, Position = 2, ValueFromPipelineByPropertyName = $true, HelpMessage = "vCenter Password")][string]$vCenterPassword,
  [parameter(Mandatory = $true, Position = 3, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi root Password")][string]$rootPassword,
  [parameter(Mandatory = $true, Position = 4, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi local monitoring User")][string]$monitoringUser,
  [parameter(Mandatory = $true, Position = 5, ValueFromPipelineByPropertyName = $true, HelpMessage = "ESXi monitoring Password")][string]$monitoringPassword,
  [parameter(Mandatory = $true, Position = 6, ValueFromPipelineByPropertyName = $true, HelpMessage = "NTP server list")][string]$NTPservers,  
  [parameter(Mandatory = $true, Position = 7, ValueFromPipelineByPropertyName = $true, HelpMessage = "Path to host definition CSV file")][string]$HostsCSV,
  [parameter(Mandatory = $true, Position = 8, ValueFromPipelineByPropertyName = $true, HelpMessage = "Path to Pure target definition CSV file")][string]$PureCSV,
  [parameter(Mandatory = $true, Position = 9, ValueFromPipelineByPropertyName = $true, HelpMessage = "Pure Hostname")][string]$PureHostname,
  [parameter(Mandatory = $true, Position = 10, ValueFromPipelineByPropertyName = $true, HelpMessage = "Pure Username")][string]$PureUser,
  [parameter(Mandatory = $true, Position = 11, ValueFromPipelineByPropertyName = $true, HelpMessage = "Pure Password")][string]$PurePassword,
  [parameter(Mandatory = $true, Position = 12, ValueFromPipelineByPropertyName = $true, HelpMessage = "Pure Host Group")][string]$PureHostGroup
)

Get-Module -Name VMware* -ListAvailable | Import-Module
import-module PureStoragePowerShellSDK

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session -Confirm:$false | Out-Null

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
  
  $PureCreds = new-object System.Management.Automation.PSCredential ($PureUser,(ConvertTo-SecureString $PurePassword -AsPlainText -Force))
  Write-Verbose -Message "$(Get-Date -Format G) Authenticating to Pure $PureHostname"
  try {
    $PureArray = New-PfaArray -EndPoint $PureHostname -Credentials $PureCreds -IgnoreCertificateError -ErrorAction stop
  }
  catch {
    Write-Warning -Message "$_"
    Write-Error -Category AuthenticationError -Message "Failed to authenticate to Pure $PureHostname as user $PureUser. Exiting."
    exit 1
  }
  
  # Create the host group on the Pure if it does not exist already
  try { 
    Write-Verbose -Message "$(Get-Date -Format G) Checking if Pure host group already exists for $PureHostGroup"
    $PureHG = Get-PfaHostGroup -Array $PureArray -Name $PureHostGroup -ErrorAction stop
  }
  catch {
    Write-Verbose -Message "$(Get-Date -Format G) Could not get host group: $PureHostGroup, trying to create it."
    Write-Warning -Message "$_"
    try {
      Write-Verbose -Message "$(Get-Date -Format G) Creating Pure host group for $PureHostGroup"
      $PureHG = New-PfaHostGroup -Array $PureArray -Name $PureHostGroup -ErrorAction stop
    }
    catch {
      Write-Warning -Message "$_"
    }
  }
  
  # Get vCenter server IP to use for Net Dump config (requires IP, not hostname)
  $vCenterServerIP = [System.Net.Dns]::GetHostAddresses($vCenterServer).IPAddressToString

  # Import CSV contents
  $vmhostConfig = import-csv $HostsCSV
  $pureConfig = import-csv $PureCSV
  
  # Loop through all hosts in CSV file and configure them
  $vmhostConfig | ForEach-Object {
    $thisVMhost = $_.host
    $vMotionIP = $_.vMotionIP
    $vMotionVLAN = $_.vMotionVLAN
    $iSCSIIPA = $_.iSCSIIPA
    $iSCSIIPB = $_.iSCSIIPB
    $iSCSIVLAN = $_.iSCSIVLAN

    write-host "$(Get-Date -Format G) Configuring $thisVMhost"
    try {
      $vmhost = get-vmhost $thisVMhost
    }
    catch {
      Write-Error -Category ResourceUnavailable -Message "Failed to get-vmhost $thisVMhost"
      break
    }

    Write-Verbose -Message "$(Get-Date -Format G) Checking if host is in maintenance mode"
    if ($vmhost.ConnectionState -ne "Maintenance") {
      Write-Error -Category ResourceUnavailable -Message "Host $thisVMhost is not in maintenance mode, skipping"
      break
    }

    Write-Verbose -Message "$(Get-Date -Format G) Checking if host is licensed"
    if ($vmhost.LicenseKey -eq '00000-00000-00000-00000-00000') { 
      Write-Error -Category ResourceUnavailable -Message "Host $thisVMhost is not licensed, skipping"
      break
    }
    
    $esxcli = get-esxcli -VMHost $vmhost -v2
    
    # Suppress warning for https://kb.vmware.com/s/article/57374
    $vmhost | Get-AdvancedSetting | Where-Object {$_.Name -eq "UserVars.SuppressHyperthreadWarning"} | Set-AdvancedSetting -Value "1" -Confirm:$false | Out-null
  
	  # enable/start ssh
    Write-Verbose -Message "$(Get-Date -Format G) Enabling/starting SSH"
    $vmhost | get-vmhostservice | where-object {$_.key -eq "TSM-SSH"} | set-vmhostservice -policy "On" | Out-Null
    $vmhost | get-vmhostservice | where-object {$_.key -eq "TSM-SSH"} | start-vmhostservice -confirm:$false | Out-Null
    $vmhost | Get-AdvancedSetting | Where-Object {$_.Name -eq "UserVars.SuppressShellWarning"} | Set-AdvancedSetting -Value "1" -Confirm:$false | Out-null

	  # syslog
    Write-Verbose -Message "$(Get-Date -Format G) Configuring syslog to send to $vCenterServer"
    try {
      Set-VMHostSysLogServer -vmhost $vmhost -SysLogServer "udp://$($vCenterServer):514"
    }
    catch {
      Write-Error -Category ResourceUnavailable -Message "Failed to set syslog server, see /var/log/.vmsyslogd.err on host"
    }
    Get-VMHostFireWallException -vmhost $vmhost -Name Syslog | Set-VMHostFirewallException -Enabled:$True
    $esxcli.network.firewall.refresh.Invoke()
    $esxcli.system.syslog.reload.invoke()

	  # set network dump dest to vCenter IP
    Write-Verbose -Message "$(Get-Date -Format G) Configuring coredump network to send to $vCenterServer IP $vCenterServerIP"
    $esxcliArgs = $esxcli.system.coredump.network.set.CreateArgs()
    $esxcliArgs.interfacename = "vmk0"
    $esxcliArgs.serverip = "$vCenterServerIP"
    $esxcliArgs.serverport = "6500"
    $esxcli.system.coredump.network.set.Invoke($esxcliArgs)
    
    $esxcliArgs = $esxcli.system.coredump.network.set.CreateArgs()
    $esxcliArgs.enable = "true"
    $esxcli.system.coredump.network.set.Invoke($esxcliArgs)

    $esxcli.system.coredump.network.get.Invoke()
    $esxcli.system.coredump.network.check.Invoke()
    
	  # set NTP
    Write-Verbose -Message "$(Get-Date -Format G) Configuring NTP"
    $NTPservers.Split(",") | ForEach-Object { 
        write-host "adding ntpserver $_"
        try {
            Add-VmHostNtpServer -vmhost $vmhost -NtpServer $_ 
            }
        catch {
            Write-Warning -Message "$_"
        }
    }
    $vmhost | Get-VMHostFirewallException | Where-Object {$_.Name -eq "NTP client"} | Set-VMHostFirewallException -Enabled:$true
    $vmhost | Get-VmHostService | Where-Object {$_.key -eq "ntpd"} | Start-VMHostService
    $vmhost | Get-VmHostService | Where-Object {$_.key -eq "ntpd"} | Set-VMHostService -policy "automatic"

	  # add local esxi read-only user for monitoring
    Write-Verbose -Message "$(Get-Date -Format G) Adding local user for monitoring: $monitoringUser"
    $esxhostserver = connect-viserver -server $vmhost -user root -password $rootPassword
    $rootFolder = Get-Folder -Name "root" -server $esxhostserver
    try {   
        $opsAccount = new-vmhostaccount -id $monitoringUser -password $monitoringPassword -useraccount -server $esxhostserver
        New-VIPermission -Entity $rootFolder -Principal $opsAccount -Role ReadOnly -server $esxhostserver
    }
    catch { Write-Warning -Message "$_" }

    try {
        Disconnect-VIServer -Server $esxhostserver -force -Confirm:$false
    }
    catch { Write-Warning -Message "$_" }

	  # configure networking
    Write-Verbose -Message "$(Get-Date -Format G) Configuring host networking"
    
    $vSwitch = Get-VirtualSwitch -vmhost $vmhost -name vSwitch0
    $vSwitch | Set-VirtualSwitch -Mtu 9000 -confirm:$false

    try {
      $vmhostAdapter = $vswitch | Get-VMHostNetworkAdapter -name vmnic1 -ErrorAction stop
    }
    catch {
      Write-Verbose -Message "$(Get-Date -Format G) Adding vmnic1 to vSwitch0 as it was not found"
      
      $vmhostAdapter = $vmhost | Get-VMHostNetworkAdapter -physical -name vmnic1
      $vswitch | Add-VirtualSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $vmhostAdapter -confirm:$false
    }

    Write-Verbose -Message "$(Get-Date -Format G) Setting vmk0/Management Network as MTU 9000"
    $vmhostMgmtAdapter = Get-VMHostNetworkAdapter -vmhost $vmhost -VirtualSwitch $vswitch -PortGroup "Management Network"
    try {
      $vmhostMgmtAdapter | set-VMHostNetworkAdapter -Mtu 9000 -ErrorAction stop
    }
    catch {
      Write-Warning -Message "$_"
    }

    ## remove default portgroup
    Write-Verbose -Message "$(Get-Date -Format G) Removing default 'VM Network' portgroup if it exists"
    try {
        Get-virtualportgroup -vmhost $vmhost -name "VM Network" | remove-virtualportgroup -confirm:$false
    }
    catch { Write-Warning -Message "$_" }
    
    Write-Verbose -Message "$(Get-Date -Format G) Configuring $vmhost vMotion IP $vMotionIP on $vMotionVLAN"

    try {
        $vMotionPG = New-VirtualPortGroup -Name "vMotion" -VirtualSwitch $vSwitch -VLanId $vMotionVLAN -Confirm:$false    
        $esxcli.network.ip.netstack.add.invoke(@{netstack = "vmotion"})
    }
    catch { Write-Warning -Message "$_" }

    $esxcliArgs = $esxcli.network.ip.interface.add.CreateArgs()
    $esxcliArgs.mtu = 9000
    $esxcliArgs.portgroupname = "vMotion"
    $esxcliArgs.netstack = "vmotion"
    $esxcliArgs.interfacename = "vmk1"
    try {
        $esxcli.network.ip.interface.add.Invoke($esxcliArgs)
    }
    catch {
        Write-Warning -Message "$_"
    }

    $esxcliArgs = $esxcli.network.ip.interface.ipv4.set.CreateArgs()
    $esxcliArgs.netmask = "255.255.255.0"
    $esxcliArgs.ipv4 = "$vMotionIP"
    $esxcliArgs.type = "static"
    $esxcliArgs.interfacename = "vmk1"
    try {
        $esxcli.network.ip.interface.ipv4.set.Invoke($esxcliArgs) 
    }
    catch {
        Write-Warning -Message "$_"
    }

	  # configure storage
    Write-Verbose -Message "$(Get-Date -Format G) Configuring storage"

    # Pure best practices
    $vmhost | Get-AdvancedSetting -name Disk.DiskMaxIOSize | Set-AdvancedSetting -Value "4096" -Confirm:$false
    
    # Claim rule for Pure already included in 6.7 by default
    #Write-Verbose -Message "$(Get-Date -Format G) Adding claim rule for Pure"
    #$esxcliArgs = $esxcli.storage.nmp.satp.rule.add.CreateArgs()
    #$esxcliArgs.description = "PURE FlashArray IO Operation Limit Rule"
    #$esxcliArgs.model = "FlashArray"
    #$esxcliArgs.vendor = "PURE"
    #$esxcliArgs.satp = "VMW_SATP_ALUA"
    #$esxcliArgs.psp = "VMW_PSP_RR"
    #$esxcliArgs.option = "iops=1"
    #try {
    #    $esxcli.storage.nmp.satp.rule.add.Invoke($esxcliArgs)
    #    }
    #catch {
    #    Write-Warning -Message "$_"
    #}

    Write-Verbose -Message "$(Get-Date -Format G) Configuring iSCSI"

    $iSCSIPGA_Name = "iSCSI_A"
    $iSCSIPGB_Name = "iSCSI_B"
   
    try { 
      $iSCSIPGA = New-VirtualPortGroup -Name "$iSCSIPGA_Name" -VirtualSwitch $vSwitch -VLanId $iSCSIVLAN -Confirm:$false
    }
    catch {
      $iSCSIPGA = Get-VirtualPortGroup -Name "$iSCSIPGA_Name" -VirtualSwitch $vSwitch
    }
    try {
      $iSCSIPGB = New-VirtualPortGroup -Name "$iSCSIPGB_Name" -VirtualSwitch $vSwitch -VLanId $iSCSIVLAN -Confirm:$false
    }
    catch {
      $iSCSIPGB = Get-VirtualPortGroup -Name "$iSCSIPGB_Name" -VirtualSwitch $vSwitch
    }

    Get-VirtualPortGroup -Name $iSCSIPGA -vmhost $vmhost | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive vmnic0 -MakeNicUnused vmnic1
    Get-VirtualPortGroup -Name $iSCSIPGB -vmhost $vmhost | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive vmnic1 -MakeNicUnused vmnic0
    
    try { 
      $iSCSIvmkA = New-VMHostNetworkAdapter -vmhost $vmhost -VirtualSwitch $vSwitch -PortGroup $iSCSIPGA -IP $iSCSIIPA -SubnetMask 255.255.255.0 -mtu 9000
    }
    catch {
      $iSCSIvmkA = Get-VMHostNetworkAdapter -vmhost $vmhost -VirtualSwitch $vswitch -PortGroup $iSCSIPGA
    }
    try {
      $iSCSIvmkB = New-VMHostNetworkAdapter -vmhost $vmhost -VirtualSwitch $vSwitch -PortGroup $iSCSIPGB -IP $iSCSIIPB -SubnetMask 255.255.255.0 -mtu 9000
    }
    catch {
      $iSCSIvmkB = Get-VMHostNetworkAdapter -vmhost $vmhost -VirtualSwitch $vswitch -PortGroup $iSCSIPGB
    }

    $iSCSIvmkA_name = $iSCSIvmkA.Name
	  $iSCSIvmkB_name = $iSCSIvmkB.Name
    
    get-vmhoststorage -vmhost $vmhost | set-vmhoststorage -softwareiscsienabled $true
    $swhba = Get-VMHostHba -vmhost $vmhost -Type iScsi
    $swhba_iqn = $swhba.IScsiName
    $swhba_name = $swhba.Device
	
    $esxcliArgs = $esxcli.iscsi.networkportal.add.CreateArgs()
    $esxcliArgs.adapter = "$swhba_name"
    $esxcliArgs.nic = "$iSCSIvmkA_name"
    $esxcliArgs
    try {
      $esxcli.iscsi.networkportal.add.Invoke($esxcliArgs)
    }
    catch {
        Write-Warning -Message "$_"
    }
    $esxcliArgs = $esxcli.iscsi.networkportal.add.CreateArgs()
    $esxcliArgs.adapter = "$swhba_name"
    $esxcliArgs.nic = "$iSCSIvmkB_name"
    $esxcliArgs
    try {
      $esxcli.iscsi.networkportal.add.Invoke($esxcliArgs)
    }
    catch {
        Write-Warning -Message "$_"
    }

    # Pure best practices
    $esxcliArgs = $esxcli.iscsi.adapter.param.set.CreateArgs()
    $esxcliArgs.adapter="vmhba64"
    $esxcliArgs.key="DelayedAck"
    $esxcliArgs.value="false"
    $esxcli.iscsi.adapter.param.set.Invoke($esxcliArgs)

    $esxcliArgs = $esxcli.iscsi.adapter.param.set.CreateArgs()
    $esxcliArgs.adapter="vmhba64"
    $esxcliArgs.key="LoginTimeout"
    $esxcliArgs.value="30"
    $esxcli.iscsi.adapter.param.set.Invoke($esxcliArgs)

	  # pure steps
    Write-Verbose -Message "$(Get-Date -Format G) Adding host to Pure array"
    
    try {
      New-PfaHost -Array $PureArray -Name $vmhost.NetworkInfo.HostName -IqnList $swhba_iqn
    }
    catch {
        Write-Warning -Message "$_"
    }
    Set-PfaPersonality -Array $PureArray -Name $vmhost.NetworkInfo.HostName -Personality esxi
    try {
      Add-PfaHosts -Array $PureArray -Name $PureHostGroup -hoststoadd $vmhost.NetworkInfo.HostName
    }
    catch {
        Write-Warning -Message "$_"
    }

    Write-Verbose -Message "$(Get-Date -Format G) Adding Pure targets to host"
    $pureConfig | ForEach-Object { 
      try {
        $swhba | new-iscsihbatarget -address $_.targetIP 
      }
      catch {
        Write-Warning -Message "$_"
      }
    }
  }

  try { $PureArray | Disconnect-PfaArray } catch { Write-Warning -Message "$_" }
  $vCenterSession | disconnect-viserver -confirm:$false 

}

# Clear any lingering vcenter connections
try {
  Disconnect-VIServer * -force -confirm:$false -ErrorAction Continue
}
catch {
  
}

Write-Host "$(Get-Date -Format G) Started" 

Main

Write-Host "$(Get-Date -Format G) Done"
