#Requires -Version 5.1
<#
.SYNOPSIS
    Records what a Settings toggle writes to the registry (evidence standard).

.DESCRIPTION
    Run this in a disposable VM or Windows Sandbox. The script only READS the registry and
    never changes a setting - you switch the toggle yourself in the Settings app:

      1. records Windows edition, version, build and UBR and checks that the machine is a
         VM or Windows Sandbox
      2. baseline: two snapshots of the watched keys, -BaselineSeconds apart, while nobody
         touches the system; whatever changes in between is background churn
      3. you switch the toggle to the state the rule will set (-TargetState); snapshot
      4. you switch it back (-OriginalState); snapshot
      5. steps 3 and 4 repeat for -Cycles
      6. attribution: only changes that happened on every switch, were reversed exactly on
         every switch back, were identical in every cycle and did not occur during the
         baseline are attributable to the toggle
      7. a draft write-up is saved to Docs\Evidence\<RuleId>.md

    Review the draft, complete the conclusion, and reference it from the rule's "evidence"
    array.

.PARAMETER RuleId
    The rule the evidence is for, for example 'privacy.settings-suggested-content.disable'.

.PARAMETER Setting
    The Settings page and toggle, for example
    'Settings > Privacy & security > General > Show me suggested content in the Settings app'.

.PARAMETER TargetState
    The toggle state the rule will set, for example 'Off'.

.PARAMETER OriginalState
    The state the toggle is switched back to, for example 'On'.

.PARAMETER Path
    Registry keys to watch. The default covers the per-user keys used by the privacy,
    recommendation and File Explorer settings.

.PARAMETER Depth
    Levels of subkeys to include below each watched key.

.PARAMETER BaselineSeconds
    How long to watch the keys without any action before the first switch.

.PARAMETER Cycles
    How many times to switch the toggle to the target state and back (1-5).

.PARAMETER ConfirmDisposableEnvironment
    Run although no VM or Windows Sandbox was detected, because the machine is a disposable
    VM the detection does not recognize. Recorded in the write-up. Never use it on a
    primary workstation.

.PARAMETER OutputPath
    Where to save the write-up. Default: Docs\Evidence\<RuleId>.md.

.PARAMETER Force
    Overwrite an existing write-up.

.EXAMPLE
    .\Tools\Capture-WinLeanEvidence.ps1 -RuleId privacy.settings-suggested-content.disable `
        -Setting 'Settings > Privacy & security > General > Show me suggested content in the Settings app' `
        -TargetState Off -OriginalState On -Cycles 2
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive tool.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*)+$')]
    [string] $RuleId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Setting,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TargetState,

    [ValidateNotNullOrEmpty()]
    [string] $OriginalState = 'its previous state',

    [string[]] $Path = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
        'HKCU:\Control Panel\International\User Profile'
    ),

    [ValidateRange(0, 10)]
    [int] $Depth = 2,

    [ValidateRange(0, 600)]
    [int] $BaselineSeconds = 15,

    [ValidateRange(1, 5)]
    [int] $Cycles = 1,

    [switch] $ConfirmDisposableEnvironment,

    [string] $OutputPath,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
Get-Module -All | Where-Object { $_.Name -eq 'WinLean' -or $_.Name.StartsWith('WinLean.', [System.StringComparison]::Ordinal) } | Remove-Module -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Evidence.psm1')
Import-Module -Name (Join-Path -Path $repositoryRoot -ChildPath 'src\WinLean.Common.psm1')

if (-not $OutputPath) {
    $OutputPath = Join-Path -Path $repositoryRoot -ChildPath ("Docs\Evidence\{0}.md" -f $RuleId)
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "'$OutputPath' already exists. Use -Force to overwrite it."
}

Write-Host ''
Write-Host 'WinLean evidence capture' -ForegroundColor Cyan
Write-Host 'This script only reads the registry. You switch the setting yourself in the Settings app.'
Write-Host ''

$capture = Invoke-WinLeanEvidenceCapture -RuleId $RuleId -Setting $Setting -TargetState $TargetState -OriginalState $OriginalState `
    -Path $Path -Depth $Depth -BaselineSeconds $BaselineSeconds -Cycles $Cycles -ConfirmDisposableEnvironment:$ConfirmDisposableEnvironment `
    -Prompt { param([string] $Message) [void](Read-Host -Prompt $Message) } `
    -WriteLine { param([string] $Line) Write-Host $Line }

Write-WinLeanTextFile -Path $OutputPath -Content $capture.markdown
Write-Host ''
Write-Host "Draft saved to $OutputPath. Review it, complete the conclusion, and reference it from the rule." -ForegroundColor Green
