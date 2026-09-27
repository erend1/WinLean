# WinLean
## Reproducible, Reversible Windows Optimization Framework

### 1. Project Purpose

WinLean is a Windows optimization framework whose purpose is to transform a normal, supported Windows installation into a deliberately minimal, clean, fast, and predictable system without compromising:

- Windows Update
- Windows servicing
- system stability
- security
- gaming compatibility
- development tools
- driver compatibility
- recoverability
- future Windows upgrades

The project must not behave like a traditional “debloat script” that blindly deletes applications, services, scheduled tasks, or registry keys.

Instead, WinLean should behave like a small infrastructure-as-code system for Windows.

The governing principle is:

> Windows, minus everything we do not intentionally use.

The project should prioritize measurable reduction of unnecessary activity rather than cosmetic reductions in Task Manager process count.

---

# 2. Core Design Principles

## 2.1 Reversible by Default

Every meaningful configuration change must have:

- an apply operation
- an undo operation
- a verification operation
- a description of expected effects
- a description of possible side effects

A change that cannot reasonably be reversed must be explicitly classified as such.

Irreversible operations should be rare and should not be part of the default Safe or Lean profiles.

---

## 2.2 Idempotent

Running WinLean multiple times should not damage the system.

For example:

- removing an already removed AppX package should not fail the entire process
- disabling an already disabled setting should be treated as success
- applying the same registry value twice should not produce inconsistent state
- installed packages should be detected before installation

The ideal behavior is:

```text
Apply profile
Apply profile again
Apply profile again

Result: same system state
```

---

## 2.3 Transparent

Before changing the system, WinLean should be able to produce a dry-run plan.

Example:

```text
PLAN

[REMOVE] Microsoft.SomeUnusedPackage
Risk: Low
Reversible: Yes

[DISABLE] Windows personalized recommendations
Risk: Low
Reversible: Yes

[KEEP] Xbox authentication services
Reason: Xbox/Game Pass usage enabled

[SKIP] Print Spooler
Reason: Printer support requested
```

No major operation should be hidden from the user.

---

## 2.4 Deterministic Execution

Artificial intelligence may help analyze the system or recommend a configuration.

Artificial intelligence must not execute arbitrary destructive commands directly.

The recommended architecture is:

```text
System Inventory
      │
      ▼
Analysis / AI
      │
      ▼
Known Rule IDs
      │
      ▼
Policy Engine
      │
      ▼
Deterministic Implementation
```

For example:

```text
AI recommends:

services.print-spooler.disable
apps.onedrive.remove
privacy.recommendations.disable
```

The AI should not generate arbitrary commands such as:

```powershell
sc.exe delete ...
```

Instead, each rule ID maps to a reviewed implementation already present in the repository.

---

# 3. Non-Goals

WinLean is NOT intended to:

- create a custom Windows ISO initially
- permanently remove Windows Update
- remove the servicing stack
- disable Defender merely to reduce RAM usage
- disable hardware security features for synthetic benchmarks
- modify Windows kernel files
- apply undocumented gaming tweaks without evidence
- delete arbitrary system services
- remove components merely because a YouTube guide claims they are unnecessary
- optimize solely for lowest possible Task Manager process count

The project may later investigate advanced image customization, but this is explicitly outside the first versions.

---

# 4. Optimization Philosophy

The optimization target is not:

```text
minimum possible number of processes
```

The optimization target is:

```text
minimum unnecessary system activity
while preserving required functionality
```

Metrics that matter include:

- idle CPU usage
- idle memory consumption
- background disk I/O
- background network traffic
- startup time
- login-to-usable-desktop time
- startup application count
- persistent third-party service count
- scheduled background activity
- DPC/ISR latency where relevant
- game 1% low performance where relevant
- application startup latency
- Windows Update reliability
- event-log health

---

# 5. Optimization Categories

WinLean should organize rules into clear categories.

Recommended categories:

```text
Applications
Startup
Services
Scheduled Tasks
Privacy
Recommendations / Advertising
Optional Windows Features
Gaming
Explorer / Shell
Search
Cloud Integration
Development
Networking
Power
Storage / Cleanup
Telemetry
Security
OEM Software
Third-Party Software
UI Preferences
Package Installation
```

---

# 6. Risk Model

Each rule should receive a risk classification.

## LOW

Normally safe and unlikely to affect compatibility.

Examples:

- disable personalized recommendations
- disable advertising ID
- disable unwanted startup application
- uninstall clearly optional third-party bloatware
- configure Explorer preferences

## MEDIUM

Feature-dependent.

Examples:

- disable Print Spooler
- remove OneDrive
- disable Xbox-related functionality
- disable Bluetooth-related services
- disable Windows Search indexing
- remove certain optional Windows features

Requires explicit compatibility conditions.

## HIGH

May impact servicing, security, or broad compatibility.

Examples:

- disabling core Windows security components
- disabling Windows Update services
- removing servicing infrastructure
- removing broadly shared runtime components
- undocumented scheduler/kernel tweaks
- permanently deleting system services

High-risk rules should normally be excluded from standard builds.

---

# 7. Profiles

The first release should contain four profiles.

## 7.1 Safe

Purpose:

General cleanup suitable for almost every Windows system.

Suggested scope:

- disable advertisements
- disable personalized recommendations
- disable suggested content
- remove obvious promotional applications
- disable unnecessary startup entries
- remove OEM trialware
- privacy cleanup using supported settings
- configure Explorer
- clean temporary files
- install desired baseline utilities
- leave core Windows services untouched

The Safe profile should have very low compatibility risk.

---

## 7.2 Lean

This should become the recommended everyday profile.

Includes Safe plus:

- unused optional Windows components
- application background restrictions
- selected scheduled tasks
- unused integrations
- selected feature-dependent services
- gaming-aware changes
- development-aware configuration
- cloud integration cleanup
- vendor updater cleanup
- third-party startup reduction

Lean should aggressively remove wasted work while respecting known user requirements.

---

## 7.3 Minimal

Includes Lean plus more aggressive removals.

May include:

- major optional component removal
- feature-specific service disabling
- deeper AppX cleanup
- broader scheduled task disabling
- optional shell feature removal
- optional Windows integration reduction

Every operation must still remain documented.

Minimal should display clear compatibility warnings.

---

## 7.4 Custom

The system creates a profile based on user requirements.

Typical questionnaire:

```text
Do you use Bluetooth?
Do you print?
Do you use scanners?
Do you use Xbox Game Pass?
Do you use Microsoft Store?
Do you use OneDrive?
Do you use Hyper-V?
Do you use WSL2?
Do you use Windows Sandbox?
Do you use Remote Desktop?
Do you use Windows Hello?
Do you use BitLocker?
Do you use touch input?
Do you use a pen?
Do you use Windows Search indexing?
Do you use Phone Link?
Do you use widgets?
Do you use Microsoft Teams?
Do you use Copilot?
Do you use location services?
Do you use telemetry-dependent diagnostics?
Do you use virtualization software?
Do you use Docker Desktop?
Do you use Visual Studio?
Do you use SQL Server?
Do you use NVIDIA/AMD vendor utilities?
Do you use RGB/control-center software?
Do you use motherboard vendor utilities?
Do you use printers over the network?
Do you use file sharing?
Do you use SMB?
Do you use Xbox controllers?
Do you use Bluetooth audio?
```

Answers should produce compatibility flags consumed by the rule engine.

---

# 8. Example Compatibility Context

Internally, WinLean could create a system/user capability object such as:

```json
{
  "printer": false,
  "bluetooth": true,
  "xbox": true,
  "gamePass": true,
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
  "phoneLink": false,
  "widgets": false,
  "copilot": false,
  "developerMachine": true,
  "gamingMachine": true
}
```

Rules evaluate conditions against this object.

---

# 9. Rule Model

Each optimization should exist as a discrete rule.

Recommended conceptual schema:

```yaml
id: privacy.recommendations.disable

name: Disable Windows recommendations

category: privacy

description:
  Disable personalized recommendations and suggested content.

risk: low

reversible: true

reboot_required: false

supported:
  windows_11: true

conditions: []

effects:
  - disables_suggested_content
  - reduces_promotional_content

side_effects:
  - fewer personalized Windows recommendations

apply:
  implementation_reference

undo:
  implementation_reference

verify:
  implementation_reference
```

More conditional example:

```yaml
id: services.print-spooler.disable

name: Disable Print Spooler

category: services

risk: medium

reversible: true

reboot_required: false

conditions:
  printer: false

side_effects:
  - local printing unavailable
  - network printing unavailable
  - some PDF software may depend on printing APIs

apply:
  implementation_reference

undo:
  implementation_reference

verify:
  implementation_reference
```

---

# 10. Recommended Repository Structure

Initial structure:

```text
WinLean/
│
├── README.md
├── LICENSE
├── CHANGELOG.md
│
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
│   ├── Compatibility.json
│   └── Packages.json
│
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   └── Fixtures/
│
├── Reports/
│
├── Backups/
│
└── Docs/
    ├── Architecture.md
    ├── Rules.md
    ├── Safety.md
    ├── Benchmarking.md
    └── Compatibility.md
```

---

# 11. PowerShell First

The first implementation should use PowerShell.

Reasons:

- native Windows administration
- registry access
- service management
- AppX management
- scheduled task management
- optional feature management
- WinGet integration
- easy logging
- easy portability
- easy manual inspection

The project should avoid introducing a large compiled application before the optimization policy itself is stable.

---

# 12. Future GUI

A later version may use .NET.

Potential architecture:

```text
WinLean.Core
    │
    ├── Inventory
    ├── Policy Engine
    ├── Rule Database
    ├── Executor
    └── Reporting

PowerShell CLI
      +
.NET GUI
```

The GUI should call the same underlying engine.

Possible UI:

```text
WinLean

System Analysis
──────────────────────────────────

Startup applications            17
Third-party services            21
Optional packages               12
Possible optimizations          34

Profile

○ Safe
● Lean
○ Minimal
○ Custom

[Analyse]
[Preview Changes]
[Optimize]
[Restore]
```

---

# 13. Execution Lifecycle

Recommended workflow:

```text
1. Detect operating system
2. Detect Windows build
3. Verify administrator privileges
4. Create inventory
5. Create baseline benchmark
6. Create backup
7. Load compatibility profile
8. Load optimization profile
9. Evaluate rules
10. Produce plan
11. Show dry run
12. Request execution
13. Apply rules
14. Verify every rule
15. Record outcome
16. Reboot if required
17. Run post-optimization benchmark
18. Generate report
```

---

# 14. Inventory

Before modification, WinLean should collect:

## System

- Windows edition
- Windows version
- Windows build
- architecture
- CPU
- RAM
- GPU
- storage devices
- motherboard if useful

## Windows features

- enabled optional features
- installed capabilities
- AppX packages
- provisioned AppX packages

## Applications

- installed Win32 applications
- WinGet packages
- Microsoft Store packages

## Startup

- registry startup entries
- startup folder entries
- scheduled startup actions

## Services

- service name
- display name
- startup type
- current state
- executable path
- Microsoft vs third-party where determinable

## Scheduled tasks

- task name
- task path
- author/vendor
- trigger
- executable/action

## Security

Collect state but do not disable by default:

- Defender status
- firewall status
- BitLocker status if available
- Secure Boot
- virtualization-based security
- SmartScreen if available

---

# 15. Backup Strategy

Before applying modifications:

Create:

```text
Backups/
└── YYYY-MM-DD_HH-mm-ss/
    ├── inventory.json
    ├── registry/
    ├── services.json
    ├── scheduled-tasks.json
    ├── appx.json
    ├── features.json
    ├── startup.json
    └── execution-plan.json
```

For supported configuration changes, record previous values individually.

Example:

```json
{
  "rule": "privacy.recommendations.disable",
  "before": {
    "registryValue": 1
  },
  "after": {
    "registryValue": 0
  }
}
```

Restoration should use recorded previous state rather than assumptions whenever possible.

---

# 16. Logging

Logs should be human-readable and machine-readable.

Example console output:

```text
[INFO] Inventory complete
[INFO] 34 rules applicable

[APPLY] privacy.recommendations.disable
[OK] Verified

[SKIP] services.print-spooler.disable
Reason: printer capability enabled

[FAIL] app.somepackage.remove
Reason: access denied
```

JSON logs should also be generated.

---

# 17. Dry Run

Dry-run is essential.

Example:

```powershell
.\WinLean.ps1 -Profile Lean -WhatIf
```

Expected output:

```text
31 applicable rules

17 will be applied
8 already satisfied
4 skipped because incompatible
2 require user confirmation

Estimated reboot required: Yes
```

---

# 18. Restore

Example:

```powershell
.\WinLean.ps1 -Restore Latest
```

or:

```powershell
.\WinLean.ps1 -Restore "2026-09-27_14-30-12"
```

Restore should reverse only changes made by WinLean where possible.

---

# 19. Benchmarking

Benchmarking should occur before and after optimization.

At minimum collect:

```text
Idle CPU
Idle RAM
Process count
Startup applications
Third-party running services
Boot duration
Background disk utilization
Background network utilization
```

Advanced optional measurements:

```text
DPC latency
ISR latency
Windows boot trace
application launch times
1% low gaming benchmark
frame-time variance
energy usage
```

Do not optimize for process count alone.

---

# 20. Report

Generate:

```text
Reports/
└── YYYY-MM-DD-report.md
```

Example:

```text
WINLEAN REPORT

Machine
────────────────────────────

Windows 11 ...
CPU ...
RAM ...

Optimization Profile
Lean

Before / After
────────────────────────────

Idle RAM
Before: ...
After: ...

Startup apps
Before: 17
After: 5

Third-party services
Before: 24
After: 11

Applied Rules
────────────────────────────
...

Skipped Rules
────────────────────────────
...

Compatibility Decisions
────────────────────────────
...
```

---

# 21. Applications and Package Management

Where practical, prefer supported package mechanisms.

Potential interfaces:

- WinGet
- AppX PowerShell cmdlets
- Windows optional feature tooling
- DISM where appropriate

Do not use destructive file deletion when package management exists.

---

# 22. Service Rules

Services require particular caution.

Never create rules based solely on statements such as:

```text
Service X uses 10 MB RAM, therefore disable it.
```

A service rule must document:

- purpose
- dependencies
- affected features
- default Windows behavior
- compatibility requirements
- expected optimization benefit

Prefer changing:

```text
Automatic
→ Manual
```

over:

```text
Automatic
→ Disabled
```

where Windows can safely start the service on demand.

Do not delete services during early project phases.

---

# 23. Scheduled Tasks

Scheduled tasks should be classified into:

```text
System-critical
Security
Maintenance
Telemetry
Application updater
Vendor utility
Promotional
Optional
Unknown
```

Unknown tasks should not be disabled automatically.

---

# 24. Third-Party Optimization

Third-party software may produce greater gains than Windows itself.

Particularly inspect:

- motherboard utilities
- RGB software
- hardware control suites
- printer suites
- peripheral suites
- Adobe background services
- browser updaters
- game launchers
- cloud drives
- chat clients
- vendor telemetry
- OEM utilities

The project should eventually detect known third-party background applications and recommend alternatives.

---

# 25. Gaming Compatibility

Gaming optimization must distinguish between:

```text
Steam
Xbox / Game Pass
Epic
EA
Ubisoft
Battle.net
GOG
VR
anti-cheat systems
controller support
HDR
Bluetooth audio
```

Never disable Xbox-related components if Game Pass or Microsoft gaming services are required.

Never apply anti-cheat-breaking optimizations.

Gaming tests should prioritize:

```text
frame-time stability
1% lows
input latency
background CPU spikes
```

rather than average FPS alone.

---

# 26. Development Machine Compatibility

Development systems may require:

- WSL2
- Hyper-V
- Docker
- virtualization
- Visual Studio
- .NET SDK
- SQL Server
- SSH
- OpenSSH server/client
- Git
- Windows Terminal
- PowerShell 7
- Python
- Node.js
- package managers
- local database engines

WinLean must not assume these are unnecessary.

---

# 27. Security Policy

The standard profiles should preserve:

- Microsoft Defender
- Windows Firewall
- Windows Update
- Secure Boot
- core mitigations
- servicing stack
- certificate infrastructure
- account security
- BitLocker if enabled
- Windows Hello if used

Security modifications should require an explicit specialized profile.

---

# 28. AI Integration

AI integration should initially be optional.

Possible AI tasks:

- classify unknown applications
- explain scheduled tasks
- recommend compatible rules
- interpret benchmark reports
- detect redundant software
- create custom profiles
- explain trade-offs
- compare before/after results

AI should output structured recommendations, for example:

```json
{
  "recommendedRules": [
    "privacy.recommendations.disable",
    "apps.onedrive.remove",
    "startup.vendor-helper.disable"
  ],
  "rejectedRules": [
    {
      "id": "services.xbox.disable",
      "reason": "Game Pass is enabled"
    }
  ]
}
```

The executor should only accept known registered rule IDs.

---

# 29. Testing Strategy

Testing is essential because operating-system configuration is high impact.

## Unit tests

Test:

- rule loading
- condition evaluation
- profile parsing
- logging
- backup serialization
- rule dependency handling

## Integration tests

Use disposable environments such as:

- Windows Sandbox where applicable
- Hyper-V virtual machines
- disposable Windows VM images

Test:

```text
Baseline
Apply Safe
Verify
Undo Safe
Verify

Baseline
Apply Lean
Verify
Undo Lean
Verify
```

Never use the primary workstation as the first test environment for new medium/high-risk rules.

---

# 30. Rule Acceptance Criteria

A rule should only enter Safe or Lean if:

1. its purpose is understood
2. the Windows feature it controls is understood
3. its compatibility impact is documented
4. apply behavior is implemented
5. undo behavior is implemented
6. verification is implemented
7. it is idempotent
8. it fails safely
9. it has been tested
10. its optimization value is plausible

---

# 31. Version 0.1 Scope

Version 0.1 should intentionally be small.

Recommended capabilities:

```text
System inventory
Profile loading
Rule engine
Dry run
Backup
Logging
Registry rule support
Startup inspection
AppX inspection
WinGet inspection
Optional feature inspection
Safe privacy rules
Safe recommendation rules
Safe UI rules
Report generation
Restore support
```

Do NOT begin with aggressive service optimization.

---

# 32. Version 0.2 Scope

Add:

```text
App removal
Startup optimization
Optional feature management
Selected scheduled tasks
Compatibility questionnaire
Lean profile
Benchmarking
```

---

# 33. Version 0.3 Scope

Add:

```text
Known third-party software rules
Gaming-aware configuration
Developer-machine configuration
Service optimization
Dependency model
Improved benchmark comparison
```

---

# 34. Version 1.0 Goal

A stable WinLean release should offer:

```text
Analyse
Preview
Optimize
Verify
Benchmark
Restore
```

with:

```text
Safe
Lean
Minimal
Custom
```

profiles.

The result should be reproducible across Windows reinstalls.

---

# 35. Ideal End-State

A future Windows installation should require roughly:

```text
Install Windows
Install drivers
Clone/download WinLean
Run:

.\WinLean.ps1 -Profile MyPC

Reboot
```

The system should then automatically reproduce:

- desired privacy settings
- Windows cleanup
- desired applications
- development environment
- gaming environment
- startup policy
- optional features
- shell configuration
- service policy
- personal machine preferences

WinLean therefore becomes both:

```text
Windows optimization tool
+
personal Windows infrastructure-as-code
```

---

# 36. Guiding Engineering Rule

Whenever uncertain whether something is safe to remove:

> Keep it, document it, investigate it, and make the decision later.

A slightly less minimal system that remains predictable and reliable is preferable to a marginally lighter system that becomes fragile after Windows Update.