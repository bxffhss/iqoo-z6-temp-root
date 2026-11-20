#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 root 子进程改成"逐步经管道回报"，用来钉死那道 SIGKILL 到底落在第几个 syscall 上。

为什么要这么做(第 46 发的一手事实)：
  - 子进程在 GRANT_ROOT 返回后 0.5s 被 **SIGKILL**(`send_signal sig 9 … code 128=SI_KERNEL`)；
  - 它上一版的动作顺序是 写管道(成功!) → close → **openat(/data/local/tmp)** ← 死在这里之后，
    所以两个产物文件都没生成，我们只知道"死了"，不知道"死在哪一步"。
  ⇒ 管道是唯一被证明 grant 后还可用的信道，于是把每一步都用管道写出来；管道在驻留/exec 前先关掉，
    保证父进程能立刻拿到 EOF 而不被挂住。
"""
import io
import sys

P = "suw_apk/suwksu_jni.c"
s = io.open(P, encoding="utf-8", errors="replace").read()

# ---- 1) 加两个小助手：kstep(管道逐步回报) 与 fld(从 status 文本里取字段) ----
anchor = "static void crep(int fd, const char *fmt, ...)"
assert s.count(anchor) == 1, "crep 锚点"
helpers = '''/* kstep —— 子进程**每一步**都往管道写一行：管道是实测在 GRANT_ROOT 之后仍然可用的信道
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
    static char out[64];
    const char *q;
    char pat[32];
    int i;

    for (i = 0; name[i] && i < (int)sizeof(pat) - 2; i++)
        pat[i] = name[i];
    pat[i] = ':';
    pat[i + 1] = 0;
    q = strstr(buf, pat);
    if (!q) {
        snprintf(out, sizeof out, "(无 %s)", name);
        return out;
    }
    q += strlen(pat);
    while (*q == ' ' || *q == '\t')
        q++;
    snprintf(out, sizeof out, "%s", q);
    {
        char *z = strchr(out, '\n');
        if (z)
            *z = 0;
    }
    return out;
}

'''
s = s.replace(anchor, helpers + anchor)

# ---- 2) 子进程整段换成"逐步回报"版 ----
i = s.index("        if (kid == 0) {")
j = s.index("            _exit(r == 0 && getuid() == 0 ? 0 : 1);\n        }\n", i)
j += len("            _exit(r == 0 && getuid() == 0 ? 0 : 1);\n        }\n")

new_child = '''        if (kid == 0) {
            int e, r, sfd, lf;
            ssize_t sn;
            char kb[32], line[96], sb[2048];

            close(pfd[0]);
            snprintf(kb, sizeof kb, "%d", (int)getpid());
            prctl(PR_SET_NAME, "suwrootd", 0, 0, 0);
            r = ioctl(got, KSU_IOCTL_GRANT_ROOT, NULL);
            e = errno;
            /* 第一行保持老格式(父进程按 4 个数 sscanf 出判据②)，后面才追加步骤行 */
            snprintf(line, sizeof line, "%d %d %u %u\\n", r, e,
                     (unsigned)getuid(), (unsigned)geteuid());
            if (write(pfd[1], line, strlen(line)) < 0) { /* 父会自己发现 */ }
            kstep(pfd[1], "S1 grant 返回 rc=%d errno=%d(%s) uid=%u euid=%u gid=%u comm=suwrootd",
                  r, e, strerror(e), (unsigned)getuid(), (unsigned)geteuid(), (unsigned)getgid());
            if (r == 0 && getuid() == 0) {
                kstep(pfd[1], "S2 write(管道) 仍可用 ⇒ 至少 write 这个 syscall 没被当场杀");
                sfd = open("/proc/thread-self/status", O_RDONLY | O_CLOEXEC);
                kstep(pfd[1], "S3 openat(/proc/thread-self/status)=%d errno=%d(%s)",
                      sfd, sfd < 0 ? errno : 0, sfd < 0 ? strerror(errno) : "ok");
                if (sfd >= 0) {
                    sn = read(sfd, sb, sizeof(sb) - 1);
                    if (sn > 0) {
                        sb[sn] = 0;
                        kstep(pfd[1], "S4 read=%zd SigPnd=[%s] ShdPnd=[%s] SigBlk=[%s] Seccomp=[%s] CapEff=[%s]",
                              sn, fld(sb, "SigPnd"), fld(sb, "ShdPnd"), fld(sb, "SigBlk"),
                              fld(sb, "Seccomp"), fld(sb, "CapEff"));
                    } else {
                        kstep(pfd[1], "S4 read 失败 rc=%zd errno=%d(%s)", sn, errno, strerror(errno));
                    }
                    close(sfd);
                }
                kstep(pfd[1], "S5 prctl(PR_GET_SECCOMP)=%d errno=%d(%s)",
                      prctl(PR_GET_SECCOMP), errno, strerror(errno));
                /* ★管道到此为止：先关它，父进程才能不等驻留/exec 就拿到全量黑匣子 */
                close(pfd[1]);
                pfd[1] = -1;
                lf = open("/data/local/tmp/suw_child.log", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
                if (lf >= 0) {
                    crep(lf, "S6 openat(/data/local/tmp/suw_child.log) 成功 fd=%d ⇒ /data 也可写", lf);
                    if (cmd && cmd[0]) {
                        int cf = open("/data/local/tmp/suw_cmd.out",
                                      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
                        crep(lf, "S7 suw_cmd.out fd=%d，准备 exec /system/bin/sh -c [%.160s]", cf, cmd);
                        if (cf >= 0) {
                            if (dup2(cf, 1) < 0) { /* 忽略 */ }
                            if (dup2(cf, 2) < 0) { /* 忽略 */ }
                            close(cf);
                        }
                        execl("/system/bin/sh", "sh", "-c", cmd, (char *)0);
                        crep(lf, "S8 exec 失败 errno=%d(%s) ⇒ 不是被杀，是 exec 本身被拒",
                              errno, strerror(errno));
                    }
                    {
                        int i2;
                        for (i2 = 1; i2 <= PARK_SEC; i2++) {
                            if (i2 % 5 == 0)
                                crep(lf, "S9 驻留 t+%02ds: uid=%u", i2, (unsigned)getuid());
                            sleep(1);
                        }
                    }
                    close(lf);
                } else {
                    /* /data 不能写：退回 FUSE 报告(不 fsync，避免 §6.63 那个 D 状态) */
                    rep("S6 openat(/data/local/tmp/suw_child.log) 失败 errno=%d(%s) ⇒ 退回报告文件",
                        errno, strerror(errno));
                }
            } else {
                kstep(pfd[1], "S1e 授权未成立: rc=%d errno=%d(%s) uid=%u",
                      r, e, strerror(e), (unsigned)getuid());
                close(pfd[1]);
                pfd[1] = -1;
            }
            _exit(r == 0 && getuid() == 0 ? 0 : 1);
        }
'''
s = s[:i] + new_child + s[j:]

# ---- 3) 父进程：把管道读干净(多行)，逐行落进报告 ----
old_par = '''        close(pfd[1]);
        {
            ssize_t n = read(pfd[0], ack, sizeof(ack) - 1);
            if (n > 0)
                ack[n] = 0;
        }
        close(pfd[0]);
        rep("判据② 子进程回报(来自管道，不靠共享文件偏移): rc/errno/uid/euid = %s",
            ack[0] ? ack : "(没回报 ⇒ 子进程在 ioctl 里就没回来)");'''
new_par = '''        close(pfd[1]);
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
            nl = strchr(all, '\\n');
            if (nl)
                *nl = 0;
            snprintf(ack, sizeof ack, "%s", all);
            if (nl) {
                char *p = nl + 1;
                while (*p) {
                    char *q = strchr(p, '\\n');
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
        rep("判据② 子进程回报首行(管道): rc/errno/uid/euid = %s", ack[0] ? ack : "(空)");'''
assert s.count(old_par) == 1, "父进程读管道锚点"
s = s.replace(old_par, new_par)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("子进程已改成逐步管道回报版")
