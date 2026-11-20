import io
import sys

NL = chr(10)
QT = chr(34)

P = "suw_apk/suwksu_jni.c"
s = io.open(P, encoding="utf-8").read()

if "文件通道" in s:
    print("JNI 已经是 v46 ⇒ 跳过")
    raise SystemExit(0)

if "#include <sys/stat.h>" not in s:
    s = s.replace("#include <sys/socket.h>" + NL,
                  "#include <sys/socket.h>" + NL + "#include <sys/stat.h>" + NL, 1)
    print("ok [sys/stat.h]")

old = NL.join([
    '    snprintf(q, sizeof q, "RUN %s %s' + chr(92) + 'n", SUW_SUSHD_TOKEN, real);',
    "    if (write(c, q, strlen(q)) < 0) {",
    '        rep("SUSHD 发请求失败 errno=%d(%s)", errno, strerror(errno));',
    "        close(c);",
    "        return;",
    "    }",
    '    rep("SUSHD 已把命令交给 root 侧守护：[%.140s]", real);',
])
if s.count(old) != 1:
    sys.exit("ANCHOR FAIL [发送段] count=%d" % s.count(old))

new = NL.join([
    "    {",
    "        /* v46：先把上一次的落盘文件删掉，再发请求 ⇒ 否则轮询会读到**上一发留下的**内容。",
    "         *   请求里带上自己的包名，守护就把输出落到我们自己的私有目录。 */",
    "        unlink(SUSHD_APP_FILE);",
    '        snprintf(q, sizeof q, "RUN %s %s %s' + chr(92) + 'n", SUW_SUSHD_TOKEN, SUSHD_PKG, real);',
    "        if (write(c, q, strlen(q)) < 0) {",
    '            rep("SUSHD 发请求失败 errno=%d(%s)", errno, strerror(errno));',
    "            close(c);",
    "            return;",
    "        }",
    '        rep("SUSHD 已把命令交给 root 侧守护：[%.140s]", real);',
    "    }",
])
s = s.replace(old, new)

old2 = NL.join([
    "    {",
    "        /* ①读要有截止时间：这段跑在 app 的 **UI 线程**上，卡住就等于把进程交出去",
    "         *   (第六十六发就是守护回完了、app 这侧一行没落盘)。 */",
    "        struct timeval tv;",
    "        int of;",
    "",
    "        tv.tv_sec = 25;",
    "        tv.tv_usec = 0;",
    "        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));",
    '        /* ②另存一份：报告文件每次触发都是 O_TRUNC 重写的，后面几发会冲掉这一格 */',
    '        of = open("/sdcard/Android/data/com.suw.manager/files/sushd_out.txt",',
    "                  O_WRONLY | O_CREAT | O_APPEND, 0666);",
    "        if (of < 0)",
    '            rep("SUSHD 开不出 sushd_out.txt errno=%d(%s)", errno, strerror(errno));',
    "        for (;;) {",
    "            n = read(c, buf, sizeof(buf) - 1);",
    "            if (n < 0) {",
    '                rep("SUSHD 读结束 errno=%d(%s)", errno, strerror(errno));',
    "                break;",
    "            }",
    "            if (n == 0)",
    "                break;",
    "            buf[n] = 0;",
    '            rep("SUSHD 回: %s", buf);',
    "            if (of >= 0 && write(of, buf, (size_t)n) < 0) { }",
    "        }",
    "        if (of >= 0)",
    "            close(of);",
    "    }",
])
if s.count(old2) != 1:
    sys.exit("ANCHOR FAIL [读回包段] count=%d" % s.count(old2))

new2 = NL.join([
    "    {",
    "        /* ★判据这一格换通道：这段跑在 app 的 **UI 线程**上，第六十六/六十七发正逢",
    "         *   com.suw.manager 的 memcg 被强制回收 ⇒ 守护那边明明" + QT + "已回给 … 102 字节 exit=0" + QT + "，",
    "         *   app 这侧阻塞在 socket read 上却一行都没落盘。所以改成**只轮询本地文件**",
    "         *   (read 一个私有目录里的小文件不会卡)，socket 那份降级成补充信息、2s 超时。 */",
    "        struct timeval tv;",
    "        struct stat st;",
    "        int k, fd, gotb = 0;",
    "",
    "        for (k = 0; k < 60; k++) {",
    "            if (stat(SUSHD_APP_FILE, &st) == 0 && st.st_size > 0)",
    "                break;",
    "            usleep(200000);",
    "        }",
    '        rep("SUSHD 等落盘文件用了 %dms", k * 200);',
    "        fd = open(SUSHD_APP_FILE, O_RDONLY | O_CLOEXEC);",
    "        if (fd < 0) {",
    '            rep("SUSHD 读不到 %s errno=%d(%s)", SUSHD_APP_FILE, errno, strerror(errno));',
    "        } else {",
    "            n = read(fd, buf, sizeof(buf) - 1);",
    "            close(fd);",
    "            if (n > 0) {",
    "                buf[n] = 0;",
    "                gotb = 1;",
    '                rep("SUSHD 回(文件通道): %s", buf);',
    "            } else {",
    '                rep("SUSHD 文件里没东西 rc=%zd", n);',
    "            }",
    "        }",
    "        tv.tv_sec = 2;",
    "        tv.tv_usec = 0;",
    "        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));",
    "        n = read(c, buf, sizeof(buf) - 1);",
    "        if (n > 0) {",
    "            buf[n] = 0;",
    '            rep("SUSHD 回(socket): %s", buf);',
    "        }",
    "        if (gotb) {",
    "            int of = open(SUSHD_EXT_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);",
    "",
    "            if (of >= 0) {",
    "                if (write(of, buf, strlen(buf)) < 0) { }",
    "                close(of);",
    "            }",
    "        }",
    "    }",
])
s = s.replace(old2, new2)

# 宏定义
s = s.replace(
    '#define SUW_SUSHD_TOKEN "changeme"',
    '#define SUW_SUSHD_TOKEN "changeme"' + NL
    + '#define SUSHD_PKG "com.suw.manager"          /* 守护靠它定位发起者的私有目录 */' + NL
    + '#define SUSHD_APP_FILE "/data/data/com.suw.manager/files/sushd_out.txt"' + NL
    + '#define SUSHD_EXT_FILE "/sdcard/Android/data/com.suw.manager/files/sushd_out.txt"',
    1,
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("JNI v46：改成轮询私有目录里的落盘文件")
