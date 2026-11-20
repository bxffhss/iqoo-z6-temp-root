# FAKE-SEQFILE 读原语普查 (2026-09-28, 纯离线静态分析, 无设备)

目标: 判断"把 `file->private_data` 指向一个**静态可写对象**, 然后把它伪造成 `struct seq_file`,
用 `read()`/`readv()` 得到任意内核读"这条路在本机构建上是否成立。
结论先说：**这条路作为设计稿不成立(致命点不在 `p->size`, 而在 `*ppos`/`p->read_pos` 记账)；
但普查过程中挖到一个已经完整可用、且完全符合写原语取值边界的读/mmap 通道(`/proc/sla/{wlan,wwan}_stats`)。**

标注约定: 每条陈述都带 `[VERIFIED: 证据]` 或 `[INFERRED]`。证据全是本机构建
`kernel_dev_g2a88cd145def.bin`(加载基址 `0xffffffc010080000`) + `kallsyms_g2a88cd145def.txt` +
`cfi_type_tables.txt` + `config_dev.txt`。

---

## 0. TL;DR (5 行)

1. **全镜像 711 条 `str x?,[x?,#0xd8]`(= 写 `filp->private_data`)分布在 589 个函数里, 其中值为
   "链接期静态常量/全局变量里的静态指针"的一条都没有落在 `.open` 处理函数里** ⇒ 没有任何
   fops 的 open 会把静态对象交给 private_data [VERIFIED: `pd_static_scan.py` 全镜像扫描]。
2. 114 个 fops 的 `.read` 链接期就等于 `seq_read`(全部在**可写 .data**), 但它们的 `.open` 全是
   `seq_open/single_open/…` ⇒ private_data 是**堆上的 seq_file**, 我们的写原语打不到 [VERIFIED: `fake_seq_scan.py`]。
3. `p->size` 必须 0 或核地址这个限制**不是障碍**(快路径根本不读 `p->size`); 真正的障碍是
   `*ppos == 0` 时 `seq_read` 会把 `p->count` 清零并走 `traverse()` ⇒ 解引用 `p->op` ⇒ 空指针 oops,
   而 `p->read_pos` 需要的非零小值只有形状(3) 能给的 1..3 [VERIFIED: `seq_read` 反汇编 + `GHOST-WRITE-SHAPES` 形状表]。
4. **可落地的替代通道**: `stats_fops @0xffffffc0121d8b10`(`/proc/sla/wlan_stats`, `/proc/sla/wwan_stats`,
   mode **0644** world-readable): `.read = stats_read` = `simple_read_from_buffer(..., from=file->private_data,
   avail=0x63ed0 = 409,296 字节)(≈400 KB 窗口, 偏移由 `default_llseek` 自由给), `.mmap = stats_map` =
   `remap_pfn_range(vma, vm_start, __pa(private_data)>>12, vm_end-vm_start, …)` **长度不受对象大小约束** [VERIFIED: 反汇编]。
5. 下一个探针: 先 `cat /proc/sla/wlan_stats`(409,296 字节)看有没有内核指针; 再 `mmap(LEN≈2MB, PROT_READ)`
   该 fd 越界读物理相邻页(注意 `stats_map` 硬编码 pgprot `0x6800000000000fd3` 含 PXN|UXN 位, EL0 可读性必须实测)。

---

## 1. 方法(新建的脚本, 都可重跑)

| 脚本 | 干什么 |
|---|---|
| `analysis/cfi_map.py` | 把 `cfi_type_tables.txt` 变成 `KCFI 序言地址 → 函数名` 表: 成员地址 = `组基址 + 4*组内下标`(`.text.cfi_jt` 每条 4 字节)。与 kallsyms 里 36458 个 `*.cfi_jt` 符号交叉验证: 名字全对(差异只是 `$hash` 后缀)。[VERIFIED] |
| `analysis/scan_static_fops.py` | 统计"某类函数出现在对象内哪个偏移", 用来**反推本构建 fops 布局**。 |
| `analysis/fops_layout.py` | 给定 fops 符号名, 打印每个 8 字节槽的 `.rela` 加数并解析成函数名。 |
| `analysis/fake_seq_scan.py` | 列出 `.read(+0x10) == seq_read` 的 fops + 扫 open 组成员找 private_data 写入, 求交集。 |
| `analysis/pd_static_scan.py` | **全镜像**按指令编码筛 `str/stur x?,[x?,#PD]`(PD 可给 0xd8 / 0x2c0 …), 归到函数, 在函数内追 adrp/add/mov/ldr 常量, 报告写入值的来源(静态常量 / 全局变量 / 间接)。 |
| `analysis/fops_pair_scan.py` | 所有 fops 的 `read × open` 配对表, 挑出 open 属于 `inode->i_private` 一族的。 |
| `analysis/rd_oracle_scan.py` | 在所有 `.read/.read_iter` 里找 `simple_read_from_buffer`/`memory_read_from_buffer`/`_copy_to_user` 且**源寄存器直接来自 private_data** 的读 oracle。 |
| `analysis/gvar_read_scan.py` | 同类扫描但要求"源 = 静态全局变量的内容"(即双跳, 理论上最契合我们的写边界)——**命中 0**。 |
| `analysis/adrp_site.py` | 找 `adrp+add` 得到某个具体链接期地址的代码点(初版漏了 `.init.text`, 已用等价的内联扫描补做)。 |

关键 idiom 复用了本项目已有的 house rules: `.data/.bss` 指针的真实链接期值取自 `.rela`
(`R_AARCH64_RELATIVE`=1027, 全镜像 `data.find` 一次拿到 127418 条, 槽值 = r_addend, 槽地址 = r_offset 为绝对链接地址)[VERIFIED: 对 `proc_kmsg_operations`/`proc_stat_operations` 的解析结果与上游源码逐槽吻合]。

---

## 2. 布局(全部按二进制钉死, 不靠上游记忆)

### 2.1 `struct file`
| 偏移 | 字段 | 证据 |
|---|---|---|
| +0x28 | `f_op` | `__vfs_read`(0xffffffc010579cc0): `ldr x9,[x0,#0x28]; ldr x8,[x9,#0x10]` [VERIFIED] |
| +0xc8 | `f_pos` | `seq_read` 入口 `ldr x8,[file,#0xc8] → str [p,#0x38]`, 出口 `ldr x8,[p,#0x38] → str [file,#0xc8]` [VERIFIED] |
| +0xd8 | `private_data` | `seq_read+0x24: ldr x21,[x0,#0xd8]`; `simple_open: str x8,[x1,#0xd8]` [VERIFIED] |

### 2.2 本构建 `struct file_operations`(槽偏移直方图, 只统计属于对应 KCFI 类型的槽)
| 偏移 | 字段 | 命中数 | 证据 |
|---|---|---|---|
| +0x08 | `.llseek` | 236(全在 line 12913) | [VERIFIED] |
| +0x10 | `.read` | 224(全在 line 14233) | 且 `__vfs_read` 就是取 +0x10 后做类型范围检查 [VERIFIED] |
| +0x18 | `.write` | 111+ | [INFERRED] |
| +0x20 | `.read_iter` | 23(line 14187) | [VERIFIED] |
| +0x28 | `.write_iter` | 22(line 14187) | [VERIFIED] |
| +0x48 | `.poll` | — | `proc_kmsg_operations+0x48` = `__typeid__ZTSFjP4fileP17poll_table_structE`(poll 类型组基址) [VERIFIED] |
| +0x60 | `.mmap` | — | `stats_fops+0x60 = stats_map`, 其体是 `remap_pfn_range` 包装 [VERIFIED] |
| +0x70 | `.open` | 212(line 14253) | 如 `proc_stat_operations+0x70 = stat_open` [VERIFIED] |
| +0x80 | `.release` | 222(line 14253) | `proc_stat_operations+0x80 = single_release`, `proc_kmsg_operations+0x80 = kmsg_release` [VERIFIED] |

⚠ 与上游 5.4 相比, `.read`/`.read_iter` 位置一致, 但 **`.open`/`.release` 在 +0x70/+0x80**(上游 +0x60/+0x70)
⇒ 本机在 `write_iter` 与 `open` 之间多一个槽 [VERIFIED: 上述交叉验证; 具体是哪个字段 [INFERRED: vendor 加的 `uring_cmd`/`fadvise` 一类]]。

### 2.3 本构建 `struct seq_file`(全部从 `seq_read` 0xffffffc0105b0d5c 的反汇编取用)
| 偏移 | 字段 | 证据(`seq_read` 里的用法) |
|---|---|---|
| +0x00 | `buf` | `ldr x0,[x21]`; 为 0 时 `kvmalloc_node(0x1000,…)` 后 `str x0,[x21]` [VERIFIED] |
| +0x08 | `size` | 只在 `[x21,#0x8b]` bit1 置位时用于 `min(size, count)`; 分配路径里被内核写 0x1000 [VERIFIED] |
| +0x10 | `from` | `ldr x8,[x21,#0x10]; add x26, x0, x8` = 拷贝源 `buf+from` [VERIFIED] |
| +0x18 | `count` | `ldr x8,[x21,#0x18]`; `csel x22 = min(count, requested)`; `*ppos==0` 时被清零 [VERIFIED] |
| +0x28 | `index` | `str xzr,[x21,#0x28]`; 传给 `op->start(p, &p->index)` [VERIFIED] |
| +0x30 | `read_pos` | `ldr x8,[x21,#0x30]; cmp x1(=*ppos),x8; b.ne → traverse`; 成功后 `+= copied` [VERIFIED] |
| +0x38 | (f_pos 镜像) | 入口从 `file->f_pos` 拷入, 出口写回 `file->f_pos` [VERIFIED] |
| +0x40 | `lock` (mutex) | `add x27,x21,#0x40; bl mutex_lock` [VERIFIED] |
| +0x70 | `op` (`seq_operations*`) | `ldr x8,[x21,#0x70]; ldr x27,[x8]`(=start) + 内联 KCFI 范围检查 [VERIFIED] |
| +0x88 | int 标志位 | `ldr w8,[x21,#0x88]`, 测 bit24/26 [VERIFIED] |
| +0x8b | byte 标志位 | `ldrb w8,[x21,#0x8b]`, `tbz bit1` 决定是否用 `p->size` 夹取 count [VERIFIED] |

### 2.4 `struct inode` / `proc_dir_entry`
- `inode->i_private = +0x2c0` [VERIFIED: `simple_open`: `ldr x8,[x0,#0x2c0]; str x8,[x1,#0xd8]`]
- `PDE_DATA(inode)`: `ldur x8,[x0,#-0x30]`(= `PROC_I(inode)->pde`)`; ldr x0,[x8,#0x50]`(= `pde->data`) [VERIFIED: 0xffffffc01062af7c]

### 2.5 相关 CONFIG(`analysis/config_dev.txt`)
`CONFIG_CFI_CLANG=y`, `CONFIG_CFI_CLANG_SHADOW=y`, **`# CONFIG_CFI_PERMISSIVE is not set`**(违约即 BUG),
`CONFIG_STRICT_KERNEL_RWX=y`, `CONFIG_RODATA_FULL_DEFAULT_ENABLED=y`, `CONFIG_ARM64_PAN=y`,
`CONFIG_HARDENED_USERCOPY=y`(第6389行), **`# CONFIG_HARDENED_USERCOPY_FALLBACK is not set`**(⇒ 违约不可降级), `CONFIG_BUG=y`(193), `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`(6432), `CONFIG_STACKPROTECTOR_STRONG=y`, `CONFIG_ARM64_VA_BITS=39`, `CONFIG_BUG=y`。[VERIFIED: 逐行 grep]

---

## 3. Q1/Q2: 哪些 `.open` 会把 private_data 指向静态对象?

**答案: 一个都没有。** 方法与数据:

- `private_data` 偏移 = 0xd8 (§2.1)。全镜像按编码筛 `str x?,[x?,#0xd8]` + `stur x?,[x?,#0xd8]`
  ⇒ **711 条 store, 落在 589 个函数** [VERIFIED: `pd_static_scan.py`]。
- 对这 711 条逐个在**所属函数内**(按 kallsyms 定界, 不越界到下个函数)追 adrp/add/mov/ldr,
  只有 11 条的写入值是链接期常量, 且**没有一条在 open 处理函数里**(它们是 crypto `drbg_cores`、
  `f2fs_cryptops`、irq-domain/skb 的 `.cfi_jt` 指针、`tipc_genl_v2_ops` 等别的结构的 +0xd8 字段)
  [VERIFIED: `pd_static_scan.py` 段 A; `grep '是某些 fops 的 +0x70(open)?' = 否` ×11]。
- 把范围放宽到"值来自一个全局变量(`ldr` 自 adrp 锚定的 .data/.bss 槽)": **同样是 0 条 open 命中** [VERIFIED]。
- 反过来(更现实的一类): `private_data = inode->i_private` 的 open 族, 命中如下(对象均为**可写 .data**, 但
  private_data 的真实值要等 inode 创建时才知道) [VERIFIED: `pd_static_scan.py` 段 B + `fops_pair_scan.py`]:

| open 函数 | private_data 来源 | 挂它的 fops(全在可写 .data) | `.read` 是谁 |
|---|---|---|---|
| `simple_open` @0xffffffc0105b5ad8 | `[inode+0x2c0]` | `tracefs_file_operations` @0x12150c90, `stats_fops` @0x121d8b10, `stats_data_fops` @0x12172ac8 | `default_read_file` / **`stats_read`** / (空) |
| `tracing_open_generic(_tr)` / `tracing_open_file_tr` | `[inode+0x2c0]` | `trace_options_core_fops`, `tracing_thresh_fops`, `tracing_readme_fops`, `tracing_saved_cmdlines_size_fops`, `ftrace_enable_fops`, `ftrace_event_filter_fops`, `set_tracer_fops`, `tracing_cpumask_fops`, `rb_simple_fops`, `buffer_percent_fops`, `tracing_stats_fops`, `tracing_entries_fops` … (22 个) | 各自的 `tracing_*_read`, **没有一个是 seq_read** |
| `stats_open` @0xffffffc010f719d4 | `PDE_DATA(inode)` → `inode->i_private` | `stats_fops` | **`stats_read`** ← §6 |
| `ffs_ep0_open`/`ffs_epfile_open`/`relay_file_open` | `[inode+0x2c0]` | `ffs_ep0_operations` @0x121aa0b0, `relay_file_operations` @0x1211cfb0 | `ffs_ep0_read`/`ffs_epfile_read_iter`/`relay_file_read` |
| `f_cdev_open`/`tmc_etr_byte_cntr_open` | `[inode+0x298]`(= `i_cdev`, 之后 `container_of`) | `f_cdev_fops` @0x121aa7d0, `byte_cntr_fops` | `f_cdev_read`/`tmc_etr_byte_cntr_read` |
| `hidraw_open`,`usbdev_open`,`aw869xx_file_open`,`ipa3_open`,`dm_open` | 某设备结构字段(+0xfb0/+0xf98/+0x868/+0x7a0/+0xf90) | 对应 vendor fops | 各自 read |

**交集(Q1∩"fops.read=seq_read")= 0** [VERIFIED: `fake_seq_scan.py` 段 D: `交集 = 0`]。
114 个 `.read = seq_read` 的 fops 全清单在附录 B; 它们的 `.open` 全是 `*_open`(→ `seq_open`/`single_open`
→ **堆 seq_file**), 没有一个给静态对象。

顺带两个有价值的事实:
- **本机构建里所有 `file_operations` 都在可写 `.data`**(114/114 类型字母 `d`/`D`; `random_fops`/`binder_fops`/
  `ext4_file_operations`/`def_chr_fops` 也都是 `D`) [VERIFIED: kallsyms 类型字母]。
  但按 §4 的写边界, 我们只能把这些槽写成 0 / 1..3 / 可写地址 ⇒ 只能"关掉"槽, 不能装新函数。
- 这 114 个 seq fops 的 `.read_iter(+0x20)` **全为 0** [VERIFIED] ⇒ `read()/pread()` 会直接走 `.read`(见 §4)。

---

## 4. 写原语取值边界(重述 + 对本案的影响)

`GHOST-WRITE-SHAPES-20260927.md` 的形状表(由 `rb_erase@0xffffffc0115446e0` 反汇编坐实)给出
可装进任意 8 字节对齐静态槽的值只有 **0 / 1..3 / 一个可写核地址**; `.text`(含 KCFI 序言 `.cfi_jt`)
不是可写地址 ⇒ **无法安装函数指针** [VERIFIED: 形状表 + `CONFIG_CFI_PERMISSIVE is not set` + `STRICT_KERNEL_RWX=y`]。

本案的两个直接后果:
1. `.cfi_jt` 序言地址在 0xffffffc01156xxxx–0xffffffc01159xxxx 区间(实测 `seq_read.cfi_jt = 0xffffffc011586f3c`,
   `_etext = 0xffffffc0115a0000`) ⇒ 它是只读 text 里的地址 ⇒ 不能作为形状(2) 的 V [VERIFIED]。
   ⇒ **给静态 fops 的 `.read` 槽安装 `seq_read` 是不可能的**; `.read` 必须在链接期就已经是 `seq_read`。
2. 于是可用的形态只剩: 找一个**链接期 `.read` 就已是 seq_read 的 fops** + 它的 open 交出静态对象。§3 已证: 不存在。

---

## 5. `seq_read` 作为 gadget 的可行性判定(含 `p->size` 限制的正式回答)

假定我们已经拿到"private_data = 可写静态对象 P(前 0x90 字节全 0)"这个前提(实际拿不到, 见 §3),
把 P 伪造成 seq_file 会发生什么(逐条按 `seq_read` 反汇编):

**(a) `p->size` 必须是 0 或核地址 —— 这个限制不重要。** [VERIFIED]
`seq_read` 里 `p->size`(+0x08) 只在 `ldrb [p,#0x8b]` 的 **bit1 为 1** 时用于 `min(size, count)` 夹取,
而那个字节我们留 0 ⇒ 走 `tbz` 直接跳过, `p->size` 全程不被读。快路径(纯拷贝)也不需要 `p->size`。
⇒ **"`p->size` 只能填 0 或一个可写核地址"不影响这个 gadget 的可用性。**

**(b) 真正的第一道坎: `p->count` 必须非 0, 但 `*ppos == 0` 会把 `p->count` 清零。** [VERIFIED]
```
0xd80: ldr x21,[x0,#0xd8]        ; p = file->private_data
0xdb4: bl  mutex_lock(p+0x40)
0xdc0: ldr x1,[ppos]
0xdc4: cbnz x1, 0xdd8
0xdc8..0xdd0: p->index=0; p[+0x38]=0; p->count=0     ← 关键: pos 0 就把 count 抹零
0xdd8: ldr x8,[p,#0x30] ; cmp x1,x8 ; b.ne → traverse(p,pos)   ← traverse 会解引用 p->op(+0x70)
0xe14: ldr x8,[p,#0x18](count) ; cbz → 0xe60 → p->op->start(p,&p->index)   ← p->op=0 ⇒ oops
```
⇒ `*ppos == 0`(`read()` 在新 fd 上就是这个值)必然落到 `p->op` 解引用 ⇒ **NULL deref ⇒ panic** [VERIFIED: 反汇编]。

**(c) 需要的条件, 以及它能不能凑出来:** 走拷贝分支要求
`*ppos != 0` **且** `*ppos == p->read_pos(+0x30)`。[VERIFIED: 同上]
- `p->read_pos` 只能填 0 / 1..3 / 可写核地址: 填 0 ⇒ 违反 `*ppos != 0`; 填核地址 ⇒ 有符号为负,
  `pread/lseek` 的负 offset 被 VFS `-EINVAL` 拒掉 [INFERRED: 标准 VFS 语义, 未在本机反汇编确认]。
- **唯一可行解: 用写形状(3) 把 1..3 写进 `p->read_pos`, 然后用 `pread(fd, buf, N, off)`(`off ∈ {1,2,3}`)
  或 `lseek(fd, off, SEEK_SET)` 把 f_pos 定成同一个值。** 形状(3) 的值域正好是 1/2/3, 目的地只需 4 字节对齐
  ⇒ 够用 [VERIFIED: `GHOST-WRITE-SHAPES` 形状表 + `rb_erase` 反汇编]。
- ⚠ 副作用: 形状(3) 会把 `T(=read_pos 槽)` 写进假锁的 `root->rb_node`, 且下一次 futex 入队会从 T 下潜
  ⇒ 必须保证 `T+0x08`/`T+0x10` 为 0 [VERIFIED: 形状表注记]。`seq_file` 的 `from(+0x10)`/`count(+0x18)`
  紧邻 `read_pos(+0x30)`, 所以 T 选 +0x30 时下潜会读 `count(+0x18)`/`index(+0x28)` —— 我们把 count 写成
  "可写核地址"(非 0)就会破坏这条约束 [INFERRED: 由布局直接推出, 需要在带内挑零洞验证]。

**(d) 满足 (c) 之后, 一次能读多少字节?** [VERIFIED: 反汇编 + §5(e)]
```
0xe1c: cmp x8(p->count), x25(请求长度) ; csel x22 = min(count, 请求)
0xe24: lsr x8,x22,#0x1f ; cbnz → brk #0x800       ← 只要 min(...) < 2^31 就不炸
0xe2c: x8 = p->from(=0) ; x26 = p->buf + x8
0xe40: __check_object_size(x26, x22, 1) ; 0xe50: _copy_to_user(user, x26, x22)
0xeb0: p->from += n ; p->count -= n ; 请求剩余 = 0 → b.eq → 正常退出
```
⇒ **可读长度 = 我们请求的字节数**(count 填一个可写核地址 ⇒ 恒大于请求), 上限 < 2^31;
源地址 = 我们写进 `p->buf` 的那个可写核地址 + `p->from`(0, 小偏移写不出来)。
一次 read 之后 `p->read_pos`/`f_pos` 会被推进 ⇒ 每次都要重新写 `read_pos` 再 `pread` [VERIFIED: 0x1104-0x1118]。

**(e) HARDENED_USERCOPY 会不会拦住?"不会 —— 前提是源在 kernel image(.data/.bss)内。"** [VERIFIED: `__check_object_size@0xffffffc0105721b4` 反汇编]
- 源在 `.text`/`_etext` 之下: `0x22d8 cmp x20,_etext; b.hs 0x22ec` 不跳 ⇒ 落入 `0x2388` 的 `usercopy_abort`
  (`usercopy_abort` 尾部 `brk #0x800` ⇒ `CONFIG_BUG=y` ⇒ **panic**) ⇒ **绝不能把 `p->buf` 指向 text** [VERIFIED]。
- 源是 slab 页: `PageSlab` 位测试 `tbz w8,#9` 通过 ⇒ `__check_heap_object` 按对象边界检查 ⇒ 越界即 abort [VERIFIED]。
- 源是 kernel image 的 .data/.bss(`>= _etext`): 走 `0x22ec` 后 `cmp x8(=非线形映射下界), x20; b.ls → return`
  ⇒ **直接返回, 不做任何长度约束 ⇒ 从静态对象往后可以读任意多字节(页边界不限)** [VERIFIED: 逐条分支]。
- 源是线形映射里的非 slab 页(堆/buddy): 也走 `0x22ec` 分支, 与 `_text - kimage_voffset - physvirt_offset`
  比较 ⇒ 实际是否放行依赖运行期值 [INFERRED: 需在设备上验证; 保守假设"会被约束"]。

**(f) `readv()` 能不能用?** `.read_iter(+0x20)` 为 0 ⇒ `__vfs_read` 取 `f_op->read`(+0x10)并直接调用
[VERIFIED: `__vfs_read+0x2c` 的 `ldr x9,[x0,#0x28]; ldr x8,[x9,#0x10]` + 对 line 14233 组基址的内联 KCFI 检查]。
`readv()` 的 `do_loop_readv_writev` 回退路径同样最终走 `.read` [INFERRED: 5.4 语义, 本机未反汇编确认]。
⇒ 用 `pread()` 最省事, 且能自选 `*ppos`。

**综合判定:** 即使 `p->size`/`p->count` 的限制可以绕过(§5a/d), **fake seq_file 仍然需要
形状(3) 把 1..3 写进 `p->read_pos` 这种额外巧技, 而它的前提(静态 private_data)在本机构建里根本不存在
(§3) ⇒ 这条路整体判死。**

---

## 6. ★ 普查的真正收获: `/proc/sla/{wlan,wwan}_stats` 双通道读原语

这是本项目一直在找的"kernel address leak"落地候选, 而且**它对写原语没有任何要求**(纯 DAC 可读)。

### 6.1 对象与入口
```
stats_fops @ 0xffffffc0121d8b10   kallsyms 类型 'd' = 可写 .data, 尺寸~0x120
  +0x08 .llseek  = default_llseek       (序言 0xffffffc01157fa60, line 12913 idx0)
  +0x10 .read    = stats_read           (序言 0xffffffc011587160)
  +0x60 .mmap    = stats_map            (序言 0xffffffc011582390)
  +0x70 .open    = stats_open           (序言 0xffffffc011588760)
  +0x80 .release = (空)
```
[VERIFIED: `fops_layout.py stats_fops`]

创建点(`.init.text`, 所以开机即存在):
```
0xffffffc010f73040  sla_wlan_stats_create:
    ldr x2,[x20,#0x560]           ; parent = sla_dir (bss 槽 0xffffffc013236560)
    ldr x4,[x21,#0x6a0]           ; data   = *(bss 槽 0xffffffc0132366a0) = 全局变量 wlan_stats
    adrp/add x0 -> 0xffffffc011e2c953 = "wlan_stats"
    mov  w1, #0x1a4               ; mode 0644  ← uid 2000 可读!
    adrp/add x3 -> 0xffffffc0121d8b10 = &stats_fops
    bl   proc_create_data         ; 结果 pde 存到 *(0xffffffc013236700)(wlan_stats_file)
0xffffffc010f731b0  sla_wwan_stats_create: 同上, "wwan_stats"@0x12001fc6, data = *(0xffffffc0132366c0)
sla_dir = proc_mkdir("sla"@0xffffffc011f0d96c, NULL)   ; in sla_static_collector_init+0x48
```
⇒ **路径 = `/proc/sla/wlan_stats` 和 `/proc/sla/wwan_stats`, mode 0644(世界可读)** [VERIFIED: 反汇编 + 字符串]。

`stats_open`(0xffffffc010f719d4): `PDE_DATA(inode)` → 写进 `inode->i_private(+0x2c0)` → `simple_open`
→ `filp->private_data = inode->i_private` ⇒ **private_data = 打开那一刻 `wlan_stats` 全局变量的值**
(即那块 0x63ed0 字节缓冲的地址; 值本身由驱动早期分配, 见 §6.4) [VERIFIED: 反汇编]。

### 6.2 通道 A: `stats_read` —— 400 KB 有界读 oracle
```
stats_read @ 0xffffffc010f73220   (kallsyms: stats_read$9999b02a…)
  0x…3230  ldr x3, [x0, #0xd8]          ; from = file->private_data (不解引用, 直接当源)
  0x…3234  mov w4, #0x3ed0
  0x…323c  movk w4, #6, lsl #16         ; available = 0x63ed0 = 409,296 字节
  0x…3248  bl  simple_read_from_buffer  ; (to=用户buf, count=用户给, ppos, from, avail)
```
[VERIFIED: 反汇编; `rd_oracle_scan.py` 全镜像里它是**唯一**一个"源=private_data 本身"的 read 函数]
⇒ `read(fd, buf, N)` 得到 `[private_data + f_pos, +N)`; `.llseek = default_llseek` ⇒ `lseek` 可在
`0 .. 0x63ed0` 任意定位 ⇒ **固定 409,296 字节窗口, 偏移自选**。不涉及 `__check_object_size` 的
额外约束之外(源是堆缓冲, 见 §5e 注意事项: `simple_read_from_buffer` 的 `memcpy_to_user` 会过
`check_object_size`; 该缓冲是 0x63ed0 的大块分配, 落在"非 slab/buddy 或 big-kmalloc"分支, 单对象边界
判定见 §5e 最后一条 [INFERRED: 需实测一次即可确认])。

### 6.3 通道 B: `stats_map` —— **长度不受对象约束**的 remap
```
stats_map @ 0xffffffc010f73258   (挂在 .mmap)
  0x…3268 ldr  x9,[x0,#0xd8]      ; x9 = private_data;  为 0 → return -EINVAL
  0x…327c ldp  x8,x10,[x1]        ; x8 = vma->vm_start, x10 = vma->vm_end
  0x…32a0 sub  x3,x10,x8          ; size = vm_end - vm_start   ← 完全由用户 mmap 长度决定
  0x…32b4 add  x9,x10,x9 / lsr x2,x9,#0xc   ; pfn = __pa(private_data) >> 12
  0x…32b8 mov  x4,#0xfd3 ; movk x4,#0x68,lsl#48   ; pgprot = 0x6800000000000FD3 (硬编码)
  0x…32cc bl   remap_pfn_range
```
⇒ **没有任何地方把 `size` 与 0x63ed0 或该对象大小比较** [VERIFIED: 函数全长 0x94, 只有上面这些指令]。
⇒ `mmap(NULL, LEN, PROT_READ, MAP_SHARED, fd, 0)` 若成功, 就得到
`[__pa(private_data) 页对齐起, +LEN)` 的**物理内存读窗口**; 而 0x63ed0 字节的分配是 order-7
(512 KB)的物理连续块 ⇒ 越过块尾读到的就是**相邻 buddy 页(别的内核堆数据: 指针、栈、其他对象)** [INFERRED: 分配尺寸/order 由 memset(…,0x63ed0) 反推; 页阶需实测]。
⚠ **必须实测的风险**: 硬编码 pgprot 低位 `0xFD3`(AP=11 含 PTE_USER, AF/SH/nG/Page)+ bit 51,
bit 53(PXN), bit 54(UXN)。若 UXN 真被置起, EL0 读会 SEGV ⇒ 通道 B 作废(通道 A 不受影响)
[INFERRED: 只做了位域计算, 未在设备上验证]。

### 6.4 关键静态槽位(写原语的落点, 若要"任意地址"化)
| 槽 | 地址 | 段 | 谁读写它 |
|---|---|---|---|
| `wlan_stats` | `0xffffffc0132366a0` | 'b' (.bss, 可写, 链接期 0) | 读: `sla_wlan_stats_create`(data 参数), `sla_stats_disable` ×3; 写: `sla_stats_disable` 的 `str xzr` [VERIFIED: `field_consumers.py`] |
| `wwan_stats` | `0xffffffc0132366c0` | 'b' | 同上(wwan 版) |
| `sla_dir` | `0xffffffc013236560` | 'b' | `sla_static_collector_init` 写 |
| enable 标志 | `0xffffffc01323656c` | 'b' byte | `sla_stats_enable/disable` + `config_file_write` |
| `wlan_stats_file`/`wlan1_stats_file`/`wwan_stats_file` (pde*) | `0x13236700` / `0x13236708` / `0x13236710` | 'b' | `proc_remove` 用 |

"任意地址"化只有这一条路径: **改 `wlan_stats` 槽(形状 2, 值=可写核地址 V)→ 让驱动重新 `proc_create_data`
→ 新 pde->data = V → 再 open ⇒ `stats_read`/`stats_map` 的源变成 V。**
重新创建的触发点是 `sla_stats_enable`(0xffffffc010f72268), 它被两处调用:
`sla_static_collector_init+0x218`(开机) 与 `config_file_write+0x388`(0xffffffc010f72690) —— 后者挂在
`/proc/sla/config`(`config_fops @0x121d8690`, `.write = config_file_write`), 而该文件 mode 也是 **0x1a4=0644**
⇒ **uid 2000 拿不到写权限 ⇒ 触发不了重建** [VERIFIED: `sla_static_collector_init+0x1a0` 的
`proc_create_data("config"@0xffffffc011e322e8, 0644, sla_dir, &config_fops)`]。
⇒ 这一"任意地址"升级目前 **不可用**, 除非找到别的 0644/0666 可写触发点(未穷尽; `sla_netlink_receive`
也引用同一页, 是一条待查线索 [INFERRED])。
⚠ **重大副作用警告**: `sla_stats_disable`- `stats_map` 里那段 `eor/cmp/csneg` 就是 arm64 的 `__pa()`(线形映射用 `physvirt_offset`,
  kernel image 用 `kimage_voffset`, 二者选一)⇒ **驱动预期 private_data 是线形映射里的地址(kmalloc/buddy),
  不是 vmalloc** ⇒ "物理连续 512 KB 块 + 越界读到相邻 buddy 页"这个推断站得住 [VERIFIED: 反汇编 + INFERRED: 页阶]。
- 但 `wlan_stats` 槽的**初值写入点**没有出现在 `str`-立即数形式里(只有 `sla_stats_disable` 的 `str xzr`),
  极可能走 `stp` 或寄存器别名 ⇒ 该缓冲的分配器(kmalloc vs. kzalloc vs. 大块)未坐实 [INFERRED],
  实测时先看 `read` 出来的字节像不像计数器即可反推。

`sla_stats_disable`(0xffffffc010f71a10) 会执行
`memset(*wlan_stats, 0, 0x63ed0)`; 若我们已把 `wlan_stats` 改成 V, 一旦有人触发 disable,
就是往 V 起 **409,296 字节清零** ⇒ 整机立崩。改槽方案除非同时确认无人触发 disable, 否则不要做 [VERIFIED: 反汇编]。

---

## 7. Q3(前 0x40 字节是否为 0 / 有没有人把这些槽当指针解引用)的判定结果

由于 §3 的候选集为空, 这一问只对 §6 的槽位有意义, 已就地完成:
- `wlan_stats@0x132366a0` / `wwan_stats@0x132366c0`: 类型字母 `b` ⇒ **在裸 Image 之外 = .bss ⇒ 链接期恒 0**
  [VERIFIED: `type='b'` + 槽地址 > Image 末 `0x12b17a00`]。
- 全镜像对该 8 字节的访问点: 1 处 `ldr`(create 时取 data)+ 4 处 `sla_stats_disable` 内 `ldr`/`str xzr`,
  **没有任何别的地方把它当指针解引用** ⇒ 把它改成另一个可写核地址, 除了 §6.4 的 memset 风险外不会破坏其它子系统
  [VERIFIED: `field_consumers.py 0xffffffc0132366a0 0x18`]。
- 若仍想走 fake-seqfile(需要一块 ≥0x90 字节、前 0x90 全 0、且无人当指针用的 .bss 对象),
  现成的枚举工具是 `find_pair_targets.py`(已按"可写 + 尺寸 + 跨 64KB 边界 + 8 字节为 0"筛过一批),
  但**必须先有 open 交出静态 private_data, §3 已证没有** ⇒ 不必再花时间挑对象。

---

## 8. KCFI 同类型组(题面要求的行号与成员)

`cfi_type_tables.txt` 行号 + 组基址; 成员地址 = 基址 + 4×下标 [VERIFIED: 与 kallsyms `*.cfi_jt` 交叉一致]。

| 用途 | 行号 | 组基址 | n | 我们要的函数(下标) |
|---|---|---|---|---|
| `.read`(`long (*)(struct file*, char*, size_t, loff_t*)`) | **14233** | `0xffffffc011586f30` | 112 | `seq_read`(3, 序言 `0xffffffc011586f3c`), `stats_read`, `simple_read_from_buffer` 家族等; **`seq_read_iter` 不在其中** |
| `.read_iter`/`.write_iter`(`long (*)(struct kiocb*, iov_iter*)`) | **14187** | `0xffffffc01158a794` | 46 | `generic_file_read_iter`, `blkdev_read_iter`, `shmem_file_read_iter`, `sock_read_iter`, `pipe_read` …; **`seq_read_iter` 不存在** |
| `.llseek` | **12913** | `0xffffffc01157fa60` | 4 | `default_llseek`(0), `noop_llseek`(1), `seq_lseek`(2), `generic_file_llseek`(3) |
| `.open`/`.release`(主组, 296 个成员里 +0x70 出现 212 次、+0x80 出现 222 次) | **14253** | `0xffffffc0115881e4` | 296 | `cpuinfo_open`(0), `seq_release`(1), `stat_open`(2), `single_release`(3), `kmsg_open`(4), `kmsg_release`(5), `seq_fdinfo_open`, `single_open_net`, `seq_open_net`, `seq_release_net`, `single_release_net`, `nonseekable_open`, `stream_open` … |
| `.open`/`.release`(第二组, 同样出现在 +0x70/+0x80) | **14240** | `0xffffffc011588684` | 131 | `stats_open`, `posix_clock_open`, `uid_procstat_open`, `dm_open`, `ashmem_open`, `mem_open`, `profile_open`, `sched_open`, `f_cdev_release`, `seq_release_private`, `bpffs_map_release` … |
| `seq_open` / `single_open` / `single_open_size` / `seq_open_private` | 77 / 84 / 80 / 4456 | 见文件 | 1 | 它们是 5 参原型 ⇒ 各自独占一个 n=1 组 ⇒ 不能与 2 参 open 互换 [VERIFIED] |

**完整成员清单见附录 A。**

关于 `seq_read_iter` 的正式回答: **本构建没有 `seq_read_iter`** —— `grep -c seq_read_iter` 在
`kallsyms_g2a88cd145def.txt` 与 `cfi_type_tables.txt` 里均为 **0**(`grep -c seq_read_iter` 两文件各 0); `seq_read` 自己就是 2004 字节的完整实现
(旧式 `read` 版, 直接 `copy_to_user`, 不经 iov_iter) [VERIFIED: grep + 反汇编]。
⇒ 题面里"`seq_read_iter` 应该在 `.read_iter` 那一组"的前提不成立; `.read_iter` 组(14187)里没有任何 seq 函数。

---

## 9. 下一个探针(next probe should try X)

**X = 直接把 `/proc/sla/wlan_stats`(和 `wwan_stats`)当现成读通道打, 一次两件事:
(1) `dd if=/proc/sla/wlan_stats bs=409296 count=1` 把 `stats_read` 的 409,296 字节全量倒出来,
在 409,296 字节里扫"像内核 VA 的 8 字节"(前缀 `0xffffff80`/`0xffffffe6`/`0xfffffdff` 之类) ⇒ 命中即拿到
kernel/heap 指针 = 我们缺的地址泄漏;
(2) `mmap(NULL, 2MB, PROT_READ, MAP_SHARED, fd, 0)` 试 `stats_map` —— 若 mmap 成功且**读第一页不 SEGV**,
就证明硬编码 pgprot 允许 EL0 访问, 于是得到"越过 512 KB 缓冲尾、读物理相邻页"的无 usercopy 检查通道,
按页步进把邻居页(其它堆对象/页表)全部倒出来。**
风险与判据: 若 mmap 返回成功但一读就 SEGV ⇒ pgprot 的 UXN 被置起(§6.3 的 [INFERRED]), 通道 B 作废,
只保留通道 A; 两条通道都**不需要**任何写操作, 因此零崩风险(只读), 且 `/proc/sla` 是 0644 世界可读 [VERIFIED: mode 立即数 0x1a4]。
SELinux: 仍需实测 shell 域能否 open `/proc/sla/*`(标签未知) —— 若被拒, 先按既有计划用形状(1) 把
`selinux_state` 的 enforcing 字节清零再试(项目已证该写可落地) [INFERRED]。

---

## 附录 A: KCFI 组完整成员清单(按组内下标顺序; 成员地址 = 基址 + 4*下标)

### line 14187  base=0xffffffc01158a794  n=46

read_iter_zero, write_iter_null, read_iter_null, logger_write, rpmsg_eptdev_read_iter, rpmsg_eptdev_write_iter, generic_file_direct_write, f2fs_direct_IO, fat_direct_IO, fuse_dev_write, random_read_iter, pipe_read, pipe_write, blkdev_read_iter, exfat_direct_IO, snd_pcm_readv, noop_direct_IO, blkdev_write_iter, ext4_direct_IO, snd_pcm_writev, ffs_epfile_write_iter, blkdev_direct_IO, fuse_file_read_iter, sock_read_iter, ext4_file_write_iter, urandom_read_iter, f2fs_file_write_iter, tun_chr_read_iter, sock_write_iter, shmem_file_read_iter, tun_chr_write_iter, ashmem_read_iter, fuse_file_write_iter, ffs_epfile_read_iter, ovl_read_iter, generic_file_read_iter, ovl_write_iter, devkmsg_write, generic_write_checks, generic_file_write_iter, fuse_direct_IO, __generic_file_write_iter, f2fs_file_read_iter, fuse_dev_read, ext4_file_read_iter, random_write_iter


### line 12913  base=0xffffffc01157fa60  n=4

default_llseek, noop_llseek, seq_lseek, generic_file_llseek


### line 14233  base=0xffffffc011586f30  n=112

ikconfig_read_current, bm_entry_read, bm_status_read, seq_read, kmsg_read, mhi_uci_read, dcc_sram_read, glink_pkt_read, spcom_device_read, read_null, aw8697_file_read, spidev_read, ccid_bulk_read, ccid_ctrl_read, evdev_read, uinput_read, i2cdev_read, logger_read, bbklog_en_read, quota_proc_read, media_read, ipa3_read, fuse_load_scale_up_thre_read, configfs_read_bin_file, proc_sessionid_read, posix_clock_read, f_hidg_read, rng_dev_read, pem_event_read, sel_read_policycap, relay_file_read, bpf_dummy_read, sel_read_enforce, sel_read_bool, rfkill_fop_read, sg_read, ffs_ep0_read, sel_read_handle_status, ipa_adpl_read, mbd_proc_read, tracing_saved_cmdlines_size_read, sel_read_mls, devkmsg_read, v4l2_read, fuse_conn_congestion_threshold_read, pem_process_read, vb2_fop_read, trace_options_core_read, tmc_read, tmc_etr_byte_cntr_read, snd_rawmidi_read, hung_up_tty_read, sel_read_sidtab_hash_stats, simple_transaction_read, rtc_dev_read, usbdev_read, rb_simple_read, fuse_io_stat_read, fuse_is_primary_read, snd_info_entry_read, proc_coredump_filter_read, tracing_cpumask_read, proc_sched_task_boost_period_read, fuse_debug_read, uvc_v4l2_read, proc_bus_pci_read, hidraw_read, tracing_entries_read, oom_adj_read, tracing_set_trace_read, uhid_char_read, usb_device_read, tracing_readme_read, proc_sys_read, tracing_thresh_read, trace_options_read, inotify_read, uio_read, fuse_stat_freq_request_read, sel_read_avc_cache_threshold, fuse_delay_ms_read, fmea_read, pm_qos_power_read, haptic_core_read, subsystem_filter_read, mem_read, show_header, kpagecgroup_read, haptic_read, fuse_time_warn_thre_read, fuse_load_warn_thre_read, default_read_file, fscontext_read, pem_thml_type_read, sel_read_avc_hash_stats, ramdump_read, pending_reads_read, vivolog_read, auxv_read, simple_attr_read, iio_buffer_read_first_n_outer, kpagecount_read, snd_ctl_read, snd_pcm_read, f_cdev_read, kernfs_fop_read, fuse_conn_waiting_read, ipa_odl_ctl_fops_read, lineevent_read, proc_sched_task_boost_read, log_read, proc_pid_cmdline_read


### line 14253  base=0xffffffc0115881e4  n=296

cpuinfo_open, seq_release, stat_open, single_release, kmsg_open, kmsg_release, bsptest_info_open, mhi_uci_open, mhi_uci_release, qiib_open, qiib_release, dcc_sram_open, smcinvoke_open, smcinvoke_release, glink_pkt_open, glink_pkt_release, spcom_device_open, spcom_device_release, memory_open, aw8697_file_open, aw8697_file_release, spidev_open, spidev_release, stream_open, ccid_bulk_open, ccid_bulk_release, ccid_ctrl_open, ccid_ctrl_release, evdev_open, evdev_release, uinput_open, uinput_release, i2cdev_open, i2cdev_release, qvr_external_sensor_fops_open, qvr_external_sensor_fops_close, logger_open, logger_release, nonseekable_open, bbklog_en_open, bbklog_en_release, rpmsg_ctrldev_open, rpmsg_ctrldev_release, rpmsg_eptdev_open, rpmsg_eptdev_release, fuse_release, gnss_open, timerfd_release, tty_release, usbdev_release, fmea_release, vaudit_open, ftrace_event_release, snd_pcm_playback_open, tracing_err_log_open, subsys_device_open, tracing_open_pipe, devkmsg_open, dma_buf_file_release, pem_wake_up_reason_open, proc_reg_open, uid_remove_open, tracing_buffers_release, system_tr_open, blkdev_open, input_proc_handlers_open, signalfd_release, bpf_raw_tracepoint_release, tracing_release_file_tr, eventfd_release, dupack_file_open, config_file_open, fastrpc_device_release, bpffs_obj_open, snd_pcm_capture_open, profile_open, uio_release, media_release, seq_fdinfo_open, ftrace_event_avail_open, tracing_release_options, f2fs_release_file, qseecom_release, mem_buf_export_release, single_release_net, pem_process_open, btf_release, fastrpc_device_open, tracing_release, tracing_open_options, sel_open_avc_cache_stats, ftrace_event_set_open, pidfd_release, pid_maps_open, ovl_dir_release, drm_stub_open, event_trigger_release, sensors_ssc_open, pem_event_open, v4l2_open, ipa_odl_ctl_fops_release, perf_release, jbd2_seq_info_open, log_open, proc_seq_open, meminfo_quick_proc_open, auxv_open, binder_transaction_log_open, stm_char_release, cvp_open, ddebug_proc_open, fuse_open, swait_open, seq_release_net, psi_io_open, single_open_net, ipa_adpl_open, seq_open_net, drm_release, binder_transactions_open, gsi_ctrl_dev_release, bpffs_map_open, configfs_release_bin_file, fifo_open, rt_cpu_seq_open, relay_file_open, sg_release, kgsl_open, ext4_release_file, snd_rawmidi_release, lineevent_release, tracing_open_generic, prof_cpu_mask_proc_open, synx_open, qcedev_open, snd_rawmidi_open, snd_info_entry_open, gpio_chrdev_release, event_track_open, appmem_detail_open, proc_pid_attr_open, watchdog_release, gpio_chrdev_open, rtc_dev_release, tracing_single_release_tr, key_hash_proc_open, pem_aprocess_open, misc_open, fuse_dir_release, irq_affinity_proc_open, fscontext_release, psi_fop_release, pem_process_release, show_traces_open, jbd2_seq_info_release, tracing_release_generic_tr, fops_u64_open, tun_chr_close, configfs_dir_close, ext4_release_dir, tmc_release, proc_rsc_svp_open, simple_attr_release, subsystem_open, extfreekb_open, binder_state_open, usbdev_open, ffs_epfile_release, tracing_release_pipe, fuse_dir_open, cvp_close, tracing_buffers_open, dm_release, pagemap_release, fas_render_open, proc_seq_open_vmalloc, pem_thml_type_open, ipa_adpl_release, mem_big_data_proc_open, pagemap_open, seccomp_notify_release, mmc_rpmb_chrdev_open, ext4_file_open, tracing_open_file_tr, rng_dev_open, configfs_release, memlog_open, uid_io_open, rms_version_proc_open, chrdev_open, pending_reads_release, mem_buf_buffer_release, binder_stats_open, drm_syncobj_file_release, drm_open, media_open, kallsyms_open, pm_qos_power_release, bsg_open, snd_ctl_release, vsoc_open, ep_eventpoll_release, iio_chrdev_release, acc_open, media_request_close, probes_open, ext4_dir_open, proc_cma_info_open, uid_remove_open, slabinfo_open, proc_seq_release, uid_cputime_open, appmem_open, snd_disconnect_release, kmemleak_open, rt_cache_seq_open, open_vis_display, aw869xx_file_release, v4l2_release, pem_pidcputime_release, ppp_release, io_uring_release, iio_chrdev_open, posix_clock_release, rfkill_fop_open, dcache_dir_close, tracing_stat_release, snd_timer_user_release, rtc_dev_open, environ_open, pid_virt_open, show_traces_release, f_hidg_release, snd_ctl_open, pid_smaps_open, log_release, appmem_release, linehandle_release, snd_timer_user_open, nb_release, file_open, kmem_pressure_level_open, sel_open_policy, ppp_open, tracing_saved_tgids_open, ftrace_formats_open, sg_open, event_trigger_open, tracing_clock_open, close_vis_display, haptic_core_release, stat_top_open, snd_hwdep_release, tracing_stat_open, f_cdev_open, psi_cpu_open, tracing_open_generic_tr, fas_audio_open, relay_file_release, tracing_err_log_release, ffs_ep0_open, pem_thml_para_open, uhid_char_release, sec_stage_proc_open, pem_cmd_open, uhid_char_open, snd_open, qseecom_open, sync_file_release, fuse_dev_release, sec_enable_anti_rollback_proc_open, pipe_release, f_hidg_open, aw869xx_file_open, sock_close, mountstats_open, cec_open, pstore_file_open, uio_open, pem_event_release, input_proc_devices_open, timerslack_ns_open, handshake_open, kernfs_fop_release, sla_tcp_stat_open, bad_file_open, dcache_dir_open, pem_pidcputime_open, swaps_open, snd_compr_free, roccat_release, mem_antifrag_open, stat_top_open_all, roccat_open, swait_release, blkdev_close


### line 14240  base=0xffffffc011588684  n=131

posix_clock_open, acc_release, ramdump_release, uid_procstat_open, sla_sock_diag_open, ffs_ep0_release, tracing_trace_options_open, gsi_ctrl_dev_open, dquot_file_open, ftrace_event_set_pid_open, mem_blocks_mb_open, tracing_free_buffer_release, dm_open, bpffs_map_release, snd_pcm_release, usb_open, sensors_ssc_release, ipa_odl_ctl_fops_open, shrinker_proc_open, snd_info_entry_release, haptic_open, ovl_release, ovl_dir_open, snd_compr_open, configfs_dir_open, no_open, sched_wake_up_idle_open, mmonitor_open, default_affinity_open, f_cdev_release, snd_info_text_entry_open, exfat_file_release, sched_init_task_load_open, stm_char_open, fscrypt_file_open, ion_proc_stat_open, uid_stat_open, bpf_prog_release, sel_open_handle_status, f2fs_file_open, sched_open, profile_open, proc_ion_mm_heap_open, hiddev_open, haptic_core_open, bsg_release, event_track_release, pm_qos_power_open, fuse_dev_open, modules_open, ashmem_release, cec_release, snd_info_text_entry_release, mem_lastfg_open, mmc_rpmb_chrdev_release, stats_open, haptic_release, file_release, ashmem_open, mem_open, hidraw_release, ffs_epfile_open, rpmb_prov_proc_open, probes_open, kernfs_dir_fop_release, ramdump_open, ipa3_wan_ioctl_open, nd_open, trace_format_open, inotify_release, binder_release, binder_open, mounts_release, iio_event_chrdev_release, sched_low_latency_open, bpf_map_release, sched_group_id_open, tmc_open, tracing_time_stamp_mode_open, rsc_boost_open, proc_reg_release, proc_single_open, devkmsg_release, qcedev_release, kmem_event_open, ptmx_open, ipa3_open, hiddev_release, sel_release_policy, tmc_etr_byte_cntr_release, tmc_etr_byte_cntr_open, snd_hwdep_open, seq_release_private, ovl_open, tty_open, hidraw_open, fsverity_file_open, tun_chr_open, kernfs_fop_open, ipa3_nat_ipv6ct_open, psi_memory_open, memlog_release, smaps_rollup_release, fmea_open, subsystem_release, fat_file_release, configfs_open_bin_file, mountinfo_open, shrinker_detail_proc_open, sec_enable_proc_open, meminfo_slub_open, proc_open, synx_close, watchdog_open, vsoc_release, proc_sys_open, configfs_open_file, dyn_event_open, nb_open, proc_single_open, f2fs_dir_open, pending_reads_open, extfreekb_release, mem_release, subsys_device_close, handshake_release, simple_transaction_release, top_exit_open, rfkill_fop_release, smaps_rollup_open, mem_fg_open


---

## 附录 B: %d 个 ".read(+0x10) 链接期就等于 seq_read" 的静态 fops

全部 kallsyms 类型字母 = `d`/`D`(**可写 .data**); `.read_iter(+0x20)` 全为 0; `.open(+0x70)` 全是 seq/single 家族 ⇒ 运行时 private_data = 堆上 seq_file。
这是 fake-seqfile 路线"目标 fops 存在、但 private_data 拿不到静态对象"的完整证据表。

| fops | 地址 | 段 | 尺寸 | .llseek | .open | .release |
|---|---|---|---|---|---|---|
| proc_cpuinfo_operations | `0xffffffc012007fe8` | d | 0x120 | seq_lseek | cpuinfo_open | seq_release |
| proc_stat_operations | `0xffffffc012008148` | d | 0x120 | seq_lseek | stat_open | single_release |
| proc_bsptest_info_operations | `0xffffffc0120083b0` | d | 0x150 | seq_lseek | bsptest_info_open | single_release |
| psi_io_fops | `0xffffffc012118530` | d | 0x120 | seq_lseek | psi_io_open | psi_fop_release |
| psi_memory_fops | `0xffffffc012118650` | d | 0x120 | seq_lseek | psi_memory_open | psi_fop_release |
| psi_cpu_fops | `0xffffffc012118770` | d | 0x120 | seq_lseek | psi_cpu_open | psi_fop_release |
| irq_affinity_proc_fops | `0xffffffc012118d08` | d | 0x120 | seq_lseek | irq_affinity_proc_open | single_release |
| irq_affinity_list_proc_fops | `0xffffffc012118e28` | d | 0x120 | seq_lseek | irq_affinity_list_proc_open | single_release |
| default_affinity_proc_fops | `0xffffffc012118f48` | d | 0x120 | seq_lseek | default_affinity_open | single_release |
| uid_io_stat_fops | `0xffffffc012119690` | d | 0x120 | seq_lseek | uid_stat_open | single_release |
| stat_top_all_fops | `0xffffffc0121197b0` | d | 0x120 | seq_lseek | stat_top_open_all | single_release |
| stat_top_fops | `0xffffffc0121198d0` | d | 0x120 | seq_lseek | stat_top_open | single_release |
| top_exit_fops | `0xffffffc0121199f0` | d | 0x120 | seq_lseek | top_exit_open | single_release |
| mmonitor_file_operations | `0xffffffc012119c40` | d | 0x120 | seq_lseek | mmonitor_open | single_release |
| mem_fg_file_operations | `0xffffffc012119d60` | d | 0x120 | seq_lseek | mem_fg_open | single_release |
| mem_lastfg_file_operations | `0xffffffc012119e80` | d | 0x120 | seq_lseek | mem_lastfg_open | single_release |
| memlog_file_operations | `0xffffffc012119fa0` | d | 0x120 | seq_lseek | memlog_open | memlog_release |
| extfreekb_file_operations | `0xffffffc01211a0c0` | d | 0x120 | seq_lseek | extfreekb_open | extfreekb_release |
| swait_file_operations | `0xffffffc01211a1e0` | d | 0x120 | seq_lseek | swait_open | swait_release |
| appmem_detail_file_operations | `0xffffffc01211a300` | d | 0x120 | seq_lseek | appmem_detail_open | appmem_release |
| appmem_file_operations | `0xffffffc01211a420` | d | 0x120 | seq_lseek | appmem_open | appmem_release |
| mem_antifrag_file_operations | `0xffffffc01211a540` | d | 0x120 | seq_lseek | mem_antifrag_open | seq_release |
| mem_blocks_mb_file_operations | `0xffffffc01211a660` | d | 0x130 | seq_lseek | mem_blocks_mb_open | seq_release |
| vaudit_operations | `0xffffffc01211a8e0` | d | 0x120 | seq_lseek | vaudit_open | single_release |
| fas_render_ops | `0xffffffc01211aa88` | d | 0x120 | seq_lseek | fas_render_open | single_release |
| fas_audio_ops | `0xffffffc01211aba8` | d | 0x120 | seq_lseek | fas_audio_open | single_release |
| prof_cpu_mask_proc_fops | `0xffffffc01211ae00` | d | 0x120 | seq_lseek | prof_cpu_mask_proc_open | single_release |
| proc_modules_operations | `0xffffffc01211bec8` | d | 0x120 | seq_lseek | modules_open | seq_release |
| kallsyms_operations | `0xffffffc01211c020` | d | 0x120 | seq_lseek | kallsyms_open | seq_release_private |
| show_traces_fops | `0xffffffc01211d560` | d | 0x120 | seq_lseek | show_traces_open | show_traces_release |
| tracing_iter_fops | `0xffffffc01211d8c0` | d | 0x120 | seq_lseek | tracing_trace_options_open | tracing_single_release_tr |
| tracing_fops | `0xffffffc01211d9e0` | d | 0x120 | tracing_lseek | tracing_open | tracing_release |
| trace_clock_fops | `0xffffffc01211e1c0` | d | 0x120 | seq_lseek | tracing_clock_open | tracing_single_release_tr |
| trace_time_stamp_mode_fops | `0xffffffc01211e400` | d | 0x120 | seq_lseek | tracing_time_stamp_mode_open | tracing_single_release_tr |
| tracing_err_log_fops | `0xffffffc01211e640` | d | 0x120 | tracing_lseek | tracing_err_log_open | tracing_err_log_release |
| tracing_saved_cmdlines_fops | `0xffffffc01211eda0` | d | 0x120 | seq_lseek | tracing_saved_cmdlines_open | seq_release |
| tracing_saved_tgids_fops | `0xffffffc01211efe0` | d | 0x120 | seq_lseek | tracing_saved_tgids_open | seq_release |
| tracing_stat_fops | `0xffffffc012120318` | d | 0x120 | seq_lseek | tracing_stat_open | tracing_stat_release |
| ftrace_formats_fops | `0xffffffc012120480` | d | 0x120 | seq_lseek | ftrace_formats_open | seq_release |
| ftrace_avail_fops | `0xffffffc0121205d0` | d | 0x120 | seq_lseek | ftrace_event_avail_open | seq_release |
| ftrace_event_format_fops | `0xffffffc012120a50` | d | 0x120 | seq_lseek | trace_format_open | seq_release |
| ftrace_set_event_fops | `0xffffffc012120dd0` | d | 0x120 | seq_lseek | ftrace_event_set_open | ftrace_event_release |
| ftrace_set_event_pid_fops | `0xffffffc012121010` | d | 0x120 | seq_lseek | ftrace_event_set_pid_open | ftrace_event_release |
| event_trigger_fops | `0xffffffc012121440` | D | 0x120 | tracing_lseek | event_trigger_open | event_trigger_release |
| kprobe_events_ops | `0xffffffc0121219c8` | d | 0x120 | seq_lseek | probes_open | seq_release |
| kprobe_profile_ops | `0xffffffc012121ae8` | d | 0x120 | seq_lseek | profile_open | seq_release |
| dynamic_events_ops | `0xffffffc012121e18` | d | 0x120 | seq_lseek | dyn_event_open | seq_release |
| uprobe_events_ops | `0xffffffc012122378` | d | 0x120 | seq_lseek | probes_open | seq_release |
| uprobe_profile_ops | `0xffffffc012122498` | d | 0x120 | seq_lseek | profile_open | seq_release |
| bpffs_map_fops | `0xffffffc012123d40` | d | 0x120 | None | bpffs_map_open | bpffs_map_release |
| shrinker_proc_fops | `0xffffffc012126bf0` | d | 0x120 | seq_lseek | shrinker_proc_open | single_release |
| shrinker_detail_proc_fops | `0xffffffc012126d10` | d | 0x128 | seq_lseek | shrinker_detail_proc_open | single_release |
| proc_slabinfo_operations | `0xffffffc012128460` | d | 0x120 | seq_lseek | slabinfo_open | seq_release |
| meminfo_slub_fops | `0xffffffc012128580` | d | 0x120 | seq_lseek | meminfo_slub_open | seq_release |
| proc_swaps_operations | `0xffffffc012129720` | d | 0x120 | seq_lseek | swaps_open | seq_release |
| kmemleak_fops | `0xffffffc01212a0a8` | d | 0x120 | seq_lseek | kmemleak_open | seq_release |
| proc_cma_info_fops | `0xffffffc01212a2f0` | d | 0x120 | seq_lseek | proc_cma_info_open | single_release |
| mem_big_data_proc_fops | `0xffffffc01212a410` | d | 0x128 | seq_lseek | mem_big_data_proc_open | single_release |
| kmem_pressure_level_fops | `0xffffffc01212a670` | d | 0x120 | seq_lseek | kmem_pressure_level_open | single_release |
| proc_mounts_operations | `0xffffffc01212d1f0` | D | 0x120 | seq_lseek | mounts_open | mounts_release |
| proc_mountinfo_operations | `0xffffffc01212d310` | D | 0x120 | seq_lseek | mountinfo_open | mounts_release |
| proc_mountstats_operations | `0xffffffc01212d430` | D | 0x140 | seq_lseek | mountstats_open | mounts_release |
| proc_pid_maps_operations | `0xffffffc01212e9d8` | D | 0x120 | seq_lseek | pid_maps_open | proc_map_release |
| proc_pid_virt_operations | `0xffffffc01212eaf8` | D | 0x120 | seq_lseek | pid_virt_open | proc_map_release |
| proc_pid_smaps_operations | `0xffffffc01212ec18` | D | 0x120 | seq_lseek | pid_smaps_open | proc_map_release |
| proc_pid_smaps_rollup_operations | `0xffffffc01212ed38` | D | 0x120 | seq_lseek | smaps_rollup_open | smaps_rollup_release |
| proc_single_file_operations | `0xffffffc012130300` | d | 0x120 | seq_lseek | proc_single_open | single_release |
| proc_pid_sched_operations | `0xffffffc012130420` | d | 0x120 | seq_lseek | sched_open | single_release |
| proc_pid_set_comm_operations | `0xffffffc012130540` | d | 0x120 | seq_lseek | comm_open | single_release |
| proc_pid_sched_wake_up_idle_operations | `0xffffffc012131d50` | d | 0x120 | seq_lseek | sched_wake_up_idle_open | single_release |
| proc_pid_sched_init_task_load_operations | `0xffffffc012131e70` | d | 0x120 | seq_lseek | sched_init_task_load_open | single_release |
| proc_pid_sched_group_id_operations | `0xffffffc012131f90` | d | 0x120 | seq_lseek | sched_group_id_open | single_release |
| proc_pid_sched_low_latency_operations | `0xffffffc0121322f0` | d | 0x120 | seq_lseek | sched_low_latency_open | single_release |
| proc_pid_rsc_boost_operations | `0xffffffc012132410` | d | 0x120 | seq_lseek | rsc_boost_open | single_release |
| proc_pid_set_timerslack_ns_operations | `0xffffffc012132650` | d | 0x120 | seq_lseek | timerslack_ns_open | single_release |
| proc_seq_fops | `0xffffffc012133a40` | d | 0x120 | seq_lseek | proc_seq_open | proc_seq_release |
| proc_seq_vmalloc_fops | `0xffffffc012133b60` | d | 0x120 | seq_lseek | proc_seq_open_vmalloc | proc_seq_release |
| proc_single_fops | `0xffffffc012133c80` | d | 0x140 | seq_lseek | proc_single_open | single_release |
| proc_fdinfo_file_operations | `0xffffffc012134440` | d | 0x128 | seq_lseek | seq_fdinfo_open | single_release |
| meminfo_quick_proc_fops | `0xffffffc012134588` | d | 0x120 | seq_lseek | meminfo_quick_proc_open | single_release |
| rms_version_proc_fops | `0xffffffc0121346a8` | d | 0x120 | seq_lseek | rms_version_proc_open | single_release |
| sec_enable_proc_fops | `0xffffffc012134d40` | d | 0x120 | seq_lseek | sec_enable_proc_open | single_release |
| sec_stage_proc_fops | `0xffffffc012134e60` | d | 0x120 | seq_lseek | sec_stage_proc_open | single_release |
| sec_enable_anti_rollback_proc_fops | `0xffffffc012134f80` | d | 0x120 | seq_lseek | sec_enable_anti_rollback_proc_open | single_release |
| key_hash_proc_fops | `0xffffffc0121350a0` | d | 0x120 | seq_lseek | key_hash_proc_open | single_release |
| rpmb_prov_proc_fops | `0xffffffc0121351c0` | d | 0x120 | seq_lseek | rpmb_prov_proc_open | single_release |
| proc_net_seq_fops | `0xffffffc012135820` | d | 0x120 | seq_lseek | seq_open_net | seq_release_net |
| proc_net_single_fops | `0xffffffc012135940` | d | 0x140 | seq_lseek | single_open_net | single_release_net |
| jbd2_seq_info_fops | `0xffffffc01213a0c0` | d | 0x120 | seq_lseek | jbd2_seq_info_open | jbd2_seq_info_release |
| sel_avc_cache_stats_ops | `0xffffffc012155320` | d | 0x120 | seq_lseek | sel_open_avc_cache_stats | seq_release |
| ddebug_proc_fops | `0xffffffc012166830` | d | 0x120 | seq_lseek | ddebug_proc_open | seq_release_private |
| uid_cputime_fops | `0xffffffc01219c850` | d | 0x120 | seq_lseek | uid_cputime_open | single_release |
| uid_io_fops | `0xffffffc01219c970` | d | 0x120 | seq_lseek | uid_io_open | single_release |
| proc_ion_mm_heap_fops | `0xffffffc01219e540` | d | 0x120 | seq_lseek | proc_ion_mm_heap_open | single_release |
| input_devices_fileops | `0xffffffc0121ab8b8` | d | 0x120 | seq_lseek | input_proc_devices_open | seq_release |
| input_handlers_fileops | `0xffffffc0121ab9d8` | d | 0x120 | seq_lseek | input_proc_handlers_open | seq_release |
| ion_proc_stat_ops | `0xffffffc0121d1c48` | d | 0x120 | seq_lseek | ion_proc_stat_open | single_release |
| binder_stats_fops | `0xffffffc0121d6d60` | d | 0x120 | seq_lseek | binder_stats_open | single_release |
| binder_state_fops | `0xffffffc0121d6e80` | d | 0x120 | seq_lseek | binder_state_open | single_release |
| binder_transactions_fops | `0xffffffc0121d6fa0` | d | 0x120 | seq_lseek | binder_transactions_open | single_release |
| binder_transaction_log_fops | `0xffffffc0121d70c0` | d | 0x14f | seq_lseek | binder_transaction_log_open | single_release |
| proc_fops | `0xffffffc0121d7540` | d | 0x140 | seq_lseek | proc_open | single_release |
| pem_cmd_fops | `0xffffffc0121d7bb0` | d | 0x120 | seq_lseek | pem_cmd_open | single_release |
| pem_aprocess_fops | `0xffffffc0121d7df0` | d | 0x120 | None | pem_aprocess_open | single_release |
| pem_pidcputime_fops | `0xffffffc0121d7f10` | d | 0x120 | None | pem_pidcputime_open | pem_pidcputime_release |
| pem_wake_up_reason_fops | `0xffffffc0121d8030` | d | 0x120 | None | pem_wake_up_reason_open | single_release |
| pem_thml_para_fops | `0xffffffc0121d8150` | d | 0x120 | None | pem_thml_para_open | single_release |
| sla_tcp_stat_fops | `0xffffffc0121d84d0` | d | 0x120 | seq_lseek | sla_tcp_stat_open | single_release |
| config_fops | `0xffffffc0121d8690` | d | 0x120 | seq_lseek | config_file_open | single_release |
| dupack_fops | `0xffffffc0121d87b0` | d | 0x120 | seq_lseek | dupack_file_open | single_release |
| sla_sock_diag_fops | `0xffffffc0121d89f0` | d | 0x120 | seq_lseek | sla_sock_diag_open | single_release |
| snd_info_text_entry_ops | `0xffffffc0121d9370` | d | 0x120 | seq_lseek | snd_info_text_entry_open | snd_info_text_entry_release |
| rt_cache_seq_fops | `0xffffffc0122162f8` | d | 0x120 | seq_lseek | rt_cache_seq_open | seq_release |
| rt_cpu_seq_fops | `0xffffffc012216418` | d | 0x120 | seq_lseek | rt_cpu_seq_open | seq_release |

(共 114 行)
