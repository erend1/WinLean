BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Compatibility', 'WinLean.Common'

    $script:SchemaPath = Join-Path $script:RepoRoot 'Schemas\compatibility.schema.json'
    $script:Keys = @(Get-WinLeanRequirementDefinitions -SchemaPath $script:SchemaPath | ForEach-Object { $_.key })

    function New-Section {
        param($Data)
        return [pscustomobject]@{ available = $true; reason = $null; message = $null; durationMs = 0; data = $Data }
    }

    function New-Probe {
        param($Data)
        return New-Section -Data $Data
    }

    function New-TestInventory {
        $hardware = [pscustomobject]@{
            bluetooth = New-Probe -Data ([pscustomobject]@{ adapterPresent = $true })
            battery   = New-Probe -Data ([pscustomobject]@{ present = $false; count = 0 })
            printers  = New-Probe -Data ([pscustomobject]@{ physicalCount = 0; printers = @() })
        }
        return [pscustomobject]@{
            sections = [pscustomobject]@{
                hardware          = New-Section -Data $hardware
                optionalFeatures  = New-Section -Data ([pscustomobject]@{ features = @([pscustomobject]@{ name = 'Microsoft-Hyper-V-All'; state = 'Enabled' }, [pscustomobject]@{ name = 'Microsoft-Windows-Subsystem-Linux'; state = 'Disabled' }) })
                win32Applications = New-Section -Data ([pscustomobject]@{ applications = @([pscustomobject]@{ name = 'Microsoft OneDrive' }) })
                appxPackages      = [pscustomobject]@{ available = $false; reason = 'Error'; message = 'x'; durationMs = 0; data = $null }
            }
        }
    }
}

Describe 'Requirement definitions' {
    It 'reads the canonical requirement keys from the schema' {
        $script:Keys.Count | Should -Be 36
        $script:Keys | Should -Contain 'printer'
        $script:Keys | Should -Contain 'gamingMachine'
    }
}

Describe 'Import-WinLeanCompatibility' {
    It 'treats a missing file as "nothing declared"' {
        $compatibility = Import-WinLeanCompatibility -Path (Join-Path $TestDrive 'missing.json') -KnownRequirementKeys $script:Keys
        $compatibility.exists | Should -BeFalse
        $compatibility.requirements.Count | Should -Be 0
        $compatibility.errorCount | Should -Be 0
    }

    It 'loads declared requirements and ignores unknown keys with a warning' {
        $path = Join-Path $TestDrive 'compat.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "requirements": { "printer": false, "bluetooth": true, "printers": true } }'
        $compatibility = Import-WinLeanCompatibility -Path $path -KnownRequirementKeys $script:Keys
        $compatibility.requirements['printer'] | Should -BeFalse
        $compatibility.requirements['bluetooth'] | Should -BeTrue
        $compatibility.requirements.ContainsKey('printers') | Should -BeFalse
        @($compatibility.issues | Where-Object { $_.severity -eq 'Warning' }).Count | Should -Be 1
        $compatibility.errorCount | Should -Be 0
    }

    It 'reports invalid files as errors' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "requirements": { "printer": "no" } }'
        (Import-WinLeanCompatibility -Path $path -KnownRequirementKeys $script:Keys).errorCount | Should -Be 1
    }
}

Describe 'Capabilities and facts' {
    It 'derives capabilities and omits what cannot be determined' {
        $capabilities = Get-WinLeanCapabilities -Inventory (New-TestInventory)
        $capabilities['bluetoothAdapterPresent'] | Should -BeTrue
        $capabilities['physicalPrinterInstalled'] | Should -BeFalse
        $capabilities['batteryPresent'] | Should -BeFalse
        $capabilities['hyperVEnabled'] | Should -BeTrue
        $capabilities['wslEnabled'] | Should -BeFalse
        $capabilities['oneDriveInstalled'] | Should -BeTrue
        $capabilities.ContainsKey('phoneLinkInstalled') | Should -BeFalse
        (Get-WinLeanCapabilities -Inventory $null).Count | Should -Be 0
    }

    It 'suggests declaring requirements for detected but undeclared features only' {
        $path = Join-Path $TestDrive 'declared.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "requirements": { "hyperV": true } }'
        $compatibility = Import-WinLeanCompatibility -Path $path -KnownRequirementKeys $script:Keys
        $suggestions = @(Get-WinLeanCompatibilitySuggestions -Compatibility $compatibility -Capabilities (Get-WinLeanCapabilities -Inventory (New-TestInventory)))
        $suggestions.requirement | Should -Contain 'bluetooth'
        $suggestions.requirement | Should -Contain 'onedrive'
        $suggestions.requirement | Should -Not -Contain 'hyperV'
    }

    It 'builds facts from platform, requirements and capabilities' {
        $path = Join-Path $TestDrive 'facts.json'
        Set-Content -LiteralPath $path -Value '{ "schemaVersion": 1, "requirements": { "printer": false } }'
        $compatibility = Import-WinLeanCompatibility -Path $path -KnownRequirementKeys $script:Keys
        $capabilities = New-WinLeanDictionary
        $capabilities['batteryPresent'] = $true
        $platform = [pscustomobject]@{ build = 26200; ubr = 1; editionId = 'Professional'; displayVersion = '25H2'; installationType = 'Client'; architecture = 'X64'; partOfDomain = $false }
        $facts = New-WinLeanFacts -Platform $platform -Compatibility $compatibility -Capabilities $capabilities
        $facts['system.build'] | Should -Be 26200
        $facts['requirement.printer'] | Should -BeFalse
        $facts['capability.batteryPresent'] | Should -BeTrue
        $facts.ContainsKey('requirement.bluetooth') | Should -BeFalse
    }

    It 'summarizes declared, undeclared and detected values' {
        $compatibility = Import-WinLeanCompatibility -Path $null -KnownRequirementKeys $script:Keys
        $summary = Get-WinLeanCompatibilitySummary -Compatibility $compatibility -KnownRequirementKeys $script:Keys
        $summary.exists | Should -BeFalse
        @($summary.undeclared).Count | Should -Be 36
    }
}
