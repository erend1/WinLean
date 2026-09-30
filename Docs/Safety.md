# Safety model

WinLean treats Windows configuration as high-impact systems work. This document lists the
guarantees and how each one is enforced.

## Absolute constraints

WinLean does not disable Windows Update, Microsoft Defender, Windows Firewall or servicing,
does not delete services, modify the kernel, remove shared components, delete files as a
substitute for package management, or apply undocumented tweaks.

Enforcement:

- **Sourced settings only.** Every rule needs a documentation reference, or - for per-user
  Settings toggles only - a recorded observation from a disposable VM (evidence standard,
  enforced by validation). The research log in [Rules.md](Rules.md) records what was
  rejected or is still waiting for evidence.
- **Protected locations.** The registry provider refuses to write to these areas, both when
  a rule is validated and again inside the write functions (defense in depth):
  Defender and Windows Security (including policies and Defender for Endpoint), Windows
  Update (policies and state), the servicing stack (Component Based Servicing), AppX
  deployment state, Windows Firewall policy, every service key
  (`HKLM\SYSTEM\*ControlSet*\Services`), Device Guard / VBS, LSA, Secure Boot, code
  integrity, Session Manager (kernel, memory management, mitigations), SCHANNEL, Image File
  Execution Options, Winlogon, UAC policy, certificate stores and cryptography, WinTrust,
  software restriction policies, BitLocker policy, attachment (Mark-of-the-Web) policies,
  the SmartScreen values and Task Manager's undocumented startup state (`StartupApproved`).
- **Declarative rules.** Rules cannot contain code. The only code that changes Windows is
  the reviewed providers in `src\Providers\`: `RegistryValue` and `StartupEntry` (both
  through the registry provider's protected write functions) and `WindowsOptionalFeature`
  (through the DISM PowerShell module, never through servicing registry keys).
- **Optional features.** Defender, virtualization-based security, device lockdown and Sysmon
  features are never changed; SMB 1.0, Windows PowerShell 2.0 and Simple TCP/IP services are
  never enabled by a rule. Feature rules need risk Medium or higher, a restart declaration,
  and - for Hyper-V, WSL, Virtual Machine Platform, Windows Sandbox and other features that
  compatibility requirements depend on - an explicit "not needed" decision by the user. A
  change that makes DISM change other features too is reverted and fails
  (`CollateralChange`). WinLean never downloads feature payloads.
- **Startup entries.** Only the Run keys are managed (not RunOnce, not the Startup folders,
  never `StartupApproved`). Adding an entry (`ensure: Present`) makes Windows run a
  program at every sign-in; its command is declared in the reviewed rule, shown in the plan,
  and such rules need risk Medium or higher. The Windows Security entries are protected.
- **Known ids only.** Profiles can only reference rules in the catalog; an unknown id stops
  the run.

## Before anything changes

- `-Profile` without `-Apply` is a dry run. `-Apply -WhatIf` is also a dry run.
- `-Apply` shows the complete plan and asks for confirmation (ConfirmImpact High).
- Undeclared compatibility requirements are treated as required: conditional rules are
  skipped until you decide.
- Windows builds newer than a rule's `maxValidatedBuild` require `-AllowUntestedBuild`;
  unsupported builds, editions and non-client installations are refused per rule.
- The plan blocks rules whose current value cannot be captured losslessly (for example
  `REG_NONE`), whose value is unreadable, that conflict, or whose dependencies are not met.

## Privileges

- WinLean never elevates itself. Rules are blocked, with an explanation, when the process
  lacks write access. Access is determined by opening the target key (or its nearest
  existing parent) for writing - nothing is created - so unusual ACLs are handled correctly.
- Analysis, dry runs, benchmarks and reports work without Administrator rights; sections
  that need elevation are reported as unavailable.
- **Per-user target check.** When WinLean runs as a different account than the one signed in
  to the desktop (for example "Run as administrator" with another admin account, or SYSTEM),
  per-user rules are blocked because they would change the wrong profile.
- Backups record the user's SID; per-user values recorded by one account cannot be restored
  from another account.

## While changing

- **Backup first.** The before-state of every resource is written to `changes.json` before
  the first change. If the backup cannot be written, nothing is changed.
- **Fresh state.** State is re-read immediately before applying; already satisfied rules are
  not touched (idempotency).
- **Verification.** Every changed value is read back. A rule is only successful when every
  resource has the desired value.
- **Rollback.** A rule that fails (write error, verification failure) is rolled back to its
  captured state; the rollback is verified too.
- **Isolation.** One failing rule does not stop the others, except rules that depend on it.
- **Record keeping.** Results are written after every rule; if that becomes impossible, no
  further changes are made.
- **Exclusive lock.** Only one apply or restore runs at a time (`Backups\.winlean.lock`).

## Restore

- Uses the recorded previous values, including "value did not exist" (the value is deleted)
  and "key did not exist" (keys WinLean created are removed again, only while empty).
- Only values that still hold WinLean's value are restored. Values changed afterwards are
  left alone unless `-Force` is given, so a restore never silently overwrites a newer change.
- Every restored value is verified; the backup records Restored, RestoredWithSkips or
  Incomplete, and incomplete restores can be repeated.

## Testing policy

- Unit tests never touch the real registry (an in-memory fake replaces the provider's I/O).
- Integration tests use real APIs only inside Pester's TestRegistry key and TestDrive.
- The destructive suite (applies the real Safe profile) refuses to run unless
  `WINLEAN_ALLOW_DESTRUCTIVE_TESTS=YES`; run it only in a disposable VM or Windows Sandbox.
- New Medium/High risk rules must never be tried first on a primary workstation.

## Known limitations

- Policy-based rules can be overridden by domain or MDM policy; the plan warns on
  domain-joined devices, and verification only reflects the moment of the check.
- Some settings take full effect only after signing out or restarting File Explorer;
  WinLean does not restart Explorer.
- WinLean does not create System Restore points. Its backups contain exactly the values it
  changed - not a full system backup.
- On PowerShell 7.0-7.4, JSON parsing converts ISO-8601-looking strings to dates. Restoring
  such a string value is refused with an explanation (use PowerShell 7.5+ or 5.1).
