#Requires -Version 5.1
<#
    WinLean.Evidence
    ----------------
    Helpers for the evidence standard (Docs/Rules.md): read-only registry snapshots,
    their comparison, and a Markdown write-up of an observation.

    Used by Tools/Capture-WinLeanEvidence.ps1 to record what the Settings app writes when
    a toggle changes. Nothing in this module modifies the registry, and nothing changes a
    setting: the person running the capture switches the toggle in the Settings app.

    Capture workflow (Invoke-WinLeanEvidenceCapture):

      environment  Windows edition, version, build and UBR; the capture refuses to run
                   outside a detected VM or Windows Sandbox unless the operator confirms a
                   disposable environment
      baseline     two snapshots taken while nobody touches the system; whatever changes
                   between them is background churn and never counts as evidence
      cycles       the operator switches the toggle to the rule's state, then back; a
                   snapshot is taken after each step (optionally several cycles)
      attribution  a value is attributable to the toggle only when it changed on every
                   switch, returned exactly to its previous state on every switch back,
                   changed the same way each time, and is not background churn
      write-up     Markdown for Docs/Evidence/<rule-id>.md with all phases, the attribution,
                   draft resources and the reviewer's checklist
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
            $changes.Add([pscustomobject]@{ change = 'KeyAdded'; key = $key; name = $null; before = $null; after = $null; beforeState = $null; afterState = $null })
        }
    }
    foreach ($key in @($Before.keys)) {
        if (@($After.keys) -notcontains $key) {
            $changes.Add([pscustomobject]@{ change = 'KeyRemoved'; key = $key; name = $null; before = $null; after = $null; beforeState = $null; afterState = $null })
        }
    }
    foreach ($id in @($afterValues.Keys)) {
        $entry = $afterValues[$id]
        if (-not $beforeValues.ContainsKey($id)) {
            $changes.Add([pscustomobject]@{ change = 'Added'; key = $entry.key; name = $entry.name; before = $null; after = (Format-WinLeanRegistryState -State $entry.state); beforeState = $null; afterState = $entry.state })
            continue
        }
        $previous = $beforeValues[$id]
        if (-not (Test-WinLeanRegistryStateEqual -Expected $previous.state -Actual $entry.state)) {
            $changes.Add([pscustomobject]@{ change = 'Changed'; key = $entry.key; name = $entry.name; before = (Format-WinLeanRegistryState -State $previous.state); after = (Format-WinLeanRegistryState -State $entry.state); beforeState = $previous.state; afterState = $entry.state })
        }
    }
    foreach ($id in @($beforeValues.Keys)) {
        if (-not $afterValues.ContainsKey($id)) {
            $entry = $beforeValues[$id]
            $changes.Add([pscustomobject]@{ change = 'Removed'; key = $entry.key; name = $entry.name; before = (Format-WinLeanRegistryState -State $entry.state); after = $null; beforeState = $entry.state; afterState = $null })
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

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

function Get-WinLeanEnvironmentKind {
    <#
    .SYNOPSIS
        Classifies the machine from its manufacturer, model and user name: WindowsSandbox,
        VirtualMachine, Physical or Unknown. Pure function; a heuristic.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $Manufacturer,
        [AllowNull()] [string] $Model,
        [AllowNull()] [string] $UserName
    )

    $vendor = if ($Manufacturer) { $Manufacturer } else { '' }
    $product = if ($Model) { $Model } else { '' }
    if ($UserName -and [string]::Equals($UserName, 'WDAGUtilityAccount', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ kind = 'WindowsSandbox'; detail = 'Windows Sandbox (WDAGUtilityAccount)' }
    }
    $signatures = @(
        @{ Vendor = 'Microsoft Corporation'; Model = 'Virtual Machine'; Name = 'Hyper-V' }
        @{ Vendor = 'VMware'; Model = $null; Name = 'VMware' }
        @{ Vendor = $null; Model = 'VMware'; Name = 'VMware' }
        @{ Vendor = 'innotek'; Model = $null; Name = 'VirtualBox' }
        @{ Vendor = $null; Model = 'VirtualBox'; Name = 'VirtualBox' }
        @{ Vendor = 'QEMU'; Model = $null; Name = 'QEMU/KVM' }
        @{ Vendor = $null; Model = 'KVM'; Name = 'QEMU/KVM' }
        @{ Vendor = 'Parallels'; Model = $null; Name = 'Parallels' }
        @{ Vendor = 'Xen'; Model = $null; Name = 'Xen' }
    )
    foreach ($signature in $signatures) {
        $vendorMatches = (-not $signature.Vendor) -or (Test-WinLeanTextContains -Text $vendor -Value $signature.Vendor)
        $modelMatches = (-not $signature.Model) -or (Test-WinLeanTextContains -Text $product -Value $signature.Model)
        if ($vendorMatches -and $modelMatches) {
            return [pscustomobject]@{ kind = 'VirtualMachine'; detail = "$($signature.Name) virtual machine ($vendor, $product)" }
        }
    }
    if (-not $vendor -and -not $product) {
        return [pscustomobject]@{ kind = 'Unknown'; detail = 'manufacturer and model unavailable' }
    }
    return [pscustomobject]@{ kind = 'Physical'; detail = "no virtual machine detected ($vendor, $product)" }
}

function Get-WinLeanEvidenceEnvironment {
    <#
    .SYNOPSIS
        Describes where a capture runs: Windows edition, version, build, UBR and whether
        the machine is a VM or Windows Sandbox. Read-only.
    #>
    [CmdletBinding()]
    param()

    $platform = Get-WinLeanPlatform
    $manufacturer = $null
    $model = $null
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $manufacturer = [string]$system.Manufacturer
        $model = [string]$system.Model
    }
    catch {
        Write-Verbose "Win32_ComputerSystem is unavailable: $($_.Exception.Message)"
    }
    $kind = Get-WinLeanEnvironmentKind -Manufacturer $manufacturer -Model $model -UserName ([Environment]::UserName)
    return [pscustomobject]@{
        productName    = $platform.productName
        editionId      = $platform.editionId
        displayVersion = $platform.displayVersion
        build          = $platform.build
        ubr            = $platform.ubr
        architecture   = $platform.architecture
        kind           = $kind.kind
        detail         = $kind.detail
        confirmedBy    = 'Detection'
    }
}

# ---------------------------------------------------------------------------
# Attribution
# ---------------------------------------------------------------------------

function ConvertTo-WinLeanSnapshotIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Snapshot)

    $values = New-WinLeanDictionary
    foreach ($entry in @($Snapshot.values)) {
        $values[$entry.key + $script:Separator + $entry.name] = $entry
    }
    $keys = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($Snapshot.keys)) {
        [void]$keys.Add([string]$key)
    }
    return [pscustomobject]@{ values = $values; keys = $keys }
}

function Get-WinLeanIndexedState {
    <#
    .SYNOPSIS
        The state of a value in an indexed snapshot ("not set" when absent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Index,
        [Parameter(Mandatory)] [string] $Id
    )

    if ($Index.values.ContainsKey($Id)) {
        return $Index.values[$Id].state
    }
    return [pscustomobject]@{ keyExists = $true; valueExists = $false; valueType = $null; value = $null; restorable = $true; missingKeyRoot = $null }
}

function Get-WinLeanEvidenceAttribution {
    <#
    .SYNOPSIS
        Decides which registry changes are attributable to the toggle. Pure function.
    .PARAMETER BaselineStart
        Snapshot taken first, before the baseline wait.
    .PARAMETER Before
        Snapshot at the end of the baseline wait: the state before the first switch.
    .PARAMETER Cycles
        One object per cycle with 'applied' (snapshot after switching to the rule's state)
        and 'reversed' (snapshot after switching back).
    .OUTPUTS
        One finding per value or key that changed at any point, with a classification:
          Attributable  changed on every switch, came back exactly on every switch back,
                        changed the same way every time, and did not change during the
                        baseline
          Churn         changed during the baseline, while nobody touched the system
          NotReversed   did not return to its previous state when the toggle was switched back
          Inconsistent  changed differently from one cycle to the next (counters, timestamps)
          Other         changed, but not as a result of switching the toggle
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $BaselineStart,
        [Parameter(Mandatory)] $Before,
        [Parameter(Mandatory)] [object[]] $Cycles
    )

    $start = ConvertTo-WinLeanSnapshotIndex -Snapshot $BaselineStart
    $initial = ConvertTo-WinLeanSnapshotIndex -Snapshot $Before
    $phases = @(foreach ($cycle in $Cycles) {
            [pscustomobject]@{
                applied  = ConvertTo-WinLeanSnapshotIndex -Snapshot $cycle.applied
                reversed = ConvertTo-WinLeanSnapshotIndex -Snapshot $cycle.reversed
            }
        })

    # Every value and key seen in any snapshot, in first-seen order.
    $valueIds = New-Object -TypeName System.Collections.Generic.List[string]
    $keyIds = New-Object -TypeName System.Collections.Generic.List[string]
    $seenValues = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $seenKeys = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($index in @($start, $initial) + @($phases | ForEach-Object { $_.applied; $_.reversed })) {
        foreach ($id in @($index.values.Keys)) { if ($seenValues.Add($id)) { $valueIds.Add($id) } }
        foreach ($key in $index.keys) { if ($seenKeys.Add($key)) { $keyIds.Add($key) } }
    }

    $findings = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($id in $valueIds) {
        $beforeState = Get-WinLeanIndexedState -Index $initial -Id $id
        $churn = -not (Test-WinLeanRegistryStateEqual -Expected (Get-WinLeanIndexedState -Index $start -Id $id) -Actual $beforeState)
        $changedOnSwitch = $true
        $reversedEveryTime = $true
        $consistent = $true
        $changedAnywhere = $churn
        $firstApplied = $null
        $finalState = $beforeState
        foreach ($phase in $phases) {
            $appliedState = Get-WinLeanIndexedState -Index $phase.applied -Id $id
            $reversedState = Get-WinLeanIndexedState -Index $phase.reversed -Id $id
            $finalState = $reversedState
            $applyChanged = -not (Test-WinLeanRegistryStateEqual -Expected $beforeState -Actual $appliedState)
            $reverseRestored = Test-WinLeanRegistryStateEqual -Expected $beforeState -Actual $reversedState
            if ($applyChanged -or -not $reverseRestored) { $changedAnywhere = $true }
            if (-not $applyChanged) { $changedOnSwitch = $false }
            if (-not $reverseRestored) { $reversedEveryTime = $false }
            if ($null -eq $firstApplied) {
                $firstApplied = $appliedState
            }
            elseif (-not (Test-WinLeanRegistryStateEqual -Expected $firstApplied -Actual $appliedState)) {
                $consistent = $false
            }
        }
        if (-not $changedAnywhere) { continue }

        $classification = if ($churn) { 'Churn' }
        elseif ($changedOnSwitch -and $reversedEveryTime -and $consistent) { 'Attributable' }
        elseif ($changedOnSwitch -and -not $consistent) { 'Inconsistent' }
        elseif ($changedOnSwitch) { 'NotReversed' }
        else { 'Other' }
        # IndexOf(char) is ordinal; IndexOf(string) would compare culture-sensitively, and
        # the NUL separator is ignorable in culture-sensitive comparisons.
        $separator = $id.IndexOf([char]0)
        $findings.Add([pscustomobject]@{
                kind           = 'Value'
                key            = $id.Substring(0, $separator)
                name           = $id.Substring($separator + 1)
                classification = $classification
                before         = Format-WinLeanRegistryState -State $beforeState
                applied        = Format-WinLeanRegistryState -State $firstApplied
                final          = Format-WinLeanRegistryState -State $finalState
                beforeState    = $beforeState
                appliedState   = $firstApplied
            })
    }

    foreach ($key in $keyIds) {
        $existedBefore = $initial.keys.Contains($key)
        $churn = ($start.keys.Contains($key) -ne $existedBefore)
        $changedOnSwitch = $true
        $reversedEveryTime = $true
        $changedAnywhere = $churn
        $finalExists = $existedBefore
        foreach ($phase in $phases) {
            $applied = $phase.applied.keys.Contains($key)
            $reversed = $phase.reversed.keys.Contains($key)
            $finalExists = $reversed
            if ($applied -eq $existedBefore) { $changedOnSwitch = $false }
            if ($reversed -ne $existedBefore) { $reversedEveryTime = $false }
            if ($applied -ne $existedBefore -or $reversed -ne $existedBefore) { $changedAnywhere = $true }
        }
        if (-not $changedAnywhere) { continue }
        $classification = if ($churn) { 'Churn' } elseif ($changedOnSwitch -and $reversedEveryTime) { 'Attributable' } elseif ($changedOnSwitch) { 'NotReversed' } else { 'Other' }
        $describe = { param([bool] $Exists) if ($Exists) { 'key exists' } else { 'key missing' } }
        $findings.Add([pscustomobject]@{
                kind           = 'Key'
                key            = $key
                name           = $null
                classification = $classification
                before         = & $describe $existedBefore
                applied        = & $describe (-not $existedBefore)
                final          = & $describe $finalExists
                beforeState    = $null
                appliedState   = $null
            })
    }
    $findings.ToArray()
}

function ConvertTo-WinLeanEvidenceResourceSuggestion {
    <#
    .SYNOPSIS
        Draft RegistryValue resources (JSON) for attributable per-user values. The reviewer
        decides which of them, if any, the rule uses.
    .NOTES
        Only HKCU values outside \Policies\ are suggested: rules backed only by an
        observation may not change anything else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings)

    foreach ($finding in $Findings) {
        if ($finding.kind -cne 'Value' -or $finding.classification -cne 'Attributable') { continue }
        if (-not $finding.key.StartsWith('HKCU:\', [System.StringComparison]::OrdinalIgnoreCase) -or
            (Test-WinLeanTextContains -Text ($finding.key + '\') -Value '\Policies\')) { continue }
        $resource = [ordered]@{ type = 'RegistryValue'; path = $finding.key; name = $finding.name }
        $state = $finding.appliedState
        if (-not [bool]$state.valueExists) {
            $resource['ensure'] = 'Absent'
        }
        elseif (-not [bool]$state.restorable) {
            continue
        }
        else {
            $resource['valueType'] = [string]$state.valueType
            $resource['value'] = if ($state.valueType -ceq 'MultiString') { , [string[]]@($state.value) } else { $state.value }
        }
        ConvertTo-Json -InputObject $resource -Compress -Depth 5
    }
}

# ---------------------------------------------------------------------------
# Write-up
# ---------------------------------------------------------------------------

function ConvertTo-WinLeanEvidenceCell {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function ConvertTo-WinLeanEvidenceMarkdown {
    <#
    .SYNOPSIS
        Builds the evidence write-up for Docs/Evidence/<rule-id>.md from a capture
        (Invoke-WinLeanEvidenceCapture).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Capture)

    $environment = $Capture.environment
    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    $add = { param([string] $Line = '') $lines.Add($Line) }
    $cell = { param($Value) ConvertTo-WinLeanEvidenceCell -Value $Value }

    & $add "# Evidence: $($Capture.ruleId)"
    & $add
    & $add ('> Status: **{0}**. Draft written by Tools/Capture-WinLeanEvidence.ps1; a reviewer must complete the conclusion before a rule may reference it.' -f $Capture.quality)
    & $add
    & $add '| Item | Value |'
    & $add '|---|---|'
    & $add ('| Setting | {0} |' -f (& $cell $Capture.setting))
    & $add ('| Rule state | {0} (switched back to: {1}) |' -f (& $cell $Capture.targetState), (& $cell $Capture.originalState))
    & $add ('| Windows | {0}, edition {1}, version {2} |' -f (& $cell $environment.productName), (& $cell $environment.editionId), (& $cell $environment.displayVersion))
    & $add ('| Build | {0}.{1} ({2}) |' -f $environment.build, $environment.ubr, (& $cell $environment.architecture))
    $confirmation = if ($environment.confirmedBy -ceq 'Operator') { ' - not detected automatically; confirmed as disposable by the operator' } else { '' }
    & $add ('| Environment | {0}: {1}{2} |' -f $environment.kind, (& $cell $environment.detail), $confirmation)
    & $add '| Method | RegistryDiff (read-only snapshots; the operator switched the toggle in the Settings app) |'
    & $add ('| Recorded | {0} |' -f (Format-WinLeanTimestamp -Value $Capture.recordedAt))
    & $add ('| Baseline | {0} s without any action |' -f $Capture.baselineSeconds)
    & $add ('| Cycles | {0} (switch to the rule state, then back) |' -f @($Capture.cycles).Count)
    & $add
    & $add '## Watched keys'
    & $add
    foreach ($path in @($Capture.paths)) { & $add ('- `{0}`' -f $path) }
    if (@($Capture.inaccessible).Count -gt 0) {
        & $add
        & $add ('Not readable (excluded): ' + ((@($Capture.inaccessible) | ForEach-Object { '`' + $_ + '`' }) -join ', '))
    }

    $sections = @([pscustomobject]@{ title = 'Baseline: no action (background churn)'; changes = $Capture.baselineChanges })
    $cycleNumber = 0
    foreach ($cycle in @($Capture.cycles)) {
        $cycleNumber++
        $sections += [pscustomobject]@{ title = "Cycle $($cycleNumber): switched to '$($Capture.targetState)'"; changes = $cycle.appliedChanges }
        $sections += [pscustomobject]@{ title = "Cycle $($cycleNumber): switched back to '$($Capture.originalState)'"; changes = $cycle.reversedChanges }
    }
    foreach ($section in $sections) {
        & $add
        & $add "## $($section.title)"
        & $add
        if (@($section.changes).Count -eq 0) {
            & $add 'No registry changes in the watched keys.'
            continue
        }
        & $add '| Change | Location | Before | After |'
        & $add '|---|---|---|---|'
        foreach ($change in @($section.changes)) {
            $location = if ($change.name) { "$($change.key)\$($change.name)" } else { $change.key }
            & $add ('| {0} | `{1}` | {2} | {3} |' -f $change.change, (& $cell $location), (& $cell $change.before), (& $cell $change.after))
        }
    }

    $attributable = @($Capture.findings | Where-Object { $_.classification -ceq 'Attributable' })
    $other = @($Capture.findings | Where-Object { $_.classification -cne 'Attributable' })
    & $add
    & $add '## Attribution'
    & $add
    & $add 'A change is attributable to the toggle only when it happened on every switch to the rule state, was reversed exactly on every switch back, was the same every time, and did not occur during the baseline. Everything else is not evidence.'
    & $add
    if ($attributable.Count -eq 0) {
        & $add 'No change is attributable to the toggle. This capture does not support a rule.'
    }
    else {
        & $add '| Location | Before | Rule state | Final |'
        & $add '|---|---|---|---|'
        foreach ($finding in $attributable) {
            $location = if ($finding.name) { "$($finding.key)\$($finding.name)" } else { $finding.key }
            & $add ('| `{0}` | {1} | {2} | {3} |' -f (& $cell $location), (& $cell $finding.before), (& $cell $finding.applied), (& $cell $finding.final))
        }
    }
    if ($other.Count -gt 0) {
        & $add
        & $add 'Not attributable:'
        & $add
        & $add '| Location | Reason | Before | Rule state | Final |'
        & $add '|---|---|---|---|---|'
        $reasons = @{
            Churn        = 'changed during the baseline (background churn)'
            NotReversed  = 'not restored when the toggle was switched back'
            Inconsistent = 'changed differently in each cycle'
            Other        = 'changed without a matching switch'
        }
        foreach ($finding in $other) {
            $location = if ($finding.name) { "$($finding.key)\$($finding.name)" } else { $finding.key }
            & $add ('| `{0}` | {1} | {2} | {3} | {4} |' -f (& $cell $location), $reasons[[string]$finding.classification], (& $cell $finding.before), (& $cell $finding.applied), (& $cell $finding.final))
        }
    }

    $suggestions = @(ConvertTo-WinLeanEvidenceResourceSuggestion -Findings @($Capture.findings))
    & $add
    & $add '## Draft resources'
    & $add
    if ($suggestions.Count -eq 0) {
        & $add 'None (no attributable per-user value outside \Policies\).'
    }
    else {
        & $add 'For review only; a rule backed only by this observation may use per-user values outside `\Policies\`:'
        & $add
        & $add '```json'
        foreach ($suggestion in $suggestions) { & $add $suggestion }
        & $add '```'
    }

    & $add
    & $add '## Conclusion (reviewer)'
    & $add
    & $add '- [ ] The setting above is the Settings page and toggle the rule describes.'
    & $add '- [ ] The capture ran in a disposable VM or Windows Sandbox, never on a primary workstation.'
    & $add '- [ ] The rule changes only values listed as attributable, to their "rule state".'
    & $add '- [ ] Every value that is not attributable was reviewed and is not needed by the rule.'
    & $add ('- [ ] The rule''s `windows.maxValidatedBuild` is not newer than build {0}.' -f $environment.build)
    & $add
    & $add 'Reviewer: _name_ - Date: _yyyy-MM-dd_ - Notes: _..._'
    & $add
    return ($lines.ToArray() -join "`n")
}

# ---------------------------------------------------------------------------
# Capture workflow
# ---------------------------------------------------------------------------

function Invoke-WinLeanEvidenceCapture {
    <#
    .SYNOPSIS
        Runs the read-only evidence capture: baseline, toggle cycles performed by the
        operator, attribution and write-up.
    .PARAMETER Prompt
        Script block that shows an instruction and waits until the operator has done it.
    .PARAMETER WriteLine
        Script block that shows one line of progress text.
    .PARAMETER Snapshot
        Script block (paths, depth) -> snapshot. Defaults to Get-WinLeanRegistrySnapshot.
    .PARAMETER Wait
        Script block (seconds) used for the baseline wait. Defaults to Start-Sleep.
    .PARAMETER Environment
        The environment description (Get-WinLeanEvidenceEnvironment) - detected when omitted.
    .PARAMETER ConfirmDisposableEnvironment
        Run although no VM or Windows Sandbox was detected: the operator confirms that the
        machine is disposable (recorded in the write-up). Never use it on a primary
        workstation.
    .OUTPUTS
        The capture object, including the Markdown write-up (property 'markdown').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RuleId,
        [Parameter(Mandatory)] [string] $Setting,
        [Parameter(Mandatory)] [string] $TargetState,
        [string] $OriginalState = 'its previous state',
        [Parameter(Mandatory)] [string[]] $Path,
        [ValidateRange(0, 10)] [int] $Depth = 2,
        [ValidateRange(0, 600)] [int] $BaselineSeconds = 15,
        [ValidateRange(1, 5)] [int] $Cycles = 1,
        [Parameter(Mandatory)] [scriptblock] $Prompt,
        [Parameter(Mandatory)] [scriptblock] $WriteLine,
        [scriptblock] $Snapshot = { param($Paths, $SnapshotDepth) Get-WinLeanRegistrySnapshot -Path $Paths -Depth $SnapshotDepth },
        [scriptblock] $Wait = { param($Seconds) Start-Sleep -Seconds $Seconds },
        $Environment,
        [switch] $ConfirmDisposableEnvironment
    )

    if ($null -eq $Environment) {
        $Environment = Get-WinLeanEvidenceEnvironment
    }
    if (@('VirtualMachine', 'WindowsSandbox') -cnotcontains [string]$Environment.kind) {
        if (-not $ConfirmDisposableEnvironment) {
            throw (New-Object -TypeName System.InvalidOperationException -ArgumentList ("No virtual machine or Windows Sandbox was detected ($($Environment.detail)). " +
                    'Evidence must be captured in a disposable VM or Windows Sandbox, never on a primary workstation. ' +
                    'If this machine is a disposable VM that was not recognized, re-run with -ConfirmDisposableEnvironment.'))
        }
        $Environment = [pscustomobject]@{
            productName    = $Environment.productName
            editionId      = $Environment.editionId
            displayVersion = $Environment.displayVersion
            build          = $Environment.build
            ubr            = $Environment.ubr
            architecture   = $Environment.architecture
            kind           = $Environment.kind
            detail         = $Environment.detail
            confirmedBy    = 'Operator'
        }
    }

    & $WriteLine ("Windows: {0}, edition {1}, version {2}, build {3}.{4}" -f $Environment.productName, $Environment.editionId, $Environment.displayVersion, $Environment.build, $Environment.ubr)
    & $WriteLine ("Environment: {0} ({1})" -f $Environment.kind, $Environment.detail)
    & $WriteLine "Setting: $Setting"
    & $WriteLine ''

    $baselineStart = & $Snapshot $Path $Depth
    & $WriteLine ("Baseline: {0} values in {1} keys. Waiting {2} s without any action to detect background churn - do not touch the system." -f @($baselineStart.values).Count, @($baselineStart.keys).Count, $BaselineSeconds)
    if ($BaselineSeconds -gt 0) {
        & $Wait $BaselineSeconds
    }
    $before = & $Snapshot $Path $Depth
    $baselineChanges = @(Compare-WinLeanRegistrySnapshot -Before $baselineStart -After $before)
    & $WriteLine ("Background churn during the baseline: {0} change(s)." -f $baselineChanges.Count)

    $cycleResults = New-Object -TypeName System.Collections.Generic.List[object]
    $previous = $before
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        & $Prompt ("[{0}/{1}] In the Settings app, switch '{2}' to '{3}'. Press Enter when the Settings app shows the new state" -f $cycle, $Cycles, $Setting, $TargetState)
        $applied = & $Snapshot $Path $Depth
        $appliedChanges = @(Compare-WinLeanRegistrySnapshot -Before $previous -After $applied)
        & $WriteLine "Changes after switching to '$TargetState':"
        foreach ($line in @(Format-WinLeanRegistryChange -Changes $appliedChanges)) { & $WriteLine $line }

        & $Prompt ("[{0}/{1}] Now switch '{2}' back to '{3}'. Press Enter when done" -f $cycle, $Cycles, $Setting, $OriginalState)
        $reversed = & $Snapshot $Path $Depth
        $reversedChanges = @(Compare-WinLeanRegistrySnapshot -Before $applied -After $reversed)
        & $WriteLine "Changes after switching back to '$OriginalState':"
        foreach ($line in @(Format-WinLeanRegistryChange -Changes $reversedChanges)) { & $WriteLine $line }

        $cycleResults.Add([pscustomobject]@{ applied = $applied; reversed = $reversed; appliedChanges = $appliedChanges; reversedChanges = $reversedChanges })
        $previous = $reversed
    }

    $findings = @(Get-WinLeanEvidenceAttribution -BaselineStart $baselineStart -Before $before -Cycles $cycleResults.ToArray())
    $attributable = @($findings | Where-Object { $_.classification -ceq 'Attributable' })
    $quality = if ($attributable.Count -gt 0) { 'Candidate - attributable changes found' } else { 'Insufficient - no change is attributable to the toggle' }
    $inaccessible = @(@($baselineStart.inaccessible) + @($before.inaccessible) | Where-Object { $_ } | Select-Object -Unique)

    $capture = [pscustomobject]@{
        ruleId          = $RuleId
        setting         = $Setting
        targetState     = $TargetState
        originalState   = $OriginalState
        environment     = $Environment
        recordedAt      = Get-WinLeanTimestamp
        paths           = $Path
        depth           = $Depth
        baselineSeconds = $BaselineSeconds
        inaccessible    = $inaccessible
        baselineChanges = $baselineChanges
        cycles          = $cycleResults.ToArray()
        findings        = $findings
        quality         = $quality
        markdown        = $null
    }
    $capture.markdown = ConvertTo-WinLeanEvidenceMarkdown -Capture $capture
    & $WriteLine ''
    & $WriteLine ("Attributable to the toggle: {0} change(s). Status: {1}." -f $attributable.Count, $quality)
    return $capture
}

Export-ModuleMember -Function @(
    'Get-WinLeanRegistrySnapshot'
    'Compare-WinLeanRegistrySnapshot'
    'Format-WinLeanRegistryChange'
    'Get-WinLeanEnvironmentKind'
    'Get-WinLeanEvidenceEnvironment'
    'Get-WinLeanEvidenceAttribution'
    'ConvertTo-WinLeanEvidenceResourceSuggestion'
    'ConvertTo-WinLeanEvidenceMarkdown'
    'Invoke-WinLeanEvidenceCapture'
)