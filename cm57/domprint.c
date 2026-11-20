/* domprint.c —— #53：零 fork 的"我是谁"打印器。
 *
 * 为什么需要它：上一发(第 45 发)判据载荷是 shell 脚本，su 之后的孩子里 mksh 要 fork 才能跑
 * `$(getenforce)` / `id`，一手回执是
 *     /data/local/tmp/w147_dom2.sh[14]: can't fork - try again
 * ⇒ **整格没有任何读数**，而且这条错是"孩子活着、只是生不出孙子"，最容易看成"su 没通"。
 * 这个二进制被 su 之后的 `sh -c` **直接 exec**(单条简单命令，mksh 不 fork)，
 * 自己把该读的都读出来 ⇒ 判据不依赖任何 fork。
 *
 * 只做三件事：uid/凭据、attr/current(SELinux 域)、能力与 seccomp；外加 enforce 与 rlimit 现场快照，
 * 用来把"can't fork"的成因(uid 0 的 RLIMIT_NPROC / pid 耗尽 / cgroup pids.max)夹出来。
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

static void dump_file(const char *tag, const char *path, int n)
{
    char buf[512];
    int fd, got = 0;
    ssize_t r;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        printf("%s=OPENFAIL errno=%d(%s)\n", tag, errno, strerror(errno));
        return;
    }
    while (got < (int)sizeof(buf) - 1) {
        r = read(fd, buf + got, sizeof(buf) - 1 - got);
        if (r <= 0)
            break;
        got += (int)r;
    }
    close(fd);
    buf[got] = 0;
    while (got > 0 && (buf[got - 1] == '\n' || buf[got - 1] == '\r'))
        buf[--got] = 0;
    if (n > 0 && got > n)
        buf[n] = 0;
    printf("%s=[%s]\n", tag, buf);
}

static void one_line(const char *tag, const char *path, const char *want)
{
    char buf[1024];
    FILE *f = fopen(path, "r");

    if (!f) {
        printf("%s=FOPENFAIL errno=%d(%s)\n", tag, errno, strerror(errno));
        return;
    }
    while (fgets(buf, sizeof(buf), f)) {
        size_t l = strlen(want);
        if (!strncmp(buf, want, l)) {
            char *p = buf + l;
            while (*p == ' ' || *p == '\t')
                p++;
            printf("%s=%s", tag, p);
            fclose(f);
            return;
        }
    }
    printf("%s=NOTFOUND\n", tag);
    fclose(f);
}

int main(int argc, char **argv)
{
    struct rlimit rl;
    char lbl[64];
    const char *mark = argc > 1 ? argv[1] : "DOM";

    snprintf(lbl, sizeof(lbl), "%s", mark);
    printf("=== %s uid=%d euid=%d gid=%d egid=%d pid=%d ppid=%d\n", lbl,
           (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid(),
           (int)getpid(), (int)getppid());
    if (getrlimit(RLIMIT_NPROC, &rl) == 0)
        printf("%s RLIMIT_NPROC cur=%llu max=%llu\n", lbl,
               (unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max);
    else
        printf("%s RLIMIT_NPROC=getrlimit失败 errno=%d(%s)\n", lbl, errno, strerror(errno));

    dump_file("CTX", "/proc/self/attr/current", 128);
    one_line("CapEff", "/proc/self/status", "CapEff:");
    one_line("CapBnd", "/proc/self/status", "CapBnd:");
    one_line("Seccomp", "/proc/self/status", "Seccomp:");
    one_line("NoNewPrivs", "/proc/self/status", "NoNewPrivs:");
    dump_file("ENFORCE", "/sys/fs/selinux/enforce", 4);
    /* 现场夹"can't fork"的成因：全局 pid 池 + 我们自己这个 uid 的进程数 */
    dump_file("PIDMAX", "/proc/sys/kernel/pid_max", 16);
    dump_file("THREADNR", "/proc/sys/kernel/threads-max", 16);
    printf("=== %s-DONE rc=0 ===\n", lbl);
    fflush(stdout);
    return 0;
}
