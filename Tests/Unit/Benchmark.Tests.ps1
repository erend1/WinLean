BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Benchmark'
}

Describe 'CPU calculation' {
    It 'computes busy percent from raw idle and time counters' {
        $previous = [pscustomobject]@{ idle = [uint64]1000; timestamp = [uint64]10000 }
        $current = [pscustomobject]@{ idle = [uint64]1750; timestamp = [uint64]11000 }
        Get-WinLeanCpuBusyPercent -Previous $previous -Current $current | Should -Be 25
    }

    It 'clamps to 0..100 and rejects samples that cannot be compared' {
        $previous = [pscustomobject]@{ idle = [uint64]0; timestamp = [uint64]100 }
        Get-WinLeanCpuBusyPercent -Previous $previous -Current ([pscustomobject]@{ idle = [uint64]200; timestamp = [uint64]200 }) | Should -Be 0
        Get-WinLeanCpuBusyPercent -Previous $previous -Current ([pscustomobject]@{ idle = [uint64]10; timestamp = [uint64]100 }) | Should -BeNullOrEmpty
    }
}

Describe 'Statistics' {
    It 'computes average, median, minimum and maximum with one decimal' {
        $statistics = Get-WinLeanStatistics -Values @(3.0, 1.0, 2.0)
        $statistics.average | Should -Be 2
        $statistics.median | Should -Be 2
        $statistics.minimum | Should -Be 1
        $statistics.maximum | Should -Be 3
        (Get-WinLeanStatistics -Values @(1.0, 2.0, 3.0, 4.0)).median | Should -Be 2.5
        (Get-WinLeanStatistics -Values @(1.0, 2.0, 2.0)).average | Should -Be 1.7
    }

    It 'returns nulls for no samples' {
        (Get-WinLeanStatistics -Values @()).average | Should -BeNullOrEmpty
    }
}

Describe 'Compare-WinLeanBenchmark' {
    It 'reports before, after and signed changes with invariant formatting' {
        $before = [pscustomobject]@{ cpu = [pscustomobject]@{ averagePercent = 21.6; medianPercent = 13.8 }; memory = [pscustomobject]@{ inUseMB = 14207; committedMB = 20262 }; processes = [pscustomobject]@{ count = 300 }; services = [pscustomobject]@{ running = 138; runningThirdParty = 20 }; startup = [pscustomobject]@{ enabled = 3 } }
        $after = [pscustomobject]@{ cpu = [pscustomobject]@{ averagePercent = 30.0; medianPercent = 12.8 }; memory = [pscustomobject]@{ inUseMB = 14228; committedMB = $null }; processes = [pscustomobject]@{ count = 300 }; services = [pscustomobject]@{ running = 130; runningThirdParty = 18 }; startup = [pscustomobject]@{ enabled = 1 } }
        $rows = @(Compare-WinLeanBenchmark -Before $before -After $after)
        ($rows | Where-Object { $_.metric -eq 'Average CPU (%)' }).change | Should -Be '+8.4'
        ($rows | Where-Object { $_.metric -eq 'Median CPU (%)' }).change | Should -Be '-1.0'
        ($rows | Where-Object { $_.metric -eq 'Processes' }).change | Should -Be '0'
        ($rows | Where-Object { $_.metric -eq 'Running services' }).change | Should -Be '-8'
        ($rows | Where-Object { $_.metric -eq 'Commit charge (MB)' }).change | Should -BeNullOrEmpty
    }

    It 'leaves the after column empty when there is no after benchmark' {
        $before = [pscustomobject]@{ processes = [pscustomobject]@{ count = 300 } }
        $row = @(Compare-WinLeanBenchmark -Before $before -After $null) | Where-Object { $_.metric -eq 'Processes' }
        $row.before | Should -Be '300'
        $row.after | Should -BeNullOrEmpty
    }
}
