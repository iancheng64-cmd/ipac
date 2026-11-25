"""Host-only regression for the production iOS JIT availability lifecycle.

Compile the allocator's post-mapping tail and lifecycle functions unchanged.
Only mapping operations and executable-code validation are stubbed; no device.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "ios/Henge/Native/henge-ios-jit.c"
)


def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin + len(start))].strip()


PREFIX = r"""
#include "henge-ios-jit.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#define HENGE_LOG(...) do {} while (0)
typedef uintptr_t vm_address_t;
typedef size_t vm_size_t;
static atomic_bool g_jit_available;
static _Thread_local bool g_expecting_jit_trap;
static HengeDualMapping henge_prewarmed, last_candidate;
static bool henge_prewarm_done, injected_selftest, live_during_selftest;
static unsigned allocations, deallocations, detachments, failures;
static vm_address_t released[4];
static uintptr_t mach_task_self(void) { return 0; }
static int vm_deallocate(uintptr_t task, vm_address_t address, vm_size_t bytes) {
    (void)task; (void)bytes;
    if (deallocations >= 4) abort();
    released[deallocations++] = address;
    return 0;
}
static void henge_brk_jit_detach(void) { detachments++; }
static void henge_ios_hold_high(void) {}
void henge_ios_jit_log_footprint(const char *tag) { (void)tag; }
static bool henge_jit_selftest(const HengeDualMapping *mapping) {
    last_candidate = *mapping;
    live_during_selftest = henge_ios_jit_is_available();
    return injected_selftest;
}
static HengeDualMapping henge_ios_jit_allocate_real(size_t bytes) {
    HengeDualMapping region = {NULL, NULL, 0};
    uint64_t n = ++allocations;
    void *rx = (void *)(uintptr_t)(0x10000 + n * 0x40000);
    vm_address_t rw = (vm_address_t)(uintptr_t)rx + 0x10000;
"""


CHECKS = r"""
static void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int mode = atoi(argv[1]);
    if (mode == 0) {
        check(!henge_ios_jit_is_available(), "fresh process is unavailable");
        return failures != 0;
    }
    injected_selftest = mode != 1;
    bool warm = henge_ios_jit_prewarm(16384);
    if (mode == 1) {
        check(!warm && henge_prewarmed.rw_addr == NULL, "failed prewarm");
        check(deallocations == 2 && henge_prewarmed.size == 0, "both views released");
        check(released[0] == (vm_address_t)last_candidate.rw_addr &&
              released[1] == (vm_address_t)last_candidate.rx_addr, "failed candidate released");
        check(!henge_ios_jit_is_available(), "failed selftest cannot advertise JIT");
        check(!henge_ios_jit_prewarm(16384) && allocations == 1, "failure is one-shot");
        return failures != 0;
    }
    check(warm && henge_ios_jit_is_available(), "successful prewarm is live");
    HengeDualMapping held = henge_prewarmed;
    if (mode == 2) {
        check(!live_during_selftest, "do not publish before validation finishes");
        check(henge_ios_jit_prewarm(16384) && allocations == 1, "success is one-shot");
    } else if (mode == 3) {
        henge_ios_jit_detach();
        check(detachments == 1 && !g_expecting_jit_trap, "detach completes");
        check(deallocations == 0 && henge_ios_jit_is_available(), "detach retains JIT");
    } else if (mode == 4) {
        injected_selftest = false;
        HengeDualMapping rejected = henge_ios_jit_allocate_real(16384);
        check(!rejected.rw_addr && !rejected.rx_addr && !rejected.size, "candidate rejected");
        check(deallocations == 2 && henge_ios_jit_is_available(), "prior mapping stays live");
        check(last_candidate.rw_addr != held.rw_addr &&
              last_candidate.rx_addr != held.rx_addr, "new candidate has distinct views");
        check(released[0] == (vm_address_t)last_candidate.rw_addr &&
              released[1] == (vm_address_t)last_candidate.rx_addr, "only candidate views released");
    } else {
        return 2;
    }
    check(held.rw_addr == henge_prewarmed.rw_addr &&
          held.rx_addr == henge_prewarmed.rx_addr &&
          held.size == henge_prewarmed.size, "held mapping is retained");
    return failures != 0;
}
"""


class IOSJITAvailabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SOURCE.read_text()
        tail = section(
            source, "    region.rw_addr = (uint8_t *)rw;",
            "\nvoid henge_ios_jit_release(HengeDualMapping *m)",
        )
        functions = [
            section(source, start, end)
            for start, end in [
                ("void henge_ios_jit_release(HengeDualMapping *m)\n{",
                 "\nvoid henge_ios_jit_detach(void)"),
                ("void henge_ios_jit_detach(void)\n{",
                 "\nbool henge_ios_jit_is_available(void)"),
                ("bool henge_ios_jit_is_available(void)\n{",
                 "\n/* ------------------------------------------------------------- MAP_JIT probe */"),
                ("HENGE_EXPORT bool henge_ios_jit_prewarm(size_t bytes)\n{",
                 "\n/*\n * Before iOS 26, without a trap:"),
            ]
        ]
        temporary = tempfile.TemporaryDirectory(prefix="ipac-jit-state-test-")
        cls.addClassCleanup(temporary.cleanup)
        cls.binary = str(Path(temporary.name) / "test")
        build = subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
             "-I", str(SOURCE.parent), "-x", "c", "-", "-o", cls.binary],
            input=PREFIX + tail + "\n" + "\n".join(functions) + CHECKS,
            text=True, capture_output=True, timeout=30,
        )
        if build.returncode:
            raise RuntimeError(build.stderr)

    def run_case(self, mode):
        result = subprocess.run(
            [self.binary, str(mode)], text=True, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fresh_process_is_unavailable(self):
        self.run_case(0)

    def test_failed_selftest_stays_unavailable_and_is_one_shot(self):
        self.run_case(1)

    def test_success_publishes_only_after_selftest(self):
        self.run_case(2)

    def test_detach_retains_verified_mapping(self):
        self.run_case(3)

    def test_rejected_candidate_does_not_revoke_live_mapping(self):
        self.run_case(4)


if __name__ == "__main__":
    unittest.main()
