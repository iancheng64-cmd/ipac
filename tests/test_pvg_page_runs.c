#include "pvg_page_runs.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static unsigned calls;
static int reject_group;
static vm_address_t reject_page;

static kern_return_t remap(vm_address_t to, vm_address_t from, vm_size_t bytes) {
    calls++;
    if ((reject_group && bytes > HV_PVG_PAGE_BYTES) || from == reject_page) return KERN_FAILURE;
    return hv_pvg_remap(to, from, bytes);
}

static vm_address_t alloc(vm_size_t bytes) {
    vm_address_t base = 0;
    assert(vm_allocate(mach_task_self(), &base, bytes, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    return base;
}

static void fragments(void) {
    const vm_size_t page = HV_PVG_PAGE_BYTES;
    const int layout[] = {3, 4, -1, 0, 5, 6, 4};
    const int n = sizeof layout / sizeof *layout;
    vm_address_t src = alloc(n * page), dst = alloc(n * page);
    for (int i = 0; i < n; i++) memset((void *)(src + i * page), i + 1, page);
    HvPvgPageRun run = {0};
    calls = 0;
    for (int i = 0; i < n; i++)
        if (layout[i] >= 0)
            assert(hv_pvg_queue_page(&run, dst + i * page, src + layout[i] * page, remap) == KERN_SUCCESS);
    assert(hv_pvg_flush_run(&run, remap) == KERN_SUCCESS && calls == 4);
    for (int i = 0; i < n; i++) {
        assert(*(unsigned char *)(dst + i * page) == layout[i] + 1);
        assert(*(unsigned char *)(dst + (i + 1) * page - 1) == layout[i] + 1);
    }
    *(unsigned char *)(dst + page) = 121;
    assert(*(unsigned char *)(src + 4 * page) == 121 && *(unsigned char *)(dst + 6 * page) == 121);
    *(unsigned char *)(src + 3 * page) = 87;
    assert(*(unsigned char *)dst == 87);
    reject_group = 1;
    calls = 0;
    for (int i = 0; i < n; i++)
        assert(hv_pvg_queue_page(&run, dst + i * page, src + i * page, remap) == KERN_SUCCESS);
    assert(hv_pvg_flush_run(&run, remap) == KERN_SUCCESS && calls == 1 + (unsigned)n);
    assert(memcmp((void *)dst, (void *)src, n * page) == 0);
    reject_page = src + page;
    for (int i = 0; i < n; i++)
        assert(hv_pvg_queue_page(&run, dst + i * page, src + i * page, remap) == KERN_SUCCESS);
    assert(hv_pvg_flush_run(&run, remap) == KERN_FAILURE);
    reject_group = 0;
    reject_page = 0;
    assert(vm_deallocate(mach_task_self(), dst, n * page) == KERN_SUCCESS);
    assert(vm_deallocate(mach_task_self(), src, n * page) == KERN_SUCCESS);
}

static int cmp_ticks(const void *ap, const void *bp) {
    uint64_t a = *(const uint64_t *)ap, b = *(const uint64_t *)bp;
    return (a > b) - (a < b);
}

int main(void) {
    fragments();
    enum { pages = (1920 * 1336 * 8 + HV_PVG_PAGE_BYTES - 1) / HV_PVG_PAGE_BYTES, samples = 9 };
    const vm_size_t bytes = pages * HV_PVG_PAGE_BYTES;
    vm_address_t src = alloc(bytes);
    memset((void *)src, 31, bytes);
    uint64_t times[2][samples];
    for (int trial = 0; trial < samples; trial++) {
        for (int j = 0; j < 2; j++) {
            int grouped = (trial + j) % 2;
            vm_address_t dst = alloc(bytes);
            HvPvgPageRun run = {0};
            calls = 0;
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
            for (vm_size_t off = 0; off < bytes; off += HV_PVG_PAGE_BYTES) {
                kern_return_t kr = grouped ? hv_pvg_queue_page(&run, dst + off, src + off, remap)
                                           : remap(dst + off, src + off, HV_PVG_PAGE_BYTES);
                assert(kr == KERN_SUCCESS);
            }
            assert(hv_pvg_flush_run(&run, remap) == KERN_SUCCESS);
            times[grouped][trial] = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0;
            assert(calls == (grouped ? 1 : pages) && !memcmp((void *)dst, (void *)src, bytes));
            assert(vm_deallocate(mach_task_self(), dst, bytes) == KERN_SUCCESS);
        }
    }
    for (int i = 0; i < 2; i++) qsort(times[i], samples, sizeof(uint64_t), cmp_ticks);
    printf("PVG page aliases, holes and fallback passed. Contiguous surface: %d -> 1 Mach calls, median %.3f -> %.3f ms (%d samples).\n",
           pages, times[0][samples / 2] * 1e-6, times[1][samples / 2] * 1e-6, samples);
    assert(vm_deallocate(mach_task_self(), src, bytes) == KERN_SUCCESS);
}
