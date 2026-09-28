#Requires -Version 5.1
<#
    WinLean.Executor
    ----------------
    Executes the Applicable items of a plan:

      1. re-read the current state of every rule (the plan may be minutes old)
      2. write the backup (before-state of every resource) - nothing is changed if this fails
      3. apply rule by rule, in plan (dependency) order; each rule is a transaction:
           apply -> verify by reading the state again -> on failure roll the rule back
      4. record every result in execution.json (atomically, after each rule)

    A failure never stops the other rules, except rules that depend on the failed one
    (DependencyFailure). Success is only reported after verification.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Common.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Logging.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Rules.psm1')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinLean.Backup.psm1')

function ConvertTo-WinLeanStateList {
    <#
    .SYNOPSIS
        Projects rule state into the compact before/after lists stored in results.
    #>
    [CmdletBinding()]
    param([AllowNull()] $State)

    if ($null -eq $State) {
        return
    }
    foreach ($resource in $State.resources) {
        [pscustomobject]@{
            target = $resource.target
            state  = $resource.current
            text   = $resource.currentText
        }
    }
}

function New-WinLeanRuleResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] [ValidateSet('Succeeded', 'AlreadySatisfied', 'Failed')] [string] $Status,
        [bool] $Changed = $false,
        $Before,
        $After,
        $Failure,
        $Rollback,
        [string] $StartedAt,
        [long] $DurationMs = 0
    )

    return [pscustomobject]@{
        ruleId         = $Rule.id
        name           = $Rule.name
        status         = $Status
        changed        = $Changed
        before         = @(ConvertTo-WinLeanStateList -State $Before)
        after          = @(ConvertTo-WinLeanStateList -State $After)
        rebootRequired = [bool]($Status -eq 'Succeeded' -and $Changed -and $Rule.requiresReboot)
        takesEffect    = $Rule.takesEffect
        failure        = $Failure
        rollback       = $Rollback
        startedAt      = if ($StartedAt) { $StartedAt } else { Get-WinLeanTimestamp }
        durationMs     = $DurationMs
    }
}

function Invoke-WinLeanRollback {
    <#
    .SYNOPSIS
        Restores the captured before-state of a rule after a failed apply or verification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] $BeforeState,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Logger')] $Logger
    )

    $undo = Undo-WinLeanRuleState -Rule $Rule -BeforeState $BeforeState
    if ($undo.restored) {
        Write-WinLeanLog -Logger $Logger -Level INFO -Tag RESTORE -Message "$($Rule.id): rolled back to the previous state"
    }
    else {
        Write-WinLeanLog -Logger $Logger -Level WARN -Message "$($Rule.id): rollback incomplete; the backup can restore these values later" -Detail ($undo.mismatches -join '; ')
    }
    return [pscustomobject]@{
        attempted  = $true
        restored   = [bool]$undo.restored
        mismatches = @($undo.mismatches)
    }
}

function Invoke-WinLeanRuleTransaction {
    <#
    .SYNOPSIS
        Applies one rule, verifies it by reading the state again and rolls it back on failure.
    .OUTPUTS
        Structured rule result (ruleId, status, changed, before, after, rebootRequired,
        failure, rollback, startedAt, durationMs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Rule')] $Rule,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Logger')] $Logger
    )

    $startedAt = Get-WinLeanTimestamp
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-WinLeanLog -Logger $Logger -Tag APPLY -Message $Rule.id -Data @{ ruleId = $Rule.id; name = $Rule.name }

    try {
        $applied = Set-WinLeanRuleState -Rule $Rule -State $State
    }
    catch {
        $failure = ConvertTo-WinLeanFailure -ErrorObject $_
        Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($Rule.id): $($failure.class)" -Detail $failure.message -Data @{ ruleId = $Rule.id; failure = $failure }
        $rollback = Invoke-WinLeanRollback -Rule $Rule -BeforeState $State -Logger $Logger
        return New-WinLeanRuleResult -Rule $Rule -Status Failed -Changed $false -Before $State -Failure $failure -Rollback $rollback -StartedAt $startedAt -DurationMs $stopwatch.ElapsedMilliseconds
    }

    try {
        $verification = Confirm-WinLeanRuleState -Rule $Rule
    }
    catch {
        $failure = ConvertTo-WinLeanFailure -ErrorObject $_ -Class 'StateUnavailable'
        Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($Rule.id): the result could not be verified" -Detail $failure.message -Data @{ ruleId = $Rule.id; failure = $failure }
        $rollback = Invoke-WinLeanRollback -Rule $Rule -BeforeState $State -Logger $Logger
        return New-WinLeanRuleResult -Rule $Rule -Status Failed -Changed $false -Before $State -Failure $failure -Rollback $rollback -StartedAt $startedAt -DurationMs $stopwatch.ElapsedMilliseconds
    }

    if (-not $verification.verified) {
        $failure = [pscustomobject]@{
            class     = 'VerificationFailed'
            message   = 'The system is not in the desired state after applying: ' + ($verification.mismatches -join '; ')
            exception = $null
            hresult   = $null
        }
        Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($Rule.id): verification failed" -Detail $failure.message -Data @{ ruleId = $Rule.id; failure = $failure }
        $rollback = Invoke-WinLeanRollback -Rule $Rule -BeforeState $State -Logger $Logger
        return New-WinLeanRuleResult -Rule $Rule -Status Failed -Changed $false -Before $State -After $verification.state -Failure $failure -Rollback $rollback -StartedAt $startedAt -DurationMs $stopwatch.ElapsedMilliseconds
    }

    Write-WinLeanLog -Logger $Logger -Tag OK -Message 'Verified' -Data @{ ruleId = $Rule.id; changedResources = $applied.changedResources }
    return New-WinLeanRuleResult -Rule $Rule -Status Succeeded -Changed ($applied.changedResources.Count -gt 0) -Before $State -After $verification.state -StartedAt $startedAt -DurationMs $stopwatch.ElapsedMilliseconds
}

function Get-WinLeanExecutionSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    $succeeded = @($Results | Where-Object { $_.status -eq 'Succeeded' })
    return [pscustomobject]@{
        succeeded          = $succeeded.Count
        alreadySatisfied   = @($Results | Where-Object { $_.status -eq 'AlreadySatisfied' }).Count
        failed             = @($Results | Where-Object { $_.status -eq 'Failed' }).Count
        changed            = @($succeeded | Where-Object { $_.changed }).Count
        rebootRequired     = (@($succeeded | Where-Object { $_.rebootRequired }).Count -gt 0)
        signOutRecommended = (@($succeeded | Where-Object { $_.changed -and @('SignOut', 'ExplorerRestart') -contains $_.takesEffect }).Count -gt 0)
    }
}

function New-WinLeanExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $StartedAt,
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results,
        $Backup
    )

    $notApplied = @(foreach ($item in $Plan.items) {
            if ($item.status -ne 'Applicable') {
                [pscustomobject]@{ ruleId = $item.ruleId; name = $item.name; status = $item.status; reasons = @($item.reasons) }
            }
        })
    return [pscustomobject]@{
        PSTypeName     = 'WinLean.Execution'
        schemaVersion  = 1
        runId          = $RunId
        planId         = [string](Get-WinLeanProperty -InputObject $Plan -Name 'planId' -Default '')
        profile        = [string]$Plan.profile.name
        winLeanVersion = Get-WinLeanVersion
        startedAt      = $StartedAt
        completedAt    = if ($Status -eq 'InProgress') { $null } else { Get-WinLeanTimestamp }
        status         = $Status
        backupId       = if ($Backup) { $Backup.id } else { $null }
        backupPath     = if ($Backup) { $Backup.path } else { $null }
        summary        = Get-WinLeanExecutionSummary -Results $Results
        results        = $Results
        notApplied     = $notApplied
    }
}

function Invoke-WinLeanExecution {
    <#
    .SYNOPSIS
        Applies the Applicable items of a plan with backup, verification and rollback.
    .PARAMETER BackupRoot
        Folder in which the backup directory is created.
    .PARAMETER RunId
        Identifier of this run; also the requested backup id.
    .OUTPUTS
        WinLean.Execution. Status is NoChanges (nothing needed changing), Completed,
        CompletedWithFailures or Aborted (the backup could not be written; nothing changed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Plan')] $Plan,
        [Parameter(Mandatory)] [PSTypeName('WinLean.RuleCatalog')] $Catalog,
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [PSTypeName('WinLean.Logger')] $Logger,
        [Parameter(Mandatory)] $Identity,
        $Platform,
        $Inventory,
        $Benchmark
    )

    $startedAt = Get-WinLeanTimestamp
    $results = New-Object -TypeName System.Collections.Generic.List[object]
    $prepared = New-Object -TypeName System.Collections.Generic.List[object]
    $changes = New-Object -TypeName System.Collections.Generic.List[object]

    # 1. Fresh state for every applicable rule.
    foreach ($item in @($Plan.items | Where-Object { $_.status -eq 'Applicable' })) {
        $rule = Get-WinLeanCatalogRule -Catalog $Catalog -Id $item.ruleId
        try {
            $state = Get-WinLeanRuleState -Rule $rule -IncludeAccess
        }
        catch {
            $failure = ConvertTo-WinLeanFailure -ErrorObject $_ -Class 'StateUnavailable'
            Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($rule.id): the current state could not be read" -Detail $failure.message
            $results.Add((New-WinLeanRuleResult -Rule $rule -Status Failed -Failure $failure))
            continue
        }
        if ($state.inDesiredState) {
            Write-WinLeanLog -Logger $Logger -Tag SKIP -Message "$($rule.id): already satisfied"
            $results.Add((New-WinLeanRuleResult -Rule $rule -Status AlreadySatisfied -Before $state -After $state))
            continue
        }
        $problem = $null
        if (-not $state.restorable) {
            $problem = [pscustomobject]@{ class = 'Unsupported'; message = 'The current state cannot be captured losslessly, so it is not modified.'; exception = $null; hresult = $null }
        }
        elseif ($state.writable -eq $false) {
            $problem = [pscustomobject]@{ class = 'PermissionDenied'; message = 'No write access to one or more values of this rule.'; exception = $null; hresult = $null }
        }
        if ($problem) {
            Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($rule.id): $($problem.class)" -Detail $problem.message
            $results.Add((New-WinLeanRuleResult -Rule $rule -Status Failed -Before $state -Failure $problem))
            continue
        }
        foreach ($record in @(New-WinLeanChangeRecords -Rule $rule -State $state -StartSequence ($changes.Count + 1))) {
            $changes.Add($record)
        }
        $prepared.Add([pscustomobject]@{ rule = $rule; state = $state })
    }

    if ($prepared.Count -eq 0) {
        $status = if (@($results | Where-Object { $_.status -eq 'Failed' }).Count -gt 0) { 'CompletedWithFailures' } else { 'NoChanges' }
        Write-WinLeanLog -Logger $Logger -Message 'Nothing to change; no backup was needed.'
        return New-WinLeanExecution -Plan $Plan -RunId $RunId -StartedAt $startedAt -Status $status -Results $results.ToArray()
    }

    # 2. Backup. If it cannot be written, nothing is changed.
    try {
        $backup = New-WinLeanBackup -Root $BackupRoot -BackupId $RunId -Changes $changes.ToArray() -Plan $Plan -Identity $Identity -Platform $Platform -Inventory $Inventory -Benchmark $Benchmark
    }
    catch {
        $failure = ConvertTo-WinLeanFailure -ErrorObject $_ -Class 'BackupFailed'
        Write-WinLeanLog -Logger $Logger -Level ERROR -Message "Backup failed; no changes were made: $($failure.message)"
        foreach ($entry in $prepared) {
            $results.Add((New-WinLeanRuleResult -Rule $entry.rule -Status Failed -Before $entry.state -Failure $failure))
        }
        return New-WinLeanExecution -Plan $Plan -RunId $RunId -StartedAt $startedAt -Status 'Aborted' -Results $results.ToArray()
    }
    Write-WinLeanLog -Logger $Logger -Message "Backup created: $($backup.path)" -Data @{ backupId = $backup.id; changes = $changes.Count }
    $executionPath = Join-Path -Path $backup.path -ChildPath 'execution.json'
    $saveExecution = {
        param([string] $Status)
        Write-WinLeanJsonFile -Path $executionPath -InputObject (New-WinLeanExecution -Plan $Plan -RunId $RunId -StartedAt $startedAt -Status $Status -Results $results.ToArray() -Backup $backup)
    }
    try {
        & $saveExecution 'InProgress'
    }
    catch {
        $failure = ConvertTo-WinLeanFailure -ErrorObject $_ -Class 'BackupFailed'
        Write-WinLeanLog -Logger $Logger -Level ERROR -Message "The execution record could not be written; no changes were made: $($failure.message)"
        foreach ($entry in $prepared) {
            $results.Add((New-WinLeanRuleResult -Rule $entry.rule -Status Failed -Before $entry.state -Failure $failure))
        }
        return New-WinLeanExecution -Plan $Plan -RunId $RunId -StartedAt $startedAt -Status 'Aborted' -Results $results.ToArray() -Backup $backup
    }

    # 3. Apply rule by rule. The record is updated after every rule; if that becomes
    #    impossible, no further changes are made.
    $failedRuleIds = New-Object -TypeName System.Collections.Generic.List[string]
    $recordFailure = $null
    foreach ($entry in $prepared) {
        $rule = $entry.rule
        if ($null -ne $recordFailure) {
            $results.Add((New-WinLeanRuleResult -Rule $rule -Status Failed -Before $entry.state -Failure $recordFailure))
            $failedRuleIds.Add($rule.id)
            continue
        }
        $failedDependencies = @($rule.dependencies | Where-Object { $failedRuleIds.Contains($_) })
        if ($failedDependencies.Count -gt 0) {
            $failure = [pscustomobject]@{ class = 'DependencyFailure'; message = "Dependency failed: $($failedDependencies -join ', ')"; exception = $null; hresult = $null }
            Write-WinLeanLog -Logger $Logger -Level ERROR -Tag FAIL -Message "$($rule.id): not applied" -Detail $failure.message
            $result = New-WinLeanRuleResult -Rule $rule -Status Failed -Before $entry.state -Failure $failure
        }
        else {
            $result = Invoke-WinLeanRuleTransaction -Rule $rule -State $entry.state -Logger $Logger
        }
        if ($result.status -eq 'Failed') {
            $failedRuleIds.Add($rule.id)
        }
        $results.Add($result)
        try {
            & $saveExecution 'InProgress'
        }
        catch {
            $recordFailure = [pscustomobject]@{
                class     = 'BackupFailed'
                message   = "Not attempted: the execution record could not be updated ($($_.Exception.Message))."
                exception = $_.Exception.GetType().FullName
                hresult   = $null
            }
            Write-WinLeanLog -Logger $Logger -Level ERROR -Message 'The execution record could not be updated; stopping before further changes. The backup can still restore every change made so far.' -Detail $_.Exception.Message
        }
    }

    # 4. Finish. Recording problems are reported but do not hide the results.
    $status = if (@($results | Where-Object { $_.status -eq 'Failed' }).Count -gt 0) { 'CompletedWithFailures' } else { 'Completed' }
    $execution = New-WinLeanExecution -Plan $Plan -RunId $RunId -StartedAt $startedAt -Status $status -Results $results.ToArray() -Backup $backup
    try {
        Write-WinLeanJsonFile -Path $executionPath -InputObject $execution
        [void](Update-WinLeanBackupManifest -Path $backup.path -Values @{
                status           = $status
                completedAt      = $execution.completedAt
                changedRuleCount = $execution.summary.changed
                files            = [string[]](@($backup.manifest.files) + 'execution.json')
            })
    }
    catch {
        Write-WinLeanLog -Logger $Logger -Level ERROR -Message "The final execution record could not be written to '$($backup.path)': $($_.Exception.Message)"
    }
    return $execution
}

Export-ModuleMember -Function @(
    'Invoke-WinLeanExecution'
    'Invoke-WinLeanRuleTransaction'
    'Get-WinLeanExecutionSummary'
)
