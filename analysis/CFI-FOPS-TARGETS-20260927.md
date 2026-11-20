# CFI-FOPS 同类型劫持目标评审 (2026-09-27)

对象：把 `ashmem_misc.fops`（一次指针写）顶成**我们完全可控的栈上伪 `file_operations`（地址 S）**后，
`open("/dev/ashmem")` 使 VFS 用我们的表；此时 `file->private_data = &ashmem_misc`（**一个已知的固定 .data 地址**），
`file->f_op = S`。本文回答：**哪一个间接调用槽、顶成哪一个同类型现成内核函数，能给出通往 uid0 / 任意内核读写的路。**

所有反汇编证据均来自**真机同构建** `kernel_dev_g2a88cd145def.bin` + `kallsyms_g2a88cd145def.txt`
（load base `0xffffffc010080000`），符号即设备 build 的 link-time 地址（运行期 = link + slide）。
凡是标【已验证】= 我逐条读了反汇编；【推断】= 依据上游 5.4 语义/结构体定义。

---

## 0. 三处必须更正的承重前提（错了会白重启）

### 0.1 【已验证 + 源码】本 build 的 `struct miscdevice` **没有 owner 字段**
`k54src/include/linux/miscdevice.h`（即本内核）定义：
```
struct miscdevice {
  int                  minor;   // +0x00 (4B) +4 pad
  const char *         name;    // +0x08
  const file_operations* fops;  // +0x10   ← 我们的写落点，正确
  struct list_head     list;    // +0x18 next / +0x20 prev  ← 真机运行期是真实 .data 指针
  struct device *      parent;  // +0x28   (ashmem 未设 ⇒ NULL)
  struct device *      this_device; // +0x30 (misc_register 里 device_create ⇒ 堆指针!)
  const attribute_group **groups;// +0x38  (NULL)
  const char *         nodename;// +0x40
  umode_t              mode;    // +0x48
};                                // sizeof ≈ 0x50
```
⇒ 任务书里“+0x18 = owner”是**旧（<5.0）布局**，本内核不成立。
+0x18 是 `list.next`（指向 misc_list 里下一个 miscdevice，**运行期真指针**）；+0x30 是 `this_device`（**堆指针**）。
“跳过模块引用计数”的正确做法：把伪 fops 的 `.owner`（**file_operations +0x00**）置 0，使 `fops_get()` 的
`try_module_get(fops->owner)` 走 builtin 分支返回真——与任务书“owner 槽置 NULL”一致，只是它属于
`file_operations`（+0x00）不是 `miscdevice`。【推断，上游 fops_get 语义】

### 0.2 【已验证】关键偏移：`file->f_op = +0x28`，`file->private_data = +0xd8`
全表内每条 `ldr x?,[x0,#0xd8]` 即从 `struct file*` 取 private_data；`show_fdinfo` 调用点取 `f_op=[x,#0x28]`。
（承接 `CFI-SAMETYPE-TABLES-20260926.md` §4.1b 与本次多条一手指令。）

### 0.3 【已验证】`private_data + 0x10 == S`（即伪 fops 本体）
因为 miscdevice.fops 就是我们写的 S。⇒ **任何 handler 若把 `private_data` 当自身设备结构、
去读它的 `+0x10` 字段并当指针解引用/拷贝，就等于读了我们完全可控的栈缓冲 S**——这是把“类型混淆”升级成
“任意地址读写”的唯一可控指针通道。**但见 §3：我在 read/write/ioctl 三张同类型表里穷举确认——没有任何函数把 `pd+0x10` 当数据指针用。**

> **★2026-10-05 一手更正(这条前提错了，但 §3 的负结果不受影响)**：对**正常 open 出来的 `/dev/ashmem` fd**,
> `filp->private_data` **不是 `&ashmem_misc`**。两条独立指令证据：
> ① `misc_open@0xffffffc0109d8950` 里 `str x22,[x19,#0xd8]`(=pd=miscdev) 在**第 64 条**,
>    而间接调用 `blr` 在第 **79/216/248** 条 ⇒ misc 层是**先**写 pd、**后**调设备的 `.open`;
> ② `ashmem_open@0xffffffc010eeee04` 随后 `bl kmem_cache_zalloc` → `str x20,[x19,#0xd8]`
>    把 pd **覆盖成 per-fd 的 `struct ashmem_area`**(源码同句：厂商树
>    `k54src/drivers/staging/android/ashmem.c:250-269`，注释自己写着 "written to file->private_data")。
> ⇒ 所以 `pd+0x10` 落在**用户可用 `ASHMEM_SET_NAME` 写的 name 区**(实测可写范围 `pd+0x0b..0x10a`),
>    不是"miscdevice 里的 fops 指针"。"§0.3 = S" 这个等式作废；
>    但 §3 那句"没有任何函数把 `pd+0x10` 当数据指针用"是**独立穷举**得出的，仍然成立。
>    新形状(把窗口搬到可塑形堆对象)的意义与后续待复核项见 `analysis/OPEN-PD-SHAPEABLE-20261005.md`。
所以这条路在本表集合内是**死的**（重要负结果，省下盲目试错）。

---

## 1. 直接回答“哪个槽”

- `.unlocked_ioctl`（165 成员，含 compat，线 14244）：**唯一能用纯 `ioctl()` 系统调用把 cmd+arg 全交给我们的槽**。
  但见 §2/§4：成员几乎全部把 `private_data` 当**自家设备句柄**解引用 ⇒ 在 `pd=&ashmem_misc` 下 oops/死锁；
  不碰 pd 的少数几个（mem_buf/ipa3/stats_data）又**只提供对全局/fd/smem 的操作，不构成任意地址读写**。
- `.read`（63 成员，线 14208）/ `.write`（64 成员，线 14212）：`read()/write()` 把 **用户 buf + 可控 count + 可控 ppos(lseek)** 交给函数——
  **天然适合做“安全、可重复、长度/偏移可控”的内核读**。⇒ 本 build 的最佳“无害读写入口”在这里，不在 ioctl。
  `.write` 穷举：**没有任何 handler 用 `copy_from_user`/`simple_write_to_buffer` 把数据写进 `private_data`**（负结果）⇒ 写原语此路不通。
- `.open`（131 成员，线 14239）：open 无 arg，最多把 `private_data` 改设成某全局/新分配对象；本轮未找到“把 pd 设成我们可控指针”的成员（列为下一步专门搜）。
- `.mmap`（仅 4 成员）/ `.llseek`(27) / `.get_unmapped_area` / `.poll`：均不产生任意内核读写；mmap 4 成员里无“用户给 pfn 即映射”者（承接前文）。

**结论槽 = `.read`，函数 = `stats_read`。** 它是本表集合里**唯一经反汇编证实的“安全 + 可控长度/偏移 + 无 pd 解引用 + 无锁 + 无间接调用”内核读原语**。

---

## 2. 首选：`.read` 槽 → `stats_read` @ `0xffffffc010f73220`【已验证】

序言即全部（函数只有 6 条实指令 + `simple_read_from_buffer`）：
```
f73230: ldr x3, [x0, #0xd8]    ; x3 = file->private_data = &ashmem_misc   ← 只当线性地址，从不解引用
f73234: mov w4, #0x3ed0
f7323c: movk w4, #6, lsl #16   ; w4 = available = 0x63ed0 (≈ 400KB)
f73238: mov x0, x1             ; to   = 用户 buf (read() 传入)
f73240: mov x1, x2             ; count= 用户传入
f73244: mov x2, x8             ; ppos = &file->f_pos   (可用 lseek 预置 ⇒ 偏移可控)
f73248: bl simple_read_from_buffer(to=x0, count=x1, ppos=x2, from=x3(=&misc), avail=x4=0x63ed0)
```
`simple_read_from_buffer` 语义 = `copy_to_user(to, from + *ppos, min(count, avail-*ppos))`。
⇒ **原语 = 读取 `[&ashmem_misc + off , +0x63ed0)` 区间内任意偏移、任意长度(≤400KB) 的内核 .data/.bss 字节，送回用户 buf**。

private_data 要求：**无**（任何非空都行，我们正好有 `&ashmem_misc`）。
不触碰任何指针解引用/锁/间接调用 ⇒ **CFI 无关、无 oops、可无限重复**。

**局限（诚实）**：`from` 基址**固定为 &ashmem_misc**，且 `ppos≥0` 只能**向后**读，窗口 = `[0x12a55960, 0x12ab9830)`。
经核对 kallsyms：`init_cred(0x1293d528)`、`init_task`、`init_nsproxy`、`__per_cpu_offset` 都在窗口**之下（读不到）**，
`nr_threads` 在窗口之上（略超）。⇒ **stats_read 不能直接读到 cred/task_struct，也不能顺着某个指针往里跟（基址固定）。**

它的真正价值（作为链条一环）：
1. **零风险证明“一次指针写→fops 劫持”这条通道成立**（读回确定性 .data 字节）；
2. **钉死 KASLR slide**（窗口里满是“值 = link+slide”的指针，一比对即得 slide）；
3. 泄漏窗口内的**真实指针**：`this_device`(pd+0x30)=**堆指针**（打掉堆 KASLR）、各 miscdevice 的 name/fops（=slide 后可算全镜像）。

---

## 3. 关键负结果【已验证，穷举 read(63)+write(64)+ioctl(165)=292 函数】

写脚本批量反汇编三张表，按“**是否 `ldr x?,[x0,#0xd8]` 取 pd 后，把 `[pd+K]` 当指针用于 copy/deref**”筛选：
- **没有任何成员读 `pd+0x10`（=可控的 S）当数据指针** ⇒ 无法把 hijack 升级成“任意地址（S 里放谁就读/写谁）”。
- `.write` 表里**没有任何成员** `copy_from_user`/`simple_write_to_buffer` 写向 `private_data` ⇒ 无 .data 写通道。
- 唯一的“把 pd 整个当缓冲区读”的成员就是 `stats_read`（from=pd，不解引用）；其余读表成员（acc_read/synx_read/vsoc_read/nb_read）
  都把 pd 当**自家结构 + 立即解引用**（见 §5），在 `pd=&misc` 下崩溃。

⇒ **本几何（pd=&misc 固定 .data）下，同类型 fops 表给不出“干净任意地址 RW”，只给出一个固定窗口的大范围 LEAK。**
这条判死本身省掉后续多次盲目真机试错。

---

## 4. 备选（按可用度排序）

**#2 `.unlocked_ioctl` → `i2cdev_ioctl` @ `0xffffffc010188280`**【部分已验证 + 承接 IOCTL-CFI-165-REFRAME §6.1】
- pd 要求：入口 `ldrh [pd]` 读 misc.minor（无害）；`x8 = *(pd+0x18) = list.next`（**真机=另一 miscdevice 的真指针，可先用 stats_read 读出**）。
- 对 arg：`I2C_SLAVE`(0x703) 分支 `str w19,[x8,#0x6c]`，w19 被钳 ≤0x3ff。
- 得到：**向 `list.next + 0x6c` 写 4 字节（值∈[0,0x3ff]，高位必 0）**，目的地址=某已知 .data 邻接对象。
- 通往 uid0：❌ 够不到 cred（写基址非 task/cred，且值受限）。只有“把某 .data 全局清零/置小值”的边角用途。列为次选而非主选。

**#3 `.unlocked_ioctl` → 不碰 pd 的 `stats_data_ioctl`@`0xffffffc01095b8a8` / `mem_buf_dev_ioctl`@`0xffffffc010966244` / `ipa3_ioctl`@`0xffffffc01101b99c`**【已验证：pd 不进入】
- 三者入口均**不** `ldr [x0,#0xd8]` ⇒ `pd=&misc` 完全无害，是安全的第一实验候补。
- 但**不构成任意地址读写**：stats_data 只 `copy_to_user(arg, 本地小结构)` 且数据源是 `qcom_smem_get` 的固定 smem 项（需该项存在）；
  mem_buf 走 `dma_buf_get(用户fd)`/vaddr 换算，作用于真 dma_buf；ipa3 用全局资源句柄索引。**无 arg-as-内核指针。**

**#4 `.read` → `kgsl_read` @ `0xffffffc010a7ed88`**【已验证】
`simple_read_from_buffer(buf,count,ppos, .rodata 常量串 0x11e47085c, strlen+1)`，**完全忽略 private_data**。安全但零信息量，仅可用于最保守“槽被走”探针。

**#5 `.open`（131 成员）——待搜**：需要“`filp->private_data = <可控/可塑形对象>`”的成员，把窗口基址从 &misc 搬走或搬到堆。本轮未定位，列为下一步离线搜目标。

**#6（负价值）经伪 fops 调 `ashmem_ioctl`——不是安全对照**【已验证】：详见 §6。

---

## 5. 明确判死的候选 + 理由（一手指令）

| 函数 | 地址 | 判死原因（`pd=&ashmem_misc`） |
|---|---|---|
| `synx_ioctl` | 0x10d84c48 | `ldr x19,[x0,#0xd8]`;`ldr w19,[x19]`(=minor) 后 `mov x0,x19; bl synx_create`——把 minor 当 session 指针传入 ⇒ 崩 |
| `gsi_ctrl_dev_ioctl` | 0x10cf1414 | `x8=pd`;`w8=[pd+0]`(minor) 作 `+0x40` 步长索引 gsi 数组再 `mutex_lock` ⇒ 越界/崩 |
| `acc_read` | 0x10ce4aa8 | `ldrh [x23+0xf8]`→`ldr [x8,#0x2e]`（解引用 pd+0xf8 处的 .data 值当指针）+ 在 pd+0x728 的假 wait_queue 上 `schedule()` ⇒ 崩/挂 |
| `qseecom_ioctl` | 0x10b5ce70 | `ldr w8,[pd+0x19c]` 后按 listener 语境解引用 pd ⇒ 崩 |
| `kgsl_ioctl` | 0x10a86568 | `ldp x22,x8,[pd]`;`x8=name+0x1d8`;`stset/ldxr [x8]` 对 **.rodata** 原子写 ⇒ STRICT_KERNEL_RWX 数据异常崩 |
| `smcinvoke_ioctl` | 0x10102760 | `ldr w8,[x28]`(=pd+0=minor) 当“客户端状态”，非 0 即走错误分支 ⇒ 无原语（且不解引用不崩，但也拿不到读写） |
| `fastrpc_device_ioctl` | 0x109e427c | **危险**：`x22=pd+0x10`(=S=`.read` 槽!) 处 `_raw_spin_lock` ⇒ 该 8 字节若非 0 即**死转软锁机**；`ldr [pd+0xb8]` 解引用 ⇒ 崩 |
| `vsoc_ioctl`/`vsoc_read` | 0x10ef0600/0x10ef0300 | pd 仅判空；操作全走 `vsoc_dev` 全局 + **由 inode minor 派生的共享内存** ⇒ 需 minor 命中且非任意地址，不可控 RW |
| `dispatch_ioctl` | 0x10713c0c | 走 inode 伪 fs 字段取指针（§承接旧审计）⇒ 判死 |
| `ext4/f2fs/fuse/fat/dm/…` 文件系统类 | — | `f_inode/f_mapping` 是 ashmem 伪 fs ⇒ 首步 magic 校验失败/oops |

---

## 6. 安全性问答：“把 `.unlocked_ioctl` 也顶成 `ashmem_ioctl`，是否与真机行为一致(无崩对照实验)？”——**否**

`ashmem_ioctl`@`0xffffffc010eee6ac` 期望 `pd = struct ashmem_area`（堆、大对象），我们给的是 `&ashmem_misc`（0x50 字节 .data）：
- `mutex_lock(pd+0x138)`（`0xeee790/0x8d8/0x920/0x9f4` 多处）= 对 `ashmem_misc+0x138`（实为邻接 `vsoc_pci_driver` 区）取锁：若那块非 0/非 mutex 语义 ⇒ **未定义/死锁**。
- `ASHMEM_SET_NAME` → `strcpy(pd+0xb, 用户串)`（`0xeee820` 起的 name 逻辑）：`pd+0xb` 起覆盖 **name(+8)/fops(+0x10) 本身** ⇒ 会把我们刚装的 `misc.fops=S` 踩成字符串 ⇒ 下次 open 用垃圾指针 → 崩；且外溢进 `vsoc_pci_driver`。
- `ASHMEM_SET_SIZE` → `str x20,[pd+0x128]`（`0xeeea14` 的 `=misc+0x128=vsoc_pci_driver+0x98`）**以 `ldr [pd+0x120]`(=misc+0x120=`vsoc_pci_driver+0x90`)=0 为前提**；该处是 pci_driver 字段，大概率非 0 ⇒ 走 `-EBUSY` 分支，不写。

⇒ 伪 fops 下 `ashmem_ioctl` **绝不“等同真机”**，且 SET_NAME/取锁路径**有明确崩/锁死风险**。**不要**拿它当第一实验。
**第一实验请用 `.read`=stats_read（§2）或 `.unlocked_ioctl`=stats_data/mem_buf（§4#3，pd 不进入，纯无害）。**

---

## 7. 推荐与下一步实验

**推荐（本轮唯一经反汇编坐实的可用原语）：槽 = `.read`，函数 = `stats_read`（0xffffffc010f73220）。**
伪 fops 里只填两处：`.owner(file_ops+0x00)=0`（过 fops_get）、`.read(+0x10)=stats_read`，其余全 0（尤其 `.open=0` 以免误触发，
`unlocked_ioctl=0` 以免任何 handler 把 `pd+0x10` 误当锁/指针——注意 `pd+0x10` 恰是本表 S，与 fastrpc 的 spin_lock 雷区同源）。

**下一次真机动作（风险最低、信息最高）：**
1. 一次指针写 `ashmem_misc.fops(0x12a55960+0x10)=S`；S 内放 `[0]=0, [0x10]=stats_read`（+slide）。
2. `int fd=open("/dev/ashmem",O_RDWR); lseek(fd, off, SEEK_SET); read(fd, ubuf, len);`
   - 读到确定性 .data 字节 ⇒ **通道打通、零崩**；
   - 由窗口内指针算出 **KASLR slide**；
   - 读出 `this_device(pd+0x30)` 等 ⇒ **堆指针**。

**通往 uid0 的缺口（诚实声明）**：stats_read 基址固定、够不到 cred/task_struct，且本轮证明三张同类型表里
**没有“任意地址读/写”成员**。要收口，需二选一（均为**零风险离线**任务）：
- **(A)** 在 ioctl(165) 里专搜“把 **arg 当内核指针**做 `copy_to_user(ubuf, arg, n)`/解引用”的厂商函数（本轮扫描只针对 pd 派生，arg 直接解引用是另一类，需补扫）；
- **(B)** 在 open(131) 里找“`filp->private_data = kmalloc/可塑形对象`”的成员，把窗口基址搬到堆，使某 `.read` 能顺指针跟到 task_struct。

拿到任一“任意地址读”后：读回 `current`(经 sp_el0/percpu) 或从堆 task 链定位**本任务 task_struct** →
`task->cred`/`task->real_cred` 地址可知 → **用每尝试一次的通用指针写，直接把它俩写成 `init_cred`（0xffffffc01293d528+slide）**，
得到 uid0+全 caps，reboot 即复位（cred 指向只读 init_cred，不改任何页内容）。

---

## 8. 涉及数据
- 表行：ioctl 线 14244（165）、read 线 14208（63）、write 线 14212（64）、open 线 14239（131）、mmap 线 12933（4）、llseek 线 14107（27）。
- 关键 link 地址：`ashmem_misc=0x12a55960`，`init_cred=0x1293d528`，`stats_read=0x10f73220`，`i2cdev_ioctl=0x10188280`，
  `ashmem_ioctl=0x10eee6ac`，`fastrpc_device_ioctl=0x109e427c`，`qseecom_ioctl=0x10b5ce70`，`kgsl_ioctl=0x10a86568`。
- 方法学承接：`CFI-SAMETYPE-TABLES-20260926.md`（偏移 f_op@0x28/private_data@0xd8）、`IOCTL-CFI-165-REFRAME-20260926.md`（旧几何下 i2cdev/snd_compr）。
  **本文的几何不同**：旧文档假设 `private_data` 是可控 name 区的 `ashmem_area`；本情形 `private_data=&ashmem_misc` 固定不可控，故旧结论多数**不再适用**，已按新几何逐条复核。
