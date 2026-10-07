# VM validation

Reading a rule's sources shows what a setting is supposed to do. Only applying it shows what
it does on a given Windows build, that WinLean's verification holds, and that the previous
state really comes back. This document describes how to do that in a disposable virtual
machine, and the checklist that becomes the validation record.

**Never validate on a machine you depend on.** A rule of risk Medium or higher must not be
applied to a primary workstation before it has a recorded VM validation.

## When it is required

| Situation | Requirement |
|---|---|
| A Medium or High risk rule is added to a shipped profile | a `VmApplyRestore` validation record (enforced by the repository tests) |
| A rule uses a provider for the first time on real state (`StartupEntry`, `WindowsOptionalFeature`) | VM validation of that rule, including a restart |
| A rule is validated for a newer Windows build (`maxValidatedBuild` raised) | repeat the procedure on that build |
| A rule is backed only by a recorded observation | apply and restore it in the VM used for the capture |
| Low risk rules already shipped | recommended; the destructive suite automates it for the Safe profile |

## Choosing the environment

| | Hyper-V (or another hypervisor) VM | Windows Sandbox |
|---|---|---|
| Clean baseline | a checkpoint taken after setup; revert to it afterwards | every session starts clean |
| Windows build and edition | any you install: validate the build and edition the rule targets | always the host's build and edition |
| Restart | yes | only a restart started inside the sandbox keeps its state (Windows 11 22H2 and later); closing it discards everything |
| Sign out and back in, other accounts | yes: test a standard user and an administrator | no: one built-in administrator account (`WDAGUtilityAccount`) |
| Optional features, startup entries, machine-wide policies | yes | not suitable: these need restarts, sign-ins or servicing that a sandbox session does not represent |
| Suitable for | everything; **required** for rules that need a restart, a sign-out, elevation differences, optional features or startup entries | evidence captures and Low risk per-user settings that take effect immediately or after restarting File Explorer |

Prefer a Hyper-V VM (Windows 11 Pro, Enterprise or Education host) with a standard
checkpoint. Windows Sandbox is a convenient second choice for the narrow cases above.

## Procedure

Commands are run in the VM, from the WinLean folder. "Record" means: write the result into
the validation record (the checklist below).

### 1. Clean baseline

1. Install or reset the VM to the Windows 11 build and edition to validate. Let it finish
   setup and pending updates; make sure no restart is pending.
2. Create two accounts where the rules differ by privilege: a standard user (the account to
   configure) and an administrator.
3. Copy the WinLean commit under test into the VM. Record the commit hash.
4. Take a checkpoint named after the baseline. Everything below can be undone by reverting
   to it - which is also the last step.

### 2. Inventory

```powershell
.\WinLean.ps1 -Validate
.\WinLean.ps1 -Analyze
.\WinLean.ps1 -Configure          # declare the requirements the rules' conditions need
```

Record the Windows product, edition, version, build and UBR (shown by `-Analyze`), and keep
the inventory file (`Reports\Inventory`). Capture what "exact restoration" will be compared
against - read-only:

```powershell
Import-Module .\Tools\WinLean.Evidence.psm1
$keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'   # every key the rules write
$before = Get-WinLeanRegistrySnapshot -Path $keys -Depth 2

# Only for rules that change optional features (elevated):
Get-WindowsOptionalFeature -Online | Sort-Object FeatureName | Select-Object FeatureName, State |
    Export-Csv .\features-before.csv -NoTypeInformation
```

### 3. Dry run

```powershell
.\WinLean.ps1 -Profile <profile> -WhatIf
```

To validate rules that are not part of a shipped profile yet, create a local profile that
lists exactly those rules (a `.json` file passed by path; do not commit it).

Check and record: every rule has the expected status; blocked, skipped and unsupported rules
have the expected reasons; the changes shown are exactly the documented ones; the restart
announcement is correct. Nothing may have changed (`$after` snapshot equals `$before`).

### 4. Apply

```powershell
.\WinLean.ps1 -Profile <profile> -Apply
```

Record the backup id, "applied and verified" for every rule, failures (there should be
none) and the reported restart requirement.

### 5. Verify

```powershell
.\WinLean.ps1 -Profile <profile> -WhatIf      # applied rules are now "already satisfied"
.\WinLean.ps1 -Profile <profile> -Apply       # "Nothing to apply"; no new backup
```

### 6. Restart or sign out

Do what the rules' `takesEffect` asks for: restart File Explorer, sign out and in, or
restart Windows (always restart for optional features). Then repeat step 5: the settings
must still be in place, and no optional feature may be left in a pending state.

### 7. Verify functionality

1. The intended effect is visible: the Settings page shows the new state (or "managed by
   your organization" for policies), the feature is gone, the startup program no longer
   starts.
2. The documented side effects - and only those - occurred.
3. Nothing else broke. At minimum: sign-in, Start menu, Settings, File Explorer, network
   access, Windows Update (the page opens and a check for updates runs), Windows Security
   (protections on, no new warnings). Then everything declared as required in the
   compatibility configuration that the rules could plausibly affect (printing, Bluetooth,
   virtualization, ...).

Record what was checked and the result. A rule that breaks anything it does not document
fails the validation.

### 8. Restore

```powershell
.\WinLean.ps1 -Restore Latest -WhatIf        # preview
.\WinLean.ps1 -Restore Latest
```

Record the status - it must be `Restored`, not `RestoredWithSkips` or `Incomplete` - and the
reported restart requirement. Restart or sign out again as in step 6.

### 9. Verify exact restoration

```powershell
.\WinLean.ps1 -Profile <profile> -WhatIf     # the same statuses as in step 3
$after = Get-WinLeanRegistrySnapshot -Path $keys -Depth 2
Compare-WinLeanRegistrySnapshot -Before $before -After $after | Format-Table change, key, name, before, after

# Optional features (elevated):
$now = Get-WindowsOptionalFeature -Online | Sort-Object FeatureName | Select-Object FeatureName, State
Compare-Object (Import-Csv .\features-before.csv) $now -Property FeatureName, State
```

The values WinLean changed are back to their recorded state, keys WinLean created are gone,
and every optional feature is in its previous state. Differences that WinLean did not cause
(background churn) must be explained; unexplained differences fail the validation. Repeat the
functionality check of step 7 for the restored state where it matters.

### 10. Automated suite

```powershell
$env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'
.\Tests\Invoke-WinLeanTests.ps1 -Suite Destructive     # as the standard user, then elevated
```

It applies and restores the Safe profile, removes and restores a disposable entry in the
real per-user Run key, and (elevated) toggles the Telnet Client optional feature.

### 11. Record and clean up

1. Save the checklist as `Docs\Validation\<yyyy-MM-dd>-<build>-<topic>.md`.
2. Add a validation record to every rule that passed, and raise `windows.maxValidatedBuild`
   when the build is newer:

   ```json
   { "method": "VmApplyRestore", "build": 26200, "date": "2026-10-10", "file": "Docs/Validation/2026-10-10-26200-safe.md" }
   ```

3. Run `.\WinLean.ps1 -Validate` and the test suites.
4. Revert the VM to the baseline checkpoint.

## Checklist (validation record)

Copy this into `Docs\Validation\<yyyy-MM-dd>-<build>-<topic>.md` and fill it in. Leave no box
unchecked without a note.

```markdown
# VM validation: <topic>

| Item | Value |
|---|---|
| Date | yyyy-MM-dd |
| Validated by | |
| WinLean commit | |
| Environment | Hyper-V VM / other hypervisor / Windows Sandbox |
| Windows | product, edition, version, build.UBR |
| Accounts | standard user / administrator |
| Profile and rules | |

## Results

- [ ] 1. Clean baseline: fresh VM of the target build, no pending restart, checkpoint taken
- [ ] 2. Inventory: `-Validate` clean, `-Analyze` saved, requirements configured, "before" state captured
- [ ] 3. Dry run: expected statuses and reasons; nothing changed
- [ ] 4. Apply: every rule applied and verified; backup id: `...`; restart reported: yes / no
- [ ] 5. Verify: applied rules already satisfied; second apply changes nothing
- [ ] 6. Restart / sign-out done; settings still in place; no feature left pending
- [ ] 7. Functionality: intended effect present; only documented side effects; nothing else broke
- [ ] 8. Restore: status `Restored`; restart reported: yes / no
- [ ] 9. Exact restoration: same plan statuses as in step 3; no unexplained differences
- [ ] 10. Destructive suite passed (standard user / elevated)
- [ ] 11. Validation records added to the rules; VM reverted

## Functionality checks

| Check | After apply | After restore |
|---|---|---|
| Sign-in, Start menu, Settings, File Explorer | | |
| Network access | | |
| Windows Update check | | |
| Windows Security status | | |
| Rule-specific effect | | |
| Required compatibility features | | |

## Deviations and notes

(Anything unexpected, with the decision taken. A deviation that is not understood fails the
validation.)
```

## Status

No VM validation has been recorded yet: `Docs\Validation` contains no records, and every
shipped rule carries a `SourceReview` validation only. The shipped rules are Low risk
registry settings; the engine paths they use are covered by the unit and integration tests,
and the Safe profile by the destructive suite, which still has to be run in a VM and
recorded.
