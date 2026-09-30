BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Report', 'WinLean.Common'

    function New-PlanItem {
        <# Without -Benefit the item looks like a plan item written by WinLean 0.1. #>
        param([string] $Id, [string] $Status, [string[]] $Reasons = @(), [object[]] $Resources = @(), $Benefit)
        $item = [pscustomobject]@{
            ruleId = $Id; name = "Name of $Id"; category = 'Privacy'; description = 'd'; status = $Status; reasons = $Reasons; notes = @()
            risk = 'Low'; reversible = $true; requiresReboot = $false; takesEffect = 'SignOut'; scope = 'CurrentUser'; mechanism = 'Preference'
            requiresAdministrator = $false; untestedBuild = $false; dependencies = @(); resources = $Resources
        }
        if ($Benefit) {
            $item | Add-Member -NotePropertyName 'benefit' -NotePropertyValue $Benefit
            $item | Add-Member -NotePropertyName 'lastValidated' -NotePropertyValue '2026-09-28'
        }
        return $item
    }

    function New-Backup {
        param($Execution, $BenchmarkBefore, [object[]] $Items = @(New-PlanItem -Id 'privacy.a.disable' -Status 'Applicable'))
        return [pscustomobject]@{
            id = '2026-09-27_18-45-12'; path = (Join-Path $TestDrive 'Backups\2026-09-27_18-45-12')
            manifest = [pscustomobject]@{
                winLeanVersion = '0.1.0'; profile = 'Safe'; createdAt = '2026-09-27T18:45:12.0000000+03:00'; completedAt = '2026-09-27T18:45:20.0000000+03:00'
                status = 'Completed'; changeCount = 1; user = [pscustomobject]@{ name = 'TEST\user'; sid = 'S-1' }; isAdministrator = $false
                system = [pscustomobject]@{ productName = 'Microsoft Windows 11 Pro'; displayVersion = '25H2'; build = 26200; ubr = 1 }
            }
            plan = [pscustomobject]@{
                profile = [pscustomobject]@{ name = 'Safe'; chain = @('Safe'); maxRisk = 'Low'; excluded = @() }
                options = [pscustomobject]@{ allowUntestedBuild = $false }
                items = $Items
                compatibility = [pscustomobject]@{ exists = $false; source = $null; declared = [pscustomobject]@{}; undeclared = @('printer'); capabilities = [pscustomobject]@{} }
            }
            execution = $Execution
            inventory = $null
            benchmarkBefore = $BenchmarkBefore
        }
    }

    function New-Execution {
        param([object[]] $Results = @(), [object[]] $NotApplied = @())
        return [pscustomobject]@{
            status = 'Completed'; results = $Results; notApplied = $NotApplied
            summary = [pscustomobject]@{ succeeded = 1; alreadySatisfied = 0; failed = 0; changed = 1; rebootRequired = $false; signOutRecommended = $true }
        }
    }

    $script:Succeeded = [pscustomobject]@{
        ruleId = 'privacy.a.disable'; name = 'A'; status = 'Succeeded'; changed = $true
        before = @([pscustomobject]@{ target = 'HKCU:\Software\X\A'; text = 'not set' }); after = @([pscustomobject]@{ target = 'HKCU:\Software\X\A'; text = '1 (DWord)' })
        rebootRequired = $false; takesEffect = 'SignOut'; failure = $null; rollback = $null
    }
}

Describe 'Plan text' {
    It 'groups rules by status with changes, reasons and summary lines' {
        $resource = [pscustomobject]@{ target = 'HKCU:\Software\X\A'; currentText = 'not set'; desiredText = '1 (DWord)'; inDesiredState = $false }
        $plan = [pscustomobject]@{
            profile = [pscustomobject]@{ name = 'Safe'; chain = @('Safe'); maxRisk = 'Low' }
            system = [pscustomobject]@{ productName = 'Microsoft Windows 11 Pro'; displayVersion = '25H2'; build = 26200; ubr = 1; architecture = 'X64' }
            session = [pscustomobject]@{ userName = 'TEST\user'; isAdministrator = $false }
            compatibility = $null
            items = @(
                New-PlanItem -Id 'privacy.a.disable' -Status 'Applicable' -Resources @($resource)
                New-PlanItem -Id 'privacy.b.disable' -Status 'Skipped' -Reasons @('Printing must remain available.')
            )
            summary = [pscustomobject]@{
                total = 2; counts = [pscustomobject]@{ Applicable = 1; AlreadySatisfied = 0; Skipped = 1; Blocked = 0; RequiresConfirmation = 0; Unsupported = 0 }
                rebootRequired = $false; signOutRecommended = $true; administratorRequiredForItems = @()
            }
            warnings = @('Example warning')
        }
        $text = (Format-WinLeanPlanText -Plan $plan) -join "`n"
        $text | Should -BeLike '*WINLEAN PLAN*'
        $text | Should -BeLike '*APPLY*privacy.a.disable*HKCU:\Software\X\A: not set -> 1 (DWord)*'
        $text | Should -BeLike '*SKIPPED*privacy.b.disable*Reason: Printing must remain available.*'
        $text | Should -BeLike '*Reboot required: No*'
        $text | Should -BeLike '*Warning: Example warning*'
        $text | Should -BeLike '*Benefit: unspecified   Last validated: unknown*'
    }

    It 'summarizes the benefit of the rules to apply' {
        $privacy = [pscustomobject]@{ type = 'Privacy'; value = 'Low'; measurement = 'NotMeasured' }
        $distraction = [pscustomobject]@{ type = 'Distraction'; value = 'Moderate'; measurement = 'NotMeasured' }
        $plan = [pscustomobject]@{
            profile = [pscustomobject]@{ name = 'Safe'; chain = @('Safe'); maxRisk = 'Low' }
            system = $null
            session = [pscustomobject]@{ userName = 'TEST\user'; isAdministrator = $false }
            compatibility = $null
            items = @(
                New-PlanItem -Id 'privacy.a.disable' -Status 'Applicable' -Benefit $privacy
                New-PlanItem -Id 'privacy.b.disable' -Status 'Applicable' -Benefit $privacy
                New-PlanItem -Id 'recommendations.c.disable' -Status 'Applicable' -Benefit $distraction
                New-PlanItem -Id 'privacy.d.disable' -Status 'AlreadySatisfied' -Benefit $privacy
            )
            summary = [pscustomobject]@{
                total = 4; counts = [pscustomobject]@{ Applicable = 3; AlreadySatisfied = 1; Skipped = 0; Blocked = 0; RequiresConfirmation = 0; Unsupported = 0 }
                rebootRequired = $false; signOutRecommended = $false; administratorRequiredForItems = @()
            }
            warnings = @()
        }
        $text = (Format-WinLeanPlanText -Plan $plan) -join "`n"
        $text | Should -BeLike '*Benefit of the rules to apply: Privacy 2, Distraction 1 (qualitative; see each rule)*'
        $text | Should -BeLike '*recommendations.c.disable*Benefit: Distraction (Moderate, not measured)   Last validated: 2026-09-28*'
    }
}

Describe 'Rule list' {
    It 'shows the benefit and the latest validation of every rule' {
        $rule = [pscustomobject]@{
            id = 'privacy.a.disable'; name = 'Turn off A'; risk = 'Low'; scope = 'CurrentUser'; mechanism = 'Preference'
            benefit = [pscustomobject]@{ type = 'Privacy'; value = 'Moderate'; measurement = 'NotMeasured' }
            validation = @(
                [pscustomobject]@{ method = 'VmApplyRestore'; build = 26200; date = '2026-10-01' }
                [pscustomobject]@{ method = 'SourceReview'; build = 26100; date = '2026-09-01' }
            )
        }
        $text = (Format-WinLeanRuleListText -Rules @($rule)) -join "`n"
        $text | Should -BeLike '*privacy.a.disable*Low*CurrentUser*Preference*Privacy/Moderate*-*'
        $text | Should -BeLike '*Validated: VM apply/restore on build 26200 (2026-10-01)*'
    }
}

Describe 'Markdown report' {
    It 'renders a run in which every rule was applied (regression: no skipped rules)' {
        $markdown = ConvertTo-WinLeanMarkdownReport -Backup (New-Backup -Execution (New-Execution -Results @($script:Succeeded)))
        $markdown.Contains('| `privacy.a.disable` | A | unspecified | Applied and verified. HKCU:\Software\X\A: not set -> 1 (DWord) |') | Should -BeTrue
        $markdown | Should -BeLike '*## Skipped, blocked and unsupported rules*None.*'
        $markdown | Should -BeLike '*## Failed rules*None.*'
        $markdown | Should -BeLike '*Sign out recommended: Yes*'
    }

    It 'shows the benefit of applied rules recorded in the plan' {
        $item = New-PlanItem -Id 'privacy.a.disable' -Status 'Applicable' -Benefit ([pscustomobject]@{ type = 'Privacy'; value = 'Low'; measurement = 'NotMeasured' })
        $markdown = ConvertTo-WinLeanMarkdownReport -Backup (New-Backup -Execution (New-Execution -Results @($script:Succeeded)) -Items @($item))
        $markdown | Should -BeLike '*Benefit of the applied rules: Privacy 1.*'
        $markdown.Contains('| `privacy.a.disable` | A | Privacy (Low, not measured) | Applied and verified.') | Should -BeTrue
    }

    It 'renders a run without any results' {
        $markdown = ConvertTo-WinLeanMarkdownReport -Backup (New-Backup -Execution (New-Execution))
        $markdown | Should -BeLike '*No rules were applied.*'
    }

    It 'renders a backup whose execution record is missing' {
        $markdown = ConvertTo-WinLeanMarkdownReport -Backup (New-Backup -Execution $null)
        $markdown | Should -BeLike '*Unknown: the execution record is missing.*'
    }

    It 'lists not-applied and failed rules and escapes table cells' {
        $failed = [pscustomobject]@{
            ruleId = 'privacy.f.disable'; name = 'F'; status = 'Failed'; changed = $false; before = @(); after = @(); rebootRequired = $false; takesEffect = 'SignOut'
            failure = [pscustomobject]@{ class = 'VerificationFailed'; message = 'expected 1 | found 0' }; rollback = [pscustomobject]@{ restored = $true }
        }
        $notApplied = @([pscustomobject]@{ ruleId = 'privacy.s.disable'; name = 'S'; status = 'Skipped'; reasons = @('Needs a printer.') })
        $markdown = ConvertTo-WinLeanMarkdownReport -Backup (New-Backup -Execution (New-Execution -Results @($script:Succeeded, $failed) -NotApplied $notApplied))
        $markdown.Contains('| `privacy.s.disable` | Skipped | Needs a printer. |') | Should -BeTrue
        $markdown.Contains('| `privacy.f.disable` | VerificationFailed | expected 1 \| found 0 | rolled back |') | Should -BeTrue
    }

    It 'compares before and after benchmarks and lists restores' {
        $before = [pscustomobject]@{ collectedAt = '2026-09-27T18:45:00+03:00'; context = [pscustomobject]@{ uptimeMinutes = 10 }; processes = [pscustomobject]@{ count = 300 } }
        $after = [pscustomobject]@{ collectedAt = '2026-09-27T19:45:00+03:00'; context = [pscustomobject]@{ uptimeMinutes = 5 }; processes = [pscustomobject]@{ count = 290 } }
        $restore = [pscustomobject]@{ completedAt = '2026-09-27T20:00:00+03:00'; status = 'Restored'; summary = [pscustomobject]@{ Restored = 1; NotNeeded = 0; Skipped = 0; Blocked = 0; Failed = 0 } }
        $markdown = ConvertTo-WinLeanMarkdownReport -Backup (New-Backup -Execution (New-Execution -Results @($script:Succeeded)) -BenchmarkBefore $before) -BenchmarkAfter $after -Restores @($restore)
        $markdown | Should -BeLike '*| Processes | 300 | 290 | -10 |*'
        $markdown | Should -BeLike '*| Restored | 1 | 0 | 0 | 0 | 0 |*'
    }
}

Describe 'Label formatting' {
    It 'separates labels longer than the column from their value' {
        InModuleScope 'WinLean.Report' {
            Format-WinLeanLabel -Label 'virtualMachinePlatformEnabled' -Value 'Yes' -Width 26 -Indent 0 | Should -BeExactly 'virtualMachinePlatformEnabled Yes'
            Format-WinLeanLabel -Label 'CPU' -Value 'x' -Width 6 -Indent 2 | Should -BeExactly '  CPU   x'
            Format-WinLeanLabel -Label 'GPU' -Value $null -Width 4 -Indent 0 | Should -BeExactly 'GPU unknown'
        }
    }
}

Describe 'Other console text' {
    It 'lists backups or explains that there are none' {
        (Format-WinLeanBackupListText -Backups @()) -join "`n" | Should -BeLike '*No backups yet*'
        $backup = [pscustomobject]@{ id = '2026-09-27_18-45-12'; profile = 'Safe'; status = 'Completed'; changeCount = 2; restoreStatus = $null }
        (Format-WinLeanBackupListText -Backups @($backup)) -join "`n" | Should -BeLike '*2026-09-27_18-45-12*Safe*Completed*2*-*'
    }

    It 'summarizes executions with failures and the undo command' {
        $failed = [pscustomobject]@{ ruleId = 'privacy.f.disable'; status = 'Failed'; failure = [pscustomobject]@{ class = 'CommandFailed'; message = 'boom' }; rollback = [pscustomobject]@{ restored = $false } }
        $execution = [pscustomobject]@{
            status = 'CompletedWithFailures'; backupId = '2026-09-27_18-45-12'; backupPath = $null; results = @($failed)
            summary = [pscustomobject]@{ succeeded = 0; alreadySatisfied = 0; failed = 1; changed = 0; rebootRequired = $false; signOutRecommended = $false }
        }
        $text = (Format-WinLeanExecutionText -Execution $execution) -join "`n"
        $text | Should -BeLike '*FAILED privacy.f.disable: CommandFailed - boom (rollback incomplete)*'
        $text | Should -BeLike '*.\WinLean.ps1 -Restore 2026-09-27_18-45-12*'
    }
}
