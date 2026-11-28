#include <fcntl.h>
#include <errno.h>
#include <TargetConditionals.h>
#include "../core/machine.h"
#include "disk.h"

#include <limits.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>

#define DISK_IO_CHUNK (128u << 20)

int hv_disk_open(HvDisk *d, const char *path, uint64_t offset, int readonly) {
    d->wfd = -1;
    d->fd = open(path, readonly ? O_RDONLY : O_RDWR);
    if (d->fd < 0) return -1;
    struct stat st;
    if (fstat(d->fd, &st) != 0 || (uint64_t)st.st_size < offset) {
        close(d->fd);
        d->fd = -1;
        return -1;
    }
    d->offset = offset;
    d->size = (uint64_t)st.st_size - offset;
    d->readonly = readonly;
    (void)fcntl(d->fd, F_RDAHEAD, 1);
#if TARGET_OS_IPHONE
    /* Keep host UBC active by default so reads/writes benefit from kernel caching; opt into F_NOCACHE only via HV_DISK_NOCACHE=1. */
    const char *nc = getenv("HV_DISK_NOCACHE");
    if (nc && atoi(nc) > 0) {
        (void)fcntl(d->fd, F_NOCACHE, 1);
    }
#endif
    /* HV_WRITE_CACHE=0: writes skip the host's cache (F_NOCACHE), so a long run of them cannot pile up
       gigabytes of dirty pages; reads stay cached, and the kernel keeps the two coherent. Off by default:
       on the Mac bench big writes took 2-3x as long that way (2 GB + sync 4-6 s -> 9-17 s) and everyday
       work was no faster. The phone's installer turns it on for the restore, which writes ~15 GB at once. */
    const char *wc = getenv("HV_WRITE_CACHE");
    if (!readonly && wc && !atoi(wc)) {
        d->wfd = open(path, O_RDWR);
        if (d->wfd >= 0 && fcntl(d->wfd, F_NOCACHE, 1) == -1) {
            close(d->wfd);
            d->wfd = -1;
        }
    }
    return 0;
}

void hv_disk_close(HvDisk *d) {
    if (d->fd >= 0) close(d->fd);
    if (d->wfd >= 0) close(d->wfd);
    d->fd = d->wfd = -1;
}

int hv_disk_read(HvDisk *d, uint64_t off, void *buf, uint64_t len) {
    if (off > d->size || len > d->size - off) return -1;
    uint8_t *p = buf;
    while (len) {
        size_t count = len > DISK_IO_CHUNK ? DISK_IO_CHUNK : (size_t)len;
        ssize_t n = pread(d->fd, p, count, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        off += (uint64_t)n;
        len -= (uint64_t)n;
    }
    return 0;
}

static uint64_t disk_transferv(HvDisk *d, uint64_t off, struct iovec *vec, int count, int write_op) {
    if (off > d->size || (write_op && d->readonly)) return 0;
    int fd = write_op && d->wfd >= 0 ? d->wfd : d->fd;
    uint64_t remaining = d->size - off, done = 0;
    for (int i = 0; i < count; i++) {
        if (vec[i].iov_len > remaining) return 0;
        remaining -= vec[i].iov_len;
    }
    while (count > 0) {
        if (!vec->iov_len) { vec++; count--; continue; }
        size_t bytes = vec->iov_len < DISK_IO_CHUNK ? vec->iov_len : DISK_IO_CHUNK;
        int nvec = 1;
        while (nvec < count && nvec < IOV_MAX && bytes < DISK_IO_CHUNK && vec[nvec].iov_len <= DISK_IO_CHUNK - bytes)
            bytes += vec[nvec++].iov_len;
        off_t at = (off_t)(d->offset + off + done);
        ssize_t n;
        if (write_op)
            n = nvec == 1 ? pwrite(fd, vec->iov_base, bytes, at) : pwritev(fd, vec, nvec, at);
        else
            n = nvec == 1 ? pread(fd, vec->iov_base, bytes, at) : preadv(fd, vec, nvec, at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (size_t)n;
        size_t moved = (size_t)n;
        while (count && vec->iov_len <= moved) {
            moved -= vec->iov_len;
            vec++; count--;
        }
        if (moved) {
            vec->iov_base = (uint8_t *)vec->iov_base + moved;
            vec->iov_len -= moved;
        }
    }
    return done;
}

uint64_t hv_disk_readv(HvDisk *d, uint64_t off, struct iovec *vec, int count) {
    return disk_transferv(d, off, vec, count, 0);
}

uint64_t hv_disk_writev(HvDisk *d, uint64_t off, struct iovec *vec, int count) {
    return disk_transferv(d, off, vec, count, 1);
}

int hv_disk_write(HvDisk *d, uint64_t off, const void *buf, uint64_t len) {
    if (d->readonly || off > d->size || len > d->size - off) return -1;
    const uint8_t *p = buf;
    while (len) {
        size_t count = len > DISK_IO_CHUNK ? DISK_IO_CHUNK : (size_t)len;
        ssize_t n = pwrite(d->wfd >= 0 ? d->wfd : d->fd, p, count, (off_t)(d->offset + off));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        off += (uint64_t)n;
        len -= (uint64_t)n;
    }
    return 0;
}

int hv_disk_sync(HvDisk *d) {
    if (d->readonly) return 0;
    int rc;
    do { rc = fsync(d->fd); } while (rc == -1 && errno == EINTR);
    return rc;
}

/* HV_FLUSH: 0 fsync; 1 nothing here, what was written is safe in the host's cache as long as the
   host runs; 2 fcntl(F_BARRIERFSYNC). */
int hv_disk_flush(HvDisk *d) {
    if (d->readonly) return 0;
    switch (hv_knob[HV_K_FLUSH]) {
    case 1: return 0;
    case 2: return fcntl(d->fd, F_BARRIERFSYNC) == -1 ? -1 : 0;
    default: return hv_disk_sync(d);
    }
}
