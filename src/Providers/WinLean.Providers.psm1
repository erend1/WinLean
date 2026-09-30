#Requires -Version 5.1
<#
    WinLean.Providers
    -----------------
    Registry of resource providers and the dispatcher the engine uses to reach them.

    Every declarative resource type is implemented by exactly one provider that fulfils
    this contract (Service, ScheduledTask and AppxPackage are planned):

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

    Optional parts of the contract:

      * RuleConstraints (definition, rule) -> problem descriptions for constraints that
        involve the whole rule, for example a minimum risk for resources of this type.
      * A captured state may contain 'available' = $false when the resource does not
        exist on this system (for example an optional feature that is not part of the
        Windows image). The policy engine reports such rules as Unsupported unless the
        resource is already in its desired state.
      * A captured state may contain 'note': a short explanation shown in the plan when
        the resource cannot be changed (not available, not restorable).
      * Set and Restore may return an object with 'rebootRequired' ($true / $false) when
        the provider knows whether a restart is needed to complete the change. Nothing
        (or $null) means "unknown"; the rule's declared takesEffect then applies.

    Resources of different types may share an identity when they manage the same
    underlying object (a StartupEntry is a registry value); their desired states are then
    compared with both providers.

    The engine only calls the wrappers below, so adding a provider never changes the
    policy engine, executor or restore logic.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name ([System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\WinLean.Common.psm1')))
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Provider.Registry.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Provider.Startup.psm1')

# RuleConstraints (optional): checks that need the whole rule definition, for example a
# minimum risk level for resources of this type.
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
    StartupEntry  = @{
        Validate        = 'Test-WinLeanStartupResourceDefinition'
        RuleConstraints = 'Test-WinLeanStartupRuleConstraints'
        Normalize       = 'ConvertTo-WinLeanStartupResource'
        Describe        = 'Get-WinLeanStartupResourceInfo'
        GetState        = 'Get-WinLeanStartupResourceState'
        GetDesired      = 'Get-WinLeanStartupDesiredState'
        Equal           = 'Test-WinLeanStartupStateEqual'
        Restorable      = 'Test-WinLeanStartupStateRestorable'
        TestAccess      = 'Test-WinLeanStartupResourceAccess'
        Set             = 'Set-WinLeanStartupResource'
        Restore         = 'Restore-WinLeanStartupResource'
        FormatState     = 'Format-WinLeanStartupState'
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

function Test-WinLeanResourceRuleConstraints {
    <#
    .SYNOPSIS
        Checks provider-specific constraints that involve the whole rule (for example a
        minimum risk). Call only for resource definitions that passed validation.
    .OUTPUTS
        Problem descriptions (strings).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)] $Rule
    )

    $command = Get-WinLeanProviderCommand -Type ([string]$Definition.type) -Operation 'RuleConstraints'
    if ($command) {
        & $command -Definition $Definition -Rule $Rule
    }
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

function Test-WinLeanResourceDesiredStateEqual {
    <#
    .SYNOPSIS
        Compares the desired states of two resources that share an identity.
    .NOTES
        Resources of the same type are compared by their provider. Resources of different
        types (for example a RegistryValue and a StartupEntry for the same Run value) are
        equal only when both providers consider the desired states equal; a provider
        that cannot interpret the other state counts as "different".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right
    )

    $leftDesired = Get-WinLeanResourceDesiredState -Resource $Left
    $rightDesired = Get-WinLeanResourceDesiredState -Resource $Right
    $leftType = [string]$Left.type
    $rightType = [string]$Right.type
    if ($leftType -ceq $rightType) {
        return [bool](Test-WinLeanResourceStateEqual -Type $leftType -Expected $leftDesired -Actual $rightDesired)
    }
    try {
        return ([bool](Test-WinLeanResourceStateEqual -Type $leftType -Expected $leftDesired -Actual $rightDesired) -and
            [bool](Test-WinLeanResourceStateEqual -Type $rightType -Expected $rightDesired -Actual $leftDesired))
    }
    catch {
        return $false
    }
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

function Test-WinLeanResourceStateAvailable {
    <#
    .SYNOPSIS
        Returns $false when a captured state reports that the resource does not exist on
        this system (optional 'available' property); $true otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowNull()] $State)

    if ($null -eq $State) {
        return $true
    }
    return [bool](Get-WinLeanProperty -InputObject $State -Name 'available' -Default $true)
}

function ConvertTo-WinLeanProviderResult {
    <#
    .SYNOPSIS
        Normalizes what a provider's Set or Restore operation emitted.
    .OUTPUTS
        Object with rebootRequired: $true, $false or $null (unknown).
    #>
    [CmdletBinding()]
    param([AllowNull()] [object[]] $Output)

    $rebootRequired = $null
    foreach ($item in @($Output)) {
        if ($null -eq $item -or $item -is [string] -or $item -is [ValueType]) {
            continue
        }
        if (Test-WinLeanProperty -InputObject $item -Name 'rebootRequired') {
            $value = Get-WinLeanProperty -InputObject $item -Name 'rebootRequired'
            if ($value -is [bool]) {
                $rebootRequired = $value
            }
        }
    }
    return [pscustomobject]@{ rebootRequired = $rebootRequired }
}

function Test-WinLeanResourceAccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Resource)

    & (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'TestAccess') -Resource $Resource
}

function Set-WinLeanResource {
    <#
    .SYNOPSIS
        Puts a resource into its desired state.
    .OUTPUTS
        Object with rebootRequired ($true, $false or $null when unknown).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resource)

    $output = @(& (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'Set') -Resource $Resource)
    return ConvertTo-WinLeanProviderResult -Output $output
}

function Restore-WinLeanResource {
    <#
    .SYNOPSIS
        Writes a captured state back.
    .OUTPUTS
        Object with rebootRequired ($true, $false or $null when unknown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $State
    )

    $output = @(& (Get-WinLeanProviderCommand -Type ([string]$Resource.type) -Operation 'Restore') -Resource $Resource -State $State)
    return ConvertTo-WinLeanProviderResult -Output $output
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
    'Test-WinLeanResourceRuleConstraints'
    'ConvertTo-WinLeanResource'
    'Get-WinLeanResourceInfo'
    'Get-WinLeanResourceState'
    'Get-WinLeanResourceDesiredState'
    'Test-WinLeanResourceStateEqual'
    'Test-WinLeanResourceDesiredStateEqual'
    'Test-WinLeanResourceStateRestorable'
    'Test-WinLeanResourceStateAvailable'
    'ConvertTo-WinLeanProviderResult'
    'Test-WinLeanResourceAccess'
    'Set-WinLeanResource'
    'Restore-WinLeanResource'
    'Format-WinLeanResourceState'
)
