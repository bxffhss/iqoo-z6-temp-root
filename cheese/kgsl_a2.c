/* kgsl_a2.c — A2: MAP_USER_MEM(0x15) 对齐字段(flags bits16-23 = 指数)定向实测   §CQ
 *
 * 背景(源码级结论):
 *   - gpumem_alloc_entry(GPUOBJ_ALLOC) 对对齐字段有显式上界: (flags & 0xFF0000) > 0x180000 -> dev_err + sanitize
 *     ⇒ 指数被封在 <=24
 *   - kgsl_ioctl_map_user_mem(0x15/0x20) 的掩码是 0x91FFFF08, **没有该上界**
 *   - map_user_mem 在 0x10a7a8e4 汇合点按 size 反写对齐: >=2MB->21, >=1MB->20, >=64KB->6,
 *     **<64KB -> 完全不碰, 用户传的 bits16-23 原样保留**
 *   - 消费点 kgsl_iommu_get_gpuaddr: align = max(1 << ((flags>>16)&0xffff), 0x1000)   [32 位 lsl, 零扩展]
 *
 * 测量设计:
 *   对每个指数 exp, 用同一个 host 页连做两次 MAP_USER_MEM(len=0x1000 <64KB 以保留用户 flags),
 *   比较两次拿到的 gpuaddr 间距。
 *   - exp=0  (基线)  间距应很小(页级)
 *   - exp=N  间距应约等于 2^N(第二次被推到下一个对齐边界) => 对齐字段确实到达了 VA 分配器
 *   - exp=31 若生效 => 间距约 2GiB
 *
 * 结构(48B, 与 0x15 的 _IOC_SIZE 一致):
 *   int fd@0x00 | u64 gpuaddr@0x08 | size_t len@0x10 | size_t offset@0x18
 *   u64 hostptr@0x20 | u32 memtype@0x28 | u32 flags@0x2c
 *
 * 安全: 只做映射, 不下发 GPU 命令; 每步后做存活 canary(重开 /dev/kgsl-3d0)。
 *       内核 oops 会重启设备 -> 每行立即 fflush, 指数从小到大(最危险的 31 放最后)。
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>

#define CMD_MAP_USER_MEM  0xc0300915u   /* nr=0x15, size 48, dir=RW */
#define CMD_DEV_GETPROP   0xc0180902u   /* 存活 canary 用 */

#define MEMTYPE_ADDR 2

static int g_fd = -1;

/* 存活 canary: 重新 open 一次并做一次已知可用的只读 ioctl */
static int alive(void) {
    int f = open("/dev/kgsl-3d0", O_RDWR);
    if (f < 0) { printf("      [canary] open 失败 errno=%d\n", errno); return 0; }
    unsigned char p[24];
    memset(p, 0, sizeof(p));
    /* DEVICE_GETPROPERTY: type@0(u32)=1 (DEVICE_INFO) */
    *(uint32_t *)p = 1;
    errno = 0;
    int r = ioctl(f, CMD_DEV_GETPROP, p);
    printf("      [canary] ok ret=%d errno=%d chip_id=0x%08x\n", r, errno, *(uint32_t *)(p + 12));
    close(f);
    return 1;
}

static unsigned long long do_map(void *host, unsigned long long len,
                                 unsigned int flags, int *pret, int *perrno) {
    unsigned char b[48];
    memset(b, 0, sizeof(b));
    *(int32_t *)(b + 0x00) = -1;                        /* fd */
    *(uint64_t *)(b + 0x08) = 0;                        /* gpuaddr (出) */
    *(uint64_t *)(b + 0x10) = len;
    *(uint64_t *)(b + 0x18) = 0;                        /* offset */
    *(uint64_t *)(b + 0x20) = (uint64_t)(uintptr_t)host; /* hostptr */
    *(uint32_t *)(b + 0x28) = MEMTYPE_ADDR;
    *(uint32_t *)(b + 0x2c) = flags;
    errno = 0;
    int r = ioctl(g_fd, CMD_MAP_USER_MEM, b);
    *pret = r; *perrno = errno;
    uint64_t ga = 0;
    memcpy(&ga, b + 0x08, 8);
    (void)ga;
    return ga;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== kgsl_a2: MAP_USER_MEM 对齐字段定向实测 ===\n");

    g_fd = open("/dev/kgsl-3d0", O_RDWR);
    if (g_fd < 0) { printf("open /dev/kgsl-3d0 失败 errno=%d\n", errno); return 1; }
    printf("open ok fd=%d\n", g_fd);
    alive();

    void *host = mmap(NULL, 0x2000, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (host == MAP_FAILED) { printf("mmap 失败 errno=%d\n", errno); return 1; }
    memset(host, 0x41, 0x2000);
    printf("host=%p (页对齐=%d)\n\n", host, ((uintptr_t)host & 0xfff) == 0);

    /* 指数从小到大; 末位放 31(最危险) */
    static const int exps[] = { 0, 8, 13, 16, 20, 24, 31 };
    const int LEN = 0x1000;   /* < 64KB => map_user_mem 不会覆盖用户 flags */

    for (unsigned i = 0; i < sizeof(exps)/sizeof(exps[0]); i++) {
        unsigned int flags = (unsigned int)(exps[i] << 16);
        int r1, e1, r2, e2;

        printf("[exp=%2d] flags=0x%08x\n", exps[i], flags);

        unsigned long long ga1 = do_map(host, LEN, flags, &r1, &e1);
        printf("   A: ret=%d errno=%-3d gpuaddr=0x%llx\n", r1, e1, ga1);

        unsigned long long ga2 = do_map(host, LEN, flags, &r2, &e2);
        printf("   B: ret=%d errno=%-3d gpuaddr=0x%llx\n", r2, e2, ga2);

        if (r1 == 0 && r2 == 0)
            printf("   >> 间距 = 0x%llx  (%llu MB)\n",
                   ga2 - ga1, (ga2 - ga1) >> 20);
        else
            printf("   >> 未双成功, 无法测间距\n");

        alive();
        printf("\n");
    }

    printf("=== 完成, 设备存活 ===\n");
    close(g_fd);
    return 0;
}
