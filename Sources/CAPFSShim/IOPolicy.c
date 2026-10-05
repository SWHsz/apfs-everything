#include "CAPFSShim.h"
#include <sys/resource.h>
#include <errno.h>

int apfs_deny_dataless_materialization(void) {
#if defined(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES) && \
    defined(IOPOL_SCOPE_THREAD) && defined(IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    int result = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                               IOPOL_SCOPE_THREAD);
    if (result < 0) return -1;
    if (result != IOPOL_MATERIALIZE_DATALESS_FILES_OFF &&
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                      IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) < 0)
        return -1;
    /* Also avoid resolving automount triggers, when the SDK exposes this knob. */
#if defined(IOPOL_TYPE_VFS_TRIGGER_RESOLVE) && defined(IOPOL_VFS_TRIGGER_RESOLVE_OFF)
    result = getiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_THREAD);
    /* Some SDKs expose this optional type although the running kernel rejects
     * it with EINVAL. That is not a dataless-policy failure. Cached mount checks
     * and trigger metadata remain the primary automount boundary. */
    if (result >= 0 && result != IOPOL_VFS_TRIGGER_RESOLVE_OFF) {
        int trigger_result = setiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_THREAD,
                                          IOPOL_VFS_TRIGGER_RESOLVE_OFF);
        if (trigger_result < 0) return 0; /* Optional capability, safe fallback. */
    }
#endif
    return 0;
#else
    return 1;
#endif
}
