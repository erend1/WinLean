#Requires -Version 5.1
<#
    WinLean.Logging
    ---------------
    Three sinks, one call:

      * console    - readable, colored, filtered by ConsoleLevel
      * text log   - <Directory>\<Name>.log, one line per entry
      * JSON log   - <Directory>\<Name>.jsonl, one JSON document per line (JSON Lines),
                     append-only so a crash never corrupts earlier entries

    Levels: TRACE < DEBUG < INFO < WARN < ERROR. A Tag (APPLY, OK, SKIP, FAIL, ...)
    replaces the level as the visible console label without changing severity.

    The logger is an explicit object passed to the functions that need it; there is
    no global logger state.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')

$script:LevelRank = @{
    TRACE = 0
    DEBUG = 1
    INFO  = 2
    WARN  = 3
    ERROR = 4
    NONE  = 5
}

$script:TagColor = @{
    APPLY   = 'Cyan'
    OK      = 'Green'
    SKIP    = 'DarkGray'
    FAIL    = 'Red'
    BLOCKED = 'Yellow'
    RESTORE = 'Cyan'
    PLAN    = 'Cyan'
}

$script:LevelColor = @{
    TRACE = 'DarkGray'
    DEBUG = 'DarkGray'
    INFO  = 'Gray'
    WARN  = 'Yellow'
    ERROR = 'Red'
}

function New-WinLeanLogger {
    <#
    .SYNOPSIS
        Creates a logger. Without -Directory only the console sink is active.
    .PARAMETER Capture
        Keeps every entry in memory (Entries property). Used by tests and reports.
    #>
    [CmdletBinding()]
    param(
        [string] $Directory,

        [ValidatePattern('^[A-Za-z0-9._-]+$')]
        [string] $Name = 'winlean',

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'NONE')]
        [string] $ConsoleLevel = 'INFO',

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'NONE')]
        [string] $FileLevel = 'DEBUG',

        [switch] $Capture
    )

    $textPath = $null
    $jsonPath = $null
    if ($Directory) {
        $fullDirectory = Resolve-WinLeanPath -Path $Directory
        if (-not [System.IO.Directory]::Exists($fullDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($fullDirectory)
        }
        $textPath = Join-Path -Path $fullDirectory -ChildPath ($Name + '.log')
        $jsonPath = Join-Path -Path $fullDirectory -ChildPath ($Name + '.jsonl')
    }

    return [pscustomobject]@{
        PSTypeName   = 'WinLean.Logger'
        TextPath     = $textPath
        JsonPath     = $jsonPath
        ConsoleLevel = $ConsoleLevel.ToUpperInvariant()
        FileLevel    = $FileLevel.ToUpperInvariant()
        Capture      = [bool]$Capture
        Entries      = New-Object -TypeName System.Collections.Generic.List[object]
    }
}

function Write-WinLeanLog {
    <#
    .SYNOPSIS
        Writes one log entry to every configured sink.
    .PARAMETER Tag
        Console label shown instead of the level, for example APPLY, OK, SKIP or FAIL.
    .PARAMETER Detail
        Optional second line (for example a skip reason), indented on the console.
    .PARAMETER Data
        Structured context stored in the JSON log only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSTypeName('WinLean.Logger')]
        $Logger,

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [string] $Tag,

        [string] $Detail,

        [System.Collections.IDictionary] $Data
    )

    $Level = $Level.ToUpperInvariant()
    $label = if ($Tag) { $Tag.ToUpperInvariant() } else { $Level }
    $rank = $script:LevelRank[$Level]
    $timestamp = Get-WinLeanTimestamp

    $entry = [pscustomobject]@{
        timestamp = $timestamp
        level     = $Level
        tag       = $label
        message   = $Message
        detail    = if ($Detail) { $Detail } else { $null }
        data      = $Data
    }

    if ($Logger.Capture) {
        $Logger.Entries.Add($entry)
    }

    if ($rank -ge $script:LevelRank[$Logger.ConsoleLevel]) {
        Write-WinLeanConsoleEntry -Label $label -Level $Level -Message $Message -Detail $Detail
    }

    if ($rank -ge $script:LevelRank[$Logger.FileLevel]) {
        if ($Logger.TextPath) {
            $line = '{0} [{1}] [{2}] {3}' -f $timestamp, $Level.PadRight(5), $label, $Message
            if ($Detail) {
                $line = $line + ' | ' + $Detail
            }
            [System.IO.File]::AppendAllText($Logger.TextPath, $line + [Environment]::NewLine, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
        }
        if ($Logger.JsonPath) {
            Add-WinLeanJsonLine -Path $Logger.JsonPath -InputObject $entry
        }
    }
}

function Write-WinLeanConsoleEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console sink.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Level,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Message,
        [string] $Detail
    )

    $color = $script:LevelColor[$Level]
    if ($Level -eq 'INFO' -and $script:TagColor.ContainsKey($Label)) {
        $color = $script:TagColor[$Label]
    }
    Write-Host -Object ('[{0}] ' -f $Label) -ForegroundColor $color -NoNewline
    Write-Host -Object $Message
    if ($Detail) {
        Write-Host -Object ('        ' + $Detail) -ForegroundColor DarkGray
    }
}

function Write-WinLeanConsole {
    <#
    .SYNOPSIS
        Writes preformatted text (plans, summaries) to the console.
    .PARAMETER Color
        Optional foreground color for all lines.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console output.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines,

        [System.ConsoleColor] $Color
    )

    foreach ($line in $Lines) {
        if ($PSBoundParameters.ContainsKey('Color')) {
            Write-Host -Object $line -ForegroundColor $Color
        }
        else {
            Write-Host -Object $line
        }
    }
}

Export-ModuleMember -Function @(
    'New-WinLeanLogger'
    'Write-WinLeanLog'
    'Write-WinLeanConsole'
)
