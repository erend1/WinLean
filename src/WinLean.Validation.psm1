#Requires -Version 5.1
<#
    WinLean.Validation
    ------------------
    Structural and semantic validation of rule, profile and compatibility files.

    This module is the authoritative validator. The JSON Schema files in Schemas/ exist
    for editor support (completion and inline errors) and are kept consistent with this
    module by unit tests.

    Validation reports issues; it never throws for invalid input. Each issue has a
    severity (Error or Warning), a stable code, a source (file or rule id) and a message.
    Anything that is an Error prevents WinLean from using the file.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Providers\WinLean.Providers.psm1')

$script:SchemaVersion = 1

# Rule categories and the rule-id prefix each category uses (rules live in Rules/<Category>/).
$script:Categories = [ordered]@{
    Applications    = 'apps'
    Startup         = 'startup'
    Services        = 'services'
    ScheduledTasks  = 'tasks'
    Privacy         = 'privacy'
    Recommendations = 'recommendations'
    Features        = 'features'
    Gaming          = 'gaming'
    Explorer        = 'explorer'
    Search          = 'search'
    Networking      = 'networking'
    Power           = 'power'
    Security        = 'security'
    Development     = 'development'
    ThirdParty      = 'thirdparty'
}

$script:RiskLevels = @('Low', 'Medium', 'High')
$script:TakesEffectValues = @('Immediately', 'ExplorerRestart', 'SignOut', 'Reboot')
$script:ConditionOperators = @('Equals', 'NotEquals', 'In', 'NotIn', 'GreaterOrEqual', 'LessOrEqual')

# WinLean targets Windows 11 client editions; no rule may declare support below this build.
$script:MinimumWindowsBuild = 22000

$script:RuleProperties = @(
    '$schema', 'schemaVersion', 'id', 'name', 'category', 'description', 'rationale', 'risk',
    'reversible', 'requiresReboot', 'takesEffect', 'windows', 'conditions', 'dependencies',
    'conflicts', 'effects', 'sideEffects', 'notes', 'references', 'evidence', 'resources', 'tags'
)
$script:WindowsProperties = @('minBuild', 'maxBuild', 'maxValidatedBuild', 'editions')
$script:ConditionProperties = @('fact', 'operator', 'value', 'reason')
$script:ReferenceProperties = @('title', 'url')

# Recorded observations (evidence standard, see Docs/Rules.md). An observation shows what
# the Settings app writes when a toggle changes, captured in a disposable VM.
$script:EvidenceProperties = @('method', 'build', 'file', 'summary')
$script:EvidenceMethods = @('RegistryDiff', 'ProcessMonitor')
$script:EvidenceFilePattern = '^Docs/Evidence/[A-Za-z0-9][A-Za-z0-9._-]*\.md$'
$script:ProfileProperties = @('$schema', 'schemaVersion', 'name', 'description', 'extends', 'rules', 'exclude', 'maxRisk', 'allowIrreversible')
$script:CompatibilityProperties = @('$schema', 'schemaVersion', 'description', 'requirements')

$script:RuleIdPattern = '^[a-z][a-z0-9]*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*)+$'
$script:FactPattern = '^(?:requirement|capability|system)\.[A-Za-z][A-Za-z0-9]*$'
$script:ProfileNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$script:TagPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'

# ---------------------------------------------------------------------------
# Public metadata
# ---------------------------------------------------------------------------

function Get-WinLeanRuleCategories {
    <#
    .SYNOPSIS
        Returns the rule categories with their rule-id prefixes.
    #>
    [CmdletBinding()]
    param()

    foreach ($name in $script:Categories.Keys) {
        [pscustomobject]@{ category = $name; prefix = $script:Categories[$name] }
    }
}

function Get-WinLeanRiskLevels {
    <#
    .SYNOPSIS
        Returns the risk levels, lowest first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:RiskLevels
}

function Get-WinLeanRiskRank {
    <#
    .SYNOPSIS
        Returns 0 for Low, 1 for Medium, 2 for High (-1 for unknown values).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()] [string] $Risk)

    return [System.Array]::IndexOf($script:RiskLevels, $Risk)
}

function New-WinLeanIssue {
    <#
    .SYNOPSIS
        Creates a validation issue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Error', 'Warning')] [string] $Severity,
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Source,
        [Parameter(Mandatory)] [string] $Message
    )

    return [pscustomobject]@{
        PSTypeName = 'WinLean.Issue'
        severity   = $Severity
        code       = $Code
        source     = $Source
        message    = $Message
    }
}

# ---------------------------------------------------------------------------
# Small typed checks (return $true when valid)
# ---------------------------------------------------------------------------

function Test-WinLeanNonEmptyString {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Test-WinLeanInteger {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }
    if ($Value -is [int] -or $Value -is [long]) {
        return $true
    }
    if ($Value -is [decimal] -or $Value -is [double]) {
        return ([System.Math]::Truncate($Value) -eq $Value -and [System.Math]::Abs([double]$Value) -lt 2147483648)
    }
    return $false
}

function Test-WinLeanStringArray {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $Value,
        [int] $MinimumCount = 0,
        [string] $Pattern
    )

    if (-not (Test-WinLeanEnumerable -Value $Value)) {
        return $false
    }
    $count = 0
    foreach ($item in $Value) {
        if (-not (Test-WinLeanNonEmptyString -Value $item)) {
            return $false
        }
        if ($Pattern -and -not (Test-WinLeanPattern -Text $item -Pattern $Pattern -CaseSensitive)) {
            return $false
        }
        $count++
    }
    return ($count -ge $MinimumCount)
}

function Test-WinLeanObject {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $Value)

    return ($null -ne $Value -and $Value -isnot [string] -and $Value -isnot [ValueType] -and -not (Test-WinLeanEnumerable -Value $Value))
}

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

function Test-WinLeanRuleDefinition {
    <#
    .SYNOPSIS
        Validates one rule definition (the parsed content of a rule file).
    .PARAMETER SourcePath
        Path of the rule file relative to the Rules directory, for example
        'Privacy\privacy.advertising-id.disable.json'. When given, the folder must match
        the category and the file name must match the rule id.
    .PARAMETER KnownRequirementKeys
        Compatibility requirement keys that conditions may reference. When omitted,
        requirement keys are not checked.
    .OUTPUTS
        WinLean.Issue objects. Nothing is emitted for a valid rule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Definition,
        [string] $SourcePath,
        [string[]] $KnownRequirementKeys
    )

    $id = Get-WinLeanProperty -InputObject $Definition -Name 'id'
    $source = if ($SourcePath) { $SourcePath } elseif ($id -is [string]) { $id } else { '<rule>' }
    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    $addError = {
        param([string] $Code, [string] $Message)
        $issues.Add((New-WinLeanIssue -Severity Error -Code $Code -Source $source -Message $Message))
    }

    if (-not (Test-WinLeanObject -Value $Definition)) {
        & $addError 'RuleSchema' 'A rule file must contain a single JSON object.'
        return $issues.ToArray()
    }

    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Definition)) {
        if ($script:RuleProperties -cnotcontains $propertyName) {
            & $addError 'UnknownProperty' "Unknown property '$propertyName'. Allowed: $($script:RuleProperties -join ', ')."
        }
    }

    $schemaVersion = Get-WinLeanProperty -InputObject $Definition -Name 'schemaVersion'
    if (-not (Test-WinLeanInteger -Value $schemaVersion) -or [int]$schemaVersion -ne $script:SchemaVersion) {
        & $addError 'SchemaVersion' "'schemaVersion' must be $($script:SchemaVersion)."
    }

    # Identity and classification
    $idIsValid = ($id -is [string] -and (Test-WinLeanPattern -Text $id -Pattern $script:RuleIdPattern -CaseSensitive))
    if (-not $idIsValid) {
        & $addError 'RuleId' "'id' must be a lowercase dotted identifier such as 'privacy.advertising-id.disable'."
    }
    $category = Get-WinLeanProperty -InputObject $Definition -Name 'category'
    $categoryIsValid = ($category -is [string] -and @($script:Categories.Keys) -ccontains $category)
    if (-not $categoryIsValid) {
        & $addError 'Category' "'category' must be one of: $(@($script:Categories.Keys) -join ', ')."
    }
    if ($idIsValid -and $categoryIsValid) {
        $prefix = $script:Categories[$category] + '.'
        if (-not $id.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            & $addError 'RuleIdPrefix' "Rules in category '$category' must have an id starting with '$prefix'."
        }
    }

    foreach ($field in @('name', 'description', 'rationale')) {
        if (-not (Test-WinLeanNonEmptyString -Value (Get-WinLeanProperty -InputObject $Definition -Name $field))) {
            & $addError 'RequiredField' "'$field' must be a non-empty string."
        }
    }

    $risk = Get-WinLeanProperty -InputObject $Definition -Name 'risk'
    if ($script:RiskLevels -cnotcontains $risk) {
        & $addError 'Risk' "'risk' must be one of: $($script:RiskLevels -join ', ')."
    }

    $reversible = Get-WinLeanProperty -InputObject $Definition -Name 'reversible'
    if ($reversible -isnot [bool]) {
        & $addError 'RequiredField' "'reversible' must be true or false."
    }
    $requiresReboot = Get-WinLeanProperty -InputObject $Definition -Name 'requiresReboot'
    if ($requiresReboot -isnot [bool]) {
        & $addError 'RequiredField' "'requiresReboot' must be true or false."
    }
    $takesEffect = Get-WinLeanProperty -InputObject $Definition -Name 'takesEffect'
    if ($script:TakesEffectValues -cnotcontains $takesEffect) {
        & $addError 'TakesEffect' "'takesEffect' must be one of: $($script:TakesEffectValues -join ', ')."
    }
    elseif ($requiresReboot -is [bool] -and ($requiresReboot -ne ($takesEffect -ceq 'Reboot'))) {
        & $addError 'TakesEffect' "'requiresReboot' must be true exactly when 'takesEffect' is 'Reboot'."
    }

    # Supported Windows builds and editions
    $windows = Get-WinLeanProperty -InputObject $Definition -Name 'windows'
    foreach ($message in @(Test-WinLeanWindowsSupport -Windows $windows)) {
        & $addError 'Windows' $message
    }

    # Conditions
    $conditions = Get-WinLeanProperty -InputObject $Definition -Name 'conditions' -NoEnumerate
    if (-not (Test-WinLeanEnumerable -Value $conditions)) {
        & $addError 'Conditions' "'conditions' must be an array (use [] for none)."
    }
    else {
        $index = 0
        foreach ($condition in $conditions) {
            foreach ($message in @(Test-WinLeanConditionDefinition -Condition $condition -KnownRequirementKeys $KnownRequirementKeys)) {
                & $addError 'Conditions' "conditions[$index]: $message"
            }
            $index++
        }
    }

    # Dependencies and conflicts
    foreach ($field in @('dependencies', 'conflicts')) {
        $value = Get-WinLeanProperty -InputObject $Definition -Name $field -NoEnumerate
        if (-not (Test-WinLeanStringArray -Value $value -Pattern $script:RuleIdPattern)) {
            & $addError 'References' "'$field' must be an array of rule ids (use [] for none)."
        }
        elseif ($idIsValid -and @($value) -ccontains $id) {
            & $addError 'References' "A rule cannot list itself in '$field'."
        }
    }

    # Documentation
    foreach ($field in @('effects', 'sideEffects')) {
        if (-not (Test-WinLeanStringArray -Value (Get-WinLeanProperty -InputObject $Definition -Name $field -NoEnumerate) -MinimumCount 1)) {
            & $addError 'Documentation' "'$field' must be an array with at least one non-empty string."
        }
    }
    if (Test-WinLeanProperty -InputObject $Definition -Name 'notes') {
        if (-not (Test-WinLeanStringArray -Value (Get-WinLeanProperty -InputObject $Definition -Name 'notes' -NoEnumerate))) {
            & $addError 'Documentation' "'notes' must be an array of non-empty strings."
        }
    }
    # Sources: documentation references and/or recorded observations (evidence standard).
    $references = Get-WinLeanProperty -InputObject $Definition -Name 'references' -NoEnumerate
    $referenceCount = 0
    if (-not (Test-WinLeanEnumerable -Value $references)) {
        & $addError 'References' "'references' must be an array (use [] when the rule relies on recorded evidence only)."
    }
    else {
        $index = 0
        foreach ($reference in $references) {
            foreach ($message in @(Test-WinLeanReferenceDefinition -Reference $reference)) {
                & $addError 'References' "references[$index]: $message"
            }
            $index++
        }
        $referenceCount = $index
    }
    $evidenceCount = 0
    $newestObservedBuild = 0
    if (Test-WinLeanProperty -InputObject $Definition -Name 'evidence') {
        $evidence = Get-WinLeanProperty -InputObject $Definition -Name 'evidence' -NoEnumerate
        if (-not (Test-WinLeanEnumerable -Value $evidence)) {
            & $addError 'Evidence' "'evidence' must be an array of recorded observations."
        }
        else {
            $index = 0
            foreach ($observation in $evidence) {
                foreach ($message in @(Test-WinLeanEvidenceDefinition -Evidence $observation)) {
                    & $addError 'Evidence' "evidence[$index]: $message"
                }
                $build = Get-WinLeanProperty -InputObject $observation -Name 'build'
                if ((Test-WinLeanInteger -Value $build) -and [int]$build -gt $newestObservedBuild) {
                    $newestObservedBuild = [int]$build
                }
                $index++
            }
            $evidenceCount = $index
        }
    }
    if ($referenceCount + $evidenceCount -lt 1) {
        & $addError 'References' "A rule needs at least one source: a reference that documents the setting, or a recorded observation in 'evidence' (see Docs/Rules.md)."
    }
    if (Test-WinLeanProperty -InputObject $Definition -Name 'tags') {
        if (-not (Test-WinLeanStringArray -Value (Get-WinLeanProperty -InputObject $Definition -Name 'tags' -NoEnumerate) -Pattern $script:TagPattern)) {
            & $addError 'Tags' "'tags' must be an array of lowercase words separated by hyphens."
        }
    }

    # Resources
    $resources = Get-WinLeanProperty -InputObject $Definition -Name 'resources' -NoEnumerate
    if (-not (Test-WinLeanEnumerable -Value $resources) -or @($resources).Count -lt 1) {
        & $addError 'Resources' "'resources' must contain at least one resource."
    }
    else {
        $index = 0
        foreach ($resource in $resources) {
            foreach ($message in @(Test-WinLeanResourceDefinition -Definition $resource)) {
                & $addError 'Resources' "resources[$index]: $message"
            }
            $index++
        }
        # Every resource type in 0.1 is declarative and restorable from captured state.
        if ($reversible -is [bool] -and -not $reversible) {
            & $addError 'Reversible' "Declarative resources are always restored from captured state; 'reversible' must be true."
        }

        # Observations can only establish what a user-facing toggle writes: rules without a
        # documentation reference may only change per-user preferences, and are validated
        # only up to the newest build on which the behaviour was observed.
        if ($referenceCount -eq 0 -and $evidenceCount -gt 0) {
            foreach ($resource in $resources) {
                $path = [string](Get-WinLeanProperty -InputObject $resource -Name 'path' -Default '')
                if (-not $path.StartsWith('HKCU:\', [System.StringComparison]::OrdinalIgnoreCase) -or
                    (Test-WinLeanTextContains -Text ($path + '\') -Value '\Policies\')) {
                    & $addError 'Evidence' "Rules without a documentation reference may only change per-user preferences (HKCU, outside \Policies\); '$path' needs a documented source."
                }
            }
            $maxValidated = Get-WinLeanProperty -InputObject $windows -Name 'maxValidatedBuild'
            if ((Test-WinLeanInteger -Value $maxValidated) -and $newestObservedBuild -gt 0 -and [int]$maxValidated -gt $newestObservedBuild) {
                & $addError 'Evidence' "'windows.maxValidatedBuild' ($maxValidated) is newer than the newest observed build ($newestObservedBuild)."
            }
        }
    }

    # File location
    if ($SourcePath -and $idIsValid -and $categoryIsValid) {
        $fileName = [System.IO.Path]::GetFileName($SourcePath)
        $folder = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($SourcePath))
        if ($fileName -cne ($id + '.json')) {
            & $addError 'Location' "The file must be named '$id.json'."
        }
        if ($folder -cne $category) {
            & $addError 'Location' "The file must be located in the Rules\$category folder."
        }
    }

    return $issues.ToArray()
}

function Test-WinLeanWindowsSupport {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Windows)

    if (-not (Test-WinLeanObject -Value $Windows)) {
        "'windows' must be an object with 'minBuild' and 'maxValidatedBuild'."
        return
    }
    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Windows)) {
        if ($script:WindowsProperties -cnotcontains $propertyName) {
            "unknown property 'windows.$propertyName'"
        }
    }
    $minBuild = Get-WinLeanProperty -InputObject $Windows -Name 'minBuild'
    $maxValidated = Get-WinLeanProperty -InputObject $Windows -Name 'maxValidatedBuild'
    $maxBuild = Get-WinLeanProperty -InputObject $Windows -Name 'maxBuild'
    if (-not (Test-WinLeanInteger -Value $minBuild) -or [int]$minBuild -lt $script:MinimumWindowsBuild) {
        "'windows.minBuild' must be an integer of at least $($script:MinimumWindowsBuild) (Windows 11)."
        return
    }
    if (-not (Test-WinLeanInteger -Value $maxValidated) -or [int]$maxValidated -lt [int]$minBuild) {
        "'windows.maxValidatedBuild' must be an integer not lower than 'minBuild'."
    }
    if ($null -ne $maxBuild) {
        if (-not (Test-WinLeanInteger -Value $maxBuild) -or [int]$maxBuild -lt [int]$minBuild) {
            "'windows.maxBuild' must be null or an integer not lower than 'minBuild'."
        }
        elseif ((Test-WinLeanInteger -Value $maxValidated) -and [int]$maxValidated -gt [int]$maxBuild) {
            "'windows.maxValidatedBuild' cannot be higher than 'windows.maxBuild'."
        }
    }
    if (Test-WinLeanProperty -InputObject $Windows -Name 'editions') {
        if (-not (Test-WinLeanStringArray -Value (Get-WinLeanProperty -InputObject $Windows -Name 'editions' -NoEnumerate) -MinimumCount 1 -Pattern '^[A-Za-z0-9]+$')) {
            "'windows.editions' must be a non-empty array of EditionID values such as 'Enterprise'."
        }
    }
}

function Test-WinLeanConditionDefinition {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] $Condition,
        [string[]] $KnownRequirementKeys
    )

    if (-not (Test-WinLeanObject -Value $Condition)) {
        'a condition must be an object with fact, operator and value'
        return
    }
    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Condition)) {
        if ($script:ConditionProperties -cnotcontains $propertyName) {
            "unknown property '$propertyName'"
        }
    }
    $fact = Get-WinLeanProperty -InputObject $Condition -Name 'fact'
    $operator = Get-WinLeanProperty -InputObject $Condition -Name 'operator'
    if ($fact -isnot [string] -or -not (Test-WinLeanPattern -Text $fact -Pattern $script:FactPattern -CaseSensitive)) {
        "'fact' must look like 'requirement.printer', 'capability.bluetoothAdapter' or 'system.editionId'"
    }
    if ($script:ConditionOperators -cnotcontains $operator) {
        "'operator' must be one of: $($script:ConditionOperators -join ', ')"
        return
    }
    if (-not (Test-WinLeanProperty -InputObject $Condition -Name 'value')) {
        "'value' is required"
        return
    }
    $value = Get-WinLeanProperty -InputObject $Condition -Name 'value' -NoEnumerate
    if ($operator -ceq 'In' -or $operator -ceq 'NotIn') {
        if (-not (Test-WinLeanEnumerable -Value $value) -or @($value).Count -lt 1) {
            "'value' must be a non-empty array for operator '$operator'"
        }
    }
    elseif ($operator -ceq 'GreaterOrEqual' -or $operator -ceq 'LessOrEqual') {
        if ($null -eq $value -or $value -is [bool] -or -not ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal])) {
            "'value' must be a number for operator '$operator'"
        }
    }
    elseif ($null -eq $value -or (Test-WinLeanEnumerable -Value $value) -or (Test-WinLeanObject -Value $value)) {
        "'value' must be a single boolean, number or string for operator '$operator'"
    }

    if ($fact -is [string] -and $fact.StartsWith('requirement.', [System.StringComparison]::Ordinal)) {
        $key = $fact.Substring('requirement.'.Length)
        if (($operator -ceq 'Equals' -or $operator -ceq 'NotEquals') -and $value -isnot [bool]) {
            "requirements are booleans; use true or false as the value"
        }
        if ($KnownRequirementKeys -and $KnownRequirementKeys -cnotcontains $key) {
            "unknown compatibility requirement '$key' (see Schemas/compatibility.schema.json)"
        }
    }
    if ((Test-WinLeanProperty -InputObject $Condition -Name 'reason') -and -not (Test-WinLeanNonEmptyString -Value (Get-WinLeanProperty -InputObject $Condition -Name 'reason'))) {
        "'reason' must be a non-empty string when present"
    }
}

function Test-WinLeanReferenceDefinition {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Reference)

    if (-not (Test-WinLeanObject -Value $Reference)) {
        'a reference must be an object with title and url'
        return
    }
    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Reference)) {
        if ($script:ReferenceProperties -cnotcontains $propertyName) {
            "unknown property '$propertyName'"
        }
    }
    if (-not (Test-WinLeanNonEmptyString -Value (Get-WinLeanProperty -InputObject $Reference -Name 'title'))) {
        "'title' must be a non-empty string"
    }
    $url = Get-WinLeanProperty -InputObject $Reference -Name 'url'
    if ($url -isnot [string] -or -not $url.StartsWith('https://', [System.StringComparison]::Ordinal)) {
        "'url' must be an https:// URL"
    }
}

function Test-WinLeanEvidenceDefinition {
    <#
    .SYNOPSIS
        Validates one recorded observation: method, build, evidence file and summary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Evidence)

    if (-not (Test-WinLeanObject -Value $Evidence)) {
        'an evidence record must be an object with method, build, file and summary'
        return
    }
    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Evidence)) {
        if ($script:EvidenceProperties -cnotcontains $propertyName) {
            "unknown property '$propertyName'"
        }
    }
    if ($script:EvidenceMethods -cnotcontains (Get-WinLeanProperty -InputObject $Evidence -Name 'method')) {
        "'method' must be one of: $($script:EvidenceMethods -join ', ')"
    }
    $build = Get-WinLeanProperty -InputObject $Evidence -Name 'build'
    if (-not (Test-WinLeanInteger -Value $build) -or [int]$build -lt $script:MinimumWindowsBuild) {
        "'build' must be the Windows build the observation was made on ($($script:MinimumWindowsBuild) or later)"
    }
    $file = Get-WinLeanProperty -InputObject $Evidence -Name 'file'
    if ($file -isnot [string] -or -not (Test-WinLeanPattern -Text $file -Pattern $script:EvidenceFilePattern -CaseSensitive)) {
        "'file' must be a Markdown file in Docs/Evidence, for example 'Docs/Evidence/<rule-id>.md'"
    }
    if (-not (Test-WinLeanNonEmptyString -Value (Get-WinLeanProperty -InputObject $Evidence -Name 'summary'))) {
        "'summary' must describe what was observed"
    }
}

function Test-WinLeanRuleCatalog {
    <#
    .SYNOPSIS
        Cross-rule validation of normalized rules: duplicate ids, unknown or cyclic
        dependencies, contradictory declarations and undeclared resource conflicts.
    .OUTPUTS
        WinLean.Issue objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rules
    )

    $byId = New-WinLeanDictionary
    foreach ($rule in $Rules) {
        if ($byId.ContainsKey($rule.id)) {
            New-WinLeanIssue -Severity Error -Code 'DuplicateRuleId' -Source $rule.sourcePath -Message "Rule id '$($rule.id)' is also defined in '$($byId[$rule.id].sourcePath)'."
            continue
        }
        $byId[$rule.id] = $rule
    }

    foreach ($rule in $byId.Values) {
        foreach ($dependency in $rule.dependencies) {
            if (-not $byId.ContainsKey($dependency)) {
                New-WinLeanIssue -Severity Error -Code 'UnknownDependency' -Source $rule.id -Message "Dependency '$dependency' is not a known rule."
            }
            if ($rule.conflicts -ccontains $dependency) {
                New-WinLeanIssue -Severity Error -Code 'ContradictoryReferences' -Source $rule.id -Message "'$dependency' is listed both as a dependency and as a conflict."
            }
        }
        foreach ($conflict in $rule.conflicts) {
            if (-not $byId.ContainsKey($conflict)) {
                New-WinLeanIssue -Severity Error -Code 'UnknownConflict' -Source $rule.id -Message "Conflict '$conflict' is not a known rule."
            }
        }
    }

    $cycle = @(Find-WinLeanDependencyCycle -Rules @($byId.Values))
    if ($cycle.Count -gt 0) {
        New-WinLeanIssue -Severity Error -Code 'DependencyCycle' -Source $cycle[0] -Message ('Dependency cycle: ' + ($cycle -join ' -> '))
    }

    # Two rules that set the same resource to different values must declare the conflict.
    $targets = New-WinLeanDictionary
    foreach ($rule in $byId.Values) {
        foreach ($resource in $rule.resources) {
            $identity = (Get-WinLeanResourceInfo -Resource $resource).identity
            $desired = Get-WinLeanResourceDesiredState -Resource $resource
            if (-not $targets.ContainsKey($identity)) {
                $targets[$identity] = New-Object -TypeName System.Collections.Generic.List[object]
            }
            foreach ($other in $targets[$identity]) {
                $differs = -not (Test-WinLeanResourceStateEqual -Type $resource.type -Expected $other.desired -Actual $desired)
                $declared = ($rule.conflicts -ccontains $other.rule.id) -or ($other.rule.conflicts -ccontains $rule.id)
                if ($differs -and -not $declared) {
                    New-WinLeanIssue -Severity Warning -Code 'UndeclaredConflict' -Source $rule.id -Message "Sets '$identity' differently from '$($other.rule.id)' but neither rule declares the conflict."
                }
            }
            $targets[$identity].Add([pscustomobject]@{ rule = $rule; desired = $desired })
        }
    }
}

function Find-WinLeanDependencyCycle {
    <#
    .SYNOPSIS
        Returns the rule ids of the first dependency cycle found (first id repeated at the
        end), or nothing when the dependency graph is acyclic.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rules
    )

    $byId = New-WinLeanDictionary
    foreach ($rule in $Rules) {
        $byId[$rule.id] = $rule
    }
    # 0 = unvisited, 1 = on the current path, 2 = finished
    $color = New-WinLeanDictionary
    $path = New-Object -TypeName System.Collections.Generic.List[string]

    $visit = $null
    $visit = {
        param([string] $Id)
        $color[$Id] = 1
        $path.Add($Id)
        foreach ($dependency in $byId[$Id].dependencies) {
            if (-not $byId.ContainsKey($dependency)) {
                continue
            }
            $state = 0
            if ($color.ContainsKey($dependency)) {
                $state = [int]$color[$dependency]
            }
            if ($state -eq 1) {
                $start = $path.IndexOf($dependency)
                return [string[]](@($path.GetRange($start, $path.Count - $start)) + $dependency)
            }
            if ($state -eq 0) {
                $found = & $visit $dependency
                if ($found) {
                    return $found
                }
            }
        }
        $path.RemoveAt($path.Count - 1)
        $color[$Id] = 2
        return $null
    }

    foreach ($id in @($byId.Keys)) {
        if (-not $color.ContainsKey($id)) {
            $cycle = & $visit $id
            if ($cycle) {
                $cycle
                return
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

function Test-WinLeanProfileDefinition {
    <#
    .SYNOPSIS
        Validates one profile definition (the parsed content of a profile file).
    .PARAMETER ExpectedName
        When given (the file base name), the profile 'name' must match it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Definition,
        [string] $Source = '<profile>',
        [string] $ExpectedName
    )

    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    $addError = {
        param([string] $Code, [string] $Message)
        $issues.Add((New-WinLeanIssue -Severity Error -Code $Code -Source $Source -Message $Message))
    }

    if (-not (Test-WinLeanObject -Value $Definition)) {
        & $addError 'ProfileSchema' 'A profile file must contain a single JSON object.'
        return $issues.ToArray()
    }
    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Definition)) {
        if ($script:ProfileProperties -cnotcontains $propertyName) {
            & $addError 'UnknownProperty' "Unknown property '$propertyName'. Allowed: $($script:ProfileProperties -join ', ')."
        }
    }
    $schemaVersion = Get-WinLeanProperty -InputObject $Definition -Name 'schemaVersion'
    if (-not (Test-WinLeanInteger -Value $schemaVersion) -or [int]$schemaVersion -ne $script:SchemaVersion) {
        & $addError 'SchemaVersion' "'schemaVersion' must be $($script:SchemaVersion)."
    }
    $name = Get-WinLeanProperty -InputObject $Definition -Name 'name'
    if ($name -isnot [string] -or -not (Test-WinLeanPattern -Text $name -Pattern $script:ProfileNamePattern -CaseSensitive)) {
        & $addError 'ProfileName' "'name' must contain only letters, digits, '.', '_' and '-'."
    }
    elseif ($ExpectedName -and $name -cne $ExpectedName) {
        & $addError 'ProfileName' "'name' is '$name' but the file is named '$ExpectedName.json'."
    }
    if (-not (Test-WinLeanNonEmptyString -Value (Get-WinLeanProperty -InputObject $Definition -Name 'description'))) {
        & $addError 'RequiredField' "'description' must be a non-empty string."
    }
    $extends = Get-WinLeanProperty -InputObject $Definition -Name 'extends'
    if ($null -ne $extends -and ($extends -isnot [string] -or -not (Test-WinLeanPattern -Text $extends -Pattern $script:ProfileNamePattern -CaseSensitive))) {
        & $addError 'Extends' "'extends' must be null or the name of another profile."
    }
    foreach ($field in @('rules', 'exclude')) {
        if (-not (Test-WinLeanStringArray -Value (Get-WinLeanProperty -InputObject $Definition -Name $field -NoEnumerate) -Pattern $script:RuleIdPattern)) {
            & $addError 'RuleList' "'$field' must be an array of rule ids (use [] for none)."
        }
    }
    if ($script:RiskLevels -cnotcontains (Get-WinLeanProperty -InputObject $Definition -Name 'maxRisk')) {
        & $addError 'Risk' "'maxRisk' must be one of: $($script:RiskLevels -join ', ')."
    }
    if ((Test-WinLeanProperty -InputObject $Definition -Name 'allowIrreversible') -and
        (Get-WinLeanProperty -InputObject $Definition -Name 'allowIrreversible') -isnot [bool]) {
        & $addError 'RequiredField' "'allowIrreversible' must be true or false."
    }
    return $issues.ToArray()
}

# ---------------------------------------------------------------------------
# Compatibility configuration
# ---------------------------------------------------------------------------

function Test-WinLeanCompatibilityDefinition {
    <#
    .SYNOPSIS
        Validates a compatibility configuration. Unknown requirement keys are warnings
        (they are probably typos and would otherwise be silently ignored).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Definition,
        [string] $Source = '<compatibility>',
        [string[]] $KnownRequirementKeys
    )

    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    if (-not (Test-WinLeanObject -Value $Definition)) {
        $issues.Add((New-WinLeanIssue -Severity Error -Code 'CompatibilitySchema' -Source $Source -Message 'A compatibility file must contain a single JSON object.'))
        return $issues.ToArray()
    }
    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Definition)) {
        if ($script:CompatibilityProperties -cnotcontains $propertyName) {
            $issues.Add((New-WinLeanIssue -Severity Error -Code 'UnknownProperty' -Source $Source -Message "Unknown property '$propertyName'. Allowed: $($script:CompatibilityProperties -join ', ')."))
        }
    }
    $schemaVersion = Get-WinLeanProperty -InputObject $Definition -Name 'schemaVersion'
    if (-not (Test-WinLeanInteger -Value $schemaVersion) -or [int]$schemaVersion -ne $script:SchemaVersion) {
        $issues.Add((New-WinLeanIssue -Severity Error -Code 'SchemaVersion' -Source $Source -Message "'schemaVersion' must be $($script:SchemaVersion)."))
    }
    $requirements = Get-WinLeanProperty -InputObject $Definition -Name 'requirements'
    if (-not (Test-WinLeanObject -Value $requirements)) {
        $issues.Add((New-WinLeanIssue -Severity Error -Code 'Requirements' -Source $Source -Message "'requirements' must be an object of true/false values."))
        return $issues.ToArray()
    }
    foreach ($key in @(Get-WinLeanPropertyNames -InputObject $requirements)) {
        $value = Get-WinLeanProperty -InputObject $requirements -Name $key
        if ($value -isnot [bool]) {
            $issues.Add((New-WinLeanIssue -Severity Error -Code 'Requirements' -Source $Source -Message "Requirement '$key' must be true or false."))
        }
        if ($KnownRequirementKeys -and $KnownRequirementKeys -cnotcontains $key) {
            $issues.Add((New-WinLeanIssue -Severity Warning -Code 'UnknownRequirement' -Source $Source -Message "Unknown requirement '$key' is ignored. Check the spelling against Schemas/compatibility.schema.json."))
        }
    }
    return $issues.ToArray()
}

Export-ModuleMember -Function @(
    'Get-WinLeanRuleCategories'
    'Get-WinLeanRiskLevels'
    'Get-WinLeanRiskRank'
    'New-WinLeanIssue'
    'Test-WinLeanRuleDefinition'
    'Test-WinLeanRuleCatalog'
    'Find-WinLeanDependencyCycle'
    'Test-WinLeanProfileDefinition'
    'Test-WinLeanCompatibilityDefinition'
)
