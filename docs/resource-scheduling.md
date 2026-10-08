# Resource-aware maintenance (v0.6)

Production sessions share one MaintenanceScheduler. It serializes cold scans,
recovery, namespace compaction, metadata bootstrap and metadata checkpoints.
ResourceSignalProviding is injectable: deterministic tests use FakeResourceSignals;
explicit fixture jobs can use an ungated scheduler. SystemResourceSignals uses
DispatchSourceMemoryPressure and ProcessInfo thermal/power notifications. Its
system CPU counter timer runs every two seconds **only with pending/running work**.
An empty maintenance queue cancels that timer. EWMA alpha is 0.4. Pending samples also refresh ProcessInfo thermal/power state so CLI jobs do not depend on a main-run-loop notification delivery.

Opportunistic jobs require normal memory pressure, nominal/fair thermal state,
power mode off, no active query, ten seconds of interaction quiet, event queue
<=64, dirty scopes <=16, and CPU idle >=60% for ten seconds. Idle <30% for two
seconds, or <15% immediately, yields at a chunk boundary. Required recovery can
run on a busy system with one worker; interaction and critical memory still yield.
Emergency work proceeds in bounded chunks with a small throttle, even when busy.
Internal pressure is read through per-volume callbacks at decisions/checkpoints, outside the scheduler lock. A drained event storm can therefore unblock queued work without another namespace mutation; stale queue observations do not keep jobs waiting forever. Event IDs are not interpreted as event counts.

Operating states are interactive, busy, opportunistic, maintaining, emergency and
suspended. Deferred jobs stay queued; sampling is therefore intentionally active
while deferred work exists.

Scanners check between getattrlistbulk pages. Namespace generation and emission
check per 4096 records/children; metadata columns per 8192 records and bitmap per
16384. CRC validation checks per 64 KiB and structure validation per 4096 records.
Leases check cancellation, resource state and source identity (at most every
100 ms). Store publication retains its secure-directory checks, atomic rename,
fsync, CRC and final generation/identity checks. Yield unwinds private builds,
discards staging, releases the lease and requeues. It never publishes a partial
base. An existing metadata base remains readable during a retryable rebuild, and
a dirty bootstrap prevents writing a falsely clean metadata cursor.

Correctness overlays survive pressure. Each hot directory cache replaces its storage with at most 2048 MRU entries on warning, and new root-only storage on critical; no eager refill on normal.
After shrinking caches, the C shim asks malloc_zone_pressure_relief to return already freed allocator pages. This is best effort, affects no live objects, and does not replace kernel footprint measurements. A one-shot release also follows completed namespace builds after their temporary frame is released.

Namespace overlay stops accepting changes at 500k entries or 128 MiB estimated
bytes. Core marks recovery and stops advancing the processed/durable namespace
cursor. Recovery is emergency, using a fresh scan and conservative replay fence.
Metadata overlay similarly stops at its hard bound, pins its cursor and requests
namespace compaction plus metadata recovery. Namespace event inbox and rebuild buffers
retain their existing bounded overflow recovery. Ordinary metadata inbox overflow
keeps its event hard cap and repairs the known watched root using bounded directory
slices, without allocating full-volume bootstrap columns. A second overflow while
that frontier is active requests one follow-up pass after the current pass finishes;
the metadata cursor stays pinned through both. Suspension retains only a scalar
repair fence. Real stream invalidation is remembered even if its event was dropped
from the full inbox, and still requests authoritative recovery. A >100k-record atomic subtree
delete/diff goes to recovery rather than monopolizing the writer. Metadata subtree
walks retain bounded pending directories and pause for active queries or critical
pressure. Directory diff/update collection is capped at 100k records and pending directory frontiers at 100k; larger frontiers invalidate and recover. The frontier limit is separate from the 16,384-entry duplicate window. The duplicate window rolls at 16,384 instead of treating a large unchanged tree as a recovery error. Child paths must be direct descendants, so this does not admit filesystem cycles. Metadata bootstrap consumes bulk pages directly instead of accumulating all files in wide directories. There is no periodic maintenance or full-disk idle scan.

The desktop reports window visibility, input, sorting, paging and file actions.
Active queries are bracketed in the core HybridIndex as well as desktop submission.
A visible but inactive window does not defer maintenance forever. The UI shows a short reason while work waits for resource conditions. Hidden result refresh does not reset the interaction quiet period. Pressure gauge
samples and scheduler counters are exposed through metrics; no telemetry or log
files are introduced.

Limits: yield restarts a build rather than saving cross-process progress. Recovery
still temporarily constructs the reference FileIndex. Byte limits are conservative
application estimates, separate from Mach physical/internal/external gauges.

While recovery is scheduled/running, obsolete namespace reconciliation stops and the durable cursor remains pinned. A restarted stream replays from the new pre-scan fence instead of applying old buffered hints to the fresh scan. Its bounded in-process buffer overflow alone does not invalidate a complete fresh replay; actual stream drop flags still request recovery.

Recovered scans are published as namespace v2 plus streamed metadata v1 under the scan maintenance lease before starting replay. The complete scan FileIndex is then released; catching-up queries use mmap rather than retaining a large Swift object graph until HistoryDone. The scan metadata seed is compact, and the namespace generation advances on recovery publication. A one-shot allocator relief follows the completed frame.

Reconciliation checks a mapped directory’s old child count before reconstructing paths (100k cap), even when most old children have disappeared. Its cumulative atomic diff is strictly capped at 100k, including the final directory. A rejected plan publishes no partial mutations and requests fenced recovery.

## v0.6.1 shutdown, diagnostics and strict quiet

Fast shutdown first requests cancellation of active queries, retryable core/metadata maintenance and metadata lookups, before queue barriers. Queued leases are cancelled. Delivered ordinary namespace updates drain; reconciliation interrupted by exit discards its partial plan and pins the conservative cursor for restart replay. A metadata updater barrier cannot begin a new large pending subtree scan after cancellation. Running jobs join at page/chunk checkpoints, retaining old legal bases; already-entered atomic publication may finish its short critical section. State-only writes do not serialize the dirty overlay. A second stop joins the same shutdown rather than creating another teardown.

Per-volume metrics report query cancellation, watcher stop, namespace drain, metadata updater, maintenance cancellation, both maintenance group waits, state write, session teardown and total wall time. The multi-volume total includes all volume stops. CLI `APFSFIND_SHUTDOWN_METRICS=1` emits a quit-request timestamp separately, allowing command backlog to be distinguished from actual engine teardown.

Maintenance records retain kind/volume/urgency, queued/running time, checkpoints, yields/restarts, progress counters, peak gauges and termination reasons. CPU/I/O are **overlapping process intervals**, not exclusive per-task accounting; concurrent namespace/metadata work contributes to each interval and totals must not be summed. Repeated yielded/no-progress attempts use capped exponential one-shot backoff (1–30 seconds); emergency correctness bypasses the delay. Empty queues cancel the backoff timer and CPU sampler. Unmarked releases are reported honestly rather than assumed completed.

Metadata parent enumeration now uses the same local-error policy as subtree reconciliation: descendant permission/dataless failures preserve known values, ordinary disappearance/boundary races do not invalidate an entire sidecar, and root/unexpected I/O failures still request recovery. Query/pressure yields keep deferred parents and do not advance the metadata cursor. Errno, recovery-request and yield counters expose these causes.

Only an explicitly prepared smoke bundle polls the strict quiet gate. All volumes must be namespace live and metadata live, with no event/batch/metadata pending work, no scheduled compaction/metadata jobs, no queued/running maintenance, and 30 seconds of unchanged namespace/metadata generations. The deadline remains 20 minutes. Timeout emits blockers plus queues, tasks, overlays and cursors; it never starts or labels an idle measurement. A passing gate starts a hidden 600-second window, with a 60-second CPU checkpoint and final generation/resource checks. Benchmark captures live inside its excluded owned cache so their own stdout writes do not manufacture new filesystem events. Production has no such polling or capture files.

Metadata overlay accounting tracks retained overrides, delta values and tombstones, subtracting allocations on delete/recreate. The unchanged 500k-entry/128-MiB hard cap applies to net growth, so replacing an existing value at capacity remains possible. Diagnostics expose estimated and accounted bytes plus the overflow flag. A queued automatic metadata bootstrap is superseded only when a different namespace base has published valid metadata and no recovery remains pending or metadata overflow occurred before/during the queued wait. A monotonic overflow epoch survives namespace binding, because compaction copies known columns without repairing dropped values; explicit user rebuilds keep their force flag across yielded retries.


Ordinary metadata parent refresh also yields after at most 32 parents or 20 ms, retaining unstarted requested paths and genuinely collapsed parents. Pure budget continuation uses a short one-shot delay; rate limiting and read failures retain their original backoff. Event classification retires Foundation temporaries per event. Neither budget continuation advances the cursor through unfinished refresh.

The v0.6.2 owned real-volume smoke uses a separate fixed 20-minute active-live gate: real generations may change, but full scans, resource-yield rebuilds, restart loops, monotonically growing backlogs and unfinished deadline maintenance fail. Physical footprint above 150 MiB remains a failure; startup lifetime peaks are reported separately and never substituted for active samples. Controlled quiet still requires the original 60-second CPU/write/timer checks.
