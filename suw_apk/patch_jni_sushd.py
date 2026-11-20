import io
import sys

P = "suw_apk/suwksu_jni.c"
s = io.open(P, encoding="utf-8").read()

if "@sushd:" in s:
    print("已经有 sushd 客户端 ⇒ 跳过")
    raise SystemExit(0)

# 1) 客户端函数：放在 nativeRun 之前
anchor = "Java_com_suw_manager_Ksu_nativeRun"
i = s.find(anchor)
if i < 0:
    sys.exit("找不到 nativeRun")
# 往前找到这个函数的注释/签名开头
j = s.rfind("\n/*", 0, i)
if j < 0:
    j = s.rfind("\nJNIEXPORT", 0, i)
if j < 0:
    sys.exit("找不到插入点")

FN = r'''
/* v42(§6.69③ / §6.72③)：**app 侧只当客户端**，root 命令交给 root 侧守护跑。
 * 为什么要这一格：本机厂商模块 vr 有两道执法——①靠 escape 变 uid 0 立刻被 force_sig(SIGKILL)
 *   (rc32 能软掉)，②这个任务接着 execve 被 EPERM。而窗口里"生下来就是 root"的进程 execve
 *   一切正常 ⇒ "替 app 跑一条 root 命令"的执行体只能是它(ksuctl sushd)。
 * 授权判定**不在这里也不在守护里写规则**：守护拿 SO_PEERCRED 的发起 uid 去问内核
 *   UID_GRANTED_ROOT ⇒ 名单(=KernelSU 白名单)说没有就没有。
 * 用法：cmd 以 "@sushd:" 开头 ⇒ 把冒号后面那段交给守护执行，结果逐行写进报告。
 */
#define SUW_SUSHD_TOKEN "changeme"

static void run_via_sushd(const char *cmd)
{
    struct sockaddr_un a;
    char q[1400], buf[8192];
    ssize_t n;
    int c, on = 1;
    const char *real = cmd + 7;   /* 去掉 "@sushd:" */

    c = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c < 0) {
        rep("SUSHD socket 失败 errno=%d(%s)", errno, strerror(errno));
        return;
    }
    setsockopt(c, SOL_SOCKET, SO_PASSCRED, &on, sizeof(on));
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    memcpy(a.sun_path + 1, "suwksu", 6);
    if (connect(c, (struct sockaddr *)&a,
                (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + 6)) < 0) {
        rep("SUSHD connect @suwksu 失败 errno=%d(%s) ⇒ root 侧守护没在跑?",
            errno, strerror(errno));
        close(c);
        return;
    }
    snprintf(q, sizeof q, "RUN %s %s\n", SUW_SUSHD_TOKEN, real);
    if (write(c, q, strlen(q)) < 0) {
        rep("SUSHD 发请求失败 errno=%d(%s)", errno, strerror(errno));
        close(c);
        return;
    }
    rep("SUSHD 已把命令交给 root 侧守护：[%.140s]", real);
    for (;;) {
        n = read(c, buf, sizeof(buf) - 1);
        if (n <= 0)
            break;
        buf[n] = 0;
        rep("SUSHD 回: %s", buf);
    }
    close(c);
}

'''
s = s[:j] + FN + s[j:]

# 2) nativeRun 里分流
old2 = '    rep("===== app 侧内核授权自检 arm=%d =====", (int)arm);\n'
assert s.count(old2) == 1, "anchor2"
new2 = (
    old2
    + "    /* ★分流：@sushd: 前缀 = 让 root 侧守护替我跑(本机 app 自己 exec 会被 vr 挡，§6.72) */\n"
    + "    if (cmd && strncmp(cmd, \"@sushd:\", 7) == 0) {\n"
    + "        run_via_sushd(cmd);\n"
    + "        rep(\"===== 结束(走守护代跑，不碰本进程 cred) 状态码=0 =====\");\n"
    + "        (*env)->ReleaseStringUTFChars(env, jpath, path);\n"
    + "        if (cmd)\n"
    + "            (*env)->ReleaseStringUTFChars(env, jcmd, cmd);\n"
    + "        G_FD = -1;\n"
    + "        return (*env)->NewStringUTF(env, \"status=0 via-sushd\");\n"
    + "    }\n"
)
s = s.replace(old2, new2)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("sushd 客户端已加进 JNI")
