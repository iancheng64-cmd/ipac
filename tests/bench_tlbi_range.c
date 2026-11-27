/* Compare the local 16 KiB TLBI range path with Build 113's per-page invalidation. */
#include "machine.h"
#include "mmu.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static HvMachine machine;
static HvCpu cpu;

static uint64_t measure(unsigned pages, int asid, int batched) {
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    for (int r = 0; r < 4096; r++) {
        uint64_t base = 0x100000000ull + ((uint64_t)(r & 15) << 21);
        if (batched)
            hv_tlb_flush_small_range(&cpu, base, (uint64_t)pages << HV_TLB_PAGE_BITS, asid);
        else
            for (unsigned i = 0; i < pages; i++)
                hv_tlb_flush_va_asid(&cpu, base + ((uint64_t)i << HV_TLB_PAGE_BITS), asid);
    }
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start;
}

static int cmp(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

int main(void) {
    if (hv_machine_init(&machine, 1 << 20)) return 1;
    hv_cpu_reset(&cpu, &machine);
    cpu.ttbr0_el1 = 5ull << 48;
    hv_ijc_switch(&cpu);
    for (int i = 0; i < HV_STASHES; i++)
        cpu.pc_state->stash[i].ttbr0 = (uint64_t)i << 48 | 0x4000;
    const unsigned sizes[] = {2, 32, 128};
    for (unsigned k = 0; k < sizeof sizes / sizeof *sizes; k++) {
        for (int asid = -1; asid <= 5; asid += 6) {
            uint64_t times[2][9];
            for (unsigned iter = 0; iter < 9; iter++)
                for (unsigned turn = 0; turn < 2; turn++) {
                    unsigned mode = (iter + turn) & 1;
                    HvTlbStash *st = &cpu.pc_state->stash[5];
                    uint32_t start = st->gen;
                    times[mode][iter] = measure(sizes[k], asid, mode);
                    assert(st->gen - start == 4096u * (mode ? 1u : sizes[k]));
                }
            for (int m = 0; m < 2; m++) qsort(times[m], 9, sizeof(uint64_t), cmp);
            printf("%3u pages asid=%2d: per-page %.1f ns  batched %.1f ns\n",
                   sizes[k], asid, times[0][4] / 4096., times[1][4] / 4096.);
        }
    }
    hv_machine_free(&machine);
    return 0;
}
