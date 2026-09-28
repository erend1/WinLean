#Requires -Version 5.1
<#
    WinLean.Providers
    -----------------
    Registry of resource providers and the dispatcher the engine uses to reach them.

    Every declarative resource type is implemented by exactly one provider that fulfils
    this contract (RegistryValue is the only type in milestone 0.1; Service,
    ScheduledTask, OptionalFeature and AppxPackage are planned):

      Validate     definition        -> problem descriptions (nothing when valid)
      Normalize    definition        -> normalized resource object
      Describe     resource          -> identity, scope, mechanism, target, description
      GetState     resource          -> captured state (plain, JSON-serializable data)
      GetDesired   resource          -> desired state (same shape as captured state)
      Equal        expected, actual  -> $true when the states match
      Restorable   state             -> $true when the state can be written back exactly
      TestAccess   resource          -> $true when this process may apply and restore it
      Set          resource          -> puts the system into the desired state
      Restore      resource, state   -> writes a captured state back
      FormatState  state             -> human-readable text

    The engine only calls the wrappers below, so adding a provider never changes the
    policy engine, executor or restore logic.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name ([System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\WinLean.Common.psm1')))
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Provider.Registry.psm1')

$script:Providers = @{
    RegistryValue = @{
        Validate    = 'Test-WinLeanRegistryResourceDefinition'
        Normalize   = 'ConvertTo-WinLeanRegistryResource'
        Describe    = 'Get-WinLeanRegistryResourceInfo'
        GetState    = 'Get-WinLeanRegistryResourceState'
        GetDesired  = 'Get-WinLeanRegistryDesiredState'
        Equal       = 'Test-WinLeanRegistryStateEqual'
        Restorable  = 'Test-WinLeanRegistryStateRestorable'
        TestAccess  = 'Test-WinLeanRegistryResourceAccess'
        Set         = 'Set-WinLeanRegistryResource'
        Restore     = 'Restore-WinLeanRegistryResource'
        FormatState = 'Format-WinLeanRegistryState'
    }
}

function Get-WinLeanResourceTypes {
    <#
    .SYNOPSIS
        Lists the resource types that have a provider.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $types = [string[]]@($script:Providers.Keys)
    [System.Array]::Sort($types, [System.StringComparer]::Ordinal)
    $types
}

function Get-WinLeanProviderCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Type,
        [Parameter(Mandatory)] [string] $Operation
    )

    foreach ($knownType in $script:Providers.Keys) {
        if ($knownType -ceq $Type) {
            return [string]$script:Providers[$knownType][$Operation]
        }
    }
    throw (New-WinLeanException -Class Unsupported -Message "No provider is registered for resource type '$Type'.")
}

function Test-WinLeanResourceDefinition {
    <#
    .SYNOPSIS
        Validates a resource definition from a rule file. Emits problem descriptions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Definition
    )

    if ($null -eq $Definition -or $Definition -is [string] -or (Test-WinLeanEnumerable -Value $Definition)) {
        'resource must be an object'
        return
    }
    $type = Get-WinLeanProperty -InputObject $Definition -Name 'type'
    if (@(Get-WinLeanResourceTypes) -cnotcontains $type) {
        "'type' must be one of: " + (@(Get-WinLeanResourceTypes) -join ', ')
        return
    }
    & (Get-WinLeanProviderCommand -Type $type -Operation 'Validate') -Definition $Definition
}

function ConvertTo-WinLeanResource {
    <#
    .SYNOPSIS
        Normalizes a validated resource definition.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Definition)

    & (Get-WinLeanProviderCommand -Type ([string]$Definition.type) -Operation 'Normalize') -Definition $Definition
}

function Get-WinLeanResourceInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'Describe') -Resource $Resource
}

function Get-WinLeanResourceState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'GetState') -Resource $Resource
}

function Get-WinLeanResourceDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'GetDesired') -Resource $Resource
}

function Test-WinLeanResourceStateEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual
    )

    & (Get-WinLeanProviderCommand -Type $Type -Operation 'Equal') -Expected $Expected -Actual $Actual
}

function Test-WinLeanResourceStateRestorable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] $State
    )

    & (Get-WinLeanProviderCommand -Type $Type -Operation 'Restorable') -State $State
}

function Test-WinLeanResourceAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Resource)

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'TestAccess') -Resource $Resource
}

function Set-WinLeanResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'Set') -Resource $Resource
}

function Restore-WinLeanResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $State
    )

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'Restore') -Resource $Resource -State $State
}

function Format-WinLeanResourceState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] $State
    )

    & (Get-WinLeanProviderCommand -Type $Type -Operation 'FormatState') -State $State
}

Export-ModuleMember -Function @(
    'Get-WinLeanResourceTypes'
    'Test-WinLeanResourceDefinition'
    'ConvertTo-WinLeanResource'
    'Get-WinLeanResourceInfo'
    'Get-WinLeanResourceState'
    'Get-WinLeanResourceDesiredState'
    'Test-WinLeanResourceStateEqual'
    'Test-WinLeanResourceStateRestorable'
    'Test-WinLeanResourceAccess'
    'Set-WinLeanResource'
    'Restore-WinLeanResource'
    'Format-WinLeanResourceState'
)
