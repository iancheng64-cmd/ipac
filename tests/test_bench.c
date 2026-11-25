/* Native vs JIT timing for typical code shapes (see bench_programs.S). */
#include "harness.h"
#include "jit_loop_fixture.h"

#include <errno.h>
#include <mach/mach_time.h>

#include "translate.h"
#include <stdlib.h>

DECLARE_PROGRAM(bench_calls);
DECLARE_PROGRAM(bench_mem);
DECLARE_PROGRAM(bench_dispatch);
DECLARE_PROGRAM(bench_loop);
extern const char bench_programs_begin[], bench_programs_finish[];

static const TestProgram programs[] = {
    TEST_PROGRAM(bench_calls), TEST_PROGRAM(bench_mem), TEST_PROGRAM(bench_dispatch), TEST_PROGRAM(bench_loop),
};

/* EL0, so the indirect-branch cache takes these low (user) addresses. */
static void at_el0(HvCpu *cpu) {
    cpu->el = 0;
    cpu->spsel = 0;
}

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static unsigned benchmark_count(const char *text, unsigned limit) {
    char *end;
    errno = 0;
    unsigned long count = strtoul(text, &end, 10);
    if (errno || !*text || *end || !count || count > limit) {
        fprintf(stderr, "invalid benchmark count: %s\n", text);
        exit(2);
    }
    return (unsigned)count;
}

static int batch_benchmark(unsigned rounds, unsigned executions, const char *selected) {
    static HvMachine m;
    static HvCpu initial, native, jit;
    if (hv_machine_init(&m, 4 << 20) != 0) return 1;
    m.chain = 1;
    uint8_t *stack = aligned_alloc(PAGE_BYTES, 65536);
    if (!stack || hv_machine_add_ram(&m, (uint64_t)(uintptr_t)bench_programs_begin,
            bench_programs_finish - bench_programs_begin, (void *)bench_programs_begin, 1) != 0 ||
        hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0) != 0) return 1;
    unsigned tested = 0;
    for (size_t i = 0; i < sizeof programs / sizeof *programs; i++) {
        const TestProgram *p = &programs[i];
        if (selected && strcmp(selected, p->name)) continue;
        tested++;
        memset(&initial, 0, sizeof initial);
        seed_cpu(&initial, i + 1, (uint64_t)(uintptr_t)stack + 32768);
        memset(stack, 0, 65536);
        native = initial;
        hv_native_run(&native, p->native);
        uint64_t expected0 = native.x[0], expected5 = native.x[5];
        memset(stack, 0, 65536);
        double start = now_ms();
        if (run_jit(&m, p, &initial, &jit, at_el0) != 0 ||
            jit.x[0] != expected0 || jit.x[5] != expected5) return 1;
        double cold_ms = now_ms() - start;
        for (unsigned r = 0; r < rounds; r++) {
            start = now_ms();
            for (unsigned n = 0; n < executions; n++) {
                memset(stack, 0, 65536);
                native = initial;
                hv_native_run(&native, p->native);
            }
            double native_ms = now_ms() - start;
            uint64_t translated = m.stats.translations, blocks = m.stats.blocks, slow = m.stats.helper[HV_OP_MEM];
            start = now_ms();
            for (unsigned n = 0; n < executions; n++) {
                memset(stack, 0, 65536);
                if (run_jit(&m, p, &initial, &jit, at_el0) != 0 ||
                    jit.x[0] != expected0 || jit.x[5] != expected5) return 1;
            }
            double jit_ms = now_ms() - start;
            if (m.stats.translations != translated) return 1;
            printf("{\"workload\":\"%s\",\"round\":%u,\"batch\":%u,\"native_ms\":%.6f,\"jit_ms\":%.6f,"
                   "\"cold_ms\":%.6f,\"retranslations\":%llu,\"dispatcher_entries\":%llu,\"slow_mem\":%llu}\n",
                   p->name, r, executions, native_ms, jit_ms, cold_ms,
                   (unsigned long long)(m.stats.translations - translated),
                   (unsigned long long)(m.stats.blocks - blocks), (unsigned long long)(m.stats.helper[HV_OP_MEM] - slow));
        }
    }
    hv_machine_free(&m);
    free(stack);
    return tested ? 0 : 2;
}

static int churn_benchmark(unsigned rounds, unsigned cycles, unsigned batches) {
    static HvMachine m;
    static HvCpu cpu;
    Fixture f;
    if (fixture_init(&f, &m, &cpu, 8, 16 << 20, NULL) != 0) return 1;
    for (unsigned r = 0; r < rounds; r++) {
        double elapsed = 0;
        uint64_t translations = 0, chains = 0, invalidations = 0;
        for (unsigned b = 0; b < batches; b++) {
            hv_flush_blocks(&m);
            f.guest[PAGE_BYTES / 4] = UINT32_C(0x91000400);
            if (fixture_run(&f, 1) != 0) return 1;
            uint64_t translated = m.stats.translations, chained = m.stats.chained, invalidated = m.stats.flush_smc;
            double start = now_ms();
            for (unsigned n = 0; n < cycles; n++) {
                unsigned increment = 1 + (n & 1);
                f.guest[PAGE_BYTES / 4] = UINT32_C(0x91000000) | increment << 10;
                hv_invalidate_code(&m, f.base + PAGE_BYTES);
                if (fixture_run(&f, increment) != 0) return 1;
            }
            elapsed += now_ms() - start;
            translations += m.stats.translations - translated;
            chains += m.stats.chained - chained;
            invalidations += m.stats.flush_smc - invalidated;
        }
        printf("{\"workload\":\"translate_chain_invalidate\",\"round\":%u,\"cycles\":%u,\"batches\":%u,"
               "\"jit_ms\":%.6f,\"translations\":%llu,\"chains\":%llu,\"invalidations\":%llu,\"resets\":%u,"
               "\"capacity_flushes\":%llu,\"jit_words\":%zu}\n", r, cycles, batches, elapsed,
               (unsigned long long)translations, (unsigned long long)chains, (unsigned long long)invalidations,
               batches, (unsigned long long)m.stats.flush_full, m.jit.used);
    }
    fixture_destroy(&f);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if ((argc == 4 || argc == 5) && strcmp(argv[1], "--batch") == 0)
        return batch_benchmark(benchmark_count(argv[2], 101), benchmark_count(argv[3], 100000),
                               argc == 5 ? argv[4] : NULL);
    if (argc == 5 && strcmp(argv[1], "--churn") == 0)
        return churn_benchmark(benchmark_count(argv[2], 101), benchmark_count(argv[3], 1000000),
                               benchmark_count(argv[4], 128));
    if (argc != 1) return 2;
    static HvMachine m;
    if (hv_machine_init(&m, 4 << 20) != 0) return 1;
    m.chain = 1;
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)bench_programs_begin, bench_programs_finish - bench_programs_begin,
                       (void *)bench_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    uint64_t sp = (uint64_t)(uintptr_t)stack + 32768;
    int failed = 0;
    for (size_t i = 0; i < sizeof programs / sizeof programs[0]; i++) {
        const TestProgram *p = &programs[i];
        static HvCpu init, native, jit;
        memset(&init, 0, sizeof init);
        seed_cpu(&init, i + 1, sp);
        double tn = 1e9, tj = 1e9;
        uint64_t entries = 0, slow = 0;
        for (int k = 0; k < 5; k++) {
            double t0 = now_ms();
            native = init;
            hv_native_run(&native, p->native);
            double t1 = now_ms();
            uint64_t b0 = m.stats.blocks, s0 = m.stats.helper[HV_OP_MEM];
            if (run_jit(&m, p, &init, &jit, at_el0)) return 1;
            entries = m.stats.blocks - b0;
            slow = m.stats.helper[HV_OP_MEM] - s0;
            double t2 = now_ms();
            if (t1 - t0 < tn) tn = t1 - t0;
            if (k && t2 - t1 < tj) tj = t2 - t1; /* the first JIT run includes translation */
        }
        int bad = i != 1 && (native.x[0] != jit.x[0] || native.x[5] != jit.x[5]); /* bench_mem's results depend on the buffer's earlier contents */
        printf("%-15s native %7.3f ms  jit %7.3f ms  %5.2fx  (%llu dispatcher entries, %llu slow loads/stores)%s\n", p->name, tn, tj, tj / tn,
               (unsigned long long)entries, (unsigned long long)slow, bad ? "  WRONG RESULT" : "");
        failed += bad;
    }
    /* HV_DUMP=file: every translated block (guest VA, guest words, host words) for disassembly. */
    if (getenv("HV_DUMP")) {
        FILE *f = fopen(getenv("HV_DUMP"), "wb");
        for (int i = 0; f && i < m.nblocks; i++) {
            HvBlock *b = &m.blocks[i];
            uint32_t *end = i + 1 < m.nblocks ? m.blocks[i + 1].code : m.jit.base + m.jit.used;
            uint64_t hdr[3] = {b->va, b->ninsns, (uint64_t)(end - b->code)};
            fwrite(hdr, sizeof hdr, 1, f);
            fwrite((const void *)(uintptr_t)b->va, 4, b->ninsns, f);
            fwrite(b->code, 4, (size_t)(end - b->code), f);
        }
        if (f) fclose(f);
    }
    return failed != 0;
}
