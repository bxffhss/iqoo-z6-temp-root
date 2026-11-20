#!/usr/bin/env python3
"""w688_docsync4.py —— 把 rc74「编好了、离线闸门全绿、还没上机」这件事成对写回对外件。

   规矩照旧：
   ①新值一律本脚本现算 md5(先把 w688 自己接进总闸清单，再取总闸的 md5 ⇒ 写进文档的就是最终值)；
   ②旧值降历史要**拆掉 `名字`＝`哈希` 的成对形状**(改成裸 8 位＋「上一版」)，否则 w415 的 R9 会把旧值当现值验；
   ③锚点命中数≠1 就一个文件都不写；
   ④★CJK 串里不许出现 ASCII 双引号(第一版就是踩这条把 python 炸成 SyntaxError，见 env 记忆)。

   跑法：PYTHONUTF8=1 python kmod/w688_docsync4.py
"""
import hashlib
import io
import sys

W413 = "kmod/w413_selftest_sweep.sh"
s = io.open(W413, encoding="utf-8").read()
A = "kmod/w682_rr.py kmod/w685_add_birthfd.py; do"
N = "kmod/w682_rr.py kmod/w685_add_birthfd.py kmod/w688_docsync4.py; do"
if "kmod/w688_docsync4.py" in s:
    print("  [skip] w413 里已有 w688")
elif s.count(A) != 1:
    print("[x] w413 锚点命中 %d(应 1)⇒ 停" % s.count(A))
    sys.exit(1)
else:
    io.open(W413, "w", encoding="utf-8", newline="\n").write(s.replace(A, N))
    print("  [OK] w413：w688 已接进 py_compile 清单")

H = {}
for p in ["kmod/kernelsu_rc74.ko", "kmod/remote_ksu_rc74.sh", "kmod/w685_add_birthfd.py",
          "kmod/w682_rr.py", "kmod/w413_selftest_sweep.sh", "kmod/w625_seedrestart.sh",
          "kmod/kernelsu_rc73.ko", "kmod/ksu_args.txt", "kmod/w686_shot50_plan.md"]:
    H[p] = hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]
RC74, BSH, PY74, RR, SWP = (H["kmod/kernelsu_rc74.ko"], H["kmod/remote_ksu_rc74.sh"],
                            H["kmod/w685_add_birthfd.py"], H["kmod/w682_rr.py"],
                            H["kmod/w413_selftest_sweep.sh"])
print("  现取：rc74=%s 构建脚本=%s 补丁件=%s 远程跑件=%s 总闸=%s" % (RC74, BSH, PY74, RR, SWP))

D = "kmod/DELIVERY.md"
H2 = "analysis/CONTINUE_HERE.md"
C = "analysis/CURRENT-STATUS.md"
OLD = "516ac2ad"
R = []

# ---- 1) 总闸又换版(往 py 清单里加了 w682/w685/w688 三件)⇒ 四处成对值都要换成最终值 ----
R.append((D, "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 04:5x＝把 w680 接进 py_compile；上一版 3fb3776b)" % OLD,
          "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 12:1x＝把 rc74 那批工具件 w682/w685/w688 接进 py_compile、"
          "remote_ksu_rc73/74 接进 bash -n；上一版 %s／3fb3776b)" % (SWP, OLD)))
R.append((D, "、包内 `z6root/kernelsu.ko`＝`34b3efa8`、总闸＝`%s`。" % OLD,
          "、包内 `z6root/kernelsu.ko`＝`34b3efa8`、总闸＝`%s`。" % SWP))
R.append((C, "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 04:5x＝w680 接进 py_compile；上一版 3fb3776b)" % OLD,
          "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 12:1x＝rc74 那批工具件接进清单；上一版 %s／3fb3776b)" % (SWP, OLD)))
R.append((H2, "忠实性闸＝`85f08e82…`｜总闸＝`%s…`(接进了 w680 自己)。" % OLD,
          "忠实性闸＝`85f08e82…`｜总闸＝`%s…`(10-24 12:1x＝rc74 那批工具件接进清单；上一版 %s)。" % (SWP, OLD)))
R.append((H2, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`。" % OLD,
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(上一版 %s)。" % (SWP, OLD)))

# ---- 2) DELIVERY §1B：把 rc74 登记成「已编好、未上机」，出货默认仍写 rc73 ----
R.append((D, "**10-24 #180（§6.411）新登记／改值的件**：",
          "**10-24 12:1x rc74（§6.413）新登记**：★**只是「编好了、离线闸门全绿、还没上机」**，出货默认**仍是 rc73**(那支在第 48 发单变量里载过)。"
          "候选件 `kmod/kernelsu_rc74.ko`＝`%s…`(5,095,728 B；＝rc73 那段护栏 ＋ 「Manager 一出生就给它装驱动 fd」那一小段)｜"
          "构建驱动 `kmod/remote_ksu_rc74.sh`＝`%s…`｜打补丁件 `kmod/w685_add_birthfd.py`＝`%s…`(只追加＋只插两处，锚点命中数≠1 就停)｜"
          "远程跑件 `kmod/w682_rr.py`＝`%s…`｜开枪判据(写死在开枪前)`kmod/w686_shot50_plan.md`。\n"
          "离线核对(全是那次构建日志与本机现跑的一手读数)：`vermagic` 逐字同 rc73｜`__versions` 两支都 `000027c0`＝159 条(CRC 表没动)｜"
          "`llvm-nm` 的 U 计数 rc73=rc74=158 **且两个方向的差都为空**(⇒ 装入门径没变)｜段差＝`.text` 0x12cd0→0x12ea8(+472B) / "
          "`.rodata` +24B / `.rodata.str1.1` +269B / `.bss` +20B(那三个静态量 `ksu_birth_pid/start/queued` 逐条 nm 指认) / "
          "`__param` 1240→1280B(多一个参数)，`.data` 逐字节不变｜符号 837→847(新增 10 条，全属这次那段新代码)｜"
          "`strings` 串集：新增 37 条逐条可指认、消失 2 条都是说不清=0 的形状，**带 %% 的串 421→426 只增不减**(这条是「允许把短片段当噪声放过」的前提闸)｜"
          "`kmod/check_ko.py` 判定「可以上机」｜两次独立构建产物 md5 相同(可复现)。\n"
          "★新参数 `ksu_mgr_birth_fd` **默认 1(开)** ⇒ `kmod/ksu_args.txt`＝`%s…` 一个字都不用改；"
          "要逐字退回 rc73 的行为就在 insmod 额外带 `ksu_mgr_birth_fd=0`(只在实验/对照里用，不进交付)。\n"
          "\n**10-24 #180（§6.411）新登记／改值的件**：" % (RC74, BSH, PY74, RR, H["kmod/ksu_args.txt"])))

docs = {}
for f, old, new in R:
    if f not in docs:
        docs[f] = io.open(f, encoding="utf-8").read()
    c = docs[f].count(old)
    if c != 1:
        print("[x] %s 的锚点命中 %d(应 1)⇒ 一个文件都不写：%s…" % (f, c, old[:56]))
        sys.exit(1)
    docs[f] = docs[f].replace(old, new)
for f, t in docs.items():
    io.open(f, "w", encoding="utf-8", newline="\n").write(t)
    print("  [OK] 写了 %s(字节=%d)" % (f, len(t.encode("utf-8"))))
print("=== w688 完成：rc74 登记为「已编好未上机」=%s／总闸现值=%s ===" % (RC74, SWP))
