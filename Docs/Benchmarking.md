# Benchmarking

`.\WinLean.ps1 -Benchmark` measures background activity; `-Apply` records a baseline before
changing anything (unless `-SkipBenchmark`). `-Report` compares the baseline with the newest
benchmark taken after the run.

## Metrics and methods

| Metric | Method |
|---|---|
| CPU busy % | `Win32_PerfRawData_PerfOS_Processor` (`_Total`), sampled every second for 10 s. For two samples: `100 * (1 - delta(PercentProcessorTime) / delta(Timestamp_Sys100NS))` (the raw counter measures idle time). Reported as average, median and maximum with one decimal. |
| Top CPU consumers | `TotalProcessorTime` of every accessible process at the start and end of the window, as a percentage of total capacity (window x logical processors). Protected processes are not visible and are counted as inaccessible. |
| Memory in use | `Win32_OperatingSystem`: `TotalVisibleMemorySize - FreePhysicalMemory` (available memory includes the standby cache), in MB. |
| Commit charge | `Win32_PerfRawData_PerfOS_Memory.CommittedBytes`, in MB. |
| Processes | number of processes at the end of the window. |
| Running services | `Win32_Service` in state Running. |
| Running third-party services | vendor heuristic: CompanyName of the service binary (or its ServiceDll for svchost-hosted services), with the organization of a valid Authenticode signature as fallback. WHQL signatures ("Microsoft Windows Hardware Compatibility Publisher") count as third-party because they certify, not author, a driver package. |
| Enabled startup entries | Run/RunOnce keys and startup folders, minus entries disabled in Task Manager (StartupApproved data; see Compatibility.md for the heuristic). |
| Context | uptime, power source (battery discharging or not), logical processors, elevation. |

Raw performance classes are used because performance counter *names* are localized; the WMI
classes are not. The first query of a WMI performance class can take seconds; a warm-up query
is made before sampling.

## Precision

A benchmark is a snapshot, not a controlled experiment. Values are rounded (CPU one decimal,
memory whole MB) to avoid suggesting more precision than a 10-second sample has. Differences
of a few percent CPU or a few hundred MB are within normal fluctuation.

## How to compare fairly

1. Close applications, stay on the same power source (plugged in), and let the system idle for
   a few minutes after signing in (background maintenance runs right after sign-in).
2. Take the baseline under those conditions (`-Apply` does this automatically, or run
   `-Benchmark` first).
3. After applying, sign out (or reboot if the report says so), sign in, wait the same time,
   then run `.\WinLean.ps1 -Benchmark` and `.\WinLean.ps1 -Report`.
4. Repeat measurements if the difference matters; compare trends, not single values.

The rules of milestone 0.1 are privacy and recommendation settings. They reduce network
requests and promotional content more than CPU or memory use, so a before/after benchmark
will usually show no significant difference. Service, startup and scheduled-task rules in
later milestones are expected to show measurable effects.

## Not measured yet

- **Boot time.** The Diagnostics-Performance event log (event 100: BootTime,
  MainPathBootTime, BootPostBootTime) requires Administrator rights, is not written for every
  boot, and its values need careful interpretation (fast startup, updates). Planned for a
  later milestone together with login-to-usable-desktop time.
- Disk and network background activity, DPC/ISR latency, frame-time measurements.
