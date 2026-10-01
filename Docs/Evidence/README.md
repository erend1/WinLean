# Recorded observations

This folder holds the write-ups that rules reference in their `evidence` array (see the
evidence standard in [../Rules.md](../Rules.md#evidence-standard)). One file per rule:
`Docs/Evidence/<rule-id>.md`.

Observations are accepted only for ordinary per-user Settings preferences (HKCU, outside
`\Policies\`), never for services, security, servicing, update infrastructure, kernel
behaviour, drivers, networking internals or machine-wide state, and never from the primary
workstation, forum posts or third-party scripts.

## Procedure

Use a disposable VM or Windows Sandbox with the Windows build you want to validate.

1. Start from a clean baseline: a freshly installed or freshly reset VM (or a new Windows
   Sandbox session) with the build to validate. Copy WinLean into it and open PowerShell
   (no elevation is needed for per-user settings).
2. Start the capture. It only reads the registry and never changes a setting:

   ```powershell
   .\Tools\Capture-WinLeanEvidence.ps1 `
       -RuleId privacy.settings-suggested-content.disable `
       -Setting 'Settings > Privacy & security > General > Show me suggested content in the Settings app' `
       -TargetState Off -OriginalState On -Cycles 2
   ```

   Add `-Path <keys>` when the setting lives outside the default watched keys.
3. The tool records the Windows edition, version, build and UBR and checks that it runs in
   a VM or Windows Sandbox (Hyper-V, VMware, VirtualBox, QEMU/KVM, Parallels, Xen, Sandbox).
   On anything else it stops. `-ConfirmDisposableEnvironment` overrides this only for a
   disposable VM the detection does not recognize; the write-up records that the operator
   confirmed it.
4. **Baseline.** Do not touch the system while the tool takes two snapshots
   `-BaselineSeconds` apart (default 15). Values that change in this window are background
   churn (timestamps, counters, caches) and can never count as evidence.
5. **Switch.** When asked, switch the toggle in the Settings app to the state the rule will
   set (`-TargetState`) and press Enter once Settings shows the new state.
6. **Switch back.** When asked, switch it back (`-OriginalState`) and press Enter.
7. Steps 5 and 6 repeat for every cycle (`-Cycles`, 1-5). Two cycles are recommended: they
   expose values that change differently each time.
8. Review the saved draft. Its attribution lists:
   - **Attributable** changes: changed on every switch, returned exactly to the previous
     state on every switch back, identical in every cycle, and absent from the baseline;
   - everything else, with the reason it is not evidence (background churn, not reversed,
     inconsistent between cycles, changed without a matching switch).
   Incidental registry churn is never proof, even when it happens to coincide with a switch.
9. Complete the reviewer checklist in the draft. A rule may use only attributable per-user
   values; the draft lists them as JSON resources for convenience.
10. Add the file to the rule's `evidence` array with the build, set
    `windows.maxValidatedBuild` to (at most) that build, add a validation record, and run
    `.\WinLean.ps1 -Validate`.
11. Apply and restore the new rule in the same VM following [../VmValidation.md](../VmValidation.md).

`ProcessMonitor` captures (Sysinternals Process Monitor, filtered on `SystemSettings.exe`
and `RegSetValue`) are accepted as well; they must cover the same steps (baseline, switch,
switch back) and the write-up must present them in the same format.

## Write-up contents

- status (Candidate or Insufficient) and the reviewer checklist
- setting (Settings page and toggle), the rule's target state and the state switched back to
- Windows product, edition, version, build and UBR, architecture
- environment (detected VM or Windows Sandbox, or operator-confirmed), method, date,
  baseline duration and number of cycles
- watched registry keys (and keys that could not be read)
- the changes of the baseline and of every switch (location, before, after)
- the attribution: attributable changes (before, rule state, final state) and the
  non-attributable changes with their reason
- draft `RegistryValue` resources for the attributable per-user values
