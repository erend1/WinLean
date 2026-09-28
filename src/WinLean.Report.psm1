#Requires -Version 5.1
<#
    WinLean.Report
    --------------
    Presentation of WinLean data: console text for analyses, plans, rule lists and
    validation results. Every function returns lines of text and writes nothing itself,
    so the same output can go to the console, a log or a file.

    Numbers are always formatted with the invariant culture.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Inventory.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Benchmark.psm1')

$script:Rule = [string]::new([char]0x2500, 64)

# Plan sections in display order: status -> heading.
$script:PlanSections = [ordered]@{
    Applicable           = 'APPLY'
    AlreadySatisfied     = 'ALREADY SATISFIED'
    RequiresConfirmation = 'REQUIRES CONFIRMATION'
    Blocked              = 'BLOCKED'
    Skipped              = 'SKIPPED'
    Unsupported          = 'UNSUPPORTED'
}

function Format-WinLeanYesNo {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return 'unknown' }
    if ([bool]$Value) { return 'Yes' }
    return 'No'
}

function Format-WinLeanLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Label,
        [AllowNull()] $Value,
        [int] $Width = 26,
        [int] $Indent = 2
    )

    $text = if ($null -eq $Value -or ($Value -is [string] -and $Value.Length -eq 0)) { 'unknown' } else { [string]$Value }
    return (' ' * $Indent) + $Label.PadRight($Width) + $text
}

function Format-WinLeanSectionValue {
    <#
    .SYNOPSIS
        Formats an inventory section (or probe): a value when available, otherwise the reason.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] $Section,
        [Parameter(Mandatory)] [scriptblock] $Formatter
    )

    if ($null -eq $Section) {
        return 'unavailable'
    }
    if (-not [bool](Get-WinLeanProperty -InputObject $Section -Name 'available' -Default $false)) {
        return 'unavailable (' + [string](Get-WinLeanProperty -InputObject $Section -Name 'reason' -Default 'Error') + ')'
    }
    return [string](& $Formatter $Section.data)
}

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

function Format-WinLeanAnalysisText {
    <#
    .SYNOPSIS
        Console summary of an analysis (inventory, capabilities, compatibility).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Analysis,
        [string] $BasePath
    )

    $inventory = $Analysis.inventory
    $sections = $inventory.sections
    $summary = Get-WinLeanInventorySummary -Inventory $inventory

    ''
    'WINLEAN ANALYSIS'
    ''
    'System'
    Format-WinLeanLabel -Label 'Windows' -Value $summary.windows
    Format-WinLeanLabel -Label 'CPU' -Value $summary.cpu
    Format-WinLeanLabel -Label 'Installed memory' -Value $(if ($summary.memoryGB) { "$($summary.memoryGB) GB" } else { $null })
    Format-WinLeanLabel -Label 'GPU' -Value $summary.gpu
    Format-WinLeanLabel -Label 'Administrator' -Value $(if ($summary.isAdministrator) { 'Yes' } else { 'No (sections that need elevation are marked unavailable)' })
    ''
    'Software'
    Format-WinLeanLabel -Label 'AppX packages' -Value (Format-WinLeanSectionValue -Section $sections.appxPackages -Formatter { param($d) "$($d.count) (current user)" })
    Format-WinLeanLabel -Label 'Provisioned AppX packages' -Value (Format-WinLeanSectionValue -Section $sections.provisionedAppxPackages -Formatter { param($d) "$($d.count)" })
    Format-WinLeanLabel -Label 'Win32 applications' -Value (Format-WinLeanSectionValue -Section $sections.win32Applications -Formatter { param($d) "$($d.count)" })
    Format-WinLeanLabel -Label 'WinGet packages' -Value (Format-WinLeanSectionValue -Section $sections.wingetPackages -Formatter { param($d) "$($d.count)" })
    Format-WinLeanLabel -Label 'Optional features' -Value (Format-WinLeanSectionValue -Section $sections.optionalFeatures -Formatter { param($d) "$($d.enabledCount) enabled of $($d.count)" })
    ''
    'Startup and background activity'
    Format-WinLeanLabel -Label 'Startup entries' -Value (Format-WinLeanSectionValue -Section $sections.startup -Formatter { param($d) "$($d.count) ($($d.enabledCount) enabled, $($d.disabledCount) disabled in Task Manager)" })
    Format-WinLeanLabel -Label 'Services' -Value (Format-WinLeanSectionValue -Section $sections.services -Formatter { param($d) "$($d.count) installed, $($d.runningCount) running" })
    Format-WinLeanLabel -Label 'Running third-party svcs' -Value (Format-WinLeanSectionValue -Section $sections.services -Formatter { param($d) "$($d.runningThirdPartyCount) (vendor heuristic)" })
    Format-WinLeanLabel -Label 'Scheduled tasks' -Value (Format-WinLeanSectionValue -Section $sections.scheduledTasks -Formatter { param($d) if ($d.complete) { "$($d.count)" } else { "$($d.count) (visible to this user)" } })

    $security = if ($sections.security.available) { $sections.security.data } else { $null }
    ''
    'Security (recorded only; WinLean never weakens it)'
    if ($null -eq $security) {
        Format-WinLeanLabel -Label 'Security state' -Value (Format-WinLeanSectionValue -Section $sections.security -Formatter { param($d) '' })
    }
    else {
        Format-WinLeanLabel -Label 'Microsoft Defender' -Value (Format-WinLeanSectionValue -Section $security.defender -Formatter {
                param($d)
                $state = if ($d.realTimeProtectionEnabled) { 'real-time protection on' } else { 'real-time protection OFF' }
                "$state ($($d.runningMode))"
            })
        Format-WinLeanLabel -Label 'Firewall' -Value (Format-WinLeanSectionValue -Section $security.firewall -Formatter {
                param($d)
                (@($d.profiles) | ForEach-Object { '{0} {1}' -f $_.name, $(if ($_.enabled) { 'on' } elseif ($_.enabled -eq $false) { 'OFF' } else { 'unknown' }) }) -join ', '
            })
        Format-WinLeanLabel -Label 'Secure Boot' -Value (Format-WinLeanSectionValue -Section $security.secureBoot -Formatter { param($d) $d.state })
        Format-WinLeanLabel -Label 'Virtualization-based sec.' -Value (Format-WinLeanSectionValue -Section $security.virtualizationBasedSecurity -Formatter {
                param($d)
                if (@($d.servicesRunning).Count -gt 0) { "$($d.status) ($(@($d.servicesRunning) -join ', '))" } else { $d.status }
            })
        Format-WinLeanLabel -Label 'BitLocker' -Value (Format-WinLeanSectionValue -Section $security.bitLocker -Formatter {
                param($d)
                (@($d.volumes) | ForEach-Object { '{0} {1}' -f $_.mountPoint, $_.protectionStatus }) -join ', '
            })
    }

    ''
    'Detected capabilities (facts, not decisions)'
    $capabilityNames = @(Get-WinLeanPropertyNames -InputObject $Analysis.compatibility.capabilities)
    if ($capabilityNames.Count -eq 0) {
        '  none detected'
    }
    foreach ($name in $capabilityNames) {
        Format-WinLeanLabel -Label $name -Value (Format-WinLeanYesNo -Value (Get-WinLeanProperty -InputObject $Analysis.compatibility.capabilities -Name $name))
    }

    ''
    'Compatibility requirements (decisions)'
    Format-WinLeanLabel -Label 'Configuration' -Value (Format-WinLeanCompatibilitySource -Compatibility $Analysis.compatibility -BasePath $BasePath)
    foreach ($suggestion in @($Analysis.suggestions)) {
        '  - ' + $suggestion.message
    }

    $unavailable = @(foreach ($name in @(Get-WinLeanPropertyNames -InputObject $sections)) {
            $section = Get-WinLeanProperty -InputObject $sections -Name $name
            if (-not $section.available -and $section.reason -ne 'Skipped') { "$name ($($section.reason))" }
        })
    if ($unavailable.Count -gt 0) {
        ''
        'Unavailable sections: ' + ($unavailable -join ', ')
    }
    ''
}

function Format-WinLeanCompatibilitySource {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Compatibility,
        [string] $BasePath
    )

    if (-not $Compatibility.exists) {
        return 'not configured - every requirement is treated as required (see Config\Compatibility.example.json)'
    }
    $source = [string]$Compatibility.source
    if ($BasePath) {
        $source = Get-WinLeanRelativePath -Path $source -BasePath $BasePath
    }
    $declaredCount = @(Get-WinLeanPropertyNames -InputObject $Compatibility.declared).Count
    return "$source ($declaredCount declared, $(@($Compatibility.undeclared).Count) undeclared)"
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

function Format-WinLeanPlanText {
    <#
    .SYNOPSIS
        Console rendering of an execution plan (dry run).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Plan,
        [string] $BasePath
    )

    $system = $Plan.system
    $counts = $Plan.summary.counts
    ''
    'WINLEAN PLAN'
    ''
    Format-WinLeanLabel -Label 'Profile' -Value ('{0}  (chain: {1}; maximum risk: {2})' -f $Plan.profile.name, ($Plan.profile.chain -join ' > '), $Plan.profile.maxRisk) -Indent 0 -Width 16
    if ($system) {
        Format-WinLeanLabel -Label 'Windows' -Value ('{0} {1} (build {2}.{3}, {4})' -f $system.productName, $system.displayVersion, $system.build, $system.ubr, $system.architecture) -Indent 0 -Width 16
    }
    $userText = '{0} ({1})' -f $Plan.session.userName, $(if ($Plan.session.isAdministrator) { 'Administrator' } else { 'standard rights' })
    Format-WinLeanLabel -Label 'User' -Value $userText -Indent 0 -Width 16
    if ($Plan.compatibility) {
        Format-WinLeanLabel -Label 'Compatibility' -Value (Format-WinLeanCompatibilitySource -Compatibility $Plan.compatibility -BasePath $BasePath) -Indent 0 -Width 16
    }
    ''
    'Rules: {0}   Apply: {1}   Already satisfied: {2}   Requires confirmation: {3}   Blocked: {4}   Skipped: {5}   Unsupported: {6}' -f `
        $Plan.summary.total, $counts.Applicable, $counts.AlreadySatisfied, $counts.RequiresConfirmation, $counts.Blocked, $counts.Skipped, $counts.Unsupported

    foreach ($status in $script:PlanSections.Keys) {
        $items = @($Plan.items | Where-Object { $_.status -eq $status })
        if ($items.Count -eq 0) { continue }
        ''
        $script:PlanSections[$status]
        $script:Rule
        foreach ($item in $items) {
            $item.ruleId
            '  ' + $item.name
            if ($status -eq 'Applicable') {
                '  Risk: {0}   Reversible: {1}   Reboot: {2}   Takes effect: {3}   Scope: {4} ({5})' -f `
                    $item.risk, (Format-WinLeanYesNo -Value $item.reversible), (Format-WinLeanYesNo -Value $item.requiresReboot), $item.takesEffect, $item.scope, $item.mechanism
                foreach ($resource in @($item.resources | Where-Object { -not $_.inDesiredState })) {
                    '  {0}: {1} -> {2}' -f $resource.target, $resource.currentText, $resource.desiredText
                }
            }
            foreach ($reason in @($item.reasons)) {
                '  Reason: ' + $reason
            }
            foreach ($note in @($item.notes)) {
                '  Note: ' + $note
            }
            ''
        }
    }

    'Reboot required: ' + (Format-WinLeanYesNo -Value $Plan.summary.rebootRequired)
    if ($Plan.summary.signOutRecommended) {
        'Sign out recommended: Yes (some changes take full effect after signing out or restarting File Explorer)'
    }
    $adminItems = @($Plan.summary.administratorRequiredForItems)
    if ($adminItems.Count -gt 0) {
        "Administrator rights: required for $($adminItems.Count) blocked rule(s). Run PowerShell as Administrator to include them."
    }
    foreach ($warning in @($Plan.warnings)) {
        'Warning: ' + $warning
    }
    ''
}

# ---------------------------------------------------------------------------
# Rules and validation
# ---------------------------------------------------------------------------

function Format-WinLeanRuleListText {
    <#
    .SYNOPSIS
        Console table of the rule catalog with profile membership.
    .PARAMETER Membership
        Dictionary rule id -> profile names that include the rule.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rules,
        [System.Collections.IDictionary] $Membership
    )

    ''
    'WINLEAN RULES'
    ''
    $idWidth = [Math]::Max(10, (@($Rules | ForEach-Object { $_.id.Length }) + 0 | Measure-Object -Maximum).Maximum + 2)
    ('{0}{1}{2}{3}{4}' -f 'ID'.PadRight($idWidth), 'RISK'.PadRight(8), 'SCOPE'.PadRight(13), 'KIND'.PadRight(12), 'PROFILES')
    $script:Rule
    foreach ($rule in $Rules) {
        $profiles = ''
        if ($Membership -and (Test-WinLeanDictionaryKey -Dictionary $Membership -Key $rule.id)) {
            $profiles = (@($Membership[$rule.id]) -join ', ')
        }
        ('{0}{1}{2}{3}{4}' -f $rule.id.PadRight($idWidth), $rule.risk.PadRight(8), $rule.scope.PadRight(13), $rule.mechanism.PadRight(12), $(if ($profiles) { $profiles } else { '-' }))
        '  ' + $rule.name
    }
    ''
    "$($Rules.Count) rule(s). Details: Rules\<Category>\<rule-id>.json"
    ''
}

function Format-WinLeanIssueText {
    <#
    .SYNOPSIS
        Console rendering of validation issues.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Issues
    )

    foreach ($issue in $Issues) {
        '[{0}] {1} {2}: {3}' -f $issue.severity.ToUpperInvariant(), $issue.code, $issue.source, $issue.message
    }
}

# ---------------------------------------------------------------------------
# Execution, restore and backups
# ---------------------------------------------------------------------------

function Format-WinLeanExecutionText {
    <#
    .SYNOPSIS
        Console summary after -Apply.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Execution,
        [string] $BasePath
    )

    $summary = $Execution.summary
    ''
    'WINLEAN EXECUTION'
    $script:Rule
    Format-WinLeanLabel -Label 'Status' -Value $Execution.status -Indent 0 -Width 16
    Format-WinLeanLabel -Label 'Rules' -Value ('{0} applied and verified, {1} already satisfied, {2} failed' -f $summary.succeeded, $summary.alreadySatisfied, $summary.failed) -Indent 0 -Width 16
    if ($Execution.backupPath) {
        $backupText = if ($BasePath) { Get-WinLeanRelativePath -Path $Execution.backupPath -BasePath $BasePath } else { $Execution.backupPath }
        Format-WinLeanLabel -Label 'Backup' -Value $backupText -Indent 0 -Width 16
    }
    foreach ($result in @($Execution.results | Where-Object { $_.status -eq 'Failed' })) {
        $rollback = ''
        if ($result.rollback) {
            $rollback = if ($result.rollback.restored) { ' (rolled back)' } else { ' (rollback incomplete)' }
        }
        '  FAILED {0}: {1} - {2}{3}' -f $result.ruleId, $result.failure.class, $result.failure.message, $rollback
    }
    ''
    'Reboot required: ' + (Format-WinLeanYesNo -Value $summary.rebootRequired)
    if ($summary.signOutRecommended) {
        'Sign out (or restart File Explorer) so that every change takes effect.'
    }
    if ($Execution.backupId) {
        "To undo these changes: .\WinLean.ps1 -Restore $($Execution.backupId)"
    }
    ''
}

function Format-WinLeanRestorePlanText {
    <#
    .SYNOPSIS
        Console rendering of a restore plan.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $RestorePlan
    )

    $headings = [ordered]@{
        Restore = 'RESTORE'
        None    = 'ALREADY IN THE PREVIOUS STATE'
        Skip    = 'SKIPPED (CHANGED SINCE WINLEAN APPLIED IT)'
        Blocked = 'BLOCKED'
    }
    ''
    'WINLEAN RESTORE PLAN'
    ''
    Format-WinLeanLabel -Label 'Backup' -Value $RestorePlan.backupId -Indent 0 -Width 16
    Format-WinLeanLabel -Label 'Profile' -Value $RestorePlan.profile -Indent 0 -Width 16
    Format-WinLeanLabel -Label 'Created' -Value ('{0} by {1}' -f (Format-WinLeanTimestamp -Value $RestorePlan.createdAt), $RestorePlan.recordedBy) -Indent 0 -Width 16
    if ($RestorePlan.force) {
        Format-WinLeanLabel -Label 'Mode' -Value '-Force: values changed after WinLean applied them are restored too' -Indent 0 -Width 16
    }
    ''
    'Recorded changes: {0}   Restore: {1}   Already previous: {2}   Skipped: {3}   Blocked: {4}' -f `
        @($RestorePlan.items).Count, $RestorePlan.summary.Restore, $RestorePlan.summary.None, $RestorePlan.summary.Skip, $RestorePlan.summary.Blocked
    foreach ($action in $headings.Keys) {
        $items = @($RestorePlan.items | Where-Object { $_.action -eq $action })
        if ($items.Count -eq 0) { continue }
        ''
        $headings[$action]
        $script:Rule
        foreach ($item in $items) {
            '{0}  ({1})' -f $item.target, $item.ruleId
            if ($action -eq 'Restore') {
                '  now: {0}  ->  restore: {1}' -f $item.currentText, $item.beforeText
            }
            elseif ($action -ne 'None') {
                '  now: {0}   WinLean set: {1}   previous: {2}' -f $item.currentText, $item.desiredText, $item.beforeText
                '  Reason: ' + $item.reason
            }
        }
    }
    ''
}

function Format-WinLeanRestoreResultText {
    <#
    .SYNOPSIS
        Console summary after -Restore.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Result
    )

    $summary = $Result.summary
    ''
    'WINLEAN RESTORE'
    $script:Rule
    Format-WinLeanLabel -Label 'Backup' -Value $Result.backupId -Indent 0 -Width 16
    Format-WinLeanLabel -Label 'Status' -Value $Result.status -Indent 0 -Width 16
    Format-WinLeanLabel -Label 'Values' -Value ('{0} restored and verified, {1} already previous, {2} skipped, {3} blocked, {4} failed' -f `
            $summary.Restored, $summary.NotNeeded, $summary.Skipped, $summary.Blocked, $summary.Failed) -Indent 0 -Width 16
    foreach ($item in @($Result.results | Where-Object { @('Failed', 'Blocked') -contains $_.status })) {
        '  {0} {1}: {2}' -f $item.status.ToUpperInvariant(), $item.target, $item.reason
    }
    if ($Result.status -eq 'Incomplete') {
        'Some values were not restored. Fix the cause and run the restore again; values already restored are skipped.'
    }
    ''
}

function Format-WinLeanBackupListText {
    <#
    .SYNOPSIS
        Console table of backups, newest first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Backups
    )

    ''
    'WINLEAN BACKUPS'
    ''
    if ($Backups.Count -eq 0) {
        'No backups yet. A backup is created by every -Apply run that changes something.'
        ''
        return
    }
    ('{0}{1}{2}{3}{4}' -f 'ID'.PadRight(24), 'PROFILE'.PadRight(16), 'STATUS'.PadRight(24), 'CHANGES'.PadRight(9), 'RESTORE')
    $script:Rule
    foreach ($backup in $Backups) {
        $restore = if ($backup.restoreStatus) { [string]$backup.restoreStatus } else { '-' }
        ('{0}{1}{2}{3}{4}' -f ([string]$backup.id).PadRight(24), ([string]$backup.profile).PadRight(16), ([string]$backup.status).PadRight(24), ([string]$backup.changeCount).PadRight(9), $restore)
    }
    ''
    "'-Restore Latest' restores the newest backup that has not been restored yet."
    ''
}

# ---------------------------------------------------------------------------
# Benchmark
# ---------------------------------------------------------------------------

function Format-WinLeanBenchmarkText {
    <#
    .SYNOPSIS
        Console summary of a benchmark.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Benchmark
    )

    $context = $Benchmark.context
    $power = if ($null -eq $context.onBattery) { 'no battery' } elseif ($context.onBattery) { 'on battery' } else { 'on AC power' }
    ''
    'WINLEAN BENCHMARK'
    $script:Rule
    Format-WinLeanLabel -Label 'Collected' -Value ('{0} (uptime {1} min, {2})' -f (Format-WinLeanTimestamp -Value $Benchmark.collectedAt), $context.uptimeMinutes, $power) -Indent 0 -Width 16
    if ($Benchmark.cpu.available -and $Benchmark.cpu.sampleCount -gt 0) {
        Format-WinLeanLabel -Label 'CPU' -Value ('average {0} %, median {1} %, maximum {2} % ({3} x {4} s samples)' -f `
                (Format-WinLeanNumber -Value $Benchmark.cpu.averagePercent -Decimals 1), (Format-WinLeanNumber -Value $Benchmark.cpu.medianPercent -Decimals 1),
                (Format-WinLeanNumber -Value $Benchmark.cpu.maximumPercent -Decimals 1), $Benchmark.cpu.sampleCount, $Benchmark.cpu.sampleIntervalSeconds) -Indent 0 -Width 16
    }
    else {
        Format-WinLeanLabel -Label 'CPU' -Value 'unavailable' -Indent 0 -Width 16
    }
    $memory = $Benchmark.memory
    $commit = if ($null -ne $memory.committedMB) { '; commit charge {0} MB' -f (Format-WinLeanNumber -Value $memory.committedMB) } else { '' }
    Format-WinLeanLabel -Label 'Memory' -Value ('{0} MB in use of {1} MB ({2} %){3}' -f (Format-WinLeanNumber -Value $memory.inUseMB), (Format-WinLeanNumber -Value $memory.totalMB), (Format-WinLeanNumber -Value $memory.inUsePercent -Decimals 1), $commit) -Indent 0 -Width 16
    Format-WinLeanLabel -Label 'Processes' -Value $Benchmark.processes.count -Indent 0 -Width 16
    if ($Benchmark.services) {
        Format-WinLeanLabel -Label 'Services' -Value ('{0} running, {1} third-party (vendor heuristic)' -f $Benchmark.services.running, $Benchmark.services.runningThirdParty) -Indent 0 -Width 16
    }
    if ($Benchmark.startup) {
        Format-WinLeanLabel -Label 'Startup entries' -Value ('{0} enabled of {1}' -f $Benchmark.startup.enabled, $Benchmark.startup.entries) -Indent 0 -Width 16
    }
    $consumers = @($Benchmark.processes.topCpuConsumers)
    if ($consumers.Count -gt 0) {
        'Top CPU consumers during the sampling window:'
        foreach ($consumer in $consumers) {
            '  {0,-30} {1} %' -f $consumer.name, (Format-WinLeanNumber -Value $consumer.percent -Decimals 1)
        }
    }
    foreach ($note in @($Benchmark.notes)) {
        'Note: ' + $note
    }
    ''
}

# ---------------------------------------------------------------------------
# Markdown report
# ---------------------------------------------------------------------------

function ConvertTo-WinLeanMarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function ConvertTo-WinLeanMarkdownReport {
    <#
    .SYNOPSIS
        Builds the Markdown report of an apply run from its backup.
    .PARAMETER Backup
        A loaded backup (Get-WinLeanBackup): manifest, plan, execution, inventory, benchmarkBefore.
    .PARAMETER BenchmarkAfter
        A benchmark taken after the run (for example after signing out), if any.
    .PARAMETER Restores
        Restore results recorded in the backup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Backup,
        $BenchmarkAfter,
        [object[]] $Restores = @(),
        [string] $BasePath,
        [string] $GeneratedAt = (Get-WinLeanTimestamp)
    )

    $manifest = $Backup.manifest
    $plan = $Backup.plan
    $execution = $Backup.execution
    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    $add = { param([string] $Line = '') $lines.Add($Line) }
    $cell = { param($Value) ConvertTo-WinLeanMarkdownCell -Value $Value }
    $backupPath = if ($BasePath) { Get-WinLeanRelativePath -Path $Backup.path -BasePath $BasePath } else { $Backup.path }
    $status = if ($execution) { $execution.status } else { $manifest.status }

    & $add '# WinLean report'
    & $add
    & $add '| Item | Value |'
    & $add '|---|---|'
    & $add ('| Generated | {0} |' -f (Format-WinLeanTimestamp -Value $GeneratedAt))
    & $add ('| WinLean version | {0} |' -f (& $cell $manifest.winLeanVersion))
    & $add ('| Run / backup id | `{0}` |' -f $Backup.id)
    & $add ('| Profile | {0} |' -f (& $cell $manifest.profile))
    & $add ('| Execution status | {0} |' -f (& $cell $status))
    & $add ('| Backup written | {0} |' -f (Format-WinLeanTimestamp -Value $manifest.createdAt))
    & $add ('| Execution completed | {0} |' -f $(if ($manifest.completedAt) { Format-WinLeanTimestamp -Value $manifest.completedAt } else { 'not recorded' }))

    # System information
    & $add
    & $add '## System information'
    & $add
    & $add '| Property | Value |'
    & $add '|---|---|'
    if ($Backup.inventory) {
        $summary = Get-WinLeanInventorySummary -Inventory $Backup.inventory
        & $add ('| Windows | {0} |' -f (& $cell $summary.windows))
        & $add ('| CPU | {0} |' -f (& $cell $summary.cpu))
        & $add ('| Installed memory | {0} |' -f $(if ($summary.memoryGB) { "$($summary.memoryGB) GB" } else { 'unknown' }))
        & $add ('| GPU | {0} |' -f (& $cell $summary.gpu))
    }
    elseif ($manifest.system) {
        & $add ('| Windows | {0} {1} (build {2}.{3}) |' -f (& $cell $manifest.system.productName), (& $cell $manifest.system.displayVersion), $manifest.system.build, $manifest.system.ubr)
    }
    & $add ('| User | {0} (Administrator: {1}) |' -f (& $cell $manifest.user.name), (Format-WinLeanYesNo -Value $manifest.isAdministrator))

    # Profile
    if ($plan) {
        & $add
        & $add '## Profile'
        & $add
        & $add ('- Name: **{0}** (inheritance: {1})' -f $plan.profile.name, (@($plan.profile.chain) -join ' > '))
        & $add ('- Maximum risk: {0}' -f $plan.profile.maxRisk)
        & $add ('- Rules evaluated: {0}' -f @($plan.items).Count)
        & $add ('- Excluded by the profile: {0}' -f $(if (@($plan.profile.excluded).Count -gt 0) { (@($plan.profile.excluded) | ForEach-Object { '`' + $_ + '`' }) -join ', ' } else { 'none' }))
        if ($plan.options -and $plan.options.allowUntestedBuild) {
            & $add '- `-AllowUntestedBuild` was specified.'
        }

        # Compatibility
        $compatibility = $plan.compatibility
        & $add
        & $add '## Compatibility configuration'
        & $add
        if ($null -eq $compatibility -or -not $compatibility.exists) {
            & $add 'No compatibility configuration was found. Every requirement was treated as required, so rules with compatibility conditions were skipped.'
        }
        else {
            & $add ('Source: `{0}`' -f $(if ($BasePath) { Get-WinLeanRelativePath -Path $compatibility.source -BasePath $BasePath } else { $compatibility.source }))
            & $add
            & $add '| Requirement | Decision |'
            & $add '|---|---|'
            foreach ($key in @(Get-WinLeanPropertyNames -InputObject $compatibility.declared)) {
                $required = [bool](Get-WinLeanProperty -InputObject $compatibility.declared -Name $key)
                & $add ('| {0} | {1} |' -f $key, $(if ($required) { 'required (preserve)' } else { 'not needed' }))
            }
            if (@($compatibility.undeclared).Count -gt 0) {
                & $add
                & $add ('Undeclared (treated as required): {0}' -f (@($compatibility.undeclared) -join ', '))
            }
        }
        $capabilityNames = @()
        if ($compatibility -and $compatibility.capabilities) {
            $capabilityNames = @(Get-WinLeanPropertyNames -InputObject $compatibility.capabilities)
        }
        if ($capabilityNames.Count -gt 0) {
            & $add
            & $add ('Detected capabilities: {0}' -f (($capabilityNames | ForEach-Object { '{0} = {1}' -f $_, (Format-WinLeanYesNo -Value (Get-WinLeanProperty -InputObject $compatibility.capabilities -Name $_)) }) -join ', '))
        }
    }

    # Benchmark
    & $add
    & $add '## Benchmark'
    & $add
    if ($null -eq $Backup.benchmarkBefore) {
        & $add 'No baseline benchmark was recorded for this run (-SkipBenchmark).'
    }
    else {
        $before = $Backup.benchmarkBefore
        & $add ('- Before: {0} (uptime {1} min)' -f (Format-WinLeanTimestamp -Value $before.collectedAt), $before.context.uptimeMinutes)
        if ($null -ne $BenchmarkAfter) {
            & $add ('- After: {0} (uptime {1} min)' -f (Format-WinLeanTimestamp -Value $BenchmarkAfter.collectedAt), $BenchmarkAfter.context.uptimeMinutes)
        }
        else {
            & $add '- After: not captured yet. Sign out (or reboot), let the system settle, run `.\WinLean.ps1 -Benchmark`, then `.\WinLean.ps1 -Report`.'
        }
        & $add
        & $add '| Metric | Before | After | Change |'
        & $add '|---|---:|---:|---:|'
        foreach ($row in @(Compare-WinLeanBenchmark -Before $before -After $BenchmarkAfter)) {
            & $add ('| {0} | {1} | {2} | {3} |' -f $row.metric, $(if ($null -ne $row.before) { $row.before } else { 'n/a' }), $(if ($null -ne $row.after) { $row.after } else { '-' }), $(if ($null -ne $row.change) { $row.change } else { '-' }))
        }
        & $add
        & $add '> A benchmark reflects the moment it was taken. Compare measurements taken under similar conditions (similar uptime, same power source, no user activity); see Docs/Benchmarking.md.'
    }

    # Rules
    $results = if ($execution) { @($execution.results) } else { @() }
    $applied = @($results | Where-Object { $_.status -eq 'Succeeded' })
    & $add
    & $add '## Applied rules'
    & $add
    if ($applied.Count -eq 0) {
        & $add 'No rules were applied.'
    }
    else {
        & $add '| Rule | Name | Result |'
        & $add '|---|---|---|'
        foreach ($result in $applied) {
            $changes = @(for ($index = 0; $index -lt @($result.before).Count; $index++) {
                    $beforeText = @($result.before)[$index].text
                    $afterText = if ($index -lt @($result.after).Count) { @($result.after)[$index].text } else { '?' }
                    '{0}: {1} -> {2}' -f @($result.before)[$index].target, $beforeText, $afterText
                })
            & $add ('| `{0}` | {1} | Applied and verified. {2} |' -f $result.ruleId, (& $cell $result.name), (& $cell ($changes -join '; ')))
        }
    }

    $satisfied = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($result in @($results | Where-Object { $_.status -eq 'AlreadySatisfied' })) { $satisfied.Add($result.ruleId) }
    if ($execution) {
        foreach ($item in @($execution.notApplied | Where-Object { $_.status -eq 'AlreadySatisfied' })) {
            if (-not $satisfied.Contains($item.ruleId)) { $satisfied.Add($item.ruleId) }
        }
    }
    & $add
    & $add '## Already satisfied'
    & $add
    & $add $(if ($satisfied.Count -gt 0) { ($satisfied | ForEach-Object { '- `' + $_ + '`' }) -join "`n" } else { 'None.' })

    $notApplied = if ($execution) { @($execution.notApplied | Where-Object { $_.status -ne 'AlreadySatisfied' }) } else { @() }
    & $add
    & $add '## Skipped, blocked and unsupported rules'
    & $add
    if ($notApplied.Count -eq 0) {
        & $add 'None.'
    }
    else {
        & $add '| Rule | Status | Reason |'
        & $add '|---|---|---|'
        foreach ($item in $notApplied) {
            & $add ('| `{0}` | {1} | {2} |' -f $item.ruleId, $item.status, (& $cell (@($item.reasons) -join ' ')))
        }
    }

    $failed = @($results | Where-Object { $_.status -eq 'Failed' })
    & $add
    & $add '## Failed rules'
    & $add
    if ($failed.Count -eq 0) {
        & $add 'None.'
    }
    else {
        & $add '| Rule | Failure | Details | Rollback |'
        & $add '|---|---|---|---|'
        foreach ($result in $failed) {
            $rollback = if ($null -eq $result.rollback) { 'not needed' } elseif ($result.rollback.restored) { 'rolled back' } else { 'incomplete - restore the backup' }
            & $add ('| `{0}` | {1} | {2} | {3} |' -f $result.ruleId, (& $cell $result.failure.class), (& $cell $result.failure.message), $rollback)
        }
    }

    # Backup and restore
    & $add
    & $add '## Backup and restore'
    & $add
    & $add ('- Backup location: `{0}`' -f $backupPath)
    & $add ('- Recorded changes: {0}' -f $manifest.changeCount)
    & $add ('- Undo this run: `.\WinLean.ps1 -Restore {0}` (preview first with `-WhatIf`)' -f $Backup.id)
    & $add '- WinLean does not create a System Restore point; the backup contains exactly the values WinLean changed.'
    if (@($Restores).Count -gt 0) {
        & $add
        & $add '| Restore run | Status | Restored | Already previous | Skipped | Blocked | Failed |'
        & $add '|---|---|---:|---:|---:|---:|---:|'
        foreach ($restore in $Restores) {
            & $add ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f (Format-WinLeanTimestamp -Value $restore.completedAt), $restore.status, $restore.summary.Restored, $restore.summary.NotNeeded, $restore.summary.Skipped, $restore.summary.Blocked, $restore.summary.Failed)
        }
    }

    # Reboot
    & $add
    & $add '## Reboot requirement'
    & $add
    if ($execution) {
        & $add ('- Reboot required: {0}' -f (Format-WinLeanYesNo -Value $execution.summary.rebootRequired))
        & $add ('- Sign out recommended: {0}' -f $(if ($execution.summary.signOutRecommended) { 'Yes - some changes take full effect after signing out or restarting File Explorer' } else { 'No' }))
    }
    else {
        & $add 'Unknown: the execution record is missing.'
    }
    & $add
    return ($lines.ToArray() -join "`n")
}

Export-ModuleMember -Function @(
    'Format-WinLeanAnalysisText'
    'Format-WinLeanPlanText'
    'Format-WinLeanRuleListText'
    'Format-WinLeanIssueText'
    'Format-WinLeanCompatibilitySource'
    'Format-WinLeanYesNo'
    'Format-WinLeanExecutionText'
    'Format-WinLeanRestorePlanText'
    'Format-WinLeanRestoreResultText'
    'Format-WinLeanBackupListText'
    'Format-WinLeanBenchmarkText'
    'ConvertTo-WinLeanMarkdownReport'
)
