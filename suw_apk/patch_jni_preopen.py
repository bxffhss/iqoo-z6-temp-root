import io, sys

P = "suw_apk/suwksu_jni.c"
s = io.open(P, encoding="utf-8").read()

A_START = "        if (kid == 0) {"
A_END = "        close(pfd[1]);\n        {"

i = s.find(A_START)
if i < 0 or s.count(A_START) != 1:
    sys.exit("ANCHOR FAIL start count=%d" % s.count(A_START))
j = s.find(A_END, i)
if j < 0:
    sys.exit("ANCHOR FAIL end")

NEW = r'''        if (kid == 0) {
            int e, r, sfd, lf, i2;
            ssize_t sn;
            char kb[32], line[96], sb[2048];

            close(pfd[0]);
            snprintf(kb, sizeof kb, "%d", (int)getpid());
            prctl(PR_SET_NAME, "suwrootd", 0, 0, 0);
            /* v30：status fd 在授权**之前**开好(那时还是 uid 10284，开得动)。
             *   上一发黑匣子：授权后 3 次 write 全活、死在下一次 openat 上 ⇒
             *   这一版授权后一个 openat 都不做，只 read 预开的 fd，把"open 招杀"
             *   和"信号本来就挂着、只是在这一步兑现"分开。
             *   管道也先不关：每个危险 syscall 前后各插一格，死了就知道死在哪格。 */
            sfd = open("/proc/thread-self/status", O_RDONLY | O_CLOEXEC);
            kstep(pfd[1], "S0 授权前预开 status fd=%d errno=%d(%s)",
                  sfd, sfd < 0 ? errno : 0, sfd < 0 ? strerror(errno) : "ok");
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
            kstep(pfd[1], "S2b 授权后不做 openat，只 read 预开的 fd=%d", sfd);
            if (sfd >= 0) {
                sn = read(sfd, sb, sizeof(sb) - 1);
                if (sn > 0) {
                    ssize_t sn2;
                    sb[sn] = 0;
                    /* ★S4 是关键一格里的一格：SigPnd/ShdPnd 若已经带着 9，
                     *   说明信号是 grant 当时就挂上的(只是没能兑现)；全 0 则是"下一个 syscall 才挨"。 */
                    kstep(pfd[1], "S4 read=%zd SigPnd=[%s] ShdPnd=[%s] SigBlk=[%s] Seccomp=[%s] CapEff=[%s]",
                          sn, fld(sb, "SigPnd"), fld(sb, "ShdPnd"), fld(sb, "SigBlk"),
                          fld(sb, "Seccomp"), fld(sb, "CapEff"));
                    /* seq_file：不 seek 第二次 read 只会拿到 0(EOF)，所以先 lseek 回 0 再读一遍 */
                    sn2 = (lseek(sfd, 0, SEEK_SET) == 0) ? read(sfd, sb, sizeof(sb) - 1) : -1;
                    if (sn2 > 0) {
                        sb[sn2] = 0;
                        kstep(pfd[1], "S4b 二次 read=%zd SigPnd=[%s] ShdPnd=[%s]",
                              sn2, fld(sb, "SigPnd"), fld(sb, "ShdPnd"));
                    } else {
                        kstep(pfd[1], "S4b 二次 read 失败 rc=%zd errno=%d(%s)",
                              sn2, errno, strerror(errno));
                    }
                } else {
                    kstep(pfd[1], "S4 read 失败 rc=%zd errno=%d(%s)", sn, errno, strerror(errno));
                }
                close(sfd);
            }
            kstep(pfd[1], "S5 prctl(PR_GET_SECCOMP)=%d errno=%d(%s)",
                  prctl(PR_GET_SECCOMP), errno, strerror(errno));
            kstep(pfd[1], "S5b 准备 openat(/data/local/tmp/suw_child.log)");
            lf = open("/data/local/tmp/suw_child.log",
                      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
            kstep(pfd[1], "S6 openat(suw_child.log)=%d errno=%d(%s)",
                  lf, lf < 0 ? errno : 0, lf < 0 ? strerror(errno) : "ok");
            if (lf < 0) {
                close(pfd[1]);
                pfd[1] = -1;
                _exit(0);
            }
            crep(lf, "S6c 子进程 %s 授权后仍活着 uid=%u ⇒ /data 也能写", kb, (unsigned)getuid());
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
                close(pfd[1]);
                pfd[1] = -1;
                execl("/system/bin/sh", "sh", "-c", cmd, (char *)0);
                crep(lf, "S8 exec 失败 errno=%d(%s) ⇒ 不是被杀，是 exec 本身被拒",
                     errno, strerror(errno));
            } else {
                close(pfd[1]);
                pfd[1] = -1;
            }
            for (i2 = 1; i2 <= PARK_SEC; i2++) {
                if (i2 % 5 == 0)
                    crep(lf, "S9 驻留 t+%02ds: uid=%u", i2, (unsigned)getuid());
                sleep(1);
            }
            close(lf);
            _exit(0);
        }

'''

s = s[:i] + NEW + s[j + len("        close(pfd[1]);\n"):]
# 上面把父进程那行 close(pfd[1]); 一起吃掉了，补回来
s = s[:i + len(NEW)] + "        close(pfd[1]);\n" + s[i + len(NEW):]
if s.count(A_END) != 1:
    sys.exit("POST-CHECK FAIL: 父进程块开头被弄坏 count=%d" % s.count(A_END))

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("rewrote child block; bytes=%d" % len(s))
