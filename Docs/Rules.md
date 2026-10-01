# Rules

A rule is a reviewed JSON document in `Rules\<Category>\<rule-id>.json`. Rules contain no
code. The validator in `src\WinLean.Validation.psm1` is authoritative; `Schemas\rule.schema.json`
gives editors completion and inline errors (add `"$schema": "../../Schemas/rule.schema.json"`).

## Schema

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | `1` |
| `id` | yes | lowercase dotted id starting with the category prefix, e.g. `privacy.advertising-id.disable`; the file is named `<id>.json` |
| `name`, `description`, `rationale` | yes | what it is, exactly what it changes (including the matching Settings or Group Policy option), and why it is worth doing |
| `category` | yes | Applications (`apps`), Startup, Services, ScheduledTasks (`tasks`), Privacy, Recommendations, Features, Gaming, Explorer, Search, Networking, Power, Security, Development, ThirdParty (`thirdparty`) |
| `risk` | yes | `Low` (normally safe), `Medium` (feature-dependent; needs a `requirement.*` condition), `High` (servicing, security, broad compatibility; needs a `requirement.*` condition; excluded from standard profiles) |
| `reversible` | yes | `true` for every declarative resource |
| `requiresReboot` | yes | `true` exactly when `takesEffect` is `Reboot` |
| `takesEffect` | yes | `Immediately`, `ExplorerRestart`, `SignOut` or `Reboot`: the latest point at which the change is fully effective |
| `windows` | yes | `minBuild` (>= 22000), `maxValidatedBuild`, optional `maxBuild` and `editions` (EditionID values) |
| `conditions` | yes | all must be true; see below (`[]` for none) |
| `dependencies` | yes | rules that must be applied or already satisfied first |
| `conflicts` | yes | rules that must not be in effect together with this rule |
| `effects`, `sideEffects` | yes | at least one entry each |
| `notes` | no | reviewer notes: Windows default, policy definition, caveats |
| `benefit` | yes | what the rule is good for: `type`, `value`, `measurement` (see [Benefit](#benefit)) |
| `references` | yes | `https://` sources that document the exact setting (may be `[]` only when `evidence` is present) |
| `evidence` | no | recorded observations of what a Settings toggle writes (see [Evidence standard](#evidence-standard)) |
| `validation` | yes | how, on which build and when the rule was validated (see [Validation records](#validation-records)) |
| `resources` | yes | declarative resources: `RegistryValue`, `StartupEntry`, `WindowsOptionalFeature` |
| `tags` | no | lowercase words |

### Benefit

```json
"benefit": { "type": "Privacy", "value": "Low", "measurement": "NotMeasured" }
```

Benefits are qualitative. WinLean has no numeric scores, because a number would suggest a
precision nobody has measured.

| Field | Values |
|---|---|
| `type` | `Performance` (measurable speed or responsiveness), `BackgroundActivity` (fewer processes, services, tasks or network activity), `Privacy` (less data collected or shared), `Security` (reduced exposure without disabling protections), `Storage` (disk space), `Usability` (a more convenient or transparent interface), `Distraction` (fewer tips, suggestions and promotions) |
| `value` | `Cosmetic`, `Low`, `Moderate`, `High`: the expected size of the benefit |
| `measurement` | `Measured`: a recorded measurement shows the effect (`measurementFile` in `Docs/Measurements/` is then required). `NotMeasured`: the benefit follows from the documented behaviour of the setting |

Validation enforces that claims match their support:

- `Performance` requires `Measured`: WinLean makes no performance claims without a
  measurement. An unmeasured change that probably reduces load is `BackgroundActivity`.
- `BackgroundActivity` with value `Moderate` or `High` requires `Measured`.
- Privacy, security, distraction and usability benefits are not relabelled as performance.

The plan, `-ListRules` and the Markdown report show the benefit of each rule and summarize
the rules to apply (or applied) per benefit type.

### Validation records

```json
"validation": [
  { "method": "VmApplyRestore", "build": 26200, "date": "2026-10-02", "file": "Docs/Validation/2026-10-02-26200.md" },
  { "method": "SourceReview", "build": 26200, "date": "2026-09-28" }
]
```

Together with `references` and `evidence` (where a setting comes from), validation records
answer how the rule was validated, on which Windows build and when:

| Method | Meaning |
|---|---|
| `SourceReview` | the setting was checked against its references (or evidence) on that build: policy definitions, documented values, the value read on a real system |
| `VmApplyRestore` | the rule was applied, verified and restored with WinLean in a disposable VM following [VmValidation.md](VmValidation.md); `file` names the validation record in `Docs/Validation/` |

- `windows.maxValidatedBuild` must equal the newest build in `validation`, so the two cannot
  drift apart; every record must lie within `minBuild`..`maxBuild`.
- `date` is `yyyy-MM-dd` and may not lie in the future. The newest date is shown as "last
  validated".
- The plan notes Medium and High risk rules that have no `VmApplyRestore` record yet, and the
  repository tests refuse such rules in shipped profiles.

### Conditions

```json
{ "fact": "requirement.printer", "operator": "Equals", "value": false, "reason": "Printing must remain available." }
```

- Facts: `requirement.<key>` (declared in the compatibility configuration),
  `capability.<key>` (detected), `system.<key>` (`build`, `ubr`, `editionId`,
  `displayVersion`, `installationType`, `architecture`, `partOfDomain`).
- Operators: `Equals`, `NotEquals`, `In`, `NotIn` (array value), `GreaterOrEqual`,
  `LessOrEqual` (numbers). Requirement values are booleans.
- A fact that is not known (for example an undeclared requirement) never satisfies a
  condition: the rule is Skipped. Undeclared requirements are therefore treated as required.

### RegistryValue resources

```json
{ "type": "RegistryValue", "path": "HKCU:\\Software\\...", "name": "Value", "valueType": "DWord", "value": 0 }
{ "type": "RegistryValue", "path": "HKLM:\\SOFTWARE\\...", "name": "Value", "ensure": "Absent" }
```

- `path`: `HKCU:\` or `HKLM:\` only. `valueType`: `String`, `ExpandString`, `MultiString`,
  `DWord` (0..4294967295), `QWord` (number or decimal string), `Binary` (hex string).
- Values below `\Policies\` are classified as Group Policy values (mechanism `Policy`):
  Settings shows them as managed, and organizational policy may override them.
- Protected locations (Defender, Windows Update, Firewall, services, LSA, code integrity,
  Secure Boot, mitigations, certificates, SmartScreen, UAC, ...) are rejected by validation
  and again at write time. See [Safety.md](Safety.md).
- Two rules that set the same value differently must declare the conflict; otherwise
  validation warns and the plan blocks both.
- The Run and RunOnce keys cannot be targeted by `RegistryValue` resources: startup
  entries use `StartupEntry`, and RunOnce entries are not managed at all.

### StartupEntry resources

```json
{ "type": "StartupEntry", "location": "CurrentUserRun", "name": "Example", "ensure": "Absent" }
{ "type": "StartupEntry", "location": "MachineRun", "name": "Example", "ensure": "Present",
  "command": "\"C:\\Program Files\\Example\\example.exe\" /background", "valueType": "String" }
```

| Location | Registry key | Scope |
|---|---|---|
| `CurrentUserRun` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | CurrentUser |
| `MachineRun` | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` | Machine (Administrator) |
| `MachineRun32` | `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run` | Machine (Administrator; 32-bit programs) |

- A startup entry is one registry value. The provider reuses the registry provider for
  capture, writes and restore, so the backup keeps the exact command (unexpanded
  `%variables%`) and value kind, and the identity equals the `RegistryValue` identity of
  the same value (conflicts across the two types are detected).
- `ensure: Absent` removes the entry; `ensure: Present` adds or replaces it with `command`
  (`valueType` `String`, the default, or `ExpandString`). Adding an entry makes Windows run
  a program at every sign-in, so such rules need risk Medium or higher.
- Task Manager's enabled/disabled choice (`Explorer\StartupApproved`) is undocumented binary
  data. WinLean never modifies it (it is a protected registry location); because it stays
  untouched, restoring a removed entry also brings back its previous Task Manager state.
  The inventory reads it heuristically, for information only.
- Not supported: `RunOnce` keys (Windows deletes a RunOnce entry when it runs it; such
  entries represent pending one-time work, often an installer finishing) and the Startup
  folders (removing a shortcut needs a lossless file backup - content, attributes and
  security descriptor - planned for a later milestone).
- Protected entries: `SecurityHealth` and `WindowsDefender` in `MachineRun` (Windows
  Security).
- No shipped rule uses `StartupEntry` yet: removing a vendor's startup program is a
  compatibility decision that needs a requirement condition, and every such rule must be
  validated in a VM first.

### WindowsOptionalFeature resources

```json
{ "type": "WindowsOptionalFeature", "name": "TelnetClient", "state": "Disabled" }
```

- `name` is the exact feature name shown by `Get-WindowsOptionalFeature -Online`; `state` is
  `Enabled` or `Disabled`. Removing feature payloads (`-Remove`) is not supported by rules.
- Changes go through the DISM PowerShell module only (`Enable-/Disable-WindowsOptionalFeature
  -Online -NoRestart`), never through servicing registry keys. Enabling uses `-LimitAccess`,
  so WinLean never downloads a payload from Windows Update; `-All` is never used, so parent
  features must be listed explicitly (before their children when enabling, after them when
  disabling).
- State is read with DISM in elevated sessions and with `Win32_OptionalFeature` otherwise
  (standard users can plan; applying needs Administrator rights, and the executor re-reads
  the state with DISM first).
- A feature that is not part of the Windows image is "Disabled" (nothing to do) and makes a
  rule that needs it enabled **Unsupported**. A pending change (`EnablePending`,
  `DisablePending`) counts as done after WinLean's change, but a feature that is already
  waiting for a restart is **Blocked** until Windows has been restarted.
- **Collateral changes.** WinLean reads every feature before and after each change. If DISM
  changed anything besides the target (for example the children of a disabled parent),
  WinLean reverts the target and every collateral change and fails the rule with
  `CollateralChange`: the backup records only the declared features, so it could not restore
  the others.
- **Restart.** DISM's `RestartNeeded` (or a pending state) is reported in the rule result and
  in restore results. Rules must declare `takesEffect: Reboot`, so the plan announces a
  possible restart.
- **Rule constraints.** Risk `Medium` or `High`. Disabling a feature that a compatibility
  requirement depends on needs the matching condition `requirement.<key> Equals false`, so a
  feature is never removed merely because it exists:

  | Feature | Required conditions (all `false`) |
  |---|---|
  | `Microsoft-Hyper-V*` | `hyperV` |
  | `HypervisorPlatform` | `virtualization` |
  | `VirtualMachinePlatform`, `Microsoft-Windows-Subsystem-Linux` | `wsl2`, `docker` |
  | `Containers-DisposableClientVM` (Windows Sandbox) | `windowsSandbox` |
  | `Containers` | `docker` |
  | `Printing-*` | `printer` |
  | `SMB1Protocol*`, `SmbDirect` | `smb` |
  | `SearchEngine-Client-Package` | `windowsSearch` |
  | `Microsoft-RemoteDesktopConnection` | `remoteDesktop` |
  | `DirectPlay`, `LegacyComponents` | `gamingMachine` |

- **Protected features**, refused by validation and again at write time: never changed -
  `Windows-Defender-*`, `Containers-Server-For-Application-Guard`, `IsolatedUserMode`,
  `HostGuardian`, `Sysmon*`, device lockdown (`Client-DeviceLockdown`, `Client-Embedded*`,
  `Client-KeyboardFilter`, `Client-UnifiedWriteFilter`); never enabled by a rule -
  `SMB1Protocol`, `SMB1Protocol-Client`, `SMB1Protocol-Server`,
  `MicrosoftWindowsPowerShellV2*`, `SimpleTCP`. Restoring a recorded previous state of the
  latter group is allowed, because it undoes WinLean's own change.
- No shipped rule changes an optional feature. Hyper-V, WSL, Virtual Machine Platform and
  Windows Sandbox are never disabled automatically.

### Validation issue codes

RuleSchema, UnknownProperty, SchemaVersion, RuleId, RuleIdPrefix, Category, RequiredField,
Risk, TakesEffect, Windows, Conditions, References, Evidence, Benefit, Validation,
Documentation, Tags, Resources, Reversible, Location, RuleParse; catalog: DuplicateRuleId,
UnknownDependency, UnknownConflict, ContradictoryReferences, DependencyCycle,
UndeclaredConflict (warning).

## Evidence standard

Every rule needs a source for the exact setting it changes. Two kinds of source are
accepted:

1. **Documentation** (`references`): Microsoft documentation, ADMX/ADML policy definitions
   (`C:\Windows\PolicyDefinitions`), the Policy CSP reference, or Microsoft source code.
2. **Recorded observation** (`evidence`): what the Settings app writes when the user flips
   the corresponding toggle, captured in a disposable VM or Windows Sandbox:

   ```json
   "evidence": [
     {
       "method": "RegistryDiff",
       "build": 26200,
       "file": "Docs/Evidence/<rule-id>.md",
       "summary": "Turning the toggle off wrote X = 0 (DWord); turning it on again wrote X = 1."
     }
   ]
   ```

   A valid observation shows the value(s) the rule writes when the toggle is switched to the
   rule's state, and the previous value(s) coming back when it is switched back. Methods:
   `RegistryDiff` (`Tools\Capture-WinLeanEvidence.ps1`: read-only snapshots of a baseline
   without any action, then after every switch and switch back) or `ProcessMonitor`
   (Sysinternals Process Monitor trace of `SystemSettings.exe`). Only *attributable*
   changes count: changed on every switch, reversed exactly on every switch back, identical
   in every cycle and absent from the baseline - incidental registry churn is never proof.
   The write-up in `Docs\Evidence\` records the setting, the Windows edition, build and UBR,
   the environment, every phase, the attribution and the reviewer's conclusion
   ([procedure](Evidence/README.md)).

Rules whose only source is an observation are held to stricter limits, enforced by
validation:

- they may only change **per-user preferences** (`HKCU`, outside `\Policies\`) - policy
  values must be backed by their ADMX definition, and machine-wide values by documentation;
- `windows.maxValidatedBuild` may not be newer than the newest observed build, so every new
  Windows build needs a new capture before the rule is validated for it.

Observations never come from the primary workstation, and never from forum posts or other
scripts.

## Catalog

All rules are Low risk and reversible. `maxValidatedBuild` is 26200 (Windows 11 25H2): on
that build the policy definitions (ADMX/ADML in `C:\Windows\PolicyDefinitions`) or registry
locations were checked against Microsoft's documentation, and the per-user values were read
(never written) on a real system - recorded as a `SourceReview` validation dated 2026-09-28.
No rule has a `VmApplyRestore` record yet: applying and restoring the real settings is
covered by the destructive test suite, which must be run in a VM (see
[VmValidation.md](VmValidation.md)) before such a record is added. Milestone 0.2A added no
rules.

| Rule | Setting | Scope | Benefit | Source |
|---|---|---|---|---|
| `privacy.advertising-id.disable` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy = 1` (policy "Turn off the advertising ID") | Machine, needs Administrator | Privacy, Moderate | UserProfiles.admx; Policy CSP Privacy/DisableAdvertisingId; privacy guidance 18.1 |
| `privacy.tailored-experiences.disable` | `HKCU\Software\Policies\Microsoft\Windows\CloudContent\DisableTailoredExperiencesWithDiagnosticData = 1` (user policy "Do not use diagnostic data for tailored experiences") | CurrentUser; usually needs an elevated session of the same user (HKCU\Software\Policies ACL) | Privacy, Low | CloudContent.admx; Policy CSP Experience/AllowTailoredExperiencesWithDiagnosticData; privacy guidance 18.16 |
| `privacy.language-list-web-access.disable` | `HKCU\Control Panel\International\User Profile\HttpAcceptLanguageOptOut = 1` | CurrentUser | Privacy, Low | privacy guidance 18.1 |
| `privacy.app-launch-tracking.disable` (Lean) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\Start_TrackProgs = 0` | CurrentUser | Privacy, Low | privacy guidance 18.1 |
| `recommendations.settings-online-tips.disable` | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\AllowOnlineTips = 0` (policy "Allow Online Tips", unchecked) | Machine, needs Administrator | Distraction, Low | ControlPanel.admx; Policy CSP Settings/AllowOnlineTips |
| `recommendations.windows-tips.disable` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableSoftLanding = 1` | Machine; Enterprise/Education editions only | Distraction, Low | CloudContent.admx ("only applies to Enterprise and Education SKUs"); Policy CSP Experience/AllowWindowsTips |
| `recommendations.consumer-experiences.disable` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures = 1` | Machine; Enterprise/Education editions only | Distraction, Moderate | CloudContent.admx; Policy CSP Experience/AllowWindowsConsumerFeatures |
| `explorer.file-extensions.show` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\HideFileExt = 0` | CurrentUser | Security, Low (disguised file names such as `invoice.pdf.exe` become visible) | Microsoft winget-dsc, Microsoft.Windows.Developer WindowsExplorer resource |
| `explorer.hidden-files.show` (optional) | `...\Explorer\Advanced\Hidden = 1` (ShowSuperHidden untouched) | CurrentUser | Usability, Cosmetic | Microsoft winget-dsc |

None of the benefits is measured; none is a performance claim.

"Privacy guidance" is Microsoft Learn's *Manage connections from Windows operating system
components to Microsoft services*. ADMX files are in `C:\Windows\PolicyDefinitions`; their
explanation texts (ADML) were read for the exact semantics and edition restrictions.

## Research log

Candidates that were **not** implemented yet, because their exact semantics are not documented
by Microsoft, or that are unsuitable. Per-user Settings toggles can now qualify through a
recorded observation (see [Evidence standard](#evidence-standard)); they are added once a
capture in a disposable VM confirms the values.

| Candidate | Status |
|---|---|
| `ContentDeliveryManager\SubscribedContent-338393Enabled`, `-353694Enabled`, `-353696Enabled` ("Show me suggested content in the Settings app") | eligible under the evidence standard (per-user toggle); awaiting a VM capture |
| `ContentDeliveryManager\SubscribedContent-338389Enabled` ("Get tips and suggestions when using Windows") | eligible under the evidence standard; awaiting a VM capture (the documented policy DisableSoftLanding is edition-limited) |
| `Explorer\Advanced\Start_IrisRecommendations` ("Show recommendations for tips, shortcuts, new apps, and more" in Start) | eligible under the evidence standard; awaiting a VM capture |
| `Explorer\Advanced\TaskbarDa` (widgets button) | protected by the User Choice Protection Driver on current builds; also a preference rather than an optimization |
| `HKCU\...\AdvertisingInfo\Enabled` (per-user advertising ID toggle) | eligible under the evidence standard as a non-policy alternative for standard users; the documented policy is used today |
| `HKLM\...\CurrentVersion\AdvertisingInfo\Enabled` | mentioned in the privacy guidance without semantics; not needed with the policy |
| `...\Privacy\TailoredExperiencesWithDiagnosticDataEnabled` (per-user toggle) | not documented; the documented user policy is used instead |
| Service start types, scheduled tasks, AppX removal, optional features | planned for later milestones with dedicated providers; not raw registry edits |

## Acceptance criteria (for Safe and Lean)

Safe stays very conservative: only Low risk rules without compatibility conditions, whose
effect is a documented setting that every user of the profile can live with. Safe is not
expanded to make it look more effective.

A rule enters Lean only if all of the following hold:

1. its benefit is understood and recorded in `benefit` (no unmeasured performance claims);
2. its compatibility impact is explicit: Medium and High risk rules carry a
   `requirement.*` condition, so they apply only after the user declared the feature
   unnecessary;
3. its source satisfies the evidence standard above;
4. its provider is implemented and tested (unit and integration tests);
5. it has been applied, verified and restored successfully in a disposable VM, recorded as a
   `VmApplyRestore` validation (enforced by the repository tests for Medium and High risk
   rules in shipped profiles).

Minimal may remain incomplete. See the rule development checklist in the README.
