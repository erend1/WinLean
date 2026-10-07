# Architecture

## Pipeline

```text
Inventory                 read-only facts about the machine            WinLean.Inventory
   |
Compatibility context     requirements (decisions) + capabilities       WinLean.Compatibility
   |
Profile                   ordered, resolved list of rule ids            WinLean.Policy
   |
Rule evaluation           platform, conditions, state, conflicts,       WinLean.Policy / .Rules
   |                      dependencies, access, build validation
Plan (dry run)            one status and reasons per rule               WinLean.Policy / .Report
   |
Backup                    before-state of everything that will change   WinLean.Backup
   |
Execution                 rule by rule, dependencies first              WinLean.Executor
   |
Verification              every value read back; failed rules rolled    WinLean.Rules / .Executor
   |                      back
Logging                   console, text log, JSON Lines log             WinLean.Logging
   |
Report                    Markdown report with before/after benchmark   WinLean.Report / .Benchmark
   |
Restore                   recorded previous values, verified            WinLean.Restore
```

## Modules

```text
WinLean.ps1  ->  WinLean.Core (engine facade; also the root module of src\WinLean.psd1)
                   |
                   +-- WinLean.Inventory ------- WinLean.Common
                   +-- WinLean.Compatibility --- WinLean.Validation, WinLean.Inventory
                   +-- WinLean.Policy ---------- WinLean.Rules
                   +-- WinLean.Executor -------- WinLean.Rules, WinLean.Backup, WinLean.Logging
                   +-- WinLean.Restore --------- Providers, WinLean.Backup, WinLean.Logging
                   +-- WinLean.Benchmark ------- WinLean.Inventory
                   +-- WinLean.Report ---------- WinLean.Inventory, WinLean.Benchmark
                   +-- WinLean.Logging
WinLean.Rules      -> Providers\WinLean.Providers (dispatcher), WinLean.Validation
WinLean.Validation -> Providers\WinLean.Providers
Providers\WinLean.Providers -> Providers\WinLean.Provider.Registry, .Provider.Startup, .Provider.OptionalFeature
Providers\WinLean.Provider.Startup -> Providers\WinLean.Provider.Registry
everything         -> WinLean.Common (JSON, paths, culture-safe helpers, platform facts, failures)
```

| Module | Responsibility |
|---|---|
| WinLean.Common | JSON with atomic writes, culture-invariant helpers, timestamps, identity/privilege/platform facts, failure classification |
| WinLean.Logging | one logger object, three sinks (console, `.log`, `.jsonl`) |
| WinLean.Validation | authoritative validation of rules, catalog, profiles and compatibility files |
| Providers\WinLean.Provider.Registry | the `RegistryValue` resource type; exact registry capture, protected-location checks and the only registry-writing functions |
| Providers\WinLean.Provider.Startup | the `StartupEntry` resource type (Run keys), built on the registry provider |
| Providers\WinLean.Provider.OptionalFeature | the `WindowsOptionalFeature` resource type (DISM), with collateral-change protection |
| Providers\WinLean.Providers | provider registry and uniform dispatcher |
| WinLean.Rules | rule catalog, conditions, the rule interface |
| WinLean.Inventory | read-only inventory with per-section fault isolation |
| WinLean.Compatibility | requirements, detected capabilities, facts, suggestions; the `-Configure` questionnaire and the validated, atomic saving of the configuration |
| WinLean.Policy | profiles, dependency ordering, plan generation |
| WinLean.Backup | backup directories, manifest, change records, lock |
| WinLean.Executor | backup-first execution with verification and rollback |
| WinLean.Restore | restore decisions and verified restore |
| WinLean.Benchmark | read-only measurements and comparison |
| WinLean.Report | console text and Markdown reports (returns text, writes nothing) |
| WinLean.Core | session and the commands used by front-ends |

Outside the engine, `Tools\` holds two read-only diagnostic modules with their scripts:
`WinLean.Evidence` (registry snapshots, attribution of changes to a Settings toggle, evidence
write-ups) and `WinLean.RegistryAccess` (access control reports and their comparison). They
import engine modules but are not imported by the engine.

Each module imports its own dependencies and exports an explicit function list, so every
module can be imported alone in tests. There is no global mutable state: a *session* object
(paths, logger, identity, platform facts) is passed to the facade functions.

## Rule interface

| Conceptual | Function | Notes |
|---|---|---|
| Test-Applicable | `Test-WinLeanRuleApplicable` | platform, build range, edition, conditions; no system access |
| Get-State | `Get-WinLeanRuleState` | current vs desired per resource; optional write-access probe |
| Apply | `Set-WinLeanRuleState` | only resources not yet in the desired state are written |
| Verify | `Confirm-WinLeanRuleState` | fresh read and comparison |
| Undo | `Undo-WinLeanRuleState` | writes the captured state back, newest first, and verifies |

Rules are data. The behaviour behind the interface comes from resource providers.

## Resource provider contract

| Operation | Purpose |
|---|---|
| Validate | problems in a resource definition (types, ranges, protected locations) |
| Normalize | canonical resource object |
| Describe | identity (for conflict detection), scope (CurrentUser/Machine), mechanism (Policy/Preference), text |
| GetState | lossless, JSON-serializable current state |
| GetDesired | desired state in the same shape |
| Equal | exact, type-aware comparison |
| Restorable | whether a captured state can be written back exactly |
| TestAccess | non-modifying probe of write access |
| Set | apply the desired state |
| Restore | write a captured state back (including removing keys WinLean created) |
| FormatState | human-readable text |

Optional parts of the contract:

| Part | Meaning | Engine behaviour |
|---|---|---|
| `available = $false` in a captured state | the resource does not exist on this system | plan: **Unsupported** unless already in the desired state; executor: `Unsupported` failure |
| `note` in a captured state | why the resource cannot be changed | shown as the plan reason |
| `rebootRequired` returned by Set / Restore | the provider knows whether a restart is needed | rule and restore results use it; when a provider cannot tell (`$null`), the rule's `takesEffect` decides |

Resources of different types may share an identity when they manage the same object (a
`StartupEntry` is a registry value); conflict detection then compares the desired states
with both providers.

Adding a provider (planned: Service, ScheduledTask, AppxPackage) means implementing this
contract and registering it in `Providers\WinLean.Providers.psm1`; the policy engine,
executor, backup and restore do not change.

### Rule-level constraints

A provider may register a `RuleConstraints` operation for checks that involve the whole rule.
Validation calls it for every resource that passed its own validation:

| Resource type | Constraint |
|---|---|
| `StartupEntry` | `ensure: Present` (a program run at every sign-in) needs risk Medium or higher |
| `WindowsOptionalFeature` | risk Medium or higher; `takesEffect: Reboot`; disabling a feature that a compatibility requirement depends on needs `requirement.<key> Equals false` |

### Reading and changing optional features

```text
Get-WinLeanOptionalFeatureRecord      elevated: Get-WindowsOptionalFeature (DISM)
                                      otherwise: Win32_OptionalFeature (CIM, no pending states)
Set / Restore
  -> Get-WinLeanFeatureOperation      Enable | Disable | DisableRemovePayload | nothing
  -> Invoke-WinLeanFeatureTransition  snapshot of all features
                                      Invoke-WinLeanOptionalFeatureChange (DISM, -NoRestart)
                                      snapshot of all features
                                      other features changed? revert target and collateral
                                      changes, throw CollateralChange
  -> { rebootRequired }               DISM RestartNeeded, or the feature is pending
```

## Compatibility questionnaire

```text
Get-WinLeanConfiguration                   read the file (refuse files with errors), build one
                                           question per schema key, optional detection hints
Invoke-WinLeanConfigurationQuestionnaire   injected reader/writer; Enter keeps an answer; returns
                                           the answers and the list of changes
Save-WinLeanConfiguration                  write a temporary file, read it back, validate it,
                                           replace the target in one step, keep the previous version
```

The questionnaire never derives an answer from a detection result: capabilities appear as
text only, and the answer dictionary changes only in response to input.

## Plan evaluation order

1. Platform: installation type Client, build >= 22000, rule `minBuild`/`maxBuild`, editions -> **Unsupported**
2. Conditions against facts (`requirement.*`, `capability.*`, `system.*`); unknown facts fail -> **Skipped**
3. Current state (read-only): unreadable -> **Blocked**; already desired -> **AlreadySatisfied**; resource does not exist on this system -> **Unsupported**; not losslessly capturable -> **Blocked**
4. Conflicts among rules in effect: declared, or two rules setting the same value differently -> **Blocked** (both)
5. Dependencies, in dependency order: dependency not Applicable/AlreadySatisfied (or, outside the profile, not satisfied) -> **Blocked**
6. Per-user target: per-user rules while running as another account than the desktop user -> **Blocked**
7. Write access (real ACL probe): missing -> **Blocked** (with "requires Administrator" when not elevated)
8. Build newer than `maxValidatedBuild` without `-AllowUntestedBuild` -> **RequiresConfirmation**
9. Otherwise -> **Applicable**

## Backup format

```text
Backups\<yyyy-MM-dd_HH-mm-ss>\
  manifest.json          id, times, version, profile, user (name, SID), status, restore status, files
  changes.json           ordered records: rule, resource, before-state, desired state (written first)
  plan.json              the confirmed plan
  inventory.json         inventory at backup time (without WinGet)
  benchmark-before.json  baseline benchmark (unless -SkipBenchmark)
  execution.json         per-rule results, rewritten atomically after every rule
  restore-<run>.json     one per restore run
```

`changes.json` is complete before the first change and never modified, so a backup can be
restored even after an interruption: restore compares the current value with the recorded
before and desired values and acts only where WinLean's value is still present.

## Execution transaction

For every Applicable rule, in dependency order:

1. re-read the state (the plan may be stale); already satisfied -> no change
2. write only resources that differ
3. read everything back; mismatch -> `VerificationFailed`
4. on any failure restore the rule's captured state and verify that too (rollback)
5. rules depending on a failed rule are not attempted (`DependencyFailure`)

A result requires a restart when a provider reported one for a changed resource, or when no
provider could tell and the rule declares `takesEffect: Reboot`; a rollback that left a
restart pending is reported as well. Change records store the rule's declaration so that a
restore can report restarts in the same way.

Failure classes: PermissionDenied, Unsupported, CommandFailed, VerificationFailed,
DependencyFailure, StateUnavailable, BackupFailed, ProtectedResource, CollateralChange (a
change altered resources that the rule does not declare; reverted), UnexpectedError.
Classification uses exception types and HRESULTs, never (localized) message text.

## Restore algorithm

Newest change first. For each recorded change: another user's per-user value -> Blocked;
current == before -> nothing to do; current == desired -> restore; otherwise the value changed
after WinLean applied it -> skip (restore with `-Force`); no write access -> Blocked. Each
Restore item is re-checked immediately before writing, and verified afterwards. The manifest
records Restored, RestoredWithSkips or Incomplete; `-Restore Latest` selects the newest backup
that is not Restored/RestoredWithSkips.

## Conventions and PowerShell pitfalls

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in every module.
- Culture safety: `-like` and `-match` compare case-insensitively with the *current culture*
  (under tr-TR `'WINDOWS' -like 'windows'` is `$false`). Use ordinal comparisons,
  `Test-WinLeanTextEqual/Contains/Pattern`, and invariant formatting (`Format-WinLeanNumber`).
  Culture tests run under tr-TR.
- Functions that return collections emit their items; callers wrap calls in `@()`. Never
  write `$x = if (...) { @(...) } else { @() }` - an `if` statement unrolls arrays (an empty
  array becomes `$null`); write `$x = @(if (...) { ... })`.
- `continue` inside a `switch` statement continues the switch, not the enclosing loop.
- `$null` passed to a .NET `string` parameter becomes `''`; use `[NullString]::Value`.
- Generic dictionaries only expose `ContainsKey`; `OrderedDictionary` only `Contains`; use
  `Test-WinLeanDictionaryKey`.
- The registry is read with the .NET API (exact kinds, unexpanded `REG_EXPAND_SZ`), in the
  64-bit view on 64-bit Windows.
- JSON: explicit depth, UTF-8 without BOM, atomic replacement; on PowerShell 7.5+
  `-DateKind String` keeps ISO-like strings as strings.
- Source files are ASCII-only so Windows PowerShell 5.1 reads them correctly without a BOM.
- `String.StartsWith`, `EndsWith`, `IndexOf` and `LastIndexOf` with a *string* argument
  compare with the current culture (ICU on .NET 5 and later), where some characters - for
  example NUL - are ignorable and match at position 0. Pass a `StringComparison` or use the
  `[char]` overload; a repository test enforces this for `src` and `Tools`.
- Under strict mode, reading a property of `$null` throws. Use `Get-WinLeanProperty` for
  values that may be absent (optional JSON properties, results of mocked functions).
- A hexadecimal literal with the high bit set (`0x80000000`) is a negative 32-bit number;
  write `0x80000000L` for access masks.
- `$profile`, `$input`, `$args`, `$matches` and other automatic variables must not be used
  as variable or parameter names (enforced by static analysis).
- DISM cmdlets do not support `-WhatIf`; `Get-Acl -LiteralPath` fails for registry keys on
  Windows PowerShell 5.1 (use `-Path` or the .NET API).
- Windows PowerShell 5.1 turns the redirected stderr of a child process into terminating
  errors; scripts that are tested end to end report failures on stdout.

## Deviations from the suggested layout

| Suggestion | Implementation | Reason |
|---|---|---|
| `Inventory.psm1`, `Policy.psm1`, ... | `WinLean.Inventory.psm1`, ... | module names such as `Logging` collide with PSGallery modules; the prefix keeps `Get-Module`/`Remove-Module` unambiguous |
| - | `WinLean.Common`, `WinLean.Rules`, `WinLean.Compatibility`, `WinLean.Report`, `Providers\` | separation of shared primitives, rule model, compatibility context, presentation and the only system-writing code |
| `WinLean.Core.psm1` | engine facade and root module of `src\WinLean.psd1` | the spec describes "WinLean.Core" as the engine behind CLI and GUI |
| - | `Schemas\` | JSON schemas give editors completion and inline errors |
| `Rules\...` | adds `Rules\Recommendations\` | the spec lists "Recommendations / Advertising" as a category |
| `Config\Compatibility.json` | `Config\Compatibility.example.json` tracked; `Config\Compatibility.json` local and ignored | requirements are machine-specific decisions |
| per-category backup files | one `changes.json` | a single ordered record is simpler to restore correctly and cannot become inconsistent |
| - | `Logs\`, `Tests\Destructive\`, `Tests\Helpers\` | text/JSON logs; destructive tests separated and gated |
| - | `Tools\`, `Docs\Evidence\`, `Docs\Validation\`, `Docs\Measurements\` | read-only diagnostics, and the records that rule metadata refers to |
| a `StartupFolder` resource | not implemented | removing a shortcut needs a lossless file backup; planned |
