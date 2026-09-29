<#
    Registry snapshots against the real registry, confined to Pester's TestRegistry.
    The snapshot functions only read; the test itself creates the changes to observe.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Provider.Registry', 'WinLean.Common'
    Import-Module -Name (Join-Path $script:RepoRoot 'Tools\WinLean.Evidence.psm1') -DisableNameChecking

    $root = (Get-PSDrive -Name TestRegistry).Root
    $script:Base = if ($root.StartsWith('HKEY_CURRENT_USER\', [System.StringComparison]::OrdinalIgnoreCase)) { 'HKCU:\' + $root.Substring('HKEY_CURRENT_USER\'.Length) } else { $root.TrimEnd('\') }
}

Describe 'Get-WinLeanRegistrySnapshot' {
    It 'observes exactly the changes made between two snapshots' {
        $key = "$script:Base\Observed"
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -LiteralPath $key -Name 'Toggle' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $key -Name 'Untouched' -Value 'same' -Type String

        $before = Get-WinLeanRegistrySnapshot -Path @($key) -Depth 1
        Set-ItemProperty -LiteralPath $key -Name 'Toggle' -Value 0 -Type DWord
        New-Item -Path "$key\Child" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$key\Child" -Name 'New' -Value '%TEMP%' -Type ExpandString
        $after = Get-WinLeanRegistrySnapshot -Path @($key) -Depth 1

        $changes = @(Compare-WinLeanRegistrySnapshot -Before $before -After $after)
        ($changes | Where-Object { $_.name -eq 'Toggle' }).after | Should -Be '0 (DWord)'
        ($changes | Where-Object { $_.name -eq 'New' }).after | Should -Be "'%TEMP%' (ExpandString)"
        ($changes | Where-Object { $_.change -eq 'KeyAdded' }).key | Should -Be "$key\Child"
        $changes.name | Should -Not -Contain 'Untouched'
    }

    It 'respects the depth limit and skips missing keys' {
        $key = "$script:Base\Deep"
        New-Item -Path "$key\A\B" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$key\A\B" -Name 'Hidden' -Value 1 -Type DWord
        $shallow = Get-WinLeanRegistrySnapshot -Path @($key, "$script:Base\Missing") -Depth 1
        $shallow.keys | Should -Contain "$key\A"
        $shallow.keys | Should -Not -Contain "$key\A\B"
        @($shallow.values).Count | Should -Be 0
    }
}
