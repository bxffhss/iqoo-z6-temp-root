#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""由 build_exp6d.py 逐字派生 build_cut5.py；片段从 _cut5_patch_snippet.txt 读入，避开引号嵌套。"""
import io, os

BASE = r"G:/项目/Windows管理/usb/临时root/kmod/"
s = open(BASE + "build_exp6d.py", encoding="utf-8").read()
snippet = open(BASE + "_cut5_patch_snippet.txt", encoding="utf-8").read()


def rep(old, new, n=1):
    global s
    c = s.count(old)
    assert c == n, "命中 %d 次(期望 %d): %r" % (c, n, old[:80])
    s = s.replace(old, new, n)


# 1) docstring
a = s.index('"""')
b = s.index('"""', a + 3)
doc = '''"""Exp-9 构建（§6.612）：cut=5 —— §6.603 七写了、但从没打过的那一格。

差集已被压到 7 项（见 kmod/w1222_next_probe_plan.md）：
  cut=1（prologue 后立刻 return orig）活 >=193.5 s；完整 decline 段 ~19.5 s 死。
  quiet=1 已否掉 SD1 打印；noslow=1 已否掉慢路；第 16 枪否掉并发；第 17 枪否掉"第一次进入"。
cut=5 = 在 SD1 decline 分支里、ksu_hp_pr 与 goto **之前**直接 return orig：
  保留 execveat 检查 / filename_user 检查 / ksu_is_allow_uid_for_current()；
  跳过 SD1 打印 / goto / do_orig_execve 标签体 / **函数尾 return orig 的编译形态**。
  · 仍 ~19.5 s 死 => 凶手在前三行 => 下一发 cut=6 再逐行二分。
  · 活 >=30 min => 凶手在标签体或"尾部 return 的调用形态" => 反汇编对比 cut=1 与完整 decline。

本文件由 build_exp6d.py 逐字派生（quiet 总闸 + cut=1/2 框架不改一个字符），只做：
  E-1 加 ksu_exp6_cut5_hits 计数  E-2 加 cut=5 切口
  E-3 加 /proc/ksu_ser 拉取式见证（沿用同名，w1223 采集器不用改）
  本发 args：mode=1 + ksu_exp6_cut=5（quiet 缺省 0）；不开 rate/serial/once/noslow。

用法：python build_cut5.py            # 预览（0 接触）
      python build_cut5.py --apply    # 备份+上传+编译+拉回+无条件还原
"""'''
s = s[:a] + doc + s[b + 3:]

# 2) 常量
rep('BK_SEB = "/tmp/seb_exp6d_orig.c"', 'BK_SEB = "/tmp/seb_cut5_orig.c"')
rep('BK_SC = "/tmp/sucompat_exp6d_orig.c"', 'BK_SC = "/tmp/sucompat_cut5_orig.c"')
rep('LOG = "/home/lucy/exp6d_build.log"', 'LOG = "/home/lucy/cut5_build.log"')
rep('KO_HOME = "/home/lucy/kernelsu_exp6d.ko"', 'KO_HOME = "/home/lucy/kernelsu_cut5.ko"')
rep('LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp6d.ko"',
    'LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_cut5.ko"')
rep('data = api.read_bytes("kernelsu_exp6d.ko")', 'data = api.read_bytes("kernelsu_cut5.ko")')
rep('"EXP6D_KO_OK"', '"CUT5_KO_OK"')

# 3) 计数变量
rep('unsigned ksu_exp6_cut2_hits = 0;\n"""',
    'unsigned ksu_exp6_cut2_hits = 0;\nunsigned ksu_exp6_cut5_hits = 0;\n"""')

# 4) 把 cut=2 那一行替换成 "cut=2 + 整个片段"
rep('sc2 = sc2.replace(CUT2_ANCHOR, CUT2_BLOCK + CUT2_ANCHOR, 1)\n',
    snippet + '\n')

# 5) 自检扩展
rep("for need in ('ksu_exp6_cut1_hits', 'ksu_exp6_cut2_hits', 'KSUBEAT CUT1', 'KSUBEAT CUT2'):",
    "for need in ('ksu_exp6_cut1_hits', 'ksu_exp6_cut2_hits', 'KSUBEAT CUT1', 'KSUBEAT CUT2',\n"
    "             'ksu_exp6_cut5_hits', 'KSUBEAT CUT5', 'ksu_cut5_read', 'proc_create'):")

# 6) 预览落盘
rep('if not APPLY:\n    print("\\n==> 预览模式：未碰远端。确认 diff 后可加 --apply。")\n    sys.exit(0)',
    'if not APPLY:\n'
    '    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_cut5_seb.c", "w",\n'
    '         encoding="utf-8", newline="\\n").write(seb2)\n'
    '    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_cut5_sucompat.c", "w",\n'
    '         encoding="utf-8", newline="\\n").write(sc2)\n'
    '    print("\\n==> 预览模式：未碰远端。已落 _preview_cut5_*.c；确认后可加 --apply。")\n'
    '    sys.exit(0)')

# 7) apply 前加一道 ko 现状检查（防止备份错件）
rep('rc = api.exec("cp -f %s %s && md5sum %s" % (KO_REMOTE, KO_RC80_BK, KO_RC80_BK), timeout=180)',
    'chk = api.exec("md5sum %s" % KO_REMOTE, timeout=120)\n'
    'got_ko = chk.stdout.split()[0] if chk.stdout.split() else ""\n'
    'print("==> 远端 kernelsu.ko 现状:", got_ko)\n'
    'if got_ko != "98bf405273e8652cdb7fffcc3fe42dc2":\n'
    '    raise SystemExit("!! 远端 kernelsu.ko 不是 rc80，拒绝（免得备份错件）")\n'
    'rc = api.exec("cp -f %s %s && md5sum %s" % (KO_REMOTE, KO_RC80_BK, KO_RC80_BK), timeout=180)')

open(BASE + "build_cut5.py", "w", encoding="utf-8", newline="\n").write(s)
print("生成 build_cut5.py，行数", len(s.splitlines()))
