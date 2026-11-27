/* The serial Metal worker decodes one immutable guest command snapshot at a time.
   Grow its storage geometrically; a single very large command must not raise the
   long-term footprint. The decoder uses the command length, not buffer.length. */
#import <Foundation/Foundation.h>

enum { HV_COMMAND_CACHE_LIMIT = 256 * 1024 };

static inline NSMutableData *hv_pvg_command_storage(NSMutableData *__strong *cache, NSUInteger size) {
    if (size > HV_COMMAND_CACHE_LIMIT) return [[NSMutableData alloc] initWithLength:size];
    if ((*cache).length < size) {
        NSUInteger capacity = 4096;
        while (capacity < size) capacity *= 2;
        *cache = [[NSMutableData alloc] initWithLength:capacity];
    }
    return *cache;
}
