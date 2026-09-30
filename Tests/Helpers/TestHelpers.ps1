<#
    Shared helpers for the WinLean Pester tests. Dot-source in BeforeAll:

        BeforeAll { . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1') }

    Contents:
      * module loading with a clean module table
      * builders for rules, catalogs, profiles, facts and plan contexts
      * an in-memory fake registry that replaces the six low-level registry functions of
        WinLean.Provider.Registry, so that everything above them (validation, rules,
        policy, executor, backup, restore) runs unchanged without touching the real
        registry
#>
Set-StrictMode -Version Latest

$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\..'))
$script:SourceRoot = Join-Path -Path $script:RepoRoot -ChildPath 'src'

function Import-WinLeanTestModule {
    <#
    .SYNOPSIS
        Removes every loaded WinLean module and imports the given ones from src.
    .EXAMPLE
        Import-WinLeanTestModule -Name WinLean.Policy, WinLean.Rules
    #>
    param([Parameter(Mandatory)] [string[]] $Name)

    Get-Module -All | Where-Object { $_.Name -eq 'WinLean' -or $_.Name.StartsWith('WinLean.', [System.StringComparison]::Ordinal) } | Remove-Module -Force
    foreach ($moduleName in $Name) {
        $relative = if ($moduleName.StartsWith('WinLean.Provider', [System.StringComparison]::Ordinal)) { "Providers\$moduleName.psm1" } else { "$moduleName.psm1" }
        # No -Force: modules were removed above, and -Force here would load a second copy of
        # a module that an earlier import already loaded as a dependency (mocks would then
        # target the wrong copy).
        Import-Module -Name (Join-Path -Path $script:SourceRoot -ChildPath $relative) -DisableNameChecking
    }
}

# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------

function ConvertTo-JsonShape {
    <#
    .SYNOPSIS
        Round-trips a hashtable through JSON so that tests use exactly the shapes that
        ConvertFrom-Json produces for rule files.
    #>
    param([Parameter(Mandatory)] $InputObject)

    return ($InputObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function New-TestRuleDefinition {
    <#
    .SYNOPSIS
        Returns a valid rule definition (as parsed from JSON). Override any field.
    #>
    param(
        [string] $Id = 'privacy.test-rule.disable',
        [string] $Category = 'Privacy',
        [object[]] $Resources,
        [object[]] $Conditions = @(),
        [string[]] $Dependencies = @(),
        [string[]] $Conflicts = @(),
        [hashtable] $Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 },
        [string] $Risk = 'Low',
        [bool] $RequiresReboot = $false,
        [string] $TakesEffect = 'Immediately',
        [hashtable] $Extra = @{}
    )

    if (-not $Resources) {
        $Resources = @(@{ type = 'RegistryValue'; path = 'HKCU:\Software\WinLeanTest\Rule'; name = 'Value'; valueType = 'DWord'; value = 1 })
    }
    # The validation record must name the newest validated build (windows.maxValidatedBuild).
    $validatedBuild = $Windows['maxValidatedBuild']
    if ($Extra.ContainsKey('windows') -and $Extra['windows'] -is [hashtable] -and $Extra['windows'].ContainsKey('maxValidatedBuild')) {
        $validatedBuild = $Extra['windows']['maxValidatedBuild']
    }
    $definition = [ordered]@{
        schemaVersion  = 1
        id             = $Id
        name           = "Test rule $Id"
        category       = $Category
        description    = 'A rule used by the unit tests.'
        rationale      = 'Exercises the engine.'
        risk           = $Risk
        reversible     = $true
        requiresReboot = $RequiresReboot
        takesEffect    = $TakesEffect
        windows        = $Windows
        conditions     = @($Conditions)
        dependencies   = @($Dependencies)
        conflicts      = @($Conflicts)
        effects        = @('Changes a test value.')
        sideEffects    = @('None; test only.')
        benefit        = @{ type = 'Privacy'; value = 'Low'; measurement = 'NotMeasured' }
        references     = @(@{ title = 'Test reference'; url = 'https://example.com/test' })
        validation     = @(@{ method = 'SourceReview'; build = $validatedBuild; date = '2026-09-28' })
        resources      = @($Resources)
    }
    foreach ($key in $Extra.Keys) {
        $definition[$key] = $Extra[$key]
    }
    return ConvertTo-JsonShape -InputObject $definition
}

function New-TestRule {
    <#
    .SYNOPSIS
        Returns a normalized rule (requires the WinLean.Rules module in the module table).
        Accepts the same parameters as New-TestRuleDefinition.
    #>
    param(
        [string] $Id = 'privacy.test-rule.disable',
        [string] $Category = 'Privacy',
        [object[]] $Resources,
        [object[]] $Conditions = @(),
        [string[]] $Dependencies = @(),
        [string[]] $Conflicts = @(),
        [hashtable] $Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 },
        [string] $Risk = 'Low',
        [bool] $RequiresReboot = $false,
        [string] $TakesEffect = 'Immediately',
        [hashtable] $Extra = @{}
    )

    $definition = New-TestRuleDefinition @PSBoundParameters
    $rulesModule = Get-Module -Name 'WinLean.Rules'
    if ($null -eq $rulesModule) {
        $rulesModule = Get-Module -All | Where-Object { $_.Name -eq 'WinLean.Rules' } | Select-Object -First 1
    }
    return & $rulesModule { param($d) ConvertTo-WinLeanRule -Definition $d -SourcePath "$($d.category)\$($d.id).json" } $definition
}

function New-TestCatalog {
    <#
    .SYNOPSIS
        Builds a rule catalog object from normalized rules (no files involved).
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rules)

    $byId = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $Rules) {
        $byId[$rule.id] = $rule
    }
    $ids = [string[]]@($byId.Keys)
    [System.Array]::Sort($ids, [System.StringComparer]::Ordinal)
    return [pscustomobject]@{
        PSTypeName = 'WinLean.RuleCatalog'
        path       = 'TestCatalog'
        rules      = $byId
        ruleIds    = $ids
        issues     = @()
        errorCount = 0
    }
}

function New-TestProfile {
    param(
        [string] $Name = 'Test',
        [Parameter(Mandatory)] [string[]] $RuleIds,
        [string] $MaxRisk = 'Low'
    )

    return [pscustomobject]@{
        PSTypeName        = 'WinLean.Profile'
        name              = $Name
        description       = 'Test profile'
        source            = 'TestProfile.json'
        chain             = [string[]]@($Name)
        ruleIds           = $RuleIds
        excluded          = [string[]]@()
        maxRisk           = $MaxRisk
        allowIrreversible = $false
    }
}

function New-TestFacts {
    param(
        [int] $Build = 26200,
        [string] $EditionId = 'Professional',
        [string] $InstallationType = 'Client',
        [hashtable] $Requirements = @{},
        [hashtable] $Capabilities = @{},
        [bool] $PartOfDomain = $false
    )

    $facts = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $facts['system.build'] = $Build
    $facts['system.editionId'] = $EditionId
    $facts['system.installationType'] = $InstallationType
    $facts['system.partOfDomain'] = $PartOfDomain
    foreach ($key in $Requirements.Keys) { $facts["requirement.$key"] = $Requirements[$key] }
    foreach ($key in $Capabilities.Keys) { $facts["capability.$key"] = $Capabilities[$key] }
    return , $facts
}

function New-TestIdentity {
    param(
        [string] $Name = 'TEST\user',
        [string] $Sid = 'S-1-5-21-1000-1000-1000-1001',
        [bool] $IsAdministrator = $false
    )

    return [pscustomobject]@{ name = $Name; sid = $Sid; isSystem = $false; isAdministrator = $IsAdministrator }
}

function New-TestValueRule {
    <#
    .SYNOPSIS
        A rule with one registry value resource (DWord by default).
    #>
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $Name = 'Value',
        $Value = 1,
        [string] $ValueType = 'DWord',
        [string] $Path = 'HKCU:\Software\WinLeanTest\Engine',
        [hashtable] $Extra = @{}
    )

    $parameters = @{ Id = $Id; Resources = @(@{ type = 'RegistryValue'; path = $Path; name = $Name; valueType = $ValueType; value = $Value }) }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    return New-TestRule @parameters
}

function New-TestPlan {
    <#
    .SYNOPSIS
        Runs the real policy engine for the given rules (WinLean.Policy must be imported).
    #>
    param(
        [Parameter(Mandatory)] [object[]] $Rules,
        [string[]] $RuleIds,
        $Facts,
        [bool] $IsAdministrator = $false,
        [string] $PerUserTarget = 'Match'
    )

    if (-not $RuleIds) { $RuleIds = @($Rules | ForEach-Object { $_.id }) }
    if (-not $Facts) { $Facts = New-TestFacts }
    $context = New-WinLeanPlanContext -Facts $Facts -IsAdministrator $IsAdministrator -PerUserTarget $PerUserTarget -UserName 'TEST\user'
    $plan = New-WinLeanPlan -Profile (New-TestProfile -RuleIds $RuleIds) -Catalog (New-TestCatalog -Rules $Rules) -Context $context
    $plan | Add-Member -NotePropertyName 'planId' -NotePropertyValue 'test-plan'
    return $plan
}
# ---------------------------------------------------------------------------
# Fake registry
# ---------------------------------------------------------------------------

function New-FakeRegistry {
    <#
    .SYNOPSIS
        Creates an empty in-memory registry.
    .NOTES
        DeniedPaths     key prefixes without write access (writes throw UnauthorizedAccess)
        FailingValues   'path\name' entries whose writes throw an IOException
        StickyValues    'path\name' entries that silently ignore writes (like a value
                        enforced by another policy), which makes verification fail
        ReadFailures    'path\name' entries whose reads throw
        Writes          log of every successful write/delete ('path\name')
    #>
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $registry = [pscustomobject]@{
        Keys          = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList $comparer
        DeniedPaths   = New-Object -TypeName System.Collections.Generic.List[string]
        FailingValues = New-Object -TypeName System.Collections.Generic.List[string]
        StickyValues  = New-Object -TypeName System.Collections.Generic.List[string]
        ReadFailures  = New-Object -TypeName System.Collections.Generic.List[string]
        Writes        = New-Object -TypeName System.Collections.Generic.List[string]
    }
    # Keys that always exist on a real system.
    Add-FakeKey -Registry $registry -Path 'HKCU:\Software'
    Add-FakeKey -Registry $registry -Path 'HKLM:\SOFTWARE'
    return $registry
}

function Get-FakeKeyPath {
    param([Parameter(Mandatory)] [string] $Path)

    $normalized = $Path.TrimEnd('\')
    $colon = $normalized.IndexOf(':')
    return $normalized.Substring(0, $colon).ToUpperInvariant() + $normalized.Substring($colon)
}

function Test-FakeListMatch {
    param($List, [string] $Value)

    foreach ($entry in $List) {
        if ([string]::Equals($entry, $Value, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-FakeDenied {
    param($Registry, [string] $Path)

    $key = Get-FakeKeyPath -Path $Path
    foreach ($denied in $Registry.DeniedPaths) {
        $prefix = Get-FakeKeyPath -Path $denied
        if ([string]::Equals($key, $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $key.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-FakeKey {
    param($Registry, [string] $Path)

    $key = Get-FakeKeyPath -Path $Path
    $parts = $key.Split('\')
    $current = $parts[0]
    for ($index = 1; $index -lt $parts.Count; $index++) {
        $current = $current + '\' + $parts[$index]
        if (-not $Registry.Keys.ContainsKey($current)) {
            $Registry.Keys[$current] = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        }
    }
}

function Set-FakeRegistryValue {
    <#
    .SYNOPSIS
        Test setup: stores a value (raw .NET data, as the registry API would return it).
    #>
    param($Registry, [string] $Path, [string] $Name, [string] $Kind, $Data)

    Add-FakeKey -Registry $Registry -Path $Path
    $Registry.Keys[(Get-FakeKeyPath -Path $Path)][$Name] = [pscustomobject]@{ Kind = $Kind; Data = $Data }
}

function Get-FakeRegistryValue {
    param($Registry, [string] $Path, [string] $Name)

    $key = Get-FakeKeyPath -Path $Path
    if (-not $Registry.Keys.ContainsKey($key) -or -not $Registry.Keys[$key].ContainsKey($Name)) {
        return $null
    }
    return $Registry.Keys[$key][$Name]
}

function Get-FakeRegistrySnapshot {
    <#
    .SYNOPSIS
        Serializes the whole fake registry to a canonical string (for exact comparisons).
    #>
    param($Registry)

    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    $keys = [string[]]@($Registry.Keys.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $keys) {
        $lines.Add("[$key]")
        $names = [string[]]@($Registry.Keys[$key].Keys)
        [System.Array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $names) {
            $value = $Registry.Keys[$key][$name]
            $data = if ($value.Data -is [array]) { ($value.Data | ForEach-Object { [string]$_ }) -join ',' } else { [string]$value.Data }
            $lines.Add("$name=$($value.Kind):$data")
        }
    }
    return ($lines -join "`n")
}

function Read-FakeRegistryValue {
    param($Registry, [string] $Path, [string] $Name)

    if (Test-FakeListMatch -List $Registry.ReadFailures -Value "$(Get-FakeKeyPath -Path $Path)\$Name") {
        throw (New-Object -TypeName System.IO.IOException -ArgumentList 'Read failed (fake registry).')
    }
    $key = Get-FakeKeyPath -Path $Path
    if (-not $Registry.Keys.ContainsKey($key)) {
        return [pscustomobject]@{ keyExists = $false; valueExists = $false; kind = $null; data = $null }
    }
    if (-not $Registry.Keys[$key].ContainsKey($Name)) {
        return [pscustomobject]@{ keyExists = $true; valueExists = $false; kind = $null; data = $null }
    }
    $value = $Registry.Keys[$key][$Name]
    return [pscustomobject]@{ keyExists = $true; valueExists = $true; kind = $value.Kind; data = $value.Data }
}

function Write-FakeRegistryValue {
    param($Registry, [string] $Path, [string] $Name, [string] $Kind, $Data)

    $target = "$(Get-FakeKeyPath -Path $Path)\$Name"
    if (Test-FakeDenied -Registry $Registry -Path $Path) {
        throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList "Access to '$Path' is denied (fake registry).")
    }
    if (Test-FakeListMatch -List $Registry.FailingValues -Value $target) {
        throw (New-Object -TypeName System.IO.IOException -ArgumentList "Writing '$target' failed (fake registry).")
    }
    if (Test-FakeListMatch -List $Registry.StickyValues -Value $target) {
        return
    }
    Set-FakeRegistryValue -Registry $Registry -Path $Path -Name $Name -Kind $Kind -Data $Data
    $Registry.Writes.Add($target)
}

function Remove-FakeRegistryValue {
    param($Registry, [string] $Path, [string] $Name)

    if (Test-FakeDenied -Registry $Registry -Path $Path) {
        throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList "Access to '$Path' is denied (fake registry).")
    }
    $key = Get-FakeKeyPath -Path $Path
    if ($Registry.Keys.ContainsKey($key) -and $Registry.Keys[$key].ContainsKey($Name)) {
        [void]$Registry.Keys[$key].Remove($Name)
        $Registry.Writes.Add("$key\$Name")
    }
}

function Remove-FakeRegistryKeyIfEmpty {
    param($Registry, [string] $Path)

    $key = Get-FakeKeyPath -Path $Path
    if ($key.Split('\').Count -le 2 -or -not $Registry.Keys.ContainsKey($key)) {
        return $false
    }
    if ($Registry.Keys[$key].Count -gt 0) {
        return $false
    }
    foreach ($other in @($Registry.Keys.Keys)) {
        if ($other.StartsWith($key + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    [void]$Registry.Keys.Remove($key)
    return $true
}

function Register-FakeRegistryMocks {
    <#
    .SYNOPSIS
        Routes the low-level registry functions of WinLean.Provider.Registry to
        $script:FakeRegistry. Call from BeforeEach (after creating $script:FakeRegistry).
    #>
    $moduleName = 'WinLean.Provider.Registry'
    Mock -ModuleName $moduleName -CommandName Read-WinLeanRegistryValue -MockWith { Read-FakeRegistryValue -Registry $script:FakeRegistry -Path $Path -Name $Name }
    Mock -ModuleName $moduleName -CommandName Write-WinLeanRegistryValue -MockWith { Write-FakeRegistryValue -Registry $script:FakeRegistry -Path $Path -Name $Name -Kind $Kind -Data $Data }
    Mock -ModuleName $moduleName -CommandName Remove-WinLeanRegistryValue -MockWith { Remove-FakeRegistryValue -Registry $script:FakeRegistry -Path $Path -Name $Name }
    Mock -ModuleName $moduleName -CommandName Test-WinLeanRegistryKey -MockWith { $script:FakeRegistry.Keys.ContainsKey((Get-FakeKeyPath -Path $Path)) }
    Mock -ModuleName $moduleName -CommandName Remove-WinLeanRegistryKeyIfEmpty -MockWith { Remove-FakeRegistryKeyIfEmpty -Registry $script:FakeRegistry -Path $Path }
    Mock -ModuleName $moduleName -CommandName Test-WinLeanRegistryWriteAccess -MockWith { -not (Test-FakeDenied -Registry $script:FakeRegistry -Path $Path) }
}

# ---------------------------------------------------------------------------
# Fake optional features (servicing)
# ---------------------------------------------------------------------------

function New-FakeFeatureStore {
    <#
    .SYNOPSIS
        Creates an in-memory set of optional features for the WindowsOptionalFeature provider.
    .NOTES
        Features        name -> state
        IsAdministrator whether the fake process may change features
        PendingChanges  when $true, changes end in EnablePending/DisablePending
        RestartNeeded   what DISM reports after a change
        Cascade         parent -> child names disabled together with the parent (collateral)
        FailingNames    features whose changes throw
        Operations      log of 'Operation:Name'
    #>
    param([hashtable] $Features = @{})

    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $store = [pscustomobject]@{
        Features        = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList $comparer
        IsAdministrator = $true
        PendingChanges  = $false
        RestartNeeded   = $false
        Cascade         = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string[]]' -ArgumentList $comparer
        FailingNames    = New-Object -TypeName System.Collections.Generic.List[string]
        Operations      = New-Object -TypeName System.Collections.Generic.List[string]
    }
    foreach ($name in $Features.Keys) {
        $store.Features[$name] = [string]$Features[$name]
    }
    return $store
}

function Invoke-FakeFeatureChange {
    param($Store, [string] $Name, [string] $Operation)

    if (Test-FakeListMatch -List $Store.FailingNames -Value $Name) {
        throw (New-Object -TypeName System.Runtime.InteropServices.COMException -ArgumentList "The operation failed (fake servicing).", -2146498529)
    }
    if (-not $Store.Features.ContainsKey($Name)) {
        throw (New-Object -TypeName System.Runtime.InteropServices.COMException -ArgumentList "Unknown feature (fake servicing).", -2146498548)
    }
    $Store.Operations.Add("$($Operation):$Name")
    switch ($Operation) {
        'Enable' {
            if ($Store.Features[$Name] -eq 'DisabledWithPayloadRemoved') {
                throw (New-Object -TypeName System.Runtime.InteropServices.COMException -ArgumentList "The source files could not be found (fake servicing).", -2146498529)
            }
            $Store.Features[$Name] = if ($Store.PendingChanges) { 'EnablePending' } else { 'Enabled' }
        }
        'Disable' {
            $Store.Features[$Name] = if ($Store.PendingChanges) { 'DisablePending' } else { 'Disabled' }
            if ($Store.Cascade.ContainsKey($Name)) {
                foreach ($child in $Store.Cascade[$Name]) { $Store.Features[$child] = $Store.Features[$Name] }
            }
        }
        'DisableRemovePayload' { $Store.Features[$Name] = 'DisabledWithPayloadRemoved' }
    }
    return [pscustomobject]@{ restartNeeded = [bool]$Store.RestartNeeded }
}

function Get-FakeFeatureSnapshot {
    param($Store)

    $copy = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Store.Features.Keys)) { $copy[$name] = $Store.Features[$name] }
    return , $copy
}

function Register-FakeFeatureMocks {
    <#
    .SYNOPSIS
        Routes the low-level functions of WinLean.Provider.OptionalFeature to
        $script:FakeFeatures. Call from BeforeEach (after creating $script:FakeFeatures).
    #>
    $moduleName = 'WinLean.Provider.OptionalFeature'
    Mock -ModuleName $moduleName -CommandName Test-WinLeanOptionalFeatureServicingAccess -MockWith { [bool]$script:FakeFeatures.IsAdministrator }
    Mock -ModuleName $moduleName -CommandName Get-WinLeanOptionalFeatureRecord -MockWith {
        $state = if ($script:FakeFeatures.Features.ContainsKey($Name)) { $script:FakeFeatures.Features[$Name] } else { 'NotPresent' }
        [pscustomobject]@{ name = $Name; state = $state; source = 'Fake' }
    }
    Mock -ModuleName $moduleName -CommandName Get-WinLeanOptionalFeatureSnapshot -MockWith { , (Get-FakeFeatureSnapshot -Store $script:FakeFeatures) }
    Mock -ModuleName $moduleName -CommandName Invoke-WinLeanOptionalFeatureChange -MockWith { Invoke-FakeFeatureChange -Store $script:FakeFeatures -Name $Name -Operation $Operation }
}

function Get-FakeFeatureSnapshotText {
    param($Store)

    $names = [string[]]@($Store.Features.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
    return (@($names | ForEach-Object { "$_=$($Store.Features[$_])" }) -join "`n")
}

function New-TestLogger {
    <#
    .SYNOPSIS
        A logger that keeps entries in memory and writes nothing to the console or disk.
    #>
    $loggingModule = Get-Module -All | Where-Object { $_.Name -eq 'WinLean.Logging' } | Select-Object -First 1
    return & $loggingModule { New-WinLeanLogger -ConsoleLevel NONE -Capture }
}
