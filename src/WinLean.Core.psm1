#Requires -Version 5.1
<#
    WinLean.Core
    ------------
    The engine facade. WinLean.ps1 (and any future front-end such as a GUI) calls only
    these functions; they orchestrate the component modules:

      Inventory -> Compatibility context -> Profile -> Rule evaluation -> Plan (dry run)
      -> Backup -> Execution -> Verification -> Logging -> Report -> Restore

    A session object carries the paths, the logger and the facts about the current
    process. There is no global mutable state.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($module in @(
        'WinLean.Common'
        'WinLean.Logging'
        'Providers\WinLean.Providers'
        'WinLean.Validation'
        'WinLean.Rules'
        'WinLean.Inventory'
        'WinLean.Compatibility'
        'WinLean.Policy'
        'WinLean.Report'
    )) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath ($module + '.psm1'))
}

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

function New-WinLeanSession {
    <#
    .SYNOPSIS
        Creates the session used by every WinLean command.
    .PARAMETER InstallRoot
        The WinLean folder (contains Rules, Profiles, Config, Schemas and src).
    .PARAMETER DataRoot
        Where Backups, Reports and Logs are written. Defaults to InstallRoot.
    .PARAMETER CompatibilityPath
        Compatibility requirements file. Defaults to Config\Compatibility.json.
    .PARAMETER Command
        Name of the command, used in log file names.
    .PARAMETER NoLogFiles
        Log to the console only (used by tests).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [string] $DataRoot,
        [string] $CompatibilityPath,
        [ValidatePattern('^[A-Za-z0-9-]+$')] [string] $Command = 'session',
        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'NONE')] [string] $ConsoleLevel = 'INFO',
        [switch] $NoLogFiles,
        [switch] $CaptureLog
    )

    $install = Resolve-WinLeanPath -Path $InstallRoot
    $data = if ($DataRoot) { Resolve-WinLeanPath -Path $DataRoot } else { $install }
    $runId = New-WinLeanRunId
    $paths = [pscustomobject]@{
        install             = $install
        data                = $data
        rules               = Join-Path -Path $install -ChildPath 'Rules'
        profiles            = Join-Path -Path $install -ChildPath 'Profiles'
        config              = Join-Path -Path $install -ChildPath 'Config'
        schemas             = Join-Path -Path $install -ChildPath 'Schemas'
        compatibilitySchema = Join-Path -Path $install -ChildPath 'Schemas\compatibility.schema.json'
        compatibility       = if ($CompatibilityPath) { Resolve-WinLeanPath -Path $CompatibilityPath } else { Join-Path -Path $install -ChildPath 'Config\Compatibility.json' }
        backups             = Join-Path -Path $data -ChildPath 'Backups'
        reports             = Join-Path -Path $data -ChildPath 'Reports'
        logs                = Join-Path -Path $data -ChildPath 'Logs'
    }

    $loggerParameters = @{ Name = "$runId-$Command"; ConsoleLevel = $ConsoleLevel; Capture = [bool]$CaptureLog }
    if (-not $NoLogFiles) {
        $loggerParameters['Directory'] = $paths.logs
    }
    $identity = Get-WinLeanIdentity

    return [pscustomobject]@{
        PSTypeName      = 'WinLean.Session'
        runId           = $runId
        command         = $Command
        version         = Get-WinLeanVersion
        paths           = $paths
        logger          = New-WinLeanLogger @loggerParameters
        identity        = $identity
        isAdministrator = [bool]$identity.isAdministrator
        platform        = Get-WinLeanPlatform
    }
}

function Get-WinLeanKnownRequirementKeys {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    @(Get-WinLeanRequirementDefinitions -SchemaPath $Session.paths.compatibilitySchema | ForEach-Object { $_.key })
}

function Get-WinLeanSessionCatalog {
    <#
    .SYNOPSIS
        Loads the rule catalog and refuses to continue when it contains errors.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $catalog = Import-WinLeanRuleCatalog -Path $Session.paths.rules -KnownRequirementKeys @(Get-WinLeanKnownRequirementKeys -Session $Session)
    foreach ($issue in @($catalog.issues | Where-Object { $_.severity -eq 'Warning' })) {
        Write-WinLeanLog -Logger $Session.logger -Level WARN -Message "$($issue.source): $($issue.message)"
    }
    if ($catalog.errorCount -gt 0) {
        foreach ($issue in @($catalog.issues | Where-Object { $_.severity -eq 'Error' })) {
            Write-WinLeanLog -Logger $Session.logger -Level ERROR -Message "$($issue.source): $($issue.message)"
        }
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "The rule catalog contains $($catalog.errorCount) error(s). Run .\WinLean.ps1 -Validate for details.")
    }
    Write-WinLeanLog -Logger $Session.logger -Level DEBUG -Message "Loaded $($catalog.ruleIds.Count) rules from $($Session.paths.rules)"
    return $catalog
}

function Get-WinLeanSessionCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $compatibility = Import-WinLeanCompatibility -Path $Session.paths.compatibility -KnownRequirementKeys @(Get-WinLeanKnownRequirementKeys -Session $Session)
    foreach ($issue in @($compatibility.issues)) {
        $level = if ($issue.severity -eq 'Error') { 'ERROR' } else { 'WARN' }
        Write-WinLeanLog -Logger $Session.logger -Level $level -Message "$($issue.source): $($issue.message)"
    }
    if ($compatibility.errorCount -gt 0) {
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList "The compatibility configuration '$($compatibility.source)' is invalid.")
    }
    return $compatibility
}

function Get-WinLeanPerUserTarget {
    <#
    .SYNOPSIS
        Match when this process runs as the user who owns the desktop, Mismatch when it
        does not, Unknown when that cannot be determined.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    if ($Session.identity.isSystem) {
        return 'Mismatch'
    }
    $interactiveSid = Get-WinLeanInteractiveUserSid
    if (-not $interactiveSid) {
        return 'Unknown'
    }
    if ($interactiveSid -eq $Session.identity.sid) {
        return 'Match'
    }
    return 'Mismatch'
}

function Write-WinLeanInventoryProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Logger')] $Logger,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Result
    )

    if ($Result.available) {
        Write-WinLeanLog -Logger $Logger -Level DEBUG -Message "Inventory section '$Name' collected in $($Result.durationMs) ms"
    }
    elseif ($Result.reason -eq 'Skipped') {
        Write-WinLeanLog -Logger $Logger -Level DEBUG -Message "Inventory section '$Name' skipped"
    }
    else {
        $level = if ($Result.reason -eq 'Error') { 'WARN' } else { 'INFO' }
        Write-WinLeanLog -Logger $Logger -Level $level -Message "Inventory section '$Name' unavailable ($($Result.reason)): $($Result.message)"
    }
}

function Invoke-WinLeanInventoryCollection {
    <#
    .SYNOPSIS
        Collects the inventory with progress logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [string[]] $Section,
        [string[]] $ExcludeSection
    )

    # The callback stays bound to this module, so it sees $logger and private functions.
    $logger = $Session.logger
    $parameters = @{
        OnSection = { param($name, $result) Write-WinLeanInventoryProgress -Logger $logger -Name $name -Result $result }
    }
    if ($Section) { $parameters['Section'] = $Section }
    if ($ExcludeSection) { $parameters['ExcludeSection'] = $ExcludeSection }
    return Get-WinLeanInventory @parameters
}

# ---------------------------------------------------------------------------
# Analyze
# ---------------------------------------------------------------------------

function Invoke-WinLeanAnalyze {
    <#
    .SYNOPSIS
        Collects and saves the inventory and derives capabilities and suggestions.
        Read-only; works without administrator rights.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [string[]] $ExcludeSection
    )

    $logger = $Session.logger
    Write-WinLeanLog -Logger $logger -Message 'Collecting inventory (read-only)'
    $inventory = Invoke-WinLeanInventoryCollection -Session $Session -ExcludeSection $ExcludeSection
    $inventoryPath = Join-Path -Path $Session.paths.reports -ChildPath ("Inventory\{0}-inventory.json" -f $Session.runId)
    Write-WinLeanJsonFile -Path $inventoryPath -InputObject $inventory
    Write-WinLeanLog -Logger $logger -Message "Inventory completed in $([Math]::Round($inventory.durationMs / 1000.0, 1)) s" -Data @{ path = $inventoryPath }

    $capabilities = Get-WinLeanCapabilities -Inventory $inventory
    $compatibility = Get-WinLeanSessionCompatibility -Session $Session
    $keys = @(Get-WinLeanKnownRequirementKeys -Session $Session)
    return [pscustomobject]@{
        PSTypeName    = 'WinLean.Analysis'
        inventory     = $inventory
        inventoryPath = $inventoryPath
        compatibility = Get-WinLeanCompatibilitySummary -Compatibility $compatibility -KnownRequirementKeys $keys -Capabilities $capabilities
        suggestions   = @(Get-WinLeanCompatibilitySuggestions -Compatibility $compatibility -Capabilities $capabilities)
    }
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

function Invoke-WinLeanDryRun {
    <#
    .SYNOPSIS
        Loads the profile, evaluates every rule and returns the execution plan.
        Read-only; the plan is saved as JSON unless -NoSave is given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session,
        [Parameter(Mandatory)] [string] $ProfileName,
        [switch] $AllowUntestedBuild,
        [switch] $NoSave
    )

    $logger = $Session.logger
    $catalog = Get-WinLeanSessionCatalog -Session $Session
    $profile = Import-WinLeanProfile -Name $ProfileName -ProfileDirectory $Session.paths.profiles
    $profileIssues = @(Test-WinLeanProfileRules -Profile $profile -Catalog $catalog)
    foreach ($issue in @($profileIssues | Where-Object { $_.severity -eq 'Warning' })) {
        Write-WinLeanLog -Logger $logger -Level WARN -Message $issue.message
    }
    $profileErrors = @($profileIssues | Where-Object { $_.severity -eq 'Error' })
    if ($profileErrors.Count -gt 0) {
        throw (New-Object -TypeName System.IO.InvalidDataException -ArgumentList ("Profile '$($profile.name)' is invalid: " + (($profileErrors | ForEach-Object { $_.message }) -join ' ')))
    }
    Write-WinLeanLog -Logger $logger -Message "Profile '$($profile.name)' loaded ($($profile.ruleIds.Count) rules)"

    $compatibility = Get-WinLeanSessionCompatibility -Session $Session
    $keys = @(Get-WinLeanKnownRequirementKeys -Session $Session)

    # Capabilities are only collected when a rule of the profile asks for one.
    $capabilities = New-WinLeanDictionary
    $rules = @(foreach ($id in $profile.ruleIds) { $catalog.rules[$id] })
    $capabilityFacts = @(Get-WinLeanRuleFactNames -Rules $rules | Where-Object { $_.StartsWith('capability.', [System.StringComparison]::Ordinal) })
    if ($capabilityFacts.Count -gt 0) {
        Write-WinLeanLog -Logger $logger -Message 'Detecting capabilities used by rule conditions'
        $inventory = Invoke-WinLeanInventoryCollection -Session $Session -Section @('hardware', 'appxPackages', 'win32Applications', 'optionalFeatures')
        $capabilities = Get-WinLeanCapabilities -Inventory $inventory
    }

    $warnings = New-Object -TypeName System.Collections.Generic.List[string]
    if (-not $compatibility.exists) {
        $warnings.Add("No compatibility configuration found at '$($Session.paths.compatibility)'. Every requirement is treated as required, so rules with compatibility conditions are skipped. Copy Config\Compatibility.example.json to Config\Compatibility.json to declare your requirements.")
    }
    $perUserTarget = Get-WinLeanPerUserTarget -Session $Session
    if ($perUserTarget -eq 'Unknown') {
        $warnings.Add('Could not determine which account owns the desktop session; per-user settings will be applied to the account running WinLean.')
    }

    $context = New-WinLeanPlanContext `
        -Facts (New-WinLeanFacts -Platform $Session.platform -Compatibility $compatibility -Capabilities $capabilities) `
        -IsAdministrator $Session.isAdministrator `
        -PerUserTarget $perUserTarget `
        -UserName $Session.identity.name `
        -Platform $Session.platform `
        -Compatibility (Get-WinLeanCompatibilitySummary -Compatibility $compatibility -KnownRequirementKeys $keys -Capabilities $capabilities) `
        -Warnings $warnings.ToArray() `
        -AllowUntestedBuild:$AllowUntestedBuild
    $plan = New-WinLeanPlan -Profile $profile -Catalog $catalog -Context $context
    $plan | Add-Member -NotePropertyName 'planId' -NotePropertyValue $Session.runId

    $counts = $plan.summary.counts
    Write-WinLeanLog -Logger $logger -Tag PLAN -Message ("{0} rules evaluated: {1} to apply, {2} already satisfied, {3} blocked, {4} skipped, {5} require confirmation, {6} unsupported" -f `
            $plan.summary.total, $counts.Applicable, $counts.AlreadySatisfied, $counts.Blocked, $counts.Skipped, $counts.RequiresConfirmation, $counts.Unsupported)

    if (-not $NoSave) {
        $planPath = Join-Path -Path $Session.paths.reports -ChildPath ("Plans\{0}-{1}-plan.json" -f $Session.runId, $profile.name)
        Write-WinLeanJsonFile -Path $planPath -InputObject $plan
        $plan | Add-Member -NotePropertyName 'planPath' -NotePropertyValue $planPath
        Write-WinLeanLog -Logger $logger -Level DEBUG -Message "Plan saved to $planPath"
    }
    return $plan
}

# ---------------------------------------------------------------------------
# Validation and rule listing
# ---------------------------------------------------------------------------

function Test-WinLeanConfiguration {
    <#
    .SYNOPSIS
        Validates every rule, every profile and the compatibility files.
    .OUTPUTS
        Object with issues, errorCount, warningCount, ruleCount and profileCount.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $keys = @(Get-WinLeanKnownRequirementKeys -Session $Session)
    $issues = New-Object -TypeName System.Collections.Generic.List[object]
    $catalog = Import-WinLeanRuleCatalog -Path $Session.paths.rules -KnownRequirementKeys $keys
    foreach ($issue in $catalog.issues) { $issues.Add($issue) }

    $profileFiles = @()
    if ([System.IO.Directory]::Exists($Session.paths.profiles)) {
        $profileFiles = [System.IO.Directory]::GetFiles($Session.paths.profiles, '*.json')
        [System.Array]::Sort($profileFiles, [System.StringComparer]::OrdinalIgnoreCase)
    }
    foreach ($file in $profileFiles) {
        try {
            $profile = Import-WinLeanProfile -Name $file -ProfileDirectory $Session.paths.profiles
            foreach ($issue in @(Test-WinLeanProfileRules -Profile $profile -Catalog $catalog)) { $issues.Add($issue) }
        }
        catch {
            $issues.Add((New-WinLeanIssue -Severity Error -Code 'Profile' -Source $file -Message $_.Exception.Message))
        }
    }

    foreach ($path in @((Join-Path -Path $Session.paths.config -ChildPath 'Compatibility.example.json'), $Session.paths.compatibility)) {
        if ([System.IO.File]::Exists($path)) {
            $compatibility = Import-WinLeanCompatibility -Path $path -KnownRequirementKeys $keys
            foreach ($issue in $compatibility.issues) { $issues.Add($issue) }
        }
    }

    $all = $issues.ToArray()
    return [pscustomobject]@{
        issues       = $all
        errorCount   = @($all | Where-Object { $_.severity -eq 'Error' }).Count
        warningCount = @($all | Where-Object { $_.severity -eq 'Warning' }).Count
        ruleCount    = $catalog.ruleIds.Count
        profileCount = $profileFiles.Count
    }
}

function Get-WinLeanRules {
    <#
    .SYNOPSIS
        Returns the rules of the catalog and, for each rule, the profiles that include it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSTypeName('WinLean.Session')] $Session)

    $catalog = Get-WinLeanSessionCatalog -Session $Session
    $membership = New-WinLeanDictionary
    if ([System.IO.Directory]::Exists($Session.paths.profiles)) {
        $files = [System.IO.Directory]::GetFiles($Session.paths.profiles, '*.json')
        [System.Array]::Sort($files, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $files) {
            try {
                $profile = Import-WinLeanProfile -Name $file -ProfileDirectory $Session.paths.profiles
            }
            catch {
                Write-WinLeanLog -Logger $Session.logger -Level WARN -Message "Skipping profile '$file': $($_.Exception.Message)"
                continue
            }
            foreach ($id in $profile.ruleIds) {
                if (-not $membership.ContainsKey($id)) {
                    $membership[$id] = New-Object -TypeName System.Collections.Generic.List[string]
                }
                $membership[$id].Add($profile.name)
            }
        }
    }
    return [pscustomobject]@{
        rules      = @(foreach ($id in $catalog.ruleIds) { $catalog.rules[$id] })
        membership = $membership
    }
}

Export-ModuleMember -Function @(
    'New-WinLeanSession'
    'Invoke-WinLeanAnalyze'
    'Invoke-WinLeanDryRun'
    'Test-WinLeanConfiguration'
    'Get-WinLeanRules'
)
