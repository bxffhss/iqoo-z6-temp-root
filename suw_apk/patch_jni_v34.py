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
            /* v34(§6.67)：凶手已点名——厂商模块 **vr** 里有个函数在受害者自己的上下文里调
             *   force_sig(SIGKILL)(kprobe: `fs: force_sig sig=0x9 lr=0xffffffd03435e408`，
             *   那个 LR 落在模块 vr 的 text 里、整段没有符号)。它不是挂在 open 上，而是挂在
             *   **调度点**上(第五十一发：signal_generate 之后 10ms 才 deliver，期间子进程
             *   连 openat 都没来得及进)。所以这一版把"授权后要做的 open"全部提前到授权**之前**
             *   (uid 10284 写得了自己的 /data/data ⇒ 日志与 stdout 不依赖授权后的任何 open)，
             *   授权后只剩 read + dup2 + execve ⇒ 抢在杀之前把 mm 换掉。
             *   若"换了 mm 就不杀"成立 ⇒ 模块的 `su -c` 原语成立。 */
            lf = open("/data/data/com.suw.manager/files/child.log",
                      O_RDWR | O_CREAT | O_TRUNC, 0666);
            sfd = open("/proc/thread-self/status", O_RDONLY | O_CLOEXEC);
            kstep(pfd[1], "S0 授权前预开 child.log=%d status=%d errno=%d(%s) dm=%d",
                  lf, sfd, errno, strerror(errno), dm);
            if (dm) {
                /* 二次 fork + setsid：第一子立刻退出 ⇒ 孙进程被 init 收养(ppid=1)。
                 *   vr 若判的是"uid 0 却挂在 app 底下"，这一支就该活下来。 */
                if (fork() > 0)
                    _exit(0);
                setsid();
                kstep(pfd[1], "S0b daemon 化完成 pid=%d ppid=%d", (int)getpid(),
                      (int)getppid());
            }
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
                    kstep(pfd[1], "S4 read=%zd SigPnd=[%s]", sn, fld(sb, "SigPnd"));
                    kstep(pfd[1], "S4 Seccomp=[%s] CapEff=[%s]",
                          fld(sb, "Seccomp"), fld(sb, "CapEff"));
                }
                close(sfd);
            }
            /* ★管道到此为止：daemon 版不能占着写端，否则 app 侧要等它退出才拿到报告 */
            close(pfd[1]);
            pfd[1] = -1;
            if (lf < 0)
                _exit(2);
            if (dup2(lf, 1) < 0) { /* 忽略 */ }
            if (dup2(lf, 2) < 0) { /* 忽略 */ }
            execl("/system/bin/sh", "sh", "-c", (cc && cc[0]) ? cc : "id", (char *)0);
            /* 走到这里 = exec 本身失败(不是被杀) */
            {
                int ee = errno;
                char b[160];
                int n = snprintf(b, sizeof b, "S8 exec 失败 errno=%d(%s) uid=%u\r\n",
                                 ee, strerror(ee), (unsigned)getuid());
                if (n > 0 && write(lf, b, (size_t)n) < 0) { /* 没地方可报了 */ }
                fsync(lf);
            }
            _exit(3);
        }

'''
s = s[:i] + NEW + s[j + len("        close(pfd[1]);\n"):]
s = s[:i + len(NEW)] + "        close(pfd[1]);\n" + s[i + len(NEW):]
if s.count(A_END) != 1:
    sys.exit("POST-CHECK FAIL count=%d" % s.count(A_END))

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
