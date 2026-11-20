# CFI 同类型表重建 + ashmem f_op 写通道判定 (2026-09-26)

## 0. 一句话结论

**`show_fdinfo` 槽的 CFI 同类型集合 = 13 个函数，全部是"往 seq_file 里打印 fd 信息"的只读实现，
一个都不写内核内存 ⇒ 经 `f_op->show_fdinfo` 拿"非栈写通道"这条路判死。**
同一次重建还给出：`->mmap` 槽同类型只有 4 个(无任意 pfn 映射者)，`->unlocked_ioctl` 槽有 165 个
(唯一还没审的菜单)。副产品是一份可复用资产：**14,257 张全内核同类型表**。

---

## 1. 先纠正三件承重事实

### 1.1 上一轮"kernel.elf 与运行内核不是同一构建"的判断是**我的算术错误**
`C:/qemu_test/kernel.elf` 是"在原始 Image 前面塞了 64 字节 ELF 头"的手工产物，
但它的 program header 让 `vaddr ↔ file offset` 整体**偏移了 0x38**。
所以我在 `0xffffffc010eeed38` 处读到的是 ashmem_ioctl 的代码而不是 ashmem_mmap 的序言，
我据此判"不同构建"。**撤回该结论。**

### 1.2 真正的离线镜像与 `vmlinux_full.asm` 逐字节自洽
用 `ashmem_mmap` 序言的 7 条指令编码(小端)在三个文件里搜：

| 文件 | 命中处推出的 vaddr |
|---|---|
| `C:/qemu_test/Image` (73MB) | `0xffffffc010eeed38` ✅ 与 asm 标签一致 |
| `analysis/kernel` (44,661,248B) | `0xffffffc010eeed38` ✅ |
| `C:/qemu_test/kernel.elf` | `0xffffffc010eeed70` ← 差 0x38，即 1.1 |

映射规则：**`vaddr = 0xffffffc010080000 + fileoff`**（`analysis/vmlinux_workflow.md` 的说法成立）。
另一处独立自校验：上轮从已删除的 `vmlinux.elf` 导出的 `cfi_check_jt.asm` 里
`0x115855ac = 0x17f7741c`，今天在 `analysis/kernel` 文件偏移 `0x15055ac` 解出同一个字 ✅。

### 1.3 离线镜像确实不是真机那个 build，但 config 逐字节相同
| | 版本串 | 构建时间 |
|---|---|---|
| 真机运行 | `5.4.281-qgki-g**2a88cd145def**` | Wed May 7 12:07:39 CST **2025** |
| 离线镜像(全部三份) | `5.4.281-qgki-g**bfef221370b4**` | Thu Jun 18 09:47:45 CST **2026** |

**新证据（此前没人做过）**：从镜像里 carve 出内嵌 IKCONFIG（magic `IKCFG_ST` 在文件偏移
`0x1583130`，gzip 数据从 `0x1583138` 起）与真机 `/proc/config.gz` 逐行 diff：

```
dev_config.txt (7041 行)  vs  img_config.txt (7041 行)   diff = 0 行
```

⇒ 同 arch / 同 clang(Android r383902b 11.0.2) / **同 .config**。
**结构体偏移可以跨这两个 build 迁移**（残余风险：两个 commit 之间厂商改过结构体定义本身）；
**代码地址不可以**（13 个月的厂商 commit 足以搬动函数位置）。

---

## 2. 真机一手证据（不依赖任何 ELF）

### 2.1 `f_op->show_fdinfo` 在真机上确实被派发 —— P47
app 里 `open(/dev/ashmem)` → `ASHMEM_SET_NAME("P47SENTINELNAME")` → 读 `/proc/self/fdinfo/84`：

```
pos:    0
flags:  0400002
mnt_id: 27542
ino:    14839
name:   P47SENTINELNAME      ← 我们写进内核堆的串，被内核打印回来
```
两组对照组都干净：
* `/dev/null` 的 fdinfo → 只有前 4 行通用字段，**无 name:**
* **不设名**的第二个 ashmem fd → 同样**无 name:**

⇒ `name:` 行只可能来自 `ashmem_show_fdinfo`，即 **`file->f_op->show_fdinfo` 这一槽被 proc 读取路径
真实调用**。这是"槽存在且被走"的功能级证明，比读 ELF 硬。
附带确认：`ASHMEM_GET_NAME = 0x81007702` 可用（默认名 `dev/ashmem`），app 域
`ioctl(/dev/ashmem, ...)` 循环能跑到 **1.26 M 次/秒**。

### 2.2 KASLR 只能从 shell 侧拿，且 slide 每次开机都变 —— P46
| 通道 | 结果 |
|---|---|
| app `perf_event_open(SW cpu_clock, exclude_user=1)` | **EACCES(13)**（`paranoid=-1` 也拦不住 SELinux） |
| shell `perf_event_open(pid=<app pid>, cpu=-1)` | **EACCES(13)**（跨进程要 `ptrace_may_access`，SELinux 拒） |
| shell `cat /proc/kallsyms` / `cat /proc/sys/kernel/kptr_restrict` | **EACCES(13)** |
| shell 自采样（本进程 pid=0） | ✅ 这是 `HANDOFF §U` 拿到 slide 的方式，仍是唯一可用通道 |

**slide 不是常量**：`HANDOFF` 记录 `0x264f200000`，而 9-25 的 `perf_ips.txt` 里的内核 IP
落在 `0xffffffd129ec…0xffffffd12b15`（推出 slide ≈ `0x1129c0…`）⇒ 中途重启后 base 变了。
⇒ ** exploit 时必须在现场测 slide**，不能写死。

顺带否掉一个我差点得出的错误结论：拿 403 个真机 IP 与离线 kallsyms 做"整体平移互相关"，
23/23 命中的候选 slide 有 **24,870 个** —— 因为符号平均每 290 字节一个，任何把 IP 落进 text 的
平移都"全命中"。**这个检验没有判别力**，不能用它证明布局等价（相对距离在平移下不变）。

---

## 3. 同类型表是怎么重建出来的（方法，可复用）

`CONFIG_CFI_CLANG=y` + `SHADOW`，clang 原生 CFI（**不是** kCFI：函数体里没有 `mov w16,#id` 前导，
序言是 SCS `str x30,[x18],#8`）。机制：

1. **`.text.cfi_jt`**：每条是一个光杆 `b <target>`。在 `analysis/kernel` 里从 vaddr
   `0xffffffc01156a928` 起有 **连续 41,466 条 `b` 桩**（165,864 字节）——就是整张节。
2. **调用点**里 clang 用 `adrp x?, #<本类型表首页>` + `add x?, x?, #:lo12:<表首>` 算出**该函数类型
   自己的表基址**，再用 `sub/cmp` 做区间校验，越界才 `bl __cfi_slowpath`（此时 `x0` 是被
   `mov`+3×`movk` 拼出的 **64 位类型哈希**）。
   ⇒ **收集所有"落在桩表内的 adrp+add 结果"= 拿到全部 per-type 表边界**。
   踩过的坑：JS 里 `w & 0x9f000000` 出的是**带符号 int32**，与 `0x90000000` 比较恒不等 ⇒
   必须 `>>> 0`。修好后从 0 个基址变成 **14,257 个**。
3. 表区间 = [本基址, 下一个基址)，成员即"与之一模一样类型、可以互相顶替"的函数集合。

**为什么这套切分可信（正对照）**：切出来的最大几张表语义完全自洽 ——
`n=508` 全是 `__arm64_sys_*`（系统调用表）、`n=840` 全是 `trace_raw_output_*`、
`n=663` 全是 `int (*)(void)` 的 initcall、`n=505` 全是 `trace_event_define_fields_*`。

资产：`analysis/cfi_type_tables.txt`（1.3MB，14,257 行，每行 `表基址 n=成员数 名字|名字|...`，按 n 升序）。
工具：`C:/qemu_test/cfi_types.js`（重建+导出）、`C:/qemu_test/cfi_set.js <符号名>`（查单个槽的同类型集）、
`C:/qemu_test/cfi_scan.js`（找连续 `b` 大块）。

---

## 4. 三条槽的判定

### 4.1 `->show_fdinfo`：13 个成员 ⇒ **写通道判死**
表基址 `0xffffffc01157e17c`（被 pc `0x102466f0`、`0x1062d868` 引用），成员：

`bpf_btf_show_fdinfo` `inotify_show_fdinfo` `bpf_map_show_fdinfo` `tun_chr_show_fdinfo`
`timerfd_show` `bpf_prog_show_fdinfo` `ep_show_fdinfo` `signalfd_show_fdinfo`
`tty_show_fdinfo` `ashmem_show_fdinfo` `dma_buf_show_fdinfo` `eventfd_show_fdinfo`
`pidfd_show_fdinfo`

正好是 5.4 安卓内核里**全部** `->show_fdinfo` 实现 ⇒ 切分正确。
全部效果都是 `seq_printf/seq_putc` 往 `m->buf` 里写 ⇒ **没有任何一个能写内核任意地址**。
唯一残值是"类型混淆式泄露"：例如把 ashmem 的 fd 顶成 `bpf_prog_show_fdinfo`，它会把
`struct file` 按 `struct bpf_prog` 的偏移去读并打印（`prog_type`/`prog_tag`/`jited`/跟 `aux` 指针）
⇒ 可读 `struct file` 内的 `f_op`/`private_data`/`f_path` 等指针，**是 KASLR 泄露的形状**，
但**前提仍是先有那一次写**。

（注意：上表 13 项与 §2.1 的功能级证明要分清 —— **槽被走** 已在真机证；
**槽的偏移**（`file_operations` 内 `show_fdinfo` 的 `#imm`，以及 `file->f_op` 的 `#imm`）
目前仍只有"同 config 可迁移"这一级证据，**没在真机上量过**。）

### 4.1b 调用点本身把两个承重偏移和校验形式钉死了（同一 config 的二进制里）
`seq_show`（fs/proc/fd.c）@ `0xffffffc01062d868` 起的原文：

```
ffffffc01062d85c: f94016a8   ldr  x8, [x21, #0x28]     ← x21 = struct file*  ⇒ file->f_op = +0x28
ffffffc01062d860: f9407114   ldr  x20, [x8, #0xe0]     ← ⇒ file_operations->show_fdinfo = +0xe0
ffffffc01062d864: b4000154   cbz  x20                  ← 槽为 0 只是跳过（清零不是崩溃）
ffffffc01062d868: b0007a88   adrp x8, 0xffffffc01157e000 <...cfi_jt>
ffffffc01062d86c: 9105f108   add  x8, x8, #0x17c       ← 本类型表基址 = 0x1157e17c（与我重建的完全一致）
ffffffc01062d870: cb080288   sub  x8, x20, x8
ffffffc01062d874: 93c80908   ror  x8, x8, #0x2         ← /4
ffffffc01062d878: f100351f   cmp  x8, #0xd
ffffffc01062d87c: 540001c2   b.hs __cfi_slowpath 分支   ← 越界才走慢路径
ffffffc01062d888: d63f0280   blr  x20
```

⇒ 三点收获：① **`f_op@0x28`、`show_fdinfo@0xe0`**（此前记忆里的 `0x20`/`+0x70`/`0x2a8` 都不对）；
② 校验形式 = `(target - 表基址)/4 <= 13`，**表基址就是我从调用点 adrp+add 恢复出来的那个值** ⇒
"用调用点基址切 per-type 表"的方法被一手代码验证；
③ `cmp #0xd` 允许 14 个槽位，而我按"下一个表基址"切出来是 13 个成员 ——
第 14 项是 `drm_i2c_encoder_detect`（语义上不可能属于本类型），
判为**表尾对齐余量**（13 项 = 52 字节，按 8 字节对齐进位到 56 字节 ⇒ 上界写成 13）。
不影响"这一类型只有 13 个 `*_show_fdinfo`"的结论。

### 4.2 `->mmap`：4 个成员 ⇒ 没有任意物理映射
`ashmem_vmfile_mmap` | `snd_disconnect_mmap` | `generic_file_mmap` | `ashmem_mmap`
—— 没有一个是 `remap_pfn_range(vma, …, vma->vm_pgoff, …)` 型的"用户给 pfn 就映射"的 handler，
所以顶掉 `->mmap` 也换不到物理内存读写。

### 4.3 `->unlocked_ioctl`：165 个成员 ⇒ 唯一未审的菜单
表基址 `0xffffffc011589764`，成员含 `mhi_uci_ioctl` `smcinvoke_ioctl` `glink_pkt_ioctl`
`spcom_device_ioctl` `msm_rng_ioctl` `aw8697_file_unlocked_ioctl` `spidev_ioctl` `ccid_ctrl_ioctl`
`evdev_ioctl(_compat)` `uinput_ioctl(_compat)` `i2cdev_ioctl` …（完整 165 个见
`cfi_type_tables.txt`）。
这是目前唯一还有可能藏着"写/泄露"入口的集合，但要清楚它的用法前提：
这些 handler 都按自己的类型解释 `file->private_data`，而我们的 fd 的 `private_data` 是
`struct ashmem_area` ⇒ 直接顶过去多半是 oops 而不是干净原语；**能用的形态**只有
"把用户标量存进 private_data 某字段" 或 "copy_*_user 只依赖 arg 指针" 这一类。

---

## 5. 现状与下一步（更新后的顺序）

1. **ashmem/f_op 路线的生死已经判了**：`show_fdinfo` 变体死，`mmap` 变体死，`ioctl` 变体待审
   （审法：对 165 个成员逐个反汇编，找"写 `private_data` 指向的字段"或"以 arg 为目的地址 copy_to_user"
   的模式）。**这件事不需要真机、零风险，可以离线做完。**
2. 但**整条路线仍卡在先决条件上**：需要一个"写 8 字节到内核堆上 `struct file`"的原语
   （= [[binder-uaf-2026]] 该供的东西）。f_op 路线不是那个写本身，是写的**下游**。
3. 若继续 binder：§4.1/§4.3 的表只给"能顶成谁"，**槽偏移仍需在真机钉死**：
   `struct file` 内 `f_op` 的 `#imm`、`file_operations` 内 `unlocked_ioctl` 的 `#imm`，
   应从**与真机同构建**的镜像取，而本机三份镜像都是 2026-06 那个 build。
   ⇒ 值得做的兜底：拿到 `PD2220A / compiler05071149` 对应的 boot 镜像（真机同 build），
   或在动手前用 §2.1 那种功能级探针逐个自证。
4. **KASLR**：唯一可用泄露通道仍是 shell 自采样 perf（app 域被 SELinux 拦死），
   且 slide 每次开机变 ⇒ 任何地址都必须运行期测，不能写死。

## 6. 涉及的文件

* 探针：`C:/qemu_test/appdapk/jni_p46.c`(app perf 判定), `jni_p47.c`(fdinfo A/B + ashmem 密集循环),
  `perf_pid.c`→`/data/local/tmp/p47_pp`(按 pid 采样，因 ptrace 闸而不可用)
* 分析脚本：`C:/qemu_test/cfi_scan.js`, `cfi_types.js`, `cfi_set.js`, `kaslr_layout.js`
* 资产：`analysis/cfi_type_tables.txt`, `C:/qemu_test/cfi_showfdinfo_set.txt`
* 关联记忆：[[ashmem-fop-write-channel]], [[app-reachability-surface]], [[device-observability-limits]],
  [[binder-uaf-2026]], [[feedback-probe-false-positives]]
