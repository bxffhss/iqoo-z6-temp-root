# -*- coding: utf-8 -*-
# _rc65.py —— 给 dev_syms 加 /proc/ksu_crown(王座归属把手)，两步精确替换 + 写后回读
import io

p = "kmod/ksu_dev_syms_rc65.c"
s = io.open(p, encoding="utf-8", errors="replace").read()

KNOB_ANCHOR = """static const struct file_operations ksu_mgrdomain_fops = {
\t.owner = THIS_MODULE,
\t.write = ksu_mgrdomain_write,
\t.llseek = no_llseek,
};"""

KNOB_NEW = KNOB_ANCHOR + """

/* ===== rc65(#82)：运行期改"王座归属"，触发口 `/proc/ksu_crown`(0600) =====
 * 为什么要它：加冕发生在 insmod 那一刻 —— throne_tracker 扫 /data/app，按**签名**认第一个匹配者
 *   (`crown_manager()` 命中就 `ksu_set_manager_appid()`)，而 ko 只认两个期望值
 *   (`EXPECTED_HASH` / `EXPECTED_HASH2`)。suw 与官方 Manager 的证书不同 ⇒ **共存时谁戴冠不确定**
 *   (§6.169 就是"官方占着王座"把 suw 的闸门打成 FAIL=6)
 *   ⇒ 想可重复地测官方 UI，必须先有一个确定性的"现在王座是谁"的把手。
 * 形状：`echo <appid> > /proc/ksu_crown` 把 `ksu_manager_appid` 换成那个数(appid = uid % 100000)；
 *       `echo ? > /proc/ksu_crown` 只把当前值打进 /proc/ksu_slots(每发都整份导出)。
 * ★切走之前一定先留退路：用当时的王座身份给 suw 自己写一条普通 app 的 profile
 *   (`@setprof:<suw 的 uid>:1:com.suw.manager`)——王座是"自动允许"，一旦被换掉，
 *   suw 只剩普通 app 身份，`@sushd:`/`@setprof` 会全断(而它是唯一 root 通道)。 */
extern uid_t ksu_manager_appid; /* manager/throne_tracker.c：llvm-nm 里是 `D ksu_manager_appid` */

static struct proc_dir_entry *ksu_crown_pe;

static ssize_t ksu_crown_write(struct file *filp, const char __user *ubuf, size_t cnt, loff_t *ppos)
{
\tchar buf[32];
\tsize_t n = cnt < sizeof(buf) - 1 ? cnt : sizeof(buf) - 1;
\tunsigned long want;
\tuid_t prev = ksu_manager_appid;

\tif (copy_from_user(buf, ubuf, n))
\t\treturn -EFAULT;
\tbuf[n] = 0;
\tif (n && buf[n - 1] == '\\n')
\t\tbuf[n - 1] = 0;
\tif (buf[0] == '?') {
\t\tksu_slots_puts("CROWN 现在 appid=%u\\n", (unsigned)prev);
\t\treturn cnt;
\t}
\twant = simple_strtoul(buf, NULL, 10);
\tif (want > 100000) { /* appid = uid%100000，超出这个范围一定是打错了 */
\t\tksu_slots_puts("CROWN 拒绝[%s](appid 必须 <=100000)，现在仍=%u\\n", buf, (unsigned)prev);
\t\treturn cnt;
\t}
\tksu_manager_appid = (uid_t)want;
\tksu_slots_puts("CROWN 改 appid=%u(写前=%u) 串=[%s]\\n", (unsigned)want, (unsigned)prev, buf);
\tpr_info("CROWN 王座换人: appid %u -> %u\\n", (unsigned)prev, (unsigned)want);
\treturn cnt;
}

static const struct file_operations ksu_crown_fops = {
\t.owner = THIS_MODULE,
\t.write = ksu_crown_write,
\t.llseek = no_llseek,
};"""

CREATE_ANCHOR = "\tfor (i = 0; i < sizeof(ksu_pcode_funcs) / sizeof(ksu_pcode_funcs[0]); i++)"

CREATE_NEW = """\t/* rc65(#82)：王座归属的运行期把手(默认不写=加冕照旧由 insmod 那一刻的扫描决定)。 */
\tif (!ksu_crown_pe)
\t\tksu_crown_pe = proc_create("ksu_crown", 0600, NULL, &ksu_crown_fops);
\tksu_slots_puts("crown proc=%s 起点 appid=%u\\n", ksu_crown_pe ? "ok" : "FAIL",
\t\t       (unsigned)ksu_manager_appid);
""" + CREATE_ANCHOR

for name, a in (("KNOB", KNOB_ANCHOR), ("CREATE", CREATE_ANCHOR)):
    c = s.count(a)
    print("锚点 %s 命中 %d" % (name, c))
    if c != 1:
        raise SystemExit("[x] %s 锚点不是 1 次 ⇒ 不写盘" % name)

n0 = len(s.encode("utf-8"))
s = s.replace(KNOB_ANCHOR, KNOB_NEW, 1).replace(CREATE_ANCHOR, CREATE_NEW, 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)

b = io.open(p, "rb").read()
print("[ok] 写后回读：字节 %d (原 %d，只增) 长度对=%s" % (len(b), n0, len(b) > n0))
for pat in (b"static ssize_t ksu_crown_write", b'proc_create("ksu_crown", 0600',
            b"extern uid_t ksu_manager_appid;", b"CROWN \xe6\x94\xb9 appid", b"crown proc="):
    print("  %-42s 命中 %d" % (pat[:30].decode("utf-8", "replace"), b.count(pat)))
