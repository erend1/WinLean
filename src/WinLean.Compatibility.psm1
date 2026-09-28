#Requires -Version 5.1
<#
    WinLean.Compatibility
    ---------------------
    The compatibility context keeps two concepts strictly apart:

      requirement  what the user needs    "Bluetooth must keep working"   requirement.<key>
                   (Config/Compatibility.json, a decision)
      capability   what WinLean detected  "a Bluetooth adapter exists"    capability.<key>
                   (derived from the inventory, a fact)

    Rules evaluate conditions against requirements, capabilities and system facts. A
    detected capability never turns into a requirement automatically; WinLean only
    suggests declaring it.

    Undeclared requirements are unknown, and unknown facts make conditions fail, so
    WinLean assumes an undeclared requirement is needed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Validation.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Inventory.psm1')

# Capability detectors: name, the requirement it relates to (for suggestions), a
# description, and a script block that receives the inventory and returns $true, $false
# or $null (unknown).
$script:CapabilityDetectors = @(
    @{
        Name        = 'bluetoothAdapterPresent'
        Requirement = 'bluetooth'
        Description = 'A Bluetooth adapter is present (heuristic).'
        Detect      = {
            param($Inventory)
            $hardware = Get-WinLeanInventorySection -Inventory $Inventory -Name 'hardware'
            if ($null -eq $hardware -or -not $hardware.bluetooth.available) { return $null }
            return [bool]$hardware.bluetooth.data.adapterPresent
        }
    }
    @{
        Name        = 'physicalPrinterInstalled'
        Requirement = 'printer'
        Description = 'A printer that is not a software printer (PDF, XPS, OneNote, fax) is installed.'
        Detect      = {
            param($Inventory)
            $hardware = Get-WinLeanInventorySection -Inventory $Inventory -Name 'hardware'
            if ($null -eq $hardware -or -not $hardware.printers.available) { return $null }
            return ([int]$hardware.printers.data.physicalCount -gt 0)
        }
    }
    @{
        Name        = 'batteryPresent'
        Requirement = $null
        Description = 'The device has a battery (laptop or tablet).'
        Detect      = {
            param($Inventory)
            $hardware = Get-WinLeanInventorySection -Inventory $Inventory -Name 'hardware'
            if ($null -eq $hardware -or -not $hardware.battery.available) { return $null }
            return [bool]$hardware.battery.data.present
        }
    }
    @{
        Name        = 'hyperVEnabled'
        Requirement = 'hyperV'
        Description = 'The Hyper-V optional feature is enabled.'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V') }
    }
    @{
        Name        = 'wslEnabled'
        Requirement = 'wsl2'
        Description = 'The Windows Subsystem for Linux optional feature is enabled.'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('Microsoft-Windows-Subsystem-Linux') }
    }
    @{
        Name        = 'virtualMachinePlatformEnabled'
        Requirement = 'wsl2'
        Description = 'The Virtual Machine Platform optional feature (used by WSL 2) is enabled.'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('VirtualMachinePlatform') }
    }
    @{
        Name        = 'windowsSandboxEnabled'
        Requirement = 'windowsSandbox'
        Description = 'The Windows Sandbox optional feature is enabled.'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('Containers-DisposableClientVM') }
    }
    @{
        Name        = 'oneDriveInstalled'
        Requirement = 'onedrive'
        Description = 'OneDrive is installed.'
        Detect      = { param($Inventory) Test-WinLeanApplicationInstalled -Inventory $Inventory -Name 'Microsoft OneDrive' }
    }
    @{
        Name        = 'phoneLinkInstalled'
        Requirement = 'phoneLink'
        Description = 'The Phone Link app is installed.'
        Detect      = { param($Inventory) Test-WinLeanAppxInstalled -Inventory $Inventory -Name 'Microsoft.YourPhone' }
    }
    @{
        Name        = 'xboxAppInstalled'
        Requirement = 'xbox'
        Description = 'The Xbox app is installed.'
        Detect      = { param($Inventory) Test-WinLeanAppxInstalled -Inventory $Inventory -Name 'Microsoft.GamingApp' }
    }
)

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

function Get-WinLeanRequirementDefinitions {
    <#
    .SYNOPSIS
        Returns the known requirement keys and their descriptions from the compatibility schema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SchemaPath
    )

    $schema = Read-WinLeanJsonFile -Path $SchemaPath
    $properties = $schema.properties.requirements.properties
    foreach ($key in @(Get-WinLeanPropertyNames -InputObject $properties)) {
        [pscustomobject]@{
            key         = $key
            description = [string](Get-WinLeanProperty -InputObject (Get-WinLeanProperty -InputObject $properties -Name $key) -Name 'description')
        }
    }
}

function Import-WinLeanCompatibility {
    <#
    .SYNOPSIS
        Loads the user's compatibility requirements.
    .PARAMETER Path
        The compatibility file. A missing file is not an error: every requirement is then
        undeclared (and therefore treated as required).
    .OUTPUTS
        WinLean.Compatibility: source, exists, requirements (dictionary key -> bool),
        issues, errorCount.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $Path,
        [string[]] $KnownRequirementKeys
    )

    $requirements = New-WinLeanDictionary
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists((Resolve-WinLeanPath -Path $Path))) {
        return [pscustomobject]@{
            PSTypeName   = 'WinLean.Compatibility'
            source       = if ($Path) { Resolve-WinLeanPath -Path $Path } else { $null }
            exists       = $false
            requirements = $requirements
            issues       = @()
            errorCount   = 0
        }
    }

    $fullPath = Resolve-WinLeanPath -Path $Path
    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    try {
        $definition = Read-WinLeanJsonFile -Path $fullPath
        foreach ($issue in @(Test-WinLeanCompatibilityDefinition -Definition $definition -Source $fullPath -KnownRequirementKeys $KnownRequirementKeys)) {
            $issues.Add($issue)
        }
        $values = Get-WinLeanProperty -InputObject $definition -Name 'requirements'
        foreach ($key in @(Get-WinLeanPropertyNames -InputObject $values)) {
            $value = Get-WinLeanProperty -InputObject $values -Name $key
            if ($value -is [bool] -and (-not $KnownRequirementKeys -or $KnownRequirementKeys -contains $key)) {
                $requirements[$key] = $value
            }
        }
    }
    catch {
        $issues.Add((New-WinLeanIssue -Severity Error -Code 'CompatibilityParse' -Source $fullPath -Message $_.Exception.Message))
    }

    return [pscustomobject]@{
        PSTypeName   = 'WinLean.Compatibility'
        source       = $fullPath
        exists       = $true
        requirements = $requirements
        issues       = $issues.ToArray()
        errorCount   = @($issues | Where-Object { $_.severity -eq 'Error' }).Count
    }
}

# ---------------------------------------------------------------------------
# Capabilities (detected)
# ---------------------------------------------------------------------------

function Test-WinLeanFeatureEnabled {
    [CmdletBinding()]
    param(
        [AllowNull()] $Inventory,
        [Parameter(Mandatory)] [string[]] $Names
    )

    $features = Get-WinLeanInventorySection -Inventory $Inventory -Name 'optionalFeatures'
    if ($null -eq $features) {
        return $null
    }
    foreach ($feature in @($features.features)) {
        if ($Names -contains $feature.name -and $feature.state -eq 'Enabled') {
            return $true
        }
    }
    return $false
}

function Test-WinLeanApplicationInstalled {
    [CmdletBinding()]
    param(
        [AllowNull()] $Inventory,
        [Parameter(Mandatory)] [string] $Name
    )

    $applications = Get-WinLeanInventorySection -Inventory $Inventory -Name 'win32Applications'
    if ($null -eq $applications) {
        return $null
    }
    foreach ($application in @($applications.applications)) {
        if (Test-WinLeanTextEqual -Left $application.name -Right $Name) {
            return $true
        }
    }
    return $false
}

function Test-WinLeanAppxInstalled {
    [CmdletBinding()]
    param(
        [AllowNull()] $Inventory,
        [Parameter(Mandatory)] [string] $Name
    )

    $appx = Get-WinLeanInventorySection -Inventory $Inventory -Name 'appxPackages'
    if ($null -eq $appx) {
        return $null
    }
    foreach ($package in @($appx.packages)) {
        if (Test-WinLeanTextEqual -Left $package.name -Right $Name) {
            return $true
        }
    }
    return $false
}

function Get-WinLeanCapabilities {
    <#
    .SYNOPSIS
        Derives detected capabilities from an inventory.
    .OUTPUTS
        Dictionary capability name -> $true / $false. Capabilities that could not be
        determined (missing inventory data) are omitted, which makes them unknown.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Inventory
    )

    $capabilities = New-WinLeanDictionary
    if ($null -eq $Inventory) {
        return , $capabilities
    }
    foreach ($detector in $script:CapabilityDetectors) {
        try {
            $value = & $detector.Detect $Inventory
            if ($null -ne $value) {
                $capabilities[$detector.Name] = [bool]$value
            }
        }
        catch {
            Write-Verbose "Capability '$($detector.Name)' could not be detected: $($_.Exception.Message)"
        }
    }
    return , $capabilities
}

function Get-WinLeanCapabilityDefinitions {
    <#
    .SYNOPSIS
        Lists the capabilities WinLean can detect.
    #>
    [CmdletBinding()]
    param()

    foreach ($detector in $script:CapabilityDetectors) {
        [pscustomobject]@{ name = $detector.Name; requirement = $detector.Requirement; description = $detector.Description }
    }
}

function Get-WinLeanCompatibilitySuggestions {
    <#
    .SYNOPSIS
        Suggests declaring requirements for features that were detected but not declared.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Compatibility')] $Compatibility,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Capabilities
    )

    foreach ($detector in $script:CapabilityDetectors) {
        if (-not $detector.Requirement) { continue }
        if (-not (Test-WinLeanDictionaryKey -Dictionary $Capabilities -Key $detector.Name) -or -not $Capabilities[$detector.Name]) { continue }
        if (Test-WinLeanDictionaryKey -Dictionary $Compatibility.requirements -Key $detector.Requirement) { continue }
        [pscustomobject]@{
            requirement = $detector.Requirement
            capability  = $detector.Name
            message     = "$($detector.Description) Requirement '$($detector.Requirement)' is not declared (treated as required); declare it to make the decision explicit."
        }
    }
}

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

function New-WinLeanFacts {
    <#
    .SYNOPSIS
        Builds the fact dictionary that rule conditions are evaluated against.
    .OUTPUTS
        Dictionary with system.<key>, requirement.<key> and capability.<key> entries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Platform,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Compatibility')] $Compatibility,
        [System.Collections.IDictionary] $Capabilities
    )

    $facts = New-WinLeanDictionary
    foreach ($name in @('build', 'ubr', 'editionId', 'displayVersion', 'installationType', 'architecture', 'partOfDomain')) {
        $value = Get-WinLeanProperty -InputObject $Platform -Name $name
        if ($null -ne $value -and -not ($value -is [string] -and $value.Length -eq 0)) {
            $facts['system.' + $name] = $value
        }
    }
    foreach ($key in @($Compatibility.requirements.Keys)) {
        $facts['requirement.' + $key] = [bool]$Compatibility.requirements[$key]
    }
    if ($Capabilities) {
        foreach ($key in @($Capabilities.Keys)) {
            $facts['capability.' + $key] = [bool]$Capabilities[$key]
        }
    }
    return , $facts
}

function Get-WinLeanCompatibilitySummary {
    <#
    .SYNOPSIS
        Summarizes the compatibility context for plans and reports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Compatibility')] $Compatibility,
        [string[]] $KnownRequirementKeys,
        [System.Collections.IDictionary] $Capabilities
    )

    $declared = [ordered]@{}
    $keys = [string[]]@($Compatibility.requirements.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    foreach ($key in $keys) {
        $declared[$key] = [bool]$Compatibility.requirements[$key]
    }
    $undeclared = @(foreach ($key in @($KnownRequirementKeys)) {
            if ($key -and -not (Test-WinLeanDictionaryKey -Dictionary $Compatibility.requirements -Key $key)) { $key }
        })
    $detected = [ordered]@{}
    if ($Capabilities) {
        $capabilityKeys = [string[]]@($Capabilities.Keys)
        [System.Array]::Sort($capabilityKeys, [System.StringComparer]::Ordinal)
        foreach ($key in $capabilityKeys) {
            $detected[$key] = [bool]$Capabilities[$key]
        }
    }
    return [pscustomobject]@{
        source       = $Compatibility.source
        exists       = $Compatibility.exists
        declared     = [pscustomobject]$declared
        undeclared   = [string[]]$undeclared
        capabilities = [pscustomobject]$detected
    }
}

Export-ModuleMember -Function @(
    'Get-WinLeanRequirementDefinitions'
    'Import-WinLeanCompatibility'
    'Get-WinLeanCapabilities'
    'Get-WinLeanCapabilityDefinitions'
    'Get-WinLeanCompatibilitySuggestions'
    'New-WinLeanFacts'
    'Get-WinLeanCompatibilitySummary'
)
