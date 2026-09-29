BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Provider.Registry'
}

Describe 'Registry paths' {
    It 'parses HKCU and HKLM paths case-insensitively' {
        $location = ConvertFrom-WinLeanRegistryPath -Path 'hklm:\Software\Policies\X'
        $location.hive | Should -Be 'HKLM'
        $location.subKey | Should -Be 'Software\Policies\X'
        $location.path | Should -Be 'HKLM:\Software\Policies\X'
    }

    It 'rejects <Path>' -ForEach @(
        @{ Path = 'HKU:\S-1-5-18\Software' }
        @{ Path = 'HKCU\Software\X' }
        @{ Path = 'HKCU:\Software\\X' }
        @{ Path = 'Registry::HKEY_CURRENT_USER\Software' }
    ) {
        { ConvertFrom-WinLeanRegistryPath -Path $Path } | Should -Throw
    }
}

Describe 'Protected locations' {
    It 'protects <Path>\<Name>' -ForEach @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableRealtimeMonitoring' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate' }
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend'; Name = 'Start' }
        @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\wuauserv'; Name = 'Start' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\StandardProfile'; Name = 'EnableFirewall' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLUA' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled' }
    ) {
        Get-WinLeanRegistryProtectedReason -Path $Path -Name $Name | Should -Not -BeNullOrEmpty
    }

    It 'allows ordinary locations and unprotected values next to protected ones' {
        Get-WinLeanRegistryProtectedReason -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' | Should -BeNullOrEmpty
        Get-WinLeanRegistryProtectedReason -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'Other' | Should -BeNullOrEmpty
        Get-WinLeanRegistryProtectedReason -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defenderish' -Name 'X' | Should -BeNullOrEmpty
    }

    It 'refuses to write a protected value even when called directly' {
        { Write-WinLeanRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Kind DWord -Data 1 } |
            Should -Throw -ExpectedMessage '*protected registry location*'
        { Remove-WinLeanRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend' -Name 'Start' } |
            Should -Throw -ExpectedMessage '*protected registry location*'
    }
}

Describe 'Resource definitions' {
    It 'accepts <Case>' -ForEach @(
        @{ Case = 'a DWord'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = 4294967295 } }
        @{ Case = 'a QWord string'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'QWord'; value = '18446744073709551615' } }
        @{ Case = 'a MultiString'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'MultiString'; value = @('a') } }
        @{ Case = 'a Binary value'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'Binary'; value = '0A0b' } }
        @{ Case = 'an absent value'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; ensure = 'Absent' } }
    ) {
        @(Test-WinLeanRegistryResourceDefinition -Definition (ConvertTo-JsonShape -InputObject $Definition)).Count | Should -Be 0
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a negative DWord'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = -1 } }
        @{ Case = 'a DWord above 32 bits'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = 4294967296 } }
        @{ Case = 'a string for a DWord'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = '0' } }
        @{ Case = 'a fractional DWord'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = 1.5 } }
        @{ Case = 'a scalar MultiString'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'MultiString'; value = 'a' } }
        @{ Case = 'odd-length hex'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'Binary'; value = 'abc' } }
        @{ Case = 'a value for an absent resource'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; ensure = 'Absent'; value = 1 } }
        @{ Case = 'the unnamed default value'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = ''; valueType = 'String'; value = 'x' } }
        @{ Case = 'a lowercase value type'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'dword'; value = 1 } }
        @{ Case = 'an unknown property'; Definition = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = 1; hive = 'HKCU' } }
    ) {
        @(Test-WinLeanRegistryResourceDefinition -Definition (ConvertTo-JsonShape -InputObject $Definition)).Count | Should -BeGreaterThan 0
    }
}

Describe 'State conversion' {
    It 'converts raw <Kind> data losslessly' -ForEach @(
        @{ Kind = 'DWord'; Data = [int]-1; ExpectedType = 'DWord'; Expected = [uint32]4294967295 }
        @{ Kind = 'QWord'; Data = [long]-1; ExpectedType = 'QWord'; Expected = '18446744073709551615' }
        @{ Kind = 'Binary'; Data = [byte[]](10, 255); ExpectedType = 'Binary'; Expected = '0aff' }
        @{ Kind = 'ExpandString'; Data = '%SystemRoot%\x'; ExpectedType = 'ExpandString'; Expected = '%SystemRoot%\x' }
    ) {
        $state = ConvertTo-WinLeanRegistryState -Raw ([pscustomobject]@{ keyExists = $true; valueExists = $true; kind = $Kind; data = $Data })
        $state.valueType | Should -Be $ExpectedType
        $state.value | Should -Be $Expected
        $state.restorable | Should -BeTrue
    }

    It 'keeps single-element MultiString values as arrays' {
        $state = ConvertTo-WinLeanRegistryState -Raw ([pscustomobject]@{ keyExists = $true; valueExists = $true; kind = 'MultiString'; data = [string[]]@('only') })
        , $state.value | Should -BeOfType [string[]]
        $state.value.Count | Should -Be 1
    }

    It 'marks unsupported kinds as not restorable' {
        $state = ConvertTo-WinLeanRegistryState -Raw ([pscustomobject]@{ keyExists = $true; valueExists = $true; kind = 'None'; data = [byte[]](1) })
        $state.restorable | Should -BeFalse
    }

    It 'converts values back to registry data' {
        ConvertTo-WinLeanRegistryData -ValueType DWord -Value ([uint32]4294967295) | Should -Be -1
        ConvertTo-WinLeanRegistryData -ValueType QWord -Value '18446744073709551615' | Should -Be ([long]-1)
        $bytes = ConvertTo-WinLeanRegistryData -ValueType Binary -Value '0aff'
        , $bytes | Should -BeOfType [byte[]]
        $bytes | Should -Be @(10, 255)
        $multi = ConvertTo-WinLeanRegistryData -ValueType MultiString -Value @('one')
        , $multi | Should -BeOfType [string[]]
    }

    It 'refuses to restore string data that a JSON parser turned into a date' {
        { ConvertTo-WinLeanRegistryData -ValueType String -Value ([datetime]'2026-01-01') } | Should -Throw -ExpectedMessage '*cannot be restored losslessly*'
    }
}

Describe 'State comparison' {
    It 'compares type, existence and data strictly' {
        $dword0 = [pscustomobject]@{ valueExists = $true; valueType = 'DWord'; value = 0 }
        $string0 = [pscustomobject]@{ valueExists = $true; valueType = 'String'; value = '0' }
        $absent = [pscustomobject]@{ valueExists = $false; valueType = $null; value = $null }
        Test-WinLeanRegistryStateEqual -Expected $dword0 -Actual $dword0 | Should -BeTrue
        Test-WinLeanRegistryStateEqual -Expected $dword0 -Actual $string0 | Should -BeFalse
        Test-WinLeanRegistryStateEqual -Expected $dword0 -Actual $absent | Should -BeFalse
        Test-WinLeanRegistryStateEqual -Expected $absent -Actual ([pscustomobject]@{ keyExists = $false; valueExists = $false }) | Should -BeTrue
    }

    It 'compares strings case-sensitively, hex case-insensitively and multi-strings in order' {
        $a = [pscustomobject]@{ valueExists = $true; valueType = 'String'; value = 'On' }
        $b = [pscustomobject]@{ valueExists = $true; valueType = 'String'; value = 'on' }
        Test-WinLeanRegistryStateEqual -Expected $a -Actual $b | Should -BeFalse
        $hexA = [pscustomobject]@{ valueExists = $true; valueType = 'Binary'; value = '0A' }
        $hexB = [pscustomobject]@{ valueExists = $true; valueType = 'Binary'; value = '0a' }
        Test-WinLeanRegistryStateEqual -Expected $hexA -Actual $hexB | Should -BeTrue
        $multiA = [pscustomobject]@{ valueExists = $true; valueType = 'MultiString'; value = @('a', 'b') }
        $multiB = [pscustomobject]@{ valueExists = $true; valueType = 'MultiString'; value = @('b', 'a') }
        Test-WinLeanRegistryStateEqual -Expected $multiA -Actual $multiB | Should -BeFalse
    }

    It 'treats DWord numbers from JSON (Int64) and registry (UInt32) as equal' {
        $fromJson = '{ "valueExists": true, "valueType": "DWord", "value": 4294967295 }' | ConvertFrom-Json
        $fromRegistry = ConvertTo-WinLeanRegistryState -Raw ([pscustomobject]@{ keyExists = $true; valueExists = $true; kind = 'DWord'; data = [int]-1 })
        Test-WinLeanRegistryStateEqual -Expected $fromJson -Actual $fromRegistry | Should -BeTrue
    }
}

Describe 'Resource information' {
    It 'derives identity, scope and mechanism' {
        $resource = ConvertTo-WinLeanRegistryResource -Definition (ConvertTo-JsonShape -InputObject @{ type = 'RegistryValue'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\X'; name = 'Val'; valueType = 'DWord'; value = 1 })
        $info = Get-WinLeanRegistryResourceInfo -Resource $resource
        $info.identity | Should -BeExactly 'REGISTRYVALUE:HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\X\VAL'
        $info.scope | Should -Be 'Machine'
        $info.mechanism | Should -Be 'Policy'
        $info.description | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\X\Val = 1 (DWord)'
    }
}
