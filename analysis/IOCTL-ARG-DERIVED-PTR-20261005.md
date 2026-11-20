# ioctl(165) 的 "把 arg 本身当内核指针" 补扫（§7A）—— 完整覆盖的**负结果**（2026-10-05）

## 0. 这一格在整条线里的位置（前置条件没变）
`analysis/CFI-FOPS-TARGETS-20260927.md` §7 留了两个**零风险离线**补扫：
- **(A)** 旧的 292 成员穷举（read(63)+write(64)+ioctl(165)）**只筛了"`private_data` 派生的指针"**；
  没人扫过 **"ioctl 的 `arg` 自己被抓成内核指针"** 的形状 —— 本文就是补这一刀。
- (B) `open(131)` 里找"把 `filp->private_data` 换成可塑形堆对象"的成员（**未做**，见 §4）。

★这不是新洞：**整条线的前置仍然是"先把一次 8 字节写落到 `struct file`"**（由 binder-UAF 那条线供，
见 [[binder-uaf-2026]] / `ashmem-fop-write-channel.md`）。本文回答的只是"有了那次写之后，
165 个 ioctl 入口里有没有一个能直接把 `arg` 当内核地址用"，也就是"能不能拿到任意地址读/写"。
**全文不出现"可利用"字样**：只报指令形状与到达它的 `cmd` 门。

## 1. 方法与数据源（都可复现）
- 同类型表：`analysis/cfi_type_tables.txt` **第 14245 行**，`base=0xffffffc011589764`，`n=165`，
  `ashmem_ioctl` 是第 88 个成员（用 `n=165` + 必须含 `ashmem_ioctl` 两个条件锁行，不靠行号）。
- 符号→链接地址：`analysis/kallsyms_g2a88cd145def.txt`；165 个名字**全部解析成功**（`无法解析 0`）。
- 镜像与映射：`analysis/kernel_dev_g2a88cd145def.bin`，`BASE=0xffffffc010080000`，
  文件偏移 = `link - BASE`。**这条映射单独验过**：`ashmem_ioctl@0xffffffc010eee6ac` 反汇编出来是
  正常函数序言（`sub sp, sp, #0x170` / `stp x29,x30` / `mov w21, w1`…），不是垃圾字节。
- 扫描器：`analysis/ioctl_arg_scan.py`（capstone AArch64）。入口约定
  `unlocked_ioctl(struct file *filp /*x0*/, unsigned int cmd /*w1*/, unsigned long arg /*x2*/)`
  ⇒ **污点种子 = `x2`**，`w1` 用来报 `cmd` 门。
- uaccess 判定：`_copy_to_user(to=__user,from=内核,n)` 的内核侧槽 = `x1`；
  `_copy_from_user(to=内核,from=__user,n)` 的内核侧槽 = `x0`；另外把 `memcpy/memset/strlen/kfree/
  *lock*` 等按参数位置分类（`COPY_SPEC`/`MEMCPY2`/`LOCK0`，见脚本 92-135 行）。
- **"是否落在 uaccess 窗口内"** 的启发式：该 load/store 前后 `[-80,+40]` 条指令里出现
  `msr/mrs ttbr0_el1`（本机是带 TTBR0 切换补丁的 5.4 厂商树）⇒ 标 `UAACCESS-GUARDED`
  ，意思是"这个 arg 派生的地址是按**用户指针**访问的"，不是内核解引用。

## 2. 结果（两个上限都跑完，覆盖是完整的）
| 扫描 | 每函数上限 | 截断的函数 | KPTR-COPY | arg 派生且**不在** uaccess 窗口内的 DEREF |
|---|---|---|---|---|
| 快扫（脚本默认） | 400 条 | **31** | **0** | 8 个直接命中 + 107 个一层跟进命中，**全部带 `UAACCESS-GUARDED`** |
| 深扫（本次补跑，只针对那 31 个） | 8000 条 | **0** | **0** | **0** |

⇒ **165/165 个同类型 `unlocked_ioctl` 成员，在"整个函数都看完"的覆盖下，没有任何一个把 `arg`
当成内核侧缓冲区或内核地址来写/读。** §7(A) 到此关闭。
深扫覆盖到的 31 个正是厂商最重的那批（`ipa3_ioctl` 4668 条、`qseecom_ioctl` 5524、`fastrpc_device_ioctl`
1914、`binder_ioctl` 1789、`ext4_ioctl` 1590、`f2fs_ioctl` 1309、`sg_ioctl` 2607、`ppp_ioctl` 1049、
`tty_ioctl` 660、`watchdog_ioctl` 877、`hiddev_ioctl` 800、`spidev_ioctl` 903、`smcinvoke_ioctl` 655…），
所以"截断里可能藏着形状"这个担心已经被排掉，不是留着当借口。
复现深扫：`import analysis/ioctl_arg_scan.py` 后对 `out[*]['full']==False` 的 31 个函数
调 `scan(addr, {'x2':('ptr','arg')}, 'top', budget=8000)`（本次结果就是这两行跑出来的，无新脚本）。

## 3. 三条必须写明的覆盖限制（别把负结果说满）
1. **污点跟进只有一层**：`INDIRECT` 是"top 函数里 `bl` 到一个**同表尺寸可容**的静态 helper"再扫一次；
   两层以上的调用链没跟。⇒ "arg 被传到第三个函数里当内核指针"这种形状本次**测不出来**。
2. **`UAACCESS-GUARDED` 是邻近启发**，不是证明：它只看 ±80/40 条里有没有 `ttbr0_el1` 读写。
   反向的风险是"真内核解引用恰好离一次 ttbr0 切换很近而被误标成 guarded"。本次 8+107 个命中
   全都带这个标，也就是说**这个启发式一旦错，本文的负结论就跟着错** ⇒ 若要推翻，
   最便宜的证伪法是把 `LOCK0`/`COPY_SPEC` 判据换成"逐条人工读那 8 个直接命中"（都是 ≤20 行上下文的事）。
3. `cmd` 门只是**近似**（从 `cmp w1, #imm` 捞出来的），没建模 switch 的跳转表；所以"哪个 cmd 到那条路径"
   只能当线索，不能当结论。

## 4. 这条线现在剩什么
- **(B) 未做**：`open(131)`（表行 `0xffffffc011589…`，n=131）里找"把 `filp->private_data` 指到
  `kmalloc`/可塑形对象"的成员 —— 那才是把 §2 里"基址固定、够不到 cred"这一堵墙搬开的东西
  （`stats_read` 的窗口基址固定在静态 `.data`，见 `CFI-FOPS-TARGETS-20260927.md` §2/§3）。
- 与本文同源的另一个未验前提：`file->f_op = +0x28` / `private_data = +0xd8` /
  `pd+0x10 == 伪 fops 本体` 都来自**离线镜像里的指令**（一手指令，非 `.rs`），
  但**"把 f_op 真顶成一个别的 fops 静态地址"这件事在真机上从没做过一次无崩对照**。
  真要往下走，最小一步是那条负/正对照实验（`CFI-FOPS-TARGETS` §6 已从静态判死一个变体，另一变体在 §2）。
- ★顺带纠正：项目记忆索引里"只剩 ioctl(165) 待审"这句**已过期**（它是 2026-09-26 的状态，
  09-27 的复核 + 本文把 ioctl 这一半彻底关掉了），索引与 `ashmem-fop-write-channel.md` 正文都已改。
