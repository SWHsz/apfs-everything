#include "CAPFSShim.h"
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <mach/mach.h>

int apfs_process_resources(APFSProcessResources *output) {
    if (!output) { errno = EINVAL; return -1; }
    memset(output, 0, sizeof(*output));
#if defined(RUSAGE_INFO_V4)
    struct rusage_info_v4 info = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return -1;
    output->disk_bytes_read = info.ri_diskio_bytesread;
    output->disk_bytes_written = info.ri_diskio_byteswritten;
    output->logical_bytes_written = info.ri_logical_writes;
    output->physical_footprint = info.ri_phys_footprint;
    output->peak_physical_footprint = info.ri_lifetime_max_phys_footprint;
    output->idle_wakeups = info.ri_pkg_idle_wkups;
    output->interrupt_wakeups = info.ri_interrupt_wkups;
    output->pageins = info.ri_pageins;
#if defined(TASK_VM_INFO) && defined(TASK_VM_INFO_REV0_COUNT)
    struct task_vm_info vm = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS
        && count >= TASK_VM_INFO_REV0_COUNT) {
        output->internal_resident_bytes = vm.internal;
        output->external_resident_bytes = vm.external;
        output->compressed_bytes = vm.compressed;
        output->peak_compressed_bytes = vm.compressed_peak;
        output->memory_info_valid = 1;
    }
#endif
    return 0;
#else
    errno = ENOTSUP;
    return -1;
#endif
}

int apfs_system_cpu(APFSCPUCounter *output) {
    if (!output) { errno = EINVAL; return -1; }
    host_cpu_load_info_data_t info = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || count < HOST_CPU_LOAD_INFO_COUNT) { errno = EIO; return -1; }
    output->user = info.cpu_ticks[CPU_STATE_USER]; output->system = info.cpu_ticks[CPU_STATE_SYSTEM];
    output->nice = info.cpu_ticks[CPU_STATE_NICE]; output->idle = info.cpu_ticks[CPU_STATE_IDLE];
    return 0;
}
