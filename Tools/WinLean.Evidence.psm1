#Requires -Version 5.1
<#
    WinLean.Evidence
    ----------------
    Helpers for the evidence standard (Docs/Rules.md): read-only registry snapshots,
    their comparison, and a Markdown write-up of an observation.

    Used by Tools/Capture-WinLeanEvidence.ps1 to record what the Settings app writes when
    a toggle changes. Nothing in this module modifies the registry.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\src'))
Import-Module -Name (Join-Path -Path $sourceRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $sourceRoot -ChildPath 'Providers\WinLean.Provider.Registry.psm1')

$script:Separator = [string][char]0

function Get-WinLeanRegistrySnapshot {
    <#
    .SYNOPSIS
        Reads every value below the given keys (read-only) into a snapshot.
    .PARAMETER Path
        Keys such as 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'.
    .PARAMETER Depth
        How many levels of subkeys to include (0 = only the keys themselves).
    .PARAMETER MaximumValues
        Safety limit for very large subtrees.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Path,
        [ValidateRange(0, 10)] [int] $Depth = 2,
        [ValidateRange(1, 1000000)] [int] $MaximumValues = 50000
    )

    $keys = New-Object -TypeName System.Collections.Generic.List[string]
    $values = New-Object -TypeName System.Collections.Generic.List[object]
    $inaccessible = New-Object -TypeName System.Collections.Generic.List[string]
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    $hives = @{ HKCU = [Microsoft.Win32.RegistryHive]::CurrentUser; HKLM = [Microsoft.Win32.RegistryHive]::LocalMachine }

    foreach ($root in $Path) {
        $location = ConvertFrom-WinLeanRegistryPath -Path $root
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hives[$location.hive], $view)
        try {
            $pending = New-Object -TypeName System.Collections.Generic.Queue[object]
            $pending.Enqueue([pscustomobject]@{ subKey = $location.subKey; level = 0 })
            while ($pending.Count -gt 0) {
                $item = $pending.Dequeue()
                $displayPath = $location.hive + ':\' + $item.subKey
                $key = $null
                try {
                    $key = $baseKey.OpenSubKey($item.subKey, $false)
                }
                catch {
                    $inaccessible.Add($displayPath)
                    continue
                }
                if ($null -eq $key) {
                    continue
                }
                try {
                    $keys.Add($displayPath)
                    foreach ($name in $key.GetValueNames()) {
                        if ($values.Count -ge $MaximumValues) {
                            throw (New-Object -TypeName System.InvalidOperationException -ArgumentList "The snapshot exceeds $MaximumValues values; narrow -Path or reduce -Depth.")
                        }
                        $raw = [pscustomobject]@{
                            keyExists   = $true
                            valueExists = $true
                            kind        = $key.GetValueKind($name).ToString()
                            data        = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        }
                        $values.Add([pscustomobject]@{ key = $displayPath; name = $name; state = (ConvertTo-WinLeanRegistryState -Raw $raw) })
                    }
                    if ($item.level -lt $Depth) {
                        foreach ($child in $key.GetSubKeyNames()) {
                            $pending.Enqueue([pscustomobject]@{ subKey = $item.subKey + '\' + $child; level = $item.level + 1 })
                        }
                    }
                }
                finally {
                    $key.Dispose()
                }
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }

    return [pscustomobject]@{
        takenAt      = Get-WinLeanTimestamp
        paths        = $Path
        depth        = $Depth
        keys         = $keys.ToArray()
        values       = $values.ToArray()
        inaccessible = $inaccessible.ToArray()
    }
}

function Compare-WinLeanRegistrySnapshot {
    <#
    .SYNOPSIS
        Lists what changed between two snapshots: keys and values added, removed or changed.
        Pure function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Before,
        [Parameter(Mandatory)] $After
    )

    $beforeValues = New-WinLeanDictionary
    foreach ($entry in @($Before.values)) { $beforeValues[$entry.key + $script:Separator + $entry.name] = $entry }
    $afterValues = New-WinLeanDictionary
    foreach ($entry in @($After.values)) { $afterValues[$entry.key + $script:Separator + $entry.name] = $entry }

    $changes = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($key in @($After.keys)) {
        if (@($Before.keys) -notcontains $key) {
            $changes.Add([pscustomobject]@{ change = 'KeyAdded'; key = $key; name = $null; before = $null; after = $null })
        }
    }
    foreach ($key in @($Before.keys)) {
        if (@($After.keys) -notcontains $key) {
            $changes.Add([pscustomobject]@{ change = 'KeyRemoved'; key = $key; name = $null; before = $null; after = $null })
        }
    }
    foreach ($id in @($afterValues.Keys)) {
        $entry = $afterValues[$id]
        if (-not $beforeValues.ContainsKey($id)) {
            $changes.Add([pscustomobject]@{ change = 'Added'; key = $entry.key; name = $entry.name; before = $null; after = (Format-WinLeanRegistryState -State $entry.state) })
            continue
        }
        $previous = $beforeValues[$id]
        if (-not (Test-WinLeanRegistryStateEqual -Expected $previous.state -Actual $entry.state)) {
            $changes.Add([pscustomobject]@{ change = 'Changed'; key = $entry.key; name = $entry.name; before = (Format-WinLeanRegistryState -State $previous.state); after = (Format-WinLeanRegistryState -State $entry.state) })
        }
    }
    foreach ($id in @($beforeValues.Keys)) {
        if (-not $afterValues.ContainsKey($id)) {
            $entry = $beforeValues[$id]
            $changes.Add([pscustomobject]@{ change = 'Removed'; key = $entry.key; name = $entry.name; before = (Format-WinLeanRegistryState -State $entry.state); after = $null })
        }
    }

    $items = $changes.ToArray()
    $sortKeys = [string[]]@(foreach ($item in $items) { $item.key + $script:Separator + [string]$item.name + $script:Separator + $item.change })
    [System.Array]::Sort($sortKeys, $items, [System.StringComparer]::OrdinalIgnoreCase)
    $items
}

function Format-WinLeanRegistryChange {
    <#
    .SYNOPSIS
        One line per change, for the console.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Changes)

    if ($Changes.Count -eq 0) {
        '  (no registry changes in the watched keys)'
        return
    }
    foreach ($change in $Changes) {
        switch ($change.change) {
            'KeyAdded' { '  key added:   {0}' -f $change.key }
            'KeyRemoved' { '  key removed: {0}' -f $change.key }
            'Added' { '  added:       {0}\{1} = {2}' -f $change.key, $change.name, $change.after }
            'Removed' { '  removed:     {0}\{1} (was {2})' -f $change.key, $change.name, $change.before }
            default { '  changed:     {0}\{1}: {2} -> {3}' -f $change.key, $change.name, $change.before, $change.after }
        }
    }
}

function ConvertTo-WinLeanEvidenceMarkdown {
    <#
    .SYNOPSIS
        Builds the evidence write-up for Docs/Evidence/<rule-id>.md.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RuleId,
        [Parameter(Mandatory)] [string] $Setting,
        [Parameter(Mandatory)] $Platform,
        [Parameter(Mandatory)] [string[]] $Paths,
        [Parameter(Mandatory)] [string] $FirstAction,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $FirstChanges,
        [Parameter(Mandatory)] [string] $SecondAction,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $SecondChanges,
        [string] $Method = 'RegistryDiff',
        [string] $RecordedAt = (Get-WinLeanTimestamp)
    )

    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    $lines.Add("# Evidence: $RuleId")
    $lines.Add('')
    $lines.Add('| Item | Value |')
    $lines.Add('|---|---|')
    $lines.Add("| Setting | $($Setting.Replace('|', '\|')) |")
    $lines.Add(('| Windows | {0} {1} (build {2}.{3}, {4}) |' -f $Platform.productName, $Platform.displayVersion, $Platform.build, $Platform.ubr, $Platform.architecture))
    $lines.Add("| Method | $Method (Tools/Capture-WinLeanEvidence.ps1) |")
    $lines.Add("| Recorded | $(Format-WinLeanTimestamp -Value $RecordedAt) |")
    $lines.Add('| Environment | disposable VM or Windows Sandbox (confirm) |')
    $lines.Add('')
    $lines.Add('## Watched keys')
    $lines.Add('')
    foreach ($path in $Paths) { $lines.Add("- ``$path``") }
    foreach ($phase in @(@{ Action = $FirstAction; Changes = $FirstChanges }, @{ Action = $SecondAction; Changes = $SecondChanges })) {
        $lines.Add('')
        $lines.Add("## $($phase.Action)")
        $lines.Add('')
        if (@($phase.Changes).Count -eq 0) {
            $lines.Add('No registry changes in the watched keys.')
            continue
        }
        $lines.Add('| Change | Location | Before | After |')
        $lines.Add('|---|---|---|---|')
        foreach ($change in $phase.Changes) {
            $location = if ($change.name) { "$($change.key)\$($change.name)" } else { $change.key }
            $lines.Add(('| {0} | `{1}` | {2} | {3} |' -f $change.change, $location, [string]$change.before, [string]$change.after))
        }
    }
    $lines.Add('')
    $lines.Add('## Conclusion')
    $lines.Add('')
    $lines.Add('Reviewer: state which value(s) the toggle controls, confirm that the change was')
    $lines.Add('reversed exactly when the toggle was switched back, and note unrelated changes')
    $lines.Add('(for example timestamps) that were ignored.')
    $lines.Add('')
    return ($lines.ToArray() -join "`n")
}

Export-ModuleMember -Function @(
    'Get-WinLeanRegistrySnapshot'
    'Compare-WinLeanRegistrySnapshot'
    'Format-WinLeanRegistryChange'
    'ConvertTo-WinLeanEvidenceMarkdown'
)
