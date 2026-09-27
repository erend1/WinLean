You are the lead software engineer responsible for implementing a new project called **WinLean**.

Read the accompanying `PROJECT_SPEC.md` completely before modifying or generating code.

Your responsibility is not merely to write a Windows debloat script.

You are building a small, maintainable, testable, reversible Windows configuration and optimization framework.

The core design principle is:

> Windows, minus everything the user does not intentionally use.

The system must favor stability, transparency, reversibility, supported Windows mechanisms, and measurable optimization over aggressive undocumented tweaks.

## Absolute Constraints

Do NOT:

- disable Windows Update
- disable Microsoft Defender
- disable Windows Firewall
- disable core Windows servicing infrastructure
- delete Windows services
- make kernel modifications
- remove shared system DLLs
- use destructive filesystem deletion as a substitute for proper package management
- apply undocumented “gaming tweaks” without strong technical justification
- execute arbitrary AI-generated shell commands
- optimize purely for lowest process count
- blindly copy rules from existing debloat projects

No optimization should be introduced merely because another repository, forum post, Reddit thread, or YouTube video recommends it.

Every optimization must be understood.

---

# Objective for Milestone 0.1

Implement the architectural foundation of WinLean.

Do NOT attempt to implement hundreds of optimization rules yet.

The first milestone should prove that the following architecture works:

```text
Inventory
    ↓
Compatibility Context
    ↓
Profile
    ↓
Rule Evaluation
    ↓
Dry Run
    ↓
Backup
    ↓
Execution
    ↓
Verification
    ↓
Logging
    ↓
Report
    ↓
Restore
```

---

# Technology

Start with:

```text
PowerShell 7+
```

Maintain compatibility with modern Windows 11.

Avoid unnecessary external dependencies.

Where PowerShell 5.1 compatibility is easy to preserve, that is desirable but not mandatory if it significantly harms architecture.

---

# Repository

Create approximately the following structure:

```text
WinLean/
│
├── README.md
├── LICENSE
├── CHANGELOG.md
├── WinLean.ps1
│
├── src/
│   ├── WinLean.Core.psm1
│   ├── Inventory.psm1
│   ├── Policy.psm1
│   ├── Executor.psm1
│   ├── Backup.psm1
│   ├── Restore.psm1
│   ├── Benchmark.psm1
│   ├── Logging.psm1
│   └── Validation.psm1
│
├── Rules/
│   ├── Applications/
│   ├── Startup/
│   ├── Services/
│   ├── ScheduledTasks/
│   ├── Privacy/
│   ├── Features/
│   ├── Gaming/
│   ├── Explorer/
│   ├── Search/
│   ├── Networking/
│   ├── Power/
│   ├── Security/
│   ├── Development/
│   └── ThirdParty/
│
├── Profiles/
│   ├── Safe.json
│   ├── Lean.json
│   ├── Minimal.json
│   └── Example.Custom.json
│
├── Config/
│   ├── Compatibility.example.json
│   └── Packages.json
│
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   └── Fixtures/
│
├── Reports/
├── Backups/
│
└── Docs/
    ├── Architecture.md
    ├── Rules.md
    ├── Safety.md
    ├── Benchmarking.md
    └── Compatibility.md
```

You may improve this layout if there is a clear architectural reason.

Explain major deviations.

---

# CLI

Implement an initial CLI resembling:

```powershell
.\WinLean.ps1 -Analyze

.\WinLean.ps1 -Profile Safe -WhatIf

.\WinLean.ps1 -Profile Safe -Apply

.\WinLean.ps1 -Restore Latest

.\WinLean.ps1 -Benchmark

.\WinLean.ps1 -Report
```

Do not rely only on PowerShell's built-in `-WhatIf` semantics if that prevents producing a complete structured plan.

WinLean should have its own explicit planning model.

---

# Rule System

Design a formal rule schema.

Each rule should contain at least:

```text
ID
Name
Category
Description
Risk
Reversible
Requires reboot
Supported Windows versions/builds
Conditions
Dependencies
Conflicts
Expected effects
Possible side effects
Apply
Undo
Verify
```

Rules may initially be implemented as PowerShell objects, PSD1, JSON, YAML, or another clearly justified representation.

Prefer a representation that is:

- easily reviewable
- easy to diff in Git
- easy to validate
- easy to load programmatically

Do not embed all rules in one giant PowerShell file.

---

# Rule Interface

Conceptually, every rule must support:

```text
Test-Applicable
Get-State
Apply
Verify
Undo
```

Applying a rule should return a structured result.

Example:

```json
{
  "ruleId": "privacy.recommendations.disable",
  "status": "success",
  "changed": true,
  "before": {},
  "after": {},
  "rebootRequired": false
}
```

---

# Idempotency

Design idempotency from the beginning.

If:

```powershell
.\WinLean.ps1 -Profile Safe -Apply
```

is executed three times, the second and third executions should largely produce:

```text
already satisfied
```

rather than repeat destructive actions.

---

# Inventory

Implement an initial system inventory.

Collect at least:

```text
Windows edition
Windows version
Windows build
architecture
CPU
installed RAM
GPU if reasonably accessible

AppX packages
provisioned AppX packages
installed Win32 applications where practical
WinGet packages if WinGet exists

optional Windows features

startup registry entries
startup folders

services
service startup type
service running state

scheduled tasks

basic security state:
Defender
Firewall
Secure Boot where available
```

Unknown or inaccessible information should not crash inventory.

Record it as unavailable.

Serialize inventory to JSON.

---

# Compatibility Context

Design a compatibility object.

Example:

```json
{
  "printer": true,
  "bluetooth": true,
  "xbox": false,
  "gamePass": false,
  "onedrive": false,
  "hyperV": true,
  "wsl2": true,
  "windowsSandbox": false,
  "remoteDesktop": false,
  "windowsHello": true,
  "bitLocker": true,
  "touch": false,
  "pen": false,
  "windowsSearch": true,
  "developerMachine": true,
  "gamingMachine": true
}
```

For milestone 0.1 this may be loaded from configuration rather than automatically detected.

Keep detection and user preference separate.

Example:

```text
hardware capability:
Bluetooth adapter exists

user requirement:
Bluetooth must be preserved
```

Those are not the same thing.

---

# Policy Engine

The policy engine should:

1. load selected profile
2. load rule registry
3. validate rule IDs
4. evaluate compatibility conditions
5. evaluate dependencies
6. evaluate conflicts
7. inspect current state
8. generate an execution plan

The result should distinguish:

```text
Applicable
Already satisfied
Skipped
Blocked
Requires confirmation
Unsupported
```

---

# Dry Run

Before system modification, produce a plan such as:

```text
WINLEAN PLAN

Profile: Safe

Applicable rules: 14

APPLY
────────────────────

privacy.recommendations.disable
Risk: Low
Reversible: Yes

privacy.advertising-id.disable
Risk: Low
Reversible: Yes


ALREADY SATISFIED
────────────────────

explorer.show-file-extensions


SKIPPED
────────────────────

services.print-spooler.disable

Reason:
Printer compatibility requirement enabled.
```

Also serialize the plan to JSON.

---

# Backup

Before Apply:

create a timestamped backup directory.

Example:

```text
Backups/
2026-09-27_18-45-12/
```

Record:

```text
inventory
plan
rule states before modification
registry values touched
service configuration touched
scheduled task configuration touched
feature configuration touched
package information touched
```

Do not attempt full-system backup.

Back up only the state required to reverse WinLean changes.

---

# Initial Rules

Implement only a small number of low-risk demonstration rules.

Approximately 5–10 rules are sufficient.

Prefer rules from categories such as:

```text
Privacy
Recommendations
Explorer
UI
Startup inspection
```

Avoid service disabling in milestone 0.1.

Avoid aggressive application removal.

Candidate demonstration rules might include:

```text
Disable Windows suggested/recommended content
Disable personalized advertising ID where supported
Show file extensions
Show hidden files as an optional rule
Disable a clearly optional recommendation setting
```

Before implementing each rule:

document exactly what Windows setting it modifies.

Do not guess registry values.

If a setting cannot be confidently verified, omit that rule for now and document it as future research.

---

# Verification

After every Apply operation:

read the resulting system state again.

Do not assume success merely because a command returned without error.

Example:

```text
write registry value
read registry value
compare
```

If verification fails:

mark rule as failure.

Do not continue pretending the desired state was achieved.

---

# Logging

Implement:

```text
console log
text log
JSON execution log
```

Suggested levels:

```text
TRACE
DEBUG
INFO
WARN
ERROR
```

Console output should remain readable.

Example:

```text
[INFO] Inventory completed

[APPLY] privacy.recommendations.disable
[OK] Verified

[SKIP] services.print-spooler.disable
Printer support required
```

---

# Restore

Implement:

```powershell
.\WinLean.ps1 -Restore Latest
```

Restore must:

1. load previous WinLean backup
2. determine what WinLean changed
3. restore captured previous state
4. verify restoration
5. log results

Do not simply apply assumed Windows defaults.

Restore the recorded previous values wherever possible.

---

# Benchmark

Implement a basic benchmark module.

Initially measure:

```text
current process count
idle memory usage
idle CPU sampling
running services
third-party running services where reasonably identifiable
startup entry count
```

If Windows boot timing information can be obtained reliably without adding major complexity, include it.

Otherwise leave boot benchmarking as a future milestone.

Do not create fake precision.

Document measurement methodology.

---

# Reporting

Generate a Markdown report containing:

```text
System information
Profile
Compatibility configuration
Before benchmark
After benchmark
Applied rules
Skipped rules
Failed rules
Restore point / backup location
Reboot requirement
```

---

# Error Handling

A single failed optimization must not corrupt the whole execution.

Rules should fail independently where possible.

Classify failures.

For example:

```text
PermissionDenied
Unsupported
CommandFailed
VerificationFailed
DependencyFailure
UnexpectedError
```

---

# Administrator Privileges

Detect whether administrative privileges are required.

Do not silently attempt privilege escalation.

Clearly report when the user must launch PowerShell as Administrator.

Analysis-only commands should work without administrator rights wherever practical.

---

# Windows Version Safety

Detect Windows version and build.

Rules should be able to declare supported ranges.

Do not apply an optimization to an unknown future Windows build merely because it happened to work on an older build.

Unknown builds should produce a warning or require explicit override where appropriate.

---

# Testing

Use Pester.

Create unit tests for:

```text
profile loading
rule validation
condition evaluation
dependency handling
conflict handling
plan generation
backup serialization
restore-state logic
idempotency helpers
```

System-changing integration tests should not automatically run on the developer's primary machine.

Clearly separate:

```text
Unit tests
Integration tests
Destructive integration tests
```

---

# Documentation

Create a high-quality README.

The README should explain:

```text
What WinLean is
What WinLean is not
Why it exists
Safety philosophy
How to analyze
How to dry-run
How to apply
How to restore
How to create a custom profile
How rules work
How to contribute a rule
```

Also document the rule-development checklist.

---

# Engineering Quality

Prefer:

```text
small functions
clear naming
strict mode
structured objects
typed concepts where useful
explicit error handling
testability
separation of concerns
```

Avoid:

```text
one giant script
global mutable state
magic registry values
copy-pasted tweaks
silent failures
arbitrary sleeps
hard-coded paths
```

Use `$env:` and proper Windows path APIs rather than assuming user names or drive letters.

---

# Source Control

Use Git from the beginning.

Create logical commits.

Suggested initial sequence:

```text
chore: initialize WinLean repository

feat: add core rule model

feat: add inventory engine

feat: add profile and policy engine

feat: add execution planning

feat: add backup and restore framework

feat: add initial low-risk rules

feat: add benchmark reporting

test: add core Pester coverage

docs: document architecture and safety model
```

Do not combine the entire project into one massive initial commit if practical.

---

# Work Style

You may use worker agents if available.

Suggested parallel workstreams:

Agent 1:
Core architecture, rules, policy engine.

Agent 2:
Inventory, backup, restore, benchmark.

Agent 3:
Tests and documentation.

The lead agent must review and integrate all work.

Do not allow worker agents to independently invent aggressive Windows tweaks.

---

# Before Coding

First:

1. inspect the current repository
2. read PROJECT_SPEC.md
3. summarize the proposed architecture
4. identify ambiguous design decisions
5. choose sensible defaults without blocking progress
6. produce a milestone plan
7. begin implementation

Do not ask the human to decide trivial implementation details.

Use engineering judgment.

Escalate only decisions that materially affect safety, compatibility, or project direction.

---

# Definition of Done for Milestone 0.1

Milestone 0.1 is complete when:

```text
WinLean can inventory a Windows machine.

WinLean can load a profile.

WinLean can evaluate known rules.

WinLean can generate a dry-run execution plan.

WinLean can back up affected state.

WinLean can apply several safe rules.

WinLean verifies every applied rule.

WinLean logs what happened.

WinLean can restore the captured state.

WinLean can generate a before/after report.

Core policy behavior has automated tests.
```

Do not expand scope until this foundation is reliable.

At the end of the milestone provide:

```text
1. architecture summary
2. implemented functionality
3. repository tree
4. test results
5. known limitations
6. safety considerations
7. proposed milestone 0.2
8. exact commands for the human to test WinLean safely
```

The project should be treated as production-quality systems tooling even though it begins as a personal project.

Reliability is more important than the number of tweaks implemented.