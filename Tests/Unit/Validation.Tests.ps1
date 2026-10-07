BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before BeforeAll runs.
    $script:CanValidateSchemas = $PSVersionTable.PSVersion.Major -ge 7 -and $null -ne (Get-Command -Name Test-Json -ErrorAction SilentlyContinue)
}
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

Describe 'Evidence standard' {
    BeforeAll {
        $script:Observation = @{ method = 'RegistryDiff'; build = 26200; file = 'Docs/Evidence/privacy.test-rule.disable.md'; summary = 'Toggling the setting off wrote Value = 1.' }
    }

    It 'accepts a per-user preference rule backed only by a recorded observation' {
        $definition = New-TestRuleDefinition -Extra @{ references = @(); evidence = @($script:Observation) }
        @(Test-WinLeanRuleDefinition -Definition $definition).Count | Should -Be 0
    }

    It 'requires at least one reference or observation' {
        Get-IssueCodes -Definition (New-TestRuleDefinition -Extra @{ references = @() }) | Should -Contain 'References'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'machine-wide values without documentation'; Resources = @(@{ type = 'RegistryValue'; path = 'HKLM:\SOFTWARE\WinLeanTest'; name = 'V'; valueType = 'DWord'; value = 1 }); Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 }; Observation = $null }
        @{ Case = 'policy values without documentation'; Resources = @(@{ type = 'RegistryValue'; path = 'HKCU:\Software\Policies\WinLeanTest'; name = 'V'; valueType = 'DWord'; value = 1 }); Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 }; Observation = $null }
        @{ Case = 'a validated build newer than the observation'; Resources = $null; Windows = @{ minBuild = 22000; maxValidatedBuild = 26300 }; Observation = $null }
        @{ Case = 'an unknown capture method'; Resources = $null; Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 }; Observation = @{ method = 'Guess'; build = 26200; file = 'Docs/Evidence/x.md'; summary = 's' } }
        @{ Case = 'an evidence file outside Docs/Evidence'; Resources = $null; Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 }; Observation = @{ method = 'RegistryDiff'; build = 26200; file = 'C:\evidence.md'; summary = 's' } }
        @{ Case = 'a build below Windows 11'; Resources = $null; Windows = @{ minBuild = 22000; maxValidatedBuild = 26200 }; Observation = @{ method = 'RegistryDiff'; build = 19045; file = 'Docs/Evidence/x.md'; summary = 's' } }
    ) {
        $observation = if ($Observation) { $Observation } else { $script:Observation }
        $parameters = @{ Windows = $Windows; Extra = @{ references = @(); evidence = @($observation) } }
        if ($Resources) { $parameters['Resources'] = $Resources }
        Get-IssueCodes -Definition (New-TestRuleDefinition @parameters) | Should -Contain 'Evidence'
    }

    It 'allows documented machine-wide rules to add observations' {
        $resources = @(@{ type = 'RegistryValue'; path = 'HKLM:\SOFTWARE\WinLeanTest'; name = 'V'; valueType = 'DWord'; value = 1 })
        $definition = New-TestRuleDefinition -Resources $resources -Extra @{ evidence = @($script:Observation) }
        @(Test-WinLeanRuleDefinition -Definition $definition).Count | Should -Be 0
    }
}

Describe 'Benefit and validation metadata' {
    It 'reports <Code> for <Case>' -ForEach @(
        @{ Case = 'a missing benefit'; Code = 'Benefit'; Extra = @{ benefit = $null } }
        @{ Case = 'an unknown benefit property'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Privacy'; value = 'Low'; measurement = 'NotMeasured'; score = 7 } } }
        @{ Case = 'an unknown benefit type'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Speed'; value = 'Low'; measurement = 'NotMeasured' } } }
        @{ Case = 'an unknown benefit value'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Privacy'; value = 'Huge'; measurement = 'NotMeasured' } } }
        @{ Case = 'an unmeasured performance claim'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Performance'; value = 'Low'; measurement = 'NotMeasured' } } }
        @{ Case = 'an unmeasured moderate background-activity claim'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'BackgroundActivity'; value = 'Moderate'; measurement = 'NotMeasured' } } }
        @{ Case = 'a measurement without a write-up'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Performance'; value = 'Low'; measurement = 'Measured' } } }
        @{ Case = 'a write-up outside Docs/Measurements'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Performance'; value = 'Low'; measurement = 'Measured'; measurementFile = 'C:\m.md' } } }
        @{ Case = 'a write-up for an unmeasured benefit'; Code = 'Benefit'; Extra = @{ benefit = @{ type = 'Privacy'; value = 'Low'; measurement = 'NotMeasured'; measurementFile = 'Docs/Measurements/m.md' } } }
        @{ Case = 'no validation record'; Code = 'Validation'; Extra = @{ validation = @() } }
        @{ Case = 'an unknown validation method'; Code = 'Validation'; Extra = @{ validation = @(@{ method = 'Guess'; build = 26200; date = '2026-09-28' }) } }
        @{ Case = 'a date in another format'; Code = 'Validation'; Extra = @{ validation = @(@{ method = 'SourceReview'; build = 26200; date = '28.09.2026' }) } }
        @{ Case = 'a date in the future'; Code = 'Validation'; Extra = @{ validation = @(@{ method = 'SourceReview'; build = 26200; date = '2999-01-01' }) } }
        @{ Case = 'a VM validation without its record'; Code = 'Validation'; Extra = @{ validation = @(@{ method = 'VmApplyRestore'; build = 26200; date = '2026-09-28' }) } }
        @{ Case = 'a maxValidatedBuild that differs from the newest validation'; Code = 'Validation'; Extra = @{ validation = @(@{ method = 'SourceReview'; build = 26100; date = '2026-09-28' }) } }
        @{ Case = 'a validation below the minimum build'; Code = 'Validation'; Extra = @{ windows = @{ minBuild = 26100; maxValidatedBuild = 26200 }; validation = @(@{ method = 'SourceReview'; build = 26200; date = '2026-09-28' }, @{ method = 'SourceReview'; build = 22631; date = '2026-09-01' }) } }
        @{ Case = 'a Medium risk rule without a requirement condition'; Code = 'Conditions'; Extra = @{ risk = 'Medium' } }
        @{ Case = 'a High risk rule with only a capability condition'; Code = 'Conditions'; Extra = @{ risk = 'High'; conditions = @(@{ fact = 'capability.batteryPresent'; operator = 'Equals'; value = $false }) } }
    ) {
        Get-IssueCodes -Definition (New-TestRuleDefinition -Extra $Extra) | Should -Contain $Code
    }

    It 'accepts <Case>' -ForEach @(
        @{ Case = 'a measured performance benefit'; Extra = @{ benefit = @{ type = 'Performance'; value = 'Moderate'; measurement = 'Measured'; measurementFile = 'Docs/Measurements/privacy.test-rule.disable.md' } } }
        @{ Case = 'a low, unmeasured background-activity benefit'; Extra = @{ benefit = @{ type = 'BackgroundActivity'; value = 'Low'; measurement = 'NotMeasured' } } }
        @{ Case = 'a VM validation with its record'; Extra = @{ validation = @(@{ method = 'VmApplyRestore'; build = 26200; date = '2026-09-29'; file = 'Docs/Validation/2026-09-29-26200.md'; notes = 'Hyper-V VM' }, @{ method = 'SourceReview'; build = 26100; date = '2026-09-01' }) } }
        @{ Case = 'a Medium risk rule with a requirement condition'; Extra = @{ risk = 'Medium'; conditions = @(@{ fact = 'requirement.printer'; operator = 'Equals'; value = $false }) } }
    ) {
        @(Test-WinLeanRuleDefinition -Definition (New-TestRuleDefinition -Extra $Extra) | ForEach-Object { "$($_.code): $($_.message)" }) | Should -BeNullOrEmpty
    }

    It 'accepts dates that PowerShell 7.0-7.4 parsed from JSON as DateTime' {
        $definition = New-TestRuleDefinition
        $definition.validation[0].date = [datetime]::new(2026, 9, 28)
        @(Test-WinLeanRuleDefinition -Definition $definition).Count | Should -Be 0
        (ConvertTo-WinLeanRule -Definition $definition).lastValidated | Should -Be '2026-09-28'
    }

    It 'normalizes validation records newest first' {
        $rule = New-TestRule -Extra @{ validation = @(@{ method = 'SourceReview'; build = 26100; date = '2026-09-01' }, @{ method = 'VmApplyRestore'; build = 26200; date = '2026-09-29'; file = 'Docs/Validation/v.md' }) }
        $rule.validation[0].date | Should -Be '2026-09-29'
        $rule.lastValidated | Should -Be '2026-09-29'
        $rule.vmValidated | Should -BeTrue
        $rule.benefit.type | Should -Be 'Privacy'
    }
}

Describe 'Backward compatibility of rule files' {
    It 'loads a rule file written before validation records existed' {
        $definition = New-TestRuleDefinition
        $definition.PSObject.Properties.Remove('validation')
        @(Test-WinLeanRuleDefinition -Definition $definition | ForEach-Object { "$($_.code): $($_.message)" }) | Should -BeNullOrEmpty
        $rule = ConvertTo-WinLeanRule -Definition $definition
        $rule.lastValidated | Should -BeNullOrEmpty
        $rule.vmValidated | Should -BeFalse
        @($rule.validation).Count | Should -Be 0
        $rule.windows.maxValidatedBuild | Should -Be 26200
    }

    It 'still requires every rule to state its benefit' {
        $definition = New-TestRuleDefinition
        $definition.PSObject.Properties.Remove('benefit')
        Get-IssueCodes -Definition $definition | Should -Contain 'Benefit'
    }
}

Describe 'JSON schema and validator' {
    BeforeAll {
        $script:RuleSchemaText = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Schemas\rule.schema.json')
    }

    It 'agree on <Case>' -Skip:(-not $script:CanValidateSchemas) -ForEach @(
        @{ Case = 'a registry value'; Valid = $true; Resource = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord'; value = 1 } }
        @{ Case = 'a registry value without data'; Valid = $false; Resource = @{ type = 'RegistryValue'; path = 'HKCU:\Software\X'; name = 'V'; valueType = 'DWord' } }
        @{ Case = 'removing a startup entry'; Valid = $true; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent' } }
        @{ Case = 'adding a startup entry'; Valid = $true; Resource = @{ type = 'StartupEntry'; location = 'MachineRun'; name = 'Example'; ensure = 'Present'; command = 'C:\Example\example.exe'; valueType = 'ExpandString' } }
        @{ Case = 'a startup entry without ensure'; Valid = $false; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example' } }
        @{ Case = 'a removed startup entry with a command'; Valid = $false; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent'; command = 'x.exe' } }
        @{ Case = 'an added startup entry without a command'; Valid = $false; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Present' } }
        @{ Case = 'a startup entry in RunOnce'; Valid = $false; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRunOnce'; name = 'Example'; ensure = 'Absent' } }
        @{ Case = 'an optional feature'; Valid = $true; Resource = @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled' } }
        @{ Case = 'an optional feature with payload removal'; Valid = $false; Resource = @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Removed' } }
        @{ Case = 'an optional feature with an unknown property'; Valid = $false; Resource = @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled'; all = $true } }
        @{ Case = 'an optional feature with an invalid name'; Valid = $false; Resource = @{ type = 'WindowsOptionalFeature'; name = 'Telnet Client'; state = 'Disabled' } }
        @{ Case = 'an unknown resource type'; Valid = $false; Resource = @{ type = 'Service'; name = 'Spooler' } }
    ) {
        # A Medium risk rule with a requirement condition and a restart satisfies the
        # rule-level constraints of every resource type, so only the resource decides.
        $definition = New-TestRuleDefinition -Id 'features.sample.set' -Category 'Features' -Resources @($Resource) -Risk 'Medium' `
            -Conditions @(@{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false }) -RequiresReboot $true -TakesEffect 'Reboot'
        $json = $definition | ConvertTo-Json -Depth 20
        [bool](Test-Json -Json $json -Schema $script:RuleSchemaText -ErrorAction SilentlyContinue) | Should -Be $Valid -Because 'of the JSON schema'
        (@(Test-WinLeanRuleDefinition -Definition $definition).Count -eq 0) | Should -Be $Valid -Because 'of the validator'
    }

    It 'agree on rule metadata: <Case>' -Skip:(-not $script:CanValidateSchemas) -ForEach @(
        @{ Case = 'a complete rule'; Valid = $true; Extra = @{} }
        @{ Case = 'an unmeasured performance claim'; Valid = $false; Extra = @{ benefit = @{ type = 'Performance'; value = 'Low'; measurement = 'NotMeasured' } } }
        @{ Case = 'a measured benefit without its write-up'; Valid = $false; Extra = @{ benefit = @{ type = 'Storage'; value = 'Low'; measurement = 'Measured' } } }
        @{ Case = 'a measured performance benefit'; Valid = $true; Extra = @{ benefit = @{ type = 'Performance'; value = 'High'; measurement = 'Measured'; measurementFile = 'Docs/Measurements/x.md' } } }
        @{ Case = 'a VM validation without its record'; Valid = $false; Extra = @{ validation = @(@{ method = 'VmApplyRestore'; build = 26200; date = '2026-09-28' }) } }
        @{ Case = 'an empty validation list'; Valid = $false; Extra = @{ validation = @() } }
    ) {
        $definition = New-TestRuleDefinition -Extra $Extra
        $json = $definition | ConvertTo-Json -Depth 20
        [bool](Test-Json -Json $json -Schema $script:RuleSchemaText -ErrorAction SilentlyContinue) | Should -Be $Valid -Because 'of the JSON schema'
        (@(Test-WinLeanRuleDefinition -Definition $definition).Count -eq 0) | Should -Be $Valid -Because 'of the validator'
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
