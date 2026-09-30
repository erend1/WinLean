<#
    The generic parts of the resource provider contract: normalization of provider
    results, reboot propagation and the engine's use of optional state properties.
    Provider-specific behaviour is tested with each provider.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Restore', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Providers', 'WinLean.Common'
}

Describe 'Provider results' {
    It 'normalizes <Case>' -ForEach @(
        @{ Case = 'no output to unknown'; Output = @(); Expected = $null }
        @{ Case = 'a reported restart'; Output = @([pscustomobject]@{ rebootRequired = $true }); Expected = $true }
        @{ Case = 'a reported "no restart"'; Output = @([pscustomobject]@{ rebootRequired = $false }); Expected = $false }
        @{ Case = 'stray values around the result'; Output = @($true, 'text', [pscustomobject]@{ rebootRequired = $true }, 5); Expected = $true }
        @{ Case = 'a non-boolean report to unknown'; Output = @([pscustomobject]@{ rebootRequired = 'yes' }); Expected = $null }
    ) {
        (ConvertTo-WinLeanProviderResult -Output $Output).rebootRequired | Should -Be $Expected
    }

    It 'combines the reports of several changed resources' {
        Join-WinLeanRebootRequirement -Values @() | Should -BeNullOrEmpty
        Join-WinLeanRebootRequirement -Values @($false, $true, $null) | Should -BeTrue
        Join-WinLeanRebootRequirement -Values @($false, $false) | Should -BeFalse
        Join-WinLeanRebootRequirement -Values @($false, $null) | Should -BeNullOrEmpty
    }

    It 'returns an unknown reboot requirement for registry changes' {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
        $rule = New-TestValueRule -Id 'privacy.a.disable'
        $applied = Set-WinLeanRuleState -Rule $rule -State (Get-WinLeanRuleState -Rule $rule)
        $applied.changedResources | Should -Be @(0)
        $applied.rebootRequired | Should -BeNullOrEmpty
    }
}

Describe 'Reboot requirement of a rule result' {
    BeforeAll {
        $script:ExecutorModule = Get-Module -Name 'WinLean.Executor'
        function Get-Requirement {
            param([bool] $Declared, [string] $Status = 'Succeeded', [bool] $Changed = $true, $Reported = $null, $Rollback = $null)
            $parameters = @{ TakesEffect = 'Immediately' }
            if ($Declared) { $parameters = @{ RequiresReboot = $true; TakesEffect = 'Reboot' } }
            $rule = New-TestValueRule -Id 'privacy.a.disable' -Extra $parameters
            return & $script:ExecutorModule {
                param($r, $s, $c, $p, $b)
                Get-WinLeanResultRebootRequirement -Rule $r -Status $s -Changed $c -Reported $p -Rollback $b
            } $rule $Status $Changed $Reported $Rollback
        }
    }

    It 'follows the declaration when no provider reports' {
        Get-Requirement -Declared $true | Should -BeTrue
        Get-Requirement -Declared $false | Should -BeFalse
    }

    It 'follows the provider when it reports' {
        Get-Requirement -Declared $false -Reported $true | Should -BeTrue
        Get-Requirement -Declared $true -Reported $false | Should -BeFalse
    }

    It 'is false for unchanged or failed rules unless a rollback is pending a restart' {
        Get-Requirement -Declared $true -Changed $false | Should -BeFalse
        Get-Requirement -Declared $true -Status 'Failed' -Reported $true | Should -BeFalse
        Get-Requirement -Declared $false -Status 'Failed' -Rollback ([pscustomobject]@{ restored = $true; rebootRequired = $true }) | Should -BeTrue
    }
}

Describe 'Domain warning' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'is shown only when policy-based resources will be applied' {
        $preference = New-TestValueRule -Id 'privacy.preference.disable' -Path 'HKCU:\Software\WinLeanTest\Preference'
        $policy = New-TestValueRule -Id 'privacy.policy.disable' -Path 'HKCU:\Software\Policies\WinLeanTest'
        $warning = 'This device is joined to a domain. Organizational Group Policy may override or conflict with policy-based settings.'
        (New-TestPlan -Rules @($preference) -Facts (New-TestFacts -PartOfDomain $true)).warnings | Should -Not -Contain $warning
        (New-TestPlan -Rules @($preference, $policy) -Facts (New-TestFacts -PartOfDomain $true)).warnings | Should -Contain $warning
        (New-TestPlan -Rules @($preference, $policy) -Facts (New-TestFacts -PartOfDomain $false)).warnings | Should -Not -Contain $warning
    }
}

Describe 'Reboot requirement of a restore' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'uses the declaration recorded in the backup when the provider cannot tell' {
        $rule = New-TestValueRule -Id 'privacy.reboot.disable' -Extra @{ RequiresReboot = $true; TakesEffect = 'Reboot' }
        $backupRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $execution = Invoke-WinLeanExecution -Plan (New-TestPlan -Rules @($rule)) -Catalog (New-TestCatalog -Rules @($rule)) -BackupRoot $backupRoot `
            -RunId '2026-09-30_10-00-00' -Logger (New-TestLogger) -Identity (New-TestIdentity)
        $execution.summary.rebootRequired | Should -BeTrue

        $backup = Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId
        $backup.changes[0].requiresReboot | Should -BeTrue
        $restorePlan = Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)
        $result = Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_10-05-00' -Logger (New-TestLogger)
        $result.status | Should -Be 'Restored'
        $result.rebootRequired | Should -BeTrue
        $result.results[0].rebootRequired | Should -BeTrue
    }

    It 'treats backups written before reboot information was recorded as not requiring a restart' {
        $item = [pscustomobject]@{ sequence = 1; ruleId = 'privacy.a.disable' }
        $restoreModule = Get-Module -Name 'WinLean.Restore'
        & $restoreModule { param($i) Get-WinLeanRestoreRebootRequirement -Item $i -Reported $null } $item | Should -BeFalse
        & $restoreModule { param($i) Get-WinLeanRestoreRebootRequirement -Item $i -Reported $true } $item | Should -BeTrue
    }
}
