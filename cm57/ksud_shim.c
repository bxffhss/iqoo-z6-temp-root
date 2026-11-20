// ksud_shim.c —— 放在设备的 `/data/adb/ksud`，当 KernelSU 的 su 命令实现用。
//
// 依据(kmod/ROUTE-B-OFFSET-INVERSION.md §6.22，一手读 sucompat.c:200-245)：
//   KSU 的内核侧只要求 `/data/adb/ksud` 这个文件存在且可 open，
//   然后用 `execveat(fd, "", argv=app 原样 argv, envp=app 原样 envp, AT_EMPTY_PATH)` 执行它，
//   并且 **cred 在 exec 之前就已经被 escape_with_root_profile() 换成 root_profile**。
//   ⇒ 所以"ksud 是什么"内核不挑：我们可以放自己这个 shim，
//     于是不需要 KSU 的 manager APK、不需要 Rust 版 ksud、也不需要 app 侧能发
//     reboot/supercall(§6.20 已测 app 域 reboot=SIGSYS)。
//
// 行为(与被 exec 的 `su` 语义对齐；注意 argv[0] 是调用方给的 "su")：
//   su -c "<cmd>"   →  exec sh -c "<cmd>"
//   su <args...>    →  exec sh <args...>        (交互 shell, stdio 继承调用方的管道)
//   su --selftest   →  自己回显 uid/gid/caps/SELinux 域, 用来**自证**这条通道真给了 root
//
// ★自证判据(不许"没报错就当成功")：--selftest 必须打印 uid=0 且 CapEff=3fffffffff，
//   并打印 /proc/self/attr/current 的域；与 suw 层已有的举证口径一致。
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <stdbool.h>   /* ★uapi/app_profile.h 里用了 bool，但它自己不 include(ksuctl.c 靠 stdbool.h 编过) */
#include "uapi/supercall.h"

extern char **environ;

#define SH "/system/bin/sh"

/* ★★md §6.105 的设计转折：sucompat **不在钩子里提权**。
 *   一手(窗口 103/104)：`ksu_hook_mask=0x2` 下
 *     · escape/cred_override 都关(ATT=1) ⇒ 改道成功、机器活着、`su -c id` 真跑出输出；
 *     · 打开 escape(ATT=3/5) ⇒ 脚印跑到 X7/X8/X9s 都有(连 `ksu_no_disable_seccomp=1` 也照样死)，
 *       约 18 秒后整机复位；而**同一个 `escape_with_root_profile()` 走 ioctl 路历发无事**
 *       (窗口 94/100/101：escape 之后 `execvp` 出 `uid=0(root) context=u:r:shell:s0`)。
 *   ⇒ 毒的是"在 execve 钩子(sys_enter tracepoint/调度器)上下文里换 creds"这个形状，不是那几笔动作。
 *   所以：内核只把 `execve(/system/bin/su)` 改道成 `execveat(fd_of_ksud,…)`(=ATT=1 已证安全的那半段)，
 *   **提权由 exec 完成之后的我们自己这个进程来做**——走的就是历发实测安全的那条 ioctl 路：
 *     ① `reboot(KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, &out)` 让内核把一个驱动 fd 的**号码**回传给我们
 *        (ksuctl 实测：`ret=-1 errno=22` 但 `回传值=3` —— 这个口就是设计成返回 EINVAL 的，别被 ret 骗)；
 *     ② 扫 `/proc/self/fd` 找 `[ksu_driver]` 当兜底；
 *     ③ `ioctl(fd, KSU_IOCTL_GRANT_ROOT, NULL)` ⇒ 内核对我们的 uid 跑 escape(在普通 ioctl 上下文里)。
 *   判据不许用"没报错"：③ 之后必须自己读回 `getuid()==0` 才算成。 */
static int scan_ksu_fd_dump(int *out, int max)
{
    DIR *d = opendir("/proc/self/fd");
    int n = 0;
    struct dirent *de;

    if (!d) {
        fprintf(stderr, "SHIM-ESC opendir(/proc/self/fd) 失败 errno=%d(%s)\n", errno, strerror(errno));
        return 0;
    }
    while ((de = readdir(d)) != NULL) {
        char link[64], tgt[160];
        ssize_t m;
        int fdnum = atoi(de->d_name);
        if (fdnum <= 2)
            continue;   /* 标准流不可能是驱动 fd，也免得把 atoi("0") 当命中 */
        snprintf(link, sizeof(link), "/proc/self/fd/%s", de->d_name);
        m = readlink(link, tgt, sizeof(tgt) - 1);
        if (m <= 0)
            continue;
        tgt[m] = 0;
        if (getenv("KSU_SHIM_DUMPFD"))
            fprintf(stderr, "SHIM-FD %d -> %s\n", fdnum, tgt);
        /* 内核在改道成功后装的正是这个：`su_fd = ksu_install_su_fd()`(sucompat.c SU4 之后)，
         * 名字是 "[ksu_driver_su]" ⇒ 子串 "ksu_driver" 两种都能认。 */
        if (strstr(tgt, "ksu_driver") && n < max)
            out[n++] = fdnum;
    }
    closedir(d);
    return n;
}

/* 返回 0=已经 root；非 0=没成(原因印在 stdout 里，上层必须能看见) */
static int escalate(void)
{
    int cands[24];
    int n, i;

    fprintf(stderr, "SHIM-ESC 起点 uid=%u ctx=", (unsigned)getuid());
    fflush(stderr);
    {
        int cfd = open("/proc/self/attr/current", O_RDONLY);
        char cb[80];
        ssize_t cn = cfd >= 0 ? read(cfd, cb, sizeof(cb) - 1) : -1;
        if (cn > 0) {
            cb[cn] = 0;
            fprintf(stderr, "%s", cb);
        } else
            fprintf(stderr, "(读不到 errno=%d)", errno);
        if (cfd >= 0)
            close(cfd);
    }
    fprintf(stderr, "\n");
    fflush(stderr);

    n = scan_ksu_fd_dump(cands, 24);
    fprintf(stderr, "SHIM-ESC 扫 /proc/self/fd 得到 %d 个 ksu 驱动 fd:", n);
    for (i = 0; i < n; i++)
        fprintf(stderr, " %d", cands[i]);
    fprintf(stderr, "\n");
    fflush(stderr);

    for (i = 0; i < n; i++) {
        long r = ioctl(cands[i], KSU_IOCTL_GRANT_ROOT, NULL);
        int e = errno;
        fprintf(stderr, "SHIM-ESC ioctl(GRANT_ROOT fd=%d) ret=%ld errno=%d(%s) uid后=%u euid后=%u\n",
                cands[i], r, e, strerror(r == 0 ? 0 : e), (unsigned)getuid(), (unsigned)geteuid());
        fflush(stderr);
        if (getuid() == 0)
            return 0;
    }

    /* 一个都没成 ⇒ 才退回"让内核主动装一个 fd 并回传号码"的老口子。
     * ★顺序不能反：app 域里 `reboot(2)`(syscall 142) 被 seccomp 判 SIGSYS(§6.110)，
     *   放在前面就是"还没扫就先被杀"，日志里连一行都没有。 */
    if (getenv("KSU_SHIM_NOESC_REBOOT")) {
        fprintf(stderr, "SHIM-ESC 跳过 reboot 魔数口(KSU_SHIM_NOESC_REBOOT)，直接失败\n");
        return 1;
    }
    {
        int out = -1;
        long r;
        int e;

        fprintf(stderr, "SHIM-ESC 扫描没成 ⇒ 试 reboot 魔数口(app 域可能 SIGSYS)\n");
        fflush(stderr);
        r = syscall(SYS_reboot, (int)KSU_INSTALL_MAGIC1, (int)KSU_INSTALL_MAGIC2, 0, &out);
        e = errno;
        fprintf(stderr, "SHIM-ESC reboot(magic) ret=%ld errno=%d(%s) 回传 fd=%d uid前=%u\n", r, e,
                strerror(r == 0 ? 0 : e), out, (unsigned)getuid());
        fflush(stderr);
        if (out < 0)
            return 1;
        r = ioctl(out, KSU_IOCTL_GRANT_ROOT, NULL);
        e = errno;
        fprintf(stderr, "SHIM-ESC ioctl(GRANT_ROOT fd=%d) ret=%ld errno=%d(%s) uid后=%u euid后=%u\n", out,
                r, e, strerror(r == 0 ? 0 : e), (unsigned)getuid(), (unsigned)geteuid());
        fflush(stderr);
    }
    return getuid() == 0 ? 0 : 2;
}

static void selftest(void)
{
    char buf[8192];   /* ★必须够大到读到 /proc/self/status 末尾的 CapEff 行: 上一版只给 512 字节 => 自证关键字段被截掉 */
    ssize_t n;
    int fd;

    printf("SHIM uid=%u gid=%u euid=%u\n", (unsigned)getuid(), (unsigned)getgid(),
           (unsigned)geteuid());
    fd = open("/proc/self/status", O_RDONLY);
    if (fd >= 0) {
        n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            char *p;
            buf[n] = 0;
            p = strstr(buf, "CapEff:");
            printf("SHIM %.16s\n", p ? p : "(无 CapEff)");
        }
    }
    fd = open("/proc/self/attr/current", O_RDONLY);
    if (fd >= 0) {
        n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = 0;
            printf("SHIM context=%s\n", buf);
        }
    }
    fflush(stdout);
}

int main(int argc, char **argv)
{
    char **av;
    int i;

    /* ★提权一定发生在 exec **之后**(这才是关键)：此刻我们已经在普通进程上下文里，
     *   走的是历发实测安全的 ioctl escape。`KSU_SHIM_NOESC=1` 留给"同一发里做 A/B"用。 */
    if (!getenv("KSU_SHIM_NOESC"))
        escalate();

    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        selftest();
        return 0;
    }

    /* 把 argv[0] 从 "su" 换成 "sh"，其余原样传给 shell；
     * 内核把 stdin/stdout/stderr 原封不动继承过来，所以 suw 侧照旧用管道喂命令。 */
    av = calloc((size_t)argc + 1, sizeof(*av));
    if (!av)
        return 12;
    av[0] = SH;
    for (i = 1; i < argc; i++)
        av[i] = argv[i];

    execve(SH, av, environ);
    /* exec 失败一定要出声：否则上层会把"没 root 到"误读成"命令本身报错" */
    perror("ksud_shim: execve " SH " failed");
    return 127;
}
