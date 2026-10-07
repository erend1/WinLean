# WinLean

[![Tests](https://github.com/erend1/WinLean/actions/workflows/tests.yml/badge.svg)](https://github.com/erend1/WinLean/actions/workflows/tests.yml)

> Windows, minus everything you do not intentionally use.

WinLean is a small, testable and reversible configuration framework for Windows 11. It
inventories the system, evaluates a profile of reviewed rules against *your* compatibility
requirements, shows an explicit plan, and only then - after a backup - applies changes,
verifies every one of them and lets you restore the previous values.

Milestone 0.1 built the foundation: inventory, compatibility context, profiles, rule
evaluation, dry run, backup, execution with verification, logging, reports, benchmarks and
restore - with nine deliberately conservative, documented rules.

Milestone 0.2A (version 0.2.0-alpha) extends the engine without adding rules: a
compatibility questionnaire (`-Configure`), two new resource providers (startup entries and
Windows optional features), benefit and validation metadata for every rule, a stricter
evidence capture, a read-only registry access report, static analysis and a documented VM
validation procedure. The profiles are unchanged on purpose.

## What WinLean is

- **Infrastructure as code for a Windows machine.** Rules are reviewed JSON documents;
  profiles select rules; the same profile produces the same state on every run.
- **Transparent.** Every run starts with a dry-run plan that states, per rule, what will
  change, what is already done, what is skipped and why.
- **Reversible.** Before the first change WinLean records the exact previous value of
  everything it will touch. `-Restore` writes those values back - never "assumed defaults".
- **Verified.** A change counts as done only after the value has been read back.
- **Idempotent.** Applying a profile twice changes nothing the second time.

## What WinLean is not

- Not a "debloat script". It does not delete services, remove system components, strip
  AppX packages blindly or copy tweaks from forums.
- It never disables Windows Update, Microsoft Defender, Windows Firewall, Secure Boot or
  servicing - and it refuses to write to those areas of the registry, to change the
  corresponding optional features or to touch the Windows Security startup entry, even if a
  rule asks.
- It does not change services, scheduled tasks or AppX packages yet: those need dedicated,
  reviewed providers and are not implemented.
- It does not optimize for the lowest process count. The target is the least *unnecessary
  background activity* while preserving what you actually use.
- It does not escalate privileges on its own, run AI-generated commands, or create custom
  Windows images.

## Why it exists

Most Windows "optimizers" are opaque scripts that change hundreds of settings at once, cannot
be undone precisely and silently break things after the next feature update. WinLean takes
the opposite approach: a small number of understood changes, each with documentation,
compatibility conditions, verification and an exact undo - and measurements instead of
folklore.

## Safety philosophy

1. **Keep it, document it, investigate it, decide later.** Unknown means "keep".
2. Only settings documented by Microsoft (ADMX policy definitions, Policy CSP, privacy
   guidance, Microsoft source code) become rules - or per-user Settings toggles whose effect
   was recorded in a disposable VM (evidence standard). Everything else stays in the
   research log.
3. An undeclared compatibility requirement is treated as **required**.
4. Least privilege: per-user rules run without elevation; rules that need write access to
   machine settings are *blocked* with a clear message instead of trying to elevate.
5. A change that cannot be backed up losslessly is not made.
6. On newer Windows builds than a rule was validated on, the rule needs `-AllowUntestedBuild`.
7. No performance claim without a measurement: every rule states its benefit (privacy,
   distraction, security, ...) qualitatively, and whether it was measured.
8. Medium and High risk rules apply only after you declared the affected feature unnecessary,
   and enter a shipped profile only after a recorded apply/restore in a disposable VM.
9. Access control lists are observed, never changed.

Details: [Docs/Safety.md](Docs/Safety.md).

## Requirements

- Windows 11 (client editions, build 22000 or later)
- PowerShell 7.4 or later (recommended; tested with 7.5.5) or Windows PowerShell 5.1
- Administrator rights only for machine-wide rules (the plan tells you which)

If you downloaded WinLean as a ZIP file, unblock it first:
`Get-ChildItem -Recurse | Unblock-File`.

## Quick start

```powershell
.\WinLean.ps1 -Analyze                      # read-only inventory and summary
.\WinLean.ps1 -Configure                    # declare what this PC needs (questionnaire)
.\WinLean.ps1 -Profile Safe -WhatIf         # dry run: what would change and why
.\WinLean.ps1 -Profile Safe -Apply          # plan, confirm, back up, apply, verify, report
.\WinLean.ps1 -Restore Latest -WhatIf       # preview the restore
.\WinLean.ps1 -Restore Latest               # restore the recorded previous values
.\WinLean.ps1 -Benchmark                    # measure background activity
.\WinLean.ps1 -Report                       # Markdown report of the latest run
```

Also available: `-ListRules`, `-ListBackups`, `-Validate`. Run `Get-Help .\WinLean.ps1 -Full`
for every option.

### Analyze

```powershell
.\WinLean.ps1 -Analyze              # add -SkipWinGet to skip the (slow) WinGet section
```

Collects edition, version, build, architecture, CPU, RAM, GPU, AppX and provisioned
packages, Win32 applications, WinGet packages, optional features, startup entries,
services, scheduled tasks and the security state (Defender, Firewall, Secure Boot, VBS,
BitLocker). Sections that need elevation or are not available are recorded as
*unavailable* with the reason; nothing fails. The inventory is saved to
`Reports\Inventory\<run>-inventory.json`.

### Dry run

```powershell
.\WinLean.ps1 -Profile Safe -WhatIf
```

`-Profile` without `-Apply` is always a dry run. Every rule gets one status:

| Status | Meaning |
|---|---|
| Applicable | will be applied by `-Apply` |
| AlreadySatisfied | the system already has the desired value |
| Skipped | a compatibility condition is not met or not declared |
| Blocked | cannot be applied now (needs Administrator, dependency, conflict, unreadable value, ...) |
| RequiresConfirmation | Windows build is newer than the rule was validated on (`-AllowUntestedBuild`) |
| Unsupported | not supported on this build, edition or installation type |

The plan is saved to `Reports\Plans\<run>-<profile>-plan.json`.

### Apply

```powershell
.\WinLean.ps1 -Profile Safe -Apply
```

WinLean shows the plan and asks for confirmation. Then it records an inventory and a
baseline benchmark, writes the backup, applies the rules one by one, reads every value back,
rolls a rule back if verification fails, and writes `Reports\<run>-report.md`.

- `-Confirm:$false` skips the confirmation (automation). On Windows PowerShell 5.1 pass it
  from inside PowerShell (`& .\WinLean.ps1 ... -Confirm:$false`); `powershell.exe -File`
  cannot pass switch values.
- `-SkipBenchmark` skips the 10-second baseline measurement.
- Run it again: already satisfied rules are not touched.
- Some settings take full effect after signing out or restarting File Explorer; the plan and
  report say so.

### Restore

```powershell
.\WinLean.ps1 -ListBackups
.\WinLean.ps1 -Restore Latest -WhatIf
.\WinLean.ps1 -Restore Latest
.\WinLean.ps1 -Restore 2026-09-27_18-45-12 -Force
```

`Latest` is the newest backup that has not been restored yet, so repeating
`-Restore Latest` walks back through history. A value is restored only if it still holds the
value WinLean wrote; values changed afterwards (by you or another program) are left alone
unless you add `-Force`. Every restored value is verified.

### Benchmark and report

```powershell
.\WinLean.ps1 -Benchmark     # ideally after signing out and letting the system settle
.\WinLean.ps1 -Report        # before/after table uses the newest benchmark after the run
```

Methodology and limits: [Docs/Benchmarking.md](Docs/Benchmarking.md).

## Compatibility configuration

```powershell
.\WinLean.ps1 -Configure
```

The questionnaire asks, topic by topic, what this PC must keep supporting (printing,
Bluetooth, Hyper-V, WSL, gaming, ...) and writes `Config\Compatibility.json` (not tracked by
Git): `Y` = required, WinLean must preserve it; `N` = not needed; `U` or no answer =
undeclared, which is treated as required. It shows what a read-only inventory detected on
the machine as a hint, but a detected feature never becomes a requirement - and an undetected
one never becomes "not needed" - unless you answer. Existing answers are kept, the changes
are summarized before anything is written, and the previous file is kept as
`Compatibility.previous.json`.

You can also copy `Config\Compatibility.example.json` and edit it by hand. Details:
[Docs/Compatibility.md](Docs/Compatibility.md).

## Profiles

| Profile | Contents |
|---|---|
| Safe | documented privacy and recommendation settings, show file extensions (low risk) |
| Lean | Safe + app-launch tracking off (removes the "most used" list in Start) |
| Minimal | Lean; aggressive rules are planned for later milestones |
| Example.Custom | Lean + show hidden files, keeps the language list available to websites |

### Create a custom profile

```json
{
  "$schema": "../Schemas/profile.schema.json",
  "schemaVersion": 1,
  "name": "MyPC",
  "description": "My workstation.",
  "extends": "Lean",
  "rules": ["explorer.hidden-files.show"],
  "exclude": ["privacy.app-launch-tracking.disable"],
  "maxRisk": "Low",
  "allowIrreversible": false
}
```

Save it as `Profiles\MyPC.json` (file name and `name` must match), check it with
`.\WinLean.ps1 -Validate`, then run `.\WinLean.ps1 -Profile MyPC -WhatIf`. A profile may
also be given by path: `-Profile D:\profiles\MyPC.json`.

## How rules work

A rule is a JSON file in `Rules\<Category>\<rule-id>.json`. It contains metadata (risk,
reversibility, supported builds and editions, compatibility conditions, dependencies,
conflicts, effects, side effects, its benefit, its sources and how it was validated) and one
or more **declarative resources** - for example a registry value and its desired data. Rules
contain no code: apply, verify and undo are implemented once per resource type by a reviewed
provider.

| Resource type | Manages | Notes |
|---|---|---|
| `RegistryValue` | one registry value (set or absent) | exact capture of every restorable value kind; protected locations are refused |
| `StartupEntry` | a program in a Run key (present or absent) | Run keys only; never RunOnce, Startup folders or Task Manager's `StartupApproved` data |
| `WindowsOptionalFeature` | a Windows optional feature (enabled or disabled) | through DISM only; detects and reverts collateral changes; reports restarts |

No shipped rule uses the two new types yet: they exist so that such rules can be written,
reviewed and validated in a VM first.

```json
{
  "id": "explorer.file-extensions.show",
  "category": "Explorer",
  "risk": "Low",
  "windows": { "minBuild": 22000, "maxValidatedBuild": 26200 },
  "conditions": [],
  "benefit": { "type": "Security", "value": "Low", "measurement": "NotMeasured" },
  "validation": [{ "method": "SourceReview", "build": 26200, "date": "2026-09-28" }],
  "resources": [
    {
      "type": "RegistryValue",
      "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
      "name": "HideFileExt",
      "valueType": "DWord",
      "value": 0
    }
  ]
}
```

(abridged - see [Docs/Rules.md](Docs/Rules.md) for the complete schema, the current rule
catalog with sources and the research log of rejected candidates.)

## How to contribute a rule

1. Find a source for the exact setting: authoritative documentation (an ADMX policy
   definition in `C:\Windows\PolicyDefinitions`, the Policy CSP reference, Microsoft privacy
   guidance or Microsoft source code), or - for per-user Settings toggles only - a recorded
   observation captured in a disposable VM with `Tools\Capture-WinLeanEvidence.ps1`
   (see [Docs/Evidence](Docs/Evidence/README.md)). Forum posts and other scripts are not enough.
2. Write `Rules\<Category>\<category-prefix>.<subject>.<action>.json` with the exact
   resource, effects, side effects, the Windows default and references.
3. State the benefit honestly (`benefit`): its type, a qualitative value, and whether it was
   measured. A performance claim needs a measurement in `Docs\Measurements`.
4. Declare compatibility conditions for anything feature-dependent. Medium and High risk
   rules must have a `requirement.*` condition; rules that disable an optional feature must
   require the matching requirement to be `false`.
5. Record how you validated it (`validation`): a `SourceReview` with build and date.
6. Run `.\WinLean.ps1 -Validate`, `.\Tests\Invoke-WinLeanTests.ps1 -Suite All` and
   `.\Tests\Invoke-WinLeanAnalysis.ps1`.
7. Check the plan (`-WhatIf`), then apply, verify and restore the rule in a disposable VM
   following [Docs/VmValidation.md](Docs/VmValidation.md), and add the `VmApplyRestore`
   record. Never try a Medium or High risk rule on a machine you depend on first.
8. Add the rule to a profile only when it meets every point of the checklist below.

### Rule development checklist

- [ ] The purpose and the Windows feature the setting controls are understood.
- [ ] The exact key, value name, type and data come from documentation or a recorded VM
      observation of the Settings toggle - never guessed.
- [ ] The Windows default and the matching Settings or Group Policy option are recorded.
- [ ] Effects and side effects are described honestly (including "managed by your
      organization" banners for policy values).
- [ ] Compatibility conditions cover every feature the change can affect.
- [ ] Supported builds (`minBuild`, `maxValidatedBuild`) and editions are set.
- [ ] Undo is exact (declarative resources restore the recorded value).
- [ ] Verification is meaningful (the value is read back; policy values may be overridden
      by organizational policy - documented).
- [ ] Applying twice changes nothing (idempotent).
- [ ] The benefit is stated in `benefit` and `rationale` without unmeasured performance
      claims; privacy or usability benefits are not presented as performance.
- [ ] `validation` records how, on which build and when the rule was validated.
- [ ] Validation, static analysis, unit and integration tests pass.
- [ ] Apply, verify and restore succeeded in a disposable VM and are recorded
      (`VmApplyRestore`) - mandatory for Medium and High risk rules in a profile.

## Testing

```powershell
.\Tests\Invoke-WinLeanTests.ps1 -Bootstrap        # once: saves Pester 5 to .tools (repo-local)
.\Tests\Invoke-WinLeanTests.ps1 -Suite Unit        # no system changes (in-memory fakes)
.\Tests\Invoke-WinLeanTests.ps1 -Suite All         # + integration tests in TestRegistry/TestDrive
.\Tests\Invoke-WinLeanAnalysis.ps1 -Bootstrap     # static analysis (PSScriptAnalyzer, 5.1 and 7 syntax)
```

The destructive suite changes the real system (it applies and restores the Safe profile, a
disposable startup entry and the Telnet Client feature). Run it only in a disposable VM with
`$env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'`; it never runs in CI. See
[Docs/Testing.md](Docs/Testing.md) and [Docs/VmValidation.md](Docs/VmValidation.md).

## Diagnostic tools

| Tool | Purpose |
|---|---|
| `Tools\Capture-WinLeanEvidence.ps1` | In a VM: records what a Settings toggle writes - baseline, switch, switch back - and which changes are attributable to it. Read-only. |
| `Tools\Get-WinLeanRegistryAccessReport.ps1` | Lists explicit and inherited access entries of registry keys and compares two systems. Read-only; WinLean never changes access control lists. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success (including "nothing to do") |
| 1 | completed with failures (some rules or values failed) |
| 2 | invalid input or configuration (unknown profile, invalid rule, no backup to restore) |
| 3 | cancelled at the confirmation prompt |

## Repository layout

```text
WinLean.ps1            CLI
src/                   engine (WinLean.Core is the facade used by the CLI and future GUIs)
  Providers/           resource providers: RegistryValue, StartupEntry, WindowsOptionalFeature
Rules/<Category>/      one JSON file per rule
Profiles/              Safe, Lean, Minimal, Example.Custom
Config/                Compatibility.example.json, Packages.json (Compatibility.json is local)
Schemas/               JSON schemas for rules, profiles and compatibility (editor support)
Tests/                 Unit, Integration, Destructive, Helpers, test and analysis runners
Tools/                 evidence capture and registry access report (both read-only)
Docs/                  Architecture, Rules, Safety, Benchmarking, Compatibility, Testing,
                       VmValidation; Evidence, Validation and Measurements records
PSScriptAnalyzerSettings.psd1   static analysis settings
Backups/ Reports/ Logs/  runtime output (not tracked by Git)
```

## License

MIT - see [LICENSE](LICENSE).
