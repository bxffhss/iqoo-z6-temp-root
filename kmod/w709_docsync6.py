#!/usr/bin/env python3
"""w709_docsync6.py —— 把 rc74b（修好去重与谓词那一段）成对登记进对外件，并刷新总闸现值。

   规矩照旧：①先把本轮新件接进总闸清单再**现取**它的 md5；②旧值降历史一律拆掉成对形状；
   ③锚点命中数≠1 就一个文件都不写；④CJK 串里不许混 ASCII 双引号(python 会被炸)。
"""
import hashlib
import io
import sys

W413 = "kmod/w413_selftest_sweep.sh"
s = io.open(W413, encoding="utf-8").read()
BA = "kmod/w690_ksubirth.sh kmod/w694_ringwitness.sh cm57/build_sustatic.sh; do"
BB = ("kmod/w690_ksubirth.sh kmod/w694_ringwitness.sh kmod/remote_ksu_rc74b.sh "
      "cm57/build_sustatic.sh; do")
PA = "kmod/w688_docsync4.py kmod/w707_docsync5.py; do"
PB = "kmod/w688_docsync4.py kmod/w707_docsync5.py kmod/w689_add_birthfd2.py kmod/w691_birth_test.py kmod/w709_docsync6.py; do"
changed = False
if "kmod/remote_ksu_rc74b.sh" not in s:
    if s.count(BA) != 1:
        print("[x] w413 bash 清单锚点命中 %d(应 1)⇒ 停" % s.count(BA))
        sys.exit(1)
    s = s.replace(BA, BB)
    changed = True
    print("  [OK] w413：remote_ksu_rc74b.sh 已接进 bash -n 清单")
else:
    print("  [skip] w413 里已有 remote_ksu_rc74b")
if "kmod/w689_add_birthfd2.py" not in s:
    if s.count(PA) != 1:
        print("[x] w413 py 清单锚点命中 %d(应 1)⇒ 停" % s.count(PA))
        sys.exit(1)
    s = s.replace(PA, PB)
    changed = True
    print("  [OK] w413：w689/w691/w709 已接进 py_compile 清单")
else:
    print("  [skip] w413 里已有 w689")
if changed:
    io.open(W413, "w", encoding="utf-8", newline="\n").write(s)

FILES = ["kmod/kernelsu_rc74b.ko", "kmod/remote_ksu_rc74b.sh", "kmod/w689_add_birthfd2.py",
         "kmod/w691_birth_test.py", "kmod/w695_shot51_plan.md", "kmod/w686_shot50_plan.md",
         "kmod/kernelsu_rc74.ko", "kmod/kernelsu_rc73.ko", "kmod/ksu_args.txt",
         "kmod/w413_selftest_sweep.sh", "kmod/w690_ksubirth.sh", "kmod/w694_ringwitness.sh"]
H = {}
for p in FILES:
    H[p] = hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]
B, BS, BP, BT, P51, SWP = (H["kmod/kernelsu_rc74b.ko"], H["kmod/remote_ksu_rc74b.sh"],
                           H["kmod/w689_add_birthfd2.py"], H["kmod/w691_birth_test.py"],
                           H["kmod/w695_shot51_plan.md"], H["kmod/w413_selftest_sweep.sh"])
P50 = H["kmod/w686_shot50_plan.md"]
print("  现取：rc74b=%s 构建=%s 补丁=%s 逻辑测试=%s 判据51=%s 判据50=%s 总闸=%s" % (B, BS, BP, BT, P51, P50, SWP))

D = "kmod/DELIVERY.md"
H2 = "analysis/CONTINUE_HERE.md"
C = "analysis/CURRENT-STATUS.md"
R = []

# ---------- 1) 总闸换版：三处成对值刷新；旧值留文里但拆掉成对形状 ----------
R.append((D, "总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`(★10-24 13:5x＝第 50 发两条读数腿 w690/w694＋docsync5 接进清单；",
          "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 15:4x＝把 rc74b 那批(w689/w691/w709＋remote_ksu_rc74b)接进清单；上一版 2746e105／" % SWP))
R.append((H2, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`｜这一发的 ko",
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`｜这一发的 ko" % SWP))
R.append((H2, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`(上一版 6388f71f)",
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`(当时；现值见上面那节，本条已降历史)"))
R.append((C, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`(已把这两条腿接进 `bash -n`)",
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(10-24 15:4x＝rc74b 那批接进清单；上一版 2746e105)" % SWP))
R.append((C, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`(10-24 13:5x＝把第 50 发两条读数腿 w690/w694 与本件接进清单；",
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`2746e105…`(当时；现值见上面新那节，这条降历史；旧注：10-24 13:5x＝把第 50 发两条读数腿 w690/w694 与本件接进清单；"))
# 第 50 发判据件追加了读数节 ⇒ 三处现值刷新
R.append((H2, "`kmod/w686_shot50_plan.md`＝`8b0e795f…`", "`kmod/w686_shot50_plan.md`＝`%s…`" % P50))
R.append((C, "`kmod/w686_shot50_plan.md`＝`8b0e795f…`", "`kmod/w686_shot50_plan.md`＝`%s…`" % P50))

# ---------- 2) DELIVERY §1B：登记 rc74b ----------
R.append((D, "**10-24 12:1x rc74（§6.413）新登记**：★**只是「编好了、离线闸门全绿、还没上机」**",
          "**10-24 15:4x rc74b（§6.415）新登记**：★同样**只是「编好了、离线全绿、还没上机」**，出货默认**仍是 rc73**。"
          "候选件 `kmod/kernelsu_rc74b.ko`＝`%s…`(5,106,064 B；＝rc73 ＋ 修正过的出生即装段：环状去重 `ksu_birth_ring[16]`＋只认主进程(`real_parent` 同 uid 一律不排)"
          "＋每 boot 硬上限 `ksu_mgr_birth_cap=64`＋分配失败回滚占位)｜构建驱动 `kmod/remote_ksu_rc74b.sh`＝`%s…`｜打补丁件 `kmod/w689_add_birthfd2.py`＝`%s…`｜"
          "**逻辑真值表** `kmod/w691_birth_test.py`＝`%s…`(把判定函数从打完补丁的源码里**原样抠出**、gcc 编到宿主跑 25 格，含一条负对照：同一负载喂 rc74 的单槽逻辑必须洪排 400 次而 rc74b 只排 4 次)｜"
          "开枪判据 `kmod/w695_shot51_plan.md`＝`%s…`(九条，开枪前写死)。离线一手读数：`llvm-nm` U 计数 **158=158 且双向差为空**、`__versions` 都 `000027c0`＝159 条(⇒ 装入门径逐字同 rc73)、"
          "`KSUBIRTH` 证人串源码 7 条＝产物 7 条、七条逐一点名(`seen Manager`/`queued self fd`/`dupskip n=`/`childskip n=`/`cap total=`/`kzalloc(ATOMIC) failed`/参数名)且同框负对照 rc74 里那三条新串都是 0、"
          "新符号 18 条**认不出来源＝0**、rc74 那三个单槽符号在产物里必须查不到、段差 `.text` 0x12cd0→0x132e0／`.data` +8B／`.bss` +280B(逐条 nm 指认)/`.rodata` +40B/`__param` 1240→1320B、"
          "`check_ko.py` 判定「可以上机」、**两次独立构建 md5 相同**。\n"
          "\n**10-24 12:1x rc74（§6.413）新登记**：★**只是「编好了、离线闸门全绿、还没上机」**" % (B, BS, BP, BT, P51)))

# ---------- 3) 两份入口文档各加一节 ----------
R.append((H2, "## ★★★★★★★★★★★★★★★★★★ **2026-10-24 13:17–13:58 第 50 发(1 枪)：rc74 的机制判正",
          "## ★★★★★★★★★★★★★★★★★★ **2026-10-24 14:5x–15:4x 收口：0 枪：rc74b 编好＝把第 50 发抓到的「去重被顶穿⇒驱动 fd 泄漏」修掉(环状去重＋只认主进程＋每-boot 上限)，"
          "判定函数在宿主上跑真值表(含 rc74 单槽作负对照)；还没上机 ⇒ 默认仍是 rc73**（一手 md **§6.415**）\n\n"
          "- **改了三件事，都不是新形状**：①去重从**单槽**换成 `ksu_birth_ring[16]` 的 `(pid,start_time)` 环——第 50 发那处泄漏的根因就是单槽被 Manager 一家子多个 pid 交替顶穿；"
          "②谓词收窄：`real_parent` 的 uid 与我相同 ⇒ 那是 Manager 自己 fork 的 `sh`/`id`/`libksud.so`，**不排**(牌子只认主进程)；③每 boot 硬上限 `ksu_mgr_birth_cap=64` ＋ 分配失败把占掉的槽回滚(否则那个进程被永久拉黑)。\n"
          "- ★**挡住的分支不打印**，只留 `dupskip`/`childskip` **每 256 次一条**计数证人——热路径洪印把机器拖死过一次(§6.118)，这条是刻意设计，别当成「没证人」。\n"
          "- **怎么证明修对了(不等上机的那半)**：判定函数写成**纯函数**并用 `BEGIN/END KSUBIRTH-PURE` 圈住 ⇒ `kmod/w691_birth_test.py` 从**打完补丁的那份源码**里原样抠出这段、gcc 编到宿主跑 25 格真值表；"
          "★负对照同框：同一份负载(4 个 pid 交替 ×100)喂 rc74 的单槽逻辑 ⇒ 洪排 **400** 次，喂 rc74b ⇒ 恰好 **4** 次。另有一格专测「同 pid 但 `start_time` 变(pid 复用)必须再排」——那正是我加 `start_time` 的初衷。\n"
          "- **离线结构核对(全是从构建日志现读，不是我记忆的数)**：U 计数 158=158 **双向差为空**｜`__versions` 都 159 条 `000027c0` ⇒ **装入门径逐字同 rc73**(自旋锁那两个符号 rc73 本来就引用了，我原本预期会多两条，实测多 0 条)｜"
          "`KSUBIRTH` 源码 7 条＝产物 7 条｜七条证人串逐条点名＋**同框负对照** rc74 里 `dupskip/childskip/cap` 全 0｜新符号 18 条「认不出来源＝0」｜rc74 的三个单槽符号在产物里必须查不到｜"
          "`.text` 0x12cd0→0x132e0、`.data` +8B、`.bss` +280B(七个占位逐条 nm 指认)、`.rodata` +40B、`__param` 1240→1320B｜`check_ko.py` 判定可以上机｜**两次独立构建同 md5**。\n"
          "- ★**这一发我又错了两次闸门**(同例 173/174 族，两条都值得记)：①把 `KSUBIRTH 串 >=9` 当判据——9 是**源码里那个 token 的出现次数**(含注释与横幅)，产物里真格式串是 7 条 ⇒ 一份正确的 ko 被我判红；"
          "修＝期望值**从源码现数** `grep -cE 'pr_*(\"KSUBIRTH'`，两边都是现数的同一口径。②串集对表的「认得出」名单只写了硬编码模式，被新函数的**形参名**(`is_leader`/`parent_is_mgr`，因 DWARF 进了产物)打红；"
          "修＝白名单改成「这次改的那两份文件里出现过的标识符」＋打印白名单条数当输入证人。\n"
          "- **登记(现取)**：候选 ko `kmod/kernelsu_rc74b.ko`＝`%s…`｜构建驱动 `kmod/remote_ksu_rc74b.sh`＝`%s…`｜补丁件 `kmod/w689_add_birthfd2.py`＝`%s…`｜逻辑测试 `kmod/w691_birth_test.py`＝`%s…`｜"
          "第 51 发判据 `kmod/w695_shot51_plan.md`＝`%s…`｜构建日志存证 `kmod/w103_evidence/w693_rc74b_build.log`｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`｜出货默认仍未变＝`kmod/kernelsu_rc73.ko`＝`34b3efa8…`＋`kmod/ksu_args.txt`＝`67199f48…`。\n"
          "- **下一步＝第 51 发(要用户点头才开枪)**：`KO=kmod/kernelsu_rc74b.ko I_KNOW=1 bash kmod/go.sh`，九条判据写死；★主判据从「牌子亮」变成「**每个 pid 的 `queued self fd` 恰好 1 次**＋主进程表里 `fd_ksu` ≤2」"
          "(第 50 发同位置是 14→68→75)；机制那一格只当复现。★**代价仍是两发**：51 验 rc74b；52 才是 #178「当前版包真机一键认证(连 ko 一起认)」。机器现态 `Enforcing mod=0`、boot_id `95faa669`、**10-24 枪数＝1**。\n\n"
          "## ★★★★★★★★★★★★★★★★★★ **2026-10-24 13:17–13:58 第 50 发(1 枪)：rc74 的机制判正"
          % (B, BS, BP, BT, P51, SWP)))

R.append((C, "## ★★★★★★★★★★★★★★★★★★ 2026-10-24 13:5x 更新（本节最新，取代 12:1x 那节）",
          "## ★★★★★★★★★★★★★★★★★★ 2026-10-24 15:4x 更新（本节最新，取代 13:5x 那节）—— **rc74b 编好：把第 50 发抓到的「去重被顶穿⇒驱动 fd 泄漏」修掉了；0 枪，还没上机 ⇒ 默认仍是 rc73**（md **§6.415**）\n\n"
          "- **改的三件**：单槽去重 ⇒ `ksu_birth_ring[16]` 的 `(pid,start_time)` 环；谓词 ⇒ `real_parent` 同 uid(Manager 自己 fork 的子进程)一律不排，只认主进程；加每-boot 硬上限 `ksu_mgr_birth_cap=64`＋分配失败回滚占位。\n"
          "- **不等上机就有的一半证据**：判定函数是纯函数并带标记 ⇒ `kmod/w691_birth_test.py` 从打完补丁的源码里原样抠出来、gcc 宿主跑 25 格；负对照＝同一负载 rc74 单槽洪排 400 次 vs rc74b 恰好 4 次；另有一格钉「pid 复用(`start_time` 变)必须再排」。\n"
          "- **离线一手**：U 158=158 双向差为空、`__versions` 159 条未变(**装入门径逐字同 rc73**)、证人串源码 7＝产物 7 且七条逐条点名、新符号 18 条认不出来源＝0、rc74 的单槽符号在产物里查不到、`check_ko.py` 可以上机、两次构建同 md5。\n"
          "- **现值(现取)**：`kmod/kernelsu_rc74b.ko`＝`%s…`｜`kmod/remote_ksu_rc74b.sh`＝`%s…`｜`kmod/w689_add_birthfd2.py`＝`%s…`｜`kmod/w691_birth_test.py`＝`%s…`｜`kmod/w695_shot51_plan.md`＝`%s…`｜"
          "`kmod/w686_shot50_plan.md`＝`%s…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`。机器 `Enforcing mod=0`、boot_id `95faa669`、**10-24 枪数＝1**。\n\n"
          "## ★★★★★★★★★★★★★★★★★★ 2026-10-24 13:5x 更新（本节最新，取代 12:1x 那节）"
          % (B, BS, BP, BT, P51, P50, SWP)))

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
print("=== w709 完成：rc74b=%s 已登记为「编好未上机」；总闸现值=%s ===" % (B, SWP))
