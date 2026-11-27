/* A warmed temporary host file. Pass --write for cached gather writes, not durable storage throughput. */
#include "disk.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { PAGE = 16384, PARTS = 8, SIZE = 8 << 20, RUNS = 1024, PAIRS = 9 };
static uint8_t source[SIZE], scratch[PARTS][PAGE * 2];
static uint64_t clock_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static double run(HvDisk *disk, int parts, int vector, int writing, unsigned seed) {
    uint64_t t0 = clock_ns();
    size_t off = 0;
    for (int i = 0; i < RUNS; i++) {
        seed = seed * 1664525u + 1013904223u;
        off = (seed % (SIZE / PAGE - parts + 1)) * PAGE;
        if (vector) {
            struct iovec vec[PARTS];
            for (int k = 0; k < parts; k++) vec[k] = (struct iovec){scratch[k], PAGE};
            uint64_t done = writing ? hv_disk_writev(disk, off, vec, parts) : hv_disk_readv(disk, off, vec, parts);
            if (done != (size_t)parts * PAGE) abort();
        } else {
            for (int k = 0; k < parts; k++)
                if (writing ? hv_disk_write(disk, off + k * PAGE, scratch[k], PAGE)
                            : hv_disk_read(disk, off + k * PAGE, scratch[k], PAGE)) abort();
        }
    }
    uint64_t elapsed = clock_ns() - t0;
    for (int k = 0; k < parts; k++) {
        if (writing) {
            uint8_t verify[PAGE];
            if (hv_disk_read(disk, off + k * PAGE, verify, PAGE) || memcmp(scratch[k], verify, PAGE)) abort();
        } else if (memcmp(scratch[k], source + off + k * PAGE, PAGE)) abort();
    }
    return (double)elapsed / RUNS / 1000;
}

static int compare(const void *a, const void *b) {
    double l = *(const double *)a, r = *(const double *)b;
    return (l > r) - (l < r);
}
int main(int argc, char **argv) {
    int writing = argc == 2 && !strcmp(argv[1], "--write");
    if (argc != 1 && !writing) return 2;
    const char *tmp = getenv("TMPDIR");
    char path[1024];
    int n = snprintf(path, sizeof path, "%s/henge-scatter.XXXXXX", tmp ? tmp : "/tmp");
    if (n < 0 || (size_t)n >= sizeof path) return 1;
    int fd = mkstemp(path);
    if (fd == -1) return 1;
    unlink(path);
    HvDisk disk = { .fd = fd, .wfd = -1, .size = SIZE };
    unsigned generator = 3221;
    for (int i = 0; i < SIZE; i++) {
        generator = generator * 1664525u + 1013904223u;
        source[i] = (uint8_t)(generator >> 24);
    }
    if (hv_disk_write(&disk, 0, source, SIZE) != 0 || hv_disk_sync(&disk) != 0) return 1;
    for (int k = 0; k < PARTS; k++) memcpy(scratch[k], source + k * PAGE, PAGE);
    for (int parts = 1; parts <= PARTS; parts = parts == 1 ? 4 : parts * 2) {
        run(&disk, parts, 0, writing, 0); run(&disk, parts, 1, writing, 0);
        double rounds[2][PAIRS], ratios[PAIRS];
        for (int i = 0; i < PAIRS; i++) {
            int first = i & 1;
            rounds[first][i] = run(&disk, parts, first, writing, (unsigned)i);
            rounds[!first][i] = run(&disk, parts, !first, writing, (unsigned)i);
            ratios[i] = rounds[1][i] / rounds[0][i];
        }
        qsort(rounds[0], PAIRS, sizeof(double), compare);
        qsort(rounds[1], PAIRS, sizeof(double), compare);
        qsort(ratios, PAIRS, sizeof(double), compare);
        printf("%s %d x 16 KiB; scalar %.3f us, vector %.3f us, paired median change %+.1f%%\n",
               writing ? "write" : "read", parts, rounds[0][PAIRS/2], rounds[1][PAIRS/2], (ratios[PAIRS/2] - 1) * 100);
    }
    hv_disk_close(&disk);
    return 0;
}
