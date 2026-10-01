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
# description, the detected subject (for questionnaire hints), and a script block that
# receives the inventory and returns $true, $false or $null (unknown).
$script:CapabilityDetectors = @(
    @{
        Name        = 'bluetoothAdapterPresent'
        Requirement = 'bluetooth'
        Description = 'A Bluetooth adapter is present (heuristic).'
        Subject     = 'a Bluetooth adapter (heuristic)'
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
        Subject     = 'an installed printer that is not a software printer (PDF, XPS, OneNote, fax)'
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
        Subject     = 'a battery (laptop or tablet)'
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
        Subject     = 'the Hyper-V feature, enabled'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V') }
    }
    @{
        Name        = 'wslEnabled'
        Requirement = 'wsl2'
        Description = 'The Windows Subsystem for Linux optional feature is enabled.'
        Subject     = 'the Windows Subsystem for Linux feature, enabled'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('Microsoft-Windows-Subsystem-Linux') }
    }
    @{
        Name        = 'virtualMachinePlatformEnabled'
        Requirement = 'wsl2'
        Description = 'The Virtual Machine Platform optional feature (used by WSL 2) is enabled.'
        Subject     = 'the Virtual Machine Platform feature (used by WSL 2), enabled'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('VirtualMachinePlatform') }
    }
    @{
        Name        = 'windowsSandboxEnabled'
        Requirement = 'windowsSandbox'
        Description = 'The Windows Sandbox optional feature is enabled.'
        Subject     = 'the Windows Sandbox feature, enabled'
        Detect      = { param($Inventory) Test-WinLeanFeatureEnabled -Inventory $Inventory -Names @('Containers-DisposableClientVM') }
    }
    @{
        Name        = 'oneDriveInstalled'
        Requirement = 'onedrive'
        Description = 'OneDrive is installed.'
        Subject     = 'OneDrive, installed'
        Detect      = { param($Inventory) Test-WinLeanApplicationInstalled -Inventory $Inventory -Name 'Microsoft OneDrive' }
    }
    @{
        Name        = 'phoneLinkInstalled'
        Requirement = 'phoneLink'
        Description = 'The Phone Link app is installed.'
        Subject     = 'the Phone Link app, installed'
        Detect      = { param($Inventory) Test-WinLeanAppxInstalled -Inventory $Inventory -Name 'Microsoft.YourPhone' }
    }
    @{
        Name        = 'xboxAppInstalled'
        Requirement = 'xbox'
        Description = 'The Xbox app is installed.'
        Subject     = 'the Xbox app, installed'
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
        [pscustomobject]@{ name = $detector.Name; requirement = $detector.Requirement; description = $detector.Description; subject = $detector.Subject }
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

# ---------------------------------------------------------------------------
# Configuration questionnaire (-Configure)
# ---------------------------------------------------------------------------

# Topics of the questionnaire, in the order they are asked. Requirement keys that are not
# listed (for example keys added to the schema later) are asked under 'Other'.
$script:RequirementGroups = [ordered]@{
    'Devices and peripherals'        = @('printer', 'networkPrinting', 'scanner', 'bluetooth', 'bluetoothAudio', 'touch', 'pen', 'xboxControllers')
    'Gaming'                         = @('gamingMachine', 'xbox', 'gamePass')
    'Microsoft apps and services'    = @('microsoftStore', 'onedrive', 'phoneLink', 'widgets', 'teams', 'copilot', 'windowsSearch')
    'Development and virtualization' = @('developerMachine', 'hyperV', 'wsl2', 'windowsSandbox', 'virtualization', 'docker', 'visualStudio', 'sqlServer')
    'Networking and remote access'   = @('remoteDesktop', 'fileSharing', 'smb')
    'Security and sign-in'           = @('windowsHello', 'bitLocker')
    'Privacy and diagnostics'        = @('locationServices', 'telemetryDiagnostics')
    'Vendor utilities'               = @('gpuVendorUtilities', 'rgbSoftware', 'motherboardUtilities')
}

$script:DefaultCompatibilityDescription = 'Compatibility requirements of this PC, maintained with .\WinLean.ps1 -Configure. true = required (WinLean preserves it), false = not needed (rules may reduce it). Requirements that are not listed are undeclared and treated as required.'

function Get-WinLeanRequirementGroups {
    <#
    .SYNOPSIS
        Returns the questionnaire topics and their requirement keys.
    #>
    [CmdletBinding()]
    param()

    foreach ($name in $script:RequirementGroups.Keys) {
        [pscustomobject]@{ group = $name; keys = [string[]]$script:RequirementGroups[$name] }
    }
}

function Get-WinLeanConfigurationQuestions {
    <#
    .SYNOPSIS
        One question per known requirement, grouped by topic, with detection hints.
    .PARAMETER Definitions
        Requirement definitions (Get-WinLeanRequirementDefinitions): key and description.
    .PARAMETER Capabilities
        Detected capabilities (Get-WinLeanCapabilities). They only produce hints; a
        detected capability never becomes a requirement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Definitions,
        [System.Collections.IDictionary] $Capabilities
    )

    $descriptions = [ordered]@{}
    foreach ($definition in $Definitions) {
        $descriptions[[string]$definition.key] = [string]$definition.description
    }
    $ordered = New-Object -TypeName System.Collections.Generic.List[object]
    $asked = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    foreach ($group in $script:RequirementGroups.Keys) {
        foreach ($key in $script:RequirementGroups[$group]) {
            if ($descriptions.Contains($key) -and $asked.Add($key)) {
                $ordered.Add([pscustomobject]@{ key = $key; group = $group })
            }
        }
    }
    foreach ($key in $descriptions.Keys) {
        if ($asked.Add($key)) {
            $ordered.Add([pscustomobject]@{ key = $key; group = 'Other' })
        }
    }

    foreach ($entry in $ordered) {
        $hints = New-Object -TypeName System.Collections.Generic.List[string]
        foreach ($detector in $script:CapabilityDetectors) {
            if ([string]$detector.Requirement -cne $entry.key) { continue }
            if ($null -eq $Capabilities -or -not (Test-WinLeanDictionaryKey -Dictionary $Capabilities -Key $detector.Name)) { continue }
            if ([bool]$Capabilities[$detector.Name]) {
                $hints.Add("Detected on this PC: $($detector.Subject).")
            }
            else {
                $hints.Add("Not detected on this PC: $($detector.Subject).")
            }
        }
        [pscustomobject]@{
            key         = $entry.key
            group       = $entry.group
            description = $descriptions[$entry.key]
            hints       = $hints.ToArray()
        }
    }
}

function ConvertFrom-WinLeanConfigurationAnswer {
    <#
    .SYNOPSIS
        Interprets one answer: Yes, No, Undeclared, Keep (Enter), Help, Quit, EndOfInput
        ($null, for example when piped input is exhausted) or Invalid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Answer)

    if ($null -eq $Answer) {
        return 'EndOfInput'
    }
    switch -CaseSensitive (([string]$Answer).Trim().ToLowerInvariant()) {
        '' { return 'Keep' }
        'y' { return 'Yes' }
        'yes' { return 'Yes' }
        'n' { return 'No' }
        'no' { return 'No' }
        'u' { return 'Undeclared' }
        'undeclared' { return 'Undeclared' }
        '?' { return 'Help' }
        'help' { return 'Help' }
        'q' { return 'Quit' }
        'quit' { return 'Quit' }
    }
    return 'Invalid'
}

function Format-WinLeanRequirementAnswer {
    <#
    .SYNOPSIS
        "required (Yes)", "not needed (No)" or "undeclared (treated as required)".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return 'undeclared (treated as required)' }
    if ([bool]$Value) { return 'required (Yes)' }
    return 'not needed (No)'
}

function Invoke-WinLeanRequirementQuestionnaire {
    <#
    .SYNOPSIS
        Asks every question and returns the new answers. Nothing is written to disk.
    .PARAMETER Current
        Current answers: dictionary key -> $true / $false. Undeclared keys are absent.
    .PARAMETER ReadAnswer
        Script block that receives the prompt and returns the answer ($null = end of input).
    .PARAMETER WriteLine
        Script block that receives one line of text to show.
    .OUTPUTS
        Object with answers (ordered dictionary of declared keys), asked (questions
        answered) and stopped ($true when the user stopped early or the input ended; the
        remaining answers are unchanged).
    .NOTES
        Pressing Enter keeps the current answer, so a detection hint never turns into a
        requirement unless the user answers the question.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Questions,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $Current,
        [Parameter(Mandatory)] [scriptblock] $ReadAnswer,
        [Parameter(Mandatory)] [scriptblock] $WriteLine
    )

    $answers = [ordered]@{}
    foreach ($key in @($Current.Keys)) {
        $answers[[string]$key] = [bool]$Current[$key]
    }
    $prompt = '  Needed on this PC? [Y] Yes  [N] No  [U] Leave undeclared  [Enter] Keep  [?] Help  [Q] Stop'
    $total = $Questions.Count
    $group = $null
    $asked = 0
    $stopped = $false
    for ($index = 0; $index -lt $total -and -not $stopped; $index++) {
        $question = $Questions[$index]
        if ($question.group -cne $group) {
            $group = $question.group
            & $WriteLine ''
            & $WriteLine "== $group =="
        }
        & $WriteLine ''
        & $WriteLine ('[{0}/{1}] {2} - {3}' -f ($index + 1), $total, $question.key, $question.description)
        foreach ($hint in @($question.hints)) {
            & $WriteLine "  $hint"
        }
        $currentValue = if ($answers.Contains($question.key)) { $answers[$question.key] } else { $null }
        & $WriteLine ('  Current answer: ' + (Format-WinLeanRequirementAnswer -Value $currentValue))

        $answered = $false
        while (-not $answered) {
            $answer = ConvertFrom-WinLeanConfigurationAnswer -Answer (& $ReadAnswer $prompt)
            if ($answer -ceq 'Yes') {
                $answers[$question.key] = $true
                $answered = $true
            }
            elseif ($answer -ceq 'No') {
                $answers[$question.key] = $false
                $answered = $true
            }
            elseif ($answer -ceq 'Undeclared') {
                $answers.Remove($question.key)
                $answered = $true
            }
            elseif ($answer -ceq 'Keep') {
                $answered = $true
            }
            elseif ($answer -ceq 'Help') {
                & $WriteLine '  Y      this PC needs it. WinLean preserves it: rules that would reduce it are skipped.'
                & $WriteLine '  N      not needed. Rules that reduce it may be applied (always after your confirmation).'
                & $WriteLine '  U      undecided. Treated exactly like Y, but shown as undeclared.'
                & $WriteLine '  Enter  keep the current answer. Detection hints never change an answer by themselves.'
                & $WriteLine '  Q      stop asking. The remaining answers stay as they are; you can still review and save.'
            }
            elseif ($answer -ceq 'Quit' -or $answer -ceq 'EndOfInput') {
                $stopped = $true
                $answered = $true
            }
            else {
                & $WriteLine '  Please answer Y, N, U, Enter, ? or Q.'
            }
        }
        if (-not $stopped) {
            $asked++
        }
    }
    return [pscustomobject]@{
        answers = $answers
        asked   = $asked
        stopped = $stopped
    }
}

function Get-WinLeanRequirementChanges {
    <#
    .SYNOPSIS
        Lists the requirements whose answer differs between two answer sets, in the given
        key order. Values are $true, $false or $null (undeclared).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $Before,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $After,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Keys
    )

    foreach ($key in $Keys) {
        $old = if (Test-WinLeanDictionaryKey -Dictionary $Before -Key $key) { [bool]$Before[$key] } else { $null }
        $new = if (Test-WinLeanDictionaryKey -Dictionary $After -Key $key) { [bool]$After[$key] } else { $null }
        if (($null -eq $old) -ne ($null -eq $new) -or ($null -ne $old -and $old -ne $new)) {
            [pscustomobject]@{ key = $key; before = $old; after = $new }
        }
    }
}

function Read-WinLeanCompatibilityDocument {
    <#
    .SYNOPSIS
        Reads a compatibility file for editing.
    .DESCRIPTION
        Answers for known requirements and entries with unknown keys are returned
        separately, both in file order; unknown entries are kept unchanged when the file is
        saved again (they may come from a newer WinLean version or be typos the user wants
        to fix). A file with errors is refused, so that -Configure never discards content
        it does not understand.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $KnownRequirementKeys
    )

    $fullPath = Resolve-WinLeanPath -Path $Path
    $document = [pscustomobject]@{
        path            = $fullPath
        exists          = $false
        schemaReference = $null
        description     = $script:DefaultCompatibilityDescription
        requirements    = [ordered]@{}
        unknown         = [ordered]@{}
        warnings        = @()
    }
    if (-not [System.IO.File]::Exists($fullPath)) {
        return $document
    }
    # An existing file keeps exactly the description it has (or none).
    $document.description = $null

    $definition = Read-WinLeanJsonFile -Path $fullPath
    $issues = @(Test-WinLeanCompatibilityDefinition -Definition $definition -Source $fullPath -KnownRequirementKeys $KnownRequirementKeys)
    $errors = @($issues | Where-Object { $_.severity -eq 'Error' })
    if ($errors.Count -gt 0) {
        $details = ($errors | ForEach-Object { $_.message }) -join ' '
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "The compatibility configuration '$fullPath' has errors and was not changed: $details Fix or remove the file, then run -Configure again.")
    }

    $document.exists = $true
    $schemaReference = Get-WinLeanProperty -InputObject $definition -Name '$schema'
    if ($schemaReference -is [string] -and $schemaReference.Length -gt 0) {
        $document.schemaReference = $schemaReference
    }
    $description = Get-WinLeanProperty -InputObject $definition -Name 'description'
    if ($description -is [string] -and $description.Length -gt 0) {
        $document.description = $description
    }
    $values = Get-WinLeanProperty -InputObject $definition -Name 'requirements'
    foreach ($key in @(Get-WinLeanPropertyNames -InputObject $values)) {
        $value = [bool](Get-WinLeanProperty -InputObject $values -Name $key)
        if (-not $KnownRequirementKeys -or $KnownRequirementKeys -ccontains $key) {
            $document.requirements[$key] = $value
        }
        else {
            $document.unknown[$key] = $value
        }
    }
    $document.warnings = @($issues | Where-Object { $_.severity -eq 'Warning' })
    return $document
}

function ConvertTo-WinLeanJsonStringLiteral {
    <#
    .SYNOPSIS
        Encodes a string as a JSON string literal (quotes included). The same output on
        every PowerShell version.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    $builder = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($Value.Length + 2)
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($character -eq '"') { [void]$builder.Append('\"') }
        elseif ($character -eq '\') { [void]$builder.Append('\\') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -lt 32) { [void]$builder.Append('\u' + $code.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture)) }
        else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-WinLeanCompatibilityJson {
    <#
    .SYNOPSIS
        Renders a compatibility document with stable, readable formatting.
    .PARAMETER Requirements
        Ordered dictionary key -> boolean, in the order the keys should appear.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $SchemaReference,
        [AllowNull()] [string] $Description,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $Requirements
    )

    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    $lines.Add('{')
    if ($SchemaReference) {
        $lines.Add('  "$schema": ' + (ConvertTo-WinLeanJsonStringLiteral -Value $SchemaReference) + ',')
    }
    $lines.Add('  "schemaVersion": 1,')
    if ($Description) {
        $lines.Add('  "description": ' + (ConvertTo-WinLeanJsonStringLiteral -Value $Description) + ',')
    }
    $keys = @($Requirements.Keys)
    if ($keys.Count -eq 0) {
        $lines.Add('  "requirements": {}')
    }
    else {
        $lines.Add('  "requirements": {')
        for ($index = 0; $index -lt $keys.Count; $index++) {
            $value = $Requirements[$keys[$index]]
            if ($value -isnot [bool]) {
                throw (New-Object -TypeName System.ArgumentException -ArgumentList "Requirement '$($keys[$index])' must be true or false.")
            }
            $separator = if ($index -lt $keys.Count - 1) { ',' } else { '' }
            $lines.Add('    ' + (ConvertTo-WinLeanJsonStringLiteral -Value ([string]$keys[$index])) + ': ' + $(if ($value) { 'true' } else { 'false' }) + $separator)
        }
        $lines.Add('  }')
    }
    $lines.Add('}')
    return (($lines.ToArray() -join "`n") + "`n")
}

function Get-WinLeanSchemaReference {
    <#
    .SYNOPSIS
        The relative path from a configuration file to a schema file ('$schema'), or $null
        when the two are on different drives.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ConfigurationPath,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $directory = [System.IO.Path]::GetDirectoryName((Resolve-WinLeanPath -Path $ConfigurationPath)).TrimEnd('\') + '\'
    $from = New-Object -TypeName System.Uri -ArgumentList $directory
    $to = New-Object -TypeName System.Uri -ArgumentList (Resolve-WinLeanPath -Path $SchemaPath)
    $relative = $from.MakeRelativeUri($to)
    if ($relative.IsAbsoluteUri) {
        return $null
    }
    return [System.Uri]::UnescapeDataString($relative.ToString())
}

function Save-WinLeanCompatibility {
    <#
    .SYNOPSIS
        Writes a compatibility file atomically, after validating the new content.
    .DESCRIPTION
        The content is written to a temporary file next to the target, read back and
        validated (and compared with the intended answers). Only then is the target
        replaced in one step; the previous content is kept as '<name>.previous.json'. If
        anything fails, the existing file is left untouched.
    .PARAMETER Requirements
        Answers for known requirements (key -> boolean); written in KnownRequirementKeys order.
    .PARAMETER Unknown
        Entries with unknown keys from the existing file; written unchanged after the known keys.
    .OUTPUTS
        Object with path and previousPath ($null when no file existed before).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $Requirements,
        [AllowEmptyCollection()] [System.Collections.IDictionary] $Unknown = @{},
        [AllowNull()] [string] $Description,
        [AllowNull()] [string] $SchemaReference,
        [Parameter(Mandatory)] [string[]] $KnownRequirementKeys
    )

    $fullPath = Resolve-WinLeanPath -Path $Path
    $ordered = [ordered]@{}
    foreach ($key in $KnownRequirementKeys) {
        if (Test-WinLeanDictionaryKey -Dictionary $Requirements -Key $key) {
            $ordered[$key] = $Requirements[$key]
        }
    }
    foreach ($key in @($Requirements.Keys)) {
        if ($KnownRequirementKeys -cnotcontains [string]$key) {
            throw (New-Object -TypeName System.ArgumentException -ArgumentList "Unknown requirement '$key'; known requirements are listed in Schemas/compatibility.schema.json.")
        }
    }
    foreach ($key in @($Unknown.Keys)) {
        if (-not $ordered.Contains([string]$key)) {
            $ordered[[string]$key] = $Unknown[$key]
        }
    }
    $json = ConvertTo-WinLeanCompatibilityJson -SchemaReference $SchemaReference -Description $Description -Requirements $ordered

    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }
    $temporaryPath = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

        # Validate exactly what is on disk before it replaces anything.
        $written = Read-WinLeanJsonFile -Path $temporaryPath
        $errors = @(Test-WinLeanCompatibilityDefinition -Definition $written -Source $fullPath -KnownRequirementKeys $KnownRequirementKeys | Where-Object { $_.severity -eq 'Error' })
        if ($errors.Count -gt 0) {
            throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList ('The new compatibility configuration is invalid and was not saved: ' + (($errors | ForEach-Object { $_.message }) -join ' ')))
        }
        $writtenValues = Get-WinLeanProperty -InputObject $written -Name 'requirements'
        $writtenKeys = @(Get-WinLeanPropertyNames -InputObject $writtenValues)
        if ($writtenKeys.Count -ne $ordered.Count) {
            throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList 'The new compatibility configuration could not be read back completely and was not saved.')
        }
        foreach ($key in @($ordered.Keys)) {
            if ((Get-WinLeanProperty -InputObject $writtenValues -Name $key) -ne $ordered[$key]) {
                throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Requirement '$key' was not written correctly; the configuration was not saved.")
            }
        }

        $previousPath = $null
        if ([System.IO.File]::Exists($fullPath)) {
            $previousPath = Join-Path -Path $directory -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($fullPath) + '.previous.json')
            [System.IO.File]::Replace($temporaryPath, $fullPath, $previousPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
        return [pscustomobject]@{ path = $fullPath; previousPath = $previousPath }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
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
    'Get-WinLeanRequirementGroups'
    'Get-WinLeanConfigurationQuestions'
    'ConvertFrom-WinLeanConfigurationAnswer'
    'Format-WinLeanRequirementAnswer'
    'Invoke-WinLeanRequirementQuestionnaire'
    'Get-WinLeanRequirementChanges'
    'Read-WinLeanCompatibilityDocument'
    'ConvertTo-WinLeanCompatibilityJson'
    'Get-WinLeanSchemaReference'
    'Save-WinLeanCompatibility'
)
