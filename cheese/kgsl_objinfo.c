/* kgsl_objinfo.c — 反推 GPUOBJ_INFO(0x40) / GPUOBJ_ALLOC(0x3c) 的内核结构体布局
 * 方法: 调用前把缓冲填成已知图案, 调用后对比 → 被改写的位置 = 内核输出字段
 * 全程只做 4KB 分配与查询, 不下发 GPU 命令, 风险低
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

#define CMD_GPUOBJ_ALLOC 0xc018093cu   /* size 24 */
#define CMD_GPUOBJ_INFO  0xc0100940u   /* size 16 */
#define CMD_GPUOBJ_SET_INFO 0xc0100941u
#define CMD_GPUOBJ_FREE  0xc0180942u

static void dump(const char *tag, unsigned char *b, int n) {
    printf("  %-14s", tag);
    for (int i = 0; i < n; i++) {
        if (i && i % 8 == 0) printf("\n                ");
        printf(" %02x", b[i]);
    }
    printf("\n");
}
static void dumpw(const char *tag, unsigned char *b, int n) {
    printf("  %-14s", tag);
    for (int i = 0; i < n; i += 8) {
        unsigned long long v = 0;
        memcpy(&v, b + i, 8);
        printf(" [%02d]0x%016llx", i, v);
        if (i % 32 == 24) printf("\n                ");
    }
    printf("\n");
}

int main(void) {
    int fd = open("/dev/kgsl-3d0", O_RDWR);
    if (fd < 0) { printf("open fail errno=%d\n", errno); return 1; }
    unsigned char b[64];

    /* ---- 1) GPUOBJ_INFO 零填充(上一轮返回成功) ---- */
    printf("== 1) GPUOBJ_INFO(0x40) 零填充 ==\n");
    memset(b, 0, sizeof(b));
    errno = 0;
    int r = ioctl(fd, CMD_GPUOBJ_INFO, b);
    printf("  ret=%d errno=%d\n", r, errno);
    dumpw("after:", b, 24);

    /* ---- 2) GPUOBJ_INFO 带图案 → 看内核写哪些位置 ---- */
    printf("\n== 2) GPUOBJ_INFO 带图案(0xA5) ==\n");
    memset(b, 0xA5, sizeof(b));
    errno = 0;
    r = ioctl(fd, CMD_GPUOBJ_INFO, b);
    printf("  ret=%d errno=%d\n", r, errno);
    dumpw("after:", b, 24);

    /* ---- 3) GPUOBJ_ALLOC: 试探布局 ---- */
    printf("\n== 3) GPUOBJ_ALLOC(0x3c) 试探 ==\n");
    struct { const char *name; unsigned long long a, b_, c; } tries[] = {
        {"size=4K flags=0 va_len=4K", 0x1000, 0, 0x1000},
        {"size=4K flags=0 va_len=0  ", 0x1000, 0, 0},
        {"size=4K flags=8 va_len=4K ", 0x1000, 8, 0x1000},
        {"size=0   flags=0 va_len=4K ", 0, 0, 0x1000},
    };
    for (unsigned i = 0; i < sizeof(tries)/sizeof(tries[0]); i++) {
        memset(b, 0, sizeof(b));
        memcpy(b + 0,  &tries[i].a,   8);
        memcpy(b + 8,  &tries[i].b_,  8);
        memcpy(b + 16, &tries[i].c,   8);
        errno = 0;
        int rr = ioctl(fd, CMD_GPUOBJ_ALLOC, b);
        printf("  [%s] ret=%d errno=%d\n", tries[i].name, rr, errno);
        dumpw("    buf:", b, 40);
        if (rr == 0) {
            /* 拿到 id 后查 INFO */
            unsigned char c2[64]; memset(c2, 0, sizeof(c2));
            memcpy(c2, b, 24);            /* 原样带过去(id 在缓冲里) */
            errno = 0;
            int ri = ioctl(fd, CMD_GPUOBJ_INFO, c2);
            printf("    → GPUOBJ_INFO(带 alloc 结果) ret=%d errno=%d\n", ri, errno);
            dumpw("    info:", c2, 40);
        }
    }
    close(fd);
    printf("\ndone alive\n");
    return 0;
}
