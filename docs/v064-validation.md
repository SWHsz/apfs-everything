# v0.6.4 — Disk-backed cold and recovery construction

Phase A closed #2 before this implementation began. [Native Settings Move/default receipt](benchmarks/v0.6.3/native-settings-20261013.json) covers two normal Quit/warm restarts, all twelve fixture paths/exact sizes/nanosecond times/four sorts, unchanged hashes and retained rollback copies. External/default backing is pread/mmap, both warm startups have zero full scans and resource-yield rebuilds, locator returns to defaultInternal (280 bytes). The preceding large real-data migration and performance receipts remain separate. [Phase A HEAD CI](https://github.com/SWHsz/apfs-everything/actions/runs/38337724572) and its roadmap-only follow-up passed all four jobs. No tag or Release.

## Implementation

PersistentIndexCoordinator supplies a sealed disk build to UpdateCoordinator. Its default cold/recovery path does not call BulkScanner.scan, makePrivateIndex, FileIndex.metadataSeed or SnapshotV2Writer's RAM exporter. Ephemeral and standalone reference/test paths retain FileIndex. Existing compaction planning and explicit full verify are outside this change.

BulkStreamingDirectorySource uses the safe getattrlistbulk reader's throwing page visitor. Each directory page sorts by the existing folded/raw UTF8/kind ordering. Binary external merging retains at most 64 run descriptors and two 16KiB heads. Duplicate raw-name hints caused by a changing enumeration are compacted within and across runs; replay remains authoritative for their current type/metadata. A failed partial directory becomes an empty directory listing (root failure remains fatal). Mount boundaries and symlinks remain leaf records.

Sorted listings go to a shared disk spool; DFS frames retain an ordinal, canonical current path, child slot and 16KiB cursor buffer. The builder appends records, original/folded names, child ordinals, size/time columns and a two-bit validity bitmap to separate files. Parent child slots are reserved before descent; closing a subtree pwrite-patches its end. Child record ordinals themselves follow preorder, preserving existing v2 contiguous subtrees. No global path/ordinal map, reference array, record array or full Data payload is built.

SnapshotBuildWorkspace creates an exclusive owned 0700 directory on the selected SnapshotStore volume. Fixed sections are 0600, exclusive/no-follow and pinned by descriptors. An owner-lock excludes active workspaces from stale cleanup. Cleanup only unlinks its allowlisted sections; unknown files are retained. Paths/inodes/storage are checked during work and before publication. Writes, allocation, cancellation and storage errors abort the workspace.

Assembly copies sections through bounded 1MiB chunks (64KiB under warning), computes incremental CRCs, writes existing footers and backpatches the existing headers, fsyncs and fully validates both readonly files. Namespace v2 and metadata v1 remain byte-compatible. Internal storage uses existing mmap validation/readers; external/unknown storage uses bounded pread throughout. Unicode Foundation folding in both validators drains its temporary autorelease objects immediately. Both full validators use an ancestor stack for path-length checks; the mmap validator no longer allocates a UInt32 length for every record.

The final writer transaction renames the two already validated inodes under the existing per-root flock. Ordinary rename/fsync failures restore both previous names. Query captures retain previous readers until completion. This is not a new multi-file crash journal: a crash between the two renames can leave a complete namespace with a mismatched optional sidecar; the existing base-UUID binding rejects that sidecar and rebuilds metadata. Partial columns/namespace files are never accepted.

## Events and resource policy

Cold captures E0 before enumeration. Recovery captures a pre-enumeration fence, retains the old searchable base and bounded event buffers, and restarts the journal stream at that fence after publication. HistoryDone establishes Live; recent live events can still be inside FSEvents’ delivery latency window, so integration acceptance waits for actual mutation convergence as well. Historical buffered hints are not blindly applied to a newer scan; the journal replay closes that gap using the existing recovery protocol. Failure/cancellation does not advance the old durable cursor.

A StreamingBuildMaintenance lease spans the build and final installation. Yield releases/reacquires the scheduler lease while preserving workspace, traversal, fence and recovery epoch. Checkpoints run each directory page, each 4096-record CPU chunk and bounded copy/CRC chunks, with work-time checks at about 50ms. Required first build/recovery uses one DFS worker even when CPU is busy. Opportunistic scheduler requests wait on CPU/Low Power gates. Query activity and serious/critical thermal state yield on notifications; critical memory pressure cancels safely. Warning shrinks section buffers. No permanent maintenance timer is introduced; SystemResourceSignals samples CPU only while scheduler work is queued/running.

## Correctness and failure coverage

New tests cover real mixed trees against the retained RAM SnapshotV2Writer oracle (record fields/paths/folded names/columns), NFC and NFD in distinct APFS parents, symlinks, a 100-level tree, 100k-wide equivalent directory pages, boundary/permission/partial-page failures, duplicate race hints, active/stale workspace cleanup, cancellation, ENOSPC injection, damaged staging, publication rollback and latched external I/O failure. Actual FSEvents tests mutate create/delete/rename/content after enumeration and during recovery, then verify exact final namespace/size. Captured old readers remain valid after the new base publishes; successful recovery and subsequent warm restart verify with zero startup scans. Query/thermal yield retains the same workspace/fence; critical cancellation retains the old base/cursor.

Actual forced-removal coverage uses an owned disposable APFS sparse image and the production PersistentIndexCoordinator with explicit equivalent 65,537-record pages, pausing after sections to place removal before assembly. Cold stops on a structured workspace-identity validation failure after detach, and recovery reports structured storage-offline with child exit0; after reattachment immutable hashes must be unchanged (no cold base, old recovery pair). This supplements the existing nine-mode production storage probes, not a physical SSD power-loss test.

CI at `dc411` exposed ordinary assertion failures in the ASan job (no ASan memory error report): a multi-volume readiness timeout and immediate recovery verification before live mutation delivery. A deterministic subscription test proves the old observer loses the last update if it races with initial snapshot capture. The observer now subscribes first and serializes initial/update delivery; the recovery test waits for actual create/delete/rename convergence. The old observer fails the regression and the fix passes. Failed CI and earlier benchmark receipts remain distinguishable from final acceptance. [Regression receipt](benchmarks/v0.6.4/ci-regressions.json), [failed run](https://github.com/SWHsz/apfs-everything/actions/runs/38342143303).

The final runtime’s first CI attempt subsequently failed thirteen real-event methods, including unchanged RAM-only BurstIntegrationTests; there was no ASan memory report, and a test’s later force-unwrap trapped after convergence assertions failed. The identical HEAD’s failed job was rerun once and the entire ASan suite passed (all four required jobs green). The initial failure is retained; runner/event-service causation is not proven. No tests were skipped or assertions weakened for this retry.

## Measurements and reproduction

Final candidate local release/app/signature, actual APFS removal and all 359 ordinary/ASan/TSan tests (335 Core + 24 Desktop, one optional mount skip) pass. All four required runtime jobs passed at [38344287117 attempt 2](https://github.com/SWHsz/apfs-everything/actions/runs/38344287117/attempts/2). [Final checks and binary receipt](benchmarks/v0.6.4/final-checks.json) pins the measured release binaries and log digests. Documentation HEAD CI is recorded in the Issue #13 closeout. No local build/test overlaps the formal resource measurements. Each cold/reference/recovery measurement starts in a fresh process. Synthetic pages model 4096-file directories with one percent Unicode names, exact deterministic metadata and no content reads; they do not measure real filesystem enumeration throughput. The explicit RAM comparison is a lower bound on the old path because it does not additionally retain BulkScanner's full ScanResult array. RSS includes reclaimable mapped validation/query pages; physical footprint and internal/compressed gauges are reported separately.

```bash
swift build -c release -j 4
.build/release/apfsfind cold-build-bench --entries 1000000
.build/release/apfsfind cold-build-bench --entries 3000000
.build/release/apfsfind cold-build-bench --entries 1000000 --reference
.build/release/apfsfind cold-build-bench --entries 3000000 --reference
.build/release/apfsfind recovery-build-bench
python3 scripts/probe_streaming_storage.py --cli .build/release/apfsfind
swift test -j 4
swift test -j 4 --sanitize=address
swift test -j 4 --sanitize=thread
bash scripts/build_app.sh
codesign --verify --deep --strict dist/APFSFind.app
```

Both new benchmark commands emit final-line JSON. Source/cache are process-owned temporary directories and are removed after readers stop. The APFS driver retains its report/image for audit and only detaches its owned image. No user daily index/settings migration or temp-root purge is performed.


## Final candidate resource receipts

Runtime `26c8d3ef354e541ced1074305db5d5ccb51f4c3e`; release CLI SHA256 `bc633a0e2d65e1931ff15ce5d2275dd7a472d80a0bc68a922d0ac9d21f06ed9b`; signed Desktop SHA256 `4db12f634d83f76e14b6d9ff140bdebe0be157ae1f2d16681ff8f24375e76aba`.

| Equivalent records | Streaming physical peak MiB | Peak RSS MiB | Workspace logical peak MiB | Final pair MiB | Streaming wall s | RAM reference wall s | Wall ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1M | 6.63 | 92.44 | 254.24 | 93.72 | 9.211 | 10.438 | 0.882 |
| 3M | 6.47 | 249.23 | 762.71 | 281.16 | 27.249 | 31.554 | 0.864 |

1M: workspace allocated peak 284,991,488 bytes, final pair 98,271,199 bytes; section logical writes 476,553,602, process logical/disk writes 488,846,664/244,506,624 bytes, throughput 108,572 records/s. RAM reference physical peak 550.58MiB. [Streaming receipt](benchmarks/v0.6.4/cold-1m.json), [reference](benchmarks/v0.6.4/reference-1m.json).

3M: workspace allocated peak 831,803,392 bytes, final pair 294,812,402 bytes; section logical writes 1,429,659,026, process logical/disk writes 1,466,469,356/761,634,816 bytes, throughput 110,097 records/s. RAM reference physical peak 1622.05MiB. [Streaming receipt](benchmarks/v0.6.4/cold-3m.json), [reference](benchmarks/v0.6.4/reference-3m.json).

3M recovery: build/replay 27.900s (whole process including initial cold 55.427s); physical peak 7.55MiB, RSS peak 420.62MiB. All 213 sampled queries returned the expected path; maximum 26.839ms. Retained old reader remains valid after publication, zero materialized FileEntry graph. Recovery logical/disk writes 1,464,249,324/772,284,416 bytes. [Recovery receipt](benchmarks/v0.6.4/recovery-3m.json).

Both 500MiB hard and 300MiB stretch physical gates pass. Mapped pages explain entry-dependent RSS; they are reclaimable and are not a private Swift graph. Small physical-peak differences include allocator/VM behavior; two scales are evidence, not a mathematical bound for every filename distribution. The workspace peak includes staged final files; do not add the final pair again for a cold build. Recovery additionally retains the old final pair until publication (about 1.095GB logical storage for this 3M case). I/O counters are process/kernel measurements, not SSD wear or a guarantee that every cached write reached physical media by the sample. Wider directories require more scratch merge I/O; real source enumeration latency is not claimed by these equivalent-page timings.

[Actual APFS forced-removal receipt](benchmarks/v0.6.4/forced-removal.json): cold/recovery children exit0, detach/reattach/cleanup exit0, immutable hashes unchanged; no cold partial base, old recovery pair retained. Historical first-measurement receipts and the preflight script's incorrect executable-name failure remain local, separate from these final candidate measurements.

## Delivery and remaining limits

Started at `68ae8998fcaf1848b2b83943fe661353711b5743`. Phase A #2 was closed before #13 implementation. #13 and roadmap #12 track this builder; final publication HEAD/CI and closure are recorded in [Issue #13](https://github.com/SWHsz/apfs-everything/issues/13). No tag/Release and no changes to the user’s daily locator/index. Namespace v2 / metadata v1 and their existing count/name/blob/path limits remain. Explicit full verify and existing compaction planning can still allocate O(N) data; this sprint bounds default persistent cold/recovery and validation. Pair publication is individually atomic with ordinary-error rollback and mismatched-sidecar recovery, not a crash-atomic multi-file journal. Performance gates use equivalent paged records; actual filesystem tests and APFS detach are separate.
