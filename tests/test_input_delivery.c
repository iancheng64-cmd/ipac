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

/* Give an endpoint no guest transfers until after the entire input burst. */
static void drain(HvXhci *x, int dev, unsigned slots, unsigned stride) {
    memset(guest, 0, sizeof guest);
    x->slots[1].dev = dev;
    x->slots[1].ep_running[2] = 1;
    x->slots[1].ep[2].dequeue = 0x1000;
    x->slots[1].ep[2].ccs = 1;
    for (unsigned i = 0; i < slots; i++) {
        uint32_t trb[4] = {0x3000u + stride * i, 0, stride, 1 << 10 | 1};
        memcpy((uint8_t *)guest + i * 16, trb, sizeof trb);
    }
    hv_xhci_poll(x);
}

static unsigned sample_ms(const uint8_t *r) {
    return (r[9] >> 3) | ((unsigned)r[10] << 5) | ((unsigned)r[11] << 13);
}

static int sample_x(const uint8_t *f) {
    int x = f[0] | ((f[1] & 0x1f) << 8);
    return (x & 0x1000 ? x - 0x2000 : x) + HV_TP_SENSOR_X / 2;
}

static void stalled_input(void) {
    HvXhci x = {.m = &machine};
    pthread_mutex_init(&x.mu, NULL);
    x.tp_rhead = x.tp_rtail = UINT32_MAX - 19;
    hv_xhci_touch(&x, 1, 0, 200, 500, 100);
    hv_xhci_touch(&x, 2, 0, 800, 500, 101);
    for (int i = 1; i <= 180; ++i) {
        int pos = i <= 90 ? i : 180 - i; /* one finger reverses while the other keeps moving */
        hv_xhci_touch(&x, 1, 1, 200 + pos, 500, 101 + 8 * i);
        hv_xhci_touch(&x, 2, 1, 800 + i, 500, 101 + 8 * i);
        hv_xhci_touch_frame(&x, 101 + 8 * i);
    }
    hv_xhci_touch(&x, 1, 2, 0, 0, 1550);
    hv_xhci_touch(&x, 2, 2, 0, 0, 1551);
    hv_xhci_touch_button(&x, 1);
    hv_xhci_touch_button(&x, 0);
    drain(&x, 1, HV_TP_REPORTS, 64);
    const uint8_t *out = (const uint8_t *)guest + 0x2000;
    unsigned n = (unsigned)x.tp_delivered;
    assert(n >= 10 && n <= HV_TP_REPORTS && x.tp_rhead == x.tp_rtail);
    assert(out[(n-1)*64+7] == 2 && out[(n-2)*64+1] == 1 && out[(n-1)*64+1] == 0);
    assert(out[12+8] % 16 == 1 && out[64+21+8] % 16 == 2);
    assert(sample_ms(out) == 100 && sample_ms(out + 64) == 101);
    /* The last two motion samples still have their original speed and two-finger geometry. */
    const uint8_t *last = out + (n - 7) * 64, *prev = last - 64;
    assert(sample_ms(prev) == 101 + 8 * 179 && sample_ms(last) == 101 + 8 * 180);
    assert(sample_x(last+12) == 200 && sample_x(last+21) == 980);
    assert(sample_x(prev+12) == 201 && sample_x(prev+21) == 979);
    int reversed = 0;
    for (unsigned i = 1; i < n - 6; i++) {
        const uint8_t *p = out + i * 64;
        if (sample_ms(p) == 101 + 8 * 90 && sample_x(p+12) == 290 && sample_x(p+21) == 890) reversed++;
    }
    assert(reversed == 1);
    assert((last[64+15] >> 5) == 7 && (last[64+24] >> 5) == 4);
    assert((last[2*64+12+8] & 15) == 2 && (last[3*64+15] >> 5) == 7 && last[4*64+7] == 2);
    for (unsigned i = 1; i < n - 2; i++) assert(sample_ms(out + i*64) > sample_ms(out + (i-1)*64));
    printf("stalled pad: %u USB reports, final two of 180 motion samples plus all release/button edges delivered\n", n);

    /* A stall filled only with edges has no disposable movement; still deliver the final released state. */
    x.tp_rhead = x.tp_rtail = x.tp_delivered = 0;
    for (int i = 0; i < HV_TP_REPORTS + 1; ++i) hv_xhci_touch_button(&x, !(i & 1));
    drain(&x, 1, HV_TP_REPORTS, 64);
    assert(x.tp_delivered == HV_TP_REPORTS && out[(HV_TP_REPORTS-1)*64+1] == 1);
    hv_xhci_touch_button(&x, 0);
    drain(&x, 1, HV_TP_REPORTS, 64);
    assert(x.tp_delivered == HV_TP_REPORTS + 1 && out[1] == 0);

    for (int i = 0; i < HV_XHCI_REPORTS - 1; ++i) hv_xhci_key(&x, 4, !(i & 1));
    hv_xhci_key(&x, 0xe1, 1);
    hv_xhci_key(&x, 0xe1, 0);
    hv_xhci_key(&x, 4, 0);
    drain(&x, 0, HV_XHCI_REPORTS, 8);
    assert(x.delivered == HV_XHCI_REPORTS && !memcmp(out + (HV_XHCI_REPORTS - 1)*8, (uint8_t[8]){0}, 8));
    pthread_mutex_destroy(&x.mu);
}

static void saved_input_validation(void) {
    HvXhci x = {0};
    x.tp_rhead = UINT32_MAX;
    x.tp_rtail = x.tp_rhead + 2;
    x.tp_rlen[0] = HV_TP_REPORT_LEN;
    x.tp_rlen[1] = 255; /* inactive slots may contain old bytes */
    for (unsigned len = 0; len <= UINT8_MAX; len++) {
        x.tp_rlen[HV_TP_REPORTS - 1] = (uint8_t)len;
        assert(hv_xhci_input_state_valid(&x) == (len >= 12 && len <= HV_TP_REPORT_LEN && (len-12)%9 == 0));
    }
    x.tp_rlen[HV_TP_REPORTS - 1] = 12;
    x.tp_rtail = x.tp_rhead + HV_TP_REPORTS + 1;
    assert(!hv_xhci_input_state_valid(&x));
    x.tp_rtail = x.tp_rhead;
    x.rtail = HV_XHCI_REPORTS + 1;
    assert(!hv_xhci_input_state_valid(&x));
    x.rtail = HV_XHCI_REPORTS;
    x.tp_f1_len = -1;
    assert(!hv_xhci_input_state_valid(&x));
    x.tp_f1_len = sizeof x.tp_f1 + 1;
    assert(!hv_xhci_input_state_valid(&x));
    x.tp_f1_len = sizeof x.tp_f1;
    assert(hv_xhci_input_state_valid(&x));
}

int main(void) {
    assert(!hv_machine_add_ram(&machine, 0x1000, sizeof(guest), guest, 0));
    machine.stats_interval = 1;
    mouse_reports();
    touch_reports();
    stalled_input();
    saved_input_validation();
    hv_machine_free(&machine);
    puts("input delivery: identical mouse events, 3 -> 1 wakes; two-finger movement: one wake, all seven USB reports delivered");
    return 0;
}
