#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc55：把 sucompat 的 ksud 路径变成 **insmod 期参数** `ksu_ksud_path`（md §6.109）。

为什么要动它：`/data/adb/ksud` 在 /data 上 ⇒ **跨重启还在**，所以 stage 收尾必须 `rm -rf /data/adb/ksud`；
代价是"stage 一收尾，`su` 就没得用了"（第一百零八发之前吃过一次：晚期复跑只剩 ENOENT，
差点被我读成钩子失效）。tmpfs 里的文件重启自动没有，天然合"临时 root 不持久化"的规矩；
本机 `/dev` 是 `tmpfs rw,nosuid,relatime,mode=755` —— **没有 noexec**（nosuid 只影响 setuid 位，
而我们的 uid 是内核给的，不靠 setuid），`/mnt`、`/linkerconfig` 都是 noexec 不能用。

判据（下一发跑）：
  · 早段(和第一百零八发同一形状)：`/dev/ksud` 能被改道并 `execveat` 成功 ⇒ 换路径没把通道弄坏；
  · 晚段(等 stage 打完 `=== 结束 ===` 之后)：`su` 还能出 `uid=0(root)` ⇒ 这一格真正要的东西。
  · 若晚段失败而早段成功 ⇒ 说明 /dev 上 exec 被别的关卡拦了(SELabel/`execute` 权限)，
    参数默认值仍是 `/data/adb/ksud`，改回来零成本。

只动 `feature/sucompat.c` 一个文件，三处引用（kern_path + 两个 filp_open）。
用法：python3 patch_ksu_ksudpath.py <KSU 源码根>     # 幂等(tag=ksu_ksud_path)
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/feature/sucompat.c"
TAG = "ksu_ksud_path"

PARAM = """/* rc55(md §6.109)：ksud 的路径做成 insmod 期参数，默认保持老行为(/data/adb/ksud)。
 * 放 tmpfs(如 /dev/ksud)的好处是"重启自动没有"，于是 stage 不必为了不留痕而删它 ——
 * 而现在一删，`su` 就在窗口后段失效了(第一百零八发前实测)。
 * ★参数是 insmod 时复制进缓冲区的(module_param_string)，运行时写不进去(sysfs 早被我们自己摘了)，
 *   所以换路径 = 改 /data/local/tmp/ksu_args.txt 再打一发，不用重编。 */
static char ksu_ksud_path[64] = KSUD_PATH;
module_param_string(ksu_ksud_path, ksu_ksud_path, sizeof(ksu_ksud_path), 0444);
MODULE_PARM_DESC(ksu_ksud_path, "sucompat 改道后要 exec 的那个文件(默认 " KSUD_PATH ")");

"""

SITE_K = "    if (kern_path(KSUD_PATH, 0, &path) < 0) {\n"
SITE_F = "        ksud_file = filp_open(KSUD_PATH, O_PATH, 0);\n"


def main():
    s = io.open(F, encoding="utf-8").read()
    if TAG in s:
        print("  sucompat.c 已经有 ksu_ksud_path(跳过)")
        return 0
    n = s.count(SITE_F)
    if s.count(SITE_K) != 1 or n != 2:
        print("!! 锚点对不上：kern_path=%d filp_open=%d(要 1 和 2)，不动文件" % (s.count(SITE_K), n))
        return 1
    s = s.replace(SITE_K, SITE_K.replace("KSUD_PATH", "ksu_ksud_path"), 1)
    s = s.replace(SITE_F, SITE_F.replace("KSUD_PATH", "ksu_ksud_path"), n)
    anchor = "static const char su_path[] = SU_PATH;\n"
    if s.count(anchor) != 1:
        print("!! 参数锚点(su_path 那行)命中 %d 次，不动文件" % s.count(anchor))
        return 1
    s = s.replace(anchor, anchor + PARAM, 1)
    io.open(F, "w", encoding="utf-8", newline="\n").write(s)
    print("  sucompat.c 已换成 ksu_ksud_path：校验 %s" %
          " ".join("%s=%d" % (k, s.count(k)) for k in ("ksu_ksud_path", "kern_path(ksu_ksud_path",
                                                        "filp_open(ksu_ksud_path")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
