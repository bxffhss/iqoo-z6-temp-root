/* kgsl_cheese_probe3.c — §20 待办 4: GPUOBJ_ALLOC + USE_CPU_MAP(0x10000000)
 * 该对象 CPU mmap 是 EINVAL, 用 GPU→GPU 拷贝验证其 GPU 可达性:
 *   out(0xCAFEBABE) --CP_MEM_WRITE--> cpu_map_obj+0
 *   cpu_map_obj+0   --MEM_TO_MEM-->  out+0x400   (回读判定)
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

static uint64_t g_clsz;
static void cache_op(void *start, void *end, int inval) {
    start = (char*)((uintptr_t)start & ~(g_clsz - 1));
    for (; start < end; start += g_clsz) {
        if (inval) __asm volatile("dc civac, %0" : : "r" (start) : "memory");
        else       __asm volatile("dc cvac, %0"  : : "r" (start) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
}

struct kgsl_gpuobj_alloc { uint64_t size, flags; uint32_t va_len, va_flags, mmapsize, id; };
typedef struct { uint32_t id, pad; uint64_t gpuaddr; } gpuobj_info_t;

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
    if (err) printf("    GPU_COMMAND ret=%d errno=%d(%s)\n", err, errno, strerror(errno));
    else printf("    GPU_COMMAND ok ts=%u\n", req.timestamp);
    return err;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);

    int fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open fail\n"); return 1; }

    uint32_t ctx;
    if (ctx_create(fd, &ctx)) { printf("ctx fail\n"); return 1; }
    printf("ctx=%u\n", ctx);

    uint32_t *out = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(out, 0, 0x1000);
    uint64_t out_ga;
    if (kgsl_map(fd, (unsigned long)out, 0x1000, &out_ga)) { printf("map out fail\n"); return 1; }
    printf("out ga=0x%llx\n", (unsigned long long)out_ga);

    /* GPUOBJ_ALLOC flags = USE_CPU_MAP */
    struct kgsl_gpuobj_alloc ga;
    memset(&ga, 0, sizeof(ga));
    ga.size = 0x1000;
    ga.flags = KGSL_MEMFLAGS_USE_CPU_MAP;
    int r = ioctl(fd, _IOWR(0x09, 0x45, struct kgsl_gpuobj_alloc), &ga);
    printf("GPUOBJ_ALLOC(USE_CPU_MAP) ret=%d errno=%d id=%u mmapsize=%u\n", r, r ? errno : 0, ga.id, ga.mmapsize);
    if (r) {
        /* 对照: 不带 flag */
        memset(&ga, 0, sizeof(ga));
        ga.size = 0x1000;
        r = ioctl(fd, _IOWR(0x09, 0x45, struct kgsl_gpuobj_alloc), &ga);
        printf("GPUOBJ_ALLOC(plain) ret=%d id=%u mmapsize=%u\n", r, ga.id, ga.mmapsize);
        if (r) return 1;
    }

    /* GPUOBJ_INFO 查 gpuaddr */
    struct { uint32_t id, pad; uint64_t gpuaddr; } gi;
    uint64_t obj_ga = 0;
    if (!r) {
        memset(&gi, 0, sizeof(gi));
        gi.id = ga.id;
        if (!ioctl(fd, _IOWR(0x09, 0x47, gpuobj_info_t), &gi)) {
            obj_ga = gi.gpuaddr;
            printf("GPUOBJ_INFO gpuaddr=0x%llx\n", (unsigned long long)obj_ga);
        } else printf("GPUOBJ_INFO fail errno=%d\n", errno);
    }

    /* mmap 该对象(CPU_MAP 对象预期 EINVAL, 但试一下) */
    void *m = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_SHARED, fd, (off_t)obj_ga);
    printf("mmap(obj) = %p (errno=%d %s)\n", m, m == MAP_FAILED ? errno : 0, m == MAP_FAILED ? strerror(errno) : "");

    /* GPU 写入与回读 */
    uint32_t *ib = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x1000);
    uint64_t ib_ga;
    if (kgsl_map(fd, (unsigned long)ib, 0x1000, &ib_ga)) { printf("map ib fail\n"); return 1; }

    out[0] = 0xCAFEBABE;
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 0);

    /* 步骤1: out[0] -> obj_ga+0 (若 obj_ga=0 且对象在 gpuaddr 0, 直接测) */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(obj_ga);
    *c++ = upper_32_bits(obj_ga);
    *c++ = 0x1D1D1D1D;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("[step1] CP_MEM_WRITE -> obj(0x%llx) = 0x1D1D1D1D:\n", (unsigned long long)obj_ga);
    gpu_command(fd, ctx, ib_ga, 16);
    sleep(1);

    /* 步骤2: obj_ga -> out+0x400 */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
    *c++ = 0;
    *c++ = lower_32_bits(out_ga + 0x400); *c++ = upper_32_bits(out_ga + 0x400);
    *c++ = lower_32_bits(obj_ga);         *c++ = upper_32_bits(obj_ga);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("[step2] MEM_TO_MEM out+0x400 <- obj:\n");
    if (!gpu_command(fd, ctx, ib_ga, 24)) {
        sleep(1);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("  out[0x100] = 0x%08x %s\n", out[0x100],
               out[0x100] == 0x1D1D1D1D ? "<<< USE_CPU_MAP 对象 GPU 可达!!!" : "(未变)");
    }

    /* 对照: 用 ADDR 映射缓冲直接走同样两步(证明流程本身有效) */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(out_ga + 0x800);
    *c++ = upper_32_bits(out_ga + 0x800);
    *c++ = 0x2E2E2E2E;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("[ctrl] 对照 CP_MEM_WRITE -> out+0x800 = 0x2E2E2E2E:\n");
    if (!gpu_command(fd, ctx, ib_ga, 16)) {
        sleep(1);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("  out[0x200] = 0x%08x %s\n", out[0x200], out[0x200] == 0x2E2E2E2E ? "<<< 流程有效" : "(未变)");
    }

    printf("done alive\n");
    return 0;
}
