# rc82_kp 第 1 发（11-13 17:1x–18:0x）：**insmod 后整机硬复位**；B 方案判据一条都没验到

> 上游：`kmod/build_rc82_kp.py`（rc82 = 给 ko 加"保持 Permissive"看门狗，默认关）
> 目标：解决 16:3x「RCQ环境 → 加载全部模块」把 SELinux 设回 Enforcing ⇒ 临时 root 两条腿全灭。
> 判据（16:4x 预登记）：模块 apply 后 `getenforce` 回 0、`asuid 10342 /product/bin/su -c id` 出 root、
> `mountinfo` 仍有 lsposed 挂载、`lspd/zn-daemon` 在跑、LSPosed 显示已激活。
> **本发结论：五条全未验到，且设备被硬复位打断。B 方案既未被证实也未被证伪。**
> **11-13 21:4x 离线复核（0 枪）见 §3.1**：死点收敛到 killscan 开头的 report 序列、
> 二进制对照证伪"混链"假设、**原 §6 的 A（全量重编）作废**，A 修正为 A′、B 优先级上升。

## 0. 一句话

`go.sh` 按 §6.290 闩锁判成「空枪，reboot 重来」，但那是**误判**：真实事件是
**`insmod` 内核侧完整跑完后约 1 秒，整机 PS_HOLD 硬复位**。硬复位后的新 boot
天然满足闩锁三条件（Enforcing / pr 没了 / 无判据⑥），所以判据分不出这两者。

## 1. 本发形状（唯一变量＝ rc82_kp + keep_permissive=1）

| 项 | 值 |
|---|---|
| ko | `kmod/kernelsu_rc82_kp.ko` 5,108,176 B / md5 `1c2c74b1ebbe4eac1f63e3bbc69cd2c7`（设备侧 `kernelsu.ko` 同值） |
| args | `kmod/ksu_args_kp.txt` = `ksu_mass_mark=0 ksu_hook_mask=0x0 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd ksu_keep_permissive=1`（md5 `b5db1c0a…`） |
| 其余 | 交付形状逐字不变：非 quiet、默认 AP_KEY/DOM/SHBIN、NOSUW 未给、RACE 开关在、`SU_BIND=1`、`b8_setup` 铺 6 条名单（suw 10342 主条目 + 官方 10308 + 3 标准 app + Termux 10667） |
| 对照 | rc80 (`98bf4052`) + `fec3d301`(0x0) 在 B8/B9/验收窗等多次满窗存活 ⇒ 0x0 本身不是死因 |

内核日志确认装载是**成功**的，不是 insmod 失败：
```
[ 1068.097703] KSUSTEP 0 enter: stage=7 caller_pid=20805 comm=insmod
[ 1068.100595] KSUDEV: /dev/ksud char device registered (minor=78)
[ 1068.352162] KSUSTEP 0 done: miss=0
[ 1068.470331] KSUBEAT L0 before apply_kernelsu_rules()
   … L1…L10 全走过 …
[ 1068.621935] Crowning manager: me.weishu.kernelsu(uid=10308)
[ 1068.622157] KSUSTEP 9 skip: setenforce
```
（`KSUSTEP 9 skip: setenforce` = KSU 自己跳过了恢复执法，正是"窗口保持 Permissive"的既有机制。）

## 2. ★证据链：不是空枪，是硬复位

1. **`ro.boot.bootreason = HARD_RESET/PS_HOLD/0x01+0x01`、`sys.boot.reason = hard`、
   `sys.boot.reason.last = hard`，且
   `persist.sys.boot.reason.history = hard,1794562487`** —— 该 epoch 换算为
   **2026-11-13 17:34:47 CST**，精确落在 insmod 那一刻（stage.log 时间戳 17:34:02，punch 飞了约
   670 s 后 insmod）。这是**当前 boot** 的开机原因。本发第 2 步自己做过的那次 `adb reboot`
   在账本里记作 `reboot,user_choose`／正常 reason，**不会**记成 `HARD_RESET/PS_HOLD` ⇒
   当前 boot 必然是 17:34:47 那次硬复位起来的。
2. **内核日志与采样器同时断流**：`dmesg2.log` 末行 `[ 1069.155672]`，`w184_sample.out` 末行
   `up=1068 … mod=1`；`dmesg.live` 心跳止于 `--- HB up=1069.37 ---`。insmod 在 `up=1068.10`
   ⇒ **装载后约 1 秒两个独立采集通道一起消失**（进程随复位消失，不是"没走到"）。
3. **stage 脚本没有走完**：`ksu_stage.log` 停在
   `----- ★insmod 实参原文=[… ksu_keep_permissive=1 killguard=1] -----`（17:34:02），
   **没有**下一行 `insmod rc=…`（`ksu_one_stage.sh:523`）⇒ insmod 调用没返回就被打断。
4. **设备终态**：`up=4310 mod=0 Enforcing`、无 `/dev/ksud`、无 `/product/bin/su`、
   无残留 su/ksud 进程 ⇒ ko 已随复位消失，窗口自然关闭，**不是**"空枪后还活着"。

### 2.1 为什么 go.sh 的两套 `up` 看似矛盾、其实完全自洽

- `#55` 采样器与 `dmesg2` 记的是**复位前那一 boot**：`up=399`（punch 起跑）→ `up=1068`（insmod）→ `up=1069`（断流）。punch 飞了约 670 s，与历史「punch 需 ~11 分钟」铁律一致。
- `go.sh` 第 3 步等待循环记的是**复位后的新 boot**：`up=149 → 230 → … → 1553`，分诊时 `up=1618`。
- go.sh 第 2 步 `bootstrap --punch` 是**同步等 punch 跑完**的，所以硬复位发生在第 2 步末尾与第 3 步开头之间 ⇒ 第 3 步第一拍读到的就是新 boot 的 uptime。

### 2.2 ★方法论缺口（账本级，建议补进 §6.290）

`blank_now` / 闩锁三条件（本 boot 见过 Permissive + 现在 Enforcing + pr 没了 + 无 [POST]）在
**硬复位后的全新 boot** 上同样成立。判据只看"当前状态像不像空枪"，没看
**`boot_id` / `bootreason` 是否在等待期间变过** ⇒ 把"ko 把机器打 reboot 了"读成"提权没成功"。
建议：等待循环开始先存一次 `boot_id` + `ro.boot.bootreason`，分诊时比对；变了就判
`HARD_RESET_DURING_WAIT`，并强制归档 `dmesg2.log`/采样器（本发靠人工捞回来的）。

## 3. 看门狗到底有没有跑起来？—— **未能证实，也未能证否**

- **编进去了**（字节搜索 + 远端 `nm`）：`KSUKEEP`×3、`ksu_keep_permissive`×3、
  `ksu_enforce_get_raw` / `ksu_enforce_force_permissive` 为 `T`、`ksu_kp_fn` @`0x12be8`、
  `ksu_kp_work`/`ksu_kp_hits` 在 .bss、`__param_ksu_keep_permissive` 在 `__param`。
  （第一次用 `strings` 查得"全无"是 shim 里**没有 `strings` 命令**造成的假阴性，已用 `grep -ac` 字节搜索纠正。）
- **挂点也在**：`aarch64-linux-gnu-objdump -d` 显示 `ksu_fd_install_run` 开头已被编译器内联进
  `ksu_kp_start()`——读 `ksu_keep_permissive`，非 0 走 `INIT_DELAYED_WORK`+`schedule_delayed_work`，
  0 走 `printk("KSUKEEP 未开")`。该函数由 `core/init.c:205` 无条件调用，位置在 `KSUSTEP 9` 之后。
- **★用时序对齐判"看门狗有没有被调用"（不要拿计数 0 当否据）**：归档的**成功窗口**
  `w421_1113-1554_246_dmesg_full.txt.gz` 给出基线：
  `[ 963.833379] KSUSTEP 9 skip: setenforce` → `[ 964.749828] KSUFDINST 触发口 … 已建好`，
  **相隔 0.916 s**（这段是 `ksu_killscan_run()` 扫厂商模块的耗时，它排在
  `ksu_fd_install_run()` **之前**，见 init.c:202/205）。
  本发 `KSUSTEP 9` 在 **1068.622**、内核日志断在 **1069.155 ⇒ 只隔 0.533 s**，
  **比基线该出现的时刻早了 0.38 s** ⇒ 机器死在 `ksu_killscan_run()` 里，**没活到
  `ksu_fd_install_run()`**。看门狗启动点就挂在该函数第一行 ⇒ **一次都没被调用过**，
  `ksu_keep_permissive=1` 本发无任何作用。
  （修正上一稿：当时把 `KSUFDINST=0` 说成"连同函数原有打印都没有 ⇒ 函数没进"的**决定性一刀**，
  论证不严——正常窗口里它本来就要晚 0.9 s 才打印。改用与成功窗口的**时序对齐**才是硬证据；
  结论不变。）
- **死点收敛到 `ksu_killscan_run()`**（init.c:202，不是笼统的 202–209 一小段）。
  该步注释自己写着「放 init 末尾：这时 KSU 自己的符号解析层已经热好了，走 kallsyms 而不是
  kprobe ⇒ 不会跟 insmod 的 `module_mutex` 抢锁序」⇒ **"增量链接产物导致符号解析层没热好、
  killscan 退回 kprobe 抢锁"是与本发形状自洽的待验假设**，也正好是 A（全量重编）要对准的靶子。
  没有 panic/Oops/Call trace 落盘（本机无事后日志，属已知观测极限）。
- **反汇编确认新代码本身干净**：`ksu_kp_fn` 只读 `ksu_keep_permissive` → `ksu_enforce_get_raw()`
  → 条件写 `strb wzr, [x8,#1]` → `queue_delayed_work_on(...,50)`；两个裸接口都是
  `ldrb/strb [x8,#1]` + NULL 判空，无锁、无分配、无睡眠。且本发 `enforcing` 一直是 0
  （punch 已翻 Permissive，`KSUSTEP 9 skip` 也证明没被写回 1）⇒ 即使跑了也只会空转、不会写。
- **★但 rc82_kp 与 rc80 之间确实不止一个变量（本发最重要的坑）**：构建日志只重编了 3 个 `.o`
  （`sucompat.o`/`selinux.o`/`dev_syms.o`），其余走增量缓存；而 `feature/sucompat.c` 的 mtime 是
  **11-12 13:50**（rc81_order 实验之后，内容已包含 `ksu_stat_off`/`ksu_no_escape` 等一整套实验开关
  与 `SD1 decline` 打印），**rc80.ko 却是 11-09 17:26 编的**。⇒ rc82_kp 里装的是
  "rc81_order 之后的 sucompat.o"，rc80 里是 11-09 那版。虽然本发 `ksu_hook_mask=0x0`
  （sucompat 不武装），静态上这条差异不该生效，但**没有单变量对照就不能盖棺**。
  远端 `git status` 显示整棵树 19 个文件均为 `M`（长期深度改造态），`dev_syms.c` 甚至是未跟踪文件 ⇒
  "源码现状 ≠ ko 内容"是这个仓库的常态，别拿还原后的源码去解释 ko 行为。

### 3.1 ★离线复核（11-13 21:4x，0 枪、纯只读）—— 修正上面两处推断，并推翻原 A 的前提

复核工具：`kmod/probe_rc82b.py`（远端只读 preflight）、`kmod/analyze_killscan.py`（本地日志时序对齐），
外加远端 `aarch64-linux-gnu-nm -S` 对两把 ko 做符号/字符串对照。**全程未碰设备、未改远端源码、未编译。**

**(a) 死点比 §3 写的更早：不是「扫模块链表 / kprobe 抢锁」，是 `ksu_killscan_run()` 开头的 report 序列中途**

`init.c:202` 的 `ksu_killscan_run()` 第一行并不是 `pr_info("KILLSCAN enter")`；源码（dev_syms.c:1818）里
它先连调四个诊断 report，再解析 `force_sig`/`modules`，**最后**才打 `KILLSCAN enter`：

```c
ksu_lsmhook_report();  ksu_slottbl_report();  ksu_pcode_report();  ksu_uts_report();
fs = ksu_sym_addr("force_sig");  mh_addr = ksu_sym_addr("modules");
pr_info("KILLSCAN enter: ...");     // ← 之后才是扫链表 / kprobe
```

5 个成功窗口的基线**高度一致**（`w421_*dmesg_full.txt.gz`）：

| 窗口 | `KSUSTEP 9` | `LSMHOOK 进入` | `KILLSCAN enter` | `KSUFDINST` | STEP9→ENTER | ENTER→FDINST | `CFI __arm64` 条数 |
|---|---|---|---|---|---|---|---|
| 1112-1353 | 607.023311 | 607.023313 | 607.951206 | 607.952646 | 0.928 s | 0.001 s | 18 |
| 1112-1836 | 669.205464 | — | 670.103994 | 670.104975 | 0.899 s | 0.001 s | 18 |
| 1112-2318 | 660.561853 | — | 661.477529 | 661.478626 | 0.916 s | 0.001 s | 18 |
| 1112-2345 | 605.725407 | 605.725409 | 606.635050 | 606.636061 | 0.910 s | 0.001 s | 18 |
| **1113-1554** | **963.833379** | 963.833381 | **964.748650** | **964.749828** | **0.915 s** | **0.001 s** | **18** |

⇒ 那 0.915 s **不是**「扫 124 个厂商模块的耗时」（扫链表只花 0.001 s），
而是**四个 report 函数打印/解析的耗时**。上稿把它归给 killscan 主体、并据此推出
「符号层没热好 → killscan 退回 kprobe → 与 insmod 抢 `module_mutex`」——**这个靶子不存在**。

本发 `rc82kp_dmesg2.log`：`KILLSCAN`/`KILLGUARD` **0 条**，`KILLSCAN enter` 从未出现；
但 `LSMHOOK 进入` 在 `1068.622159`（STEP9 后 2 µs）**有**，随后 CFI 只打出 **16 条**
（成功窗口固定 18 条），第 16 条 `1069.155672` 就是整个日志的末行。
距 `LSMHOOK 进入` 仅 **0.533 s**，比基线该走完的 ~0.915 s **早 0.38 s**。
⇒ 时间上**还没走到** `KILLSCAN enter`，不是"走到了但 printk 被限流吞掉"。
**死点＝ `ksu_pcode_report()` 打 CFI `__arm64_sys_*` 表的中途**（`ksu_killscan_run()` 开头第 3 个 report）。
「没活到 `ksu_fd_install_run()`」的大结论不变，看门狗依然一次没被调用。

> 旁证（线索，非定论）：本发 `CELLULAR_TCP` 打印 **2315 条**，成功窗口为 0/95/87/202/105 条
> ⇒ 本发窗口期内核 printk / 网络重传压力高一个数量级，与"跑在诊断 report 中途被硬复位"自洽。

**(b) 二进制对照：死点那段代码在 rc80 与 rc82_kp 里等价 ⇒ 混链没有让它变形**

远端 `aarch64-linux-gnu-nm -S --defined-only`（地址 / size）：

| 符号 | rc80 (`98bf4052`) | rc82_kp (`1c2c74b1`) | size |
|---|---|---|---|
| `ksu_killscan_run` | `0x109b8` | `0x109f0` | **0x800 / 0x800** |
| `ksu_lsmhook_report` | `0xea94` | `0xeacc` | **0x3c0 / 0x3c0** |
| `ksu_slottbl_report` | `0xe4bc` | `0xe4f4` | **0x4f4 / 0x4f4** |
| `ksu_pcode_report` | `0xf1c4` | `0xf1fc` | **0x958 / 0x958** |
| `ksu_uts_report` | `0xee54` | `0xee8c` | **0x78 / 0x78** |
| `ksu_sym_addr` | `0xe26c` | `0xe2a4` | **0x158 / 0x158** |
| `ksu_fd_install_run` | `0x113c8` | `0x11400` | 0x98 / **0x120**（+0x88＝内联 `ksu_kp_start()`） |
| `ksu_enforce_get_raw` / `...force_permissive` | — | `0x9eec` / `0x9f10` | 0x24 / 0x14 |
| `ksu_kp_fn` | — | `0x12be8` | 0x78 |

地址整体平移 **0x38 = 0x24 + 0x14**，正好是 `selinux.c` 新增的两个裸接口长度；
所有 report 函数 size 逐一全同。字节搜索 `grep -ac` 的 report 字符串计数也全同
（`LSMHOOK 进入`=1、`KILLSCAN enter`=1、`KILLSCAN 收工`=1、`KSUFDINST 触发口`=1、`SLOTTBL`=8、`PCODE`=7），
唯一差别是 `KSUKEEP` 0→3。（`CFI __arm64` 两把 ko 都数到 0 是因为它是 `pr_info("CFI %s ...")` 的
格式化参数、符号名不落在字符串常量里，**不要**误读成"没有 CFI 打印"。）

⇒ `dev_syms.o` 里 report/killscan 主体是**同一份源码**编出来的；"增量链接把新旧 `.o` 混在一起
导致 killscan 行为异常"**被证伪**。结合 (a)，本发更像**偶发的环境侧硬复位**（同一段 report 序列
在 5 个成功窗口都完整跑完），而非 ko 的结构性缺陷。

**(c) 原 A「全量 clean 重编」方向错了，理由不是"消不掉 sucompat.c"，而是它拉大差异**

preflight 实测远端：37 个 `.o` 中 **29 个是 11-09**、2 个 11-10、1 个 11-12、5 个 11-13；
`init.c` mtime 11-06、`Kbuild` 10-04、`sucompat.c` 11-12 13:50、`dev_syms.c`/`selinux.c` 11-13 09:14；
`git status` 19 个 `M`。⇒ **全量 clean 重编 ≠ 回到 rc80 基线**，而是把当前 11-13 工作树的
19 个改动文件**全部**编进 ko，与稳定 rc80（11-09 工作树）的距离**比 rc82_kp 更远**。
原 A 想排的"混链产物"靶子已被 (b) 否定，代价却是引入更多共变量。**原 A 作废。**

**(d) 顺带确认的工程事实（写进下一版构建脚本的约束）**

- 源码已**干净还原**：`selinux.c`/`dev_syms.c` 的 md5 与 `.rc82bak` 逐一相同
  （`96961886…` / `658c033e…`），两个锚点各出现 1 次、rc82 残留 0 ⇒ 补丁可原样重打。
- `dev_syms.c.ksud_bak` 是 **11-06** 版（108086 B / `2eb0a998…`），diff 显示 11-09 之后加的是
  `/dev/ksud` misc 设备段 ⇒ **不是** rc80 基线备份；11-09 的 `sucompat.c` / `dev_syms.c`
  没有可靠源码备份（只有 `.o` 还在）。
- `Kbuild` 无自定义 `clean` 目标；`make -C $KDIR M=$MDIR clean` dry-run 确认只删 `MDIR` 下的
  `*.o/*.ko/.*.cmd/Module.symvers/modules.order`，**不碰内核树**；`/home/lucy` 可写、余 1.8 T。
- 内核 **5.4.281**，`/proc` 节点用 `struct file_operations` + `proc_create()`
  （`struct proc_ops` 是 5.6+ 才有，别照抄新内核写法）；`dev_syms.c:31` 已 include `linux/proc_fs.h`
  且已有 7 处 `proc_create` 用例（`ksu_slots`/`ksu_fixuts`/`ksu_fixcfi`/`ksu_cfiscan`/
  `ksu_openprobe`/`ksu_install_fd`…）⇒ `/proc/ksu_kp_stat` 可照抄，零新增依赖。

## 4. 结论

- **本发是负结果，不是 B 方案的验证**：五条判据一条未测（连模块 apply 都没走到）。
- **★★看门狗已被洗清，同时也未被验证**：按 §3.1(a) 的时序对齐，机器在 `LSMHOOK 进入` 后
  0.533 s 就断流（基线要走 ~0.915 s 才到 `KILLSCAN enter`、再 0.001 s 到 `ksu_fd_install_run()`）
  ⇒ `ksu_keep_permissive=1` 这个参数**在本发里从未产生任何作用**。所以这一发
  **既不能说"看门狗把机器打崩了"，也不能说"看门狗能守住 Permissive"**。B 方案完好无损，
  但要验证它，必须先让 ko 活过 init 末尾。
- **死因收敛到「`ksu_killscan_run()` 开头的 report 序列中途被硬复位」**，不是模块扫描、
  不是 kprobe 锁序、也不是 `kobject_del()`（那些都在更后面）。§3.1(b) 又证明这段代码在
  rc80 与 rc82_kp 里**二进制等价**，而 5 个成功窗口里同一段序列都完整跑完
  ⇒ **最自洽的解释是偶发的环境侧硬复位**（本发 `CELLULAR_TCP` 2315 条 vs 成功窗口 ≤202 条，
  printk/网络压力高一个数量级），**不是 ko 的结构性缺陷**。但没有单变量对照，不能盖棺。
- **不能用这一发去否定 B 方案本身**（把 enforce 拉回 0 的思路没被证伪，是载体出事）。
- **下枪必须换见证**：`KSUKEEP`/`KSUFDINST` 都靠 printk，本机限流重、且硬复位会抹日志 ⇒
  改成 `/proc/ksu_kp_stat` 直接读 `hits`/`started`/`last_enforcing`（5.4 用
  `file_operations` + `proc_create`，见 §3.1(d)）。**注意**：见证节点只能解决"窗口活着时
  读不到 printk"，**解决不了硬复位把内存态全抹掉**；它服务的是 B 方案五条判据，不是本发死因诊断。
- **★方法上的意外收获**：`rc80 + 0x0` 多次满窗活，说明 report 序列本身在这台机上通常是安全的。
  **原 §6 的 A（全量 clean 重编）已被 §3.1(c) 作废** —— 它不回到基线，反而把 11-13 工作树
  19 个 `M` 文件全编进 ko，拉大与 rc80 的距离。⇒ **B 对照枪（现成 rc80 验环境）的优先级上升**，
  比"重编后再开一枪"信息量更大。

## 5. 设备终态与纪律核对

- `mod=0 / Enforcing / 无 /dev/ksud / 无 /product/bin/su / 无 ksu 进程` ⇒ **已回出厂态，无过夜窗口**，
  不需要 teardown。`kd` 仍在（`/data/local/tmp/kd`，`shell:shell`，2.2 MB，apk_data_file 标签），
  是 inert 残留；Enforcing 下 shell 可删（这份是 shell 属主），下个窗口会覆盖。
- 交付件**全程未动**：`kmod/ksu_args.txt` 已由 go.sh EXIT 兜底还原为 `fec3d301ff5a55a19720477f01dc71d9`；
  `kernelsu_rc80.ko` (`98bf4052`)、`z6root.zip` 一字未改。
- 本发**已花掉该 boot 唯一一发 punch**；按硬纪律不在同 boot 重打，要重打必须先 `adb reboot`。

## 6. 下一步（三选一，需点头再开火）

> **注意**：原计划的"同一把 ko 换 `ksu_keep_permissive=0` 做单变量对照"**已被 §3 的证据作废**——
> 本发里看门狗压根没被调用，参数 0 与 1 会得到同一个 ko 行为，那枪是白打的。

> **原 A（全量 clean 重编）作废**：见 §3.1(b)(c)。混链靶子已被二进制对照否定，
> 而全量重编会把 11-13 工作树 19 个 `M` 文件全编进 ko，离稳定 rc80 更远。下表 A′ 是修正版。

| 选项 | 做法 | 代价 / 收益 |
|---|---|---|
| **A′. 加见证的最小重编（0 枪、离线、可回退）** | **不做 clean**，照抄 rc82_kp 的 make 命令（命令行不变 ⇒ `if_changed` 不触发无关重编）。`.o` 实测 `sucompat.c`(11-12 13:50) 比 `sucompat.o`(11-13 09:14) **旧** ⇒ make 自然不会重编它，**无需冻结技巧**；于是只重编 `selinux.o` + `dev_syms.o` + 链接产物。改动＝在 `dev_syms.c` 加 `/proc/ksu_kp_stat`（5.4 的 `file_operations`+`proc_create`，用 `snprintf`+`simple_read_from_buffer` 避免新增 `seq_file` 依赖），并把**创建点挂到 `ksu_dev_syms_init()`**（init.c:128，整个 init 第一件事）；`ksu_kp_start()` 仍挂 `ksu_fd_install_run()`，**不动 `init.c`、不动启动点** | 产物 `kernelsu_rc82b.ko` 相对 **rc82_kp** 只有"见证节点 + 其创建点"这一个变量；离线做、不碰设备、失败可退回 rc80。⚠️ 它**不解决本发死因**（§3.1 判为偶发环境事件），价值是给下一发**不依赖 printk 的确定性读数**：窗口再死在 report 阶段也能读到 `started=0`；活过 init 则读 `started=1`/`hits`/`enforcing` 验 B 方案五条判据。⚠️ 注意它的基线是 **rc82_kp 而非 rc80**：`sucompat.o` 装的是 11-12 版（11-09 版无可靠备份），相对 rc80 的差异仍在，但那部分在 rc82_kp 第一发已证明能装载成功 |
| **B. 对照枪（1 枪，★优先级已上升）** | 用**现成的 rc80.ko + `fec3d301`(0x0)** 重打一发，确认"这台机现在还能满窗活、report 序列还能跑完" | 1 枪 / 若满窗活 ⇒ 坐实本发是偶发环境侧事件，A′ 可直接开火验五条判据；若 rc80 也崩 ⇒ 与 ko 无关，是设备/环境侧变化，**应暂停 rc82 线**并先查设备状态 |
| **C. 收手** | 撤掉 rc82 线，回到 `rc80 + 0x0` 交付形状；「模块 apply 与临时 root 互斥」按 16:3x 口径保持为已知限制 | 0 枪 / 保住稳定交付，但用户想要的 LSPosed 激活路径无解 |

**修正后的顺序：离线（A′ 构建 + `go.sh` 分诊增强，0 枪）→ B 对照枪（1 枪验环境）→ A′ 产物开火验五条判据。**
（原顺序 A→B→A 产物 的前提是"重编能修死因"，已被 §3.1 否定；现在 B 才是决定该不该继续的那一步。）

另外无论选哪条，都建议先把 §2.2 的 `boot_id`/`bootreason` 比对补进 `go.sh` 分诊
（纯诊断增强，不改开火形状），否则下一发还会把硬复位误读成空枪。

**A′ 的创建点已由 `kmod/probe_a_prime.py` 确认（11-13 21:5x，纯只读）**：
`ksu_dev_syms_init()` 定义在 `dev_syms.c:439`，在 **`core/init.c:128`** 被调用，
注释明写「★必须在最前面：KSU 自己的 resolver 会用到未导出符号」；它排在
`KSUBEAT L0`(151) / `KSUSTEP 9`(~184) / killscan(202) / fd_install(205) **之前**，
函数第一行就是 `KSUSTEP 0 enter`（本发 `1068.097703` 有这条 ⇒ 确实走到了）。
⇒ 见证节点在这里创建后，**即使窗口再死在 report 序列里，节点也已存在**，
`cat` 到 `started=0` 即可硬证"没活到 `ksu_fd_install_run()`"，且不依赖任何 printk。
另注：项目硬纪律是活窗口不 `rmmod`、关窗靠 reboot，故不注册 `proc_remove`/
`cancel_delayed_work_sync`（与 rc82_kp 一致），避免为清理逻辑再改 `kernelsu_exit()`。

## 7. 归档证据（`kmod/w103_evidence/`）

| 文件 | 内容 |
|---|---|
| `go_rc82kp.log` | go.sh 全程（85 行，含误判空枪与 args 还原） |
| `rc82kp_dmesg2.log` | 2,064,498 B，16,148 行；覆盖 446→1069，含 insmod 全流程与断流点 |
| `rc82kp_dmesg_live.txt` | 8,544 B，心跳止于 `up=1069.37` |
| `rc82kp_stage.log` | 50 行，停在 insmod 实参行（无 `insmod rc=`） |
| `rc82kp_sample.out` | 229 行，`up=399→1068`，末行 `mod=1` |
| 远端 `/home/lucy/kernelsu_rc82_kp.ko` | 与本地同 md5，供反汇编复核 |
| `w421_1112-1353 / 1112-1836 / 1112-2318 / 1112-2345 / 1113-1554` 的 `_dmesg_full.txt.gz` | §3.1(a) 的 5 个成功窗口基线：report 序列 0.899~0.928 s、`CFI __arm64` 固定 18 条、`KILLSCAN enter`→`KSUFDINST` 0.001 s |
| `kmod/probe_rc82b.py` | 11-13 21:4x 远端**纯只读** preflight：源码还原状态、`init.c` 调用链、`make clean` dry-run、5.4 `/proc` API、`.o` mtime 分布 |
| `kmod/analyze_killscan.py` | 本地日志时序对齐：本发 vs 5 个成功窗口的 STEP9/LSMHOOK/CFI/KILLSCAN/KSUFDINST 时刻 |
| 远端 `/home/lucy/kernelsu_rc80_cmp.ko` | `98bf4052` 上传副本，供 `aarch64-linux-gnu-nm -S` 与 rc82_kp 做符号/字符串对照（§3.1(b)） |

## 8. 复核方法（可复现，全离线）

```bash
# ① 本地日志时序对齐（无需网络）
python3 kmod/analyze_killscan.py

# ② 远端只读 preflight（不上传/不编译/不改源码）
python3 kmod/probe_rc82b.py

# ③ 两把 ko 的符号与 size 对照（远端）
aarch64-linux-gnu-nm -S --defined-only <ko> | grep -E 'ksu_(killscan_run|.*_report|fd_install_run|kp_.*)'
for s in 'LSMHOOK 进入' 'KILLSCAN enter' 'KILLSCAN 收工' 'KSUFDINST 触发口' 'KSUKEEP'; do \
    printf '%s=%s ' "$s" "$(grep -ac "$s" <ko>)"; done
```

> ⚠️ **本机 shim 里没有 `strings` 命令**，用它查 ko 里的字符串会拿到全 0 的假阴性；
> 一律用 `grep -ac "<串>" file.ko` 做字节搜索（本项目已踩过一次，见 MEMORY.md 观测极限）。
> ⚠️ 判断"某函数有没有跑"**不要拿 printk 计数 0 当否据**（本机限流重），
> 要用「与成功窗口的时序对齐」：本发 0.533 s 断流 vs 基线 ~0.915 s，才是硬证据。

## 9. A′ 离线执行结果（11-13 21:5x，**0 枪、未碰设备、可回退**）

### 9.1 产物

| 项 | 值 |
|---|---|
| ko | `kmod/kernelsu_rc82b.ko` **5,111,448 B / md5 `2807a4cacb6e31796ac3165176050499`**（远端 `/home/lucy/kernelsu_rc82b.ko` 同值） |
| 相对 rc82_kp | +3,272 B；**唯一变量＝ `/proc/ksu_kp_stat` 见证节点及其创建点** |
| 构建脚本 | `kmod/build_rc82b.py`（`--apply` 才编译；默认预览模式只校验锚点） |
| 验收脚本 | `kmod/verify_rc82b.py` |
| 第二步 preflight | `kmod/probe_a_prime.py` |
| args | 沿用 `kmod/ksu_args_kp.txt`（`b5db1c0a`，含 `ksu_keep_permissive=1`）；**本次未改任何 args 文件** |

### 9.2 构建形状（严格符合 A′ 约束）

`make` 与 `build_rc82_kp.py` **逐字相同**（`KCFLAGS="-include /home/lucy/ksu_compat54.h"`、`modules -j32`），
且**不做 clean** ⇒ `if_changed` 只触发了 2 个 `.o`：

```
CC [M]  /root/k/ksu/kernel/selinux/selinux.o
CC [M]  /root/k/ksu/kernel/infra/dev_syms.o
LD [M]  /root/k/ksu/kernel/kernelsu.o      MODPOST 1 modules
CC [M]  /root/k/ksu/kernel/kernelsu.mod.o
LD [M]  /root/k/ksu/kernel/kernelsu.ko     EXITCODE=0
```

- `sucompat.o` mtime **before = after = `1794561252`**（2026-11-13 09:14:12）⇒ 未重编 ✓
  （原因：`sucompat.c` 11-12 13:50 比 `.o` 11-13 09:14 **旧**，make 判它是最新的；**不需要任何冻结技巧**）
- 源码无条件还原：`selinux.c`=`96961886…`、`dev_syms.c`=`658c033e…`，与 `.rc82bbak` 逐一相同，rc82 残留 0 ✓

### 9.3 验收结果（`kmod/verify_rc82b.py`）

- 字节搜索：`ksu_kp_stat`=3、`param=%u started=%u hits=%lu now_enforcing=%d`=1、`KSUKEEP`=3、
  `ksu_keep_permissive`=3、`ksu_enforce_get_raw`=2。
  三把 ko 对照：rc80 `kp_stat=0/KSUKEEP=0`、rc82_kp `0/3`、**rc82b `3/3`** ⇒ 唯一变量成立 ✓
- 符号齐全：`ksu_kp_stat_read`(t,0xf8)、`ksu_kp_stat_fops`(r,0x120)、`ksu_kp_stat_pe`(b)、
  `ksu_kp_started`(b,1)、`ksu_kp_hits`(b,8)、`ksu_kp_work`(b,0x88)、`__param_ksu_keep_permissive` ✓
- **report/killscan 段三把 ko 的 size 逐一全同**（0x800/0x3c0/0x4f4/0x958/0x78/0x158）
  ⇒ 新补丁没碰死点代码 ✓
- ★`objdump -dr` 确认 `ksu_dev_syms_init` 里 **`df58: bl <proc_create>` 是函数第一条 `bl`**，
  排在 `printk`(KSUSTEP 0) 与 `misc_register` 之前 ⇒ 见证节点确为整个 init 的第一件事 ✓
- `bash -n kmod/go.sh` OK；交付三件哈希一字未动：`kernelsu_rc80.ko`=`98bf4052`、
  `ksu_args.txt`=`fec3d301`、`z6root.zip`=`93774ad4` ✓

### 9.4 `go.sh` 分诊增强（§2.2 落地，纯诊断）

`kmod/go.sh` 新增 §6.292：等待循环前存 `BOOT0`(`/proc/sys/kernel/random/boot_id`)+`BR0`；
分诊判空枪前比对 `BOOT1`，**变了就报 `HARD_RESET_DURING_WAIT`**，打印起/终 boot_id、
`ro.boot.bootreason`、`persist.sys.boot.reason.history`，并**强制归档**
`$EV/hard_<BTAG>_{dmesg.live*,w184_sample.out,ksu_stage.log,punch.log,dmesg_now.txt}`。
**不改 `exit 5`、不改开火形状** ⇒ 下一发不会再像本发那样把硬复位误读成空枪、且日志被 reboot 抹掉。

### 9.5 下一发 runbook（**需用户点头 + 先 `adb reboot`**）

1. **先按 §6 修正后的顺序打 B 对照枪**：现成 `rc80.ko` + `fec3d301`(0x0)，验"这台机现在还能满窗活"。
   若 rc80 也崩 ⇒ 与 ko 无关，暂停 rc82 线先查设备/环境。
2. B 满窗活才谈 rc82b 开火。~~铺 args 时记住铁律：`kmod/ksu_args.txt` 与
   `kmod/ksu_args.txt.bak_delivery` 两份同改（go.sh 会拿 bak 覆盖回来）~~，
   内容取 `ksu_args_kp.txt`（含 `ksu_keep_permissive=1`）；`KO=kmod/kernelsu_rc82b.ko`。
   > 🔧 **11-14 01:2x 口径更正（原文保留划掉，见 `RC82B_FIRE_RUNBOOK_1114.md` §1）**：
   > 这句是「手改现件 + 没有 trap 兜底」时代的旧口径。`go.sh` L61–72 现已有 `ARGS_FILE` 机制，
   > 正确写法＝ **`ARGS_FILE=kmod/ksu_args_kp.txt`**，**不改 `.bak_delivery`**（否则永久污染交付基线）。
3. 窗口活过 init 后，`cat /proc/ksu_kp_stat` 读 `param/started/hits/now_enforcing`
   （**0400，需 root 读**）：`started=1` ⇒ 看门狗挂上了；点「加载全部模块」后
   `hits` 增长、`now_enforcing=0` ⇒ B 方案成立，再验预登记的五条判据。
   若又死在 report 序列，节点仍在 ⇒ `started=0` 就是"没活到 `ksu_fd_install_run()`"的硬证据。
4. **本轮全程 0 枪、未连接设备、未改交付形状**；`kmod/B-SCOPE.md`（交付口径）无需改动。
