import io, sys

M = sys.argv[1]
p = M + "/core/init.c"
s = io.open(p, encoding="utf-8", errors="replace").read()

if "ksu_killscan_run" in s:
    print("init.c 已经有 killscan ⇒ 跳过")
    raise SystemExit(0)

anchor = "        ksu_file_wrapper_init();\n    }\n"
if s.count(anchor) != 1:
    sys.exit("ANCHOR FAIL: ksu_file_wrapper_init 段 count=%d" % s.count(anchor))

s = s.replace(
    anchor,
    anchor
    + "\n    /* killscan(§6.69)：扫厂商模块里所有 bl->force_sig，默认只打印。放 init 末尾：\n"
    + "     *   这时 KSU 自己的符号解析层已经热好了，走的是 kallsyms 而不是 kprobe ⇒ 不会跟\n"
    + "     *   insmod 的 module_mutex 抢锁序。 */\n"
    + "    { extern void ksu_killscan_run(void); ksu_killscan_run(); }\n",
)

io.open(p, "w", encoding="utf-8", newline="").write(s)
print("init.c 已挂 killscan")
