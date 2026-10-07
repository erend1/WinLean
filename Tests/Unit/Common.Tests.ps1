BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Common'
}

Describe 'Property helpers' {
    It 'returns the default for missing properties and null objects' {
        $object = [pscustomobject]@{ present = 1 }
        Get-WinLeanProperty -InputObject $object -Name 'missing' -Default 'fallback' | Should -Be 'fallback'
        Get-WinLeanProperty -InputObject $null -Name 'x' -Default 7 | Should -Be 7
        Get-WinLeanProperty -InputObject $object -Name 'present' | Should -Be 1
    }

    It 'keeps single-element arrays intact with -NoEnumerate' {
        $object = '{ "list": ["only"] }' | ConvertFrom-Json
        $value = Get-WinLeanProperty -InputObject $object -Name 'list' -NoEnumerate
        , $value | Should -BeOfType [object[]]
        $value.Count | Should -Be 1
    }

    It 'emits array items and nothing for missing or null arrays' {
        $object = '{ "empty": [], "none": null, "two": ["a", "b"], "scalar": "s" }' | ConvertFrom-Json
        @(Get-WinLeanArrayProperty -InputObject $object -Name 'empty').Count | Should -Be 0
        @(Get-WinLeanArrayProperty -InputObject $object -Name 'none').Count | Should -Be 0
        @(Get-WinLeanArrayProperty -InputObject $object -Name 'missing').Count | Should -Be 0
        @(Get-WinLeanArrayProperty -InputObject $object -Name 'two').Count | Should -Be 2
        @(Get-WinLeanArrayProperty -InputObject $object -Name 'scalar') | Should -Be @('s')
    }

    It 'finds keys in Hashtable, OrderedDictionary and generic Dictionary' {
        $generic = New-WinLeanDictionary
        $generic['Key'] = 1
        Test-WinLeanDictionaryKey -Dictionary @{ Key = 1 } -Key 'key' | Should -BeTrue
        Test-WinLeanDictionaryKey -Dictionary ([ordered]@{ Key = 1 }) -Key 'Key' | Should -BeTrue
        Test-WinLeanDictionaryKey -Dictionary $generic -Key 'KEY' | Should -BeTrue
        Test-WinLeanDictionaryKey -Dictionary $generic -Key 'other' | Should -BeFalse
    }
}

Describe 'JSON files' {
    It 'round-trips values and replaces existing files atomically' {
        $path = Join-Path $TestDrive 'data.json'
        Write-WinLeanJsonFile -Path $path -InputObject ([pscustomobject]@{ version = 1; items = @('a') })
        # A second write replaces the existing file (regression: File.Replace with a null backup path).
        Write-WinLeanJsonFile -Path $path -InputObject ([pscustomobject]@{ version = 2; items = @('b'); big = [uint32]::MaxValue })
        $read = Read-WinLeanJsonFile -Path $path
        $read.version | Should -Be 2
        @($read.items) | Should -Be @('b')
        [uint32]$read.big | Should -Be ([uint32]::MaxValue)
        Test-Path -LiteralPath ($path + '.tmp') | Should -BeFalse
    }

    It 'writes UTF-8 without a byte order mark' {
        $path = Join-Path $TestDrive 'utf8.json'
        $text = 'H' + [char]0x00FC + 'seyin ' + [char]0x015F
        Write-WinLeanJsonFile -Path $path -InputObject ([pscustomobject]@{ text = $text })
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Not -Be 0xEF
        (Read-WinLeanJsonFile -Path $path).text | Should -BeExactly $text
    }

    It 'keeps ISO 8601 looking strings as strings where PowerShell supports it' -Skip:(-not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $value = ConvertFrom-WinLeanJson -Json '{ "text": "2026-09-27T18:45:12" }'
        $value.text | Should -BeOfType [string]
        $value.text | Should -Be '2026-09-27T18:45:12'
    }

    It 'reports invalid JSON with the file name' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{ not json'
        { Read-WinLeanJsonFile -Path $path } | Should -Throw -ExpectedMessage "*broken.json*"
    }

    It 'appends JSON lines' {
        $path = Join-Path $TestDrive 'log.jsonl'
        Add-WinLeanJsonLine -Path $path -InputObject @{ n = 1 }
        Add-WinLeanJsonLine -Path $path -InputObject @{ n = 2 }
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 2
        ($lines[1] | ConvertFrom-Json).n | Should -Be 2
    }
}

Describe 'Time and formatting' {
    It 'creates sortable run ids' {
        $time = [System.DateTimeOffset]::new(2026, 9, 27, 18, 45, 12, [TimeSpan]::FromHours(3))
        New-WinLeanRunId -Time $time | Should -Be '2026-09-27_18-45-12'
    }

    It 'formats numbers with the invariant culture' {
        Format-WinLeanNumber -Value 12.5 -Decimals 1 | Should -Be '12.5'
        Format-WinLeanNumber -Value 1234 | Should -Be '1234'
    }

    It 'converts timestamps from strings and dates' {
        (ConvertTo-WinLeanDateTimeOffset -Value '2026-09-27T18:45:12.0000000+03:00').Hour | Should -Be 18
        ConvertTo-WinLeanDateTimeOffset -Value 'not a date' | Should -BeNullOrEmpty
        Format-WinLeanTimestamp -Value $null | Should -Be 'unknown'
    }
}

Describe 'Failure classification' {
    It 'classifies <Name>' -ForEach @(
        @{ Name = 'UnauthorizedAccessException'; Exception = [System.UnauthorizedAccessException]::new('denied'); Expected = 'PermissionDenied' }
        @{ Name = 'SecurityException'; Exception = [System.Security.SecurityException]::new('denied'); Expected = 'PermissionDenied' }
        @{ Name = 'ERROR_ELEVATION_REQUIRED'; Exception = [System.Runtime.InteropServices.COMException]::new('localized text', -2147024156); Expected = 'PermissionDenied' }
        @{ Name = 'NotSupportedException'; Exception = [System.NotSupportedException]::new('no'); Expected = 'Unsupported' }
        @{ Name = 'IOException'; Exception = [System.IO.IOException]::new('io'); Expected = 'CommandFailed' }
        @{ Name = 'other exceptions'; Exception = [System.InvalidOperationException]::new('bug'); Expected = 'UnexpectedError' }
    ) {
        Get-WinLeanFailureClass -ErrorObject $Exception | Should -Be $Expected
    }

    It 'uses the class carried by WinLean exceptions, also when wrapped' {
        $inner = New-WinLeanException -Class VerificationFailed -Message 'mismatch'
        $outer = [System.Exception]::new('outer', $inner)
        Get-WinLeanFailureClass -ErrorObject $outer | Should -Be 'VerificationFailed'
    }

    It 'builds structured failures with the innermost message' {
        try { throw (New-WinLeanException -Class CommandFailed -Message 'it failed') }
        catch { $failure = ConvertTo-WinLeanFailure -ErrorObject $_ }
        $failure.class | Should -Be 'CommandFailed'
        $failure.message | Should -Be 'it failed'
    }
}

Describe 'Command line quoting' {
    It 'quotes <Argument>' -ForEach @(
        @{ Argument = 'simple'; Expected = 'simple' }
        @{ Argument = 'with space'; Expected = '"with space"' }
        @{ Argument = ''; Expected = '""' }
        @{ Argument = 'C:\Program Files\x\'; Expected = '"C:\Program Files\x\\"' }
        @{ Argument = 'say "hi"'; Expected = '"say \"hi\""' }
    ) {
        ConvertTo-WinLeanCommandLineArgument -Argument $Argument | Should -BeExactly $Expected
    }
}

Describe 'Platform facts' {
    It 'reports a Windows build and a Windows 11 product name on Windows 11' {
        $platform = Get-WinLeanPlatform
        $platform.build | Should -BeGreaterThan 0
        if ($platform.build -ge 22000 -and $platform.installationType -eq 'Client') {
            $platform.isWindows11 | Should -BeTrue
            $platform.productName | Should -Not -BeLike '*Windows 10*'
        }
    }
}

Describe 'Version' {
    It 'comes from the module manifest, including its prerelease label' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\WinLean.psd1')
        $expected = [string]$manifest.ModuleVersion
        if ($manifest.PrivateData.PSData.ContainsKey('Prerelease') -and $manifest.PrivateData.PSData.Prerelease) {
            $expected = "$expected-$($manifest.PrivateData.PSData.Prerelease)"
        }
        Get-WinLeanVersion | Should -Be $expected
        Get-WinLeanVersion | Should -Match '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
    }
}
