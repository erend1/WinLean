#Requires -Version 5.1
<#
    WinLean.Common
    --------------
    Shared primitives used by every other WinLean module:

      * JSON serialization with stable settings and atomic file writes
      * culture-invariant formatting and comparison helpers
      * timestamps and run identifiers
      * platform, identity and privilege facts
      * failure classification

    This module never modifies Windows configuration.

    Culture safety: WinLean must behave identically on every Windows display
    language. In particular, PowerShell's -match and -like operators are
    culture-sensitive when ignoring case (under tr-TR, 'WINDOWS' -like 'windows'
    is $false because of the dotted/dotless i). Use the helpers in this module,
    ordinal comparisons, or case-sensitive operators on normalized input instead.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:JsonDepth = 64
$script:ConvertFromJsonParameters = (Get-Command -Name ConvertFrom-Json).Parameters
$script:ModuleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.psd1'

# HRESULT values (as signed 32-bit integers) that indicate missing privileges.
$script:AccessDeniedHResults = @(
    -2147024891 # 0x80070005 E_ACCESSDENIED
    -2147024156 # 0x800702E4 ERROR_ELEVATION_REQUIRED
)

# Failure classes reported in execution and restore results.
$script:FailureClasses = @(
    'PermissionDenied'
    'Unsupported'
    'CommandFailed'
    'VerificationFailed'
    'DependencyFailure'
    'StateUnavailable'
    'BackupFailed'
    'ProtectedResource'
    'CollateralChange'
    'UnexpectedError'
)

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

function Get-WinLeanVersion {
    <#
    .SYNOPSIS
        Returns the WinLean version from the module manifest (single source of truth),
        including the prerelease label when there is one: '0.2.0-alpha'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $manifest = Import-PowerShellDataFile -LiteralPath $script:ModuleManifestPath
    $version = [string]$manifest.ModuleVersion
    $privateData = Get-WinLeanProperty -InputObject $manifest -Name 'PrivateData'
    $prerelease = [string](Get-WinLeanProperty -InputObject (Get-WinLeanProperty -InputObject $privateData -Name 'PSData') -Name 'Prerelease' -Default '')
    if ($prerelease) {
        return "$version-$prerelease"
    }
    return $version
}

# ---------------------------------------------------------------------------
# Object helpers
# ---------------------------------------------------------------------------

function Get-WinLeanProperty {
    <#
    .SYNOPSIS
        Reads a property from a PSCustomObject or dictionary without failing under strict mode.
    .PARAMETER NoEnumerate
        Returns array values as a single array object (assign the result directly; do not
        wrap the call in @()). Without it, array values are unrolled by the pipeline.
    .NOTES
        Use Get-WinLeanArrayProperty to read array-valued properties as a list of items.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $Name,

        [AllowNull()]
        $Default = $null,

        [switch] $NoEnumerate
    )

    $value = $Default
    if ($null -ne $InputObject) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if (Test-WinLeanDictionaryKey -Dictionary $InputObject -Key $Name) {
                $value = $InputObject[$Name]
            }
        }
        else {
            $property = $InputObject.PSObject.Properties[$Name]
            if ($null -ne $property) {
                $value = $property.Value
            }
        }
    }

    if ($NoEnumerate -and $null -ne $value -and (Test-WinLeanEnumerable -Value $value)) {
        return , $value
    }
    return $value
}

function Get-WinLeanArrayProperty {
    <#
    .SYNOPSIS
        Emits the items of an array-valued property. Missing or null properties emit nothing.
    .EXAMPLE
        $conditions = @(Get-WinLeanArrayProperty -InputObject $rule -Name 'conditions')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = Get-WinLeanProperty -InputObject $InputObject -Name $Name -NoEnumerate
    if ($null -eq $value) {
        return
    }
    if (Test-WinLeanEnumerable -Value $value) {
        foreach ($item in $value) {
            $item
        }
        return
    }
    $value
}

function Test-WinLeanEnumerable {
    <#
    .SYNOPSIS
        Returns $true for arrays and lists; $false for strings, dictionaries and scalars.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.Collections.IDictionary]) {
        return $false
    }
    return $Value -is [System.Collections.IEnumerable]
}

function Test-WinLeanProperty {
    <#
    .SYNOPSIS
        Returns $true when the object (PSCustomObject or dictionary) has the named property.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $false
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return (Test-WinLeanDictionaryKey -Dictionary $InputObject -Key $Name)
    }
    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Test-WinLeanDictionaryKey {
    <#
    .SYNOPSIS
        Returns $true when a dictionary contains the key.
    .NOTES
        Generic dictionaries only expose ContainsKey (IDictionary.Contains is an explicit
        interface member PowerShell cannot call), while OrderedDictionary only exposes
        Contains. This helper works for Hashtable, OrderedDictionary and Dictionary<,>.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Collections.IDictionary] $Dictionary,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Key
    )

    if ($null -eq $Dictionary) {
        return $false
    }
    if ($Dictionary -is [System.Collections.Specialized.OrderedDictionary]) {
        return [bool]$Dictionary.Contains($Key)
    }
    if ($null -ne $Dictionary.PSObject.Methods['ContainsKey']) {
        return [bool]$Dictionary.ContainsKey($Key)
    }
    return [bool]$Dictionary.Contains($Key)
}

function Get-WinLeanPropertyNames {
    <#
    .SYNOPSIS
        Returns the property (or key) names of a PSCustomObject or dictionary.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties | ForEach-Object { $_.Name })
}

function New-WinLeanDictionary {
    <#
    .SYNOPSIS
        Creates a string-keyed dictionary that compares keys ordinally and case-insensitively.
    #>
    [CmdletBinding()]
    param()

    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    return , (New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList $comparer)
}

# ---------------------------------------------------------------------------
# Culture-safe text helpers
# ---------------------------------------------------------------------------

function Test-WinLeanTextEqual {
    <#
    .SYNOPSIS
        Ordinal, case-insensitive string equality (culture independent).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [string] $Left,
        [AllowNull()] [string] $Right
    )

    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-WinLeanTextContains {
    <#
    .SYNOPSIS
        Ordinal, case-insensitive substring test (culture independent).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [string] $Text,
        [Parameter(Mandatory)] [string] $Value
    )

    if ($null -eq $Text) {
        return $false
    }
    return $Text.IndexOf($Value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-WinLeanPattern {
    <#
    .SYNOPSIS
        Regular-expression match that is always culture invariant.
    .PARAMETER CaseSensitive
        Performs a case-sensitive match. The default ignores case using invariant rules.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [string] $Text,
        [Parameter(Mandatory)] [string] $Pattern,
        [switch] $CaseSensitive
    )

    if ($null -eq $Text) {
        return $false
    }
    $options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (-not $CaseSensitive) {
        $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }
    return [System.Text.RegularExpressions.Regex]::IsMatch($Text, $Pattern, $options)
}

function Format-WinLeanNumber {
    <#
    .SYNOPSIS
        Formats a number with a fixed number of decimals using the invariant culture.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double] $Value,

        [ValidateRange(0, 6)]
        [int] $Decimals = 0
    )

    return $Value.ToString('F' + $Decimals, $script:Invariant)
}

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

function Get-WinLeanTimestamp {
    <#
    .SYNOPSIS
        Returns the current local time as an ISO 8601 string with offset.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [System.DateTimeOffset]::Now.ToString('o', $script:Invariant)
}

function New-WinLeanRunId {
    <#
    .SYNOPSIS
        Returns a sortable run identifier such as 2026-09-27_18-45-12.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [System.DateTimeOffset] $Time = [System.DateTimeOffset]::Now
    )

    return $Time.ToString('yyyy-MM-dd_HH-mm-ss', $script:Invariant)
}

function ConvertTo-WinLeanDateTimeOffset {
    <#
    .SYNOPSIS
        Converts a timestamp read from JSON (string or DateTime) to a DateTimeOffset.
    .OUTPUTS
        System.DateTimeOffset, or $null when the value cannot be interpreted.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.DateTimeOffset]) {
        return $Value
    }
    if ($Value -is [datetime]) {
        return [System.DateTimeOffset]$Value
    }
    $parsed = [System.DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([System.DateTimeOffset]::TryParse([string]$Value, $script:Invariant, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Format-WinLeanTimestamp {
    <#
    .SYNOPSIS
        Formats a timestamp for humans (invariant culture): 2026-09-27 18:45:12 +03:00.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Value
    )

    $time = ConvertTo-WinLeanDateTimeOffset -Value $Value
    if ($null -eq $time) {
        return 'unknown'
    }
    return $time.ToString('yyyy-MM-dd HH:mm:ss zzz', $script:Invariant)
}

# ---------------------------------------------------------------------------
# Paths and files
# ---------------------------------------------------------------------------

function Resolve-WinLeanPath {
    <#
    .SYNOPSIS
        Resolves a (possibly relative, possibly non-existent) path to a full file-system path.
    .NOTES
        .NET file APIs resolve relative paths against the process working directory, which
        differs from PowerShell's current location. Always resolve before calling them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-WinLeanRelativePath {
    <#
    .SYNOPSIS
        Returns Path relative to BasePath when it is located below it; otherwise the full path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $BasePath
    )

    $full = Resolve-WinLeanPath -Path $Path
    $base = (Resolve-WinLeanPath -Path $BasePath).TrimEnd('\') + '\'
    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length)
    }
    return $full
}

function ConvertTo-WinLeanJson {
    <#
    .SYNOPSIS
        Serializes an object to JSON with WinLean's standard settings.
    .NOTES
        Only serialize plain data (PSCustomObject, dictionaries, arrays, primitives).
        Live CIM or .NET objects can produce huge or cyclic output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [switch] $Compress
    )

    return ConvertTo-Json -InputObject $InputObject -Depth $script:JsonDepth -Compress:$Compress
}

function ConvertFrom-WinLeanJson {
    <#
    .SYNOPSIS
        Parses JSON text into PowerShell objects.
    .NOTES
        On PowerShell 7.5+ ISO 8601 strings are kept as strings (-DateKind String).
        Earlier PowerShell 7 versions convert such strings to DateTime; code that must
        restore exact string data detects this case and refuses to guess (see the
        registry provider).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json
    )

    $parameters = @{ InputObject = $Json }
    if ($script:ConvertFromJsonParameters.ContainsKey('DateKind')) {
        $parameters['DateKind'] = 'String'
    }
    if ($script:ConvertFromJsonParameters.ContainsKey('NoEnumerate')) {
        $parameters['NoEnumerate'] = $true
    }
    return ConvertFrom-Json @parameters
}

function Read-WinLeanJsonFile {
    <#
    .SYNOPSIS
        Reads and parses a UTF-8 JSON file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = Resolve-WinLeanPath -Path $Path
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "JSON file not found: $fullPath", $fullPath)
    }
    $text = [System.IO.File]::ReadAllText($fullPath, $script:Utf8NoBom)
    try {
        return ConvertFrom-WinLeanJson -Json $text
    }
    catch {
        $message = "Invalid JSON in '$fullPath': $($_.Exception.Message)"
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList $message, $_.Exception)
    }
}

function Write-WinLeanJsonFile {
    <#
    .SYNOPSIS
        Writes an object as UTF-8 (no BOM) JSON. The file is replaced atomically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject
    )

    $fullPath = Resolve-WinLeanPath -Path $Path
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }

    $json = ConvertTo-WinLeanJson -InputObject $InputObject
    $temporaryPath = $fullPath + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $script:Utf8NoBom)
    if ([System.IO.File]::Exists($fullPath)) {
        # [NullString]::Value: PowerShell would pass $null to a .NET string parameter as ''.
        [System.IO.File]::Replace($temporaryPath, $fullPath, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($temporaryPath, $fullPath)
    }
}

function Add-WinLeanJsonLine {
    <#
    .SYNOPSIS
        Appends one compact JSON document as a line to a JSON Lines file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject
    )

    $fullPath = Resolve-WinLeanPath -Path $Path
    $line = ConvertTo-WinLeanJson -InputObject $InputObject -Compress
    [System.IO.File]::AppendAllText($fullPath, $line + "`n", $script:Utf8NoBom)
}

function Write-WinLeanTextFile {
    <#
    .SYNOPSIS
        Writes text as UTF-8 (no BOM), creating the directory when needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    $fullPath = Resolve-WinLeanPath -Path $Path
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }
    [System.IO.File]::WriteAllText($fullPath, $Content, $script:Utf8NoBom)
}

# ---------------------------------------------------------------------------
# Failures
# ---------------------------------------------------------------------------

function Get-WinLeanFailureClasses {
    <#
    .SYNOPSIS
        Returns the list of failure classes WinLean reports.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return $script:FailureClasses
}

function New-WinLeanException {
    <#
    .SYNOPSIS
        Creates an exception that carries a WinLean failure class.
    .EXAMPLE
        throw (New-WinLeanException -Class VerificationFailed -Message 'Value was not written.')
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ $script:FailureClasses -contains $_ })]
        [string] $Class,

        [Parameter(Mandatory)]
        [string] $Message,

        [System.Exception] $InnerException
    )

    if ($InnerException) {
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList $Message, $InnerException
    }
    else {
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList $Message
    }
    $exception.Data['WinLeanFailureClass'] = $Class
    return $exception
}

function Get-WinLeanFailureClass {
    <#
    .SYNOPSIS
        Classifies an ErrorRecord or Exception into a WinLean failure class.
    .NOTES
        Classification never depends on (localized) message text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $ErrorObject
    )

    $exception = $ErrorObject
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorObject.Exception
    }

    for ($current = $exception; $null -ne $current; $current = $current.InnerException) {
        if ($current.Data.Contains('WinLeanFailureClass')) {
            return [string]$current.Data['WinLeanFailureClass']
        }
        if ($current -is [System.UnauthorizedAccessException] -or $current -is [System.Security.SecurityException]) {
            return 'PermissionDenied'
        }
        if ($script:AccessDeniedHResults -contains $current.HResult) {
            return 'PermissionDenied'
        }
        if ($current.GetType().FullName -eq 'Microsoft.Management.Infrastructure.CimException' -and
            [string]$current.NativeErrorCode -eq 'AccessDenied') {
            return 'PermissionDenied'
        }
        if ($current -is [System.PlatformNotSupportedException] -or $current -is [System.NotSupportedException]) {
            return 'Unsupported'
        }
    }

    for ($current = $exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.IO.IOException] -or
            $current -is [System.ComponentModel.Win32Exception] -or
            $current -is [System.Runtime.InteropServices.ExternalException] -or
            $current -is [System.TimeoutException]) {
            return 'CommandFailed'
        }
    }
    return 'UnexpectedError'
}

function ConvertTo-WinLeanFailure {
    <#
    .SYNOPSIS
        Converts an error into the structured failure object stored in results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $ErrorObject,

        [string] $Class
    )

    $exception = $ErrorObject
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorObject.Exception
    }
    if (-not $Class) {
        $Class = Get-WinLeanFailureClass -ErrorObject $ErrorObject
    }

    # Unwrap PowerShell's MethodInvocationException to reach the meaningful message.
    $messageSource = $exception
    while ($messageSource -is [System.Management.Automation.MethodInvocationException] -and $messageSource.InnerException) {
        $messageSource = $messageSource.InnerException
    }

    return [pscustomobject]@{
        class     = $Class
        message   = [string]$messageSource.Message
        exception = $messageSource.GetType().FullName
        hresult   = ('0x{0:X8}' -f $messageSource.HResult)
    }
}

# ---------------------------------------------------------------------------
# Identity, privileges and platform facts (read-only)
# ---------------------------------------------------------------------------

function Test-WinLeanAdministrator {
    <#
    .SYNOPSIS
        Returns $true when the current process runs with an elevated administrator token.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Get-WinLeanIdentity {
    <#
    .SYNOPSIS
        Returns the identity of the current process (name, SID, elevation).
    #>
    [CmdletBinding()]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return [pscustomobject]@{
            name            = $identity.Name
            sid             = $identity.User.Value
            isSystem        = $identity.IsSystem
            isAdministrator = (Test-WinLeanAdministrator)
        }
    }
    finally {
        $identity.Dispose()
    }
}

function Get-WinLeanInteractiveUserSid {
    <#
    .SYNOPSIS
        Returns the SID of the user that owns the desktop (explorer.exe) in the current
        session, or $null when it cannot be determined.
    .NOTES
        Used to detect "over-the-shoulder" elevation, where an administrator account other
        than the signed-in user runs WinLean. Per-user (HKCU) settings would then be
        written to the wrong profile.
    #>
    [CmdletBinding()]
    param()

    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $filter = "Name = 'explorer.exe' AND SessionId = $sessionId"
        foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop)) {
            # GetOwnerSid only reads; -WhatIf:$false keeps a caller's -WhatIf from suppressing it.
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop -WhatIf:$false -Confirm:$false
            if ($owner.ReturnValue -eq 0 -and $owner.Sid) {
                return [string]$owner.Sid
            }
        }
    }
    catch {
        Write-Verbose "Could not determine the interactive user: $($_.Exception.Message)"
    }
    return $null
}

function Get-WinLeanPlatform {
    <#
    .SYNOPSIS
        Collects the Windows platform facts WinLean needs for policy decisions.
    .NOTES
        Reads HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion (readable without elevation).
        The registry ProductName still says "Windows 10" on Windows 11, so the product name
        comes from Win32_OperatingSystem and the Windows generation from the build number.
    #>
    [CmdletBinding()]
    param()

    $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = 0
    [void][int]::TryParse([string](Get-WinLeanProperty -InputObject $currentVersion -Name 'CurrentBuildNumber' -Default '0'), [ref]$build)
    $ubr = [int](Get-WinLeanProperty -InputObject $currentVersion -Name 'UBR' -Default 0)
    $registryProductName = [string](Get-WinLeanProperty -InputObject $currentVersion -Name 'ProductName' -Default '')

    $productName = $null
    $partOfDomain = $null
    try {
        $productName = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
    }
    catch {
        Write-Verbose "Win32_OperatingSystem unavailable: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($productName)) {
        $productName = $registryProductName
        if ($build -ge 22000) {
            $productName = $productName.Replace('Windows 10', 'Windows 11')
        }
    }
    try {
        $partOfDomain = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    }
    catch {
        Write-Verbose "Win32_ComputerSystem unavailable: $($_.Exception.Message)"
    }

    $installationType = [string](Get-WinLeanProperty -InputObject $currentVersion -Name 'InstallationType' -Default '')
    return [pscustomobject]@{
        productName      = $productName.Trim()
        editionId        = [string](Get-WinLeanProperty -InputObject $currentVersion -Name 'EditionID' -Default '')
        displayVersion   = [string](Get-WinLeanProperty -InputObject $currentVersion -Name 'DisplayVersion' -Default '')
        build            = $build
        ubr              = $ubr
        version          = ('10.0.{0}.{1}' -f $build, $ubr)
        installationType = $installationType
        architecture     = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        isWindows11      = ($build -ge 22000 -and $installationType -eq 'Client')
        partOfDomain     = $partOfDomain
    }
}

# ---------------------------------------------------------------------------
# External processes
# ---------------------------------------------------------------------------

function ConvertTo-WinLeanCommandLineArgument {
    <#
    .SYNOPSIS
        Quotes one argument using the rules of CommandLineToArgvW / the MSVC runtime.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.Length -gt 0 -and $Argument.IndexOfAny([char[]]@(' ', "`t", '"')) -lt 0) {
        return $Argument
    }
    $builder = New-Object -TypeName System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append([char]'\', ($backslashes * 2) + 1)
        }
        elseif ($backslashes -gt 0) {
            [void]$builder.Append([char]'\', $backslashes)
        }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]'\', $backslashes * 2)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-WinLeanProcess {
    <#
    .SYNOPSIS
        Runs an external program with a timeout and captures its output.
    .NOTES
        Throws a CommandFailed exception on timeout. The exit code is returned, not thrown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 120
    )

    $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WinLeanCommandLineArgument -Argument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { Write-Verbose "Could not stop '$FilePath': $($_.Exception.Message)" }
            throw (New-WinLeanException -Class CommandFailed -Message "'$FilePath' did not finish within $TimeoutSeconds seconds.")
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            exitCode       = $process.ExitCode
            standardOutput = $standardOutput.Result
            standardError  = $standardError.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Get-WinLeanVersion'
    'Get-WinLeanProperty'
    'Get-WinLeanArrayProperty'
    'Test-WinLeanEnumerable'
    'Test-WinLeanProperty'
    'Test-WinLeanDictionaryKey'
    'Get-WinLeanPropertyNames'
    'New-WinLeanDictionary'
    'Test-WinLeanTextEqual'
    'Test-WinLeanTextContains'
    'Test-WinLeanPattern'
    'Format-WinLeanNumber'
    'Get-WinLeanTimestamp'
    'New-WinLeanRunId'
    'ConvertTo-WinLeanDateTimeOffset'
    'Format-WinLeanTimestamp'
    'Resolve-WinLeanPath'
    'Get-WinLeanRelativePath'
    'ConvertTo-WinLeanJson'
    'ConvertFrom-WinLeanJson'
    'Read-WinLeanJsonFile'
    'Write-WinLeanJsonFile'
    'Add-WinLeanJsonLine'
    'Write-WinLeanTextFile'
    'Get-WinLeanFailureClasses'
    'New-WinLeanException'
    'Get-WinLeanFailureClass'
    'ConvertTo-WinLeanFailure'
    'Test-WinLeanAdministrator'
    'Get-WinLeanIdentity'
    'Get-WinLeanInteractiveUserSid'
    'Get-WinLeanPlatform'
    'ConvertTo-WinLeanCommandLineArgument'
    'Invoke-WinLeanProcess'
)
