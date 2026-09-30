#Requires -Version 5.1
<#
    WinLean.Backup
    --------------
    Backups record exactly the state WinLean needs to reverse its own changes; they are
    not system backups.

    Layout of Backups\<backupId>\ :

      manifest.json          metadata, status and restore status
      changes.json           ordered before-state of every resource WinLean may change;
                             written BEFORE the first change and never modified afterwards
      plan.json              the confirmed execution plan
      inventory.json         system inventory at backup time (when collected)
      benchmark-before.json  baseline benchmark (when collected)
      execution.json         per-rule results; rewritten atomically after every rule
      restore-<runId>.json   one file per restore run

    Because changes.json is complete before anything is modified, a backup can be
    restored even if WinLean was interrupted halfway: restore compares every resource
    with its recorded before and desired state and only acts where WinLean's value is
    still present.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')

$script:BackupIdPattern = '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d{1,3})?$'
$script:RestorableStatuses = @('InProgress', 'Completed', 'CompletedWithFailures')
$script:FinishedRestoreStatuses = @('Restored', 'RestoredWithSkips')

function Test-WinLeanBackupId {
    <#
    .SYNOPSIS
        Returns $true for a well-formed backup id (also prevents path traversal).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [string] $Id)

    return (Test-WinLeanPattern -Text $Id -Pattern $script:BackupIdPattern -CaseSensitive)
}

function New-WinLeanChangeRecords {
    <#
    .SYNOPSIS
        Converts the state of a rule (Get-WinLeanRuleState output) into change records.
    .PARAMETER StartSequence
        Sequence number of the first record. Restore processes records in reverse order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [int] $StartSequence
    )

    $sequence = $StartSequence
    foreach ($resourceState in $State.resources) {
        [pscustomobject]@{
            sequence       = $sequence
            ruleId         = $Rule.id
            resourceIndex  = $resourceState.index
            resource       = $Rule.resources[$resourceState.index]
            identity       = $resourceState.identity
            target         = $resourceState.target
            scope          = $resourceState.scope
            # The rule's declaration; used by restore when a provider cannot tell whether
            # writing the previous state back needs a restart.
            requiresReboot = [bool]$Rule.requiresReboot
            before         = $resourceState.current
            desired        = $resourceState.desired
        }
        $sequence++
    }
}

function New-WinLeanBackup {
    <#
    .SYNOPSIS
        Creates a backup directory and writes everything needed to reverse the planned
        changes. Must complete successfully before WinLean modifies anything.
    .OUTPUTS
        WinLean.Backup with id, path and manifest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $BackupId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Changes,
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] $Identity,
        $Platform,
        $Inventory,
        $Benchmark
    )

    if (-not (Test-WinLeanBackupId -Id $BackupId)) {
        throw (New-Object -TypeName System.ArgumentException -ArgumentList "Invalid backup id '$BackupId'.")
    }
    $rootPath = Resolve-WinLeanPath -Path $Root
    if (-not [System.IO.Directory]::Exists($rootPath)) {
        [void][System.IO.Directory]::CreateDirectory($rootPath)
    }

    # Never reuse a directory: add a suffix when two runs start within the same second.
    $id = $BackupId
    $suffix = 1
    while ([System.IO.Directory]::Exists((Join-Path -Path $rootPath -ChildPath $id))) {
        $suffix++
        $id = '{0}_{1}' -f $BackupId, $suffix
    }
    $path = Join-Path -Path $rootPath -ChildPath $id
    [void][System.IO.Directory]::CreateDirectory($path)

    $createdAt = Get-WinLeanTimestamp
    $files = New-Object -TypeName System.Collections.Generic.List[string]
    Write-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'changes.json') -InputObject ([pscustomobject]@{
            schemaVersion = 1
            backupId      = $id
            createdAt     = $createdAt
            changes       = $Changes
        })
    $files.Add('changes.json')
    Write-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'plan.json') -InputObject $Plan
    $files.Add('plan.json')
    if ($null -ne $Inventory) {
        Write-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'inventory.json') -InputObject $Inventory
        $files.Add('inventory.json')
    }
    if ($null -ne $Benchmark) {
        Write-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'benchmark-before.json') -InputObject $Benchmark
        $files.Add('benchmark-before.json')
    }

    $system = $null
    if ($null -ne $Platform) {
        $system = [pscustomobject]@{
            productName    = $Platform.productName
            editionId      = $Platform.editionId
            displayVersion = $Platform.displayVersion
            build          = $Platform.build
            ubr            = $Platform.ubr
        }
    }
    $manifest = [pscustomobject]@{
        schemaVersion    = 1
        backupId         = $id
        createdAt        = $createdAt
        completedAt      = $null
        winLeanVersion   = Get-WinLeanVersion
        profile          = [string]$Plan.profile.name
        planId           = [string](Get-WinLeanProperty -InputObject $Plan -Name 'planId' -Default '')
        user             = [pscustomobject]@{ name = [string]$Identity.name; sid = [string]$Identity.sid }
        isAdministrator  = [bool]$Identity.isAdministrator
        system           = $system
        status           = 'InProgress'
        changeCount      = $Changes.Count
        changedRuleCount = 0
        restore          = [pscustomobject]@{ status = $null; restoredAt = $null; lastRestoreRunId = $null }
        files            = $files.ToArray()
    }
    Write-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'manifest.json') -InputObject $manifest

    return [pscustomobject]@{
        PSTypeName = 'WinLean.Backup'
        id         = $id
        path       = $path
        manifest   = $manifest
    }
}

function Update-WinLeanBackupManifest {
    <#
    .SYNOPSIS
        Updates top-level manifest fields (read, modify, atomic write).
    .EXAMPLE
        Update-WinLeanBackupManifest -Path $backup.path -Values @{ status = 'Completed' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Values
    )

    $manifestPath = Join-Path -Path $Path -ChildPath 'manifest.json'
    $manifest = Read-WinLeanJsonFile -Path $manifestPath
    foreach ($key in $Values.Keys) {
        if ($null -eq $manifest.PSObject.Properties[$key]) {
            $manifest | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key]
        }
        else {
            $manifest.$key = $Values[$key]
        }
    }
    Write-WinLeanJsonFile -Path $manifestPath -InputObject $manifest
    return $manifest
}

function Add-WinLeanBackupFile {
    <#
    .SYNOPSIS
        Writes an additional JSON file into a backup and lists it in the manifest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9._-]+\.json$')] [string] $FileName,
        [Parameter(Mandatory)] [AllowNull()] $InputObject
    )

    Write-WinLeanJsonFile -Path (Join-Path -Path $Path -ChildPath $FileName) -InputObject $InputObject
    $manifest = Read-WinLeanJsonFile -Path (Join-Path -Path $Path -ChildPath 'manifest.json')
    $files = @(Get-WinLeanArrayProperty -InputObject $manifest -Name 'files')
    if ($files -notcontains $FileName) {
        [void](Update-WinLeanBackupManifest -Path $Path -Values @{ files = [string[]]($files + $FileName) })
    }
}

function Get-WinLeanBackupList {
    <#
    .SYNOPSIS
        Lists backups, newest first. Unreadable backups are listed with status Unreadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root
    )

    $rootPath = Resolve-WinLeanPath -Path $Root
    if (-not [System.IO.Directory]::Exists($rootPath)) {
        return
    }
    $directories = @(foreach ($directory in [System.IO.Directory]::GetDirectories($rootPath)) {
            $name = [System.IO.Path]::GetFileName($directory)
            if (Test-WinLeanBackupId -Id $name) { $directory }
        })
    $names = [string[]]@($directories | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    $sorted = [string[]]$directories.Clone()
    [System.Array]::Sort($names, $sorted, [System.StringComparer]::Ordinal)
    [System.Array]::Reverse($sorted)

    foreach ($directory in $sorted) {
        $id = [System.IO.Path]::GetFileName($directory)
        try {
            $manifest = Read-WinLeanJsonFile -Path (Join-Path -Path $directory -ChildPath 'manifest.json')
            [pscustomobject]@{
                id               = $id
                path             = $directory
                createdAt        = $manifest.createdAt
                profile          = $manifest.profile
                status           = $manifest.status
                changeCount      = [int](Get-WinLeanProperty -InputObject $manifest -Name 'changeCount' -Default 0)
                changedRuleCount = [int](Get-WinLeanProperty -InputObject $manifest -Name 'changedRuleCount' -Default 0)
                restoreStatus    = Get-WinLeanProperty -InputObject (Get-WinLeanProperty -InputObject $manifest -Name 'restore') -Name 'status'
                user             = [string](Get-WinLeanProperty -InputObject (Get-WinLeanProperty -InputObject $manifest -Name 'user') -Name 'name')
                manifest         = $manifest
                error            = $null
            }
        }
        catch {
            [pscustomobject]@{
                id               = $id
                path             = $directory
                createdAt        = $null
                profile          = $null
                status           = 'Unreadable'
                changeCount      = 0
                changedRuleCount = 0
                restoreStatus    = $null
                user             = $null
                manifest         = $null
                error            = $_.Exception.Message
            }
        }
    }
}

function Resolve-WinLeanBackupId {
    <#
    .SYNOPSIS
        Resolves 'Latest' (the newest backup that recorded changes and has not been fully
        restored yet) or validates an explicit backup id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Id
    )

    if ($Id -eq 'Latest') {
        foreach ($backup in @(Get-WinLeanBackupList -Root $Root)) {
            if ($script:RestorableStatuses -contains $backup.status -and
                $backup.changeCount -gt 0 -and
                $script:FinishedRestoreStatuses -notcontains $backup.restoreStatus) {
                return $backup.id
            }
        }
        throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "No backup with unrestored changes was found in '$Root'.")
    }
    if (-not (Test-WinLeanBackupId -Id $Id)) {
        throw (New-Object -TypeName System.ArgumentException -ArgumentList "Invalid backup id '$Id'. Use 'Latest' or an id such as 2026-09-27_18-45-12 (see -ListBackups).")
    }
    if (-not [System.IO.Directory]::Exists((Join-Path -Path (Resolve-WinLeanPath -Path $Root) -ChildPath $Id))) {
        throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Backup '$Id' was not found in '$Root'.")
    }
    return $Id
}

function Get-WinLeanBackup {
    <#
    .SYNOPSIS
        Loads a backup: manifest, change records and, when present, plan and execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Id
    )

    $resolvedId = Resolve-WinLeanBackupId -Root $Root -Id $Id
    $path = Join-Path -Path (Resolve-WinLeanPath -Path $Root) -ChildPath $resolvedId
    $manifest = Read-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'manifest.json')
    $changesDocument = Read-WinLeanJsonFile -Path (Join-Path -Path $path -ChildPath 'changes.json')

    $optional = @{}
    foreach ($name in @('plan', 'execution', 'inventory', 'benchmark-before')) {
        $file = Join-Path -Path $path -ChildPath ($name + '.json')
        $optional[$name] = if ([System.IO.File]::Exists($file)) { Read-WinLeanJsonFile -Path $file } else { $null }
    }

    return [pscustomobject]@{
        PSTypeName      = 'WinLean.Backup'
        id              = $resolvedId
        path            = $path
        manifest        = $manifest
        changes         = @(Get-WinLeanArrayProperty -InputObject $changesDocument -Name 'changes')
        plan            = $optional['plan']
        execution       = $optional['execution']
        inventory       = $optional['inventory']
        benchmarkBefore = $optional['benchmark-before']
    }
}

function Enter-WinLeanLock {
    <#
    .SYNOPSIS
        Takes an exclusive lock so that only one apply or restore runs at a time.
    .OUTPUTS
        The open lock stream; pass it to Exit-WinLeanLock. The operating system releases
        the lock automatically if the process ends.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $path = Resolve-WinLeanPath -Path $Directory
    if (-not [System.IO.Directory]::Exists($path)) {
        [void][System.IO.Directory]::CreateDirectory($path)
    }
    $lockPath = Join-Path -Path $path -ChildPath '.winlean.lock'
    try {
        return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch {
        throw (New-Object -TypeName System.InvalidOperationException -ArgumentList "Another WinLean apply or restore is running (lock file '$lockPath' is in use).", $_.Exception)
    }
}

function Exit-WinLeanLock {
    [CmdletBinding()]
    param([AllowNull()] $Lock)

    if ($null -ne $Lock) {
        $Lock.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Test-WinLeanBackupId'
    'New-WinLeanChangeRecords'
    'New-WinLeanBackup'
    'Update-WinLeanBackupManifest'
    'Add-WinLeanBackupFile'
    'Get-WinLeanBackupList'
    'Resolve-WinLeanBackupId'
    'Get-WinLeanBackup'
    'Enter-WinLeanLock'
    'Exit-WinLeanLock'
)
