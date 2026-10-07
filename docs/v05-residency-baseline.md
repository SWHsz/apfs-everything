# v0.5 residency baseline

Source anchor: `9295470152dbb4dd309d2582611111f01ea2074b`. The original runtime was measured by a diagnostic build with extra process counters and a read-only CLI probe; it retained both original full directory maps. Baseline source was also independently archived and passed all 196 ordinary, ASan and TSan tests (one optional mount skip), release app build and codesign verification. Its existing CI is https://github.com/SWHsz/apfs-everything/actions/runs/37558381259 (four successful jobs).

[Aggregate report](benchmarks/v0.6.0/v05-residency.json): 3,308,277 + 1,615,001 records; 551,518 + 79,461 directories. Namespace bytes 439,850,047; metadata bytes 80,003,813. Both maps each estimated at 119,772,703 bytes, combined 239,545,406 bytes, with estimates labelled independently from system counters.

Existing daily snapshots were opened read-only; missing metadata was built in owned scratch using the v0.5 builder. No live stream or daily cache mutation was involved. Entries may be stale, so this diagnoses residency rather than namespace freshness. The measurement includes both selected source volumes and metadata; scope was not reduced to lower memory.

After loading: physical footprint 543,229,416 bytes. After 600 seconds idle: 317,031,864 bytes footprint, 315,768,832 compressed bytes, 5,832,704 RSS bytes. After 30 broad queries: 317,162,936 bytes footprint and 427,540,480 RSS bytes. Compression explains why RSS alone is misleading. Idle CPU 0.001130 seconds, physical disk writes 0, logical writes 20,480 bytes, idle wakeups 0 and interrupt wakeups 2; nonzero counters remain in the report.

TASK_VM_INFO reports internal/external resident and compressed bytes; rusage_info_v4 provides physical and peak footprint and I/O counters. A separate private/anonymous ledger and dirty-private-page count are unavailable and are not fabricated. A vmmap summary of the owned baseline process separately observed 302.3 MiB physical footprint and 291.4 MiB malloc allocated bytes.
