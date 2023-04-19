<#
  .SYNOPSIS
  Process desired DR state or cycle DR VMs
  .DESCRIPTION
  Process desired DR state or cycle DR VMs
  .PARAMETER Action
  Script mode: ScaleUp | ScaleDown | CycleVMs
  .PARAMETER AvailabilitySet
  Optional: Availablity set. If not specified, Action will affect all availablity sets found by function getAzAvailSets where dr-state is set to a specific value.
  .PARAMETER DryRun
  Optional: DryRun/do not perform any actions - defaults to TRUE, must use -DryRun $false to have the script perform any actions.
  .PARAMETER SendEmailTo
  Optional: Always send email log to this email address using SendGrid credentials from Azure Automation stored credentials.
  .PARAMETER SendWarningEmailTo
  Optional: Send email log to this email address using SendGrid credentials from Azure Automation stored credentials when Warn log entries are present.
  
  .EXAMPLE
  .\run_dr.ps1 -Action <ScaleUp|ScaleDown|CycleVMs> -AvailabilitySet <optional: Availability set name> -DryRun (optional, defaults to true. Use -DryRun $false to perform any changes)
  .NOTES
  An automation account should be created in each subscription to run this script and affect availability sets in that subscription.
    - Supports using a RunAs account (default, deprecated) or ManagedIdentity. Will try RunAs first, unless $UseAzureAutomationRunAs = $false.

  The following Modules need to be imported in to the Azure Automation account: 
    - Az.Accounts
    - Az.Compute
    - Az.Resources

  The following Credentials must be configured in the Automation Account:
  - SMTP (username & password)

  The following Variables must be configured in the Automation Account:
  - SMTPServer: smtp.sendgrid.net for example. Must support SSL and TCP/587.
  - SMTPFrom: email address to send emails from. Must be registered sender with SendGrid.
  
  The following tags are required to be configured on various resources and will be set by the script if not present. Defaults are set in $DefaultTagValues. Some tags are used to record states and do not need to be manually set.
    - Subscriptions
      ○ dr-runstate (records state, do not set manually)
        § ready - script is not running
        § running - script is running, do not run another instance of script
    - Availability sets
      ○ dr-min_running - minimum number of VMs in the set to keep running when in standby mode (not DR)
      ○ dr-cycle_hrs - number of hours a VM in standby mode should run before shutting down and starting another.
      ○ dr-state (not automatically set by script if does not exist. Manually set this tag to 'standby' on availability sets that should be cycled.)
        § standby - set is in standby mode where dr-min_running VMs are running, ready for ScaleUp
        § dr - set is in dr mode where all VMs are running, ready for ScaleDown
      ○ dr-last_cycle (records state, do not set manually: timestamp of last ScaleUp/ScaleDown event)
      ○ dr-notify_hrs - notify via email alert every X hours that the availability set is in DR mode
      ○ dr-notify_timestamp (records state, do not set manually: timestamp of last alert email)
    - Virtual machines
      ○ dr-last_cycle (records state, do not set manually: timestamp of last Start/Stop event performed by the script)
      ○ dr-vmstate (records state, do not set manually: state of VM as managed by the script)
        § standby - VM is running in standby mode, will remain on during ScaleUp and changed to 'dr'.
        § dr - VM is running in dr mode because ScaleUp was performed on the availability set
        § ready - VM is off but ready to start for standby or dr mode.
#>

Param ( $Action, $AvailabilitySet, $DryRun = $true, $SendEmailTo, $SendWarningEmailTo )

[OutputType([string])]
$ErrorActionPreference = "Continue"
$VerbosePreference = "Continue"

# Set preferences
$UseAzureAutomationRunAs = $true # Change this to $false if using a ManagedIdentity
$LogonAttempts = 10
$VMStopWaitSecs = 120 # seconds to wait before querying a newly-stopped VM for its status
$EmailDebugLogs = $false
$TZConvertTo = "Pacific Standard Time"

# Accept $DryRun 'True' or 'False' or $true or $false, use 'false' with Azure Automation parameter form, not $false
$DryRun = [System.Convert]::ToBoolean($DryRun)

$ScriptVersion = "1.0"

# Default values to use if tag is not present on resource when trying to retrieve it. Will be set on resource if $DryRun = $false
$DefaultTagValues = @{}
$DefaultTagValues.Add('dr-min_running',1) # Availability set
$DefaultTagValues.Add('dr-state',"standby") # Availability set - not set by script on any availability set. Must be manually set by administrator or terraform to enable this script to operate on it.
$DefaultTagValues.Add('dr-cycle_hrs',"24") # Availability set
$DefaultTagValues.Add('dr-notify_hrs',"24") # Availability set - repeat email alert every 24 hours about being in DR
$DefaultTagValues.Add('dr-notify_timestamp',"1970-01-01T00:00:00") # Availability set - timestamp of last email alert sent about being in DR
$DefaultTagValues.Add('dr-runstate',"ready") # Subscription
$DefaultTagValues.Add('dr-vmstate',"ready") # VM
$DefaultTagValues.Add('dr-last_cycle',"1970-01-01T00:00:00") # VM or Availability set

# Set flag indicating Warn log entries are present
$global:LogWarnEntriesPresent = $false

function LogOutput {
  <#
    .SYNOPSIS
    Record a log entry
    .DESCRIPTION
    Record a log entry with timestamp and certain formatting for script output and email output
    .PARAMETER LogMessage
    String of message to log
    .PARAMETER LogType
    Type of log:
     INFO: Uses Write-Output
     WARN: Uses Write-Warning and email will have entry formatted red/bold
     DEBUG: Uses Write-Verbose and email will have entry formatted in italics
     EM: Uses Write-Output and email will ahve entry formatted bold
    .EXAMPLE
    LogOutput -LogType "INFO" -LogMessage "test log message"
  #>
  param (
    [parameter(Mandatory = $true)][string]$LogMessage,
    [parameter(Mandatory = $false)][ValidateSet('INFO','WARN','DEBUG','EM')][string]$LogType = "INFO"
  )

  $LogTimestamp = Get-Date $([System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($(Get-Date),[System.TimeZoneInfo]::Local.Id,$TZConvertTo)) -Format G

  switch ($LogType) {
    "INFO" {
      Write-Output "$LogTimestamp $LogMessage"
      $global:EmailLog += "$LogTimestamp INFO $LogMessage`n"
    }
    "WARN" {
      Write-Warning "$LogTimestamp $LogMessage"
      $LogEntry = "<font color='red'><b>$LogTimestamp WARN $LogMessage</b></font>`n"
      $global:EmailLog += $LogEntry
      $global:LogWarnEntriesPresent = $true
    }
    "DEBUG" {
      Write-Verbose "$LogTimestamp $LogMessage"
      if ( $EmailDebugLogs ) { $global:EmailLog += "<i>$LogTimestamp DEBUG $LogMessage</i>`n" }
    }
    "EM" {
      Write-Output "$LogTimestamp $LogMessage"
      $global:EmailLog += "<b>$LogTimestamp INFO $LogMessage</b>`n"
    }
  }
}

function ScaleUp {
  <#
    .SYNOPSIS
    ScaleUp a specific availability set.
    .DESCRIPTION
    ScaleUp a specific availability set by powering on all VMs.
    .PARAMETER AvailabilitySet
    Availability set name
    .EXAMPLE
    ScaleUp -AvailabilitySet <name>
  #>
  param (
    [parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set object")][Microsoft.Azure.Commands.Compute.Models.PSAvailabilitySet]$AvailabilitySet
  )

  LogOutput -LogType "EM" -LogMessage "ScaleUp availability set: $($AvailabilitySet.Name)"

  # Record the date, use the same timestamp for the last_cycle on the availability set and VMs within.
  $DateCycled = Get-Date -Format o

  # Get all VMs in the availability set and start them, regardless if they are running or not.
  $AvailabilitySet.VirtualMachinesReferences | Get-AzResource | Get-AzVM | ForEach-Object {
    LogOutput -LogType "EM" -LogMessage "Starting VM $($_.Name)"
    if (! $DryRun) { 
      try { 
        $vmResult = $_ | Start-AzVM -NoWait
      } catch { LogOutput -LogType "WARN" -LogMessage "VM $($_.Name) was not able to start! $($_.Exception.Message)" }
    
      # Update the dr tags for the VM
      $updateTagResult = Update-AzTag -ResourceId $_.Id -tag @{"dr-last_cycle"="$DateCycled";"dr-vmstate"="dr";} -Operation Merge
    }
  }

  # Update the dr tags for the availability set
  if (! $DryRun) { $updateTagResult = Update-AzTag -ResourceId $AvailabilitySet.Id -tag @{"dr-last_cycle"="$DateCycled"; "dr-notify_timestamp"="$DateCycled"; "dr-state"="dr";} -Operation Merge }
}

function ScaleDown {
  <#
    .SYNOPSIS
    ScaleDown an individual availability set.
    .DESCRIPTION
    ScaleDown an individual availability set by stopping all VMs except for quantity specified by availability set tag dr-min_running
    .PARAMETER AvailabilitySet
    Availability set name
    .EXAMPLE
    ScaleDown -AvailabilitySet <name>
  #>
  param (
    [parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set object")][Microsoft.Azure.Commands.Compute.Models.PSAvailabilitySet]$AvailabilitySet
  )

  LogOutput -LogType "EM" -LogMessage "ScaleDown availability set: $($AvailabilitySet.Name)"

  $VMCount = $AvailabilitySet.VirtualMachinesReferences.Count
  $minRunning = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-min_running"

  LogOutput -LogType "DEBUG" -LogMessage "Availability set contains $VMCount VMs. $minRunning are required to remain running. Will shut down $($VMCount - $minRunning) VM(s)."

  # Get all VMs in the availability set, randomize them, and shut them down except for quantity specified by tag dr-min_running.
  $VMs = $AvailabilitySet.VirtualMachinesReferences | Get-AzResource | Get-AzVM | Sort-Object {Get-Random}
  
  $VMCounter = 1
  $VMCounterMax = ($VMCount - $minRunning)
  if ($VMCounterMax -gt 0) {
    $VMCounter..$VMCounterMax | ForEach-Object {
      $VM = $VMs[$_-1] # Array starts at zero but we start VMCounter at 1, so always subtract one. Handles availability sets with 2 VMs.
      LogOutput -LogType "EM" -LogMessage "Stopping VM $_ $($VM.Name)"
      if (! $DryRun) {
        $vmResult = $VM | Stop-AzVM -NoWait -Force

        # Update the dr tags for the VM - set the last_cycle to when it was shut down and the vmstate to ready indicating it is available for CycleVMs rotations.
        $updateTagResult = Update-AzTag -ResourceId $VM.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)";"dr-vmstate"="ready"} -Operation Merge
      }

      $VMCounter++
    }
  } else {
    LogOutput -LogMessage "Not stopping any VMs to satisfy required $minRunning minimum running VM(s)."
  }

  LogOutput -LogType "DEBUG" -LogMessage "Completed. Sleeping $VMStopWaitSecs secs for VM status to update."
  Start-sleep -Seconds $VMStopWaitSecs

  # Update remaining running VMs with dr-vmstate = standby
  # Rebuild our representation of the VMs with their current running Status
  $VMs = @(getAzVMstates -AvailabilitySet $AvailabilitySet)
  $VMs | Where-Object {$_.Status -eq "PowerState/running"} | ForEach-Object {
    LogOutput -LogType "EM" -LogMessage "VM $($_.Name) will remain running. Setting dr-vmstate = standby"
    if (! $DryRun) { $updateTagResult = Update-AzTag -ResourceId $_.Id -tag @{"dr-vmstate"="standby"} -Operation Merge }
  }

  # Update the dr tags for the availability set
  if (! $DryRun) { $updateTagResult = Update-AzTag -ResourceId $AvailabilitySet.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)"; "dr-state"="standby";} -Operation Merge }
}

function CycleVMs {
  <#
    .SYNOPSIS
    Performs housekeeping for an availability set.
    .DESCRIPTION
    Ensures VMs are in correct state and minimum number are running. Start the oldest ones and shutdown the newest ones.
    .PARAMETER AvailabilitySet
    Optional: Availability set name
    .EXAMPLE
    CycleVMs -AvailabilitySet <name>
  #>
  param (
    [parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set object")][Microsoft.Azure.Commands.Compute.Models.PSAvailabilitySet]$AvailabilitySet
  )

  $skipCheckTooManyRunning = $false

  $drState = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-state"

  LogOutput -LogType "EM" -LogMessage "CycleVMs for availability set: $($AvailabilitySet.Name) with dr-state: $drState"

  $VMs = getAzVMstates -AvailabilitySet $AvailabilitySet

  if ($drState -eq "standby") {
    # If a vm has tag dr-last_cycle value > availablity set tag dr-cycle_hrs [value] hour(s) old, this vm must be cycled. Look for min_running stopped VMs with oldest dr-last_cycle and dr-vmstate=ready and start them. Look for running VMs with dr-vmstate=standby and newest dr-last_cycle and stop them. If VM is running but dr-vmstate=ready, then the VM was user-started and should not be cycled.
    $cycleHoursRequired = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-cycle_hrs"
    $minRunning = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-min_running"

    # Track if our state is stale and needs to be updated (due to cycling VMs)
    $myVMstateStale = $false

    # Get all VMs in the set that are PowerState/running and dr-vmstate = standby. Sort by LastCycle, oldest first. Check their LastCycle timespan from now. Power Off if LastCycle > availability set cycle_hrs.
    $VMs | Where-Object {($_.Status -eq "PowerState/running") -and ($_.DRState -eq "standby")} | Sort-Object -Property "LastCycle" | ForEach-Object {
      
      $VM = Get-AzVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName
      $lastCycled = $_.LastCycle
      
      LogOutput -LogType "DEBUG" -LogMessage "$($VM.Name) running, last cycle timestamp: $lastCycled ($((New-TimeSpan -Start (Get-Date -Date $lastCycled) -End (Get-Date)).TotalHours) hours ago). Padding timestamp by an hour ($((Get-Date -Date $lastCycled).AddHours(1))) so VM runs an extra hour before being stopped."

      $cycleTimeSpanHrs = (New-TimeSpan -Start (Get-Date -Date $lastCycled).AddHours(2) -End (Get-Date)).TotalHours # Add time to the last cycle timestamp so the VM ends up running an additional hour before being stopped.
      if ($cycleTimeSpanHrs -gt $cycleHoursRequired) { 
        LogOutput -LogType "EM" -LogMessage "$($VM.Name) running, last cycle $cycleTimeSpanHrs hours ago is > $cycleHoursRequired hr(s) required by availability set tag dr-cycle_hrs. Stopping VM."

        if (! $DryRun) {
          $vmResult = $VM | Stop-AzVM -NoWait -Force
          $myVMstateStale = $true
          $updateTagResult = Update-AzTag -ResourceId $VM.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)";"dr-vmstate"="ready"} -Operation Merge
        }
      }
    }

    # Get all VMs in the set that are PowerState/deallocated. Sort by LastCycle, oldest first. Select the minRunning required for the set. Check their LastCycle timespan from now. Power On if > availability set cycle_hrs.
    $VMs | Where-Object {($_.Status -eq "PowerState/deallocated") -and ($_.DRState -eq "ready")} | Sort-Object -Property "LastCycle" | Select-Object -First $minRunning | ForEach-Object {
      
      $VM = Get-AzVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName
      $lastCycled = $_.LastCycle
      $cycleTimeSpanHrs = (New-TimeSpan -Start (Get-Date -Date $lastCycled) -End (Get-Date)).TotalHours

      LogOutput -LogType "DEBUG" -LogMessage "$($VM.Name) stopped, last cycle timestamp: $lastCycled ($cycleTimeSpanHrs hours ago)"
      
      if ($cycleTimeSpanHrs -gt $cycleHoursRequired) { 
        LogOutput -LogType "EM" -LogMessage "$($VM.Name) stopped, last cycle $cycleTimeSpanHrs hours ago is > $cycleHoursRequired hr(s) required by availability set tag dr-cycle_hrs. Starting VM."

        if (! $DryRun) {
          try {
            $vmResult = $VM | Start-AzVM -NoWait
            $myVMstateStale = $true
            $skipCheckTooManyRunning = $true # When a VM is started by standby cycle, do not check if too many are running, prefer to have multiple VMs running in the set until the next cycle.
            $updateTagResult = Update-AzTag -ResourceId $VM.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)";"dr-vmstate"="standby"} -Operation Merge
          } catch { LogOutput -LogType "WARN" -LogMessage "VM $($VM.Name) was not able to start or tag could not be updated! $($_.Exception.Message)" }
        }
      }
    }

    # If our VM state is stale due to standby cycling, sleep so Azure RM API can update and then get updated state view
    if ($myVMstateStale) {
      LogOutput -LogType "DEBUG" -LogMessage "VM cycling completed. Sleeping $VMStopWaitSecs secs for VM status to update before updating VM state to check min/max running counts."
      Start-sleep -Seconds $VMStopWaitSecs

      # Update our VM state array after changes from standby cycle
      $VMs = getAzVMstates -AvailabilitySet $AvailabilitySet
    }

    # Check if dr-min_running are running and no more/less, otherwise fix. 
    # Be sure to not stop any where dr-vmstate=ready because the VM was user-started and should not be stopped. If VM is running and has vmstate of 'standby', that is correct.
    
    LogOutput -LogType "DEBUG" -LogMessage "Availability set $($AvailabilitySet.Name) tag dr-state is standby, checking that running VM count matches required dr-min_running."

    $VMCounterRunning = @($VMs | Where-Object {$_.Status -eq "PowerState/running"}).Count

    LogOutput -LogType "DEBUG" -LogMessage "Running VM count: $VMCounterRunning" 

    if ($VMCounterRunning -ne $minRunning) {
      LogOutput -LogMessage "Running VM count: $VMCounterRunning does not equal required minimum running count of $minRunning."

      # Start some stopped ones if not enough
      if ($VMCounterRunning -lt $minRunning) {
        LogOutput -LogType "DEBUG" -LogMessage "Running VM count: $VMCounterRunning is less than the required minimum running VM count of $minRunning."
        $StartVMcount = $minRunning - $VMCounterRunning

        LogOutput -LogMessage "$StartVMcount VM(s) will be started."

        # Start $StartVMcount VMs starting with those that have oldest last cycle time
        $VMs | Where-Object {$_.Status -eq "PowerState/deallocated"} | Sort-Object -Property "LastCycle" | select-object -first $StartVMcount | ForEach-Object {
          LogOutput -LogType "EM" -LogMessage "Starting $($_.Name)"
          $VM = Get-AzVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName
          if (! $DryRun) {
            try {
              $vmResult = $VM | Start-AzVM -NoWait
            } catch { LogOutput -LogType "WARN" -LogMessage "VM $($_.Name) was not able to start! $($_.Exception.Message)" }

            $updateTagResult = Update-AzTag -ResourceId $VM.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)";"dr-vmstate"="standby"} -Operation Merge
          }
        }
      }

      # Stop some running ones if too many, but not ones with dr-vmstate=ready because the VM was user-started and should not be stopped
      if ($VMCounterRunning -gt $minRunning) {
        LogOutput -LogType "DEBUG" -LogMessage "Running VM count $VMCounterRunning is greater than the required minimum running VM count of $minRunning."
        if (! $skipCheckTooManyRunning) {
          $StopVMcount = $VMCounterRunning - $minRunning

          LogOutput -LogMessage "$StopVMcount VM(s) will be stopped."

          # Stop $StopVMCount VMs starting with those that have oldest last cycle time
          $VMs | Where-Object {$_.Status -eq "PowerState/running"} | Sort-Object -Property "LastCycle" | select-object -first $StopVMcount | ForEach-Object {
            $VM = Get-AzVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName

            $drVMstate = getAzTagValue -ResourceId $VM.id -TagName "dr-vmstate"
            
            if ($drVMstate -eq "standby" -or $null -eq $drVMstate) {
              LogOutput -LogType "EM" -LogMessage "Stopping $($_.Name)"
              
              if (! $DryRun) {
                $vmResult = $VM | Stop-AzVM -NoWait -Force

                $updateTagResult = Update-AzTag -ResourceId $VM.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)";"dr-vmstate"="ready"} -Operation Merge
              }
            } else {
              LogOutput -LogType "WARN" -LogMessage "VM $($_.Name) was selected for shutdown but its dr-vmstate is not 'standby'. Skipping."
            }
          }
        } else { LogOutput -LogMessage "Skipped stopping any VMs due to too many running, because standby cycle started a VM. Will resume at next cycle." }

        # Log VMs that are ready but are running (should be stopped)
        $VMs | Where-Object {($_.Status -eq "PowerState/running") -and ($_.DRState -eq "ready")} | ForEach-Object {
          LogOutput -LogType "WARN" -LogMessage "VM $($_.Name) is running but its dr-vmstate is 'ready'. VM should be manually stopped!"
        }
      }
    } else {
      LogOutput -LogMessage "Running VM count $VMCounterRunning matches required minimum running count of $minRunning (tag dr-min_running)."
    }
  }

  # Check if availability set with dr-state:dr has all VMs running
  if ($drState -eq "dr") {
    LogOutput -LogType "DEBUG" -LogMessage "AvailabilitySet: $($AvailabilitySet.Name) dr-state is dr, checking that all VMs in the set are running."

    if (@($VMs | Where-Object {$_.Status -eq "PowerState/running"}).Count -ne $VMs.Count) {
      LogOutput -LogType "WARN" -LogMessage "Not all VMs in the availability set $($AvailabilitySet.Name) are running."

      $VMs | Where-Object {$_.Status -eq "PowerState/deallocated"} | ForEach-Object {
        LogOutput -LogType "EM" -LogMessage "Starting $($_.Name)"
        $VM = Get-AzVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName
        if (! $DryRun) {
          try {
            $vmResult = $VM | Start-AzVM -NoWait
            $updateTagResult = Update-AzTag -ResourceId $VM.Id -tag @{"dr-last_cycle"="$(Get-Date -Format o)";"dr-vmstate"="dr"} -Operation Merge
          } catch { LogOutput -LogType "WARN" -LogMessage "VM $($_.Name) was not able to start or tag could not be updated! $($_.Exception.Message)" }
        }
      }
    } else {
      LogOutput -LogType "INFO" -LogMessage "All VMs in the availability set $($AvailabilitySet.Name) are running."
    }

    # Send an email alert if availability set dr-last_cycle is > dr-notify_hrs hours ago
    $AvailSetLastCycle = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-last_cycle"
    $AvailSetDRnotifyHrs = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-notify_hrs"
    $AvailSetDRalertLastTimestamp = getAzTagValue -ResourceId $($AvailabilitySet.id) -TagName "dr-notify_timestamp"

    $AvailSetCycleTimeSpanHrs = (New-TimeSpan -Start (Get-Date -Date $AvailSetLastCycle) -End (Get-Date)).TotalHours # Hours since DR started
    $AvailSetDRalertTimeSpanHrs = (New-TimeSpan -Start (Get-Date -Date $AvailSetDRalertLastTimestamp) -End (Get-Date)).TotalHours # Hours since last email alert

    $AvailSetDRalertMessage = "Availability set $($AvailabilitySet.Name) is in DR mode and has been for $AvailSetCycleTimeSpanHrs hours since $AvailSetLastCycle."
    if ($AvailSetDRalertTimeSpanHrs -gt $AvailSetDRnotifyHrs) {
      # Last email alert was sent more than dr-notify_hrs hours ago, log a warning to trigger an email to the $SendWarningEmailTo address.
      LogOutput -LogType "WARN" -LogMessage $AvailSetDRalertMessage
      LogOutput -LogType "INFO" -LogMessage "This alert will repeat every $AvailSetDRnotifyHrs hours (availability set tag dr-notify_hrs)."
      if (! $DryRun) { $updateTagResult = Update-AzTag -ResourceId $AvailabilitySet.Id -tag @{"dr-notify_timestamp"="$(Get-Date -Format o)";} -Operation Merge }
    } else {
      LogOutput -LogType "INFO" -LogMessage $AvailSetDRalertMessage
    }
  }
}

function getAzVMstates {
  <#
    .SYNOPSIS
    Get VM states
    .DESCRIPTION
    Get VM states and return object
    .PARAMETER AvailabilitySet
    Availability set object
    .EXAMPLE
    getAzVMstates -AvailabilitySet <object>
  #>
  param (
    [parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set object")][Microsoft.Azure.Commands.Compute.Models.PSAvailabilitySet]$AvailabilitySet
  )

  LogOutput -LogType "DEBUG" -LogMessage "getAzVMstates. AvailabilitySet: $($AvailabilitySet.Name)"

  # Build our own status array of VMs in the availability set
  $VMs = @()
  $AvailabilitySet.VirtualMachinesReferences | Get-AzResource | ForEach-Object {
    $VM = $_ | Get-AzVM -Status

    $VMObject = [PSCustomObject]@{
      "Name" = $VM.Name
      "ID" = $_.Id
      "ResourceGroupName" = $VM.ResourceGroupName
      "Status" = $VM.Statuses[1].Code
      "LastCycle" = getAzTagValue -ResourceID $_.Id -TagName "dr-last_cycle"
      "DRState" = getAzTagValue -ResourceID $_.Id -TagName "dr-vmstate"
    }

    $VMs += $VMObject

    LogOutput -LogType "DEBUG" -LogMessage "getAzVMstates. VM: $($VMObject.Name) $($VMObject.Status) (DRState: $($VMObject.DRState) LastCycle: $($VMObject.LastCycle) ResourceGroupName: $($VMObject.ResourceGroupName) ID: $($VMObject.ID))"
  }

  return $VMs
}

function getAzTagValue {
  <#
    .SYNOPSIS
    Get tag value
    .DESCRIPTION
    Get tag value and use a pre-defined default if no value is present
    .PARAMETER ResourceID
    Resource ID
    .PARAMETER TagName
    Tag name to retrieve
    .EXAMPLE
    getAzTagValue -ResourceId <resource ID> -TagName <tagName>
  #>
  param (
    [parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Resource ID")][string]$ResourceID,
    [parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Tag name")][string]$TagName
  )

  #LogOutput -LogType "DEBUG" -LogMessage "getAzTagValue: TagName: $TagName ResourceId: $ResourceID"
  
  try { $tagValue = (Get-AzTag -ResourceId $ResourceId).properties.TagsProperty[$TagName] }
  catch { $tagValue = $null }

  if ($null -eq $tagValue) {
    $tagValueDefault = $DefaultTagValues[$TagName]
    LogOutput -LogType "DEBUG" -LogMessage "Resource $ResourceID does not have value for tag $TagName. Assuming default tag value of '$tagValueDefault'."
    $tagValue = $tagValueDefault
    if (! $DryRun) { 
      LogOutput -LogType "DEBUG" -LogMessage "Setting $TagName = '$tagValueDefault' on $ResourceID"
      $updateTagResult = Update-AzTag -ResourceId $ResourceID -tag @{"$TagName"="$tagValueDefault"} -Operation Merge 
    }
  }

  return $tagValue
}

function getAzAvailSets {
  <#
    .SYNOPSIS
    Get Availability Sets with a specific tag/value
    .DESCRIPTION
    Get Availability Sets with a specific tag/value
    .PARAMETER AvailabilitySet
    Optional availability set name
    .PARAMETER TagName
    Tag name to check for a given TagValue
    .PARAMETER TagValue
    Value to check for a given TagName
    .EXAMPLE
    getAzAvailSets -AvailabilitySet <optional: name> -TagName <tagName> -TagValue <tagValue>
  #>
  param (
    [parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set name")][string]$AvailabilitySet,
    [parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set tag name")][string]$TagName,
    [parameter(Mandatory = $true, Position = 2, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Availability set tag value")][string]$TagValue
  )

  LogOutput -LogType "DEBUG" -LogMessage "getAzAvailSets. AvailabilitySet: $AvailabilitySet TagName: $TagName TagValue: $TagValue"

  if ($AvailabilitySet) {
    # availability set was specified, query for an existing Availability Set with the correct tag/value
    LogOutput -LogType "DEBUG" -LogMessage "getAzAvailSets. Availability set specified, retrieving details."
    $asList = Get-AzResource -ResourceType Microsoft.Compute/availabilitySets -TagName $TagName -TagValue $TagValue -Name $AvailabilitySet | Get-AzAvailabilitySet
    
    # Exit with an error if the given availability set cannot be found
    if ($null -eq $asList) {
      throw "$(Get-Date -Format G) getAzAvailSets. Availability set $AvailabilitySet with TagName '$TagName' and TagValue '$TagValue' not found!"
      exit 1
    }
  } else {
    # availability set was not specified, query for existing Availability Sets with the correct tag/value
    LogOutput -LogType "DEBUG" -LogMessage "getAzAvailSets. No availability set specified, retrieving all where $TagName = $TagValue."
    $asList = Get-AzResource -ResourceType Microsoft.Compute/availabilitySets -TagName $TagName -TagValue $TagValue | Get-AzAvailabilitySet
  }

  return $asList
}

# Main engine start

# Confirm connection to Azure
$useAzureAutomation = $true

# Try using a RunAs account first
if ($UseAzureAutomationRunAs) {
  try { 
    Write-Verbose "$(Get-Date -Format G) Connecting to Azure using RunAs account ..." 
    $connection = Get-AutomationConnection -Name AzureRunAsConnection -ErrorAction Stop
      
    } catch { 
      Write-Verbose "$(Get-Date -Format G) Could not load Get-AutomationConnection, RunAs account may not be available: $($_.Exception.Message)" 
      $UseAzureAutomationRunAs = $false
  }

  if ($UseAzureAutomationRunAs) {
    $TenantID = $connection.TenantID
    $ApplicationId = $connection.ApplicationId
    $CertificateThumbprint = $connection.CertificateThumbprint

    Write-Verbose "$(Get-Date -Format G) Get-AutomationConnection returned TenantID $TenantID ApplicationId $ApplicationID CertificateThumbprint $CertificateThumbprint" 

    $logonAttempt = 0
    while(!($connectionResult) -and ($logonAttempt -le $LogonAttempts)) {
      $LogonAttempt++
      try {
        Write-Verbose "$(Get-Date -Format G) Connecting to Azure TenantID $TenantID as RunAs ServicePrincipal ApplicationId $ApplicationID with CertificateThumbprint $CertificateThumbprint, attempt $logonAttempt"
        $connectionResult = Connect-AzAccount -ServicePrincipal -Tenant $TenantID -ApplicationId $ApplicationID -CertificateThumbprint $CertificateThumbprint -ErrorAction Stop
        Write-Verbose "$(Get-Date -Format G) Connected to Azure on attempt $logonAttempt"
      } catch {
        Write-Warning "$(Get-Date -Format G) Unable to connect to Azure, attempt $logonAttempt, sleeping 30 secs: $($_.Exception.Message)"
        Start-Sleep -Seconds 30
      }
    }
  }
}

if (! $UseAzureAutomationRunAs) {
  Write-Verbose "$(Get-Date -Format G) Connecting to Azure using ManagedIdentity ..."

  $logonAttempt = 0
  while(!($connectionResult) -and ($logonAttempt -le $LogonAttempts)) {
    $LogonAttempt++
    try {
      
      $connectionResult = Connect-AzAccount -Identity -ErrorAction Stop
      Write-Verbose "$(Get-Date -Format G) Connected to Azure on attempt $logonAttempt"
      $useAzureAutomation = $true
    } catch {
      Write-Warning "$(Get-Date -Format G) Unable to connect to Azure, attempt $logonAttempt, sleeping 30 secs: $($_.Exception.Message)"
      Start-Sleep -Seconds 30
      $useAzureAutomation = $false
    }
  }
}


if ($useAzureAutomation) {
  # Retrieve Automation assets from Azure Automation.
  try {
    Write-Verbose "$(Get-Date -Format G) Retrieving Automation assets"

    $SMTPServer = Get-AutomationVariable -Name 'SMTPServer'
    $SMTPFrom = Get-AutomationVariable -Name 'SMTPFrom'
    $SMTPCredential = Get-AutomationPSCredential -Name 'SMTP'
    $SMTPUsername = $SMTPCredential.UserName
    $SMTPPassword = $SMTPCredential.GetNetworkCredential().Password
  } catch { Write-Warning "$(Get-Date -Format G) Could not retrieve Automation assets. Email alerting will not be available: $($_.Exception.Message)" }
}

try { $SubscriptionID = (Get-AzContext).Subscription.Id } catch {
  throw "$(Get-Date -Format G) Could not determine Azure context, is there an authenticated connection to Azure? $($_.Exception.Message)"
}

if (! $SubscriptionID) { throw "$(Get-Date -Format G) Could not determine Subscription ID, is there an authenticated connection to Azure?" }

$SubscriptionName = (Get-AzContext).Subscription.Name

$emailHeader = "<html><body><h2>Azure DR: <i>$($SubscriptionName)</i>: $Action</h2><hr><i>Timestamps converted to $TZConvertTo<br><pre>"

$global:EmailLog = $emailHeader

LogOutput -LogType "INFO" -LogMessage "Starting, script version $ScriptVersion. Action: $Action AvailabilitySet: $AvailabilitySet DryRun: $DryRun"

if ($DryRun) { LogOutput -LogType "EM" -LogMessage "DryRun enabled, no actions will be performed." }

$runState = getAzTagValue -ResourceId "/subscriptions/$SubscriptionID" -TagName "dr-runstate"
LogOutput -LogType "DEBUG" -LogMessage "Current run state from subscription $($SubscriptionName) $($SubscriptionID): $runState"

# Check/Set dr-runstate on Subscription to act as a lock while the script is running. Do not proceed if tag is not 'ready'. If a ScaleUp action is requested, it will fail if script is already performing a CycleVMs cycle and must be retried when the CycleVMs cycle is complete.
if (! $DryRun) { 
  if ($runState = "ready") {
    LogOutput -LogType "DEBUG" -LogMessage "Updating subscription tag dr-runstate=running"
    $updateTagResult = Update-AzTag -ResourceId "/subscriptions/$SubscriptionID" -tag @{"dr-runstate"="running $(Get-Date -Format o)"} -Operation Merge 
  } else {
    throw "$(Get-Date -Format G) Script may already be running! Subscription $($SubscriptionName) $($SubscriptionID) tag dr-runstate is not 'ready'"
  }
}

# Perform the action based on the command line Action arg
if ($Action) {
  switch ($Action) {
    "ScaleUp" { getAzAvailSets -AvailabilitySet $AvailabilitySet -TagName "dr-state" -TagValue "standby" | ForEach-Object { ScaleUp -AvailabilitySet $_ } }
    "ScaleDown" { getAzAvailSets -AvailabilitySet $AvailabilitySet -TagName "dr-state" -TagValue "dr" | ForEach-Object { ScaleDown -AvailabilitySet $_ } }
    "CycleVMs" { 
      if ($AvailabilitySet) { 
        Get-AzResource -ResourceType Microsoft.Compute/availabilitySets -Name $AvailabilitySet | Get-AzAvailabilitySet | CycleVMs
      }
      else {
        # Check/cycle sets that are standby
        getAzAvailSets -TagName "dr-state" -TagValue "standby" | ForEach-Object { CycleVMs -AvailabilitySet $_ } 

        # Check sets that are dr
        getAzAvailSets -TagName "dr-state" -TagValue "dr" | ForEach-Object { CycleVMs -AvailabilitySet $_ } 
      }
    }
  }
}

# Update dr-runstate on Subscription to free the lock for future runs of the script.
if (! $DryRun) { 
    LogOutput -LogType "DEBUG" -LogMessage "Updating subscription tag dr-runstate=ready"
    $updateTagResult = Update-AzTag -ResourceId "/subscriptions/$((get-azcontext).Subscription.Id)" -tag @{"dr-runstate"="ready"} -Operation Merge 
}

LogOutput -LogMessage "Finished"

$emailFooter = "</pre></body></html>"

$global:EmailLog += $emailFooter

if ($SendEmailTo -and $SMTPServer -and $SMTPUsername -and $SMTPPassword) { 
  Write-Verbose "Sending email log to $SendEmailTo using server $SMTPServer username $SMTPUsername from $SMTPFrom"
  Send-MailMessage -SmtpServer $SMTPServer -UseSsl -Port 587 -Credential $(New-Object System.Management.Automation.PSCredential $SMTPUsername, $(ConvertTo-SecureString $SMTPPassword -AsPlainText -Force)) -From $SMTPFrom -To $SendEmailTo -Subject "Azure DR: $($SubscriptionName): $Action" -Body $global:EmailLog -BodyAsHtml 
}

if ($SendWarningEmailTo -and $global:LogWarnEntriesPresent -and $SMTPServer -and $SMTPUsername -and $SMTPPassword) { 
  Write-Verbose "Sending warning email log to $SendWarningEmailTo using server $SMTPServer username $SMTPUsername from $SMTPFrom"
  Send-MailMessage -SmtpServer $SMTPServer -UseSsl -Port 587 -Credential $(New-Object System.Management.Automation.PSCredential $SMTPUsername, $(ConvertTo-SecureString $SMTPPassword -AsPlainText -Force)) -From $SMTPFrom -To $SendWarningEmailTo -Subject "Warnings: Azure DR: $($SubscriptionName): $Action" -Body $global:EmailLog -BodyAsHtml 
}
