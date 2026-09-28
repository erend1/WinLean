#Requires -Version 5.1
<#
    WinLean.Restore
    ---------------
    Reverses the changes recorded in a backup, using the recorded previous values -
    never assumed Windows defaults.

    For every recorded change (newest first) the current value is compared with:

      before   the value recorded before WinLean changed it
      desired  the value WinLean wrote

    and one action is chosen:

      None      the value already equals 'before'; nothing to do
      Restore   the value still equals 'desired' (WinLean's value): write 'before' back
      Skip      the value changed since WinLean applied it (someone or something else set
                it); it is left alone unless -Force is given
      Blocked   restoring is not possible here: another user's per-user value, missing
                write access, an unreadable value or an unrestorable recorded state

    Every restored value is verified by reading it again.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Logging.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Providers\WinLean.Providers.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Backup.psm1')

function Get-WinLeanRestoreDecision {
    <#
    .SYNOPSIS
        Decides what to do with one recorded change, given the current state. Pure function.
    .PARAMETER SameUser
        $false when the change was recorded by another user account (per-user values of
        that account cannot be restored from this account).
    .PARAMETER Writable
        $false when the current process cannot write the value; $null when unknown.
    .OUTPUTS
        Object with action (None, Restore, Skip, Blocked), reason and requiresAdministrator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Change,
        [Parameter(Mandatory)] $Current,
        [bool] $SameUser = $true,
        [AllowNull()] $Writable = $null,
        [bool] $IsAdministrator = $false,
        [switch] $Force
    )

    $type = [string]$Change.resource.type
    $decision = {
        param([string] $Action, [string] $Reason, [bool] $RequiresAdministrator = $false)
        [pscustomobject]@{ action = $Action; reason = $Reason; requiresAdministrator = $RequiresAdministrator }
    }

    if ([string]$Change.scope -ne 'Machine' -and -not $SameUser) {
        return & $decision 'Blocked' 'This per-user value was recorded for another user account. Run the restore as that user.'
    }
    if (Test-WinLeanResourceStateEqual -Type $type -Expected $Change.before -Actual $Current) {
        return & $decision 'None' 'Already has the recorded previous value.'
    }
    if (-not (Test-WinLeanResourceStateRestorable -Type $type -State $Change.before)) {
        return & $decision 'Blocked' 'The recorded previous value cannot be written back by WinLean.'
    }
    $holdsWinLeanValue = Test-WinLeanResourceStateEqual -Type $type -Expected $Change.desired -Actual $Current
    if (-not $holdsWinLeanValue -and -not $Force) {
        return & $decision 'Skip' 'The value changed after WinLean applied it. It is left alone so that a newer change is not overwritten; use -Force to restore it anyway.'
    }
    if ($Writable -eq $false) {
        if ($IsAdministrator) {
            return & $decision 'Blocked' 'Access denied, even with Administrator rights.'
        }
        return & $decision 'Blocked' 'Requires Administrator: no write access. Run the restore from an elevated PowerShell.' $true
    }
    if ($holdsWinLeanValue) {
        return & $decision 'Restore' 'Restore the value WinLean replaced.'
    }
    return & $decision 'Restore' 'The value changed after WinLean applied it; restoring anyway because -Force was specified.'
}

function Get-WinLeanRestorePlan {
    <#
    .SYNOPSIS
        Evaluates every recorded change of a backup (newest first). Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Backup')] $Backup,
        [Parameter(Mandatory)] $Identity,
        [switch] $Force
    )

    $recordedUser = Get-WinLeanProperty -InputObject $Backup.manifest -Name 'user'
    $recordedSid = [string](Get-WinLeanProperty -InputObject $recordedUser -Name 'sid' -Default '')
    $sameUser = [string]::Equals($recordedSid, [string]$Identity.sid, [System.StringComparison]::OrdinalIgnoreCase)

    $changes = @($Backup.changes)
    $keys = [int[]]@($changes | ForEach-Object { [int]$_.sequence })
    [System.Array]::Sort($keys, $changes)
    [System.Array]::Reverse($changes)

    $items = @(foreach ($change in $changes) {
            $type = [string]$change.resource.type
            $current = $null
            $currentText = 'unknown'
            try {
                $current = Get-WinLeanResourceState -Resource $change.resource
                $currentText = Format-WinLeanResourceState -Type $type -State $current
                $writable = Test-WinLeanResourceAccess -Resource $change.resource
                $decision = Get-WinLeanRestoreDecision -Change $change -Current $current -SameUser $sameUser -Writable $writable -IsAdministrator ([bool]$Identity.isAdministrator) -Force:$Force
            }
            catch {
                $failure = ConvertTo-WinLeanFailure -ErrorObject $_
                $decision = [pscustomobject]@{ action = 'Blocked'; reason = "The current value could not be read ($($failure.class)): $($failure.message)"; requiresAdministrator = $false }
            }
            [pscustomobject]@{
                sequence              = [int]$change.sequence
                ruleId                = [string]$change.ruleId
                target                = [string]$change.target
                scope                 = [string]$change.scope
                resource              = $change.resource
                before                = $change.before
                desired               = $change.desired
                current               = $current
                beforeText            = Format-WinLeanResourceState -Type $type -State $change.before
                desiredText           = Format-WinLeanResourceState -Type $type -State $change.desired
                currentText           = $currentText
                action                = $decision.action
                reason                = $decision.reason
                requiresAdministrator = [bool]$decision.requiresAdministrator
            }
        })

    $summary = [ordered]@{}
    foreach ($action in @('Restore', 'None', 'Skip', 'Blocked')) {
        $summary[$action] = @($items | Where-Object { $_.action -eq $action }).Count
    }
    return [pscustomobject]@{
        PSTypeName = 'WinLean.RestorePlan'
        backupId   = $Backup.id
        backupPath = $Backup.path
        profile    = [string](Get-WinLeanProperty -InputObject $Backup.manifest -Name 'profile' -Default '')
        createdAt  = Get-WinLeanProperty -InputObject $Backup.manifest -Name 'createdAt'
        recordedBy = [string](Get-WinLeanProperty -InputObject $recordedUser -Name 'name' -Default '')
        sameUser   = $sameUser
        force      = [bool]$Force
        items      = $items
        summary    = [pscustomobject]$summary
    }
}

function New-WinLeanRestoreItemResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [ValidateSet('Restored', 'NotNeeded', 'Skipped', 'Blocked', 'Failed')] [string] $Status,
        [Parameter(Mandatory)] [string] $Reason,
        $After,
        $Failure
    )

    return [pscustomobject]@{
        sequence = $Item.sequence
        ruleId   = $Item.ruleId
        target   = $Item.target
        status   = $Status
        reason   = $Reason
        before   = $Item.before
        after    = $After
        failure  = $Failure
    }
}

function Invoke-WinLeanRestorePlan {
    <#
    .SYNOPSIS
        Executes a restore plan, verifies every restored value and records the result in
        the backup (restore-<runId>.json and the manifest).
    .NOTES
        Each Restore item is re-checked immediately before writing, because the system may
        have changed since the plan was shown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.RestorePlan')] $RestorePlan,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Logger')] $Logger
    )

    $startedAt = Get-WinLeanTimestamp
    $results = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($item in $RestorePlan.items) {
        # Note: 'continue' inside a switch statement would not continue this loop, so the
        # non-restore actions are handled with if statements.
        if ($item.action -eq 'None') {
            $results.Add((New-WinLeanRestoreItemResult -Item $item -Status NotNeeded -Reason $item.reason -After $item.current))
            continue
        }
        if ($item.action -eq 'Skip') {
            Write-WinLeanLog -Logger $Logger -Tag SKIP -Message $item.target -Detail $item.reason
            $results.Add((New-WinLeanRestoreItemResult -Item $item -Status Skipped -Reason $item.reason -After $item.current))
            continue
        }
        if ($item.action -ne 'Restore') {
            Write-WinLeanLog -Logger $Logger -Level WARN -Tag BLOCKED -Message $item.target -Detail $item.reason
            $results.Add((New-WinLeanRestoreItemResult -Item $item -Status Blocked -Reason $item.reason -After $item.current))
            continue
        }

        $type = [string]$item.resource.type
        Write-WinLeanLog -Logger $Logger -Tag RESTORE -Message "$($item.target) -> $($item.beforeText)" -Data @{ ruleId = $item.ruleId; sequence = $item.sequence }
        try {
            $current = Get-WinLeanResourceState -Resource $item.resource
            if (Test-WinLeanResourceStateEqual -Type $type -Expected $item.before -Actual $current) {
                $results.Add((New-WinLeanRestoreItemResult -Item $item -Status NotNeeded -Reason 'Already has the recorded previous value.' -After $current))
                continue
            }
            if (-not $RestorePlan.force -and -not (Test-WinLeanResourceStateEqual -Type $type -Expected $item.desired -Actual $current)) {
                $reason = 'The value changed after the restore plan was created; it was left alone.'
                Write-WinLeanLog -Logger $Logger -Tag SKIP -Message $item.target -Detail $reason
                $results.Add((New-WinLeanRestoreItemResult -Item $item -Status Skipped -Reason $reason -After $current))
                continue
            }

            Restore-WinLeanResource -Resource $item.resource -State $item.before
            $after = Get-WinLeanResourceState -Resource $item.resource
            if (Test-WinLeanResourceStateEqual -Type $type -Expected $item.before -Actual $after) {
                Write-WinLeanLog -Logger $Logger -Tag OK -Message 'Verified'
                $results.Add((New-WinLeanRestoreItemResult -Item $item -Status Restored -Reason $item.reason -After $after))
            }
            else {
                $failure = [pscustomobject]@{
                    class     = 'VerificationFailed'
                    message   = "Expected $($item.beforeText), found $(Format-WinLeanResourceState -Type $type -State $after)."
                    exception = $null
                    hresult   = $null
                }
                Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message $item.target -Detail $failure.message
                $results.Add((New-WinLeanRestoreItemResult -Item $item -Status Failed -Reason 'Verification failed.' -After $after -Failure $failure))
            }
        }
        catch {
            $failure = ConvertTo-WinLeanFailure -ErrorObject $_
            Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($item.target): $($failure.class)" -Detail $failure.message
            $results.Add((New-WinLeanRestoreItemResult -Item $item -Status Failed -Reason $failure.message -Failure $failure))
        }
    }

    $all = $results.ToArray()
    $counts = [ordered]@{}
    foreach ($status in @('Restored', 'NotNeeded', 'Skipped', 'Blocked', 'Failed')) {
        $counts[$status] = @($all | Where-Object { $_.status -eq $status }).Count
    }
    $overall = 'Restored'
    if ($counts['Failed'] -gt 0 -or $counts['Blocked'] -gt 0) {
        $overall = 'Incomplete'
    }
    elseif ($counts['Skipped'] -gt 0) {
        $overall = 'RestoredWithSkips'
    }

    $record = [pscustomobject]@{
        PSTypeName    = 'WinLean.RestoreResult'
        schemaVersion = 1
        runId         = $RunId
        backupId      = $RestorePlan.backupId
        backupPath    = $RestorePlan.backupPath
        startedAt     = $startedAt
        completedAt   = Get-WinLeanTimestamp
        force         = $RestorePlan.force
        status        = $overall
        summary       = [pscustomobject]$counts
        results       = $all
    }
    try {
        Add-WinLeanBackupFile -Path $RestorePlan.backupPath -FileName ("restore-{0}.json" -f $RunId) -InputObject $record
        [void](Update-WinLeanBackupManifest -Path $RestorePlan.backupPath -Values @{
                restore = [pscustomobject]@{ status = $overall; restoredAt = $record.completedAt; lastRestoreRunId = $RunId }
            })
    }
    catch {
        Write-WinLeanLog -Logger $Logger -Level ERROR -Message "The restore result could not be recorded in '$($RestorePlan.backupPath)': $($_.Exception.Message)"
    }
    return $record
}

Export-ModuleMember -Function @(
    'Get-WinLeanRestoreDecision'
    'Get-WinLeanRestorePlan'
    'Invoke-WinLeanRestorePlan'
)
