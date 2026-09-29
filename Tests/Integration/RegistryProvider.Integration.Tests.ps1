<#
    Real registry operations, confined to Pester's TestRegistry
    (HKCU\Software\Pester\<guid>, deleted automatically after the tests).
#>
BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before modules are imported.
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $script:IsAdministrator = ([System.Security.Principal.WindowsPrincipal]$identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Provider.Registry', 'WinLean.Common'

    function Get-TestRegistryBase {
        $root = (Get-PSDrive -Name TestRegistry).Root
        if ($root.StartsWith('HKEY_CURRENT_USER\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'HKCU:\' + $root.Substring('HKEY_CURRENT_USER\'.Length)
        }
        return $root.TrimEnd('\')
    }

    function New-Resource {
        param([string] $Path, [string] $Name, [string] $ValueType, $Value, [string] $Ensure = 'Present')
        $definition = @{ type = 'RegistryValue'; path = $Path; name = $Name }
        if ($Ensure -eq 'Absent') { $definition['ensure'] = 'Absent' } else { $definition['valueType'] = $ValueType; $definition['value'] = $Value }
        return ConvertTo-WinLeanRegistryResource -Definition (ConvertTo-JsonShape -InputObject $definition)
    }
}

Describe 'Registry provider against the real registry' {
    BeforeEach {
        $base = Get-TestRegistryBase
        $key = "$base\Values"
    }

    It 'writes and reads back <ValueType> values exactly' -ForEach @(
        @{ ValueType = 'DWord'; Value = [uint32]4294967295 }
        @{ ValueType = 'QWord'; Value = '18446744073709551615' }
        @{ ValueType = 'String'; Value = 'text with spaces' }
        @{ ValueType = 'ExpandString'; Value = '%SystemRoot%\not-expanded' }
        @{ ValueType = 'MultiString'; Value = @('only') }
        @{ ValueType = 'Binary'; Value = '00ff10' }
    ) {
        $resource = New-Resource -Path $key -Name $ValueType -ValueType $ValueType -Value $Value
        Set-WinLeanRegistryResource -Resource $resource
        $state = Get-WinLeanRegistryResourceState -Resource $resource
        $state.valueType | Should -Be $ValueType
        Test-WinLeanRegistryStateEqual -Expected (Get-WinLeanRegistryDesiredState -Resource $resource) -Actual $state | Should -BeTrue
    }

    It 'reads values case-insensitively by name' {
        $resource = New-Resource -Path $key -Name 'MixedCase' -ValueType 'DWord' -Value 1
        Set-WinLeanRegistryResource -Resource $resource
        (Read-WinLeanRegistryValue -Path $key -Name 'MIXEDCASE').valueExists | Should -BeTrue
    }

    It 'finds the shallowest missing key and removes created keys again on restore' {
        $deep = "$base\Created\Deeper\Deepest"
        Get-WinLeanRegistryMissingKeyRoot -Path $deep | Should -Be "$base\Created"
        $resource = New-Resource -Path $deep -Name 'Value' -ValueType 'DWord' -Value 1
        $before = Get-WinLeanRegistryResourceState -Resource $resource
        $before.keyExists | Should -BeFalse
        $before.missingKeyRoot | Should -Be "$base\Created"

        Set-WinLeanRegistryResource -Resource $resource
        Test-WinLeanRegistryKey -Path $deep | Should -BeTrue
        Restore-WinLeanRegistryResource -Resource $resource -State $before
        Test-WinLeanRegistryKey -Path "$base\Created" | Should -BeFalse
        Test-WinLeanRegistryKey -Path $base | Should -BeTrue
    }

    It 'keeps created keys that received other content in the meantime' {
        $deep = "$base\Shared\Child"
        $resource = New-Resource -Path $deep -Name 'Value' -ValueType 'DWord' -Value 1
        $before = Get-WinLeanRegistryResourceState -Resource $resource
        Set-WinLeanRegistryResource -Resource $resource
        Write-WinLeanRegistryValue -Path "$base\Shared" -Name 'SomethingElse' -Kind String -Data 'keep'
        Restore-WinLeanRegistryResource -Resource $resource -State $before
        Test-WinLeanRegistryKey -Path $deep | Should -BeFalse
        Test-WinLeanRegistryKey -Path "$base\Shared" | Should -BeTrue
    }

    It 'restores a deleted value with its original kind' {
        Write-WinLeanRegistryValue -Path $key -Name 'Original' -Kind ExpandString -Data '%TEMP%\keep'
        $absent = New-Resource -Path $key -Name 'Original' -Ensure 'Absent'
        $before = Get-WinLeanRegistryResourceState -Resource $absent
        Set-WinLeanRegistryResource -Resource $absent
        (Read-WinLeanRegistryValue -Path $key -Name 'Original').valueExists | Should -BeFalse
        Restore-WinLeanRegistryResource -Resource $absent -State $before
        $raw = Read-WinLeanRegistryValue -Path $key -Name 'Original'
        $raw.kind | Should -Be 'ExpandString'
        $raw.data | Should -BeExactly '%TEMP%\keep'
    }

    It 'probes write access without creating anything' {
        Test-WinLeanRegistryWriteAccess -Path "$base\Probe\Not\Created" | Should -BeTrue
        Test-WinLeanRegistryKey -Path "$base\Probe" | Should -BeFalse
    }

    It 'reports missing write access to machine policies for standard users' -Skip:$script:IsAdministrator {
        Test-WinLeanRegistryWriteAccess -Path 'HKLM:\SOFTWARE\Policies\WinLeanNeverCreated' | Should -BeFalse
    }
}
