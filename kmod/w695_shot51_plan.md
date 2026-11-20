# w695 —— 第 51 发（rc74b：真去重＋只认主进程）开枪前写死的判据与形状

★规矩照旧（§6.198 之后一直用）：判据在开枪**之前**写死；跑完只往本文件追加"读数"，不改判据。
上一发（第 50 发＝rc74）的判据与读数在 `kmod/w686_shot50_plan.md`——**机制已判正**，那一发抓到的是**实现缺陷**。

## 形状（一句话）
**唯一变量＝ko**：`KO=kmod/kernelsu_rc74b.ko`（＝rc73 ＋ 修正过的"出生即装"那一段），其余逐字同交付默认
（`kmod/ksu_args.txt` `67199f48` 五条参数不动 ＋ 装载后写回 6 条 CFI 桩 ＋ 单条目名单 ＋ 零实验开关）。
跑法＝`KO=kmod/kernelsu_rc74b.ko I_KNOW=1 bash kmod/go.sh`（PC 编排那条，**不是**包那条）。

## 这一发在验什么（跟第 50 发不一样的地方，说清楚）
rc74 已经把"牌子能不能自己亮"判正了 ⇒ 那一条**再验一次当复现**；这一发的**新增信息量在缺陷有没有修掉**：
去重是不是真的（一个进程只排一次）、装进去的是不是只有主进程、驱动 fd 有没有泄漏。
★**这发不打包**（两个变量混一发＝红了说不出是谁造成的，§6.140 那一族）。代价照旧要说清：**这条路要两发**
（51 验 rc74b；它赢了 52 才是 #178"当前版包真机一键认证"，且要连 ko 一起认）。

## 判据（九条，缺一条就算这发没做完）
1. `push_ksu.sh` 回执 `ok kernelsu.ko 18750560…` ＋ `ok ksu_args.txt 67199f48…`（参数上机只认这两条 md5）。
2. `insmod rc=0` ＋ `lsmod=[kernelsu …]` ＋那一刻的 `up=`（＝开窗）。
3. ★**去重正证（这一发的主判据）**：从装载期全量件（`/data/local/tmp/dmesg.live`，先打印它的覆盖区间）里数
   `KSUBIRTH queued self fd pid=X` ⇒ **每个 X 恰好出现 1 次**；把逐 pid 计数打进存证（`w690_ksubirth.sh` 第①组已带这张表）。
   判负口径：出现 ≥2 次＝去重还是没生效 ⇒ 这发直接算失败，**不许**用"机子没炸"抵。
4. ★**挡住的分支有证人（不打印的那两条靠限流计数）**：至少一条 `KSUBIRTH dupskip n=`（＝同一进程后续 syscall 被挡住）；
   重启 Manager 之后至少一条 `KSUBIRTH childskip n=`（＝它 fork 的 `sh`/`id`/`libksud.so` 被挡住）。
   ★若两条都是 0：**先查覆盖区间**（读的是活环还是装载期全量件）⇒ 覆盖不到就记**未测**，不记"没生效"（§6.414 仪器教训②）。
5. ★**没有 fd 泄漏（第 50 发那条曲线的反面）**：root 读回 `ls -l /proc/<Manager 主进程>/fd | grep -c ksu_driver`
   ⇒ 期望 **≤2**（第 50 发同位置是 14→68→**75**）；并且再 force-stop→`am start` 一轮之后复读，仍 ≤4。
6. **只认主进程**：`queued self fd` 里出现的每个 pid 都必须是 `pidof me.weishu.kernelsu` 里的那个主进程 pid
   （子进程出现在这里＝谓词没收窄成功）。
7. **机制复现（第 50 发那一格）**：`am force-stop me.weishu.kernelsu` → **只用 `am start`**（不写触发口、不跑 w625、不发深链）
   ⇒ 首页 `工作中／版本：32601-2`；读之前**必须断言焦点在 Manager**，被弹窗/通知栏挡住就记未测（第 50 发现场两次）。
   负对照来自第 49 发的 `D1` 格（无生产者重开 ⇒ `不支持`）＋第 50 发读数——**一 boot 换不了 ko，别假装这发内有对照**。
8. **稳定性/护栏**（三条都数并写进存证）：`KSUBIRTH kzalloc(ATOMIC) failed`＝0、`KSUBIRTH task_work_add … rc=`＝0、
   `KSUFDINST NULLFILES skip`＝0、`received signal 6`＝0、boot_id 与 `up=` 连续（整机不许复位）。
   ★`ksu_mgr_birth_cap` 默认 64 是兜底闸：如果这发看到 `KSUBIRTH cap total=` 出现＝有东西在疯排 ⇒ **判负**，别当成"兜底生效所以没事"。
9. **顺手再收一枚 #178 的形状**（不额外烧枪）：判据 7 之后立刻连敲两次恢复腿 ⇒ 第 2 次必须 `SR-ALREADY` 且 `pidof` 一字不变。

## 收尾（顺序不能换）
所有要 root 的腿排在 `w426_enforce.sh` 之前；`T3`/`w165b_adb_clean` 删净脚印（★注意 §6.414 那条：**teardown 的 90 条名单不含 `w625_lock`**，
那件在 `w558_rm3.sh` 的 151 条里 ⇒ 收尾后要独立 `ls` 复证一次，缺了就 shell 侧补删——它是 `shell_data_file`，shell 删得动）；
`/data/adb` 复证 `[. ..]`；最后 reboot。**开工前**把这一发要用的每条腿重推＋chmod＋设备 `sh -n`＋两端 md5
（§6.414：上一发我自己把 `w690/w694` 的设备副本删了，现值 `w690_ksubirth.sh`＝`95706ae8`、`w694_ringwitness.sh`＝`a28f199a`）。
★**不许**碰 `ksu_fd_keepalive`（§6.400 判死）。

## 已知风险（开枪前就认）
- 这发**只可能比 rc74 更保守**：多出来的运行期成本是"每 256 次挡印一条"＋一个自旋锁临界区；真正的未知还是"给全机每条 syscall 加的那次读参数"要不要命（§6.118 那次整机复位就是打印洪灾）。
- 如果判据 3 过了但判据 7 暗了：先查是不是**子进程被挡得太狠**（官方 Manager 的 `:root`/`libksud.so` 在本机每次 abort，§6.409；那跟"主进程有没有 fd"是两件事，别把它们混成一条结论）。
- 如果 `dupskip`/`childskip` 两条证人都是 0 而覆盖区间确实含装载时刻：说明谓词在**第一次**就把进程挡在外面（`total` 不涨）⇒
  去看 `KSUBIRTH seen Manager` 有没有；一条都没有 ⇒ 按第 50 发的分家法先查 `ksu_manager_appid` 那行，**别先怀疑我那段代码**。

## 读数（跑完再写）

### 判 51 总结论(先给一句话)
**去重这条主判据判正**——一 boot 内 11 个被排队的 pid **每个恰好 1 次**，长活主进程 `fd_ksu=1`、二轮 `=2`（第 50 发同位置 14→68→75）；
**判据 6 按字面判负、按性质判正**：被排队的不止"Manager 主进程"，还有同 uid(10104) 的 `usap64`/`crash_dump64`/`libksud.so`
——而 **主进程那条 fd 恰恰是在它还叫 `usap64` 时装进去的**（下面 ⑥/⑦ 有原样行）。⇒ 机制成立，"只认主进程"这句我写窄了，
真性质是"只认 Manager uid 的线程组领头"。另抓到一条**新的、可量化的兜底风险**：`cap=64` 会被 Manager 崩溃风暴吃（实测 14 次/1842 秒）。

### 逐条读数
1. `push_ksu.sh`：`ok kernelsu.ko 1875056003135b3323a2cc7a152b5e41` ＋ `ok ksu_args.txt 67199f48…`（存证 `w711_go_shot51.log`）。**判正**。
2. `[16:42:59] insmod rc=0 up=1993.48 lsmod=[kernelsu 204800 0]`，`GO_RC=0`，boot_id `12afb83f-…5298`，起窗 enf=Permissive。**判正**。
3. ★主判据：**每个 pid 恰好排队 1 次**（两份件分开数，都算）
   - 装载期全量件 `dmesg.live`（内容覆盖 **up=1261→2279**，含 insmod 的 1993.48；离线件 `w717_dmesg_live_shot51.log`，
     解析 `w719_ring_reconcile_shot51.txt`）：`queued self fd` 4 条 = pid 24511(`libksud.so`) / 24545 / 24561(`crash_dump64`) / 24563，
     `total=` 依次 3,4,6,7；逐 pid 计数全 =1。
   - 当前环两次快照（`w720_lines_1.txt` 覆盖 3412→3771；`w724_lines_2.txt` 覆盖 3852→4180）：`queued` 7 条 =
     pid 21205(`usap64`,total=15) / 22211 / 22238 / 22250(`crash_dump64`) / 22213 / 22240 / 22253(`libksud.so`)，逐 pid 仍全 =1，
     每条后面都跟一条 `=> fd=`(8 条回调)。
   - 老主进程 pid 14230 只有 `dupskip`(25 条，n 从 4097 起) ⇒ 它的 `queued` 行被采集通道丢了（同件里 `seen`=1 vs `queued`=4 就是丢行的直接显示），
     但 **dupskip 需要环里已有它** ⇒ 它确实被排过且只排过一次。
   **判正**（第 50 发那条"同一 pid 反复排队"的曲线在这发一次都没复现）。
4. 挡住的分支都有证人：`dupskip` 最大 **n=78849**（pid 525/14230/21205 都见过），`childskip` 最大 **n=32257** 且样本里
   `pid=22203 comm=[libksud.so]`、`pid=22208 comm=[crash_dump64]` 被"Manager 自己 fork 的"这一支挡住 ⇒ 收窄确实在踢。
   覆盖区间含装载时刻，**不是未测**。**判正**。
5. 无 fd 泄漏：pid 525(单生产者、窗内活的长命主进程) **`fd_ksu=1`**(27)；第二轮 force-stop→起→腿之后 pid 21205 **`fd_ksu=2`**(27 出生＋80 腿写)。
   **判正**（判据写的 ≤2 / 再一轮 ≤4 都满足）。
6. ★**按字面判负**：`queued` 的 comm 只有 21205 那条最终属于主进程，且它排队时 comm 还是 **`usap64`**；其余是 `crash_dump64`/`libksud.so`。
   共同点＝`seen Manager` 行的 `uid=10104` 全对 ⇒ **性质是"Manager uid 的线程组领头"**，不是"Manager 主进程"。
   危害实测＝每个只拿 1 条 fd、都是短命进程、`NULLFILES skip`=0、`signal 6`=0；**真风险是 cap**（见 ⑧）。
7. 机制复现：**判正**——pid 525 那一格是干净格（`am force-stop`→**只用 `am start`**，不写触发口、不跑腿、不发深链）
   ⇒ `工作中／版本：32601-2／越狱／页签 4`，读之前焦点断言在 `me.weishu.kernelsu/.ui.MainActivity`。
   pid 21205 那格(⑨ 的第 1 敲)也算亮，但**有两个生产者**(出生即装＋腿写口) ⇒ 只当交付形状看，不当天花板。
8. 稳定性：`kzalloc(ATOMIC) failed`=0、`task_work_add rc=`=0、`NULLFILES skip`=0、`received signal 6`=0、`Service 'zygote'` 行=0、
   boot_id 全程 `12afb83f` 不变；**窗内活到 insmod+2907 秒**(≈48.5 分钟，本战线最长)。
   ★`KSUBIRTH cap`=0 但这发量到了消费的**速度**：`total` 从 7(2012 秒)涨到 21(3854 秒)＝14 次/1842 秒(≈0.45/分钟)，
   且 **一次 Manager 重启的当口 0.37 秒内吃 6 次**(3×crash_dump64＋3×libksud.so，§6.409 那支崩溃风暴)。按这速率 cap=64 约 2.4 小时见底
   ⇒ 之后本 boot 不再出生即装(腿那条路仍然能用)。**这条要单独决定，别当"兜底生效所以没事"。**
9. ★SR 形状第二枚(真形状非夹具)：第 1 敲 `SR-ROUND r=1 pid=21205 fd=2`、**0 拍**就命中(说明 fd 早就在表里＝出生即装的功劳)；
   第 2 敲 `SR-ALREADY pid=21205 fd=2 coolup=3854 now=3882`，`pidof` 前后**一字不变**(21205)。两条腿输出各自单独存证
   (`w721_c9_tap1.txt`/`w722_c9_tap2.txt`)——因为这条腿的产物名是固定的，第二敲会覆盖第一敲。

### 收尾（顺序照 §6.414 那条改过）
`w165b_adb_clean.sh`(root)：`/data/adb` `[. .. .suwtest ksu ksud]`→**`[. ..]`**(腿自己 `ls -laR` 回读，`w725_t1_adb_clean.txt`)
→ `w558_rm3.sh`(root，**现值 e2314525＝151 条**；设备上当刻那份还是旧的 `9860c9ce`，重推后跑) ⇒ 独立状态回读
`dmesg.live/kernelsu.ko/w625_lock/w625_seedrestart.out/a_10342.bin/app_ksu.txt` 全"不在"
→ shell 侧补删这一发新名字的 10 件脚印(`w715/w716/w720_*/w723.xml/w690_*.out/w694_*.out/w664_*.out`)＋`ls` 复证
   ⇒ 名单里只剩 5 件**工具腿**(`w625/w664/w690/w694/w720 .sh`)，符合"工具件不进清理名单"
→ `w426_enforce.sh`(root)：第 2 次轮询 `enforce=1`＋`getenforce=Enforcing` ⇒ **恢复执法排在所有 root 腿之后，做到了**
→ `adb reboot`：新 boot_id `ccde849f`、`mod=0`、`bind(/product/bin)=0`、Enforcing、开机 54 秒即可读。
   ★`persist.sys.boot.reason.history` 最新一条＝`reboot,shell,1792834324`(换成设备钟正是我们敲的那刻)，
   而 `ro.boot.bootreason` 报 `HARD_RESET/PS_HOLD/NONE+NONE` ⇒ 又一次当场兑现"bootreason 分不了收尾 vs 异常复位"，
   所以这发的"没有意外复位"押的是**同 boot 的 boot_id 连续＋history 那条带时刻的 `reboot,shell`**，不押 bootreason。

### 仪器条目（这一发的四条，都进 例 176 那一族）
1. **我又拿 `/system/bin/su` 从 adb 侧当 root 通道**(两次 RC=127/`inaccessible or not found`)——那条路只对 **app 域＋Permissive** 成立，
   shell 域改道根本不生效。PC 侧的 root 腿只有一个口径：**`bash kmod/w211_ui.sh rleg <脚本名>`**(suw 通道)。
2. **重推没 chmod** ⇒ 腿被派下去但 `exit=126`(sushd.log 写得清清楚楚：72 字节输出/exit=126)。
   §6.414 那条"重推＋chmod＋设备 `sh -n`＋两端 md5"我又只做了后两件——**这条要当硬闸做，不是清单尾巴**。
3. **覆盖区间用行首正则算＝假否据**：`dmesg.live` 的行是 `<6>[ 2012…]` 形状(优先级前缀)，我第一次按 `^\[` 只数到 1899/19591 行，
   于是把覆盖读成"2266→2279"(13 秒)，差点判成"装载期不在覆盖内"；改成行内搜索后真覆盖 **1261→2279**。同 例 170 那一族。
4. **同一件腿的产物名固定 ⇒ 第二次调用覆盖第一次**（⑨ 两敲必须一敲一拉）。这次靠"每次 pull 完再敲"避开，
   写进判据而不是靠我记得。
