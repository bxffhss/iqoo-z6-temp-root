// reboot_probe.c —— 量"能不能进到 __arm64_sys_reboot 的入口"(KernelSU supercall 的唯一投递入口)
//
// 判据(三种结局含义不同，别混)：
//   errno=EINVAL/EPERM  ⇒ **进到了 sys_reboot 函数体** ⇒ KSU 挂在入口上的 kprobe pre_handler 会跑 ⇒ 可用 ✔
//   SIGSYS(31) / ENOSYS ⇒ seccomp 在入口前就拦掉 ⇒ kprobe 不会跑 ⇒ 该域拿不到 ksu 驱动 fd ✘
//   真关机              ⇒ **不可能发生**：KSU 的魔数 0xDEADBEEF/0xCAFEBABE 不等于内核的
//                         LINUX_REBOOT_MAGIC1(0xfee1dead)/MAGIC2(0x28121969)，sys_reboot 第一步就 EINVAL
// 对照组(必须一起跑，否则结论不成立 —— 见 memory:feedback-gpu-execution-oracles)：
//   getuid      = 已知可达(应返回 0)
//   userfaultfd = 本项目此前实测在 untrusted_app 被 seccomp 打成 ENOSYS ⇒ 同构的"被拦"参照
// 每个被测 syscall 都在**fork 出来的子进程**里跑：SIGSYS 只会杀子进程，父进程能读到信号号。
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <linux/reboot.h>

#define KSU_MAGIC1 0xdeadbeef
#define KSU_MAGIC2 0xcafebabe

static int read_seccomp_field(void)
{
    char buf[4096];
    int fd = open("/proc/self/status", O_RDONLY);
    int v = -1;
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return -1;
    buf[n] = 0;
    char *p = strstr(buf, "Seccomp:");
    if (p)
        v = atoi(p + 8);
    return v;
}

/* 子进程里跑一个 syscall，把结果写进 out 并 _exit(0)；被 seccomp 杀则父进程看到 SIGSYS */
static void probe(const char *name, long nr, long a1, long a2, long a3, long a4)
{
    int pfd[2];
    if (pipe(pfd) != 0) {
        printf("[%-12s] pipe 失败: %s\n", name, strerror(errno));
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {
        close(pfd[0]);
        long r = syscall(nr, a1, a2, a3, a4);
        int e = errno;
        char line[128];
        int n = snprintf(line, sizeof(line), "r=%ld errno=%d(%s)\n", r, e, strerror(e));
        if (write(pfd[1], line, n) < 0) { /* 忽略 */ }
        close(pfd[1]);
        _exit(0);
    }
    close(pfd[1]);
    char buf[160] = {0};
    read(pfd[0], buf, sizeof(buf) - 1);
    close(pfd[0]);

    int st = 0;
    waitpid(pid, &st, 0);
    printf("[%-12s] 子进程: ", name);
    if (WIFSIGNALED(st))
        printf("**被信号 %d 杀死**%s\n", WTERMSIG(st),
               WTERMSIG(st) == SIGSYS ? "  ⇒ seccomp 在入口前拦掉(kprobe 不会跑)" : "");
    else
        printf("活着, 返回串 = %s", buf);
}

int main(void)
{
    uid_t u = getuid();
    printf("=== reboot 入口可达性探针 (uid=%u, /proc/self/status:Seccomp=%d)\n",
           (unsigned)u, read_seccomp_field());
    printf("  解读: EINVAL/EPERM=进到了函数体(kprobe 会跑✔) | SIGSYS/ENOSYS=seccomp 挡住✘\n\n");

    probe("getuid", __NR_getuid, 0, 0, 0, 0);
    probe("userfaultfd", __NR_userfaultfd, 0, 0, 0, 0);
    /* KSU 的入口: reboot(magic1, magic2, cmd, arg) —— 魔数不对,内核第一步就 EINVAL,不会关机 */
    probe("reboot_ksu", __NR_reboot, KSU_MAGIC1, KSU_MAGIC2, LINUX_REBOOT_CMD_RESTART, 0);
    /* 再看内核自己的魔数会怎样(只是多走一步到 capability 检查;同样不会关机:cmd 用无效值) */
    probe("reboot_kmag", __NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, 0x1234, 0);

    printf("\n=== 结束后 uname(证明机器没被 reboot 影响) ===\n");
    fflush(stdout);
    return 0;
}
