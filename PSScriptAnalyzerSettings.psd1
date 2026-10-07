@{
    # Settings for PSScriptAnalyzer. Run the analysis with
    #
    #     .\Tests\Invoke-WinLeanAnalysis.ps1
    #
    # which uses this file for WinLean.ps1, src and Tools, and adds the exclusions listed
    # there for the Pester tests. Editors that support PSScriptAnalyzer pick this file up
    # automatically.

    # Errors and warnings fail the analysis. Information-level rules (for example
    # PSUseOutputTypeCorrectly) are advisory by the analyzer's own classification.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Name-based rule: it asks every function whose verb is New, Set, Remove, Update,
        # ... to support -WhatIf, including the many functions that only build objects in
        # memory (New-WinLeanPlan, New-WinLeanIssue, New-WinLeanSession). The functions that
        # really change Windows are held to a stricter, explicit standard instead: the
        # low-level write functions and every provider Set/Restore operation must support
        # ShouldProcess, which Tests\Unit\Repository.Tests.ps1 verifies by name.
        'PSUseShouldProcessForStateChangingFunctions'

        # WinLean names functions that return collections in the plural
        # (Get-WinLeanRules, Get-WinLeanBackups, Get-WinLeanResourceTypes). Several of them
        # are part of the engine facade; renaming them would break callers for a style
        # preference.
        'PSUseSingularNouns'
    )

    Rules        = @{
        # WinLean supports Windows PowerShell 5.1 and PowerShell 7: reject syntax that only
        # one of them understands (ternary operator, null coalescing, pipeline chains, ...).
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
