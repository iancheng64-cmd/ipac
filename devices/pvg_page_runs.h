#ifndef HENGE_PVG_PAGE_RUNS_H
#define HENGE_PVG_PAGE_RUNS_H

#include <mach/mach.h>

enum { HV_PVG_PAGE_BYTES = 0x4000 };
typedef struct { vm_address_t to, from; vm_size_t bytes; } HvPvgPageRun;
typedef kern_return_t (*HvPvgRemap)(vm_address_t to, vm_address_t from, vm_size_t bytes);

static inline kern_return_t hv_pvg_remap(vm_address_t to, vm_address_t from, vm_size_t bytes) {
    vm_prot_t cur, max;
    return vm_remap(mach_task_self(), &to, bytes, 0, VM_FLAGS_OVERWRITE, mach_task_self(), from, FALSE, &cur, &max, VM_INHERIT_NONE);
}

static inline kern_return_t hv_pvg_flush_run(HvPvgPageRun *r, HvPvgRemap remap) {
    vm_size_t bytes = r->bytes;
    if (!bytes) return KERN_SUCCESS;
    r->bytes = 0;
    kern_return_t result = remap(r->to, r->from, bytes);
    if (result == KERN_SUCCESS || bytes == HV_PVG_PAGE_BYTES) return result;
    // Adjacent addresses can span different host mappings. Keep the original page-by-page behavior.
    result = KERN_SUCCESS;
    for (vm_size_t off = 0; off < bytes; off += HV_PVG_PAGE_BYTES) {
        kern_return_t kr = remap(r->to + off, r->from + off, HV_PVG_PAGE_BYTES);
        if (kr != KERN_SUCCESS && result == KERN_SUCCESS) result = kr;
    }
    return result;
}

static inline kern_return_t hv_pvg_queue_page(HvPvgPageRun *r, vm_address_t to, vm_address_t from, HvPvgRemap remap) {
    if (r->bytes && r->to + r->bytes == to && r->from + r->bytes == from) {
        r->bytes += HV_PVG_PAGE_BYTES;
        return KERN_SUCCESS;
    }
    kern_return_t kr = hv_pvg_flush_run(r, remap);
    *r = (HvPvgPageRun){to, from, HV_PVG_PAGE_BYTES};
    return kr;
}

#endif
