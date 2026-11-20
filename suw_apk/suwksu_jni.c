/* suwksu_jni.c —— 在 **untrusted_app 域内**把"内核授权"这条路一次跑完，并逐行落盘。
 *
 * 为什么必须待在 JNI 里：app 发不出 `reboot`(§6.20 实测 SIGSYS)，Java 也没有通用 syscall；
 * 而 KSU 的授权判定发生在 **ioctl 当时**、按收方 current_uid 判 ⇒ 只要 shell 域的 agent(shd)
 * 把驱动 fd 用 SCM_RIGHTS 递过来，app 自己 ioctl(GRANT_ROOT) 就够了，
 * 不需要 /system/bin/su、不需要 reboot、也不碰那条必炸的 execve 改写(§6.57)。
 * 参考实现(同一条链, 单线程版): cm57/ksuctl.c: cmd_passfd —— 真机已复现 4 次(§6.53~§6.56)。
 *
 * ★三个判据，缺一个都不算数：
 *   ① GET_INFO 在**收到的 fd** 上 rc=0      ⇒ fd 跨进程仍然活着(这是整条链唯一依赖的传递性)
 *   ② GRANT_ROOT rc=0 且本线程 uid 变 0     ⇒ 内核真的改了 cred(不是"没报错"而已)
 *   ③ 未 arm 时必须 rc=EPERM/EACCES 且 uid 不变 ⇒ 闸门(按 uid 算)没被 fd 绕过
 * ★坑: commit_creds 只改 **current 线程**的 cred(patch_ksu_escape_steps.py 的 X7/X8 就是
 *   单线程语义)，app 是多线程进程 ⇒ 读 `/proc/self/status` 会拿到线程组 leader 的旧 cred,
 *   看上去"没提上去"= 假阴性。所以这里一律读 `/proc/thread-self/status` + 直接 getuid()。
 * ★每行写完就 fsync：这一支历史上出过"瞬间静默复位"(§6.57)，不落盘的日志等于没有。
 */
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <sys/syscall.h>
#include <stdbool.h>
#include <sched.h>
#include <sys/prctl.h>
#include <sys/wait.h>

#include "../kmod/uapi/supercall.h"

#define UNIXNAME "suwshd"   /* 与 shd.c 的 abstract socket 名同源 */
#define PARK_SEC 25         /* 授权成功后本线程驻留时长(让 root 侧从 /proc 外部看到那个 uid 0) */

static int G_FD = -1;        /* 报告文件 */

static void rep(const char *fmt, ...) {
    char line[512];
    struct timespec ts;
    va_list ap;
    int n;

    if (G_FD < 0)
        return;
    clock_gettime(CLOCK_REALTIME, &ts);
    n = snprintf(line, sizeof(line), "[%02ld:%02ld:%02ld.%03ld] ",
                 (long)((ts.tv_sec % 86400) / 3600), (long)((ts.tv_sec % 3600) / 60),
                 (long)(ts.tv_sec % 60), ts.tv_nsec / 1000000);
    va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    if (n > 0) {
        if (line[n - 1] != '\n' && (size_t)n + 1 < sizeof(line))
            line[n++] = '\n';
        if (write(G_FD, line, n) < 0) { /* 没地方可退 */ }
        fsync(G_FD);
    }
}

/* /proc/thread-self(而不是 /proc/self)—— 见文件头那条假阴性说明 */
/* crep —— 子进程专用行记录：写的是 /data/local/tmp 上的**普通文件系统**(f2fs)，
 * 绝不碰 /sdcard(FUSE)。第四十一发的现场：子进程授权成 uid 0 之后继续对 FUSE 报告文件
 * 逐行 write+fsync ⇒ 永久堵在 `State: D (disk sleep)`，于是"驻留 t+08s"之后的行一条也没有，
 * 我一度把它读成"子进程 4 秒就被杀"(其实是自己下一条命令的 am force-stop 打的)。
 * 判据本身没丢(shell 读 /proc 抓到 uid=0)，但 exec 那一支永远走不到 ⇒ 这条必须改。 */
/* kstep —— 子进程**每一步**都往管道写一行：管道是实测在 GRANT_ROOT 之后仍然可用的信道
 * (第 46 发那一行 `0 88 0 0` 就是 grant 之后写进去的)，所以用它当"黑匣子"最可靠。 */
static void kstep(int fd, const char *fmt, ...)
{
    char line[256];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n <= 0)
        return;
    if ((size_t)n + 1 < sizeof(line))
        line[n++] = '\n';
    if (write(fd, line, n) < 0) { /* 管道断了就只能往下走 */ }
}

/* fld —— 从 /proc/<tid>/status 的文本里取一行的值(不用正则，直接按名字找) */
static const char *fld(const char *buf, const char *name)
{
    /* v31 修 bug：以前这里只有**一块** static 缓冲 ⇒ 同一条 kstep 里调 5 次 fld，
     *   5 个指针全指向同一块内存，printf 求值完剩下的就是"最后一个字段的值"。
     *   第四十八发的现场：SigPnd/ShdPnd/SigBlk/Seccomp/CapEff 全印成 ffffffffffffffff
     *   (= CapEff)，把最想要的 SigPnd 结论吃掉了。改成 8 槽轮转。 */
    static char pool[8][64];
    static int slot;
    char *out = pool[slot];
    const char *q;
    char pat[32];
    int i;

    slot = (slot + 1) & 7;

    for (i = 0; name[i] && i < (int)sizeof(pat) - 2; i++)
        pat[i] = name[i];
    pat[i] = ':';
    pat[i + 1] = 0;
    q = strstr(buf, pat);
    if (!q) {
        snprintf(out, 64, "(无 %s)", name);
        return out;
    }
    q += strlen(pat);
    while (*q == ' ' || *q == '	')
        q++;
    snprintf(out, 64, "%s", q);
    {
        char *z = strchr(out, '\n');
        if (z)
            *z = 0;
    }
    return out;
}

static void crep(int fd, const char *fmt, ...)
{
    char line[512];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n <= 0)
        return;
    if (line[n - 1] != '\n' && (size_t)n + 1 < sizeof(line))
        line[n++] = '\n';
    if (write(fd, line, n) < 0) { /* 没地方可退 */ }
}

static void dump_cred(const char *tag) {
    char path[64], buf[256], line[192];
    int fd;
    ssize_t n, r;

    line[0] = 0;
    snprintf(path, sizeof(path), "/proc/thread-self/status");
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            char *p;
            buf[n] = 0;
            p = strstr(buf, "CapEff:");
            if (p) {
                char *e = strchr(p, '\n');
                if (e) *e = 0;
                snprintf(line, sizeof(line), "%s", p);
            }
        }
    }
    {
        char ctx[128] = "(读不到)";
        int cfd = open("/proc/thread-self/attr/current", O_RDONLY | O_CLOEXEC);
        if (cfd >= 0) {
            r = read(cfd, ctx, sizeof(ctx) - 1);
            close(cfd);
            if (r > 0) {
                ctx[r] = 0;
                if (r > 0 && ctx[r - 1] == '\n') ctx[r - 1] = 0;
            }
        }
        rep("%s: getuid=%u geteuid=%u getgid=%u getegid=%u %s 域=%s",
            tag, (unsigned)getuid(), (unsigned)geteuid(), (unsigned)getgid(),
            (unsigned)getegid(), line[0] ? line : "CapEff:?", ctx);
    }
}

/* v42(§6.69③ / §6.72③)：**app 侧只当客户端**，root 命令交给 root 侧守护跑。
 * 为什么要这一格：本机厂商模块 vr 有两道执法——①靠 escape 变 uid 0 立刻被 force_sig(SIGKILL)
 *   (rc32 能软掉)，②这个任务接着 execve 被 EPERM。而窗口里"生下来就是 root"的进程 execve
 *   一切正常 ⇒ "替 app 跑一条 root 命令"的执行体只能是它(ksuctl sushd)。
 * 授权判定**不在这里也不在守护里写规则**：守护拿 SO_PEERCRED 的发起 uid 去问内核
 *   UID_GRANTED_ROOT ⇒ 名单(=KernelSU 白名单)说没有就没有。
 * 用法：cmd 以 "@sushd:" 开头 ⇒ 把冒号后面那段交给守护执行，结果逐行写进报告。
 */
#define SUW_SUSHD_TOKEN "changeme"
#define SUSHD_PKG "com.suw.manager"          /* 守护靠它定位发起者的私有目录 */
#define SUSHD_APP_FILE "/data/data/com.suw.manager/files/sushd_out.txt"
#define SUSHD_EXT_FILE "/sdcard/Android/data/com.suw.manager/files/sushd_out.txt"

/* 返回 0=守护确实跑出输出(落盘拿到了); -1=连接/派发/落盘 3 次都没成 */
static int run_via_sushd(const char *cmd)
{
    struct sockaddr_un a;
    char q[1400], buf[8192];
    ssize_t n;
    int c, on = 1, attempt, ok = -1;
    const char *real = cmd + 7;   /* 去掉 "@sushd:" */

    for (attempt = 0; attempt < 3 && ok != 0; attempt++) {
        if (attempt) usleep(400000);
        c = socket(AF_UNIX, SOCK_STREAM, 0);
        if (c < 0) { rep("SUSHD socket 失败 errno=%d(%s)", errno, strerror(errno)); continue; }
        setsockopt(c, SOL_SOCKET, SO_PASSCRED, &on, sizeof(on));
        memset(&a, 0, sizeof(a));
        a.sun_family = AF_UNIX;
        memcpy(a.sun_path + 1, "suwksu", 6);
        if (connect(c, (struct sockaddr *)&a,
                    (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + 6)) < 0) {
            rep("SUSHD connect @suwksu 失败(第%d次) errno=%d(%s) ⇒ 守护没跑?",
                attempt + 1, errno, strerror(errno));
            close(c);
            continue;
        }
        unlink(SUSHD_APP_FILE);
        snprintf(q, sizeof q, "RUN %s %s %s\n", SUW_SUSHD_TOKEN, SUSHD_PKG, real);
        if (write(c, q, strlen(q)) < 0) {
            rep("SUSHD 发请求失败(第%d次) errno=%d(%s)", attempt + 1, errno, strerror(errno));
            close(c);
            continue;
        }
        rep("SUSHD 已派发(第%d次): [%.140s]", attempt + 1, real);
        {
            /* ★只轮询本地落盘文件(权威)。守护 cmd 有 10s 超时，这里给 18s 留足余量。 */
            struct timeval tv;
            struct stat st;
            int k, fd, gotb = 0;

            for (k = 0; k < 90; k++) {
                if (stat(SUSHD_APP_FILE, &st) == 0 && st.st_size > 0)
                    break;
                usleep(200000);
            }
            rep("SUSHD 等落盘 %dms(第%d次)", k * 200, attempt + 1);
            fd = open(SUSHD_APP_FILE, O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                n = read(fd, buf, sizeof(buf) - 1);
                close(fd);
                if (n > 0) {
                    buf[n] = 0;
                    gotb = 1;
                    rep("SUSHD 回: %s", buf);
                }
            }
            tv.tv_sec = 2;
            tv.tv_usec = 0;
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            n = read(c, buf, sizeof(buf) - 1);
            if (n > 0) { buf[n] = 0; }
            if (gotb) {
                int of = open(SUSHD_EXT_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);

                if (of >= 0) {
                    if (write(of, buf, strlen(buf)) < 0) { }
                    close(of);
                }
                ok = 0;
            }
        }
        close(c);
    }
    if (ok != 0)
        rep("SUSHD 重试 3 次仍无落盘 ⇒ 判失败(守护没跑/没回)");
    return ok;
}


/* 每次 recvmsg 都挂 control 缓冲 ⇒ 就算问候行与 KSUFD 回复被合并成一次投递, cmsg 也不会丢
 * (用 read() 才会丢: 内核会把没处放的 fd 塞进错误队列)。 */
static ssize_t rx(int c, char *acc, size_t cap, size_t *used, int *gotfd) {
    char chunk[512], ctl[128];
    struct msghdr m;
    struct iovec io;
    size_t take;
    ssize_t n;

    memset(&m, 0, sizeof(m));
    memset(ctl, 0, sizeof(ctl));
    io.iov_base = chunk;
    io.iov_len = sizeof(chunk);
    m.msg_iov = &io;
    m.msg_iovlen = 1;
    m.msg_control = ctl;
    m.msg_controllen = sizeof(ctl);
    n = recvmsg(c, &m, 0);
    if (n <= 0)
        return n;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm; cm = CMSG_NXTHDR(&m, cm))
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
            memcpy(gotfd, CMSG_DATA(cm), sizeof(int));
    take = (size_t)n;
    if (*used + take >= cap)
        take = cap - *used - 1;
    if (take) {
        memcpy(acc + *used, chunk, take);
        *used += take;
        acc[*used] = 0;
    }
    return n;
}

static int unix_connect(void) {
    struct sockaddr_un u;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);

    if (fd < 0) {
        rep("socket() 失败 errno=%d(%s)", errno, strerror(errno));
        return -1;
    }
    memset(&u, 0, sizeof(u));
    u.sun_family = AF_UNIX;
    u.sun_path[0] = 0;                       /* abstract namespace */
    strncpy(u.sun_path + 1, UNIXNAME, sizeof(u.sun_path) - 2);
    if (connect(fd, (struct sockaddr *)&u,
                offsetof(struct sockaddr_un, sun_path) + 1 + strlen(UNIXNAME)) < 0) {
        rep("connect(@%s) 失败 errno=%d(%s) ⇒ agent 没在跑, 或 SELinux 不让 app connectto"
            " (EACCES=SELinux/uid 闸, ECONNREFUSED=没人监听)",
            UNIXNAME, errno, strerror(errno));
        close(fd);
        return -1;
    }
    {
        /* agent 是外部进程：它要是回半截就死，也不许把 app 的线程永久挂住(判据就再也不落盘了) */
        struct timeval tv = { 20, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    return fd;
}

JNIEXPORT jstring JNICALL
Java_com_suw_manager_Ksu_nativeRun(JNIEnv *env, jclass cls, jstring jpath, jboolean jarm,
                                jstring jcmd)
{
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    const jboolean arm = jarm;
    const char *cmd = jcmd ? (*env)->GetStringUTFChars(env, jcmd, NULL) : NULL;
    char acc[2048];
    char summary[160];
    size_t used = 0, seen;
    int c, got = -1, rounds, rc, status = 0;
    ssize_t w;
    jstring out;

    /* ★O_APPEND 而不是 O_TRUNC(窗口 98 一手)：同一个文件有**两个写者** ——
     *   intent 触发这一份(onCreate 的 autoRun)和 UI 自己刷列表那一份(ksuPolicy("show") 也调 runOnce)。
     *   O_TRUNC 下"后写的把先写的抹掉"，我读到的永远是 UI 那份 `arm=0 cmd=[@list]`，
     *   于是第①步(发的是 @mgr)看起来像"动词发歪"，其实是**判据文件自己互相覆盖**。
     *   改成追加之后每一步都从首行 banner(`===== … arm=%d cmd=[%s] =====`)里挑自己要的那一段。 */
    G_FD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (G_FD < 0) {
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        return (*env)->NewStringUTF(env, "ERR open-report");
    }
    /* ★把**收到的东西原样印出来**：第九十六发就是"我以为发出去的是 @mgr，报告里却跑出 @list 的行为"，
     *   而 arm 也和我传的 ksuarm 不符 —— 动词分发对不对，先看**入口参数到底是什么**，
     *   不然整条判据链都建在"我猜 intent 发对了"上(记忆：判据代码自己也会骗自己)。 */
    rep("===== app 侧内核授权自检 arm=%d cmd=[%s] =====", (int)arm, cmd ? cmd : "(null)");
    /* ★分流：@sushd: 前缀 = 让 root 侧守护替我跑(本机 app 自己 exec 会被 vr 挡，§6.72) */
    if (cmd && strncmp(cmd, "@sushd:", 7) == 0) {
        int sr = run_via_sushd(cmd);
        rep("===== 结束(走守护代跑，不碰本进程 cred) 真实状态码=%d =====", sr);
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        if (cmd)
            (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
        close(G_FD);   /* 不能只置 -1：那是把报告文件的 fd 漏了 */
        G_FD = -1;
        return (*env)->NewStringUTF(env, sr == 0 ? "status=0 via-sushd" : "status=FAIL via-sushd");
    }
    /* ★§6.116：Termux/Shizuku 报"设备上没找到 su"的**真因**不是 su 方言，而是它们**先探测再执行**
     *   (`access()`/`stat()`)，而本机 `/system/bin/su` 这个文件根本不存在 —— 我们只挂了 execve 那一位，
     *   探测没被伪造就在第一步死掉，永远走不到改道。内核里那半个功能是现成的
     *   (`ksu_handle_faccessat_sucompat`/`ksu_handle_stat_sucompat`，hook 位 3/4)，只是从没开过。
     *   这个动词就是**量这件事**的探针：必须用**本进程(未 escape 的授权 uid)**来探测 ——
     *   uid 0 会被 `forbid_system_uid` 直接拒，探测结果就没意义了。 */
    if (cmd && strncmp(cmd, "@suprobe:", 9) == 0) {
        const char *su = "/system/bin/su";
        const char *xbin = "/system/xbin/su";   /* ★负对照：钩子只认 /system/bin/su，这个必须还是失败 */
        struct stat st;
        int rc;

        rep("SUPROBE 起点 uid=%u(必须是名单内、且未 escape 的 uid，否则判据无意义)", (unsigned)getuid());
        errno = 0;
        rc = access(su, X_OK);
        rep("SUPROBE access(%s,X_OK)=%d errno=%d(%s)", su, rc, errno, strerror(errno));
        errno = 0;
        rc = stat(su, &st);
        rep("SUPROBE stat=%d errno=%d(%s) mode=0%o size=%lld ino=%lu", rc, errno, strerror(errno),
            rc == 0 ? (unsigned)(st.st_mode & 07777) : 0, rc == 0 ? (long long)st.st_size : -1,
            rc == 0 ? (unsigned long)st.st_ino : 0UL);
        errno = 0;
#ifndef SYS_faccessat2
#define SYS_faccessat2 439   /* arm64 = asm-generic 表里的 439；NDK 头没定义时用它 */
#endif
        rc = (int)syscall(SYS_faccessat2, AT_FDCWD, su, X_OK, 0);
        rep("SUPROBE faccessat2=%d errno=%d(%s) ★这条钩子没挂(bionic 的 access 走 faccessat)，"
            "如果哪天 app 改用它，就得再挂一位", rc, errno, strerror(errno));
        errno = 0;
        rc = access(xbin, X_OK);
        rep("SUPROBE 负对照 access(%s)=%d errno=%d(%s) ⇒ 期望**失败**", xbin, rc, errno, strerror(errno));

        /* ★真正对齐 Termux/Shizuku 的一步：它们不是"直接 execv 一个绝对路径"，而是
         *   **按 PATH 找命令**(execvp/`which`)⇒ 先 access() 探测，探测失败就报"没找到 su"，
         *   连 execve 都不发。所以判据必须是"裸 `su` 走 PATH 查找能不能变成 root"。
         *   app 进程的 PATH 里有 /system/bin ⇒ 与 Termux 里手敲 su 同形。 */
        {
            char *pv[] = { (char *)"su", (char *)"-c",
                           (char *)(cmd[9] ? (cmd + 9) : (char *)"id"), NULL };
            const char *of = "/sdcard/Android/data/com.suw.manager/files/app_su.txt";
            pid_t pid = fork();

            if (pid == 0) {
                int fd = open(of, O_WRONLY | O_CREAT | O_TRUNC, 0666);
                if (fd >= 0) {
                    dup2(fd, 1);
                    dup2(fd, 2);
                    if (fd > 2)
                        close(fd);
                }
                execvp("su", pv);   /* ← 走 PATH：这一步就包含 access() 探测 */
                fprintf(stderr, "SUPROBE execvp(su) 失败 errno=%d(%s) ⇒ 探测或改道没通\n", errno,
                        strerror(errno));
                _exit(127);
            }
            rep("SUPROBE execvp 子进程=%d(PATH 查找 su，输出在 app_su.txt)", (int)pid);
            if (pid > 0) {
                int st = 0, w;
                do {
                    w = waitpid(pid, &st, 0);
                } while (w < 0 && errno == EINTR);
                rep("SUPROBE execvp 结果 w=%d %s sig=%d exit=%d", w,
                    WIFSIGNALED(st) ? "**被信号杀**" : "退出", WIFSIGNALED(st) ? WTERMSIG(st) : -1,
                    WIFEXITED(st) ? WEXITSTATUS(st) : -1);
            }
        }
        rep("===== 结束(@suprobe: 探测+按 PATH 执行) 状态码=0 =====");
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        if (cmd)
            (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
        close(G_FD);
        G_FD = -1;
        {
            char s[48];
            snprintf(s, sizeof(s), "status=0 suprobe rc=%d", rc);
            return (*env)->NewStringUTF(env, s);
        }
    }
    /* ★§6.110 的怀疑点：**真·第三方 app 敲 su 通不通**。
     *   前面所有 su 判据(§6.106/§6.108/§6.109)都是 `ksuctl su <uid>` 的子进程 —— 它的祖先是 sushd，
     *   **没有 app 的 seccomp 过滤器**。而我们的 shim 提权第一步是 `syscall(SYS_reboot, 魔数…)` 去要
     *   驱动 fd，可 app 域 `reboot` = SIGSYS(§6.6 一手) ⇒ 这个形状很可能当场被 seccomp 打死，
     *   而不是"没权限"。这个动词就是把它做出来：fork(不预先 escape) ⇒ execv("/system/bin/su")，
     *   父进程收 waitpid —— `sig=31` 就是证据，届时改成"sucompat 把驱动 fd 直接递给孩子"
     *   (孩子只需扫 /proc/self/fd 找 [ksu_driver]，不必自己发 reboot)。 */
    /* #53 的两条 app 侧域判据入口。都从**真 app 进程**fork(孩子原样带着 app 的 uid、seccomp 与
     * u:r:untrusted_app 域)，输出统一进 app_dom.txt：
     *   @domapp:<script>  完全不碰 su ⇒ 态0 基线(域必须还是 untrusted_app，DOM 全被挡)
     *   @domsu:<script>   PATH **只给挂载点一项**再 execvp("su") ⇒ 态1/态2：与交付同形，
     *                     而且 ko 的 execve 钩子(按字符串 "/system/bin/su" 匹配)插不进来，
     *                     所以"出不出 root"只可能由内核名单决定(§6.124⑤ 的那两处判据错误)。 */
    if (cmd && (!strncmp(cmd, "@domapp:", 8) || !strncmp(cmd, "@domsu:", 7))) {
        int is_su = (cmd[4] == 's');   /* "@domsu:"→'s'，"@domapp:"→'a' */
        const char *real = cmd + (is_su ? 7 : 8);
        const char *of = "/sdcard/Android/data/com.suw.manager/files/app_dom.txt";
        pid_t pid = fork();

        rep("DOMAPP 起点 uid=%u 走su=%d 载荷=[%s]", (unsigned)getuid(), is_su, real);
        if (pid == 0) {
            int fd = open(of, O_WRONLY | O_CREAT | O_TRUNC, 0666);
            char *av[8];

            if (fd >= 0) {
                dup2(fd, 1);
                dup2(fd, 2);
                if (fd > 2)
                    close(fd);
            }
            memset(av, 0, sizeof(av));
            if (is_su) {
                setenv("PATH", "/product/bin", 1);
                av[0] = (char *)"su";
                av[1] = (char *)"-c";
                av[2] = (char *)real;
                execvp("su", av);
            } else {
                av[0] = (char *)"sh";
                av[1] = (char *)real;
                execv("/system/bin/sh", av);
            }
            fprintf(stderr, "DOMAPP execv 失败 errno=%d(%s)\n", errno, strerror(errno));
            _exit(127);
        }
        if (pid > 0) {
            int st = 0, w;
            do {
                w = waitpid(pid, &st, 0);
            } while (w < 0 && errno == EINTR);
            rep("DOMAPP 结果 w=%d %s sig=%d exit=%d 输出=%s", w,
                WIFSIGNALED(st) ? "**被信号杀**" : "退出",
                WIFSIGNALED(st) ? WTERMSIG(st) : -1,
                WIFEXITED(st) ? WEXITSTATUS(st) : -1, of);
        }
        snprintf(summary, sizeof(summary), "status=0 domapp=%d", is_su);
        status = 0;
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        if (cmd)
            (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
        close(G_FD);
        G_FD = -1;
        return (*env)->NewStringUTF(env, summary);
    }
    if (cmd && strncmp(cmd, "@su:", 4) == 0) {
        char *av[] = { (char *)"/system/bin/su", (char *)"-c", (char *)(cmd + 4), NULL };
        const char *of = "/sdcard/Android/data/com.suw.manager/files/app_su.txt";
        pid_t pid = fork();

        if (pid == 0) {
            int fd = open(of, O_WRONLY | O_CREAT | O_TRUNC, 0666);
            if (fd >= 0) {
                dup2(fd, 1);
                dup2(fd, 2);
                if (fd > 2)
                    close(fd);
            }
            /* ★让 shim 把整张 /proc/self/fd 印进 app_su.txt：
             *   "扫没扫到驱动 fd"和"app 域能不能 readlink 自己的 fd"是两件事，一次分开来看。 */
            setenv("KSU_SHIM_DUMPFD", "1", 1);
            execv("/system/bin/su", av);
            fprintf(stderr, "execv(su) 失败 errno=%d(%s)\n", errno, strerror(errno));
            _exit(127);
        }
        rep("SU-APP 父: fork=%d uid=%u 子进程带着 app 的 seccomp+域去敲 su", (int)pid, (unsigned)getuid());
        if (pid > 0) {
            int st = 0, w;
            do {
                w = waitpid(pid, &st, 0);
            } while (w < 0 && errno == EINTR);
            rep("SU-APP 结果 w=%d %s sig=%d exit=%d 输出文件=%s", w,
                WIFSIGNALED(st) ? "**被信号杀**" : "退出",
                WIFSIGNALED(st) ? WTERMSIG(st) : -1,
                WIFEXITED(st) ? WEXITSTATUS(st) : -1, of);
        }
        rep("===== 结束(@su: 真 app 域，不预先 escape) 状态码=0 =====");
        (*env)->ReleaseStringUTFChars(env, jpath, path);
        if (cmd)
            (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
        close(G_FD);
        G_FD = -1;
        return (*env)->NewStringUTF(env, "status=0 via-app-su");
    }
    dump_cred("起点");

    c = unix_connect();
    if (c < 0) {
        snprintf(summary, sizeof(summary), "status=1 connect-fail");
        goto done;
    }
    acc[0] = 0;
    if (rx(c, acc, sizeof(acc), &used, &got) <= 0) {
        rep("问候行没收到(连接被立刻关了?)");
        snprintf(summary, sizeof(summary), "status=2 no-greeting");
        status = 2;
        goto done;
    }
    rep("问候行: %.120s", acc);   /* "OK unix uid=10284 pid=..." = SO_PEERCRED 用的是真身份 */
    w = write(c, "KSUFD" "\n", 6);
    if (w != 6) {
        /* ★这里必须比 `!= 6`：write 成功返回的是**字节数 6**，上一版写 `!= 0` 把成功当失败，
         *   于是真机上明明连上了(问候行都收到了)却报"发 KSUFD 失败"，
         *   errno 还是上一个调用留下的 88(ENOTSOCK) —— 典型的"自己把自己判死"。 */
        rep("发 KSUFD 失败: 返回 %zd errno=%d(%s)", w, errno, strerror(errno));
        snprintf(summary, sizeof(summary), "status=3 send-fail");
        status = 3;
        goto done;
    }
    seen = used;
    for (rounds = 0; rounds < 20 && got < 0; rounds++) {
        ssize_t n = rx(c, acc, sizeof(acc), &used, &got);
        if (n <= 0)
            break;
        if (strstr(acc + seen, "ERR"))
            break;
        /* ★与 shd --fdtest 那条客户端同一口径：带 fd 的那次 recvmsg 已经把 SCM_RIGHTS 收下了，
         *   状态行读完就该走 —— 上一版只认 ERR/超时，于是白等满 SO_RCVTIMEO(20s)，看着像"卡死"。 */
        if (strchr(acc + seen, '\n') != NULL)
            break;
    }
    rep("KSUFD 回复: %.240s", acc + seen);
    rep("收到 fd=%d", got);
    if (got < 0) {
        rep("=> 没有 fd: agent 那边拿不到驱动 fd(kernelsu.ko 没装载/白名单没 seed)。握手本身是通的。");
        snprintf(summary, sizeof(summary), "status=4 no-fd handshake-ok");
        status = 4;
        goto done;
    }

    /* 判据①: fd 是跨进程递过来的, 在本进程 ioctl 得打得进去 */
    {
        struct ksu_get_info_cmd gi;
        memset(&gi, 0, sizeof(gi));
        rc = ioctl(got, KSU_IOCTL_GET_INFO, &gi);
        rep("判据① GET_INFO(收到的 fd=%d): rc=%d errno=%d(%s) version=%u flags=0x%x features=%u uapi=%u",
            got, rc, rc ? errno : 0, strerror(rc ? errno : 0), gi.version, gi.flags, gi.features,
            gi.uapi_version);
        if (rc != 0) {
            snprintf(summary, sizeof(summary), "status=5 getinfo-fail errno=%d", errno);
            status = 5;
            goto done;
        }
    }

    /* v47(管理面) 锚点 */
    if (cmd && !strncmp(cmd, "@mgr", 4)) {
        struct ksu_get_manager_appid_cmd ma;
        memset(&ma, 0, sizeof(ma));
        rc = ioctl(got, KSU_IOCTL_GET_MANAGER_APPID, &ma);
        rep("MGR GET_MANAGER_APPID: rc=%d errno=%d(%s) appid=%u  本任务 uid%%100000=%u ⇒ %s",
            rc, rc ? errno : 0, strerror(rc ? errno : 0), ma.appid, (unsigned)(getuid() % 100000),
            (!rc && ma.appid == (unsigned)(getuid() % 100000)) ? "★本 app 就是 Manager" : "不是 Manager");
        rep("MGR 顺带看 GET_INFO 的 flags: MANAGER 位=1<<1 ⇒ 被 crown 时应当从 0xd 变 0xf");
        snprintf(summary, sizeof(summary), "status=0 mgr appid=%u", ma.appid);
        status = 0;
        goto done;
    }
    if (cmd && !strncmp(cmd, "@list", 5)) {
        /* 路线 C 的读侧：UI 上"这个开关现在是开还是关"必须以内核名单为准，不能信 app 自己的缓存
         *   (§6.78 一手：SET_APP_PROFILE 写进去之后内核回读 UID_GRANTED_ROOT 才是真值)。
         * perm=manager_or_root ⇒ 被 crown 的 suw 读得动；未 crown 时这条会 EPERM ⇒ 报告里看得见。 */
        const int cap = 512;
        size_t sz = sizeof(struct ksu_new_get_allow_list_cmd) + sizeof(__u32) * cap;
        struct ksu_new_get_allow_list_cmd *al = calloc(1, sz);
        unsigned n = 0;
        int i;

        if (!al) {
            snprintf(summary, sizeof(summary), "status=9 list-nomem");
            status = 9;
            goto done;
        }
        al->count = (__u16)cap;
        rc = ioctl(got, KSU_IOCTL_NEW_GET_ALLOW_LIST, al);
        rep("LIST NEW_GET_ALLOW_LIST: rc=%d errno=%d(%s) count=%u total=%u", rc,
            rc ? errno : 0, strerror(rc ? errno : 0), al->count, al->total_count);
        if (rc == 0) {
            n = al->count;
            for (i = 0; i < (int)n && i < cap; i++)
                rep("LIST uid=%u", al->uids[i]);
        }
        free(al);
        snprintf(summary, sizeof(summary), "status=%d list rc=%d n=%u", rc ? 6 : 0, rc, n);
        status = rc ? 6 : 0;
        goto done;
    }
    if (cmd && !strncmp(cmd, "@setprof:", 9)) {
        /* 形如 @setprof:<uid>:<0|1>[:<包名>]。allow=1 抄 ksuctl build_profile() 那份**本机验过**的自填
         * profile(域=u:r:shell:s0；use_default=1 那条走不通，default 模板要解 u:r:ksu:s0)；
         * allow=0 只置 allow_su=false 走 non-root 支路 = 把这个 uid 从名单里摘掉。
         * ★第三段包名是路线 C 补的：KSU 的 ksu_prune_allowlist() 会拿 key 去校验 uid，
         *   给别的 app 授权却写自己的包名 ⇒ insmod 后 0.27s 就被整条删掉(§6.46 一手)，
         *   所以**给谁授权就必须写谁的真包名**；不传就还是我们自己(向后兼容旧触发)。 */
        char argb[320], *p1, *p2, *p3, *p4, *q, *cut;
        struct ksu_set_app_profile_cmd sp;
        struct ksu_uid_granted_root_cmd gc;
        long who;
        int allow;
        int ee;                     /* 当场存下来的 errno(见下面 SETPROF 回执那条注释) */
        const char *dom = "u:r:shell:s0";   /* §6.107②：本机验过的自填域 */
        static const char dom_okchars[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:.-";

        if (strlen(cmd + 9) >= sizeof(argb)) {
            rep("SETPROF 参数串太长(%zu >= %zu)", strlen(cmd + 9), sizeof(argb));
            snprintf(summary, sizeof(summary), "status=9 setprof-arg-too-long");
            status = 9;
            goto done;
        }
        strcpy(argb, cmd + 9);
        /* ★不能用 strtok(",") 切第 4 段：SELinux 域**自己就带冒号**(u:r:kernel:s0)，strtok 会把它切成
         * "u"/"r"/"kernel"/"s0"。所以前三段按冒号切，第三段之后的**剩余整串**当域。 */
        p1 = argb;
        p2 = p3 = p4 = NULL;
        cut = strchr(p1, ':');
        if (cut) { *cut++ = 0; p2 = cut; cut = strchr(p2, ':'); }
        if (cut) { *cut++ = 0; p3 = cut; cut = strchr(p3, ':'); }
        if (cut) { *cut++ = 0; p4 = cut; }
        who = p1[0] ? strtol(p1, NULL, 0) : -1;
        allow = (p2 && p2[0]) ? (int)strtol(p2, NULL, 0) : -1;
        /* 第 4 段=可选域(#53)：判据要打在设备侧回执里，不能靠"我们猜它落哪个域"。
         * 只认一个白名单字符集 + 长度上限 ⇒ 传错就停下报错，绝不发半套 profile。 */
        if (p4 && p4[0] && strcmp(p4, "-")) {
            if (strlen(p4) >= sizeof(sp.profile.rp_config.profile.selinux_domain)) {
                rep("SETPROF 域太长(%zu)：[%s]", strlen(p4), p4);
                snprintf(summary, sizeof(summary), "status=9 setprof-domain-too-long");
                status = 9;
                goto done;
            }
            for (q = p4; *q; q++)
                if (!strchr(dom_okchars, *q)) break;
            if (*q) {
                rep("SETPROF 域字符非法：[%s]", p4);
                snprintf(summary, sizeof(summary), "status=9 setprof-domain-badchars");
                status = 9;
                goto done;
            }
            dom = p4;
        }

        if (who < 0 || (allow != 0 && allow != 1)) {
            rep("SETPROF 参数不对: [%s] 要 <uid>:<0|1>", cmd);
            snprintf(summary, sizeof(summary), "status=9 setprof-bad-args");
            status = 9;
            goto done;
        }
        memset(&sp, 0, sizeof(sp));
        sp.profile.version = KSU_APP_PROFILE_VER;
        if (p3 && p3[0]) {
            if (strlen(p3) >= sizeof(sp.profile.key)) {
                rep("SETPROF 包名太长(%zu >= %zu)：[%s]", strlen(p3), sizeof(sp.profile.key), p3);
                snprintf(summary, sizeof(summary), "status=9 setprof-key-too-long");
                status = 9;
                goto done;
            }
            strcpy(sp.profile.key, p3);
        } else {
            strcpy(sp.profile.key, "com.suw.manager");
        }
        sp.profile.curr_uid = (__s32)who;
        sp.profile.allow_su = allow ? true : false;
        if (allow) {
            sp.profile.rp_config.use_default = false;
            sp.profile.rp_config.profile.uid = 0;
            sp.profile.rp_config.profile.gid = 0;
            sp.profile.rp_config.profile.groups_count = 1;
            sp.profile.rp_config.profile.groups[0] = 0;
            sp.profile.rp_config.profile.capabilities.effective = ~(__u64)0;
            sp.profile.rp_config.profile.namespaces = 0; /* KSU_NS_INHERITED */
            strcpy(sp.profile.rp_config.profile.selinux_domain, dom);
        } else {
            sp.profile.nrp_config.use_default = true;
        }
        rc = ioctl(got, KSU_IOCTL_SET_APP_PROFILE, &sp);
        /* ★errno 必须**当场**取好再打印：第 47 发的回执出现 `errno=0(Socket operation on non-socket)`
         *  这种自相矛盾的读数——`rc ? errno : 0` 与 `strerror(errno)` 在同一句里求值顺序未定，
         *  strerror 拿到的是**上一次 socket 调用留下的陈旧 errno**。读数自相矛盾 ⇒ 以后任何
         *  按 "errno=0(Success)" 形状的断言都会莫名其妙地失配。 */
        ee = rc ? errno : 0;
        rep("SETPROF uid=%ld allow=%d key=%s domain=%s: rc=%d errno=%d(%s)", who, allow, sp.profile.key,
            allow ? sp.profile.rp_config.profile.selinux_domain : (const char *)"-",
            rc, ee, strerror(ee));
        memset(&gc, 0, sizeof(gc));
        gc.uid = (__u32)who;
        rc = ioctl(got, KSU_IOCTL_UID_GRANTED_ROOT, &gc);
        rep("SETPROF 之后内核回读 UID_GRANTED_ROOT uid=%ld: rc=%d granted=%u ⇒ 名单是**我们自己**改的",
            who, rc, gc.granted);
        snprintf(summary, sizeof(summary), "status=0 setprof uid=%ld allow=%d granted=%u", who,
                 allow, gc.granted);
        status = 0;
        goto done;
    }

    /* 未 arm = 只做无副作用的握手。★这里**不能**拿 GRANT_ROOT 当负对照：
     *   本 app 的 uid 本来就在名单里，ioctl 会真的成功 ⇒ "不 arm 也被拒"这个预期是错的。
     *   负对照(名单外 uid 光有 fd 也提不上去)由 shell 侧那一发负责:
     *     adb shell /data/local/tmp/shd --ksugrant   (uid 2000 是 system uid，内核 forbid_system_uid) */
    if (!arm) {
        rep("未 arm ⇒ 不申请授权(握手与判据①已过)。负对照请看 `shd --ksugrant`(uid 2000 应被拒)。");
        snprintf(summary, sizeof(summary), "status=0 handshake-ok getinfo-ok");
        status = 0;
        goto done;
    }

    /* 判据②: 授权 —— ★发到 **fork 出来的子进程**里，不发在 UI 进程的线程上。
     *   37/38 发实测：在本 app 自己的线程上 commit_creds 成功之后 ~1 秒，system_server 就
     *   SIGKILL 整个进程（dmesg 一手 `send_signal sig 9 … <- system_server … to … com.suw.manager`）
     *   ⇒ "授权后"那行永远进不了报告，外部观察也抓不到，判据链缺一层。
     *   子进程是**新 pid**、ActivityManager 不认识它 ⇒ 没人按 uid 变化杀它；它单线程 ⇒
     *   commit_creds 之后整个进程 uid=0 ⇒ `/proc/<kid>/status` 的 Uid 八栏全是 0，
     *   这就是上一发缺的那层"不是 app 自报"的一手证据。 */
    {
        int pfd[2];
        pid_t kid;
        char ack[64] = "";
        int waited, st = -1;

        if (pipe(pfd)) {
            rep("pipe 失败 errno=%d(%s) ⇒ 拿不到子进程回报", errno, strerror(errno));
            snprintf(summary, sizeof(summary), "status=7 pipe-fail errno=%d", errno);
            status = 7;
            goto done;
        }
        kid = fork();
        if (kid < 0) {
            rep("fork 失败 errno=%d(%s)", errno, strerror(errno));
            snprintf(summary, sizeof(summary), "status=8 fork-fail errno=%d", errno);
            status = 8;
            goto done;
        }
        if (kid == 0) {
            int e, r, sfd, lf, dm;
            ssize_t sn;
            char kb[32], line[96], sb[2048];
            const char *cc = cmd;

            close(pfd[0]);
            snprintf(kb, sizeof kb, "%d", (int)getpid());
            prctl(PR_SET_NAME, "suwrootd", 0, 0, 0);
            dm = (cc && strncmp(cc, "@daemon:", 8) == 0);
            if (dm)
                cc += 8;
            /* v35(§6.67)：第五十二发两支都是**自己退出的**(child.log 开不出来 ⇒ _exit(2))，
             *   等于没验 exec。三处改：
             *   ① 日志改到 app 自己**已经存在**的外置目录(/sdcard/Android/data/<pkg>/files)，
             *      而且**开不出来也照样往下 exec**(证据主要靠命令自己写 /data/local/tmp)；
             *   ② daemon 版把预开 fd 挪到 fork **之后**：/proc/<tid>/status 的 fd 会钉在
             *      "打开它的那个 task"上，第五十一发孙进程读到的其实是已死的父 task
             *      (Seccomp=2/CapEff=0 那行就是这么来的，是假数据)；
             *   ③ 管道一路留到 execve 之后 ⇒ "exec 失败"有地方报，且 exec 成功的进程退出时
             *      自然给父进程 EOF。 */
            if (dm) {
                if (fork() > 0)
                    _exit(0);
                setsid();
                kstep(pfd[1], "S0b daemon 化完成 pid=%d ppid=%d", (int)getpid(),
                      (int)getppid());
            }
            lf = open("/sdcard/Android/data/com.suw.manager/files/child.log",
                      O_RDWR | O_CREAT | O_TRUNC, 0666);
            sfd = open("/proc/thread-self/status", O_RDONLY | O_CLOEXEC);
            kstep(pfd[1], "S0 授权前预开 child.log=%d status=%d errno=%d(%s) dm=%d",
                  lf, sfd, errno, strerror(errno), dm);
            r = ioctl(got, KSU_IOCTL_GRANT_ROOT, NULL);
            e = errno;
            /* 第一行保持老格式(父进程按 4 个数 sscanf 出判据②)，后面才是步骤行 */
            snprintf(line, sizeof line, "%d %d %u %u\n", r, e,
                     (unsigned)getuid(), (unsigned)geteuid());
            if (write(pfd[1], line, strlen(line)) < 0) { /* 父会自己发现 */ }
            kstep(pfd[1], "S1 grant 返回 rc=%d uid=%u euid=%u ⇒ 立刻 exec",
                  r, (unsigned)getuid(), (unsigned)geteuid());
            if (r != 0 || getuid() != 0) {
                kstep(pfd[1], "S1e 授权未成立 ⇒ 收工");
                close(pfd[1]);
                pfd[1] = -1;
                _exit(1);
            }
            if (sfd >= 0) {
                sn = read(sfd, sb, sizeof(sb) - 1);
                if (sn > 0) {
                    sb[sn] = 0;
                    kstep(pfd[1], "S4 read=%zd Uid=[%s]", sn, fld(sb, "Uid"));
                    kstep(pfd[1], "S4 SigPnd=[%s] Seccomp=[%s]",
                          fld(sb, "SigPnd"), fld(sb, "Seccomp"));
                }
                close(sfd);
            }
            if (lf >= 0) {
                if (dup2(lf, 1) < 0) { /* 忽略 */ }
                if (dup2(lf, 2) < 0) { /* 忽略 */ }
                if (lf > 2)
                    close(lf);
            }
            kstep(pfd[1], "S7 准备 execve [%.120s]", (cc && cc[0]) ? cc : "id");
            execl("/system/bin/sh", "sh", "-c", (cc && cc[0]) ? cc : "id", (char *)0);
            /* 走到这里 = exec 本身失败(不是被杀) */
            kstep(pfd[1], "S8 exec 失败 errno=%d(%s) uid=%u", errno, strerror(errno),
                  (unsigned)getuid());
            close(pfd[1]);
            pfd[1] = -1;
            _exit(3);
        }

        close(pfd[1]);
        {
            char all[4096];
            size_t used = 0;
            ssize_t n;
            char *nl;

            while (used + 1 < sizeof(all)) {
                n = read(pfd[0], all + used, sizeof(all) - 1 - used);
                if (n <= 0)
                    break;
                used += (size_t)n;
                all[used] = 0;
            }
            all[used] = 0;
            if (used == 0)
                rep("判据② 子进程回报=0 字节 ⇒ 它在 ioctl 里就没回来");
            /* 第一行是给 sscanf 用的四元组；其余 S* 步骤行原样落到报告里 */
            nl = strchr(all, '\n');
            if (nl)
                *nl = 0;
            snprintf(ack, sizeof ack, "%s", all);
            if (nl) {
                char *p = nl + 1;
                while (*p) {
                    char *q = strchr(p, '\n');
                    if (q)
                        *q = 0;
                    rep("  %s", p);
                    if (!q)
                        break;
                    p = q + 1;
                }
            }
        }
        close(pfd[0]);
        rep("判据② 子进程回报首行(管道): rc/errno/uid/euid = %s", ack[0] ? ack : "(空)");
        /* ★判据用 sscanf 逐字段读，不用子串匹配（"0 0 10284 10284" 这种只要漏看一位就会读反） */
        {
            int arc = -1, aerrno = 0;
            unsigned au = 1, ae = 1;
            int nf = sscanf(ack, "%d %d %u %u", &arc, &aerrno, &au, &ae);
            if (nf == 4 && arc == 0 && au == 0) {
                rep(">>> 内核级授权成立: app fork 出来的进程靠递进来的 fd 变成 uid=0 <<<");
                snprintf(summary, sizeof(summary), "status=0 GRANTED child pid=%d uid=%u",
                         (int)kid, au);
                status = 0;
            } else {
                snprintf(summary, sizeof(summary),
                         "status=6 not-granted kid=%d fields=%d rc=%d uid=%u",
                         (int)kid, nf, arc, au);
                status = 6;
            }
        }
        /* 父只等到子进程的最终状态为止：★必须把死因分开写(正常退出 / 被哪个信号杀)，
         *   第四十四发的现场是"子进程拿到 uid=0 后 0.5s 就没了"，只写"已收尾"等于没判。 */
        for (waited = 0; waited < 60; waited++) {
            if (waitpid(kid, &st, WNOHANG) == kid)
                break;
            usleep(500000);
        }
        if (st < 0)
            rep("父进程侧: waitpid(kid=%d) 30s 内没等到 ⇒ 子进程还活着(或卡住)", (int)kid);
        else if (WIFSIGNALED(st))
            rep("父进程侧: 子进程 %d **被信号 %d 杀死**(SIGKILL=9 ⇒ 外部杀的，不是我们 _exit)；"
                "core=%d", (int)kid, WTERMSIG(st), WCOREDUMP(st) ? 1 : 0);
        else if (WIFEXITED(st))
            rep("父进程侧: 子进程 %d 正常退出 code=%d", (int)kid, WEXITSTATUS(st));
        else
            rep("父进程侧: 子进程 %d 状态无法解释 st=0x%x", (int)kid, (unsigned)st);
    }

done:
    if (got >= 0)
        close(got);
    if (c >= 0)
        close(c);
    rep("===== 结束(能到这行=进程活下来了) 状态码=%d =====", status);
    close(G_FD);
    G_FD = -1;
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (cmd)
        (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
    out = (*env)->NewStringUTF(env, summary);
    return out;
}
