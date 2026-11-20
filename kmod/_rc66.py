# -*- coding: utf-8 -*-
# _rc66.py —— rc66 = rc65 + `/proc/ksu_crown` 的两处健壮性(§6.188④ 那颗静默地雷)：
#   ① 空写/纯空白/非数字开头 ⇒ **只记回执、不改王座**(printf 的第二次空 write 会把 appid 清成 0)
#   ② 加 **read 处理器** ⇒ 查询根本不必往写口灌东西(地雷的源头就是"用一次写来查询")
#   两步精确替换 + 锚点必须各命中 1 次 + 写后回读。
import io

p = "kmod/ksu_dev_syms_rc66.c"
s = io.open(p, encoding="utf-8", errors="replace").read()

A1 = "want = simple_strtoul(buf, NULL, 10);"

GUARD = r"""/* rc66(#82, §6.188④)：只有**真的写了数字**才动王座。
	 * 一手事故：`printf '?\n' > /proc/ksu_crown` 在设备上产生**两次 write**(`?` 与 `\n`)，
	 * 第二次是空串 ⇒ `simple_strtoul("")` 返回 0 ⇒ 王座被**静默清零**(那一发正好在救窗口的中途)。
	 * ⇒ 空写/纯空白/非数字开头一律只记回执不改账；查询请走下面的 .read。 */
	{
		const char *q = buf;

		while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r')
			q++;
		if (*q < '0' || *q > '9') {
			ksu_slots_puts("CROWN 忽略空写/非数字[%s]，现在仍=%u\n", buf, (unsigned)prev);
			return cnt;
		}
	}
	"""

N1 = GUARD + A1

A2 = ('static const struct file_operations ksu_crown_fops = {\n'
      '\t.owner = THIS_MODULE,\n'
      '\t.write = ksu_crown_write,\n'
      '\t.llseek = no_llseek,\n'
      '};')

READFN = r"""/* rc66(#82)：`cat /proc/ksu_crown` 直接回当前 appid。
 * 为什么要读口：§6.188④ 那次是把"查询"写成了 `printf '?\n' > 这个口`——一次写变成两次 write，
 * 空的那次把王座清了零。**能读就没人会用写去问**，这比在写口里加解释更对症。 */
static ssize_t ksu_crown_read(struct file *filp, char __user *ubuf, size_t cnt, loff_t *ppos)
{
	char b[32];
	int len;

	len = snprintf(b, sizeof(b), "%u\n", (unsigned)ksu_manager_appid);
	return simple_read_from_buffer(ubuf, cnt, ppos, b, len);
}

"""

N2 = READFN + ('static const struct file_operations ksu_crown_fops = {\n'
               '\t.owner = THIS_MODULE,\n'
               '\t.read = ksu_crown_read,\n'
               '\t.write = ksu_crown_write,\n'
               '\t.llseek = no_llseek,\n'
               '};')

for name, a in (("GUARD", A1), ("READFOPS", A2)):
    c = s.count(a)
    print("锚点 %s 命中 %d" % (name, c))
    if c != 1:
        raise SystemExit("[x] %s 锚点不是 1 次 ⇒ 不写盘" % name)

n0 = len(s.encode("utf-8"))
s = s.replace(A1, N1, 1).replace(A2, N2, 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)

b = io.open(p, "rb").read()
print("[ok] 写后回读：字节 %d (原 %d) 变长=%s" % (len(b), n0, len(b) > n0))
for pat in (b"CROWN \xe5\xbf\x98\xe7\x95\xa5\xe7\xa9\xba\xe5\x86\x99",      # CROWN 忽略空写
            b"static ssize_t ksu_crown_read",
            b".read = ksu_crown_read,",
            b"simple_read_from_buffer(ubuf, cnt, ppos, b, len)",
            b"want = simple_strtoul(buf, NULL, 10);"):
    print("  命中 %-2d  %s" % (b.count(pat), pat[:34].decode("utf-8", "replace")))
# 幂等性：再跑一次应当两个锚点都变 0(说明不会重复插入)
s2 = io.open(p, encoding="utf-8", errors="replace").read()
print("[幂等] 再跑一次会命中：GUARD=%d READFOPS=%d (都应为 0 ⇒ 不会重复插)"
      % (s2.count(A1), s2.count(A2)))
