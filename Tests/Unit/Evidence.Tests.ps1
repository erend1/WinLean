BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Provider.Registry', 'WinLean.Common'
    Import-Module -Name (Join-Path $script:RepoRoot 'Tools\WinLean.Evidence.psm1') -DisableNameChecking

    function New-Entry {
        param([string] $Key, [string] $Name, [string] $Kind, $Data)
        $state = ConvertTo-WinLeanRegistryState -Raw ([pscustomobject]@{ keyExists = $true; valueExists = $true; kind = $Kind; data = $Data })
        return [pscustomobject]@{ key = $Key; name = $Name; state = $state }
    }

    function New-Snapshot {
        param([string[]] $Keys, [object[]] $Values)
        return [pscustomobject]@{ takenAt = 'now'; paths = @('HKCU:\Software\T'); depth = 1; keys = $Keys; values = $Values; inaccessible = @() }
    }
}

Describe 'Compare-WinLeanRegistrySnapshot' {
    It 'reports added, removed and changed values and keys, and ignores unchanged ones' {
        $before = New-Snapshot -Keys @('HKCU:\Software\T', 'HKCU:\Software\T\Old') -Values @(
            (New-Entry -Key 'HKCU:\Software\T' -Name 'Same' -Kind 'DWord' -Data 1)
            (New-Entry -Key 'HKCU:\Software\T' -Name 'Flip' -Kind 'DWord' -Data 1)
            (New-Entry -Key 'HKCU:\Software\T' -Name 'Gone' -Kind 'String' -Data 'x')
        )
        $after = New-Snapshot -Keys @('HKCU:\Software\T', 'HKCU:\Software\T\New') -Values @(
            (New-Entry -Key 'HKCU:\Software\T' -Name 'Same' -Kind 'DWord' -Data 1)
            (New-Entry -Key 'HKCU:\Software\T' -Name 'Flip' -Kind 'DWord' -Data 0)
            (New-Entry -Key 'HKCU:\Software\T\New' -Name 'Fresh' -Kind 'DWord' -Data 5)
        )
        $changes = @(Compare-WinLeanRegistrySnapshot -Before $before -After $after)
        $changes.Count | Should -Be 5
        ($changes | Where-Object { $_.name -eq 'Flip' }).change | Should -Be 'Changed'
        ($changes | Where-Object { $_.name -eq 'Flip' }).before | Should -Be '1 (DWord)'
        ($changes | Where-Object { $_.name -eq 'Flip' }).after | Should -Be '0 (DWord)'
        ($changes | Where-Object { $_.name -eq 'Gone' }).change | Should -Be 'Removed'
        ($changes | Where-Object { $_.name -eq 'Fresh' }).change | Should -Be 'Added'
        ($changes | Where-Object { $_.change -eq 'KeyAdded' }).key | Should -Be 'HKCU:\Software\T\New'
        ($changes | Where-Object { $_.change -eq 'KeyRemoved' }).key | Should -Be 'HKCU:\Software\T\Old'
        $changes.name | Should -Not -Contain 'Same'
    }

    It 'treats a change of value type as a change' {
        $before = New-Snapshot -Keys @('HKCU:\Software\T') -Values @(New-Entry -Key 'HKCU:\Software\T' -Name 'V' -Kind 'DWord' -Data 0)
        $after = New-Snapshot -Keys @('HKCU:\Software\T') -Values @(New-Entry -Key 'HKCU:\Software\T' -Name 'V' -Kind 'String' -Data '0')
        (@(Compare-WinLeanRegistrySnapshot -Before $before -After $after)).change | Should -Be @('Changed')
    }

    It 'returns nothing for identical snapshots' {
        $snapshot = New-Snapshot -Keys @('HKCU:\Software\T') -Values @(New-Entry -Key 'HKCU:\Software\T' -Name 'V' -Kind 'DWord' -Data 0)
        @(Compare-WinLeanRegistrySnapshot -Before $snapshot -After $snapshot).Count | Should -Be 0
        (Format-WinLeanRegistryChange -Changes @()) | Should -BeLike '*no registry changes*'
    }
}

Describe 'ConvertTo-WinLeanEvidenceMarkdown' {
    It 'records the setting, the environment and both phases' {
        $platform = [pscustomobject]@{ productName = 'Microsoft Windows 11 Pro'; displayVersion = '25H2'; build = 26200; ubr = 1; architecture = 'X64' }
        $off = @([pscustomobject]@{ change = 'Changed'; key = 'HKCU:\Software\T'; name = 'V'; before = '1 (DWord)'; after = '0 (DWord)' })
        $markdown = ConvertTo-WinLeanEvidenceMarkdown -RuleId 'privacy.test.disable' -Setting 'Settings > Test | Toggle' -Platform $platform -Paths @('HKCU:\Software\T') `
            -FirstAction 'Turned the toggle off' -FirstChanges $off -SecondAction 'Turned it back on' -SecondChanges @()
        $markdown | Should -BeLike '# Evidence: privacy.test.disable*'
        $markdown.Contains('| Setting | Settings > Test \| Toggle |') | Should -BeTrue
        $markdown.Contains('build 26200.1') | Should -BeTrue
        $markdown.Contains('| Changed | `HKCU:\Software\T\V` | 1 (DWord) | 0 (DWord) |') | Should -BeTrue
        $markdown.Contains('## Turned it back on') | Should -BeTrue
        $markdown.Contains('No registry changes in the watched keys.') | Should -BeTrue
    }
}
