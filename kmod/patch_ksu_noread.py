#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# patch_ksu_noread.py —— rc72 那一刀：让 ko **根本不打开、不读**那份 allowlist。
#   为什么要有它(§6.281 / 任务 #109)：第 130 发(rc71 firstonly)已经把"循环走第二圈"摘掉却照死，
#     而 firstonly 下 ko 的动作(开文件→读 magic/version→读第 1 条 784 B→挂 hash→break)
#     与"健康的 792 字节单条目文件"逐字节相同 ⇒ 数据侧再夹不动，只能把"开+读"这一整层拿掉。
#   判据(开枪前写死)：活过 +30 分钟 ⇒ 死在我们对这份文件的**访问动作**上(外部按访问触发的监控)；
#     仍在 +16~30 秒 ⇒ 与我们做什么都无关——"磁盘那份两条记录 + ko 被加载"就是全部致死条件。
#   ★正对照为什么打在 syscall_hook.c：§6.280 实测 `dmesg.live` 会把装载期那**一整段**一次性打印吃掉
#     (127/130 连 `KSUBEAT L5`/`allowlist version` 都没有)，而 `KSUBEAT BN dispatcher entered` 那一族
#     在同样两份文件里被抓住 397/396 次 ⇒ 参数现值必须跟着这条**每 syscall 都打**的行走。
# 用法：
#   python3 patch_ksu_noread.py <allowlist.c> <syscall_hook.c>
#   python3 patch_ksu_noread.py --selftest <allowlist.c(rc67 状态)> <syscall_hook.c>
import hashlib
import io
import os
import subprocess
import sys
import tempfile

MARK = "RC72 SKIPREAD"
ALLOW_MD5_RC67 = "3c479222cc94106c990a9e9a06a83794"
HOOK_MD5_BASE = "f30801f0bb30687d365bb77b487c42fd"

A_ALLOW = "#include <linux/kref.h>\n"
R_ALLOW = "#include <linux/kref.h>\n#include <linux/moduleparam.h> /* " + MARK + " */\n"

B_ALLOW = "#define FILE_FORMAT_VERSION 4 // u32\n"
R_BALLOW = (
    "#define FILE_FORMAT_VERSION 4 // u32\n"
    "\n"
    "bool ksu_no_allowlist_read = false;\n"
    "module_param(ksu_no_allowlist_read, bool, 0);\n"
    "MODULE_PARM_DESC(ksu_no_allowlist_read, \"" + MARK + ": do not filp_open/kernel_read the allowlist at all\");\n"
)

D_ALLOW = (
    "void ksu_load_allow_list()\n"
    "{\n"
    "#ifdef CONFIG_KSU_DISABLE_POLICY\n"
    "    pr_info(\"allowlist load skipped because policy is disabled\\n\");\n"
    "    return;\n"
    "#endif\n"
)
R_DALLOW = D_ALLOW + (
    "\n"
    "    if (ksu_no_allowlist_read) {\n"
    "        pr_info(\"" + MARK + ": 这份 allowlist **没被打开也没被读**(flag=%d)\\n\", ksu_no_allowlist_read);\n"
    "        ksu_show_allow_list();\n"
    "        return;\n"
    "    }\n"
)

E_HOOK = (
    "    pr_info(\"KSUBEAT BN dispatcher entered: syscallno=%d stash=%d pid=%d comm=%s\\n\",\n"
    "                        regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid,\n"
    "                        current->comm);\n"
)
R_EHOOK = (
    "    extern bool ksu_no_allowlist_read; /* " + MARK + ": 参数现值打进这条高频行(§6.280：装载期一次性打印会被通道整段吃掉) */\n"
    "    pr_info(\"KSUBEAT BN dispatcher entered: syscallno=%d stash=%d pid=%d comm=%s r72=%d\\n\",\n"
    "                        regs->syscallno, (int)PT_REGS_ORIG_SYSCALL(regs), current->pid,\n"
    "                        current->comm, ksu_no_allowlist_read);\n"
)

# (文件角色, 锚点, 替换, 该文件打完后的标记数)
PAIRS = [
    ("allow-A-include", A_ALLOW, R_ALLOW, None),
    ("allow-B-param", B_ALLOW, R_BALLOW, None),
    ("allow-D-guard", D_ALLOW, R_DALLOW, None),
]
HOOK_PAIRS = [("hook-E-stamp", E_HOOK, R_EHOOK, None)]

ALLOW_MARKS_AFTER = 3
HOOK_MARKS_AFTER = 1


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def load(p):
    return io.open(p, encoding="utf-8", newline="").read()


def save(p, s):
    io.open(p, "w", encoding="utf-8", newline="").write(s)


def sub(text, name, anchor, repl):
    n = text.count(anchor)
    if n != 1:
        raise SystemExit("[x] 锚点 %s 命中 %d 次(必须 1) ⇒ 停手，别硬编" % (name, n))
    return text.replace(anchor, repl, 1)


def patch_allow(s):
    if "RC71 LOADFIRST" in s:
        raise SystemExit("[x] 这份 allowlist.c 带着 **RC71 LOADFIRST**(循环只跑一圈)的补丁 ⇒ rc72 要求 rc67 底，先把它还原成 md5 " + ALLOW_MD5_RC67 + " 再打")
    for name, a, r, _ in PAIRS:
        s = sub(s, name, a, r)
    return s


def patch_hook(s):
    for name, a, r, _ in HOOK_PAIRS:
        s = sub(s, name, a, r)
    return s


def apply_pair(ap, hp):
    a_src, h_src = load(ap), load(hp)
    # ★先验底，再谈幂等：否则一份"RC71+RC72 都打过"的 allowlist 会被幂等分支悄悄放行，
    #   而那一发就不再是单变量了(§6.281 要的底是 rc67)。
    if "RC71 LOADFIRST" in a_src:
        raise SystemExit("[x] 这份 allowlist.c 带着 **RC71 LOADFIRST** ⇒ rc72 要求 rc67 底，先还原成 md5 " + ALLOW_MD5_RC67)
    am, hm = md5(a_src), md5(h_src)
    ac, hc = a_src.count(MARK), h_src.count(MARK)
    if ac == ALLOW_MARKS_AFTER and hc == HOOK_MARKS_AFTER:
        print("两个文件都已打过(标记 %d/%d) ⇒ 幂等跳过；md5 不变 %s / %s" % (ac, hc, am, hm))
        return am, am, hm, hm
    if ac or hc:
        raise SystemExit("[x] 半打：标记数 allow=%d hook=%d(应 0/0 或 %d/%d) ⇒ 停手别接着编"
                         % (ac, hc, ALLOW_MARKS_AFTER, HOOK_MARKS_AFTER))
    a_out, h_out = patch_allow(a_src), patch_hook(h_src)
    if a_out.count(MARK) != ALLOW_MARKS_AFTER or h_out.count(MARK) != HOOK_MARKS_AFTER:
        raise SystemExit("[x] 打完标记数不对 allow=%d hook=%d ⇒ 这一份不可信，停"
                         % (a_out.count(MARK), h_out.count(MARK)))
    if "ksu_load_first_only" in a_out:
        raise SystemExit("[x] 打完还看见 ksu_load_first_only ⇒ 底不是 rc67")
    save(ap, a_out)
    save(hp, h_out)
    am2, hm2 = md5(a_out), md5(h_out)
    print("打完了：allow %s -> %s (%d 字节)  hook %s -> %s (%d 字节)"
          % (am, am2, len(a_out.encode("utf-8")), hm, hm2, len(h_out.encode("utf-8"))))
    return am, am2, hm, hm2


def run(files):
    r = subprocess.run([sys.executable, __file__] + files, capture_output=True)
    return r.returncode, (r.stdout + r.stderr).decode("utf-8", "replace")


def selftest(ref_allow, ref_hook):
    base_a, base_h = load(ref_allow), load(ref_hook)
    if md5(base_a) != ALLOW_MD5_RC67:
        raise SystemExit("[x] 参照 allowlist.c md5=%s != rc67 的 %s ⇒ 拿错底了" % (md5(base_a), ALLOW_MD5_RC67))
    if md5(base_h) != HOOK_MD5_BASE:
        raise SystemExit("[x] 参照 syscall_hook.c md5=%s != 记下的 %s ⇒ 底不对就别预测 md5" % (md5(base_h), HOOK_MD5_BASE))
    tmp = []
    try:
        pa, ph = pair(tmp, base_a, base_h)
        a0, a1, h0, h1 = apply_pair(pa, ph)
        assert a1 != a0 and h1 != h0, "[x] 第一遍没改 ⇒ 作废(例 88)"
        print("  [1] 证明动了：allow %s->%s  hook %s->%s ✓" % (a0[:8], a1[:8], h0[:8], h1[:8]))
        _a, a2, _h, h2 = apply_pair(pa, ph)
        assert a2 == a1 and h2 == h1, "[x] 第二遍改了东西 ⇒ 不幂等(例 72)"
        print("  [2] 幂等：再跑一遍两个 md5 都不变 ✓")
        ca, ch = load(pa), load(ph)
        assert ca.count("if (ksu_no_allowlist_read) {") == 1, "[x] 闸不止一处"
        assert ch.count("r72=%d") == 1, "[x] 高频行的 r72 不止一处"
        assert "module_param(ksu_no_allowlist_read, bool, 0);" in ca, "[x] module_param 没进去"
        assert ca.count("#endif\n\n    if (ksu_no_allowlist_read) {") == 1, "[x] 闸没落在 #endif 之后"
        print("  [3] 末行唯一：闸 1 处(在 #endif 之后) / r72 1 处 / module_param 在 ✓")
        # [4] 锚点被挪走 ⇒ 必须**因为锚点**失败(不许因为别的原因红)
        bad_h = base_h.replace("                        current->comm);\n", "                        current->comm /* x */);\n", 1)
        if bad_h == base_h:
            raise SystemExit("[x] 变异没生效(hook 锚点不在 base 里) ⇒ 这一格等于没测")
        x1, x2 = pair(tmp, base_a, bad_h)
        rc, msg = run([x1, x2])
        assert rc != 0 and "锚点 hook-E-stamp" in msg, "[x] hook 锚点没了没被这个闸抓住：rc=%d msg=%s" % (rc, msg[-120:])
        print("  [4] 拒绝坏输入(hook 锚点被挪走)：退出码=%d 且报的是锚点 ✓" % rc)
        # [4b] 半打：allow 打了、hook 没打
        y1, y2 = pair(tmp, patch_allow(base_a), base_h)
        rc2, msg2 = run([y1, y2])
        assert rc2 != 0 and "半打" in msg2, "[x] 半打被放行：rc=%d" % rc2
        print("  [4b] 半打(allow 打、hook 没打)必须被拒：退出码=%d ✓" % rc2)
        # [4c] 错底：allowlist 带 RC71 LOADFIRST(且两块标记齐全 ⇒ 幂等分支会放行，所以底验必须在幂等之前)
        z1, z2 = pair(tmp, patch_allow(base_a).replace("/* " + MARK + " */\n", "/* " + MARK + " */\n/* RC71 LOADFIRST */\n", 1), patch_hook(base_h))
        rc3, msg3 = run([z1, z2])
        assert rc3 != 0 and "RC71 LOADFIRST" in msg3, "[x] 带 RC71 的底被幂等分支放行：rc=%d msg=%s" % (rc3, msg3[-120:])
        print("  [4c] 拒错底(RC71+RC72 都在，标记数刚好 3/1)：退出码=%d ✓" % rc3)
        print("SELFTEST 全过；预测 md5：allow=%s hook=%s" % (a1, h1))
    finally:
        for p in tmp:
            try:
                os.unlink(p)
            except OSError:
                pass


def pair(tmp, a_text, h_text):
    fd, pa = tempfile.mkstemp(suffix=".c"); os.close(fd); tmp.append(pa)
    fd, ph = tempfile.mkstemp(suffix=".c"); os.close(fd); tmp.append(ph)
    save(pa, a_text); save(ph, h_text)
    return pa, ph


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest(sys.argv[2], sys.argv[3])
    else:
        apply_pair(sys.argv[1], sys.argv[2])
