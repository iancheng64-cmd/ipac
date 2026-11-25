#include "harness.h"
#include "jit_loop_fixture.h"

#include <errno.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>

DECLARE_PROGRAM(bench_calls);
DECLARE_PROGRAM(bench_mem);
DECLARE_PROGRAM(bench_dispatch);
DECLARE_PROGRAM(bench_loop);
extern const char bench_programs_begin[], bench_programs_finish[];

static int checks, failures;
#define CHECK(x) do { checks++; if (!(x)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); } } while (0)

static void mode(int compact) {
    if (compact) setenv("HV_COMPACT_JIT_METADATA", "1", 1);
    else unsetenv("HV_COMPACT_JIT_METADATA");
}

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

typedef struct Writer {
    HvMachine *m;
    HvJitMetadata *table;
    uint32_t *code;
    uint32_t first, count;
    int failed;
} Writer;

static void *write_entries(void *arg) {
    Writer *w = arg;
    for (uint32_t round = 0; round < 64; round++)
        for (uint32_t i = w->first; i < w->first + w->count; i++) {
            uint32_t *value = w->code + ((i + round) & 31);
            if (hv_jit_metadata_set(w->m, w->table, i, value) != 0 ||
                hv_jit_metadata_get(w->m, w->table, i) != value)
                w->failed = 1;
        }
    return NULL;
}

static void test_storage(int compact) {
    static HvMachine m;
    uint32_t code[32] = {0};
    memset(&m, 0, sizeof m);
    m.jit.base = code;
    m.jit.capacity = 32;
    m.max_slots = 8;
    m.compact_jit_metadata = compact;
    HvJitMetadata *tables[] = {&m.slot_site, &m.slot_stub, &m.slot_cond};
    CHECK(sizeof(HvBlock) == 80);
    CHECK(sizeof *m.slots == 8);
    CHECK(hv_jit_metadata_entry_bytes(&m) == (compact ? 4 : 8));
    for (size_t t = 0; t < 3; t++) {
        tables[t]->entries = calloc(m.max_slots, hv_jit_metadata_entry_bytes(&m));
        CHECK(tables[t]->entries != NULL);
        if (!tables[t]->entries) exit(1);
        for (uint32_t i = 0; i < m.max_slots; i++) CHECK(hv_jit_metadata_get(&m, tables[t], i) == NULL);
        CHECK(hv_jit_metadata_set(&m, tables[t], 0, code) == 0);
        CHECK(hv_jit_metadata_get(&m, tables[t], 0) == code);
        CHECK(hv_jit_metadata_set(&m, tables[t], 1, code + 31) == 0);
        CHECK(hv_jit_metadata_get(&m, tables[t], 1) == code + 31);
        if (compact) {
            CHECK(((uint32_t *)tables[t]->entries)[0] == 1);
            CHECK(((uint32_t *)tables[t]->entries)[1] == 32);
        }
        CHECK(hv_jit_metadata_set(&m, tables[t], 0, NULL) == 0);
        CHECK(hv_jit_metadata_get(&m, tables[t], 0) == NULL);
        errno = 0;
        CHECK(hv_jit_metadata_set(&m, tables[t], m.max_slots, code) == -1 && errno == ERANGE);
        errno = 0;
        CHECK(hv_jit_metadata_get(&m, tables[t], m.max_slots) == NULL && errno == ERANGE);
        if (compact) {
            CHECK(hv_jit_metadata_set(&m, tables[t], 0, code + 7) == 0);
            const uintptr_t invalid[] = {(uintptr_t)code - 4, (uintptr_t)code + sizeof code, (uintptr_t)code + 1};
            for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
                errno = 0;
                CHECK(hv_jit_metadata_set(&m, tables[t], 0, (uint32_t *)invalid[i]) == -1 && errno == EOVERFLOW);
                CHECK(hv_jit_metadata_get(&m, tables[t], 0) == code + 7);
            }
        }
        Writer writers[2] = {{&m, tables[t], code, 0, 4, 0}, {&m, tables[t], code, 4, 4, 0}};
        pthread_t threads[2];
        for (size_t i = 0; i < 2; i++) {
            int r = pthread_create(&threads[i], NULL, write_entries, &writers[i]);
            CHECK(r == 0);
            if (r) exit(1);
        }
        for (size_t i = 0; i < 2; i++) {
            CHECK(pthread_join(threads[i], NULL) == 0);
            CHECK(!writers[i].failed);
        }
        for (uint32_t i = 0; i < m.max_slots; i++)
            CHECK(hv_jit_metadata_get(&m, tables[t], i) == code + ((i + 63) & 31));
    }
    CHECK(hv_jit_metadata_bytes(&m) == (size_t)m.max_slots * 3 * (compact ? 4 : 8));
    if (compact) {
        m.jit.base = (uint32_t *)(uintptr_t)UINT64_C(0x100000000);
        m.jit.capacity = UINT32_MAX;
        CHECK(hv_jit_metadata_compact_supported(&m.jit));
        uint32_t *last = (uint32_t *)((uintptr_t)m.jit.base + ((uintptr_t)UINT32_MAX - 1) * 4);
        CHECK(hv_jit_metadata_set(&m, &m.slot_site, 0, last) == 0);
        CHECK(((uint32_t *)m.slot_site.entries)[0] == UINT32_MAX);
        CHECK(hv_jit_metadata_get(&m, &m.slot_site, 0) == last);
        m.jit.capacity = (size_t)UINT32_MAX + 1;
        CHECK(!hv_jit_metadata_compact_supported(&m.jit));
        CHECK(hv_jit_metadata_set(&m, &m.slot_site, 0, last) == -1);
        m.jit.base = (uint32_t *)(UINTPTR_MAX - 3);
        m.jit.capacity = 1;
        CHECK(!hv_jit_metadata_compact_supported(&m.jit));
        m.jit.base = (uint32_t *)((uintptr_t)code + 1);
        m.jit.capacity = 32;
        CHECK(!hv_jit_metadata_compact_supported(&m.jit));
        m.jit.base = NULL;
        CHECK(!hv_jit_metadata_compact_supported(&m.jit));
    }
    for (size_t t = 0; t < 3; t++) free(tables[t]->entries);
    memset(&m, 0, sizeof m);
}

static void test_integration(int compact) {
    static HvMachine m;
    static HvCpu cpu;
    Fixture f;
    mode(compact);
    int initialized = fixture_init(&f, &m, &cpu, 37, 4 << 20, NULL);
    CHECK(initialized == 0);
    if (initialized) return;
    CHECK(m.compact_jit_metadata == compact);
    CHECK(m.jit.capacity == (4u << 20) / 4);
    CHECK(m.max_blocks == (4u << 20) / 160);
    CHECK(m.max_slots == m.max_blocks * 2);
    CHECK(hv_jit_metadata_bytes(&m) == (size_t)m.max_slots * 3 * (compact ? 4 : 8));
    CHECK(fixture_run(&f, 1) == 0);
    CHECK(m.stats.chained > 0 && m.nslots > 0);
    CHECK(m.nslots <= m.max_slots);
    for (uint32_t i = 0; i < m.nslots; i++) {
        HvJitMetadata *tables[] = {&m.slot_site, &m.slot_stub, &m.slot_cond};
        for (size_t t = 0; t < 3; t++) {
            uint32_t *p = hv_jit_metadata_get(&m, tables[t], i);
            CHECK(!p || ((uintptr_t)p >= (uintptr_t)m.jit.base &&
                        (uintptr_t)p - (uintptr_t)m.jit.base < m.jit.capacity * 4 && !((uintptr_t)p & 3)));
        }
    }
    uint32_t chained = UINT32_MAX;
    for (uint32_t i = 0; i < m.nslots; i++)
        if (m.slot_xpa[i] == ((f.base + PAGE_BYTES) | 1)) { chained = i; break; }
    CHECK(chained != UINT32_MAX);
    mode(!compact);
    CHECK(m.compact_jit_metadata == compact);
    CHECK(fixture_run(&f, 1) == 0);
    uint64_t translated = m.stats.translations, invalidated = m.stats.flush_smc;
    f.guest[PAGE_BYTES / 4] = UINT32_C(0x91000800);
    hv_invalidate_code(&m, f.base + PAGE_BYTES);
    CHECK(m.stats.flush_smc == invalidated + 1);
    CHECK(m.ram[0].xhead[1] == 0);
    if (chained != UINT32_MAX) {
        uint32_t *site = hv_jit_metadata_get(&m, &m.slot_site, chained);
        uint32_t *stub = hv_jit_metadata_get(&m, &m.slot_stub, chained);
        CHECK(m.slots[chained] == 0 && m.slot_xpa[chained] == 0);
        CHECK(site && stub && *site == branch((uint64_t)(uintptr_t)site, (uint64_t)(uintptr_t)stub));
    }
    CHECK(fixture_run(&f, 2) == 0);
    CHECK(m.stats.translations > translated);
    hv_flush_blocks(&m);
    CHECK(m.nslots == 0 && m.nblocks == 0);
    CHECK(fixture_run(&f, 2) == 0);
    fixture_destroy(&f);
    CHECK(hv_jit_metadata_bytes(&m) == 0);
}

typedef struct RestartWorker {
    Fixture *fixture;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int work, done, stop, result;
} RestartWorker;

static void *restart_worker(void *arg) {
    RestartWorker *w = arg;
    pthread_mutex_lock(&w->mu);
    for (;;) {
        while (!w->work && !w->stop) pthread_cond_wait(&w->cv, &w->mu);
        if (w->stop) break;
        pthread_mutex_unlock(&w->mu);
        int result = fixture_run(w->fixture, 1);
        pthread_mutex_lock(&w->mu);
        w->result = result;
        w->work = 0;
        w->done = 1;
        pthread_cond_signal(&w->cv);
    }
    pthread_mutex_unlock(&w->mu);
    return NULL;
}

static int restart_worker_run(RestartWorker *w) {
    pthread_mutex_lock(&w->mu);
    w->work = 1;
    w->done = 0;
    pthread_cond_signal(&w->cv);
    while (!w->done) pthread_cond_wait(&w->cv, &w->mu);
    int result = w->result;
    pthread_mutex_unlock(&w->mu);
    return result;
}

static void test_reinitialize(int compact) {
    static HvMachine m;
    static HvCpu cpu;
    HvJitRegion prewarm;
    Fixture f;
    RestartWorker worker = {.fixture = &f, .mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER};
    pthread_t thread;
    mode(compact);
    int opened = hv_jit_region_open(&prewarm, 4 << 20);
    CHECK(opened == 0);
    if (opened) return;
    int started = pthread_create(&thread, NULL, restart_worker, &worker);
    CHECK(started == 0);
    if (started) {
        hv_jit_region_close(&prewarm);
        return;
    }
    for (int on_worker = 0; on_worker < 2; on_worker++) {
        for (int supplied = 1; supplied >= 0; supplied--) {
            for (int restart = 0; restart < 2; restart++) {
                size_t bytes = supplied || !restart ? 4 << 20 : 16 << 20;
                int initialized = fixture_init(&f, &m, &cpu, 37, bytes, supplied ? &prewarm : NULL);
                CHECK(initialized == 0);
                if (initialized) continue;
                CHECK(m.jit_gen == 0);
                CHECK(m.jit.used == 0);
                if (supplied) CHECK(m.jit.base == prewarm.base);
                CHECK((on_worker ? restart_worker_run(&worker) : fixture_run(&f, 1)) == 0);
                CHECK(m.jit.used > 0 && m.nblocks > 0);
                for (int i = 0; i < m.nblocks; i++) {
                    uintptr_t code = (uintptr_t)m.blocks[i].code, base = (uintptr_t)m.jit.base;
                    CHECK(code >= base && code - base < m.jit.used * sizeof(uint32_t));
                }
                fixture_destroy(&f);
            }
        }
    }
    pthread_mutex_lock(&worker.mu);
    worker.stop = 1;
    pthread_cond_signal(&worker.cv);
    pthread_mutex_unlock(&worker.mu);
    CHECK(pthread_join(thread, NULL) == 0);
    pthread_cond_destroy(&worker.cv);
    pthread_mutex_destroy(&worker.mu);
    hv_jit_region_close(&prewarm);
}

typedef struct MemoryStats {
    uint64_t footprint, resident, reusable, compressed;
} MemoryStats;

static MemoryStats memory_stats(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) exit(1);
    return (MemoryStats){info.phys_footprint, info.resident_size, info.reusable, info.compressed};
}

static int memory_benchmark(unsigned cache_mib) {
    static HvMachine m;
    static uint32_t code[32];
    memset(&m, 0, sizeof m);
    m.jit.base = code;
    m.jit.capacity = (size_t)cache_mib * 1048576 / 4;
    m.max_blocks = (uint32_t)((size_t)cache_mib * 1048576 / 160);
    if (m.max_blocks < 4096) m.max_blocks = 4096;
    m.max_slots = m.max_blocks * 2;
    const char *setting = getenv("HV_COMPACT_JIT_METADATA");
    m.compact_jit_metadata = setting && atoi(setting) != 0;
    HvJitMetadata *tables[] = {&m.slot_site, &m.slot_stub, &m.slot_cond};
    for (size_t t = 0; t < 3; t++) {
        tables[t]->entries = calloc(m.max_slots, hv_jit_metadata_entry_bytes(&m));
        if (!tables[t]->entries) return 1;
    }
    MemoryStats before = memory_stats();
    double start = now_ms();
    uintptr_t checksum = 0;
    for (uint32_t i = 0; i < m.max_slots; i++)
        for (size_t t = 0; t < 3; t++) {
            uint32_t *p = code + ((i + (uint32_t)t) & 31);
            if (hv_jit_metadata_set(&m, tables[t], i, p) != 0) return 1;
        }
    double touch_ms = now_ms() - start;
    for (uint32_t i = 0; i < m.max_slots; i++)
        for (size_t t = 0; t < 3; t++) {
            uint32_t *p = hv_jit_metadata_get(&m, tables[t], i);
            if (p != code + ((i + (uint32_t)t) & 31)) return 1;
            checksum += (uintptr_t)p - (uintptr_t)code;
        }
    MemoryStats after = memory_stats();
    printf("memory mode=%s cache_mib=%u slots=%u payload_bytes=%zu resident_delta_bytes=%" PRId64
           " footprint_delta_bytes=%" PRId64 " reusable_delta_bytes=%" PRId64
           " compressed_delta_bytes=%" PRId64 " touch_ms=%.3f checksum=%" PRIuPTR "\n",
           m.compact_jit_metadata ? "compact" : "pointer", cache_mib, m.max_slots, hv_jit_metadata_bytes(&m),
           (int64_t)after.resident - (int64_t)before.resident, (int64_t)after.footprint - (int64_t)before.footprint,
           (int64_t)after.reusable - (int64_t)before.reusable, (int64_t)after.compressed - (int64_t)before.compressed,
           touch_ms, checksum);
    for (size_t t = 0; t < 3; t++) free(tables[t]->entries);
    return 0;
}

static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void at_el0(HvCpu *cpu) {
    cpu->el = 0;
    cpu->spsel = 0;
}

static int performance_benchmark(unsigned rounds) {
    static const TestProgram programs[] = {
        TEST_PROGRAM(bench_calls), TEST_PROGRAM(bench_mem), TEST_PROGRAM(bench_dispatch), TEST_PROGRAM(bench_loop),
    };
    static HvMachine m;
    static HvCpu initial, native, jit;
    if (hv_machine_init(&m, 4 << 20) != 0) return 1;
    uint8_t *stack = aligned_alloc(PAGE_BYTES, 65536);
    if (!stack || hv_machine_add_ram(&m, (uint64_t)(uintptr_t)bench_programs_begin,
            bench_programs_finish - bench_programs_begin, (void *)bench_programs_begin, 1) != 0 ||
        hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0) != 0) return 1;
    double times[101];
    for (size_t p = 0; p < sizeof programs / sizeof *programs; p++) {
        memset(&initial, 0, sizeof initial);
        seed_cpu(&initial, p + 1, (uint64_t)(uintptr_t)stack + 32768);
        memset(stack, 0, 65536);
        native = initial;
        hv_native_run(&native, programs[p].native);
        memset(stack, 0, 65536);
        if (run_jit(&m, &programs[p], &initial, &jit, at_el0) != 0 ||
            native.x[0] != jit.x[0] || native.x[5] != jit.x[5]) return 1;
        uint64_t translated = m.stats.translations;
        for (unsigned r = 0; r < rounds; r++) {
            memset(stack, 0, 65536);
            double start = now_ms();
            if (run_jit(&m, &programs[p], &initial, &jit, at_el0) != 0 ||
                native.x[0] != jit.x[0] || native.x[5] != jit.x[5]) return 1;
            times[r] = now_ms() - start;
        }
        qsort(times, rounds, sizeof *times, compare_double);
        printf("bench mode=%s workload=%s median_ms=%.6f min_ms=%.6f rounds=%u retranslations=%" PRIu64
               " slots=%u jit_words=%zu\n", m.compact_jit_metadata ? "compact" : "pointer", programs[p].name,
               times[rounds / 2], times[0], rounds, m.stats.translations - translated, m.nslots, m.jit.used);
    }
    hv_machine_free(&m);
    free(stack);
    Fixture f;
    if (fixture_init(&f, &m, &jit, 8, 16 << 20, NULL) != 0) return 1;
    if (fixture_run(&f, 1) != 0) return 1;
    const unsigned cycles = 1000;
    uint64_t translated = m.stats.translations, chained = m.stats.chained, invalidated = m.stats.flush_smc;
    for (unsigned r = 0; r < rounds; r++) {
        double start = now_ms();
        for (unsigned i = 0; i < cycles; i++) {
            unsigned increment = 1 + (i & 1);
            f.guest[PAGE_BYTES / 4] = UINT32_C(0x91000000) | increment << 10;
            hv_invalidate_code(&m, f.base + PAGE_BYTES);
            if (fixture_run(&f, increment) != 0) return 1;
        }
        times[r] = now_ms() - start;
    }
    qsort(times, rounds, sizeof *times, compare_double);
    printf("bench mode=%s workload=translate_chain_invalidate median_ms=%.6f min_ms=%.6f rounds=%u cycles=%u"
           " translations=%" PRIu64 " chains=%" PRIu64 " invalidations=%" PRIu64 " flushes=%" PRIu64
           " slots=%u jit_words=%zu\n", m.compact_jit_metadata ? "compact" : "pointer",
           times[rounds / 2], times[0], rounds, cycles, m.stats.translations - translated,
           m.stats.chained - chained, m.stats.flush_smc - invalidated, m.stats.flush_full, m.nslots, m.jit.used);
    fixture_destroy(&f);
    return 0;
}

static unsigned argument_count(const char *text, unsigned limit) {
    char *end;
    errno = 0;
    unsigned long n = strtoul(text, &end, 10);
    if (errno || !*text || *end || !n || n > limit) {
        fprintf(stderr, "invalid count: %s\n", text);
        exit(1);
    }
    return (unsigned)n;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "--memory") == 0)
        return memory_benchmark(argc > 2 ? argument_count(argv[2], 1536) : 512);
    if (argc > 1 && strcmp(argv[1], "--bench") == 0)
        return performance_benchmark(argc > 2 ? argument_count(argv[2], 101) : 9);
    if (argc == 2 && strcmp(argv[1], "--reinitialize") == 0) {
        const char *setting = getenv("HV_COMPACT_JIT_METADATA");
        test_reinitialize(setting && atoi(setting) != 0);
        printf("JIT reinitialize: %d checks, %d failures\n", checks, failures);
        return failures != 0;
    }
    if (argc != 1) return 1;
    const char *original = getenv("HV_COMPACT_JIT_METADATA");
    char *saved = original ? strdup(original) : NULL;
    test_storage(0);
    test_storage(1);
    test_integration(0);
    test_integration(1);
    test_reinitialize(0);
    test_reinitialize(1);
    if (saved) { setenv("HV_COMPACT_JIT_METADATA", saved, 1); free(saved); }
    else unsetenv("HV_COMPACT_JIT_METADATA");
    printf("JIT metadata: %d checks, %d failures (pointer and compact)\n", checks, failures);
    return failures != 0;
}
