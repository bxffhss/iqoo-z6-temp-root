# w796 —— 第 55 发（10-25 05:0x–）判据（**开枪前写死**）：认证「新打的这份包」＋维持件第二态＋包内收尾腿修正版

> 一件要说在前面：**这份包换了**。本发跑的是刚重打的 `z6root.zip`＝`ee2bbdc9…`（上一份认证过的是 `24664916…`）。
> 跑成 ⇒ 交付默认跟着换到这一份，并按 #152 的规矩写清"认证过的是哪一份"；跑红 ⇒ 形状问题，不猜环境。
> 本轮 0 枪已改的三处：①入口件 `chmod 755` 改成**从 MANIFEST 现数**（一手：上一版被写成引号粘连 ⇒ keeper／`w135_fix.sh`／`w450_close.sh` **三只没拿到 x 位**，而 `2>/dev/null` 把失败咽掉了）；②包内收尾腿 `w450_close.sh` 加了 kill switch 先删＋**挂载行没收回就不许删源**＋产物权限排在第一行读数之前；③教程第 7 条补了三句新形状的读数口径。忠实性闸 **76 项全绿**（含三把新反夹具）。

## 甲组＝这份包的形状（沿用第 53 发七条 ＋ 本发新增 x 位那一格）

1. 设备侧一条命令 `/system/bin/sh /sdcard/z6root/z6root.sh` 跑到最后一行 `=== Z6ROOT_DONE … mod=1`。
2. `入口形状=1`（名单在装载那一刻写好，免 UI、免 suw）。
3. 活表读数 `count=1 uid=<现取> granted=1`；uid 一律 `pm list packages -U` 现取，别抄台账值。
4. 载荷两端各核：`MANIFEST` 逐条 md5 ＋ 包内 `kernelsu.ko`＝`18750560…`（与打包器映射的源件逐字节同一份）；args 读回＝`67199f48…`。
5. root-only bind 起来：`NOSUW_BIND_RC=0`、mountinfo 源＝`/adb/ksu/pbin`（**不许出现 `//deleted`**）、`/product/bin/su` 在、维持件在跑（`w774_keeper.log` 每 20 秒一行）。
6. ★**本发新增（x 位的活证人）**：入口件那行 `chmod 的 .sh 件=[N 条清单命中] 实到=[…]` 必须把清单里每条 `.sh` 都列出来；
   随后**真打字 exec 一条包内 .sh 腿**（用只读的 `selfcheck`，不碰 /proc）：`su -c /data/local/tmp/w774_pbin_keeper.sh selfcheck`
   ⇒ 期望看到它自己打的 `PASS`，**不是 `exit=126`**。判据是"跑起来了并输出形状"，不是"rc=0"。
7. 牌子读数（焦点 OK 的格子才算）＝`工作中／32601-2／越狱有`。

## 乙组＝#188：维持件的第二态（源还在、只是被 umount）

8. 派 `su -c /data/local/tmp/w797_umount_only.sh`（无参数，只 umount、**不碰源**）⇒ 一手序列要同时看到：
   `umount rc1/rc2` 之后**挂载行=0**、`/product/bin/su 没了`、**`源内文件` 仍 ≥1**（源还在＝这一态成立的前提）；
   然后 ≤20–25 秒（一个维持节拍）`su` 回来，keeper 日志出现 `重建#1` → `修好了`、`GIVEUP=0`；
   ★两条独立证人：①复挂后 mountinfo 那行的源仍是 `/adb/ksu/pbin` 且**没有** `//deleted`；②随后再打一条 root 腿仍 `uid=0`。
   ★仪器自约束：如果挂载**没**收回，这一格按**未测**记（w797 自己 `exit 5` 并明写），不许算成维持件失败。

## 丙组＝#187A：包内那条收尾腿（修正版）第一次上机

9. 收尾**用包内那一条**：`su -c /data/local/tmp/w450_close.sh` ⇒ 判据三条并列：
   ①产物 `/sdcard/w450_close.txt` **PC 侧能 `adb pull` 读回**（这一条就是"权限排在执法之前"那处缺陷的直接证人；读不到＝丙组判负）；
   ②里面齐这七个键：`killswitch_rm_rc=0`／`KEEPER_LEFT=退了`／`umount_rc=0`／`MOUNT_LEFT=0`／`rm_allow_rc=0`／`ALLOW_LEFT=[…No such file…]`／`rm_pbin_src_rc=0`；
   ③`清之后 /data/adb=[…]` 不含 `ksu`（★第 54 发挂成"未查"的那格，这发要能复证）。
   ★只读判据：维持件是否真退了，只认**独立读数**（`ps -A` 里没有那条 `sh w774_pbin_keeper.sh`），不许拿 `pgrep -f w774` 的命中当凭据——它会命中我自己的命令行（第 54 发一手）。
10. 收尾之后按铁律：恢复执法排**最后**（root 腿全做完），再 `adb reboot`；复位后独立读回 `Enforcing`／`mod=0`／pbin 挂载行=0／`/product/bin` 无 `su`／reason 里有 `reboot,shell`。

## 不许顺手做 ＆ 代价

- 不许：抬 cap（**#185 已出局**，本窗只用到 7/64、`cap`=0）、`NOBIND=1`（#182：Manager 自己的 su 没落点）、`ksu_fd_keepalive`（§6.400 会把 zygote 打进 SIGABRT）、动 seccomp（#110）。
- 代价：1 boot 只 1 枪；这一发同时验三件（包／维持件第二态／收尾腿），任何一件红都如实登记成"未测/判负"，不许用别的件的绿灯顶替。
- 收尾不许留窗口过夜：丙组跑完立刻执法＋reboot。

---

# 读数（开枪后填，10-25 11:0x–11:2x）

**先记一句我自己的仪器错**：10:46 我第一次把这条一键**打进了 Termux** ⇒ 它在第 0 步就被自己的铁律闸拦下（`grep: /proc/modules: Permission denied`，Termux 是 app 域，读不动 /proc 也写不动 /data/local/tmp）。
**那一枪没打出去**（`mod=0`、什么都没装载），所以本 boot 的配额还在；但拦下来的**文案是假的**——它把"空读数"报成"本 boot 已经有 kernelsu 模块"。⇒ 已修成分三支（0／非数字＝宿主不对／其余＝真已装载），并进了闸（run_z6pack ⑭a/⑭b/⑭c）。教程第 4 条也改写成"宿主必须是 uid=2000 的 shell"。

## 甲组＝这份新包（`z6root.zip`＝`7c8b32da…`）＝**五条直证、两条未测**

| # | 判据 | 读数 |
|---|---|---|
| ① | 一键跑到 `Z6ROOT_DONE` | ✅ `=== Z6ROOT_DONE up=23971.79 mod=1 enforce=Permissive ===`（第 425 秒等到判据⑥） |
| ② | `入口形状=1` | ✅ `入口形状=1（1=免 suw/免界面）目标包=com.termux 现取 uid=10667` |
| ③ | 活表 | ✅ `allowlist: NEW_GET_ALLOW_LIST rc=0 count=1 total=1`＋`allow[0] uid=10667`＋`granted[10667] UID_GRANTED_ROOT rc=0 granted=1` |
| ④ | 载荷两端各核 | ✅ MANIFEST 22 条逐条 `ok <名> <md5>`；`/sdcard/z6root/z6root.sh`＝`adff3707…`、`教程.txt`＝`c7cfb68b…` 与仓内同一份；args 读回＝`67199f48…`（登记值） |
| ⑤ | root-only bind | ✅ `前置闸一：pbin 行数=0`、`NOSUW_BIND_RC=0`、`NOSUW_CP_N=4 NOSUW_HEALTH=OK`、mountinfo 源=`/adb/ksu/pbin`（**无 `//deleted`**）、`/product/bin/su`＝`-rwxr-xr-x root root 2241944 11:05`、keeper 在跑（`第 29 轮：好(su 在，deleted行=0 源内文件=4)`） |
| ⑥ | ★x 位的**活**证人 | ❌ **未测**——窗口在能派打字腿之前就复位了。只有静态证人（入口件那行 `chmod 的 .sh 件=[7 条清单命中] 实到=[ ksu_post.sh w135_fix.sh slide_solve.sh w450_close.sh w625_seedrestart.sh w774_pbin_keeper.sh z6root.sh ]` ＋ 落点文件本身带 x 位）；**"execve 真能起来"这一格不许拿静态证人顶替** |
| ⑦ | 牌子 | ❌ **未读到**：`w745` 第一次 `adb shell` 就报 `no devices` ⇒ 那一刻设备已经掉了 |

## 乙组（#188 只 umount 那一态）＝**未测**；丙组（#187 包内收尾腿）＝**未测**

两条都要靠 root 打字腿，窗口没活到那时候。**不许把"没跑到"写成"跑输了"**——这一发对 #188/#187 的结论是零。

## ★这一发真正拿到的新东西：窗口在 insmod+≈635 秒被 `HARD_RESET/PS_HOLD` 打断，死前 100 秒出生风暴化

- 时刻（全部同源，设备钟）：insmod≈`11:05:0x`（stage `11:05:01` 实参行／`11:05:03` allowlist 行）→ keeper 最后一轮 `11:14:50 up=24531.68` → 环里最后一次写 `11:15:09.45 up=24550.48` → 新 boot 起来 `11:15:41`（现在 `11:23:09 up=448.28` 反推）。**⇒ 寿命 ≈ 10 分 35 秒，复位空档 ≈ 32 秒。**
- 死因**没有**证人：环只覆盖最后 **100 秒**（因为 KSUBEAT 打到 **127.8 行/秒**），里面没有 panic/hung_task/RCU 行。
  ★那 10 处 `PS_HOLD` **不是**死因打印，是 `cms_v5: check_uvlo_trigger: pon=HARD_RESET, poff=PS_HOLD` 每 11 秒一次的**状态行**（它内嵌的是 **UTC**，比设备钟早 8 小时——第一次看到会误以为"三点的日志"）。死因只由 `ro.boot.bootreason=HARD_RESET/PS_HOLD/0x01+0x01` ＋ history 里 `hard,1792898156` 定性。
- 与第 54 发（同一支 ko、同一 args、活到 insmod+2633 秒）的**同口径对比**（都按"环覆盖段内"数）：

  | | 覆盖 | KSUBEAT | KSUBIRTH | queued | `total` 最大 | `dupskip n` 最大 | `crash_dump64` 引用 |
  |---|---|---|---|---|---|---|---|
  | 第 54 发（活） | 1684 s | 43,433＝**25.8/s** | 45 | 3 | **7**／64 | 10,241 | 7 |
  | 第 55 发（死前 100 s） | 100 s | 12,783＝**127.8/s** | 396 | 9 | **25**／64 | **177,921** | 28 |

  死前的 `queued self fd` 两行 `comm=[crash_dump64]`、`comm=[libksud.so]` ⇒ **出生检查被大量进程创建反复命中**，而 `crash_dump64` 的出现说明同期有进程在反复崩溃（环里没有 `Fatal signal` 行，logcat 不活过重启 ⇒ 这条只能算"有崩溃活动"，不能算"谁崩"）。
- **口径要收住**：这**不是**"证明出生安装杀死了窗口"。能说的是：①同一支 ko 在两扇窗里的行为差 5–17 倍；②`cap` 仍然一次没踢（`cap`=0 行，`total` 才 25/64）；③`dupskip` 那个计数器已经数到 17 万，说明**被调用**的次数远超"Manager 出生"这件事本身。§6.198 那条"fork-exec 风暴 → PS_HOLD"是同类形状，但那一次的storm是**我们自己的 root sh** 造的，这一次我在 insmod 之后**一条 root 腿都没派**、只做了几次 shell 侧只读。
- ★顺带一条仪器事实（下次别再被骗）：`ps -A` **看不到**维持件（它的 `comm` 是 `sh`，脚本名不在列里），所以"keeper 在不在"只认**它自己的日志有没有在推进**（本发 29 轮×20 秒连续在写＝在跑）。`pgrep -f w774` 还会命中我自己那条命令行（第 54 发一手）。

## 这一发的账 ＆ 下一步

- **判正**：甲组①②③④⑤（这份新包的一键链在设备侧真跑通，root-only 源＋维持件＋bind＋活表授权全部到位）。
- **未测**：甲组⑥（x 位活证人）、⑦（牌子）、乙组（#188）、丙组（#187）——**四格全空**，都卡在窗口寿命上。
- **新立的问题（优先级排在 #188/#187 之前）**：**"窗口为什么会在一扇 10 分钟的窗里 PS_HOLD"**——这是"长期存在"目标里比牌子更硬的一层。设计成单变量：下一发**开窗后什么都不派、不点 UI、不起打字腿**，只让包自带的 stage/keeper 自己跑，然后看寿命与那三计数（KSUBEAT/s、`dupskip n`、`total`）。如果空窗也死在 ~10 分钟 ⇒ 是我们 ko 的**被动成本**（tracepoint 上被调太多次＋打印洪水）；如果空窗活过 30 分钟 ⇒ 死因在本发派出去的那些动作里。
- **交付口径**：本发跑的 `7c8b32da…` **不算认证完成**（甲组 2/7 未测、且没跑到收尾）⇒ 默认仍是第 53 发认证过的那一份；那份的**字节在仓里已被重打包覆盖**，但设备侧留了完整快照 `/sdcard/z6root_shot54_24664916`（23 件）。★下一发要么把新包跑到七条齐＋收尾复证，要么把默认重新指回快照那一份。

