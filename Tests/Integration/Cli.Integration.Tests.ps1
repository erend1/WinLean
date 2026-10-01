<#
    End-to-end tests of WinLean.ps1 in a child PowerShell process.

    The apply/restore cycle runs against a copy of WinLean whose only rules target
    Pester's TestRegistry (HKCU\Software\Pester\<guid>), so no Windows setting is touched.
    The read-only commands (-Validate, -ListRules, -Profile Safe -WhatIf) run against the
    real repository with Backups/Reports/Logs redirected to TestDrive.
#>
BeforeDiscovery {
    # WinLean applies rules only on Windows 11 client installations. On other systems (for
    # example the Windows Server images of CI runners) every rule is Unsupported by design,
    # so the apply/restore cycle is skipped there.
    $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:IsWindows11Client = ($currentVersion.InstallationType -eq 'Client') -and ([int]$currentVersion.CurrentBuildNumber -ge 22000)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')

    $script:HostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function Invoke-WinLeanCli {
        <#
            Runs WinLean.ps1 in a child process through -Command. (-File cannot pass switch
            values such as -Confirm:$false on Windows PowerShell 5.1.) Arguments starting
            with '-' are passed as PowerShell syntax; everything else is single-quoted.
            -InputLines are piped to the child process (answers for Read-Host).
        #>
        param([Parameter(Mandatory)] [string] $Script, [Parameter(Mandatory)] [string[]] $Arguments, [string[]] $InputLines)
        $quoted = foreach ($argument in $Arguments) {
            if ($argument.StartsWith('-')) { $argument } else { "'" + $argument.Replace("'", "''") + "'" }
        }
        $command = "& '{0}' {1}; exit `$LASTEXITCODE" -f $Script.Replace("'", "''"), ($quoted -join ' ')
        if ($PSBoundParameters.ContainsKey('InputLines')) {
            $output = ($InputLines -join "`n") | & $script:HostPath -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { "$_" }
        }
        else {
            $output = & $script:HostPath -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { "$_" }
        }
        return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
    }

    function Get-TestRegistryBase {
        $root = (Get-PSDrive -Name TestRegistry).Root
        if ($root.StartsWith('HKEY_CURRENT_USER\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'HKCU:\' + $root.Substring('HKEY_CURRENT_USER\'.Length)
        }
        return $root.TrimEnd('\')
    }
}

Describe 'Read-only commands on the real repository' {
    BeforeAll {
        $script:Cli = Join-Path $script:RepoRoot 'WinLean.ps1'
        $script:Data = Join-Path $TestDrive 'data'
    }

    It 'validates the shipped rules and profiles' {
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Validate', '-DataRoot', $script:Data)
        $result.exitCode | Should -Be 0
        $result.output | Should -BeLike '*0 error(s), 0 warning(s)*'
    }

    It 'lists the rules' {
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-ListRules', '-DataRoot', $script:Data)
        $result.exitCode | Should -Be 0
        $result.output | Should -BeLike '*explorer.file-extensions.show*'
    }

    It 'produces a dry-run plan for the Safe profile and saves it' {
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Profile', 'Safe', '-WhatIf', '-DataRoot', $script:Data)
        $result.exitCode | Should -Be 0
        $result.output | Should -BeLike '*WINLEAN PLAN*'
        $result.output | Should -BeLike '*no changes were made*'
        @(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Reports\Plans') -Filter '*-Safe-plan.json').Count | Should -Be 1
    }

    It 'returns exit code 2 for an unknown profile' {
        (Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Profile', 'DoesNotExist', '-WhatIf', '-DataRoot', $script:Data)).exitCode | Should -Be 2
    }

    It 'returns exit code 2 when there is nothing to restore' {
        (Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Restore', 'Latest', '-DataRoot', $script:Data)).exitCode | Should -Be 2
    }
}

Describe 'Compatibility questionnaire (-Configure)' {
    BeforeAll {
        $script:Cli = Join-Path $script:RepoRoot 'WinLean.ps1'
        $script:Data = Join-Path $TestDrive 'configure-data'
        $script:Config = Join-Path $TestDrive 'Configure\Compatibility.json'

        function Invoke-Configure {
            param([string[]] $Answers, [string[]] $Extra = @('-Confirm:$false'))
            $arguments = @('-Configure', '-SkipDetection', '-CompatibilityPath', $script:Config, '-DataRoot', $script:Data) + $Extra
            return Invoke-WinLeanCli -Script $script:Cli -Arguments $arguments -InputLines $Answers
        }
    }

    It 'creates the configuration from the answers' {
        # printer: Y, networkPrinting: N, scanner: Enter, bluetooth: Q
        $result = Invoke-Configure -Answers @('y', 'n', '', 'q')
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -BeLike '*printer: undeclared -> required*networkPrinting: undeclared -> not needed*'
        $saved = Get-Content -Raw -LiteralPath $script:Config | ConvertFrom-Json
        $saved.requirements.printer | Should -BeTrue
        $saved.requirements.networkPrinting | Should -BeFalse
        @($saved.requirements.PSObject.Properties).Count | Should -Be 2
        (Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Validate', '-CompatibilityPath', $script:Config, '-DataRoot', $script:Data)).exitCode | Should -Be 0
    }

    It 'writes nothing when no answer changes' {
        $before = Get-Content -Raw -LiteralPath $script:Config
        $result = Invoke-Configure -Answers @('', '', 'q')
        $result.exitCode | Should -Be 0
        $result.output | Should -BeLike '*Nothing to save*'
        Get-Content -Raw -LiteralPath $script:Config | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $TestDrive 'Configure\Compatibility.previous.json') | Should -BeFalse
    }

    It 'shows the summary but writes nothing with -WhatIf' {
        $before = Get-Content -Raw -LiteralPath $script:Config
        $result = Invoke-Configure -Answers @('n', 'q') -Extra @('-WhatIf')
        $result.exitCode | Should -Be 0
        $result.output | Should -BeLike '*printer: required -> not needed*Dry run (-WhatIf)*'
        Get-Content -Raw -LiteralPath $script:Config | Should -BeExactly $before
    }

    It 'updates the configuration and keeps the previous version' {
        $before = Get-Content -Raw -LiteralPath $script:Config
        $result = Invoke-Configure -Answers @('u', 'q')
        $result.exitCode | Should -Be 0 -Because $result.output
        (Get-Content -Raw -LiteralPath $script:Config | ConvertFrom-Json).requirements.PSObject.Properties.Name | Should -Be @('networkPrinting')
        Get-Content -Raw -LiteralPath (Join-Path $TestDrive 'Configure\Compatibility.previous.json') | Should -BeExactly $before
    }

    It 'refuses to edit an invalid configuration (exit code 2) and leaves it untouched' {
        $broken = Join-Path $TestDrive 'Configure\Broken.json'
        Set-Content -LiteralPath $broken -Value '{ "schemaVersion": 1, "requirements": { "printer": "yes" } }' -Encoding utf8
        $before = Get-Content -Raw -LiteralPath $broken
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Configure', '-SkipDetection', '-CompatibilityPath', $broken, '-DataRoot', $script:Data, '-Confirm:$false') -InputLines @('y')
        $result.exitCode | Should -Be 2
        $result.output | Should -BeLike '*has errors and was not changed*'
        Get-Content -Raw -LiteralPath $broken | Should -BeExactly $before
    }

    It 'shows read-only detection hints' {
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Configure', '-CompatibilityPath', $script:Config, '-DataRoot', $script:Data, '-Confirm:$false') -InputLines @('q')
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -BeLike '*Detecting hardware and software for hints*'
        $result.output | Should -BeLike '*Nothing to save*'
    }
}

Describe 'Apply and restore cycle in a sandbox' -Skip:(-not $script:IsWindows11Client) {
    BeforeAll {
        $base = Get-TestRegistryBase
        $script:Sandbox = "$base\Cli"
        $install = Join-Path $TestDrive 'install'
        $script:Data = Join-Path $TestDrive 'sandbox-data'
        New-Item -ItemType Directory -Force -Path (Join-Path $install 'Rules\Development'), (Join-Path $install 'Profiles'), (Join-Path $install 'Config') | Out-Null
        Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot 'src') -Destination $install
        Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot 'Schemas') -Destination $install
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'WinLean.ps1') -Destination $install
        $script:Cli = Join-Path $install 'WinLean.ps1'

        function Write-SandboxRule {
            param([string] $Id, [object[]] $Resources, [string[]] $Dependencies = @())
            $definition = New-TestRuleDefinition -Id $Id -Category 'Development' -Resources $Resources -Dependencies $Dependencies
            Set-Content -LiteralPath (Join-Path $install "Rules\Development\$Id.json") -Value ($definition | ConvertTo-Json -Depth 20) -Encoding utf8
        }
        Write-SandboxRule -Id 'development.sandbox-existing.set' -Resources @(@{ type = 'RegistryValue'; path = "$script:Sandbox\Existing"; name = 'Value'; valueType = 'DWord'; value = 1 })
        Write-SandboxRule -Id 'development.sandbox-new.set' -Dependencies @('development.sandbox-existing.set') -Resources @(@{ type = 'RegistryValue'; path = "$script:Sandbox\New\Deep"; name = 'Value'; valueType = 'String'; value = 'hello' })
        $profile = @{ schemaVersion = 1; name = 'Sandbox'; description = 'Sandbox'; extends = $null; rules = @('development.sandbox-new.set', 'development.sandbox-existing.set'); exclude = @(); maxRisk = 'Low' }
        Set-Content -LiteralPath (Join-Path $install 'Profiles\Sandbox.json') -Value ($profile | ConvertTo-Json) -Encoding utf8

        New-Item -Path "$script:Sandbox\Existing" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$script:Sandbox\Existing" -Name 'Value' -Value 0 -Type DWord

        function Get-SandboxValue { (Get-ItemProperty -LiteralPath "$script:Sandbox\Existing").Value }
    }

    It 'applies with verification and creates a backup' {
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Profile', 'Sandbox', '-Apply', '-Confirm:$false', '-SkipBenchmark', '-DataRoot', $script:Data)
        $result.exitCode | Should -Be 0 -Because $result.output
        $result.output | Should -BeLike '*[[]OK] Verified*'
        Get-SandboxValue | Should -Be 1
        Test-Path -LiteralPath "$script:Sandbox\New\Deep" | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Backups') -Directory).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Reports') -Filter '*-report.md').Count | Should -Be 1
    }

    It 'is idempotent' {
        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Profile', 'Sandbox', '-Apply', '-Confirm:$false', '-SkipBenchmark', '-DataRoot', $script:Data)
        $result.exitCode | Should -Be 0
        $result.output | Should -BeLike '*Nothing to apply*'
        @(Get-ChildItem -LiteralPath (Join-Path $script:Data 'Backups') -Directory).Count | Should -Be 1
    }

    It 'previews and then restores the previous state exactly' {
        $preview = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Restore', 'Latest', '-WhatIf', '-DataRoot', $script:Data)
        $preview.exitCode | Should -Be 0
        Get-SandboxValue | Should -Be 1

        $result = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Restore', 'Latest', '-Confirm:$false', '-DataRoot', $script:Data)
        $result.exitCode | Should -Be 0 -Because $result.output
        Get-SandboxValue | Should -Be 0
        Test-Path -LiteralPath "$script:Sandbox\New" | Should -BeFalse
    }

    It 'skips values changed after apply unless -Force is given' {
        (Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Profile', 'Sandbox', '-Apply', '-Confirm:$false', '-SkipBenchmark', '-DataRoot', $script:Data)).exitCode | Should -Be 0
        Set-ItemProperty -LiteralPath "$script:Sandbox\Existing" -Name 'Value' -Value 5 -Type DWord
        $backupId = (Get-ChildItem -LiteralPath (Join-Path $script:Data 'Backups') -Directory | Sort-Object Name | Select-Object -Last 1).Name

        $skipped = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Restore', $backupId, '-Confirm:$false', '-DataRoot', $script:Data)
        $skipped.output | Should -BeLike '*RestoredWithSkips*'
        Get-SandboxValue | Should -Be 5

        $forced = Invoke-WinLeanCli -Script $script:Cli -Arguments @('-Restore', $backupId, '-Force', '-Confirm:$false', '-DataRoot', $script:Data)
        $forced.exitCode | Should -Be 0
        Get-SandboxValue | Should -Be 0
    }
}
