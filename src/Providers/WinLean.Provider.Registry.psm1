#Requires -Version 5.1
<#
    WinLean.Provider.Registry
    -------------------------
    Resource provider for the declarative resource type "RegistryValue".

    A RegistryValue resource in a rule file looks like:

        {
          "type": "RegistryValue",
          "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
          "name": "HideFileExt",
          "valueType": "DWord",
          "value": 0
        }

    or, to require that a value does not exist:

        { "type": "RegistryValue", "path": "...", "name": "...", "ensure": "Absent" }

    Design rules:

      * Only HKCU:\ and HKLM:\ are supported. The 64-bit registry view is used on
        64-bit Windows so that results do not depend on the PowerShell bitness.
      * Values are read with the .NET registry API, never Get-ItemProperty, so that
        REG_EXPAND_SZ data is captured unexpanded and value kinds are exact.
      * Captured state is lossless for String, ExpandString, MultiString, DWord, QWord
        and Binary. Values of any other kind are reported as not restorable, and the
        policy engine refuses to modify them.
      * Protected locations (Defender, Windows Update, Firewall, services, LSA, ...) are
        rejected during rule validation AND again at write time (defense in depth).
      * The low-level I/O functions (Read-/Write-/Remove-WinLeanRegistryValue,
        Test-WinLeanRegistryKey, Remove-WinLeanRegistryKeyIfEmpty,
        Test-WinLeanRegistryWriteAccess) are the only functions that touch the registry.
        Unit tests replace them with an in-memory fake.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name ([System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\WinLean.Common.psm1')))

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

$script:Hives = @{
    HKCU = [Microsoft.Win32.RegistryHive]::CurrentUser
    HKLM = [Microsoft.Win32.RegistryHive]::LocalMachine
}

# Value kinds that can be captured and restored losslessly.
$script:ValueTypes = @('String', 'ExpandString', 'MultiString', 'DWord', 'QWord', 'Binary')

# Properties allowed in a RegistryValue resource definition (typo protection).
$script:DefinitionProperties = @('type', 'path', 'name', 'ensure', 'valueType', 'value')

# Registry locations WinLean must never modify, whatever a rule says. Keys are matched
# as prefixes on key boundaries; entries with a Name protect a single value.
# ControlSetNNN is treated as an alias of CurrentControlSet.
$script:ProtectedLocations = @(
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS DEFENDER'; Reason = 'Microsoft Defender' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS DEFENDER'; Reason = 'Microsoft Defender policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS DEFENDER SECURITY CENTER'; Reason = 'Windows Security' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS DEFENDER SECURITY CENTER'; Reason = 'Windows Security policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS ADVANCED THREAT PROTECTION'; Reason = 'Microsoft Defender for Endpoint' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS ADVANCED THREAT PROTECTION'; Reason = 'Microsoft Defender for Endpoint policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWSUPDATE'; Reason = 'Windows Update' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\WINDOWSUPDATE'; Reason = 'Windows Update policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\WINDOWSUPDATE'; Reason = 'Windows Update' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\COMPONENT BASED SERVICING'; Reason = 'Windows servicing stack' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\APPX'; Reason = 'AppX deployment state (use package management)' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWSFIREWALL'; Reason = 'Windows Firewall policy' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\SERVICES'; Reason = 'Windows services (never edited through raw registry writes)' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\CONTROL\DEVICEGUARD'; Reason = 'Virtualization-based security' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\DEVICEGUARD'; Reason = 'Virtualization-based security policy' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\CONTROL\LSA'; Reason = 'Local Security Authority and credential protection' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\CONTROL\SECUREBOOT'; Reason = 'Secure Boot' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\CONTROL\CI'; Reason = 'Code integrity' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\CONTROL\SESSION MANAGER'; Reason = 'Kernel, memory management and mitigation settings' }
    @{ Key = 'HKLM\SYSTEM\CURRENTCONTROLSET\CONTROL\SECURITYPROVIDERS'; Reason = 'TLS / SCHANNEL configuration' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS NT\CURRENTVERSION\IMAGE FILE EXECUTION OPTIONS'; Reason = 'Process mitigations and debugger redirection' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS NT\CURRENTVERSION\WINLOGON'; Reason = 'Logon infrastructure' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\POLICIES\SYSTEM'; Reason = 'User Account Control and logon security policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\SYSTEMCERTIFICATES'; Reason = 'Certificate stores' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\SYSTEMCERTIFICATES'; Reason = 'Certificate policy' }
    @{ Key = 'HKCU\SOFTWARE\MICROSOFT\SYSTEMCERTIFICATES'; Reason = 'User certificate stores' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\CRYPTOGRAPHY'; Reason = 'Cryptography configuration' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\WINTRUST'; Reason = 'Authenticode trust providers' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\SAFER'; Reason = 'Software restriction policies' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\FVE'; Reason = 'BitLocker policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\POLICIES\ATTACHMENTS'; Reason = 'Mark-of-the-Web handling' }
    @{ Key = 'HKCU\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\POLICIES\ATTACHMENTS'; Reason = 'Mark-of-the-Web handling' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\MICROSOFTEDGE\PHISHINGFILTER'; Reason = 'Microsoft Edge SmartScreen policy' }
    @{ Key = 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\SYSTEM'; Name = 'ENABLESMARTSCREEN'; Reason = 'SmartScreen policy' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\EXPLORER'; Name = 'SMARTSCREENENABLED'; Reason = 'SmartScreen' }
    @{ Key = 'HKCU\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\APPHOST'; Name = 'ENABLEWEBCONTENTEVALUATION'; Reason = 'SmartScreen for apps' }
    @{ Key = 'HKCU\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\EXPLORER\STARTUPAPPROVED'; Reason = 'Task Manager startup state (undocumented binary data)' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\EXPLORER\STARTUPAPPROVED'; Reason = 'Task Manager startup state (undocumented binary data)' }
)

# Keys that RegistryValue resources must not target because another resource type manages
# them (or because WinLean deliberately does not manage them). Checked during validation.
$script:DedicatedLocations = @(
    @{ Key = 'HKCU\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\RUN'; Message = "startup entries are managed with the 'StartupEntry' resource type" }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\RUN'; Message = "startup entries are managed with the 'StartupEntry' resource type" }
    @{ Key = 'HKLM\SOFTWARE\WOW6432NODE\MICROSOFT\WINDOWS\CURRENTVERSION\RUN'; Message = "startup entries are managed with the 'StartupEntry' resource type" }
    @{ Key = 'HKCU\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\RUNONCE'; Message = 'RunOnce entries describe pending one-time work and are not managed by WinLean' }
    @{ Key = 'HKLM\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\RUNONCE'; Message = 'RunOnce entries describe pending one-time work and are not managed by WinLean' }
    @{ Key = 'HKLM\SOFTWARE\WOW6432NODE\MICROSOFT\WINDOWS\CURRENTVERSION\RUNONCE'; Message = 'RunOnce entries describe pending one-time work and are not managed by WinLean' }
)

# ---------------------------------------------------------------------------
# Paths and protected locations
# ---------------------------------------------------------------------------

function ConvertFrom-WinLeanRegistryPath {
    <#
    .SYNOPSIS
        Parses 'HKCU:\Sub\Key' or 'HKLM:\Sub\Key' into hive and subkey.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $match = [System.Text.RegularExpressions.Regex]::Match($Path, '^(?<hive>HKCU|HKLM):\\(?<subKey>.+)$', 'IgnoreCase, CultureInvariant')
    if (-not $match.Success) {
        throw (New-WinLeanException -Class Unsupported -Message "Unsupported registry path '$Path'. Paths must start with 'HKCU:\' or 'HKLM:\'.")
    }
    $hive = $match.Groups['hive'].Value.ToUpperInvariant()
    $subKey = $match.Groups['subKey'].Value
    foreach ($segment in $subKey.Split('\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            throw (New-WinLeanException -Class Unsupported -Message "Registry path '$Path' contains an empty key name.")
        }
    }
    return [pscustomobject]@{
        hive   = $hive
        subKey = $subKey
        path   = $hive + ':\' + $subKey
    }
}

function Get-WinLeanRegistryProtectedReason {
    <#
    .SYNOPSIS
        Returns why a registry location is protected, or $null when it may be modified.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Name
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $key = ($location.hive + '\' + $location.subKey).ToUpperInvariant()
    $key = [System.Text.RegularExpressions.Regex]::Replace($key, '^HKLM\\SYSTEM\\CONTROLSET\d{3}(?=\\|$)', 'HKLM\SYSTEM\CURRENTCONTROLSET', 'CultureInvariant')
    $valueName = if ($Name) { $Name.ToUpperInvariant() } else { $null }

    foreach ($entry in $script:ProtectedLocations) {
        $protectedKey = [string]$entry.Key
        if ($entry.ContainsKey('Name')) {
            if ($key -ceq $protectedKey -and $valueName -ceq [string]$entry.Name) {
                return [string]$entry.Reason
            }
            continue
        }
        if ($key -ceq $protectedKey -or $key.StartsWith($protectedKey + '\', [System.StringComparison]::Ordinal)) {
            return [string]$entry.Reason
        }
    }
    return $null
}

function Get-WinLeanRegistryDedicatedReason {
    <#
    .SYNOPSIS
        Returns why a RegistryValue resource must not target a key (another resource type
        manages it), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $key = ($location.hive + '\' + $location.subKey).ToUpperInvariant()
    foreach ($entry in $script:DedicatedLocations) {
        $dedicatedKey = [string]$entry.Key
        if ($key -ceq $dedicatedKey -or $key.StartsWith($dedicatedKey + '\', [System.StringComparison]::Ordinal)) {
            return [string]$entry.Message
        }
    }
    return $null
}

function Assert-WinLeanRegistryLocationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Name
    )

    $reason = Get-WinLeanRegistryProtectedReason -Path $Path -Name $Name
    if ($reason) {
        $target = if ($Name) { "$Path\$Name" } else { $Path }
        throw (New-WinLeanException -Class ProtectedResource -Message "Refusing to modify protected registry location '$target' ($reason).")
    }
}

# ---------------------------------------------------------------------------
# Low-level I/O (the only functions that touch the registry)
# ---------------------------------------------------------------------------

function Open-WinLeanRegistryBaseKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('HKCU', 'HKLM')]
        [string] $Hive
    )

    $view = [Microsoft.Win32.RegistryView]::Default
    if ([Environment]::Is64BitOperatingSystem) {
        $view = [Microsoft.Win32.RegistryView]::Registry64
    }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($script:Hives[$Hive], $view)
}

function Read-WinLeanRegistryValue {
    <#
    .SYNOPSIS
        Reads one registry value exactly as stored.
    .OUTPUTS
        Object with keyExists, valueExists, kind (RegistryValueKind name) and data
        (raw .NET value: Int32 for DWord, Int64 for QWord, string[] for MultiString,
        byte[] for Binary, unexpanded string for ExpandString).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $baseKey = Open-WinLeanRegistryBaseKey -Hive $location.hive
    try {
        $key = $baseKey.OpenSubKey($location.subKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ keyExists = $false; valueExists = $false; kind = $null; data = $null }
        }
        try {
            $exists = $false
            foreach ($valueName in $key.GetValueNames()) {
                if ([string]::Equals($valueName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $exists = $true
                    break
                }
            }
            if (-not $exists) {
                return [pscustomobject]@{ keyExists = $true; valueExists = $false; kind = $null; data = $null }
            }
            $kind = $key.GetValueKind($Name).ToString()
            $data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ keyExists = $true; valueExists = $true; kind = $kind; data = $data }
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Write-WinLeanRegistryValue {
    <#
    .SYNOPSIS
        Creates the key if needed and writes one value. Refuses protected locations.
    .PARAMETER Data
        .NET data matching the kind (see ConvertTo-WinLeanRegistryData).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('String', 'ExpandString', 'MultiString', 'DWord', 'QWord', 'Binary')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        $Data
    )

    Assert-WinLeanRegistryLocationAllowed -Path $Path -Name $Name
    if (-not $PSCmdlet.ShouldProcess("$Path\$Name", "Set registry value ($Kind)")) {
        return
    }
    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $baseKey = Open-WinLeanRegistryBaseKey -Hive $location.hive
    try {
        $key = $baseKey.CreateSubKey($location.subKey, $true)
        if ($null -eq $key) {
            throw (New-WinLeanException -Class CommandFailed -Message "Could not open or create registry key '$Path'.")
        }
        try {
            $key.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind)
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Remove-WinLeanRegistryValue {
    <#
    .SYNOPSIS
        Deletes one value if it exists. Refuses protected locations.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    Assert-WinLeanRegistryLocationAllowed -Path $Path -Name $Name
    if (-not $PSCmdlet.ShouldProcess("$Path\$Name", 'Delete registry value')) {
        return
    }
    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $baseKey = Open-WinLeanRegistryBaseKey -Hive $location.hive
    try {
        $key = $baseKey.OpenSubKey($location.subKey, $true)
        if ($null -eq $key) {
            return
        }
        try {
            $key.DeleteValue($Name, $false)
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Test-WinLeanRegistryKey {
    <#
    .SYNOPSIS
        Returns $true when the registry key exists.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $baseKey = Open-WinLeanRegistryBaseKey -Hive $location.hive
    try {
        $key = $baseKey.OpenSubKey($location.subKey, $false)
        if ($null -eq $key) {
            return $false
        }
        $key.Dispose()
        return $true
    }
    finally {
        $baseKey.Dispose()
    }
}

function Remove-WinLeanRegistryKeyIfEmpty {
    <#
    .SYNOPSIS
        Deletes a key only when it has no values and no subkeys. Returns $true when deleted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    Assert-WinLeanRegistryLocationAllowed -Path $Path
    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $separator = $location.subKey.LastIndexOf([char]'\')
    if ($separator -lt 0) {
        # Never delete keys directly below a hive root.
        return $false
    }
    $parentSubKey = $location.subKey.Substring(0, $separator)
    $leaf = $location.subKey.Substring($separator + 1)

    $baseKey = Open-WinLeanRegistryBaseKey -Hive $location.hive
    try {
        $key = $baseKey.OpenSubKey($location.subKey, $false)
        if ($null -eq $key) {
            return $false
        }
        try {
            if ($key.ValueCount -gt 0 -or $key.SubKeyCount -gt 0) {
                return $false
            }
        }
        finally {
            $key.Dispose()
        }
        if (-not $PSCmdlet.ShouldProcess($Path, 'Delete empty registry key')) {
            return $false
        }
        $parent = $baseKey.OpenSubKey($parentSubKey, $true)
        if ($null -eq $parent) {
            return $false
        }
        try {
            $parent.DeleteSubKey($leaf, $false)
        }
        finally {
            $parent.Dispose()
        }
        return $true
    }
    finally {
        $baseKey.Dispose()
    }
}

function Test-WinLeanRegistryWriteAccess {
    <#
    .SYNOPSIS
        Returns $true when the current process may create or modify values under the key.
    .NOTES
        Opens the deepest existing key on the path with write access and closes it again.
        Nothing is modified. This reflects the real ACL, which is more accurate than
        assuming "HKLM needs administrator rights".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $baseKey = Open-WinLeanRegistryBaseKey -Hive $location.hive
    try {
        $subKey = $location.subKey
        while ($true) {
            $key = $null
            try {
                $key = $baseKey.OpenSubKey($subKey, $true)
            }
            catch {
                if ((Get-WinLeanFailureClass -ErrorObject $_) -eq 'PermissionDenied') {
                    return $false
                }
                throw
            }
            if ($null -ne $key) {
                $key.Dispose()
                return $true
            }
            $separator = $subKey.LastIndexOf([char]'\')
            if ($separator -lt 0) {
                # Creating a key directly below the hive root: allowed in HKCU only.
                return ($location.hive -eq 'HKCU')
            }
            $subKey = $subKey.Substring(0, $separator)
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Get-WinLeanRegistryMissingKeyRoot {
    <#
    .SYNOPSIS
        Returns the shallowest missing key on the path, or $null when the key exists.
    .EXAMPLE
        # HKCU:\A exists, HKCU:\A\B does not:
        Get-WinLeanRegistryMissingKeyRoot -Path 'HKCU:\A\B\C'   # -> 'HKCU:\A\B'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    if (Test-WinLeanRegistryKey -Path $location.path) {
        return $null
    }
    $current = $null
    foreach ($segment in $location.subKey.Split('\')) {
        if ($null -eq $current) {
            $current = $segment
        }
        else {
            $current = $current + '\' + $segment
        }
        $candidate = $location.hive + ':\' + $current
        if (-not (Test-WinLeanRegistryKey -Path $candidate)) {
            return $candidate
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Value conversion
# ---------------------------------------------------------------------------

function Test-WinLeanIntegralNumber {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [byte]) {
        return $true
    }
    # PowerShell 7 parses JSON integers beyond Int64 as BigInteger. The type is referenced
    # by name because System.Numerics is not loaded by default in Windows PowerShell 5.1.
    if ($Value.GetType().FullName -eq 'System.Numerics.BigInteger') {
        return $true
    }
    if ($Value -is [decimal] -or $Value -is [double]) {
        return [System.Math]::Truncate($Value) -eq $Value
    }
    return $false
}

function Test-WinLeanRegistryValueData {
    <#
    .SYNOPSIS
        Validates a desired value against its value type. Returns a problem description or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ValueType,
        [AllowNull()] $Value
    )

    switch -CaseSensitive ($ValueType) {
        'DWord' {
            if (-not (Test-WinLeanIntegralNumber -Value $Value) -or [decimal]$Value -lt 0 -or [decimal]$Value -gt [decimal][uint32]::MaxValue) {
                return "DWord value must be an integer between 0 and 4294967295"
            }
            return $null
        }
        'QWord' {
            if ($Value -is [string]) {
                $parsed = [uint64]0
                if (-not [uint64]::TryParse($Value, [System.Globalization.NumberStyles]::None, $script:Invariant, [ref]$parsed)) {
                    return "QWord value must be an integer between 0 and 18446744073709551615 (number or decimal string)"
                }
                return $null
            }
            if (-not (Test-WinLeanIntegralNumber -Value $Value) -or [decimal]$Value -lt 0 -or [decimal]$Value -gt [decimal][uint64]::MaxValue) {
                return "QWord value must be an integer between 0 and 18446744073709551615 (number or decimal string)"
            }
            return $null
        }
        { $_ -ceq 'String' -or $_ -ceq 'ExpandString' } {
            if ($Value -isnot [string]) {
                return "$ValueType value must be a string"
            }
            return $null
        }
        'MultiString' {
            if (-not (Test-WinLeanEnumerable -Value $Value)) {
                return "MultiString value must be an array of strings"
            }
            foreach ($item in $Value) {
                if ($item -isnot [string]) {
                    return "MultiString value must be an array of strings"
                }
            }
            return $null
        }
        'Binary' {
            if ($Value -isnot [string] -or -not (Test-WinLeanPattern -Text $Value -Pattern '^(?:[0-9a-fA-F]{2})*$' -CaseSensitive)) {
                return "Binary value must be a hexadecimal string with an even number of digits, for example '0a1b'"
            }
            return $null
        }
    }
    return "unsupported valueType '$ValueType'"
}

function ConvertTo-WinLeanRegistryNormalizedValue {
    <#
    .SYNOPSIS
        Normalizes a validated desired value: DWord -> UInt32, QWord -> decimal string,
        MultiString -> string[], Binary -> lowercase hex string.
    .NOTES
        Returns a single object (arrays are not unrolled); assign the result directly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ValueType,
        [AllowNull()] $Value
    )

    switch -CaseSensitive ($ValueType) {
        'DWord' { return [uint32]$Value }
        'QWord' {
            if ($Value -is [string]) {
                $unsigned = [uint64]::Parse($Value, [System.Globalization.NumberStyles]::None, $script:Invariant)
            }
            else {
                $unsigned = [uint64][decimal]$Value
            }
            return $unsigned.ToString($script:Invariant)
        }
        'String' { return [string]$Value }
        'ExpandString' { return [string]$Value }
        'MultiString' { return , ([string[]]@($Value)) }
        'Binary' { return ([string]$Value).ToLowerInvariant() }
    }
    throw (New-WinLeanException -Class Unsupported -Message "Unsupported registry value type '$ValueType'.")
}

function Assert-WinLeanStringData {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) {
        throw (New-WinLeanException -Class Unsupported -Message ('A captured string value was converted to a date by this PowerShell version''s JSON parser, so it cannot be restored losslessly. ' +
                'Run WinLean with PowerShell 7.5 or later to restore this value.'))
    }
}

function ConvertTo-WinLeanRegistryData {
    <#
    .SYNOPSIS
        Converts a normalized value into the .NET data expected by RegistryKey.SetValue.
    .NOTES
        Returns a single object (arrays are not unrolled); assign the result directly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ValueType,
        [AllowNull()] $Value
    )

    switch -CaseSensitive ($ValueType) {
        'DWord' {
            return [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([uint32]$Value), 0)
        }
        'QWord' {
            $unsigned = [uint64]::Parse(([string]$Value), [System.Globalization.NumberStyles]::None, $script:Invariant)
            return [System.BitConverter]::ToInt64([System.BitConverter]::GetBytes($unsigned), 0)
        }
        { $_ -ceq 'String' -or $_ -ceq 'ExpandString' } {
            Assert-WinLeanStringData -Value $Value
            return [string]$Value
        }
        'MultiString' {
            $items = New-Object -TypeName System.Collections.Generic.List[string]
            foreach ($item in @($Value)) {
                Assert-WinLeanStringData -Value $item
                $items.Add([string]$item)
            }
            return , $items.ToArray()
        }
        'Binary' {
            $hex = [string]$Value
            $bytes = New-Object -TypeName 'byte[]' -ArgumentList ($hex.Length / 2)
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                $bytes[$index] = [System.Convert]::ToByte($hex.Substring($index * 2, 2), 16)
            }
            return , $bytes
        }
    }
    throw (New-WinLeanException -Class Unsupported -Message "Unsupported registry value type '$ValueType'.")
}

function ConvertTo-WinLeanHex {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [byte[]] $Bytes)

    if ($null -eq $Bytes) {
        return ''
    }
    $builder = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($Bytes.Length * 2)
    foreach ($byte in $Bytes) {
        [void]$builder.Append($byte.ToString('x2', $script:Invariant))
    }
    return $builder.ToString()
}

function ConvertTo-WinLeanRegistryState {
    <#
    .SYNOPSIS
        Converts raw registry data (Read-WinLeanRegistryValue output) into a normalized,
        JSON-serializable state object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Raw
    )

    $state = [pscustomobject]@{
        keyExists      = [bool]$Raw.keyExists
        valueExists    = [bool]$Raw.valueExists
        valueType      = $null
        value          = $null
        restorable     = $true
        missingKeyRoot = $null
    }
    if (-not $Raw.valueExists) {
        return $state
    }

    $data = $Raw.data
    $state.valueType = [string]$Raw.kind
    switch -CaseSensitive ([string]$Raw.kind) {
        'DWord' {
            if ($data -is [int]) {
                $state.value = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]$data), 0)
            }
            else {
                $state.value = [uint32]$data
            }
        }
        'QWord' {
            if ($data -is [long]) {
                $unsigned = [System.BitConverter]::ToUInt64([System.BitConverter]::GetBytes([long]$data), 0)
            }
            else {
                $unsigned = [uint64]$data
            }
            $state.value = $unsigned.ToString($script:Invariant)
        }
        'String' { $state.value = [string]$data }
        'ExpandString' { $state.value = [string]$data }
        'MultiString' { $state.value = [string[]]@($data) }
        'Binary' { $state.value = ConvertTo-WinLeanHex -Bytes ([byte[]]$data) }
        default {
            # REG_NONE, REG_LINK, REG_RESOURCE_LIST, ...: recorded for diagnostics only.
            $state.restorable = $false
            if ($data -is [byte[]]) {
                $state.value = ConvertTo-WinLeanHex -Bytes $data
            }
        }
    }
    return $state
}

function Test-WinLeanRegistryDataEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ValueType,
        [AllowNull()] $Expected,
        [AllowNull()] $Actual
    )

    if ($null -eq $Expected -or $null -eq $Actual) {
        return ($null -eq $Expected -and $null -eq $Actual)
    }
    try {
        switch -CaseSensitive ($ValueType) {
            'DWord' { return ([uint32]$Expected -eq [uint32]$Actual) }
            'QWord' {
                $left = [uint64]::Parse(([string]$Expected), [System.Globalization.NumberStyles]::None, $script:Invariant)
                $right = [uint64]::Parse(([string]$Actual), [System.Globalization.NumberStyles]::None, $script:Invariant)
                return ($left -eq $right)
            }
            { $_ -ceq 'String' -or $_ -ceq 'ExpandString' } {
                if ($Expected -isnot [string] -or $Actual -isnot [string]) {
                    return $false
                }
                return [string]::Equals($Expected, $Actual, [System.StringComparison]::Ordinal)
            }
            'MultiString' {
                $left = @($Expected)
                $right = @($Actual)
                if ($left.Count -ne $right.Count) {
                    return $false
                }
                for ($index = 0; $index -lt $left.Count; $index++) {
                    if ($left[$index] -isnot [string] -or $right[$index] -isnot [string] -or
                        -not [string]::Equals($left[$index], $right[$index], [System.StringComparison]::Ordinal)) {
                        return $false
                    }
                }
                return $true
            }
            default {
                return [string]::Equals([string]$Expected, [string]$Actual, [System.StringComparison]::OrdinalIgnoreCase)
            }
        }
    }
    catch {
        return $false
    }
}

function Format-WinLeanRegistryData {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $ValueType,
        [AllowNull()] $Value
    )

    switch -CaseSensitive ($ValueType) {
        'DWord' { return ('{0} ({1})' -f ([uint32]$Value).ToString($script:Invariant), $ValueType) }
        'QWord' { return ('{0} ({1})' -f [string]$Value, $ValueType) }
        'MultiString' { return ('[{0}] ({1})' -f ((@($Value) | ForEach-Object { "'" + [string]$_ + "'" }) -join ', '), $ValueType) }
        'Binary' { return ('0x{0} ({1})' -f [string]$Value, $ValueType) }
    }
    return ("'{0}' ({1})" -f [string]$Value, $ValueType)
}

# ---------------------------------------------------------------------------
# Resource provider contract
# ---------------------------------------------------------------------------

function Test-WinLeanRegistryResourceDefinition {
    <#
    .SYNOPSIS
        Validates a RegistryValue resource as written in a rule file.
    .OUTPUTS
        Problem descriptions (strings). Nothing is emitted when the definition is valid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Definition
    )

    foreach ($propertyName in @(Get-WinLeanPropertyNames -InputObject $Definition)) {
        if ($script:DefinitionProperties -cnotcontains $propertyName) {
            "unknown property '$propertyName'"
        }
    }

    $path = Get-WinLeanProperty -InputObject $Definition -Name 'path'
    $location = $null
    if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) {
        "'path' must be a non-empty string"
    }
    else {
        try {
            $location = ConvertFrom-WinLeanRegistryPath -Path $path
        }
        catch {
            $_.Exception.Message
        }
    }

    $name = Get-WinLeanProperty -InputObject $Definition -Name 'name'
    if ($name -isnot [string] -or [string]::IsNullOrEmpty($name)) {
        "'name' must be a non-empty string (the unnamed default value is not supported)"
        $name = $null
    }

    $ensure = Get-WinLeanProperty -InputObject $Definition -Name 'ensure' -Default 'Present'
    $valueType = Get-WinLeanProperty -InputObject $Definition -Name 'valueType'
    $hasValue = Test-WinLeanProperty -InputObject $Definition -Name 'value'
    if ($ensure -ceq 'Present') {
        if ($script:ValueTypes -cnotcontains $valueType) {
            "'valueType' must be one of: " + ($script:ValueTypes -join ', ')
        }
        elseif (-not $hasValue) {
            "'value' is required when 'ensure' is 'Present'"
        }
        else {
            $problem = Test-WinLeanRegistryValueData -ValueType $valueType -Value (Get-WinLeanProperty -InputObject $Definition -Name 'value' -NoEnumerate)
            if ($problem) {
                $problem
            }
        }
    }
    elseif ($ensure -ceq 'Absent') {
        if ($null -ne $valueType -or $hasValue) {
            "'valueType' and 'value' must be omitted when 'ensure' is 'Absent'"
        }
    }
    else {
        "'ensure' must be 'Present' or 'Absent'"
    }

    if ($null -ne $location -and $null -ne $name) {
        $reason = Get-WinLeanRegistryProtectedReason -Path $location.path -Name $name
        if ($reason) {
            "targets a protected registry location ($reason)"
        }
    }
    if ($null -ne $location) {
        $dedicated = Get-WinLeanRegistryDedicatedReason -Path $location.path
        if ($dedicated) {
            "must not target '$($location.path)': $dedicated"
        }
    }
}

function ConvertTo-WinLeanRegistryResource {
    <#
    .SYNOPSIS
        Converts a validated definition into a normalized resource object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Definition
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path ([string]$Definition.path)
    $ensure = [string](Get-WinLeanProperty -InputObject $Definition -Name 'ensure' -Default 'Present')
    $valueType = $null
    $value = $null
    if ($ensure -ceq 'Present') {
        $valueType = [string]$Definition.valueType
        $value = ConvertTo-WinLeanRegistryNormalizedValue -ValueType $valueType -Value (Get-WinLeanProperty -InputObject $Definition -Name 'value' -NoEnumerate)
    }
    return [pscustomobject]@{
        type      = 'RegistryValue'
        path      = $location.path
        name      = [string]$Definition.name
        ensure    = $ensure
        valueType = $valueType
        value     = $value
    }
}

function Get-WinLeanRegistryResourceInfo {
    <#
    .SYNOPSIS
        Describes a normalized resource: identity, scope, mechanism and display text.
    .NOTES
        identity  - stable key used to detect two rules targeting the same value
        scope     - CurrentUser (HKCU) or Machine (HKLM)
        mechanism - Policy for values below a \Policies\ key, otherwise Preference
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resource
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Resource.path
    $scope = if ($location.hive -eq 'HKCU') { 'CurrentUser' } else { 'Machine' }
    $mechanism = if (Test-WinLeanTextContains -Text ('\' + $location.subKey + '\') -Value '\Policies\') { 'Policy' } else { 'Preference' }
    $target = $location.path + '\' + $Resource.name
    $desired = if ($Resource.ensure -ceq 'Absent') { 'absent' } else { Format-WinLeanRegistryData -ValueType $Resource.valueType -Value $Resource.value }

    return [pscustomobject]@{
        identity    = ('RegistryValue:' + $location.hive + '\' + $location.subKey + '\' + $Resource.name).ToUpperInvariant()
        scope       = $scope
        mechanism   = $mechanism
        target      = $target
        description = $target + ' = ' + $desired
    }
}

function Get-WinLeanRegistryResourceState {
    <#
    .SYNOPSIS
        Reads the current state of the value targeted by a resource.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resource
    )

    $raw = Read-WinLeanRegistryValue -Path $Resource.path -Name $Resource.name
    $state = ConvertTo-WinLeanRegistryState -Raw $raw
    if (-not $state.keyExists) {
        $state.missingKeyRoot = Get-WinLeanRegistryMissingKeyRoot -Path $Resource.path
    }
    return $state
}

function Get-WinLeanRegistryDesiredState {
    <#
    .SYNOPSIS
        Returns the state a resource asks for, in the same shape as captured state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resource
    )

    if ($Resource.ensure -ceq 'Absent') {
        return [pscustomobject]@{ valueExists = $false; valueType = $null; value = $null }
    }
    return [pscustomobject]@{ valueExists = $true; valueType = $Resource.valueType; value = $Resource.value }
}

function Test-WinLeanRegistryStateEqual {
    <#
    .SYNOPSIS
        Compares two value states (existence, kind and data). Key existence is ignored.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual
    )

    $expectedExists = [bool](Get-WinLeanProperty -InputObject $Expected -Name 'valueExists' -Default $false)
    $actualExists = [bool](Get-WinLeanProperty -InputObject $Actual -Name 'valueExists' -Default $false)
    if ($expectedExists -ne $actualExists) {
        return $false
    }
    if (-not $expectedExists) {
        return $true
    }
    $expectedType = [string](Get-WinLeanProperty -InputObject $Expected -Name 'valueType')
    $actualType = [string](Get-WinLeanProperty -InputObject $Actual -Name 'valueType')
    if ($expectedType -cne $actualType) {
        return $false
    }
    return Test-WinLeanRegistryDataEqual -ValueType $expectedType `
        -Expected (Get-WinLeanProperty -InputObject $Expected -Name 'value' -NoEnumerate) `
        -Actual (Get-WinLeanProperty -InputObject $Actual -Name 'value' -NoEnumerate)
}

function Test-WinLeanRegistryStateRestorable {
    <#
    .SYNOPSIS
        Returns $true when a captured state can be written back exactly.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $State
    )

    return [bool](Get-WinLeanProperty -InputObject $State -Name 'restorable' -Default $true)
}

function Test-WinLeanRegistryResourceAccess {
    <#
    .SYNOPSIS
        Returns $true when the current process can apply (and later restore) the resource.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Resource
    )

    return Test-WinLeanRegistryWriteAccess -Path $Resource.path
}

function Set-WinLeanRegistryResource {
    <#
    .SYNOPSIS
        Puts the value into the state the resource asks for.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Resource
    )

    if ($Resource.ensure -ceq 'Absent') {
        Remove-WinLeanRegistryValue -Path $Resource.path -Name $Resource.name -WhatIf:$WhatIfPreference
        return
    }
    $data = ConvertTo-WinLeanRegistryData -ValueType $Resource.valueType -Value $Resource.value
    Write-WinLeanRegistryValue -Path $Resource.path -Name $Resource.name -Kind $Resource.valueType -Data $data -WhatIf:$WhatIfPreference
}

function Restore-WinLeanRegistryResource {
    <#
    .SYNOPSIS
        Writes a previously captured state back: the original value, or no value at all.
    .NOTES
        When the key did not exist before, keys created by WinLean are deleted again,
        deepest first, but only while they are empty and never above the recorded
        missing-key root.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Resource,
        [Parameter(Mandatory)] $State
    )

    if ([bool](Get-WinLeanProperty -InputObject $State -Name 'valueExists' -Default $false)) {
        if (-not (Test-WinLeanRegistryStateRestorable -State $State)) {
            throw (New-WinLeanException -Class Unsupported -Message "The captured value '$($Resource.path)\$($Resource.name)' has registry kind '$($State.valueType)', which WinLean cannot restore.")
        }
        $valueType = [string]$State.valueType
        $data = ConvertTo-WinLeanRegistryData -ValueType $valueType -Value (Get-WinLeanProperty -InputObject $State -Name 'value' -NoEnumerate)
        Write-WinLeanRegistryValue -Path $Resource.path -Name $Resource.name -Kind $valueType -Data $data -WhatIf:$WhatIfPreference
        return
    }

    Remove-WinLeanRegistryValue -Path $Resource.path -Name $Resource.name -WhatIf:$WhatIfPreference

    $keyExisted = [bool](Get-WinLeanProperty -InputObject $State -Name 'keyExists' -Default $true)
    $missingRoot = [string](Get-WinLeanProperty -InputObject $State -Name 'missingKeyRoot' -Default '')
    if ($keyExisted -or [string]::IsNullOrEmpty($missingRoot)) {
        return
    }
    $resourcePath = (ConvertFrom-WinLeanRegistryPath -Path $Resource.path).path
    $rootPath = (ConvertFrom-WinLeanRegistryPath -Path $missingRoot).path
    $isAncestor = [string]::Equals($resourcePath, $rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $resourcePath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isAncestor) {
        Write-Verbose "Recorded missing-key root '$rootPath' is not an ancestor of '$resourcePath'; created keys are left in place."
        return
    }

    $current = $resourcePath
    while ($current.Length -ge $rootPath.Length) {
        if (-not (Remove-WinLeanRegistryKeyIfEmpty -Path $current -WhatIf:$WhatIfPreference)) {
            break
        }
        if ([string]::Equals($current, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $current.Substring(0, $current.LastIndexOf([char]'\'))
    }
}

function Format-WinLeanRegistryState {
    <#
    .SYNOPSIS
        Human-readable form of a state: "0 (DWord)", "not set", "key missing".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $State
    )

    if (-not [bool](Get-WinLeanProperty -InputObject $State -Name 'valueExists' -Default $false)) {
        if (-not [bool](Get-WinLeanProperty -InputObject $State -Name 'keyExists' -Default $true)) {
            return 'not set (key missing)'
        }
        return 'not set'
    }
    return Format-WinLeanRegistryData -ValueType ([string]$State.valueType) -Value (Get-WinLeanProperty -InputObject $State -Name 'value' -NoEnumerate)
}

Export-ModuleMember -Function @(
    'ConvertFrom-WinLeanRegistryPath'
    'Get-WinLeanRegistryProtectedReason'
    'Get-WinLeanRegistryDedicatedReason'
    'Read-WinLeanRegistryValue'
    'Write-WinLeanRegistryValue'
    'Remove-WinLeanRegistryValue'
    'Test-WinLeanRegistryKey'
    'Remove-WinLeanRegistryKeyIfEmpty'
    'Test-WinLeanRegistryWriteAccess'
    'Get-WinLeanRegistryMissingKeyRoot'
    'Test-WinLeanRegistryValueData'
    'ConvertTo-WinLeanRegistryData'
    'ConvertTo-WinLeanRegistryState'
    'Test-WinLeanRegistryResourceDefinition'
    'ConvertTo-WinLeanRegistryResource'
    'Get-WinLeanRegistryResourceInfo'
    'Get-WinLeanRegistryResourceState'
    'Get-WinLeanRegistryDesiredState'
    'Test-WinLeanRegistryStateEqual'
    'Test-WinLeanRegistryStateRestorable'
    'Test-WinLeanRegistryResourceAccess'
    'Set-WinLeanRegistryResource'
    'Restore-WinLeanRegistryResource'
    'Format-WinLeanRegistryState'
)
