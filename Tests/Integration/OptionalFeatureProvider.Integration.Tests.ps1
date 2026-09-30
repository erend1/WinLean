<#
    WindowsOptionalFeature provider against the real servicing interfaces - READ-ONLY.
    Nothing here enables or disables a feature: state is read through Win32_OptionalFeature
    (standard users) or DISM (elevated sessions), and plans are evaluated without being
    applied. Changing a real feature is covered by the destructive suite (VM only).
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Policy', 'WinLean.Rules', 'WinLean.Provider.OptionalFeature', 'WinLean.Common'

    $script:IsAdministrator = [bool](Test-WinLeanAdministrator)
    $script:Facts = New-TestFacts -Requirements @{ developerMachine = $false }

    function New-FeatureRule {
        param([string] $Name, [string] $State)
        return New-TestRule -Id 'features.sample.set' -Category 'Features' -Resources @(@{ type = 'WindowsOptionalFeature'; name = $Name; state = $State }) `
            -Risk 'Medium' -Conditions @(@{ fact = 'requirement.developerMachine'; operator = 'Equals'; value = $false }) -RequiresReboot $true -TakesEffect 'Reboot'
    }
}

Describe 'WindowsOptionalFeature provider on this system (read-only)' {
    It 'reads the state of an existing feature consistently with Win32_OptionalFeature' {
        $candidate = @(Get-CimInstance -ClassName Win32_OptionalFeature | Where-Object { @(1, 2) -contains [int]$_.InstallState } |
                Where-Object { -not (Get-WinLeanOptionalFeatureProtectedReason -Name $_.Name -State 'Disabled') } | Select-Object -First 1)
        $candidate.Count | Should -Be 1 -Because 'every Windows installation has optional features'
        $expected = if ([int]$candidate[0].InstallState -eq 1) { 'Enabled' } else { 'Disabled' }

        $state = Get-WinLeanOptionalFeatureResourceState -Resource ([pscustomobject]@{ type = 'WindowsOptionalFeature'; name = $candidate[0].Name; state = $expected })
        $state.available | Should -BeTrue
        $state.source | Should -Be $(if ($script:IsAdministrator) { 'Dism' } else { 'Cim' })
        Test-WinLeanOptionalFeatureStateEqual -Expected ([pscustomobject]@{ state = $expected }) -Actual $state | Should -BeTrue
    }

    It 'reports a feature that is not part of this Windows image as not available' {
        $state = Get-WinLeanOptionalFeatureResourceState -Resource ([pscustomobject]@{ type = 'WindowsOptionalFeature'; name = 'WinLean-Feature-That-Does-Not-Exist'; state = 'Enabled' })
        $state.state | Should -Be 'NotPresent'
        $state.available | Should -BeFalse
    }

    It 'plans without changing anything: a missing feature is already disabled and cannot be enabled' {
        $disable = New-FeatureRule -Name 'WinLean-Feature-That-Does-Not-Exist' -State 'Disabled'
        (New-TestPlan -Rules @($disable) -Facts $script:Facts -IsAdministrator $script:IsAdministrator).items[0].status | Should -Be 'AlreadySatisfied'
        $enable = New-FeatureRule -Name 'WinLean-Feature-That-Does-Not-Exist' -State 'Enabled'
        (New-TestPlan -Rules @($enable) -Facts $script:Facts -IsAdministrator $script:IsAdministrator).items[0].status | Should -Be 'Unsupported'
    }

    It 'requires elevation to change features' {
        Test-WinLeanOptionalFeatureResourceAccess -Resource ([pscustomobject]@{ type = 'WindowsOptionalFeature'; name = 'TelnetClient'; state = 'Disabled' }) | Should -Be $script:IsAdministrator
    }

    It 'rejects names that are not feature names before querying anything' {
        { Get-WinLeanOptionalFeatureRecord -Name "x' OR Name LIKE '%" } | Should -Throw -ExpectedMessage '*Invalid optional feature name*'
    }
}
