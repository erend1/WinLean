BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Policy', 'WinLean.Rules'

    function Write-ProfileFile {
        param([string] $Directory, [string] $Name, [string[]] $Rules = @(), [string[]] $Exclude = @(), $Extends = $null, [string] $MaxRisk = 'Low', [string] $FileName)
        if (-not $FileName) { $FileName = "$Name.json" }
        $definition = [ordered]@{ schemaVersion = 1; name = $Name; description = "Profile $Name"; extends = $Extends; rules = @($Rules); exclude = @($Exclude); maxRisk = $MaxRisk }
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
        Set-Content -LiteralPath (Join-Path $Directory $FileName) -Value ($definition | ConvertTo-Json -Depth 5) -Encoding utf8
    }
}

Describe 'Import-WinLeanProfile' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'resolves inheritance with parent rules first' {
        Write-ProfileFile -Directory $directory -Name 'Base' -Rules @('privacy.a.disable', 'privacy.b.disable')
        Write-ProfileFile -Directory $directory -Name 'Child' -Extends 'Base' -Rules @('privacy.c.disable', 'privacy.a.disable') -MaxRisk 'Medium'
        $profile = Import-WinLeanProfile -Name 'Child' -ProfileDirectory $directory
        $profile.ruleIds | Should -Be @('privacy.a.disable', 'privacy.b.disable', 'privacy.c.disable')
        $profile.chain | Should -Be @('Base', 'Child')
        $profile.maxRisk | Should -Be 'Medium'
    }

    It 'removes excluded inherited rules and records them' {
        Write-ProfileFile -Directory $directory -Name 'Base' -Rules @('privacy.a.disable', 'privacy.b.disable')
        Write-ProfileFile -Directory $directory -Name 'Child' -Extends 'Base' -Exclude @('privacy.a.disable')
        $profile = Import-WinLeanProfile -Name 'Child' -ProfileDirectory $directory
        $profile.ruleIds | Should -Be @('privacy.b.disable')
        $profile.excluded | Should -Be @('privacy.a.disable')
    }

    It 'accepts a path to a profile file' {
        Write-ProfileFile -Directory $directory -Name 'Solo' -Rules @('privacy.a.disable')
        (Import-WinLeanProfile -Name (Join-Path $directory 'Solo.json') -ProfileDirectory $TestDrive).name | Should -Be 'Solo'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'inheritance cycles'; Setup = { Write-ProfileFile -Directory $directory -Name 'A' -Extends 'B'; Write-ProfileFile -Directory $directory -Name 'B' -Extends 'A' }; Name = 'A'; Message = '*cycle*' }
        @{ Case = 'a missing parent'; Setup = { Write-ProfileFile -Directory $directory -Name 'A' -Extends 'Missing' }; Name = 'A'; Message = '*not found*' }
        @{ Case = 'a name that does not match the file'; Setup = { Write-ProfileFile -Directory $directory -Name 'Other' -FileName 'A.json' }; Name = 'A'; Message = '*Invalid profile*' }
        @{ Case = 'including and excluding the same rule'; Setup = { Write-ProfileFile -Directory $directory -Name 'A' -Rules @('privacy.a.disable') -Exclude @('privacy.a.disable') }; Name = 'A'; Message = '*both includes and excludes*' }
        @{ Case = 'unsafe profile names'; Setup = { }; Name = '..'; Message = '*Invalid profile name*' }
    ) {
        & $Setup
        { Import-WinLeanProfile -Name $Name -ProfileDirectory $directory } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'Test-WinLeanProfileRules' {
    It 'reports unknown rules, excessive risk and irreversible rules' {
        $low = New-TestRule -Id 'privacy.low.disable'
        $medium = New-TestRule -Id 'privacy.medium.disable' -Risk 'Medium'
        $irreversible = New-TestRule -Id 'privacy.forever.disable'
        $irreversible.reversible = $false
        $catalog = New-TestCatalog -Rules @($low, $medium, $irreversible)
        $profile = New-TestProfile -RuleIds @('privacy.low.disable', 'privacy.medium.disable', 'privacy.forever.disable', 'privacy.unknown.disable') -MaxRisk 'Low'
        $codes = @(Test-WinLeanProfileRules -Profile $profile -Catalog $catalog | ForEach-Object { $_.code })
        $codes | Should -Contain 'UnknownRule'
        $codes | Should -Contain 'RiskTooHigh'
        $codes | Should -Contain 'Irreversible'
    }
}

Describe 'Get-WinLeanDependencyOrder' {
    It 'orders dependencies first and keeps the input order otherwise' {
        $rules = @(
            New-TestRule -Id 'privacy.c.disable' -Dependencies @('privacy.b.disable')
            New-TestRule -Id 'privacy.a.disable'
            New-TestRule -Id 'privacy.b.disable' -Dependencies @('privacy.x.disable')
        )
        Get-WinLeanDependencyOrder -Rules $rules | Should -Be @('privacy.a.disable', 'privacy.b.disable', 'privacy.c.disable')
    }

    It 'throws on cycles' {
        $rules = @(
            New-TestRule -Id 'privacy.a.disable' -Dependencies @('privacy.b.disable')
            New-TestRule -Id 'privacy.b.disable' -Dependencies @('privacy.a.disable')
        )
        { Get-WinLeanDependencyOrder -Rules $rules } | Should -Throw -ExpectedMessage '*cycle*'
    }
}
