# Compatibility context

WinLean keeps two different things apart:

| | Requirement | Capability |
|---|---|---|
| Question | What must keep working? | What does this machine have? |
| Source | your decision, `Config\Compatibility.json` | detected from the inventory |
| Example | `"bluetooth": true` - Bluetooth must be preserved | a Bluetooth adapter exists |
| Fact name | `requirement.bluetooth` | `capability.bluetoothAdapterPresent` |

A detected capability never becomes a requirement automatically. `-Analyze` lists what was
detected and suggests declaring requirements for detected features that are not declared.

## Configuring requirements

```powershell
.\WinLean.ps1 -Configure                  # questionnaire with detection hints
.\WinLean.ps1 -Configure -SkipDetection   # without the (read-only) inventory
.\WinLean.ps1 -Configure -WhatIf          # answer, review the summary, write nothing
```

`-Configure` creates or updates `Config\Compatibility.json` (or the file given with
`-CompatibilityPath`):

- Every known requirement is asked, grouped by topic (devices, gaming, Microsoft apps,
  development and virtualization, networking, security, privacy, vendor utilities), with
  its description and current answer.
- Answers: `Y` required, `N` not needed, `U` leave undeclared, `Enter` keep the current
  answer, `?` help, `Q` stop asking (the remaining answers stay as they are).
- **Detection hints** ("Detected on this PC: a Bluetooth adapter") come from a read-only
  inventory. They are facts, not decisions: no answer changes unless you give it, so a
  detected feature never silently becomes a requirement, and an undetected one never
  silently becomes "not needed".
- Existing answers are retained. Entries with keys this WinLean version does not know are
  reported and kept unchanged. A file with errors (invalid JSON, non-boolean values,
  another schema version) is refused - fix or remove it first - so nothing is lost.
- At the end WinLean lists the changes and asks for confirmation. The new content is written
  to a temporary file, read back and validated, and only then replaces the configuration in
  one step; the replaced version is kept as `Compatibility.previous.json`.

The file can also be edited by hand:

```powershell
Copy-Item Config\Compatibility.example.json Config\Compatibility.json
notepad Config\Compatibility.json
.\WinLean.ps1 -Validate
```

`Config\Compatibility.json` and `Compatibility.previous.json` are ignored by Git (they
describe one machine). Use `-CompatibilityPath <file>` to point to another file.

- `true` = required: rules that would reduce the feature are skipped.
- `false` = not needed: such rules may apply (subject to profile and risk).
- missing = undeclared = **treated as required**.
- Unknown keys are reported as warnings (probably typos) and ignored by the rules.

The canonical key list, with descriptions, is `Schemas\compatibility.schema.json`:
printer, networkPrinting, scanner, bluetooth, bluetoothAudio, xbox, xboxControllers,
gamePass, microsoftStore, onedrive, hyperV, wsl2, windowsSandbox, virtualization, docker,
remoteDesktop, windowsHello, bitLocker, touch, pen, windowsSearch, phoneLink, widgets, teams,
copilot, locationServices, telemetryDiagnostics, visualStudio, sqlServer, gpuVendorUtilities,
rgbSoftware, motherboardUtilities, fileSharing, smb, developerMachine, gamingMachine.

None of the shipped rules has compatibility conditions yet: they are safe regardless of
the answers. Conditions are mandatory for Medium and High risk rules (validation enforces at
least one `requirement.*` condition), and rules that disable an optional feature such as
Hyper-V, WSL, Virtual Machine Platform or Windows Sandbox must require the matching
requirement to be `false` - see [Rules.md](Rules.md).

## Detected capabilities

| Capability | Detection | Related requirement |
|---|---|---|
| bluetoothAdapterPresent | Bluetooth-class PnP devices whose device id does not start with `BTH` (radios rather than paired devices) - heuristic | bluetooth |
| physicalPrinterInstalled | printers not on the software ports PORTPROMPT:, NUL:, SHRFAX:, FILE:, XPSPORT: - heuristic | printer |
| batteryPresent | `Win32_Battery` | - |
| hyperVEnabled | optional feature Microsoft-Hyper-V-All / Microsoft-Hyper-V enabled | hyperV |
| wslEnabled | optional feature Microsoft-Windows-Subsystem-Linux enabled | wsl2 |
| virtualMachinePlatformEnabled | optional feature VirtualMachinePlatform enabled | wsl2 |
| windowsSandboxEnabled | optional feature Containers-DisposableClientVM enabled | windowsSandbox |
| oneDriveInstalled | uninstall entry "Microsoft OneDrive" | onedrive |
| phoneLinkInstalled | AppX package Microsoft.YourPhone | phoneLink |
| xboxAppInstalled | AppX package Microsoft.GamingApp | xbox |

Capabilities that cannot be determined (for example because an inventory section needs
elevation) are unknown, and conditions on unknown facts are not met.

## Startup entry approval

Task Manager records its enable/disable choice in the undocumented
`...\Explorer\StartupApproved\Run`, `Run32` and `StartupFolder` values. Observed data uses
0x02/0x06 as the first byte for enabled and 0x03/0x07 for disabled entries; WinLean uses the
low bit of the first byte and labels the result as a heuristic. It is only used for
inventory and benchmarks, never to change anything.
