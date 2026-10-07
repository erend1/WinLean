<#
    The registry access report against the real access control API - READ-ONLY. The tests
    compare security descriptors before and after to prove that nothing is modified; the
    only key they create is inside Pester's TestRegistry.

    Get-Acl is called with -Path: -LiteralPath fails for registry keys on Windows
    PowerShell 5.1.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Common'
    Import-Module -Name (Join-Path $script:RepoRoot 'Tools\WinLean.RegistryAccess.psm1') -DisableNameChecking

    $root = (Get-PSDrive -Name TestRegistry).Root
    $script:Key = 'HKCU:\' + $root.Substring('HKEY_CURRENT_USER\'.Length) + '\Access'
    New-Item -Path $script:Key -Force | Out-Null
    $script:HostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:Tool = Join-Path $script:RepoRoot 'Tools\Get-WinLeanRegistryAccessReport.ps1'

    function Invoke-Tool {
        param([string[]] $Arguments)
        $quoted = foreach ($argument in $Arguments) { if ($argument.StartsWith('-')) { $argument } else { "'" + $argument.Replace("'", "''") + "'" } }
        # Errors are reported on stdout: Windows PowerShell 5.1 turns stderr of a child
        # process into terminating errors when it is redirected.
        $command = "try {{ & '{0}' {1} }} catch {{ [Console]::Out.WriteLine('ERROR: ' + `$_.Exception.Message); exit 1 }}" -f $script:Tool.Replace("'", "''"), ($quoted -join ' ')
        $output = & $script:HostPath -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
    }
}

Describe 'Registry access report on this system (read-only)' {
    It 'describes a key without changing its security descriptor' {
        $before = (Get-Acl -Path $script:Key).Sddl
        $key = Get-WinLeanRegistryKeyAccess -Path $script:Key -CurrentUserSid ([string](Get-WinLeanIdentity).sid)
        $key.exists | Should -BeTrue
        $key.readable | Should -BeTrue
        @($key.entries).Count | Should -BeGreaterThan 0
        @($key.entries | Where-Object { $_.isInherited }).Count | Should -BeGreaterThan 0 -Because 'a new key below HKCU\Software inherits its entries'
        $key.currentProcessCanWrite | Should -BeTrue
        @($key.entries | Where-Object { $_.writeCapable }).Count | Should -BeGreaterThan 0
        (Get-Acl -Path $script:Key).Sddl | Should -BeExactly $before
    }

    It 'reports a missing key as missing and creates nothing' {
        $missing = "$script:Key\DoesNotExist"
        $key = Get-WinLeanRegistryKeyAccess -Path $missing
        $key.exists | Should -BeFalse
        @(Get-WinLeanRegistryAccessObservations -Key $key) | Should -Be @('The key does not exist.')
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'reports the default policy keys without modifying them' {
        $policies = 'HKCU:\Software\Policies'
        $before = if (Test-Path -LiteralPath $policies) { (Get-Acl -Path $policies).Sddl } else { $null }
        $report = Get-WinLeanRegistryAccessReport
        @($report.keys).Count | Should -Be @(Get-WinLeanRegistryAccessDefaultPaths).Count
        $report.system.build | Should -BeGreaterThan 0
        @(Format-WinLeanRegistryAccessReport -Report $report).Count | Should -BeGreaterThan 5
        $after = if (Test-Path -LiteralPath $policies) { (Get-Acl -Path $policies).Sddl } else { $null }
        $after | Should -BeExactly $before
    }

    It 'saves a report without account identifiers and compares it with itself as identical' {
        $saved = Join-Path $TestDrive 'access.json'
        $first = Invoke-Tool -Arguments @('-Path', $script:Key, '-OutputPath', $saved)
        $first.exitCode | Should -Be 0 -Because $first.output
        $first.output | Should -BeLike '*WINLEAN REGISTRY ACCESS REPORT (read-only)*'
        $json = Get-Content -Raw -LiteralPath $saved
        $json | Should -Not -Match 'S-1-5-21-\d+-\d+-\d+-\d+' -Because 'machine-specific SIDs are reduced to their relative id'
        ($json | ConvertFrom-Json).keys[0].path | Should -Be $script:Key

        $second = Invoke-Tool -Arguments @('-Path', $script:Key, '-CompareWith', $saved)
        $second.exitCode | Should -Be 0 -Because $second.output
        $second.output | Should -BeLike '*COMPARISON WITH THE REFERENCE REPORT*identical*'
        $second.output | Should -BeLike '*Both reports come from the same Windows build and edition*'
    }

    It 'rejects a file that is not an access report' {
        $other = Join-Path $TestDrive 'other.json'
        Set-Content -LiteralPath $other -Value '{ "schemaVersion": 1, "requirements": {} }' -Encoding utf8
        (Invoke-Tool -Arguments @('-Path', $script:Key, '-CompareWith', $other)).output | Should -BeLike '*is not a WinLean registry access report*'
    }
}
