# Recorded observations

This folder holds the write-ups that rules reference in their `evidence` array (see the
evidence standard in [../Rules.md](../Rules.md#evidence-standard)). One file per rule:
`Docs/Evidence/<rule-id>.md`.

## Procedure

Use a disposable VM or Windows Sandbox with the Windows build you want to validate - never the
primary workstation.

1. Copy WinLean into the VM and open PowerShell (no elevation is needed for per-user
   settings).
2. Start the capture. It only reads the registry:

   ```powershell
   .\Tools\Capture-WinLeanEvidence.ps1 `
       -RuleId privacy.settings-suggested-content.disable `
       -Setting 'Settings > Privacy & security > General > Show me suggested content in the Settings app'
   ```

   Add `-Path <keys>` when the setting lives outside the default watched keys.
3. When asked, switch the toggle in the Settings app to the state the rule will set
   (for example off) and describe what you did.
4. When asked again, switch it back and describe what you did.
5. Review the saved draft:
   - the first phase must show exactly the value(s) the rule writes;
   - the second phase must show the previous value(s) coming back;
   - explain unrelated changes (timestamps, caches) in the conclusion and ignore them.
6. Complete the conclusion, add the file to the rule's `evidence` array with the build, set
   `windows.maxValidatedBuild` to (at most) that build, and run `.\WinLean.ps1 -Validate`.
7. Apply and restore the new rule in the same VM (`-Suite Destructive` or
   `-Profile <test profile> -Apply` followed by `-Restore Latest`).

`ProcessMonitor` captures (Sysinternals Process Monitor, filtered on `SystemSettings.exe` and
`RegSetValue`) are accepted as well; attach the relevant rows to the write-up in the same
format.

## Write-up contents

- setting (where the toggle is), Windows edition, version and build, method, date,
  environment (VM or Sandbox)
- watched registry keys
- the observed changes for both phases (location, before, after)
- the reviewer's conclusion
