<#
    StartupEntry provider against the real registry API. The CurrentUserRun location is
    redirected to Pester's TestRegistry (HKCU\Software\Pester\<guid>), so the real Run key
    - and therefore what starts at sign-in - is never touched. The destructive suite covers
    the real Run key.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Restore', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Provider.Startup', 'WinLean.Provider.Registry', 'WinLean.Common'

    $root = (Get-PSDrive -Name TestRegistry).Root
    $script:Base = 'HKCU:\' + $root.Substring('HKEY_CURRENT_USER\'.Length)
    $script:RunKey = "$script:Base\Run"
    $script:StartupModule = Get-Module -Name 'WinLean.Provider.Startup'
    $script:OriginalPath = & $script:StartupModule { $script:Locations['CurrentUserRun'].Path }
    & $script:StartupModule { param($path) $script:Locations['CurrentUserRun'].Path = $path } $script:RunKey

    function New-StartupRule {
        param([hashtable] $Resource, [string] $Risk = 'Low')
        $conditions = @(if ($Risk -ne 'Low') { @{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false } })
        return New-TestRule -Id 'startup.example.remove' -Category 'Startup' -Resources @($Resource) -Risk $Risk -Conditions $conditions
    }
}

AfterAll {
    & $script:StartupModule { param($path) $script:Locations['CurrentUserRun'].Path = $path } $script:OriginalPath
}

Describe 'StartupEntry provider against the real registry' {
    It 'is redirected to the disposable test key' {
        (Get-WinLeanStartupLocations | Where-Object { $_.location -eq 'CurrentUserRun' }).path | Should -Be $script:RunKey
        $script:OriginalPath | Should -Be 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    }

    It 'removes an entry and restores its exact command and kind through backup and restore' {
        Write-WinLeanRegistryValue -Path $script:RunKey -Name 'WinLeanTestEntry' -Kind ExpandString -Data '"%LOCALAPPDATA%\WinLeanTest\none.exe" /quiet'
        $rule = New-StartupRule -Resource @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'WinLeanTestEntry'; ensure = 'Absent' }
        $backupRoot = Join-Path $TestDrive 'Backups'

        $plan = New-TestPlan -Rules @($rule)
        $plan.items[0].status | Should -Be 'Applicable'
        $execution = Invoke-WinLeanExecution -Plan $plan -Catalog (New-TestCatalog -Rules @($rule)) -BackupRoot $backupRoot `
            -RunId '2026-09-30_12-00-00' -Logger (New-TestLogger) -Identity (New-TestIdentity)
        $execution.status | Should -Be 'Completed'
        (Read-WinLeanRegistryValue -Path $script:RunKey -Name 'WinLeanTestEntry').valueExists | Should -BeFalse
        (New-TestPlan -Rules @($rule)).items[0].status | Should -Be 'AlreadySatisfied'

        $restorePlan = Get-WinLeanRestorePlan -Backup (Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId) -Identity (New-TestIdentity)
        $result = Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_12-05-00' -Logger (New-TestLogger)
        $result.status | Should -Be 'Restored'
        $raw = Read-WinLeanRegistryValue -Path $script:RunKey -Name 'WinLeanTestEntry'
        $raw.kind | Should -Be 'ExpandString'
        $raw.data | Should -BeExactly '"%LOCALAPPDATA%\WinLeanTest\none.exe" /quiet'
    }

    It 'adds an entry and removes it again, including the key it created' {
        $rule = New-StartupRule -Risk 'Medium' -Resource @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'WinLeanAdded'; ensure = 'Present'; command = 'C:\WinLeanTest\none.exe' }
        Remove-Item -LiteralPath $script:RunKey -Recurse -ErrorAction SilentlyContinue
        $before = Get-WinLeanRuleState -Rule $rule
        $before.resources[0].current.keyExists | Should -BeFalse
        [void](Set-WinLeanRuleState -Rule $rule -State $before)
        (Confirm-WinLeanRuleState -Rule $rule).verified | Should -BeTrue
        (Read-WinLeanRegistryValue -Path $script:RunKey -Name 'WinLeanAdded').kind | Should -Be 'String'

        (Undo-WinLeanRuleState -Rule $rule -BeforeState $before).restored | Should -BeTrue
        Test-WinLeanRegistryKey -Path $script:RunKey | Should -BeFalse
    }
}
