@{
    RootModule           = 'WinLean.Core.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'defaa4ea-3aa2-48dd-8d1f-00461dc0b4db'
    Author               = 'WinLean contributors'
    Copyright            = '(c) 2026 WinLean contributors. Released under the MIT License.'
    Description          = 'Reproducible, reversible Windows configuration and optimization framework.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')

    # The engine facade used by WinLean.ps1 (and by future front-ends such as a GUI).
    # Component modules (WinLean.Policy, WinLean.Executor, ...) are imported by the
    # root module and can be imported individually for testing.
    FunctionsToExport    = @(
        'New-WinLeanSession'
        'Invoke-WinLeanAnalyze'
        'Get-WinLeanConfiguration'
        'Invoke-WinLeanConfigurationQuestionnaire'
        'Save-WinLeanConfiguration'
        'Invoke-WinLeanDryRun'
        'Invoke-WinLeanApply'
        'Invoke-WinLeanRestorePreview'
        'Invoke-WinLeanRestore'
        'Invoke-WinLeanBenchmark'
        'New-WinLeanReport'
        'Test-WinLeanConfiguration'
        'Get-WinLeanRules'
        'Get-WinLeanBackups'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('Windows', 'Configuration', 'Optimization', 'Privacy', 'Reversible')
            LicenseUri = 'https://opensource.org/license/mit'
        }
    }
}
