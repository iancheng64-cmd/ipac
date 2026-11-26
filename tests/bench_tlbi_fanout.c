/* Timed host microbenchmark for the posted (not inline) TLB invalidation path.
   Run build/bench_tlbi_fanout 4, 6, or 8. This measures all-active fanout, not guest FPS. */
#include "machine.h"
#include <mach/mach_time.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static HvMachine machine;
static HvCpu cpus[HV_MAX_CPUS];
static atomic_int ready, done;

static void *receiver(void *arg) {
    HvCpu *cpu = arg;
    __atomic_store_n(&cpu->pc_state->tlb_live, 1, __ATOMIC_SEQ_CST);
    atomic_fetch_add(&ready, 1);
    while (!atomic_load_explicit(&done, memory_order_relaxed))
        hv_cpu_process_requests(cpu);
    return NULL;
}

static int broadcasts(int count, int rounds) {
    uint64_t seq[HV_MAX_CPUS];
    for (int r = 0; r < rounds; ++r) {
        /* VAE1IS, one page, as if every remote CPU needed to handle this invalidation itself. */
        for (int c = 1; c < count; ++c)
            seq[c] = hv_cpu_post_tlbi(&cpus[c], 0, 8, 3, 1, (uint64_t)(r & 255) << 2);
        for (int c = 1; c < count; ++c) {
            hv_cpu_sync(&cpus[0], &cpus[c], seq[c]);
            if (__atomic_load_n(&cpus[c].pc_state->ack_seq, __ATOMIC_ACQUIRE) != seq[c]) return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "4") && strcmp(argv[1], "6") && strcmp(argv[1], "8"))) return 2;
    int count = argv[1][0] - '0';
    if (hv_machine_init(&machine, 4 << 20) != 0) return 1;
    pthread_t workers[HV_MAX_CPUS];
    for (int c = 0; c < count; ++c) {
        hv_cpu_reset_index(&cpus[c], &machine, (uint32_t)c);
        if (c && pthread_create(&workers[c], NULL, receiver, &cpus[c]) != 0) return 1;
    }
    while (atomic_load(&ready) < count - 1) sched_yield();
    if (broadcasts(count, 1000) != 0) return 1;
    const int rounds = 8000;
    uint64_t start = mach_absolute_time();
    int result = broadcasts(count, rounds);
    uint64_t elapsed = mach_absolute_time() - start;
    atomic_store(&done, 1);
    for (int c = 1; c < count; ++c) pthread_join(workers[c], NULL);
    hv_machine_free(&machine);
    if (result != 0) return 1;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    printf("{\"cpus\":%d,\"broadcasts\":%d,\"acks\":%d,\"us_per_broadcast\":%.3f}\n",
           count, rounds, rounds * (count - 1), (double)elapsed * timebase.numer / timebase.denom / (1000.0 * rounds));
    return 0;
}
