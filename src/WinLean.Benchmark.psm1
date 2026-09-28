#Requires -Version 5.1
<#
    WinLean.Benchmark
    -----------------
    Measures background activity of the current system. Read-only.

    Metrics and methods (see Docs/Benchmarking.md):

      CPU        Win32_PerfRawData_PerfOS_Processor (_Total): busy % between consecutive
                 samples = 100 * (1 - delta(idle time) / delta(timestamp)). Raw counters are
                 used because they are not localized (performance counter names are).
      Memory     Win32_OperatingSystem: in use = total visible - available (available
                 includes the standby list); commit charge from Win32_PerfRawData_PerfOS_Memory.
      Processes  number of processes at the end of the sampling window, and the processes
                 that used the most CPU during the window (accessible processes only).
      Services   running services and running third-party services (vendor heuristic of
                 the inventory).
      Startup    enabled startup entries (Run keys and startup folders).

    Precision is deliberately limited: CPU is reported with one decimal, memory in whole
    megabytes. A single measurement reflects the moment it was taken; compare runs taken
    under similar conditions (same uptime range, power source, no user activity).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Inventory.psm1')

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-WinLeanCpuCounterSample {
    [CmdletBinding()]
    param()

    $counter = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor -Filter "Name = '_Total'" -ErrorAction Stop
    return [pscustomobject]@{
        idle      = [uint64]$counter.PercentProcessorTime
        timestamp = [uint64]$counter.Timestamp_Sys100NS
    }
}

function Get-WinLeanCpuBusyPercent {
    <#
    .SYNOPSIS
        Busy percentage between two raw samples of the _Total processor counter, or $null
        when the samples cannot be compared. Pure function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Previous,
        [Parameter(Mandatory)] $Current
    )

    if ([uint64]$Current.timestamp -le [uint64]$Previous.timestamp -or [uint64]$Current.idle -lt [uint64]$Previous.idle) {
        return $null
    }
    $elapsed = [double]([uint64]$Current.timestamp - [uint64]$Previous.timestamp)
    $idle = [double]([uint64]$Current.idle - [uint64]$Previous.idle)
    $busy = 100.0 * (1.0 - ($idle / $elapsed))
    return [Math]::Max(0.0, [Math]::Min(100.0, $busy))
}

function Get-WinLeanStatistics {
    <#
    .SYNOPSIS
        Average, median, minimum and maximum of a list of numbers (one decimal). Pure function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [double[]] $Values
    )

    if ($Values.Count -eq 0) {
        return [pscustomobject]@{ average = $null; median = $null; minimum = $null; maximum = $null }
    }
    $sorted = [double[]]$Values.Clone()
    [System.Array]::Sort($sorted)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    $median = if ($sorted.Count % 2 -eq 1) { $sorted[$middle] } else { ($sorted[$middle - 1] + $sorted[$middle]) / 2.0 }
    $sum = 0.0
    foreach ($value in $sorted) { $sum += $value }
    return [pscustomobject]@{
        average = [Math]::Round($sum / $sorted.Count, 1)
        median  = [Math]::Round($median, 1)
        minimum = [Math]::Round($sorted[0], 1)
        maximum = [Math]::Round($sorted[$sorted.Count - 1], 1)
    }
}

function Get-WinLeanProcessCpuTimes {
    <#
    .SYNOPSIS
        Total processor time per accessible process (keyed by id and start time).
    #>
    [CmdletBinding()]
    param()

    $times = New-WinLeanDictionary
    $inaccessible = 0
    foreach ($process in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $key = '{0}:{1}' -f $process.Id, $process.StartTime.Ticks
            $times[$key] = [pscustomobject]@{ name = $process.ProcessName; seconds = $process.TotalProcessorTime.TotalSeconds }
        }
        catch {
            $inaccessible++
        }
        finally {
            $process.Dispose()
        }
    }
    return [pscustomobject]@{ times = $times; inaccessible = $inaccessible }
}

function Measure-WinLeanSystem {
    <#
    .SYNOPSIS
        Samples CPU for SampleCount x IntervalSeconds and records memory, processes,
        services and startup entries.
    .PARAMETER SampleCount
        Number of CPU samples (each covering IntervalSeconds).
    .PARAMETER IntervalSeconds
        Length of each CPU sample.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(2, 600)] [int] $SampleCount = 10,
        [ValidateRange(1, 60)] [int] $IntervalSeconds = 1
    )

    $notes = New-Object -TypeName System.Collections.Generic.List[string]
    $collectedAt = Get-WinLeanTimestamp
    $logicalProcessors = [Environment]::ProcessorCount

    # Context
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $lastBoot = [System.DateTimeOffset]$operatingSystem.LastBootUpTime
    $uptimeMinutes = [Math]::Round(([System.DateTimeOffset]::Now - $lastBoot).TotalMinutes)
    $onBattery = $null
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        if ($batteries.Count -gt 0) {
            # BatteryStatus 1 means "discharging" (running on battery).
            $onBattery = (@($batteries | Where-Object { [int]$_.BatteryStatus -eq 1 }).Count -gt 0)
        }
    }
    catch {
        $notes.Add("Power source unknown: $($_.Exception.Message)")
    }

    # CPU: warm up the performance provider, then sample.
    $cpuSamples = New-Object -TypeName System.Collections.Generic.List[double]
    $processStart = Get-WinLeanProcessCpuTimes
    $windowTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $cpuAvailable = $true
    try {
        $null = Get-WinLeanCpuCounterSample
        $previous = Get-WinLeanCpuCounterSample
        for ($index = 0; $index -lt $SampleCount; $index++) {
            Start-Sleep -Seconds $IntervalSeconds
            $current = Get-WinLeanCpuCounterSample
            $busy = Get-WinLeanCpuBusyPercent -Previous $previous -Current $current
            if ($null -ne $busy) {
                $cpuSamples.Add([Math]::Round($busy, 1))
            }
            $previous = $current
        }
    }
    catch {
        $cpuAvailable = $false
        $notes.Add("CPU counters unavailable: $($_.Exception.Message)")
    }
    $windowSeconds = $windowTimer.Elapsed.TotalSeconds
    $processEnd = Get-WinLeanProcessCpuTimes

    # Top CPU consumers during the window (accessible processes only).
    $consumers = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($key in @($processEnd.times.Keys)) {
        if (-not $processStart.times.ContainsKey($key)) { continue }
        $cpuSeconds = $processEnd.times[$key].seconds - $processStart.times[$key].seconds
        if ($cpuSeconds -le 0) { continue }
        $consumers.Add([pscustomobject]@{
                name       = $processEnd.times[$key].name
                cpuSeconds = [Math]::Round($cpuSeconds, 2)
                percent    = [Math]::Round(100.0 * $cpuSeconds / ($windowSeconds * $logicalProcessors), 1)
            })
    }
    $topConsumers = @($consumers.ToArray() | Sort-Object -Property cpuSeconds -Descending | Select-Object -First 5)

    # Memory
    $totalMB = [Math]::Round([double]$operatingSystem.TotalVisibleMemorySize / 1024)
    $refreshed = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $availableMB = [Math]::Round([double]$refreshed.FreePhysicalMemory / 1024)
    $committedMB = $null
    try {
        $memoryCounter = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        $committedMB = [Math]::Round([double]$memoryCounter.CommittedBytes / 1MB)
    }
    catch {
        $notes.Add("Commit charge unavailable: $($_.Exception.Message)")
    }

    # Services and startup (reuse the inventory collectors and their heuristics).
    $services = $null
    try {
        $serviceInventory = Get-WinLeanServiceInventory -IsAdministrator (Test-WinLeanAdministrator)
        $services = [pscustomobject]@{
            running           = $serviceInventory.runningCount
            runningThirdParty = $serviceInventory.runningThirdPartyCount
            thirdPartyRunning = [string[]]@($serviceInventory.services | Where-Object { $_.state -eq 'Running' -and $_.vendor -eq 'ThirdParty' } | ForEach-Object { $_.name })
        }
    }
    catch {
        $notes.Add("Services unavailable: $($_.Exception.Message)")
    }
    $startup = $null
    try {
        $startupInventory = Get-WinLeanStartupInventory -IsAdministrator (Test-WinLeanAdministrator)
        $startup = [pscustomobject]@{ entries = $startupInventory.count; enabled = $startupInventory.enabledCount }
    }
    catch {
        $notes.Add("Startup entries unavailable: $($_.Exception.Message)")
    }

    $cpuStatistics = Get-WinLeanStatistics -Values $cpuSamples.ToArray()
    return [pscustomobject]@{
        PSTypeName     = 'WinLean.Benchmark'
        schemaVersion  = 1
        collectedAt    = $collectedAt
        winLeanVersion = Get-WinLeanVersion
        context        = [pscustomobject]@{
            lastBootTime      = $lastBoot.ToString('o', $script:Invariant)
            uptimeMinutes     = $uptimeMinutes
            onBattery         = $onBattery
            logicalProcessors = $logicalProcessors
            isAdministrator   = Test-WinLeanAdministrator
        }
        cpu            = [pscustomobject]@{
            available             = $cpuAvailable
            sampleCount           = $cpuSamples.Count
            sampleIntervalSeconds = $IntervalSeconds
            samples               = $cpuSamples.ToArray()
            averagePercent        = $cpuStatistics.average
            medianPercent         = $cpuStatistics.median
            maximumPercent        = $cpuStatistics.maximum
        }
        memory         = [pscustomobject]@{
            totalMB      = $totalMB
            availableMB  = $availableMB
            inUseMB      = $totalMB - $availableMB
            inUsePercent = if ($totalMB -gt 0) { [Math]::Round(100.0 * ($totalMB - $availableMB) / $totalMB, 1) } else { $null }
            committedMB  = $committedMB
        }
        processes      = [pscustomobject]@{
            count            = @([System.Diagnostics.Process]::GetProcesses()).Count
            topCpuConsumers  = $topConsumers
            inaccessibleCount = $processEnd.inaccessible
        }
        services       = $services
        startup        = $startup
        method         = [pscustomobject]@{
            cpu      = 'Win32_PerfRawData_PerfOS_Processor(_Total): 100 * (1 - delta idle / delta time) per sample.'
            memory   = 'Win32_OperatingSystem: in use = total visible - available (available includes standby memory).'
            services = 'Running services; third-party = vendor heuristic (CompanyName, Authenticode fallback).'
            startup  = 'Enabled entries in Run keys and startup folders (Task Manager approval heuristic).'
        }
        notes          = $notes.ToArray()
    }
}

function Compare-WinLeanBenchmark {
    <#
    .SYNOPSIS
        Compares two benchmarks metric by metric. Pure function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Before,
        [AllowNull()] $After
    )

    $metrics = @(
        @{ Name = 'Average CPU (%)'; Path = @('cpu', 'averagePercent'); Decimals = 1 }
        @{ Name = 'Median CPU (%)'; Path = @('cpu', 'medianPercent'); Decimals = 1 }
        @{ Name = 'Memory in use (MB)'; Path = @('memory', 'inUseMB'); Decimals = 0 }
        @{ Name = 'Commit charge (MB)'; Path = @('memory', 'committedMB'); Decimals = 0 }
        @{ Name = 'Processes'; Path = @('processes', 'count'); Decimals = 0 }
        @{ Name = 'Running services'; Path = @('services', 'running'); Decimals = 0 }
        @{ Name = 'Running third-party services'; Path = @('services', 'runningThirdParty'); Decimals = 0 }
        @{ Name = 'Enabled startup entries'; Path = @('startup', 'enabled'); Decimals = 0 }
    )
    foreach ($metric in $metrics) {
        $beforeValue = Get-WinLeanBenchmarkValue -Benchmark $Before -Path $metric.Path
        $afterValue = if ($null -ne $After) { Get-WinLeanBenchmarkValue -Benchmark $After -Path $metric.Path } else { $null }
        $change = $null
        if ($null -ne $beforeValue -and $null -ne $afterValue) {
            $difference = [double]$afterValue - [double]$beforeValue
            $sign = if ($difference -gt 0) { '+' } else { '' }
            $change = $sign + (Format-WinLeanNumber -Value $difference -Decimals $metric.Decimals)
        }
        [pscustomobject]@{
            metric = $metric.Name
            before = if ($null -ne $beforeValue) { Format-WinLeanNumber -Value ([double]$beforeValue) -Decimals $metric.Decimals } else { $null }
            after  = if ($null -ne $afterValue) { Format-WinLeanNumber -Value ([double]$afterValue) -Decimals $metric.Decimals } else { $null }
            change = $change
        }
    }
}

function Get-WinLeanBenchmarkValue {
    [CmdletBinding()]
    param(
        [AllowNull()] $Benchmark,
        [Parameter(Mandatory)] [string[]] $Path
    )

    $value = $Benchmark
    foreach ($segment in $Path) {
        $value = Get-WinLeanProperty -InputObject $value -Name $segment
        if ($null -eq $value) {
            return $null
        }
    }
    return $value
}

Export-ModuleMember -Function @(
    'Measure-WinLeanSystem'
    'Compare-WinLeanBenchmark'
    'Get-WinLeanCpuBusyPercent'
    'Get-WinLeanStatistics'
)
