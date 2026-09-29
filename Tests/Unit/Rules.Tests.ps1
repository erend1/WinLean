BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Rules', 'WinLean.Common'

    function Write-RuleFile {
        param([string] $Root, $Definition, [string] $FileName)
        $folder = Join-Path $Root $Definition.category
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        if (-not $FileName) { $FileName = "$($Definition.id).json" }
        Set-Content -LiteralPath (Join-Path $folder $FileName) -Value ($Definition | ConvertTo-Json -Depth 20) -Encoding utf8
    }
}

Describe 'Import-WinLeanRuleCatalog' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $root | Out-Null
    }

    It 'loads valid rules and normalizes them' {
        Write-RuleFile -Root $root -Definition (New-TestRuleDefinition -Id 'privacy.first.disable')
        Write-RuleFile -Root $root -Definition (New-TestRuleDefinition -Id 'explorer.second.show' -Category 'Explorer')
        $catalog = Import-WinLeanRuleCatalog -Path $root
        $catalog.errorCount | Should -Be 0
        $catalog.ruleIds | Should -Be @('explorer.second.show', 'privacy.first.disable')
        $rule = $catalog.rules['privacy.first.disable']
        $rule.PSObject.TypeNames | Should -Contain 'WinLean.Rule'
        $rule.scope | Should -Be 'CurrentUser'
        $rule.mechanism | Should -Be 'Preference'
        $rule.resources[0].value | Should -BeOfType [uint32]
        $rule.sourcePath | Should -Be 'Privacy\privacy.first.disable.json'
    }

    It 'excludes invalid rules and reports why' {
        Write-RuleFile -Root $root -Definition (New-TestRuleDefinition -Id 'privacy.valid.disable')
        Write-RuleFile -Root $root -Definition (New-TestRuleDefinition -Id 'privacy.bad.disable' -Risk 'Extreme')
        Set-Content -LiteralPath (Join-Path $root 'Privacy\privacy.broken.disable.json') -Value '{ broken'
        $catalog = Import-WinLeanRuleCatalog -Path $root
        $catalog.ruleIds | Should -Be @('privacy.valid.disable')
        $catalog.errorCount | Should -Be 2
        @($catalog.issues | Where-Object { $_.code -eq 'Risk' }).Count | Should -Be 1
        @($catalog.issues | Where-Object { $_.code -eq 'RuleParse' }).Count | Should -Be 1
    }

    It 'rejects conditions on unknown requirement keys when keys are known' {
        $conditions = @(@{ fact = 'requirement.printers'; operator = 'Equals'; value = $false })
        Write-RuleFile -Root $root -Definition (New-TestRuleDefinition -Id 'privacy.typo.disable' -Conditions $conditions)
        $catalog = Import-WinLeanRuleCatalog -Path $root -KnownRequirementKeys @('printer')
        $catalog.errorCount | Should -Be 1
        $catalog.issues[0].message | Should -BeLike '*unknown compatibility requirement*printers*'
    }

    It 'fails for a missing directory' {
        { Import-WinLeanRuleCatalog -Path (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}

Describe 'Test-WinLeanCondition' {
    BeforeAll {
        $facts = New-TestFacts -Requirements @{ printer = $true; onedrive = $false } -EditionId 'Enterprise'
    }

    It '<Case>' -ForEach @(
        @{ Case = 'Equals is true when the requirement matches'; Condition = @{ fact = 'requirement.onedrive'; operator = 'Equals'; value = $false }; Expected = 'True' }
        @{ Case = 'Equals is false when the requirement differs'; Condition = @{ fact = 'requirement.printer'; operator = 'Equals'; value = $false }; Expected = 'False' }
        @{ Case = 'an undeclared requirement is Unknown'; Condition = @{ fact = 'requirement.bluetooth'; operator = 'Equals'; value = $false }; Expected = 'Unknown' }
        @{ Case = 'NotEquals compares like Equals'; Condition = @{ fact = 'requirement.printer'; operator = 'NotEquals'; value = $false }; Expected = 'True' }
        @{ Case = 'In matches strings case-insensitively'; Condition = @{ fact = 'system.editionId'; operator = 'In'; value = @('ENTERPRISE', 'Education') }; Expected = 'True' }
        @{ Case = 'NotIn excludes listed values'; Condition = @{ fact = 'system.editionId'; operator = 'NotIn'; value = @('Enterprise') }; Expected = 'False' }
        @{ Case = 'GreaterOrEqual compares numbers'; Condition = @{ fact = 'system.build'; operator = 'GreaterOrEqual'; value = 26100 }; Expected = 'True' }
        @{ Case = 'LessOrEqual compares numbers'; Condition = @{ fact = 'system.build'; operator = 'LessOrEqual'; value = 22631 }; Expected = 'False' }
        @{ Case = 'a type mismatch never matches'; Condition = @{ fact = 'requirement.printer'; operator = 'Equals'; value = 'true' }; Expected = 'False' }
    ) {
        $result = Test-WinLeanCondition -Condition ([pscustomobject]$Condition) -Facts $facts
        $result.result | Should -Be $Expected
    }

    It 'explains unknown requirements and uses the rule reason for failures' {
        $unknown = Test-WinLeanCondition -Condition ([pscustomobject]@{ fact = 'requirement.bluetooth'; operator = 'Equals'; value = $false; reason = '' }) -Facts $facts
        $unknown.message | Should -BeLike "*'bluetooth' is not declared*treats undeclared requirements as required*"
        $failed = Test-WinLeanCondition -Condition ([pscustomobject]@{ fact = 'requirement.printer'; operator = 'Equals'; value = $false; reason = 'Printing must remain available.' }) -Facts $facts
        $failed.message | Should -BeLike 'Printing must remain available.*'
    }
}

Describe 'Test-WinLeanRuleApplicable' {
    It 'marks non-client installations Unsupported' {
        $rule = New-TestRule
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -InstallationType 'Server')).status | Should -Be 'Unsupported'
    }

    It 'marks builds below Windows 11 or the rule minimum Unsupported' {
        $rule = New-TestRule -Windows @{ minBuild = 22621; maxValidatedBuild = 26200 }
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 19045)).status | Should -Be 'Unsupported'
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 22000)).status | Should -Be 'Unsupported'
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 22621)).status | Should -Be 'Applicable'
    }

    It 'honours maxBuild and editions' {
        $rule = New-TestRule -Windows @{ minBuild = 22000; maxBuild = 26100; maxValidatedBuild = 26100; editions = @('Enterprise') }
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 26200 -EditionId 'Enterprise')).status | Should -Be 'Unsupported'
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 26100 -EditionId 'Professional')).status | Should -Be 'Unsupported'
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 26100 -EditionId 'enterprise')).status | Should -Be 'Applicable'
    }

    It 'flags builds newer than the validated build' {
        $rule = New-TestRule -Windows @{ minBuild = 22000; maxValidatedBuild = 26100 }
        $result = Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Build 26200)
        $result.status | Should -Be 'Applicable'
        $result.untestedBuild | Should -BeTrue
    }

    It 'skips rules whose conditions are not met or unknown' {
        $rule = New-TestRule -Conditions @(@{ fact = 'requirement.printer'; operator = 'Equals'; value = $false })
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts)).status | Should -Be 'Skipped'
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Requirements @{ printer = $true })).status | Should -Be 'Skipped'
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -Requirements @{ printer = $false })).status | Should -Be 'Applicable'
    }
}

Describe 'Rule interface with the fake registry' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
        $key = 'HKCU:\Software\WinLeanTest\Rule'
        $rule = New-TestRule -Resources @(
            @{ type = 'RegistryValue'; path = $key; name = 'A'; valueType = 'DWord'; value = 1 }
            @{ type = 'RegistryValue'; path = $key; name = 'B'; valueType = 'String'; value = 'on' }
        )
    }

    It 'reports the current and desired state of every resource' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $key -Name 'A' -Kind 'DWord' -Data 1
        $state = Get-WinLeanRuleState -Rule $rule -IncludeAccess
        $state.inDesiredState | Should -BeFalse
        $state.resources[0].inDesiredState | Should -BeTrue
        $state.resources[1].inDesiredState | Should -BeFalse
        $state.resources[1].currentText | Should -Be 'not set'
        $state.writable | Should -BeTrue
    }

    It 'applies only what is not in the desired state (idempotent)' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $key -Name 'A' -Kind 'DWord' -Data 1
        $state = Get-WinLeanRuleState -Rule $rule
        $applied = Set-WinLeanRuleState -Rule $rule -State $state
        $applied.changedResources | Should -Be @(1)
        $script:FakeRegistry.Writes | Should -Be @('HKCU:\Software\WinLeanTest\Rule\B')

        $second = Set-WinLeanRuleState -Rule $rule -State (Get-WinLeanRuleState -Rule $rule)
        @($second.changedResources).Count | Should -Be 0
        $script:FakeRegistry.Writes.Count | Should -Be 1
    }

    It 'verifies by reading again and reports mismatches' {
        $script:FakeRegistry.StickyValues.Add('HKCU:\Software\WinLeanTest\Rule\B')
        [void](Set-WinLeanRuleState -Rule $rule -State (Get-WinLeanRuleState -Rule $rule))
        $verification = Confirm-WinLeanRuleState -Rule $rule
        $verification.verified | Should -BeFalse
        $verification.mismatches[0] | Should -BeLike '*\B: expected*'
    }

    It 'undoes to the captured state, including keys WinLean created' {
        $before = Get-WinLeanRuleState -Rule $rule
        $snapshot = Get-FakeRegistrySnapshot -Registry $script:FakeRegistry
        [void](Set-WinLeanRuleState -Rule $rule -State $before)
        $script:FakeRegistry.Keys.ContainsKey('HKCU:\Software\WinLeanTest\Rule') | Should -BeTrue
        $undo = Undo-WinLeanRuleState -Rule $rule -BeforeState $before
        $undo.restored | Should -BeTrue
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -BeExactly $snapshot
    }
}
