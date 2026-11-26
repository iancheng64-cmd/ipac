/* Inject delayed peer replies; measure the waiter's CPU time, not guest FPS. */
#include "machine.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

static HvMachine machine;
static HvCpu sender, peer;
static atomic_int ready, done, saw_park;

static void *answer(void *unused) {
    (void)unused;
    HvPerCpu *p = peer.pc_state;
    __atomic_store_n(&p->tlb_live, 1, __ATOMIC_SEQ_CST);
    atomic_store(&ready, 1);
    while (!atomic_load(&done)) {
        if (__atomic_load_n(&p->req_seq, __ATOMIC_ACQUIRE) ==
            __atomic_load_n(&p->ack_seq, __ATOMIC_RELAXED)) {
            sched_yield();
            continue;
        }
        struct timespec delay = {.tv_nsec = 500000};
        nanosleep(&delay, NULL);
        if (__atomic_load_n(&p->ack_waiters, __ATOMIC_SEQ_CST))
            atomic_fetch_add(&saw_park, 1);
        hv_cpu_process_requests(&peer);
    }
    return NULL;
}

static void sample(int mode, int hot, int expect_park) {
    const int rounds = 240;
    hv_knob[HV_K_SYNCWAIT] = mode;
    hv_set_host_thermal_pressure(hot);
    atomic_store(&saw_park, 0);
    uint64_t wall = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    for (int i = 0; i < rounds; ++i) {
        uint64_t seq = hv_cpu_post_tlbi(&peer, 0, 8, 3, 1, (uint64_t)i << 2);
        hv_cpu_sync(&sender, &peer, seq);
        assert(__atomic_load_n(&peer.pc_state->ack_seq, __ATOMIC_ACQUIRE) == seq);
    }
    cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu;
    wall = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - wall;
    int parked = atomic_load(&saw_park);
    assert((parked != 0) == expect_park);
    printf("mode=%d hot=%d acks=%d observed_parks=%d waiter_cpu_ms=%.3f wall_ms=%.3f\n",
           mode, hot, rounds, parked, cpu / 1e6, wall / 1e6);
}

int main(void) {
    if (hv_machine_init(&machine, 4 << 20) != 0) return 1;
    hv_cpu_reset_index(&sender, &machine, 0);
    hv_cpu_reset_index(&peer, &machine, 1);
    pthread_t worker;
    if (pthread_create(&worker, NULL, answer, NULL)) return 1;
    while (!atomic_load(&ready)) sched_yield();
    sample(0, 1, 0);
    sample(2, 1, 1);
    sample(2, 0, 0);
    sample(1, 0, 1);
    sample(2, 1, 1);
    sample(2, 0, 0);
    atomic_store(&done, 1);
    pthread_join(worker, NULL);
    hv_machine_free(&machine);
    return 0;
}
