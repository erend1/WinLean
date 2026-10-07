<#
    Integrity checks for everything shipped in the repository: rules, profiles, schemas,
    configuration examples and source files.
#>
BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before BeforeAll runs.
    $script:CanValidateSchemas = $PSVersionTable.PSVersion.Major -ge 7 -and $null -ne (Get-Command -Name Test-Json -ErrorAction SilentlyContinue)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Validation', 'WinLean.Compatibility', 'WinLean.Common'

    $script:Keys = @(Get-WinLeanRequirementDefinitions -SchemaPath (Join-Path $script:RepoRoot 'Schemas\compatibility.schema.json') | ForEach-Object { $_.key })
    $script:Catalog = Import-WinLeanRuleCatalog -Path (Join-Path $script:RepoRoot 'Rules') -KnownRequirementKeys $script:Keys
    $script:ProfileDirectory = Join-Path $script:RepoRoot 'Profiles'
    $script:RuleSchema = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Schemas\rule.schema.json') | ConvertFrom-Json
}

Describe 'Shipped rules' {
    It 'load without errors or warnings' {
        $messages = @($script:Catalog.issues | ForEach-Object { "$($_.source): $($_.message)" })
        $messages | Should -BeNullOrEmpty
        $script:Catalog.ruleIds.Count | Should -BeGreaterOrEqual 5
    }

    It 'are all low risk and reversible' {
        foreach ($id in $script:Catalog.ruleIds) {
            $rule = $script:Catalog.rules[$id]
            $rule.risk | Should -Be 'Low' -Because $id
            $rule.reversible | Should -BeTrue -Because $id
        }
    }

    It 'document where every setting comes from' {
        foreach ($id in $script:Catalog.ruleIds) {
            $rule = $script:Catalog.rules[$id]
            @($rule.references).Count | Should -BeGreaterThan 0 -Because $id
            foreach ($reference in $rule.references) {
                $reference.url | Should -BeLike 'https://*' -Because $id
            }
            @($rule.sideEffects).Count | Should -BeGreaterThan 0 -Because $id
        }
    }

    It 'reference evidence, measurement and validation files that exist' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'Rules') -Filter '*.json' -Recurse) {
            $definition = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            $files = @(
                @(Get-WinLeanArrayProperty -InputObject $definition -Name 'evidence') | ForEach-Object { $_.file }
                @(Get-WinLeanArrayProperty -InputObject $definition -Name 'validation') | ForEach-Object { Get-WinLeanProperty -InputObject $_ -Name 'file' }
                Get-WinLeanProperty -InputObject $definition.benefit -Name 'measurementFile'
            ) | Where-Object { $_ }
            foreach ($relative in $files) {
                Test-Path -LiteralPath (Join-Path $script:RepoRoot $relative) | Should -BeTrue -Because "$($file.Name) references $relative"
            }
        }
    }

    It 'declare their benefit and when they were last validated' {
        foreach ($id in $script:Catalog.ruleIds) {
            $rule = $script:Catalog.rules[$id]
            $rule.benefit.type | Should -Not -BeNullOrEmpty -Because $id
            $rule.lastValidated | Should -Match '^\d{4}-\d{2}-\d{2}$' -Because $id
            @($rule.validation)[0].build | Should -Be $rule.windows.maxValidatedBuild -Because $id
        }
    }

    It 'validate against the JSON schema' -Skip:(-not $script:CanValidateSchemas) {
        $schema = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Schemas\rule.schema.json')
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'Rules') -Filter '*.json' -Recurse) {
            Test-Json -Json (Get-Content -Raw -LiteralPath $file.FullName) -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue -Because $file.Name
        }
    }
}

Describe 'Shipped profiles' {
    It 'resolve and reference only known rules within their risk limit' {
        foreach ($file in Get-ChildItem -LiteralPath $script:ProfileDirectory -Filter '*.json') {
            $ruleProfile = Import-WinLeanProfile -Name $file.FullName -ProfileDirectory $script:ProfileDirectory
            @(Test-WinLeanProfileRules -Profile $ruleProfile -Catalog $script:Catalog) | Should -BeNullOrEmpty -Because $file.Name
        }
    }

    It 'build on each other: Safe < Lean < Minimal' {
        $safe = Import-WinLeanProfile -Name 'Safe' -ProfileDirectory $script:ProfileDirectory
        $lean = Import-WinLeanProfile -Name 'Lean' -ProfileDirectory $script:ProfileDirectory
        $minimal = Import-WinLeanProfile -Name 'Minimal' -ProfileDirectory $script:ProfileDirectory
        $safe.maxRisk | Should -Be 'Low'
        foreach ($id in $safe.ruleIds) { $lean.ruleIds | Should -Contain $id }
        foreach ($id in $lean.ruleIds) { $minimal.ruleIds | Should -Contain $id }
        $minimal.chain | Should -Be @('Safe', 'Lean', 'Minimal')
    }

    It 'keep optional preferences out of Safe and Lean' {
        (Import-WinLeanProfile -Name 'Lean' -ProfileDirectory $script:ProfileDirectory).ruleIds | Should -Not -Contain 'explorer.hidden-files.show'
        $custom = Import-WinLeanProfile -Name 'Example.Custom' -ProfileDirectory $script:ProfileDirectory
        $custom.ruleIds | Should -Contain 'explorer.hidden-files.show'
        $custom.excluded | Should -Contain 'privacy.language-list-web-access.disable'
    }

    It 'keep Safe conservative: low risk rules without compatibility conditions' {
        foreach ($id in (Import-WinLeanProfile -Name 'Safe' -ProfileDirectory $script:ProfileDirectory).ruleIds) {
            $rule = $script:Catalog.rules[$id]
            $rule.risk | Should -Be 'Low' -Because $id
            @($rule.conditions).Count | Should -Be 0 -Because "$id should not depend on compatibility decisions"
        }
    }

    It 'include rules of risk Medium or higher only after a VM apply/restore validation' {
        # Lean admission criteria (Docs/Rules.md): an understood benefit, an explicit
        # compatibility condition, a satisfied source standard, a tested provider and a
        # successful apply/verify/restore in a disposable VM.
        foreach ($file in Get-ChildItem -LiteralPath $script:ProfileDirectory -Filter '*.json') {
            $ruleProfile = Import-WinLeanProfile -Name $file.FullName -ProfileDirectory $script:ProfileDirectory
            foreach ($id in $ruleProfile.ruleIds) {
                $rule = $script:Catalog.rules[$id]
                if ((Get-WinLeanRiskRank -Risk $rule.risk) -ge 1) {
                    $rule.vmValidated | Should -BeTrue -Because "$id ($($rule.risk)) is part of profile $($ruleProfile.name)"
                }
            }
        }
    }
}

Describe 'Schemas and configuration' {
    It 'list the same categories, risks and effect timings as the validator' {
        $categories = @(Get-WinLeanRuleCategories | ForEach-Object { $_.category })
        @($script:RuleSchema.properties.category.enum) | Should -Be $categories
        @($script:RuleSchema.properties.risk.enum) | Should -Be @(Get-WinLeanRiskLevels)
        @($script:RuleSchema.properties.takesEffect.enum) | Should -Be @('Immediately', 'ExplorerRestart', 'SignOut', 'Reboot')
    }

    It 'list the same benefit, evidence and validation values as the validator' {
        $vocabulary = Get-WinLeanRuleVocabulary
        $properties = $script:RuleSchema.properties
        @($properties.takesEffect.enum) | Should -Be $vocabulary.takesEffect
        @($properties.benefit.properties.type.enum) | Should -Be $vocabulary.benefitTypes
        @($properties.benefit.properties.value.enum) | Should -Be $vocabulary.benefitValues
        @($properties.benefit.properties.measurement.enum) | Should -Be $vocabulary.benefitMeasurements
        @($properties.evidence.items.properties.method.enum) | Should -Be $vocabulary.evidenceMethods
        @($properties.validation.items.properties.method.enum) | Should -Be $vocabulary.validationMethods
        @($script:RuleSchema.required) | Should -Contain 'benefit'
        # 'validation' stays optional for rule files written before it existed.
        @($script:RuleSchema.required) | Should -Not -Contain 'validation'
    }

    It 'have a compatibility example that declares every known requirement' {
        $examplePath = Join-Path $script:RepoRoot 'Config\Compatibility.example.json'
        $example = Get-Content -Raw -LiteralPath $examplePath | ConvertFrom-Json
        $declared = @($example.requirements.PSObject.Properties | ForEach-Object { $_.Name })
        ($declared | Sort-Object) | Should -Be ($script:Keys | Sort-Object)
        (Import-WinLeanCompatibility -Path $examplePath -KnownRequirementKeys $script:Keys).issues | Should -BeNullOrEmpty
    }

    It 'validate profiles and the compatibility example against their schemas' -Skip:(-not $script:CanValidateSchemas) {
        $profileSchema = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Schemas\profile.schema.json')
        foreach ($file in Get-ChildItem -LiteralPath $script:ProfileDirectory -Filter '*.json') {
            Test-Json -Json (Get-Content -Raw -LiteralPath $file.FullName) -Schema $profileSchema -ErrorAction SilentlyContinue | Should -BeTrue -Because $file.Name
        }
        $compatibilitySchema = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Schemas\compatibility.schema.json')
        Test-Json -Json (Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Config\Compatibility.example.json')) -Schema $compatibilitySchema -ErrorAction SilentlyContinue | Should -BeTrue
    }
}

Describe 'Continuous integration and static analysis' {
    It 'never runs the destructive suite on hosted runners' {
        $workflows = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot '.github\workflows') -File | Where-Object { $_.Extension -in @('.yml', '.yaml') })
        $workflows.Count | Should -BeGreaterThan 0
        foreach ($workflow in $workflows) {
            $content = Get-Content -Raw -LiteralPath $workflow.FullName
            $content | Should -Not -Match 'WINLEAN_ALLOW_DESTRUCTIVE_TESTS' -Because "$($workflow.Name) must not enable destructive tests"
            $content | Should -Not -Match '-Suite\s+Destructive' -Because "$($workflow.Name) must not run destructive tests"
        }
    }

    It 'excludes only the analyzer rules that are documented in the settings file' {
        $settings = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1')
        @($settings.ExcludeRules | Sort-Object) | Should -Be @('PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns')
        $settings.Severity | Should -Contain 'Error'
        $settings.Severity | Should -Contain 'Warning'
        $settings.Rules.PSUseCompatibleSyntax.TargetVersions | Should -Contain '5.1'
    }
}

Describe 'Source files' {
    It 'are ASCII only, so Windows PowerShell 5.1 reads them correctly without a BOM' {
        # Filter by extension explicitly: Windows PowerShell 5.1 ignores -Include with -LiteralPath.
        $files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
                Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') -and $_.FullName -notlike '*\.tools\*' })
        $files.Count | Should -BeGreaterThan 10
        foreach ($file in $files) {
            $nonAscii = @([System.IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count
            $nonAscii | Should -Be 0 -Because $file.FullName
        }
    }

    It 'search text with ordinal comparisons' {
        # String.StartsWith/EndsWith/IndexOf/LastIndexOf(string) compare with the current
        # culture (ICU on .NET 5+), where some characters are ignorable. Literal searches
        # must pass a StringComparison or use the [char] overload.
        $pattern = '\.(StartsWith|EndsWith|IndexOf|LastIndexOf)\(\s*(''[^'']*''|"[^"]*")\s*(,\s*[^,()]+)?\)'
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src'), (Join-Path $script:RepoRoot 'Tools') -Recurse -File |
                Where-Object { $_.Extension -in @('.ps1', '.psm1') })
        $offenders = @(foreach ($file in $files) {
                $number = 0
                foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                    $number++
                    foreach ($match in [regex]::Matches($line, $pattern)) {
                        if ($match.Value -notmatch 'StringComparison') { "$($file.Name):$($number): $($match.Value)" }
                    }
                }
            })
        $offenders | Should -BeNullOrEmpty
    }

    It 'support -WhatIf in every function that changes Windows' {
        # Replaces the name-based analyzer rule PSUseShouldProcessForStateChangingFunctions
        # (excluded in PSScriptAnalyzerSettings.psd1) with an exact requirement: the Set and
        # Restore operation of every registered provider, and the low-level functions that
        # write to the system.
        $providersModule = Get-Module -All | Where-Object { $_.Name -eq 'WinLean.Providers' } | Select-Object -First 1
        $names = New-Object -TypeName System.Collections.Generic.List[string]
        foreach ($name in @(& $providersModule { foreach ($type in $script:Providers.Keys) { $script:Providers[$type]['Set']; $script:Providers[$type]['Restore'] } })) { $names.Add($name) }
        foreach ($name in @('Write-WinLeanRegistryValue', 'Remove-WinLeanRegistryValue', 'Remove-WinLeanRegistryKeyIfEmpty', 'Invoke-WinLeanOptionalFeatureChange')) { $names.Add($name) }
        $names.Count | Should -BeGreaterOrEqual 10
        foreach ($name in $names) {
            $command = & $providersModule { param($n) Get-Command -Name $n -ErrorAction Stop } $name
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$name changes Windows state"
        }
    }

    It 'enable strict mode in every module' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src') -Recurse -Filter '*.psm1') {
            (Get-Content -Raw -LiteralPath $file.FullName) | Should -Match 'Set-StrictMode -Version Latest' -Because $file.Name
        }
    }

    It 'export every facade function listed in the manifest' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\WinLean.psd1')
        $core = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'src\WinLean.Core.psm1')
        foreach ($name in $manifest.FunctionsToExport) {
            $core | Should -Match ("function $name " -replace '-', '\-') -Because $name
            $core | Should -Match ("'$name'" -replace '-', '\-') -Because "$name is exported"
        }
    }
}
