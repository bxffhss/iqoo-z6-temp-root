#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
社区化(2026-11-09)：在真实的远端基线 /root/k/ksu/kernel/infra/dev_syms.c 上
**只**补回 stock KSU 的 /dev/ksud 字符设备（misc_register），使标准 su 二进制 /
官方 Manager 能 open("/dev/ksud") + ioctl(GRANT_ROOT) 提权。

本脚本刻意只做「增量插入」，绝不删除任何既存代码（尤其是 rc74c 的
ksu_mgr_birth_fd 出生装 fd 子系统与 files==NULL 护栏）。所有插入点都用
内容匹配 + 断言保护：锚点找不到或已应用都会直接抛错，避免悄悄损坏文件。

插入点：
  1) #include <linux/proc_fs.h> 之后插入 #include <linux/miscdevice.h>
  2) int ksu_dev_syms_init(void) 之前插入字符设备脚手架（extern + fops + ksu_misc）
  3) pr_info("KSUSTEP 0 enter: ...") 之后插入 misc_register(&ksu_misc) 调用
"""
import os
import sys

PATH = "/root/k/ksu/kernel/infra/dev_syms.c"
BAK = PATH + ".ksud_bak"

def main():
    if not os.path.exists(PATH):
        sys.exit("FATAL: baseline not found: " + PATH)

    # 备份一次（仅当尚未备份）
    if not os.path.exists(BAK):
        os.system("cp -p '%s' '%s'" % (PATH, BAK))
        print("BACKUP -> " + BAK)

    with open(PATH, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # ---------- 防御：本脚本幂等，重复运行应被断言拦下 ----------
    if any("linux/miscdevice.h" in ln for ln in lines):
        sys.exit("GUARD: miscdevice.h already present -> already applied? abort.")
    if any("ksu_chr_ioctl" in ln for ln in lines):
        sys.exit("GUARD: ksu_chr_ioctl already present -> already applied? abort.")
    if any("misc_register(&ksu_misc)" in ln for ln in lines):
        sys.exit("GUARD: misc_register already present -> already applied? abort.")

    # ---------- 编辑 1：miscdevice.h include ----------
    proc_idx = None
    for i, ln in enumerate(lines):
        if ln.startswith("#include <linux/proc_fs.h>"):
            proc_idx = i
            break
    if proc_idx is None:
        sys.exit("FATAL: anchor '#include <linux/proc_fs.h>' not found")
    inc = ('#include <linux/miscdevice.h> /* 社区化：/dev/ksud 字符设备'
           '（stock KSU 的 su 入口） */\n')
    lines.insert(proc_idx + 1, inc)

    # ---------- 编辑 2：字符设备脚手架（在 init 函数之前） ----------
    init_idx = None
    for i, ln in enumerate(lines):
        if ln.startswith("int ksu_dev_syms_init(void)"):
            init_idx = i
            break
    if init_idx is None:
        sys.exit("FATAL: anchor 'int ksu_dev_syms_init(void)' not found")
    plumb = (
        "/* ===== 0a) /dev/ksud 字符设备（社区化 su 模型，2026-11-09）=====\n"
        " * rc 谱系原本只靠内核注入 fd 暴露 su 授权（仅 Manager/漏洞 bootstrap 启动的 app 才有 fd），\n"
        " * 从不注册 /dev/ksud 字符设备 => 标准 su 二进制 / 官方 Manager 直接 open(\"/dev/ksud\") 只会命中\n"
        " * 交付埋进去的 sustatic 普通文件而 ENOTTY（grant_test 实测 errno=25）。这里补回 stock KSU 的\n"
        " * misc 设备：任意白名单进程 open(\"/dev/ksud\") + ioctl(GRANT_ROOT) 即可提权，门仍是\n"
        " * allowed_for_su（纯白名单、无 su-session 要求），与官方 KSU 行为一致。\n"
        " * fops.unlocked_ioctl 直接接到已有的全局符号 ksu_supercall_handle_ioctl（supercall/dispatch.c:876）；\n"
        " *   GRANT_ROOT 那一条的 perm_check 就是 allowed_for_su，授权逻辑一行未改。\n"
        " * 设备 mode=0666：任意 app 都能 open；授权门是 allowlist 不是文件权限（非白名单 ioctl 仍 -EPERM）。 */\n"
        "extern long ksu_supercall_handle_ioctl(const struct file *filp, unsigned int cmd, void __user *argp);\n"
        "\n"
        "static long ksu_chr_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)\n"
        "{\n"
        "\t/* 内核 misc 设备的 ioctl 第三参是 unsigned long（用户指针），与\n"
        "\t * ksu_supercall_handle_ioctl 期望的 void __user * 等价。 */\n"
        "\treturn ksu_supercall_handle_ioctl(filp, cmd, (void __user *)arg);\n"
        "}\n"
        "\n"
        "static const struct file_operations ksu_chr_fops = {\n"
        "\t.owner = THIS_MODULE,\n"
        "\t.unlocked_ioctl = ksu_chr_ioctl,\n"
        "#ifdef CONFIG_COMPAT\n"
        "\t.compat_ioctl = ksu_chr_ioctl,\n"
        "#endif\n"
        "};\n"
        "\n"
        "static struct miscdevice ksu_misc = {\n"
        "\t.minor = MISC_DYNAMIC_MINOR,\n"
        "\t.name = \"ksud\",\n"
        "\t.mode = 0666,\n"
        "\t.fops = &ksu_chr_fops,\n"
        "};\n"
        "\n"
    )
    lines.insert(init_idx, plumb)

    # ---------- 编辑 3：misc_register 调用（在 KSUSTEP 0 enter 之后） ----------
    ksustep_idx = None
    for i, ln in enumerate(lines):
        if "KSUSTEP 0 enter" in ln:
            ksustep_idx = i
            break
    if ksustep_idx is None:
        sys.exit("FATAL: anchor 'KSUSTEP 0 enter' not found")
    reg = (
        "\t/* ★社区化：注册 /dev/ksud 字符设备（stock KSU 的 su 入口）。失败只告警，不拒绝加载。 */\n"
        "\t{\n"
        "\t\tint mr = misc_register(&ksu_misc);\n"
        "\t\tif (mr)\n"
        "\t\t\tpr_err(\"KSUDEV: misc_register(ksud) failed=%d\\n\", mr);\n"
        "\t\telse\n"
        "\t\t\tpr_info(\"KSUDEV: /dev/ksud char device registered (minor=%d)\\n\", ksu_misc.minor);\n"
        "\t}\n"
        "\n"
    )
    lines.insert(ksustep_idx + 1, reg)

    with open(PATH, "w", encoding="utf-8") as f:
        f.writelines(lines)

    print("EDITS_APPLIED ok")
    print("total_lines=%d" % len(lines))
    print("has_miscdevice=%s" % any("miscdevice.h" in ln for ln in lines))
    print("has_chr_ioctl=%s" % any("ksu_chr_ioctl" in ln for ln in lines))
    print("has_misc_register=%s" % any("misc_register(&ksu_misc)" in ln for ln in lines))
    # 关键回归保护：出生装 fd 子系统必须还在
    print("has_birth_fd=%s" % any("ksu_mgr_birth_fd" in ln for ln in lines))
    print("has_files_null_guard=%s" % any("target has no files" in ln for ln in lines))

if __name__ == "__main__":
    main()
