# w760 —— 第 53 发（开枪前写死）：认证"当前版包"（候选包＝rc74b）＋顺手把 #184 那一格捕获到

## 形状（一句话）
**被测对象＝包本身**：设备侧一条命令 `/system/bin/sh /sdcard/z6root/z6root.sh`（**不走 PC 编排的 go.sh**）。
包内 ko `z6root/kernelsu.ko`＝`1875056003135b3323a2cc7a152b5e41`（＝第 51/52 发那支 rc74b）、`ksu_args.txt`＝`67199f48…` 五条逐字未动、
`z6root.zip`＝`af5fff6c…`；`MANIFEST` 22 条，包自己会在运行时两端核 md5（铁律 4）。
★这一发同时换两样东西（ko 与"包这个交付物"），**所以两组判据必须各自独立取数**：甲组（下面 1~7）只答"包能不能一键跑通"，乙组（8~10）只答"牌子在什么条件下会灭"。

## 判据（十格，缺一条就算这发没做完）
### 甲组＝#178「当前版包真机一键认证」的七条（沿用 §6.370 第 33 发那七条的形状）
1. **包自己打的入口证人**：`-- 3.6) 入口形状` ⇒ `★免 suw 开关已铺并读回：内容=[<uid> <包名>] 词数=2` ＋ `入口形状=1`（取不到 uid 会退回 A 形状并**当场明写**，不许静默换形状）。
2. **stage 侧**：`起点 v61 stage=… args=[五条] dom=… up=…` ＋ `★NOSUW 入口证人：名单主条目=(uid=…, key=…)`。
3. **活表**：`allowlist: NEW_GET_ALLOW_LIST rc=0 count=1 total=1 | allow[0] uid=…` ＋ `granted[…] granted=1`；同刻 `insmod rc=0 up=…` ＋ `★insmod 实参原文=[…]`（**这条要能看出 ko 是哪一支**：配合下面 4 的 md5）。
4. **载荷逐件两端核**（我自己核，不靠包）：`/sdcard/z6root/*` 与本机 `z6root/*` 的 md5 逐条一致，其中 **`kernelsu.ko` 必须是 `18750560…`**；跑完再看包自己的 `MANIFEST` 比对有没有报"不符就停"。
5. **屏幕那一格（判据只有截图＋无障碍树）**：官方 Manager 首页 `工作中／版本：32601-2` ＋ Termux 里 `/system/bin/su -c id` 出 `uid=0 … context=u:r:shell:s0`。★焦点断言不对就记**未测**。
6. **包里那条 root 侧收尾腿**（教程第 7 步那条路）：`CLOSE …`／`umount_rc=0`／`MOUNT_LEFT=0`／`rm_allow_rc=0`（读数是 root 命名空间那一份，要**点名在哪个 ns 读的**）。
7. **收尾句**：`=== Z6ROOT_DONE up=… mod=1 enforce=Permissive ===`——这是这一跑唯一"我跑完了"的证人；没有它，甲组一律不算齐。

### 乙组＝#184「什么操作才让牌子灭」的捕获（必须在甲组之后跑，避免污染）
8. **UI 真点进超级用户页**（不用深链——第 52 发证明深链走"投递给已存在实例"、页面逐字未变）：
   点之前起 `w731_root_sampler.sh`（**只派一次**，自己 `--loop` 甩后台）；点完**每 3 秒连读 6 格**，同刻四件齐：
   牌子文本（首页要回头看）＋`pidof me.weishu.kernelsu`＋`logcat -d -b crash -b main -t 400`（找 `Fatal signal 31 (SIGSYS)`／`Fatal signal 6`／`RootServerMain`／`libsu`／ANR）＋内核侧 `KSUBEAT` 改道链（SU0/SD4/SU1）计数。
   ★判读口径（开枪前写死）：**改道链出现又死于 SIGSYS＝(c) seccomp**；**改道链压根没出现＝(a)/(b)**；**`fd_ksu` 掉到 0 或 pid 变了＝(a)**；三者都没动而牌子灭了＝新的第四种，如实记"解释不了"。
9. **Manager 崩了之后还亮不亮**（这条是"长期存在"的真正判据）：若第 8 格把 Manager 打死，**只等系统重开/自己 `am start` 重开**（不跑恢复腿、不写触发口），看新 pid 的牌子与 `fd_ksu` ⇒ 期望**亮且 ≥1 条 fd**（出生即装），同时记 `KSUBIRTH total` 涨了几格（给 #185 的 cap 消费速率第三枚）。
10. **稳定性与收尾**：`received signal 6` 计数、boot_id 与 `up=` 连续（整机不许复位）、`KSUBIRTH cap` 必须＝0（出现＝疯排⇒判负）；
    收尾顺序照 §6.416/§6.421：**所有要 root 的腿排在 `w426_enforce.sh` 之前** → `w165b_adb_clean.sh`(root) → `w558_rm3.sh`(151 条) → shell 侧补删本轮新名字（`w760_*`/`w731_*`/`w745_*`/`ksu_stage.log`/`punch.log`）＋`ls` 复证 → `w426_enforce.sh` → reboot → 复核。
    ★开工前每条腿**重推＋chmod 755＋设备 `sh -n`＋两端 md5**（例 176②，这次是硬闸不是清单尾巴）。

## 已知风险／作废条件（开枪前就认）
- 现在约 23:15，这一发会跑到约 00:2x——**用户明确点头"开始"了才打**；打完必须当场收尾，绝不把窗口留过夜。
- 包认证那七条历史上偶有"腿没跑"（exit=127＝腿文件不在设备上）与"读数没拿到"——**一律记未测**，不许写成"没问题"。
- vivo 模态框（USB 用途选择／开发模式 heads-up）会抢焦点：★**只用 `input keyevent 4` 关它，绝不点"取消"**（可能把 adb 数据通道一起关掉）；每格读数前先断言 `mCurrentFocus`。
- 乙组第 8 格**有可能把 Manager 打死**——那是想要的读数，不是事故；但死了之后进程数、`Seccomp`、crash 行必须同刻落盘，否则事后读不到（环只覆盖最近约 1 分钟）。
- 不许顺手做：动 cap（#185 A/B）、开 `ksu_fd_keepalive`（§6.400 判死）、卸 `com.suw.manager`、rmmod 活窗口、改 `ksu_args.txt`。

## 读数（跑完再写）
（待填）

## 读数（第 53 发，23:29–00:12）

### 一句话
**候选包（包内 ko＝rc74b `18750560…`）设备侧一条命令跑通：甲组七条里五条直接成立、两条降级为"替代证人/未测"；乙组三轮导航＋在超级用户页停 10 秒，牌子一次都没灭，而 `libksud.so` 的 SIGSYS 终于被抓到实名行——那支确实死，但死的不是主进程、也不影响牌子。**

### 甲组（#178 那七条）
1. **成立**：`★免 suw 开关已铺并读回：内容=[10667 com.termux] 词数=2 字节=17` ＋ `入口形状=1 目标包=com.termux 现取 uid=10667`。
2. **部分成立（我删早了一件证人）**：包 stdout 的第 10 步已把 `★insmod 实参原文=[ksu_stage=7  ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd killguard=1]`、`allowlist: … count=1 total=1 | allow[0] uid=10667`、`insmod rc=0 up=7174.07` 三条打出来；但**"起点 vNN stage=…"那一行只在 `/data/local/tmp/ksu_stage.log` 里，而我在收尾补删时把它删了** ⇒ 那一行不可恢复。★记流程缺陷：**补删之前要先 pull 存证**（旧账里这条写过两次，第三次犯）。
3. **成立**：活表 `count=1 uid=10667` ＋ `granted[10667] granted=1`；同刻 insmod 实参原文如上。
4. **成立（两端各核一遍）**：包自己 `21 条 ok`；我另算 `/sdcard/z6root` 22 件、MANIFEST 21 条逐字对，包内 `kernelsu.ko`＝`1875056003135b3323a2cc7a152b5e41`（5,106,064 B）、`ksu_args.txt`＝`67199f48…`。
5. **降级为"替代证人"**：`~ $ su` 后屏幕出现 `uid=0` 这一形**没拿到**（第一次打字腿失败：InputManager 异常＋chmod 靶子模式未变＝命令根本没执行；#116 那格"root 输出写不回 app 终端"本来也挡着它）。改用两条独立证人成立：**①内核侧改道链 `SU0→SD4→SU1b/c/d→SU2→SU3→SU4 after nested execveat: ret=0 uid=10667`；②那条 su 跑起来的脚本自己报 `uid=0`**（就是 `w767` 收尾腿）。⇒ 口径：**app 侧 su 出 root 成立；"屏幕上看得见"这格仍未测**。
6. **降级**：包里那条 `w450_close.sh` **没跑**（B 形状下 suw 未授权 ⇒ PC 侧 `rleg` 通道全瞎：`w731 … 没等到 DONE`，设备上连 `.out` 都没生成——**这是本轮最有用的流程发现**）。等价动作由我自写的 `w767_close_shot53.sh` 经 Termux 的 su 跑掉：`/data/adb [ksu ksud]`→`[]`、151 条清理件、补删、**最后** `enforce=1`／`getenforce=Enforcing`。
7. **成立**：`=== Z6ROOT_DONE up=7200.16 mod=1 enforce=Permissive ===`（唯一"跑完了"证人）。另：`slide=0000002bda800000` 设备侧自解成功、`NOSUW_BIND_RC=0 HEALTH=OK CP_N=4`、`SU_AT_TGT=-rwxr-xr-x root root 2241944 /product/bin/su`。

### 乙组（#184 那一格）
- **一次都没灭**：`am force-stop`→`am start` 起的新 Manager（pid **32050**）从 up=7441 到 8047 全程 `工作中／32601-2／越狱`；三次"进超级用户页→停 10 秒→回首页"读数**完全相同**（`字节=18500 节点=20`），`不支持` 出现 **0 次**，pid 一字未变。
- ★**新计数**：`dupskip n` 到 **133633**（同 pid 一直被挡＝去重在 22 分钟里持续有效）、`fd_ksu=`**1**（比第 52 发的 3 更干净：这一发没有第二个生产者）、`Seccomp=2`、`KSUBIRTH cap`真踢=**0**、`received signal 6`=**0**。
- ★**实名抓到了**（这是 #184 要的东西）：`Fatal signal 31 (SIGSYS), code 1 (SYS_SECCOMP), syscall 142 in … (libksud.so)` ×3（23:33:31 一段重试风暴），backtrace 帧全在 `…/me.weishu.kernelsu-…/lib/arm64/libksud.so` ⇒ **官方 ksud 那支在本机确实被 app 域 seccomp 打死**（旧口径 #125 从"推断"升为"有实名行"）。**但它死的是 `libksud.so` 自己的进程；主进程活着、牌子不掉。**
- ⇒ **(a)/(b)/(c) 的现状**：(c) 被证实存在但**与牌子无关**；(a) 在 rc74b 下不成立（新进程必有 fd）；(b) 未观测（RootService 那支没被触发到崩主进程）。**"用户那一次为什么会灭"最自然的解释换成了：他跑的是上一份包（rc73）——那里进程一旦被系统回收就再没人补装 fd**，而"点返回"只是让画面重绘出新状态。这条现在有三发正面凭据（51/52/53 都是"新进程 1 条 fd、不掉"）。

### 收尾与现态
补删后设备上只剩 7 件工具腿；旧包（第 33 发认证那份）整目录留在 `/sdcard/z6root_shot33_rc73` 未动。reboot 复核：boot_id `62aac196`、`Enforcing`、`mod=0`、`bind=0`、`hist` 最新一条 `cold,charger,1792856771`（★我们敲的是 `adb reboot`，这台机仍可能记成 `cold,charger`——"分不了收尾 vs 异常复位"第四次，别拿它当结论）。**10-24 枪数＝4。**

### 仪器条目（这一发三条）
①★**B 形状下 PC 侧 root 通道是瞎的**：名单主条目是目标 app，suw 没授权 ⇒ `rleg` 一切腿静默失败（这次靠"设备上连 .out 都没生成"发现，不是靠回执文本）⇒ **交付口径要写：走 B 形状时收尾请用包里那条腿（在 Termux 里跑）**。
②**打字腿要先暖行且必须前台**：补上 `input text echo%swarm`＋Enter 且确认 `mCurrentFocus=com.termux` 之后，同一条命令一次成功（第一次失败时 Termux 不在前台）。
③**补删前先 pull**（判据 2 那行就是这么丢的）。
