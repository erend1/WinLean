BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Common'

    $script:Key = 'HKCU:\Software\WinLeanTest\Engine'

    function Invoke-TestExecution {
        param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] [object[]] $Rules, [string] $BackupRoot = (Join-Path $TestDrive 'Backups'), [string] $RunId = '2026-09-27_18-45-12')
        $script:Logger = New-TestLogger
        return Invoke-WinLeanExecution -Plan $Plan -Catalog (New-TestCatalog -Rules $Rules) -BackupRoot $BackupRoot -RunId $RunId -Logger $script:Logger -Identity (New-TestIdentity)
    }

    function Get-Result {
        param($Execution, [string] $Id)
        return $Execution.results | Where-Object { $_.ruleId -eq $Id }
    }
}

Describe 'Invoke-WinLeanExecution' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
        $backupRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'backs up, applies and verifies every applicable rule' {
        $rules = @((New-TestValueRule -Id 'privacy.a.disable' -Name 'A'), (New-TestValueRule -Id 'privacy.b.disable' -Name 'B' -ValueType 'String' -Value 'on'))
        $execution = Invoke-TestExecution -Plan (New-TestPlan -Rules $rules) -Rules $rules -BackupRoot $backupRoot

        $execution.status | Should -Be 'Completed'
        $execution.summary.succeeded | Should -Be 2
        $execution.summary.changed | Should -Be 2
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'A').Data | Should -Be 1
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'B').Data | Should -Be 'on'

        $backup = Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId
        $backup.manifest.status | Should -Be 'Completed'
        $backup.manifest.changedRuleCount | Should -Be 2
        @($backup.changes).Count | Should -Be 2
        $backup.changes[0].before.valueExists | Should -BeFalse
        $backup.execution.status | Should -Be 'Completed'
    }

    It 'writes the backup before the first change' {
        $rules = @(New-TestValueRule -Id 'privacy.a.disable')
        [void](Invoke-TestExecution -Plan (New-TestPlan -Rules $rules) -Rules $rules -BackupRoot $backupRoot)
        $messages = @($script:Logger.Entries | ForEach-Object { "$($_.tag) $($_.message)" })
        $backupIndex = [array]::FindIndex([string[]]$messages, [Predicate[string]] { param($m) $m.StartsWith('INFO Backup created') })
        $applyIndex = [array]::FindIndex([string[]]$messages, [Predicate[string]] { param($m) $m.StartsWith('APPLY ') })
        $backupIndex | Should -BeGreaterOrEqual 0
        $applyIndex | Should -BeGreaterThan $backupIndex
    }

    It 'is idempotent: a second run changes nothing and creates no backup' {
        $rules = @(New-TestValueRule -Id 'privacy.a.disable')
        [void](Invoke-TestExecution -Plan (New-TestPlan -Rules $rules) -Rules $rules -BackupRoot $backupRoot)
        $writes = $script:FakeRegistry.Writes.Count

        $secondPlan = New-TestPlan -Rules $rules
        $secondPlan.summary.counts.AlreadySatisfied | Should -Be 1
        $second = Invoke-TestExecution -Plan $secondPlan -Rules $rules -BackupRoot $backupRoot -RunId '2026-09-27_18-50-00'
        $second.status | Should -Be 'NoChanges'
        $second.backupId | Should -BeNullOrEmpty
        $script:FakeRegistry.Writes.Count | Should -Be $writes
        @(Get-ChildItem -LiteralPath $backupRoot -Directory).Count | Should -Be 1
    }

    It 'treats rules satisfied since planning as AlreadySatisfied' {
        $rules = @(New-TestValueRule -Id 'privacy.a.disable')
        $plan = New-TestPlan -Rules $rules
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Value' -Kind 'DWord' -Data 1
        $execution = Invoke-TestExecution -Plan $plan -Rules $rules -BackupRoot $backupRoot
        (Get-Result $execution 'privacy.a.disable').status | Should -Be 'AlreadySatisfied'
        $execution.status | Should -Be 'NoChanges'
    }

    It 'fails and rolls back a rule whose verification fails, and continues with other rules' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'X' -Kind 'DWord' -Data 0
        $script:FakeRegistry.StickyValues.Add("$script:Key\Y")
        $failing = New-TestRule -Id 'privacy.failing.disable' -Resources @(
            @{ type = 'RegistryValue'; path = $script:Key; name = 'X'; valueType = 'DWord'; value = 1 }
            @{ type = 'RegistryValue'; path = $script:Key; name = 'Y'; valueType = 'DWord'; value = 1 }
        )
        $other = New-TestValueRule -Id 'privacy.other.disable' -Name 'Other'
        $execution = Invoke-TestExecution -Plan (New-TestPlan -Rules @($failing, $other)) -Rules @($failing, $other) -BackupRoot $backupRoot

        $result = Get-Result $execution 'privacy.failing.disable'
        $result.status | Should -Be 'Failed'
        $result.failure.class | Should -Be 'VerificationFailed'
        $result.rollback.restored | Should -BeTrue
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'X').Data | Should -Be 0
        (Get-Result $execution 'privacy.other.disable').status | Should -Be 'Succeeded'
        $execution.status | Should -Be 'CompletedWithFailures'
    }

    It 'rolls back values already written when a later write fails' {
        $script:FakeRegistry.FailingValues.Add("$script:Key\Second")
        $rule = New-TestRule -Id 'privacy.partial.disable' -Resources @(
            @{ type = 'RegistryValue'; path = $script:Key; name = 'First'; valueType = 'DWord'; value = 1 }
            @{ type = 'RegistryValue'; path = $script:Key; name = 'Second'; valueType = 'DWord'; value = 1 }
        )
        $execution = Invoke-TestExecution -Plan (New-TestPlan -Rules @($rule)) -Rules @($rule) -BackupRoot $backupRoot
        $result = Get-Result $execution 'privacy.partial.disable'
        $result.failure.class | Should -Be 'CommandFailed'
        $result.rollback.restored | Should -BeTrue
        Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'First' | Should -BeNullOrEmpty
    }

    It 'does not attempt rules that lost write access after planning' {
        $rule = New-TestValueRule -Id 'privacy.denied.disable'
        $plan = New-TestPlan -Rules @($rule)
        $script:FakeRegistry.DeniedPaths.Add('HKCU:\Software\WinLeanTest')
        $execution = Invoke-TestExecution -Plan $plan -Rules @($rule) -BackupRoot $backupRoot
        (Get-Result $execution 'privacy.denied.disable').failure.class | Should -Be 'PermissionDenied'
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Write-WinLeanRegistryValue -Times 0 -Exactly
    }

    It 'does not apply rules whose dependency failed' {
        $script:FakeRegistry.StickyValues.Add("$script:Key\Base")
        $base = New-TestValueRule -Id 'privacy.base.disable' -Name 'Base'
        $dependent = New-TestValueRule -Id 'privacy.dependent.disable' -Name 'Dependent' -Extra @{ Dependencies = @('privacy.base.disable') }
        $execution = Invoke-TestExecution -Plan (New-TestPlan -Rules @($base, $dependent)) -Rules @($base, $dependent) -BackupRoot $backupRoot
        (Get-Result $execution 'privacy.dependent.disable').failure.class | Should -Be 'DependencyFailure'
        Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Dependent' | Should -BeNullOrEmpty
    }

    It 'changes nothing when the backup cannot be written' {
        $blocker = Join-Path $TestDrive 'not-a-directory'
        Set-Content -LiteralPath $blocker -Value 'file'
        $rules = @(New-TestValueRule -Id 'privacy.a.disable')
        $execution = Invoke-TestExecution -Plan (New-TestPlan -Rules $rules) -Rules $rules -BackupRoot $blocker
        $execution.status | Should -Be 'Aborted'
        (Get-Result $execution 'privacy.a.disable').failure.class | Should -Be 'BackupFailed'
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Write-WinLeanRegistryValue -Times 0 -Exactly
    }

    It 'returns structured results with before and after state' {
        $rules = @(New-TestValueRule -Id 'privacy.a.disable')
        $result = Get-Result (Invoke-TestExecution -Plan (New-TestPlan -Rules $rules) -Rules $rules -BackupRoot $backupRoot) 'privacy.a.disable'
        $result.changed | Should -BeTrue
        $result.rebootRequired | Should -BeFalse
        $result.before[0].text | Should -Be 'not set (key missing)'
        $result.after[0].text | Should -Be '1 (DWord)'
        $result.failure | Should -BeNullOrEmpty
    }
}
