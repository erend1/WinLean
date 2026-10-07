<#
    DESTRUCTIVE: toggles the Telnet Client optional feature of the Windows installation
    running the tests through DISM, verifies it, and restores the recorded state.

    Telnet Client is a small, self-contained client feature; toggling it does not affect
    other features. Requires an elevated PowerShell.

        $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'
        .\Tests\Invoke-WinLeanTests.ps1 -Suite Destructive

    Run only in a disposable VM with a checkpoint. Windows Sandbox is not a suitable
    environment for servicing changes (see Docs/VmValidation.md).
#>
BeforeDiscovery {
    $script:Allowed = $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS -eq 'YES'
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $script:IsAdministrator = ([System.Security.Principal.WindowsPrincipal]$identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Restore', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Provider.OptionalFeature', 'WinLean.Common'
}

Describe 'WindowsOptionalFeature on this Windows installation' -Tag 'Destructive' -Skip:(-not ($script:Allowed -and $script:IsAdministrator)) {
    It 'toggles Telnet Client, verifies it and restores the recorded state' {
        $initial = Get-WinLeanOptionalFeatureRecord -Name 'TelnetClient'
        @('Enabled', 'Disabled') | Should -Contain $initial.state -Because 'the feature must exist and not wait for a restart'
        $target = if ($initial.state -eq 'Enabled') { 'Disabled' } else { 'Enabled' }
        $rule = New-TestRule -Id 'features.telnet-client.toggle' -Category 'Features' -Resources @(@{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = $target }) `
            -Risk 'Medium' -Conditions @(@{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false }) -RequiresReboot $true -TakesEffect 'Reboot'
        $facts = New-TestFacts -Requirements @{ developerMachine = $false } -Build ([int](Get-WinLeanPlatform).build)
        $identity = New-TestIdentity -IsAdministrator $true
        $backupRoot = Join-Path $TestDrive 'Backups'

        $plan = New-TestPlan -Rules @($rule) -Facts $facts -IsAdministrator $true
        $plan.items[0].status | Should -Be 'Applicable'
        $execution = Invoke-WinLeanExecution -Plan $plan -Catalog (New-TestCatalog -Rules @($rule)) -BackupRoot $backupRoot -RunId '2026-09-30_15-00-00' -Logger (New-TestLogger) -Identity $identity
        $execution.status | Should -Be 'Completed' -Because (($execution.results | ForEach-Object { $_.failure.message }) -join '; ')
        Test-WinLeanOptionalFeatureStateEqual -Expected ([pscustomobject]@{ state = $target }) -Actual (Get-WinLeanOptionalFeatureRecord -Name 'TelnetClient') | Should -BeTrue

        $restorePlan = Get-WinLeanRestorePlan -Backup (Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId) -Identity $identity
        (Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_15-05-00' -Logger (New-TestLogger)).status | Should -Be 'Restored'
        Test-WinLeanOptionalFeatureStateEqual -Expected ([pscustomobject]@{ state = $initial.state }) -Actual (Get-WinLeanOptionalFeatureRecord -Name 'TelnetClient') | Should -BeTrue
    }
}
