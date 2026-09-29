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
Copy-Item Config\Compatibility.example.json Config\Compatibility.json
notepad Config\Compatibility.json
.\WinLean.ps1 -Validate
```

`Config\Compatibility.json` is ignored by Git (it describes one machine). Use
`-CompatibilityPath <file>` to point to another file.

- `true` = required: rules that would reduce the feature are skipped.
- `false` = not needed: such rules may apply (subject to profile and risk).
- missing = undeclared = **treated as required**.
- Unknown keys are reported as warnings (probably typos) and ignored.

The canonical key list, with descriptions, is `Schemas\compatibility.schema.json`:
printer, networkPrinting, scanner, bluetooth, bluetoothAudio, xbox, xboxControllers,
gamePass, microsoftStore, onedrive, hyperV, wsl2, windowsSandbox, virtualization, docker,
remoteDesktop, windowsHello, bitLocker, touch, pen, windowsSearch, phoneLink, widgets, teams,
copilot, locationServices, telemetryDiagnostics, visualStudio, sqlServer, gpuVendorUtilities,
rgbSoftware, motherboardUtilities, fileSharing, smb, developerMachine, gamingMachine.

None of the milestone 0.1 rules has compatibility conditions: they are safe regardless of
the answers. Conditions become essential for the feature-dependent (Medium risk) rules of
later milestones, for example `services.print-spooler.disable` requiring `printer: false`.

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
