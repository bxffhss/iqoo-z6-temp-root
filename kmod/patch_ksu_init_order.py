#!/usr/bin/env python3
# 把 ksu_dev_syms_init() 从 late-load 分支里搬到 ksu_init() 最前面。
# 为什么(一手): core/init.c 里顺序是
#   ksu_cred = prepare_creds(); ksu_init_symbol_resolver(); ksu_syscall_hook_init();
#   ksu_feature_init(); ... ksu_supercalls_init(); ksu_app_profile_init();
#   if (ksu_late_loaded) { ksu_dev_syms_init(); apply_kernelsu_rules(); cache_sid(); setup_ksu_cred(); }
# ⇒ 上一发我们把注入点选在 apply_kernelsu_rules() 之前, 但那已经在**所有 init 之后**了:
#   KSU 自己的 symbol resolver 早在那之前就用 kallsyms_lookup_name ⇒ 拿到 0 ⇒ -ENOENT。
# 锚点全部唯一 + 幂等, 可回滚: git -C /root/k/ksu checkout -- kernel/core/init.c
import re, sys

P = "/root/k/ksu/kernel/core/init.c"
s = open(P, encoding="utf-8", errors="replace").read()
OLD = "\tksu_dev_syms_init();   /* 未导出符号必须先解析(md §6.11) */\n"
NEW_HEAD = "\tksu_dev_syms_init();   /* ★必须在最前面: KSU 自己的 resolver 会用到未导出符号(md §6.23) */\n"

changed = []
# 1) 去掉 late-load 分支里那一处(只去掉我们注入的那行原文, 别的不动)
if OLD in s:
    s = s.replace(OLD, "", 1)
    changed.append("移除 late-load 分支里的调用")
# 2) 插到 `ksu_cred = prepare_creds();` 之前(唯一锚点)
m = re.search(r"^[ \t]*ksu_cred = prepare_creds\(\);", s, re.M)
if m is None:
    print("!! 找不到 prepare_creds 锚点, 不动")
    sys.exit(1)
if "必须在最前面" in s:
    print("已挪过, 跳过")
else:
    line_start = s.rfind("\n", 0, m.start()) + 1
    indent = s[line_start:m.start()][: len(s[line_start:m.start()]) - len(s[line_start:m.start()].lstrip())]
    s = s[:line_start] + indent + "ksu_dev_syms_init();   /* ★必须在最前面: KSU 自己的 resolver 会用到未导出符号(md §6.23) */\n" + s[line_start:]
    changed.append("在 prepare_creds 之前插入调用")

if changed:
    open(P, "w", encoding="utf-8", newline="\n").write(s)
print("; ".join(changed) or "无变化")
print("=== 校验: 文件里现在只有一处调用, 且在 prepare_creds 之前 ===")
for i, l in enumerate(open(P, encoding="utf-8", errors="replace"), 1):
    if "ksu_dev_syms_init" in l or "prepare_creds" in l or "ksu_init_symbol_resolver" in l:
        print(f"{i}: {l.rstrip()}")
