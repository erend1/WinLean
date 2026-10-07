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

Describe 'Get-WinLeanEnvironmentKind' {
    It 'classifies <Case> as <Kind>' -ForEach @(
        @{ Case = 'Hyper-V'; Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine'; UserName = 'tester'; Kind = 'VirtualMachine' }
        @{ Case = 'VMware'; Manufacturer = 'VMware, Inc.'; Model = 'VMware20,1'; UserName = 'tester'; Kind = 'VirtualMachine' }
        @{ Case = 'VirtualBox'; Manufacturer = 'innotek GmbH'; Model = 'VirtualBox'; UserName = 'tester'; Kind = 'VirtualMachine' }
        @{ Case = 'QEMU'; Manufacturer = 'QEMU'; Model = 'Standard PC (Q35 + ICH9, 2009)'; UserName = 'tester'; Kind = 'VirtualMachine' }
        @{ Case = 'Windows Sandbox'; Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine'; UserName = 'WDAGUtilityAccount'; Kind = 'WindowsSandbox' }
        @{ Case = 'a desktop PC'; Manufacturer = 'Micro-Star International Co., Ltd.'; Model = 'MS-7D75'; UserName = 'tester'; Kind = 'Physical' }
        @{ Case = 'a Surface device'; Manufacturer = 'Microsoft Corporation'; Model = 'Surface Laptop 5'; UserName = 'tester'; Kind = 'Physical' }
        @{ Case = 'missing data'; Manufacturer = ''; Model = ''; UserName = 'tester'; Kind = 'Unknown' }
    ) {
        (Get-WinLeanEnvironmentKind -Manufacturer $Manufacturer -Model $Model -UserName $UserName).kind | Should -Be $Kind
    }
}

Describe 'Get-WinLeanEvidenceAttribution' {
    BeforeAll {
        $script:Key = 'HKCU:\Software\T'
        function New-StateSnapshot {
            <# Values as name -> DWord (or $null to omit); keys default to the watched key. #>
            param([hashtable] $Values, [string[]] $ExtraKeys = @(), [hashtable] $ExtraValues = @{})
            $entries = @(foreach ($name in $Values.Keys) {
                    if ($null -ne $Values[$name]) { New-Entry -Key $script:Key -Name $name -Kind 'DWord' -Data $Values[$name] }
                })
            $entries += @(foreach ($name in $ExtraValues.Keys) { New-Entry -Key "$script:Key\Sub" -Name $name -Kind 'DWord' -Data $ExtraValues[$name] })
            return New-Snapshot -Keys (@($script:Key) + $ExtraKeys) -Values $entries
        }
        function Get-Classification {
            param($Findings, [string] $Name, [string] $Kind = 'Value')
            return ($Findings | Where-Object { $_.kind -eq $Kind -and (($Kind -eq 'Key' -and $_.key -eq $Name) -or $_.name -eq $Name) }).classification
        }
    }

    It 'attributes only changes that follow the toggle and come back exactly' {
        $start = New-StateSnapshot -Values @{ Toggle = 1; Clock = 100; Counter = 1; Sticky = 1; Quiet = 7 }
        $before = New-StateSnapshot -Values @{ Toggle = 1; Clock = 101; Counter = 1; Sticky = 1; Quiet = 7 }
        $applied = New-StateSnapshot -Values @{ Toggle = 0; Clock = 102; Counter = 2; Sticky = 0; Quiet = 7 } -ExtraKeys @("$script:Key\Sub") -ExtraValues @{ Flag = 1 }
        $reversed = New-StateSnapshot -Values @{ Toggle = 1; Clock = 103; Counter = 3; Sticky = 0; Quiet = 7 }
        $findings = @(Get-WinLeanEvidenceAttribution -BaselineStart $start -Before $before -Cycles @([pscustomobject]@{ applied = $applied; reversed = $reversed }))

        Get-Classification $findings 'Toggle' | Should -Be 'Attributable'
        Get-Classification $findings 'Clock' | Should -Be 'Churn'
        Get-Classification $findings 'Counter' | Should -Be 'NotReversed'
        Get-Classification $findings 'Sticky' | Should -Be 'NotReversed'
        Get-Classification $findings 'Flag' | Should -Be 'Attributable'
        Get-Classification $findings "$script:Key\Sub" -Kind 'Key' | Should -Be 'Attributable'
        @($findings | Where-Object { $_.name -eq 'Quiet' }).Count | Should -Be 0 -Because 'unchanged values are not reported'
        $toggle = $findings | Where-Object { $_.name -eq 'Toggle' }
        $toggle.before | Should -Be '1 (DWord)'
        $toggle.applied | Should -Be '0 (DWord)'
        $toggle.final | Should -Be '1 (DWord)'
    }

    It 'requires the same change in every cycle' {
        $start = New-StateSnapshot -Values @{ Toggle = 1; Stamp = 1 }
        $before = New-StateSnapshot -Values @{ Toggle = 1; Stamp = 1 }
        $cycles = @(
            [pscustomobject]@{ applied = (New-StateSnapshot -Values @{ Toggle = 0; Stamp = 2 }); reversed = (New-StateSnapshot -Values @{ Toggle = 1; Stamp = 1 }) }
            [pscustomobject]@{ applied = (New-StateSnapshot -Values @{ Toggle = 0; Stamp = 3 }); reversed = (New-StateSnapshot -Values @{ Toggle = 1; Stamp = 1 }) }
        )
        $findings = @(Get-WinLeanEvidenceAttribution -BaselineStart $start -Before $before -Cycles $cycles)
        Get-Classification $findings 'Toggle' | Should -Be 'Attributable'
        Get-Classification $findings 'Stamp' | Should -Be 'Inconsistent'
    }

    It 'does not attribute a value that changed in only one of several cycles' {
        $base = New-StateSnapshot -Values @{ Toggle = 1; Once = 1 }
        $cycles = @(
            [pscustomobject]@{ applied = (New-StateSnapshot -Values @{ Toggle = 0; Once = 0 }); reversed = (New-StateSnapshot -Values @{ Toggle = 1; Once = 1 }) }
            [pscustomobject]@{ applied = (New-StateSnapshot -Values @{ Toggle = 0; Once = 1 }); reversed = (New-StateSnapshot -Values @{ Toggle = 1; Once = 1 }) }
        )
        $findings = @(Get-WinLeanEvidenceAttribution -BaselineStart $base -Before $base -Cycles $cycles)
        Get-Classification $findings 'Once' | Should -Be 'Other'
    }

    It 'suggests resources only for attributable per-user values outside \Policies\' {
        $findings = @(
            [pscustomobject]@{ kind = 'Value'; key = 'HKCU:\Software\T'; name = 'Toggle'; classification = 'Attributable'; appliedState = (New-Entry -Key 'x' -Name 'y' -Kind 'DWord' -Data 0).state }
            [pscustomobject]@{ kind = 'Value'; key = 'HKCU:\Software\T'; name = 'Removed'; classification = 'Attributable'; appliedState = [pscustomobject]@{ valueExists = $false } }
            [pscustomobject]@{ kind = 'Value'; key = 'HKCU:\Software\Policies\T'; name = 'Policy'; classification = 'Attributable'; appliedState = (New-Entry -Key 'x' -Name 'y' -Kind 'DWord' -Data 1).state }
            [pscustomobject]@{ kind = 'Value'; key = 'HKLM:\SOFTWARE\T'; name = 'Machine'; classification = 'Attributable'; appliedState = (New-Entry -Key 'x' -Name 'y' -Kind 'DWord' -Data 1).state }
            [pscustomobject]@{ kind = 'Value'; key = 'HKCU:\Software\T'; name = 'Clock'; classification = 'Churn'; appliedState = (New-Entry -Key 'x' -Name 'y' -Kind 'DWord' -Data 5).state }
        )
        $suggestions = @(ConvertTo-WinLeanEvidenceResourceSuggestion -Findings $findings | ForEach-Object { $_ | ConvertFrom-Json })
        $suggestions.Count | Should -Be 2
        $suggestions[0].name | Should -Be 'Toggle'
        $suggestions[0].valueType | Should -Be 'DWord'
        $suggestions[0].value | Should -Be 0
        $suggestions[1].ensure | Should -Be 'Absent'
    }
}

Describe 'Invoke-WinLeanEvidenceCapture' {
    BeforeAll {
        $script:Vm = [pscustomobject]@{ productName = 'Windows 11 Pro'; editionId = 'Professional'; displayVersion = '25H2'; build = 26200; ubr = 8246; architecture = 'X64'; kind = 'VirtualMachine'; detail = 'Hyper-V virtual machine'; confirmedBy = 'Detection' }
        $script:Physical = [pscustomobject]@{ productName = 'Windows 11 Pro'; editionId = 'Professional'; displayVersion = '25H2'; build = 26200; ubr = 8246; architecture = 'X64'; kind = 'Physical'; detail = 'no virtual machine detected'; confirmedBy = 'Detection' }

        function Invoke-TestCapture {
            param($Environment = $script:Vm, [switch] $ConfirmDisposableEnvironment)
            $key = 'HKCU:\Software\T'
            $sequence = New-Object -TypeName System.Collections.Generic.Queue[object]
            $sequence.Enqueue((New-Snapshot -Keys @($key) -Values @((New-Entry -Key $key -Name 'Toggle' -Kind 'DWord' -Data 1), (New-Entry -Key $key -Name 'Clock' -Kind 'DWord' -Data 1))))
            $sequence.Enqueue((New-Snapshot -Keys @($key) -Values @((New-Entry -Key $key -Name 'Toggle' -Kind 'DWord' -Data 1), (New-Entry -Key $key -Name 'Clock' -Kind 'DWord' -Data 2))))
            $sequence.Enqueue((New-Snapshot -Keys @($key) -Values @((New-Entry -Key $key -Name 'Toggle' -Kind 'DWord' -Data 0), (New-Entry -Key $key -Name 'Clock' -Kind 'DWord' -Data 3))))
            $sequence.Enqueue((New-Snapshot -Keys @($key) -Values @((New-Entry -Key $key -Name 'Toggle' -Kind 'DWord' -Data 1), (New-Entry -Key $key -Name 'Clock' -Kind 'DWord' -Data 4))))
            $prompts = New-Object -TypeName System.Collections.Generic.List[string]
            $script:CapturePrompts = $prompts
            return Invoke-WinLeanEvidenceCapture -RuleId 'privacy.test.disable' -Setting 'Settings > Test | Toggle' -TargetState 'Off' -OriginalState 'On' `
                -Path @($key) -BaselineSeconds 5 -Environment $Environment -ConfirmDisposableEnvironment:$ConfirmDisposableEnvironment `
                -Snapshot { $sequence.Dequeue() }.GetNewClosure() `
                -Wait { } `
                -Prompt { param($Message) $prompts.Add($Message) }.GetNewClosure() `
                -WriteLine { }
        }
    }

    It 'records the environment, every phase, the attribution and a reviewer checklist' {
        $capture = Invoke-TestCapture
        @($capture.findings | Where-Object { $_.classification -eq 'Attributable' }).name | Should -Be @('Toggle')
        ($capture.findings | Where-Object { $_.name -eq 'Clock' }).classification | Should -Be 'Churn'
        $capture.quality | Should -BeLike 'Candidate*'
        $script:CapturePrompts.Count | Should -Be 2
        $script:CapturePrompts[0] | Should -BeLike "*switch 'Settings > Test | Toggle' to 'Off'*"

        $markdown = $capture.markdown
        $markdown | Should -BeLike '# Evidence: privacy.test.disable*'
        $markdown.Contains('| Setting | Settings > Test \| Toggle |') | Should -BeTrue
        $markdown.Contains('| Build | 26200.8246 (X64) |') | Should -BeTrue
        $markdown.Contains('| Environment | VirtualMachine: Hyper-V virtual machine |') | Should -BeTrue
        $markdown.Contains('## Baseline: no action (background churn)') | Should -BeTrue
        $markdown.Contains("## Cycle 1: switched to 'Off'") | Should -BeTrue
        $markdown.Contains("## Cycle 1: switched back to 'On'") | Should -BeTrue
        $markdown.Contains('| `HKCU:\Software\T\Toggle` | 1 (DWord) | 0 (DWord) | 1 (DWord) |') | Should -BeTrue
        $markdown.Contains('changed during the baseline (background churn)') | Should -BeTrue
        $markdown.Contains('{"type":"RegistryValue","path":"HKCU:\\Software\\T","name":"Toggle","valueType":"DWord","value":0}') | Should -BeTrue
        $markdown.Contains('## Conclusion (reviewer)') | Should -BeTrue
    }

    It 'refuses to run outside a detected VM or Windows Sandbox' {
        { Invoke-TestCapture -Environment $script:Physical } | Should -Throw -ExpectedMessage '*never on a primary workstation*'
    }

    It 'records when the operator confirmed an undetected disposable environment' {
        $capture = Invoke-TestCapture -Environment $script:Physical -ConfirmDisposableEnvironment
        $capture.environment.confirmedBy | Should -Be 'Operator'
        $capture.markdown.Contains('confirmed as disposable by the operator') | Should -BeTrue
    }
}
