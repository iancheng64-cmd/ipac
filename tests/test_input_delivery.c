#include "virtio_input.h"
#include "xhci.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Real virtio / xHCI input paths; count device wakes without running a guest CPU. */
static HvMachine machine;
static HvVirtioInput mouse;
static HvXhci pad;
static uint32_t guest[4096];

static void mouse_reports(void) {
    mouse.vio.m = &machine;
    pthread_mutex_init(&mouse.mu, NULL);
    const HvInputEvent axes[] = {{HV_EV_REL, HV_REL_X, -9}, {HV_EV_REL, HV_REL_Y, 3}};
    const HvInputEvent syn = {HV_EV_SYN, 0, 0};
    _Static_assert(sizeof(HvInputEvent) == 8, "mouse event wire size");

    for (int i = 0; i < 2; i++)
        hv_virtio_input_send(&mouse, axes[i].type, axes[i].code, axes[i].value);
    hv_virtio_input_send(&mouse, syn.type, syn.code, syn.value);
    assert(machine.stats.kick_src[3] == 3 && mouse.tail == 3);
    hv_virtio_input_report(&mouse, axes, 2);
    assert(machine.stats.kick_src[3] == 4 && mouse.tail == 6);
    assert(!memcmp(mouse.ring, mouse.ring + 3, 3 * sizeof(*axes)));
    hv_virtio_input_report(&mouse, NULL, 0);
    assert(machine.stats.kick_src[3] == 4 && mouse.tail == 6);

    mouse.head = mouse.tail = UINT32_MAX - 1;
    hv_virtio_input_report(&mouse, axes, 2);
    assert(mouse.tail == 1 && mouse.dropped == 0);
    assert(!memcmp(&mouse.ring[HV_VINPUT_RING - 2], axes, sizeof(axes)));
    assert(!memcmp(&mouse.ring[0], &syn, sizeof(syn)));
    pthread_mutex_destroy(&mouse.mu);
}

static void touch_reports(void) {
    pad.m = &machine;
    pthread_mutex_init(&pad.mu, NULL);
    pad.slots[1].dev = 1;
    pad.slots[1].ep_running[2] = 1;
    pad.slots[1].ep[2].dequeue = 0x1000;
    pad.slots[1].ep[2].ccs = 1;
    for (int i = 0; i < 7; i++) {
        uint32_t trb[4] = {0x2000 + 64u * i, 0, 64, 1 << 10 | 1};
        memcpy((uint8_t *)guest + 16 * i, trb, sizeof(trb));
    }
    machine.stats.kick_src[3] = 0;
    hv_xhci_touch(&pad, 1, 0, 300, 500, 10);
    hv_xhci_touch(&pad, 2, 0, 900, 500, 11);
    hv_xhci_touch(&pad, 1, 1, 310, 505, 18);
    hv_xhci_touch(&pad, 2, 1, 910, 505, 18);
    assert(pad.tp_rtail == 2 && machine.stats.kick_src[3] == 2);
    hv_xhci_touch_frame(&pad, 18);
    assert(pad.tp_rtail == 3 && machine.stats.kick_src[3] == 3);
    hv_xhci_touch(&pad, 1, 2, 0, 0, 21);
    hv_xhci_touch(&pad, 2, 2, 0, 0, 21);
    assert(pad.tp_rtail == 7 && machine.stats.kick_src[3] == 5);
    hv_xhci_poll(&pad);
    assert(pad.tp_delivered == 7 && pad.tp_rhead == pad.tp_rtail);
    assert(pad.tp_multi_logs == (getenv("HV_XHCI_LOG") ? 3u : 0u));
    const uint8_t *delivered = (const uint8_t *)guest + 0x1000;
    assert(pad.tp_rlen[2] == 30 && !memcmp(delivered + 2 * 64, pad.tp_reports[2], 30));
    assert(pad.tp_rlen[6] == 12 && !memcmp(delivered + 6 * 64, pad.tp_reports[6], 12));
    assert(pad.tp_ts == 24);
    pthread_mutex_destroy(&pad.mu);
}

int main(void) {
    assert(!hv_machine_add_ram(&machine, 0x1000, sizeof(guest), guest, 0));
    machine.stats_interval = 1;
    mouse_reports();
    touch_reports();
    hv_machine_free(&machine);
    puts("input delivery: identical mouse events, 3 -> 1 wakes; two-finger movement: one wake, all seven USB reports delivered");
    return 0;
}
