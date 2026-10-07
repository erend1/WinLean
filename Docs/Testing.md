# Testing

```powershell
.\Tests\Invoke-WinLeanTests.ps1 -Bootstrap            # once: saves Pester 5 to .tools\Modules
.\Tests\Invoke-WinLeanTests.ps1                       # Unit (default)
.\Tests\Invoke-WinLeanTests.ps1 -Suite Integration
.\Tests\Invoke-WinLeanTests.ps1 -Suite All -OutputPath .\TestResults\results.xml
.\Tests\Invoke-WinLeanTests.ps1 -Path .\Tests\Unit\Plan.Tests.ps1 -Verbosity Detailed

.\Tests\Invoke-WinLeanAnalysis.ps1 -Bootstrap         # once: saves PSScriptAnalyzer to .tools\Modules
.\Tests\Invoke-WinLeanAnalysis.ps1                    # static analysis
```

The test runner requires Pester >= 5.5 and < 6. It uses `.tools\Modules` first, then
installed modules; `-Bootstrap` saves Pester into the repository (`.tools` is ignored by Git)
instead of installing it system-wide. Tests run on PowerShell 7 and Windows PowerShell 5.1.

## Suites

| Suite | Touches | Safe on a workstation |
|---|---|---|
| Unit (`Tests\Unit`) | nothing: the low-level registry and servicing functions are replaced by in-memory fakes | yes |
| Integration (`Tests\Integration`) | Pester's TestRegistry (`HKCU\Software\Pester\<guid>`, removed afterwards) and TestDrive; everything else is read-only (inventory, benchmark, optional feature state, access control lists) | yes |
| Destructive (`Tests\Destructive`) | the real Windows configuration: applies and restores the Safe profile, removes and restores a disposable entry in the real Run key, toggles the Telnet Client optional feature | **no - disposable VM only** |

```powershell
# In a disposable VM only (see VmValidation.md):
$env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'
.\Tests\Invoke-WinLeanTests.ps1 -Suite Destructive
```

Run the destructive suite once as a standard user and once elevated to cover per-user and
machine-wide rules; the optional feature test needs elevation and skips itself otherwise.
`-Suite All` never includes it, and the runner refuses it without the environment variable.

## Static analysis

`Tests\Invoke-WinLeanAnalysis.ps1` runs PSScriptAnalyzer (pinned to one version so that a new
analyzer release cannot change the result for an unchanged commit) with
`PSScriptAnalyzerSettings.psd1`:

- Errors and warnings fail the analysis; Information-level findings are advisory
  (`-IncludeInformation` lists them).
- `PSUseCompatibleSyntax` is enabled for PowerShell 5.1 and 7.0: syntax that only one of
  them understands is an error.
- Two rules are excluded, with the reasons recorded in the settings file:
  `PSUseShouldProcessForStateChangingFunctions` (name-based; replaced by a repository test
  that requires `-WhatIf` support in every provider Set/Restore operation and every
  low-level write function) and `PSUseSingularNouns` (functions returning collections are
  named in the plural, several of them in the facade).
- For the Pester tests only, `PSUseDeclaredVarsMoreThanAssignments` is excluded: the analyzer
  cannot connect variables assigned in `BeforeEach` with their use in `It` blocks.
- Individual suppressions carry a justification next to the code (for example the uniform
  collector and provider signatures). A repository test fails when the exclusion list in the
  settings file changes.

## Continuous integration

`.github\workflows\tests.yml` runs on a hosted Windows Server runner for every push and pull
request: static analysis, `-Validate`, and the Unit and Integration suites on PowerShell 7
and on Windows PowerShell 5.1.

- Hosted runners are not disposable WinLean test machines. The Destructive suite is never
  run there; a repository test fails if a workflow references it or its opt-in variable.
- WinLean treats every rule as Unsupported on Windows Server, so the CLI apply/restore cycle
  (which only writes to TestRegistry) runs on Windows 11 client machines only.
- The runner is elevated, so the integration tests read optional feature state through DISM
  there, while a standard-user workstation reads it through `Win32_OptionalFeature`.

## What is covered

- Unit: property/JSON helpers and atomic writes; failure classification; logging; registry
  path parsing, protected locations, value conversion and comparison; rule, catalog, profile
  and compatibility validation, including benefit and validation metadata and the evidence
  standard; rule loading; conditions and applicability; profiles and inheritance; dependency
  ordering and cycles; plan generation for every status (conflicts, dependencies, access,
  per-user target, untested builds, unreadable, unrestorable and unavailable state);
  execution (backup first, verification failure and rollback, write and permission failures,
  dependency failures, backup failure, idempotency); the provider contract (result
  normalization, reboot propagation, dispatch); the StartupEntry provider (validation, exact
  capture, apply/verify/undo, conflicts across resource types); the WindowsOptionalFeature
  provider (validation, rule constraints, state semantics, DISM and CIM read paths,
  privilege blocking, reboot reporting, collateral-change protection, failure rollback);
  backup and restore with several resource types; restore decisions, drift and `-Force`,
  re-checks, failures and other-user protection; compatibility and capabilities; the
  `-Configure` questionnaire (questions, answers, migration of existing files, validated
  atomic saving); evidence attribution and write-ups; the registry access report; benchmark
  math; report rendering; repository integrity (shipped rules and profiles valid and matching
  their JSON schemas, profile admission rules, ASCII-only sources, ordinal text searches,
  `-WhatIf` support, manifest exports, analyzer exclusions, CI guard); culture safety under
  tr-TR.
- Integration: registry provider round trips for every value kind, missing-key handling and
  write-access probing; the StartupEntry provider against the real registry API (location
  redirected to TestRegistry); optional feature state, read-only; CLI end to end in a child
  process (validate, list rules, dry run, error exit codes, `-Configure` with piped answers,
  apply, idempotency, restore preview, restore, drift and `-Force`); evidence capture with
  real snapshots; the access report with real access control lists; inventory and benchmark
  on the real machine.
- Destructive (VM only): the Safe profile, a disposable entry in the real per-user Run key,
  and the Telnet Client optional feature - each applied, verified and restored.

Not covered by automated tests on this machine: anything that needs elevation with real
servicing (the DISM enable/disable path is tested against a fake and in the destructive
suite only).

## Writing tests

- Dot-source `Tests\Helpers\TestHelpers.ps1` in `BeforeAll`; use `Import-WinLeanTestModule`
  so every test file starts with a clean module table.
- For anything that reads or writes the registry, create `$script:FakeRegistry = New-FakeRegistry`
  and call `Register-FakeRegistryMocks` in `BeforeEach`. The fake supports denied paths,
  failing writes, "sticky" values (ignored writes, to simulate policy overrides) and read
  failures. StartupEntry resources use the same fake.
- For optional features, create `$script:FakeFeatures = New-FakeFeatureStore -Features @{...}`
  and call `Register-FakeFeatureMocks`. The fake supports missing elevation, pending states,
  DISM's restart flag, parent-to-child cascades (collateral changes) and failing features.
- `-Skip` and `-ForEach` values are evaluated during discovery; compute them in
  `BeforeDiscovery`, not in `BeforeAll`.
- The test scope runs under strict mode: data-driven cases must define every key they use,
  and a local variable must not reuse the name of a data key (variable names are
  case-insensitive).
- A script block created with `GetNewClosure()` has its own script scope: capture state
  through local variables, not `$script:` variables.
- Any test that changes real configuration outside TestRegistry/TestDrive belongs in
  `Tests\Destructive` with the `Destructive` tag and the opt-in check.
