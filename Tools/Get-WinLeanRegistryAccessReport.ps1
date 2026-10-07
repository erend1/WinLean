#Requires -Version 5.1
<#
.SYNOPSIS
    Reports the access control of registry keys: explicit and inherited entries, and who
    can change the key. Read-only.

.DESCRIPTION
    Lists, for each key, the owner and every access entry with its source (explicit or
    inherited), type, principal, scope and rights, and states whether the current process
    can write to the key.

    The script NEVER modifies access control lists, owners, keys or values, and it has no
    option to do so. It reports facts and does not judge them: an unusual entry is not an
    error. To evaluate an observation, create the same report in a clean VM of the same
    Windows build and edition and compare the two with -CompareWith.

    Saved reports identify principals by role: well-known SIDs are kept, the current user
    is stored as 'CurrentUser', and other machine-specific account SIDs are reduced to
    their relative id. They contain no user names.

.PARAMETER Path
    Keys to report ('HKCU:\...' or 'HKLM:\...'). Default: HKCU:\Software,
    HKCU:\Software\Policies, HKCU:\Software\Policies\Microsoft,
    HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies and HKLM:\SOFTWARE\Policies.

.PARAMETER OutputPath
    Saves the report as JSON (for a later comparison).

.PARAMETER CompareWith
    A report saved with -OutputPath on the reference system, normally a clean VM of the
    same Windows build and edition. The differences are listed after the report.

.PARAMETER PassThru
    Also writes the report object (and the comparison) to the pipeline.

.EXAMPLE
    .\Tools\Get-WinLeanRegistryAccessReport.ps1

.EXAMPLE
    # In a clean VM of the same build:
    .\Tools\Get-WinLeanRegistryAccessReport.ps1 -OutputPath .\clean-vm-access.json
    # On the system under examination:
    .\Tools\Get-WinLeanRegistryAccessReport.ps1 -CompareWith .\clean-vm-access.json
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive diagnostic tool.')]
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string[]] $Path,

    [string] $OutputPath,

    [string] $CompareWith,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
Get-Module -All | Where-Object { $_.Name -eq 'WinLean' -or $_.Name.StartsWith('WinLean.', [System.StringComparison]::Ordinal) } | Remove-Module -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.RegistryAccess.psm1')
Import-Module -Name (Join-Path -Path $repositoryRoot -ChildPath 'src\WinLean.Common.psm1')

$parameters = @{}
if ($Path) { $parameters['Path'] = $Path }
$report = Get-WinLeanRegistryAccessReport @parameters
foreach ($line in @(Format-WinLeanRegistryAccessReport -Report $report)) { Write-Host $line }

if ($OutputPath) {
    Write-WinLeanJsonFile -Path $OutputPath -InputObject $report
    Write-Host "Report saved to $(Resolve-WinLeanPath -Path $OutputPath)"
}

$comparison = $null
if ($CompareWith) {
    $reference = Read-WinLeanJsonFile -Path $CompareWith
    if ([int](Get-WinLeanProperty -InputObject $reference -Name 'schemaVersion' -Default 0) -ne 1 -or $null -eq (Get-WinLeanProperty -InputObject $reference -Name 'keys')) {
        throw "'$CompareWith' is not a WinLean registry access report."
    }
    $comparison = Compare-WinLeanRegistryAccessReport -Reference $reference -Difference $report
    foreach ($line in @(Format-WinLeanRegistryAccessComparison -Comparison $comparison)) { Write-Host $line }
}

if ($PassThru) {
    $report
    if ($null -ne $comparison) { $comparison }
}
