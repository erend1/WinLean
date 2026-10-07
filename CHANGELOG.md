# Changelog

All notable changes to WinLean are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0-alpha] - 2026-10-07

Milestone 0.2A: engine capabilities for feature-dependent rules. No rules were added and
the Safe, Lean and Minimal profiles are unchanged.

### Added

- `-Configure`: interactive questionnaire that creates or updates the compatibility
  configuration. Every requirement is asked by topic with its current answer and read-only
  detection hints; hints never change an answer. Existing answers and unknown entries are
  kept, files with errors are refused, and the validated result replaces the file atomically
  while the previous version is kept as `Compatibility.previous.json`.
- `StartupEntry` resource provider: programs started through the Run keys (`CurrentUserRun`,
  `MachineRun`, `MachineRun32`), present or absent, with exact capture of the command and
  value kind. RunOnce keys, Startup folders and Task Manager's `StartupApproved` data are not
  managed; the latter is now a protected registry location.
- `WindowsOptionalFeature` resource provider: enables or disables optional features through
  DISM only. Reads state without elevation (CIM), requires elevation to change, treats
  features missing from the image as disabled, blocks features with a pending restart,
  reports DISM's restart requirement, and detects, reverts and fails changes that alter
  other features too (`CollateralChange`). Defender, virtualization-based security, device
  lockdown and Sysmon features are never changed; SMB 1.0, Windows PowerShell 2.0 and Simple
  TCP/IP services are never enabled.
- Provider contract extensions: providers may report a restart requirement, mark resources
  as not available on the system (plan status Unsupported) and check rule-level constraints.
  Conflicts are detected across resource types that share an identity.
- Rule metadata `benefit` (type, qualitative value, measured or not) and `validation`
  (method, build, date, record). Performance claims and Moderate/High background-activity
  claims require a recorded measurement; `windows.maxValidatedBuild` must equal the newest
  validated build. The plan, `-ListRules` and reports show and summarize benefits.
- Evidence standard (rules may be backed by a recorded observation for per-user Settings
  toggles) with a capture tool that records the environment, a no-action baseline, toggle
  cycles performed by the operator and the changes attributable to the toggle; it refuses to
  run outside a detected VM or Windows Sandbox unless the operator confirms a disposable
  environment.
- `Tools\Get-WinLeanRegistryAccessReport.ps1`: read-only report of explicit and inherited
  registry access entries, with a comparison against a report from another system.
- Static analysis with a pinned PSScriptAnalyzer, including PowerShell 5.1/7 syntax
  compatibility; GitHub Actions workflow running the analysis, validation and the unit and
  integration tests on PowerShell 7 and Windows PowerShell 5.1.
- Documentation: VM validation procedure and checklist, validation and measurement record
  folders, registry access observations, and updated rule, safety, compatibility and testing
  guides.
- Destructive tests (VM only, opt-in) for a disposable entry in the real Run key and for the
  Telnet Client optional feature.

### Changed

- Every rule must declare its `benefit`; rule files written for 0.1 need this one addition.
  `validation` records are optional, so older rule files keep loading, and required for
  shipped rules.
- Rules of risk Medium or High must have a `requirement.*` condition. Rules that disable an
  optional feature a compatibility requirement depends on (Hyper-V, WSL, Virtual Machine
  Platform, Windows Sandbox, containers, printing, SMB, search, ...) must require that
  requirement to be `false`.
- `RegistryValue` resources may no longer target the Run and RunOnce keys.
- Rule and restore results take the restart requirement from the provider when it reports
  one; change records store the rule's declaration for restores.
- The domain warning considers only policy-based resources.
- The module version includes a prerelease label (`0.2.0-alpha`).
- Variables and parameters named `$profile` were renamed (they shadowed PowerShell's
  automatic variable); `-Profile` remains available as a parameter alias.

### Fixed

- Running WinLean a second time in the same PowerShell session with `-WhatIf` listed the
  engine modules as "What if: Remove-Module" operations and did not reload them.
- Text searches with string arguments used culture-sensitive comparisons; they are ordinal
  now, and a repository test rejects new ones.
- The "no compatibility configuration" messages pointed to copying the example file; they
  now point to `-Configure`.

## [0.1.0] - 2026-09-29

Milestone 0.1: the architectural foundation.

### Added

- CLI `WinLean.ps1`: `-Analyze`, `-Profile <name> [-WhatIf]`, `-Profile <name> -Apply`,
  `-Restore <Latest|id> [-Force] [-WhatIf]`, `-Benchmark`, `-Report [-Backup id]`,
  `-ListRules`, `-ListBackups`, `-Validate`; documented exit codes.
- Engine facade (`src\WinLean.Core.psm1`, manifest `src\WinLean.psd1`) with an explicit session
  object; component modules for inventory, compatibility, rules, policy, execution, backup,
  restore, benchmark, reporting, logging and validation.
- Declarative JSON rule model with JSON schemas, validation (typo protection, required
  documentation and references, protected registry locations, dependency cycles, undeclared
  conflicts) and the `RegistryValue` resource provider (exact .NET registry access, lossless
  capture of every restorable value kind, non-modifying write-access probe).
- Read-only inventory with per-section fault isolation: system, security, hardware, AppX and
  provisioned packages, Win32 applications, WinGet packages, optional features, startup
  entries, services (vendor heuristic) and scheduled tasks.
- Compatibility context separating user requirements from detected capabilities; undeclared
  requirements are treated as required.
- Profiles with inheritance and exclusions: Safe, Lean, Minimal (placeholder),
  Example.Custom.
- Policy engine producing an explicit plan with the statuses Applicable, AlreadySatisfied,
  Skipped, Blocked, RequiresConfirmation and Unsupported, including dependency ordering,
  conflict detection, build/edition gating, write-access checks and the per-user target check.
- Backup-first execution with per-rule verification and rollback, crash-safe records and an
  exclusive lock; restore of recorded previous values with drift protection and verification.
- Benchmark (CPU from raw performance counters, memory, processes, services, startup entries)
  and Markdown reports with before/after comparison and restore history.
- Nine documented low-risk rules (privacy, recommendations, File Explorer).
- Pester 5 test suites: unit (in-memory fake registry), integration (TestRegistry/TestDrive,
  CLI end to end), destructive (gated, VM only). Runs on PowerShell 7 and 5.1.
- Documentation: README, Architecture, Rules (with research log), Safety, Benchmarking,
  Compatibility, Testing.

### Fixed

- Atomic JSON file replacement passed `$null` as a .NET string (converted to an empty path).
- Report and inventory summary lists could become `$null` when empty.
