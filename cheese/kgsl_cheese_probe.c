/* kgsl_cheese_probe.c — cheese 链路分辨实验(§20 待办 2/3 延伸)
 * 用 cheese 原版参数(ctx=0x1812, MAP_USER_MEM ADDR, GPU_COMMAND flags=0)回答:
 *   Test A: IB = CP_MEM_WRITE 写真实映射的 output gpuaddr → CPU 侧可见?
 *   Test B: IB 指向无映射 VA 0xDEAD0000 → trace 有无 hard fault? (取指行为判定)
 *   Test C: CP_MEM_TO_MEM GPU 侧拷贝 → CPU 侧可见?
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

#define CP_SET_MODE 0x63

static int kgsl_ctx_create0(int fd, uint32_t *ctx_id) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    int ret = ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &req);
    if (ret) return ret;
    *ctx_id = req.drawctxt_id;
    return 0;
}

static int kgsl_map(int fd, unsigned long addr, size_t len, uint64_t *gpuaddr) {
    struct kgsl_map_user_mem req = {
        .len = len, .offset = 0, .hostptr = addr,
        .memtype = KGSL_USER_MEM_TYPE_ADDR,
    };
    int ret = ioctl(fd, IOCTL_KGSL_MAP_USER_MEM, &req);
    if (ret) return ret;
    *gpuaddr = req.gpuaddr;
    return 0;
}

/* 与 cheese 相同: n 个 IB 条目, flags=0, cmdsize=sizeof(object) */
static int gpu_command(int fd, uint32_t ctx_id, uint64_t ib_gpuaddr, uint32_t ib_size) {
    struct kgsl_command_object cmds[1];
    struct kgsl_gpu_command req;
    memset(cmds, 0, sizeof(cmds));
    cmds[0].flags = KGSL_CMDLIST_IB;
    cmds[0].gpuaddr = ib_gpuaddr;
    cmds[0].size = ib_size;
    memset(&req, 0, sizeof(req));
    req.context_id = ctx_id;
    req.cmdsize = sizeof(struct kgsl_command_object);
    req.numcmds = 1;
    req.cmdlist = (unsigned long)cmds;
    int err = ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &req);
    printf("  GPU_COMMAND(0x4A) ret=%d errno=%d ts=%u\n", err, err ? errno : 0, req.timestamp);
    return err;
}

/* legacy 0x10 路径 */
typedef struct { uint64_t gpuaddr, hostptr; uint32_t sizedwords, ctrl; } ibdesc_t;
typedef struct { uint32_t drawctxt_id, pad; uint64_t ibdesc_addr; uint32_t numibs, timestamp, flags, pad2; } issueib_t;

static int issue_ib(int fd, uint32_t ctx_id, uint64_t gpuaddr, uint32_t sizedwords) {
    ibdesc_t d;
    issueib_t is;
    memset(&d, 0, sizeof(d));
    d.gpuaddr = gpuaddr; d.sizedwords = sizedwords;
    memset(&is, 0, sizeof(is));
    is.drawctxt_id = ctx_id;
    is.ibdesc_addr = (uint64_t)(uintptr_t)&d;
    is.numibs = 1;
    int err = ioctl(fd, _IOWR(0x09, 0x10, issueib_t), &is);
    printf("  RISSUEIBCMDS(0x10) ret=%d errno=%d ts=%u\n", err, err ? errno : 0, is.timestamp);
    return err;
}

static void sync_from_gpu(void *start, void *end) {
    uint64_t clsz = 64;
    uint64_t ctr_el0; asm("mrs\t%x0, ctr_el0" : "=r"(ctr_el0));
    clsz = 4 << ((ctr_el0 >> 16) & 0xf);
    start = (char*)((uintptr_t)start & ~(clsz - 1));
    for (; start < end; start += clsz)
        __asm volatile("dc civac, %0" : : "r" (start) : "memory");
    __asm volatile("dsb ish" ::: "memory");
}

static void sync_to_gpu(void *start, void *end) {
    uint64_t clsz = 64;
    uint64_t ctr_el0; asm("mrs\t%x0, ctr_el0" : "=r"(ctr_el0));
    clsz = 4 << ((ctr_el0 >> 16) & 0xf);
    start = (char*)((uintptr_t)start & ~(clsz - 1));
    for (; start < end; start += clsz)
        __asm volatile("dc cvac, %0" : : "r" (start) : "memory");
    __asm volatile("dsb ish" ::: "memory");
}

int main(void) {
    int fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open kgsl fail\n"); return 1; }

    uint32_t ctx;
    if (kgsl_ctx_create0(fd, &ctx)) { printf("ctx fail: %s\n", strerror(errno)); return 1; }
    printf("[0] ctx=%u\n", ctx);

    uint32_t *ib_buf = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    uint32_t *out_buf = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib_buf, 0, 0x1000);
    memset(out_buf, 0, 0x1000);

    uint64_t ib_ga, out_ga;
    if (kgsl_map(fd, (unsigned long)ib_buf, 0x1000, &ib_ga)) { printf("map ib fail: %s\n", strerror(errno)); return 1; }
    if (kgsl_map(fd, (unsigned long)out_buf, 0x1000, &out_ga)) { printf("map out fail: %s\n", strerror(errno)); return 1; }
    printf("[0] ib_ga=0x%llx out_ga=0x%llx\n", (unsigned long long)ib_ga, (unsigned long long)out_ga);

    /* ---- Test A: CP_MEM_WRITE → 真实映射 out_ga+0x100, GPU_COMMAND flags=0 ---- */
    {
        uint32_t *c = ib_buf;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(out_ga + 0x100);
        *c++ = upper_32_bits(out_ga + 0x100);
        *c++ = 0x41414141;
        sync_to_gpu(ib_buf, ib_buf + 0x100);
        printf("[A] CP_MEM_WRITE -> out_ga+0x100 (0x4A, flags=0):\n");
        if (!gpu_command(fd, ctx, ib_ga, 16)) { sleep(1); sync_from_gpu(out_buf, out_buf + 0x1000);
            printf("    out_buf[0x40] = 0x%08x %s\n", out_buf[0x40], out_buf[0x40] == 0x41414141 ? "<<< GPU 执行!!!" : "(未变)"); }
    }

    /* ---- Test A2: legacy 0x10 路径同内容 ---- */
    {
        memset(out_buf, 0, 0x1000);
        uint32_t *c = ib_buf;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(out_ga + 0x100);
        *c++ = upper_32_bits(out_ga + 0x100);
        *c++ = 0x42424242;
        sync_to_gpu(ib_buf, ib_buf + 0x100);
        printf("[A2] 同 IB 经 0x10 legacy 路径:\n");
        if (!issue_ib(fd, ctx, ib_ga, 4)) { sleep(1); sync_from_gpu(out_buf, out_buf + 0x1000);
            printf("    out_buf[0x40] = 0x%08x %s\n", out_buf[0x40], out_buf[0x40] == 0x42424242 ? "<<< GPU 执行!!!" : "(未变)"); }
    }

    /* ---- Test B: 无映射 VA — 取指行为判定 ---- */
    {
        printf("[B] cmdlist gpuaddr=0xDEAD0000 (无映射):\n");
        int r = gpu_command(fd, ctx, 0xDEAD0000ULL, 16);
        printf("    -> 看 trace: 有 fault = GPU 真取指; 无 fault = 该路径不执行 IB\n");
        (void)r; sleep(1);
    }

    /* ---- Test C: CP_MEM_TO_MEM out+0x200 <- out+0x300(先 CPU 写入 0xCAFEBABE) ---- */
    {
        out_buf[0xC0] = 0xCAFEBABE;
        sync_to_gpu(out_buf, out_buf + 0x1000);
        uint32_t *c = ib_buf;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x200); *c++ = upper_32_bits(out_ga + 0x200);
        *c++ = lower_32_bits(out_ga + 0x300); *c++ = upper_32_bits(out_ga + 0x300);
        sync_to_gpu(ib_buf, ib_buf + 0x100);
        printf("[C] CP_MEM_TO_MEM out+0x200 <- out+0x300:\n");
        if (!gpu_command(fd, ctx, ib_ga, 24)) { sleep(1); sync_from_gpu(out_buf, out_buf + 0x1000);
            printf("    out_buf[0x80] = 0x%08x %s\n", out_buf[0x80], out_buf[0x80] == 0xCAFEBABE ? "<<< GPU 执行!!!" : "(未变)"); }
    }

    printf("done, ctx=%u alive\n", ctx);
    return 0;
}
