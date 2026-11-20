/* surface_check.c — 攻击面可用性快速探测
 * 检查: io_uring / userfaultfd / bpf / unshare / 各种关键 syscall
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <sys/utsname.h>

/* syscall 编号 (arm64) */
#ifndef __NR_io_uring_setup
#define __NR_io_uring_setup 425
#endif
#ifndef __NR_io_uring_enter
#define __NR_io_uring_enter 426
#endif
#ifndef __NR_userfaultfd
#define __NR_userfaultfd 323
#endif
#ifndef __NR_unshare
#define __NR_unshare 97
#endif
#ifndef __NR_bpf
#define __NR_bpf 280
#endif
#ifndef __NR_open_tree
#define __NR_open_tree 428
#endif
#ifndef __NR_clone3
#define __NR_clone3 435
#endif
#ifndef __NR_close_range
#define __NR_close_range 436
#endif
#ifndef __NR_faccessat2
#define __NR_faccessat2 439
#endif
#ifndef __NR_process_madvise
#define __NR_process_madvise 440
#endif
#ifndef __NR_epoll_pwait2
#define __NR_epoll_pwait2 441
#endif
#ifndef __NR_mount_setattr
#define __NR_mount_setattr 442
#endif
#ifndef __NR_quotactl_fd
#define __NR_quotactl_fd 443
#endif
#ifndef __NR_memfd_secret
#define __NR_memfd_secret 447
#endif

/* io_uring_setup 参数 */
struct io_uring_params {
    uint32_t sq_entries, cq_entries, sq_off, cq_off;
    uint32_t sq_idle_thread_timeout;
    uint32_t features;
    uint32_t wq_fd;
    uint32_t resv[3];
    struct { uint32_t offset; } sq_off_st[64];
};

static void try_syscall(const char *name, long nr, unsigned long a, unsigned long b, unsigned long c) {
    errno = 0;
    long r = syscall(nr, a, b, c);
    printf("  %-24s ret=%-4ld errno=%-3d %s\n", name, r, errno,
           r >= 0 ? "✓ 可用" : (errno == ENOSYS ? "✗ 未实现" :
           errno == EPERM ? "⚠ 权限" : errno == EACCES ? "⚠ SELinux" : "✗"));
    if (r >= 0 && nr == 425) close((int)r);
    if (r >= 0 && nr == 323) close((int)r);
}

static void try_open(const char *path, int flags) {
    errno = 0;
    int fd = open(path, flags);
    printf("  %-36s %s errno=%d\n", path, fd >= 0 ? "✓" : "✗", errno);
    if (fd >= 0) close(fd);
}

static void read_and_print(const char *path) {
    char buf[256];
    int fd = open(path, O_RDONLY);
    if (fd < 0) { printf("  %-36s ✗ errno=%d\n", path, errno); return; }
    int n = read(fd, buf, sizeof(buf)-1);
    close(fd);
    if (n < 0) n = 0;
    buf[n] = 0;
    // 去掉换行
    for (int i = 0; i < n; i++) if (buf[i] == '\n') buf[i] = ' ';
    printf("  %-36s %s\n", path, buf);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    struct utsname uts;
    uname(&uts);
    printf("=== 攻击面可用性探测 ===\n");
    printf("内核: %s %s %s\n\n", uts.sysname, uts.release, uts.machine);

    printf("-- 新内核子系统 --\n");
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    try_syscall("io_uring_setup", __NR_io_uring_setup, 1, (unsigned long)&p, 0);
    try_syscall("userfaultfd", __NR_userfaultfd, 0x80800 /*O_CLOEXEC|O_NONBLOCK*/, 0, 0);
    try_syscall("bpf(BPF_MAP_CREATE)", __NR_bpf, 0 /*BPF_MAP_CREATE*/, 0, 0);
    try_syscall("unshare(CLONE_NEWUSER)", __NR_unshare, 0x10000000 /*CLONE_NEWUSER*/, 0, 0);
    try_syscall("clone3", __NR_clone3, 0, 0, 0);
    try_syscall("memfd_secret", __NR_memfd_secret, 0, 0, 0);

    printf("\n-- 已知可用 --\n");
    int efd = eventfd(0, 0);
    printf("  eventfd                        %s\n", efd >= 0 ? "✓" : "✗");
    if (efd >= 0) close(efd);
    int ifd = inotify_init();
    printf("  inotify_init                   %s\n", ifd >= 0 ? "✓" : "✗");
    if (ifd >= 0) close(ifd);
    int tfd = timerfd_create(0 /*CLOCK_MONOTONIC*/, 0);
    printf("  timerfd_create                 %s\n", tfd >= 0 ? "✓" : "✗");
    if (tfd >= 0) close(tfd);
    int sv[2];
    printf("  socketpair(AF_UNIX)            %s\n", socketpair(1, 1, 0, sv) == 0 ? "✓" : "✗");
    if (sv[0] >= 0) { close(sv[0]); close(sv[1]); }
    int s = socket(16 /*AF_NETLINK*/, 3 /*SOCK_RAW*/, 0);
    printf("  socket(AF_NETLINK, SOCK_RAW)   %s\n", s >= 0 ? "✓" : "✗");
    if (s >= 0) close(s);

    printf("\n-- 安全配置 --\n");
    read_and_print("/proc/sys/kernel/dmesg_restrict");
    read_and_print("/proc/sys/kernel/kptr_restrict");
    read_and_print("/proc/sys/kernel/unprivileged_bpf_disabled");
    read_and_print("/proc/sys/vm/mmap_min_addr");
    read_and_print("/proc/sys/kernel/yama/ptrace_scope");

    printf("\n-- /dev 节点(逐个 try open) --\n");
    try_open("/dev/uhid", O_RDWR);
    try_open("/dev/uinput", O_RDWR);
    try_open("/dev/binder", O_RDWR);
    try_open("/dev/hwbinder", O_RDWR);
    try_open("/dev/ptmx", O_RDWR);
    try_open("/dev/ion", O_RDONLY);
    try_open("/dev/kgsl-3d0", O_RDWR);

    printf("\n--SELinux 域--\n");
    read_and_print("/proc/self/attr/current");
    read_and_print("/proc/self/status");

    printf("\n=== 完成 ===\n");
    return 0;
}
