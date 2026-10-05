#include "CAPFSShim.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#define APFS_BULK_BUFFER_SIZE (64u * 1024u)

struct APFSBulkReader {
    int fd;
    uint64_t device_id;
    unsigned char *buffer;
    APFSDirectoryEntry *entries;
    size_t entry_capacity;
};

static int close_preserving_error(int fd, int error) {
    int result = close(fd);
    if (error == 0 && result < 0) error = errno;
    errno = error;
    return -1;
}

static int path_is_at_or_below(const char *path, const char *ancestor) {
    size_t length = strlen(ancestor);
    return strncmp(path, ancestor, length) == 0 &&
        (path[length] == '\0' || path[length] == '/' ||
         (length == 1 && ancestor[0] == '/'));
}

/* MNT_NOWAIT reads cached mount metadata; never contact a network filesystem. */
static int reject_nonlocal_mount(const char *path) {
    int count = getfsstat(NULL, 0, MNT_NOWAIT);
    if (count < 0) return -1;
    if (count == 0) return 0;
    if ((size_t)count > (size_t)INT_MAX / sizeof(struct statfs)) {
        errno = EOVERFLOW;
        return -1;
    }
    struct statfs *mounts = calloc((size_t)count, sizeof(*mounts));
    if (!mounts) { errno = ENOMEM; return -1; }
    int actual = getfsstat(mounts, count * (int)sizeof(*mounts), MNT_NOWAIT);
    if (actual < 0) { int error = errno; free(mounts); errno = error; return -1; }
    if (actual > count) actual = count; /* A mount added between the two calls. */
    int reject = 0;
    for (int i = 0; i < actual; ++i) {
        if (((mounts[i].f_flags & MNT_LOCAL) == 0 ||
             strcmp(mounts[i].f_fstypename, "autofs") == 0) &&
            path_is_at_or_below(path, mounts[i].f_mntonname)) {
            reject = 1;
            break;
        }
    }
    free(mounts);
    if (reject) { errno = EXDEV; return -1; }
    return 0;
}

int apfs_prepare_root_path(const char *absolute_path) {
    /* Policy failure is intentionally nonfatal: this is a best-effort knob. */
    int policy_result = apfs_deny_dataless_materialization();
    if (policy_result < 0) {
        /* Continue the mount preflight; metadata APIs never read file contents. */
    }
    if (!absolute_path || absolute_path[0] != '/') { errno = EINVAL; return -1; }
    size_t length = strlen(absolute_path);
    if (length >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }

    /* Check lexical aliases too, e.g. /private/tmp/../../net must not slip past
     * the cached mount prefix check before a caller subsequently uses realpath. */
    char components[PATH_MAX];
    char normalized[PATH_MAX] = "/";
    memcpy(components, absolute_path, length + 1);
    size_t used = 1;
    char *save = NULL;
    for (char *component = strtok_r(components, "/", &save); component;
         component = strtok_r(NULL, "/", &save)) {
        if (!strcmp(component, ".")) continue;
        if (!strcmp(component, "..")) {
            if (used > 1) {
                while (used > 1 && normalized[used - 1] != '/') --used;
                if (used > 1) --used;
                normalized[used] = '\0';
            }
            continue;
        }
        size_t component_length = strlen(component);
        size_t separator = used > 1 ? 1 : 0;
        if (component_length >= PATH_MAX - used - separator) {
            errno = ENAMETOOLONG; return -1;
        }
        if (separator) normalized[used++] = '/';
        memcpy(normalized + used, component, component_length);
        used += component_length;
        normalized[used] = '\0';
        /* Inspect each walked prefix too: /network/../local would cause
         * realpath to touch the network prefix even though its result is local. */
        if (reject_nonlocal_mount(normalized) < 0) return -1;
    }
    return reject_nonlocal_mount(normalized);
}

static int reject_dataless_directory(const struct stat *metadata) {
    uint32_t dataless_mask = 0;
#if defined(UF_DATALESS)
    dataless_mask |= UF_DATALESS;
#endif
#if defined(SF_DATALESS)
    dataless_mask |= SF_DATALESS;
#endif
    if (S_ISDIR(metadata->st_mode) && (metadata->st_flags & dataless_mask)) {
        errno = ENODATA;
        return -1;
    }
    return 0;
}

static int append_component(const char *parent, const char *component,
                            char *result, size_t capacity) {
    size_t parent_length = strlen(parent);
    size_t component_length = strlen(component);
    size_t separator = parent_length > 1 ? 1 : 0;
    if (parent_length >= capacity || separator >= capacity - parent_length ||
        component_length >= capacity - parent_length - separator) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(result, parent, parent_length);
    size_t used = parent_length;
    if (separator) result[used++] = '/';
    memcpy(result + used, component, component_length + 1);
    return 0;
}

int apfs_resolve_local_root(const char *absolute_path, char *output, size_t capacity) {
    if (!output || capacity == 0) { errno = EINVAL; return -1; }
    output[0] = '\0';
    if (apfs_prepare_root_path(absolute_path) < 0) return -1;
    char pending[PATH_MAX];
    char resolved[PATH_MAX] = "/";
    memcpy(pending, absolute_path, strlen(absolute_path) + 1);
    unsigned int symlinks = 0;
    while (pending[0]) {
        size_t leading = strspn(pending, "/");
        if (leading) memmove(pending, pending + leading, strlen(pending + leading) + 1);
        if (!pending[0]) break;
        size_t length = strcspn(pending, "/");
        if (length > NAME_MAX) { errno = ENAMETOOLONG; return -1; }
        char component[NAME_MAX + 1];
        memcpy(component, pending, length);
        component[length] = '\0';
        size_t consumed = length + (pending[length] == '/' ? 1 : 0);
        memmove(pending, pending + consumed, strlen(pending + consumed) + 1);
        if (!strcmp(component, ".")) continue;
        if (!strcmp(component, "..")) {
            size_t used = strlen(resolved);
            if (used > 1) {
                while (used > 1 && resolved[used - 1] != '/') --used;
                if (used > 1) --used;
                resolved[used] = '\0';
            }
            continue;
        }
        char candidate[PATH_MAX];
        if (append_component(resolved, component, candidate, sizeof(candidate)) < 0) return -1;
        if (reject_nonlocal_mount(candidate) < 0) return -1;
        struct stat metadata;
        if (lstat(candidate, &metadata) < 0) return -1;
        if (S_ISLNK(metadata.st_mode)) {
            if (++symlinks > 40) { errno = ELOOP; return -1; }
            char target[PATH_MAX];
            ssize_t count = readlink(candidate, target, sizeof(target) - 1);
            if (count < 0) return -1;
            if (count == 0) { errno = EIO; return -1; }
            if ((size_t)count >= sizeof(target) - 1) { errno = ENAMETOOLONG; return -1; }
            target[count] = '\0';
            char target_absolute[PATH_MAX];
            if (target[0] == '/') {
                memcpy(target_absolute, target, (size_t)count + 1);
            } else if (append_component(resolved, target, target_absolute,
                                        sizeof(target_absolute)) < 0) return -1;
            // Reject a remote target before lstat ever follows its components.
            if (apfs_prepare_root_path(target_absolute) < 0) return -1;
            size_t rest_length = strlen(pending);
            size_t separator = rest_length > 0 ? 1 : 0;
            if ((size_t)count + separator + rest_length >= sizeof(pending)) {
                errno = ENAMETOOLONG; return -1;
            }
            char rest[PATH_MAX];
            memcpy(rest, pending, rest_length + 1);
            memcpy(pending, target, (size_t)count);
            size_t used = (size_t)count;
            if (separator) pending[used++] = '/';
            memcpy(pending + used, rest, rest_length + 1);
            if (target[0] == '/') { resolved[0] = '/'; resolved[1] = '\0'; }
            continue;
        }
        if (!S_ISDIR(metadata.st_mode)) { errno = ENOTDIR; return -1; }
        if (reject_dataless_directory(&metadata) < 0) return -1;
        memcpy(resolved, candidate, strlen(candidate) + 1);
    }
    struct stat metadata;
    if (reject_nonlocal_mount(resolved) < 0 || lstat(resolved, &metadata) < 0) return -1;
    if (!S_ISDIR(metadata.st_mode)) { errno = ENOTDIR; return -1; }
    if (reject_dataless_directory(&metadata) < 0) return -1;
    size_t length = strlen(resolved);
    if (length >= capacity) { errno = ENAMETOOLONG; return -1; }
    memcpy(output, resolved, length + 1);
    return 0;
}

static int secure_directory_open(const char *path, uint64_t expected_device,
                                 int enforce_device, struct stat *metadata) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    if (strlen(path) >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }
    if (reject_nonlocal_mount(path) < 0) return -1;

    int fd;
    do { fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW); }
    while (fd < 0 && errno == EINTR);
    if (fd < 0) return -1;

    struct stat root_metadata;
    if (fstat(fd, &root_metadata) < 0) return close_preserving_error(fd, errno);
    if (reject_dataless_directory(&root_metadata) < 0)
        return close_preserving_error(fd, errno);

    char components[PATH_MAX];
    memcpy(components, path, strlen(path) + 1);
    char *save = NULL;
    for (char *component = strtok_r(components, "/", &save); component;
         component = strtok_r(NULL, "/", &save)) {
        if (!strcmp(component, ".") || !strcmp(component, ".."))
            return close_preserving_error(fd, EINVAL);
        struct stat child_metadata;
        if (fstatat(fd, component, &child_metadata, AT_SYMLINK_NOFOLLOW) < 0)
            return close_preserving_error(fd, errno);
        if (!S_ISDIR(child_metadata.st_mode))
            return close_preserving_error(fd, S_ISLNK(child_metadata.st_mode) ? ELOOP : ENOTDIR);
        if (reject_dataless_directory(&child_metadata) < 0)
            return close_preserving_error(fd, errno);
        int next;
        do { next = openat(fd, component,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW); }
        while (next < 0 && errno == EINTR);
        if (next < 0) return close_preserving_error(fd, errno);
        if (close(fd) < 0) {
            int error = errno;
            return close_preserving_error(next, error);
        }
        fd = next;
    }

    struct statfs filesystem;
    if (fstatfs(fd, &filesystem) < 0) return close_preserving_error(fd, errno);
    if (!(filesystem.f_flags & MNT_LOCAL) ||
        strcmp(filesystem.f_fstypename, "autofs") == 0)
        return close_preserving_error(fd, EXDEV);
    if (fstat(fd, metadata) < 0) return close_preserving_error(fd, errno);
    uint64_t device = (uint64_t)(uint32_t)metadata->st_dev;
    if (enforce_device && device != expected_device)
        return close_preserving_error(fd, EXDEV);
    return fd;
}

/* Metadata-only final-component lookup; all ancestors are securely opened. */
int apfs_entry_info(const char *path, uint64_t expected_device, APFSDirectoryEntry *info) {
    if (!path || !info || path[0] != '/' || strlen(path) >= PATH_MAX) { errno = EINVAL; return -1; }
    char parent[PATH_MAX]; memcpy(parent, path, strlen(path) + 1);
    char *slash = strrchr(parent, '/');
    if (!slash || !slash[1]) { errno = EINVAL; return -1; }
    char name[NAME_MAX+1];
    if (strlen(slash+1) > NAME_MAX) { errno = ENAMETOOLONG; return -1; }
    strcpy(name,slash+1);
    if (slash == parent) slash[1] = 0; else *slash = 0;
    (void)apfs_deny_dataless_materialization();
    struct stat st;
    int fd = secure_directory_open(parent, expected_device, 1, &st);
    if (fd < 0) return -1;
    if (fstatat(fd,name,&st,AT_SYMLINK_NOFOLLOW) < 0) return close_preserving_error(fd,errno);
    memset(info,0,sizeof(*info));
    info->device_id = (uint64_t)(uint32_t)st.st_dev; info->file_id = (uint64_t)st.st_ino; info->has_file_id = 1;
    info->object_type = S_ISDIR(st.st_mode) ? APFS_OBJECT_DIRECTORY : S_ISREG(st.st_mode) ? APFS_OBJECT_FILE : S_ISLNK(st.st_mode) ? APFS_OBJECT_SYMLINK : APFS_OBJECT_OTHER;
    info->is_mount_point = info->device_id != expected_device;
    return close(fd);
}

int apfs_directory_info(const char *path, uint64_t expected_device,
                        int enforce_device, APFSDirectoryInfo *info) {
    if (!info) { errno = EINVAL; return -1; }
    struct stat metadata;
    int fd = secure_directory_open(path, expected_device, enforce_device, &metadata);
    if (fd < 0) return -1;
    info->device_id = (uint64_t)(uint32_t)metadata.st_dev;
    info->file_id = (uint64_t)metadata.st_ino;
    info->mtime_seconds = metadata.st_mtimespec.tv_sec;
    info->mtime_nanoseconds = metadata.st_mtimespec.tv_nsec;
    return close(fd);
}

APFSBulkReader *apfs_bulk_reader_open(const char *path, uint64_t expected_device,
                                    int enforce_device, int *error_code) {
    if (!error_code) { errno = EINVAL; return NULL; }
    *error_code = 0;
    struct stat metadata;
    int fd = secure_directory_open(path, expected_device, enforce_device, &metadata);
    if (fd < 0) { *error_code = errno; return NULL; }
    APFSBulkReader *reader = calloc(1, sizeof(*reader));
    if (!reader) { close_preserving_error(fd, ENOMEM); *error_code = errno; return NULL; }
    reader->buffer = malloc(APFS_BULK_BUFFER_SIZE);
    if (!reader->buffer) {
        free(reader);
        close_preserving_error(fd, ENOMEM);
        *error_code = errno;
        return NULL;
    }
    reader->fd = fd;
    reader->device_id = (uint64_t)(uint32_t)metadata.st_dev;
    return reader;
}

/* memcpy keeps every load safe even when the kernel's 4-byte layout is unaligned. */
static int consume(const unsigned char **cursor, const unsigned char *end,
                   void *value, size_t size) {
    if ((size_t)(end - *cursor) < size) { errno = EIO; return -1; }
    memcpy(value, *cursor, size);
    *cursor += size;
    return 0;
}

static int parse_entry(const unsigned char *start, uint32_t length,
                       uint64_t default_device, APFSDirectoryEntry *entry) {
    const unsigned char *cursor = start + sizeof(uint32_t);
    const unsigned char *end = start + length;
    attribute_set_t returned;
    if (consume(&cursor, end, &returned, sizeof(returned)) < 0) return -1;
    const attrgroup_t allowed = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR |
        ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
    if ((returned.commonattr & ~allowed) || returned.volattr || returned.fileattr ||
        returned.forkattr || (returned.dirattr & ~ATTR_DIR_MOUNTSTATUS)) {
        errno = EIO; return -1;
    }
    memset(entry, 0, sizeof(*entry));
    entry->device_id = default_device;
    entry->object_type = APFS_OBJECT_OTHER;
    if (returned.commonattr & ATTR_CMN_ERROR) {
        uint32_t error;
        if (consume(&cursor, end, &error, sizeof(error)) < 0) return -1;
        entry->error_code = (int)error;
    }
    if (returned.commonattr & ATTR_CMN_NAME) {
        attrreference_t reference;
        size_t reference_offset = (size_t)(cursor - start);
        if (consume(&cursor, end, &reference, sizeof(reference)) < 0) return -1;
        int64_t name_offset = (int64_t)reference_offset + reference.attr_dataoffset;
        if (name_offset < 0 || (uint64_t)name_offset > length ||
            reference.attr_length == 0 ||
            reference.attr_length > length - (size_t)name_offset) {
            errno = EIO; return -1;
        }
        const char *name = (const char *)start + (size_t)name_offset;
        const char *terminator = memchr(name, '\0', reference.attr_length);
        if (!terminator || terminator != name + reference.attr_length - 1 ||
            memchr(name, '/', reference.attr_length - 1)) {
            errno = EIO; return -1;
        }
        entry->name = name;
        entry->name_length = reference.attr_length - 1;
    } else if (!entry->error_code) { errno = EIO; return -1; }
    if (returned.commonattr & ATTR_CMN_DEVID) {
        dev_t device;
        if (consume(&cursor, end, &device, sizeof(device)) < 0) return -1;
        entry->device_id = (uint64_t)(uint32_t)device;
    }
    if (returned.commonattr & ATTR_CMN_OBJTYPE) {
        fsobj_type_t type;
        if (consume(&cursor, end, &type, sizeof(type)) < 0) return -1;
        switch (type) {
            case VREG: entry->object_type = APFS_OBJECT_FILE; break;
            case VDIR: entry->object_type = APFS_OBJECT_DIRECTORY; break;
            case VLNK: entry->object_type = APFS_OBJECT_SYMLINK; break;
            default: break;
        }
    }
    if (returned.commonattr & ATTR_CMN_FILEID) {
        if (consume(&cursor, end, &entry->file_id, sizeof(entry->file_id)) < 0) return -1;
        entry->has_file_id = 1;
    }
    if (returned.dirattr & ATTR_DIR_MOUNTSTATUS) {
        uint32_t mount_status;
        if (consume(&cursor, end, &mount_status, sizeof(mount_status)) < 0) return -1;
        entry->is_mount_point =
            (mount_status & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)) != 0;
    }
    /* Variable name bytes must not overlap any of the fixed attribute fields. */
    if (entry->name && (const unsigned char *)entry->name < cursor) {
        errno = EIO; return -1;
    }
    return 0;
}

int apfs_bulk_reader_next(APFSBulkReader *reader,
                          const APFSDirectoryEntry **entries, size_t *count) {
    if (!reader || !entries || !count) { errno = EINVAL; return -1; }
    *entries = NULL;
    *count = 0;
    struct attrlist attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR |
        ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
    attributes.dirattr = ATTR_DIR_MOUNTSTATUS;
    int result;
    do { result = getattrlistbulk(reader->fd, &attributes, reader->buffer,
                                  APFS_BULK_BUFFER_SIZE, FSOPT_NOFOLLOW); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return -1;
    if (result == 0) return 0;
    if ((size_t)result > APFS_BULK_BUFFER_SIZE / (sizeof(uint32_t) + sizeof(attribute_set_t))) {
        errno = EIO; return -1;
    }
    if ((size_t)result > reader->entry_capacity) {
        void *resized = realloc(reader->entries, (size_t)result * sizeof(*reader->entries));
        if (!resized) { errno = ENOMEM; return -1; }
        reader->entries = resized;
        reader->entry_capacity = (size_t)result;
    }
    size_t offset = 0;
    for (int i = 0; i < result; ++i) {
        uint32_t length;
        if (APFS_BULK_BUFFER_SIZE - offset < sizeof(length)) { errno = EIO; return -1; }
        memcpy(&length, reader->buffer + offset, sizeof(length));
        if (length < sizeof(uint32_t) + sizeof(attribute_set_t) ||
            length > APFS_BULK_BUFFER_SIZE - offset ||
            parse_entry(reader->buffer + offset, length, reader->device_id,
                        &reader->entries[i]) < 0) {
            errno = EIO; return -1;
        }
        offset += length;
    }
    *entries = reader->entries;
    *count = (size_t)result;
    return 0;
}

int apfs_bulk_reader_close(APFSBulkReader *reader) {
    if (!reader) { errno = EINVAL; return -1; }
    int result = close(reader->fd);
    int error = result < 0 ? errno : 0;
    free(reader->entries);
    free(reader->buffer);
    free(reader);
    if (error) errno = error;
    return result;
}
