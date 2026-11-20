#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 app 侧授权从"UI 进程的线程"改成"fork 出来的专职子进程"(md §6.62)。

为什么必须改（第三十七/三十八发的一手证据）：在 app 自己的线程上 commit_creds 之后 ~1 秒，
system_server 就 SIGKILL 整个 app 进程（dmesg: `send_signal sig 9 … <- system_server … to … com.suw.manager`），
于是"授权后"那一行永远进不了报告，外部 /proc 观察也抓不到 —— 判据链少一层。
子进程是 fork 出来的**新进程**，ActivityManager 不认识它 ⇒ 没人按 uid 变化杀它；它单线程 ⇒
commit_creds 之后整个进程 uid=0 ⇒ `/proc/<kid>/status` 一眼就能证明（这正好补上缺的那层外部证据）。
顺带加 `cmd` 参数：子进程拿到 root 后 exec `sh -c <cmd>`，把输出写进同一份报告 ⇒ 直接证明
"模块/脚本可以走这条通路跑起来"（exec 失败也要有 errno，那就是 app 域能不能 exec 的一手答案）。
"""
import io
import sys

P = "suwksu_jni.c"
s = io.open(P, encoding="utf-8", errors="replace").read()
orig = s

# ---- 1) 签名加 cmd 参数 --------------------------------------------------
a = "Java_com_suw_manager_Ksu_nativeRun(JNIEnv *env, jclass cls, jstring jpath, jboolean jarm)\n{\n    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);\n    const jboolean arm = jarm;"
b = ("Java_com_suw_manager_Ksu_nativeRun(JNIEnv *env, jclass cls, jstring jpath, jboolean jarm,\n"
     "                                jstring jcmd)\n"
     "{\n    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);\n"
     "    const jboolean arm = jarm;\n"
     "    const char *cmd = jcmd ? (*env)->GetStringUTFChars(env, jcmd, NULL) : NULL;")
assert s.count(a) == 1, ("签名锚点", s.count(a))
s = s.replace(a, b)

# ---- 2) 整段判据②换成"子进程授权" ----------------------------------------
start = s.index("    /* 判据②: 真授权。")
end = s.index("done:\n", start)
new = '''    /* 判据②: 授权 —— ★发到 **fork 出来的子进程**里，不发在 UI 进程的线程上。
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
            int e, r;
            char kb[32], line[96];
            close(pfd[0]);
            snprintf(kb, sizeof kb, "%d", (int)getpid());
            prctl(PR_SET_NAME, "suwrootd", 0, 0, 0);
            rep("子进程 pid=%s 起点 getuid=%u euid=%u ⇒ 授权前它和 app 一样是 10284",
                kb, (unsigned)getuid(), (unsigned)geteuid());
            r = ioctl(got, KSU_IOCTL_GRANT_ROOT, NULL);
            e = errno;
            snprintf(line, sizeof line, "%d %d %u %u", r, e,
                     (unsigned)getuid(), (unsigned)geteuid());
            if (write(pfd[1], line, strlen(line)) < 0) { /* 父会自己发现 */ }
            close(pfd[1]);
            if (r == 0 && getuid() == 0) {
                int i2;
                rep("子进程授权成功 uid=%u euid=%u gid=%u ★外部判据窗口 %ds: "
                    "/proc/%s/status 的 Uid 应当全是 0",
                    (unsigned)getuid(), (unsigned)geteuid(), (unsigned)getgid(),
                    PARK_SEC, kb);
                for (i2 = 1; i2 <= PARK_SEC; i2++) {
                    if (i2 % 4 == 0)
                        rep("子进程驻留 t+%02ds: uid=%u", i2, (unsigned)getuid());
                    sleep(1);
                }
                if (cmd && cmd[0]) {
                    rep("子进程 exec /system/bin/sh -c [%.160s] —— 输出直接进本报告", cmd);
                    fsync(G_FD);
                    if (dup2(G_FD, 1) < 0) { /* 忽略 */ }
                    if (dup2(G_FD, 2) < 0) { /* 忽略 */ }
                    execl("/system/bin/sh", "sh", "-c", cmd, (char *)0);
                    rep("exec 失败 errno=%d(%s) ⇒ app 域 exec 被拦(SELinux/seccomp)，"
                        "但 uid 已经是 0，这一格本身就是新知识", errno, strerror(errno));
                }
            } else {
                rep("子进程授权未成立: rc=%d errno=%d(%s) uid=%u", r, e, strerror(e),
                    (unsigned)getuid());
            }
            _exit(r == 0 && getuid() == 0 ? 0 : 1);
        }

        close(pfd[1]);
        {
            ssize_t n = read(pfd[0], ack, sizeof(ack) - 1);
            if (n > 0)
                ack[n] = 0;
        }
        close(pfd[0]);
        rep("判据② 子进程回报(来自管道，不靠共享文件偏移): rc/errno/uid/euid = %s",
            ack[0] ? ack : "(没回报 ⇒ 子进程在 ioctl 里就没回来)");
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
        /* 父只等一小会儿：子进程要驻留 PARK_SEC 供外部观察，JNI 线程没必要一起挂着；
         * 等不到就用 WNOHANG 收尾 —— 子进程会变 init 的孤儿继续活到驻留结束。 */
        for (waited = 0; waited < 6; waited++) {
            if (waitpid(kid, &st, WNOHANG) == kid)
                break;
            usleep(500000);
        }
        rep("父进程侧: waitpid(kid=%d) => %s (子进程还在驻留的话这里没收尾是正常的)",
            (int)kid, st < 0 ? "超时未收尾" : "已收尾");
    }

'''
s = s[:start] + new + s[end:]

# ---- 3) 收尾时把 jcmd 释放掉，别让 GetStringUTFChars 泄漏 ------------------
a3 = "    (*env)->ReleaseStringUTFChars(env, jpath, path);\n    out = (*env)->NewStringUTF(env, summary);"
b3 = ("    (*env)->ReleaseStringUTFChars(env, jpath, path);\n"
      "    if (cmd)\n        (*env)->ReleaseStringUTFChars(env, jcmd, cmd);\n"
      "    out = (*env)->NewStringUTF(env, summary);")
assert s.count(a3) == 1, ("释放锚点", s.count(a3))
s = s.replace(a3, b3)

if s == orig:
    print("!! 没有实际改动")
    sys.exit(1)
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("suwksu_jni.c: 授权已改成子进程形态 + cmd 执行支路")
