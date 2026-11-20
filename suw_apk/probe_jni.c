// probe_jni.c —— 在 **untrusted_app 域内**发裸 syscall，量 KernelSU 的 supercall 投递入口
// (`__arm64_sys_reboot` 上的 kprobe) 对普通 app 是否可达。
//
// 为什么必须走 JNI：Java 没有通用 syscall() 接口，app 也不能 exec /data/local/tmp 下的二进制(SELinux)。
// 判据(与 §6.17 的 shell 域测量同一口径)：
//   errno ∈ {EPERM, EINVAL} 且子进程活着  ⇒ 进到了 sys_reboot 函数体 ⇒ kprobe pre_handler 会跑 ⇒ KSU 通道可达
//   子进程被 SIGSYS(31) 杀死              ⇒ app seccomp 拦在入口前 ⇒ manager/supercall 这条路在本机走不通
//   (负对照)userfaultfd 在 app 域应表现为"被拦"，用来证明这个探针**分得出**两种结局
//   (正对照)getuid 必须在**同一次运行**里成功，否则"没崩"不能当"通到了"
// ★安全性：KSU 的魔数 0xDEADBEEF/0xCAFEBABE 不等于内核的 LINUX_REBOOT_MAGIC1(0xfee1dead)/MAGIC2，
//   而且 app 域没有 CAP_SYS_BOOT ⇒ sys_reboot 在动作之前就返回。每个被测 syscall 都放在
//   **fork 出来的子进程**里，SIGSYS 只杀子进程。
#include <jni.h>
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

static void one(int fd, const char *name, long nr, long a1, long a2, long a3, long a4)
{
    int p[2];
    char line[160];
    int n;

    if (pipe(p) != 0) {
        n = snprintf(line, sizeof(line), "[%-12s] pipe 失败 %s\n", name, strerror(errno));
        if (write(fd, line, n) < 0) { /* 忽略 */ }
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {
        close(p[0]);
        long r = syscall(nr, a1, a2, a3, a4);
        int e = errno;
        /* ★先写再关：上一版在这里先 close(p[1]) 再 write ⇒ 写进已关的 fd, errno 全丢
         *   (表现成"活着, 子进程报 (没写出东西)")。信号号那一路不受影响, 所以
         *   "reboot=SIGSYS / getuid=活着"这个对照结论仍然成立。 */
        n = snprintf(line, sizeof(line), "r=%ld errno=%d\n", r, e);
        if (write(p[1], line, n) < 0) { /* 忽略 */ }
        close(p[1]);
        _exit(0);
    }
    close(p[1]);
    char buf[64] = {0};
    if (read(p[0], buf, sizeof(buf) - 1) < 0) { /* 可能子进程被杀, 没写出来 */ }
    close(p[0]);

    int st = 0;
    waitpid(pid, &st, 0);
    if (WIFSIGNALED(st))
        n = snprintf(line, sizeof(line), "[%-12s] **SIG %d**%s\n", name, WTERMSIG(st),
                     WTERMSIG(st) == SIGSYS ? "  => seccomp 拦在入口前(kprobe 不跑)" : "");
    else
        n = snprintf(line, sizeof(line), "[%-12s] 活着, 子进程报 %s", name, buf[0] ? buf : "(没写出东西)");
    if (write(fd, line, n) < 0) { /* 忽略 */ }
}

JNIEXPORT void JNICALL
Java_com_suw_manager_Probe_run(JNIEnv *env, jclass cls, jstring jpath)
{
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    char head[200];
    int n;

    if (fd < 0) {
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        return;
    }
    n = snprintf(head, sizeof(head),
                 "=== app 域 reboot 入口探针 uid=%u gid=%u ===\n",
                 (unsigned)getuid(), (unsigned)getgid());
    if (write(fd, head, n) < 0) { /* 忽略 */ }

    one(fd, "getuid", __NR_getuid, 0, 0, 0, 0);
    one(fd, "userfaultfd", __NR_userfaultfd, 0, 0, 0, 0);
    one(fd, "reboot_ksu", __NR_reboot, KSU_MAGIC1, KSU_MAGIC2, LINUX_REBOOT_CMD_RESTART, 0);
    one(fd, "reboot_kmag", __NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, 0x1234, 0);

    close(fd);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
}
