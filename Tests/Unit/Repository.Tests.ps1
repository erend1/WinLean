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

    It 'are all low risk and reversible in milestone 0.1' {
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

    It 'reference evidence files that exist' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'Rules') -Filter '*.json' -Recurse) {
            $definition = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            foreach ($observation in @(Get-WinLeanArrayProperty -InputObject $definition -Name 'evidence')) {
                Test-Path -LiteralPath (Join-Path $script:RepoRoot $observation.file) | Should -BeTrue -Because "$($file.Name) references $($observation.file)"
            }
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
            $profile = Import-WinLeanProfile -Name $file.FullName -ProfileDirectory $script:ProfileDirectory
            @(Test-WinLeanProfileRules -Profile $profile -Catalog $script:Catalog) | Should -BeNullOrEmpty -Because $file.Name
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
}

Describe 'Schemas and configuration' {
    It 'list the same categories, risks and effect timings as the validator' {
        $categories = @(Get-WinLeanRuleCategories | ForEach-Object { $_.category })
        @($script:RuleSchema.properties.category.enum) | Should -Be $categories
        @($script:RuleSchema.properties.risk.enum) | Should -Be @(Get-WinLeanRiskLevels)
        @($script:RuleSchema.properties.takesEffect.enum) | Should -Be @('Immediately', 'ExplorerRestart', 'SignOut', 'Reboot')
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
