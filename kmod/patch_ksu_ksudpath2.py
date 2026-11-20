#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc56：让"探测伪装"和"改道目标"用**同一个**路径（md §6.116）。

用户一手症状：给别的 app 授权之后，在 Termux 里敲 `su` 报"设备上没找到 su"。两半原因：
 ① 我们只挂了 execve 那一位(`ksu_hook_mask=0x2`)，而 Termux/Shizuku 是**先探测再执行**
   (`access()`/`stat()` 按 PATH 找命令) ⇒ 探测拿到 ENOENT 就放弃，连 execve 都不发。
   内核里那半个功能是现成的(`ksu_handle_faccessat_sucompat`/`ksu_handle_stat_sucompat`，hook 位 3/4)，
   只是没开 ⇒ 这是**参数**问题(改 `kmod/ksu_args.txt` 成 0x1A)。
 ② 但就算开了位，`ksud_user_path()` 里写死的是编译期常量 `KSUD_PATH`(=/data/adb/ksud)，
   而 rc55 起真正被 exec 的文件由 insmod 参数 `ksu_ksud_path` 决定(实测放 tmpfs `/dev/ksud`，§6.109)。
   stage 收尾会 `rm -rf /data/adb/ksud` ⇒ **窗口后段**探测又变 ENOENT，而 execve 改道还活着
   ⇒ 症状长成"su 有时说没找到、有时能用"。
⇒ 本脚本把探测伪装的指向改成同一个参数。判据：开了位 3/4 之后 `@suprobe:` 那一发里
   `access(/system/bin/su,X_OK)=0`、`stat` 的 size 应当等于 `/dev/ksud` 的大小(≈2.2MB)，
   并且 `execvp("su")`(走 PATH，与 Termux 同形)的孩子印出 `uid=0(root)`。

★两处自己踩过的坑(都写成自愈)：
 - 内核没有 `<string.h>`：补它会 `fatal error: 'string.h' file not found`(strlen 由别的头带进来)。
 - `ksu_ksud_path` 的定义在 `ksud_user_path()` **下面** ⇒ `use of undeclared identifier`
   ⇒ 要把参数块整体挪到文件里那两个函数之前。
用法：python3 patch_ksu_ksudpath2.py <KSU 源码根>     # 幂等
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
SC = M + "/feature/sucompat.c"

OLD_FN = """static char __user *ksud_user_path(void)
{
    static const char ksud_path[] = KSUD_PATH;

    return userspace_stack_buffer(ksud_path, sizeof(ksud_path));
}
"""
NEW_FN = """static char __user *ksud_user_path(void)
{
    /* rc56(md §6.116)：原来写死编译期 KSUD_PATH，但 rc55 起真正被 exec 的文件是参数
     * `ksu_ksud_path`(实测指到 tmpfs 的 /dev/ksud)。探测伪装必须跟改道目标一致，
     * 否则 stage 收尾 rm 掉 /data/adb/ksud 之后 access(/system/bin/su) 又变 ENOENT，
     * 而 execve 改道还活着 ⇒ 用户看到"授权了但 app 说没找到 su"。 */
    return userspace_stack_buffer(ksu_ksud_path, strlen(ksu_ksud_path) + 1);
}
"""
PARAM_HEAD = "static char ksu_ksud_path[64] = KSUD_PATH;"
# 参数块要挪到它前面(这个函数是文件里第一个用到它的)
MOVE_BEFORE = "static void __user *userspace_stack_buffer(const void *d, size_t len)"


def main():
    s = io.open(SC, encoding="utf-8").read()
    changed = False

    # ① 自愈：摘掉误加的 <string.h>(内核没有这个头)
    bad = "#include <linux/compiler_types.h>\n#include <string.h>\n"
    if bad in s:
        s = s.replace(bad, "#include <linux/compiler_types.h>\n", 1)
        changed = True
        print("  ok 摘掉误加的 <string.h>")

    # ② 函数体改成用参数
    if "userspace_stack_buffer(ksu_ksud_path" not in s:
        if s.count(OLD_FN) != 1:
            print("!! ksud_user_path 锚点命中 %d 次(要正好 1) ⇒ 不改" % s.count(OLD_FN))
            return 1
        s = s.replace(OLD_FN, NEW_FN, 1)
        changed = True
        print("  ok ksud_user_path 改用 ksu_ksud_path")

    # ③ 参数块挪到使用点之前(否则 undeclared identifier)
    lines = s.split("\n")
    try:
        ip = next(i for i, l in enumerate(lines) if l.startswith(PARAM_HEAD))
        it = next(i for i, l in enumerate(lines) if l.startswith(MOVE_BEFORE))
    except StopIteration:
        print("!! 找不到参数块或插入点 ⇒ 停(参数块文案变了？)")
        return 1
    if ip > it:
        blk = lines[ip:ip + 3]
        del lines[ip:ip + 3]
        it = next(i for i, l in enumerate(lines) if l.startswith(MOVE_BEFORE))
        lines[it:it] = blk + [""]
        s = "\n".join(lines)
        changed = True
        print("  ok 参数块 ksu_ksud_path 已挪到 userspace_stack_buffer 之前")

    if changed:
        io.open(SC, "w", encoding="utf-8", newline="\n").write(s)
    else:
        print("  已是 rc56(无改动)")
    s2 = io.open(SC, encoding="utf-8").read()
    ip = s2.find(PARAM_HEAD)
    it = s2.find("static char __user *ksud_user_path(void)")
    print("  校验 strlen=%d 误含<string.h>=%d(期望0) 参数块在使用点之前=%s"
          % (s2.count("strlen(ksu_ksud_path)"), s2.count("<string.h>"), ip < it))
    return 0 if (ip < it and s2.count("strlen(ksu_ksud_path)") == 1) else 1


if __name__ == "__main__":
    sys.exit(main())
