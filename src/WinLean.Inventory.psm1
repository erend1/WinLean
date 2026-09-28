#Requires -Version 5.1
<#
    WinLean.Inventory
    -----------------
    Read-only system inventory.

    Every section is collected independently. A section that fails, or that needs
    privileges the current process does not have, is recorded as unavailable together
    with the reason (RequiresAdministrator, NotInstalled, NotSupported, Skipped or
    Error). One unavailable section never fails the inventory.

    Heuristics are labelled as such in the data:
      * service/task vendor: file CompanyName metadata (self-declared, not signature-verified)
      * startup approval: undocumented StartupApproved data (odd first byte = disabled)
      * Bluetooth adapter presence: Bluetooth-class devices not enumerated by the
        Bluetooth stack itself
      * virtual printers: well-known software printer ports
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:UninstallSubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$script:ExcludedReleaseTypes = @('Update', 'Hotfix', 'Security Update', 'Update Rollup', 'Service Pack')
$script:VirtualPrinterPorts = @('PORTPROMPT:', 'NUL:', 'SHRFAX:', 'FILE:', 'XPSPORT:')

# Section name -> collector. The order is the order of the inventory document.
$script:SectionCollectors = [ordered]@{
    system                  = 'Get-WinLeanSystemInventory'
    security                = 'Get-WinLeanSecurityInventory'
    hardware                = 'Get-WinLeanHardwareInventory'
    appxPackages            = 'Get-WinLeanAppxInventory'
    provisionedAppxPackages = 'Get-WinLeanProvisionedAppxInventory'
    win32Applications       = 'Get-WinLeanWin32ApplicationInventory'
    wingetPackages          = 'Get-WinLeanWinGetInventory'
    optionalFeatures        = 'Get-WinLeanOptionalFeatureInventory'
    startup                 = 'Get-WinLeanStartupInventory'
    services                = 'Get-WinLeanServiceInventory'
    scheduledTasks          = 'Get-WinLeanScheduledTaskInventory'
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Get-WinLeanInventorySections {
    <#
    .SYNOPSIS
        Lists the inventory section names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @($script:SectionCollectors.Keys)
}

function Get-WinLeanInventory {
    <#
    .SYNOPSIS
        Collects the system inventory.
    .PARAMETER Section
        Sections to collect (default: all). Other sections are recorded as Skipped.
    .PARAMETER ExcludeSection
        Sections not to collect, for example wingetPackages (slow; contacts sources).
    .PARAMETER OnSection
        Optional callback invoked after each section with the section name and result
        (used by the caller for progress logging).
    #>
    [CmdletBinding()]
    param(
        [string[]] $Section,
        [string[]] $ExcludeSection,
        [scriptblock] $OnSection
    )

    $known = @($script:SectionCollectors.Keys)
    foreach ($name in @($Section) + @($ExcludeSection)) {
        if ($name -and $known -notcontains $name) {
            throw (New-Object -TypeName System.ArgumentException -ArgumentList "Unknown inventory section '$name'. Known sections: $($known -join ', ').")
        }
    }

    $isAdministrator = Test-WinLeanAdministrator
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $sections = [ordered]@{}
    foreach ($name in $known) {
        $selected = (-not $Section -or $Section -contains $name) -and -not ($ExcludeSection -contains $name)
        if ($selected) {
            $result = Invoke-WinLeanInventoryCollector -Command $script:SectionCollectors[$name] -IsAdministrator $isAdministrator
        }
        else {
            $result = New-WinLeanUnavailableResult -Reason 'Skipped' -Message 'Not collected in this run.'
        }
        $sections[$name] = $result
        if ($OnSection) {
            $null = & $OnSection $name $result
        }
    }

    return [pscustomobject]@{
        schemaVersion   = 1
        winLeanVersion  = Get-WinLeanVersion
        collectedAt     = Get-WinLeanTimestamp
        durationMs      = $stopwatch.ElapsedMilliseconds
        isAdministrator = $isAdministrator
        sections        = [pscustomobject]$sections
    }
}

function New-WinLeanUnavailableResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string] $Message,
        [long] $DurationMs = 0
    )

    return [pscustomobject]@{
        available  = $false
        reason     = $Reason
        message    = $Message
        durationMs = $DurationMs
        data       = $null
    }
}

function New-WinLeanUnavailableException {
    <#
    .SYNOPSIS
        Creates an exception that marks data as unavailable for an explicit reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RequiresAdministrator', 'NotInstalled', 'NotSupported')]
        [string] $Reason,

        [Parameter(Mandatory)] [string] $Message
    )

    $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList $Message
    $exception.Data['WinLeanUnavailableReason'] = $Reason
    return $exception
}

function Get-WinLeanUnavailableReason {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $ErrorObject)

    $exception = $ErrorObject
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorObject.Exception
    }
    for ($current = $exception; $null -ne $current; $current = $current.InnerException) {
        if ($current.Data.Contains('WinLeanUnavailableReason')) {
            return [string]$current.Data['WinLeanUnavailableReason']
        }
    }
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord] -and ([string]$ErrorObject.FullyQualifiedErrorId).StartsWith('CommandNotFoundException', [System.StringComparison]::Ordinal)) {
        return 'NotInstalled'
    }
    switch (Get-WinLeanFailureClass -ErrorObject $ErrorObject) {
        'PermissionDenied' { return 'RequiresAdministrator' }
        'Unsupported' { return 'NotSupported' }
    }
    return 'Error'
}

function Invoke-WinLeanInventoryCollector {
    <#
    .SYNOPSIS
        Runs one collector and wraps its result: available, reason, message, durationMs, data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [bool] $IsAdministrator
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $data = & $Command -IsAdministrator $IsAdministrator
        return [pscustomobject]@{
            available  = $true
            reason     = $null
            message    = $null
            durationMs = $stopwatch.ElapsedMilliseconds
            data       = $data
        }
    }
    catch {
        $failure = ConvertTo-WinLeanFailure -ErrorObject $_
        return New-WinLeanUnavailableResult -Reason (Get-WinLeanUnavailableReason -ErrorObject $_) -Message $failure.message -DurationMs $stopwatch.ElapsedMilliseconds
    }
}

function Invoke-WinLeanProbe {
    <#
    .SYNOPSIS
        Runs a script block that returns one data object and wraps the result like a section.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock] $ScriptBlock)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $data = & $ScriptBlock
        return [pscustomobject]@{ available = $true; reason = $null; message = $null; durationMs = $stopwatch.ElapsedMilliseconds; data = $data }
    }
    catch {
        $failure = ConvertTo-WinLeanFailure -ErrorObject $_
        return New-WinLeanUnavailableResult -Reason (Get-WinLeanUnavailableReason -ErrorObject $_) -Message $failure.message -DurationMs $stopwatch.ElapsedMilliseconds
    }
}

function Get-WinLeanInventorySection {
    <#
    .SYNOPSIS
        Returns the data of an available section, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Inventory,
        [Parameter(Mandatory)] [string] $Name
    )

    $sections = Get-WinLeanProperty -InputObject $Inventory -Name 'sections'
    $section = Get-WinLeanProperty -InputObject $sections -Name $Name
    if ($null -eq $section -or -not [bool](Get-WinLeanProperty -InputObject $section -Name 'available' -Default $false)) {
        return $null
    }
    return $section.data
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function ConvertTo-WinLeanIsoTime {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetime]) {
        if ($Value -eq [datetime]::MinValue) {
            return $null
        }
        return ([System.DateTimeOffset]$Value).ToString('o', $script:Invariant)
    }
    return [string]$Value
}

function Sort-WinLeanByName {
    <#
    .SYNOPSIS
        Ordinal, case-insensitive sort of objects by a string property (culture independent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $InputObject,
        [string] $Property = 'name'
    )

    $items = [object[]]$InputObject.Clone()
    $keys = [string[]]@(foreach ($item in $items) { [string](Get-WinLeanProperty -InputObject $item -Name $Property -Default '') })
    [System.Array]::Sort($keys, $items, [System.StringComparer]::OrdinalIgnoreCase)
    $items
}

function Open-WinLeanRegistryView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.Win32.RegistryHive] $Hive,
        [Parameter(Mandatory)] [Microsoft.Win32.RegistryView] $View
    )

    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
}

function Get-WinLeanExecutablePath {
    <#
    .SYNOPSIS
        Extracts the executable path from a service or task command line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }
    $text = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -le 1) {
            return $null
        }
        $text = $text.Substring(1, $end - 1)
    }
    else {
        $index = $text.IndexOf('.exe', [System.StringComparison]::OrdinalIgnoreCase)
        if ($index -ge 0) {
            $text = $text.Substring(0, $index + 4)
        }
        else {
            $space = $text.IndexOf(' ')
            if ($space -gt 0) {
                $text = $text.Substring(0, $space)
            }
        }
    }
    if ($text.StartsWith('\??\')) {
        $text = $text.Substring(4)
    }
    if ($text.StartsWith('\SystemRoot\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $text = Join-Path -Path $env:SystemRoot -ChildPath $text.Substring('\SystemRoot\'.Length)
    }
    elseif (-not [System.IO.Path]::IsPathRooted($text)) {
        $text = Join-Path -Path $env:SystemRoot -ChildPath $text
    }
    return $text
}

function Get-WinLeanFileCompany {
    <#
    .SYNOPSIS
        Returns the vendor name of a file (cached): the CompanyName version resource, or,
        when that is empty, the organization of a valid Authenticode signature.
    .OUTPUTS
        Object with name and source ('CompanyName', 'Signature' or $null).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Cache
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ name = $null; source = $null }
    }
    if (Test-WinLeanDictionaryKey -Dictionary $Cache -Key $Path) {
        return $Cache[$Path]
    }
    $result = [pscustomobject]@{ name = $null; source = $null }
    if ([System.IO.File]::Exists($Path)) {
        try {
            $company = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).CompanyName
            if (-not [string]::IsNullOrWhiteSpace($company)) {
                $result = [pscustomobject]@{ name = $company.Trim(); source = 'CompanyName' }
            }
        }
        catch {
            Write-Verbose "Cannot read version information of '$Path': $($_.Exception.Message)"
        }
        if ($null -eq $result.name) {
            try {
                $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
                if ([string]$signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate) {
                    $commonName = Get-WinLeanDistinguishedNameValue -DistinguishedName $signature.SignerCertificate.Subject -Attribute 'CN'
                    if ($commonName -eq 'Microsoft Windows Hardware Compatibility Publisher') {
                        # WHQL: Microsoft signs certified third-party driver packages; the signature
                        # does not identify the actual vendor.
                        $result = [pscustomobject]@{ name = 'Third-party (WHQL-signed driver package)'; source = 'Signature' }
                        $Cache[$Path] = $result
                        return $result
                    }
                    $organization = Get-WinLeanDistinguishedNameValue -DistinguishedName $signature.SignerCertificate.Subject -Attribute 'O'
                    if (-not $organization) {
                        $organization = Get-WinLeanDistinguishedNameValue -DistinguishedName $signature.SignerCertificate.Subject -Attribute 'CN'
                    }
                    if ($organization) {
                        $result = [pscustomobject]@{ name = $organization; source = 'Signature' }
                    }
                }
            }
            catch {
                Write-Verbose "Cannot read the signature of '$Path': $($_.Exception.Message)"
            }
        }
    }
    $Cache[$Path] = $result
    return $result
}

function Get-WinLeanDistinguishedNameValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $DistinguishedName,
        [Parameter(Mandatory)] [string] $Attribute
    )

    if ([string]::IsNullOrEmpty($DistinguishedName)) {
        return $null
    }
    $pattern = '(?:^|,\s*)' + [System.Text.RegularExpressions.Regex]::Escape($Attribute) + '=(?:"(?<quoted>[^"]*)"|(?<plain>[^,]*))'
    $match = [System.Text.RegularExpressions.Regex]::Match($DistinguishedName, $pattern, 'CultureInvariant')
    if (-not $match.Success) {
        return $null
    }
    $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    return $value.Trim()
}

function Get-WinLeanServiceRegistryValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ServiceName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SubKey,
        [Parameter(Mandatory)] [string] $ValueName
    )

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$ServiceName$SubKey", $false)
        if ($null -eq $key) {
            return $null
        }
        $value = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) {
            return $null
        }
        return [Environment]::ExpandEnvironmentVariables([string]$value)
    }
    catch {
        Write-Verbose "Cannot read $ValueName of service '$ServiceName': $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Get-WinLeanVendorClass {
    <#
    .SYNOPSIS
        Classifies a vendor from a CompanyName: Microsoft, ThirdParty or Unknown.
    .NOTES
        Heuristic: CompanyName is self-declared file metadata, not a verified signature.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $CompanyName)

    if ([string]::IsNullOrWhiteSpace($CompanyName)) {
        return 'Unknown'
    }
    if (Test-WinLeanTextContains -Text $CompanyName -Value 'Microsoft') {
        return 'Microsoft'
    }
    return 'ThirdParty'
}

function Get-WinLeanStartupApproval {
    <#
    .SYNOPSIS
        Interprets StartupApproved data as shown in Task Manager.
    .NOTES
        The format is undocumented. Observed data: first byte 0x02/0x06 for enabled items and
        0x03/0x07 for disabled ones, so the low bit of the first byte is used. No value
        means Windows never recorded a choice and the item runs (NotSet).
    #>
    [CmdletBinding()]
    param([AllowNull()] [byte[]] $Data)

    if ($null -eq $Data -or $Data.Length -eq 0) {
        return [pscustomobject]@{ approval = 'NotSet'; raw = $null }
    }
    $state = if (($Data[0] -band 1) -eq 1) { 'Disabled' } else { 'Enabled' }
    return [pscustomobject]@{ approval = $state; raw = ('{0:x2}' -f $Data[0]) }
}

# ---------------------------------------------------------------------------
# Section collectors
# ---------------------------------------------------------------------------

function Get-WinLeanSystemInventory {
    <#
    .SYNOPSIS
        Windows edition, version and build, architecture, CPU, RAM, GPU, board and firmware.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $os = Get-WinLeanPlatform

    $computer = Invoke-WinLeanProbe {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        [pscustomobject]@{
            manufacturer          = [string]$system.Manufacturer
            model                 = [string]$system.Model
            baseboardManufacturer = if ($board) { [string]$board.Manufacturer } else { $null }
            baseboardProduct      = if ($board) { [string]$board.Product } else { $null }
            firmwareType          = $env:firmware_type
        }
    }

    $cpu = Invoke-WinLeanProbe {
        $processors = @(foreach ($processor in @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)) {
                [pscustomobject]@{
                    name              = ([string]$processor.Name).Trim()
                    manufacturer      = [string]$processor.Manufacturer
                    cores             = [int]$processor.NumberOfCores
                    logicalProcessors = [int]$processor.NumberOfLogicalProcessors
                    maxClockMHz       = [int]$processor.MaxClockSpeed
                }
            })
        [pscustomobject]@{ processors = $processors }
    }

    $memory = Invoke-WinLeanProbe {
        [uint64]$installed = 0
        $moduleCount = 0
        foreach ($module in @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)) {
            $installed += [uint64]$module.Capacity
            $moduleCount++
        }
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        [pscustomobject]@{
            installedBytes = $installed
            moduleCount    = $moduleCount
            visibleBytes   = [uint64]$operatingSystem.TotalVisibleMemorySize * 1024
        }
    }

    $gpu = Invoke-WinLeanProbe {
        # AdapterRAM is a 32-bit field that is wrong above 4 GB, so it is not reported.
        $adapters = @(foreach ($adapter in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
                [pscustomobject]@{
                    name          = [string]$adapter.Name
                    driverVersion = [string]$adapter.DriverVersion
                    status        = [string]$adapter.Status
                }
            })
        [pscustomobject]@{ adapters = $adapters }
    }

    $lastBoot = $null
    try {
        $lastBoot = ConvertTo-WinLeanIsoTime -Value (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    }
    catch {
        Write-Verbose "Last boot time unavailable: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        os           = $os
        computer     = $computer
        cpu          = $cpu
        memory       = $memory
        gpu          = $gpu
        lastBootTime = $lastBoot
    }
}

function Get-WinLeanSecurityInventory {
    <#
    .SYNOPSIS
        Security posture (recorded only; WinLean never weakens these):
        Defender, Firewall, Secure Boot, VBS, BitLocker, registered antivirus products.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $defender = Invoke-WinLeanProbe {
        $status = Get-MpComputerStatus -ErrorAction Stop
        [pscustomobject]@{
            amServiceEnabled          = [bool]$status.AMServiceEnabled
            antivirusEnabled          = [bool]$status.AntivirusEnabled
            realTimeProtectionEnabled = [bool]$status.RealTimeProtectionEnabled
            runningMode               = [string](Get-WinLeanProperty -InputObject $status -Name 'AMRunningMode')
            isTamperProtected         = Get-WinLeanProperty -InputObject $status -Name 'IsTamperProtected'
            signatureLastUpdated      = ConvertTo-WinLeanIsoTime -Value $status.AntivirusSignatureLastUpdated
            productVersion            = [string]$status.AMProductVersion
        }
    }

    $firewall = Invoke-WinLeanProbe {
        $profiles = @(foreach ($firewallProfile in @(Get-NetFirewallProfile -ErrorAction Stop)) {
                $enabled = [string]$firewallProfile.Enabled
                [pscustomobject]@{
                    name    = [string]$firewallProfile.Name
                    enabled = if ($enabled -eq 'True') { $true } elseif ($enabled -eq 'False') { $false } else { $null }
                }
            })
        [pscustomobject]@{ profiles = $profiles }
    }

    $secureBoot = Invoke-WinLeanProbe {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\SecureBoot\State', $false)
        if ($null -eq $key) {
            [pscustomobject]@{ state = 'NotSupported'; enabled = $null; source = 'registry' }
        }
        else {
            try {
                $value = $key.GetValue('UEFISecureBootEnabled')
                $state = if ($null -eq $value) { 'Unknown' } elseif ([int]$value -eq 1) { 'Enabled' } else { 'Disabled' }
                [pscustomobject]@{ state = $state; enabled = if ($null -eq $value) { $null } else { [int]$value -eq 1 }; source = 'registry' }
            }
            finally {
                $key.Dispose()
            }
        }
    }

    $vbs = Invoke-WinLeanProbe {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $statusNames = @{ 0 = 'Off'; 1 = 'EnabledNotRunning'; 2 = 'Running' }
        $serviceNames = @{ 1 = 'CredentialGuard'; 2 = 'MemoryIntegrity'; 3 = 'SystemGuardSecureLaunch'; 4 = 'SmmFirmwareMeasurement' }
        $running = @(foreach ($service in @($deviceGuard.SecurityServicesRunning)) {
                $number = [int]$service
                if ($number -eq 0) { continue }
                if ($serviceNames.ContainsKey($number)) { $serviceNames[$number] } else { "Service$number" }
            })
        $status = [int]$deviceGuard.VirtualizationBasedSecurityStatus
        [pscustomobject]@{
            status          = if ($statusNames.ContainsKey($status)) { $statusNames[$status] } else { "Unknown$status" }
            servicesRunning = [string[]]$running
        }
    }

    if ($IsAdministrator) {
        $bitLocker = Invoke-WinLeanProbe {
            $volumes = @(foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop)) {
                    [pscustomobject]@{
                        mountPoint           = [string]$volume.MountPoint
                        volumeType           = [string]$volume.VolumeType
                        protectionStatus     = [string]$volume.ProtectionStatus
                        volumeStatus         = [string]$volume.VolumeStatus
                        encryptionPercentage = [double]$volume.EncryptionPercentage
                    }
                })
            [pscustomobject]@{ volumes = $volumes }
        }
    }
    else {
        $bitLocker = New-WinLeanUnavailableResult -Reason 'RequiresAdministrator' -Message 'BitLocker status requires Administrator rights.'
    }

    $antivirus = Invoke-WinLeanProbe {
        $products = @(foreach ($product in @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
                [string]$product.displayName
            })
        [pscustomobject]@{ products = [string[]]$products }
    }

    return [pscustomobject]@{
        defender                    = $defender
        firewall                    = $firewall
        secureBoot                  = $secureBoot
        virtualizationBasedSecurity = $vbs
        bitLocker                   = $bitLocker
        antivirusProducts           = $antivirus
    }
}

function Get-WinLeanHardwareInventory {
    <#
    .SYNOPSIS
        Hardware facts used for capability detection: Bluetooth adapters, battery, printers.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $bluetooth = Invoke-WinLeanProbe {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass = 'Bluetooth'" -ErrorAction Stop)
        $adapters = @(foreach ($device in $devices) {
                $deviceId = [string]$device.DeviceID
                if (-not $deviceId.StartsWith('BTH', [System.StringComparison]::OrdinalIgnoreCase)) {
                    [pscustomobject]@{ name = [string]$device.Name; status = [string]$device.Status; bus = $deviceId.Split('\')[0] }
                }
            })
        [pscustomobject]@{
            adapterPresent = ($adapters.Count -gt 0)
            adapters       = $adapters
            deviceCount    = $devices.Count
            method         = 'Heuristic: Bluetooth-class devices whose device id does not start with BTH (radios, not paired devices).'
        }
    }

    $battery = Invoke-WinLeanProbe {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        [pscustomobject]@{ present = ($batteries.Count -gt 0); count = $batteries.Count }
    }

    $printers = Invoke-WinLeanProbe {
        $items = @(foreach ($printer in @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop)) {
                $port = [string]$printer.PortName
                [pscustomobject]@{
                    name       = [string]$printer.Name
                    driverName = [string]$printer.DriverName
                    portName   = $port
                    network    = [bool]$printer.Network
                    isDefault  = [bool]$printer.Default
                    isVirtual  = ($script:VirtualPrinterPorts -contains $port.ToUpperInvariant())
                }
            })
        [pscustomobject]@{
            printers      = $items
            physicalCount = @($items | Where-Object { -not $_.isVirtual }).Count
            method        = "Heuristic: printers on ports $($script:VirtualPrinterPorts -join ', ') are treated as virtual."
        }
    }

    return [pscustomobject]@{
        bluetooth = $bluetooth
        battery   = $battery
        printers  = $printers
    }
}

function Get-WinLeanAppxPackage {
    <#
    .SYNOPSIS
        Calls Get-AppxPackage, falling back to Windows PowerShell compatibility on
        PowerShell 7 hosts where the Appx module cannot load natively.
    #>
    [CmdletBinding()]
    param()

    try {
        Get-AppxPackage -ErrorAction Stop
    }
    catch {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            throw
        }
        Write-Verbose "Get-AppxPackage failed natively ($($_.Exception.Message)); retrying through Windows PowerShell compatibility."
        Import-Module -Name Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
        Get-AppxPackage -ErrorAction Stop
    }
}

function Get-WinLeanAppxInventory {
    <#
    .SYNOPSIS
        AppX / MSIX packages installed for the current user.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $packages = @(foreach ($package in @(Get-WinLeanAppxPackage)) {
            [pscustomobject]@{
                name              = [string]$package.Name
                version           = [string]$package.Version
                architecture      = [string]$package.Architecture
                packageFamilyName = [string]$package.PackageFamilyName
                publisherId       = [string]$package.PublisherId
                signatureKind     = [string](Get-WinLeanProperty -InputObject $package -Name 'SignatureKind')
                isFramework       = [bool](Get-WinLeanProperty -InputObject $package -Name 'IsFramework' -Default $false)
                nonRemovable      = [bool](Get-WinLeanProperty -InputObject $package -Name 'NonRemovable' -Default $false)
            }
        })
    return [pscustomobject]@{
        scope    = 'CurrentUser'
        count    = $packages.Count
        packages = @(Sort-WinLeanByName -InputObject $packages)
    }
}

function Get-WinLeanProvisionedAppxInventory {
    <#
    .SYNOPSIS
        AppX packages provisioned for new user profiles (requires Administrator rights).
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    if (-not $IsAdministrator) {
        throw (New-WinLeanUnavailableException -Reason RequiresAdministrator -Message 'Listing provisioned packages requires Administrator rights (DISM).')
    }
    $packages = @(foreach ($package in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) {
            [pscustomobject]@{
                name        = [string]$package.DisplayName
                packageName = [string]$package.PackageName
                version     = [string]$package.Version
            }
        })
    return [pscustomobject]@{
        count    = $packages.Count
        packages = @(Sort-WinLeanByName -InputObject $packages)
    }
}

function Get-WinLeanWin32ApplicationInventory {
    <#
    .SYNOPSIS
        Installed Win32 applications from the Uninstall registry keys.
    .NOTES
        Win32_Product is deliberately not used: querying it triggers Windows Installer
        consistency checks (and possible repairs) for every MSI product.
        System components, updates and child entries are excluded, like in Settings.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $sources = New-Object -TypeName System.Collections.Generic.List[object]
    if ([Environment]::Is64BitOperatingSystem) {
        $sources.Add(@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Scope = 'Machine'; Architecture = '64-bit' })
        $sources.Add(@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Scope = 'Machine'; Architecture = '32-bit' })
    }
    else {
        $sources.Add(@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Default; Scope = 'Machine'; Architecture = '32-bit' })
    }
    $sources.Add(@{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default; Scope = 'CurrentUser'; Architecture = $null })

    $applications = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($source in $sources) {
        $baseKey = Open-WinLeanRegistryView -Hive $source.Hive -View $source.View
        try {
            $uninstall = $baseKey.OpenSubKey($script:UninstallSubKey, $false)
            if ($null -eq $uninstall) {
                continue
            }
            try {
                foreach ($subKeyName in $uninstall.GetSubKeyNames()) {
                    $entry = $null
                    try {
                        $entry = $uninstall.OpenSubKey($subKeyName, $false)
                        if ($null -eq $entry) { continue }
                        $displayName = [string]$entry.GetValue('DisplayName')
                        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
                        $systemComponent = $entry.GetValue('SystemComponent')
                        if ($null -ne $systemComponent -and [int]$systemComponent -eq 1) { continue }
                        if (-not [string]::IsNullOrEmpty([string]$entry.GetValue('ParentKeyName'))) { continue }
                        if ($script:ExcludedReleaseTypes -contains [string]$entry.GetValue('ReleaseType')) { continue }
                        $windowsInstaller = $entry.GetValue('WindowsInstaller')
                        $applications.Add([pscustomobject]@{
                                name         = $displayName.Trim()
                                version      = [string]$entry.GetValue('DisplayVersion')
                                publisher    = [string]$entry.GetValue('Publisher')
                                installDate  = [string]$entry.GetValue('InstallDate')
                                scope        = $source.Scope
                                architecture = $source.Architecture
                                installer    = if ($null -ne $windowsInstaller -and [int]$windowsInstaller -eq 1) { 'MSI' } else { 'Other' }
                                registryKey  = $subKeyName
                            })
                    }
                    catch {
                        Write-Verbose "Skipping uninstall entry '$subKeyName': $($_.Exception.Message)"
                    }
                    finally {
                        if ($null -ne $entry) { $entry.Dispose() }
                    }
                }
            }
            finally {
                $uninstall.Dispose()
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }

    return [pscustomobject]@{
        count        = $applications.Count
        applications = @(Sort-WinLeanByName -InputObject $applications.ToArray())
    }
}

function Get-WinLeanWinGetInventory {
    <#
    .SYNOPSIS
        Packages known to WinGet, from 'winget export'.
    .NOTES
        Only packages that WinGet can match to a source are exported. WinGet may refresh
        its source index while doing this, so the section can take tens of seconds.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw (New-WinLeanUnavailableException -Reason NotInstalled -Message 'WinGet (winget.exe) is not installed.')
    }

    $exportPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('winlean-winget-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        $arguments = @('export', '--output', $exportPath, '--include-versions', '--accept-source-agreements', '--disable-interactivity')
        $result = Invoke-WinLeanProcess -FilePath $command.Source -ArgumentList $arguments -TimeoutSeconds 180
        if (-not [System.IO.File]::Exists($exportPath)) {
            # Older WinGet versions do not know --disable-interactivity.
            $result = Invoke-WinLeanProcess -FilePath $command.Source -ArgumentList $arguments[0..4] -TimeoutSeconds 180
        }
        if (-not [System.IO.File]::Exists($exportPath)) {
            throw (New-WinLeanException -Class CommandFailed -Message "winget export did not produce output (exit code $($result.exitCode)).")
        }
        $export = Read-WinLeanJsonFile -Path $exportPath
        $packages = @(foreach ($source in @(Get-WinLeanArrayProperty -InputObject $export -Name 'Sources')) {
                $sourceName = [string](Get-WinLeanProperty -InputObject (Get-WinLeanProperty -InputObject $source -Name 'SourceDetails') -Name 'Name')
                foreach ($package in @(Get-WinLeanArrayProperty -InputObject $source -Name 'Packages')) {
                    [pscustomobject]@{
                        id      = [string]$package.PackageIdentifier
                        version = [string](Get-WinLeanProperty -InputObject $package -Name 'Version')
                        source  = $sourceName
                    }
                }
            })
        return [pscustomobject]@{
            wingetVersion = [string](Get-WinLeanProperty -InputObject $export -Name 'WinGetVersion')
            count         = $packages.Count
            packages      = @(Sort-WinLeanByName -InputObject $packages -Property 'id')
        }
    }
    finally {
        if ([System.IO.File]::Exists($exportPath)) {
            [System.IO.File]::Delete($exportPath)
        }
    }
}

function Get-WinLeanOptionalFeatureInventory {
    <#
    .SYNOPSIS
        Optional Windows features and their state (Win32_OptionalFeature; no elevation needed).
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $stateNames = @{ 1 = 'Enabled'; 2 = 'Disabled'; 3 = 'Absent' }
    $features = @(foreach ($feature in @(Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction Stop)) {
            $installState = [int]$feature.InstallState
            [pscustomobject]@{
                name  = [string]$feature.Name
                state = if ($stateNames.ContainsKey($installState)) { $stateNames[$installState] } else { 'Unknown' }
            }
        })
    return [pscustomobject]@{
        source       = 'Win32_OptionalFeature'
        count        = $features.Count
        enabledCount = @($features | Where-Object { $_.state -eq 'Enabled' }).Count
        features     = @(Sort-WinLeanByName -InputObject $features)
    }
}

function Get-WinLeanStartupInventory {
    <#
    .SYNOPSIS
        Startup entries from the Run/RunOnce registry keys and the startup folders, with the
        enabled/disabled choice recorded by Task Manager (StartupApproved).
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $runSubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
    $runOnceSubKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $approvedSubKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $hkcu = [Microsoft.Win32.RegistryHive]::CurrentUser
    $hklm = [Microsoft.Win32.RegistryHive]::LocalMachine
    $view64 = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    $view32 = [Microsoft.Win32.RegistryView]::Registry32

    $locations = New-Object -TypeName System.Collections.Generic.List[object]
    $locations.Add(@{ Hive = $hkcu; View = $view64; SubKey = $runSubKey; Label = 'HKCU\' + $runSubKey; Scope = 'CurrentUser'; Kind = 'Run'; Approved = 'Run' })
    $locations.Add(@{ Hive = $hkcu; View = $view64; SubKey = $runOnceSubKey; Label = 'HKCU\' + $runOnceSubKey; Scope = 'CurrentUser'; Kind = 'RunOnce'; Approved = $null })
    $locations.Add(@{ Hive = $hklm; View = $view64; SubKey = $runSubKey; Label = 'HKLM\' + $runSubKey; Scope = 'Machine'; Kind = 'Run'; Approved = 'Run' })
    $locations.Add(@{ Hive = $hklm; View = $view64; SubKey = $runOnceSubKey; Label = 'HKLM\' + $runOnceSubKey; Scope = 'Machine'; Kind = 'RunOnce'; Approved = $null })
    if ([Environment]::Is64BitOperatingSystem) {
        $locations.Add(@{ Hive = $hklm; View = $view32; SubKey = $runSubKey; Label = 'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine'; Kind = 'Run'; Approved = 'Run32' })
        $locations.Add(@{ Hive = $hklm; View = $view32; SubKey = $runOnceSubKey; Label = 'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Scope = 'Machine'; Kind = 'RunOnce'; Approved = $null })
    }

    $entries = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($location in $locations) {
        $baseKey = Open-WinLeanRegistryView -Hive $location.Hive -View $location.View
        try {
            $key = $baseKey.OpenSubKey($location.SubKey, $false)
            if ($null -eq $key) { continue }
            try {
                foreach ($valueName in $key.GetValueNames()) {
                    if ([string]::IsNullOrEmpty($valueName)) { continue }
                    $approval = [pscustomobject]@{ approval = 'NotApplicable'; raw = $null }
                    if ($location.Approved) {
                        $approval = Get-WinLeanStartupApproval -Data (Get-WinLeanApprovedData -Hive $location.Hive -SubKey ($approvedSubKey + '\' + $location.Approved) -Name $valueName)
                    }
                    $entries.Add([pscustomobject]@{
                            name        = $valueName
                            kind        = $location.Kind
                            scope       = $location.Scope
                            location    = $location.Label
                            command     = [string]$key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                            approval    = $approval.approval
                            approvalRaw = $approval.raw
                        })
                }
            }
            finally {
                $key.Dispose()
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }

    $folders = @(
        @{ Path = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup); Scope = 'CurrentUser'; Hive = $hkcu }
        @{ Path = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup); Scope = 'Machine'; Hive = $hklm }
    )
    $shell = $null
    try {
        foreach ($folder in $folders) {
            if ([string]::IsNullOrEmpty($folder.Path) -or -not [System.IO.Directory]::Exists($folder.Path)) { continue }
            foreach ($file in [System.IO.Directory]::GetFiles($folder.Path)) {
                $fileName = [System.IO.Path]::GetFileName($file)
                if ($fileName -eq 'desktop.ini') { continue }
                $target = $null
                if ($fileName.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
                    try {
                        if ($null -eq $shell) { $shell = New-Object -ComObject WScript.Shell }
                        $target = [string]$shell.CreateShortcut($file).TargetPath
                    }
                    catch {
                        Write-Verbose "Cannot resolve shortcut '$file': $($_.Exception.Message)"
                    }
                }
                $approval = Get-WinLeanStartupApproval -Data (Get-WinLeanApprovedData -Hive $folder.Hive -SubKey ($approvedSubKey + '\StartupFolder') -Name $fileName)
                $entries.Add([pscustomobject]@{
                        name        = $fileName
                        kind        = 'StartupFolder'
                        scope       = $folder.Scope
                        location    = $folder.Path
                        command     = $target
                        approval    = $approval.approval
                        approvalRaw = $approval.raw
                    })
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    $items = $entries.ToArray()
    return [pscustomobject]@{
        count          = $items.Count
        enabledCount   = @($items | Where-Object { $_.approval -ne 'Disabled' }).Count
        disabledCount  = @($items | Where-Object { $_.approval -eq 'Disabled' }).Count
        approvalMethod = 'Heuristic: undocumented StartupApproved data; an odd first byte means disabled in Task Manager.'
        entries        = $items
    }
}

function Get-WinLeanApprovedData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.Win32.RegistryHive] $Hive,
        [Parameter(Mandatory)] [string] $SubKey,
        [Parameter(Mandatory)] [string] $Name
    )

    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    $baseKey = Open-WinLeanRegistryView -Hive $Hive -View $view
    try {
        $key = $baseKey.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return $null }
        try {
            $data = $key.GetValue($Name)
            if ($data -is [byte[]]) { return , $data }
            return $null
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Get-WinLeanServiceDll {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ServiceName)

    foreach ($subKey in @('\Parameters', '')) {
        $value = Get-WinLeanServiceRegistryValue -ServiceName $ServiceName -SubKey $subKey -ValueName 'ServiceDll'
        if ($value) {
            return $value
        }
    }
    return $null
}

function Get-WinLeanServiceInventory {
    <#
    .SYNOPSIS
        Services with start mode, state, binary and vendor classification.
    .NOTES
        Vendor classification reads CompanyName from the service binary, or from the
        ServiceDll for services hosted in svchost.exe. This is a heuristic.
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $cache = New-WinLeanDictionary
    $services = @(foreach ($service in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
            # Non-elevated queries return an empty PathName for some protected services;
            # the ImagePath registry value is readable and equivalent.
            $commandLine = [string]$service.PathName
            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                $commandLine = Get-WinLeanServiceRegistryValue -ServiceName ([string]$service.Name) -SubKey '' -ValueName 'ImagePath'
            }
            $binary = Get-WinLeanExecutablePath -CommandLine $commandLine
            $serviceDll = $null
            if (-not $binary -or [System.IO.Path]::GetFileName($binary) -eq 'svchost.exe') {
                $serviceDll = Get-WinLeanServiceDll -ServiceName ([string]$service.Name)
            }
            $vendorFile = if ($serviceDll) { $serviceDll } else { $binary }
            $company = Get-WinLeanFileCompany -Path $vendorFile -Cache $cache
            [pscustomobject]@{
                name             = [string]$service.Name
                displayName      = [string]$service.DisplayName
                startMode        = [string]$service.StartMode
                delayedAutoStart = [bool](Get-WinLeanProperty -InputObject $service -Name 'DelayedAutoStart' -Default $false)
                state            = [string]$service.State
                account          = [string]$service.StartName
                binaryPath       = $binary
                serviceDll       = $serviceDll
                company          = $company.name
                companySource    = $company.source
                vendor           = Get-WinLeanVendorClass -CompanyName $company.name
            }
        })
    $running = @($services | Where-Object { $_.state -eq 'Running' })
    return [pscustomobject]@{
        count                  = $services.Count
        runningCount           = $running.Count
        runningThirdPartyCount = @($running | Where-Object { $_.vendor -eq 'ThirdParty' }).Count
        runningUnknownCount    = @($running | Where-Object { $_.vendor -eq 'Unknown' }).Count
        vendorMethod           = 'Heuristic: CompanyName of the service binary (or ServiceDll for svchost services), falling back to the organization of a valid Authenticode signature.'
        services               = @(Sort-WinLeanByName -InputObject $services)
    }
}

function Get-WinLeanScheduledTaskInventory {
    <#
    .SYNOPSIS
        Scheduled tasks visible to the current user (elevation shows more tasks).
    #>
    [CmdletBinding()]
    param([bool] $IsAdministrator)

    $tasks = @(foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
            $actions = @(foreach ($action in @($task.Actions)) {
                    if ($null -eq $action) { continue }
                    $className = [string]$action.CimClass.CimClassName
                    if ($className -eq 'MSFT_TaskExecAction') {
                        [pscustomobject]@{ type = 'Exec'; execute = [string]$action.Execute; arguments = [string]$action.Arguments }
                    }
                    elseif ($className -eq 'MSFT_TaskComHandlerAction') {
                        [pscustomobject]@{ type = 'ComHandler'; classId = [string]$action.ClassId }
                    }
                    else {
                        [pscustomobject]@{ type = $className }
                    }
                })
            $triggers = @(foreach ($trigger in @($task.Triggers)) {
                    if ($null -eq $trigger) { continue }
                    ([string]$trigger.CimClass.CimClassName) -creplace '^MSFT_Task', '' -creplace 'Trigger$', ''
                })
            $taskPath = [string]$task.TaskPath
            $principal = Get-WinLeanProperty -InputObject $task -Name 'Principal'
            [pscustomobject]@{
                path     = $taskPath
                name     = [string]$task.TaskName
                state    = [string]$task.State
                author   = [string]$task.Author
                vendor   = if ($taskPath.StartsWith('\Microsoft\', [System.StringComparison]::OrdinalIgnoreCase)) { 'Microsoft' } else { 'Other' }
                runLevel = [string](Get-WinLeanProperty -InputObject $principal -Name 'RunLevel')
                userId   = [string](Get-WinLeanProperty -InputObject $principal -Name 'UserId')
                triggers = [string[]]$triggers
                actions  = $actions
            }
        })
    $stateCounts = [ordered]@{}
    foreach ($task in $tasks) {
        if (-not $stateCounts.Contains($task.state)) { $stateCounts[$task.state] = 0 }
        $stateCounts[$task.state]++
    }
    return [pscustomobject]@{
        count       = $tasks.Count
        complete    = $IsAdministrator
        stateCounts = [pscustomobject]$stateCounts
        tasks       = @(Sort-WinLeanByName -InputObject $tasks -Property 'path')
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Get-WinLeanInventorySummary {
    <#
    .SYNOPSIS
        Flattens an inventory into the key figures shown by -Analyze and in reports.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)

    $system = Get-WinLeanInventorySection -Inventory $Inventory -Name 'system'
    $os = if ($system) { $system.os } else { $null }
    $cpu = if ($system -and $system.cpu.available) { @($system.cpu.data.processors) } else { @() }
    $memory = if ($system -and $system.memory.available) { $system.memory.data } else { $null }
    $gpu = if ($system -and $system.gpu.available) { @($system.gpu.data.adapters) } else { @() }

    $countOf = {
        param([string] $Name, [string] $Property = 'count')
        $data = Get-WinLeanInventorySection -Inventory $Inventory -Name $Name
        if ($null -eq $data) { return $null }
        return Get-WinLeanProperty -InputObject $data -Name $Property
    }

    return [pscustomobject]@{
        windows                 = if ($os) { '{0} {1} (build {2}, {3}, {4})' -f $os.productName, $os.displayVersion, $os.version, $os.architecture, $os.installationType } else { $null }
        cpu                     = if ($cpu.Count -gt 0) { ($cpu | ForEach-Object { '{0} ({1} cores, {2} threads)' -f $_.name, $_.cores, $_.logicalProcessors }) -join '; ' } else { $null }
        memoryGB                = if ($memory -and $memory.installedBytes -gt 0) { Format-WinLeanNumber -Value ($memory.installedBytes / 1GB) -Decimals 1 } else { $null }
        gpu                     = if ($gpu.Count -gt 0) { ($gpu | ForEach-Object { $_.name }) -join '; ' } else { $null }
        isAdministrator         = [bool]$Inventory.isAdministrator
        appxPackages            = & $countOf 'appxPackages'
        provisionedAppxPackages = & $countOf 'provisionedAppxPackages'
        win32Applications       = & $countOf 'win32Applications'
        wingetPackages          = & $countOf 'wingetPackages'
        optionalFeatures        = & $countOf 'optionalFeatures'
        optionalFeaturesEnabled = & $countOf 'optionalFeatures' 'enabledCount'
        startupEntries          = & $countOf 'startup'
        startupEntriesEnabled   = & $countOf 'startup' 'enabledCount'
        services                = & $countOf 'services'
        servicesRunning         = & $countOf 'services' 'runningCount'
        servicesRunningThirdParty = & $countOf 'services' 'runningThirdPartyCount'
        scheduledTasks          = & $countOf 'scheduledTasks'
    }
}

Export-ModuleMember -Function @(
    'Get-WinLeanInventorySections'
    'Get-WinLeanInventory'
    'Get-WinLeanInventorySection'
    'Get-WinLeanInventorySummary'
    'Get-WinLeanSystemInventory'
    'Get-WinLeanSecurityInventory'
    'Get-WinLeanHardwareInventory'
    'Get-WinLeanAppxInventory'
    'Get-WinLeanProvisionedAppxInventory'
    'Get-WinLeanWin32ApplicationInventory'
    'Get-WinLeanWinGetInventory'
    'Get-WinLeanOptionalFeatureInventory'
    'Get-WinLeanStartupInventory'
    'Get-WinLeanServiceInventory'
    'Get-WinLeanScheduledTaskInventory'
    'Get-WinLeanExecutablePath'
    'Get-WinLeanVendorClass'
    'Get-WinLeanStartupApproval'
)
