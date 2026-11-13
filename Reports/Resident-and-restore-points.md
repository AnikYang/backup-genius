# Backup Genius 1.5.0 validation

## Behavior

Mac resident observation now starts from saved source authorization even when a backup disk is disconnected or awaiting consent. FSEvents are merged into the local SQLite dirty queue using a bounded 300 ms coalescing window while the worker is idle; ordinary idle time has no source scan timer. Pausing synchronization and ejecting the destination leave source observation running. Closing the app drains events before releasing observation. A source on the ejected volume is released and reconciled on reconnect.

Windows similarly keeps ReadDirectoryChangesW active across destination disconnection and drains source events before the coordinator's disk-consent gate. Overflow, lost observation or a process restart remain conservative: the existing USN / supplemental-scan path is used. Event evidence accelerates detection; it does not bypass stable-source checks, transaction recovery, destination identity checks or reconnect reconciliation.

Successful backups publish complete immutable restore points, independent of mutable latest copies. Native Mac history has separate tabs for points, per-run file changes, and individual historical versions. Windows has native point browsing and full-point restore. Restoration always creates a new folder. Initial independent archival adds work; zero-change receipts reuse existing content. The portable format and retention limits are documented in [the extension specification](../Protocol/Restore-points.md).

Mac UI changes include a separate disk diagnostics page, wrapped confirmation cards for the selected disk, clearer consent status, offline source observation/counts, a distinct indeterminate archive phase with sampled write rate, and hidden zero-valued “this run” metrics before a run exists. Points and health data reset when switching folders. Form-based diagnostics scroll and use semantic colors and native controls.

## Health and performance detection

Mac uses the SDK's `IOATASMARTInterface::SMARTReturnStatus`, `GetATAIdentifyData`, and `IONVMeSMARTInterface::SMARTReadData`. Windows uses [failure prediction](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddstor/ni-ntddstor-ioctl_storage_predict_failure) and [NVMe protocol queries](https://learn.microsoft.com/en-us/windows/win32/fileio/working-with-nvme-devices). NVMe critical warning, temperature and percentage used are separate values. The latter is a manufacturer's wear estimate, not a guaranteed time to failure. Health queries run only on demand, never to keep a sleeping HDD awake in the background.

ATA-reported zoned capability can identify reported SMR behavior. Absence of this capability is not proof of CMR; the app explicitly reports unknown and directs the user to the exact model's manufacturer specification. [Seagate's command reference](https://www.seagate.com/files/staticfiles/support/docs/manual/Interface%20manuals/100293068j.pdf) describes host-aware and device-managed zoned capabilities. USB bridges, permissions and firmware can make all SMART or identify information unavailable. No fabricated health percentage, model heuristic, privileged helper, external executable or paid service is used.

The bounded test writes and reads a 64 MiB exclusively-created temporary file and samples 64 aligned 4 KiB reads. Data read-back is checked, writes are flushed, and the file is removed on normal completion and handled errors. macOS requests uncached I/O; Windows uses aligned unbuffered, write-through I/O. Tests do not overwrite backup files. Results include cache, filesystem, verification and flush effects and are **short workload measurements**, not full-media health scans or sustained SMR/SSD performance guarantees. Power loss can leave an uncommitted hidden scratch file; an unrelated user file is never deleted to clean it up.

## Automated checks

- Swift suite: **37 tests passed on the final Mac implementation**, using disposable APFS/exFAT volumes. Includes offline edits/restart, point restore after deletion and external overwrite, point publication interruptions, interrupted retention cleanup/retry, retained deleted-file versions, pruned-chunk reuse, and bounded speed-test cleanup.
- C++ core: the final suite passed existing incremental, takeover, safety, pruning and transaction tests, plus complete-point restore after external changes, interrupted point publication/retry, pause/resume during capture, and speed-test cleanup.
- Actual data exchange: Swift-created exFAT fixtures restored by C++; C++-created points and interrupted transactions restored by Swift. The **two final import tests passed**. This uses the native Swift implementation and the C++ POSIX test backend on macOS.
- Win32 changed core translation units are checked as x64 and ARM64 COFF objects. Full WinUI MSBuild and physical Windows 11 UI validation require a Windows host and are not represented by these cross-compilation tests.

## Performance on virtual volumes

Release engine, Apple Silicon, macOS 27.2, native FSEvents. Each small file is 1 KiB, with one additional 32 MiB file. APFS has 100,000 small files; the completed exFAT supplement has 1,000. These are different-sized workloads and must not be used to rank the two formats or estimate USB disk speed.

| Workload | APFS 100,000 files | exFAT 1,000 files |
| --- | ---: | ---: |
| Initial backup and independent point | 220.071 s | 6.806 s |
| Unchanged | 0.060 s | 0.030 s |
| Edit 1% | 8.309 s | 0.161 s |
| Move 1% | 5.520 s | 0.165 s |
| Change one byte in the large file | 4.025 s | 0.211 s |

Both unchanged runs examined zero candidates and read/wrote zero file-body bytes; only the small completion receipt is new. Editing 1% examined exactly 1,000 / 10 candidates. Both move runs read and wrote zero body bytes. The large-file edit read 32 MiB of source to identify the changed block and wrote **64 KiB to the latest copy**. All completed scenarios reported zero issues.

APFS uses copy-on-write clones: reported historical payload writes are zero, but cloning still consumes metadata and later copy-on-write space. Profiling identified a full-device flush per clone as a bottleneck. The final implementation flushes each clone's inode and batches directory/full-device barriers with immutable metadata segments before publishing a point. Changed-point metadata replay still adds about four seconds in this 100,000-file workload; it is separate from source scanning and remains an optimization opportunity.

exFAT's initial independent point read and archived 34,578,432 additional bytes. A first change to the 32 MiB file archived 33,619,968 bytes across ordinary old-version history and the new point; the latest copy still received only 65,536 bytes. These separate history namespaces favor compatibility and independence over minimum duplicate storage.

An attempted 100,000-file exFAT run on a 2 GiB test image ran out of space. It is **not** a completed measurement or a successful acceptance result; 1.5.0's 100,000-file exFAT performance remains unverified. The earlier 1.3.0 measurement in [Performance.md](Performance.md) cannot substitute for it. Final runs used disposable 8 GiB images and did not write to the user's real backup disks.

Raw results: [APFS 100k](points-100k-apfs.json), [exFAT 1k](points-1k-exfat.json). Counters measure application payload I/O, not filesystem metadata, physical device traffic or hardware write amplification. New point reads contribute to target-read **bytes**; the existing target-read request count does not yet include those archival reads.

## Installed app, UI and physical hardware boundaries

- Mac bundle: **1.5.0 (10)**, locally built and ad hoc signed. The final bundle replaced the installed app; all four configuration JSON files had identical hashes before and after installation. A process already running build 9 must quit normally and reopen to load build 10's final archive optimization. The ZIP archive passed integrity checks and includes a SHA-256 checksum file alongside it.
- Code-level UI changes and native Mac compilation passed. Window capture repeatedly failed with ScreenCaptureKit `-3811`; final on-screen layout, keyboard, dark-mode and accessibility behavior could not be verified. This is not a completed visual acceptance pass.
- The earlier build 9 resident process sampled approximately 55–72 MiB RSS, mostly 0% CPU while waiting; it reached approximately 2.6% during synthetic event activity. These are short observations, not a sustained resource benchmark.
- A read-only, unsandboxed native probe of the attached HDD returned unavailable health and zoning data. The attached SSD returned no device health warning, without temperature or wear values. This does not establish full-media health; sandboxed app permissions and USB bridge behavior may differ. No speed test was run on either real backup disk.
- Windows native core cross-compilation covers x64 and ARM64. No new Windows executable or Windows 11 UI acceptance result is claimed without a Windows MSBuild host.
- GitHub's connected API returned 404 for `AnikYang/backup-genius`; the connector offers no repository-creation operation. The source and reports are retained locally, not represented as uploaded or released.
