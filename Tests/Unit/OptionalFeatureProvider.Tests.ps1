<#
    WindowsOptionalFeature provider: validation, state semantics, planning, privilege
    handling, reboot propagation, collateral-change protection and backup/restore - against
    an in-memory fake of the servicing interface (no feature is ever changed).
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Restore', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Validation', 'WinLean.Providers', 'WinLean.Provider.OptionalFeature', 'WinLean.Common'

    $script:NoDeveloper = @{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false }

    function New-FeatureRule {
        param(
            [string] $Id = 'features.telnet-client.disable',
            [object[]] $Resources = @(@{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled' }),
            [object[]] $Conditions = @($script:NoDeveloper)
        )
        return New-TestRule -Id $Id -Category 'Features' -Resources $Resources -Risk 'Medium' -Conditions $Conditions -RequiresReboot $true -TakesEffect 'Reboot'
    }

    function Get-FeatureIssues {
        param([hashtable] $Resource, [string] $Risk = 'Medium', [string] $TakesEffect = 'Reboot', [object[]] $Conditions = @($script:NoDeveloper))
        $definition = New-TestRuleDefinition -Id 'features.sample.set' -Category 'Features' -Resources @($Resource) -Risk $Risk -Conditions $Conditions `
            -RequiresReboot ($TakesEffect -eq 'Reboot') -TakesEffect $TakesEffect
        return @(Test-WinLeanRuleDefinition -Definition $definition | ForEach-Object { $_.message })
    }

    function Invoke-FeatureExecution {
        param([object[]] $Rules, [string] $RunId = '2026-09-30_14-00-00', $Facts = (New-TestFacts -Requirements @{ developerMachine = $false }))
        $script:BackupRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $plan = New-TestPlan -Rules $Rules -Facts $Facts -IsAdministrator $true
        return Invoke-WinLeanExecution -Plan $plan -Catalog (New-TestCatalog -Rules $Rules) -BackupRoot $script:BackupRoot -RunId $RunId -Logger (New-TestLogger) -Identity (New-TestIdentity -IsAdministrator $true)
    }
}

Describe 'WindowsOptionalFeature definitions' {
    It 'accepts disabling a feature in a Medium risk rule that takes effect after a restart' {
        Get-FeatureIssues -Resource @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled' } | Should -BeNullOrEmpty
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown state'; Expected = "*'state' must be 'Enabled' or 'Disabled'*"; Resource = @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Removed' } }
        @{ Case = 'an invalid name'; Expected = "*'name' must be the exact feature name*"; Resource = @{ type = 'WindowsOptionalFeature'; name = 'Telnet Client'; state = 'Disabled' } }
        @{ Case = 'an unknown property'; Expected = "*unknown property 'all'*"; Resource = @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled'; all = $true } }
        @{ Case = 'a Defender feature'; Expected = '*protected optional feature (Microsoft Defender)*'; Resource = @{ type = 'WindowsOptionalFeature'; name = 'Windows-Defender-Default-Definitions'; state = 'Disabled' } }
        @{ Case = 'virtualization-based security'; Expected = '*protected optional feature*'; Resource = @{ type = 'WindowsOptionalFeature'; name = 'IsolatedUserMode'; state = 'Enabled' } }
        @{ Case = 'the unified write filter'; Expected = '*protected optional feature (Unified Write Filter*'; Resource = @{ type = 'WindowsOptionalFeature'; name = 'client-unifiedwritefilter'; state = 'Enabled' } }
        @{ Case = 'enabling SMB 1.0'; Expected = '*SMB 1.0 is deprecated and insecure; WinLean never enables it*'; Resource = @{ type = 'WindowsOptionalFeature'; name = 'SMB1Protocol'; state = 'Enabled' } }
        @{ Case = 'enabling Windows PowerShell 2.0'; Expected = '*never enables it*'; Resource = @{ type = 'WindowsOptionalFeature'; name = 'MicrosoftWindowsPowerShellV2Root'; state = 'Enabled' } }
    ) {
        (Get-FeatureIssues -Resource $Resource) -join "`n" | Should -BeLike $Expected
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a Low risk rule'; Expected = '*need risk Medium or higher*'; Risk = 'Low'; TakesEffect = 'Reboot'; Conditions = @() }
        @{ Case = 'a rule that does not declare a restart'; Expected = "*must declare takesEffect 'Reboot'*"; Risk = 'Medium'; TakesEffect = 'SignOut'; Conditions = @(@{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false }) }
    ) {
        (Get-FeatureIssues -Resource @{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled' } -Risk $Risk -TakesEffect $TakesEffect -Conditions $Conditions) -join "`n" | Should -BeLike $Expected
    }

    It 'does not disable <Name> merely because it exists' -ForEach @(
        @{ Name = 'Microsoft-Hyper-V-All'; Keys = @('hyperV') }
        @{ Name = 'Microsoft-Windows-Subsystem-Linux'; Keys = @('wsl2', 'docker') }
        @{ Name = 'VirtualMachinePlatform'; Keys = @('wsl2', 'docker') }
        @{ Name = 'Containers-DisposableClientVM'; Keys = @('windowsSandbox') }
    ) {
        $resource = @{ type = 'WindowsOptionalFeature'; name = $Name; state = 'Disabled' }
        $messages = (Get-FeatureIssues -Resource $resource) -join "`n"
        foreach ($key in $Keys) {
            $messages | Should -BeLike "*needs the condition 'requirement.$key Equals false'*"
        }
        $declared = @(foreach ($key in $Keys) { @{ fact = "requirement.$key"; operator = 'Equals'; value = $false } })
        Get-FeatureIssues -Resource $resource -Conditions $declared | Should -BeNullOrEmpty
        $required = @(foreach ($key in $Keys) { @{ fact = "requirement.$key"; operator = 'Equals'; value = $true } })
        (Get-FeatureIssues -Resource $resource -Conditions $required) -join "`n" | Should -BeLike '*needs the condition*'
    }

    It 'does not require requirement conditions to enable a feature' {
        Get-FeatureIssues -Resource @{ type = 'WindowsOptionalFeature'; name = 'VirtualMachinePlatform'; state = 'Enabled' } | Should -BeNullOrEmpty
    }

    It 'is registered with the dispatcher next to the other resource types' {
        @(Get-WinLeanResourceTypes) | Should -Be @('RegistryValue', 'StartupEntry', 'WindowsOptionalFeature')
    }
}

Describe 'WindowsOptionalFeature state semantics' {
    It 'treats <Actual> as <Result> for the desired state <Desired>' -ForEach @(
        @{ Desired = 'Disabled'; Actual = 'Disabled'; Result = $true }
        @{ Desired = 'Disabled'; Actual = 'DisablePending'; Result = $true }
        @{ Desired = 'Disabled'; Actual = 'DisabledWithPayloadRemoved'; Result = $true }
        @{ Desired = 'Disabled'; Actual = 'NotPresent'; Result = $true }
        @{ Desired = 'Disabled'; Actual = 'Enabled'; Result = $false }
        @{ Desired = 'Disabled'; Actual = 'EnablePending'; Result = $false }
        @{ Desired = 'Enabled'; Actual = 'EnablePending'; Result = $true }
        @{ Desired = 'Enabled'; Actual = 'NotPresent'; Result = $false }
        @{ Desired = 'Enabled'; Actual = 'Unknown'; Result = $false }
        @{ Desired = 'DisabledWithPayloadRemoved'; Actual = 'Disabled'; Result = $false }
    ) {
        Test-WinLeanOptionalFeatureStateEqual -Expected ([pscustomobject]@{ state = $Desired }) -Actual ([pscustomobject]@{ state = $Actual }) | Should -Be $Result
    }

    It 'formats states for people' {
        Format-WinLeanOptionalFeatureState -State ([pscustomobject]@{ state = 'DisablePending' }) | Should -Be 'Disabled (restart pending)'
        Format-WinLeanOptionalFeatureState -State ([pscustomobject]@{ state = 'NotPresent' }) | Should -Be 'not part of this Windows installation'
        (Get-WinLeanOptionalFeatureResourceInfo -Resource ([pscustomobject]@{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled' })).identity | Should -BeExactly 'WINDOWSOPTIONALFEATURE:TELNETCLIENT'
    }
}

Describe 'WindowsOptionalFeature planning' {
    BeforeEach {
        $script:FakeFeatures = New-FakeFeatureStore -Features @{ TelnetClient = 'Enabled' }
        Register-FakeFeatureMocks
        $script:Facts = New-TestFacts -Requirements @{ developerMachine = $false }
    }

    It 'plans the change for an administrator and blocks it for a standard user' {
        $rule = New-FeatureRule
        $admin = (New-TestPlan -Rules @($rule) -Facts $script:Facts -IsAdministrator $true).items[0]
        $admin.status | Should -Be 'Applicable'
        $admin.resources[0].currentText | Should -Be 'Enabled'
        $admin.resources[0].desiredText | Should -Be 'Disabled'

        $script:FakeFeatures.IsAdministrator = $false
        $standard = (New-TestPlan -Rules @($rule) -Facts $script:Facts).items[0]
        $standard.status | Should -Be 'Blocked'
        $standard.requiresAdministrator | Should -BeTrue
        $standard.reasons[0] | Should -BeLike "Requires Administrator*Windows optional feature 'TelnetClient'*"
    }

    It 'skips the rule until the requirement is declared' {
        (New-TestPlan -Rules @(New-FeatureRule) -IsAdministrator $true).items[0].status | Should -Be 'Skipped'
    }

    It 'is satisfied when the feature is not part of the image, and Unsupported when it must be enabled' {
        $disable = New-FeatureRule -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'NotInThisImage'; state = 'Disabled' })
        (New-TestPlan -Rules @($disable) -Facts $script:Facts -IsAdministrator $true).items[0].status | Should -Be 'AlreadySatisfied'

        $enable = New-FeatureRule -Id 'features.missing.enable' -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'NotInThisImage'; state = 'Enabled' })
        $item = (New-TestPlan -Rules @($enable) -Facts $script:Facts -IsAdministrator $true).items[0]
        $item.status | Should -Be 'Unsupported'
        $item.reasons[0] | Should -Be "The optional feature 'NotInThisImage' is not part of this Windows installation."
    }

    It 'does not change a feature that is waiting for a restart' {
        $script:FakeFeatures.Features['TelnetClient'] = 'EnablePending'
        $item = (New-TestPlan -Rules @(New-FeatureRule) -Facts $script:Facts -IsAdministrator $true).items[0]
        $item.status | Should -Be 'Blocked'
        $item.reasons[0] | Should -BeLike '*A restart is pending*Restart Windows before WinLean changes it.*'
    }

    It 'announces a restart in the plan' {
        (New-TestPlan -Rules @(New-FeatureRule) -Facts $script:Facts -IsAdministrator $true).summary.rebootRequired | Should -BeTrue
    }
}

Describe 'WindowsOptionalFeature execution' {
    BeforeEach {
        $script:FakeFeatures = New-FakeFeatureStore -Features @{ TelnetClient = 'Enabled'; 'Parent-Feature' = 'Enabled'; 'Child-Feature' = 'Enabled'; OtherFeature = 'Disabled' }
        Register-FakeFeatureMocks
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'disables the feature, verifies it and reports the restart DISM asks for' {
        $script:FakeFeatures.RestartNeeded = $true
        $execution = Invoke-FeatureExecution -Rules @(New-FeatureRule)
        $execution.status | Should -Be 'Completed'
        $script:FakeFeatures.Features['TelnetClient'] | Should -Be 'Disabled'
        $script:FakeFeatures.Operations | Should -Be @('Disable:TelnetClient')
        $execution.results[0].rebootRequired | Should -BeTrue
        $execution.summary.rebootRequired | Should -BeTrue
    }

    It 'reports no restart when DISM needs none, although the rule declares one' {
        $execution = Invoke-FeatureExecution -Rules @(New-FeatureRule)
        $execution.results[0].rebootRequired | Should -BeFalse
        $execution.summary.rebootRequired | Should -BeFalse
    }

    It 'reports a restart when the change is pending' {
        $script:FakeFeatures.PendingChanges = $true
        $execution = Invoke-FeatureExecution -Rules @(New-FeatureRule)
        $execution.status | Should -Be 'Completed'
        $script:FakeFeatures.Features['TelnetClient'] | Should -Be 'DisablePending'
        $execution.results[0].rebootRequired | Should -BeTrue
    }

    It 'is idempotent' {
        [void](Invoke-FeatureExecution -Rules @(New-FeatureRule))
        $second = Invoke-FeatureExecution -Rules @(New-FeatureRule) -RunId '2026-09-30_14-10-00'
        $second.status | Should -Be 'NoChanges'
        $script:FakeFeatures.Operations.Count | Should -Be 1
    }

    It 'reverts and fails a change that also changed other features' {
        $script:FakeFeatures.Cascade['Parent-Feature'] = @('Child-Feature')
        $initial = Get-FakeFeatureSnapshotText -Store $script:FakeFeatures
        $rule = New-FeatureRule -Id 'features.parent.disable' -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'Parent-Feature'; state = 'Disabled' })
        $execution = Invoke-FeatureExecution -Rules @($rule)

        $result = $execution.results[0]
        $result.status | Should -Be 'Failed'
        $result.failure.class | Should -Be 'CollateralChange'
        $result.failure.message | Should -BeLike "*also changed other features: Child-Feature (Enabled -> Disabled)*WinLean reverted these changes*"
        $result.rollback.restored | Should -BeTrue
        Get-FakeFeatureSnapshotText -Store $script:FakeFeatures | Should -BeExactly $initial
        $script:FakeFeatures.Operations | Should -Be @('Disable:Parent-Feature', 'Enable:Parent-Feature', 'Enable:Child-Feature')
    }

    It 'succeeds when dependent features are listed explicitly, children first' {
        $script:FakeFeatures.Cascade['Parent-Feature'] = @('Child-Feature')
        $rule = New-FeatureRule -Id 'features.parent.disable' -Resources @(
            @{ type = 'WindowsOptionalFeature'; name = 'Child-Feature'; state = 'Disabled' }
            @{ type = 'WindowsOptionalFeature'; name = 'Parent-Feature'; state = 'Disabled' }
        )
        (Invoke-FeatureExecution -Rules @($rule)).status | Should -Be 'Completed'
    }

    It 'rolls back when servicing fails and never downloads a removed payload' {
        $script:FakeFeatures.Features['OtherFeature'] = 'DisabledWithPayloadRemoved'
        $rule = New-FeatureRule -Id 'features.other.enable' -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'OtherFeature'; state = 'Enabled' })
        $result = (Invoke-FeatureExecution -Rules @($rule)).results[0]
        $result.status | Should -Be 'Failed'
        $result.failure.class | Should -Be 'CommandFailed'
        $result.rollback.restored | Should -BeTrue
        $script:FakeFeatures.Features['OtherFeature'] | Should -Be 'DisabledWithPayloadRemoved'
    }

    It 'does not attempt the change when elevation was lost after planning' {
        $rules = @(New-FeatureRule)
        $plan = New-TestPlan -Rules $rules -Facts (New-TestFacts -Requirements @{ developerMachine = $false }) -IsAdministrator $true
        $script:FakeFeatures.IsAdministrator = $false
        $execution = Invoke-WinLeanExecution -Plan $plan -Catalog (New-TestCatalog -Rules $rules) -BackupRoot (Join-Path $TestDrive 'lost') -RunId '2026-09-30_14-20-00' -Logger (New-TestLogger) -Identity (New-TestIdentity)
        $execution.results[0].failure.class | Should -Be 'PermissionDenied'
        $script:FakeFeatures.Operations.Count | Should -Be 0
    }

    It 'fails as Unsupported when the feature disappeared after planning' {
        $rules = @(New-FeatureRule -Id 'features.telnet-client.enable' -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'OtherFeature'; state = 'Enabled' }))
        $plan = New-TestPlan -Rules $rules -Facts (New-TestFacts -Requirements @{ developerMachine = $false }) -IsAdministrator $true
        [void]$script:FakeFeatures.Features.Remove('OtherFeature')
        $execution = Invoke-WinLeanExecution -Plan $plan -Catalog (New-TestCatalog -Rules $rules) -BackupRoot (Join-Path $TestDrive 'gone') -RunId '2026-09-30_14-30-00' -Logger (New-TestLogger) -Identity (New-TestIdentity -IsAdministrator $true)
        $execution.results[0].failure.class | Should -Be 'Unsupported'
    }

    It 'refuses protected features at write time' {
        $resource = [pscustomobject]@{ type = 'WindowsOptionalFeature'; name = 'SMB1Protocol'; state = 'Enabled' }
        { Set-WinLeanOptionalFeatureResource -Resource $resource } | Should -Throw -ExpectedMessage '*protected optional feature*'
        $defender = [pscustomobject]@{ type = 'WindowsOptionalFeature'; name = 'Windows-Defender-Default-Definitions'; state = 'Disabled' }
        { Restore-WinLeanOptionalFeatureResource -Resource $defender -State ([pscustomobject]@{ state = 'Enabled'; restorable = $true }) } | Should -Throw -ExpectedMessage '*protected optional feature*'
        $script:FakeFeatures.Operations.Count | Should -Be 0
    }
}

Describe 'Backup and restore with optional features' {
    BeforeEach {
        $script:FakeFeatures = New-FakeFeatureStore -Features @{ TelnetClient = 'Enabled'; SMB1Protocol = 'Enabled' }
        Register-FakeFeatureMocks
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'restores features and registry values to their exact previous state and reports the restart' {
        $initialFeatures = Get-FakeFeatureSnapshotText -Store $script:FakeFeatures
        $initialRegistry = Get-FakeRegistrySnapshot -Registry $script:FakeRegistry
        $smb = @{ fact = 'requirement.smb'; operator = 'Equals'; value = $false }
        $rules = @(
            (New-FeatureRule)
            (New-FeatureRule -Id 'features.smb1.disable' -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'SMB1Protocol'; state = 'Disabled' }) -Conditions @($smb))
            (New-TestValueRule -Id 'privacy.value.disable')
        )
        $facts = New-TestFacts -Requirements @{ developerMachine = $false; smb = $false }
        $execution = Invoke-FeatureExecution -Rules $rules -Facts $facts
        $execution.status | Should -Be 'Completed'
        $execution.summary.succeeded | Should -Be 3

        $backup = Get-WinLeanBackup -Root $script:BackupRoot -Id $execution.backupId
        @($backup.changes | ForEach-Object { $_.resource.type }) | Should -Be @('WindowsOptionalFeature', 'WindowsOptionalFeature', 'RegistryValue')
        $backup.changes[0].before.state | Should -Be 'Enabled'

        $script:FakeFeatures.RestartNeeded = $true
        $restorePlan = Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity -IsAdministrator $true)
        $result = Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_14-40-00' -Logger (New-TestLogger)
        $result.status | Should -Be 'Restored'
        $result.rebootRequired | Should -BeTrue
        Get-FakeFeatureSnapshotText -Store $script:FakeFeatures | Should -BeExactly $initialFeatures
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -BeExactly $initialRegistry
    }

    It 'blocks restoring features without Administrator rights' {
        $execution = Invoke-FeatureExecution -Rules @(New-FeatureRule)
        $script:FakeFeatures.IsAdministrator = $false
        $restorePlan = Get-WinLeanRestorePlan -Backup (Get-WinLeanBackup -Root $script:BackupRoot -Id $execution.backupId) -Identity (New-TestIdentity)
        $restorePlan.items[0].action | Should -Be 'Blocked'
        $restorePlan.items[0].requiresAdministrator | Should -BeTrue
    }
}
