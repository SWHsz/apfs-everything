#ifndef CAPFS_SHIM_H
#define CAPFS_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum APFSObjectType {
    APFS_OBJECT_FILE = 1,
    APFS_OBJECT_DIRECTORY = 2,
    APFS_OBJECT_SYMLINK = 3,
    APFS_OBJECT_OTHER = 4
};

typedef struct APFSDirectoryEntry {
    /* Name bytes are owned by the reader, valid until the next read/close. */
    const char *name;
    size_t name_length;
    uint64_t device_id;
    uint64_t file_id;
    uint32_t object_type;
    int has_file_id;
    int is_mount_point;
    int error_code;
    uint64_t logical_size;
    int64_t mtime_seconds;
    int32_t mtime_nanoseconds;
    uint8_t has_size;
    uint8_t has_mtime;
} APFSDirectoryEntry;

typedef struct APFSDirectoryInfo {
    uint64_t device_id;
    uint64_t file_id;
    int64_t mtime_seconds;
    int64_t mtime_nanoseconds;
} APFSDirectoryInfo;

typedef struct APFSVolumeInfo {
    uint64_t device_id;
    uint64_t root_file_id;
    uint8_t volume_uuid[16];
    char mount_point[4096];
} APFSVolumeInfo;

int apfs_volume_info(const char *root, APFSVolumeInfo *info);
typedef struct APFSProcessResources {
    uint64_t disk_bytes_read;
    uint64_t disk_bytes_written;
    uint64_t logical_bytes_written;
    uint64_t physical_footprint;
    uint64_t peak_physical_footprint;
    uint64_t idle_wakeups;
    uint64_t interrupt_wakeups;
    uint64_t pageins;
    uint64_t compressed_bytes;
    uint64_t peak_compressed_bytes;
    uint64_t internal_resident_bytes;
    uint64_t external_resident_bytes;
    int memory_info_valid;
} APFSProcessResources;
/* Actual per-process counters from the SDK's rusage_info_v4, no estimates. */
int apfs_process_resources(APFSProcessResources *output);
typedef struct APFSCPUCounter {
    uint32_t user, system, nice, idle;
} APFSCPUCounter;
int apfs_system_cpu(APFSCPUCounter *output);
/* Best-effort release of already freed allocator pages after cache pressure. */
size_t apfs_release_allocator_pages(void);
/* Incremental IEEE CRC32, pass 0 for the first chunk. */
uint32_t apfs_crc32(uint32_t previous, const void *bytes, size_t length);
/* Component-wise O_NOFOLLOW cache directory walk. Creates only when requested. */
int apfs_open_cache_directory(const char *path, int create);

typedef struct APFSBulkReader APFSBulkReader;

/* Returns 0 if denied, 1 when the SDK lacks support, -1 on policy failure. */
int apfs_deny_dataless_materialization(void);

/* Before realpath/root resolution: set best-effort thread policy and reject
 * cached nonlocal/autofs mounts without opening anything. Absolute path only.
 * Does not resolve symlink components; their targets need a separate check. */
int apfs_prepare_root_path(const char *absolute_path);

/* Resolves an explicitly requested root with metadata-only component walks.
 * Checks mount boundaries before symlink targets, rejects dataless directories,
 * and resolves at most 40 links. No realpath() or file-content reads. */
int apfs_resolve_local_root(const char *absolute_path, char *output, size_t capacity);

/* Absolute paths only. Every component is opened with O_NOFOLLOW. */
APFSBulkReader *apfs_bulk_reader_open(const char *path, uint64_t expected_device,
                                    int enforce_device, int *error_code);
/* Returns 0 on success (count == 0 means EOF), -1 with errno on failure. */
int apfs_bulk_reader_next(APFSBulkReader *reader,
                          const APFSDirectoryEntry **entries, size_t *count);
int apfs_bulk_reader_close(APFSBulkReader *reader);

/* Metadata only; secure component walk has the same boundaries as enumeration. */
int apfs_entry_info(const char *path, uint64_t expected_device, APFSDirectoryEntry *info);
/* Bounded microbatch: one secure parent open; metadata only, no content fd. */
int apfs_metadata_batch(const char *parent, uint64_t expected_device,
                        const char *const *names, size_t count, APFSDirectoryEntry *entries);
int apfs_directory_info(const char *path, uint64_t expected_device,
                        int enforce_device, APFSDirectoryInfo *info);

#ifdef __cplusplus
}
#endif
#endif
