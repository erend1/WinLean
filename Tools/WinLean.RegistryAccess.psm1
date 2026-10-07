#Requires -Version 5.1
<#
    WinLean.RegistryAccess
    ----------------------
    Read-only diagnostics for registry key access control: which access entries a key has,
    which of them are explicit and which are inherited, and who can write.

    Background: on the development machine of milestone 0.1 the signed-in standard user
    could write to HKCU\Software\Policies without elevation. WinLean neither relies on that
    nor changes it - the policy engine probes real write access for every rule - and this
    module exists to describe such observations precisely.

    Rules of this module:

      * It never modifies anything: no access entry, owner, key or value is written. There
        is no "repair" or "normalize" function, by design.
      * It reports facts and does not judge them. An unusual entry is not an error. A
        conclusion needs a comparison with a clean installation of the same Windows build
        and edition (Compare-WinLeanRegistryAccessReport) and an explanation of every
        difference.
      * Saved reports identify principals by role, not by name: well-known SIDs are kept
        (they are the same on every machine), the current user becomes 'CurrentUser', and
        other machine-specific account SIDs are reduced to their relative id, so reports
        from two machines can be compared and shared without account identifiers.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\src'))
Import-Module -Name (Join-Path -Path $sourceRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $sourceRoot -ChildPath 'Providers\WinLean.Provider.Registry.psm1')

# Access mask bits that allow changing a key: SetValue, CreateSubKey, Delete,
# ChangePermissions, TakeOwnership, GENERIC_ALL and GENERIC_WRITE. The L suffix matters: a
# plain hexadecimal literal such as 0x80000000 is a negative 32-bit number in PowerShell.
$script:WriteMask = 0x2L -bor 0x4L -bor 0x10000L -bor 0x40000L -bor 0x80000L -bor 0x10000000L -bor 0x40000000L
$script:GenericRights = [ordered]@{
    'GenericRead'    = 0x80000000L
    'GenericWrite'   = 0x40000000L
    'GenericExecute' = 0x20000000L
    'GenericAll'     = 0x10000000L
}

# Well-known principals shown by name in reports (their SIDs are identical everywhere).
$script:WellKnownRoles = @{
    'S-1-1-0'      = 'Everyone'
    'S-1-3-0'      = 'CREATOR OWNER'
    'S-1-5-11'     = 'Authenticated Users'
    'S-1-5-12'     = 'RESTRICTED'
    'S-1-5-18'     = 'SYSTEM'
    'S-1-5-19'     = 'LOCAL SERVICE'
    'S-1-5-20'     = 'NETWORK SERVICE'
    'S-1-5-32-544' = 'Administrators'
    'S-1-5-32-545' = 'Users'
    'S-1-15-2-1'   = 'ALL APPLICATION PACKAGES'
    'S-1-15-2-2'   = 'ALL RESTRICTED APPLICATION PACKAGES'
}

$script:DefaultPaths = @(
    'HKCU:\Software'
    'HKCU:\Software\Policies'
    'HKCU:\Software\Policies\Microsoft'
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies'
    'HKLM:\SOFTWARE\Policies'
)

function Get-WinLeanRegistryAccessDefaultPaths {
    <#
    .SYNOPSIS
        The keys reported by default: the per-user policy keys with their parent, and the
        machine policy key for reference.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:DefaultPaths
}

function Get-WinLeanAccessRole {
    <#
    .SYNOPSIS
        Maps a SID to a role that means the same on every machine. Pure function.
    .OUTPUTS
        Object with role (comparison key) and portableSid (safe to store and share).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Sid,
        [AllowNull()] [string] $CurrentUserSid
    )

    if ($CurrentUserSid -and [string]::Equals($Sid, $CurrentUserSid, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ role = 'CurrentUser'; portableSid = 'CurrentUser' }
    }
    if ($script:WellKnownRoles.ContainsKey($Sid)) {
        return [pscustomobject]@{ role = $script:WellKnownRoles[$Sid]; portableSid = $Sid }
    }
    $match = [System.Text.RegularExpressions.Regex]::Match($Sid, '^S-1-5-21-\d+-\d+-\d+-(?<rid>\d+)$', 'CultureInvariant')
    if ($match.Success) {
        # Machine- or domain-specific account: keep only the relative id.
        $role = 'Account (RID ' + $match.Groups['rid'].Value + ')'
        return [pscustomobject]@{ role = $role; portableSid = 'S-1-5-21-*-' + $match.Groups['rid'].Value }
    }
    return [pscustomobject]@{ role = $Sid; portableSid = $Sid }
}

function Test-WinLeanAccessMaskWritable {
    <#
    .SYNOPSIS
        Returns $true when an access mask allows changing a key (values, subkeys, deletion,
        permissions or ownership). Pure function.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [int64] $Mask)

    return (($Mask -band $script:WriteMask) -ne 0)
}

function Format-WinLeanAccessMask {
    <#
    .SYNOPSIS
        Names the rights in a registry access mask, including generic rights that
        RegistryRights does not name. Pure function.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [int64] $Mask)

    $names = New-Object -TypeName System.Collections.Generic.List[string]
    $remaining = $Mask
    foreach ($name in $script:GenericRights.Keys) {
        if (($Mask -band $script:GenericRights[$name]) -ne 0) {
            $names.Add($name)
            $remaining = $remaining -band (-bnot $script:GenericRights[$name])
        }
    }
    if ($remaining -ne 0) {
        $names.Add(([System.Security.AccessControl.RegistryRights][int]$remaining).ToString())
    }
    if ($names.Count -eq 0) {
        return 'None'
    }
    return ($names.ToArray() -join ', ')
}

function ConvertTo-WinLeanAccessMask {
    [CmdletBinding()]
    [OutputType([int64])]
    param([Parameter(Mandatory)] $Rights)

    # The enum value is a signed 32-bit integer; generic rights use the high bits.
    return ([int64][int]$Rights) -band 0xFFFFFFFFL
}

function Get-WinLeanRegistryKeyAccess {
    <#
    .SYNOPSIS
        Reads the owner and the access entries of one registry key. Read-only.
    .OUTPUTS
        Object with path, exists, readable, owner, inheritanceDisabled, entries (role,
        portableSid, type, rights, mask, writeCapable, isInherited, appliesTo) and
        currentProcessCanWrite (non-modifying probe).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] [string] $CurrentUserSid
    )

    $location = ConvertFrom-WinLeanRegistryPath -Path $Path
    $result = [pscustomobject]@{
        path                   = $location.path
        exists                 = $false
        readable               = $false
        error                  = $null
        owner                  = $null
        inheritanceDisabled    = $null
        entries                = @()
        currentProcessCanWrite = $null
    }

    $hive = if ($location.hive -eq 'HKCU') { [Microsoft.Win32.RegistryHive]::CurrentUser } else { [Microsoft.Win32.RegistryHive]::LocalMachine }
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
    try {
        $key = $null
        try {
            $key = $baseKey.OpenSubKey($location.subKey, $false)
        }
        catch {
            $result.exists = $true
            $result.error = "The key could not be opened for reading: $($_.Exception.Message)"
            return $result
        }
        if ($null -eq $key) {
            return $result
        }
        try {
            $result.exists = $true
            $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
            try {
                $security = $key.GetAccessControl($sections)
            }
            catch {
                $result.error = "The access control list could not be read: $($_.Exception.Message)"
                return $result
            }
            $result.readable = $true
            $result.inheritanceDisabled = [bool]$security.AreAccessRulesProtected
            $ownerSid = $security.GetOwner([System.Security.Principal.SecurityIdentifier])
            if ($null -ne $ownerSid) {
                $result.owner = (Get-WinLeanAccessRole -Sid $ownerSid.Value -CurrentUserSid $CurrentUserSid).role
            }
            $result.entries = @(foreach ($rule in $security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                    $role = Get-WinLeanAccessRole -Sid $rule.IdentityReference.Value -CurrentUserSid $CurrentUserSid
                    $mask = ConvertTo-WinLeanAccessMask -Rights $rule.RegistryRights
                    $inheritOnly = ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
                    $appliesTo = if ($inheritOnly) { 'subkeys only' }
                    elseif ($rule.InheritanceFlags -eq [System.Security.AccessControl.InheritanceFlags]::None) { 'this key only' }
                    else { 'this key and subkeys' }
                    $allows = ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow)
                    [pscustomobject]@{
                        role         = $role.role
                        portableSid  = $role.portableSid
                        type         = if ($allows) { 'Allow' } else { 'Deny' }
                        rights       = Format-WinLeanAccessMask -Mask $mask
                        mask         = $mask
                        # An entry that applies to subkeys only does not change this key itself.
                        writeCapable = ($allows -and -not $inheritOnly -and (Test-WinLeanAccessMaskWritable -Mask $mask))
                        isInherited  = [bool]$rule.IsInherited
                        appliesTo    = $appliesTo
                    }
                })
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
    try {
        $result.currentProcessCanWrite = [bool](Test-WinLeanRegistryWriteAccess -Path $location.path)
    }
    catch {
        Write-Verbose "Write access to '$($location.path)' could not be probed: $($_.Exception.Message)"
    }
    return $result
}

function Get-WinLeanRegistryAccessReport {
    <#
    .SYNOPSIS
        Builds the access report for a set of registry keys. Read-only.
    .PARAMETER Path
        Keys to report ('HKCU:\...' or 'HKLM:\...'). Defaults to the policy keys.
    #>
    [CmdletBinding()]
    param([string[]] $Path = @(Get-WinLeanRegistryAccessDefaultPaths))

    $identity = Get-WinLeanIdentity
    $platform = Get-WinLeanPlatform
    return [pscustomobject]@{
        schemaVersion = 1
        generatedAt   = Get-WinLeanTimestamp
        system        = [pscustomobject]@{
            productName    = $platform.productName
            editionId      = $platform.editionId
            displayVersion = $platform.displayVersion
            build          = $platform.build
            ubr            = $platform.ubr
        }
        process       = [pscustomobject]@{ isAdministrator = [bool]$identity.isAdministrator }
        keys          = @(foreach ($item in $Path) { Get-WinLeanRegistryKeyAccess -Path $item -CurrentUserSid ([string]$identity.sid) })
    }
}

function Get-WinLeanRegistryAccessObservations {
    <#
    .SYNOPSIS
        Neutral observations about one key: facts worth comparing, not verdicts. Pure function.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Key)

    if (-not $Key.exists) {
        'The key does not exist.'
        return
    }
    if (-not $Key.readable) {
        [string]$Key.error
        return
    }
    $entries = @($Key.entries)
    $explicit = @($entries | Where-Object { -not $_.isInherited })
    $inherited = @($entries | Where-Object { $_.isInherited })
    if ($Key.inheritanceDisabled) {
        "Inheritance from the parent key is disabled; all $($explicit.Count) entries are explicit."
    }
    else {
        "$($explicit.Count) explicit and $($inherited.Count) inherited entries."
    }
    foreach ($entry in @($explicit | Where-Object { $_.writeCapable })) {
        "Explicit entry: $($entry.role) may change this key ($($entry.rights))."
    }
    foreach ($entry in @($entries | Where-Object { $_.type -ceq 'Deny' })) {
        "Deny entry for $($entry.role) ($($entry.rights))."
    }
    if ($null -ne $Key.currentProcessCanWrite) {
        if ($Key.currentProcessCanWrite) { 'This process can write to the key.' } else { 'This process cannot write to the key.' }
    }
}

function Format-WinLeanRegistryAccessReport {
    <#
    .SYNOPSIS
        Console rendering of an access report.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Report)

    ''
    'WINLEAN REGISTRY ACCESS REPORT (read-only)'
    ''
    'Windows:   {0}, edition {1}, version {2}, build {3}.{4}' -f $Report.system.productName, $Report.system.editionId, $Report.system.displayVersion, $Report.system.build, $Report.system.ubr
    'Elevated:  {0}' -f $(if ($Report.process.isAdministrator) { 'Yes' } else { 'No' })
    foreach ($key in @($Report.keys)) {
        ''
        [string]$key.path
        if ($key.exists -and $key.readable) {
            '  Owner: {0}' -f $key.owner
            '  {0,-9} {1,-5} {2,-39} {3,-21} {4}' -f 'SOURCE', 'TYPE', 'PRINCIPAL', 'APPLIES TO', 'RIGHTS'
            foreach ($entry in @($key.entries)) {
                $source = if ($entry.isInherited) { 'inherited' } else { 'explicit' }
                $principal = [string]$entry.role
                if ($principal.Length -gt 38) { $principal = $principal.Substring(0, 35) + '...' }
                '  {0,-9} {1,-5} {2,-39} {3,-21} {4}{5}' -f $source, $entry.type, $principal, $entry.appliesTo, $entry.rights, $(if ($entry.writeCapable) { '  [can change]' } else { '' })
            }
        }
        foreach ($observation in @(Get-WinLeanRegistryAccessObservations -Key $key)) {
            '  - ' + $observation
        }
    }
    ''
    'This report lists access entries; it does not judge them. An unusual entry is not an error.'
    'To evaluate one, save this report (-OutputPath), create the same report in a clean VM of the'
    'same Windows build and edition, and compare the two (-CompareWith). WinLean never changes'
    'access control lists.'
    ''
}

function ConvertTo-WinLeanAccessEntryKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Entry)

    return ('{0}|{1}|{2}|{3}|{4}' -f $Entry.role, $Entry.type, $Entry.mask, $(if ($Entry.isInherited) { 'inherited' } else { 'explicit' }), $Entry.appliesTo)
}

function Compare-WinLeanRegistryAccessReport {
    <#
    .SYNOPSIS
        Compares two access reports key by key. Pure function.
    .PARAMETER Reference
        The report to compare against, normally from a clean VM of the same build.
    .PARAMETER Difference
        The report under examination.
    .OUTPUTS
        Object with conclusive ($true only when both reports come from the same Windows
        build and edition), notes, and per key the entries found only in one report, owner
        and inheritance differences.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Reference,
        [Parameter(Mandatory)] $Difference
    )

    $notes = New-Object -TypeName System.Collections.Generic.List[string]
    $sameBuild = ([string]$Reference.system.build -eq [string]$Difference.system.build)
    $sameEdition = [string]::Equals([string]$Reference.system.editionId, [string]$Difference.system.editionId, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $sameBuild) {
        $notes.Add("The reports come from different Windows builds ($($Reference.system.build) and $($Difference.system.build)); differences may be caused by the build.")
    }
    if (-not $sameEdition) {
        $notes.Add("The reports come from different Windows editions ($($Reference.system.editionId) and $($Difference.system.editionId)).")
    }
    if ([bool]$Reference.process.isAdministrator -ne [bool]$Difference.process.isAdministrator) {
        $notes.Add('One report was created elevated and the other was not; "this process can write" is not comparable.')
    }

    $referenceKeys = New-WinLeanDictionary
    foreach ($key in @($Reference.keys)) { $referenceKeys[[string]$key.path] = $key }
    $keys = @(foreach ($key in @($Difference.keys)) {
            $path = [string]$key.path
            if (-not $referenceKeys.ContainsKey($path)) {
                [pscustomobject]@{ path = $path; comparable = $false; identical = $false; differences = @('The reference report does not contain this key.') }
                continue
            }
            $other = $referenceKeys[$path]
            $differences = New-Object -TypeName System.Collections.Generic.List[string]
            if ([bool]$other.exists -ne [bool]$key.exists) {
                $differences.Add("Exists: reference $([bool]$other.exists), examined $([bool]$key.exists).")
            }
            elseif ($key.exists) {
                if ([string]$other.owner -ne [string]$key.owner) {
                    $differences.Add("Owner: reference '$($other.owner)', examined '$($key.owner)'.")
                }
                if ([bool]$other.inheritanceDisabled -ne [bool]$key.inheritanceDisabled) {
                    $differences.Add("Inheritance disabled: reference $([bool]$other.inheritanceDisabled), examined $([bool]$key.inheritanceDisabled).")
                }
                $referenceEntries = New-WinLeanDictionary
                foreach ($entry in @($other.entries)) { $referenceEntries[(ConvertTo-WinLeanAccessEntryKey -Entry $entry)] = $entry }
                $examinedEntries = New-WinLeanDictionary
                foreach ($entry in @($key.entries)) { $examinedEntries[(ConvertTo-WinLeanAccessEntryKey -Entry $entry)] = $entry }
                foreach ($id in @($examinedEntries.Keys)) {
                    if (-not $referenceEntries.ContainsKey($id)) {
                        $entry = $examinedEntries[$id]
                        $differences.Add("Only in the examined report: $(if ($entry.isInherited) { 'inherited' } else { 'explicit' }) $($entry.type) $($entry.role): $($entry.rights) ($($entry.appliesTo)).")
                    }
                }
                foreach ($id in @($referenceEntries.Keys)) {
                    if (-not $examinedEntries.ContainsKey($id)) {
                        $entry = $referenceEntries[$id]
                        $differences.Add("Only in the reference report: $(if ($entry.isInherited) { 'inherited' } else { 'explicit' }) $($entry.type) $($entry.role): $($entry.rights) ($($entry.appliesTo)).")
                    }
                }
            }
            [pscustomobject]@{ path = $path; comparable = $true; identical = ($differences.Count -eq 0); differences = $differences.ToArray() }
        })

    return [pscustomobject]@{
        conclusive = ($sameBuild -and $sameEdition)
        reference  = $Reference.system
        examined   = $Difference.system
        notes      = $notes.ToArray()
        keys       = $keys
    }
}

function Format-WinLeanRegistryAccessComparison {
    <#
    .SYNOPSIS
        Console rendering of a report comparison.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Comparison)

    ''
    'COMPARISON WITH THE REFERENCE REPORT'
    ''
    'Reference: {0}, edition {1}, build {2}.{3}' -f $Comparison.reference.productName, $Comparison.reference.editionId, $Comparison.reference.build, $Comparison.reference.ubr
    'Examined:  {0}, edition {1}, build {2}.{3}' -f $Comparison.examined.productName, $Comparison.examined.editionId, $Comparison.examined.build, $Comparison.examined.ubr
    foreach ($note in @($Comparison.notes)) {
        'Note: ' + $note
    }
    foreach ($key in @($Comparison.keys)) {
        ''
        [string]$key.path
        if ($key.identical) {
            '  identical'
            continue
        }
        foreach ($difference in @($key.differences)) {
            '  - ' + $difference
        }
    }
    ''
    if ($Comparison.conclusive) {
        'Both reports come from the same Windows build and edition. A difference shows that the'
        'examined system deviates from the reference; it does not show why, or that it is harmful.'
        'Explain every difference (software, policy, migration, manual change) before drawing a'
        'conclusion. WinLean does not change access control lists.'
    }
    else {
        'NOT CONCLUSIVE: the reports do not come from the same Windows build and edition. Create'
        'the reference report in a clean VM of the same build and edition.'
    }
    ''
}

Export-ModuleMember -Function @(
    'Get-WinLeanRegistryAccessDefaultPaths'
    'Get-WinLeanAccessRole'
    'Test-WinLeanAccessMaskWritable'
    'Format-WinLeanAccessMask'
    'Get-WinLeanRegistryKeyAccess'
    'Get-WinLeanRegistryAccessReport'
    'Get-WinLeanRegistryAccessObservations'
    'Format-WinLeanRegistryAccessReport'
    'Compare-WinLeanRegistryAccessReport'
    'Format-WinLeanRegistryAccessComparison'
)
