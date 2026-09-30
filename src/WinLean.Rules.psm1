#Requires -Version 5.1
<#
    WinLean.Rules
    -------------
    Rule catalog loading and the rule interface.

    A rule is a reviewed JSON document in Rules/<Category>/<rule-id>.json. It declares
    metadata (risk, reversibility, supported builds, documentation) and one or more
    declarative resources. Rules never contain code: every operation below is carried out
    by the resource providers (see Providers/WinLean.Providers.psm1).

    Rule interface (conceptual name -> function):

      Test-Applicable -> Test-WinLeanRuleApplicable   platform, build, edition, conditions
      Get-State       -> Get-WinLeanRuleState         current vs desired state per resource
      Apply           -> Set-WinLeanRuleState         change what is not yet in desired state
      Verify          -> Confirm-WinLeanRuleState     re-read and compare (never assume)
      Undo            -> Undo-WinLeanRuleState        write captured state back and verify
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Providers\WinLean.Providers.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Validation.psm1')

# WinLean 0.1 supports Windows 11 client installations only.
$script:MinimumWindowsBuild = 22000

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------

function Import-WinLeanRuleCatalog {
    <#
    .SYNOPSIS
        Loads, validates and normalizes every rule file below a directory.
    .OUTPUTS
        WinLean.RuleCatalog with rules (dictionary id -> rule), ruleIds (sorted),
        issues and errorCount. Rules with errors are not included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string[]] $KnownRequirementKeys
    )

    $root = Resolve-WinLeanPath -Path $Path
    if (-not [System.IO.Directory]::Exists($root)) {
        throw (New-Object -TypeName System.IO.DirectoryNotFoundException -ArgumentList "Rules directory not found: $root")
    }

    $files = [System.IO.Directory]::GetFiles($root, '*.json', [System.IO.SearchOption]::AllDirectories)
    [System.Array]::Sort($files, [System.StringComparer]::OrdinalIgnoreCase)

    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    $rules = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $relativePath = Get-WinLeanRelativePath -Path $file -BasePath $root
        try {
            $definition = Read-WinLeanJsonFile -Path $file
        }
        catch {
            $issues.Add((New-WinLeanIssue -Severity Error -Code 'RuleParse' -Source $relativePath -Message $_.Exception.Message))
            continue
        }
        $ruleIssues = @(Test-WinLeanRuleDefinition -Definition $definition -SourcePath $relativePath -KnownRequirementKeys $KnownRequirementKeys)
        foreach ($issue in $ruleIssues) {
            $issues.Add($issue)
        }
        if (@($ruleIssues | Where-Object { $_.severity -eq 'Error' }).Count -gt 0) {
            continue
        }
        $rules.Add((ConvertTo-WinLeanRule -Definition $definition -SourcePath $relativePath))
    }

    foreach ($issue in @(Test-WinLeanRuleCatalog -Rules $rules.ToArray())) {
        $issues.Add($issue)
    }

    $byId = New-WinLeanDictionary
    foreach ($rule in $rules) {
        if (-not $byId.ContainsKey($rule.id)) {
            $byId[$rule.id] = $rule
        }
    }
    $ruleIds = [string[]]@($byId.Keys)
    [System.Array]::Sort($ruleIds, [System.StringComparer]::Ordinal)

    return [pscustomobject]@{
        PSTypeName = 'WinLean.RuleCatalog'
        path       = $root
        rules      = $byId
        ruleIds    = $ruleIds
        issues     = $issues.ToArray()
        errorCount = @($issues | Where-Object { $_.severity -eq 'Error' }).Count
    }
}

function ConvertTo-WinLeanRule {
    <#
    .SYNOPSIS
        Converts a validated rule definition into the normalized rule object used by the engine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Definition,
        [string] $SourcePath
    )

    $resources = @(foreach ($resource in @(Get-WinLeanArrayProperty -InputObject $Definition -Name 'resources')) {
            ConvertTo-WinLeanResource -Definition $resource
        })
    $scopes = New-Object -TypeName System.Collections.Generic.List[string]
    $mechanisms = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($resource in $resources) {
        $info = Get-WinLeanResourceInfo -Resource $resource
        if (-not $scopes.Contains($info.scope)) { $scopes.Add($info.scope) }
        if (-not $mechanisms.Contains($info.mechanism)) { $mechanisms.Add($info.mechanism) }
    }

    $windows = $Definition.windows
    $maxBuild = Get-WinLeanProperty -InputObject $windows -Name 'maxBuild'
    $normalizedWindows = [pscustomobject]@{
        minBuild          = [int]$windows.minBuild
        maxBuild          = if ($null -eq $maxBuild) { $null } else { [int]$maxBuild }
        maxValidatedBuild = [int]$windows.maxValidatedBuild
        editions          = [string[]]@(Get-WinLeanArrayProperty -InputObject $windows -Name 'editions')
    }

    $conditions = @(foreach ($condition in @(Get-WinLeanArrayProperty -InputObject $Definition -Name 'conditions')) {
            [pscustomobject]@{
                fact     = [string]$condition.fact
                operator = [string]$condition.operator
                value    = (Get-WinLeanProperty -InputObject $condition -Name 'value' -NoEnumerate)
                reason   = [string](Get-WinLeanProperty -InputObject $condition -Name 'reason' -Default '')
            }
        })

    $references = @(foreach ($reference in @(Get-WinLeanArrayProperty -InputObject $Definition -Name 'references')) {
            [pscustomobject]@{ title = [string]$reference.title; url = [string]$reference.url }
        })

    return [pscustomobject]@{
        PSTypeName     = 'WinLean.Rule'
        id             = [string]$Definition.id
        name           = [string]$Definition.name
        category       = [string]$Definition.category
        description    = [string]$Definition.description
        rationale      = [string]$Definition.rationale
        risk           = [string]$Definition.risk
        reversible     = [bool]$Definition.reversible
        requiresReboot = [bool]$Definition.requiresReboot
        takesEffect    = [string]$Definition.takesEffect
        windows        = $normalizedWindows
        conditions     = $conditions
        dependencies   = [string[]]@(Get-WinLeanArrayProperty -InputObject $Definition -Name 'dependencies')
        conflicts      = [string[]]@(Get-WinLeanArrayProperty -InputObject $Definition -Name 'conflicts')
        effects        = [string[]]@(Get-WinLeanArrayProperty -InputObject $Definition -Name 'effects')
        sideEffects    = [string[]]@(Get-WinLeanArrayProperty -InputObject $Definition -Name 'sideEffects')
        notes          = [string[]]@(Get-WinLeanArrayProperty -InputObject $Definition -Name 'notes')
        references     = $references
        tags           = [string[]]@(Get-WinLeanArrayProperty -InputObject $Definition -Name 'tags')
        resources      = $resources
        scope          = if ($scopes.Count -eq 1) { $scopes[0] } else { 'Mixed' }
        mechanism      = if ($mechanisms.Count -eq 1) { $mechanisms[0] } else { 'Mixed' }
        sourcePath     = $SourcePath
    }
}

function Get-WinLeanCatalogRule {
    <#
    .SYNOPSIS
        Returns a rule by id, or throws when the id is unknown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.RuleCatalog')] $Catalog,
        [Parameter(Mandatory)] [string] $Id
    )

    if (-not $Catalog.rules.ContainsKey($Id)) {
        throw (New-WinLeanException -Class Unsupported -Message "Unknown rule id '$Id'.")
    }
    return $Catalog.rules[$Id]
}

function Get-WinLeanRuleFactNames {
    <#
    .SYNOPSIS
        Lists the facts referenced by the conditions of the given rules.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rules
    )

    $names = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($rule in $Rules) {
        foreach ($condition in $rule.conditions) {
            if (-not $names.Contains($condition.fact)) {
                $names.Add($condition.fact)
            }
        }
    }
    $names.ToArray()
}

# ---------------------------------------------------------------------------
# Conditions
# ---------------------------------------------------------------------------

function Test-WinLeanFactValueEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $Actual,
        [AllowNull()] $Expected
    )

    if ($null -eq $Actual -or $null -eq $Expected) {
        return $false
    }
    if ($Actual -is [bool] -or $Expected -is [bool]) {
        return ($Actual -is [bool] -and $Expected -is [bool] -and $Actual -eq $Expected)
    }
    if ($Actual -is [string] -or $Expected -is [string]) {
        return ($Actual -is [string] -and $Expected -is [string] -and (Test-WinLeanTextEqual -Left $Actual -Right $Expected))
    }
    try {
        return ([decimal]$Actual -eq [decimal]$Expected)
    }
    catch {
        return $false
    }
}

function Format-WinLeanFactValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return 'unknown' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if (Test-WinLeanEnumerable -Value $Value) {
        return '[' + ((@($Value) | ForEach-Object { Format-WinLeanFactValue -Value $_ }) -join ', ') + ']'
    }
    return [string]$Value
}

function Test-WinLeanCondition {
    <#
    .SYNOPSIS
        Evaluates one rule condition against a fact dictionary.
    .OUTPUTS
        Object with result 'True', 'False' or 'Unknown' and an explanatory message.
    .NOTES
        A fact that is not known (for example an undeclared compatibility requirement)
        yields 'Unknown'. The policy engine treats Unknown like False: the rule is skipped.
        Undeclared requirements are therefore treated as "required", which is the safe
        default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Condition,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Facts
    )

    $fact = [string]$Condition.fact
    $operator = [string]$Condition.operator
    $expected = Get-WinLeanProperty -InputObject $Condition -Name 'value' -NoEnumerate
    $reason = [string](Get-WinLeanProperty -InputObject $Condition -Name 'reason' -Default '')
    $actual = $null
    if (Test-WinLeanDictionaryKey -Dictionary $Facts -Key $fact) {
        $actual = $Facts[$fact]
    }

    $separator = $fact.IndexOf('.')
    $namespace = $fact.Substring(0, $separator)
    $key = $fact.Substring($separator + 1)

    if ($null -eq $actual) {
        $message = switch ($namespace) {
            'requirement' { "Compatibility requirement '$key' is not declared. WinLean treats undeclared requirements as required, so this rule is skipped. Declare '$key' in the compatibility configuration to decide." }
            'capability' { "Capability '$key' could not be detected, so this rule is skipped." }
            default { "System fact '$key' is unavailable, so this rule is skipped." }
        }
        return [pscustomobject]@{ result = 'Unknown'; fact = $fact; operator = $operator; expected = $expected; actual = $null; message = $message }
    }

    $satisfied = $false
    switch -CaseSensitive ($operator) {
        'Equals' { $satisfied = Test-WinLeanFactValueEqual -Actual $actual -Expected $expected }
        'NotEquals' {
            $comparable = ($actual -is [bool]) -eq ($expected -is [bool]) -and ($actual -is [string]) -eq ($expected -is [string])
            $satisfied = $comparable -and -not (Test-WinLeanFactValueEqual -Actual $actual -Expected $expected)
        }
        'In' {
            foreach ($item in @($expected)) {
                if (Test-WinLeanFactValueEqual -Actual $actual -Expected $item) { $satisfied = $true; break }
            }
        }
        'NotIn' {
            $satisfied = $true
            foreach ($item in @($expected)) {
                if (Test-WinLeanFactValueEqual -Actual $actual -Expected $item) { $satisfied = $false; break }
            }
        }
        'GreaterOrEqual' {
            try { $satisfied = ($actual -isnot [bool] -and [decimal]$actual -ge [decimal]$expected) } catch { $satisfied = $false }
        }
        'LessOrEqual' {
            try { $satisfied = ($actual -isnot [bool] -and [decimal]$actual -le [decimal]$expected) } catch { $satisfied = $false }
        }
        default { $satisfied = $false }
    }

    if ($satisfied) {
        $message = "$fact $operator $(Format-WinLeanFactValue -Value $expected)"
        return [pscustomobject]@{ result = 'True'; fact = $fact; operator = $operator; expected = $expected; actual = $actual; message = $message }
    }
    $message = if ($reason) { $reason } else { "Condition not met: $fact $operator $(Format-WinLeanFactValue -Value $expected)" }
    $message = "$message (actual: $(Format-WinLeanFactValue -Value $actual))"
    return [pscustomobject]@{ result = 'False'; fact = $fact; operator = $operator; expected = $expected; actual = $actual; message = $message }
}

# ---------------------------------------------------------------------------
# Rule interface
# ---------------------------------------------------------------------------

function Test-WinLeanRuleApplicable {
    <#
    .SYNOPSIS
        Test-Applicable: evaluates platform support and compatibility conditions.
        Does not read or change system state.
    .OUTPUTS
        status: Applicable, Unsupported or Skipped; reasons; untestedBuild (the build is
        newer than the newest build the rule was validated on); conditionResults.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Facts
    )

    $reasons = New-Object -TypeName System.Collections.Generic.List[string]
    $build = $null
    if (Test-WinLeanDictionaryKey -Dictionary $Facts -Key 'system.build') { $build = $Facts['system.build'] }
    $installationType = $null
    if (Test-WinLeanDictionaryKey -Dictionary $Facts -Key 'system.installationType') { $installationType = [string]$Facts['system.installationType'] }
    $editionId = $null
    if (Test-WinLeanDictionaryKey -Dictionary $Facts -Key 'system.editionId') { $editionId = [string]$Facts['system.editionId'] }

    if ($installationType -cne 'Client') {
        $reasons.Add("WinLean supports Windows 11 client installations only (installation type: $(Format-WinLeanFactValue -Value $installationType)).")
    }
    elseif ($null -eq $build) {
        $reasons.Add('The Windows build number could not be determined.')
    }
    elseif ([int]$build -lt $script:MinimumWindowsBuild) {
        $reasons.Add("WinLean requires Windows 11 (build $($script:MinimumWindowsBuild) or later); this system is build $build.")
    }
    elseif ([int]$build -lt $Rule.windows.minBuild) {
        $reasons.Add("Requires Windows build $($Rule.windows.minBuild) or later; this system is build $build.")
    }
    elseif ($null -ne $Rule.windows.maxBuild -and [int]$build -gt $Rule.windows.maxBuild) {
        $reasons.Add("Not supported after Windows build $($Rule.windows.maxBuild); this system is build $build.")
    }
    elseif ($Rule.windows.editions.Count -gt 0 -and $Rule.windows.editions -notcontains $editionId) {
        $reasons.Add("Only effective on Windows editions $($Rule.windows.editions -join ', '); this system is '$editionId'.")
    }

    if ($reasons.Count -gt 0) {
        return [pscustomobject]@{ status = 'Unsupported'; reasons = $reasons.ToArray(); untestedBuild = $false; conditionResults = @() }
    }

    $conditionResults = @(foreach ($condition in $Rule.conditions) {
            Test-WinLeanCondition -Condition $condition -Facts $Facts
        })
    foreach ($conditionResult in $conditionResults) {
        if ($conditionResult.result -ne 'True') {
            $reasons.Add($conditionResult.message)
        }
    }
    $status = if ($reasons.Count -gt 0) { 'Skipped' } else { 'Applicable' }
    return [pscustomobject]@{
        status           = $status
        reasons          = $reasons.ToArray()
        untestedBuild    = ([int]$build -gt $Rule.windows.maxValidatedBuild)
        conditionResults = $conditionResults
    }
}

function Get-WinLeanRuleState {
    <#
    .SYNOPSIS
        Get-State: reads the current state of every resource of a rule and compares it
        with the desired state.
    .PARAMETER IncludeAccess
        Also probes (without modifying anything) whether each resource can be written.
    .NOTES
        Errors reading state are not caught here; callers classify them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [switch] $IncludeAccess
    )

    $resourceStates = New-Object -TypeName System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $Rule.resources.Count; $index++) {
        $resource = $Rule.resources[$index]
        $info = Get-WinLeanResourceInfo -Resource $resource
        $current = Get-WinLeanResourceState -Resource $resource
        $desired = Get-WinLeanResourceDesiredState -Resource $resource
        $writable = $null
        if ($IncludeAccess) {
            $writable = [bool](Test-WinLeanResourceAccess -Resource $resource)
        }
        $resourceStates.Add([pscustomobject]@{
                index          = $index
                type           = $resource.type
                identity       = $info.identity
                target         = $info.target
                scope          = $info.scope
                mechanism      = $info.mechanism
                current        = $current
                desired        = $desired
                currentText    = Format-WinLeanResourceState -Type $resource.type -State $current
                desiredText    = Format-WinLeanResourceState -Type $resource.type -State $desired
                inDesiredState = [bool](Test-WinLeanResourceStateEqual -Type $resource.type -Expected $desired -Actual $current)
                restorable     = [bool](Test-WinLeanResourceStateRestorable -Type $resource.type -State $current)
                available      = [bool](Test-WinLeanResourceStateAvailable -State $current)
                note           = [string](Get-WinLeanProperty -InputObject $current -Name 'note' -Default '')
                writable       = $writable
            })
    }

    $states = $resourceStates.ToArray()
    $writableStates = @($states | Where-Object { $null -ne $_.writable })
    return [pscustomobject]@{
        ruleId         = $Rule.id
        inDesiredState = (@($states | Where-Object { -not $_.inDesiredState }).Count -eq 0)
        restorable     = (@($states | Where-Object { -not $_.restorable }).Count -eq 0)
        # Resources that do not exist on this system and are not already in their desired
        # state: the rule cannot be applied here.
        available      = (@($states | Where-Object { -not $_.available -and -not $_.inDesiredState }).Count -eq 0)
        writable       = if ($IncludeAccess) { (@($writableStates | Where-Object { -not $_.writable }).Count -eq 0) } else { $null }
        resources      = $states
    }
}

function Join-WinLeanRebootRequirement {
    <#
    .SYNOPSIS
        Combines the reboot requirements reported for several changed resources.
    .OUTPUTS
        $true when any change needs a restart, $false when every change reported that it
        does not, $null when at least one provider did not report (unknown).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Values = @())

    if ($Values.Count -eq 0) {
        return $null
    }
    $unknown = $false
    foreach ($value in $Values) {
        if ($value -is [bool] -and $value) {
            return $true
        }
        if ($value -isnot [bool]) {
            $unknown = $true
        }
    }
    if ($unknown) {
        return $null
    }
    return $false
}

function Set-WinLeanRuleState {
    <#
    .SYNOPSIS
        Apply: puts every resource that is not in its desired state into it.
    .PARAMETER State
        The state captured immediately before (Get-WinLeanRuleState). Resources already in
        their desired state are not touched, which keeps repeated runs idempotent.
    .OUTPUTS
        Object listing the indexes of the resources that were written and whether the
        providers reported that a restart is needed (rebootRequired: $true, $false or
        $null when unknown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] $State
    )

    $changed = New-Object -TypeName System.Collections.Generic.List[int]
    $reboot = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($resourceState in $State.resources) {
        if ($resourceState.inDesiredState) {
            continue
        }
        $result = Set-WinLeanResource -Resource $Rule.resources[$resourceState.index]
        $changed.Add($resourceState.index)
        $reboot.Add($result.rebootRequired)
    }
    return [pscustomobject]@{
        ruleId           = $Rule.id
        changedResources = $changed.ToArray()
        rebootRequired   = Join-WinLeanRebootRequirement -Values $reboot.ToArray()
    }
}

function Confirm-WinLeanRuleState {
    <#
    .SYNOPSIS
        Verify: re-reads every resource and compares it with the desired state.
        Success is never assumed from the absence of errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule
    )

    $state = Get-WinLeanRuleState -Rule $Rule
    $mismatches = @(foreach ($resourceState in $state.resources) {
            if (-not $resourceState.inDesiredState) {
                "$($resourceState.target): expected $($resourceState.desiredText), found $($resourceState.currentText)"
            }
        })
    return [pscustomobject]@{
        ruleId     = $Rule.id
        verified   = ($mismatches.Count -eq 0)
        state      = $state
        mismatches = [string[]]$mismatches
    }
}

function Undo-WinLeanRuleState {
    <#
    .SYNOPSIS
        Undo: writes the captured state of every resource back (in reverse order) and
        verifies the result.
    .PARAMETER BeforeState
        The state captured before the rule was applied (Get-WinLeanRuleState output).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] $BeforeState
    )

    $mismatches = New-Object -TypeName System.Collections.Generic.List[string]
    $reboot = New-Object -TypeName System.Collections.Generic.List[object]
    $captured = @($BeforeState.resources)
    for ($position = $captured.Count - 1; $position -ge 0; $position--) {
        $before = $captured[$position]
        $resource = $Rule.resources[$before.index]
        try {
            $current = Get-WinLeanResourceState -Resource $resource
            if (-not (Test-WinLeanResourceStateEqual -Type $resource.type -Expected $before.current -Actual $current)) {
                $result = Restore-WinLeanResource -Resource $resource -State $before.current
                $reboot.Add($result.rebootRequired)
                $current = Get-WinLeanResourceState -Resource $resource
            }
            if (-not (Test-WinLeanResourceStateEqual -Type $resource.type -Expected $before.current -Actual $current)) {
                $mismatches.Add("$($before.target): expected $($before.currentText), found $(Format-WinLeanResourceState -Type $resource.type -State $current)")
            }
        }
        catch {
            $mismatches.Add("$($before.target): $($_.Exception.Message)")
        }
    }
    return [pscustomobject]@{
        ruleId         = $Rule.id
        restored       = ($mismatches.Count -eq 0)
        mismatches     = $mismatches.ToArray()
        rebootRequired = Join-WinLeanRebootRequirement -Values $reboot.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Import-WinLeanRuleCatalog'
    'ConvertTo-WinLeanRule'
    'Get-WinLeanCatalogRule'
    'Get-WinLeanRuleFactNames'
    'Test-WinLeanCondition'
    'Test-WinLeanRuleApplicable'
    'Get-WinLeanRuleState'
    'Join-WinLeanRebootRequirement'
    'Set-WinLeanRuleState'
    'Confirm-WinLeanRuleState'
    'Undo-WinLeanRuleState'
)
