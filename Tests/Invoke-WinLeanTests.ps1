#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the WinLean Pester tests.

.DESCRIPTION
    Suites:
      Unit          no system changes; the registry is replaced by an in-memory fake
      Integration   real Windows APIs, but only inside disposable locations: Pester's
                    TestRegistry (HKCU\Software\Pester\<guid>) and TestDrive. Read-only
                    elsewhere (inventory, benchmark). Safe on a developer machine.
      All           Unit + Integration (never Destructive)
      Destructive   applies real WinLean profiles to the CURRENT Windows installation and
                    restores them. Run only in a disposable VM or Windows Sandbox, and only
                    with WINLEAN_ALLOW_DESTRUCTIVE_TESTS=YES.

    Pester 5 (>= 5.5, < 6) is required. It is loaded from .tools\Modules when present;
    -Bootstrap saves it there (repository-local, nothing is installed system-wide).

.EXAMPLE
    .\Tests\Invoke-WinLeanTests.ps1 -Bootstrap

.EXAMPLE
    .\Tests\Invoke-WinLeanTests.ps1 -Suite All -OutputPath .\TestResults\results.xml

.EXAMPLE
    .\Tests\Invoke-WinLeanTests.ps1 -Path .\Tests\Unit\Plan.Tests.ps1 -Verbosity Detailed
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console progress of a developer tool.')]
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Integration', 'All', 'Destructive')]
    [string] $Suite = 'Unit',

    # Runs only these test files or folders (instead of the suite's folders). Tests tagged
    # Destructive are still excluded unless -Suite Destructive is given.
    [string[]] $Path,

    [switch] $Bootstrap,

    [string] $OutputPath,

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Verbosity = 'Normal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$toolsPath = Join-Path -Path $repositoryRoot -ChildPath '.tools\Modules'
$minimumVersion = [version]'5.5.0'
$maximumVersion = [version]'6.0.0'

function Find-WinLeanPester {
    $candidates = @()
    $localRoot = Join-Path -Path $toolsPath -ChildPath 'Pester'
    if (Test-Path -LiteralPath $localRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $localRoot -Directory) {
            $manifest = Join-Path -Path $directory.FullName -ChildPath 'Pester.psd1'
            $version = $null
            if ((Test-Path -LiteralPath $manifest) -and [version]::TryParse($directory.Name, [ref]$version)) {
                $candidates += [pscustomobject]@{ Version = $version; Path = $manifest }
            }
        }
    }
    foreach ($module in @(Get-Module -ListAvailable -Name Pester)) {
        $candidates += [pscustomobject]@{ Version = $module.Version; Path = $module.Path }
    }
    return $candidates | Where-Object { $_.Version -ge $minimumVersion -and $_.Version -lt $maximumVersion } | Sort-Object -Property Version -Descending | Select-Object -First 1
}

$pester = Find-WinLeanPester
if ($null -eq $pester -and $Bootstrap) {
    Write-Host "Saving Pester 5 to $toolsPath (repository-local)..."
    New-Item -ItemType Directory -Force -Path $toolsPath | Out-Null
    if (Get-Command -Name Save-PSResource -ErrorAction SilentlyContinue) {
        Save-PSResource -Name Pester -Version "[$minimumVersion,$maximumVersion)" -Repository PSGallery -Path $toolsPath -TrustRepository
    }
    else {
        Save-Module -Name Pester -MinimumVersion $minimumVersion -MaximumVersion '5.99.99' -Repository PSGallery -Path $toolsPath -Force
    }
    $pester = Find-WinLeanPester
}
if ($null -eq $pester) {
    throw "Pester $minimumVersion or later (below $maximumVersion) was not found. Run '.\Tests\Invoke-WinLeanTests.ps1 -Bootstrap' to save it to .tools\Modules."
}
Get-Module -Name Pester | Remove-Module -Force
Import-Module -Name $pester.Path -Force
Write-Host "Using Pester $($pester.Version) on PowerShell $($PSVersionTable.PSVersion) ($([System.Globalization.CultureInfo]::CurrentCulture.Name))"

$paths = switch ($Suite) {
    'Unit' { @(Join-Path -Path $PSScriptRoot -ChildPath 'Unit') }
    'Integration' { @(Join-Path -Path $PSScriptRoot -ChildPath 'Integration') }
    'All' { @((Join-Path -Path $PSScriptRoot -ChildPath 'Unit'), (Join-Path -Path $PSScriptRoot -ChildPath 'Integration')) }
    'Destructive' { @(Join-Path -Path $PSScriptRoot -ChildPath 'Destructive') }
}
if ($Path) {
    $paths = @(foreach ($item in $Path) { (Resolve-Path -LiteralPath $item -ErrorAction Stop).ProviderPath })
}

if ($Suite -eq 'Destructive' -and $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS -ne 'YES') {
    throw 'Destructive tests change the configuration of THIS Windows installation. Run them only in a disposable VM or Windows Sandbox, after setting $env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = ''YES''.'
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $paths
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = $Verbosity
if ($Suite -ne 'Destructive') {
    $configuration.Filter.ExcludeTag = @('Destructive')
}
if ($OutputPath) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = $OutputPath
}

$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or $result.FailedContainersCount -gt 0) {
    exit 1
}
exit 0
