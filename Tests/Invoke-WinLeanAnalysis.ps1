#Requires -Version 5.1
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on the WinLean sources and tests (static analysis).

.DESCRIPTION
    Analyzes WinLean.ps1, src and Tools with PSScriptAnalyzerSettings.psd1, and the Pester
    tests with the same settings plus the test-only exclusions explained below. Nothing is
    executed or changed: the scripts are parsed and inspected.

    PSScriptAnalyzer is loaded from .tools\Modules when present; -Bootstrap saves the
    pinned version there (repository-local, nothing is installed system-wide). The version
    is pinned so that a new analyzer release cannot change the result of an unchanged
    commit.

    Exit code 0 when no finding of severity Error or Warning remains, otherwise 1.

.PARAMETER Bootstrap
    Saves the pinned PSScriptAnalyzer version to .tools\Modules when it is missing.

.PARAMETER IncludeInformation
    Also lists Information-level findings (advisory; they never fail the analysis).

.PARAMETER PassThru
    Writes the findings to the pipeline instead of exiting.

.EXAMPLE
    .\Tests\Invoke-WinLeanAnalysis.ps1 -Bootstrap
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output of a developer tool.')]
[CmdletBinding()]
param(
    [switch] $Bootstrap,

    [switch] $IncludeInformation,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$toolsPath = Join-Path -Path $repositoryRoot -ChildPath '.tools\Modules'
$pinnedVersion = [version]'1.25.0'
$settingsPath = Join-Path -Path $repositoryRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'

# Rules that cannot follow Pester's structure are excluded for the tests only:
#   PSUseDeclaredVarsMoreThanAssignments - variables assigned in BeforeAll/BeforeEach are
#                                          used in It blocks, which are separate script
#                                          blocks the analyzer does not connect.
$testOnlyExclusions = @('PSUseDeclaredVarsMoreThanAssignments')

function Find-WinLeanAnalyzer {
    $manifest = Join-Path -Path $toolsPath -ChildPath ("PSScriptAnalyzer\{0}\PSScriptAnalyzer.psd1" -f $pinnedVersion)
    if (Test-Path -LiteralPath $manifest) {
        return $manifest
    }
    $installed = Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq $pinnedVersion } | Select-Object -First 1
    if ($null -ne $installed) {
        return $installed.Path
    }
    return $null
}

$analyzer = Find-WinLeanAnalyzer
if ($null -eq $analyzer -and $Bootstrap) {
    Write-Host "Saving PSScriptAnalyzer $pinnedVersion to $toolsPath (repository-local)..."
    New-Item -ItemType Directory -Force -Path $toolsPath | Out-Null
    if (Get-Command -Name Save-PSResource -ErrorAction SilentlyContinue) {
        Save-PSResource -Name PSScriptAnalyzer -Version "$pinnedVersion" -Repository PSGallery -Path $toolsPath -TrustRepository
    }
    else {
        Save-Module -Name PSScriptAnalyzer -RequiredVersion $pinnedVersion -Repository PSGallery -Path $toolsPath -Force
    }
    $analyzer = Find-WinLeanAnalyzer
}
if ($null -eq $analyzer) {
    throw "PSScriptAnalyzer $pinnedVersion was not found. Run '.\Tests\Invoke-WinLeanAnalysis.ps1 -Bootstrap' to save it to .tools\Modules."
}
Get-Module -Name PSScriptAnalyzer | Remove-Module -Force
Import-Module -Name $analyzer -Force
Write-Host "Using PSScriptAnalyzer $pinnedVersion on PowerShell $($PSVersionTable.PSVersion)"

$settings = Import-PowerShellDataFile -LiteralPath $settingsPath
$testSettings = Import-PowerShellDataFile -LiteralPath $settingsPath
$testSettings['ExcludeRules'] = @($testSettings['ExcludeRules']) + $testOnlyExclusions
if ($IncludeInformation) {
    $settings['Severity'] = @('Error', 'Warning', 'Information')
    $testSettings['Severity'] = @('Error', 'Warning', 'Information')
}

$targets = @(
    @{ Path = (Join-Path -Path $repositoryRoot -ChildPath 'WinLean.ps1'); Settings = $settings }
    @{ Path = (Join-Path -Path $repositoryRoot -ChildPath 'src'); Settings = $settings }
    @{ Path = (Join-Path -Path $repositoryRoot -ChildPath 'Tools'); Settings = $settings }
    @{ Path = (Join-Path -Path $repositoryRoot -ChildPath 'Tests'); Settings = $testSettings }
)
$findings = @(foreach ($target in $targets) {
        Invoke-ScriptAnalyzer -Path $target.Path -Recurse -Settings $target.Settings
    })

if ($PassThru) {
    $findings
    return
}

$failing = @($findings | Where-Object { @('Error', 'Warning', 'ParseError') -contains [string]$_.Severity })
foreach ($finding in @($findings | Sort-Object -Property ScriptPath, Line)) {
    $relative = $finding.ScriptPath
    if ($relative.StartsWith($repositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($repositoryRoot.Length).TrimStart('\')
    }
    Write-Host ('[{0}] {1}:{2} {3}: {4}' -f ([string]$finding.Severity).ToUpperInvariant(), $relative, $finding.Line, $finding.RuleName, $finding.Message)
}
Write-Host ("Static analysis: {0} finding(s), {1} failing (Error or Warning)." -f $findings.Count, $failing.Count)
if ($failing.Count -gt 0) {
    exit 1
}
exit 0
