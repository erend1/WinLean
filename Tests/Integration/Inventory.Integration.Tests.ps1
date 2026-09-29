<#
    Read-only inventory and benchmark on the current machine. Nothing is changed.
#>
BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before modules are imported.
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $script:IsAdministrator = ([System.Security.Principal.WindowsPrincipal]$identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Inventory', 'WinLean.Benchmark', 'WinLean.Compatibility', 'WinLean.Common'
    $script:Inventory = Get-WinLeanInventory -ExcludeSection 'wingetPackages'
}

Describe 'Inventory' {
    It 'records every section, available or not, with a reason' {
        foreach ($name in @(Get-WinLeanInventorySections)) {
            $section = $script:Inventory.sections.$name
            $section | Should -Not -BeNullOrEmpty -Because $name
            if (-not $section.available) {
                $section.reason | Should -BeIn @('RequiresAdministrator', 'NotInstalled', 'NotSupported', 'Skipped', 'Error') -Because $name
            }
        }
        $script:Inventory.sections.wingetPackages.reason | Should -Be 'Skipped'
    }

    It 'always collects the system facts' {
        $script:Inventory.sections.system.available | Should -BeTrue
        $script:Inventory.sections.system.data.os.build | Should -BeGreaterThan 0
    }

    It 'marks elevation-only sections instead of failing' -Skip:$script:IsAdministrator {
        $script:Inventory.sections.provisionedAppxPackages.reason | Should -Be 'RequiresAdministrator'
    }

    It 'serializes to JSON and derives capabilities' {
        $path = Join-Path $TestDrive 'inventory.json'
        Write-WinLeanJsonFile -Path $path -InputObject $script:Inventory
        $read = Read-WinLeanJsonFile -Path $path
        $read.sections.system.data.os.build | Should -Be $script:Inventory.sections.system.data.os.build
        { Get-WinLeanCapabilities -Inventory $read } | Should -Not -Throw
        $summary = Get-WinLeanInventorySummary -Inventory $read
        $summary.windows | Should -Not -BeNullOrEmpty
    }
}

Describe 'Benchmark' {
    It 'measures CPU, memory, processes and services' {
        $benchmark = Measure-WinLeanSystem -SampleCount 2 -IntervalSeconds 1
        $benchmark.cpu.sampleCount | Should -BeGreaterThan 0
        $benchmark.cpu.averagePercent | Should -BeGreaterOrEqual 0
        $benchmark.cpu.averagePercent | Should -BeLessOrEqual 100
        $benchmark.memory.totalMB | Should -BeGreaterThan 0
        $benchmark.processes.count | Should -BeGreaterThan 10
        $benchmark.services.running | Should -BeGreaterThan 10
    }
}
