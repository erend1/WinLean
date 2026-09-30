<#
    StartupEntry provider: validation, state capture, apply/verify/undo, planning and
    backup/restore - against the in-memory fake registry (the real Run keys are never
    touched).
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Executor', 'WinLean.Restore', 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Backup', 'WinLean.Validation', 'WinLean.Providers', 'WinLean.Provider.Startup', 'WinLean.Common'

    $script:UserRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $script:MachineRun = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $script:Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $script:Requirement = @{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false }

    function New-StartupRule {
        param(
            [string] $Id = 'startup.example.remove',
            [hashtable[]] $Resources = @(@{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent' }),
            [string] $Risk = 'Low',
            [object[]] $Conditions = @()
        )
        return New-TestRule -Id $Id -Category 'Startup' -Resources $Resources -Risk $Risk -Conditions $Conditions
    }

    function Get-DefinitionIssues {
        param([hashtable] $Resource, [string] $Risk = 'Low')
        $conditions = @(if ($Risk -ne 'Low') { $script:Requirement })
        $definition = New-TestRuleDefinition -Id 'startup.example.remove' -Category 'Startup' -Resources @($Resource) -Risk $Risk -Conditions $conditions
        return @(Test-WinLeanRuleDefinition -Definition $definition | ForEach-Object { $_.message })
    }
}

Describe 'StartupEntry definitions' {
    It 'accepts <Case>' -ForEach @(
        @{ Case = 'removing a per-user entry'; Risk = 'Low'; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent' } }
        @{ Case = 'removing a 32-bit machine entry'; Risk = 'Low'; Resource = @{ type = 'StartupEntry'; location = 'MachineRun32'; name = 'Vendor Tray'; ensure = 'Absent' } }
        @{ Case = 'adding an entry in a Medium risk rule'; Risk = 'Medium'; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Present'; command = '"%ProgramFiles%\Example\example.exe" /tray'; valueType = 'ExpandString' } }
    ) {
        Get-DefinitionIssues -Resource $Resource -Risk $Risk | Should -BeNullOrEmpty
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a RunOnce location'; Risk = 'Low'; Expected = "*'location' must be one of*RunOnce keys and Startup folders are not supported*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRunOnce'; name = 'Example'; ensure = 'Absent' } }
        @{ Case = 'a missing name'; Risk = 'Low'; Expected = "*'name' must be*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = ' '; ensure = 'Absent' } }
        @{ Case = 'a missing ensure'; Risk = 'Low'; Expected = "*'ensure' must be*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example' } }
        @{ Case = 'Present without a command'; Risk = 'Medium'; Expected = "*'command' must be*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Present' } }
        @{ Case = 'Absent with a command'; Risk = 'Low'; Expected = "*must be omitted*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent'; command = 'x.exe' } }
        @{ Case = 'a binary command'; Risk = 'Medium'; Expected = "*'valueType' must be one of: String, ExpandString*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Present'; command = 'x.exe'; valueType = 'Binary' } }
        @{ Case = 'an unknown property'; Risk = 'Low'; Expected = "*unknown property 'path'*"; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent'; path = 'HKCU:\x' } }
        @{ Case = 'the Windows Security entry'; Risk = 'Low'; Expected = '*protected startup entry (Windows Security notification icon)*'; Resource = @{ type = 'StartupEntry'; location = 'MachineRun'; name = 'securityhealth'; ensure = 'Absent' } }
        @{ Case = 'adding an entry in a Low risk rule'; Risk = 'Low'; Expected = '*such rules need risk Medium or higher*'; Resource = @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Present'; command = 'x.exe' } }
    ) {
        (Get-DefinitionIssues -Resource $Resource -Risk $Risk) -join "`n" | Should -BeLike $Expected
    }

    It 'routes Run and RunOnce registry values to the dedicated handling' {
        (Get-DefinitionIssues -Resource @{ type = 'RegistryValue'; path = $script:UserRun; name = 'Example'; ensure = 'Absent' }) -join "`n" |
            Should -BeLike "*startup entries are managed with the 'StartupEntry' resource type*"
        (Get-DefinitionIssues -Resource @{ type = 'RegistryValue'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; name = 'Setup'; ensure = 'Absent' }) -join "`n" |
            Should -BeLike '*RunOnce entries describe pending one-time work*'
    }

    It 'protects the undocumented StartupApproved data' {
        (Get-DefinitionIssues -Resource @{ type = 'RegistryValue'; path = $script:Approved; name = 'Example'; valueType = 'Binary'; value = '030000000000000000000000' }) -join "`n" |
            Should -BeLike '*protected registry location (Task Manager startup state*'
    }

    It 'cannot be backed by an observation alone' {
        $observation = @{ method = 'RegistryDiff'; build = 26200; file = 'Docs/Evidence/x.md'; summary = 's' }
        $definition = New-TestRuleDefinition -Id 'startup.example.remove' -Category 'Startup' -Resources @(@{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent' }) -Extra @{ references = @(); evidence = @($observation) }
        (@(Test-WinLeanRuleDefinition -Definition $definition | ForEach-Object { $_.message }) -join "`n") | Should -BeLike "*'StartupEntry' resources need a documented source*"
    }
}

Describe 'StartupEntry resources' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'describes the entry with the identity of the underlying registry value' {
        $startup = ConvertTo-WinLeanResource -Definition (ConvertTo-JsonShape @{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Absent' })
        $registry = ConvertTo-WinLeanResource -Definition (ConvertTo-JsonShape @{ type = 'RegistryValue'; path = $script:UserRun; name = 'EXAMPLE'; ensure = 'Absent' })
        $info = Get-WinLeanResourceInfo -Resource $startup
        $info.identity | Should -BeExactly (Get-WinLeanResourceInfo -Resource $registry).identity
        $info.scope | Should -Be 'CurrentUser'
        $info.mechanism | Should -Be 'Startup'
        $info.target | Should -BeLike "Startup entry 'Example' (CurrentUserRun: $script:UserRun\Example)"
        (Get-WinLeanResourceInfo -Resource (ConvertTo-WinLeanResource -Definition (ConvertTo-JsonShape @{ type = 'StartupEntry'; location = 'MachineRun32'; name = 'X'; ensure = 'Absent' }))).scope | Should -Be 'Machine'
    }

    It 'captures the command exactly, including unexpanded environment variables and the value kind' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' -Kind 'ExpandString' -Data '"%LOCALAPPDATA%\Example\example.exe" /background'
        $state = (Get-WinLeanRuleState -Rule (New-StartupRule)).resources[0]
        $state.current.valueType | Should -Be 'ExpandString'
        $state.current.value | Should -BeExactly '"%LOCALAPPDATA%\Example\example.exe" /background'
        $state.currentText | Should -BeExactly "'`"%LOCALAPPDATA%\Example\example.exe`" /background' (ExpandString)"
        $state.desiredText | Should -Be 'not present'
        $state.inDesiredState | Should -BeFalse
    }

    It 'removes an entry, verifies it and restores it exactly without touching StartupApproved' {
        $command = '"%LOCALAPPDATA%\Example\example.exe" /background'
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' -Kind 'ExpandString' -Data $command
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:Approved -Name 'Example' -Kind 'Binary' -Data ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        $initial = Get-FakeRegistrySnapshot -Registry $script:FakeRegistry
        $rule = New-StartupRule

        $before = Get-WinLeanRuleState -Rule $rule
        $applied = Set-WinLeanRuleState -Rule $rule -State $before
        $applied.changedResources | Should -Be @(0)
        Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' | Should -BeNullOrEmpty
        (Confirm-WinLeanRuleState -Rule $rule).verified | Should -BeTrue

        (Undo-WinLeanRuleState -Rule $rule -BeforeState $before).restored | Should -BeTrue
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -BeExactly $initial
        @($script:FakeRegistry.Writes | Where-Object { $_ -like '*StartupApproved*' }).Count | Should -Be 0
    }

    It 'adds an entry and removes it again on undo' {
        $rule = New-StartupRule -Id 'startup.example.add' -Risk 'Medium' -Conditions @($script:Requirement) -Resources @(@{ type = 'StartupEntry'; location = 'CurrentUserRun'; name = 'Example'; ensure = 'Present'; command = 'C:\Example\example.exe' })
        $before = Get-WinLeanRuleState -Rule $rule
        [void](Set-WinLeanRuleState -Rule $rule -State $before)
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example').Kind | Should -Be 'String'
        (Undo-WinLeanRuleState -Rule $rule -BeforeState $before).restored | Should -BeTrue
        Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' | Should -BeNullOrEmpty
        Test-FakeListMatch -List @($script:FakeRegistry.Keys.Keys) -Value $script:UserRun | Should -BeFalse -Because 'the Run key did not exist before and WinLean created it'
    }

    It 'refuses to write protected entries even when called directly' {
        $resource = ConvertTo-WinLeanStartupResource -Definition (ConvertTo-JsonShape @{ type = 'StartupEntry'; location = 'MachineRun'; name = 'SecurityHealth'; ensure = 'Absent' })
        { Set-WinLeanStartupResource -Resource $resource } | Should -Throw -ExpectedMessage '*protected startup entry*'
        { Restore-WinLeanStartupResource -Resource $resource -State ([pscustomobject]@{ valueExists = $false; keyExists = $true }) } | Should -Throw -ExpectedMessage '*protected startup entry*'
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Remove-WinLeanRegistryValue -Times 0 -Exactly
    }
}

Describe 'StartupEntry planning' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' -Kind 'String' -Data 'C:\Example\example.exe'
    }

    It 'plans the removal, then reports AlreadySatisfied once applied (idempotency)' {
        $rule = New-StartupRule
        $item = (New-TestPlan -Rules @($rule)).items[0]
        $item.status | Should -Be 'Applicable'
        $item.resources[0].currentText | Should -Be "'C:\Example\example.exe' (String)"
        [void](Set-WinLeanRuleState -Rule $rule -State (Get-WinLeanRuleState -Rule $rule))
        (New-TestPlan -Rules @($rule)).items[0].status | Should -Be 'AlreadySatisfied'
    }

    It 'blocks per-user entries when WinLean runs as another user, and machine entries without access' {
        (New-TestPlan -Rules @(New-StartupRule) -PerUserTarget 'Mismatch' -IsAdministrator $true).items[0].status | Should -Be 'Blocked'
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:MachineRun -Name 'Vendor' -Kind 'String' -Data 'C:\Vendor\tray.exe'
        $script:FakeRegistry.DeniedPaths.Add('HKLM:\SOFTWARE')
        $machine = New-StartupRule -Id 'startup.vendor.remove' -Resources @(@{ type = 'StartupEntry'; location = 'MachineRun'; name = 'Vendor'; ensure = 'Absent' })
        $item = (New-TestPlan -Rules @($machine)).items[0]
        $item.status | Should -Be 'Blocked'
        $item.requiresAdministrator | Should -BeTrue
    }

    It 'detects conflicts with registry rules for the same value across resource types' {
        $startup = New-StartupRule
        $registry = New-TestRule -Id 'privacy.example.set' -Resources @(@{ type = 'RegistryValue'; path = $script:UserRun; name = 'Example'; valueType = 'String'; value = 'C:\Other.exe' })
        $plan = New-TestPlan -Rules @($startup, $registry)
        @($plan.items | Where-Object { $_.status -eq 'Blocked' }).Count | Should -Be 2
        @(Test-WinLeanRuleCatalog -Rules @($startup, $registry) | ForEach-Object { $_.code }) | Should -Contain 'UndeclaredConflict'

        $sameEffect = New-TestRule -Id 'privacy.example.remove' -Resources @(@{ type = 'RegistryValue'; path = $script:UserRun; name = 'Example'; ensure = 'Absent' })
        @(Test-WinLeanRuleCatalog -Rules @($startup, $sameEffect)).Count | Should -Be 0
    }
}

Describe 'Backup and restore with several resource types' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'applies a startup rule and a registry rule, then restores the exact previous state' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' -Kind 'ExpandString' -Data '%ProgramFiles%\Example\example.exe'
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path 'HKCU:\Software\WinLeanTest\Engine' -Name 'Value' -Kind 'DWord' -Data 0
        $initial = Get-FakeRegistrySnapshot -Registry $script:FakeRegistry
        $rules = @((New-StartupRule), (New-TestValueRule -Id 'privacy.value.disable'))
        $backupRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))

        $execution = Invoke-WinLeanExecution -Plan (New-TestPlan -Rules $rules) -Catalog (New-TestCatalog -Rules $rules) -BackupRoot $backupRoot `
            -RunId '2026-09-30_11-00-00' -Logger (New-TestLogger) -Identity (New-TestIdentity)
        $execution.status | Should -Be 'Completed'
        $execution.summary.succeeded | Should -Be 2
        Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' | Should -BeNullOrEmpty

        $backup = Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId
        @($backup.changes | ForEach-Object { $_.resource.type }) | Should -Be @('StartupEntry', 'RegistryValue')
        $backup.changes[0].before.valueType | Should -Be 'ExpandString'

        $restorePlan = Get-WinLeanRestorePlan -Backup $backup -Identity (New-TestIdentity)
        @($restorePlan.items | ForEach-Object { $_.action }) | Should -Be @('Restore', 'Restore')
        $result = Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_11-05-00' -Logger (New-TestLogger)
        $result.status | Should -Be 'Restored'
        Get-FakeRegistrySnapshot -Registry $script:FakeRegistry | Should -BeExactly $initial
    }

    It 'leaves an entry alone that was re-added with another command after WinLean removed it' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' -Kind 'String' -Data 'C:\Old.exe'
        $rules = @(New-StartupRule)
        $backupRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $execution = Invoke-WinLeanExecution -Plan (New-TestPlan -Rules $rules) -Catalog (New-TestCatalog -Rules $rules) -BackupRoot $backupRoot `
            -RunId '2026-09-30_11-10-00' -Logger (New-TestLogger) -Identity (New-TestIdentity)
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example' -Kind 'String' -Data 'C:\New.exe'

        $restorePlan = Get-WinLeanRestorePlan -Backup (Get-WinLeanBackup -Root $backupRoot -Id $execution.backupId) -Identity (New-TestIdentity)
        $restorePlan.items[0].action | Should -Be 'Skip'
        [void](Invoke-WinLeanRestorePlan -RestorePlan $restorePlan -RunId '2026-09-30_11-15-00' -Logger (New-TestLogger))
        (Get-FakeRegistryValue -Registry $script:FakeRegistry -Path $script:UserRun -Name 'Example').Data | Should -Be 'C:\New.exe'
    }
}
