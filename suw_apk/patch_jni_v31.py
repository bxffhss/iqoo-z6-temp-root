import io, sys

P = "suw_apk/suwksu_jni.c"
s = io.open(P, encoding="utf-8").read()


def sub(old, new, tag):
    global s
    if s.count(old) != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, s.count(old)))
    s = s.replace(old, new)
    print("ok [%s]" % tag)


# ── 1) fld() 的 static 缓冲别名 bug ──────────────────────────────────
OLD_FLD = r'''static const char *fld(const char *buf, const char *name)
{
    static char out[64];
    const char *q;
    char pat[32];
    int i;
'''
NEW_FLD = r'''static const char *fld(const char *buf, const char *name)
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
'''
sub(OLD_FLD, NEW_FLD, "fld rotating pool")

sub('        snprintf(out, sizeof out, "(无 %s)", name);',
    '        snprintf(out, 64, "(无 %s)", name);', "fld sizeof fix 1")
sub('    snprintf(out, sizeof out, "%s", q);',
    '    snprintf(out, 64, "%s", q);', "fld sizeof fix 2")

# ── 2) 子进程黑匣子 v31 ──────────────────────────────────────────────
A_START = "        if (kid == 0) {"
A_END = "        close(pfd[1]);\n        {"
i = s.find(A_START)
if i < 0 or s.count(A_START) != 1:
    sys.exit("ANCHOR FAIL start count=%d" % s.count(A_START))
j = s.find(A_END, i)
if j < 0:
    sys.exit("ANCHOR FAIL end")

NEW = r'''        if (kid == 0) {
            int e, r, sfd, adf, lf, i2, tf;
            ssize_t sn;
            char kb[32], line[96], sb[2048], dom[128];

            close(pfd[0]);
            snprintf(kb, sizeof kb, "%d", (int)getpid());
            prctl(PR_SET_NAME, "suwrootd", 0, 0, 0);
            /* v31：授权前把**两个** proc fd 都开好(那时还是 uid 10284，开得动)：
             *   sfd = /proc/thread-self/status       → 授权后读 SigPnd/Seccomp
             *   adf = /proc/thread-self/attr/current → 授权后读**真实 SELinux 域**
             * 上一发(§6.65)钉死的是：授权后连做 8 个 syscall 都活着，死在**第一个
             * openat** 上；而内核侧 X6 明明跑了 setup_selinux(u:r:shell:s0) ⇒ 到底
             * 生效没有，只有 attr/current 能回答(域还是 untrusted_app ⇒ "uid 0 却待在
             * app 域"就是凶手画像)。 */
            sfd = open("/proc/thread-self/status", O_RDONLY | O_CLOEXEC);
            adf = open("/proc/thread-self/attr/current", O_RDWR | O_CLOEXEC);
            kstep(pfd[1], "S0 授权前预开 status=%d attr=%d errno=%d(%s)",
                  sfd, adf, errno, strerror(errno));
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
            kstep(pfd[1], "S2 write(管道) 仍可用");
            if (sfd >= 0) {
                sn = read(sfd, sb, sizeof(sb) - 1);
                if (sn > 0) {
                    sb[sn] = 0;
                    kstep(pfd[1], "S4 read=%zd SigPnd=[%s]", sn, fld(sb, "SigPnd"));
                    kstep(pfd[1], "S4 ShdPnd=[%s]", fld(sb, "ShdPnd"));
                    kstep(pfd[1], "S4 SigBlk=[%s]", fld(sb, "SigBlk"));
                    kstep(pfd[1], "S4 Seccomp=[%s]", fld(sb, "Seccomp"));
                    kstep(pfd[1], "S4 NStgid=[%s]", fld(sb, "NStgid"));
                } else {
                    kstep(pfd[1], "S4 read 失败 rc=%zd errno=%d(%s)", sn, errno, strerror(errno));
                }
            }
            if (adf >= 0) {
                sn = read(adf, dom, sizeof(dom) - 1);
                if (sn > 0) {
                    dom[sn] = 0;
                    kstep(pfd[1], "S4g 授权后真实域=[%s]", dom);
                } else {
                    kstep(pfd[1], "S4g 读 attr/current 失败 rc=%zd errno=%d(%s)",
                          sn, errno, strerror(errno));
                }
            }
            /* H2：先做一次**自愿上下文切换**，一个 open 都不碰。
             *   死在这儿 ⇒ 凶手挂在"调度出去时保存 fpsimd/别的 per-CPU 状态"上，
             *   与 openat 无关(上一发只是碰巧死在 openat 那一格)。 */
            kstep(pfd[1], "S5c 准备 nanosleep(2ms)：只走调度路径");
            {
                struct timespec ts;
                ts.tv_sec = 0;
                ts.tv_nsec = 2000000;
                tf = (int)nanosleep(&ts, NULL);
            }
            kstep(pfd[1], "S5d nanosleep rc=%d errno=%d(%s) ⇒ 活着回来",
                  tf, errno, strerror(errno));
            /* H1：只读打开一个现成的、跟 /data 无关的文件 ⇒ 区分"任何 open"和
             *   "在 /data 里 O_CREAT 建文件"。 */
            kstep(pfd[1], "S5e 准备 openat(/dev/null, O_RDONLY)");
            tf = open("/dev/null", O_RDONLY | O_CLOEXEC);
            kstep(pfd[1], "S5f openat(/dev/null)=%d errno=%d(%s)",
                  tf, tf < 0 ? errno : 0, tf < 0 ? strerror(errno) : "ok");
            if (tf >= 0)
                close(tf);
            kstep(pfd[1], "S5g 准备 openat(/data/local/tmp/suw_child.log)");
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
s = s[:i + len(NEW)] + "        close(pfd[1]);\n" + s[i + len(NEW):]
if s.count(A_END) != 1:
    sys.exit("POST-CHECK FAIL count=%d" % s.count(A_END))

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("written %s bytes=%d" % (P, len(s)))
