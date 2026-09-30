#Requires -Version 5.1
<#
    WinLean.Policy
    --------------
    Profiles and the policy engine.

    The policy engine turns (profile, rule catalog, compatibility context, current system
    state) into an explicit execution plan. It never modifies the system. Every rule in
    the profile ends up with exactly one status:

      Applicable            will be applied by -Apply
      AlreadySatisfied      the system is already in the desired state (nothing to do)
      Skipped               a compatibility condition is not met or not declared
      Blocked               cannot be applied now: missing access rights, unmet dependency,
                            conflict, unreadable or unrestorable current state
      RequiresConfirmation  needs an explicit override (for example -AllowUntestedBuild)
      Unsupported           not supported on this Windows build, edition or installation
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Providers\WinLean.Providers.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Validation.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Rules.psm1')

$script:PlanStatuses = @('Applicable', 'AlreadySatisfied', 'Skipped', 'Blocked', 'RequiresConfirmation', 'Unsupported')
$script:MaximumProfileDepth = 10

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

function Resolve-WinLeanProfilePath {
    <#
    .SYNOPSIS
        Resolves a profile name (Profiles/<name>.json) or an explicit path to a .json file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ProfileDirectory
    )

    $looksLikePath = $Name.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase) -or $Name.Contains('\') -or $Name.Contains('/')
    if ($looksLikePath) {
        return Resolve-WinLeanPath -Path $Name
    }
    if (-not (Test-WinLeanPattern -Text $Name -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*$' -CaseSensitive)) {
        throw (New-Object -TypeName System.ArgumentException -ArgumentList "Invalid profile name '$Name'. Use a name from the Profiles folder or a path to a .json file.")
    }
    return Join-Path -Path (Resolve-WinLeanPath -Path $ProfileDirectory) -ChildPath ($Name + '.json')
}

function Import-WinLeanProfile {
    <#
    .SYNOPSIS
        Loads a profile and resolves its inheritance chain.
    .PARAMETER Name
        A profile name from the profile directory (Safe, Lean, ...) or a path to a .json file.
        Parent profiles ('extends') are always resolved from the profile directory, or from
        the folder of an explicitly given file.
    .OUTPUTS
        WinLean.Profile with the resolved, ordered rule list. Throws on invalid profiles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ProfileDirectory
    )

    $path = Resolve-WinLeanProfilePath -Name $Name -ProfileDirectory $ProfileDirectory
    $chain = New-Object -TypeName System.Collections.Generic.List[object]
    $visited = New-WinLeanDictionary
    $currentPath = $path
    while ($true) {
        if (-not [System.IO.File]::Exists($currentPath)) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Profile not found: $currentPath", $currentPath)
        }
        if ($visited.ContainsKey($currentPath)) {
            throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Profile inheritance cycle detected at '$currentPath'.")
        }
        if ($chain.Count -ge $script:MaximumProfileDepth) {
            throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Profile inheritance is deeper than $($script:MaximumProfileDepth) levels.")
        }
        $visited[$currentPath] = $true

        $definition = Read-WinLeanJsonFile -Path $currentPath
        $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($currentPath)
        $issues = @(Test-WinLeanProfileDefinition -Definition $definition -Source $currentPath -ExpectedName $expectedName)
        $errors = @($issues | Where-Object { $_.severity -eq 'Error' })
        if ($errors.Count -gt 0) {
            $details = ($errors | ForEach-Object { $_.message }) -join ' '
            throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Invalid profile '$currentPath': $details")
        }
        $chain.Insert(0, [pscustomobject]@{ path = $currentPath; definition = $definition })

        $parent = Get-WinLeanProperty -InputObject $definition -Name 'extends'
        if ($null -eq $parent) {
            break
        }
        $currentPath = Join-Path -Path ([System.IO.Path]::GetDirectoryName($currentPath)) -ChildPath ($parent + '.json')
    }

    # Apply the chain from the root profile to the requested one.
    $ruleIds = New-Object -TypeName System.Collections.Generic.List[string]
    $excluded = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($link in $chain) {
        $own = @(Get-WinLeanArrayProperty -InputObject $link.definition -Name 'rules')
        $exclude = @(Get-WinLeanArrayProperty -InputObject $link.definition -Name 'exclude')
        foreach ($id in $exclude) {
            if ($own -ccontains $id) {
                throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Profile '$($link.path)' both includes and excludes '$id'.")
            }
            if ($ruleIds.Remove($id) -and -not $excluded.Contains($id)) {
                $excluded.Add($id)
            }
        }
        foreach ($id in $own) {
            if (-not $ruleIds.Contains($id)) {
                $ruleIds.Add($id)
            }
            [void]$excluded.Remove($id)
        }
    }

    $leaf = $chain[$chain.Count - 1].definition
    return [pscustomobject]@{
        PSTypeName        = 'WinLean.Profile'
        name              = [string]$leaf.name
        description       = [string]$leaf.description
        source            = $path
        chain             = [string[]]@($chain | ForEach-Object { [string]$_.definition.name })
        ruleIds           = $ruleIds.ToArray()
        excluded          = $excluded.ToArray()
        maxRisk           = [string]$leaf.maxRisk
        allowIrreversible = [bool](Get-WinLeanProperty -InputObject $leaf -Name 'allowIrreversible' -Default $false)
    }
}

function Test-WinLeanProfileRules {
    <#
    .SYNOPSIS
        Checks a resolved profile against the rule catalog: unknown rule ids, rules above
        the profile's maximum risk and irreversible rules that are not allowed.
    .OUTPUTS
        WinLean.Issue objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Profile')] $Profile,
        [Parameter(Mandatory)] [PSTypeName('WinLean.RuleCatalog')] $Catalog
    )

    $maxRank = Get-WinLeanRiskRank -Risk $Profile.maxRisk
    foreach ($id in $Profile.ruleIds) {
        if (-not $Catalog.rules.ContainsKey($id)) {
            New-WinLeanIssue -Severity Error -Code 'UnknownRule' -Source $Profile.name -Message "Profile '$($Profile.name)' references unknown rule '$id'."
            continue
        }
        $rule = $Catalog.rules[$id]
        if ((Get-WinLeanRiskRank -Risk $rule.risk) -gt $maxRank) {
            New-WinLeanIssue -Severity Error -Code 'RiskTooHigh' -Source $Profile.name -Message "Rule '$id' has risk $($rule.risk), above the profile maximum $($Profile.maxRisk)."
        }
        if (-not $rule.reversible -and -not $Profile.allowIrreversible) {
            New-WinLeanIssue -Severity Error -Code 'Irreversible' -Source $Profile.name -Message "Rule '$id' is irreversible and the profile does not allow irreversible rules."
        }
    }
    foreach ($id in $Profile.excluded) {
        if (-not $Catalog.rules.ContainsKey($id)) {
            New-WinLeanIssue -Severity Warning -Code 'UnknownRule' -Source $Profile.name -Message "Excluded rule '$id' is not a known rule."
        }
    }
}

# ---------------------------------------------------------------------------
# Dependency ordering
# ---------------------------------------------------------------------------

function Get-WinLeanDependencyOrder {
    <#
    .SYNOPSIS
        Orders rule ids so that dependencies come first. Ties keep the input order.
    .PARAMETER Rules
        Normalized rules (id, dependencies). Dependencies outside the list are ignored.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rules
    )

    $ids = New-Object -TypeName System.Collections.Generic.List[string]
    $pending = New-WinLeanDictionary
    foreach ($rule in $Rules) {
        if ($pending.ContainsKey($rule.id)) { continue }
        $ids.Add($rule.id)
        $pending[$rule.id] = @($rule.dependencies)
    }

    $emitted = New-WinLeanDictionary
    $order = New-Object -TypeName System.Collections.Generic.List[string]
    while ($order.Count -lt $ids.Count) {
        $progress = $false
        foreach ($id in $ids) {
            if ($emitted.ContainsKey($id)) { continue }
            $ready = $true
            foreach ($dependency in $pending[$id]) {
                if ($pending.ContainsKey($dependency) -and -not $emitted.ContainsKey($dependency)) {
                    $ready = $false
                    break
                }
            }
            if ($ready) {
                $emitted[$id] = $true
                $order.Add($id)
                $progress = $true
                break
            }
        }
        if (-not $progress) {
            $remaining = @($ids | Where-Object { -not $emitted.ContainsKey($_) })
            throw (New-Object -TypeName System.InvalidOperationException -ArgumentList ("Dependency cycle between rules: " + ($remaining -join ', ')))
        }
    }
    $order.ToArray()
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

function New-WinLeanPlanContext {
    <#
    .SYNOPSIS
        Bundles everything the policy engine needs besides the profile and catalog.
    .PARAMETER PerUserTarget
        Match when the process identity owns the desktop session, Mismatch when it does not
        (per-user settings would change another profile), Unknown when undetermined.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Facts,
        [Parameter(Mandatory)] [bool] $IsAdministrator,
        [ValidateSet('Match', 'Mismatch', 'Unknown')] [string] $PerUserTarget = 'Unknown',
        [string] $UserName,
        $Platform,
        $Compatibility,
        [string[]] $Warnings = @(),
        [switch] $AllowUntestedBuild
    )

    return [pscustomobject]@{
        PSTypeName         = 'WinLean.PlanContext'
        facts              = $Facts
        isAdministrator    = $IsAdministrator
        perUserTarget      = $PerUserTarget
        userName           = $UserName
        platform           = $Platform
        compatibility      = $Compatibility
        warnings           = $Warnings
        allowUntestedBuild = [bool]$AllowUntestedBuild
    }
}

function New-WinLeanPlanItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule)

    return [pscustomobject]@{
        ruleId                = $Rule.id
        name                  = $Rule.name
        category              = $Rule.category
        description           = $Rule.description
        risk                  = $Rule.risk
        reversible            = $Rule.reversible
        requiresReboot        = $Rule.requiresReboot
        takesEffect           = $Rule.takesEffect
        scope                 = $Rule.scope
        mechanism             = $Rule.mechanism
        dependencies          = $Rule.dependencies
        status                = $null
        reasons               = New-Object -TypeName System.Collections.Generic.List[string]
        notes                 = New-Object -TypeName System.Collections.Generic.List[string]
        requiresAdministrator = $false
        untestedBuild         = $false
        resources             = @()
    }
}

function Test-WinLeanItemsConflict {
    <#
    .SYNOPSIS
        Returns a description of the conflict between two rules, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Left,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Right
    )

    if ($Left.conflicts -ccontains $Right.id -or $Right.conflicts -ccontains $Left.id) {
        return "declared conflict with '$($Right.id)'"
    }
    foreach ($leftResource in $Left.resources) {
        $leftInfo = Get-WinLeanResourceInfo -Resource $leftResource
        foreach ($rightResource in $Right.resources) {
            $rightInfo = Get-WinLeanResourceInfo -Resource $rightResource
            if ($leftInfo.identity -cne $rightInfo.identity) { continue }
            if (-not (Test-WinLeanResourceDesiredStateEqual -Left $leftResource -Right $rightResource)) {
                return "'$($Right.id)' sets $($leftInfo.target) to a different value"
            }
        }
    }
    return $null
}

function New-WinLeanPlan {
    <#
    .SYNOPSIS
        Evaluates every rule of a profile and produces the execution plan (dry run).
    .DESCRIPTION
        1. platform support (build, edition, installation type)      -> Unsupported
        2. compatibility conditions                                   -> Skipped
        3. current state (read-only)                                  -> AlreadySatisfied / Blocked
           resources that do not exist on this system                 -> Unsupported
        4. conflicts between the remaining rules                      -> Blocked
        5. dependencies, in dependency order                          -> Blocked
        6. per-user target and write access                           -> Blocked
        7. untested Windows build without -AllowUntestedBuild         -> RequiresConfirmation
        Everything else is Applicable. Nothing is modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Profile')] $Profile,
        [Parameter(Mandatory)] [PSTypeName('WinLean.RuleCatalog')] $Catalog,
        [Parameter(Mandatory)] [PSTypeName('WinLean.PlanContext')] $Context
    )

    $unknown = @($Profile.ruleIds | Where-Object { -not $Catalog.rules.ContainsKey($_) })
    if ($unknown.Count -gt 0) {
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Profile '$($Profile.name)' references unknown rules: $($unknown -join ', ').")
    }

    $facts = $Context.facts
    $build = if (Test-WinLeanDictionaryKey -Dictionary $facts -Key 'system.build') { $facts['system.build'] } else { $null }
    $items = New-WinLeanDictionary
    $rules = @(foreach ($id in $Profile.ruleIds) { $Catalog.rules[$id] })

    # 1-3: applicability and current state, rule by rule.
    foreach ($rule in $rules) {
        $item = New-WinLeanPlanItem -Rule $rule
        $items[$rule.id] = $item

        $applicability = Test-WinLeanRuleApplicable -Rule $rule -Facts $facts
        foreach ($reason in $applicability.reasons) { $item.reasons.Add($reason) }
        if ($applicability.status -ne 'Applicable') {
            $item.status = $applicability.status
            continue
        }
        $item.untestedBuild = [bool]$applicability.untestedBuild

        try {
            $state = Get-WinLeanRuleState -Rule $rule -IncludeAccess
        }
        catch {
            $failure = ConvertTo-WinLeanFailure -ErrorObject $_
            $item.status = 'Blocked'
            $item.reasons.Add("The current state could not be read ($($failure.class)): $($failure.message)")
            continue
        }
        $item.resources = $state.resources
        if ($state.inDesiredState) {
            $item.status = 'AlreadySatisfied'
            continue
        }
        if (-not $state.available) {
            $item.status = 'Unsupported'
            foreach ($resource in @($state.resources | Where-Object { -not $_.available -and -not $_.inDesiredState })) {
                $reason = if ($resource.note) { $resource.note } else { "$($resource.target) does not exist on this system ($($resource.currentText))." }
                $item.reasons.Add($reason)
            }
            continue
        }
        if (-not $state.restorable) {
            $item.status = 'Blocked'
            foreach ($resource in @($state.resources | Where-Object { -not $_.restorable })) {
                $reason = "The current value of $($resource.target) ($($resource.currentText)) cannot be captured losslessly, so WinLean will not modify it."
                if ($resource.note) {
                    $reason = "$reason $($resource.note)"
                }
                $item.reasons.Add($reason)
            }
            continue
        }
        $item.status = 'Candidate'
    }

    # 4: conflicts between rules that are (or would be) in effect.
    $active = @($rules | Where-Object { @('Candidate', 'AlreadySatisfied') -contains $items[$_.id].status })
    for ($left = 0; $left -lt $active.Count; $left++) {
        for ($right = $left + 1; $right -lt $active.Count; $right++) {
            $leftRule = $active[$left]
            $rightRule = $active[$right]
            $conflict = Test-WinLeanItemsConflict -Left $leftRule -Right $rightRule
            if ($conflict) {
                $items[$leftRule.id].status = 'Blocked'
                $items[$leftRule.id].reasons.Add("Conflict: $conflict. Remove one of the two rules from the profile.")
                $items[$rightRule.id].status = 'Blocked'
                $items[$rightRule.id].reasons.Add("Conflict: " + (Test-WinLeanItemsConflict -Left $rightRule -Right $leftRule) + '. Remove one of the two rules from the profile.')
            }
        }
    }

    # 5-7: dependencies (dependencies first), access and build validation.
    $order = @(Get-WinLeanDependencyOrder -Rules $rules)
    foreach ($id in $order) {
        $item = $items[$id]
        if ($item.status -ne 'Candidate') { continue }
        $rule = $Catalog.rules[$id]

        foreach ($dependency in $rule.dependencies) {
            if ($items.ContainsKey($dependency)) {
                $dependencyStatus = $items[$dependency].status
                if (@('Applicable', 'AlreadySatisfied') -notcontains $dependencyStatus) {
                    $item.status = 'Blocked'
                    $item.reasons.Add("Dependency '$dependency' is $dependencyStatus.")
                }
                continue
            }
            $satisfied = $false
            if ($Catalog.rules.ContainsKey($dependency)) {
                try {
                    $satisfied = (Get-WinLeanRuleState -Rule $Catalog.rules[$dependency]).inDesiredState
                }
                catch {
                    $satisfied = $false
                }
            }
            if ($satisfied) {
                $item.notes.Add("Dependency '$dependency' is not in the profile but is already satisfied on this system.")
            }
            else {
                $item.status = 'Blocked'
                $item.reasons.Add("Dependency '$dependency' is not part of the profile and is not satisfied on this system.")
            }
        }
        if ($item.status -ne 'Candidate') { continue }

        if ($Context.perUserTarget -eq 'Mismatch' -and $rule.scope -ne 'Machine') {
            $item.status = 'Blocked'
            $item.reasons.Add("WinLean runs as '$($Context.userName)', which is not the account signed in to this desktop. Per-user settings would change the wrong user profile; run WinLean from the account you want to configure.")
            continue
        }

        $denied = @($item.resources | Where-Object { -not $_.inDesiredState -and $_.writable -eq $false })
        if ($denied.Count -gt 0) {
            $item.status = 'Blocked'
            $targets = ($denied | ForEach-Object { $_.target }) -join ', '
            if ($Context.isAdministrator) {
                $item.reasons.Add("Access denied to $targets, even with Administrator rights.")
            }
            else {
                $item.requiresAdministrator = $true
                $item.reasons.Add("Requires Administrator: no write access to $targets. Run WinLean from an elevated PowerShell to apply this rule.")
            }
            continue
        }

        if ($item.untestedBuild) {
            $message = "Windows build $build is newer than the newest build this rule was validated on ($($rule.windows.maxValidatedBuild))."
            if ($Context.allowUntestedBuild) {
                $item.notes.Add("$message Included because -AllowUntestedBuild was specified.")
            }
            else {
                $item.status = 'RequiresConfirmation'
                $item.reasons.Add("$message Re-run with -AllowUntestedBuild to include it.")
                continue
            }
        }
        $item.status = 'Applicable'
    }

    # Assemble the plan in dependency order.
    $planItems = @(foreach ($id in $order) {
            $item = $items[$id]
            [pscustomobject]@{
                ruleId                = $item.ruleId
                name                  = $item.name
                category              = $item.category
                description           = $item.description
                status                = $item.status
                reasons               = $item.reasons.ToArray()
                notes                 = $item.notes.ToArray()
                risk                  = $item.risk
                reversible            = $item.reversible
                requiresReboot        = $item.requiresReboot
                takesEffect           = $item.takesEffect
                scope                 = $item.scope
                mechanism             = $item.mechanism
                requiresAdministrator = $item.requiresAdministrator
                untestedBuild         = $item.untestedBuild
                dependencies          = $item.dependencies
                resources             = @($item.resources)
            }
        })

    $warnings = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($warning in @($Context.warnings)) {
        if ($warning) { $warnings.Add($warning) }
    }
    $applicable = @($planItems | Where-Object { $_.status -eq 'Applicable' })
    $partOfDomain = if (Test-WinLeanDictionaryKey -Dictionary $facts -Key 'system.partOfDomain') { [bool]$facts['system.partOfDomain'] } else { $false }
    $policyItems = @($applicable | Where-Object { @($_.resources | Where-Object { $_.mechanism -ceq 'Policy' }).Count -gt 0 })
    if ($partOfDomain -and $policyItems.Count -gt 0) {
        $warnings.Add('This device is joined to a domain. Organizational Group Policy may override or conflict with policy-based settings.')
    }

    return [pscustomobject]@{
        PSTypeName     = 'WinLean.Plan'
        schemaVersion  = 1
        createdAt      = Get-WinLeanTimestamp
        winLeanVersion = Get-WinLeanVersion
        profile        = [pscustomobject]@{
            name     = $Profile.name
            source   = $Profile.source
            chain    = $Profile.chain
            maxRisk  = $Profile.maxRisk
            ruleIds  = $Profile.ruleIds
            excluded = $Profile.excluded
        }
        system         = $Context.platform
        session        = [pscustomobject]@{
            userName        = $Context.userName
            isAdministrator = $Context.isAdministrator
            perUserTarget   = $Context.perUserTarget
        }
        compatibility  = $Context.compatibility
        options        = [pscustomobject]@{ allowUntestedBuild = $Context.allowUntestedBuild }
        items          = $planItems
        summary        = Get-WinLeanPlanSummary -Items $planItems
        warnings       = $warnings.ToArray()
    }
}

function Get-WinLeanPlanSummary {
    <#
    .SYNOPSIS
        Counts plan items per status and derives the reboot / sign-out / elevation needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Items
    )

    $counts = [ordered]@{}
    foreach ($status in $script:PlanStatuses) {
        $counts[$status] = @($Items | Where-Object { $_.status -eq $status }).Count
    }
    $applicable = @($Items | Where-Object { $_.status -eq 'Applicable' })
    return [pscustomobject]@{
        total                         = $Items.Count
        counts                        = [pscustomobject]$counts
        rebootRequired                = (@($applicable | Where-Object { $_.requiresReboot }).Count -gt 0)
        signOutRecommended            = (@($applicable | Where-Object { @('SignOut', 'ExplorerRestart') -contains $_.takesEffect }).Count -gt 0)
        administratorRequiredForItems = @($Items | Where-Object { $_.requiresAdministrator } | ForEach-Object { $_.ruleId })
    }
}

function Get-WinLeanPlanStatuses {
    <#
    .SYNOPSIS
        Lists the plan statuses in display order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:PlanStatuses
}

Export-ModuleMember -Function @(
    'Resolve-WinLeanProfilePath'
    'Import-WinLeanProfile'
    'Test-WinLeanProfileRules'
    'Get-WinLeanDependencyOrder'
    'New-WinLeanPlanContext'
    'New-WinLeanPlan'
    'Get-WinLeanPlanSummary'
    'Get-WinLeanPlanStatuses'
)
