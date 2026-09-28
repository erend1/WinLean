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

.PARAMETER ProfileName
    The profile to evaluate (alias -Profile): Safe, Lean, Minimal, a custom profile name
    from the Profiles folder, or a path to a profile .json file. Without -Apply this
    produces a dry-run plan only.

.PARAMETER AllowUntestedBuild
    Includes rules on a Windows build newer than the newest build they were validated on.

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
    .\WinLean.ps1 -Profile Safe -WhatIf

.NOTES
    Exit codes: 0 success, 1 completed with failures, 2 invalid input or configuration,
    3 cancelled or precondition not met.
#>
[CmdletBinding(DefaultParameterSetName = 'Help', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Analyze')]
    [switch] $Analyze,

    [Parameter(Mandatory, ParameterSetName = 'Plan')]
    [Alias('Profile')]
    [ValidateNotNullOrEmpty()]
    [string] $ProfileName,

    [Parameter(ParameterSetName = 'Plan')]
    [switch] $AllowUntestedBuild,

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
  .\WinLean.ps1 -Profile Safe -WhatIf        Dry run: show what the profile would change
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

        'Plan' {
            $result = Invoke-WinLeanDryRun -Session $session -ProfileName $ProfileName -AllowUntestedBuild:$AllowUntestedBuild
            Write-WinLeanConsole -Lines @(Format-WinLeanPlanText -Plan $result -BasePath $session.paths.install)
            Write-WinLeanLog -Logger $logger -Message "Plan saved to $($result.planPath)"
            Write-WinLeanLog -Logger $logger -Message 'Dry run only: no changes were made.'
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
