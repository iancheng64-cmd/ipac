#ifndef HENGEVM_DISK_H
#define HENGEVM_DISK_H

#include <stdint.h>
#include <sys/uio.h>

/* A raw disk image file, optionally starting `offset` bytes in (QEMU's vmapple
   notes say the first 16 KB of auxiliary.bin is metadata the guest never sees). */
typedef struct HvDisk {
    int fd;
    int wfd;         /* writes, past the host's cache (F_NOCACHE); -1: through fd */
    uint64_t offset;
    uint64_t size;   /* bytes visible to the guest */
    int readonly;
} HvDisk;

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly);
void hv_disk_close(HvDisk *d);
/* Return 0, or -1 on an I/O error or an access past the end. */
int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len);
/* Reads into scratch vectors; may advance them on a short read. Returns bytes actually read. */
uint64_t hv_disk_readv(HvDisk *d, uint64_t off, struct iovec *vec, int count);
/* Preflights the full range. Like readv, consumes scratch vectors on short I/O. */
uint64_t hv_disk_writev(HvDisk *d, uint64_t off, struct iovec *vec, int count);
int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len);
int hv_disk_flush(HvDisk *d);
/* A lifecycle boundary always requests a file sync, regardless of the guest's flush policy. */
int hv_disk_sync(HvDisk *d);

#endif
