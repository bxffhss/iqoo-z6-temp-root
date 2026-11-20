#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""整块重写 suwksu_jni.c 里的 root 子进程分支(修掉行级缝合留下的坏括号/丢掉的 S4)。

子进程的每一步都经**管道**回报 —— 管道是实测在 GRANT_ROOT 之后仍然可用的信道，
所以"死在第几个 syscall"能直接读出来，不依赖任何文件能否打开。
"""
import io
import sys

P = "suw_apk/suwksu_jni.c"
NL = chr(10)
SQ = chr(39)
DQ = chr(34)
BS = chr(92)

s = io.open(P, encoding="utf-8", errors="replace").read()
lines = s.split(NL)

i = -1
for k, l in enumerate(lines):
    if l.strip() == "if (kid == 0) {":
        i = k
        break
if i < 0:
    print("!! 找不到子进程分支开头")
    sys.exit(1)

j = -1
for k in range(i, len(lines)):
    if "_exit(r == 0 && getuid() == 0 ? 0 : 1);" in lines[k]:
        j = k + 1          # 下一行是分支的收尾 '        }'
        break
if j < 0 or lines[j].strip() != "}":
    print("!! 找不到子进程分支结尾", lines[j] if j > 0 else "")
    sys.exit(1)

new = r'''        if (kid == 0) {
            int e, r, sfd, lf, i2;
            ssize_t sn;
            char kb[32], line[96], sb[2048];

            close(pfd[0]);
            snprintf(kb, sizeof kb, "%d", (int)getpid());
            prctl(PR_SET_NAME, "suwrootd", 0, 0, 0);
            r = ioctl(got, KSU_IOCTL_GRANT_ROOT, NULL);
            e = errno;
            /* 第一行保持老格式(父进程按 4 个数 sscanf 出判据②)，后面才是步骤行 */
            snprintf(line, sizeof line, "%d %d %u %u\n", r, e,
                     (unsigned)getuid(), (unsigned)geteuid());
            if (write(pfd[1], line, strlen(line)) < 0) { /* 父会自己发现 */ }
            kstep(pfd[1], "S1 grant 返回 rc=%d errno=%d(%s) uid=%u euid=%u gid=%u",
                  r, e, strerror(e), (unsigned)getuid(), (unsigned)geteuid(), (unsigned)getgid());
            if (r != 0 || getuid() != 0) {
                kstep(pfd[1], "S1e 授权未成立 ⇒ 后面什么都不做");
                close(pfd[1]);
                pfd[1] = -1;
                _exit(1);
            }
            kstep(pfd[1], "S2 write(管道) 仍可用 ⇒ 至少 write 这个 syscall 没被当场杀");
            sfd = open("/proc/thread-self/status", O_RDONLY | O_CLOEXEC);
            kstep(pfd[1], "S3 openat(/proc/thread-self/status)=%d errno=%d(%s)",
                  sfd, sfd < 0 ? errno : 0, sfd < 0 ? strerror(errno) : "ok");
            if (sfd >= 0) {
                sn = read(sfd, sb, sizeof(sb) - 1);
                if (sn > 0) {
                    sb[sn] = 0;
                    /* ★S4 是关键一格里的一格：SigPnd/ShdPnd 若已经带着 9，
                     *   说明信号是 grant 当时就挂上的(只是没能兑现)；全 0 则是"下一个 syscall 才挨"。 */
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
            /* ★管道到此为止：先关掉它，父进程才能不等驻留/exec 就拿到整份黑匣子 */
            close(pfd[1]);
            pfd[1] = -1;
            lf = open("/data/local/tmp/suw_child.log",
                      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
            if (lf < 0) {
                rep("S6 openat(/data/local/tmp/suw_child.log) 失败 errno=%d(%s) ⇒ 退回报告文件写"
                    "(不 fsync，避免 §6.63 那个 D 状态)", errno, strerror(errno));
                _exit(0);
            }
            crep(lf, "S6 子进程 %s 授权后仍活着 uid=%u ⇒ /data 也能写", kb, (unsigned)getuid());
            if (cmd && cmd[0]) {
                int cf = open("/data/local/tmp/suw_cmd.out",
                              O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
                crep(lf, "S7 suw_cmd.out fd=%d errno=%d(%s)，准备 exec sh -c [%.160s]",
                     cf, cf < 0 ? errno : 0, cf < 0 ? strerror(errno) : "ok", cmd);
                if (cf >= 0) {
                    if (dup2(cf, 1) < 0) { /* 忽略 */ }
                    if (dup2(cf, 2) < 0) { /* 忽略 */ }
                    close(cf);
                }
                execl("/system/bin/sh", "sh", "-c", cmd, (char *)0);
                crep(lf, "S8 exec 失败 errno=%d(%s) ⇒ 不是被杀，是 exec 本身被拒",
                     errno, strerror(errno));
            }
            for (i2 = 1; i2 <= PARK_SEC; i2++) {
                if (i2 % 5 == 0)
                    crep(lf, "S9 驻留 t+%02ds: uid=%u", i2, (unsigned)getuid());
                sleep(1);
            }
            close(lf);
            _exit(0);
        }'''.replace("\\n", BS + "n")

lines[i:j + 1] = new.split(NL)
io.open(P, "w", encoding="utf-8", newline=NL).write(NL.join(lines))
print("子进程分支已整块重写(原 %d..%d 行)" % (i + 1, j + 1))
