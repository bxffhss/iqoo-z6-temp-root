#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""由 build_exp6d.py 派生 build_cut56.py：同一 ko 支持 cut=5(对照) / cut=6(新切口)。"""
BASE = r"G:/项目/Windows管理/usb/临时root/kmod/"
s = open(BASE + "build_exp6d.py", encoding="utf-8").read()
snippet = open(BASE + "_cut56_patch_snippet.txt", encoding="utf-8").read()


def rep(old, new, n=1):
    global s
    c = s.count(old)
    assert c == n, "命中 %d 次(期望 %d): %r" % (c, n, old[:80])
    s = s.replace(old, new, n)


a = s.index('"""')
b = s.index('"""', a + 3)
doc = '''"""Exp-10 构建（§6.613）：同一 ko 同时支持 cut=5(对照) / cut=6(新切口)。

第 18 枪结论（§6.612）：cut=1（函数开头 return）活，cut=5（名单判定之后 return）仍 18.28 s 死
⇒ 凶手在两者之间的三行：execveat && flags / !filename_user / ksu_is_allow_uid_for_current()。
cut=6 ＝ 在 `filename_user` 检查之后、`ksu_is_allow_uid_for_current()` **之前** return orig，
        即前两行检查保留、名单判定不执行。
★cut=1 已经在「execveat 检查之前」切过且活了，所以 cut=6 必须切在名单判定之前、
  而不是 execveat 之前（那会是重复空枪）——这是 21:4x 纠正过的定义。

两个切口互斥、由 ksu_exp6_cut 选；同一 ko 可跑 5 和 6 ⇒ 消除 ko 差异这个共变源。
判据与结局写死在 kmod/w1226_cut6_plan.md。

用法：python build_cut56.py            # 预览（0 接触）
      python build_cut56.py --apply    # 备份+上传+编译+拉回+无条件还原
"""'''
s = s[:a] + doc + s[b + 3:]

rep('BK_SEB = "/tmp/seb_exp6d_orig.c"', 'BK_SEB = "/tmp/seb_cut56_orig.c"')
rep('BK_SC = "/tmp/sucompat_exp6d_orig.c"', 'BK_SC = "/tmp/sucompat_cut56_orig.c"')
rep('LOG = "/home/lucy/exp6d_build.log"', 'LOG = "/home/lucy/cut56_build.log"')
rep('KO_HOME = "/home/lucy/kernelsu_exp6d.ko"', 'KO_HOME = "/home/lucy/kernelsu_cut56.ko"')
rep('LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_exp6d.ko"',
    'LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_cut56.ko"')
rep('data = api.read_bytes("kernelsu_exp6d.ko")', 'data = api.read_bytes("kernelsu_cut56.ko")')
rep('"EXP6D_KO_OK"', '"CUT56_KO_OK"')

rep('unsigned ksu_exp6_cut2_hits = 0;\n"""',
    'unsigned ksu_exp6_cut2_hits = 0;\nunsigned ksu_exp6_cut5_hits = 0;\nunsigned ksu_exp6_cut6_hits = 0;\n"""')

rep('sc2 = sc2.replace(CUT2_ANCHOR, CUT2_BLOCK + CUT2_ANCHOR, 1)\n', snippet + '\n')

rep("for need in ('ksu_exp6_cut1_hits', 'ksu_exp6_cut2_hits', 'KSUBEAT CUT1', 'KSUBEAT CUT2'):",
    "for need in ('ksu_exp6_cut1_hits', 'ksu_exp6_cut2_hits', 'KSUBEAT CUT1', 'KSUBEAT CUT2',\n"
    "             'ksu_exp6_cut5_hits', 'ksu_exp6_cut6_hits', 'KSUBEAT CUT5', 'KSUBEAT CUT6',\n"
    "             'ksu_cut56_read', 'proc_create'):")

rep('if not APPLY:\n    print("\\n==> 预览模式：未碰远端。确认 diff 后可加 --apply。")\n    sys.exit(0)',
    'if not APPLY:\n'
    '    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_cut56_seb.c", "w",\n'
    '         encoding="utf-8", newline="\\n").write(seb2)\n'
    '    open(r"G:/项目/Windows管理/usb/临时root/kmod/hermes_src/_preview_cut56_sucompat.c", "w",\n'
    '         encoding="utf-8", newline="\\n").write(sc2)\n'
    '    print("\\n==> 预览模式：未碰远端。已落 _preview_cut56_*.c；确认后可加 --apply。")\n'
    '    sys.exit(0)')

rep('rc = api.exec("cp -f %s %s && md5sum %s" % (KO_REMOTE, KO_RC80_BK, KO_RC80_BK), timeout=180)',
    'chk = api.exec("md5sum %s" % KO_REMOTE, timeout=120)\n'
    'got_ko = chk.stdout.split()[0] if chk.stdout.split() else ""\n'
    'print("==> 远端 kernelsu.ko 现状:", got_ko)\n'
    'if got_ko != "98bf405273e8652cdb7fffcc3fe42dc2":\n'
    '    raise SystemExit("!! 远端 kernelsu.ko 不是 rc80，拒绝（免得备份错件）")\n'
    'rc = api.exec("cp -f %s %s && md5sum %s" % (KO_REMOTE, KO_RC80_BK, KO_RC80_BK), timeout=180)')

open(BASE + "build_cut56.py", "w", encoding="utf-8", newline="\n").write(s)
print("生成 build_cut56.py，行数", len(s.splitlines()))
