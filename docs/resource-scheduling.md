# Resource-aware maintenance (v0.6)

Production sessions share one MaintenanceScheduler. It serializes cold scans,
recovery, namespace compaction, metadata bootstrap and metadata checkpoints.
ResourceSignalProviding is injectable: deterministic tests use FakeResourceSignals;
explicit fixture jobs can use an ungated scheduler. SystemResourceSignals uses
DispatchSourceMemoryPressure and ProcessInfo thermal/power notifications. Its
system CPU counter timer runs every two seconds **only with pending/running work**.
An empty maintenance queue cancels that timer. EWMA alpha is 0.4.

Opportunistic jobs require normal memory pressure, nominal/fair thermal state,
power mode off, no active query, ten seconds of interaction quiet, event queue
<=64, dirty scopes <=16, and CPU idle >=60% for ten seconds. Idle <30% for two
seconds, or <15% immediately, yields at a chunk boundary. Required recovery can
run on a busy system with one worker; interaction and critical memory still yield.
Emergency work proceeds in bounded chunks with a small throttle, even when busy.
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

Correctness overlays survive pressure. Each hot directory cache shrinks to 25%
(minimum 1024) on warning, and root only on critical; no eager refill on normal.
Namespace overlay stops accepting changes at 500k entries or 128 MiB estimated
bytes. Core marks recovery and stops advancing the processed/durable namespace
cursor. Recovery is emergency, using a fresh scan and conservative replay fence.
Metadata overlay similarly stops at its hard bound, pins its cursor and requests
namespace compaction plus metadata recovery. The event inbox and rebuild buffers
retain their existing bounded overflow recovery. A >100k-record atomic subtree
delete/diff goes to recovery rather than monopolizing the writer. Metadata subtree
walks retain bounded pending directories and pause for active queries or critical
pressure. There is no periodic maintenance or full-disk idle scan.

The desktop reports window visibility, input, sorting, paging and file actions.
Active queries are bracketed in the core HybridIndex as well as desktop submission.
A visible but inactive window does not defer maintenance forever. Pressure gauge
samples and scheduler counters are exposed through metrics; no telemetry or log
files are introduced.

Limits: yield restarts a build rather than saving cross-process progress. Recovery
still temporarily constructs the reference FileIndex. Byte limits are conservative
application estimates, separate from Mach physical/internal/external gauges.
