BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Restore', 'WinLean.Executor', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Common'

    $script:Key = 'HKCU:\Software\WinLeanTest\Engine'

    function New-DecisionChange {
        param([string] $Scope = 'CurrentUser', [bool] $BeforeRestorable = $true)
        return [pscustomobject]@{
            resource = [pscustomobject]@{ type = 'RegistryValue'; path = $script:Key; name = 'V'; ensure = 'Present'; valueType = 'DWord'; value = 1 }
            scope    = $Scope
            before   = [pscustomobject]@{ keyExists = $true; valueExists = $true; valueType = 'DWord'; value = 0; restorable = $BeforeRestorable; missingKeyRoot = $null }
            desired  = [pscustomobject]@{ valueExists = $true; valueType = 'DWord'; value = 1 }
        }
    }

    function New-Current {
        param($Value)
        if ($null -eq $Value) { return [pscustomobject]@{ keyExists = $true; valueExists = $false; valueType = $null; value = $null } }
        return [pscustomobject]@{ keyExists = $true; valueExists = $true; valueType = 'DWord'; value = $Value }
    }

    function Invoke-ApplyAndGetBackup {
        param([object[]] $Rules, [string] $Root)
        $execution = Invoke-WinLeanExecution -Plan (New-TestPlan -Rules $Rules) -Catalog (New-TestCatalog -Rules $Rules) -BackupRoot $Root -RunId '2026-09-27_18-45-12' -Logger (New-TestLogger) -Identity (New-TestIdentity)
        return Get-WinLeanBackup -Root $Root -Id $execution.backupId
    }
}

Describe 'Get-WinLeanRestoreDecision' {
    It 'decides <Expected> when <Case>' -ForEach @(
        @{ Case = 'the value already has its previous value'; Current = 0; Scope = 'CurrentUser'; SameUser = $true; Writable = $true; BeforeRestorable = $true; Force = $false; Expected = 'None' }
        @{ Case = 'the value still holds what WinLean wrote'; Current = 1; Scope = 'CurrentUser'; SameUser = $true; Writable = $true; BeforeRestorable = $true; Force = $false; Expected = 'Restore' }
        @{ Case = 'the value changed after WinLean applied it'; Current = 5; Scope = 'CurrentUser'; SameUser = $true; Writable = $true; BeforeRestorable = $true; Force = $false; Expected = 'Skip' }
        @{ Case = 'a changed value is restored with -Force'; Current = 5; Scope = 'CurrentUser'; SameUser = $true; Writable = $true; BeforeRestorable = $true; Force = $true; Expected = 'Restore' }
        @{ Case = 'another user recorded a per-user value'; Current = 1; Scope = 'CurrentUser'; SameUser = $false; Writable = $true; BeforeRestorable = $true; Force = $false; Expected = 'Blocked' }
        @{ Case = 'another user recorded a machine value'; Current = 1; Scope = 'Machine'; SameUser = $false; Writable = $true; BeforeRestorable = $true; Force = $false; Expected = 'Restore' }
        @{ Case = 'the value cannot be written'; Current = 1; Scope = 'CurrentUser'; SameUser = $true; Writable = $false; BeforeRestorable = $true; Force = $false; Expected = 'Blocked' }
        @{ Case = 'the recorded value cannot be written back'; Current = 1; Scope = 'CurrentUser'; SameUser = $true; Writable = $true; BeforeRestorable = $false; Force = $false; Expected = 'Blocked' }
        @{ Case = 'a value WinLean removed must come back'; Current = $null; Scope = 'CurrentUser'; SameUser = $true; Writable = $true; BeforeRestorable = $true; Force = $false; Expected = 'Skip' }
    ) {
        $decision = Get-WinLeanRestoreDecision -Change (New-DecisionChange -Scope $Scope -BeforeRestorable $BeforeRestorable) -Current (New-Current -Value $Current) -SameUser $SameUser -Writable $Writable -Force:$Force
        $decision.action | Should -Be $Expected
    }

    It 'asks for elevation only when not elevated' {
        $change = New-DecisionChange
        (Get-WinLeanRestoreDecision -Change $change -Current (New-Current 1) -Writable $false).requiresAdministrator | Should -BeTrue
        (Get-WinLeanRestoreDecision -Change $change -Current (New-Current 1) -Writable $false -IsAdministrator $true).requiresAdministrator | Should -BeFalse
    }
}

Describe 'Restore with the fake registry' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Existing' -Kind 'DWord' -Data 0
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Gone' -Kind 'String' -Data 'keep me'
        $rules = @(
            New-TestRule -Id 'privacy.values.disable' -Resources @(
                @{ type = 'RegistryValue'; path = $script:Key; name = 'Existing'; valueType = 'DWord'; value = 1 }
                @{ type = 'RegistryValue'; path = $script:Key; name = 'Gone'; ensure = 'Absent' }
            )
            New-TestValueRule -Id 'privacy.newkey.disable' -Name 'Deep' -Path "$script:Key\New\Deep" -ValueType 'MultiString' -Value @('a', 'b')
        )
        $script:Original = Get-FakeRegistrySnapshot -Registry $script:FakeRegistry
    }

    It 'restores the exact previous state, including deleted values and created keys' {
        $backup = Invoke-ApplyAndGetBackup -Rules $rules -Root $root
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -Not -Be $script:Original

        $plan = Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)
        @($plan.items).Count | Should -Be 3
        $plan.items[0].sequence | Should -BeGreaterThan $plan.items[2].sequence
        $plan.summary.Restore | Should -Be 3

        $result = Invoke-WinLeanRestorePlan -RestorePlan $plan -RunId '2026-09-27_19-00-00' -Logger (New-TestLogger)
        $result.status | Should -Be 'Restored'
        $result.summary.Restored | Should -Be 3
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -BeExactly $script:Original

        $manifest = Read-WinLeanJsonFile -Path (Join-Path $backup.path 'manifest.json')
        $manifest.restore.status | Should -Be 'Restored'
        Test-Path -LiteralPath (Join-Path $backup.path 'restore-2026-09-27_19-00-00.json') | Should -BeTrue
        { Resolve-WinLeanBackupId -Root $root -Id 'Latest' } | Should -Throw
    }

    It 'is idempotent: restoring again changes nothing' {
        $backup = Invoke-ApplyAndGetBackup -Rules $rules -Root $root
        [void](Invoke-WinLeanRestorePlan -RestorePlan (Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)) -RunId 'r1' -Logger (New-TestLogger))
        $writes = $script:FakeRegistry.Writes.Count
        $again = Invoke-WinLeanRestorePlan -RestorePlan (Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)) -RunId 'r2' -Logger (New-TestLogger)
        $again.summary.NotNeeded | Should -Be 3
        $script:FakeRegistry.Writes.Count | Should -Be $writes
    }

    It 'leaves values that changed after apply alone unless -Force is used' {
        $backup = Invoke-ApplyAndGetBackup -Rules $rules -Root $root
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Existing' -Kind 'DWord' -Data 7

        $result = Invoke-WinLeanRestorePlan -RestorePlan (Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)) -RunId 'r1' -Logger (New-TestLogger)
        $result.status | Should -Be 'RestoredWithSkips'
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Existing').Data | Should -Be 7

        $forced = Invoke-WinLeanRestorePlan -RestorePlan (Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity) -Force) -RunId 'r2' -Logger (New-TestLogger)
        $forced.status | Should -Be 'Restored'
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -BeExactly $script:Original
    }

    It 're-checks each value immediately before restoring it' {
        $backup = Invoke-ApplyAndGetBackup -Rules $rules -Root $root
        $plan = Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Existing' -Kind 'DWord' -Data 9
        $result = Invoke-WinLeanRestorePlan -RestorePlan $plan -RunId 'r1' -Logger (New-TestLogger)
        ($result.results | Where-Object { $_.target -like '*\Existing' }).status | Should -Be 'Skipped'
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Key -Name 'Existing').Data | Should -Be 9
    }

    It 'reports failures and keeps the backup eligible for another restore' {
        $backup = Invoke-ApplyAndGetBackup -Rules $rules -Root $root
        $script:FakeRegistry.FailingValues.Add("$script:Key\Existing")
        $result = Invoke-WinLeanRestorePlan -RestorePlan (Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)) -RunId 'r1' -Logger (New-TestLogger)
        $result.status | Should -Be 'Incomplete'
        $result.summary.Failed | Should -Be 1
        Resolve-WinLeanBackupId -Root $root -Id 'Latest' | Should -Be $backup.id
    }

    It 'blocks per-user values recorded by another account' {
        $backup = Invoke-ApplyAndGetBackup -Rules $rules -Root $root
        $otherUser = New-TestIdentity -Name 'TEST\other' -Sid 'S-1-5-21-1000-1000-1000-2002'
        $plan = Get-WinLeanRestorePlan -Backup $backup -Identity $otherUser
        $plan.sameUser | Should -BeFalse
        $plan.summary.Blocked | Should -Be 3
    }
}
