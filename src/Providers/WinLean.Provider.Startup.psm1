#Requires -Version 5.1
<#
    WinLean.Provider.Startup
    ------------------------
    Resource provider for the declarative resource type "StartupEntry": a program that
    Windows starts at sign-in through a Run registry key.

        { "type": "StartupEntry", "location": "CurrentUserRun", "name": "Example", "ensure": "Absent" }

        { "type": "StartupEntry", "location": "CurrentUserRun", "name": "Example", "ensure": "Present",
          "command": "\"C:\\Program Files\\Example\\example.exe\" /background" }

    Locations:

      CurrentUserRun   HKCU:\Software\Microsoft\Windows\CurrentVersion\Run
      MachineRun       HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
      MachineRun32     HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run
                       (32-bit programs on 64-bit Windows)

    Design rules:

      * A startup entry is one registry value. Capture, write, restore and the protected
        location checks are delegated to the registry provider, so the captured state is
        exactly a RegistryValue state (name, kind and unexpanded command) and the identity
        equals the RegistryValue identity of the same value.
      * RunOnce keys are not supported: Windows deletes a RunOnce entry when it runs it, so
        such entries describe pending one-time work (often an installer finishing), not a
        permanent startup program.
      * Startup folder shortcuts are not supported yet: removing a file needs a lossless
        file backup (content, attributes, security descriptor), planned for a later milestone.
      * Task Manager's enabled/disabled choice (Explorer\StartupApproved) is undocumented
        binary data and is never modified (it is also a protected registry location).
        Because WinLean leaves it alone, restoring a removed entry brings back the entry's
        previous Task Manager state as well.
      * Entries of Windows security components are protected and refused.
      * Adding an entry (ensure Present) makes Windows run a program at every sign-in, so
        rules that do so need risk Medium or higher.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name ([System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\WinLean.Common.psm1')))
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Provider.Registry.psm1')

# Location name -> registry key and scope. Tests may redirect the keys to a disposable
# location (module state); rules can only name the locations.
$script:Locations = [ordered]@{
    CurrentUserRun = @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Scope = 'CurrentUser'; Label = 'current user' }
    MachineRun     = @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine'; Label = 'all users' }
    MachineRun32   = @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine'; Label = 'all users, 32-bit' }
}

$script:DefinitionProperties = @('type', 'location', 'name', 'ensure', 'command', 'valueType')
$script:CommandValueTypes = @('String', 'ExpandString')

# Startup entries WinLean never changes (matched on location and value name, ignoring case).
$script:ProtectedEntries = @(
    @{ Location = 'MachineRun'; Name = 'SecurityHealth'; Reason = 'Windows Security notification icon' }
    @{ Location = 'MachineRun'; Name = 'WindowsDefender'; Reason = 'Microsoft Defender' }
)

function Get-WinLeanStartupLocations {
    <#
    .SYNOPSIS
        Lists the supported startup locations with their registry keys.
    #>
    [CmdletBinding()]
    param()

    foreach ($name in $script:Locations.Keys) {
        [pscustomobject]@{
            location = $name
            path     = [string]$script:Locations[$name].Path
            scope    = [string]$script:Locations[$name].Scope
            label    = [string]$script:Locations[$name].Label
        }
    }
}

function Get-WinLeanStartupProtectedReason {
    <#
    .SYNOPSIS
        Returns why a startup entry is protected, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Location,
        [Parameter(Mandatory)] [string] $Name
    )

    foreach ($entry in $script:ProtectedEntries) {
        if ($Location -ceq [string]$entry.Location -and [string]::Equals($Name, [string]$entry.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$entry.Reason
        }
    }
    return $null
}

function Assert-WinLeanStartupEntryAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    $reason = Get-WinLeanStartupProtectedReason -Location $Resource.location -Name $Resource.name
    if ($reason) {
        throw (New-WinLeanException -Class ProtectedResource -Message "Refusing to modify the protected startup entry '$($Resource.name)' ($reason).")
    }
}

function ConvertTo-WinLeanStartupRegistryResource {
    <#
    .SYNOPSIS
        The RegistryValue resource behind a normalized StartupEntry resource.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    $path = [string]$script:Locations[[string]$Resource.location].Path
    if ($Resource.ensure -ceq 'Absent') {
        return [pscustomobject]@{ type = 'RegistryValue'; path = $path; name = [string]$Resource.name; ensure = 'Absent'; valueType = $null; value = $null }
    }
    return [pscustomobject]@{ type = 'RegistryValue'; path = $path; name = [string]$Resource.name; ensure = 'Present'; valueType = [string]$Resource.valueType; value = [string]$Resource.command }
}

# ---------------------------------------------------------------------------
# Resource provider contract
# ---------------------------------------------------------------------------

function Test-WinLeanStartupResourceDefinition {
    <#
    .SYNOPSIS
        Validates a StartupEntry resource as written in a rule file.
    .OUTPUTS
        Problem descriptions (strings). Nothing is emitted when the definition is valid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Definition)

    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Definition)) {
        if ($script:DefinitionProperties -cnotcontains $propertyName) {
            "unknown property '$propertyName'"
        }
    }

    $location = Get-WinLeanProperty -InputObject $Definition -Name 'location'
    $locationIsValid = ($location -is [string] -and @($script:Locations.Keys) -ccontains $location)
    if (-not $locationIsValid) {
        "'location' must be one of: $(@($script:Locations.Keys) -join ', ') (RunOnce keys and Startup folders are not supported)"
    }

    $name = Get-WinLeanProperty -InputObject $Definition -Name 'name'
    $nameIsValid = ($name -is [string] -and -not [string]::IsNullOrWhiteSpace($name))
    if (-not $nameIsValid) {
        "'name' must be the non-empty name of the Run value"
    }

    $ensure = Get-WinLeanProperty -InputObject $Definition -Name 'ensure'
    $hasCommand = Test-WinLeanProperty -InputObject $Definition -Name 'command'
    $hasValueType = Test-WinLeanProperty -InputObject $Definition -Name 'valueType'
    if ($ensure -ceq 'Present') {
        $command = Get-WinLeanProperty -InputObject $Definition -Name 'command'
        if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command)) {
            "'command' must be the non-empty command line when 'ensure' is 'Present'"
        }
        if ($hasValueType -and $script:CommandValueTypes -cnotcontains (Get-WinLeanProperty -InputObject $Definition -Name 'valueType')) {
            "'valueType' must be one of: $($script:CommandValueTypes -join ', ')"
        }
    }
    elseif ($ensure -ceq 'Absent') {
        if ($hasCommand -or $hasValueType) {
            "'command' and 'valueType' must be omitted when 'ensure' is 'Absent'"
        }
    }
    else {
        "'ensure' must be 'Present' or 'Absent'"
    }

    if ($locationIsValid -and $nameIsValid) {
        $reason = Get-WinLeanStartupProtectedReason -Location $location -Name $name
        if ($reason) {
            "targets a protected startup entry ($reason)"
        }
    }
}

function Test-WinLeanStartupRuleConstraints {
    <#
    .SYNOPSIS
        Rule-level constraints: adding a startup entry needs risk Medium or higher.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)] $Rule
    )

    $risk = Get-WinLeanProperty -InputObject $Rule -Name 'risk'
    if ((Get-WinLeanProperty -InputObject $Definition -Name 'ensure') -ceq 'Present' -and @('Medium', 'High') -cnotcontains $risk) {
        "adding a startup entry makes Windows run a program at every sign-in; such rules need risk Medium or higher"
    }
}

function ConvertTo-WinLeanStartupResource {
    <#
    .SYNOPSIS
        Converts a validated definition into a normalized resource object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Definition)

    $ensure = [string]$Definition.ensure
    $command = $null
    $valueType = $null
    if ($ensure -ceq 'Present') {
        $command = [string]$Definition.command
        $valueType = [string](Get-WinLeanProperty -InputObject $Definition -Name 'valueType' -Default 'String')
    }
    return [pscustomobject]@{
        type      = 'StartupEntry'
        location  = [string]$Definition.location
        name      = [string]$Definition.name
        ensure    = $ensure
        command   = $command
        valueType = $valueType
    }
}

function Get-WinLeanStartupResourceInfo {
    <#
    .SYNOPSIS
        Describes a normalized resource. The identity is the one of the underlying registry
        value, so a StartupEntry and a RegistryValue for the same value conflict.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    $registryResource = ConvertTo-WinLeanStartupRegistryResource -Resource $Resource
    $registryInfo = Get-WinLeanRegistryResourceInfo -Resource $registryResource
    $location = $script:Locations[[string]$Resource.location]
    $target = "Startup entry '$($Resource.name)' ($($Resource.location): $($registryInfo.target))"
    $desired = if ($Resource.ensure -ceq 'Absent') { 'removed' } else { "present: $($Resource.command)" }
    return [pscustomobject]@{
        identity    = $registryInfo.identity
        scope       = [string]$location.Scope
        mechanism   = 'Startup'
        target      = $target
        description = "$target $desired"
    }
}

function Get-WinLeanStartupResourceState {
    <#
    .SYNOPSIS
        Reads the Run value exactly as stored (same shape as a RegistryValue state).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    return Get-WinLeanRegistryResourceState -Resource (ConvertTo-WinLeanStartupRegistryResource -Resource $Resource)
}

function Get-WinLeanStartupDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    return Get-WinLeanRegistryDesiredState -Resource (ConvertTo-WinLeanStartupRegistryResource -Resource $Resource)
}

function Test-WinLeanStartupStateEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual
    )

    return Test-WinLeanRegistryStateEqual -Expected $Expected -Actual $Actual
}

function Test-WinLeanStartupStateRestorable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $State)

    return Test-WinLeanRegistryStateRestorable -State $State
}

function Test-WinLeanStartupResourceAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Resource)

    return Test-WinLeanRegistryResourceAccess -Resource (ConvertTo-WinLeanStartupRegistryResource -Resource $Resource)
}

function Set-WinLeanStartupResource {
    <#
    .SYNOPSIS
        Adds or removes the Run value. Task Manager's StartupApproved data is not touched.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is implemented by the registry provider; -WhatIf is passed on.')]
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Resource)

    Assert-WinLeanStartupEntryAllowed -Resource $Resource
    Set-WinLeanRegistryResource -Resource (ConvertTo-WinLeanStartupRegistryResource -Resource $Resource) -WhatIf:$WhatIfPreference
}

function Restore-WinLeanStartupResource {
    <#
    .SYNOPSIS
        Writes the captured Run value back exactly (command and value kind), or removes an
        entry that did not exist before.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is implemented by the registry provider; -WhatIf is passed on.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $State
    )

    Assert-WinLeanStartupEntryAllowed -Resource $Resource
    Restore-WinLeanRegistryResource -Resource (ConvertTo-WinLeanStartupRegistryResource -Resource $Resource) -State $State -WhatIf:$WhatIfPreference
}

function Format-WinLeanStartupState {
    <#
    .SYNOPSIS
        "not present" or the command with its value kind.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $State)

    if (-not [bool](Get-WinLeanProperty -InputObject $State -Name 'valueExists' -Default $false)) {
        return 'not present'
    }
    return Format-WinLeanRegistryState -State $State
}

Export-ModuleMember -Function @(
    'Get-WinLeanStartupLocations'
    'Get-WinLeanStartupProtectedReason'
    'Test-WinLeanStartupResourceDefinition'
    'Test-WinLeanStartupRuleConstraints'
    'ConvertTo-WinLeanStartupResource'
    'Get-WinLeanStartupResourceInfo'
    'Get-WinLeanStartupResourceState'
    'Get-WinLeanStartupDesiredState'
    'Test-WinLeanStartupStateEqual'
    'Test-WinLeanStartupStateRestorable'
    'Test-WinLeanStartupResourceAccess'
    'Set-WinLeanStartupResource'
    'Restore-WinLeanStartupResource'
    'Format-WinLeanStartupState'
)
