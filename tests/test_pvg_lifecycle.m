#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "pvg_page_runs.h"
#include "pvg_command_copy.h"
#include "pvg_lite.h"
#include "vmapple.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <unistd.h>

/* Exercise real Metal command completion while the guest board is destroyed.
   Empty execs avoid simulator limitations on guest buffer-backed textures. */
static HvMachine machine;
static HvCpu cpus[2];
static HvVmapple board;

static void write_reg(uint64_t pa, uint32_t v) {
    assert(!hv_phys_write(&machine, pa, &v, sizeof v));
}

static void check_task_pages(void) {
    enum { page = HV_PVG_PAGE_BYTES, count = 4113 };
    const uint32_t base = VMAPPLE_MEM >> 14, task = 3;
    uint32_t *ring = hv_phys_ptr(&machine, VMAPPLE_MEM, 4 * page);
    assert(ring);
    uint32_t *root = ring + page / 4, *top = root + page / 4, *leaf = top + page / 4;
    uint32_t cmd[7] = {0x38, sizeof cmd, 1, task * 2, 0, 0, base + 1};
    memcpy(ring + 0x100 / 4, cmd, sizeof cmd);
    write_reg(VMAPPLE_GFX + 0x1030, base);
    write_reg(VMAPPLE_GFX + 0x1004, page);
    write_reg(VMAPPLE_GFX + 0x1010, 0x100);
    write_reg(VMAPPLE_GFX + 0x1008, sizeof cmd);

    uint32_t saved[count], first = 13;
    root[0] = base + 2; root[1] = 2;
    top[0] = 0x80000000u | (base + 3); top[1] = 0;
    for (unsigned i = 0; i < 4096; i++) leaf[i] = i % 7 ? (0x80000000u | i) : 0;
    hv_pvg_lite_task_pages(board.pvg, task, first, count, saved);
    for (unsigned i = 0; i < count; i++) {
        uint32_t index = first + i;
        assert(saved[i] == (index < 4096 && index % 7 ? index : 0));
    }
    assert(hv_pvg_lite_pages_match(board.pvg, task, first, count, saved));
    leaf[first + 1] ^= 0x80000000u;
    assert(hv_pvg_lite_pages_match(board.pvg, task, first, count, saved));
    leaf[4095] ^= 1;
    assert(!hv_pvg_lite_pages_match(board.pvg, task, first, count, saved));
    leaf[4095] ^= 1;
    saved[count - 1] = 8;
    assert(!hv_pvg_lite_pages_match(board.pvg, task, first, count, saved));
    saved[count - 1] = 0;

    if (getenv("HV_PVG_BENCH_PAGES")) {
        const unsigned sizes[] = {1, 64, 256, 1253}, reps = 100000;
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        volatile unsigned checked = 0;
        for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; s++) for (unsigned round = 0; round < 6; round++) {
            unsigned n = sizes[s];
            int direct = round % 2;
            uint64_t start = mach_absolute_time();
            for (unsigned i = 0; i < reps; i++) {
                if (direct) checked += hv_pvg_lite_pages_match(board.pvg, task, first, n, saved);
                else {
                    uint32_t stack[256], *copy = n <= 256 ? stack : malloc(n * sizeof *copy);
                    assert(copy);
                    hv_pvg_lite_task_pages(board.pvg, task, first, n, copy);
                    checked += !memcmp(copy, saved, n * sizeof *copy);
                    if (copy != stack) free(copy);
                }
            }
            double ns = (double)(mach_absolute_time() - start) * tb.numer / tb.denom / reps;
            printf("GPU page validation: %s %.1f ns/check (%u pages)\n", direct ? "direct" : "temporary", ns, n);
        }
        assert(checked == reps * 6 * (sizeof sizes / sizeof sizes[0]));
    }
    root[1] = UINT32_MAX;
    assert(!hv_pvg_lite_pages_match(board.pvg, task, first, count, saved));
    memset(saved, 0, sizeof saved);
    assert(hv_pvg_lite_pages_match(board.pvg, task, first, count, saved));
    assert(hv_pvg_lite_pages_match(board.pvg, 512, first, count, saved));
    assert(hv_pvg_lite_pages_match(board.pvg, task, first, 0, saved));
    puts("GPU page validation: flags, holes, changed leaves and invalid tables passed");
}

static void check_command_copies(HvPvgMetal *metal) {
    enum { page = HV_PVG_PAGE_BYTES, task = 3, sections = 4, blen = 40 };
    const uint32_t base = VMAPPLE_MEM >> 14;
    uint32_t *root = hv_phys_ptr(&machine, VMAPPLE_MEM + page, page);
    uint32_t *leaf = hv_phys_ptr(&machine, VMAPPLE_MEM + 2 * page, page);
    root[0] = base + 2; root[1] = 1;
    memset(leaf, 0, page);
    for (uint32_t i = 1; i <= 6; i++) leaf[i] = base + 30 + 2 * i;
    uint32_t *objects = hv_phys_ptr(&machine, (uint64_t)leaf[1] << 14, page);
    uint32_t *description = hv_phys_ptr(&machine, (uint64_t)leaf[2] << 14, page);
    uint8_t *left = hv_phys_ptr(&machine, (uint64_t)leaf[3] << 14, page);
    uint8_t *right = hv_phys_ptr(&machine, (uint64_t)leaf[4] << 14, page);
    uint8_t *output = hv_phys_ptr(&machine, (uint64_t)leaf[6] << 14, page);
    /* A real buffer object for the older guest's object table at offset 0x4000. */
    objects[3] = 16u << 8 | 1; objects[4] = 2 * page; objects[5] = 0;
    description[0] = page; description[1] = 0; description[2] = 6; description[3] = 0;
    uint32_t *cmd = calloc(6 + 4 * sections, sizeof *cmd);
    cmd[0] = 0x43; cmd[1] = (6 + 4 * sections) * sizeof *cmd; cmd[2] = 37;
    cmd[3] = task; cmd[5] = sections;
    for (unsigned i = 0; i < sections; i++) {
        uint32_t data[10] = {32, 2, 306, 32, 1, i * 256, 0, 256, 0, 0x30 + i};
        unsigned off = 4 * page - 16 + i * 64;
        if (!i) { memcpy(left + page - 16, data, 16); memcpy(right, (uint8_t *)data + 16, blen - 16); }
        else memcpy(right + off - 4 * page, data, blen);
        /* One unreadable segment between good ones must not replay stale cached bytes. */
        cmd[6 + i * 4] = i == 2 ? 7 * page : off;
        cmd[8 + i * 4] = blen;
    }
    hv_pvg_metal_submit(metal, board.pvg, 1, cmd, cmd[1]);
    hv_pvg_metal_quiesce(metal);
    uint32_t *stamps = hv_phys_ptr(&machine, VMAPPLE_MEM, 8);
    assert(stamps[1] == 37);
    for (unsigned i = 0; i < sections * 256; i++)
        assert(output[i] == (i / 256 == 2 ? 0 : 0x30 + i / 256));

    NSMutableData *cache = nil;
    NSMutableData *small = hv_pvg_command_storage(&cache, 512);
    assert(small == cache && cache.length == 4096);
    assert(hv_pvg_command_storage(&cache, 64) == small);
    assert(hv_pvg_command_storage(&cache, HV_COMMAND_CACHE_LIMIT) != small);
    assert(hv_pvg_command_storage(&cache, HV_COMMAND_CACHE_LIMIT + 1) != cache);
    assert(cache.length == HV_COMMAND_CACHE_LIMIT);
    if (getenv("HV_PVG_BENCH_COMMANDS")) {
        const unsigned sizes[] = {512, 4096, 16384}, reps = 10000;
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; s++) for (int j = 0; j < 6; j++) {
            unsigned sum = 0, n = sizes[s];
            uint64_t start = mach_absolute_time();
            for (unsigned i = 0; i < reps; i++) @autoreleasepool {
                NSMutableData *bytes = j % 2 ? hv_pvg_command_storage(&cache, n) : [NSMutableData dataWithLength:n];
                assert(!hv_pvg_lite_task_read(board.pvg, task, 4 * page, bytes.mutableBytes, n));
                sum += ((const uint8_t *)bytes.bytes)[48];
            }
            assert(sum == right[48] * reps);
            printf("Metal command snapshot: %s %u bytes %.1f ns\n", j % 2 ? "reused" : "fresh", n,
                   (double)(mach_absolute_time() - start) * tb.numer / tb.denom / reps);
        }
    }
    puts("Metal command snapshots: fragmented input, GPU fill bytes, unreadable segment and cache limit passed");
}

/* A real, small scanout surface submitted to the production Metal worker. */
static void submit_surface(HvPvgMetal *metal) {
    const uint64_t table = VMAPPLE_MEM + 0x20000, desc = table + 0x4000, list = desc + 0x4000, pixels = list + 0x4000;
    assert(!hv_phys_write(&machine, VMAPPLE_IOSFC + 0x1010, &table, sizeof table));
    uint32_t *slot = hv_phys_ptr(&machine, table, 4);
    uint32_t *ppn = hv_phys_ptr(&machine, list, 4);
    uint8_t *d = hv_phys_ptr(&machine, desc + 0x400, 0x400), *src = hv_phys_ptr(&machine, pixels, 16384);
    assert(slot && ppn && d && src);
    *slot = (uint32_t)(desc >> 12) | 1; *ppn = (uint32_t)(pixels >> 12) | 1;
    *(uint32_t *)d = (uint32_t)(list >> 12) | 1;
    *(uint32_t *)(d + 4) = 'BGRA';
    *(uint64_t *)(d + 0x18) = 16384; *(uint64_t *)(d + 0x20) = 64;
    *(uint64_t *)(d + 0x28) = 64; *(uint64_t *)(d + 0x30) = 256;
    d[0x3e] = 1;
    for (unsigned i = 0; i < 16384; i++) src[i] = (uint8_t)(i * 17 + 5);
    uint32_t *cmd = calloc(13, sizeof *cmd);
    cmd[0] = 8; cmd[1] = 13 * sizeof *cmd; cmd[2] = 1; cmd[5] = 1;
    hv_pvg_metal_submit(metal, board.pvg, 0, cmd, cmd[1]);
    hv_pvg_metal_quiesce(metal);
    const uint8_t *frame; uint32_t w, h;
    assert(hv_pvg_metal_frame(metal, &frame, &w, &h) == 0 && frame && w == 64 && h == 64);
    assert(!memcmp(src, frame, 16384));
}

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
        if (cycle == 0) { check_task_pages(); submit_surface(metal); check_command_copies(metal); }
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
