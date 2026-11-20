/* kgsl_objinfo2.c — 反推 GPUOBJ_INFO(0x47,48B) 结构 + GPUOBJ_SET_INFO(0x4c,32B) 试探
 * 1) 0x45 分配对象拿 id
 * 2) id 放各候选偏移调 0x47 → 找出内核读 id 的位置, 并读回 gpuaddr
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

#define CMD_ALLOC     0xc0300945u   /* GPUOBJ_ALLOC   48B */
#define CMD_INFO      0xc0300947u   /* GPUOBJ_INFO    48B */
#define CMD_SET_INFO  0xc020094cu   /* GPUOBJ_SET_INFO 32B */
#define CMD_IMPORT    0xc0200948u   /* GPUOBJ_IMPORT  32B */

static int fd;
static void dw(const unsigned char *b, int n) {
    for (int i = 0; i < n; i += 8) {
        unsigned long long v; memcpy(&v, b + i, 8);
        printf(" [%02d]0x%016llx", i, v);
    }
    printf("\n");
}
/* 分配一个对象, 返回 id (0 表示失败) */
static unsigned alloc_obj(unsigned long long size, unsigned long long flags, unsigned long long valen,
                          unsigned long long *size_out, unsigned long long *flags_out) {
    unsigned char b[64]; memset(b, 0, sizeof(b));
    memcpy(b + 0, &size, 8); memcpy(b + 8, &flags, 8); memcpy(b + 16, &valen, 8);
    errno = 0;
    int r = ioctl(fd, CMD_ALLOC, b);
    unsigned id = 0; memcpy(&id, b + 32, 4);
    if (size_out)  memcpy(size_out, b + 24, 8);
    if (flags_out) memcpy(flags_out, b + 8, 8);
    printf("  ALLOC size=0x%llx flags=0x%llx -> ret=%d errno=%d id=%u mmapsize=0x%llx\n",
           size, flags, r, errno, id, size_out ? *size_out : 0ULL);
    return r == 0 ? id : 0;
}

int main(void) {
    fd = open("/dev/kgsl-3d0", O_RDWR);
    if (fd < 0) { printf("open fail %d\n", errno); return 1; }
    unsigned long long ms = 0, fo = 0;
    printf("== 1) 分配对象 ==\n");
    unsigned id = alloc_obj(0x1000, 0, 0x1000, &ms, &fo);
    if (!id) { printf("alloc 失败, 终止\n"); return 1; }

    printf("\n== 2) GPUOBJ_INFO: id 放各候选偏移 ==\n");
    int offs[] = {0, 4, 8, 16, 24, 32, 40};
    for (unsigned k = 0; k < sizeof(offs)/sizeof(offs[0]); k++) {
        unsigned char b[64]; memset(b, 0, sizeof(b));
        int o = offs[k];
        if (o == 4) { unsigned t = id; memcpy(b+o, &t, 4); }
        else { unsigned long long t = id; memcpy(b + o, &t, 8); }
        errno = 0;
        int r = ioctl(fd, CMD_INFO, b);
        printf("  id@%-2d ret=%d errno=%-3d", o, r, errno);
        if (r == 0) { printf("  <<< 成功"); }
        printf("\n"); dw(b, 48);
    }

    printf("\n== 3) GPUOBJ_SET_INFO(0x4c,32B) 试探(id@0, flags=0) ==\n");
    for (int fl = 0; fl < 3; fl++) {
        unsigned char b[64]; memset(b, 0, sizeof(b));
        unsigned long long t = id; memcpy(b + 0, &t, 8);
        unsigned long long f = (fl == 0) ? 0 : (fl == 1 ? 1 : 2);
        memcpy(b + 8, &f, 8);
        errno = 0;
        int r = ioctl(fd, CMD_SET_INFO, b);
        printf("  flags=%llu ret=%d errno=%d\n", f, r, errno);
        dw(b, 32);
    }

    printf("\n== 4) 再查 INFO(用最可能成功的偏移) ==\n");
    {
        unsigned char b[64]; memset(b, 0, sizeof(b));
        unsigned long long t = id; memcpy(b + 8, &t, 8);
        errno = 0;
        int r = ioctl(fd, CMD_INFO, b);
        printf("  ret=%d errno=%d\n", r, errno);
        dw(b, 48);
    }
    close(fd);
    printf("\ndone alive\n");
    return 0;
}
