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

$vmObjects = @(Get-VM)
# WDDM exposes process/adapter/engine counters. GPU-PV guest contexts appear
# under the VM worker PID, sometimes with #N duplicate-instance suffixes.
# Sum contexts on each physical engine, then take the busiest engine. Adding
# different engines or GPUs together would overstate utilization.
$hostEngines = @{}
$workerEngines = @{}
$gpuPartitions = @{}
$vmWorkers = @{}
$gpuUsage = $null
$gpuCountersAvailable = $false
$gpuPartitionsAvailable = $false
try {
    foreach ($partition in @($vmObjects | Get-VMGpuPartitionAdapter -ErrorAction Stop)) {
        $vmKey = $partition.VMId.ToString()
        if (-not $gpuPartitions.ContainsKey($vmKey)) { $gpuPartitions[$vmKey] = 0 }
        $gpuPartitions[$vmKey]++
    }
    $gpuPartitionsAvailable = $true
} catch { $gpuPartitions.Clear() }
try {
    foreach ($machine in @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -ErrorAction Stop)) {
        if ($machine.ProcessID -gt 0) { $vmWorkers[$machine.Name] = [string]$machine.ProcessID }
    }
} catch { $vmWorkers.Clear() }
try {
    foreach ($counter in @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop)) {
        if ($counter.Name -notmatch '^pid_(\d+)_(luid_0x[0-9a-f]+_0x[0-9a-f]+_phys_\d+_eng_\d+)_engtype_.+?(?:#\d+)?$') { continue }
        if ($null -eq $counter.UtilizationPercentage) { continue }
        $workerKey = $Matches[1]
        $engineKey = $Matches[2]
        $usage = [double]$counter.UtilizationPercentage
        if ($usage -lt 0 -or [double]::IsNaN($usage) -or [double]::IsInfinity($usage)) { continue }
        if (-not $hostEngines.ContainsKey($engineKey)) { $hostEngines[$engineKey] = 0.0 }
        $hostEngines[$engineKey] += $usage
        if (-not $workerEngines.ContainsKey($workerKey)) { $workerEngines[$workerKey] = @{} }
        if (-not $workerEngines[$workerKey].ContainsKey($engineKey)) { $workerEngines[$workerKey][$engineKey] = 0.0 }
        $workerEngines[$workerKey][$engineKey] += $usage
    }
    if ($hostEngines.Count -gt 0) {
        $gpuCountersAvailable = $true
        $gpuUsage = [math]::Min(100, ($hostEngines.Values | Measure-Object -Maximum).Maximum)
    }
} catch { $hostEngines.Clear(); $workerEngines.Clear() }

$vms = @($vmObjects | ForEach-Object {
    $vm = $_
    $running = $vm.State.ToString() -eq 'Running'
    $assigned = [long]$vm.MemoryAssigned
    # A running guest without memory telemetry reports zero demand. Keep it
    # unknown instead of claiming zero usage or substituting assigned memory.
    $demand = $null
    if ($running -and $vm.MemoryDemand -gt 0) { $demand = [long]$vm.MemoryDemand }
    if ($assigned -eq 0 -and -not $running) { $demand = [long]0 }
    $vmKey = $vm.Id.ToString()
    $partitionCount = $null
    $vmGpuUsage = $null
    if ($gpuPartitionsAvailable) {
        $partitionCount = 0
        if ($gpuPartitions.ContainsKey($vmKey)) { $partitionCount = $gpuPartitions[$vmKey] }
    }
    if ($partitionCount -gt 0) {
        if ($vm.State.ToString() -eq 'Off' -or $vm.State.ToString() -eq 'Saved') {
            $vmGpuUsage = 0.0
        } elseif ($gpuCountersAvailable -and $vmWorkers.ContainsKey($vmKey)) {
            $workerKey = $vmWorkers[$vmKey]
            # No matching worker counters is unknown, not proof of zero usage.
            if ($workerEngines.ContainsKey($workerKey)) {
                $vmGpuUsage = [math]::Min(100, ($workerEngines[$workerKey].Values | Measure-Object -Maximum).Maximum)
            }
        }
    }
    [ordered]@{
        id = $vm.Id.ToString()
        name = $vm.Name
        state = $vm.State.ToString()
        cpuUsagePercent = $(if ($running) { [double]$vm.CPUUsage } else { 0.0 })
        processorCount = [int]$vm.ProcessorCount
        gpuPartitionCount = $partitionCount
        gpuUsagePercent = $vmGpuUsage
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
        gpuUsagePercent = $gpuUsage
        memoryTotalBytes = $totalMemory
        memoryUsedBytes = $totalMemory - $freeMemory
        uptimeSeconds = [math]::Max(0, [math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalSeconds))
    }
    virtualMachines = $vms
    volumes = $volumes
} | ConvertTo-Json -Depth 6 -Compress
