#Requires -Version 5.1
<#
    WinLean.Provider.OptionalFeature
    --------------------------------
    Resource provider for the declarative resource type "WindowsOptionalFeature":

        { "type": "WindowsOptionalFeature", "name": "TelnetClient", "state": "Disabled" }

    Design rules:

      * Features are changed only through the official servicing interface, the DISM
        PowerShell module (Enable-/Disable-WindowsOptionalFeature -Online -NoRestart),
        never by editing servicing registry keys. Enabling uses -LimitAccess: WinLean never
        downloads feature payloads from Windows Update, so enabling a feature whose payload
        was removed fails instead of reaching out to the network. -All is never used:
        parent features must be listed explicitly, before their children.
      * State is read with Get-WindowsOptionalFeature when elevated. Without elevation (dry
        runs of standard users) it is read from the Win32_OptionalFeature CIM class, which
        does not show pending restarts; changing features always requires Administrator
        rights, and the executor re-reads the state with DISM before changing anything.
      * States: Enabled, Disabled, EnablePending, DisablePending (a restart completes the
        change), DisabledWithPayloadRemoved, Superseded, PartiallyInstalled, NotPresent (the
        feature is not part of this Windows image) and Unknown. A pending state counts as
        its target state after a change, but a feature that is already waiting for a
        restart is not modified (its state cannot be restored exactly).
      * NotPresent satisfies "Disabled"; a rule that needs a missing feature enabled is
        Unsupported on that system.
      * Collateral changes: DISM may change other features as well (disabling a parent
        feature disables its children). Every change compares all feature states before
        and after; if anything besides the target changed, the target and every
        collateral change are reverted and the change fails with class CollateralChange,
        because the backup could not restore those features.
      * Restart: DISM reports whether a restart is needed; that report (or a pending state)
        is returned to the engine.
      * Protected features (Defender, virtualization-based security, device lockdown,
        Sysmon) are never changed, and features that weaken security (SMB 1.0, Windows
        PowerShell 2.0, Simple TCP/IP services) are never enabled by a rule. Restoring a
        recorded previous state is allowed for the latter, because it undoes WinLean's own
        change.
      * Disabling a feature that a compatibility requirement depends on (Hyper-V, WSL,
        Virtual Machine Platform, Windows Sandbox, ...) needs a rule condition declaring
        that requirement false, so a feature is never removed merely because it exists.
      * The low-level functions (Get-WinLeanOptionalFeatureRecord,
        Get-WinLeanOptionalFeatureSnapshot, Invoke-WinLeanOptionalFeatureChange,
        Test-WinLeanOptionalFeatureServicingAccess) are the only functions that touch the
        system. Unit tests replace them with an in-memory fake.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name ([System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\WinLean.Common.psm1')))

$script:DefinitionProperties = @('type', 'name', 'state')
$script:DesiredStates = @('Enabled', 'Disabled')
$script:FeatureNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Win32_OptionalFeature.InstallState -> state name.
$script:CimStates = @{ 1 = 'Enabled'; 2 = 'Disabled'; 3 = 'DisabledWithPayloadRemoved'; 4 = 'Unknown' }

# DISM error for an unknown feature name (CBS_E_UNKNOWN_UPDATE).
$script:UnknownFeatureHResult = -2146498548

# Features WinLean never changes (Direction Any) or never enables (Direction Enable).
# Match: Exact or Prefix, ignoring case.
$script:ProtectedFeatures = @(
    @{ Name = 'Windows-Defender-'; Match = 'Prefix'; Direction = 'Any'; Reason = 'Microsoft Defender' }
    @{ Name = 'Containers-Server-For-Application-Guard'; Match = 'Exact'; Direction = 'Any'; Reason = 'Microsoft Defender Application Guard' }
    @{ Name = 'IsolatedUserMode'; Match = 'Exact'; Direction = 'Any'; Reason = 'virtualization-based security (Isolated User Mode)' }
    @{ Name = 'HostGuardian'; Match = 'Exact'; Direction = 'Any'; Reason = 'Host Guardian (virtualization-based security)' }
    @{ Name = 'Sysmon'; Match = 'Prefix'; Direction = 'Any'; Reason = 'System Monitor security event logging' }
    @{ Name = 'Client-DeviceLockdown'; Match = 'Exact'; Direction = 'Any'; Reason = 'device lockdown (can lock users out)' }
    @{ Name = 'Client-Embedded'; Match = 'Prefix'; Direction = 'Any'; Reason = 'device lockdown (shell launcher, logon and boot experience)' }
    @{ Name = 'Client-KeyboardFilter'; Match = 'Exact'; Direction = 'Any'; Reason = 'device lockdown (keyboard filter)' }
    @{ Name = 'Client-UnifiedWriteFilter'; Match = 'Exact'; Direction = 'Any'; Reason = 'Unified Write Filter (discards disk changes)' }
    @{ Name = 'SMB1Protocol'; Match = 'Exact'; Direction = 'Enable'; Reason = 'SMB 1.0 is deprecated and insecure' }
    @{ Name = 'SMB1Protocol-Client'; Match = 'Exact'; Direction = 'Enable'; Reason = 'SMB 1.0 is deprecated and insecure' }
    @{ Name = 'SMB1Protocol-Server'; Match = 'Exact'; Direction = 'Enable'; Reason = 'SMB 1.0 is deprecated and insecure' }
    @{ Name = 'MicrosoftWindowsPowerShellV2'; Match = 'Prefix'; Direction = 'Enable'; Reason = 'Windows PowerShell 2.0 bypasses current PowerShell security logging' }
    @{ Name = 'SimpleTCP'; Match = 'Exact'; Direction = 'Enable'; Reason = 'Simple TCP/IP services open network listeners' }
)

# Features that compatibility requirements depend on. A rule that disables one of them
# must contain the condition 'requirement.<key> Equals false' for every listed key.
$script:RequirementFeatures = @(
    @{ Name = 'Microsoft-Hyper-V'; Match = 'Prefix'; Requirements = @('hyperV') }
    @{ Name = 'HypervisorPlatform'; Match = 'Exact'; Requirements = @('virtualization') }
    @{ Name = 'VirtualMachinePlatform'; Match = 'Exact'; Requirements = @('wsl2', 'docker') }
    @{ Name = 'Microsoft-Windows-Subsystem-Linux'; Match = 'Exact'; Requirements = @('wsl2', 'docker') }
    @{ Name = 'Containers-DisposableClientVM'; Match = 'Exact'; Requirements = @('windowsSandbox') }
    @{ Name = 'Containers'; Match = 'Exact'; Requirements = @('docker') }
    @{ Name = 'Printing-'; Match = 'Prefix'; Requirements = @('printer') }
    @{ Name = 'SMB1Protocol'; Match = 'Prefix'; Requirements = @('smb') }
    @{ Name = 'SmbDirect'; Match = 'Exact'; Requirements = @('smb') }
    @{ Name = 'SearchEngine-Client-Package'; Match = 'Exact'; Requirements = @('windowsSearch') }
    @{ Name = 'Microsoft-RemoteDesktopConnection'; Match = 'Exact'; Requirements = @('remoteDesktop') }
    @{ Name = 'DirectPlay'; Match = 'Exact'; Requirements = @('gamingMachine') }
    @{ Name = 'LegacyComponents'; Match = 'Exact'; Requirements = @('gamingMachine') }
)

# ---------------------------------------------------------------------------
# Names, protection and requirements
# ---------------------------------------------------------------------------

function Test-WinLeanFeatureNameMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Entry
    )

    if ([string]$Entry.Match -ceq 'Prefix') {
        return $Name.StartsWith([string]$Entry.Name, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return [string]::Equals($Name, [string]$Entry.Name, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WinLeanOptionalFeatureProtectedReason {
    <#
    .SYNOPSIS
        Returns why a feature may not be put into a state by a rule, or $null.
    .PARAMETER ForRestore
        Restoring a recorded previous state: only features that are never changed at all
        are refused.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Enabled', 'Disabled')] [string] $State,
        [switch] $ForRestore
    )

    foreach ($entry in $script:ProtectedFeatures) {
        if (-not (Test-WinLeanFeatureNameMatch -Name $Name -Entry $entry)) { continue }
        if ([string]$entry.Direction -ceq 'Any') {
            return [string]$entry.Reason
        }
        if ($State -ceq 'Enabled' -and -not $ForRestore) {
            return [string]$entry.Reason + '; WinLean never enables it'
        }
    }
    return $null
}

function Get-WinLeanOptionalFeatureRequirements {
    <#
    .SYNOPSIS
        Compatibility requirements that must be declared false before a rule may disable
        the feature.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Name)

    $keys = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($entry in $script:RequirementFeatures) {
        if (Test-WinLeanFeatureNameMatch -Name $Name -Entry $entry) {
            foreach ($key in $entry.Requirements) {
                if (-not $keys.Contains($key)) { $keys.Add($key) }
            }
        }
    }
    $keys.ToArray()
}

function Assert-WinLeanOptionalFeatureAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Enabled', 'Disabled')] [string] $State,
        [switch] $ForRestore
    )

    $reason = Get-WinLeanOptionalFeatureProtectedReason -Name $Name -State $State -ForRestore:$ForRestore
    if ($reason) {
        throw (New-WinLeanException -Class ProtectedResource -Message "Refusing to change the protected optional feature '$Name' ($reason).")
    }
}

# ---------------------------------------------------------------------------
# Low-level access (the only functions that touch the system)
# ---------------------------------------------------------------------------

function Test-WinLeanOptionalFeatureServicingAccess {
    <#
    .SYNOPSIS
        Returns $true when this process may change optional features (it is elevated).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [bool](Test-WinLeanAdministrator)
}

function Get-WinLeanOptionalFeatureRecord {
    <#
    .SYNOPSIS
        Reads the state of one feature: DISM when elevated, Win32_OptionalFeature otherwise.
    .OUTPUTS
        Object with name, state and source ('Dism' or 'Cim'). State NotPresent means the
        feature is not part of this Windows image.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)

    if (-not (Test-WinLeanPattern -Text $Name -Pattern $script:FeatureNamePattern -CaseSensitive)) {
        throw (New-WinLeanException -Class Unsupported -Message "Invalid optional feature name '$Name'.")
    }
    if (Test-WinLeanOptionalFeatureServicingAccess) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        }
        catch {
            for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                if ($exception.HResult -eq $script:UnknownFeatureHResult) {
                    return [pscustomobject]@{ name = $Name; state = 'NotPresent'; source = 'Dism' }
                }
            }
            throw
        }
        if ($null -eq $feature) {
            return [pscustomobject]@{ name = $Name; state = 'NotPresent'; source = 'Dism' }
        }
        $feature = @($feature)[0]
        return [pscustomobject]@{ name = [string]$feature.FeatureName; state = [string]$feature.State; source = 'Dism' }
    }

    $instance = @(Get-CimInstance -ClassName Win32_OptionalFeature -Filter ("Name = '{0}'" -f $Name) -ErrorAction Stop)
    if ($instance.Count -eq 0) {
        return [pscustomobject]@{ name = $Name; state = 'NotPresent'; source = 'Cim' }
    }
    $installState = [int]$instance[0].InstallState
    $state = if ($script:CimStates.ContainsKey($installState)) { $script:CimStates[$installState] } else { 'Unknown' }
    return [pscustomobject]@{ name = [string]$instance[0].Name; state = $state; source = 'Cim' }
}

function Get-WinLeanOptionalFeatureSnapshot {
    <#
    .SYNOPSIS
        Reads the state of every optional feature (DISM; requires elevation).
    .OUTPUTS
        Dictionary feature name -> state (case-insensitive keys).
    #>
    [CmdletBinding()]
    param()

    $snapshot = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($feature in @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)) {
        $snapshot[[string]$feature.FeatureName] = [string]$feature.State
    }
    return , $snapshot
}

function Invoke-WinLeanOptionalFeatureChange {
    <#
    .SYNOPSIS
        Enables or disables one feature through DISM, without restarting.
    .PARAMETER Operation
        Enable, Disable, or DisableRemovePayload (restores a feature whose payload had been
        removed).
    .OUTPUTS
        Object with restartNeeded.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Enable', 'Disable', 'DisableRemovePayload')] [string] $Operation
    )

    if (-not (Test-WinLeanPattern -Text $Name -Pattern $script:FeatureNamePattern -CaseSensitive)) {
        throw (New-WinLeanException -Class Unsupported -Message "Invalid optional feature name '$Name'.")
    }
    if (-not $PSCmdlet.ShouldProcess("optional feature '$Name'", $Operation)) {
        return [pscustomobject]@{ restartNeeded = $false }
    }
    switch -CaseSensitive ($Operation) {
        'Enable' { $result = Enable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -LimitAccess -ErrorAction Stop }
        'Disable' { $result = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop }
        'DisableRemovePayload' { $result = Disable-WindowsOptionalFeature -Online -FeatureName $Name -Remove -NoRestart -ErrorAction Stop }
    }
    $restartNeeded = $false
    foreach ($item in @($result)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['RestartNeeded'] -and [bool]$item.RestartNeeded) {
            $restartNeeded = $true
        }
    }
    return [pscustomobject]@{ restartNeeded = $restartNeeded }
}

# ---------------------------------------------------------------------------
# State semantics
# ---------------------------------------------------------------------------

function Get-WinLeanFeatureStateClass {
    <#
    .SYNOPSIS
        Groups states that mean the same for comparisons: a pending change counts as done.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $State)

    switch -CaseSensitive ($State) {
        'Enabled' { return 'Enabled' }
        'EnablePending' { return 'Enabled' }
        'Disabled' { return 'Disabled' }
        'DisablePending' { return 'Disabled' }
        'DisabledWithPayloadRemoved' { return 'PayloadRemoved' }
        'NotPresent' { return 'NotPresent' }
    }
    if ([string]::IsNullOrEmpty($State)) {
        return 'Unknown'
    }
    return $State
}

function Test-WinLeanFeatureStatePending {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [string] $State)

    return ($State -ceq 'EnablePending' -or $State -ceq 'DisablePending')
}

function ConvertTo-WinLeanOptionalFeatureState {
    <#
    .SYNOPSIS
        Builds the captured state of a feature from a record (Get-WinLeanOptionalFeatureRecord).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)

    $state = [string]$Record.state
    $restorable = @('Enabled', 'Disabled', 'DisabledWithPayloadRemoved', 'NotPresent') -ccontains $state
    $note = ''
    if (Test-WinLeanFeatureStatePending -State $state) {
        $note = "A restart is pending for the optional feature '$($Record.name)'. Restart Windows before WinLean changes it."
    }
    elseif ($state -ceq 'NotPresent') {
        $note = "The optional feature '$($Record.name)' is not part of this Windows installation."
    }
    elseif (-not $restorable) {
        $note = "The optional feature '$($Record.name)' is in state '$state', which WinLean cannot restore exactly."
    }
    return [pscustomobject]@{
        name       = [string]$Record.name
        state      = $state
        available  = ($state -cne 'NotPresent')
        restorable = $restorable
        source     = [string]$Record.source
        note       = $note
    }
}

# ---------------------------------------------------------------------------
# Resource provider contract
# ---------------------------------------------------------------------------

function Test-WinLeanOptionalFeatureResourceDefinition {
    <#
    .SYNOPSIS
        Validates a WindowsOptionalFeature resource as written in a rule file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Definition)

    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Definition)) {
        if ($script:DefinitionProperties -cnotcontains $propertyName) {
            "unknown property '$propertyName'"
        }
    }
    $name = Get-WinLeanProperty -InputObject $Definition -Name 'name'
    $nameIsValid = ($name -is [string] -and (Test-WinLeanPattern -Text $name -Pattern $script:FeatureNamePattern -CaseSensitive))
    if (-not $nameIsValid) {
        "'name' must be the exact feature name as shown by Get-WindowsOptionalFeature, for example 'TelnetClient'"
    }
    $state = Get-WinLeanProperty -InputObject $Definition -Name 'state'
    $stateIsValid = ($state -is [string] -and $script:DesiredStates -ccontains $state)
    if (-not $stateIsValid) {
        "'state' must be 'Enabled' or 'Disabled' (removing feature payloads is not supported)"
    }
    if ($nameIsValid -and $stateIsValid) {
        $reason = Get-WinLeanOptionalFeatureProtectedReason -Name $name -State $state
        if ($reason) {
            "targets a protected optional feature ($reason)"
        }
    }
}

function Test-WinLeanOptionalFeatureRuleConstraints {
    <#
    .SYNOPSIS
        Rule-level constraints: risk Medium or higher, takesEffect Reboot, and explicit
        requirement conditions before a feature that a requirement depends on is disabled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)] $Rule
    )

    if (@('Medium', 'High') -cnotcontains (Get-WinLeanProperty -InputObject $Rule -Name 'risk')) {
        'rules that change optional features need risk Medium or higher'
    }
    if ((Get-WinLeanProperty -InputObject $Rule -Name 'takesEffect') -cne 'Reboot') {
        "rules that change optional features must declare takesEffect 'Reboot' (and requiresReboot true): servicing changes may complete only after a restart"
    }
    if ((Get-WinLeanProperty -InputObject $Definition -Name 'state') -ceq 'Disabled') {
        $declaredFalse = New-Object -TypeName System.Collections.Generic.List[string]
        foreach ($condition in @(Get-WinLeanArrayProperty -InputObject $Rule -Name 'conditions')) {
            $fact = Get-WinLeanProperty -InputObject $condition -Name 'fact'
            $value = Get-WinLeanProperty -InputObject $condition -Name 'value'
            if ($fact -is [string] -and $fact.StartsWith('requirement.', [System.StringComparison]::Ordinal) -and
                (Get-WinLeanProperty -InputObject $condition -Name 'operator') -ceq 'Equals' -and $value -is [bool] -and -not $value) {
                $declaredFalse.Add($fact.Substring('requirement.'.Length))
            }
        }
        foreach ($key in @(Get-WinLeanOptionalFeatureRequirements -Name ([string]$Definition.name))) {
            if (-not $declaredFalse.Contains($key)) {
                "disabling '$($Definition.name)' needs the condition 'requirement.$key Equals false': a feature is only removed after the user declared it unnecessary"
            }
        }
    }
}

function ConvertTo-WinLeanOptionalFeatureResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Definition)

    return [pscustomobject]@{
        type  = 'WindowsOptionalFeature'
        name  = [string]$Definition.name
        state = [string]$Definition.state
    }
}

function Get-WinLeanOptionalFeatureResourceInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    $target = "Windows optional feature '$($Resource.name)'"
    return [pscustomobject]@{
        identity    = ('WindowsOptionalFeature:' + $Resource.name).ToUpperInvariant()
        scope       = 'Machine'
        mechanism   = 'OptionalFeature'
        target      = $target
        description = "$target = $($Resource.state)"
    }
}

function Get-WinLeanOptionalFeatureResourceState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    return ConvertTo-WinLeanOptionalFeatureState -Record (Get-WinLeanOptionalFeatureRecord -Name $Resource.name)
}

function Get-WinLeanOptionalFeatureDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    return [pscustomobject]@{ state = [string]$Resource.state }
}

function Test-WinLeanOptionalFeatureStateEqual {
    <#
    .SYNOPSIS
        Compares feature states. Pending changes count as done; "Disabled" is also
        satisfied by a removed payload or a feature that is not part of the image.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual
    )

    $expectedState = [string](Get-WinLeanProperty -InputObject $Expected -Name 'state' -Default '')
    $actualState = [string](Get-WinLeanProperty -InputObject $Actual -Name 'state' -Default '')
    $expectedClass = Get-WinLeanFeatureStateClass -State $expectedState
    $actualClass = Get-WinLeanFeatureStateClass -State $actualState
    if ($expectedClass -ceq 'Unknown' -or $actualClass -ceq 'Unknown') {
        return $false
    }
    if ($expectedClass -ceq 'Disabled') {
        return (@('Disabled', 'PayloadRemoved', 'NotPresent') -ccontains $actualClass)
    }
    return ($expectedClass -ceq $actualClass)
}

function Test-WinLeanOptionalFeatureStateRestorable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $State)

    return [bool](Get-WinLeanProperty -InputObject $State -Name 'restorable' -Default $true)
}

function Test-WinLeanOptionalFeatureResourceAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Resource)

    return [bool](Test-WinLeanOptionalFeatureServicingAccess)
}

function Get-WinLeanFeatureOperation {
    <#
    .SYNOPSIS
        The DISM operation that brings a feature from its current state to a target state,
        or $null when nothing needs to be done.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Current,
        [Parameter(Mandatory)] [string] $Target
    )

    $currentClass = Get-WinLeanFeatureStateClass -State $Current
    $targetClass = Get-WinLeanFeatureStateClass -State $Target
    if ($currentClass -ceq $targetClass) {
        return $null
    }
    switch -CaseSensitive ($targetClass) {
        'Enabled' { return 'Enable' }
        'Disabled' { if ($currentClass -ceq 'Enabled') { return 'Disable' } else { return $null } }
        'PayloadRemoved' { return 'DisableRemovePayload' }
    }
    throw (New-WinLeanException -Class Unsupported -Message "WinLean cannot put an optional feature into state '$Target'.")
}

function Invoke-WinLeanFeatureTransition {
    <#
    .SYNOPSIS
        Changes one feature and verifies that no other feature changed with it.
    .DESCRIPTION
        Every optional feature is read before and after the change. When other features
        changed as well (for example children of a disabled parent), the target and all
        collateral changes are reverted and a CollateralChange failure is thrown: the
        backup only records the target, so WinLean could not restore the others later.
    .OUTPUTS
        Object with rebootRequired.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Operation
    )

    $before = Get-WinLeanOptionalFeatureSnapshot
    $change = Invoke-WinLeanOptionalFeatureChange -Name $Name -Operation $Operation -WhatIf:$WhatIfPreference
    $after = Get-WinLeanOptionalFeatureSnapshot

    $collateral = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($featureName in @($after.Keys)) {
        if ([string]::Equals($featureName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $previous = if ($before.ContainsKey($featureName)) { $before[$featureName] } else { 'NotPresent' }
        if ((Get-WinLeanFeatureStateClass -State $previous) -cne (Get-WinLeanFeatureStateClass -State $after[$featureName])) {
            $collateral.Add([pscustomobject]@{ name = $featureName; before = $previous; after = $after[$featureName] })
        }
    }

    if ($collateral.Count -gt 0) {
        $problems = New-Object -TypeName System.Collections.Generic.List[string]
        # Revert the target first: collateral children can only be re-enabled after their parent.
        $targetBefore = if ($before.ContainsKey($Name)) { $before[$Name] } else { 'NotPresent' }
        $reverts = @([pscustomobject]@{ name = $Name; before = $targetBefore; after = $after[$Name] }) + $collateral.ToArray()
        foreach ($revert in $reverts) {
            try {
                $current = (Get-WinLeanOptionalFeatureRecord -Name $revert.name).state
                $operation = Get-WinLeanFeatureOperation -Current $current -Target $revert.before
                if ($operation) {
                    [void](Invoke-WinLeanOptionalFeatureChange -Name $revert.name -Operation $operation -WhatIf:$WhatIfPreference)
                }
            }
            catch {
                $problems.Add("$($revert.name): $($_.Exception.Message)")
            }
        }
        $changes = ($collateral | ForEach-Object { '{0} ({1} -> {2})' -f $_.name, $_.before, $_.after }) -join ', '
        $outcome = if ($problems.Count -eq 0) { 'WinLean reverted these changes.' } else { 'Reverting failed for: ' + ($problems -join '; ') + '. Restore these features manually.' }
        throw (New-WinLeanException -Class CollateralChange -Message "Changing the optional feature '$Name' also changed other features: $changes. $outcome List dependent features explicitly in the rule (children before their parent when disabling).")
    }

    $pending = Test-WinLeanFeatureStatePending -State $after[$Name]
    return [pscustomobject]@{ rebootRequired = ([bool]$change.restartNeeded -or $pending) }
}

function Set-WinLeanOptionalFeatureResource {
    <#
    .SYNOPSIS
        Enables or disables the feature (DISM, no restart) and reports whether a restart is
        needed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Resource)

    Assert-WinLeanOptionalFeatureAllowed -Name $Resource.name -State $Resource.state
    $current = (Get-WinLeanOptionalFeatureRecord -Name $Resource.name).state
    $operation = Get-WinLeanFeatureOperation -Current $current -Target $Resource.state
    if (-not $operation) {
        return [pscustomobject]@{ rebootRequired = (Test-WinLeanFeatureStatePending -State $current) }
    }
    return Invoke-WinLeanFeatureTransition -Name $Resource.name -Operation $operation -WhatIf:$WhatIfPreference
}

function Restore-WinLeanOptionalFeatureResource {
    <#
    .SYNOPSIS
        Puts the feature back into its captured state (Enabled, Disabled or
        DisabledWithPayloadRemoved).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $State
    )

    if (-not (Test-WinLeanOptionalFeatureStateRestorable -State $State)) {
        throw (New-WinLeanException -Class Unsupported -Message "The captured state '$($State.state)' of the optional feature '$($Resource.name)' cannot be restored by WinLean.")
    }
    $target = [string]$State.state
    $direction = if ((Get-WinLeanFeatureStateClass -State $target) -ceq 'Enabled') { 'Enabled' } else { 'Disabled' }
    Assert-WinLeanOptionalFeatureAllowed -Name $Resource.name -State $direction -ForRestore
    $current = (Get-WinLeanOptionalFeatureRecord -Name $Resource.name).state
    $operation = Get-WinLeanFeatureOperation -Current $current -Target $target
    if (-not $operation) {
        return [pscustomobject]@{ rebootRequired = (Test-WinLeanFeatureStatePending -State $current) }
    }
    return Invoke-WinLeanFeatureTransition -Name $Resource.name -Operation $operation -WhatIf:$WhatIfPreference
}

function Format-WinLeanOptionalFeatureState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $State)

    $state = [string](Get-WinLeanProperty -InputObject $State -Name 'state' -Default '')
    switch -CaseSensitive ($state) {
        'EnablePending' { return 'Enabled (restart pending)' }
        'DisablePending' { return 'Disabled (restart pending)' }
        'DisabledWithPayloadRemoved' { return 'Disabled (payload removed)' }
        'NotPresent' { return 'not part of this Windows installation' }
    }
    if ([string]::IsNullOrEmpty($state)) {
        return 'unknown'
    }
    return $state
}

Export-ModuleMember -Function @(
    'Get-WinLeanOptionalFeatureProtectedReason'
    'Get-WinLeanOptionalFeatureRequirements'
    'Test-WinLeanOptionalFeatureServicingAccess'
    'Get-WinLeanOptionalFeatureRecord'
    'Get-WinLeanOptionalFeatureSnapshot'
    'Invoke-WinLeanOptionalFeatureChange'
    'Test-WinLeanOptionalFeatureResourceDefinition'
    'Test-WinLeanOptionalFeatureRuleConstraints'
    'ConvertTo-WinLeanOptionalFeatureResource'
    'Get-WinLeanOptionalFeatureResourceInfo'
    'Get-WinLeanOptionalFeatureResourceState'
    'Get-WinLeanOptionalFeatureDesiredState'
    'Test-WinLeanOptionalFeatureStateEqual'
    'Test-WinLeanOptionalFeatureStateRestorable'
    'Test-WinLeanOptionalFeatureResourceAccess'
    'Set-WinLeanOptionalFeatureResource'
    'Restore-WinLeanOptionalFeatureResource'
    'Format-WinLeanOptionalFeatureState'
)
