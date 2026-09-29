BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Validation', 'WinLean.Rules'

    function Get-IssueCodes {
        param($Definition, [string] $SourcePath, [string[]] $KnownRequirementKeys)
        $parameters = @{ Definition = $Definition }
        if ($SourcePath) { $parameters['SourcePath'] = $SourcePath }
        if ($KnownRequirementKeys) { $parameters['KnownRequirementKeys'] = $KnownRequirementKeys }
        return @(Test-WinLeanRuleDefinition @parameters | ForEach-Object { $_.code })
    }
}

Describe 'Rule validation' {
    It 'accepts a complete rule' {
        @(Test-WinLeanRuleDefinition -Definition (New-TestRuleDefinition) -SourcePath 'Privacy\privacy.test-rule.disable.json').Count | Should -Be 0
    }

    It 'reports <Code> for <Case>' -ForEach @(
        @{ Case = 'an unknown property'; Code = 'UnknownProperty'; Extra = @{ sideEffect = @('typo') } }
        @{ Case = 'a wrong schema version'; Code = 'SchemaVersion'; Extra = @{ schemaVersion = 2 } }
        @{ Case = 'an uppercase id'; Code = 'RuleId'; Extra = @{ id = 'Privacy.Test.Disable' } }
        @{ Case = 'an id without the category prefix'; Code = 'RuleIdPrefix'; Extra = @{ id = 'explorer.test.disable' } }
        @{ Case = 'an unknown category'; Code = 'Category'; Extra = @{ category = 'Tweaks' } }
        @{ Case = 'an unknown risk'; Code = 'Risk'; Extra = @{ risk = 'Critical' } }
        @{ Case = 'a missing rationale'; Code = 'RequiredField'; Extra = @{ rationale = '' } }
        @{ Case = 'requiresReboot without takesEffect Reboot'; Code = 'TakesEffect'; Extra = @{ requiresReboot = $true } }
        @{ Case = 'a build below Windows 11'; Code = 'Windows'; Extra = @{ windows = @{ minBuild = 19045; maxValidatedBuild = 26200 } } }
        @{ Case = 'a validated build below the minimum'; Code = 'Windows'; Extra = @{ windows = @{ minBuild = 26100; maxValidatedBuild = 22631 } } }
        @{ Case = 'an unknown operator'; Code = 'Conditions'; Extra = @{ conditions = @(@{ fact = 'requirement.printer'; operator = 'Is'; value = $false }) } }
        @{ Case = 'a non-boolean requirement value'; Code = 'Conditions'; Extra = @{ conditions = @(@{ fact = 'requirement.printer'; operator = 'Equals'; value = 'no' }) } }
        @{ Case = 'a malformed fact'; Code = 'Conditions'; Extra = @{ conditions = @(@{ fact = 'printer'; operator = 'Equals'; value = $false }) } }
        @{ Case = 'a self dependency'; Code = 'References'; Extra = @{ dependencies = @('privacy.test-rule.disable') } }
        @{ Case = 'missing references'; Code = 'References'; Extra = @{ references = @() } }
        @{ Case = 'an http reference'; Code = 'References'; Extra = @{ references = @(@{ title = 't'; url = 'http://example.com' }) } }
        @{ Case = 'no side effects'; Code = 'Documentation'; Extra = @{ sideEffects = @() } }
        @{ Case = 'no resources'; Code = 'Resources'; Extra = @{ resources = @() } }
        @{ Case = 'a reversible flag of false'; Code = 'Reversible'; Extra = @{ reversible = $false } }
        @{ Case = 'invalid tags'; Code = 'Tags'; Extra = @{ tags = @('Not Valid') } }
    ) {
        Get-IssueCodes -Definition (New-TestRuleDefinition -Extra $Extra) | Should -Contain $Code
    }

    It 'rejects resources that target protected locations' {
        $resources = @(@{ type = 'RegistryValue'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; name = 'DisableAntiSpyware'; valueType = 'DWord'; value = 1 })
        $issues = @(Test-WinLeanRuleDefinition -Definition (New-TestRuleDefinition -Resources $resources))
        $issues.code | Should -Contain 'Resources'
        ($issues | Where-Object { $_.code -eq 'Resources' }).message | Should -BeLike '*protected registry location*'
    }

    It 'rejects unknown resource types and invalid resource data' {
        Get-IssueCodes -Definition (New-TestRuleDefinition -Resources @(@{ type = 'Service'; name = 'Spooler' })) | Should -Contain 'Resources'
        Get-IssueCodes -Definition (New-TestRuleDefinition -Resources @(@{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = -1 })) | Should -Contain 'Resources'
    }

    It 'checks requirement keys when known keys are given' {
        $conditions = @(@{ fact = 'requirement.printers'; operator = 'Equals'; value = $false })
        Get-IssueCodes -Definition (New-TestRuleDefinition -Conditions $conditions) -KnownRequirementKeys @('printer') | Should -Contain 'Conditions'
        Get-IssueCodes -Definition (New-TestRuleDefinition -Conditions $conditions) | Should -Not -Contain 'Conditions'
    }

    It 'requires the file name and folder to match the id and category' {
        Get-IssueCodes -Definition (New-TestRuleDefinition) -SourcePath 'Privacy\other-name.json' | Should -Contain 'Location'
        Get-IssueCodes -Definition (New-TestRuleDefinition) -SourcePath 'Explorer\privacy.test-rule.disable.json' | Should -Contain 'Location'
    }

    It 'accepts every category with its prefix' {
        foreach ($category in @(Get-WinLeanRuleCategories)) {
            $definition = New-TestRuleDefinition -Id "$($category.prefix).sample.set" -Category $category.category
            @(Test-WinLeanRuleDefinition -Definition $definition).Count | Should -Be 0 -Because "category $($category.category)"
        }
    }
}

Describe 'Catalog validation' {
    It 'reports duplicate ids, unknown references and contradictions' {
        $rules = @(
            New-TestRule -Id 'privacy.a.disable' -Dependencies @('privacy.missing.disable')
            New-TestRule -Id 'privacy.b.disable' -Conflicts @('privacy.c.disable') -Dependencies @('privacy.c.disable') -Resources @(@{ type = 'RegistryValue'; path = 'HKCU:\Software\T'; name = 'B'; valueType = 'DWord'; value = 1 })
            New-TestRule -Id 'privacy.c.disable' -Resources @(@{ type = 'RegistryValue'; path = 'HKCU:\Software\T'; name = 'C'; valueType = 'DWord'; value = 1 })
            New-TestRule -Id 'privacy.a.disable'
        )
        $codes = @(Test-WinLeanRuleCatalog -Rules $rules | ForEach-Object { $_.code })
        $codes | Should -Contain 'DuplicateRuleId'
        $codes | Should -Contain 'UnknownDependency'
        $codes | Should -Contain 'ContradictoryReferences'
    }

    It 'finds dependency cycles' {
        $rules = @(
            New-TestRule -Id 'privacy.a.disable' -Dependencies @('privacy.b.disable')
            New-TestRule -Id 'privacy.b.disable' -Dependencies @('privacy.c.disable')
            New-TestRule -Id 'privacy.c.disable' -Dependencies @('privacy.a.disable')
        )
        $cycle = @(Find-WinLeanDependencyCycle -Rules $rules)
        $cycle.Count | Should -Be 4
        $cycle[0] | Should -Be $cycle[3]
        @(Test-WinLeanRuleCatalog -Rules $rules | Where-Object { $_.code -eq 'DependencyCycle' }).Count | Should -Be 1
        @(Find-WinLeanDependencyCycle -Rules @($rules[0], $rules[1])).Count | Should -Be 0
    }

    It 'warns when two rules set the same value differently without declaring a conflict' {
        $resource0 = @{ type = 'RegistryValue'; path = 'HKCU:\Software\T'; name = 'Same'; valueType = 'DWord'; value = 0 }
        $resource1 = @{ type = 'RegistryValue'; path = 'HKCU:\Software\T'; name = 'SAME'; valueType = 'DWord'; value = 1 }
        $undeclared = @(Test-WinLeanRuleCatalog -Rules @((New-TestRule -Id 'privacy.a.disable' -Resources @($resource0)), (New-TestRule -Id 'privacy.b.disable' -Resources @($resource1))))
        $undeclared.code | Should -Be @('UndeclaredConflict')
        $undeclared[0].severity | Should -Be 'Warning'
        $declared = @(Test-WinLeanRuleCatalog -Rules @((New-TestRule -Id 'privacy.a.disable' -Resources @($resource0) -Conflicts @('privacy.b.disable')), (New-TestRule -Id 'privacy.b.disable' -Resources @($resource1))))
        $declared.Count | Should -Be 0
    }
}

Describe 'Profile validation' {
    BeforeAll {
        function New-ProfileDefinition {
            param([hashtable] $Extra = @{})
            $definition = [ordered]@{ schemaVersion = 1; name = 'Custom'; description = 'Test'; extends = $null; rules = @('privacy.a.disable'); exclude = @(); maxRisk = 'Low' }
            foreach ($key in $Extra.Keys) { $definition[$key] = $Extra[$key] }
            return ConvertTo-JsonShape -InputObject $definition
        }
    }

    It 'accepts a valid profile' {
        @(Test-WinLeanProfileDefinition -Definition (New-ProfileDefinition) -ExpectedName 'Custom').Count | Should -Be 0
    }

    It 'reports <Code> for <Case>' -ForEach @(
        @{ Case = 'a name that differs from the file name'; Code = 'ProfileName'; Extra = @{ name = 'Other' } }
        @{ Case = 'an invalid name'; Code = 'ProfileName'; Extra = @{ name = 'My Profile' } }
        @{ Case = 'an unknown property'; Code = 'UnknownProperty'; Extra = @{ include = @() } }
        @{ Case = 'an invalid rule id'; Code = 'RuleList'; Extra = @{ rules = @('Not A Rule') } }
        @{ Case = 'an unknown maximum risk'; Code = 'Risk'; Extra = @{ maxRisk = 'None' } }
        @{ Case = 'a non-string parent'; Code = 'Extends'; Extra = @{ extends = 5 } }
    ) {
        @(Test-WinLeanProfileDefinition -Definition (New-ProfileDefinition -Extra $Extra) -ExpectedName 'Custom' | ForEach-Object { $_.code }) | Should -Contain $Code
    }
}

Describe 'Compatibility validation' {
    It 'rejects non-boolean values and warns about unknown keys' {
        $definition = ConvertTo-JsonShape -InputObject @{ schemaVersion = 1; requirements = @{ printer = 'yes'; printers = $true } }
        $issues = @(Test-WinLeanCompatibilityDefinition -Definition $definition -KnownRequirementKeys @('printer'))
        @($issues | Where-Object { $_.severity -eq 'Error' }).message | Should -BeLike "*'printer' must be true or false*"
        @($issues | Where-Object { $_.severity -eq 'Warning' }).message | Should -BeLike "*'printers'*"
    }
}
