#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc63(#78)：把 profile 发来的 cap 掩码**夹进内核自己认为合法的满集**再写进 cred。

一手事实(md §6.172)：同一发窗口里三个 uid=0 的上下文跑同一个探针 ——
  agent root / suw `@su:`(cap_eff=`0x0000003fffffffff`)：vr 那 22 条**一条都不拦**；
  Termux 手敲 `su`(cap_eff/prm/bnd=`0xffffffffffffffff`，域 shell)：**11 条全 EPERM**。
这台机 `CAP_LAST_CAP=CAP_AUDIT_READ=37` ⇒ 内核配得出的满集就是 `0x3fffffffff`，
而 `~0`(bit38..63 也全 1)这种形状**只有"绕过 cap_valid 直接 memcpy"才可能出现在 cred 上**。
来源就在我们自己的代码里：`cm57/ksuctl.c:95` 与 suw 的 JNI 都写 `~(uint64_t)0`，
`policy/app_profile.c` 的 escape 路径再把这份 `capabilities.effective` **整块 memcpy**
进 cap_effective/permitted/bset/inheritable/ambient ⇒ 高位脏位原样进 cred。

这一版只改**我们自己发的 cred 形状**，不碰任何厂商桩：
  ksu_capclamp=1(默认) ⇒ 每份 cap 与 `CAP_FULL_SET` 逐字与；
  ksu_capclamp=0       ⇒ 与 rc62 行为完全一致(=同一发窗口里的负对照开关)。
权限给 0644(邻居们是 0444)，就是为了能在活窗口里 root 侧翻着打单变量。

判据三条(同一发)：① Termux `su` 里 policeprobe 的 POL 组随开关翻转(0=EPERM、1=非 EPERM)；
② CTRL 组两遍都全绿；③ `/proc/ksu_cfiscan` 两遍都还是 22(证明不是靠写回桩拿到的能力)。
回执：X7 那行现在印 `cap0/cap1/prof1/CAPCLAMP` ⇒ 日志里能直接看见"发进来 ffffffff、落到 cred 变 3f"。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/policy/app_profile.c"

HELPER = (
    "/* rc63(#78, md 6.172)：把 profile 发来的 cap 掩码夹到内核自己的满集。\n"
    " * CAP_FULL_SET = {{ ~0, CAP_TO_MASK(CAP_LAST_CAP+1)-1 }}，这台机 CAP_LAST_CAP=37\n"
    " * 合法满集 = 0x0000003fffffffff；发进来的 ~0 里 bit38..63 是内核配不出来的脏位。 */\n"
    "int ksu_capclamp __read_mostly = 1;\n"
    "module_param(ksu_capclamp, int, 0644);\n"
    "MODULE_PARM_DESC(ksu_capclamp, \"KSU_CAPCLAMP: 1=cap 夹进 CAP_FULL_SET(默认) 0=原样拷(rc62 行为)\");\n"
    "\n"
    "static void ksu_cap_clamp(kernel_cap_t *c)\n"
    "{\n"
    "\tconst kernel_cap_t full = CAP_FULL_SET;\n"
    "\tunsigned int i;\n"
    "\n"
    "\tif (!ksu_capclamp)\n"
    "\t\treturn;\n"
    "\tfor (i = 0; i < _KERNEL_CAPABILITY_U32S; i++)\n"
    "\t\tc->cap[i] &= full.cap[i];\n"
    "}\n"
    "\n"
)

# (名字, 判重用的已存在片段, 锚点, 新文本)
EDITS = [
    ("CC-PARAM",
     "static void ksu_cap_clamp(",
     "module_param(ksu_no_mark_threads, bool, 0444);\n",
     HELPER + "module_param(ksu_no_mark_threads, bool, 0444);\n"),

    ("CC-CLAMP",
     "ksu_cap_clamp(&cred->cap_bset);",
     "    memcpy(&cred->cap_bset, &profile->capabilities.effective, sizeof(cred->cap_bset));\n",
     "    memcpy(&cred->cap_bset, &profile->capabilities.effective, sizeof(cred->cap_bset));\n"
     "    ksu_cap_clamp(&cred->cap_effective);\n"
     "    ksu_cap_clamp(&cred->cap_permitted);\n"
     "    ksu_cap_clamp(&cred->cap_bset);\n"),

    ("CC-CLAMP2",
     "ksu_cap_clamp(&cred->cap_ambient);",
     "        memcpy(&cred->cap_ambient, &profile->capabilities.effective, sizeof(cred->cap_ambient));\n",
     "        memcpy(&cred->cap_ambient, &profile->capabilities.effective, sizeof(cred->cap_ambient));\n"
     "        ksu_cap_clamp(&cred->cap_inheritable);\n"
     "        ksu_cap_clamp(&cred->cap_ambient);\n"),

    ("CC-X7",
     "CAPCLAMP=%d",
     '    pr_info("KSUBEAT X7 before commit_creds: uid=%u euid=%u cap0=%#x\\n",\n'
     '            cred->uid.val, cred->euid.val, cred->cap_effective.cap[0]);\n',
     '    pr_info("KSUBEAT X7 before commit_creds: uid=%u euid=%u cap0=%#x cap1=%#x prof=%#llx CAPCLAMP=%d\\n",\n'
     '            cred->uid.val, cred->euid.val, cred->cap_effective.cap[0],\n'
     '            cred->cap_effective.cap[1],\n'
     '            (unsigned long long)profile->capabilities.effective, ksu_capclamp);\n'),
]

# ★第一次上机编译被打回的一手(rc63, 2026-10-07 05:04)：这棵 KSU 树里
#   `profile->capabilities.effective` 是 **__u64**(不是 struct kernel_cap_t)，
#   所以 `.cap[1]` 直接 `error: member reference base type '__u64' is not a structure or union`；
#   `BUILD_BUG_ON(sizeof(...) != sizeof(kernel_cap_t))` 只证明"宽度相等"，不证明"是同一个类型"。
#   小端上这 8 字节 memcpy 进 kernel_cap_t ⇒ 低 32 位落 cap[0]、高 32 位落 cap[1] ⇒ 结论不变，
#   但回执要按 u64 印。下面这一条负责把**已经写坏的旧文本**就地换成对的(远端那份现在就是这个形状)。
FIXUPS = [
    ("CC-X7FIX",
     "prof=%#llx",
     '    pr_info("KSUBEAT X7 before commit_creds: uid=%u euid=%u cap0=%#x cap1=%#x prof1=%#x CAPCLAMP=%d\\n",\n'
     '            cred->uid.val, cred->euid.val, cred->cap_effective.cap[0],\n'
     '            cred->cap_effective.cap[1], profile->capabilities.effective.cap[1], ksu_capclamp);\n',
     '    pr_info("KSUBEAT X7 before commit_creds: uid=%u euid=%u cap0=%#x cap1=%#x prof=%#llx CAPCLAMP=%d\\n",\n'
     '            cred->uid.val, cred->euid.val, cred->cap_effective.cap[0],\n'
     '            cred->cap_effective.cap[1],\n'
     '            (unsigned long long)profile->capabilities.effective, ksu_capclamp);\n'),
]

s = io.open(F, encoding="utf-8", errors="replace").read()
orig = s
n = 0
for name, marker, old, new in FIXUPS + EDITS:
    if marker in s:
        print("  = 已有 %s ⇒ 跳过(幂等)" % name)
        continue
    c = s.count(old)
    if c != 1:
        if name.endswith("FIX"):
            print("  - %s 无需修(命中 %d 次，正常)" % (name, c))
            continue
        print("  !! %s 锚点命中 %d 次 ⇒ 这一处不动" % (name, c))
        continue
    s = s.replace(old, new, 1)
    n += 1
    print("  + %s" % name)

if "static void ksu_cap_clamp(" not in s:
    print("  [x] helper 没插进去 ⇒ 不写盘(锚点全没命中，八成是上游文件变了)")
    raise SystemExit(1)

if s != orig:
    io.open(F, "w", encoding="utf-8", newline="\n").write(s)
print("写了 %d 处 ⇒ 复读(全部当场读回来，不接受'我 sed 过了'):" % n)
for pat in ("int ksu_capclamp __read_mostly = 1;",
            "module_param(ksu_capclamp, int, 0644);",
            "static void ksu_cap_clamp(kernel_cap_t *c)",
            "ksu_cap_clamp(&cred->cap_effective);",
            "ksu_cap_clamp(&cred->cap_permitted);",
            "ksu_cap_clamp(&cred->cap_bset);",
            "ksu_cap_clamp(&cred->cap_inheritable);",
            "ksu_cap_clamp(&cred->cap_ambient);",
            "prof=%#llx",
            "CAPCLAMP=%d",
            "effective.cap[1]"):
    print("  %-46s 命中 %d" % (pat, s.count(pat)))
