<#
    DESTRUCTIVE: applies the real Safe profile to the Windows installation running the
    tests, verifies it, and restores it.

    Run only in a disposable VM or Windows Sandbox:

        $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'
        .\Tests\Invoke-WinLeanTests.ps1 -Suite Destructive

    Run it once as a standard user and once from an elevated PowerShell to cover both
    per-user and machine-wide rules.
#>
BeforeDiscovery {
    $script:Allowed = $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS -eq 'YES'
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    $script:HostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:Cli = Join-Path $script:RepoRoot 'WinLean.ps1'
    $script:Data = Join-Path $TestDrive 'data'

    function Invoke-WinLeanCli {
        # -Command instead of -File: -File cannot pass -Confirm:$false on Windows PowerShell 5.1.
        param([string[]] $Arguments)
        $quoted = foreach ($argument in @($Arguments) + @('-DataRoot', $script:Data)) {
            if ($argument.StartsWith('-')) { $argument } else { "'" + $argument.Replace("'", "''") + "'" }
        }
        $command = "& '{0}' {1}; exit `$LASTEXITCODE" -f $script:Cli.Replace("'", "''"), ($quoted -join ' ')
        $output = & $script:HostPath -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($output -join "`n") }
    }

    function Get-SafePlan {
        $result = Invoke-WinLeanCli -Arguments @('-Profile', 'Safe', '-WhatIf', '-PassThru')
        $result.exitCode | Should -Be 0
        $file = Get-ChildItem -LiteralPath (Join-Path $script:Data 'Reports\Plans') -Filter '*-Safe-plan.json' | Sort-Object Name | Select-Object -Last 1
        return Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    }
}

Describe 'Safe profile on this Windows installation' -Tag 'Destructive' -Skip:(-not $script:Allowed) {
    It 'applies, verifies, is idempotent and restores the recorded state' {
        $initial = Get-SafePlan
        $applicable = @($initial.items | Where-Object { $_.status -eq 'Applicable' } | ForEach-Object { $_.ruleId })

        $apply = Invoke-WinLeanCli -Arguments @('-Profile', 'Safe', '-Apply', '-Confirm:$false', '-SkipBenchmark')
        $apply.exitCode | Should -Be 0 -Because $apply.output

        $afterApply = Get-SafePlan
        foreach ($id in $applicable) {
            ($afterApply.items | Where-Object { $_.ruleId -eq $id }).status | Should -Be 'AlreadySatisfied' -Because $id
        }

        $restore = Invoke-WinLeanCli -Arguments @('-Restore', 'Latest', '-Confirm:$false')
        $restore.exitCode | Should -Be 0 -Because $restore.output

        $afterRestore = Get-SafePlan
        foreach ($item in $initial.items) {
            ($afterRestore.items | Where-Object { $_.ruleId -eq $item.ruleId }).status | Should -Be $item.status -Because $item.ruleId
        }
    }
}
