#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc53：把 sucompat 里 **SU1(filp_open 完) → SU2(escape)** 之间那三段无脚印的路变成有脚印的，
并给其中最可疑的一段(`ksu_sulog_capture_sucompat`)加一个 insmod 期开关。md §6.95/§6.103。

为什么值得单独一条战线：第九十五发一手 `ksu_hook_mask=0x3` + app 跑 `su -c id` ⇒ **当场重启**，
而那次**没记下"最后一个回执是哪一条"** ⇒ 只知道"死在 sucompat 里"，不知道死在哪一句。
现在这段的代码形状(读自 /root/k/ksu/kernel/feature/sucompat.c)：
    SU1 before filp_open → filp_open(KSUD_PATH, O_PATH) → fd_install(tmp_fd, ksud_file);
    → pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL);
    → 改 regs(parm1..parm5，其中 parm2 = empty_user_path())
    → SU2 (escape_with_root_profile) → SU3 (nested execveat) → SU4
中间三段(fd_install / sulog 采集 / 改寄存器)一个脚印都没有，而三段各有独立的死法：
  · `GFP_KERNEL` 的采集在 syscall 入口上下文里睡/踩；
  · `empty_user_path()` 给的是不是**合法的 user 指针**(execveat 会对它 copy_from_user，
    给错就是内核地址被当用户地址读 ⇒ PAN ault ⇒ 静默复位，本机零现场)；
  · fd_install 之后 file 的所有权变化。
⇒ 本脚本只做两件事，都不改控制流(除了把采集包进开关)：
  ① SU1a/SU1b/SU1c/SU1d 四条脚印；② 新参数 `ksu_no_sulog`(默认 0=照旧采集)。
用法：python3 patch_ksu_sucompat_steps.py <KSU 源码根>     # 幂等(tag=KSUBEAT SU1a)
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/feature/sucompat.c"
TAG = "KSUBEAT SU1a"

A1 = "    fd_install(tmp_fd, ksud_file);\n"
N1 = ("    fd_install(tmp_fd, ksud_file);\n"
      "    pr_info(\"KSUBEAT SU1a fd_install 完: tmp_fd=%d ksud_file=%px\\n\", tmp_fd, (void *)ksud_file);\n")

A2 = ("    pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL);\n")
N2 = ("    if (ksu_no_sulog) {\n"
      "        pr_info(\"KSUBEAT SU1b 跳过 sulog 采集(ksu_no_sulog=1): argv=%px\\n\", (void *)argv_user);\n"
      "        pending_sucompat = NULL;\n"
      "    } else {\n"
      "        pr_info(\"KSUBEAT SU1b before sulog 采集: argv=%px filename=%lx\\n\", (void *)argv_user,\n"
      "                (unsigned long)*filename_user);\n"
      "        pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL);\n"
      "        pr_info(\"KSUBEAT SU1c after sulog 采集: pending=%px\\n\", (void *)pending_sucompat);\n"
      "    }\n")

A3 = "    regs->__PT_PARM2_REG = empty_user_path();\n"
N3 = ("    regs->__PT_PARM2_REG = empty_user_path();\n"
      "    pr_info(\"KSUBEAT SU1d 寄存器已改: parm1=%px parm2=%px parm3=%px parm4=%lx parm5=%lu\\n\",\n"
      "            (void *)orig_regs[0], (void *)regs->__PT_PARM2_REG, (void *)regs->__PT_PARM3_REG,\n"
      "            (unsigned long)regs->__PT_SYSCALL_PARM4_REG, (unsigned long)regs->__PT_PARM5_REG);\n")

PARA = ("/* rc53(md §6.103)：sucompat 里最可疑的一段(sulog 采集，用的是 GFP_KERNEL)单独一个开关，\n"
        " * 默认 0=照旧。判据：SU1b 印了而 SU1c 没印 ⇒ 死在采集里。 */\n"
        "bool ksu_no_sulog __read_mostly = false;\n"
        "module_param(ksu_no_sulog, bool, 0444);\n"
        "MODULE_PARM_DESC(ksu_no_sulog, \"sucompat: 跳过 ksu_sulog_capture_sucompat，只测改道+嵌套 execveat\");\n")


def main():
    s = io.open(F, encoding="utf-8").read()
    if TAG in s:
        print("  sucompat.c 已经有 SU1a 脚印(跳过)")
        return 0
    for i, (a, n) in enumerate(((A1, N1), (A2, N2), (A3, N3)), 1):
        if s.count(a) != 1:
            print("!! 锚点 %d 命中 %d 次(要正好 1 次)，不动文件" % (i, s.count(a)))
            return 1
        s = s.replace(a, n, 1)
    anchor = "bool ksu_no_escape __read_mostly = false;\n"
    if s.count(anchor) != 1:
        print("!! 参数锚点命中 %d 次，不动文件" % s.count(anchor))
        return 1
    s = s.replace(anchor, PARA + "\n" + anchor, 1)
    io.open(F, "w", encoding="utf-8", newline="\n").write(s)
    print("  sucompat.c 已插 SU1a/SU1b/SU1c/SU1d + ksu_no_sulog")
    for k in ("KSUBEAT SU1a", "KSUBEAT SU1b", "KSUBEAT SU1c", "KSUBEAT SU1d", "ksu_no_sulog"):
        print("   %-16s = %d" % (k, s.count(k)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
