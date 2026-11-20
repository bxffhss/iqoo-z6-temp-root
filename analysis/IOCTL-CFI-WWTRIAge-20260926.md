# IOCTL-CFI-WWTRIAge-20260926 — 165 个 unlocked_ioctl 同类型处理器的严格三判据复核

对象：vivo iQOO Z6，kernel 5.4.281-qgki（clang CFI），arm64
反汇编权威文件：`C:/qemu_test/vmlinux_full.asm`（与 `analysis/kernel` 字节一致，vaddr = file_off + 0xffffffc010080000，已用两条指令实测验证）
候选集：`analysis/cfi_type_tables.txt` 第 `ashmem_ioctl` 行，`0xffffffc011589764 n=165`
本次为**按预定严格判据重新分诊**，不沿用上一轮的排名。

## 0. 判据（按原文逐条执行）

- **C1**：到 store 的路径上不得 load/lock/deref `private_data + k`（k > 0x10a）。参考已知坏例 `watchdog_ioctl@0xffffffc010df3638`。
- **C2**：store 的基址寄存器必须是从 `private_data + k`（0x0b ≤ k ≤ 0x102，或 0x128/0x130）load 出来的值。`private_data + 常量` = 自写，不算。
- **C3**：store 写入的值派生自 `arg`，或本函数内做 `copy_to_user(ptr_from_C2, kern_src, len)` / `memcpy/copy_from_user(dst_from_C2, user, len)`。

## 1. 结论（判据行数）

**165 个候选中，同时满足 C1+C2+C3 的只有 2 个：**

1. **`snd_compr_ioctl @ 0xffffffc010fa5a8c`** —— 最强。基址 = `*(private_data+0x20)`（窗口内），写入值是 `memdup_user(arg,0x84)` 拷贝进来的**纯用户数据**，一次 ioctl 连写 4+4 字节（+0x28/+0x2c），另有 +0x20 处 8 字节。全函数对 private_data 的访问偏移只有 0x9/0x18/0x20/0x28/0xb0/0xb4，**全部 ≤ 0x10a → C1 干净**。
2. **`i2cdev_ioctl @ 0xffffffc010188280`** —— `str w19,[x8,#0x6c]`，x8 = `*(private_data+0x18)`（窗口内），w19 = `(u32)arg`（唯一约束 `arg < 2^31`）。对 private_data 只访问 0x0/0x2/0x18 → **C1 干净**。

除此之外，163 个全部拒绝。其中最接近、值得记录但**按字面判据不计入 WIN** 的是 `ccid_ctrl_ioctl`（C2 成立、但函数内 store 的值是常量 2/4；它的用户数据写入落在 `*(pd+0x100)` 的**第二跳**上，不属于 C3 列举的形状）与 `sg_ioctl`（C2 成立、值来自 get_user，但具体 cmd 分支未能钉死）。第 6/7 节给出全部逐条证据。

## 2. 方法（一次性、可复现）

1. 从 `cfi_type_tables.txt` 取 165 个名字；用 `analysis/embedded-kallsyms.txt` 解析起始地址。
   注意：kallsyms 里真正的函数符号是 `name$<hash>`（CFI 静态命名），而 `name._rs` / `name.__print_once` 是**数据**别名；按前缀匹配时必须让 `$` 变体优先，否则 `binder_ioctl`/`ion_ioctl`/`ppp_ioctl` 等 7 个会解析到 rodata 地址（本轮已修正，165 个全部落在 text，且与题给的 `watchdog_ioctl@0xffffffc010df3638` 完全一致）。
2. 一次 awk 遍历 `vmlinux_full.asm`（27 s）把 165 个函数体切到独立文件（标签行定界，遇到 kallsyms 中下一个符号即关闭）。
3. 反向 def-walk 标注：`x0=filp` → `ldr xD,[x0,#0xd8]` 得 pd → `ldr xE,[xpd,#k]` 得「窗口值 acpv(k)」→ 扫每条 `str/stp/stur/strb/stxr` 与 `bl` 的基址/实参寄存器；栈槽与 `mov/add/sub` 递归穿透；`bl` 杀 caller-saved。
4. 用 `analysis/kernel`（ARM64 EFI Image，`delta = vaddr - 0xffffffc010080000`）直接读出**跳转表原始字节**，把 case→块地址钉死（i2cdev、snd_compr、sg 三张表已解出，见下）。

## 3. WINNER 1：`snd_compr_ioctl @ 0xffffffc010fa5a8c`

### 3.1 private_data 取值与「全程窗口内」证明

```
ffffffc010fa5a8c: d10243ff     	sub	sp, sp, #0x90
ffffffc010fa5ab4: f9406c17     	ldr	x23, [x0, #0xd8]        ; x23 = filp->private_data
ffffffc010fa5ab8: b4002dd7     	cbz	x23, 0xffffffc010fa6070
ffffffc010fa5abc: f94016e8     	ldr	x8, [x23, #0x28]        ; k=0x28 ∈ 窗口
ffffffc010fa5ac0: aa0203f5     	mov	x21, x2                 ; x21 = arg（用户指针）
ffffffc010fa5ac4: 2a0103f4     	mov	w20, w1                 ; w20 = cmd
ffffffc010fa5ac8: 910042f3     	add	x19, x23, #0x10
ffffffc010fa5acc: 910f2100     	add	x0, x8, #0x3c8
ffffffc010fa5ad0: 9416c672     	bl	0xffffffc011557498 <mutex_lock>
```

`x23` 在整个函数里只有一个定义（`0x10fa5ab4`，另一处 `0x10fa5f8c` 是 epilogue 的栈回读）。对 private_data 的**全部**内存访问（grep `\[x23, #` 的枚举结果，逐条实测）：

```
16 次 [x23, #0x18]   19 次 [x23, #0x20]   4 次 [x23, #0x28]
 2 次 [x23, #0xb0]   4 次 [x23, #0xb4]    （以及 [x19,#-0x7] = [x23,#0x9]）
```
→ 没有任何 > 0x10a 的 private_data 访问，**C1 成立**。
入口处的 `mutex_lock` 目标 = `*(pd+0x28) + 0x3c8`：基址来自窗口内的 8 字节值（攻击者完全可选），且可用 `*(pd+0x28) = (pd+0x40) - 0x3c8` 把这个“假 mutex”落回自己的可控字节（0x40..0x68）→ 不构成 C1 违规，也不必然 oops。

### 3.2 分派：只看 cmd 低字节

```
ffffffc010fa5ad4: 12001e89     	and	w9, w20, #0xff          ; nr = cmd & 0xff
ffffffc010fa5ad8: 51004928     	sub	w8, w9, #0x12
ffffffc010fa5adc: 71008d1f     	cmp	w8, #0x23
ffffffc010fa5ae0: 54000248     	b.hi	0xffffffc010fa5b28      ; 越界→default
ffffffc010fa5ae4: b00091a9     	adrp	x9, 0xffffffc0121da000 <snd_pcm_f_ops+0x200>
ffffffc010fa5ae8: 9113c129     	add	x9, x9, #0x4f0
ffffffc010fa5aec: 1000008a     	adr	x10, 0xffffffc010fa5afc
ffffffc010fa5af0: 3868692b     	ldrb	w11, [x9, x8]           ; u8 跳转表 @0xffffffc0121da4f0
ffffffc010fa5af4: 8b0b094a     	add	x10, x10, x11, lsl #2
ffffffc010fa5af8: d61f0140     	br	x10
```
实测表内容（`0xffffffc0121da4f0`，36 项，base=0x10fa5afc，scale=4）：index 0（即 **cmd & 0xff == 0x12**）→ `0x10fa5afc`。

### 3.3 链路：窗口基址 + 用户数据 → store

```
ffffffc010fa5afc: f94012e8     	ldr	x8, [x23, #0x20]        ; P = *(pd+0x20)   ← C2 基址来源
ffffffc010fa5b00: b9400108     	ldr	w8, [x8]                ; 守卫：*P 必须为 0
ffffffc010fa5b04: 350022a8     	cbnz	w8, 0xffffffc010fa5f58
ffffffc010fa5b08: 52801081     	mov	w1, #0x84               ; 132
ffffffc010fa5b0c: aa1503e0     	mov	x0, x21                 ; arg
ffffffc010fa5b10: 97d533ea     	bl	0xffffffc0104f2ab8 <memdup_user>
ffffffc010fa5b14: aa0003f5     	mov	x21, x0                 ; x21 = 用户数据的内核副本
ffffffc010fa5b18: b13ffc1f     	cmn	x0, #0xfff
ffffffc010fa5b1c: 540026e3     	b.lo	0xffffffc010fa5ff8
```
校验后（`[x21]`、`[x21,#4]`、`[x21,#8]`-1 ≤ 0x100a、`[x21,#0xc]`、`[x21,#0x10]`，以及 `*(pd+0x18)` 的一次解引用判 0）：
```
ffffffc010fa6044: f9400eea     	ldr	x10, [x23, #0x18]       ; k=0x18 ∈ 窗口
ffffffc010fa604c: f940254a     	ldr	x10, [x10, #0x48]
ffffffc010fa6050: b400014a     	cbz	x10, 0xffffffc010fa6078
...
ffffffc010fa6078: f94012e8     	ldr	x8, [x23, #0x20]        ; P（同上）
ffffffc010fa6080: f9400908     	ldr	x8, [x8, #0x10]         ; 守卫：*(P+0x10)==0 → 走 __kmalloc
ffffffc010fa6084: b40000c8     	cbz	x8, 0xffffffc010fa609c
ffffffc010fa609c: 52819801     	mov	w1, #0xcc0
ffffffc010fa60a0: aa1403e0     	mov	x0, x20
ffffffc010fa60a4: 97d6812f     	bl	0xffffffc010546560 <__kmalloc>
ffffffc010fa60a8: b40003a0     	cbz	x0, 0xffffffc010fa611c
ffffffc010fa60ac: b94002a8     	ldr	w8, [x21]               ; ← 用户提供的 u32 #1
ffffffc010fa60b0: f94012e9     	ldr	x9, [x23, #0x20]         ; ← C2：基址 = *(private_data+0x20)
ffffffc010fa60b4: b9002928     	str	w8, [x9, #0x28]         ; ← 写：*(P+0x28) = 用户数据
ffffffc010fa60b8: b94006a8     	ldr	w8, [x21, #0x4]         ; ← 用户提供的 u32 #2
ffffffc010fa60bc: f94012e9     	ldr	x9, [x23, #0x20]
ffffffc010fa60c0: b9002d28     	str	w8, [x9, #0x2c]         ; ← 写：*(P+0x2c) = 用户数据
ffffffc010fa60c4: f94012e8     	ldr	x8, [x23, #0x20]
ffffffc010fa60c8: f9000d00     	str	x0, [x8, #0x18]         ; 新 kmalloc 指针 → *(P+0x18)
ffffffc010fa60cc: f94012e8     	ldr	x8, [x23, #0x20]
ffffffc010fa60d0: f9001114     	str	x20, [x8, #0x20]        ; x20 = 两个用户 u32 之积（零扩展）
```
**能力**：一次 ioctl 在攻击者选定的内核地址 P 上写 8 字节（P+0x28..0x2f，两个纯用户 u32）、写 P+0x20..0x27（用户 u32 之积，高 32 位为 0）、写 P+0x18..0x1f（一个新鲜 kmalloc 指针）。重复调用只需重新 `ASHMEM_SET_NAME` 改 `pd+0x20` 处的 8 字节。
**cmd**：任何 `cmd & 0xff == 0x12` 的 ioctl（分派只比较低字节）。上游 uapi 里 nr=0x12 是 `SNDRV_COMPRESS_START = _IO('C',0x12) = 0x4312`，但该 vendor 分支在此 case 里 `memdup_user(arg,0x84)`，语义与上游不同（见第 7 节未决项）。
**使用前置（可控，但需说明）**：`*P` 与 `*(P+0x10)` 必须可读且为 0；`*(pd+0x18)` 指向处 `+0x48` 必须可读且为 0。把这两个“假对象”放進另一个 ashmem area 的 name 区（各自 0x0b..0x10a 全可控）即可全部满足。

## 4. WINNER 2：`i2cdev_ioctl @ 0xffffffc010188280`

```
ffffffc010188280: d10103ff     	sub	sp, sp, #0x40
ffffffc01018829c: 511c0428     	sub	w8, w1, #0x701          ; 索引 = cmd-0x701
ffffffc0101882a0: aa0203f3     	mov	x19, x2                 ; x19 = arg
ffffffc0101882a4: 71007d1f     	cmp	w8, #0x1f               ; 索引 0..0x1f
ffffffc0101882b4: f9406c14     	ldr	x20, [x0, #0xd8]        ; x20 = private_data
ffffffc0101882c4: 7868792b     	ldrh	w11, [x9, x8, lsl #1]   ; u16 跳转表 @0xffffffc0120072c0
ffffffc0101882cc: d61f0140     	br	x10                       ; base 0xffffffc0101882d0, scale 4
```
cmd→块（实测表字节解码）：`0x701→0x1018831c`，`0x702→0x10188334`，`0x703/0x706→0x101882d0`，`0x704→0x10188358`，`0x708→0x101883a4`，`0x720→0x101883c4`，其余→0x10188558(-EINVAL)。

WIN 链路（`I2C_RETRIES`，cmd = 0x701）：
```
ffffffc01018831c: d35ffe68     	lsr	x8, x19, #31            ; 守卫：arg 的 bit31 必须为 0
ffffffc010188320: b50003e8     	cbnz	x8, 0xffffffc01018839c
ffffffc010188324: f9400e88     	ldr	x8, [x20, #0x18]        ; ← C2：基址 = *(private_data+0x18)
ffffffc010188328: aa1f03e2     	mov	x2, xzr
ffffffc01018832c: b9006d13     	str	w19, [x8, #0x6c]        ; ← 写：*(P+0x6c) = (u32)arg
ffffffc010188330: 1400008a     	b	0xffffffc010188558        ; return 0
```
第二条（`I2C_TIMEOUT`，cmd = 0x702）值来自 arg 的算术：
```
ffffffc01018833c: 0b130a68     	add	w8, w19, w19, lsl #2     ; arg*5
ffffffc010188340: 531f7900     	lsl	w0, w8, #1              ; arg*10
ffffffc010188344: 940909ee     	bl	0xffffffc0103caafc <__msecs_to_jiffies>
ffffffc010188348: f9400e88     	ldr	x8, [x20, #0x18]
ffffffc010188350: b9006900     	str	w0, [x8, #0x68]         ; ← 写：*(P+0x68) = jiffies(arg*10)
```
C1 证明：对 private_data 的全部访问 = `ldrh [x20]`(+0)、`strh [x20,#0x2]`(+2)、`ldr [x20,#0x18]`(+0x18)，均 ≤ 0x10a；0x701/0x702 路径上没有任何 lock/list 操作。
注意 `strh w19,[x20,#0x2]`（0x101884a0，I2C_SLAVE 路径）写的是 `private_data+0x2` → 按 C2 的“+常量=自写”规则不算 WIN。
`compat_i2cdev_ioctl@0xffffffc0101885d0` 同样 `ldr x19,[x19,#0x18]`，但它只把这个指针作为 `i2cdev_ioctl_smbus` 的第 0 参传出去，函数体内无 store → 不满足 C3。

## 5. 因 C1 被拒（到 store 路径上存在 `private_data + k`，k > 0x10a）

实测首条越界指令（偏移 / 地址 / 反汇编原文）：

| 函数 | 越界偏移 | 证据指令 |
|---|---|---|
| watchdog_ioctl | 0x428, 0x430 | `ffffffc010df3664: 9110c293 add x19, x20, #0x430` ／ `ffffffc010df3670: f9421694 ldr x20, [x20, #0x428]`（与题给参考完全一致） |
| mmc_rpmb_ioctl | 0x430 | `ffffffc010e4d2cc: f9421900 ldr x0, [x8, #0x430]` |
| mmc_rpmb_ioctl_compat | 0x430 | `ffffffc010e4d344: f9421840 ldr x0, [x2, #0x430]` |
| glink_pkt_ioctl | 0x550 (+0x558/0x598/0x5b0) | `ffffffc010108bb8: b9455288 ldr w8, [x20, #0x550]` |
| perf_ioctl | 0x218 | `ffffffc0104b627c: f9410eb6 ldr x22, [x21, #0x218]` |
| rtc_dev_ioctl | 0x3b0 (+0x4a8) | `ffffffc010d262b8: f941da77 ldr x23, [x19, #0x3b0]` |
| iio_ioctl | 0x4a0 | `ffffffc010f2a864: f9425008 ldr x8, [x0, #0x4a0]` |
| linehandle_ioctl | 0x210 | `ffffffc0108be8fc: b94212a2 ldr w2, [x21, #0x210]` |
| media_ioctl / media_compat_ioctl | 0x448 | `ffffffc010d3cfe8: f9422529 ldr x9, [x9, #0x448]`／`ffffffc010d3d084: f9422529 ldr x9, [x9, #0x448]` |
| acc_ioctl | 0x710 | `ffffffc010ce50e8: b9871100 ldrsw x0, [x8, #0x710]` |
| f_cdev_ioctl | 0x5c2/0x5e8/0x5f0/0x5f8 | `ffffffc010cec174: 794b86a8 ldrh w8, [x21, #0x5c2]`（该函数只有 `private_data+常量` 的自写，本身也违反 C2） |
| mhi_uci_ioctl | 0x154/0x158/0x4b0 | `ffffffc0100e0f2c: b9415af5 ldr w21, [x23, #0x158]` |
| rpmsg_eptdev_ioctl | 0x488 | `ffffffc0101d60d0: f9424660 ldr x0, [x19, #0x488]` |
| binder_ioctl | 0x248/0x24c | `ffffffc010f4b634: 394922a1 ldrb w1, [x21, #0x248]` |
| cec_ioctl | 0x1e0 | `ffffffc010d73b80: b941e268 ldr w8, [x19, #0x1e0]` |
| fastrpc_device_ioctl | 0x148/0x158/0x198 | `ffffffc0109e45d0: b9415a68 ldr w8, [x19, #0x158]` |
| ffs_ep0_ioctl | 0x1c0 | `ffffffc010cdca60: f940e2c0 ldr x0, [x22, #0x1c0]` |
| gpio_ioctl | 0x440/0x448/0x454/0x458 | `ffffffc0108bdd44: f9422295 ldr x21, [x20, #0x440]` |
| qseecom_ioctl | 0x19c/0x1b8/0x1c0/0x370/0x378/0x528/0x530/0x6c4/0x6e0/0x6e8 | `ffffffc010b5cf2c: b9419e68 ldr w8, [x19, #0x19c]` |
| snd_hwdep_ioctl | 0x4e4 | `ffffffc010f863fc: b944e688 ldr w8, [x20, #0x4e4]` |
| aw869xx_file_unlocked_ioctl | 0x454/0x2118/0x2120 | `ffffffc010b8ac64: b9445688 ldr w8, [x20, #0x454]` |

（共 22 个函数命中 C1；其中多数同时也只有常量/自写，属双重不合格。）

## 6. 其它拒绝，逐条附证据

### 6.1 `ccid_ctrl_ioctl @ 0xffffffc01017a868` —— C1 ✓、C2 ✓、C3 差一跳（最有价值的落选项）

```
ffffffc01017a87c: f9406c13     	ldr	x19, [x0, #0xd8]        ; private_data
ffffffc01017a880: 52886068     	mov	w8, #0x4303             ; _IOR('C',3,u32) = 0x80044303
ffffffc01017a888: 6b08003f     	cmp	w1, w8
ffffffc01017a88c: aa0203e8     	mov	x8, x2                  ; x8 = arg
ffffffc01017a894: f9408274     	ldr	x20, [x19, #0x100]      ; ← C2：P = *(private_data+0x100)（0x100 ≤ 0x102 ✓）
ffffffc01017a8a4: f9400280     	ldr	x0, [x20]               ; ← 第二跳：DST = *P
ffffffc01017a8fc: 52800095     	mov	w21, #0x4               ; 常量 4
ffffffc01017a900: 97fffee7     	bl	0xffffffc01017a49c <_copy_from_user.14250>   ; copy_from_user(*P, arg, 4)
ffffffc01017a910: b9000a95     	str	w21, [x20, #0x8]        ; 写：*(P+0x8) = 常量 4（或 2）
```
- private_data 只有 `+0x100`（窗口）与 `+0xe8`（窗口）两处访问，`0x2b0` 只出现在另一条 `copy_to_user(pd+0x2b0)` 分支上 → 对 0x40044301/0x40044302 两条路径 **C1 干净**。
- 但函数体内唯一以 C2 寄存器为基址的 store 写的是**常量 2/4**，不满足 C3 的“值派生自 arg”；而带用户数据的 `_copy_from_user` 其内核侧地址是 `*P`（在 C2 值之上再一跳），不属于 C3 列举的 `copy_to_user(ptr_from_C2,...)`/`memcpy(dst_from_C2,...)` 形状。按“字面执行、不留 maybe 桶”的要求 → **拒绝**。
- 补充事实（便于二次判断）：若把 `P` 指向自身窗口内另一个 8 字节（例如 `P = pd+0x40`，则 `*P` 也完全可控），`copy_from_user(*(pd+0x100 处值), arg, 4)` 就是 4 字节任意地址写；cmd = `0x40044301` 与 `0x40044302`（`_IOW('C',1/2,u32)`）。

### 6.2 其余「C2 成立但 C3 不成立」（store 值是常量 / 非 arg 派生）

| 函数 | C2 基址来源 | store | 拒绝理由 |
|---|---|---|---|
| spcom_device_ioctl `0x101112ac` | `ffffffc010111534: f94082c8 ldr x8,[x22,#0x100]`（x22=pd@`0x101114e0`） | `ffffffc01011153c: b829691f str wzr,[x8,x9]`；`ffffffc010111664: b82b692a str w10,[x9,x11]` | 常量 0 / 回写自身读到的值；偏移还是寄存器索引 |
| cec_ioctl `0x10d73aa8` | `ffffffc010d73ad8: f9401275 ldr x21,[x19,#0x20]` | `ffffffc010d74764: b90592a9 str w9,[x21,#0x590]`（w9=旧值−1）、`str xzr/x19/x8,[x21,#0x598/0x5a0/0x5a8]` | 值为常量或对同址的增减；另有 `ldrb [x21,#0x454]` 二级解引用；且 `ldr w8,[x19,#0x1e0]` 触发 C1 |
| snd_compr_ioctl 其它 case | 同上 `ldr x8,[x23,#0x20]` | `ffffffc010fa5cd8: b9000109 str w9,[x8]`（w9=6）、`000030/000038` 处 `str xzr` | 常量（这些 case 低字节为 0x14/0x32/0x33…） |
| sg_ioctl `0x10beeaf0` | `ffffffc010beeb28: f9400a99 ldr x25,[x20,#0x10]` | `ffffffc010bf02d0: 3901f329 strb w9,[x25,#0x7c]`，w9 来自 `ffffffc010befd0c: b9400149 ldr w9,[x10]`（get_user(arg)） | **C1/C2/C3 形状其实齐全**，但 ①只有 1 字节宽度 ②未能钉死该块的跳转表 index（137 项表 `0xffffffc0121a19fc` 无直接命中，靠 out-of-line uaccess 蹦床回跳）③路径要求 `*(*(pd+0x10))` 可读 → 判“未决”，不计 WIN（见 §7） |
| aw8697_file_unlocked_ioctl `0x1013b9a0` | `ffffffc01013b9ac: f9406c08 ldr x8,[x0,#0xd8]` → `ffffffc01013b9bc: f9403900 ldr x0,[x8,#0x70]` | 函数体内无 store，只有 `ffffffc01013b9cc: 94274031 bl 0xffffffc010b0ba90 <_dev_info>` | C3 |
| ppp_ioctl `0x10c162b4` | 表面上 `ffffffc010c164ec: f9403a73 ldr x19,[x19,#0x70]` 后有一串 `str ...,[x19,#0x90/0x94/0xa0/0xa8/0xd0]` | **假阳性**：`x19` 在整个函数只有 4 个定义（`ffffffc010c162fc: f9406eb3 ldr x19,[x21,#0xd8]`、`0x10c164ec`、`0x10c17200`、`0x10c17264`），而 `0x10c164ec` 所在块以 `ffffffc010c16534: 140002dd b 0xffffffc010c170a8` 结束、绝不落到那些 store；store 处的 x19 仍是 private_data 本身 → 全是 `private_data+常量` 自写，C2 不成立。该块真正的危害是二级取指：`ffffffc010c164f4: f9400668 ldr x8,[x19,#0x8]` → `ffffffc010c164f8: f9400515 ldr x21,[x8,#0x8]` → `ffffffc010c1650c: 54006ce1 b.ne`（与固定 cfi_jt 值比较）→ `ffffffc010c1651c: d63f02a0 blr x21`，受 CFI 目标比较限制 |

### 6.3 连 C2 都不成立（基址来源在窗口外，或只有自写）——代表性样本

- `spidev_ioctl@0x10143d04`：`ldr x19,[x22,#0x8]` → `str w23,[x19,#0x3b0]`，k=0x8 **小于 0x0b**（只有 u64 的高 5 字节可控）→ C2 拒。
- `logger_ioctl@0x101d1ae8`：`add x8,x0,#0xd8; ldr x8,[x8]; ldr x22,[x8]` → 第一跳 k=0 → C2 拒。
- `qcedev_ioctl`、`hiddev_ioctl`：store 基址来自 `ldr x?,[x_pd,#0]`/`#0x8` → C2 拒。
- `kgsl_ioctl`（k=0x1d8）、`tty_ioctl`（k=0x228）、`aw869xx`（k=0x2120）、`watchdog`（k=0x428）→ 同时 C1 违规。
- `media_request_ioctl`、`fastrpc_device_ioctl`、`ashmem_ioctl`、`f_cdev_ioctl`：store 全在 `private_data+常量`（含 `ashmem` 的 `[x19,#0x128]/[x19,#0x130]`）→ C2 明文拒绝。
- `dma_buf_ioctl`：`ldr x0,[x19,#0x70]`（窗口 ✓）→ `kfree`；`ldr x0,[x19,#0xa0]` → `dma_resv_wait_timeout_rcu`；函数体内只有 `str x20,[x19,#0x70]` 自写 → C3 拒（kfree 属释放原语，不在 C3 列举内）。

## 7. 诚实缺口 / 未能判定

1. **84/165 个函数根本不读 `private_data`**（无 `[x*,#0xd8]`，且已单独排查过 `add x?,x0,#0xd8` 变体：只有 `logger_ioctl`、`qseecom_ioctl`、`ipa3_ioctl` 三处，`ipa3`/`qseecom` 的是 adrp+0xd8 的 ratelimit 字符串、`logger` 已在 §6.3 判定）。这类函数不可能满足 C2。但其中若干把 `filp`(x0) 原样传给下层（`tty_ioctl`←`tty_compat_ioctl`、`evdev_ioctl`→`evdev_do_ioctl`、`drm_ioctl`→`drm_ioctl_kernel`、`kgsl_*`→`kgsl_ioctl_helper`、`proc_reg_*`、`v4l2/vfs_ioctl` 等）——**下层函数未在本次审计范围内**；若攻击链允许，应把那些 callee 也过一遍。
2. **C3 的“经 callee 落 store”一类一律未计入**，但它们在结构上就是「内核地址来自窗口」，值得单列决策（以下每条都是实测原文）：
   `evdev_ioctl`：`ffffffc01017c04c: f9400ef8 ldr x24,[x23,#0x18]` → `ffffffc01017c050: 91022313 add x19,x24,#0x88` → `ffffffc01017c054: aa1303e0 mov x0,x19` → `ffffffc01017c058: 944f6e1d bl 0xffffffc0115578cc <mutex_lock_interruptible>`（互斥体地址 = `*(pd+0x18)+0x88`，完全由窗口决定）；解锁在 `0xffffffc01017c09c`。
   `seccomp_notify_ioctl`：`ffffffc010429884: f9400ea0 ldr x0,[x21,#0x18]` → `ffffffc010429888: 9444c1dc bl 0xffffffc011559ff8 <down_interruptible>`（rwsem，被锁对象地址完全来自窗口）。
   `ffs_epfile_ioctl`：`ffffffc010cdd550: f9401ae8 ldr x8,[x23,#0x30]` → `ffffffc010cdd568: 9100e100 add x0,x8,#0x38` → `ffffffc010cdd56c: 9422035c bl <_raw_spin_lock_irq>`（自旋锁写在 `*(pd+0x30)+0x38`）。
   `uvc_v4l2_compat_ioctl32`：`ffffffc010dc14d0: f9405280 ldr x0,[x20,#0xa0]` → `ffffffc010dc14d8: 94000231 bl <uvc_ioctl_ctrl_map>`（该 helper 会往这个指针里写 map 指针）。
   `compat_i2cdev_ioctl`：`ffffffc010188618: f9400e73 ldr x19,[x19,#0x18]` → `ffffffc0101886d8: 94000355 bl <i2cdev_ioctl_smbus>`。
   `lineevent_ioctl`：`ffffffc0108beed0: f9400a80 ldr x0,[x20,#0x10]`（x20=pd@`0x108bee98`）→ `ffffffc0108beed4: 97fff5d6 bl <gpiod_get_value_cansleep>`。
   `dma_buf_ioctl`：`ffffffc010ba82a4: f9403a60 ldr x0,[x19,#0x70]` → `ffffffc010ba82a8: 97e67a3e bl <kfree>`（释放原语）。
   这些都是“把窗口值当内核对象用”，是否纳入 WIN 请按下发方对 C3 的正式口径决定；本轮按字面未纳入。
3. **只读方向的落选项**：`snd_rawmidi_ioctl@0x10fa3644`（pd 取值行在 `0x10fa3678`） 用 `ffffffc010fa36f4: f9400a93 ldr x19,[x20,#0x10]`（窗口）作为 `_copy_from_user` 的**源**：`ffffffc010fa3824: 910023e0 add x0,sp,#0x8` / `ffffffc010fa3828: 52800702 mov w2,#0x38` / `ffffffc010fa382c: aa1303e1 mov x1,x19` / `ffffffc010fa3840: 97c3f053 bl 0xffffffc01009f98c <_copy_from_user>` = 从攻击者选定地址读 56 字节进栈；C3 只承认“内核侧**目的**地址来自 C2”，故未计入，且这些数据是否会回到用户态未验证。
   `qcedev_ioctl`：`ffffffc010e876c8: b9403ae1 ldr w1,[x23,#0x38]`（长度取窗口值）→ `ffffffc010e876cc: 7100843f cmp w1,#0x21` + `b.hs` 上限 → `ffffffc010e876d8: b9403ae2 ldr w2,[x23,#0x38]` / `ffffffc010e876dc: 91050260 add x0,x19,#0x140` / `ffffffc010e876e0: 910062e1 add x1,x23,#0x18`（源 = `private_data+0x18`，即我们的 name 区）→ `ffffffc010e876e4: 97c81467 bl memcpy`。长度被限到 ≤0x21 且**目的不来自 C2** → 未计入。
   `ffs_epfile_ioctl@0x10cdd4dc`（本次扫描里唯一“内核数据→用户态”闭合的泄露形状，建议单独裁决）：`ffffffc010cdd560: f9401ef9 ldr x25,[x23,#0x38]`（窗口）→ `ffffffc010cdd71c: 8b090f28 add x8,x25,x9,lsl #3`（x9 = rodata 状态表项）→ `ffffffc010cdd720: f9400901 ldr x1,[x8,#0x10]` → `ffffffc010cdd728: 39400022 ldrb w2,[x1]`（长度 = 该地址低字节 ≤255）→ `ffffffc010cdd72c: 97cebc55 bl memcpy`（写向 `sp+0x10`）→ `ffffffc010cdd754: aa1403e0 mov x0,x20` / `ffffffc010cdd75c: 97cf5410 bl _copy_to_user` 回送用户。因“二级解引用 + memcpy 目的为栈”不属 C2/C3 列举形状而未计入。
   `ccid_ctrl_ioctl` 的 `copy_to_user(arg, pd+0x2b0, 4)`（`ffffffc01017a8d4: 910ac261 add x1,x19,#0x2b0` / `ffffffc01017a8d8: 52800082 mov w2,#0x4` / `ffffffc01017a8e0: 97ffff4b bl 0xffffffc01017a60c <_copy_to_user.14255>`）是超出 `struct ashmem_area`（约 0x140 字节）的**固定偏移堆读**，按 C2 的“+常量”与 C1 的 k>0x10a 双重拒。
4. **sg_ioctl 的 cmd 未钉死**：跳转表 `0xffffffc0121a19fc`（u16，base `0x10beeb8c`，index = cmd−0x2201，0..0x88）已完整解码，但 `strb w9,[x25,#0x7c]` 所在块不是任何 index 的直接目标（由 out-of-line uaccess 蹦床 `0x10befd0c → 0x10bf0284 → 0x10bf02c8` 回跳进入）。已排除 0x2287(SG_SET_KEEP_ORPHAN，其终点是 `strb w9,[x26,#0x3]` = `pd+0x13ab`，违反 C1/C2) 与 0x2289（终点 `str w9,[x11]`，目的为用户地址）。要钉死它需要一次带 CFG 的 uaccess 蹦床归约，本次未完成。
5. **snd_compr 分支语义未确认**：nr=0x12 在上游是 `SNDRV_COMPRESS_START`（无 arg），本机却在此 `memdup_user(arg,0x84)`，说明 vendor 改过；因此“结构体字段布局”的解释不能照搬上游。但本报告的全部结论都只依赖反汇编原文，不依赖命名。
6. **`+0x130` 是否真能放任意 u64 未验证**：`ashmem_ioctl` 确以 8 字节宽度写它（`ffffffc010eee890: f9009a74 str x20,[x19,#0x130]`），但上游 `ASHMEM_SET_PROT_MASK` 会先按 `ASHMEM_PROT_READ|WRITE` 过滤；若本机同样过滤，则 0x130 作为“指针槽”不可用（0x128 作为 size 可由 `ASHMEM_SET_SIZE` 设任意大值，`ffffffc010eeeae8: f9009674 str x20,[x19,#0x128]`，仍是干净的槽）。**两个 WIN 都不依赖 0x128/0x130**，只依赖 name 区（0x18 / 0x20）。
7. 可控窗口自证（与题面一致）：`ashmem_ioctl` 中 `ffffffc010eeeb4c: 91002e60 add x0,x19,#0xb`（SET_NAME 的 copy_from_user 目的）与 `ffffffc010eee8f4: 3840be68 ldrb w8,[x19,#0xb]!` 证实 name 基址 +0x0b；`0x120/0x128/0x130` 三个 8 字节字段、以及 `+0x110` 的越界访问（`ffffffc010eeec64: f9408a68 ldr x8,[x19,#0x110]`）也与题面给出的边界吻合。

## 8. 一句话总结

按 C1+C2+C3 字面执行：**165 个里 2 个 WIN —— `snd_compr_ioctl`（`*(pd+0x20)` 为基址，写 `memdup_user(arg)` 的用户数据，cmd 低字节 0x12）与 `i2cdev_ioctl`（`*(pd+0x18)` 为基址，写 `(u32)arg`，cmd = 0x701，约束 `arg < 2^31`）**。上一轮被看好的 `watchdog_ioctl`、`ppp_ioctl`、`aw869xx`、`kgsl`、`tty`、`qseecom`、`dma_buf` 等全部落空，原因见第 5/6 节的逐条指令。
