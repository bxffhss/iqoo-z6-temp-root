# IOCTL-CFI-165 审计报告 (20260926)

对象：`unlocked_ioctl` 同类型 CFI 表（n=165，表基址 `0xffffffc011589764`，取自 `analysis/cfi_type_tables.txt` 中含 `ashmem_ioctl` 的那一行，按 `|` 切分）。
反汇编唯一依据：`C:/qemu_test/vmlinux_full.asm`（与 `analysis/kernel` 字节一致）。所有 165 个函数体已一次性抽取（每个函数 = 标签行到下一标签行），本报告引用的每一条指令均为原文摘录。

调用上下文（前提，全篇通用）：`f_op->unlocked_ioctl(file, cmd, arg)`，`file` 为我们自己的 `/dev/ashmem` struct file；`file->private_data`（`struct file` +0xd8，下文简称 pd）指向一个 `struct ashmem_area`（内核堆，绝对地址未知，per-open 稳定）；`cmd`/`arg` 完全受控。ashmem_area 已知偏移：`file@+0x120`, `size@+0x128`, `prot_mask@+0x130`, `mutex@+0x138`；name 字符串缓冲经反汇编证实起于 **+0xb**（见下文 A 节）。

---

## 1. 判决

**有。** 本 165 集合中确认：

- **Class W（受控值写入 private_data+固定偏移）≥ 5 个**：
  - **W1 ashmem_ioctl**（无前置条件；≤255 字节用户字符串写入 `pd+0xb`；8 字节标量写 `pd+0x130`/`pd+0x128`）
  - **W2 binder_ioctl**（4 字节任意用户值写入 `pd+0x178`，超出 name 区；唯一副作用是对 `pd+0x230` 的 spin_lock 写）
  - **W3 sg_ioctl**（2×4 字节用户派生值写入 `pd+0x68/0x6c`，值被钳到 ≤13106；有 `[pd+0x10]≠0` 等前置）
  - **W4 watchdog_ioctl**（4 字节用户值写入 `pd+0x38`；条件：需先伪造出合法的 `pd+0x18`、`pd+0x20` 指针 ⇒ 依赖堆地址泄露）
  - **W5 fastrpc_device_ioctl**（4 字节小值 ∈{0,1}/{0..3} 写入 `pd+0x90`/`pd+0xa4`；弱）
- **Class L（从 private_data 派生内核内存 → 用户）≥ 1 个强候选 + 2 个条件候选**：
  - **L1 acc_ioctl**（最强：`copy_to_user(arg, pd+{0x108,0x208,…,0x608}, strlen+1)` — 字符串长度无上限 ⇒ 越过 ashmem_area 尾部的**堆 OOB 读**；另有 `ldrsw [pd+0x70c]/[pd+0x710]` 直接作为 ioctl 返回值 ⇒ 2 个 4 字节 OOB 标量泄露。**不需要任何 KASLR 已知量、无指针解引用、无锁**，纯安全读取（线性映射内））
  - L2 sync_file_ioctl、L3 snd_timer_user_ioctl_compat（多跳解引用链，条件性，见 D 节）。

最有价值的组合：**L1（acc_ioctl 泄露堆内容/KASLR）→ W1（ashmem SET_NAME 在 name 区伪造指针）→ 各条件型多跳链（evdev/sync_file/dma_buf/dispatch 等被解锁）**；以及不依赖泄露的独立 W1/W2。

---

## 2. 候选详情（指令级证据）

### A. ashmem_ioctl — `ffffffc010eee780`（W1 + L-弱）

prologue（寄存器钉死，后文直接引用）：
```
ffffffc010eee7a8: aa0203f4      mov x20, x2          // x20 = arg
ffffffc010eee7ac: 2a0103f5      mov w21, w1          // w21 = cmd
ffffffc010eee7b8: f9406c13      ldr x19, [x0, #0xd8] // x19 = file->private_data (asma)
```

**(a) ASHMEM_SET_NAME = 用户字符串 → strcpy 到 `pd+0xb`**（cmd `0x40087703`）：
```
ffffffc010eee83c: 528ee068      mov w8, #0x7703
ffffffc010eee840: 72a80108      movk w8, #0x4008, lsl #16
ffffffc010eee844: 6b0802bf      cmp w21, w8
ffffffc010eee848: 540013c0      b.eq 0xffffffc010eeeac0
...
ffffffc010eee944: 52802002      mov w2, #0x100                 // 上限 256
ffffffc010eee948: aa1403e1      mov x1, x20                    // src = arg (用户)
ffffffc010eee98c: 97e66347      bl  0xffffffc0108876a8 <strncpy_from_user>   // -> sp+0x18
ffffffc010eee9b0: f9409268      ldr x8, [x19, #0x120]          // asma->file
ffffffc010eee9b4: b4000cc8      cbz x8, 0xffffffc010eeeb4c     // file==NULL 才允许
...
ffffffc010eeeb4c: 91002e60      add x0, x19, #0xb              // dst = pd+0xb  (name缓冲!)
ffffffc010eeeb50: 910063e1      add x1, sp, #0x18
ffffffc010eeeb54: 9419612c      bl  0xffffffc011547004 <strcpy>
```
⇒ `strcpy(pd+0xb, 用户串)`，长度 = 用户串长（≤255，strncpy 界 0x100）。内容任意直至首个 NUL。内核堆指针 `0xffffffc0…` 的小端字节序不含 0x00，**可在 name 区内完整伪造 8 字节指针链**（自 name+0x3d 起任意对齐）。前置条件仅 `asma->file(pd+0x120)==NULL` —— 匿名创建的 ashmem_area 满足（同一函数 0xeeeacc 的 SET_SIZE 路径也用该判空）。

**(b) ASHMEM_SET_PROT_MASK（cmd `0x40087705`）= 8 字节标量写 `pd+0x130`**：
```
ffffffc010eee858: 54001ea1      b.ne ...            // cmp w21, #0x40087705
ffffffc010eee868: f9409a68      ldr x8, [x19, #0x130]
ffffffc010eee86c: ea28029f      bics xzr, x20, x8   // 仅要求 arg 与旧掩码关系
ffffffc010eee890: f9009a74      str x20, [x19, #0x130]   // 8字节: arg -> pd+0x130
```
**(c) ASHMEM_SET_SIZE（cmd `0x40087703+?`，0xeeeac0 块）= 8 字节全任意写 `pd+0x128`**：
```
ffffffc010eeeac8: 9419a274      bl  0xffffffc011557498 <mutex_lock>   // (x19+0x138)
ffffffc010eeeacc: f9409268      ldr x8, [x19, #0x120]
ffffffc010eeeae4: aa1f03f6      mov x22, xzr
ffffffc010eeeae8: f9009674      str x20, [x19, #0x128]   // size = arg(64位任意值)
```
判据：`x20` 即第 3 参数 `arg`，不经过任何校验/掩码 ⇒ **单个 8 字节全可控标量写**（条件同样是 `pd+0x120==0`，见 0xeeeae4 的 `cbz` 落点）。
(d) ASHMEM_GET_NAME 为弱 L（`strlen(pd+0xb)` 后 copy_to_user，见 `ffffffc010eee8f4: ldrb w8,[x19,#0xb]!`、`0xeeeeb34: bl _copy_to_user`）——读的是我们自己写的 name，泄露价值仅在于 name 未初始化时（新分配 area 的 name 前缀逻辑见 0xeeeaf8-0xeeeb0c 的 11 字节 "ashmem-" memcpy）。
compat 入口 `compat_ashmem_ioctl ffffffc010eeece4` 只是改 cmd 后 `bl ashmem_ioctl`（`ffffffc010eeed28: bl 0xffffffc010eee780`），继承全部原语。

### B. binder_ioctl — `ffffffc010f4af4c`（W2：4B 任意值 @ pd+0x178）

```
ffffffc010f4af88: f9406c15      ldr x21, [x0, #0xd8]       // x21 = pd
...
ffffffc010f4b314: 528c40a8      mov w8, #0x6205
ffffffc010f4b318: 72a80088      movk w8, #0x4004, lsl #16  // cmd = 0x40046205 BINDER_SET_MAX_THREADS
ffffffc010f4b31c: 6b08029f      cmp w20, w8
ffffffc010f4b320: 54008be1      b.ne ...
ffffffc010f4b324: 9100c3e0      add x0, sp, #0x30
ffffffc010f4b328: 52800082      mov w2, #0x4
ffffffc010f4b32c: aa1303e1      mov x1, x19                // x19 = arg
ffffffc010f4b334: 97c54c8f      bl  0xffffffc01009e570 <_copy_from_user>
ffffffc010f4b338: b50045a0      cbz x0 跳过错误 ...
ffffffc010f4b360: 9108c2b7      add x23, x21, #0x230
ffffffc010f4b368: 94184b8f      bl  0xffffffc01155e1a4 <_raw_spin_lock>
ffffffc010f4b36c: b94033e8      ldr w8, [sp, #0x30]        // 用户 4 字节值
ffffffc010f4b370: b9017aa8      str w8, [x21, #0x178]      // *** 任意4B值 -> pd+0x178 ***
```
判据： traced 路径上无 `proc->tsk == current` 门（0xf4af88 载入 pd 后到该分发块之间仅有 `b 0xf4b054` 与全局状态分发；0xf4c3ec 落点是 preempt 计数处理不是 EPERM——已逐行核对）；copy_from_user 与 store 之间无值校验。`pd+0x178` 在 ashmem_area name 区（0xb..0x10a）之外，属于"结构尾部或其后的邻接对象"——即真正超出自身可控区的**额外**写点。
风险/前置：入口需要 `pd!=0`（天然满足）；对 `pd+0x230` 做 `_raw_spin_lock` —— 该处若为邻接对象且非 0 会死转（软锁死）。若 area 落在 kmalloc-512/1024 槽内，0x230 大概率是本槽尾部填充（新分配常为 0，可获取锁）。可用 L1 先窥探再决定。次级发现：freeze 路径对 `pd+0x50` 做 `ldrb/ldr w8; add #1; str`（`ffffffc010f4c56c/574`）—— name 区内的可控递增。

### C. acc_ioctl — `ffffffc010ce507c`（L1：直读 pd+固定偏移 → 用户）

```
ffffffc010ce5090: f9406c08      ldr x8, [x0, #0xd8]        // x8 = pd
ffffffc010ce5094: 52965fe9      mov w9, #0xb2ff
ffffffc010ce5098: 72b7dfe9      movk w9, #0xbeff, lsl #16
ffffffc010ce509c: 0b090029      add w9, w1, w9             // cmd - 0x41004d01
ffffffc010ce50a0: 7100153f      cmp w9, #0x5
ffffffc010ce50a4: 54000168      b.hi ...
ffffffc010ce50bc: aa0203f3      mov x19, x2                // x19 = arg(用户缓冲)
ffffffc010ce50c0: d61f0160      br x11                     // 6路表跳转
ffffffc010ce50c4: 91042114      add x20, x8, #0x108        // src = pd+0x108   (其余入口 +0x208/+0x308/+0x408/+0x508/+0x608)
...
ffffffc010ce5114: 97ce9f5b      bl  0xffffffc01008ce80 <strlen>     // 长度 = 内核堆内容决定，无上界
ffffffc010ce5140: 97cf3633      bl  0xffffffc0100b2a0c <_copy_to_user>   // dst=x19(arg), src=x20(pd+k), len=x21
```
以及两条**返回值泄露**：
```
ffffffc010ce50d0: 5289a0e9      mov w9, #0x4d07
ffffffc010ce5170: b9870d00      ldrsw x0, [x8, #0x70c]     // cmd 0x4d07: 4B OOB 读 -> syscall 返回值
ffffffc010ce50dc: 5289a109      mov w9, #0x4d08
ffffffc010ce50e8: b9871100      ldrsw x0, [x8, #0x710]     // cmd 0x4d08
```
判据：ashmem_area 只有 ~0x190 字节，`pd+0x108..0x608`/`0x70c/0x710` 覆盖本结构与后续邻接 slab 对象；全部在线性映射内 ⇒ 不会 oops；`strlen` 无上限是唯一坏情况（连续非零可跨页直到未映射处，实际 kmalloc 页全映射，读出后 copy_to_user 按用户缓冲长度自然截断的是**源**长度=会全量拷贝 ⇒ 建议从 0x70c 标量与 0x108 起步逐偏移扫描）。这是 165 集合中**唯一无条件、无解引用、可重复的 OOB 堆读**。

### D. 其余 L/多跳候选（记录但不作首选）

- **sync_file_ioctl `ffffffc010badf04`**（`ldr x20,[x0,#0xd8]` @0xbadf38）：SYNC_IOC_FILE_INFO 路径 `ffffffc010bae044: ldr x0,[x26,#0x48]!` 起跳两级解引用，随后 `0xbae054: cmp x8,x9` 校验 fence_ops 合法性（`__param_str_noblk+0x38` 区间），再按 `[fence+0x44]` 个数组项 copy_to_user（`0xbae24c`）；项指针经 `blr x8`(ops->fence_get_info?) 遍历且 ror 界 0x12 校验 ⇒ 仅在已泄露地址、能在 name 区伪造合法 ops 后可用（条件 L/类型混淆）。
- **snd_timer_user_ioctl_compat `ffffffc010f89c64`**：`ldr x8,[x0,#0xd8]` → `add x19,x8,#0x90; mutex_lock` → 组装 88 字节结构后 `ffffffc010f89fb4: bl _copy_to_user`；数据源为 `[x24]`、`[x24,#0x18]`、`[x24,#0x28]`，x24 来自 pd 链上一跳 ⇒ 需伪造指针，条件性。
- **evdev_ioctl `ffffffc01017c024`**（wrapper，仅 38 行）：
  ```
  ffffffc01017c03c: ldr x23, [x0, #0xd8]
  ffffffc01017c04c: ldr x24, [x23, #0x18]     // 一跳：读 [pd+0x18] 当 struct evdev*
  ffffffc01017c050: add x19, x24, #0x88       // mutex 在其 +0x88
  ffffffc01017c068: ldrb w8, [x24, #0x4e0]    // 再解引用
  ffffffc01017c090: bl evdev_do_ioctl         // EVIOCS* 的 heap 写在 callee 内(不在165表,但经此 wrapper 可达)
  ```
  ⇒ 需先有堆泄露伪造 `pd+0x18`；一旦成立，`evdev_do_ioctl` 的 EVIOCSABS/copy 路径即成任意写链。**当前状态下 = oops**。
- **dispatch_ioctl `ffffffc010713c50`**：`ldr x8,[x0,#0x20]`(inode)→`[x8,#0x28]`→`ldr x19,[x8,#0x490]; cbz 退出` —— 沿 ashmem 伪文件系统 inode 的固定字段取指针，字段为 0/不可控 ⇒ 直接安全返回，判死。
- **vsoc_ioctl `ffffffc010ef06d4`**：`ffffffc010ef0724: ldr x9,[x0,#0xd8]` 后仅 `cbz` 判空，随后全部走全局 `vsoc_dev` 与 inode minor 派生 ⇒ pd 无关，判死。
- **mhi_uci_ioctl `ffffffc0100e0ee0`**：`ffffffc0100e0f70: str w8,[x23,#0x158]`（x23=pd），但 `w8 = ldr [x20,#0x3c8]`，x20 来自 pd 链上另一结构 ⇒ 非用户值，且先 `mhi_ioctl` 大概率报错；弱 X。

### E. W3/W4/W5 的次级直写候选（判据摘要）

- **sg_ioctl `ffffffc010beeaf0`**：入口 `ldr x20,[x0,#0xd8]`；`ffffffc010beeb28: ldr x25,[x20,#0x10]; cbz →-ENODATA`（可先 SET_NAME 使 +0x10 非零）；SG_SET_TIMEOUT(0x2201) 路径经用户读（TTBR 交换式 get_user，`...b940012a/str w10,[x9]` 系列块）后落入：
  ```
  ffffffc010befff4: 52866649      mov w9, #0x3332     // 13106 上限钳制
  ffffffc010bf0008: 1a89b108      csel w8, w8, w9, lt
  ffffffc010bf0044: 290d2289      stp w9, w8, [x20, #0x68]   // 2×4B 用户派生值 -> pd+0x68/0x6c
  ```
  注意同一函数还有 `strb` 群 `x26 = pd+0x13a8`（结构外数 KB 的字节写！`ffffffc010bf00ec/0230/0500/0718` — 值多为 0/1 常量，先读后跳，地址盲）。
- **watchdog_ioctl `ffffffc010df3638`**：`ffffffc010df3658: ldr x20,[x0,#0xd8]`；WDIOC_SETTIMEOUT 路径 get_user 值入 w21 后：
  ```
  ffffffc010df3f30: ldr x8,[x20,#0x18] ; ffffffc010df3f34: ldrb w8,[x8,#0x1]   // 需伪造 [pd+0x18]
  ffffffc010df3f50: ldr x8,[x20,#0x20] ; ffffffc010df3f54: ldr x22,[x8,#0x30]  // 需伪造 [pd+0x20]->P, P+0x30==0
  ffffffc010df3f58: cbz x22, 0xffffffc010df40fc
  ffffffc010df40fc: b9003a95      str w21, [x20, #0x38]   // 用户4B值 -> pd+0x38
  ```
  两个被解引用槽（+0x18/+0x20）都落在 name 区 ⇒ 泄露后可用 name 指向 area 自身零区满足 `P+0x30==0`；另有 `str w23,[x20,#0x34]`（0xdf4168）与 ops->set_timeout 的 `blr x22`（带 `__cfi_slowpath` 校验，0xdf412c）。
- **fastrpc_device_ioctl `ffffffc0109e4300`**：`ldr x19,[x0,#0xd8]`；`ffffffc0109e4db0: str w20,[x19,#0x90]`（入口 `0x9e4a78: cmp w20,#2 / b.lo` ⇒ w20∈{0,1}）、`ffffffc0109e4e54: str w22,[x19,#0xa4]`（`0x9e4e14: cmp w22,#3; b.hi` ⇒ 0..3）、`ffffffc0109e4dd4: str w8,[x19,#0x94]` w8=2 常量；`ffffffc0109e4564: str w8,[x19,#0xa0]` 值为当前 task cred（来自 SP_EL0+0x694，非用户）。全部在 name 区内 ⇒ 相比 SET_NAME 无增量，仅作"不可 NUL 截断场景"的备用位写入。

---

## 3. 排除方法与已判死清单（可复用）

方法：(1) 165 个函数体从 `vmlinux_full.asm` 单遍 awk 抽取；(2) 每个函数统计：行数、`copy_*_user/put/get_user` 调用目标、`#0xd8` 出现数、`ldr xN,[x0,#0xd8]` 的 N 寄存器与 `str/stp [xN,#imm]` 交集；(3) 对交集与全部"大函数+双向拷贝"逐个读窗口验证值的来源（arg/用户缓冲 vs 常量/cred/链上结构）与基址来源（真 pd vs 复用寄存器）。

被排除的典型类别与理由：
- **纯转发/桩**（≤12 行，无 pd 访问）：`usbdev_ioctl, uinput_ioctl, tun_chr_ioctl, subdev_ioctl, video_ioctl2, vfs_ioctl, bus_ioctl, dimm_ioctl, compat_*` 等 ~40 个 —— 它们 `b`/`bl` 到表外函数，被调函数地址不在 165 集合内也能工作（CFI 只约束 indirect），但转发目标的写入基址都不是我们的 pd；`fat/ext4/f2fs/overlay` 系需要真 super_block inode，第一步 `ldr [inode]` 即取到 ashmem 伪 fs inode，指针校验失败或解引用为 0 → 安全返回 ENOTTY/oops 边缘，均不可用。
- **文件系统类**（`ext4_ioctl, f2fs_ioctl, fat_*, fuse_*`）：`file->f_inode/f_mapping` 是 ashmem 伪 fs 的，`EXT4_SB(sb)` magic 校验（如 fuse 的 `super_operations` 检查）⇒ 判死（f_cdev_ioctl 的 28 条 `strh w8,[x21,#0x5c2]` 全部是常量位标志且 x21 实为复用的设备 ctx——首个 `ldr x21,[x0,#0xd8]` 后即被 `bl` 换出，非 pd 直写）。
- **仅读 [x0,#0x20]inode/全局设备**（vsoc、dispatch、media*、drm 系）：pd 不进入写路径（见 D 节 dispatch/vsoc 证据）。
- **值不可控的直写**：rpmsg_eptdev（`ffffffc0101d60dc: str xzr,[x19,#0x488]` — 常量 0，且先 `mutex_lock(pd+0x458)`、`ldr x0,[pd+0x488]→rpmsg_destroy_ept(垃圾)` 必炸）；aw869xx（`ffffffc010b8ae34: strb w8,[x20,#0x41b]`，w8=2 常量）；glink_pkt（`str wzr`）；media_request（`ffffffc010d3fb80: str w8,[x19,#0x28]`，w8=#4 常量）。
- **binder 的 [x21,#0x50]、kgsl/qcedev/qseecom/snd_*/tty/rtc/linehandle/seccomp/stm/synx/hiddev/inotify/pipe/posix_clock 等**：扫描其 pd 寄存器上无"来自 arg/用户值"的直接 store；写全部经 ≥2 跳（前跳内容默认零 ⇒ 提前返回或 oops），或值为常量/cred。tty_ioctl 的 660 行内 x8=pd 在首个 mutex 链上即被多级解引用，无泄露不可达其写点。
- **`logger_ioctl / msm_rng_ioctl / random_ioctl / spcom_device_ioctl / gsi_ctrl_dev_ioctl / nb_ioctl / ccid_ctrl_ioctl`**：pd 直取指令模式下无任何 `str [pd]`。

## 4. 未能确定（诚实声明）

1. **`pd+0x230`（binder spinlock 地址）与 `pd+0x178` 的实际落点**：`struct ashmem_area` 的精确大小/所在 kmalloc 槽级无法从纯静态确定（需 `kmem_cache` 尺寸推断或动态验证）。binder W 的可用性取决于该字是否碰巧为 0（否则 `_raw_spin_lock` 死转软锁机）。
2. **watchdog/evdev/sync_file/snd_timer_user 链**在拿到堆泄露后的完整可达性未逐跳验证（只验证了第一跳槽位落在 name 区可伪造范围内）。
3. **sg 的 165 项 cmd 二分表**（`ldrh [x12,x10,lsl#1]` @0xbeeb78）中 SG_SET_TIMEOUT 是否还有未走到的中间校验（`[x25]` 的下游解引用是否在该 case 先于 store 执行）——按线性扫描推断路径成立，未做完整 CFG 证明。
4. **acc_ioctl 的字符串源 `pd+0x108..0x608` 在 area 新分配时的初始内容**未知（正是它作为 L 的价值来源，但也意味着首次触发读出质量未知）；strlen 无上限导致跨多页 copy_to_user 的最坏行为（可复制大小时用户缓冲被写满 -EFAULT 前内核侧已完成读取）未实机验证——本审计纯静态。
5. CFI shadow 的位图校验在 `__cfi_slowpath` 路径的具体行为（如 binder 0x40046205 路径上 `blr x22` 的 notifier 链，其目标类型 id 校验细节）未展开——所列候选 W1/W2/W3/C-L1 均不含 indirect call，不受影响。
