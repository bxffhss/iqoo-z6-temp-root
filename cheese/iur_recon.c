/* iur_recon.c — 利用面侦察: 验证 reclaim 喷射原语与可达子系统
 * 1) BPF filter (SO_ATTACH_FILTER): 受控内容 alloc/free, len*8B → 任意小类
 * 2) binder: /dev/binder open + BINDER_VERSION (节点/引用对象是 kzalloc 普通类)
 * 3) eventfd / timerfd / signalfd / evdev / perf / uinput 可用性
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <linux/filter.h>
/* NDK 无 linux/binder.h, 手写所需常量 */
#include <sys/ioctl.h>
#define BINDER_VERSION _IOWR('b', 1, __s32)

int main(void){
    /* ---- 1) BPF filter 喷射原语 ---- */
    for (unsigned len = 1; len <= 16; len <<= 1){
        struct sock_filter *ins = calloc(len, sizeof(struct sock_filter));
        /* 末条必须是 RET 才能通过 classic BPF 校验; k 用小值避免校验限制 */
        for (unsigned i=0;i<len;i++) ins[i] = (struct sock_filter){ BPF_LD|BPF_W|BPF_ABS, 0, 0, 0x40u };
        ins[len-1] = (struct sock_filter){ BPF_RET|BPF_K, 0, 0, 0 };
        struct sock_fprog prog = { .len = (unsigned short)len, .filter = ins };
        int s2 = socket(AF_INET, SOCK_DGRAM, 0);   /* 每次新 socket, 避免 attach 冲突 */
        int r = setsockopt(s2, SOL_SOCKET, SO_ATTACH_FILTER, &prog, sizeof(prog));
        printf("ATTACH_FILTER(len=%u → kmalloc-%zu) = %d errno=%d\n",
               len, len*8, r, errno);
        if (r == 0){
            int zero=0; int r2 = setsockopt(s2, SOL_SOCKET, SO_DETACH_FILTER, &zero, sizeof(zero));
            printf("  DETACH = %d errno=%d\n", r2, errno);
        }
        close(s2);
        free(ins);
    }
    /* 压力: 200 次 attach/detach (kmalloc-128), 新 socket 循环 */
    struct sock_filter ins16[16];
    for (int i=0;i<16;i++) ins16[i] = (struct sock_filter){ BPF_LD|BPF_W|BPF_ABS, 0, 0, 0x40u };
    ins16[15] = (struct sock_filter){ BPF_RET|BPF_K, 0, 0, 0 };
    struct sock_fprog prog16 = { .len = 16, .filter = ins16 };
    int ok = 0;
    for (int i=0;i<200;i++){
        int s2 = socket(AF_INET, SOCK_DGRAM, 0);
        int zero=0; if (setsockopt(s2, SOL_SOCKET, SO_ATTACH_FILTER, &prog16, sizeof(prog16)) == 0 &&
            setsockopt(s2, SOL_SOCKET, SO_DETACH_FILTER, &zero, sizeof(zero)) == 0) ok++;
        close(s2);
    }
    printf("stress attach/detach x200 (kmalloc-128): %d/200\n", ok);

    /* ---- 2) binder ---- */
    int b = open("/dev/binder", O_RDWR | O_CLOEXEC);
    printf("open /dev/binder = %d errno=%d\n", b, errno);
    if (b >= 0){
        int ver = 0;
        int r = ioctl(b, BINDER_VERSION, &ver);
        printf("BINDER_VERSION = %d ver=%d errno=%d\n", r, ver, errno);
        close(b);
    }

    /* ---- 3) 其他可达性 ---- */
    int e = eventfd(0, 0);           printf("eventfd = %d errno=%d\n", e, errno); if(e>=0)close(e);
    int t = timerfd_create(CLOCK_MONOTONIC, 0); printf("timerfd = %d errno=%d\n", t, errno); if(t>=0)close(t);
    int s = signalfd(-1, 0, 0);      printf("signalfd = %d errno=%d\n", s, errno); if(s>=0)close(s);
    int ev = open("/dev/input/event0", O_RDONLY); printf("open event0 = %d errno=%d\n", ev, errno); if(ev>=0)close(ev);
    int ui = open("/dev/uinput", O_RDWR);         printf("open uinput = %d errno=%d\n", ui, errno); if(ui>=0)close(ui);
    long pf = syscall(SYS_perf_event_open, 0, 0, -1, -1, 0); printf("perf_event_open = %ld errno=%d\n", pf, errno);
    printf("=== 侦察完毕 ===\n");
    return 0;
}
