/* kgsl_objalloc.c — GPUOBJ_ALLOC(0x3c) flags 位扫描 + 成功后的 INFO/SET_INFO
 * 带上合法的 metadata 指针(避免 EFAULT), 逐位试 flags
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>

#define CMD_GPUOBJ_ALLOC    0xc0300945u
#define CMD_GPUOBJ_INFO     0xc0300947u
#define CMD_GPUOBJ_SET_INFO 0xc020094cu
#define CMD_GPUOBJ_FREE     0x40200946u

static int fd;
static unsigned char meta[128];

static void dumpw(const unsigned char *b, int n) {
    for (int i = 0; i < n; i += 8) {
        unsigned long long v; memcpy(&v, b + i, 8);
        printf(" [%02d]0x%016llx", i, v);
    }
    printf("\n");
}

/* 布局假设(据既往实测): size@0 flags@8 va_len@16 mmapsize@24 id@32 metadata_len@36 metadata@40 */
static int try_alloc(unsigned long long size, unsigned long long flags,
                     unsigned long long va_len, unsigned char *out) {
    memset(out, 0, 64);
    memcpy(out + 0,  &size,   8);
    memcpy(out + 8,  &flags,  8);
    memcpy(out + 16, &va_len, 8);
    unsigned long long mp = (unsigned long long)(uintptr_t)meta;
    memcpy(out + 40, &mp, 8);
    errno = 0;
    return ioctl(fd, CMD_GPUOBJ_ALLOC, out);
}

int main(void) {
    fd = open("/dev/kgsl-3d0", O_RDWR);
    if (fd < 0) { printf("open fail errno=%d\n", errno); return 1; }
    memset(meta, 0x11, sizeof(meta));
    unsigned char b[64];

    printf("== flags 单比特扫描 (size=4K va_len=4K, metadata=合法指针) ==\n");
    printf("flags        ret errno  buffer\n");
    unsigned long long cands[40];
    int n = 0;
    for (int i = 0; i < 32; i++) cands[n++] = (1ULL << i);
    cands[n++] = 0;
    cands[n++] = 0x10000000ULL;   /* USE_CPU_MAP(既往实测值) */
    for (int i = 0; i < n; i++) {
        int r = try_alloc(0x1000, cands[i], 0x1000, b);
        int e = errno;
        printf("0x%09llx  %3d %-5d ", cands[i], r, e);
        if (r == 0) printf("<<< 成功! ");
        dumpw(b, 48);
        if (r == 0) {
            /* INFO 查询刚分配的对象 */
            unsigned char c[64]; memset(c, 0, sizeof(c));
            memcpy(c, b, 48);
            errno = 0;
            int ri = ioctl(fd, CMD_GPUOBJ_INFO, c);
            printf("      INFO ret=%d errno=%d ->", ri, errno);
            dumpw(c, 48);
        }
        fflush(stdout);
    }
    close(fd);
    printf("\ndone alive\n");
    return 0;
}
