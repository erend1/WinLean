<#
    WinLean must behave identically on every Windows display language. These tests run
    the culture-sensitive code paths under tr-TR, where the dotted/dotless i breaks
    case-insensitive comparisons that use the current culture (for example
    'WINDOWS' -like 'windows' is $false there).
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Inventory', 'WinLean.Rules', 'WinLean.Provider.Registry', 'WinLean.Common'

    $script:OriginalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
}

AfterAll {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:OriginalCulture
}

Describe 'Culture safety under tr-TR' {
    It 'runs in the Turkish culture' {
        [System.Globalization.CultureInfo]::CurrentCulture.Name | Should -Be 'tr-TR'
        'I'.ToLower() | Should -Not -Be 'i'
    }

    It 'classifies vendors regardless of case' {
        Get-WinLeanVendorClass -CompanyName 'MICROSOFT CORPORATION' | Should -Be 'Microsoft'
        Get-WinLeanVendorClass -CompanyName 'Microsoft Windows Publisher' | Should -Be 'Microsoft'
        Get-WinLeanVendorClass -CompanyName 'Intel Corporation' | Should -Be 'ThirdParty'
    }

    It 'matches text and patterns with invariant rules' {
        Test-WinLeanTextEqual -Left 'WINDOWS' -Right 'windows' | Should -BeTrue
        Test-WinLeanTextContains -Text 'SOFTWARE\POLICIES\X' -Value '\Policies\' | Should -BeTrue
        Test-WinLeanPattern -Text 'WINDOWS' -Pattern '^windows$' | Should -BeTrue
    }

    It 'parses registry paths and derives mechanisms regardless of case' {
        (ConvertFrom-WinLeanRegistryPath -Path 'hklm:\software\policies\microsoft\windows\x').hive | Should -Be 'HKLM'
        $resource = ConvertTo-WinLeanRegistryResource -Definition (ConvertTo-JsonShape -InputObject @{ type = 'RegistryValue'; path = 'HKCU:\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\EDGEIT'; name = 'ISIT'; valueType = 'DWord'; value = 1 })
        (Get-WinLeanRegistryResourceInfo -Resource $resource).mechanism | Should -Be 'Policy'
        Get-WinLeanRegistryProtectedReason -Path 'HKLM:\software\policies\microsoft\windows defender' -Name 'x' | Should -Not -BeNullOrEmpty
    }

    It 'compares edition facts case-insensitively' {
        $rule = New-TestRule -Windows @{ minBuild = 22000; maxValidatedBuild = 26200; editions = @('EnterpriseS') }
        (Test-WinLeanRuleApplicable -Rule $rule -Facts (New-TestFacts -EditionId 'ENTERPRISES')).status | Should -Be 'Applicable'
    }

    It 'formats numbers and run ids with the invariant culture' {
        Format-WinLeanNumber -Value 12.5 -Decimals 1 | Should -Be '12.5'
        New-WinLeanRunId -Time ([System.DateTimeOffset]::new(2026, 9, 27, 18, 45, 12, [TimeSpan]::Zero)) | Should -Be '2026-09-27_18-45-12'
    }
}
