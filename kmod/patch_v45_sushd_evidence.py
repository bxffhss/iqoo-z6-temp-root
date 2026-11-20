import io
import sys

NL = chr(10)
QT = chr(34)
BS = chr(92)

# ── 1) 守护：把命令输出另外落一份到 /data/local/tmp/sushd_last.out ─────────
P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()
if "sushd_last.out" in s:
    print("ksuctl 已改过 ⇒ 跳过")
else:
    old = "\t\t\t(unsigned)uc.uid, strlen(out)," + NL
    if s.count(old) != 1:
        sys.exit("ksuctl anchor count=%d" % s.count(old))
    ins = r'''		/* ★判据不能只挂在 app 那条 socket 上：第六十六发守护确实回完了(102 字节、exit=0)，
		 *   但 app 侧那一行没落进报告(当时 com.suw.manager 的 memcg 正被强制回收、UI 线程
		 *   卡在 read 上) ⇒ 只靠 app 自报会把**成功**读成"未知"。
		 *   所以把命令的输出再落一份到"root 才写得动、shell 读得到"的地方。 */
		{
			int of = open("/data/local/tmp/sushd_last.out",
				      O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);

			if (of >= 0) {
				char hdr[128];
				int hn = snprintf(hdr, sizeof hdr,
						  "sushd: 发起 uid=%u 内核答 granted=1 exit=%d 输出 %zu 字节\n",
						  (unsigned)uc.uid,
						  WIFEXITED(st) ? WEXITSTATUS(st) : -1,
						  strlen(out));

				if (hn > 0 && write(of, hdr, (size_t)hn) < 0) { }
				if (out[0] && write(of, out, strlen(out)) < 0) { }
				close(of);
			}
		}
'''
    s = s.replace(old, ins + old)
    io.open(P, "w", encoding="utf-8", newline="").write(s)
    print("ksuctl：输出另落 sushd_last.out")

# ── 2) JNI 客户端：读带超时 + 另存一份(报告文件每次触发都被 O_TRUNC 冲掉) ──────
P2 = "suw_apk/suwksu_jni.c"
t = io.open(P2, encoding="utf-8").read()
if "sushd_out.txt" in t:
    print("JNI 已改过 ⇒ 跳过")
else:
    old2 = r'''    rep("SUSHD 已把命令交给 root 侧守护：[%.140s]", real);
    for (;;) {
        n = read(c, buf, sizeof(buf) - 1);
        if (n <= 0)
            break;
        buf[n] = 0;
        rep("SUSHD 回: %s", buf);
    }
    close(c);'''
    if t.count(old2) != 1:
        sys.exit("JNI anchor count=%d" % t.count(old2))
    new2 = r'''    rep("SUSHD 已把命令交给 root 侧守护：[%.140s]", real);
    {
        /* ①读要有截止时间：这段跑在 app 的 **UI 线程**上，卡住就等于把进程交出去
         *   (第六十六发就是守护回完了、app 这侧一行没落盘)。 */
        struct timeval tv;
        int of;

        tv.tv_sec = 25;
        tv.tv_usec = 0;
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        /* ②另存一份：报告文件每次触发都是 O_TRUNC 重写的，后面几发会冲掉这一格 */
        of = open("/sdcard/Android/data/com.suw.manager/files/sushd_out.txt",
                  O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (of < 0)
            rep("SUSHD 开不出 sushd_out.txt errno=%d(%s)", errno, strerror(errno));
        for (;;) {
            n = read(c, buf, sizeof(buf) - 1);
            if (n < 0) {
                rep("SUSHD 读结束 errno=%d(%s)", errno, strerror(errno));
                break;
            }
            if (n == 0)
                break;
            buf[n] = 0;
            rep("SUSHD 回: %s", buf);
            if (of >= 0 && write(of, buf, (size_t)n) < 0) { }
        }
        if (of >= 0)
            close(of);
    }
    close(c);'''
    t = t.replace(old2, new2)
    io.open(P2, "w", encoding="utf-8", newline="").write(t)
    print("JNI：读超时 + 另存 sushd_out.txt")
