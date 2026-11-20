# §7(B) 扫描：`open(131)` 里有没有"把 `private_data` 换成可塑形堆对象"的成员 —— **有，而且就包括 `ashmem_open` 自己**（2026-10-05）

## 0. 前置与口径（先看这段，别把本文读成新洞）
本文是 `CFI-FOPS-TARGETS-20260927.md` §7(B) 那条**零风险离线**待办的答卷，问的是：
"131 个 `open/release` 同类型成员里，有没有谁把 `filp->private_data`（+0xd8）写成
**一个内容可被用户塑造的堆对象**" —— 因为该文 §2/§3 证明 `.read→stats_read` 的窗口基址**固定在静态 `.data`**，
够不到 `cred`/`task_struct`；要把窗口搬到堆上，就得有这种成员。
**不是新洞**：整条线的前置仍是"先把一次 8 字节写落到 `struct file`"（binder-UAF 那条线供）。
全文只报**指令形状 + 源码对应**，不写"可利用/任意读写"。

## 1. 方法与资产
- 表：`analysis/cfi_type_tables.txt` **第 14240 行**，`base=0xffffffc011588684`，`n=131`
  （用"n=131 且 base 等于这个值"两个条件锁行，不靠行号）。成员里 `open`/`release` 原型相同，混在同一张表。
- 脚本：`analysis/open_pd_scan.py`，明细 `analysis/open_pd_scan_out.json`。
  **复用 `ioctl_arg_scan.py` 的镜像映射**（`BASE=0xffffffc010080000`；该映射单独验过：
  `ashmem_ioctl@0xffffffc010eee6ac` 反汇编出来是正常序言），不自己发明地址算术。
- 每函数**整段**反汇编（上限 8000 条）。粗筛两栏**彼此独立**：栏1 = 出现 `str *,[x*,#0xd8]`
  （或 `add x*,x*,#0xd8` 后 6 条内紧跟 `str *,[x*]`）；栏2 = 同函数里出现分配器/收用户数据的调用
  （`k*alloc|kmem_cache_alloc|alloc_pages|kv*vmalloc` / `copy_from_user|memdup_user|…`）。
  ⇒ **命中只意味着"值得人工读一眼"，两栏连成因果链必须人工读**（本文 §2 那三条我读了）。

覆盖：131 个成员全部解析成功；**8000 条上限下没有一个被截断**（`仍截断=0`）。
栏1 命中若干，**栏1∩栏2 = 12 个**：
`dm_open, ovl_dir_open, snd_compr_open, stm_char_open, pm_qos_power_open, ashmem_open, ramdump_open,`
`binder_open, tty_open, hidraw_open, tun_chr_open, pending_reads_open`。

## 2. 三条我逐行读过指令的（其余 9 条只算线索）
### ① `ashmem_open @0xffffffc010eeee04`（size=36，整段看完）
```
0x10eeee14  mov  x19, x1                 ; x1 = struct file *（本表原型 (inode, file)）
0x10eeee18  bl   #0x10579528             ; generic_file_open
0x10eeee2c  bl   #0x1054493c             ; kmem_cache_zalloc(ashmem_area_cachep)
0x10eeee70  str  x20, [x19, #0xd8]       ; ★ filp->private_data = 新分配、已清零的 per-fd 对象
```
与厂商源码逐行对上：`k54src/drivers/staging/android/ashmem.c:250-269`
（`asma = kmem_cache_zalloc(...); INIT_LIST_HEAD(&asma->unpinned_list);
memcpy(asma->name, ASHMEM_NAME_PREFIX, ASHMEM_NAME_PREFIX_LEN); asma->prot_mask = PROT_MASK;
file->private_data = asma;`，且注释自己写着 "the ashmem_area is not returned by this function -
It is instead written to `file->private_data`"）。
**内容可塑性**（这条线的关键，全部一手指令/真机量过）：`ASHMEM_SET_NAME` 直接写进这块对象的 `name` 区
（`pd+0x0b..0x10a`，约 249 字节，前缀 `dev/ashmem/` 固定），`ASHMEM_SET_SIZE→pd+0x128`、
`ASHMEM_SET_PROT_MASK→pd+0x130` —— 后两个偏移是被调用方**实测**钉死的：
```
ashmem_ioctl @0xffffffc010eee6ac:
  0x10eee6e4  ldr x19, [x0, #0xd8]       ; pd（x0=filp）
  0x10eee720  ldr x22, [x19, #0x128]     ; asma->size
```
⇒ **对一个正常 open 出来的 `/dev/ashmem` fd，`private_data` 是那块可塑形的堆对象，不是 `&ashmem_misc`。**

### ② `binder_open @0xffffffc010f4cb70`（size=304）
`bl kmem_cache_alloc_trace` → `0x10f4cdc4 str x19, [x20, #0xd8]`（`struct binder_proc`）。
可塑渠道不是 name 而是它自己的 `ioctl`（`BINDER_SET_CONTEXT_MGR`/`binder_write` 等会写进 proc 的字段）；
**我没有逐字段核对哪些字节用户可控** —— 只报形状。

### ③ `tun_chr_open @0xffffffc010c0c334`（size=74）
`bl kvmalloc_node` → `0x10c0c41c str x20, [x19, #0xd8]`（`struct tun_file`）。
`TUNSETIFF`/读写路径会动里面的字段；同样**未逐字段核对**。

## 3. ★这条结果**推翻/至少动摇**了一处承重前提，必须先复核再往下做
`CFI-FOPS-TARGETS-20260927.md` §0.3 写的是：
> 【已验证】`private_data + 0x10 == S`（即伪 fops 本体），**因为 miscdevice.fops 就是我们写的 S**

而 §2① 的指令与厂商源码都给的是：`/dev/ashmem` 的 fd 上 `pd = per-fd struct ashmem_area`，
`pd+0x10` 落在 **name 区**（用户可写），不是"miscdevice 里的 fops 指针"。
**已复核，胜负分出来了，方式是 (a)——直接读 `misc_open` 的指令**：
`misc_open@0xffffffc0109d8950` 里 `str x22,[x19,#0xd8]`（pd=miscdev）在**第 64 条**，而间接调用 `blr` 在第 **79/216/248** 条 ⇒ misc 层**先**写 pd、**后**调设备的 `.open`，`ashmem_open` 再把 pd 覆盖成 per-fd 的 zalloc 对象。终值 = **可塑形的堆对象**，`pd+0x10` 落在 name 区（`ASHMEM_SET_NAME` 可写）。本地厂商树里没有 `fs/char_misc.c`（树不完整），所以这条**只能靠镜像指令**定，已定。CFI-FOPS §0.3 那条等式已就地标注作废；它 §3 的 292 成员穷举是独立结论，不受影响。
⇒ **动手做真机实验之前必须把这条钉死**，两种便宜证法：
 (a) 离线：在镜像里反汇编 `misc_open`，看 `str *,[x*,#0xd8]` 出现在 `bl …->open` **之前还是之后**；
 (b) 真机（零风险、只读）：`open("/dev/ashmem")` 后 `ASHMEM_SET_NAME("AAAA…")`，
     再用本文 §2① 的 `pd+0x128` 那条路径（`ASHMEM_GET_SIZE` 回显 size）验证
     "size 存在我们写的那块对象里" ⇒ 若 SET_SIZE 之后 GET_SIZE 回显一致，pd 必是 ashmem_area。
★按老规矩把话说全：**"目录不在了"不等于"我知道为什么不在了"，"偏移对上了"也不等于"前提对了"** ——
这里我只有"pd 被 open 写成 zalloc 对象 + ioctl 从 pd+0x128 取 size"这两条一手，
`misc_open` 的终值归属还没验证，所以 §0.3 标为**待复核**，不改写它的负结果（§3 的 292 成员穷举
与本文结论彼此独立，不受这个前提影响）。

## 4. 这条线现在的地图（给下一次省时间）
| 槽 | 表行/base | 结论 | 依据 |
|---|---|---|---|
| `.read` 63 | 14208 | 唯一坐实的原语 `stats_read`，但**基址固定在静态 .data** | CFI-FOPS §2/§3 |
| `.write` 64 | 14212 | 穷举判死 | CFI-FOPS §3 |
| `.unlocked_ioctl` 165 | 14245 | **(A) 已完整覆盖判负**：没人把 `arg` 当内核指针 | `IOCTL-ARG-DERIVED-PTR-20261005.md` |
| `.open/.release` 131 | 14240 | **(B) 有 12 个成员把 pd 写成新分配堆对象**，含 `ashmem_open` | 本文 |
| `.mmap` 4 / `.show_fdinfo` 13 | 12934 / 13876 | 判死（无 `remap_pfn_range` 型 / 只 seq_printf） | `ashmem-fop-write-channel.md` ① |
| `.llseek` 27 | 14107 | 未审 | — |
剩下两件：`.llseek(27)` 没扫；§3 那条 `misc_open` 写入先后的复核**必须**在任何真机尝试之前做掉。
