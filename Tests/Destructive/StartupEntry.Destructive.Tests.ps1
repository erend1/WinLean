<#
    DESTRUCTIVE: removes and restores a disposable entry in the REAL per-user Run key
    (HKCU\Software\Microsoft\Windows\CurrentVersion\Run) of the account running the tests.

    The entry is created by the test itself and points to a program that does not exist,
    so nothing runs at sign-in even if the test is interrupted; AfterAll removes it.

        $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'
        .\Tests\Invoke-WinLeanTests.ps1 -Suite Destructive

    Run only in a disposable VM or Windows Sandbox.
#>
BeforeDiscovery {
    $script:Allowed = $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS -eq 'YES'
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Restore', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Provider.Registry', 'WinLean.Common'

    $script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $script:EntryName = 'WinLeanDestructiveTest'
    $script:Command = '"%SystemDrive%\WinLean-nonexistent\noop.exe" /test'
}

AfterAll {
    if ($env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS -eq 'YES') {
        Remove-WinLeanRegistryValue -Path $script:RunKey -Name $script:EntryName
    }
}

Describe 'StartupEntry on the real per-user Run key' -Tag 'Destructive' -Skip:(-not $script:Allowed) {
    It 'removes a disposable entry and restores it exactly' {
        Write-WinLeanRegistryValue -Path $script:RunKey -Name $script:EntryName -Kind ExpandString -Data $script:Command
        $rule = New-TestRule -Id 'startup.destructive-test.remove' -Category 'Startup' -Resources @(@{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = $script:EntryName; ensure = 'Absent' })
        $identity = New-TestIdentity
        $backupRoot = Join-Path $TestDrive 'Backups'

        $execution = Invoke-WinLeanExecution -Plan (New-TestPlan -Rules @($rule)) -Catalog (New-TestCatalog -Rules @($rule)) -BackupRoot $backupRoot `
            -RunId '2026-09-30_13-00-00' -Logger (New-TestLogger) -Identity $identity
        $execution.status | Should -Be 'Completed'
        (Read-WinLeanRegistryValue -Path $script:RunKey -Name $script:EntryName).valueExists | Should -BeFalse

        $restorePlan = Get-WinLeanRestorePlan -Backup (Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId) -Identity $identity
        (Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_13-05-00' -Logger (New-TestLogger)).status | Should -Be 'Restored'
        $raw = Read-WinLeanRegistryValue -Path $script:RunKey -Name $script:EntryName
        $raw.kind | Should -Be 'ExpandString'
        $raw.data | Should -BeExactly $script:Command
    }
}
