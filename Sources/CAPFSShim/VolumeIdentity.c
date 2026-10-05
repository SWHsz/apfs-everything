#include "CAPFSShim.h"
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <string.h>

int apfs_volume_info(const char *root, APFSVolumeInfo *info) {
    if (!info) { errno = EINVAL; return -1; }
    APFSDirectoryInfo directory;
    if (apfs_directory_info(root, 0, 0, &directory) < 0) return -1;
    struct statfs filesystem;
    if (statfs(root, &filesystem) < 0) return -1;
    if (!(filesystem.f_flags & MNT_LOCAL)) { errno = EXDEV; return -1; }
    struct attrlist attributes = {0};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
    unsigned char packed[4 + 16] = {0};
    if (getattrlist(root, &attributes, packed, sizeof(packed), FSOPT_NOFOLLOW) < 0) return -1;
    uint32_t length;
    memcpy(&length, packed, sizeof(length));
    if (length != sizeof(packed)) { errno = EIO; return -1; }
    memset(info, 0, sizeof(*info));
    info->device_id = directory.device_id;
    info->root_file_id = directory.file_id;
    memcpy(info->volume_uuid, packed + 4, 16);
    size_t mount_length = strnlen(filesystem.f_mntonname, sizeof(filesystem.f_mntonname));
    if (mount_length >= sizeof(info->mount_point)) { errno = ENAMETOOLONG; return -1; }
    memcpy(info->mount_point, filesystem.f_mntonname, mount_length + 1);
    return 0;
}

int apfs_open_cache_directory(const char *path, int create) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) { errno = EINVAL; return -1; }
    if (apfs_prepare_root_path(path) < 0) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    char components[PATH_MAX];
    memcpy(components, path, strlen(path) + 1);
    char *save = NULL;
    for (char *name = strtok_r(components, "/", &save); name; name = strtok_r(NULL, "/", &save)) {
        if (!strcmp(name, ".") || !strcmp(name, "..")) { close(fd); errno = EINVAL; return -1; }
        if (create && mkdirat(fd, name, 0700) < 0 && errno != EEXIST) {
            int error = errno; close(fd); errno = error; return -1;
        }
        int next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (next < 0) { int error = errno; close(fd); errno = error; return -1; }
        close(fd); fd = next;
    }
    struct stat metadata;
    if (fstat(fd, &metadata) < 0) { int error = errno; close(fd); errno = error; return -1; }
    if (metadata.st_uid != geteuid()) { close(fd); errno = EPERM; return -1; }
    /* Never chmod an existing caller-owned directory. mkdirat creates ours 0700. */
    if ((metadata.st_mode & 07777) != 0700) { close(fd); errno = EPERM; return -1; }
    return fd;
}
