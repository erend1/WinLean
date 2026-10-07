<#
    The read-only registry access report: role mapping, access mask interpretation,
    observations and the comparison of two reports. No registry access is needed here.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Common'
    Import-Module -Name (Join-Path $script:RepoRoot 'Tools\WinLean.RegistryAccess.psm1') -DisableNameChecking

    $script:UserSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'

    function New-Entry {
        param([string] $Role, [long] $Mask = 983103, [string] $Type = 'Allow', [bool] $Inherited = $false, [string] $AppliesTo = 'this key and subkeys')
        return [pscustomobject]@{
            role = $Role; portableSid = $Role; type = $Type; rights = (Format-WinLeanAccessMask -Mask $Mask); mask = $Mask
            writeCapable = ($Type -eq 'Allow' -and $AppliesTo -ne 'subkeys only' -and (Test-WinLeanAccessMaskWritable -Mask $Mask)); isInherited = $Inherited; appliesTo = $AppliesTo
        }
    }

    function New-Key {
        param([string] $Path = 'HKCU:\Software\Policies', [object[]] $Entries = @(), [bool] $InheritanceDisabled = $true, [string] $Owner = 'SYSTEM', [bool] $Exists = $true, $CanWrite = $false)
        return [pscustomobject]@{ path = $Path; exists = $Exists; readable = $Exists; error = $null; owner = $Owner; inheritanceDisabled = $InheritanceDisabled; entries = $Entries; currentProcessCanWrite = $CanWrite }
    }

    function New-Report {
        param([object[]] $Keys, [int] $Build = 26200, [string] $Edition = 'Professional', [bool] $IsAdministrator = $false)
        return [pscustomobject]@{
            schemaVersion = 1; generatedAt = 'now'
            system = [pscustomobject]@{ productName = 'Windows 11 Pro'; editionId = $Edition; displayVersion = '25H2'; build = $Build; ubr = 1 }
            process = [pscustomobject]@{ isAdministrator = $IsAdministrator }
            keys = $Keys
        }
    }
}

Describe 'Principals' {
    It 'maps <Case> to the role <Role>' -ForEach @(
        @{ Case = 'the current user'; Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'; Role = 'CurrentUser'; Portable = 'CurrentUser' }
        @{ Case = 'SYSTEM'; Sid = 'S-1-5-18'; Role = 'SYSTEM'; Portable = 'S-1-5-18' }
        @{ Case = 'Administrators'; Sid = 'S-1-5-32-544'; Role = 'Administrators'; Portable = 'S-1-5-32-544' }
        @{ Case = 'another local account'; Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1002'; Role = 'Account (RID 1002)'; Portable = 'S-1-5-21-*-1002' }
        @{ Case = 'a capability SID'; Sid = 'S-1-15-3-1024-1065365936-1281604716'; Role = 'S-1-15-3-1024-1065365936-1281604716'; Portable = 'S-1-15-3-1024-1065365936-1281604716' }
    ) {
        # ($Role is test data; PowerShell variable names are case-insensitive.)
        $mapped = Get-WinLeanAccessRole -Sid $Sid -CurrentUserSid $script:UserSid
        $mapped.role | Should -Be $Role
        $mapped.portableSid | Should -Be $Portable
    }
}

Describe 'Access masks' {
    It 'treats <Name> as write-capable: <Writable>' -ForEach @(
        @{ Name = 'ReadKey'; Mask = 131097; Writable = $false }
        @{ Name = 'FullControl'; Mask = 983103; Writable = $true }
        @{ Name = 'SetValue'; Mask = 2; Writable = $true }
        @{ Name = 'CreateSubKey'; Mask = 4; Writable = $true }
        @{ Name = 'ChangePermissions'; Mask = 262144; Writable = $true }
        @{ Name = 'GenericRead'; Mask = 2147483648; Writable = $false }
        @{ Name = 'GenericWrite'; Mask = 1073741824; Writable = $true }
        @{ Name = 'GenericAll'; Mask = 268435456; Writable = $true }
    ) {
        Test-WinLeanAccessMaskWritable -Mask $Mask | Should -Be $Writable
    }

    It 'names rights, including generic rights' {
        Format-WinLeanAccessMask -Mask 983103 | Should -Be 'FullControl'
        Format-WinLeanAccessMask -Mask 131097 | Should -Be 'ReadKey'
        Format-WinLeanAccessMask -Mask 2147483648 | Should -Be 'GenericRead'
        Format-WinLeanAccessMask -Mask 268435456 | Should -Be 'GenericAll'
        Format-WinLeanAccessMask -Mask (2147483648 + 131097) | Should -Be 'GenericRead, ReadKey'
        Format-WinLeanAccessMask -Mask 0 | Should -Be 'None'
    }
}

Describe 'Observations' {
    It 'states facts about explicit write access without judging them' {
        $key = New-Key -CanWrite $true -Entries @(
            (New-Entry -Role 'SYSTEM')
            (New-Entry -Role 'CurrentUser')
            (New-Entry -Role 'RESTRICTED' -Mask 131097)
        )
        $observations = @(Get-WinLeanRegistryAccessObservations -Key $key)
        $observations | Should -Contain 'Inheritance from the parent key is disabled; all 3 entries are explicit.'
        $observations | Should -Contain 'Explicit entry: CurrentUser may change this key (FullControl).'
        $observations | Should -Contain 'This process can write to the key.'
        ($observations -join ' ') | Should -Not -Match 'error|wrong|incorrect|misconfigur|repair|fix'
    }

    It 'reports inherited entries, deny entries and missing keys' {
        $key = New-Key -InheritanceDisabled $false -Entries @((New-Entry -Role 'CurrentUser' -Inherited $true), (New-Entry -Role 'Everyone' -Type 'Deny' -Mask 2))
        $observations = @(Get-WinLeanRegistryAccessObservations -Key $key)
        $observations | Should -Contain '1 explicit and 1 inherited entries.'
        $observations | Should -Contain 'Deny entry for Everyone (SetValue).'
        @(Get-WinLeanRegistryAccessObservations -Key (New-Key -Exists $false)) | Should -Be @('The key does not exist.')
    }

    It 'explains in the report that a comparison is needed before any conclusion' {
        $text = (Format-WinLeanRegistryAccessReport -Report (New-Report -Keys @(New-Key -Entries @(New-Entry -Role 'CurrentUser')))) -join "`n"
        $text | Should -BeLike '*read-only*'
        $text | Should -BeLike '*it does not judge them. An unusual entry is not an error.*'
        $text | Should -BeLike '*clean VM*same Windows build and edition*'
        $text | Should -BeLike '*explicit*Allow*CurrentUser*FullControl*`[can change`]*'
    }
}

Describe 'Comparison of two reports' {
    BeforeAll {
        $script:CleanEntries = @((New-Entry -Role 'SYSTEM'), (New-Entry -Role 'Administrators'), (New-Entry -Role 'CurrentUser' -Mask 131097))
    }

    It 'finds identical keys identical, also after a JSON round trip' {
        $reference = New-Report -Keys @(New-Key -Entries $script:CleanEntries)
        $examined = (New-Report -Keys @(New-Key -Entries $script:CleanEntries)) | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $comparison = Compare-WinLeanRegistryAccessReport -Reference $reference -Difference $examined
        $comparison.conclusive | Should -BeTrue
        $comparison.keys[0].identical | Should -BeTrue
        (Format-WinLeanRegistryAccessComparison -Comparison $comparison) -join "`n" | Should -BeLike '*identical*'
    }

    It 'lists entries that exist in only one report, and owner and inheritance differences' {
        $reference = New-Report -Keys @(New-Key -Entries $script:CleanEntries)
        $examined = New-Report -Keys @(New-Key -Owner 'Administrators' -InheritanceDisabled $false -Entries @((New-Entry -Role 'SYSTEM'), (New-Entry -Role 'Administrators'), (New-Entry -Role 'CurrentUser')))
        $comparison = Compare-WinLeanRegistryAccessReport -Reference $reference -Difference $examined
        $differences = @($comparison.keys[0].differences)
        $comparison.keys[0].identical | Should -BeFalse
        $differences | Should -Contain "Owner: reference 'SYSTEM', examined 'Administrators'."
        $differences | Should -Contain 'Inheritance disabled: reference True, examined False.'
        $differences | Should -Contain 'Only in the examined report: explicit Allow CurrentUser: FullControl (this key and subkeys).'
        $differences | Should -Contain 'Only in the reference report: explicit Allow CurrentUser: ReadKey (this key and subkeys).'
    }

    It 'is not conclusive across Windows builds or editions' {
        $examined = New-Report -Keys @(New-Key -Entries $script:CleanEntries)
        $otherBuild = Compare-WinLeanRegistryAccessReport -Reference (New-Report -Build 26100 -Keys @(New-Key -Entries $script:CleanEntries)) -Difference $examined
        $otherBuild.conclusive | Should -BeFalse
        $otherBuild.notes[0] | Should -BeLike '*different Windows builds (26100 and 26200)*'
        (Format-WinLeanRegistryAccessComparison -Comparison $otherBuild) -join "`n" | Should -BeLike '*NOT CONCLUSIVE*'
        (Compare-WinLeanRegistryAccessReport -Reference (New-Report -Edition 'Enterprise' -Keys @(New-Key -Entries $script:CleanEntries)) -Difference $examined).conclusive | Should -BeFalse
    }

    It 'never presents a difference as proof of an error' {
        $comparison = Compare-WinLeanRegistryAccessReport -Reference (New-Report -Keys @(New-Key -Entries $script:CleanEntries)) -Difference (New-Report -Keys @(New-Key -Entries @(New-Entry -Role 'CurrentUser')))
        $text = (Format-WinLeanRegistryAccessComparison -Comparison $comparison) -join "`n"
        $text | Should -BeLike '*it does not show why, or that it is harmful*'
        $text | Should -BeLike '*WinLean does not change access control lists*'
    }

    It 'notes keys the reference does not contain and reports created with different privileges' {
        $reference = New-Report -IsAdministrator $true -Keys @(New-Key -Path 'HKCU:\Software' -Entries $script:CleanEntries)
        $comparison = Compare-WinLeanRegistryAccessReport -Reference $reference -Difference (New-Report -Keys @(New-Key -Entries $script:CleanEntries))
        $comparison.keys[0].comparable | Should -BeFalse
        ($comparison.notes -join ' ') | Should -BeLike '*created elevated*'
    }
}

Describe 'Read-only guarantee' {
    It 'contains no code that could change access control, keys or values' {
        # Cmdlets by name; .NET members as calls (the code names rights such as CreateSubKey in comments).
        $forbidden = 'Set-Acl|New-Item|Set-Item|Set-ItemProperty|Remove-Item|Remove-ItemProperty|Write-WinLeanRegistryValue|Remove-WinLeanRegistry|' +
            '\.(SetAccessControl|SetOwner|SetAccessRule|AddAccessRule|RemoveAccessRule\w*|PurgeAccessRules|SetAccessRuleProtection|SetSecurityDescriptor\w*|CreateSubKey|DeleteSubKey\w*|SetValue|DeleteValue)\('
        foreach ($file in @('Tools\WinLean.RegistryAccess.psm1', 'Tools\Get-WinLeanRegistryAccessReport.ps1')) {
            $code = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot $file)
            [regex]::Matches($code, $forbidden).Count | Should -Be 0 -Because "$file must stay read-only"
        }
    }
}
