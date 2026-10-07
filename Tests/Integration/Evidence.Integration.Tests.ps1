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

    It 'captures a toggle cycle with real snapshots, attributes it and never writes the registry itself' {
        $key = "$script:Base\Capture"
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -LiteralPath $key -Name 'Toggle' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $key -Name 'Steady' -Value 'x' -Type String
        Mock -ModuleName 'WinLean.Provider.Registry' -CommandName Write-WinLeanRegistryValue -MockWith { throw 'The capture must not write.' }
        Mock -ModuleName 'WinLean.Provider.Registry' -CommandName Remove-WinLeanRegistryValue -MockWith { throw 'The capture must not write.' }

        # The prompts stand in for the operator: they switch the "toggle" in the test key.
        $switches = New-Object -TypeName System.Collections.Generic.Queue[int]
        $switches.Enqueue(0)
        $switches.Enqueue(1)
        $vm = [pscustomobject]@{ productName = 'Windows 11 Pro'; editionId = 'Professional'; displayVersion = '25H2'; build = 26200; ubr = 1; architecture = 'X64'; kind = 'VirtualMachine'; detail = 'test'; confirmedBy = 'Detection' }
        $capture = Invoke-WinLeanEvidenceCapture -RuleId 'privacy.test.disable' -Setting 'Test toggle' -TargetState 'Off' -OriginalState 'On' -Path @($key) -Depth 1 `
            -BaselineSeconds 0 -Environment $vm -WriteLine { } `
            -Prompt { Set-ItemProperty -LiteralPath $key -Name 'Toggle' -Value $switches.Dequeue() -Type DWord }.GetNewClosure()

        $attributable = @($capture.findings | Where-Object { $_.classification -eq 'Attributable' })
        $attributable.Count | Should -Be 1
        $attributable[0].name | Should -Be 'Toggle'
        $attributable[0].applied | Should -Be '0 (DWord)'
        $capture.markdown | Should -BeLike '*Status: **Candidate*'
        (Get-ItemProperty -LiteralPath $key).Toggle | Should -Be 1
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Write-WinLeanRegistryValue -Times 0 -Exactly
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
