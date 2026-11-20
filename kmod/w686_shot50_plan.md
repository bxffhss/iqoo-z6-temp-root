# w686 —— 第 50 发（rc74「Manager 出生即装 fd」）开枪前写死的判据与形状

★规矩：判据在开枪**之前**写死（§6.198 之后一直在用这一套）；跑完只往本文件追加"读数"，不改判据。

## 形状（一句话）
**唯一变量＝ko**：`KO=kmod/kernelsu_rc74.ko`（rc73 + 出生即装那一小段），其余逐字同交付默认
（`kmod/ksu_args.txt` `67199f48` 五条参数不动 ＋ 装载后写回 6 条 CFI 桩 ＋ quiet ＋ 单条目名单）。
跑法＝`I_KNOW=1 bash kmod/go.sh`（PC 编排那条），**不是**包那条。

## 为什么这一发不打包
- 包那条的判据(#178)与 ko 那条的判据(#179)是两个变量混在一发里 ⇒ 红了说不出是谁造成的（§6.140 那族教训）。
- 代价写清：**要两发**（第 50 发验 rc74；它赢了之后第 51 发才是"当前版包的真机一键认证"）。
  如果只给一发，就先打第 51 发那套（包＋rc73 已换默认）而不是这一发——由用户定。

## 判据（八条，缺一条就算这发没做完）
1. `push_ksu.sh` 回执 `ok kernelsu.ko <rc74 的 md5>` 与 `ok ksu_args.txt 67199f48…`（参数是否上机只认这两条 md5）。
2. `insmod rc=0` ＋ `lsmod=[kernelsu …]` ＋ 那一刻的 `up=`（装载成功＝开窗）。
3. **内核证人（这条是这发的主判据）**：dmesg 里出现
   `KSUBIRTH seen Manager pid=… uid=… start=…` → `KSUBIRTH queued self fd pid=… queued=N` →
   `KSUFDINST 回调跑在 pid=… comm=[…] 里 => fd=<非负数>`，三条同 pid、时刻递增。
4. **不跑任何腿、不重 punch**：Manager 首页 = 「工作中」＋`版本：32601-2`（w603_home_cell.sh：先断言焦点在被测 app，再读无障碍树＋截图）。
5. **出生即装的正证（与 §6.406/§6.407 的旧读数正好相反）**：`am force-stop me.weishu.kernelsu` →
   只用 `am start` 把它重新起来（**不写 /proc/ksu_install_fd、不跑 w625**）→ 首页**仍然亮**，且 dmesg 里出现**第二个**新 pid 的那三条 KSUBIRTH/KSUFDINST 行。
   （rc73 在这一格必须暗——一手 §6.407。所以这一格正反都成立才算证到。）
6. 第三条独立证人：root 侧 `ls -l /proc/<新 pid>/fd` 里读回 `anon_inode:[ksu_driver]`（屏幕与 dmesg 之外再一条）。
7. 稳定性/护栏监控（三条都数并写进存证）：`KSUFDINST NULLFILES skip` 次数；`init: Service 'zygote' … signal 6`；
   整机有没有复位（对比 boot_id 与 `up=` 连续性）。**不许**碰 `ksu_fd_keepalive`（§6.400 判死）。
8. 那条恢复腿的闸在真形状里的第一枚（#178 欠的那格）：在 5 之后**立刻**再敲一次
   `/system/bin/su -c /data/local/tmp/w625_seedrestart.sh` ⇒ 期望打 `SR-ALREADY`（当前 pid 就是刚被种过的那个）
   且**不 force-stop**（`pidof` 在前后一字不变）。

## 收尾（顺序不能换）
所有要 root 的腿排在 `w426_enforce.sh` 之前；`T3`/`w165b_adb_clean` 删净脚印；`/data/adb` 复证 `[. ..]`；
最后 reboot（临时 root 不持久）。工具件不进清理名单（KEEP 硬闸）。

## 已知风险（开枪前就认）
- 这段代码在**全机每条 syscall** 的入口上跑：谓词只有三次比较（主线程／appid／pid+start_time 是否已排过），
  分配只有 `GFP_ATOMIC`。真崩了会表现为一开机就复位 ⇒ 判据 3/7 会把它抓到，代价是这一发白烧。
- 构建机闸门已经拦过一次：`__param`/`__versions`/未定义引用三条对 rc73 现比，不同就停（§6.412 那四条离线核）。
- 若 KSUBIRTH 一条都不出：先怀疑 `ksu_manager_appid` 还没被加冕设上（谓词要求 `ksu_is_manager_appid_valid()`），
  读 `dmesg` 里 `ksu_manager_appid set to` / `Crowning manager` 那行来分家，**别**先怀疑我那段代码。

## 读数（跑完再写，别回头改判据）

## ★开枪前修正（10-24 13:1x，两条——都在开枪**之前**改，跑完不再动判据）
- **修正 A（判据 8 的形状改了，因为它结构上拍不到）**：`SR-ALREADY` 的谓词是"当前活着的 Manager 的 pid ＝**锁文件里那条腿自己种过 fd 的 pid**"。
  而 rc74 的整条卖点是**根本不需要腿** ⇒ 这一 boot 没人写 `/data/local/tmp/w625_lock`（设备现值：`ls` 里没有这个文件，一手 13:1x 只读检查），
  拿不到 `pid=` 就永远走不到 `SR-ALREADY` 这一支。**⇒ 这一格改成"连打两次"**：第 1 次是真做（它自己 force-stop→起进程→写触发口→落锁），
  第 2 次**立刻**再敲 ⇒ 期望 `SR-ALREADY` 且 `pidof` 前后一字不变。
  ★代价与边界写清：第 1 次那一格**不算** #178 原来要的那枚"牌子亮着时第二条被挡"（那是"腿没跑过、牌子由内核点亮"的形状，
  在 rc74 下要靠锁文件被内核侧写入才有证人，而我没打算为它改腿的形状）——所以 #178 那一枚**仍然欠着**，这发只收"闸在真形状里会拒第二次"。
- **修正 B（判据 7 加一条这发特有的新风险）**：除了 `NULLFILES skip`／`signal 6`／boot_id＋uptime 连续性，还数
  **`KSUBIRTH kzalloc(ATOMIC) failed`**——`task_work` 那个 `cb` 只能在关抢占上下文里 `GFP_ATOMIC` 分配，这条计数就是"这段代码在真机上有没有排队失败"的直接读数（ko 串表一手：这条打印就在产物里）。
  一并数 `KSUBIRTH task_work_add pid`（排队失败 rc）与 `=> fd=`（回调真跑），三对不齐就要说"排了没跑"还是"跑了没排"。
- **仪器与前置闸（已跑完，13:14）**：`kmod/w690_ksubirth.sh`＝`06745674`（六组读数：KSUBIRTH 四支各自计数／KSUFDINST 三段／加冕行／Manager 表里的 `anon_inode:[ksu_driver]`／**别的生产者还活着没有**／signal 6＋uptime）——
  设备 mksh `sh -n` rc=0、两端 md5 一致、755；`kmod/w625_seedrestart.sh`＝`72d001c1` 同（重推＋`.out` 已清，例 168 那条规矩）。
  ★匹配式一律 ASCII：环境记忆第一条（toybox grep 对 CJK 与 `\|` 不可靠），所以"已排队"取其兄弟行 `queued self fd`、"回调跑在"取 `=> fd=`。
- **起点读数（13:1x 只读，开枪前）**：`Enforcing`、`mod=0`、`/proc/ksu_install_fd` 不存在、`boot_id=b942e965`；
  uid 现取＝Termux `10667`／Manager `10104`／suw `10342`；`/data/local/tmp/` 里有上一 boot（§6.409 那次）留下的 `ksu_race_fd`、`dmesg.live`、`dmesg2.log`、`w625_seedrestart.out`，**没有** `w625_lock`。
  ⇒ 判据 5/6 之前必须先过 w690 的第⑤组：**RACE 看门狗（装载期抢装那条）必须已经不在**，否则"牌子亮了"不能算 rc74 的功劳。
（待填）

## ★读数（第 50 发，10-24 13:17–13:58，1 枪，boot_id `7a331af0`→收尾 reboot 后 `95faa669`；判据一条没改，只往下写）
**总判定：机制判正（牌子能自己亮回来），但这一支 ko 不许升默认——同发抓到"去重失效⇒驱动 fd 泄漏"。**

| 判据 | 读数 | 判定 |
|---|---|---|
| ① 装载门径 md5 | `ok kernelsu.ko 6ef4cbead8f17acfc5de685ca83821d6`＋`ok ksu_args.txt 67199f4898c98371aa3ad0ef6f649e89`（13:17 push 回执） | **正** |
| ② 装载成功 | `[13:30:06] insmod rc=0 up=728.15 lsmod=[kernelsu 200704 0]`；`GO_RC=0`；其余开关全未给＝交付形状逐字不变 | **正** |
| ③ 内核三件套（主判据） | `dmesg.live`（覆盖 `--- HB up=726.43 ---` →末行 `[1014.71]`，**含装载期**）：`[746.590109] KSUBIRTH seen Manager pid=14302 uid=10104 start=85943585747` → `[746.590119] queued self fd … queued=3` → `[746.666145] KSUFDINST 回调跑在 pid=14302 comm=[weishu.kernelsu] 里 => fd=93`；同发另有 `pid=21682 comm=[libksud.so] => fd=4/6` | **正** |
| ④ 开窗后不跑腿牌子就亮 | 前两次读数**焦点不在 Manager**（`mCurrentFocus=NotificationShade`／`VivoUsbDialog`）⇒ 按**未测**算，没当负读数；清掉弹窗后 `C4c`＝`状态=工作中 版本=32601-2 越狱串=越狱 页签=4`，pid=**14302 从未重启** | **正**（含两格未测） |
| ⑤ 出生即装的正证（关键格） | `am force-stop`→pidof 空→**只用 `am start`**（不写触发口、不跑 w625、不发深链）→ `C5_birthonly`＝`工作中／32601-2／越狱／页签=4`（pid=3560）；内核侧那 10 秒里 `seen Manager=149 / queued self fd=149 / => fd=149`，三件套同 pid 时刻递增。**负对照＝第 49 发同 boot 的 `D1` 格（无生产者重开 ⇒ `不支持`）**——一 boot 换不了 ko，所以对照来自上一发 | **正** |
| ⑥ 第三条独立证人 | root 侧 `ls -l /proc/3560/fd` 里逐条 `anon_inode:[ksu_driver]`（`fd_ksu=68`→后来 75） | **正**（但同时就是下面那条缺陷的量化凭据） |
| ⑦ 稳定性 | `KSUBIRTH kzalloc(ATOMIC) failed`＝**0**、`task_work_add rc`＝0、`NULLFILES skip`＝**0**、`received signal 6`＝**0**、`Service 'zygote'`＝0；`boot_id 7a331af0` 连续，模块活到 `up=2151`＝**insmod+1423 秒**；收尾 `reboot,shell`（不是 PS_HOLD） | **正** |
| ⑧ 恢复腿的闸在真形状（修正 A 的两敲） | 第 1 敲真做 ⇒ 锁 `coolup=2008,runs=1,pid=15159`；**立刻**第 2 敲 ⇒ `SR-ALREADY pid=15159 fd=75 coolup=2008 now=2062`，且 `pidof` 前后**一字不变**、锁的 `runs` 仍＝1（没被覆盖） | **正**（#178 欠的那枚到手） |

### ★这一发抓到的缺陷（不是判据失败，是这一格本来就该抓的东西）
- **去重没生效**：`(pid, start_time)` 那一对明明写进了 `ksu_birth_pid/ksu_birth_start`，同一 pid 仍反复入队——一手：`pid=13318 comm=[sh] start=1724956878195` 在 `1724.985655 / 1724.986266 / 1725.000273` **三次**入队，`queued` 计数从 244 一路涨到 159 组。⇒ 后果：**驱动 fd 泄漏**，Manager 主进程表里 `ksu_driver` 从 14 条涨到 68、再涨到 **75** 条（`fd 总数 185`）。
- **谓词比我以为的宽**：命中的不只是 Manager 主进程，还有它的 `[sh]`/`[id]`/`libksud.so` 子进程（uid 都是 10104）。"Manager 出生即装"实际跑成了"Manager 这一家子每次出生都装、而且每次都重排"。
- 机子没炸（判据⑦全绿），但这两条足以否决"升默认"：**每开一次 Manager 就漏几十条 fd**，窗口里没暴露只是因为它只重启了三次。⇒ **rc74b** 要修：①真的只排一次（排过就把这个 pid+start 钉住，回调跑完也不许再排）；②只给"线程组领头 ∧ appid 命中"排；③自测要配**正/负对照**：同一 pid 连做 N 次 execve ⇒ `queued` 必须只 +1；换个 pid ⇒ +1；同 pid 但 `start_time` 变（pid 复用）⇒ 必须再 +1。
- ★顺带一条**口径修正**（别写成结论，写成待验）：pid=14302 生于 `up≈85.9`（**早于 insmod**），装载期被装上 fd 之后**从未重启**，却在 `up=1667` 读出 `工作中／32601-2` ⇒ §6.406 那句"首页查询＝进程启动一次性"**至少不完整**——回前台／Activity 重建时会重查。这一格要单独设计才能定，不发新的一枪别动它。

### ★仪器上的四条（都是当场兑现了记忆里的那条规矩）
1. **腿 v1 自己骗自己**：把 `dmesg` 整个塞进变量再 `printf '%s\n' "$D"` ⇒ mksh 报 `/system/bin/printf: Argument list too long`，**六个计数全打 0**。那 0 是抽取器炸了，长得却和"内核没打印"一模一样（例 170/173 同族）。修＝先落文件、**把输入的行数/字节数/首末时间戳打在计数之前**，输入空 ⇒ 一律算"未测"。
2. **活环覆盖不到装载期**：`dmesg` 当时只覆盖 `959→1175`，而 insmod 在 `728` ⇒ 在活环里数到 0 **不是否据**。必须读 `dmesg.live`（带 `--- HB up=… ---` 的跟随器件）并打印覆盖区间——这条我在记忆里写过，这次是**第二次当场兑现**。
3. **半行不当读数**：`dmesg.live` 里 `dd` 把行切半、HB 标记插在行中，于是出现 `seen Manager pid=21682 uid=1` 这种串——`uid=1` 其实是 `uid=10104` 被截断。我差点据此多判一条"谓词命中 uid=1"的莫须有缺陷。⇒ 半行只能当"存在这行"，不许取里面的字段值。
4. **焦点断言救了两格**：`NotificationShade` 与 `VivoUsbDialog` 两次挡在前 ⇒ 腿打出"状态=未知"，我按**未测**处理（`清掉后`才拿到 `工作中`），没有把"读不到"写成"牌子没了"（例 164/167 那一族）。
5. ★另一条流程缺陷：**收尾名单有兩份**——`w161_teardown.sh` 用的是自己那份 **90 条**，而 `w625_lock`/`w625_seedrestart.out` 只进了 `w558_rm3.sh` 的 **151 条** ⇒ 这次漏删，靠事后 **shell 侧** `rm`＋`ls` 复证补上（这三件都是 `shell_data_file`，shell 删得动）。⇒ 例 169 那一族的反向版本：**名单漂移**，要么统一要么让 teardown 现数。
6. ★**这条写给自己（下一发必须照做）**：补删时我把两条**读数腿的设备副本**也 `rm` 了（`/data/local/tmp/w690_ksubirth.sh`、`w694_ringwitness.sh`）——按例 169 的规矩**工具件不该进清理名单**，这次等于我又踩了一遍（区别只在仓库有件、删的是设备副本）。⇒ **第 51 发开工要先重推这两条腿＋chmod 755＋设备 mksh `sh -n`＋两端 md5**（现值 `95706ae8`／`a28f199a`），别当它们还在。`/data/local/tmp/w625_seedrestart.sh` 同删，但包内 `/sdcard/z6root/` 那份还在 ⇒ 不影响用户那条命令的形状。

