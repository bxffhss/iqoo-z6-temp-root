#!/usr/bin/env python3
"""w707_docsync5.py —— 把第 50 发的读数成对写回对外件：机制判正／这一支不许升默认／rc74b 要修什么。

   规矩照旧(都是记忆里那几条)：
   ①先把本轮新腿(w690/w694)与本件自己接进总闸清单，**再**现取总闸 md5 ⇒ 文档写的就是最终值；
   ②旧值降历史一律**拆掉 `路径`＝`哈希` 的成对形状**(改成 当时 `xxx`)，新值必须写成对；
   ③锚点命中数≠1 就一个文件都不写；
   ④CJK 串里不许混 ASCII 双引号(会把 python 炸成 SyntaxError，w688 第一版就是这么死的)。
"""
import hashlib
import io
import sys

W413 = "kmod/w413_selftest_sweep.sh"
s = io.open(W413, encoding="utf-8").read()
A = "kmod/w670_gate_test.sh kmod/remote_ksu_rc74.sh kmod/remote_ksu_rc73.sh cm57/build_sustatic.sh; do"
B = ("kmod/w670_gate_test.sh kmod/remote_ksu_rc74.sh kmod/remote_ksu_rc73.sh "
     "kmod/w690_ksubirth.sh kmod/w694_ringwitness.sh cm57/build_sustatic.sh; do")
if "kmod/w690_ksubirth.sh" in s:
    print("  [skip] w413 里已有 w690")
elif s.count(A) != 1:
    print("[x] w413 的 bash -n 锚点命中 %d(应 1)⇒ 停" % s.count(A))
    sys.exit(1)
else:
    s = s.replace(A, B)
    io.open(W413, "w", encoding="utf-8", newline="\n").write(s)
    print("  [OK] w413：w690/w694 已接进 bash -n 清单")

s = io.open(W413, encoding="utf-8").read()
PA = "kmod/w682_rr.py kmod/w685_add_birthfd.py kmod/w688_docsync4.py; do"
PB = "kmod/w682_rr.py kmod/w685_add_birthfd.py kmod/w688_docsync4.py kmod/w707_docsync5.py; do"
if "kmod/w707_docsync5.py" in s:
    print("  [skip] w413 里已有 w707")
elif s.count(PA) != 1:
    print("[x] w413 的 py_compile 锚点命中 %d(应 1)⇒ 停" % s.count(PA))
    sys.exit(1)
else:
    io.open(W413, "w", encoding="utf-8", newline="\n").write(s.replace(PA, PB))
    print("  [OK] w413：w707 已接进 py_compile 清单")

H = {}
for p in ["kmod/kernelsu_rc74.ko", "kmod/kernelsu_rc73.ko", "kmod/ksu_args.txt",
          "kmod/w686_shot50_plan.md", "kmod/w690_ksubirth.sh", "kmod/w694_ringwitness.sh",
          "kmod/w413_selftest_sweep.sh", "kmod/w625_seedrestart.sh", "kmod/w670_gate_test.sh"]:
    H[p] = hashlib.md5(io.open(p, "rb").read()).hexdigest()[:8]
SWP = H["kmod/w413_selftest_sweep.sh"]
PLAN = H["kmod/w686_shot50_plan.md"]
print("  现取：总闸=%s 判据件=%s w690=%s w694=%s rc74=%s rc73=%s args=%s" % (
    SWP, PLAN, H["kmod/w690_ksubirth.sh"], H["kmod/w694_ringwitness.sh"],
    H["kmod/kernelsu_rc74.ko"], H["kmod/kernelsu_rc73.ko"], H["kmod/ksu_args.txt"]))

D = "kmod/DELIVERY.md"
H2 = "analysis/CONTINUE_HERE.md"
C = "analysis/CURRENT-STATUS.md"
R = []

# ---------- 1) 三处把「开枪判据」那枚旧哈希拆掉成对形状，并给出现值 ----------
R.append((H2, "开枪判据(开枪前写死)`kmod/w686_shot50_plan.md`＝`fa9ac583…`",
          "开枪判据(开枪前写死)`kmod/w686_shot50_plan.md`(当时 `fa9ac583`；★10-24 13:5x 现值＝`%s`＝追加了读数节，判据一字未改)" % PLAN))
R.append((C, "八条判据开枪前写死在 `kmod/w686_shot50_plan.md`＝`fa9ac583…`",
          "八条判据开枪前写死在 `kmod/w686_shot50_plan.md`(当时 `fa9ac583`；★10-24 13:5x 现值＝`%s`＝追加读数节，判据未改)" % PLAN))
R.append((C, "总闸 `kmod/w413_selftest_sweep.sh`＝`6388f71f…`(10-24 12:1x＝rc74 那批工具件接进清单；上一版 `516ac2ad`／`3fb3776b` 只当历史)",
          "总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(10-24 13:5x＝把第 50 发两条读数腿 w690/w694 与本件接进清单；上一版 6388f71f／516ac2ad 只当历史)" % SWP))
R.append((H2, "｜总闸 `kmod/w413_selftest_sweep.sh`＝`6388f71f…`｜出货默认**未变**",
          "｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(上一版 6388f71f)｜出货默认**未变**" % SWP))
R.append((D, "`kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 12:1x＝把 rc74 那批工具件 w682/w685/w688 接进 py_compile、" % "6388f71f",
          "`kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 13:5x＝第 50 发两条读数腿 w690/w694＋docsync5 接进清单；" % SWP))

# ---------- 2) DELIVERY：在 rc74 登记段后面接「第 50 发读数」，并说清不许升默认 ----------
R.append((D, "★新参数 `ksu_mgr_birth_fd` **默认 1(开)** ⇒",
          "★**10-24 13:5x 第 50 发读数(md §6.414，1 枪)**：机制**判正**——`am force-stop` 之后**只用 `am start`**(不写触发口、不跑恢复腿、不发深链)⇒ 官方 Manager 首页自己回 `工作中／版本：32601-2／越狱`，"
          "内核三件套同 pid 时刻递增(`KSUBIRTH seen Manager`→`queued self fd`→`KSUFDINST 回调跑在 … => fd=N`)；`GFP_ATOMIC` 分配失败 **0**、`NULLFILES skip` **0**、`signal 6` **0**、无复位、模块活到 insmod+**1423 秒**。"
          "★**但这一支不许升默认**：同发抓到 `(pid,start_time)` **去重没生效**(同一 pid 三次入队，10 秒内 149 组)⇒ **驱动 fd 泄漏**(Manager 主进程表里 `ksu_driver` 14→68→**75** 条)，且谓词宽到给 Manager 的 `[sh]`/`[id]`/`libksud.so` 子进程也装。"
          "⇒ 出货默认**仍是 rc73**；下一步＝**rc74b** 修去重＋收窄谓词(0 枪编＋专属正/负对照自测)→ 第 51 发再验 → 赢了才谈换默认与重打包。读数与仪器教训全文＝`kmod/w686_shot50_plan.md` 的「读数」节。\n"
          "★新参数 `ksu_mgr_birth_fd` **默认 1(开)** ⇒"))

# ---------- 3) 两份入口文档各加一节最新的 ----------
R.append((H2, "## ★★★★★★★★★★★★★★★★★★ **2026-10-24 11:0x–12:1x 收口：0 枪：rc74 编好了",
          "## ★★★★★★★★★★★★★★★★★★ **2026-10-24 13:17–13:58 第 50 发(1 枪)：rc74 的机制判正——force-stop 后只用 `am start`(不跑腿)牌子自己回 `工作中／32601-2`；★同发抓到「去重失效⇒驱动 fd 泄漏」⇒ 这一支不许升默认，默认仍是 rc73**（一手 md **§6.414**）\n\n"
          "- **赢在哪(一句话)**：`[13:30:06] insmod rc=0 up=728.15`；随后 `am force-stop me.weishu.kernelsu` → **只用 `am start`** → 无障碍树读回 `状态=工作中 版本=32601-2 越狱串=越狱 页签=4`(pid=3560)，"
          "同 10 秒内核 `seen Manager=149／queued self fd=149／=> fd=149`，且 `KSUBIRTH seen→queued→KSUFDINST 回调跑在 … => fd=N` 三件套同 pid 时刻递增。⇒ 「在 Manager 自己那次查询之前把 fd 塞进去」这条形状**成立**，"
          "它曾是 §6.406/§6.407 之后仅剩的形状。\n"
          "- ★**没赢的那半(为什么不发货)**：`(pid,start_time)` 去重**没生效**——同一 `pid=13318 comm=[sh] start=1724956878195` 在 `1724.985655/1724.986266/1725.000273` 三次入队 ⇒ **驱动 fd 泄漏**："
          "Manager 主进程表里 `ksu_driver` 从 14 条→68→**75** 条(`fd 总数 185`)。谓词也比我设计的宽(给它的 `[sh]`/`[id]`/`libksud.so` 子进程照装)。机子没炸只因为这窗 Manager 只重启了三次 ⇒ **每开一次漏几十条**是否决理由。\n"
          "- **稳定性/护栏全绿**：`kzalloc(ATOMIC) failed=0`(那条新写的失败支一次没走到)／`task_work_add rc=0`／`NULLFILES skip=0`／`received signal 6=0`／`Service 'zygote'=0`／boot_id `7a331af0` 连续／模块活到 `up=2151`＝**insmod+1423 秒**；收尾是 `reboot,shell`(不是 PS_HOLD)。\n"
          "- **顺带把 #178 欠的那枚收了**：恢复腿的闸在**真形状**里第一枚＝连敲两次，第 1 敲真做并落锁 `coolup=2008,runs=1,pid=15159`，立刻第 2 敲 ⇒ `SR-ALREADY pid=15159 fd=75`、`pidof` 前后一字不变、`runs` 仍 1。\n"
          "- ★**一条口径修正(待验，别当结论)**：pid=14302 生于 `up≈85.9`(**早于 insmod**)、装载期被装上 fd 后**从未重启**，却在 `up=1667` 读出 `工作中` ⇒ §6.406 那句「首页查询＝进程启动一次性」**至少不完整**(回前台／Activity 重建会重查)。"
          "这直接牵动「用户态轮询是否真的判死」，要单独设计才说得清，**不新开枪别改**。\n"
          "- ★**仪器上四条当场兑现**：①腿 v1 把 `dmesg` 塞进变量再 `printf` ⇒ `Argument list too long`、**六个计数全 0**(抽取器炸了却长得像「没打印」；修＝落文件＋计数前先打行数/字节/首末时间戳)；"
          "②活环当时只覆盖 `959→1175` 而 insmod 在 `728` ⇒ **活环里数到 0 不是否据**，必须读带 `--- HB up=… ---` 的跟随件并打印覆盖区间；③`dd` 把行切半＋HB 插在行中 ⇒ 出现 `uid=1`(其实是 `uid=10104` 被截)，"
          "我差点据此多判一条莫须有缺陷 ⇒ **半行不许取字段值**；④两次焦点不在 Manager(`NotificationShade`/`VivoUsbDialog`)⇒ 按**未测**算，没写成「牌子没了」。\n"
          "- ★**一条流程缺陷**：`w161_teardown.sh` 用的是自己那份 **90 条**名单，而 `w625_lock`/`w625_seedrestart.out` 只在 `w558_rm3.sh` 的 **151 条**里 ⇒ 这次漏删，事后靠 **shell 侧** `rm`＋`ls` 复证补上。⇒ 名单漂移＝例 169 那一族的反向版本，要么统一要么现数。\n"
          "- **登记(现取)**：判据与读数 `kmod/w686_shot50_plan.md`＝`%s…`｜读数腿 `kmod/w690_ksubirth.sh`＝`%s…`｜装载期证人腿 `kmod/w694_ringwitness.sh`＝`%s…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`｜"
          "这一发的 ko `kmod/kernelsu_rc74.ko`＝`6ef4cbea…`(**留仓不进默认**)｜默认仍 `kmod/kernelsu_rc73.ko`＝`34b3efa8…`＋`kmod/ksu_args.txt`＝`67199f48…`。机器 `Enforcing mod=0`、boot_id `95faa669`、**10-24 枪数＝1**。\n"
          "- **下一步**：**rc74b**(修去重＋收窄谓词＋专属正/负对照：同 pid 连做 N 次只许 +1／换 pid +1／**同 pid 但 `start_time` 变必须再 +1**)→ 第 51 发验 rc74b → 赢了才谈换默认＋重打包＋#178 连 ko 一起认。rc75(降 printk)仍在后面。\n\n"
          "## ★★★★★★★★★★★★★★★★★★ **2026-10-24 11:0x–12:1x 收口：0 枪：rc74 编好了" % (PLAN, H["kmod/w690_ksubirth.sh"], H["kmod/w694_ringwitness.sh"], SWP)))

R.append((C, "## ★★★★★★★★★★★★★★★★★★ 2026-10-24 12:1x 更新（本节最新，取代 10-22 那节）",
          "## ★★★★★★★★★★★★★★★★★★ 2026-10-24 13:5x 更新（本节最新，取代 12:1x 那节）—— **第 50 发(1 枪)：rc74 机制判正／同发抓到 fd 泄漏 ⇒ 默认仍是 rc73；#178 欠的那枚 `SR-ALREADY` 到手**（md **§6.414**）\n\n"
          "- **正**：force-stop 后**只用 `am start`**(不写触发口／不跑恢复腿／不发深链)⇒ 官方首页自己回 `工作中／32601-2／越狱／页签4`；内核三件套同 pid(`KSUBIRTH seen Manager`→`queued self fd`→`KSUFDINST 回调跑在 … => fd=N`)；"
          "`GFP_ATOMIC` 失败 0／`NULLFILES skip` 0／`signal 6` 0／无复位／模块活到 insmod+1423 秒；恢复腿两敲 ⇒ 第二敲 `SR-ALREADY pid=15159`、pid 一字不变。\n"
          "- ★**负(否决发货)**：`(pid,start_time)` 去重没生效 ⇒ 10 秒 149 组、Manager 表里 `ksu_driver` 涨到 **75** 条＝**驱动 fd 泄漏**；谓词宽到给 `[sh]`/`[id]`/`libksud.so` 子进程也装。⇒ 下一支＝**rc74b**(修去重＋收窄＋专属正/负对照自测)→ 第 51 发再验。\n"
          "- **现值(现取)**：`kmod/w686_shot50_plan.md`＝`%s…`(判据未改，追加读数节)｜读数腿 `kmod/w690_ksubirth.sh`＝`%s…`｜`kmod/w694_ringwitness.sh`＝`%s…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(已把这两条腿接进 `bash -n`)｜"
          "出货默认 `kmod/kernelsu_rc73.ko`＝`34b3efa8…`＋`kmod/ksu_args.txt`＝`67199f48…`未变。机器 `Enforcing mod=0`、boot_id `95faa669`、**10-24 枪数＝1**。\n\n"
          "## ★★★★★★★★★★★★★★★★★★ 2026-10-24 12:1x 更新（本节最新，取代 10-22 那节）" % (PLAN, H["kmod/w690_ksubirth.sh"], H["kmod/w694_ringwitness.sh"], SWP)))

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
print("=== w707 完成：总闸现值=%s／判据件现值=%s ===" % (SWP, PLAN))
