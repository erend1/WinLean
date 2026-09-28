#Requires -Version 5.1
<#
    WinLean.Core
    ------------
    The engine facade. WinLean.ps1 (and any future front-end such as a GUI) calls only
    these functions; they orchestrate the component modules:

      Inventory -> Compatibility context -> Profile -> Rule evaluation -> Plan (dry run)
      -> Backup -> Execution -> Verification -> Logging -> Report -> Restore

    A session object carries the paths, the logger and the facts about the current
    process. There is no global mutable state.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in @(
        'WinLean.Common'
        'WinLean.Logging'
        'Providers\WinLean.Providers'
        'WinLean.Validation'
        'WinLean.Rules'
        'WinLean.Inventory'
        'WinLean.Compatibility'
        'WinLean.Policy'
        'WinLean.Backup'
        'WinLean.Executor'
        'WinLean.Restore'
        'WinLean.Benchmark'
        'WinLean.Report'
    )) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath ($module + '.psm1'))
}

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

function New-WinLeanSession {
    <#
    .SYNOPSIS
        Creates the session used by every WinLean command.
    .PARAMETER InstallRoot
        The WinLean folder (contains Rules, Profiles, Config, Schemas and src).
    .PARAMETER DataRoot
        Where Backups, Reports and Logs are written. Defaults to InstallRoot.
    .PARAMETER CompatibilityPath
        Compatibility requirements file. Defaults to Config\Compatibility.json.
    .PARAMETER Command
        Name of the command, used in log file names.
    .PARAMETER NoLogFiles
        Log to the console only (used by tests).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [string] $DataRoot,
        [string] $CompatibilityPath,
        [ValidatePattern('^[A-Za-z0-9-]+$')] [string] $Command = 'session',
        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'NONE')] [string] $ConsoleLevel = 'INFO',
        [switch] $NoLogFiles,
        [switch] $CaptureLog
    )

    $install = Resolve-WinLeanPath -Path $InstallRoot
    $data = if ($DataRoot) { Resolve-WinLeanPath -Path $DataRoot } else { $install }
    $runId = New-WinLeanRunId
    $paths = [pscustomobject]@{
        install             = $install
        data                = $data
        rules               = Join-Path -Path $install -ChildPath 'Rules'
        profiles            = Join-Path -Path $install -ChildPath 'Profiles'
        config              = Join-Path -Path $install -ChildPath 'Config'
        schemas             = Join-Path -Path $install -ChildPath 'Schemas'
        compatibilitySchema = Join-Path -Path $install -ChildPath 'Schemas\compatibility.schema.json'
        compatibility       = if ($CompatibilityPath) { Resolve-WinLeanPath -Path $CompatibilityPath } else { Join-Path -Path $install -ChildPath 'Config\Compatibility.json' }
        backups             = Join-Path -Path $data -ChildPath 'Backups'
        reports             = Join-Path -Path $data -ChildPath 'Reports'
        logs                = Join-Path -Path $data -ChildPath 'Logs'
    }

    $loggerParameters = @{ Name = "$runId-$Command"; ConsoleLevel = $ConsoleLevel; Capture = [bool]$CaptureLog }
    if (-not $NoLogFiles) {
        $loggerParameters['Directory'] = $paths.logs
    }
    $identity = Get-WinLeanIdentity

    return [pscustomobject]@{
        PSTypeName      = 'WinLean.Session'
        runId           = $runId
        command         = $Command
        version         = Get-WinLeanVersion
        paths           = $paths
        logger          = New-WinLeanLogger @loggerParameters
        identity        = $identity
        isAdministrator = [bool]$identity.isAdministrator
        platform        = Get-WinLeanPlatform
    }
}

function Get-WinLeanKnownRequirementKeys {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    @(Get-WinLeanRequirementDefinitions -SchemaPath $Session.paths.compatibilitySchema | ForEach-Object { $_.key })
}

function Get-WinLeanSessionCatalog {
    <#
    .SYNOPSIS
        Loads the rule catalog and refuses to continue when it contains errors.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $catalog = Import-WinLeanRuleCatalog -Path $Session.paths.rules -KnownRequirementKeys @(Get-WinLeanKnownRequirementKeys -Session $Session)
    foreach ($issue in @($catalog.issues | Where-Object { $_.severity -eq 'Warning' })) {
        Write-WinLeanLog -Logger $Session.logger -Level WARN -Message "$($issue.source): $($issue.message)"
    }
    if ($catalog.errorCount -gt 0) {
        foreach ($issue in @($catalog.issues | Where-Object { $_.severity -eq 'Error' })) {
            Write-WinLeanLog -Logger $Session.logger -Level ERROR -Message "$($issue.source): $($issue.message)"
        }
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "The rule catalog contains $($catalog.errorCount) error(s). Run .\WinLean.ps1 -Validate for details.")
    }
    Write-WinLeanLog -Logger $Session.logger -Level DEBUG -Message "Loaded $($catalog.ruleIds.Count) rules from $($Session.paths.rules)"
    return $catalog
}

function Get-WinLeanSessionCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $compatibility = Import-WinLeanCompatibility -Path $Session.paths.compatibility -KnownRequirementKeys @(Get-WinLeanKnownRequirementKeys -Session $Session)
    foreach ($issue in @($compatibility.issues)) {
        $level = if ($issue.severity -eq 'Error') { 'ERROR' } else { 'WARN' }
        Write-WinLeanLog -Logger $Session.logger -Level $level -Message "$($issue.source): $($issue.message)"
    }
    if ($compatibility.errorCount -gt 0) {
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "The compatibility configuration '$($compatibility.source)' is invalid.")
    }
    return $compatibility
}

function Get-WinLeanPerUserTarget {
    <#
    .SYNOPSIS
        Match when this process runs as the user who owns the desktop, Mismatch when it
        does not, Unknown when that cannot be determined.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    if ($Session.identity.isSystem) {
        return 'Mismatch'
    }
    $interactiveSid = Get-WinLeanInteractiveUserSid
    if (-not $interactiveSid) {
        return 'Unknown'
    }
    if ($interactiveSid -eq $Session.identity.sid) {
        return 'Match'
    }
    return 'Mismatch'
}

function Write-WinLeanInventoryProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Logger')] $Logger,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Result
    )

    if ($Result.available) {
        Write-WinLeanLog -Logger $Logger -Level DEBUG -Message "Inventory section '$Name' collected in $($Result.durationMs) ms"
    }
    elseif ($Result.reason -eq 'Skipped') {
        Write-WinLeanLog -Logger $Logger -Level DEBUG -Message "Inventory section '$Name' skipped"
    }
    else {
        $level = if ($Result.reason -eq 'Error') { 'WARN' } else { 'INFO' }
        Write-WinLeanLog -Logger $Logger -Level $level -Message "Inventory section '$Name' unavailable ($($Result.reason)): $($Result.message)"
    }
}

function Invoke-WinLeanInventoryCollection {
    <#
    .SYNOPSIS
        Collects the inventory with progress logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [string[]] $Section,
        [string[]] $ExcludeSection
    )

    # The callback stays bound to this module, so it sees $logger and private functions.
    $logger = $Session.logger
    $parameters = @{
        OnSection = { param($name, $result) Write-WinLeanInventoryProgress -Logger $logger -Name $name -Result $result }
    }
    if ($Section) { $parameters['Section'] = $Section }
    if ($ExcludeSection) { $parameters['ExcludeSection'] = $ExcludeSection }
    return Get-WinLeanInventory @parameters
}

# ---------------------------------------------------------------------------
# Analyze
# ---------------------------------------------------------------------------

function Invoke-WinLeanAnalyze {
    <#
    .SYNOPSIS
        Collects and saves the inventory and derives capabilities and suggestions.
        Read-only; works without administrator rights.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [string[]] $ExcludeSection
    )

    $logger = $Session.logger
    Write-WinLeanLog -Logger $logger -Message 'Collecting inventory (read-only)'
    $inventory = Invoke-WinLeanInventoryCollection -Session $Session -ExcludeSection $ExcludeSection
    $inventoryPath = Join-Path -Path $Session.paths.reports -ChildPath ("Inventory\{0}-inventory.json" -f $Session.runId)
    Write-WinLeanJsonFile -Path $inventoryPath -InputObject $inventory
    Write-WinLeanLog -Logger $logger -Message "Inventory completed in $([Math]::Round($inventory.durationMs / 1000.0, 1)) s" -Data @{ path = $inventoryPath }

    $capabilities = Get-WinLeanCapabilities -Inventory $inventory
    $compatibility = Get-WinLeanSessionCompatibility -Session $Session
    $keys = @(Get-WinLeanKnownRequirementKeys -Session $Session)
    return [pscustomobject]@{
        PSTypeName    = 'WinLean.Analysis'
        inventory     = $inventory
        inventoryPath = $inventoryPath
        compatibility = Get-WinLeanCompatibilitySummary -Compatibility $compatibility -KnownRequirementKeys $keys -Capabilities $capabilities
        suggestions   = @(Get-WinLeanCompatibilitySuggestions -Compatibility $compatibility -Capabilities $capabilities)
    }
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

function Invoke-WinLeanDryRun {
    <#
    .SYNOPSIS
        Loads the profile, evaluates every rule and returns the execution plan.
        Read-only; the plan is saved as JSON unless -NoSave is given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [Parameter(Mandatory)] [string] $ProfileName,
        [switch] $AllowUntestedBuild,
        [switch] $NoSave
    )

    $logger = $Session.logger
    $catalog = Get-WinLeanSessionCatalog -Session $Session
    $profile = Import-WinLeanProfile -Name $ProfileName -ProfileDirectory $Session.paths.profiles
    $profileIssues = @(Test-WinLeanProfileRules -Profile $profile -Catalog $catalog)
    foreach ($issue in @($profileIssues | Where-Object { $_.severity -eq 'Warning' })) {
        Write-WinLeanLog -Logger $logger -Level WARN -Message $issue.message
    }
    $profileErrors = @($profileIssues | Where-Object { $_.severity -eq 'Error' })
    if ($profileErrors.Count -gt 0) {
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList ("Profile '$($profile.name)' is invalid: " + (($profileErrors | ForEach-Object { $_.message }) -join ' ')))
    }
    Write-WinLeanLog -Logger $logger -Message "Profile '$($profile.name)' loaded ($($profile.ruleIds.Count) rules)"

    $compatibility = Get-WinLeanSessionCompatibility -Session $Session
    $keys = @(Get-WinLeanKnownRequirementKeys -Session $Session)

    # Capabilities are only collected when a rule of the profile asks for one.
    $capabilities = New-WinLeanDictionary
    $rules = @(foreach ($id in $profile.ruleIds) { $catalog.rules[$id] })
    $capabilityFacts = @(Get-WinLeanRuleFactNames -Rules $rules | Where-Object { $_.StartsWith('capability.', [System.StringComparison]::Ordinal) })
    if ($capabilityFacts.Count -gt 0) {
        Write-WinLeanLog -Logger $logger -Message 'Detecting capabilities used by rule conditions'
        $inventory = Invoke-WinLeanInventoryCollection -Session $Session -Section @('hardware', 'appxPackages', 'win32Applications', 'optionalFeatures')
        $capabilities = Get-WinLeanCapabilities -Inventory $inventory
    }

    $warnings = New-Object -TypeName System.Collections.Generic.List[string]
    if (-not $compatibility.exists) {
        $warnings.Add("No compatibility configuration found at '$($Session.paths.compatibility)'. Every requirement is treated as required, so rules with compatibility conditions are skipped. Copy Config\Compatibility.example.json to Config\Compatibility.json to declare your requirements.")
    }
    $perUserTarget = Get-WinLeanPerUserTarget -Session $Session
    if ($perUserTarget -eq 'Unknown') {
        $warnings.Add('Could not determine which account owns the desktop session; per-user settings will be applied to the account running WinLean.')
    }

    $context = New-WinLeanPlanContext `
        -Facts (New-WinLeanFacts -Platform $Session.platform -Compatibility $compatibility -Capabilities $capabilities) `
        -IsAdministrator $Session.isAdministrator `
        -PerUserTarget $perUserTarget `
        -UserName $Session.identity.name `
        -Platform $Session.platform `
        -Compatibility (Get-WinLeanCompatibilitySummary -Compatibility $compatibility -KnownRequirementKeys $keys -Capabilities $capabilities) `
        -Warnings $warnings.ToArray() `
        -AllowUntestedBuild:$AllowUntestedBuild
    $plan = New-WinLeanPlan -Profile $profile -Catalog $catalog -Context $context
    $plan | Add-Member -NotePropertyName 'planId' -NotePropertyValue $Session.runId

    $counts = $plan.summary.counts
    Write-WinLeanLog -Logger $logger -Tag PLAN -Message ("{0} rules evaluated: {1} to apply, {2} already satisfied, {3} blocked, {4} skipped, {5} require confirmation, {6} unsupported" -f `
            $plan.summary.total, $counts.Applicable, $counts.AlreadySatisfied, $counts.Blocked, $counts.Skipped, $counts.RequiresConfirmation, $counts.Unsupported)

    if (-not $NoSave) {
        $planPath = Join-Path -Path $Session.paths.reports -ChildPath ("Plans\{0}-{1}-plan.json" -f $Session.runId, $profile.name)
        Write-WinLeanJsonFile -Path $planPath -InputObject $plan
        $plan | Add-Member -NotePropertyName 'planPath' -NotePropertyValue $planPath
        Write-WinLeanLog -Logger $logger -Level DEBUG -Message "Plan saved to $planPath"
    }
    return $plan
}

# ---------------------------------------------------------------------------
# Validation and rule listing
# ---------------------------------------------------------------------------

function Test-WinLeanConfiguration {
    <#
    .SYNOPSIS
        Validates every rule, every profile and the compatibility files.
    .OUTPUTS
        Object with issues, errorCount, warningCount, ruleCount and profileCount.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $keys = @(Get-WinLeanKnownRequirementKeys -Session $Session)
    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    $catalog = Import-WinLeanRuleCatalog -Path $Session.paths.rules -KnownRequirementKeys $keys
    foreach ($issue in $catalog.issues) { $issues.Add($issue) }

    $profileFiles = @()
    if ([System.IO.Directory]::Exists($Session.paths.profiles)) {
        $profileFiles = [System.IO.Directory]::GetFiles($Session.paths.profiles, '*.json')
        [System.Array]::Sort($profileFiles, [System.StringComparer]::OrdinalIgnoreCase)
    }
    foreach ($file in $profileFiles) {
        try {
            $profile = Import-WinLeanProfile -Name $file -ProfileDirectory $Session.paths.profiles
            foreach ($issue in @(Test-WinLeanProfileRules -Profile $profile -Catalog $catalog)) { $issues.Add($issue) }
        }
        catch {
            $issues.Add((New-WinLeanIssue -Severity Error -Code 'Profile' -Source $file -Message $_.Exception.Message))
        }
    }

    foreach ($path in @((Join-Path -Path $Session.paths.config -ChildPath 'Compatibility.example.json'), $Session.paths.compatibility)) {
        if ([System.IO.File]::Exists($path)) {
            $compatibility = Import-WinLeanCompatibility -Path $path -KnownRequirementKeys $keys
            foreach ($issue in $compatibility.issues) { $issues.Add($issue) }
        }
    }

    $all = $issues.ToArray()
    return [pscustomobject]@{
        issues       = $all
        errorCount   = @($all | Where-Object { $_.severity -eq 'Error' }).Count
        warningCount = @($all | Where-Object { $_.severity -eq 'Warning' }).Count
        ruleCount    = $catalog.ruleIds.Count
        profileCount = $profileFiles.Count
    }
}

function Get-WinLeanRules {
    <#
    .SYNOPSIS
        Returns the rules of the catalog and, for each rule, the profiles that include it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $catalog = Get-WinLeanSessionCatalog -Session $Session
    $membership = New-WinLeanDictionary
    if ([System.IO.Directory]::Exists($Session.paths.profiles)) {
        $files = [System.IO.Directory]::GetFiles($Session.paths.profiles, '*.json')
        [System.Array]::Sort($files, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $files) {
            try {
                $profile = Import-WinLeanProfile -Name $file -ProfileDirectory $Session.paths.profiles
            }
            catch {
                Write-WinLeanLog -Logger $Session.logger -Level WARN -Message "Skipping profile '$file': $($_.Exception.Message)"
                continue
            }
            foreach ($id in $profile.ruleIds) {
                if (-not $membership.ContainsKey($id)) {
                    $membership[$id] = New-Object -TypeName System.Collections.Generic.List[string]
                }
                $membership[$id].Add($profile.name)
            }
        }
    }
    return [pscustomobject]@{
        rules      = @(foreach ($id in $catalog.ruleIds) { $catalog.rules[$id] })
        membership = $membership
    }
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

function Invoke-WinLeanApply {
    <#
    .SYNOPSIS
        Applies the Applicable items of a plan that the user has confirmed.
    .DESCRIPTION
        Takes the execution lock, records an inventory (without the slow WinGet section),
        then lets the executor re-read state, write the backup, apply, verify and roll
        back failed rules. Returns the execution result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Plan')] $Plan,
        [switch] $SkipInventory,
        [switch] $SkipBenchmark
    )

    $logger = $Session.logger
    $lock = Enter-WinLeanLock -Directory $Session.paths.backups
    try {
        $inventory = $null
        $benchmark = $null
        $hasWork = @($Plan.items | Where-Object { $_.status -eq 'Applicable' }).Count -gt 0
        if ($hasWork -and -not $SkipInventory) {
            Write-WinLeanLog -Logger $logger -Message 'Recording inventory for the backup'
            $inventory = Invoke-WinLeanInventoryCollection -Session $Session -ExcludeSection @('wingetPackages')
        }
        if ($hasWork -and -not $SkipBenchmark) {
            $benchmark = Invoke-WinLeanBenchmark -Session $Session
        }
        $catalog = Get-WinLeanSessionCatalog -Session $Session
        $execution = Invoke-WinLeanExecution -Plan $Plan -Catalog $catalog -BackupRoot $Session.paths.backups -RunId $Session.runId `
            -Logger $logger -Identity $Session.identity -Platform $Session.platform -Inventory $inventory -Benchmark $benchmark
        if ($execution.backupId) {
            try {
                $report = New-WinLeanReport -Session $Session -BackupId $execution.backupId
                $execution | Add-Member -NotePropertyName 'reportPath' -NotePropertyValue $report.path
            }
            catch {
                Write-WinLeanLog -Logger $logger -Level WARN -Message "The report could not be generated: $($_.Exception.Message)"
            }
        }
        $summary = $execution.summary
        $level = if ($summary.failed -gt 0) { 'WARN' } else { 'INFO' }
        Write-WinLeanLog -Logger $logger -Level $level -Message ("Execution {0}: {1} applied and verified, {2} already satisfied, {3} failed" -f `
                $execution.status, $summary.succeeded, $summary.alreadySatisfied, $summary.failed) -Data @{ backupId = $execution.backupId }
        return $execution
    }
    finally {
        Exit-WinLeanLock -Lock $lock
    }
}

# ---------------------------------------------------------------------------
# Restore and backups
# ---------------------------------------------------------------------------

function Invoke-WinLeanRestorePreview {
    <#
    .SYNOPSIS
        Loads a backup ('Latest' or an id) and returns the restore plan. Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [string] $BackupId = 'Latest',
        [switch] $Force
    )

    $backup = Get-WinLeanBackup -Root $Session.paths.backups -Id $BackupId
    Write-WinLeanLog -Logger $Session.logger -Message "Backup $($backup.id) loaded ($(@($backup.changes).Count) recorded change(s))"
    $plan = Get-WinLeanRestorePlan -Backup $backup -Identity $Session.identity -Force:$Force
    if (-not $plan.sameUser -and @($plan.items | Where-Object { $_.scope -ne 'Machine' }).Count -gt 0) {
        Write-WinLeanLog -Logger $Session.logger -Level WARN -Message "The backup was recorded by '$($plan.recordedBy)'. Its per-user values can only be restored by that user."
    }
    return $plan
}

function Invoke-WinLeanRestore {
    <#
    .SYNOPSIS
        Executes a restore plan the user has confirmed (under the execution lock).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [Parameter(Mandatory)] [PSTypeName('WinLean.RestorePlan')] $RestorePlan
    )

    $lock = Enter-WinLeanLock -Directory $Session.paths.backups
    try {
        $result = Invoke-WinLeanRestorePlan -RestorePlan $RestorePlan -RunId $Session.runId -Logger $Session.logger
        $summary = $result.summary
        $level = if ($result.status -eq 'Incomplete') { 'WARN' } else { 'INFO' }
        Write-WinLeanLog -Logger $Session.logger -Level $level -Message ("Restore {0}: {1} restored, {2} already previous, {3} skipped, {4} blocked, {5} failed" -f `
                $result.status, $summary.Restored, $summary.NotNeeded, $summary.Skipped, $summary.Blocked, $summary.Failed) -Data @{ backupId = $result.backupId }
        return $result
    }
    finally {
        Exit-WinLeanLock -Lock $lock
    }
}

# ---------------------------------------------------------------------------
# Benchmark and report
# ---------------------------------------------------------------------------

function Invoke-WinLeanBenchmark {
    <#
    .SYNOPSIS
        Measures background activity and saves the result to Reports\Benchmarks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [ValidateRange(2, 600)] [int] $SampleCount = 10,
        [ValidateRange(1, 60)] [int] $IntervalSeconds = 1,
        [switch] $NoSave
    )

    Write-WinLeanLog -Logger $Session.logger -Message ("Measuring background activity for about {0} seconds; keep the system idle" -f ($SampleCount * $IntervalSeconds))
    $benchmark = Measure-WinLeanSystem -SampleCount $SampleCount -IntervalSeconds $IntervalSeconds
    foreach ($note in @($benchmark.notes)) {
        Write-WinLeanLog -Logger $Session.logger -Level WARN -Message $note
    }
    if (-not $NoSave) {
        $path = Join-Path -Path $Session.paths.reports -ChildPath ("Benchmarks\{0}-benchmark.json" -f $Session.runId)
        Write-WinLeanJsonFile -Path $path -InputObject $benchmark
        $benchmark | Add-Member -NotePropertyName 'path' -NotePropertyValue $path
        Write-WinLeanLog -Logger $Session.logger -Level DEBUG -Message "Benchmark saved to $path"
    }
    return $benchmark
}

function Get-WinLeanBenchmarkAfter {
    <#
    .SYNOPSIS
        Returns the newest saved benchmark collected after the given time, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [Parameter(Mandatory)] [System.DateTimeOffset] $Since
    )

    $directory = Join-Path -Path $Session.paths.reports -ChildPath 'Benchmarks'
    if (-not [System.IO.Directory]::Exists($directory)) {
        return $null
    }
    $files = [System.IO.Directory]::GetFiles($directory, '*-benchmark.json')
    [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
    [System.Array]::Reverse($files)
    foreach ($file in $files) {
        try {
            $benchmark = Read-WinLeanJsonFile -Path $file
            $collectedAt = ConvertTo-WinLeanDateTimeOffset -Value $benchmark.collectedAt
            if ($null -ne $collectedAt -and $collectedAt -gt $Since) {
                return $benchmark
            }
        }
        catch {
            Write-WinLeanLog -Logger $Session.logger -Level WARN -Message "Ignoring unreadable benchmark '$file': $($_.Exception.Message)"
        }
    }
    return $null
}

function New-WinLeanReport {
    <#
    .SYNOPSIS
        Writes the Markdown report of an apply run to Reports\<backupId>-report.md.
    .PARAMETER BackupId
        'Latest' (the newest backup, restored or not) or a backup id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [string] $BackupId = 'Latest'
    )

    $id = $BackupId
    if ($BackupId -eq 'Latest') {
        $newest = @(Get-WinLeanBackupList -Root $Session.paths.backups | Where-Object { $_.status -ne 'Unreadable' }) | Select-Object -First 1
        if ($null -eq $newest) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "No WinLean backups were found in '$($Session.paths.backups)'. A report describes an -Apply run; run '.\WinLean.ps1 -Profile <name> -Apply' first, or use -Analyze.")
        }
        $id = $newest.id
    }
    $backup = Get-WinLeanBackup -Root $Session.paths.backups -Id $id

    $since = ConvertTo-WinLeanDateTimeOffset -Value (Get-WinLeanProperty -InputObject $backup.manifest -Name 'completedAt')
    if ($null -eq $since) {
        $since = ConvertTo-WinLeanDateTimeOffset -Value $backup.manifest.createdAt
    }
    $after = Get-WinLeanBenchmarkAfter -Session $Session -Since $since

    $restoreFiles = [System.IO.Directory]::GetFiles($backup.path, 'restore-*.json')
    [System.Array]::Sort($restoreFiles, [System.StringComparer]::Ordinal)
    $restores = @(foreach ($file in $restoreFiles) { Read-WinLeanJsonFile -Path $file })

    $markdown = ConvertTo-WinLeanMarkdownReport -Backup $backup -BenchmarkAfter $after -Restores $restores -BasePath $Session.paths.data
    $path = Join-Path -Path $Session.paths.reports -ChildPath ("{0}-report.md" -f $backup.id)
    Write-WinLeanTextFile -Path $path -Content $markdown
    Write-WinLeanLog -Logger $Session.logger -Message "Report written: $path"
    return [pscustomobject]@{
        path           = $path
        backupId       = $backup.id
        benchmarkAfter = ($null -ne $after)
        markdown       = $markdown
    }
}

function Get-WinLeanBackups {
    <#
    .SYNOPSIS
        Lists the backups in the data folder, newest first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    @(Get-WinLeanBackupList -Root $Session.paths.backups)
}

Export-ModuleMember -Function @(
    'New-WinLeanSession'
    'Invoke-WinLeanAnalyze'
    'Invoke-WinLeanDryRun'
    'Invoke-WinLeanApply'
    'Invoke-WinLeanRestorePreview'
    'Invoke-WinLeanRestore'
    'Get-WinLeanBackups'
    'Invoke-WinLeanBenchmark'
    'New-WinLeanReport'
    'Test-WinLeanConfiguration'
    'Get-WinLeanRules'
)
