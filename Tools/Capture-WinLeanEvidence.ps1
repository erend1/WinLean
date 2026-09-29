#Requires -Version 5.1
<#
.SYNOPSIS
    Records what a Settings toggle writes to the registry (evidence standard).

.DESCRIPTION
    Run this in a disposable VM or Windows Sandbox. The script only READS the registry:

      1. snapshot of the watched keys
      2. you change the setting in the Settings app (for example turn it off)
      3. second snapshot and list of changes
      4. you change the setting back
      5. third snapshot and list of changes
      6. a draft write-up is saved to Docs\Evidence\<RuleId>.md

    A setting qualifies as observed evidence when step 3 shows the value(s) the rule would
    write and step 5 shows them returning to their previous state. Review the draft, complete
    the conclusion, and reference it from the rule's "evidence" array.

.PARAMETER RuleId
    The rule the evidence is for, for example 'privacy.settings-suggested-content.disable'.

.PARAMETER Setting
    Where the toggle is, for example
    'Settings > Privacy & security > General > Show me suggested content in the Settings app'.

.PARAMETER Path
    Registry keys to watch. The default covers the per-user keys used by the privacy,
    recommendation and File Explorer settings.

.PARAMETER Depth
    Levels of subkeys to include below each watched key.

.PARAMETER OutputPath
    Where to save the write-up. Default: Docs\Evidence\<RuleId>.md.

.PARAMETER Force
    Overwrite an existing write-up.

.EXAMPLE
    .\Tools\Capture-WinLeanEvidence.ps1 -RuleId privacy.settings-suggested-content.disable -Setting 'Settings > Privacy & security > General > Show me suggested content in the Settings app'
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
Write-Host 'Run this in a disposable VM or Windows Sandbox. This script only reads the registry;'
Write-Host 'you change the setting yourself in the Settings app.'
Write-Host ''
Write-Host "Setting: $Setting"
Write-Host ''

$platform = Get-WinLeanPlatform
$initial = Get-WinLeanRegistrySnapshot -Path $Path -Depth $Depth
Write-Host ("Snapshot 1: {0} values in {1} keys." -f @($initial.values).Count, @($initial.keys).Count)

$firstAction = Read-Host 'Change the setting now (for example turn it OFF), describe what you did, and press Enter'
if ([string]::IsNullOrWhiteSpace($firstAction)) { $firstAction = 'First change' }
$middle = Get-WinLeanRegistrySnapshot -Path $Path -Depth $Depth
$firstChanges = @(Compare-WinLeanRegistrySnapshot -Before $initial -After $middle)
Write-Host "Changes after '$firstAction':" -ForegroundColor Cyan
foreach ($line in @(Format-WinLeanRegistryChange -Changes $firstChanges)) { Write-Host $line }

$secondAction = Read-Host 'Now change the setting back (for example turn it ON), describe what you did, and press Enter'
if ([string]::IsNullOrWhiteSpace($secondAction)) { $secondAction = 'Change back' }
$final = Get-WinLeanRegistrySnapshot -Path $Path -Depth $Depth
$secondChanges = @(Compare-WinLeanRegistrySnapshot -Before $middle -After $final)
Write-Host "Changes after '$secondAction':" -ForegroundColor Cyan
foreach ($line in @(Format-WinLeanRegistryChange -Changes $secondChanges)) { Write-Host $line }

$markdown = ConvertTo-WinLeanEvidenceMarkdown -RuleId $RuleId -Setting $Setting -Platform $platform -Paths $Path `
    -FirstAction $firstAction -FirstChanges $firstChanges -SecondAction $secondAction -SecondChanges $secondChanges
Write-WinLeanTextFile -Path $OutputPath -Content $markdown
Write-Host ''
Write-Host "Draft saved to $OutputPath. Review it, complete the conclusion, and reference it from the rule." -ForegroundColor Green
