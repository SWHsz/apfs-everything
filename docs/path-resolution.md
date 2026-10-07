# Bounded path resolution

Persistent namespace and metadata keep no full directory-path map. `PathResolverSnapshot` pins the immutable mmap base and COW snapshots of tombstones and changed children. It starts at root and looks up each component in a parent-`EntryRef` overlay table, then the mapped child ordinal table. File/symlink and mount boundaries cannot be traversed. Base child lookup binary-searches individual mapped names without building all siblings. Explicit `children` enumeration remains available for reconciliation and snapshot generation.

`EntryRef.base(UInt32)` and `.delta(UInt32)` identify parents. Changed entries may retain complete paths and basename strings; immutable base entries do not. Deleting a directory tombstones its base subtree and removes only affected delta children. Type replacements remove the old subtree before creating children under the replacement parent. Base swaps reset overlays and cache epochs. Root identity is a snapshot invariant and is replaced through recovery.

The namespace resolver and metadata's pinned-base resolver share this implementation. Metadata must be able to resolve an original base path after namespace deletion in order to pair rename events, so it deliberately pins the base lookup view rather than borrowing mutable namespace refs. Neither captures nor rename sources copy an all-directory path dictionary.

Each resolver owns a strictly bounded hot directory cache: default 8,192 entries, minimum 1,024, maximum 16,384. Values are scalar refs. An O(1) linked LRU evicts entries, and directory prefixes/base swaps invalidate cached refs. Cache versions combine base UUID and generation; older captures cannot insert into a newer epoch. Parent cache hits avoid repeated walks for sibling file changes. Namespace mutations conservatively reset the epoch; this favors correctness over retaining every hit across changes.

Warning pressure shrinks the cache to 25% or 1,024. Critical pressure leaves only root. Normal pressure restores capacity without pre-populating entries. Counts, estimated bytes and hit/miss/eviction counters are observable. Application estimates remain distinct from kernel memory gauges.

Public namespace entry lookups capture under a short lock, resolve outside it and retry once if the base/generation changed. Strong references keep old mappings valid for point-in-time queries and compaction captures. Metadata updates also resolve outside its mutation lock. Search scans immutable name blobs and reads metadata only for matched candidates; it never reconstructs a full-path map.

Namespace and metadata validators still fully check CRC/layout/structure. They unmap the validation view and create a fresh read-only runtime view on the same pinned descriptor. No full metadata column warming is requested. Reclaim advice is optional and not used for correctness; initial real-disk measurements found `MADV_DONTNEED` did not immediately lower RSS. Most query RSS is file-backed, so RSS is reported together with internal resident, compressed bytes and physical footprint.

The namespace v2 and metadata v1 disk layouts are unchanged. Streaming metadata writing and compact build buffers are documented in `metadata-index.md`; resource and alias safety are covered by the next milestone.
