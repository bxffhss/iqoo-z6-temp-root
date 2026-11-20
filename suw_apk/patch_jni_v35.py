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

'''
s = s[:i] + NEW + s[j + len("        close(pfd[1]);\n"):]
s = s[:i + len(NEW)] + "        close(pfd[1]);\n" + s[i + len(NEW):]
if s.count(A_END) != 1:
    sys.exit("POST-CHECK FAIL count=%d" % s.count(A_END))

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
