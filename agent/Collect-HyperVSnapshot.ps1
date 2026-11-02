#Requires -Version 5.1
#Requires -Modules Hyper-V
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# CIM class/property names are independent of the Windows display language.
# This counter includes both the root partition and guest workloads.
$cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_HvStats_HyperVHypervisorLogicalProcessor -Filter "Name='_Total'"
if ($null -eq $cpu -or $null -eq $cpu.PercentTotalRunTime) {
    throw 'Hyper-V logical processor counters are unavailable.'
}
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$system = Get-CimInstance -ClassName Win32_ComputerSystem
$totalMemory = [long]$os.TotalVisibleMemorySize * 1KB
$freeMemory = [long]$os.FreePhysicalMemory * 1KB

$vms = @(Get-VM | ForEach-Object {
    $vm = $_
    $running = $vm.State.ToString() -eq 'Running'
    $assigned = [long]$vm.MemoryAssigned
    # A running guest without memory telemetry reports zero demand. Keep it
    # unknown instead of claiming zero usage or substituting assigned memory.
    $demand = $null
    if ($running -and $vm.MemoryDemand -gt 0) { $demand = [long]$vm.MemoryDemand }
    if ($assigned -eq 0 -and -not $running) { $demand = [long]0 }
    [ordered]@{
        id = $vm.Id.ToString()
        name = $vm.Name
        state = $vm.State.ToString()
        cpuUsagePercent = $(if ($running) { [double]$vm.CPUUsage } else { 0.0 })
        processorCount = [int]$vm.ProcessorCount
        memoryAssignedBytes = $assigned
        memoryDemandBytes = $demand
        memoryStartupBytes = [long]$vm.MemoryStartup
        memoryMinimumBytes = [long]$vm.MemoryMinimum
        memoryMaximumBytes = [long]$vm.MemoryMaximum
        dynamicMemoryEnabled = [bool]$vm.DynamicMemoryEnabled
        uptimeSeconds = [math]::Max(0, [math]::Floor($vm.Uptime.TotalSeconds))
    }
})

$volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size -gt 0 } | ForEach-Object {
    [ordered]@{
        id = $_.DeviceID
        name = $(if ($_.VolumeName) { "$($_.DeviceID) $($_.VolumeName)" } else { $_.DeviceID })
        totalBytes = [long]$_.Size
        usedBytes = [long]$_.Size - [long]$_.FreeSpace
        fileSystem = $_.FileSystem
    }
})

[ordered]@{
    schemaVersion = 1
    collectedAt = [DateTime]::UtcNow.ToString('o')
    host = [ordered]@{
        id = $system.Name
        name = $system.Name
        cpuUsagePercent = [math]::Min(100, [math]::Max(0, [double]$cpu.PercentTotalRunTime))
        logicalProcessorCount = [int]$system.NumberOfLogicalProcessors
        memoryTotalBytes = $totalMemory
        memoryUsedBytes = $totalMemory - $freeMemory
        uptimeSeconds = [math]::Max(0, [math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalSeconds))
    }
    virtualMachines = $vms
    volumes = $volumes
} | ConvertTo-Json -Depth 6 -Compress
