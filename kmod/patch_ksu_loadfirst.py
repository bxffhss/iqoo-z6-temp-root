#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# patch_ksu_loadfirst.py —— rc71 那一刀：让 ksu_load_allow_list() 读到第一条记录就停。
#   为什么要有它(§6.278)：第 128/129 发已经把致死条件夹到"装载循环多走一圈"这个动作本身
#     (表内容/uid/key/包名真假全都出局)，而 §6.277 逐行读过这段代码里没有定时/异步成分
#     ⇒ 数据侧再也夹不动了，只能进 ko：磁盘文件仍逐字节 1576 字节，唯一差别=循环只跑一圈。
#   判据(开枪前写死在任务 #108)：活过 +30 分钟 ⇒ 死在"循环体被执行"；仍 +16~30 秒 ⇒ 死在"打开并读了这个文件"那一层。
# 用法：python3 patch_ksu_loadfirst.py <allowlist.c 路径> [--selftest]
import hashlib
import io
import os
import subprocess
import sys
import tempfile

MARK = "RC71 LOADFIRST"

ANCHOR_A = "#include <linux/kref.h>\n"
REPL_A = "#include <linux/kref.h>\n#include <linux/moduleparam.h> /* " + MARK + " */\n"

ANCHOR_B = "#define FILE_FORMAT_VERSION 4 // u32\n"
REPL_B = (
    "#define FILE_FORMAT_VERSION 4 // u32\n"
    "\n"
    "bool ksu_load_first_only = false;\n"
    "module_param(ksu_load_first_only, bool, 0);\n"
    "MODULE_PARM_DESC(ksu_load_first_only, \"" + MARK + ": stop after the first allowlist record\");\n"
)

ANCHOR_C = ("        pr_info(\"load_allow_uid, name: %s, uid: %d, allow: %d\\n\", profile.key, profile.curr_uid, profile.allow_su);\n"
            "        ksu_set_app_profile(&profile);\n"
            "    }\n")
REPL_C = ("        pr_info(\"load_allow_uid, name: %s, uid: %d, allow: %d\\n\", profile.key, profile.curr_uid, profile.allow_su);\n"
          "        ksu_set_app_profile(&profile);\n"
          "        if (ksu_load_first_only) {\n"
          "            pr_info(\"" + MARK + " stop after first: name=%s uid=%d\\n\", profile.key, profile.curr_uid);\n"
          "            break;\n"
          "        }\n"
          "    }\n")

PAIRS = [("A-include", ANCHOR_A, REPL_A), ("B-param", ANCHOR_B, REPL_B), ("C-break", ANCHOR_C, REPL_C)]


def md5(b):
    return hashlib.md5(b).hexdigest()


def load(p):
    return io.open(p, encoding="utf-8", newline="").read()


def patch(s):
    for name, a, r in PAIRS:
        n = s.count(a)
        if n != 1:
            raise SystemExit("[x] 锚点 %s 命中 %d 次(必须 1) ⇒ 停手，别硬编" % (name, n))
        s = s.replace(a, r, 1)
    return s


def apply_file(p):
    src = load(p)
    m0 = md5(src.encode("utf-8"))
    nmark = src.count(MARK)
    if nmark == 3:
        io.open(p, "w", encoding="utf-8", newline="").write(src)
        print("已打过(标记数=3) ⇒ 幂等跳过；md5 不变 %s" % m0)
        return m0, m0
    if nmark != 0:
        raise SystemExit("[x] 标记数=%d(既不是 0 也不是 3) ⇒ 这是一份**半打**的文件，停手别接着编" % nmark)
    out = patch(src)
    if out.count(MARK) != 3:
        raise SystemExit("[x] 打完之后标记数=%d(必须 3) ⇒ 这一份不可信，停" % out.count(MARK))
    io.open(p, "w", encoding="utf-8", newline="").write(out)
    m1 = md5(out.encode("utf-8"))
    print("打完了：md5 %s -> %s  字节=%d  标记数=%d" % (m0, m1, len(out.encode("utf-8")), out.count(MARK)))
    return m0, m1


def selftest():
    # 1) 证明"第一遍真的改了"：M0 != M1(例 88)
    # 2) 幂等：再跑一遍 M1 == M2(例 72)
    # 3) 拒绝坏输入：锚点被挪走 ⇒ 必须非 0 退出(变异测试)
    # 4) 末行唯一：break 那段只出现 1 次
    ref = sys.argv[2] if len(sys.argv) > 2 else None
    if not ref:
        raise SystemExit("selftest 需要第二个参数：参照用的 allowlist.c 路径")
    base = load(ref)
    tmp = []
    try:
        for i in range(3):
            fd, p = tempfile.mkstemp(suffix=".c")
            os.close(fd)
            tmp.append(p)
            io.open(p, "w", encoding="utf-8", newline="").write(base)
        a0, a1 = apply_file(tmp[0])
        assert a0 != a1, "[x] 第一遍没改 ⇒ 作废"
        print("  [1] 证明动了：M0=%s != M1=%s ✓" % (a0[:8], a1[:8]))
        b0, b1 = apply_file(tmp[0])
        assert b1 == a1, "[x] 第二遍改了东西 ⇒ 不幂等"
        print("  [2] 幂等：再跑一遍 md5 不变 ✓")
        c = load(tmp[0])
        assert c.count("if (ksu_load_first_only) {") == 1, "[x] break 段不止一处"
        print("  [3] 末行唯一：break 段 1 处 ✓")
        bad = base.replace(ANCHOR_C, "        ksu_set_app_profile(&profile);\n    }\n")
        if bad == base:
            raise SystemExit("[x] 变异测试没变异成(ANCHOR_C 不在 base 里) ⇒ 这一格等于没测")
        assert bad.count(ANCHOR_C) == 0, "[x] 变异没生效"
        fd, p2 = tempfile.mkstemp(suffix=".c")
        os.close(fd)
        tmp.append(p2)
        io.open(p2, "w", encoding="utf-8", newline="").write(bad)
        rc = subprocess.run([sys.executable, __file__, p2], capture_output=True).returncode
        assert rc != 0, "[x] 锚点没了还能跑成 ⇒ 这个闸是假的"
        print("  [4] 拒绝坏输入(**未打过**的 base 里把 break 锚点改掉)：退出码=%d ✓" % rc)
        # 4b) "半打"的文件必须被拦下来（幂等判断不能太松）
        half = patch(base).replace(REPL_A, ANCHOR_A, 1)  # 把 A 那一刀退回去 ⇒ 标记数=2
        if half.count(MARK) != 2:
            raise SystemExit("[x] 造不出半打样本(标记数=%d) ⇒ 这一格等于没测" % half.count(MARK))
        fd, p3 = tempfile.mkstemp(suffix=".c")
        os.close(fd)
        tmp.append(p3)
        io.open(p3, "w", encoding="utf-8", newline="").write(half)
        rc2 = subprocess.run([sys.executable, __file__, p3], capture_output=True).returncode
        assert rc2 != 0, "[x] 半打的文件被当成已打过放过去了 ⇒ 幂等判断太松"
        print("  [4b] 半打(标记数=2)必须被拒：退出码=%d ✓" % rc2)
        print("SELFTEST 全过；打好的 md5=%s" % a1)
    finally:
        for p in tmp:
            try:
                os.unlink(p)
            except OSError:
                pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        selftest()
    else:
        apply_file(sys.argv[1])
