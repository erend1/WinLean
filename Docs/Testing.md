# Testing

```powershell
.\Tests\Invoke-WinLeanTests.ps1 -Bootstrap            # once: saves Pester 5 to .tools\Modules
.\Tests\Invoke-WinLeanTests.ps1                       # Unit (default)
.\Tests\Invoke-WinLeanTests.ps1 -Suite Integration
.\Tests\Invoke-WinLeanTests.ps1 -Suite All -OutputPath .\TestResults\results.xml
```

The runner requires Pester >= 5.5 and < 6. It uses `.tools\Modules` first, then installed
modules; `-Bootstrap` saves Pester into the repository (`.tools` is ignored by Git) instead of
installing it system-wide. Tests run on PowerShell 7 and Windows PowerShell 5.1.

## Suites

| Suite | Touches | Safe on a workstation |
|---|---|---|
| Unit (`Tests\Unit`) | nothing: the six low-level registry functions are replaced by an in-memory fake registry | yes |
| Integration (`Tests\Integration`) | Pester's TestRegistry (`HKCU\Software\Pester\<guid>`, removed afterwards), TestDrive; read-only inventory and benchmark | yes |
| Destructive (`Tests\Destructive`) | the real Windows configuration (applies and restores the Safe profile) | **no - VM or Windows Sandbox only** |

```powershell
# In a disposable VM or Windows Sandbox only:
$env:WINLEAN_ALLOW_DESTRUCTIVE_TESTS = 'YES'
.\Tests\Invoke-WinLeanTests.ps1 -Suite Destructive
```

Run the destructive suite once as a standard user and once elevated to cover per-user and
machine-wide rules.

## What is covered

- Unit: property/JSON helpers and atomic writes; failure classification; logging; registry
  path parsing, protected locations, value conversion and comparison; rule, catalog, profile
  and compatibility validation; rule loading; conditions and applicability; profiles and
  inheritance; dependency ordering and cycles; plan generation for every status (conflicts,
  dependencies, access, per-user target, untested builds, unreadable and unrestorable state);
  execution (backup first, verification failure and rollback, write and permission failures,
  dependency failures, backup failure, idempotency); backup serialization of every value
  kind; backup lookup and lock; restore decisions, exact restoration, drift and `-Force`,
  re-checks, failures and other-user protection; compatibility and capabilities; benchmark
  math; report rendering; repository integrity (shipped rules and profiles valid and matching
  their JSON schemas, ASCII-only sources, manifest exports); culture safety under tr-TR.
- Integration: registry provider round trips for every value kind, missing-key handling and
  write-access probing; CLI end to end in a child process (validate, list rules, dry run,
  error exit codes, apply, idempotency, restore preview, restore, drift and `-Force`);
  inventory and benchmark on the real machine.

## Writing tests

- Dot-source `Tests\Helpers\TestHelpers.ps1` in `BeforeAll`; use `Import-WinLeanTestModule`
  so every test file starts with a clean module table.
- For anything that reads or writes the registry, create `$script:FakeRegistry = New-FakeRegistry`
  and call `Register-FakeRegistryMocks` in `BeforeEach`. The fake supports denied paths,
  failing writes, "sticky" values (ignored writes, to simulate policy overrides) and read
  failures.
- `-Skip` and `-ForEach` values are evaluated during discovery; compute them in
  `BeforeDiscovery`, not in `BeforeAll`.
- The test scope runs under strict mode: data-driven cases must define every key they use.
