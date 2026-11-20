# w791 —— 第 54 发（10-25 03:30–04:2x）判据与读数：认证「root-only bind 源＋低频维持件」

> 判据在开枪前就写死（抄自 #186 原文），读数只认同源自带的 `up=`。产物在 `kmod/w103_evidence/shot54/`。
> 环境：boot_id `c5f3049b-0bf1-4940-82c8-d83a6aec5abd`；insmod≈`up=936`（03:35–03:37 段）；
> 件：包内 ko＝`kernelsu_rc74b.ko`＝`1875056003135b3323a2cc7a152b5e41`｜args `kmod/ksu_args.txt`＝`67199f4898c98371aa3ad0ef6f649e89`（**发后读回=同一份**，见 `shot54/ksu_args.txt`）
> ｜stage `kmod/ksu_one_stage.sh`＝`1ee14343`｜维持件 `kmod/w774_pbin_keeper.sh`＝`79752988`｜破坏器 `kmod/w786_break_dev.sh`＝`fab9f33a739b6fcb9338aa016d1defe0`。

## 判据（开枪前）

- **①**先跑包的甲判据（第 53 发那七条形状，别被后两件污染）。
- **②**维持件真机有效：包跑完、牌子亮着之后人为删一次挂载源 ⇒ 期望 **≤20 秒 `/product/bin/su` 复现**、`w774_keeper.log` 里出现「重建#1 → 修好了」、**不触发 GIVEUP**；★并且**两种坏态都要覆盖**：源被删／只是被 umount。
- **③**两件取证全程挂着：`KSUBIRTH cap` 与 `total现值`（#185——长窗里 cap=64 到底吃光没有）＋「谁删了 pbin」。
- **不许顺手做**：抬 cap（#185-A）、动 seccomp（#110）、`NOBIND=1`（#182）。

## 读数（开枪后）

### ① 包的甲判据＝判正（本发的跑法就是设备侧一条命令）

- stage 起来后 `NOSUW_BIND_RC=0`、mountinfo 源＝`/adb/ksu/pbin`（root-only 新位置真的挂上了）、`/product/bin/su` 在、裸 `su -c` 的腿自报 `uid=0`。
- 牌子（`w745_badge_watch2.sh` 焦点 OK 的格子）＝`工作中／32601-2／越狱有`、页签=3、包在场=是。

### ② 维持件＝**判正一半**（源被删那一态判正；只被 umount 那一态＝未测）

破坏器经 Termux 打字 `su -c /data/local/tmp/w786_break_dev.sh` 跑通（`uid=0`，尾参不再被吃——它无参数）。一手序列：

```
=== 破坏器 起 up=2688.07 uid=0 enf=0 ===
  逃生口：cp /data/adb/ksu/sustatic → /data/local/tmp/w786_esc 得到 2241944 字节(源=2241944字节)
  前: /product/bin/su=在 源内文件=4 mount=[… /adb/ksu/pbin /system/product/bin …]
  已 rm -rf /data/adb/ksu/pbin rc=0 ⇒ 立刻 /product/bin/su=没了 mount=[… /adb/ksu/pbin//deleted …]
  复现了：第 9 秒 /product/bin/su 回来了
  keeper 计数：重建=1 修好了=1 GIVEUP=0
```

- keeper 那两行（`shot54/w774_keeper.log`）：`04:06:57 up=2696.23 第 88 轮：/product/bin/su 不在(deleted行=0 源内文件=0) ⇒ 重建#1` → `up=2696.37 修好了：/product/bin/su 现在在`。
- ★判据不是"文件回来了"而是**通道活了**：破坏之后另派一条 `w777 read` 腿，`uid=0` 出来了 ⇒ 维持件真的把官方 Manager／打字 root 依赖的那个 PATH 落点恢复了。
- ★**未测的那半格**：「源没被删、只是被 umount」这一态没上机造过（造它需要 root 腿，而当时的 root 腿就是被测对象——为避免自指我没做）。离线 selfcheck 的样本 C（"没挂我们那条 ⇒ 要挂"）只证**判定形状**，不等于真机读数 ⇒ 挂 **#188**。
- ★维持件的重建**只放回 `su` 一支**：源内文件 4→1（stage 那句 `cp -a /product/bin/.` 的三份原件没了）。后果局限在本窗（umount 后真 `/product/bin` 回来，复位后实测＝`f2fs_io init.qti.display.sh qvirtmgr` 三件、无 su），但口径要写清：**它是"把 su 放回去"，不是"把整层放回去"**。

### ③ cap 取证＝**#185 的前提被打掉**（离线，`kmod/w787_live_analyze.py`）

对 `dmesg.live`（6,381,167 B，本窗跟随件，停在 up=1886）整份分析：

- 覆盖 `up=202 → 1886`（1684 秒）；带时刻行 59,601／被切半的续行 3,044（半行只用于存在性，不取字段值）。
- `KSUBIRTH` 45 行**全部**落在 `up 900–1200` 桶（＝装载那一刻的出生安装活动），之后到跟随件停笔再无一条。
- `queued self fd`=3（首行 `up=942.62 pid=17824 comm=[libksud.so] total=3 slots=3`，末行 `up=943.19 pid=17872 comm=[libksud.so] total=7 slots=7`）⇒ **`total` 最大值=7／上限 64**；`seen Manager`=2；`dupskip`=13（`n` 最大 **10241**）；`childskip`=27；**`KSUBIRTH cap`=0**；`received signal 6`=0；`SIGSYS/syscall 142`=0（只在本窗覆盖段内）。
- ⇒ **"cap=64 极可能已在长窗里吃光"这条判前提高度不成立**：本窗预算只用到 7/64，那把闸一次都没踢。#185 的 **A（抬 cap）出局**；B（cmdline 谓词把 `libksud.so`/`usap64` 这类 helper 排掉）只剩卫生理由，不再卡"长期存在"。
- ★仪器自坏一次（**例 176③ 第二次兑现**）：第一版用行锚定 `^\[` 找时间戳 ⇒ 6 万行只数到 1,873 行"带时刻"，覆盖区间被读成 1190 秒、`total`/`dupskip` 最大值直接读成 `None`。改成行内搜（`<6>` 前缀允许在前）后才对上。

### ④「谁删了 pbin」＝**收回我之前对你说过的那句**

- 我说过的"今晚那次是**源被 `rm -rf` 掉了**"——**实物证人驳掉了**：旧 `/data/local/tmp/pbin` 目录 mtime＝**01:41**，且一直活到今天 04:22 那条收尾腿把它删掉为止；**如果被删过再重建，目录 mtime 会是重建时刻**。
- 同一窗里能对上时刻的两个自己人动作：01:41 有 `w135_um.err`（0 字节＝umount 动作发生过）、**02:05 有 `w625_seedrestart.out`**——而用户口述"那文件十几分钟后消失"正好落在 01:41+≈20 分钟。
- ⇒ 更可能是**挂载被我们自己那条腿收回**（源还在、mountinfo 那行没了 ⇒ `/product/bin` 回到真空目录 ⇒ 裸 `su` 找不到），不是外部系统在自愈；inotify 那条**没做**，精确动作仍**未定** ⇒ 留在 #184。

### ⑤ 收尾＝这条腿自己又造出两个缺陷（都已修，但**修正版未上过机**）

- **umount 失败照样删源** ⇒ 本窗收尾后 mountinfo 真变成 `/adb/ksu/pbin//deleted`（正是本发要防的那个形状，被收尾腿自己复现了一次）。靠随后的 reboot 清掉：复位后 pbin 挂载行=0。
- **`chmod 666` 排在恢复执法之后** ⇒ 产物 `w789.out`＝`root:root 0600`，执法一开谁都得不到它（PC 侧只数得出 2967 字节）。⇒ 收尾腿里的 `umount rc`／`/data/adb 清之后`／`keeper 退了没` 三项**是"读不到"，不是"通过"**。
- 两处都改在 `kmod/w789_close_dev.sh`＝`b59a3c082893ff6b10770b35c0a34d4f`（`-D` 重试＋「挂载行真的=0 才许删源，否则只删名单」＋权限排在第一行之前），bash/mksh 双壳 `sh -n` 过；**但修正版还没在真机跑过 ⇒ 不许算认证**。
- 复位后的独立读数：`enforce=1`、`mod=0`、pbin 挂载行=0、`/product/bin/su` 不存在、boot reason＝`reboot,shell,1792873574`（我们命令的复位，不是异常）。

### ⑥ 牌子的同发读数（0 额外枪）

`up=3569.85`（≈insmod+2633 秒）焦点 OK ⇒ `工作中／32601-2／越狱有`、页签=3、包在场=是、pid 仍是 13506。这中间发生过：一次源删除＋维持件重建＋两条打字 root 腿。⇒ "不重启长期存在"这一格又多一个带时刻的读数；**"什么操作会让它灭"仍未捕获**（#184/#52 那条口径不变）。

## 这一发的账

- **判正**：①包的甲判据（root-only 源真挂上、su 在、牌子亮）；②的"源被删"那一态（≤9 秒恢复＋重建#1/修好了/GIVEUP=0＋通道实测活）；③cap 取证（`total`=7/64、`cap`=0 ⇒ #185-A 出局）；⑥牌子 insmod+2633 秒仍在。
- **判负/未测**：②的"只被 umount"那一态＝**未测**（#188）；④删除者＝**未定**（并收回一句我说过的话）；⑤收尾修正版＝**未认证**（#187）。
- **交付默认不变**：出货件仍是第 53 发认证过的那份 `z6root.zip`＝`24664916…`；本发只换了 stage/维持件的**形状**并验到"源被删能自恢复"，但 `w450_close.sh` 里那条收尾腿**还没接维持件的 kill switch／root-only 源**（按用户放宽的口径，root-only 那份留到下一发由 stage 前置闸重建是可接受的）⇒ 要改就下一次连同重打包一起做，不许现在宣布升级。
