#Requires -Version 5.1
<#
.SYNOPSIS
    WinLean - Windows, minus everything you do not intentionally use.

.DESCRIPTION
    Reproducible, reversible Windows configuration. WinLean inventories the system,
    evaluates a profile of reviewed rules against your compatibility requirements and
    produces an explicit plan. Nothing is changed unless you pass -Apply.

.PARAMETER Analyze
    Collects a read-only inventory of the system and prints a summary.

.PARAMETER Configure
    Interactive questionnaire that creates or updates the compatibility configuration
    (Config\Compatibility.json, or -CompatibilityPath). Every known requirement is asked
    with the current answer and read-only detection hints; Enter keeps an answer. The
    changes are summarized and saved only after confirmation (atomically, keeping the
    previous version as Compatibility.previous.json). -WhatIf shows the summary only.

.PARAMETER SkipDetection
    With -Configure: do not collect the inventory used for detection hints.

.PARAMETER ProfileName
    The profile to evaluate (alias -Profile): Safe, Lean, Minimal, a custom profile name
    from the Profiles folder, or a path to a profile .json file. Without -Apply this
    produces a dry-run plan only.

.PARAMETER Apply
    Applies the plan after showing it and asking for confirmation. A backup is written
    before the first change, and every change is verified. Combine with -WhatIf for a
    dry run, or with -Confirm:$false to skip the confirmation prompt.

.PARAMETER AllowUntestedBuild
    Includes rules on a Windows build newer than the newest build they were validated on.

.PARAMETER Restore
    Restores a backup: 'Latest' (the newest backup that has not been restored yet) or a
    backup id such as 2026-09-27_18-45-12. Shows the restore plan and asks for
    confirmation. Values changed after WinLean applied them are left alone.

.PARAMETER Force
    With -Restore: also restores values that changed after WinLean applied them.

.PARAMETER ListBackups
    Lists backups and their restore status.

.PARAMETER SkipBenchmark
    With -Apply: do not record a baseline benchmark before applying (saves about 10 s).

.PARAMETER Benchmark
    Measures background activity (CPU, memory, processes, services, startup entries) and
    saves the result to Reports\Benchmarks.

.PARAMETER Report
    Writes the Markdown report of an apply run. The newest benchmark taken after the run
    is used as the "after" measurement.

.PARAMETER Backup
    With -Report: the backup (run) to report on: 'Latest' (default) or a backup id.

.PARAMETER ListRules
    Lists the rule catalog and the profiles that use each rule.

.PARAMETER Validate
    Validates every rule, profile and compatibility file.

.PARAMETER SkipWinGet
    Skips the WinGet inventory section (it may take tens of seconds).

.PARAMETER CompatibilityPath
    Compatibility requirements file. Default: Config\Compatibility.json.

.PARAMETER DataRoot
    Folder for Backups, Reports and Logs. Default: the WinLean folder.

.PARAMETER LogLevel
    Console log level: TRACE, DEBUG, INFO (default), WARN or ERROR.

.PARAMETER PassThru
    Also writes the result object (analysis or plan) to the pipeline.

.EXAMPLE
    .\WinLean.ps1 -Analyze

.EXAMPLE
    .\WinLean.ps1 -Configure

.EXAMPLE
    .\WinLean.ps1 -Profile Safe -WhatIf

.EXAMPLE
    .\WinLean.ps1 -Profile Safe -Apply

.EXAMPLE
    .\WinLean.ps1 -Restore Latest

.EXAMPLE
    .\WinLean.ps1 -Benchmark; .\WinLean.ps1 -Report

.NOTES
    Exit codes: 0 success (including "nothing to do"), 1 completed with failures or an
    unexpected error, 2 invalid input or configuration (unknown profile, invalid rule, no
    backup to restore), 3 cancelled at the confirmation prompt.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The command switches select the parameter set.')]
[CmdletBinding(DefaultParameterSetName = 'Help', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Analyze')]
    [switch] $Analyze,

    [Parameter(Mandatory, ParameterSetName = 'Configure')]
    [switch] $Configure,

    [Parameter(ParameterSetName = 'Configure')]
    [switch] $SkipDetection,

    [Parameter(Mandatory, ParameterSetName = 'Plan')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [Alias('Profile')]
    [ValidateNotNullOrEmpty()]
    [string] $ProfileName,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [switch] $Apply,

    [Parameter(ParameterSetName = 'Plan')]
    [Parameter(ParameterSetName = 'Apply')]
    [switch] $AllowUntestedBuild,

    [Parameter(Mandatory, ParameterSetName = 'Restore')]
    [ValidateNotNullOrEmpty()]
    [string] $Restore,

    [Parameter(ParameterSetName = 'Restore')]
    [switch] $Force,

    [Parameter(Mandatory, ParameterSetName = 'ListBackups')]
    [switch] $ListBackups,

    [Parameter(ParameterSetName = 'Apply')]
    [switch] $SkipBenchmark,

    [Parameter(Mandatory, ParameterSetName = 'Benchmark')]
    [switch] $Benchmark,

    [Parameter(Mandatory, ParameterSetName = 'Report')]
    [switch] $Report,

    [Parameter(ParameterSetName = 'Report')]
    [ValidateNotNullOrEmpty()]
    [string] $Backup = 'Latest',

    [Parameter(Mandatory, ParameterSetName = 'ListRules')]
    [switch] $ListRules,

    [Parameter(Mandatory, ParameterSetName = 'Validate')]
    [switch] $Validate,

    [Parameter(ParameterSetName = 'Analyze')]
    [switch] $SkipWinGet,

    [string] $CompatibilityPath,

    [string] $DataRoot,

    [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string] $LogLevel = 'INFO',

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitSuccess = 0
$ExitFailures = 1
$ExitInvalidInput = 2
$ExitCancelled = 3

function Show-WinLeanUsage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI help.')]
    param()

    Write-Host @'

WinLean - Windows, minus everything you do not intentionally use.

  .\WinLean.ps1 -Analyze                     Read-only inventory and summary
  .\WinLean.ps1 -Configure                   Declare what this PC needs (compatibility questionnaire)
  .\WinLean.ps1 -Profile Safe -WhatIf        Dry run: show what the profile would change
  .\WinLean.ps1 -Profile Safe -Apply         Show the plan, confirm, back up, apply, verify
  .\WinLean.ps1 -Restore Latest              Restore the newest unrestored backup
  .\WinLean.ps1 -ListBackups                 List backups and their restore status
  .\WinLean.ps1 -Benchmark                   Measure background activity (about 10 s)
  .\WinLean.ps1 -Report                      Markdown report of the latest apply run
  .\WinLean.ps1 -ListRules                   List rules and the profiles that use them
  .\WinLean.ps1 -Validate                    Validate rules, profiles and configuration

Common options: -CompatibilityPath <file>  -DataRoot <folder>  -LogLevel DEBUG  -PassThru
Details: Get-Help .\WinLean.ps1 -Full, README.md and the Docs folder.

'@
}

function Get-WinLeanExitCodeForError {
    param([Parameter(Mandatory)] $ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and $exception.InnerException) {
        $exception = $exception.InnerException
    }
    if ($exception -is [System.IO.InvalidDataException] -or $exception -is [System.IO.FileNotFoundException] -or
        $exception -is [System.IO.DirectoryNotFoundException] -or $exception -is [System.ArgumentException]) {
        return $ExitInvalidInput
    }
    return $ExitFailures
}

if ($PSCmdlet.ParameterSetName -eq 'Help') {
    Show-WinLeanUsage
    exit $ExitSuccess
}

# Load the engine. Previously loaded copies are removed so that a second run in the same
# PowerShell session always uses the code on disk.
Get-Module -All | Where-Object { $_.Name -eq 'WinLean' -or $_.Name.StartsWith('WinLean.', [System.StringComparison]::Ordinal) } | Remove-Module -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'src\WinLean.psd1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'src\WinLean.Logging.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'src\WinLean.Report.psm1')

$session = $null
$result = $null
$exitCode = $ExitSuccess
try {
    $session = New-WinLeanSession -InstallRoot $PSScriptRoot -DataRoot $DataRoot -CompatibilityPath $CompatibilityPath `
        -Command $PSCmdlet.ParameterSetName.ToLowerInvariant() -ConsoleLevel $LogLevel
    $logger = $session.logger
    Write-WinLeanLog -Logger $logger -Level DEBUG -Message ("WinLean {0} run {1} as {2} (administrator: {3}) on build {4}.{5}" -f `
            $session.version, $session.runId, $session.identity.name, $session.isAdministrator, $session.platform.build, $session.platform.ubr)

    switch ($PSCmdlet.ParameterSetName) {
        'Analyze' {
            $exclude = @()
            if ($SkipWinGet) { $exclude = @('wingetPackages') }
            $result = Invoke-WinLeanAnalyze -Session $session -ExcludeSection $exclude
            Write-WinLeanConsole -Lines @(Format-WinLeanAnalysisText -Analysis $result -BasePath $session.paths.install)
            Write-WinLeanLog -Logger $logger -Message "Inventory saved to $($result.inventoryPath)"
        }

        'Configure' {
            $configuration = Get-WinLeanConfiguration -Session $session -SkipDetection:$SkipDetection
            Write-WinLeanConsole -Lines @(Format-WinLeanConfigurationIntroText -Configuration $configuration -BasePath $session.paths.install)
            $answers = Invoke-WinLeanConfigurationQuestionnaire -Configuration $configuration `
                -ReadAnswer { param([string] $Prompt) Read-Host -Prompt $Prompt } `
                -WriteLine { param([string] $Line) Write-WinLeanConsole -Lines @($Line) }
            Write-WinLeanConsole -Lines @(Format-WinLeanConfigurationChangesText -Result $answers)
            $result = $answers
            $changeCount = @($answers.changes).Count
            if ($changeCount -eq 0) {
                Write-WinLeanLog -Logger $logger -Message 'Nothing to save: the compatibility configuration was not changed.'
                break
            }
            if ($WhatIfPreference) {
                Write-WinLeanLog -Logger $logger -Message 'Dry run (-WhatIf): the compatibility configuration was not written.'
                break
            }
            if (-not $PSCmdlet.ShouldProcess($configuration.path, "Save $changeCount change(s) to the compatibility configuration")) {
                Write-WinLeanLog -Logger $logger -Message 'Cancelled: the compatibility configuration was not written.'
                $exitCode = $ExitCancelled
                break
            }
            $saved = Save-WinLeanConfiguration -Session $session -Configuration $configuration -Answers $answers.answers
            if ($saved.previousPath) {
                Write-WinLeanLog -Logger $logger -Message "Previous version kept as $($saved.previousPath)"
            }
        }

        'Plan' {
            $result = Invoke-WinLeanDryRun -Session $session -ProfileName $ProfileName -AllowUntestedBuild:$AllowUntestedBuild
            Write-WinLeanConsole -Lines @(Format-WinLeanPlanText -Plan $result -BasePath $session.paths.install)
            Write-WinLeanLog -Logger $logger -Message "Plan saved to $($result.planPath)"
            Write-WinLeanLog -Logger $logger -Message 'Dry run only: no changes were made.'
        }

        'Apply' {
            $plan = Invoke-WinLeanDryRun -Session $session -ProfileName $ProfileName -AllowUntestedBuild:$AllowUntestedBuild
            Write-WinLeanConsole -Lines @(Format-WinLeanPlanText -Plan $plan -BasePath $session.paths.install)
            $result = $plan
            $applicable = [int]$plan.summary.counts.Applicable
            if ($WhatIfPreference) {
                Write-WinLeanLog -Logger $logger -Message 'Dry run (-WhatIf): no changes were made.'
                break
            }
            if ($applicable -eq 0) {
                Write-WinLeanLog -Logger $logger -Message 'Nothing to apply: no rule in this plan needs a change.'
                break
            }
            if (-not $PSCmdlet.ShouldProcess("profile '$($plan.profile.name)': $applicable rule(s) listed under APPLY", 'Apply WinLean changes')) {
                Write-WinLeanLog -Logger $logger -Message 'Cancelled: no changes were made.'
                $exitCode = $ExitCancelled
                break
            }
            $result = Invoke-WinLeanApply -Session $session -Plan $plan -SkipBenchmark:$SkipBenchmark
            Write-WinLeanConsole -Lines @(Format-WinLeanExecutionText -Execution $result -BasePath $session.paths.data)
            if ($null -ne $result.PSObject.Properties['reportPath']) {
                Write-WinLeanLog -Logger $logger -Message "Report: $($result.reportPath)"
            }
            if (@('CompletedWithFailures', 'Aborted') -contains $result.status) {
                $exitCode = $ExitFailures
            }
        }

        'Restore' {
            $preview = Invoke-WinLeanRestorePreview -Session $session -BackupId $Restore -Force:$Force
            Write-WinLeanConsole -Lines @(Format-WinLeanRestorePlanText -RestorePlan $preview)
            $result = $preview
            if ($WhatIfPreference) {
                Write-WinLeanLog -Logger $logger -Message 'Dry run (-WhatIf): nothing was restored.'
                break
            }
            $toRestore = [int]$preview.summary.Restore
            if ($toRestore -gt 0 -and -not $PSCmdlet.ShouldProcess("backup $($preview.backupId): $toRestore value(s) listed under RESTORE", 'Restore previous values')) {
                Write-WinLeanLog -Logger $logger -Message 'Cancelled: nothing was restored.'
                $exitCode = $ExitCancelled
                break
            }
            $result = Invoke-WinLeanRestore -Session $session -RestorePlan $preview
            Write-WinLeanConsole -Lines @(Format-WinLeanRestoreResultText -Result $result)
            if ($result.status -eq 'Incomplete') {
                $exitCode = $ExitFailures
            }
        }

        'Benchmark' {
            $result = Invoke-WinLeanBenchmark -Session $session
            Write-WinLeanConsole -Lines @(Format-WinLeanBenchmarkText -Benchmark $result)
            Write-WinLeanLog -Logger $logger -Message "Benchmark saved to $($result.path)"
        }

        'Report' {
            $result = New-WinLeanReport -Session $session -BackupId $Backup
            if (-not $result.benchmarkAfter) {
                Write-WinLeanLog -Logger $logger -Message 'No benchmark was taken after this run yet; run .\WinLean.ps1 -Benchmark (ideally after signing out) and then -Report again for a before/after comparison.'
            }
        }

        'ListBackups' {
            $result = @(Get-WinLeanBackups -Session $session)
            Write-WinLeanConsole -Lines @(Format-WinLeanBackupListText -Backups $result)
        }

        'ListRules' {
            $result = Get-WinLeanRules -Session $session
            Write-WinLeanConsole -Lines @(Format-WinLeanRuleListText -Rules $result.rules -Membership $result.membership)
        }

        'Validate' {
            $result = Test-WinLeanConfiguration -Session $session
            $lines = @(Format-WinLeanIssueText -Issues $result.issues)
            if ($lines.Count -gt 0) {
                Write-WinLeanConsole -Lines $lines
            }
            $summary = "Validated $($result.ruleCount) rule(s) and $($result.profileCount) profile(s): $($result.errorCount) error(s), $($result.warningCount) warning(s)."
            if ($result.errorCount -gt 0) {
                Write-WinLeanLog -Logger $logger -Level ERROR -Message $summary
                $exitCode = $ExitInvalidInput
            }
            else {
                Write-WinLeanLog -Logger $logger -Tag OK -Message $summary
            }
        }
    }
}
catch {
    $exitCode = Get-WinLeanExitCodeForError -ErrorRecord $_
    $message = $_.Exception.Message
    if ($null -ne $session) {
        Write-WinLeanLog -Logger $session.logger -Level ERROR -Message $message -Data @{ exception = $_.Exception.GetType().FullName; position = $_.InvocationInfo.PositionMessage }
    }
    else {
        Write-Error -Message $message -ErrorAction Continue
    }
}

if ($PassThru -and $null -ne $result) {
    $result
}
exit $exitCode
