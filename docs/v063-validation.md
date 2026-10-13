# v0.6.3 implementation and acceptance record

## Historical progress; final acceptance is recorded below

Starting HEAD: `d3a7ffe051b6694c4edfa66371109dde7636600c`, branch `main`, initially clean. [Baseline CI 37830476028](https://github.com/SWHsz/apfs-everything/actions/runs/37830476028) completed successfully. At that baseline both issues were OPEN; no release tag.

The local baseline was rerun on 2026-10-10: 279 tests (259 Core, 20 Desktop), ordinary / ASan / TSan, zero failures, one optional mount test skipped. Core suite durations: ordinary 93.043s, ASan 202.217s, TSan 305.365s. Release build, app build and strict signature verification passed. CLI SHA256 `d9542edd5419ec43c7d51021fd42faca9f44afd9901e1c9ccf695b5dd7badf56`; default signed Desktop SHA256 `e622eadf8cbfbb79376d350000d9c90334b66a21b56cf9aada29a3370ba287f6`. The pre-existing independent smoke bundle has its own identity/signature.

## Phase A

The preserved owned cache/fixture was reused. The first capture, `v063-phase-a-ui`, remained incomplete: the real global menu actions were confirmed by the user and callback captures, and the GUI retained twelve paused/stale results then showed create/delete/rename/content changes (36.8ms result query). Global pause was exercised before both sessions finished startup recovery, so this capture does **not** satisfy the prescribed live-to-pause acceptance sequence. Root still reported Rebuilding / metadata unavailable at the unchanged 1200s readiness deadline. Do not replace this failure with a successful later startup.

Normal UI menu Quit was captured: process exit 0 after 1324.429s; multi-volume shutdown 0.479250ms. Four namespace/metadata base hashes and durable state hashes before/after Quit were unchanged. This is a genuine normal Quit receipt, not SIGTERM.

A subsequent diagnostic smoke variant adds only opt-in menu state snapshots and thirty-second readiness diagnostics; production reconciliation was not modified. Original signed executable and manifest are retained. In `v063-diagnostic-startup`, both sessions reached Live with metadata available. Owned fixture 12/12, sizes and exact nanosecond mtimes passed in 0.059397s; namespace full scans and resource-yield rebuilds were zero. All seven broad-query sort/direction samples reported metadataComplete=true; p95 ranged 391.0–612.5ms. A pending opportunistic compaction and startup lifetime footprint are recorded in the raw capture, so this is not a quiet or 1200s active-live gate.

The diagnostic variant is not the signed binary used for the previous published B/E gates. Final common-candidate UI, global/single-volume live-state sequences, active-live/quiet gates and Quit/restart evidence must be consolidated before closing #3. A request for the user's real Test Volume 2 menu pause is pending; this instance remains available for that check. No old-binary/manual result is silently transferred.

### 2026-10-11 status menu stability fix

The user reported that the volume submenu flickered under the pointer and could not be used to pause a single volume. `StatusBarController.update` rebuilt the whole menu on every session snapshot, destroying the hovered submenu even when its visible presentation was unchanged. This is a UI refresh defect; flicker alone does not establish repeated Live-state transitions.

The controller now defers menu and status-button updates while the root menu is tracking, retaining the original action items and volume IDs. After menu close/action dispatch it renders the latest state. Outside tracking, identical visible presentations retain their existing menu items. Login refresh publishes only when the actual service status changes.

Two regression tests exercise 100 snapshot/login refreshes while a volume submenu is open, invoke the retained volume pause item, and verify the latest global/volume/login presentation after closing; unchanged presentation and login refresh are also checked. All 22 Desktop tests passed (0 failures); release Desktop build and strict ad-hoc signature verification passed. These are automated delegate/action checks, not a replacement for a real pointer/menu acceptance.

The preceding `v063-ui-20261011` capture exited normally with code 0 after 1094.832s. Its binary and manifest were preserved before replacement. The fixed independent bundle runs under capture `v063-menu-stability-20261011`, Desktop SHA256 `f87a00cbd467d2a10ff17f20d353598db81a7a6a4b50ee5963abf25e8815fbba`. The user successfully selected Test Volume 2 pause from its real status submenu; the callback captured volume ID 2 pausedStale while volume ID 1 stayed Live. This confirms the formerly inaccessible action became usable; prolonged real hover stability and common final-candidate gates must still be consolidated.

While volume 2 remained paused, the owned fixture received a create (77 bytes), delete, rename and content write (base-3 from 173 to 257 bytes). A changed query followed by a fresh prefix query still returned the old twelve rows, old names and old sizes, all labelled paused (57.3ms). The settings window independently showed volume 1 Live with metadata ready. Raw menu snapshots and an owned before/after fixture receipt were retained.

The user then selected the real single-volume resume action. Its callback recorded volume 2 Catching up while volume 1 stayed Live. On subsequent UI inspection both were Live, volume 2 metadata was ready, and all twelve rows showed the expected new names and sizes (55.8ms). A separate SystemVersion.plist query returned 31 results from volume 1 (36.5ms). Pause-to-resume diagnostic deltas showed zero full scans and resource-yield rebuilds. Canonical fixture names were restored while preserving the updated 257/77-byte contents. This completes the observed UI sequence, but manual observation does not establish the 30s convergence deadline or nanosecond mtime equality; minute-resolution UI timestamps cannot substitute for those gates. An opt-in menu verifier is being added for automatic timing/exact metadata checks on the common candidate.

The `v063-menu-gates-20261011` warm capture preserved a failed 30.069s fixture check: names were 12/12 but metadata was still stale/unknown. At that point diagnostics explicitly reported metadata catchingUp with 3,649/7,320 pending lookups for the two sessions. The original smoke readiness condition required metadata **available**, which allows queries during replay; it did not require replay complete. Subsequent independent UI inspection showed the updated twelve rows and 257/77-byte sizes (34.5ms). This is evidence of ongoing recovery, not proof of a permanent runtime rollback defect. The failed receipt is retained.

Smoke readiness now requires both namespace Live and metadata freshness Live before fixture or active-live validation begins, retaining the original 1200s readiness deadline. A regression test rejects searchable-but-catchingUp metadata. Only acceptance code changed; production replay/reconciliation remains unchanged. All 23 Desktop tests passed. A separate Phase A source candidate excludes the unfinished storage foundations; its signed Desktop SHA256 is `c34cf91866bd5590826a6527cad4ea9c87f0bf462f41c61c172a4730d2f49356`, capture `v063-phase-a-final-20261011`. Full ordinary/ASan/TSan checks and precise menu gates are in progress; neither issue is closed.

### Scoped fixture readiness and common final candidate

The strict all-volume metadata-freshness experiment (`v063-common-native-20261011`, SHA256 `609551e6512881cbd6eb4ed400529cee5daea6d74388773b31c4093cad6ed4c3`) eventually began its active window after roughly 862s of system-volume metadata work. It was normally quit before the full window completed to install the final verifier. Focused build/test work overlapped this exploratory window; it is not a passing E receipt. Exit was 0 and multi-volume shutdown was 1.337ms. Its before-Quit hash receipt used an incorrect filename-extension filter and contains no files; retained after-Quit hashes must not be represented as a before/after comparison.

The final readiness predicate requires both namespaces Live, metadata available, and the twelve owned fixture paths/types/sizes/exact nanosecond mtimes synchronized. Unrelated system metadata may still be catching up. The original 1200s startup deadline, 1200s active window, and 30s convergence deadline are unchanged. This verifies the fixture that the benchmark actually mutates instead of waiting for the entire machine's metadata to be quiescent. New regression tests reject stale sizes, one-nanosecond timestamp differences, unknown values, wrong types, duplicate hits, missing volumes and unavailable metadata.

The menu verifier times from the real menu action entry, compares the exact owned fixture under concurrent broad-query pressure, and rejects full-scan/resource-yield rebuild increases. While only the test volume is paused it also queries SystemVersion.plist and records System freshness. Core replay/reconciliation is unchanged. The automated ten-round verifier now explicitly requires metadataComplete and counts the resume API work inside its unchanged 30s deadline. Warm restart uses an opt-in child environment flag within the already guarded smoke bundle; executable and Info.plist need not change or be re-signed.

The isolated final Phase A candidate passed all 24 Desktop tests under ordinary / ASan / TSan (0 failures). Release build passed. Full 259 Core checks had already passed ordinary / ASan / TSan on the identical unchanged Core sources. Signed Desktop SHA256 `e35f1a7e4ea3af3b69406432082fd326ab5bdaabbf10a0202002086039f2fc33`; CLI SHA256 `03716fd35d2b3cf75aa4ccc9f37773e6329a25779bbe105b03eb056c57f3fcae`. Common capture `v063-scoped-native-20261011` is in progress, using the original owned cache and fixture. Both issues remain open.

The final candidate CLI controlled 60s background check also passed: 60.005s, CPU 0.000215s, disk/logical writes 0, sampler/compaction/metadata scheduler idle wakeups 0, create/delete/rename p95 21.710/20.623/22.881ms. This is an independent small owned quiet workload, not the real dual-volume E gate.

The completed common-candidate E window was **not passed**: 1203.639s, 237 observations, sole blocker `physical footprint limit`. Maximum of the emitted 30s physical samples was 158.564MiB (the gate also samples every 5s); end 113.173MiB. Received/processed events both increased by 8739; full-scan and resource-yield rebuild deltas were zero, and disk/logical writes were zero. Search/sort/window interactions and the independent controlled CLI benchmark overlapped this exploratory E workload; causality for the peak is not established. A passing earlier binary or a quieter partial interval cannot replace this failure. A subsequent controlled same-binary E run is still required before #3 closure.

After that window all ten B rounds passed under continuous broad queries: namespace 12/12, size and exact nanosecond mtime correct, metadataComplete=true, maximum 2.665082s including the resume API, full-scan/resource-yield rebuild deltas zero. Real search input/column buttons displayed twelve fixture rows, expected 257/77/0-byte sizes and visible date columns; first query 46.7ms, size/name/relevance/mtime queries 65.9/46.6/45.7/46.7ms. UI date labels have minute precision and do not independently prove nanosecond equality. The user confirmed Option+Space display, input focus, Escape hide and Option+Space restore on this same final candidate. Real menu timing gates remain pending; no Issue closure or push has occurred.

## Phase B foundations

Implemented independent, not-yet-connected storage components:

- `IndexStoragePolicy`, versioned source-root locators, state descriptions and overflow-safe space formulas.
- Pinned no-follow locator directory; 0700 directory and 0600 configuration/lock/temp files; bounded 64KiB document; flock, file fsync, rename and parent fsync publication. Missing/corrupt optional configuration resolves to defaultInternal; publication refuses a corrupt document instead of discarding other roots.
- APFS/local-only mount provider and UUID resolver; source UUID, root inode and relative-root hash remain separate from storage UUID. Mounted paths are resolved afresh; explicit paths use volume-relative policy. Legacy unconfigured internal cache placement is preserved.
- `PReadBacking`: 64KiB blocks, default 4MiB cache per file (hard ceiling 16MiB), reads capped at 1MiB, owned Data results, cancellation, structured short-read/closed/I/O errors, identity validation even on cache hits, reclamation and serialized descriptor close.

Thirteen new focused tests passed ordinary / ASan / TSan (ordinary 0.156s, ASan 0.428s, TSan 0.559s test-suite duration, excluding build). They cover atomic publication failure, distinct source roots, corruption/symlinks/permissions, real local APFS/default-internal resolution, UUID/remount resolution, read-only/offline/low-space/identity mismatch, filesystem rejection, arithmetic overflow, bounded cross-block reads, cancellation, closure and short reads. This does not replace complete final-candidate sanitizer/CI validation.

These APIs are **not integrated into production sessions, namespace/metadata readers, migration, storage lifecycle, Settings or CLI management yet**. Current search remains the prior mmap engine. No user's daily index or settings were moved.

The required controlled `background-bench --idle-seconds 60` passed: 60.004246s, CPU 0.000135s, disk/logical writes 0, CPU sampler / compaction / metadata scheduler idle wakeups 0. This is a small owned controlled workload, not a substitute for the real dual-volume E window. [Local aggregate receipt](benchmarks/v0.6.3/foundation-local.json) records test and raw-log hashes.

## Removable storage experiment and decision

Two owned 128MiB APFS sparse-image experiments used valid synthetic namespace v2 / metadata v1 indexes (65,537 namespace records). Source and storage were on separate filesystems. Only generated index bytes were read, never source-file contents. Children, images and captures were independently owned; the real Data 1 volume was not ejected.

- Existing production mmap readers continuously searched namespace and metadata. Normal detach returned 16 (busy). After child termination, normal cleanup detach succeeded. Forced detach succeeded and the child exited **-10 (SIGBUS)**.
- The new pread backing continuously read bounded blocks from both indexes, without mapped validation or pointers in that read loop. Normal detach also returned busy because descriptors were open. Forced detach succeeded; child emitted **storageIO(5), EIO**, and exited **0**, with no SIGBUS.

This proves a fatal failure mode for long-lived mmap on this owned APFS image, and a successful bounded byte-read failure path for pread. It is **not** production external-query, migration, disconnect/reconnect, performance or comprehensive removal acceptance. [Aggregate probe receipts](benchmarks/v0.6.3/storage-probes.json) preserve raw report/stdout/stderr hashes.

Decision: all ejectable/external/unknown storage must use safe pread-based namespace and metadata readers. Checking only `volumeIsRemovable` is insufficient for fixed-media external SSDs; provider also checks internal/ejectable properties. No SIGBUS handler recovery is used. #2 must remain open until production readers and lifecycle are connected and tested.

Local experiment reproduction (current Mac Xcode build layout):

```sh
swift build -c release
swift test -j 4
swiftc -swift-version 6 -I .build/release \
  -I .build/arm64-apple-macosx/debug/CAPFSShim.build \
  scripts/StorageMMapProbe.swift .build/release/APFSFindCore.o \
  .build/release/CAPFSShim.o -framework CoreServices \
  -o /private/tmp/apfsfind-storage-backing-probe
python3 scripts/probe_removable_storage.py \
  --helper /private/tmp/apfsfind-storage-backing-probe --backing mmap
python3 scripts/probe_removable_storage.py \
  --helper /private/tmp/apfsfind-storage-backing-probe --backing pread
swift test -j 4 --filter 'IndexBackingTests|IndexStorageTests'
swift test -j 4 --sanitize=address --filter 'IndexBackingTests|IndexStorageTests'
swift test -j 4 --sanitize=thread --filter 'IndexBackingTests|IndexStorageTests'
```

The probe retains owned images/raw captures for reproducibility. Build-layout portability and public CLI probe dispatch remain to be completed.

On the next UI attempt the Mac was locked. Final real menu/hotkey operations therefore remain pending; the diagnostic instance was verified running (PID 1651) and was not killed to clear this blocker. Storage lifecycle/migration and final Issue closure remain unimplemented/unaccepted.

The final candidate real global-menu pause was received and both sessions reported `pausedStale`. After owned create/delete/rename/content-write mutations (still 12 files), fresh UI queries returned the old 12 rows at 53.6ms, including the deleted 47-byte `born-10`, old `renamed-10`, and old 110-byte `base-3`; all rows showed paused. The new created name returned zero rows at 49.8ms. On-disk expected values now include an 83-byte new file and 307-byte `base-3`; exact stat nanosecond timestamps and pinned fixture identity are in the temporary receipt. Real menu resume is pending.

The final real global-menu resume passed from the menu action entry timestamp in **8.605487s** under continuous broad query. Namespace was 12/12 with `metadataComplete=true` and exact size/nanosecond mtime correct; full-scan and resource-yield rebuild deltas were zero. The final verifier query took 54.842ms. UI also displayed the new 83-byte created file, renamed entry and updated 307-byte `base-3`, with 12 rows at 63.1ms. Single-volume menu acceptance is next.

The final real single-volume menu pause selected UUID `00000000-0000-0000-0000-000000000002` only. System namespace remained Live and its `SystemVersion.plist` search returned 31 rows, all live, at 71.683ms. After a second owned create/delete/rename/content-write set, the paused Test Volume 2 still returned its old 12 rows at 49.8ms (83-byte created file and 307-byte `base-3`, paused labels); the newly created name returned zero rows at 39.5ms. Actual expected files now contain 97-byte created file and 401-byte `base-3`, with exact stat timestamps recorded. Real single-volume resume is pending.

The final real single-volume resume passed in **6.435252s** from the menu action entry, 12/12 paths, exact size/nanosecond mtime and `metadataComplete=true`, with zero full-scan/resource-yield rebuild deltas; verifier query 51.979ms. System remained Live at both pause and resume menu callbacks. The UI displayed the updated 97/401-byte values and new renamed entry, 12 rows at 60.7ms. All required human hotkey and real global/single-volume menu interactions are now confirmed on the same signed e35 candidate. Quit/warm restart and the controlled E repeat remain pending.

The same final candidate exited normally through Command+Q: process exit 0, multi-volume shutdown **4.123833ms**, and both namespace bases, both metadata bases and the state-file inventory/hashes remained unchanged. Fixture names were returned to the canonical round-10 names (values retained: 97/401 bytes) before Quit for the same-bundle warm-restart helper. `v063-scoped-warm-20261011` now validates the unchanged signed executable and Info.plist with the same cache; restart mode is process-local environment injection behind smoke-bundle guards. Portable partial receipt: `docs/benchmarks/v0.6.2/final-desktop-common-candidate.json`.

The same e35 candidate warm restart passed without full scan or resource-yield rebuild: both namespaces Live, metadata available, fixture 12/12 and exact nanosecond values with `metadataComplete=true`. Search-ready timings were 3.546/2.103s; time-to-Live 47.519/8.054s. Fixture verification took 47.927ms after readiness; visible UI query returned 12 rows at 58.1ms. Warm instance normal exit was 0, multi-volume shutdown 68.696ms, and all base/state hashes remained unchanged.

The controlled E repeat (no additional UI or independent benchmark during the window) also **failed**, sole blocker physical footprint: 1203.397100s, 238 samples; maximum emitted physical value 188.048MiB and end 122.736MiB, writes/full-scans/resource-yield rebuilds zero. Received/processed deltas 15141/15145 (four events were pending at the baseline). Its ten B rounds all passed, maximum 6.026213s. An after-window `vmmap -summary` inspection reported 65.1MiB allocated malloc bytes and 65.0MiB dirty/swap fragmentation, including 47.5MiB virtual empty large-malloc regions; this supports investigating temporary allocation but does not establish allocation-stack attribution. Inspection happened after E/B and does not replace their measurements.

A narrow production candidate fix will page ordinary discovered metadata subtrees through the existing secure 64KiB cursor. The current branch pages inbox-overflow subtrees but allows ordinary discovered directories to collect up to 100,000 entries at once. The fix will retain cursor fencing/cancellation and be verified with a new ordinary-new-directory regression; it will not change snapshot format, cold builder or namespace reconciliation. The failed e35 receipts are retained and neither issue is closed.

The narrow paging candidate passed all 284 tests (260 Core + 24 Desktop, 1 optional mount skip) under ordinary/ASan/TSan, respectively 96.134/231.138/337.834s including builds. The isolated source candidate excludes unfinished Phase B files. Release build 50.465s and actual `build_app.sh`/strict signature verification passed. The negative control restored only the old ordinary-subtree branch: the new test failed five paging/yield/fence-budget assertions (whole 2048-entry batch), then all six focused tests passed on the fix. The old path completed those entries rather than losing their metadata; the failure demonstrates absence of bounded paging under query pressure.

New signed Desktop SHA256 `c6774c873a223559258d72165683e5ee71c22e55233b912db70dc3fcff3ca1e7`, CLI `6bb402fb20952d4c4ec7281730cbfcfd9db12c2f2fb088457957bc4e4358e0e1`. Owned bundle identity/Info/cache/fixture are retained; prior e35 signed app/manifest are archived separately. CLI G is running before the next full native window; c677 B/E/F remain unaccepted. Portable receipt: `docs/benchmarks/v0.6.2/paged-desktop-common-candidate.json`.

The c677 CLI G controlled quiet gate passed before the native run: 60.005143s, CPU 0.000279s, disk/logical writes zero, sampler/compaction/metadata/deferred wakeups zero. Its 1000 pause mutations recovered in 235.037ms; create/delete/rename p95 21.842/20.509/23.382ms. This small owned workload is independent of the subsequent real dual-volume E window.

The first c677 native launch encountered a genuine System queue-overflow recovery (startup full scans 2, other volume 0). Its subsequent E window failed after 1204.832357s / 238 observations: physical footprint and unfinished maintenance at deadline. Physical started at 623.752MiB and ended at 184.158MiB; the cold builder's 1.9GiB lifetime peak is separate. An opportunistic metadata checkpoint remained queued under actual memory warning; the queue was not cancelled or omitted to improve the result. E full-scan/resource-yield rebuild deltas and disk/logical writes were zero. All ten B rounds passed, maximum 5.526934s, exact 12 paths/size/ns mtime and complete metadata. Post-window vmmap allocated 38.8MiB, fragmentation 86.7MiB; this does not attribute allocation stacks or prove a fix. The failed receipt remains immutable as a distinct scenario.

Normal Command+Q exit 0, shutdown 1.334375ms and unchanged base/state hashes were followed by a same-executable/Info/cache warm restart. Both volumes became Live without full scan or resource-yield rebuild: search-ready 2.590/1.511s, time-to-Live 59.402/6.406s; exact fixture 12/12 with complete metadata verified in 36.093ms. UI returned 12 expected rows at 35.6ms. Warm normal exit 0, shutdown 3.489500ms, base/state hashes unchanged. A separate same-c677 warm E/B window is running with identical roots, data, 1200-second duration and 150MiB gate. It cannot erase the post-cold-recovery failure or transfer e35 UI F acceptance to c677.

That warm E also failed, physical-only: 1201.679783s / 237 observations, no full scans/yield rebuilds/writes and no deadline maintenance tasks. The 30-second output maximum 136.658MiB missed a peak detected by the actual 5-second gate; end 112.392MiB, process lifetime peak at end 164.814MiB. All ten B rounds passed, maximum 6.750896s. Do not call the sparse output maximum an acceptance maximum. Mac locked after the completed window; verified owned instance SIGTERM exit -15, unchanged base/state hashes, not a normal Quit. The c677 signed app/manifest remain separately archived.

Post-window heap reported two ScannedEntry arrays totaling 8,437,760 bytes, allocated heap 64,316,845 bytes. Namespace enumeration still materializes the entire metadata listing before mapping namespace; the next narrow candidate consumes metadata pages into the required atomic namespace listing, retaining no whole-directory ScannedEntry collection. No reconciliation algorithm, cold builder, format or 100k cap changed. New 2050-entry file/directory/symlink test checks identical identities/paths, bounded temporary collection, cancellation and cap failure. Restoring only the old namespace collection path fails its allocation-budget assertion; fixed focused 12 tests pass. Full tests/builds are running. The gate now preserves the maximum across every 5-second observation and emits peak timing/backlog; thresholds and decision rules are unchanged. xctrace startup did not complete while Mac locked and was stopped; no allocation-stack attribution is claimed.


## Phase A closure (authoritative)

The historical failures above are retained. They do not override the final same-executable acceptance in [v0.6.2 validation](v062-validation.md) and [portable receipt](benchmarks/v0.6.2/authoritative-repeat-desktop-common-candidate.json). Runtime `16472f9598f4d59d7e9277d4ddf06ca0c1abeef6`, closure documentation `d780256a4a3bf3fc3d0306d491655522c60f13fe`. [Runtime CI 38140923147](https://github.com/SWHsz/apfs-everything/actions/runs/38140923147) passed all four required jobs; [documentation CI 38141741007](https://github.com/SWHsz/apfs-everything/actions/runs/38141741007) also passed. Issue #3 is closed and roadmap #12 marks #1/#3 complete; no tag.

Final B/E/G/F: 1202.396660s / 237 observations, maximum physical 135.127MiB / end 89.205MiB, zero full scans/resource-yield rebuilds/maintenance restart loops/writes. Ten incremental rounds all passed (maximum 9.477076s). True global/single-volume menu resume: 9.384830s / 6.617918s, exact twelve paths, size, nanosecond mtime and complete metadata; System kept 31 Live results during single-volume pause. Human hotkey/show/focus/Escape/restore passed. Normal Quit exit 0 / 6.234500ms; same-cache warm restart search-ready 2.015/3.120s, Live 9.898/115.965s, full scans zero; second Quit exit 0 / 2.043917ms. Four base hashes and file inventory unchanged. Controlled 60s quiet CPU 0.000260s, zero writes/wakeups; 1000 paused changes recovered in 67.939125ms. All 297 tests passed ordinary/ASan/TSan.

## Phase B implementation

Namespace v2 and metadata v1 formats are unchanged. DefaultInternal preserves existing cache paths and filenames. Configuration is per source UUID, root file ID and SHA256 of volume-relative source root. Locator v1 stores that identity, storage UUID + relative directory, policy and updatedAt; it never identifies storage only by an absolute mount path. The default parent is 0700, locator/lock/temp files 0600, with flock, fsync, atomic rename and directory fsync. Missing/corrupt configuration safely reads as DefaultInternal; an invalid locator cannot silently be overwritten by a migration.

The resolver enumerates only local APFS mounts, rejecting network/autofs, read-only, wrong owner, symlink components and traversal. External files live in a stable per-source directory. Selected paths are excluded from scanner/events before staging. Source identity and storage mount incarnation are checked separately. Unknown or physically disconnectable media selects pread, including fixed USB/Thunderbolt SSDs. Internal non-removable storage retains mmap.

The child-process preflight demonstrated process-fatal SIGBUS for the old mmap reader under forced APFS image detach. No SIGBUS recovery handler was added. Both production immutable readers now support owned pread byte windows: 64KiB blocks, default 4MiB per backing (hard maximum 16MiB), maximum 1MiB read, latched I/O failures, cancellation and pressure cache release. Namespace decoding windows, ancestor depth, query parent/original-name caches and top-K candidates are bounded; no whole directory path map or immutable base copy is introduced.

Migration leaves old queries available during a 1MiB stream copy, uses maintenance leases and chunk yield/cancel, validates complete target formats, pauses briefly to check snapshot/source identity, publishes locator last and reopens a warm session. Failed validation, cancellation, ENOSPC, read/write faults, locator failure or replacement startup rolls back; old files remain. The explicit old-copy action requires the new session to be warm, Live and metadata-ready, and rechecks old snapshot/root identity before deleting only known files. Rollback receipts contain paths/identity/metrics, not retained file descriptors; the session's validated-reader handoff is shared, one-shot and consumed at adoption.

Space formulas are centralized: migration files + state/lock overhead + max(256MiB, 10%); compaction current files + estimated new namespace/metadata + that margin. UI displays index size, migration/compaction requirements, available bytes, source/storage UUID and mount/state. Move/default/cancel/retry/old-copy controls call the owning actor asynchronously. Reopen keeps an existing directory chooser focused. A verified device/inode comparison registers both `/private`/`/Users` and Data-volume aliases before staging exists, so scanner/event/base filtering cannot index its own custom cache. The resolver also rejects a source nested inside an internal cache through the other alias. Restoring the old registration reproduces the exclusion regression; the fixed real-directory scan retains the public file and omits the cache.

Unmount cancels queries/maintenance, stops the watcher, drains holders and drops bases/overlay/descriptors without cursor advancement. Only dependent sessions become indexStorageOffline; independent sources remain searchable. Reconnect resolves the UUID anew, validates bases, and replays durable cursors; valid history does not require a source scan. Mount-path changes are tested with the same owned APFS image at a different path.

### Preserved failures and narrow fixes

An early production probe driver missed its drain marker; its failure is preserved. A later driver incorrectly treated the safe actor mode as forced and did not inspect the distinct indexStorageOffline state. Both probe defects were corrected; the nine-mode production receipt records explicit detach type, drain and process exit. The final production actor probe deliberately retains the public migration receipt while performing a normal unmount.

The old real System snapshot replay encountered queue_overflow. Moving the existing ordinary-history overlap filter before queue admission avoids rebuilding namespace for events already covered by its fence; a bounded metadata inbox still requests existing metadata repair if needed. Unknown/new IDs, HistoryDone, gaps, must-scan and ambiguous events remain admitted. The old snapshot still overflowed on remaining work; this is retained as a failure, not described as invalid journal or solved by that filter. A current owned source epoch is prepared separately through the existing scan/replay/quiesced checkpoint path. Its preparation scan is not counted as a zero-scan migration.

A real 2.9-million-entry quiesced checkpoint exposed repeated mount enumeration at every directory validator checkpoint (281265.7ms). Hot checkpoints now check the latched monitor/backing; full UUID/device/space checks remain at transaction boundaries. The regression uses 200 directories and asserts mount-provider enumeration does not scale with directory count. The cold builder and reconciliation state machine were not rewritten.

The first complete TSan run reported two assertions in the online-write gate, with no data-race report. Its tiny three-entry base crossed automatic compaction ratios, and instrumentation outlasted the quiet interval. The gate now isolates event application with raised compaction thresholds, retaining its no-write assertions and explicit checkpoint check; separate automatic compaction tests remain. This failed run is retained alongside the later checks.

### Evidence and remaining acceptance

[Production APFS detach receipt](benchmarks/v0.6.3/production-storage-detach.json) covers safe/forced/reconnect, metadata checkpoint, compaction, metadata bootstrap, migration copy, and safe/forced post-migration actor queries. [Real storage performance](benchmarks/v0.6.3/real-storage-performance.json) retains the full accepted 4,395,790-entry workload and path-parity hashes, five samples per query/sort, no deliberate whole-index query prewarm and no concurrent build/test jobs during measurements. Final executable hashes, full checks, current-epoch migration, Settings action smoke and CI are recorded when complete below.

### Limits

Temporary cold namespace and new metadata construction still allocate O(N) scratch; removable metadata scratch uses owned heap memory rather than mapping the removable filesystem. This is distinct from copying an immutable query base into RAM. Existing uncovered event queue overflow and expired journal recovery can require a full scan; covered ordinary duplicates cannot manufacture that overflow. This release does not add cold-builder rewrites, snapshot formats, WAL, network storage, fuzzy/content indexing, Intel/Universal, signing/notarization, or tags. macOS14 is the deployment target; this machine is Apple Silicon with a newer SDK, not a separate physical macOS14/Intel validation. Forced detach of an owned APFS image is a surprise-removal equivalent, not a power-loss test of the user's actual SSD. Old-copy cleanup is offered for migration receipts retained by the running app; old files remain safe if the app is restarted before that action.


## Phase B candidate before CI compatibility follow-up

The final runtime source manifest SHA256 is `248aff09a4f974a66b9f03c29cb980ef253db58d40be461561a988c57039f884` (99 source files). Release CLI SHA256 `3621517a8989c1d6ca942904a4e565a580edb8a5da4055a6a51335990ba89aea`; signed Desktop SHA256 `5b2abf5b580afea275bc62e501f133c915d7dfb373538bc1233b3319bce8f042`. No runtime source changes followed these builds. [Checks receipt](benchmarks/v0.6.3/checks.json): 336 tests (312 Core + 24 Desktop), zero failures in ordinary/ASan/TSan; one optional native mount test skipped. Core test durations 113.388/227.928/364.508 seconds, distinct from sanitizer build-inclusive wall times 254.779/396.538 seconds. Release build 56.937s; signed app build 1.448s; strict signature verification passed.

The real accepted dataset remains 4,395,790 records / 464,589,349 namespace+metadata bytes. For each of three queries and four sorts, five mmap and pread measurements returned identical ordered paths. System worst p95 mmap/pread **90.521/173.313ms**, Data 1 **63.394/104.823ms**; all twelve comparisons per source passed the 100/200ms gates. Pread process peak RSS **25.0625/27.1094MiB**, namespace and metadata block caches each at most 4MiB, disk/logical writes zero. Format CRC validation reads bytes, and OS caches can be warm; these are not cold physical-device speed guarantees. There was no deliberately prewarmed full query index and no concurrent build/test/other formal measurement.

[Current-epoch real migration](benchmarks/v0.6.3/real-storage-migration.json): **3,118,258 records / 314,507,746 bytes**, internal→Data 1 **18.869s**, Data 1→owned second APFS image **18.555s**, return internal **11.337s**. Warm replay became Live in **11.416s**, zero full scans, identical paths/size/nanosecond mtime in all four sorts, old copies retained. Source and storage UUIDs were distinct. The internal locator measured **273 bytes after returning to DefaultInternal**; it contains configuration, never base data. Preparation used the existing scanner once, separately: 58.366s scan, 21.935s index build, 7.114s quiesced checkpoint, 91.628s overall. It is not included in the zero-scan migration claim. Migration process peak RSS 320.78MiB includes internal mmap validation and warm lifecycle; external query peak RSS is measured separately above. Three complete copies account for 943,570,944 disk bytes written. The second owned image detached normally, exit 0; the user's Data 1 volume was never detached.

[Final production detach receipt](benchmarks/v0.6.3/production-storage-detach.json) used the final CLI, 65,537 valid records and nine modes. Every child/detach exited 0. Safe modes drained before normal unmount; forced queries returned structured offline errors, no crash/hang. Metadata checkpoint, compaction and initial metadata build preserved final base hashes after forced removal; migration copy preserved old usability and locator. Actor modes exercised actual migration and session offline transitions, and normal unmount succeeded while the public migration receipt remained retained. Reconnect used the same image UUID at a different mount path, warm with zero scans. Unit integration additionally verifies replayed offline mutations and unaffected independent sessions.

[Controlled background receipt](benchmarks/v0.6.3/background.json): 60.008s quiet, CPU **0.000173s**, zero disk/logical writes and zero sampler/metadata/compaction/deferred scheduler wakeups. 1000 paused mutations retained stale results and converged in **113.954ms**. Create/delete/rename p95 **22.024/21.783/24.670ms** (100 samples each); create maximum **1522.313ms** is retained, not hidden behind the percentile. Native window lifecycle belongs to Phase A's separate acceptance.

### Issue #2 closure matrix

| Gate | Evidence / status |
| --- | --- |
| 1 per-source policy | Implemented; independent source/root migration tests |
| 2 UUID + relative locator | v1 atomic locator, remount resolution tests |
| 3 internal compatibility | Legacy names/default directory unchanged; existing bases loaded without rebuild |
| 4 external APFS | Actual Data 1 migration and owned APFS production queries |
| 5 changed mount path | Same owned image UUID remounted at changed path, warm zero-scan |
| 6 safe migration | Current System roundtrip + actor migration, old queries/rollback copies retained |
| 7 cancel/ENOSPC/I/O rollback | StorageMigrationTests fault/cancel cases and forced copy probe |
| 8 disconnect without crash | Nine final production APFS modes, structured offline, child exit 0 |
| 9 covered reconnect no scan | Production remount plus StorageRuntime/StorageMultiVolume offline replay tests |
| 10 source/storage separation | Distinct real UUIDs and dependency-only offline handling |
| 11 Settings size/space/state | Native fields and directory chooser observed; final Settings action repeat pending lock-screen clearance |
| 12 KB locator | 273 bytes after real return to default; bounded v1 configuration |
| 13 permissions | 0700 roots / 0600 known files; locator/store ownership tests |
| 14 unsafe targets rejected | Local APFS resolver; network/autofs/symlink/traversal/alias regressions |
| 15 sanitizers + CI | Final 336 ordinary/ASan/TSan pass; pushed-HEAD CI pending |
| 16 APFS detach equivalent | Final nine-mode child probe including forced removal; no SIGBUS handler |

Issue #2 stays open until the remaining desktop acceptance and final required CI are recorded. No release tag is created. The older isolated native smoke showed twelve correct rows and Settings source/storage UUID, path, Live state, index size and migration/compaction/available bytes; it opened the actual NSOpenPanel. No unrelated directory was selected. The Mac is currently locked, so this is not presented as a final-candidate Move/default action pass.

### Exact commands

```bash
swift build -c release
swift test -j 4
swift test -j 4 --sanitize=address
swift test -j 4 --sanitize=thread
bash scripts/build_app.sh
codesign --verify --deep --strict dist/APFSFind.app
.build/release/apfsfind background-bench --idle-seconds 60
python3 scripts/probe_production_storage.py --cli .build/release/apfsfind
```

The APFS driver creates its own disposable sparse image under `/private/tmp`, prints its raw report path, and detaches only that image. Existing source-epoch migration requires explicit disposable directories; the commands below keep the user's daily settings/index untouched. `SOURCE_ROOT` may be `/` for the measured System workload. `OWNED_CACHE`, `OWNED_TARGET_DIRECTORY`, and `OWNED_LOCATOR_DIRECTORY` must be directories owned by this test, with 0700 permissions; the target must be on a local writable APFS storage volume. An optional fifth directory exercises external→external migration before return.

```bash
.build/release/apfsfind _storage-refresh "$SOURCE_ROOT" "$OWNED_CACHE"
.build/release/apfsfind storage-migration-bench roundtrip "$SOURCE_ROOT" \
  "$OWNED_CACHE" "$OWNED_TARGET_DIRECTORY" "$OWNED_LOCATOR_DIRECTORY" \
  "$OWNED_SECOND_APFS_DIRECTORY"
.build/release/apfsfind _storage-performance "$SOURCE_ROOT" "$OWNED_CACHE" mmap
.build/release/apfsfind _storage-performance "$SOURCE_ROOT" "$OWNED_CACHE" pread
```

Production user management commands are documented in [README](../README.md); their normal defaults operate on the user's settings, unlike these isolated probes. Full raw logs, historical failures and privately identifying file paths remain local; portable JSON preserves counts, hashes, resource measures and outcomes.

Runtime commit: `8b9464b388ca4dd9f3e41063791f5568ed5e324b`. Portable final measurements reference the executable hashes from this unchanged source candidate.


### CI compatibility follow-up

The first pushed Phase B run [38162571565](https://github.com/SWHsz/apfs-everything/actions/runs/38162571565) failed all four jobs at compilation. Its runner was macOS15.7.9 / Xcode16.4 / Swift6.1.2; the local toolchain is Swift6.4. The migration progress closure sent a shared weak capture directly into a Task. Commit `c53c881652d70e7c3bf48d6486c2c84ce7f06a65` snapshots that optional actor reference into an immutable local before sending it, without changing migration/query/storage behavior. The three StorageMultiVolume tests passed before pushing. The failure and full CI log are retained, and the final full checks/measurements are repeated on the compatibility candidate rather than relabeling the older executable receipts.

Scoped cleanup removed the completed owned performance duplicate (464,589,349 bytes). A failed probe's 924,139,250-byte raw report was compressed to 13,263,557 bytes; decompressing it reproduced SHA256 `58f49fed92cad0b348b3281954f80b673ef0d4eb644bd33df1a20154ceae70b7` before the uncompressed file was removed. No open holders were present. Approximate reclaimed storage is 1.38GB plus generated Python bytecode. Accepted original bases, active native smoke/cache, daily indexes and failure evidence were retained. The exact local cleanup receipt is kept outside the repository.


## Final compatible runtime candidate

Runtime source remains `c53c881652d70e7c3bf48d6486c2c84ce7f06a65`; test-only follow-up `ae6e410b208dc19293cd3a3a7d2c9eddb8bdf185` strengthens the storm assertion. Source manifest SHA256 `897c0830b85cab1bbe25eae16d7a00d5a0586dc9ad367342fe32d8cd6ebae1a5` (99 files), release CLI `b3151a739777a47b4e4a483aae7101fabebda15e7317fcc6661f5214c68a43bb`, signed Desktop `5a1144ee6c87b2654bf744601186c31c54f8370ebbebe499fcd4f915f6b2c3ff`.

All 336 tests passed again in ordinary/ASan/TSan (312 Core + 24 Desktop, optional mount skip1). Core durations **114.699/228.930/365.680s**, build-inclusive wall **116.913/254.815/401.422s**. Release build **56.743s**, app build **1.457s**, strict codesign pass. The final test-only follow-up is separately run ordinary/ASan/TSan after measurements. Portable receipts now refer to the compatible executable above.

Current real-data query worst p95 mmap/pread: System **92.324/177.692ms**, Data1 **53.942/106.605ms**; 4,395,790 records unchanged, all path hashes equal, all 100/200ms gates passed. External reader process peaks **30.1875/24.875MiB**, 4MiB block-cache limits maintained, writes zero. These supersede the earlier candidate's numbers while its raw results remain preserved.

Current real System preparation: **3,189,278 records**, scan **59.023s**, build **22.790s**, quiesced checkpoint **7.280s**, preparation full scans **1**. This epoch is explicitly separate from migration. Migration copies **320,227,546 bytes**; internal→Data1 **19.191s**, Data1→second owned APFS **18.949s**, return internal **11.646s**, warm Live **10.499s**, migration full scans **0**, all four sorts' paths/size/nanosecond mtime equal, rollback copies retained. Locator **273 bytes after return to default**. All steps exit0; second image normal detach exit0. Whole migration peak **328.188MiB** includes internal mmap validation, not external steady query RAM; three copies wrote **960,712,704 disk bytes**.

The final nine-mode production APFS run passed, including actor normal/forced removal; startup receipts explicitly retain zero full-scans for warm reconnect. The 60.010s quiet gate used CPU **0.000168s**, zero disk/logical writes and scheduler wakeups. 1000 paused mutations converged in **277.071ms**; create/delete/rename p95 **22.775/21.641/24.216ms**, create maximum **164.510ms**. No local build/test overlapped formal measurements.

Run [38162790309](https://github.com/SWHsz/apfs-everything/actions/runs/38162790309) passed compilation/deterministic/desktop but failed exactly the old five-second rename assertion in integration and ASan. Its final consistency and delete assertions passed; there is no sanitizer error in that evidence. The test is a no-online-write/correctness gate, so the follow-up synchronously drains the actual FSEvents service after each batch and checks all 1000 child paths with a bounded 30s allowance. Zero-write, generation, content-ignore and explicit-checkpoint assertions are preserved. Independent latency benchmarks and native 30s gates are unchanged. The old failure remains linked and locally archived; it is not labeled a complete transient or erased by the retry.


Publication verification: [38163714821](https://github.com/SWHsz/apfs-everything/actions/runs/38163714821), head `ae6e410b208dc19293cd3a3a7d2c9eddb8bdf185`, passed all four required jobs (deterministic, integration, address-sanitizer, desktop-build). Final storm follow-up also passed locally ordinary/ASan/TSan, all 1000 child names and unchanged no-write/content-generation assertions; test-only edits did not change the compiled runtime source or release executables. Gate15 is satisfied for this runtime/test candidate. Subsequent documentation-only HEAD is checked again before publishing the final Issue #2/roadmap progress comment.

Gate11's final Settings action repeat remains pending: the Mac was still locked at the last native inventory. The compatible signed smoke bundle is prepared with isolated source/cache and **not launched**, preserving the running older smoke. Its executable SHA256 `c0c9285d07d2463824edcedd98e7af370cc9c6fe5b51a84c7e5753bb52f3b1f0` differs from the product only because the copied bundle has an isolated identifier/Info and is re-signed. It uses the same compiled runtime. On unlock, cancel the older chooser, normally quit the old instance, then launch the prepared final instance and verify Move/default/search/fields without touching daily settings. #2 remains OPEN, roadmap #2 remains unchecked, #3 is CLOSED, and no tag was created. Final CI state is also linked from the Issue #2 publication comment.


## Final native Settings closure, 2026-10-13

The real Settings repeat is now complete on the owned candidate from runtime commit `d8e7f3b6f00d6dad634bd8a6e4ba5b5893344ce2`. The ordinary, ASan, TSan, release and signed-app baseline at `68ae899` was repeated successfully: 336 tests, one optional mount skip, zero failures. Required CI for the narrow handoff fix passed all four jobs: [run 38334819518](https://github.com/SWHsz/apfs-everything/actions/runs/38334819518). Final local ordinary/ASan/TSan checks passed: 338 tests (314 Core + 24 Desktop), one optional mount skip and zero failures. Build-inclusive wall times were 139.506/249.225/403.701s. The affected nine-mode owned APFS removal probes were repeated and all passed; every child and detach exited zero. [Final checks](benchmarks/v0.6.3/native-settings-final-checks.json) retain the raw-report digest and mode outcomes.

The first real Move exposed a brief empty result during session retirement: one of six observed migration queries returned zero hits. Files and final metadata were correct, but this attempt failed continuity acceptance. Its [negative receipt](benchmarks/v0.6.3/native-settings-handoff-negative.json) is retained. The old session was stopped before the actor selected its replacement, and dispatched queries also discarded results after seeing that session offline. The fix exposes the validated replacement first, pins dispatched readers until completion, inherits pause reasons before exposure, and keeps the migration state until retirement finishes. Cancellation still permits reader pins to drain. A deterministic gated-query regression fails with two assertions under the old ordering and passes under the fix. Migration progress is reset for each job, keyed by its cancellation token and filtered against late callbacks; no backing/locator/format algorithm was rewritten.

The [native Settings receipt](benchmarks/v0.6.3/native-settings-20261013.json) records actual `Move Index…` / `NSOpenPanel` selection of an owned directory on Data 1, a normal Quit and external warm restart, actual `Use Default Internal Storage`, and another normal Quit and internal warm restart. The source/cache/bundle identities were isolated; daily settings and indexes were untouched. Source and external storage UUIDs differ. Only the selected directory's managed `APFSFindIndexes` subtree was used. All Settings identity, mount, availability, size and space fields were observed. Progress was monotonic, both old copies remain, and immutable namespace/metadata SHA256 values are unchanged.

The owned 12-file fixture contains 13 namespace records. The formal external/internal migrations copied 2,272 bytes in 73.184333/35.762458ms. Every observed migration query retained twelve complete results. All four sorts matched paths, sizes and exact nanosecond mtimes; worst external fixture p95 was 2.225333ms. This small native fixture does not replace the previously recorded 3.189M-record migration or 4.395M-record performance experiment. The external restart selected production `pread`, reached search-ready/Live in 5/223ms, and the default restart selected `mmap` in 5/243ms. Both report zero full scans and zero resource-yield rebuilds, with metadata available/live. Locator sizes were 424 bytes externally and 280 bytes after returning to `defaultInternal`; decimal Date encoding explains why this configuration receipt differs from the earlier 273-byte one.

Production signed executable SHA256: `f73bba073f0cab119c6f42c793b431eedf20580223b2e1ec482b5a4ac811a4f5`. Owned re-signed executable: `e05eca6de2ecf1bc84487b3c3f5d9e4d4af12a840ea7bdd15d4cc7e891384bd5`. CLI: `fc6ec4f1650a2ad2f41cde79831a9bfb0050c4e644e7541ea1d7ad3f9b18f3d1`. The owned executable was unchanged across the reset, formal Move/default sequence and both restarts. Test-only observers emit stdout and are opt-in behind an owned smoke bundle flag; production adds only a backing-kind diagnostic. No tag or release was created.
