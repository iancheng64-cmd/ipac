/* Per-task indexed object lookup for the serial Metal replay worker.
   Eliminates NSNumber boxing and NSDictionary hashing on hot draw/bind calls,
   while falling back cleanly to an NSMutableDictionary for ref >= HV_PVG_FAST_OBJECT_LIMIT. */
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

enum { HV_PVG_FAST_OBJECT_LIMIT = 8192 };

@interface HvTaskObjectTable : NSObject {
@public
    CFTypeRef *slots;
    uint32_t capacity;
    NSMutableDictionary<NSNumber *, id> *overflow;
}
- (id)objectForRef:(uint32_t)ref;
- (void)setObject:(id)obj forRef:(uint32_t)ref;
- (void)removeObjectForRef:(uint32_t)ref;
- (void)forEachObject:(void (^)(id obj))block;
- (void)removeAllObjects;
@end

static inline NSMutableDictionary<NSNumber *, id> *hv_pvg_ensure_overflow(HvTaskObjectTable *t) {
    if (!t->overflow) t->overflow = [NSMutableDictionary new];
    return t->overflow;
}

#ifdef HV_PVG_DEFINE_OBJECT_TABLE
@implementation HvTaskObjectTable

- (void)dealloc {
    [self removeAllObjects];
}

- (BOOL)ensureCapacity:(uint32_t)need {
    if (need <= capacity) return YES;
    uint32_t cap = capacity ? capacity : 64;
    while (cap < need) cap *= 2;
    if (cap > HV_PVG_FAST_OBJECT_LIMIT) cap = HV_PVG_FAST_OBJECT_LIMIT;
    size_t oldBytes = (size_t)capacity * sizeof(CFTypeRef);
    size_t newBytes = (size_t)cap * sizeof(CFTypeRef);
    void *mem = realloc((void *)slots, newBytes);
    if (!mem) return NO;
    memset((uint8_t *)mem + oldBytes, 0, newBytes - oldBytes);
    slots = (CFTypeRef *)mem;
    capacity = cap;
    return YES;
}

- (id)objectForRef:(uint32_t)ref {
    if (ref < capacity) return slots[ref] ? (__bridge id)slots[ref] : nil;
    if (ref >= HV_PVG_FAST_OBJECT_LIMIT && overflow) return overflow[@(ref)];
    return nil;
}

- (void)setObject:(id)obj forRef:(uint32_t)ref {
    if (ref < HV_PVG_FAST_OBJECT_LIMIT) {
        if (!obj && ref >= capacity) return;
        if (ref < capacity || [self ensureCapacity:ref + 1]) {
            CFTypeRef next = obj ? CFBridgingRetain(obj) : NULL;
            CFTypeRef prev = slots[ref];
            slots[ref] = next;
            if (prev) CFRelease(prev);
            return;
        }
    }
    NSMutableDictionary<NSNumber *, id> *dict = hv_pvg_ensure_overflow(self);
    if (obj) dict[@(ref)] = obj;
    else [dict removeObjectForKey:@(ref)];
}

- (void)removeObjectForRef:(uint32_t)ref {
    if (ref < capacity) {
        CFTypeRef prev = slots[ref];
        slots[ref] = NULL;
        if (prev) CFRelease(prev);
        return;
    }
    if (ref >= HV_PVG_FAST_OBJECT_LIMIT) [overflow removeObjectForKey:@(ref)];
}

- (void)forEachObject:(void (^)(id obj))block {
    if (!block) return;
    for (uint32_t i = 0; i < capacity; i++) {
        if (slots[i]) block((__bridge id)slots[i]);
    }
    if (overflow) {
        for (NSNumber *key in overflow) {
            id obj = overflow[key];
            if (obj) block(obj);
        }
    }
}

- (void)removeAllObjects {
    if (slots) {
        for (uint32_t i = 0; i < capacity; i++) {
            if (slots[i]) {
                CFRelease(slots[i]);
                slots[i] = NULL;
            }
        }
        free((void *)slots);
        slots = NULL;
        capacity = 0;
    }
    [overflow removeAllObjects];
    overflow = nil;
}

@end
#endif
