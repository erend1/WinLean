BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Common'

    function New-ValueRule {
        param([string] $Id, [string] $Name = 'Value', [int] $Value = 1, [string] $Path = 'HKCU:\Software\WinLeanTest\Plan', [hashtable] $Extra = @{})
        $parameters = @{ Id = $Id; Resources = @(@{ type = 'RegistryValue'; path = $Path; name = $Name; valueType = 'DWord'; value = $Value }) }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        return New-TestRule @parameters
    }

    function Invoke-Plan {
        param([object[]] $Rules, [string[]] $RuleIds, $Facts = (New-TestFacts), [bool] $IsAdministrator = $false, [string] $PerUserTarget = 'Match', [switch] $AllowUntestedBuild)
        if (-not $RuleIds) { $RuleIds = @($Rules | ForEach-Object { $_.id }) }
        $context = New-WinLeanPlanContext -Facts $Facts -IsAdministrator $IsAdministrator -PerUserTarget $PerUserTarget -UserName 'TEST\user' -AllowUntestedBuild:$AllowUntestedBuild
        return New-WinLeanPlan -Profile (New-TestProfile -RuleIds $RuleIds) -Catalog (New-TestCatalog -Rules $Rules) -Context $context
    }

    function Get-PlanItem {
        param($Plan, [string] $Id)
        return $Plan.items | Where-Object { $_.ruleId -eq $Id }
    }
}

Describe 'New-WinLeanPlan' {
    BeforeEach {
        $script:FakeRegistry = New-FakeRegistry
        Register-FakeRegistryMocks
    }

    It 'distinguishes Applicable and AlreadySatisfied' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path 'HKCU:\Software\WinLeanTest\Plan' -Name 'Done' -Kind 'DWord' -Data 1
        $plan = Invoke-Plan -Rules @((New-ValueRule -Id 'privacy.todo.disable' -Name 'Todo'), (New-ValueRule -Id 'privacy.done.disable' -Name 'Done'))
        (Get-PlanItem $plan 'privacy.todo.disable').status | Should -Be 'Applicable'
        (Get-PlanItem $plan 'privacy.done.disable').status | Should -Be 'AlreadySatisfied'
        $plan.summary.counts.Applicable | Should -Be 1
        $plan.summary.counts.AlreadySatisfied | Should -Be 1
    }

    It 'never writes to the registry' {
        [void](Invoke-Plan -Rules @(New-ValueRule -Id 'privacy.todo.disable'))
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Write-WinLeanRegistryValue -Times 0 -Exactly
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Remove-WinLeanRegistryValue -Times 0 -Exactly
    }

    It 'skips rules with unmet or undeclared compatibility conditions' {
        $rule = New-ValueRule -Id 'privacy.printer.disable' -Extra @{ Conditions = @(@{ fact = 'requirement.printer'; operator = 'Equals'; value = $false }) }
        (Get-PlanItem (Invoke-Plan -Rules @($rule)) 'privacy.printer.disable').status | Should -Be 'Skipped'
        (Get-PlanItem (Invoke-Plan -Rules @($rule) -Facts (New-TestFacts -Requirements @{ printer = $true })) 'privacy.printer.disable').status | Should -Be 'Skipped'
        (Get-PlanItem (Invoke-Plan -Rules @($rule) -Facts (New-TestFacts -Requirements @{ printer = $false })) 'privacy.printer.disable').status | Should -Be 'Applicable'
    }

    It 'marks unsupported editions and builds Unsupported without reading state' {
        $rule = New-ValueRule -Id 'privacy.enterprise.disable' -Extra @{ Windows = @{ minBuild = 22000; maxValidatedBuild = 26200; editions = @('Enterprise') } }
        $item = Get-PlanItem (Invoke-Plan -Rules @($rule)) 'privacy.enterprise.disable'
        $item.status | Should -Be 'Unsupported'
        $item.reasons[0] | Should -BeLike "*this system is 'Professional'*"
        Should -Invoke -ModuleName 'WinLean.Provider.Registry' -CommandName Read-WinLeanRegistryValue -Times 0 -Exactly
    }

    It 'requires confirmation on builds newer than the validated build' {
        $rule = New-ValueRule -Id 'privacy.new.disable' -Extra @{ Windows = @{ minBuild = 22000; maxValidatedBuild = 26100 } }
        $item = Get-PlanItem (Invoke-Plan -Rules @($rule)) 'privacy.new.disable'
        $item.status | Should -Be 'RequiresConfirmation'
        $item.reasons[0] | Should -BeLike '*-AllowUntestedBuild*'
        $allowed = Get-PlanItem (Invoke-Plan -Rules @($rule) -AllowUntestedBuild) 'privacy.new.disable'
        $allowed.status | Should -Be 'Applicable'
        $allowed.notes[0] | Should -BeLike '*-AllowUntestedBuild was specified*'
    }

    It 'blocks rules without write access and asks for elevation when not elevated' {
        $script:FakeRegistry.DeniedPaths.Add('HKLM:\SOFTWARE\Policies')
        $rule = New-ValueRule -Id 'privacy.machine.disable' -Path 'HKLM:\SOFTWARE\Policies\WinLeanTest'
        $item = Get-PlanItem (Invoke-Plan -Rules @($rule)) 'privacy.machine.disable'
        $item.status | Should -Be 'Blocked'
        $item.requiresAdministrator | Should -BeTrue
        $item.reasons[0] | Should -BeLike 'Requires Administrator*'
        $elevated = Get-PlanItem (Invoke-Plan -Rules @($rule) -IsAdministrator $true) 'privacy.machine.disable'
        $elevated.requiresAdministrator | Should -BeFalse
        $elevated.reasons[0] | Should -BeLike '*even with Administrator rights*'
    }

    It 'does not require write access for rules that are already satisfied' {
        $script:FakeRegistry.DeniedPaths.Add('HKLM:\SOFTWARE\Policies')
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path 'HKLM:\SOFTWARE\Policies\WinLeanTest' -Name 'Value' -Kind 'DWord' -Data 1
        $rule = New-ValueRule -Id 'privacy.machine.disable' -Path 'HKLM:\SOFTWARE\Policies\WinLeanTest'
        (Get-PlanItem (Invoke-Plan -Rules @($rule)) 'privacy.machine.disable').status | Should -Be 'AlreadySatisfied'
    }

    It 'blocks both rules of a declared conflict' {
        $plan = Invoke-Plan -Rules @(
            (New-ValueRule -Id 'privacy.left.disable' -Name 'Left' -Extra @{ Conflicts = @('privacy.right.disable') })
            (New-ValueRule -Id 'privacy.right.disable' -Name 'Right')
        )
        (Get-PlanItem $plan 'privacy.left.disable').status | Should -Be 'Blocked'
        (Get-PlanItem $plan 'privacy.right.disable').status | Should -Be 'Blocked'
    }

    It 'blocks rules that set the same value differently even without a declaration' {
        $plan = Invoke-Plan -Rules @((New-ValueRule -Id 'privacy.zero.set' -Value 0), (New-ValueRule -Id 'privacy.one.set' -Value 1))
        (Get-PlanItem $plan 'privacy.zero.set').reasons[0] | Should -BeLike '*sets HKCU:\Software\WinLeanTest\Plan\Value to a different value*'
        $plan.summary.counts.Blocked | Should -Be 2
    }

    It 'ignores conflicts with rules that do not apply' {
        $skipped = New-ValueRule -Id 'privacy.zero.set' -Value 0 -Extra @{ Conditions = @(@{ fact = 'requirement.printer'; operator = 'Equals'; value = $false }) }
        $plan = Invoke-Plan -Rules @($skipped, (New-ValueRule -Id 'privacy.one.set' -Value 1))
        (Get-PlanItem $plan 'privacy.one.set').status | Should -Be 'Applicable'
    }

    It 'orders dependencies first and blocks dependents of blocked rules' {
        $script:FakeRegistry.DeniedPaths.Add('HKLM:\SOFTWARE\Policies')
        $base = New-ValueRule -Id 'privacy.base.disable' -Path 'HKLM:\SOFTWARE\Policies\WinLeanTest'
        $dependent = New-ValueRule -Id 'privacy.dependent.disable' -Name 'Dependent' -Extra @{ Dependencies = @('privacy.base.disable') }
        $plan = Invoke-Plan -Rules @($dependent, $base) -RuleIds @('privacy.dependent.disable', 'privacy.base.disable')
        $plan.items[0].ruleId | Should -Be 'privacy.base.disable'
        (Get-PlanItem $plan 'privacy.dependent.disable').status | Should -Be 'Blocked'
        (Get-PlanItem $plan 'privacy.dependent.disable').reasons[0] | Should -Be "Dependency 'privacy.base.disable' is Blocked."
    }

    It 'accepts dependencies outside the profile only when they are already satisfied' {
        $base = New-ValueRule -Id 'privacy.base.disable' -Name 'Base'
        $dependent = New-ValueRule -Id 'privacy.dependent.disable' -Name 'Dependent' -Extra @{ Dependencies = @('privacy.base.disable') }
        $plan = Invoke-Plan -Rules @($dependent, $base) -RuleIds @('privacy.dependent.disable')
        (Get-PlanItem $plan 'privacy.dependent.disable').status | Should -Be 'Blocked'

        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path 'HKCU:\Software\WinLeanTest\Plan' -Name 'Base' -Kind 'DWord' -Data 1
        $plan = Invoke-Plan -Rules @($dependent, $base) -RuleIds @('privacy.dependent.disable')
        $item = Get-PlanItem $plan 'privacy.dependent.disable'
        $item.status | Should -Be 'Applicable'
        $item.notes[0] | Should -BeLike '*already satisfied*'
    }

    It 'blocks per-user rules, but not machine rules, when WinLean runs as another user' {
        $user = New-ValueRule -Id 'privacy.user.disable'
        $machine = New-ValueRule -Id 'privacy.machine.disable' -Path 'HKLM:\SOFTWARE\WinLeanTest'
        $plan = Invoke-Plan -Rules @($user, $machine) -PerUserTarget 'Mismatch' -IsAdministrator $true
        (Get-PlanItem $plan 'privacy.user.disable').status | Should -Be 'Blocked'
        (Get-PlanItem $plan 'privacy.machine.disable').status | Should -Be 'Applicable'
    }

    It 'blocks rules whose current value cannot be captured losslessly' {
        Set-FakeRegistryValue -Registry $script:FakeRegistry -Path 'HKCU:\Software\WinLeanTest\Plan' -Name 'Value' -Kind 'None' -Data ([byte[]](1))
        $item = Get-PlanItem (Invoke-Plan -Rules @(New-ValueRule -Id 'privacy.odd.disable')) 'privacy.odd.disable'
        $item.status | Should -Be 'Blocked'
        $item.reasons[0] | Should -BeLike '*cannot be captured losslessly*'
    }

    It 'blocks rules whose state cannot be read' {
        $script:FakeRegistry.ReadFailures.Add('HKCU:\Software\WinLeanTest\Plan\Value')
        $item = Get-PlanItem (Invoke-Plan -Rules @(New-ValueRule -Id 'privacy.unreadable.disable')) 'privacy.unreadable.disable'
        $item.status | Should -Be 'Blocked'
        $item.reasons[0] | Should -BeLike '*could not be read*'
    }

    It 'rejects profiles with unknown rules' {
        $context = New-WinLeanPlanContext -Facts (New-TestFacts) -IsAdministrator $false
        { New-WinLeanPlan -Profile (New-TestProfile -RuleIds @('privacy.unknown.disable')) -Catalog (New-TestCatalog -Rules @()) -Context $context } |
            Should -Throw -ExpectedMessage '*unknown rules*'
    }

    It 'summarizes reboot and sign-out needs and warns on domain-joined devices' {
        $reboot = New-ValueRule -Id 'privacy.reboot.disable' -Name 'Reboot' -Extra @{ RequiresReboot = $true; TakesEffect = 'Reboot' }
        $policy = New-ValueRule -Id 'privacy.policy.disable' -Name 'Policy' -Path 'HKCU:\Software\Policies\WinLeanTest' -Extra @{ TakesEffect = 'SignOut' }
        $plan = Invoke-Plan -Rules @($reboot, $policy) -Facts (New-TestFacts -PartOfDomain $true)
        $plan.summary.rebootRequired | Should -BeTrue
        $plan.summary.signOutRecommended | Should -BeTrue
        $plan.warnings | Should -Contain 'This device is joined to a domain. Organizational Group Policy may override or conflict with policy-based settings.'
    }

    It 'counts the benefits of applicable rules and notes Medium risk rules not yet validated in a VM' {
        $condition = @{ fact = 'requirement.printer'; operator = 'Equals'; value = $false }
        $medium = New-ValueRule -Id 'privacy.medium.disable' -Name 'Medium' -Extra @{ Risk = 'Medium'; Conditions = @($condition) }
        $low = New-ValueRule -Id 'privacy.low.disable' -Name 'Low'
        $plan = Invoke-Plan -Rules @($medium, $low) -Facts (New-TestFacts -Requirements @{ printer = $false })
        $plan.summary.benefits.Privacy | Should -Be 2
        (Get-PlanItem $plan 'privacy.medium.disable').notes[0] | Should -BeLike '*has not been applied and restored in a disposable VM yet*'
        @((Get-PlanItem $plan 'privacy.low.disable').notes).Count | Should -Be 0
        (Get-PlanItem $plan 'privacy.low.disable').lastValidated | Should -Be '2026-09-28'
    }

    It 'produces a plan that survives JSON serialization' {
        $plan = Invoke-Plan -Rules @(New-ValueRule -Id 'privacy.todo.disable')
        $json = $plan | ConvertTo-Json -Depth 30
        $read = $json | ConvertFrom-Json
        $read.items[0].status | Should -Be 'Applicable'
        $read.items[0].resources[0].desired.value | Should -Be 1
    }
}
