#!/usr/bin/env python3
# w961_mark_stale_regs.py —— 处理文档里被我这几天改动改陈旧的 6 条 md5 登记值。
# ★为什么不覆盖成新值：`DELIVERY.md:95/143`、`W345_RC68_WINDOW.md:1545` 那几条是**带日期/带发次的历史记录**
#   （"10-25 当时登记"、"第 37 发那版"）——覆盖＝篡改史账。审计器 `w415` 的 R9 早留了正确的门：
#   **登记值前 30 字内**出现"旧/当时/作废/→/滞后/已过期/错值/误记"就按历史值放过（`HIST_BEFORE`）。
#   ⇒ 所以标记必须**紧贴登记值**，行首的日期救不了它（10-18 那次"整行豁免"就是因为太松才改成逐条回看）。
# 做法两件事：①给这 6 条各加紧贴的历史标记（"当时"），文字其余一字不动；
#   ②在 DELIVERY §0 末尾追加一条 **10-27 现取登记**，现行值写在这里，由 R9 拿仓库本身当正对照回读。
# ★两阶段 fail-closed（必须全量）：先把**所有**锚点与**所有**现取 md5 在全局核一遍，任何一条不符 ⇒ 零写入。
import hashlib, os, re, sys

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

MARKS = [   # (文件, 定位锚＝登记值那一截, 要插入的历史标记)
    ("kmod/DELIVERY.md", "`kmod/_tmp_selftest_rdst/probe_shbin.sh`＝`fe0ef434", "当时"),
    ("kmod/DELIVERY.md", "`cm57/su_static.c` 现＝`7700ae25", "当时"),
    ("kmod/DELIVERY.md", "`kmod/w834_su_args_selftest.py`＝`da20f24c", "当时"),
    ("kmod/DELIVERY.md", "当前版 `kmod/ui_grant.sh`＝`f4cab5b1", "当时"),
    ("kmod/W345_RC68_WINDOW.md", "`kmod/ui_grant.sh`＝`f4cab5b1", "当时"),
    ("kmod/W345_RC68_WINDOW.md", "`kmod/w459_leg_live.sh`＝`7a085cd6", "当时"),
]
LIVE = [    # 追加登记的顺序：文件 → 我准备写进文档的前缀
    ("cm57/su_static.c", "c3f34d27"),
    ("kmod/w834_su_args_selftest.py", "de37a334"),
    ("kmod/_tmp_selftest_rdst/probe_shbin.sh", "9359aaa0"),
    ("kmod/ui_grant.sh", "e84e5e0d"),
    ("kmod/w459_leg_live.sh", "d20461e6"),
]
HIST = r"旧|当时|作废|勘误|误记|错值|已过期|滞后|→|上一版|旧版"


def md5p(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 16), b""):
            h.update(b)
    return h.hexdigest()


# ---------- 阶段一：全局核锚，一条不过就不写 ----------
bad, texts = [], {}
for path, anchor, _ in MARKS:
    if path not in texts:
        if not os.path.exists(path):
            bad.append("文件不存在 %s" % path)
            continue
        texts[path] = open(path, encoding="utf-8").read()
    n = texts.get(path, "").count(anchor)
    if n != 1:
        bad.append("%s 锚点命中 %d 次(要恰好 1)：%s" % (path, n, anchor[:60]))
    else:                                   # 已经标记过的不重复标
        i = anchor.index("＝")
        if re.search(HIST + r"$", anchor[max(0, i - 12):i].rstrip("` ")):
            bad.append("%s 这截已带历史标记，锚点写法要重看：%s" % (path, anchor[:60]))
for path, want in LIVE:
    if not os.path.exists(path):
        bad.append("现取件不存在 %s" % path)
    elif not md5p(path).startswith(want):
        bad.append("%s 现取=%s 与要写的 %s 不符 ⇒ 是登记值错，不是文件错" % (path, md5p(path)[:8], want))
if bad:
    print("=== 拒写（零字节改动）===")
    for b in bad:
        print("  [x]", b)
    sys.exit(1)
print("=== 阶段一过：%d 条锚点各 1 次、%d 件现取 md5 对得上 ⇒ 开始写 ===" % (len(MARKS), len(LIVE)))

# ---------- 阶段二：统一写 ----------
for path, anchor, mark in MARKS:
    i = anchor.index("＝")
    head = anchor[:i].replace("当前版", "当时那版")
    new = head + mark + anchor[i:]
    texts[path] = texts[path].replace(anchor, new, 1)
    print("  标记 %s：%s… ⇒ %s…" % (path, anchor[:40], new[:44]))

note = ("\n- ★**10-27 现取登记（0 枪，md §6.458）**：这几天 v6／夹具修复／自测加格把下面几件的字节改了，"
        "旧值留在原句里当史账，**现行值以这一条为准**：`cm57/su_static.c`＝`c3f34d27…`（v6 源码；出货件 `37ba7972…`）、"
        "`kmod/w834_su_args_selftest.py`＝`de37a334…`（**19 格**全绿，不是当年那 16 格）、"
        "`kmod/_tmp_selftest_rdst/probe_shbin.sh`＝`9359aaa0…`（加 `SUW_SHBIN_WITNESS` 开关，9/9）、"
        "`kmod/ui_grant.sh`＝`e84e5e0d…`（`restore_ime` 用 `${IME_RESTORE:-}`：被切片夹具 source 时不再在 `set -u` 下崩）、"
        "`kmod/w459_leg_live.sh`＝`d20461e6…`（切片后补顶层全局默认值）。"
        "★这五条由 `kmod/w415_doc_audit.py` 的 R9 拿仓库本身当正对照回读——不是我抄给自己的。\n")
lines = texts["kmod/DELIVERY.md"].split("\n")
at = next(i for i, l in enumerate(lines) if l.startswith("## 1. "))
lines.insert(at, note)
texts["kmod/DELIVERY.md"] = "\n".join(lines)

for path, body in texts.items():
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(body)
    print("  已写 %s" % path)

# ---------- 阶段三：读回落点 ----------
bad = 0
for path, anchor, mark in MARKS:
    body = open(path, encoding="utf-8").read()
    i = anchor.index("＝")
    head = anchor[:i].replace("当前版", "当时那版")
    if (head + mark + anchor[i:]) not in body:
        print("  [x] 写后读不到标记结果：%s %s" % (path, anchor[:40]))
        bad += 1
d = open("kmod/DELIVERY.md", encoding="utf-8").read()
for path, want in LIVE:
    if want not in d:
        print("  [x] DELIVERY 里没有 %s 的现取前缀 %s" % (path, want))
        bad += 1
print("=== 读回落点：%s ===" % ("全过" if bad == 0 else "%d 处没过" % bad))
sys.exit(1 if bad else 0)
