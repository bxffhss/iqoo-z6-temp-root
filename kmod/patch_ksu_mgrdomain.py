#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc64(#81)：给 `default_root_profile` 的 SELinux 域开一个**运行期**覆盖口(配合 dev_syms.c 的 /proc/ksu_mgrdomain)。

为什么要它(§6.168/#64 的账)：`allowlist.c` 取 profile 时 `is_uid_manager(uid) ⇒ goto use_default`
⇒ **给王座(Manager)写 SET_APP_PROFILE 永远不生效**，它只能吃 `default_root_profile`；
而那里的域是 `KSU_DEFAULT_SELINUX_DOMAIN = "u:r:" KERNEL_SU_DOMAIN ":s0"`，这个域在本机策略里**不存在**，
`setup_selinux()` 对不存在的域是「保持起点域」(#53 一手) ⇒ 官方 Manager 的 root 服务起来后域还是
`u:r:untrusted_app` ⇒ 官方 UI 只剩这一格没通(§6.168 的读数)。

★默认零影响：不调这个口，`default_root_profile.selinux_domain` 与 rc63 逐字相同。
★为什么不用 module_param：`core/init.c` 的 `kobject_del(&THIS_MODULE->mkobj.kobj)` 把
  `/sys/module/kernelsu/` 整个摘走 ⇒ 运行时没有参数写口(§6.178⑤)，只能自己开 proc 口。
判据(同一发窗口，单变量)：`echo ? > /proc/ksu_mgrdomain` 看起点域 → 设成 `u:r:shell:s0` →
官方 Manager 重连一次 su(它的 root 任务是**新** fork+exec 的，才会吃到新域) → 读该任务 `/proc/<pid>/attr/current`
应当是 `u:r:shell:s0`；再 `echo ?` 复位 ⇒ 第三次起的 root 任务回到 `untrusted_app`。
幂等 tag：MGRDOMAIN。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/policy/allowlist.c"

BLOCK = (
    "\n"
    "/* rc64(#81, md 6.182)：王座(Manager)只能吃 default_root_profile(上面 is_uid_manager 那条短路)，\n"
    " * 所以这里开一个运行期覆盖口给 dev_syms.c 的 /proc/ksu_mgrdomain 用。\n"
    " * 默认什么都不做；MGRDOMAIN 只改**这一个**字段，不碰 uid/gid/cap/namespaces。 */\n"
    "void ksu_set_mgr_domain(const char *d)\n"
    "{\n"
    "\tif (!d || !d[0]) {\n"
    "\t\tstrscpy(default_root_profile.selinux_domain, KSU_DEFAULT_SELINUX_DOMAIN,\n"
    "\t\t\tsizeof(default_root_profile.selinux_domain));\n"
    "\t\tpr_info(\"MGRDOMAIN 复位: 王座默认域=[%s]\\n\", default_root_profile.selinux_domain);\n"
    "\t\treturn;\n"
    "\t}\n"
    "\tstrscpy(default_root_profile.selinux_domain, d,\n"
    "\t\tsizeof(default_root_profile.selinux_domain));\n"
    "\tpr_info(\"MGRDOMAIN 王座默认域改: [%s]\\n\", default_root_profile.selinux_domain);\n"
    "}\n"
    "\n"
    "const char *ksu_get_mgr_domain(void)\n"
    "{\n"
    "\treturn default_root_profile.selinux_domain;\n"
    "}\n"
)

ANCHOR = "    default_root_profile.flags = 0;\n}\n"

s = io.open(F, encoding="utf-8", errors="replace").read()
if "ksu_set_mgr_domain" in s:
    print("  = 已有 MGRDOMAIN ⇒ 跳过(幂等)")
elif s.count(ANCHOR) != 1:
    print("  !! 锚点命中 %d 次 ⇒ 不动" % s.count(ANCHOR))
    raise SystemExit(1)
else:
    s = s.replace(ANCHOR, ANCHOR + BLOCK, 1)
    io.open(F, "w", encoding="utf-8", newline="\n").write(s)
    print("  + MGRDOMAIN(allowlist.c)")

t = io.open(F, encoding="utf-8", errors="replace").read()
for pat in ("void ksu_set_mgr_domain(const char *d)", "const char *ksu_get_mgr_domain(void)",
            "MGRDOMAIN 复位", "MGRDOMAIN 王座默认域改",
            "sizeof(default_root_profile.selinux_domain)"):
    print("  %-46s 命中 %d" % (pat, t.count(pat)))
