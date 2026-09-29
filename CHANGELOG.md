# Changelog

All notable changes to WinLean are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
