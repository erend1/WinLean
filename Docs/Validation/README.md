# Validation records

This folder holds the records that rules reference from `validation` entries with the method
`VmApplyRestore`:

```json
{ "method": "VmApplyRestore", "build": 26200, "date": "2026-10-10", "file": "Docs/Validation/2026-10-10-26200-safe.md" }
```

A record documents one run of the procedure in [../VmValidation.md](../VmValidation.md): a
set of rules was applied, verified and restored with WinLean in a disposable VM of a given
Windows build. One record may cover several rules (for example a whole profile).

- File name: `<yyyy-MM-dd>-<build>-<topic>.md`, for example `2026-10-10-26200-safe.md`.
- Content: the filled-in checklist from [../VmValidation.md](../VmValidation.md#checklist-validation-record):
  environment (hypervisor, Windows product, edition, version, build and UBR), WinLean commit,
  profile and rules, the result of every step, the functionality checks and all deviations.
- A record is written only for a validation that was actually performed and passed. Rules
  that failed are fixed or removed, not recorded.
- `SourceReview` validations do not need a record here: their evidence is the rule's
  `references` (or `evidence`).

Validation checks that a referenced record exists (repository tests) and that
`windows.maxValidatedBuild` equals the newest build in a rule's `validation` list.

No records exist yet.
