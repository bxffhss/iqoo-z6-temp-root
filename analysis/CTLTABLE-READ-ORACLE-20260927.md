# 用一发"指针写"把 `/proc/sys/kernel/ostype` 变成任意内核读原语

## 为什么改主意(比假 fops 更省)

假 fops 路线上有一连串硬约束, 今天全部撞上了:
1. `/dev/ashmem` 是 `ashmem_device` 标签, **shell 域 open 直接 EACCES**(实测
   `cat /dev/ashmem` → Permission denied) ⇒ 劫持 `ashmem_misc.fops` 之后**没法在 shell 里验证**;
   `/dev/ion` shell 能开(read 返回 EINVAL ⇒ 走到驱动了), 但它的 `struct miscdevice` 在堆上
   (`ion_device_create()` 里 kzalloc) ⇒ 地址未知 ⇒ 写不了它的 `.fops`。
2. 子任务把 329 个 `unlocked_ioctl` 同类型处理函数(加 read 63 / write 64)全部反汇编过:
   **没有一个把 `file->private_data+0x10` 解引用**, 也**没有一个 `.write` 会往 private_data 里拷**
   ⇒ 拿到 fops 劫持也换不到任意读写; 而且几乎所有 vendor ioctl 会把 private_data 当成
   自己那种设备结构体用 ⇒ 在 `private_data = &某_misc` 的位置上直接 oops/死锁。
   (另: **`ashmem_ioctl` 不能当"安全克隆对照"** —— 它的 SET_NAME 会 `strcpy(pd+0xb,…)`,
   而 pd 就是 `&ashmem_misc`, 会把我们刚写好的 `misc->fops` 又改掉; `mutex_lock(pd+0x138)`
   会锁到邻居 `vsoc_pci_driver`。这条推翻了 `GHOST-FAKE-FOPS-PLAN` 里"先克隆验证"的设想。)

## 新落点: `ctl_table.data`

5.4 `struct ctl_table`(arm64): `procname +0x00 / data +0x08 / maxlen +0x10 / mode +0x14 /
child +0x18 / proc_handler +0x20 / header +0x28`, 条目大小 0x30, 放在 **.data(可写)**。

设备 kallsyms + 镜像扫描结果:
```
uts_kern_table.llvm.175715…  = ffffffc012994938   (.data)
候选条目(按 (maxlen,mode) 匹配):
   条目基址 ffffffc012994968   maxlen=65  mode=0444   ← 5.4 utsname_sysctl.c 里
   条目基址 ffffffc012994a28   maxlen=65  mode=0644      ostype/osrelease/version 在前且 0444
   ⇒ .data 字段地址 = 基址+0x08 = 0x12994970 / 0x12994a30
```
`proc_handler = proc_dostring` ⇒ `cat /proc/sys/kernel/ostype` 会
**从 `table->data` 当作 char[] 往外拷, 遇到 NUL 截止, 最多 maxlen+1 字节**, 且
mode=0444 只要求读权限 ⇒ shell 直接可读, **不需要任何 CFI 兼容函数、不需要设备节点、
不需要 SELinux 放行写**。

⇒ 一发形状(2)的指针写: `C = 0x12994970+slide`, `P = 我们的栈带地址(=S-0x48+8*W)`
  ⇒ `*(C) = P` ⇒ **此后 `cat /proc/sys/kernel/ostype` 就是在读 P 处的内核内存** ✓
  ⇒ 配对那笔 `*(P+8) = C` 落在我们自己可控的带里, 无害 ✓
  (proc_dowatchd? 没有间接调用 ⇒ STRICT_KERNEL_RWX / CFI / SCS 全都不参与)

## 这一发能立刻兑现什么

1. **验证不需要额外前提**: 打完之后 `cat` 出来的应该是我们填在带里的字节(可控内容)
   ⇒ 一眼判定"劫持成立 + 读通道成立", 且**完全可重复**(读不动任何状态)。
2. 先指向带首 `[S-0x48, +64)` 自证; 再把 P 指到**别处**读任意 64 字节 —— 但注意
   `P` 必须同时是"可读的假 wait父"(`*(P+0x10) != S`), 且 P 本身还要当作 erase 的 parent
   ⇒ P 只能是**可读核地址**(✓ 满足) 且不能碰巧让 `parent->rb_left == node`(极小概率)。
3. 有了任意读, 下一步找**自己的 task_struct**: `current` 在 syscall 序言里通常被
   `mrs x21, sp_el0` 取好后**溢出到栈上**, 而栈的绝对地址我们已知(S) ⇒ 直接读
   `[S-0x48, S+0x1B8)` 这段(以及更外面的相邻栈帧)找 `ffffffc0…/ffff8000…` 形状的指针,
   再用它当 `C` 打第二发: `task->cred = &init_cred`(init_cred 链接期 0x1293d528)。
   `real_cred` 用第三发 ⇒ 每发的配对写都落在 `init_cred+8`(同一格, 幂等) ⇒ 不会累积破坏。
   注: `init_cred+8` 是 gid/suid 那几格, 会从 0 变成"C 的地址字节" ⇒ uid(+0x04)不受影响;
   我们的 cap 来自 init_cred 的 cap_* 字段(在更后面)也不受影响 ⇒ `setgid(0)` 靠 CAP_SETGID
   仍然可以修回 gid。这一条**需要在真机上确认**才写进结论。

## 待办(按顺序)

* [ ] `pr.c` 加 `ctl=<hexC>` 模式: 形状(2) + 假 fops 表那套代码复用, 只是 C 换成 ctl_table 的
      `.data` 字段地址, P 换成"指向带首"或"带内某字"(先打带首, 自证)。
* [ ] 打完立刻 `cat /proc/sys/kernel/ostype` 并落盘 ⇒ 期望读回我们填的字节。
* [ ] 用读通道找自己的 `task_struct`(扫栈带里的核指针), 然后再打 cred/real_cred。
* [ ] 记一笔: `ashmem_ioctl` 不能当安全对照(见上), 前一份文档里"克隆验证"那步作废。

## 真机复盘(补, 同一晚)

跑了三轮, 结论比原来的设计更硬:

1. **一次开机只吃得下一发 punch**(原文档写的是"一次有效写", 实际更严: 第二发**必炸**)。
   实测两次:
   - 第 2 发换新假 lock(`uts+0x68`): 立刻炸 ⇒ 那块并不是我以为的零洞
     (`localhost` 出现在 sysname 相对偏移 77 ⇒ uts 里的字段布局和我按 +0x45 推的不一致,
     ⇒ **任何"我记得这里是 0"的地址都不算数**)。
   - 第 2 发复用 lock#1: 第 1 发已经把 `rb_node/rb_leftmost` 写成 S ⇒
     `rb_erase_cached` 走 `rb_leftmost==node` 分支去 `rb_next(S)`, 沿 parent 链上溯会读到
     我们填的 ASCII(`0x4141…`)当指针 ⇒ 也是必死。
   ⇒ 载荷设计要按"**一个 boot 一次写机会**"来排; `hammer` 循环里的"第 2 发"设计作废。

2. **`ctl_table.data` 这条路其实不需要先知道 S**: 一发 punch 里形状(2) 会做**两笔**写
   (`*(C)=P` 和 `*(P+8)=C`), 所以把 `C=ostype 条目的 .data 字段`、`P=任意可读**且可写**的
   核地址` 一次打出去, 之后 `cat /proc/sys/kernel/ostype` 就是在读 `P` 起的 64 字节 ⇒
   **读操作本身可重复**, 不受"一次 boot 一发"的限制。
   ★ 关键约束: 配对那笔落在 `P+8` ⇒ **P 必须在可写段**(.data/.bss), 选 `.text` 直接 panic。

3. `leaked_stack()` 的 4 字节错位 bug(已修): `sysname` 在 `init_uts_ns+0x04`,
   所以内核里 8 对齐的字只出现在 sysname 偏移 ≡4 (mod 8) 处; 按 8 步进扫会**系统性错过**
   S。第一轮我是手算读出来的, 把这个 bug 盖了一整晚。
   修好后同一轮就自动打出 `[scan] name+20 = ffffffc032f7bbd8` ⇒ S。

4. 两次泄漏到的 S 低 12 位完全相同(`…bbd8`, top=`…bc00`+0x4000 ⇒ S=栈顶-0x428)
   ⇒ 栈内偏移是确定的, 只有**页/栈基**每次开机随机 ⇒ 光靠 S 也定位不到 task_struct。

## 下一步(已按"一发一用"重排)

* 单发 = `C=0x12994970+slide`, `P=<某个 .data 里放着有用指针的地址>` ⇒
  当场用 `cat /proc/sys/kernel/ostype` 反复读 `P` 起的 64 字节, 从里面找
  `task_struct *` / `cred *` 形状的指针; 下一次 boot 再用一发把 `task->cred` 写成 `&init_cred`
  (两发跨两个 boot; 配对写固定落在 `init_cred+8`, 幂等)。
* 待核: `ctl_table` 条目里 0444 的那个到底是不是 `ostype`(读回的是不是我们的标记)。
