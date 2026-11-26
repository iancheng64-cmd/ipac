#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "pvg_page_runs.h"
#include "pvg_lite.h"
#include "vmapple.h"
#include <assert.h>
#include <stdlib.h>
#include <unistd.h>

/* Exercise real Metal command completion while the guest board is destroyed.
   Empty execs avoid simulator limitations on guest buffer-backed textures. */
static HvMachine machine;
static HvCpu cpus[2];
static HvVmapple board;

static void check_buffer_aliases(void) {
    enum { page = HV_PVG_PAGE_BYTES, bytes = 6 * page };
    vm_address_t src = 0, dst = 0;
    assert(vm_allocate(mach_task_self(), &src, bytes, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    assert(vm_allocate(mach_task_self(), &dst, bytes, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    int order[] = {2, 3, -1, 0, 1, 5};
    HvPvgPageRun run = {0};
    for (unsigned i = 0; i < 6; i++) {
        memset((void *)(src + i * page), i + 1, page);
        if (order[i] >= 0)
            assert(hv_pvg_queue_page(&run, dst + i * page, src + order[i] * page, hv_pvg_remap) == KERN_SUCCESS);
    }
    assert(hv_pvg_flush_run(&run, hv_pvg_remap) == KERN_SUCCESS);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLBuffer> mapped = [device newBufferWithBytesNoCopy:(void *)dst length:bytes options:MTLResourceStorageModeShared
        deallocator:^(void *p, NSUInteger n) { vm_deallocate(mach_task_self(), (vm_address_t)p, n); }];
    id<MTLBuffer> readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    assert(mapped && readback);
    id<MTLCommandQueue> q = [device newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:mapped sourceOffset:0 toBuffer:readback destinationOffset:0 size:bytes];
    [blit fillBuffer:mapped range:NSMakeRange(0, page) value:67];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    assert(cb.status == MTLCommandBufferStatusCompleted);
    for (unsigned i = 0; i < bytes; i++)
        assert(((uint8_t *)readback.contents)[i] == order[i / page] + 1);
    for (unsigned i = 0; i < page; i++) assert(((uint8_t *)src)[2 * page + i] == 67);
    assert(vm_deallocate(mach_task_self(), src, bytes) == KERN_SUCCESS);
    puts("Metal page mapping: GPU readback and writes to guest pages passed");
}

int main(void) {
    alarm(30);
    @autoreleasepool { check_buffer_aliases(); }
    for (int cycle = 0; cycle < 6; cycle++) @autoreleasepool {
        HvCfgParams cfg = {.nr_cpus = 2};
        if (hv_machine_init(&machine, 4 << 20) ||
            hv_vmapple_create(&board, &machine, cpus, 64 << 20, NULL, NULL, &cfg, NULL)) return 1;
        hv_vmapple_reset_cpu(&board);
        HvPvgMetal *metal = hv_pvg_metal_create(board.pvg);
        if (!metal) { fprintf(stderr, "Metal replay unavailable; lifecycle test cannot run\n"); return 1; }
        CAMetalLayer *layer = [CAMetalLayer layer];
        hv_pvg_metal_set_layer(metal, (__bridge void *)layer);
        for (int i = 0; i < 64; i++) {
            uint32_t *cmd = calloc(6, sizeof *cmd);
            cmd[0] = 0x43; cmd[1] = 24; cmd[2] = i + 1;
            hv_pvg_metal_submit(metal, board.pvg, 0, cmd, 24);
        }
        hv_pvg_metal_cursor_moved(metal);
        hv_pvg_metal_set_layer(metal, NULL);
        hv_pvg_metal_destroy(metal);
        hv_vmapple_destroy(&board);
        hv_machine_free(&machine);
    }
    puts("Metal lifecycle: 6 cycles, 384 GPU completions drained");
    return 0;
}
