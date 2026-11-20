# ★ 任意内核读通道 = `/proc/cmdline` + `saved_command_line`(一发指针写换来, 不需要任何堆地址)

## 0. 结论

一发形状(2)的指针写 `*(C)=P` 里取 **`C = &saved_command_line = 0xffffffc012b27600 + slide`(.bss, 可写)**
⇒ 之后 `cat /proc/cmdline`(DAC 0444 / SELinux `config_gz`… 不, 是 `proc_cmdline`, **shell 实测可读**)
就是在**以 `P` 为起点往外印内核内存**, 直到遇到第一个 NUL 为止。
读操作本身**可重复、不改状态**, 因此"一个 boot 只能打一发"的限制对**读**不成立 ——
只要那一发把指针写对了, 这一整轮开机我们都能反复读。

一手证据(同构建 `g2a88cd145def` 反汇编):
```
cmdline_proc_show @ 0xffffffc0100be268
  adrp x8, #0xffffffc012b27000
  ldr  x1, [x8, #0x600]        ← x1 = saved_command_line (.bss 0x12b27600, kallsyms 类型 B)
  bl   seq_puts                ← seq_puts(m, saved_command_line) ⇒ 印到第一个 NUL
```
kallsyms: `ffffffc012b27600 B saved_command_line` ✔ 可写 ⇒ 形状(2) 的配对写 `*(P+8)=C` 也安全
(P 只要**可写**就行: 堆、栈、.data/.bss 都满足; `.text`/`rodata` 会因 STRICT_KERNEL_RWX 直接 panic)。

## 1. 为什么之前那两条读通道是死的(别再重开)

* **`ctl_table.data` 改指**: `__register_sysctl_table@0x106302e4` 里 `kzalloc(n*0x40+0xf9)` +
  `memcpy(hdr+0xf8, table, n*0x40)`(`register_net_sysctl@0x1152b98c` 只是
  `__register_sysctl_table(&net->sysctls,…)`, `add x0,x0,#0xb0`)
  ⇒ **读 `/proc/sys/**` 走的是堆上的表副本**, 改静态模板的 `.data` 对输出零影响。
  (顺带: `/proc/sys/kernel/*` 对 shell 域连 `stat` 都是 EACCES, 只有 `/proc/sys/net/**` 可读 —— 全表已实测 3291 条。)
* **`/proc/config.gz`**: shell 可读(0444, `u:object_r:config_gz`), 但
  `ikconfig_read_current@0x100916c8` = `simple_read_from_buffer(buf,count,ppos, kernel_config_data, 0x1160d5a9-0x11603138)`
  —— 源指针是 **adrp+add 立刻算出来的链接期常量**, 没有可劫持的静态变量 ⇒ 只能读到那块固定的 42 KB 配置 ✗。
* **165 个 ioctl 同类型处理函数**里没有任何一个把 `arg` 当内核指针(见 `argptr_summary.txt`, 全是 uaccess 之后)。

## 2. 顺手钉死的布局(全部来自镜像 `.rela` 表, 不是记忆)

裸 Image 里 `.data/.bss` 的指针字段全是 0, **值只在 rela 记录里**
(`{dest, 0x403=R_AARCH64_RELATIVE, addend}`, 24 字节一条; 本机 127,418 条, 工具 `cm57/ctls2.py`)。

`init_task` 区间内的 rela 记录 = **这个构建的精确 task_struct 布局**:

| 偏移 | 字段 | rela addend |
|---|---|---|
| `+0x068` | `stack` | `init_thread_union` |
| `+0x5e8` | `mm` | `init_mm` |
| `+0x660` | `restart_block.fn` | `do_no_restart_syscall.cfi_jt` |
| `+0x6a0/0x6a8` | `real_parent`/`parent` | `init_task` |
| **`+0x6b0/0x6b8`** | **`tasks`(next/prev)** | 自环 `init_task+0x6b0` |
| `+0x6f8` | `thread_pid` | `init_struct_pid` |
| **`+0x840`** | **`real_cred`** | `init_cred` |
| **`+0x848`** | **`cred`** | `init_cred` |
| `+0x870/878/880/888/890` | `fs`/`files`/`nsproxy`/`signal`/`sighand` | `init_fs`/`init_files`/`init_nsproxy`/… |

交叉验证: `prepare_kernel_cred@0x1031f67c` 里 `ldr x19,[x21,#0x840]` = `get_task_cred(daemon)`
⇒ **`real_cred = +0x840` 独立坐实** ✔; `adrp x19,#0x1293d000; add x19,#0x528` ⇒ `init_cred=0x1293d528` ✔。
另外 `sizeof(struct cred)≈0xa8`, `cred->usage@+0`, `jit_keyring@+0x98`(从 `str wzr,[x19,#0x98]` 看)。

## 3. 用它把 GhostLock 走到底(按"一发一用"排, 目标 = 一 boot 内 4 发)

前提约束(已实测): **一发有效写之后假树就脏了 ⇒ 第 2 发必须换干净的假 lock + 换一个新的幽灵**。
每次 punch 之前 `rt_sigreturn` 会把 0x200 覆盖层重画一遍 ⇒ 载荷可以反复重铺。

| # | 用什么形状 | 写什么 | 读什么 / 为什么安全 |
|---|---|---|---|
| p0 | SHAPE=2(`pc=1`, `right=uts 零洞`) | `root->rb_node=T`, `*(T+8)=S` | `uname()` 读回 S(已真机验证) |
| p1 | 形状(2): `C=&saved_command_line`, `P=S+0x30` | 指针写 | `cat /proc/cmdline` 印出 `waiter->task` = **我们自己的 task_struct 指针 T0**(小端 8 字节无 NUL, 后面紧跟 prio 的 `77 00` 立刻截止 ⇒ 刚好 8 字节, 够用) |
| p2 | 形状(2): `C=T0+0x848`, `P=init_cred+slide` | `task->cred = init_cred` | 配对写落在 `init_cred+8`(gid/suid) ⇒ 本机 uid/cap 全在别处, 且用完就重启 |
| p3 | 形状(2): `C=T0+0x840`, `P=init_cred+slide` | `task->real_cred = init_cred` | 同一格, 幂等 |
| 收尾 | — | — | 让 waiter 线程的 futex **超时返回**(现在真机签名就是 `errno=110`), 由**它**执行 `execve("/system/bin/sh")` ⇒ uid 0 |

要小心的点(每条都记一下, 别再踩):
1. `init_cred` 的 cap 字段必须**已经是全满**(它就是 init 用的 cred) —— 由 p2/p3 之后 `getuid()==0` +
   能 `open("/dev/block/…")` 来判; 不行再用一发形状(1) 零写 `selinux_state`。
2. `waiter->task` 在 `S+0x30` 是**载荷里我们自己填的位置**(窗口字 15 = waiter 字 +6?) —— 打 p1 时那个槽是
   我们铺进去的 `init_task` 还是内核填的真值? **必须是内核真身**: p0 之后 S 处的 node 被 erase/enqueue 涂过,
   但 `+0x30` 的 task 字段是 `rt_mutex_start_proxy_lock` 当初写进去的, 我们的重铺会覆盖它 ⇒
   **p1 的载荷必须不在 `S+0x30` 处放 `init_task`**(改成放"内核真值不被动"的偏移, 或者干脆 p1 读 `S+0x30`
   之前的原始 waiter —— 见 §4 的待验)。
3. `cat /proc/cmdline` 走 `seq_read`, 单次最多约一页 ⇒ 我们要的 ≤64 字节远小于此 ✔。
4. 读到的字节里可能有不可打印字符, 用 `dd bs=1 skip=N` + `xxd` 取, 不要 `cat | head`。

## 4. 待验(下一步)

* [ ] **一发 → 两发存活**: 同一 boot 里 p0(SHAPE=2) 之后再来一发**不同假 lock + 同一 S 重铺**的写,
      看设备活不活(活 ⇒ 上面 4 发的表成立; 死 ⇒ 只能"一次 boot 一次写", 那就要把它省到只剩 p2 一发,
      而 p2 需要 `T0`, 就得先有一 boot 专门读 —— 但那个地址再 boot 就作废 ⇒ 必须多 boot 复用**静态**信息)。
* [ ] `S+0x30` 到底是不是内核填的真 `task` 指针(重铺会不会盖掉它)。若会被盖: 改读 `S+0x28`/相邻槽里
      内核自己写的残渣(例如 `do_futex` 帧里 `q.task = current` 的位置 —— 用 p1 先 dump 一段栈找)。
* [ ] `SELinux` 放行确认: `cat /proc/cmdline` 在 punch 之后仍然可读(读的是 `P` 处, 域不变 ✔)。

## ★ 2026-09-27 深夜：**本文档的前提被真机否掉**（保留原文作为反例）

`run_ctrl2` 的一发 punch 同时留下了两条硬证据：

1. **两笔 store 都真的执行了** —— 最终 `uname()` dump 里出现了
   `f875b29ad9ffffff` = `0xffffffd99ab275f8` = 那一发的 `pc`（= 我们写的 `saved_command_line-8`），
   它正是配对写 `*(child)=pc` 落在"打印起点"（uts+0x24）上的结果 ✔
   ⇒ **任意对齐 8 字节写（含 .bss/.data）+ 同发双写 = 已由真机证实**。
   （另一半证据：同一发之前，`avenrun[0]` 被写成核指针 ⇒ `/proc/loadavg` 第一列变 9.0e15
   = `ptr>>FSHIFT` 精确吻合 ⇒ .bss 可写这一点也钉死了。）
2. **但 `/proc/cmdline` 仍然原样印启动命令行** ⇒ 那个 `char *` 变量**不是**这个构建里
   `cmdline_proc_show` 实际读的那个（或厂商把 cmdline 换成了别处的副本）。

⇒ 结论：**别再拿 `saved_command_line` 当读通道载体**；本文档 §0/§1 的"一发指针写换来任意内核读"
在这台机器上**不成立**。剩下的可用观察面只有 `uname()`（固定 .data 区域，只能看 uts 附近）。
写通道没问题，缺的仍是**动态地址**（自己的 task/cred）⇒ 转去做 shell 可读文件里的
裸内核指针普查（`cm57/kptr_sweep.py`），而不是继续猜载体。
