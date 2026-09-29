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
| `risk` | yes | `Low` (normally safe), `Medium` (feature-dependent; needs conditions), `High` (servicing, security, broad compatibility; excluded from standard profiles) |
| `reversible` | yes | `true` for every declarative resource |
| `requiresReboot` | yes | `true` exactly when `takesEffect` is `Reboot` |
| `takesEffect` | yes | `Immediately`, `ExplorerRestart`, `SignOut` or `Reboot`: the latest point at which the change is fully effective |
| `windows` | yes | `minBuild` (>= 22000), `maxValidatedBuild`, optional `maxBuild` and `editions` (EditionID values) |
| `conditions` | yes | all must be true; see below (`[]` for none) |
| `dependencies` | yes | rules that must be applied or already satisfied first |
| `conflicts` | yes | rules that must not be in effect together with this rule |
| `effects`, `sideEffects` | yes | at least one entry each |
| `notes` | no | reviewer notes: Windows default, policy definition, caveats |
| `references` | yes | `https://` sources that document the exact setting (may be `[]` only when `evidence` is present) |
| `evidence` | no | recorded observations of what a Settings toggle writes (see [Evidence standard](#evidence-standard)) |
| `resources` | yes | declarative resources (0.1: `RegistryValue`) |
| `tags` | no | lowercase words |

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

### Validation issue codes

RuleSchema, UnknownProperty, SchemaVersion, RuleId, RuleIdPrefix, Category, RequiredField,
Risk, TakesEffect, Windows, Conditions, References, Evidence, Documentation, Tags, Resources,
Reversible, Location, RuleParse; catalog: DuplicateRuleId, UnknownDependency, UnknownConflict,
ContradictoryReferences, DependencyCycle, UndeclaredConflict (warning).

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
   `RegistryDiff` (`Tools\Capture-WinLeanEvidence.ps1`, read-only snapshots before and
   after each change) or `ProcessMonitor` (Sysinternals Process Monitor trace of
   `SystemSettings.exe`). The write-up in `Docs\Evidence\` records the setting, the Windows
   build, the procedure, the observed changes and the reviewer's conclusion
   ([template and procedure](Evidence/README.md)).

Rules whose only source is an observation are held to stricter limits, enforced by
validation:

- they may only change **per-user preferences** (`HKCU`, outside `\Policies\`) - policy
  values must be backed by their ADMX definition, and machine-wide values by documentation;
- `windows.maxValidatedBuild` may not be newer than the newest observed build, so every new
  Windows build needs a new capture before the rule is validated for it.

Observations never come from the primary workstation, and never from forum posts or other
scripts.

## Catalog (milestone 0.1)

All rules are Low risk and reversible. `maxValidatedBuild` is 26200 (Windows 11 25H2): on
that build the policy definitions (ADMX/ADML in `C:\Windows\PolicyDefinitions`) or registry
locations were checked against Microsoft's documentation, and the per-user values were read
(never written) on a real system. Applying and restoring the real settings is covered by the
destructive test suite, which must be run in a VM before a rule is validated for a new build.

| Rule | Setting | Scope | Source |
|---|---|---|---|
| `privacy.advertising-id.disable` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy = 1` (policy "Turn off the advertising ID") | Machine, needs Administrator | UserProfiles.admx; Policy CSP Privacy/DisableAdvertisingId; privacy guidance 18.1 |
| `privacy.tailored-experiences.disable` | `HKCU\Software\Policies\Microsoft\Windows\CloudContent\DisableTailoredExperiencesWithDiagnosticData = 1` (user policy "Do not use diagnostic data for tailored experiences") | CurrentUser; usually needs an elevated session of the same user (HKCU\Software\Policies ACL) | CloudContent.admx; Policy CSP Experience/AllowTailoredExperiencesWithDiagnosticData; privacy guidance 18.16 |
| `privacy.language-list-web-access.disable` | `HKCU\Control Panel\International\User Profile\HttpAcceptLanguageOptOut = 1` | CurrentUser | privacy guidance 18.1 |
| `privacy.app-launch-tracking.disable` (Lean) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\Start_TrackProgs = 0` | CurrentUser | privacy guidance 18.1 |
| `recommendations.settings-online-tips.disable` | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\AllowOnlineTips = 0` (policy "Allow Online Tips", unchecked) | Machine, needs Administrator | ControlPanel.admx; Policy CSP Settings/AllowOnlineTips |
| `recommendations.windows-tips.disable` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableSoftLanding = 1` | Machine; Enterprise/Education editions only | CloudContent.admx ("only applies to Enterprise and Education SKUs"); Policy CSP Experience/AllowWindowsTips |
| `recommendations.consumer-experiences.disable` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures = 1` | Machine; Enterprise/Education editions only | CloudContent.admx; Policy CSP Experience/AllowWindowsConsumerFeatures |
| `explorer.file-extensions.show` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\HideFileExt = 0` | CurrentUser | Microsoft winget-dsc, Microsoft.Windows.Developer WindowsExplorer resource |
| `explorer.hidden-files.show` (optional) | `...\Explorer\Advanced\Hidden = 1` (ShowSuperHidden untouched) | CurrentUser | Microsoft winget-dsc |

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

A rule enters Safe or Lean only if its purpose and the controlled feature are understood,
its compatibility impact is documented, apply/undo/verify are implemented (declarative
resources provide all three), it is idempotent, fails safely, has been tested (unit,
integration and a VM apply/restore), and its value is plausible. See the rule development
checklist in the README.
