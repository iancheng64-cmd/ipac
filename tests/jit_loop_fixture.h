#ifndef HENGE_TEST_JIT_LOOP_FIXTURE_H
#define HENGE_TEST_JIT_LOOP_FIXTURE_H

#include "harness.h"

#include <stdlib.h>
#include <string.h>

#define PAGE_BYTES 16384u

typedef struct Fixture {
    HvMachine *m;
    HvCpu *cpu;
    uint32_t *guest;
    uint64_t base;
    unsigned iterations;
} Fixture;

static uint32_t branch(uint64_t from, uint64_t to) {
    return UINT32_C(0x14000000) | ((uint32_t)(((int64_t)to - (int64_t)from) / 4) & UINT32_C(0x3ffffff));
}

static int fixture_init(Fixture *f, HvMachine *m, HvCpu *cpu, unsigned iterations, size_t jit_bytes,
                        const HvJitRegion *prewarm) {
    memset(f, 0, sizeof *f);
    f->m = m;
    f->cpu = cpu;
    f->iterations = iterations;
    f->guest = aligned_alloc(PAGE_BYTES, PAGE_BYTES * 3);
    if (!f->guest) return -1;
    memset(f->guest, 0, PAGE_BYTES * 3);
    f->base = UINT64_C(0x40000000);
    int opened = prewarm ? hv_machine_init_jit(m, prewarm->base,
        (void *)((uintptr_t)prewarm->base + prewarm->rw_diff), jit_bytes) : hv_machine_init(m, jit_bytes);
    if (opened != 0 || hv_machine_add_ram(m, f->base, PAGE_BYTES * 3, f->guest, 0) != 0) {
        hv_machine_free(m);
        free(f->guest);
        return -1;
    }
    uint32_t *p = f->guest, *q = f->guest + PAGE_BYTES / 4;
    /* Alternate between guest pages; modifying q[0] exercises incoming-chain invalidation. */
    p[0] = UINT32_C(0xd2800000);
    p[1] = UINT32_C(0xd2800001) | iterations << 5;
    p[2] = branch(f->base + 8, f->base + PAGE_BYTES);
    q[0] = UINT32_C(0x91000400);
    q[1] = UINT32_C(0xf1000421);
    int64_t offset = ((int64_t)f->base + 8 - (int64_t)(f->base + PAGE_BYTES + 8)) / 4;
    q[2] = UINT32_C(0x54000001) | ((uint32_t)offset & UINT32_C(0x7ffff)) << 5;
    q[3] = UINT32_C(0xd65f03c0);
    hv_cpu_reset(cpu, m);
    cpu->el = 0;
    cpu->spsel = 0;
    cpu->sp = f->base + PAGE_BYTES * 3 - 256;
    m->stop_pc = f->base + PAGE_BYTES * 2;
    return 0;
}

static int fixture_run(Fixture *f, unsigned increment) {
    f->cpu->pc = f->base;
    f->cpu->x[30] = f->m->stop_pc;
    f->cpu->halted = HV_HALT_NONE;
    f->cpu->exit_req = 0;
    return hv_run(f->cpu) == HV_EXIT_HALT &&
           f->cpu->x[0] == (uint64_t)f->iterations * increment ? 0 : -1;
}

static void fixture_destroy(Fixture *f) {
    hv_machine_free(f->m);
    free(f->guest);
}

#endif
