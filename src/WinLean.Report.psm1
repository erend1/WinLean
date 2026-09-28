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

Export-ModuleMember -Function @(
    'Format-WinLeanAnalysisText'
    'Format-WinLeanPlanText'
    'Format-WinLeanRuleListText'
    'Format-WinLeanIssueText'
    'Format-WinLeanCompatibilitySource'
    'Format-WinLeanYesNo'
)
