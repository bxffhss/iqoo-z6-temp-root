# KernelSU 方向（外部 .ko 载体）— 路线、判据与进度

> 写这份文档的原因：这条线跨会话、要借远程 Linux、还要趁 root 窗口做上机判定，
> 细节不落到文件上一定会忘。**每做完一步就在 §7 进度日志里加一行，带日期与一手证据文件名。**

## 0. 为什么要走这条路（收益账，别自欺）

现在的 su 层（`suw_apk/` + `cm57/sud.c`）已经能按 uid 授权 root，但它有一个**结构性代价**：
**整个 boot 是全局 permissive**。也就是说这台机器在这一发窗口里，SELinux 对所有进程失效。

KernelSU 式载体（一个能常驻内核的模块）真正给的增量只有三样，按价值排序：

1. **能把 `setenforce 1` 关回去**，同时保留"只有白名单 app 能拿 root" ⇒ 这是本路线的**唯一硬收益**。
2. 模块系统（挂载 overlay 之类）。
3. 官方 manager 的授权体验（我们自己的 APK 已经做到八分，**不构成理由**）。

**跨重启常驻**这条 KSU 的传统卖点在这里**拿不到**：模块随重启消失（BL 绿锁 + verity enforcing ⇒
刷 boot 是死门；`LIVEPATCH` 在 config 里 0 次 ⇒ 无载体）。⇒ 谈这条路时不要拿"常驻"当预期。

## 1. 三道门的事实表（一手依据：`analysis/config_dev.txt` + 真机）

| 载体 | 依据 | 判定 |
|---|---|---|
| patch 过的 boot Image | `ro.boot.flash.locked=1`、`verifiedbootstate=green`、`veritymode=enforcing`、`ro.debuggable=0`、user 版 | **死** |
| LivePatch（KSU-Next LPM） | config 里 `LIVEPATCH` 出现 **0 次** | **没有框架** |
| **外部 `.ko`（`finit_module`）** | `MODULES=y`、`MODULE_SIG` 未开、`SECURITY_LOADPIN` 未开、`MODULE_UNLOAD=y`；只有 `MODVERSIONS=y` 是墙 | **唯一活门** |

`CONFIG_KPROBS`… 准确说是 **`CONFIG_KPROBES=y` + `CONFIG_EXT4_FS=y`** —— KernelSU 官方 `kernel/Kconfig`
里 `config KSU` 是 **tristate**（"the module will be called kernelsu"），依赖就这两条 ⇒ **KSU 的依赖本机满足**。

## 2. 已经翻掉的墙：MODVERSIONS 的 CRC 可以纯离线造

- `analysis/kcrctab_dump.py` → `analysis/Module.symvers_dev`：**13,546 行**，全部符号名可解析。
  步长被两个独立计数互相卡死（`.ksymtab` 179136 = 7464×24、`.kcrctab` 29856 = 7464×4）。
- 厂商 `.ko` 的 `__versions` 条目布局实测 = **`{u64 crc; char name[56];}` = 64 字节，crc 在前**；
  `e4000.ko` 22/22、`asix.ko` 80/80、`boardinfo.ko` 17/17 逐条吻合 ⇒ 表是对的。
- ★**必须用带 `-qgki` 的那批**：`/vendor/lib/modules/*.ko`（本地副本 `cm57/ko_all/`，142 个）vermagic 是
  `5.4.281-qgki-g2a88cd145def SMP preempt mod_unload modversions aarch64`；
  子目录 `5.4-gki/*.ko`（本地 `cm57/ko/`）是**另一个构建**，`module_layout` 都对不上。
  ⇒ 判"属不属于本构建"就比 `module_layout` 那条 CRC。
- 真机三次独立 boot 复现（`cm57/round5_r1..r3_dev_mod.log`）：厂商原样 `e4000.ko` 能 `finit_module`(rc=0)
  也能 `delete_module`(rc=0) ⇒ **没有自建 LKM 白名单**；改 1 字节 CRC ⇒ `EINVAL` 且 dmesg **点名符号**
  ⇒ CRC 真强制，也真会告诉我们哪个符号不对。

## 3. 还没测的那个真正的未知数

上面三次用的是**厂商原样 .ko**。我们自己的 .ko 能不能进，取决于两件没验证过的事：

1. **不借内核构建树、手工造的 ELF 段**（`.modinfo` + `__versions`）内核认不认；
2. **kprobe 在这台带 `GKI_HIDDEN_*` 的非标准 5.4.281-qgki 上能不能挂上并被触发**（KSU 的整个 hook 层都靠它）。

⇒ 阶段 0/1 就是花最小代价把这两条钉死，**不碰 KSU 一行代码**。

## 4. 阶段划分与判据（每阶段都有"失败就说失败"的口径）

| 阶段 | 做什么 | 判据（全中才算过） | 失败含义 |
|---|---|---|---|
| **0** | 最小自研 `suwprobe.ko`：`init_module` 里 `printk` 一行就返回 | `mod ins` rc=0；`/proc/modules` 出现 `suwprobe ... Live`；`/sys/module/suwprobe/initstate=live`；`dmesg` 有我们那行；`mod rm` rc=0 且 `/sys/module/suwprobe` 消失 | `ENOEXEC(8)`=ELF/段形态问题；`EINVAL(22)`=vermagic/格式串；`ENOENT(2)`=CRC 不对（会点名符号）；`EPERM(1)`=厂商 LKM 白名单（与 09-29 三次矛盾，要重查） |
| **1** | `suwkprobe.ko`：`register_kprobe` 挂 `printk`，handler 里累加计数，`rmmod` 时打印命中数并 `unregister_kprobe` | 注册 rc=0；**计数 > 0**（正对照，证明 handler 真的被调，不是"挂了但没跑"）；卸载干净 | 注册失败=非 GKI 上 kprobe 不可用 ⇒ **KSU 路线当场判死** |
| **2** | 用 kprobe 的 `pre_handler` 从 `pt_regs->pc` 反查 `kallsyms_lookup_name` 的地址 | 拿到一个落在 kernel text 区间内的地址，且能用它再解出第二个符号（**两个独立符号互校**才算数） | 拿不到 ⇒ KSU 的符号定位要换路子（它正是靠这个技巧） |
| **3** | 真编 KSU 模块形态（SukiSU/ReSukiSU 这类**仍留非 GKI 路径**的分支；官方 v1.0 起放弃非 GKI） | 编出 `kernelsu.ko`；`insmod` rc=0；`/dev/kmsg` 里 KSU 自己那行版本 | 结构体假设不符（`struct module`/`task_struct`）⇒ 可能直接崩，**见 §6 的止损** |
| **4** | 端到端：`setenforce 1` 之后，KSU manager 里授权的 app 仍能 `su`，未授权的仍被拒 | `getenforce=Enforcing` + 白名单 app `uid=0(root)` + 另一个 app rc=126 | 到这里才算真的比现有 su 层强 |

**★ 阶段 2 的必要性（今天新发现）**：`kallsyms_lookup_name` **不在** `analysis/Module.symvers_dev` 里
（13,546 个导出符号中查不到）⇒ 这台内核**没有导出它**，模块里不能直接调用。
KSU 的非 GKI 路径恰恰依赖运行时符号定位，所以"能不能拿到 `kallsyms_lookup_name`"是阶段 3 的前置，
不能想当然。**注意口径**：它没导出 ≠ 它不存在（kallsyms 里应该有），只是不能当模块符号解析。

## 5. 构建配方（不借内核构建树 —— 记下来，下次不用重新推）

- 编译器：本机 NDK r27d 的 `aarch64-linux-android35-clang`（`suw_apk/build.sh` 里同一个变量），
  关键 flag：`-ffreestanding -nostdlib -fno-builtin -fno-stack-protector -ffixed-x18
  -mgeneral-regs-only -mcmodel=small -O2`。链接用 `ld.lld -r`（**relocatable**，内核自己 `apply_relocations`）。
- 必须手工造的段（2026-09-30 实测出来的完整清单，**少一个就 ENOEXEC/EINVAL**）：
  - `.modinfo`：`vermagic=`（逐字抄 §2 那条）、`license=GPL`（**必须**，否则 `EXPORT_SYMBOL_GPL`
    的符号如 `register_kprobe` 会被拒）、`name=`、`depends=`、`srcversion=`。
  - `__versions`：每个引用符号一条，**64 字节定长**：`{u64 crc; char name[56]}`，crc 在前；
    `module_layout` 那条**必须有**（MODVERSIONS 的准入检查）。CRC 值从 `analysis/Module.symvers_dev` 取，
    当前实测：`module_layout=0xb7b3a75c`、`printk=0xc5850110`、
    `register_kprobe=0x3ce77caf`、`unregister_kprobe=0xeb3f8466`（都是 `(kernel)` 导出、无 namespace）。
  - `.gnu.linkonce.this_module`：**必须有，而且有三个字段要预填**（内核 `parse_simple_elf` 直接把
    这段内存当 `struct module` 用，且 `load_module()` 全程不给 `mod->name` 赋值）：
    `sizeof=960`、`name@24[56]`、`init@392`、`exit@888`（后两个靠 ABS64 重定位，写成 C 结构体覆盖即可，
    见 `kmod/suwprobe.c` 的 `struct suw_this_module`）。偏移量来自厂商 .ko 实测，**不是抄上游**。
  - `.plt` / `.init.plt` / `.text.ftrace_trampoline`：arm64 的 `module_frob_arch_sections` 只认**段名**，
    各留 1 字节即可（厂商 .ko 就是 size=1），内容内核自己重写成 SHT_NOBITS 并按它算的条目数分配。
  - 全局符号 `__cfi_check`：`void __cfi_check(u64 id, void *ptr, void *diag) {}` —— 本机
    `CONFIG_CFI_CLANG=y` + `SHADOW=y` + **非 permissive**，内核 `cfi_slowpath_handler` 对模块目标用的是
    `mod->cfi_check`（来自这个符号），**NULL 就 `handle_cfi_failure` = panic**；我们自己提供 = 自己放行。
- **文件作用域的 `__asm__` 不能带 `volatile`**（clang 报错），且宏里传符号名要用 `#nm` 字符串化 ——
  这两个各浪费了一次编译。
- 离线自检 `kmod/check_ko.py` 已经把上面每一条做成了闸门（缺段/空 `mod->name`/没有 this_module 重定位/
  没有 `__cfi_check`/CRC 与参照表不符 都会挡住），`kmod/build.sh` 不过自检就不让上机。**先跑自检再碰设备。**
- namespace：`MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS` **未开** ⇒ 用到带 namespace 的符号必须写
  `MODULE_IMPORT_NS()`。我们这批候选（printk/kprobe 系）namespace 为空，暂不踩。
- 设备侧没有 `insmod` ⇒ 用 `cm57/mod.c`（→ `cm57/modbin`，`finit_module`/`delete_module` 两个 syscall）。
  它的 errno 口径已经写在文件头注释里。
- 需要"真内核构建树"时（阶段 3）：**远程 Linux = `hermes-remote1/`**（本机没有 wsl/docker/make）。
  2026-10-28 现值（第二台实例，差分清点见 `hermes-remote1/README.md` 那一节）：Debian 12、root、
  `clang 14.0.6`/`aarch64-linux-gnu-gcc 12.2`/`flex`/`bison`/`bc`/`pahole`/`setools` **都已装齐**，
  构建树在 `/root/k/`（`ksu` 脏树＋`nothing_sm7325_v_mr`＋`linux-5.4.281`）。
  用法见 `hermes-remote1/README.md`（`python cli.py exec "..."`，退出码透传，结果走文件信箱不走 PTY）。
  ★仓库里的包装件默认还指着**第一台**（`hermes-remote/`）：要用第二台就给
  `HRMT_CLI=hermes-remote1/cli.py`（`w999_runcap.sh`/`w985_run.sh`/`w682_rr.py` 三个入口都吃，
  且回执第一行现印用的是哪台机；双向自测＝`run_endpoint.sh`，已进 `w413`）。

## 6. 止损与规矩（这条线不能碰的东西）

- **不动分区、不刷 boot、不留持久化**（用户长期约束）。模块是易失的，符合"用完重启即消失"。
- 阶段 3 之前**不许**加载任何"引用了大量内核内部结构"的模块 —— 结构体假设错 = 内核崩。
  崩了的代价是**当场重启**（BL 锁着、什么也没写进分区，数据在 /data 上），但**这一发的窗口就没了**。
  ⇒ 每次上机前把判据脚本准备好，一发里按阶段 0→1→2 顺序跑完，别分两发。
- 上机轮次要用户批准（每 boot 只有一发泄漏）。**本轮（2026-09-30 03:39 打的第 12 次）窗口还开着**，
  阶段 0/1/2 应该在同一发里做完。
- 收尾：`bash cm57/round9_cleanup.sh`（第一步 `su -c "rm -rf /data/adb/su"`）→ `adb reboot` 回 enforcing。
  ★`/data/adb/su` 是唯一不随重启消失的东西（0700 root，重启后 shell 连 stat 都 EACCES ⇒ 只能趁窗口删）。

## 6b. 战略结论（2026-09-30，由导出面普查推出，别走回头路）

`analysis/Module.symvers_dev` 里查这些符号（模块**能直接调用**的集合）：

| 符号 | 导出？ | 影响 |
|---|---|---|
| `register_kprobe` / `unregister_kprobe` | **有**(GPL) | 我们的符号定位入口 |
| `kallsyms_lookup_name`、`kallsyms_lookup_size_offset` | 没有 | 只能靠 kprobe 捞（已实测可用） |
| `register_ftrace_function`、`ftrace_set_filter_ip`、`ftrace_enable_ftrace_graph_caller` | **都没有** | ⇒ 模块**不能**直接用 ftrace 挂钩 |
| `text_poke`、`set_memory_ro`、`set_memory_rw`、`set_memory_x`、`flush_icache_range` | **都没有** | ⇒ 不能直接改内核 text |
| `module_alloc`、`__vmalloc_node_range` | 没有（`vmalloc`/`__alloc_pages_nodemask`/`ksize` 有） | 可执行内存要绕 |
| `sys_call_table` | 不是导出符号（但 kallsyms 里有） | 靠 kallsyms 解析 |

**推论（这是好消息，而且把"必须有匹配构建树"这个前提拆掉了）**：
kprobe 能拿到 `kallsyms_lookup_name` 的地址 ⇒ 有了它就能在运行时解析**所有**上面这些"没导出"的符号
⇒ 再从**我们自己的模块里直接调用它们**。而 kCFI 只在"**内核间接调用我们**"的方向上设卡
（那个卡我们已经用自带 `__cfi_check` 解掉）；**我们模块是 NDK clang 18 编的、本身没有 kCFI 插桩，
所以我们发起的间接调用不受检查**。

⇒ 因此有两条独立可行的路，**不必二选一**：
  A. 手搓路线：继续 `kmod/*.c` 这套（不需要内核构建树），自己实现"解析符号 + 挂 kprobe/ftrace +
     提供 accept-all `__cfi_check`"，做一个最小 KSU 等价物（只要"enforcing 下按 app 给 root"这一件事）；
  B. 真编 KSU：需要远端那棵 5.4.281 树的 ABI 断言先过（`kmod/abi_check.c`），
     过了还要解决"它内部的 ftrace hook 在严格 kCFI 下"的问题（它的回调同样要过 CFI ⇒ 要给它补 `__cfi_check`）。
★ A 的价值在于**不依赖厂商源码/构建树**，而且每一步判据都能像今天这样逐条钉死；B 的价值是省实现量。
先让 B 的断言跑，但**不要把 A 当备胎扔掉**。

## 6c. 路线 B（真编 KSU）的构建配方 —— 前提已定位，别再从头查

- 树：远端 `/root/k/linux-5.4.281`（vanilla 5.4.281 + **设备的 `.config`**）。
  已验证：`make prepare` 通过、`MODVERSIONS/KPROBES/MODULES` 都在、
  外部模块能编出 `.ko`，且 **`Module.symvers` 换成我们离线那张 `analysis/Module.symvers_dev`
  之后，modpost 写出的 `__versions` CRC 与设备逐条一致**（`module_layout=0xb7b3a75c`、
  `printk=0xc5850110` 都被 `check_ko.py` 判 [ok]）⇒ **CRC 这一关真 kbuild 也走得通**。
- vermagic 凑法（已验证产出与设备逐字相同）：
  `./scripts/config --file .config --set-str LOCALVERSION "-qgki-g2a88cd145def" --disable LOCALVERSION_AUTO`
  然后 `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=clang CC=clang prepare`
  ⇒ `kernel.release = 5.4.281-qgki-g2a88cd145def`。
  ★`CROSS_COMPILE` 不能省：5.4 的 arm64 Makefile 用它拼 `--target=`，省了就变成拿 x86 目标编 arm64
  汇编，报一堆莫名其妙的约束错误（我今天就这么误判过一次"clang 版本不兼容"）。
  ★`CC=gcc` 也不行：设备 config 会带 `-mlittle-endian`、`-mstack-protector-guard=sysreg`、
  `-mno-global-merge` 这些 clang-only flag。
- ★★**目前唯一的拦路石：`CONFIG_CFI_CLANG` 会被 `olddefconfig` 静默丢掉**（它 `depends on CC_HAS_KCFI`，
  Debian 的 clang 14 没有 Android kCFI）。后果是树算出 `sizeof(struct module)=896` 而设备是 960，
  编出来的模块会被内核越界写坏，而且产物没有 `__cfi_check`。
  ⇒ 解法分两层，**两层都必要**（08:5x 实测）：
    (1) 编译器必须是厂商那一套 —— 已解决：`android11-release` 分支的 `clang-r383902b`，
        `--version` 与设备 `CONFIG_CC_VERSION_TEXT` 逐字一致（1.1G，稀疏克隆即可）；
    (2) **源码树必须是 ACK(android12-5.4)而不是 kernel.org 的 mainline 5.4.281** ——
        mainline 里**根本没有 `CONFIG_CFI_CLANG` 这个符号**(它是 Android 下游特性)，
        所以换了对的 clang、`olddefconfig` 里 CFI 仍然不存在、`struct module` 仍然 896。
        ⇒ 判据"CFI 在不在 .config"其实同时在校验"树对不对"，别只盯着编译器。
  （与 `CONFIG_CC_VERSION_TEXT="Android (6573524 based on r383902b) clang version 11.0.2"` 逐字对应）：
  ```bash
  git clone --depth 1 --filter=blob:none --sparse -b android11-release \
      https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 /root/clangrepo
  cd /root/clangrepo && git sparse-checkout set clang-r383902b
  # 之后: CC=/root/clangrepo/clang-r383902b/bin/clang \
  #       CROSS_COMPILE=/root/clangrepo/clang-r383902b/bin/llvm-  (ld.lld 等都在 bin/ 里)
  ```
  （探测过的 URL 形状：`.../+/refs/heads/<branch>/<clang-rXXXXXX>/bin/clang?format=TEXT` 单文件可取；
  `clang-r383902b` 只在 `android11-release` 上，`master`/`android12-release`/`android13-release`/`main` 都 404。）
- 即便换了 clang，**仍然建议把模块的 `__cfi_check` 换成我们自己的 accept-all 版本**：
  这样"clang 版本 ↔ type id 编号方案"就不再是正确性前提（clang 11 与 14 的 kCFI 编号是否一致，未证实）。
- 编完必须过 `python kmod/check_ko.py <产物.ko> analysis/Module.symvers_dev` ——
  它这次就是靠"896 太小"和"没有 `__cfi_check`"两条把不能上机的产物挡下来的。

## 7. 进度日志
- **2026-09-30 03:5x** 立项。已确认：`Module.symvers_dev` 13,546 行在手；`cm57/ko_all/` 是带 `-qgki`
  的 142 个厂商 .ko（vermagic 靶子）；`cm57/modbin` 加载器可用；hermes-remote 通道可用（root+apt+128核）。
  **新事实**：`kallsyms_lookup_name` 不在导出表里 ⇒ 阶段 2 从"可选"变成"必做"。
  窗口状态：本 boot 第 12 次复现（slide `25b7000000`），Permissive，`/product/bin/su` 是新 build
  （带 `gparent=` 审计），白名单里临时有 0/2000/10832/10667/10284（收尾会随 `/data/adb/su` 一起删）。

- **2026-09-30 04:3x ★阶段 0 通过（带正对照）**：`kmod/suwprobe.ko`（4352 字节，NDK clang 手搓，
  不借任何内核构建树）在真机 `finit_module` **rc=0**、`/proc/modules` 里 `suwprobe 16384 0 - Live (O)`、
  `initstate=live`、`delete_module` **rc=0 UNLOADED** 且 `/sys/module/suwprobe` 消失，
  并且 dmesg 里出现了我们 init 里那行中文 printk ⇒ **代码真的被内核调用了**。
  ⇒ 结论：**离线那张 CRC 表 + 手工段 = 这台 kCFI 内核可接受的自研模块**，KSU 路线的"能不能装"这一半已经绿。

  这条链上每一环都是真机撞出来的，**顺序和判据记在这里，别重新推**：

  | # | 症状 | 根因 | 修法 |
  |---|---|---|---|
  | 1 | `ENOEXEC` + `No module found in object` | 缺 `.gnu.linkonce.this_module` | 内核 `parse_simple_elf` 里 `mod = sechdrs[index.mod].sh_addr` ⇒ **struct module 就用我们这段内存** |
  | 2 | `ENOEXEC` + `module PLT section(s) missing` | 缺 `.plt`/`.init.plt`/`.text.ftrace_trampoline` | `module-plts.c: module_frob_arch_sections` 只认**段名**，内容它自己重写；照厂商样子各留 1 字节 |
  | 3 | `EINVAL` + kobject `empty name` WARNING | `mod->name` 空 | 内核**从不给 `mod->name` 赋值** ⇒ 必须预填，`offsetof(struct module, name)=24` |
  | 4 | 模块 Live 但代码一行没跑 | `mod->init == NULL` ⇒ `do_init_module` 静默跳过 | 预填 `init@392`、`exit@888`（ABS64 重定位，厂商 .ko 里正是 `init_module.cfi_jt`/`cleanup_module.cfi_jt`） |
  | 5 | （预判并躲开）内核间接调用我们的函数 | `CONFIG_CFI_CLANG=y`+`SHADOW=y`+**非 permissive** | `kernel/cfi.c: cfi_slowpath_handler` 对模块目标用的是 **`mod->cfi_check`**，而它来自模块自己的 `__cfi_check` 符号(`cfi_init`: `find_kallsyms_symbol_value(mod,"__cfi_check")`)；**我们提供 `void __cfi_check(u64,void*,void*){}` = 自己给自己放行** |

  偏移量全部是**从厂商 -qgki .ko 量出来的**（asix / boardinfo / adsp_loader_dlkm 三个一致），不是抄上游：
  `sizeof(struct module)=960`、`name@24[56]`、`init@392`、`exit@888`。
  `kmod/check_ko.py` 已经把上面 5 条做成了**离线自检**(缺段/空名/无 this_module 重定位/无 `__cfi_check`
  都会挡住并说明为什么)，`kmod/build.sh` 不过自检就不让上机。

- **2026-09-30 04:3x 导出面普查（决定阶段 1/2 的形状，零风险）**：`Module.symvers_dev` 里
  `register_kprobe=0x3ce7caf`、`unregister_kprobe=0xeb3f8466`（GPL）**有**；
  `kallsyms_lookup_name`、`kallsyms_on_each_symbol`、`set_memory_x/rw`、`text_poke*`、`module_alloc`
  **全都没有**；`on_each_cpu`/`vmalloc`/`stop_machine`/`cpumask_next` 有。
  ⇒ 模块能用的符号定位路**只有 kprobe 那一招**（挂一个函数、在 pre_handler 里读 `pt_regs->pc`）
  —— 这正是 KSU 非 GKI 分支的做法。

- **阶段 1 的设计（安全优先，2026-09-30 定）**：`struct kprobe` 的字段偏移**不能猜**。
  本机 142 个厂商 .ko 里**只有一个**用了 kprobe 系：`cm57/ko_all/vfcs-misc-core.ko`
  （`register_kprobe`+`unregister_kprobe`）⇒ 它就是同一构建下的活体 oracle，反汇编 + 读
  `.rela.init.text` 的 addend 能推出偏移。
  再加一条**不会 corrupt 任何东西的正/负对照**：拿一个故意不存在的 `symbol_name` 去
  `register_kprobe`，**只有 `symbol_name` 落在正确偏移才会返回 -ENOENT**；返回别的 errno 就说明
  布局错了 ⇒ 此时**不要**去挂真函数（那才是会 panic 的动作）。

- **2026-09-30 04:5x ★★阶段 1 与阶段 2 同一发里双双通过**（`kmod/suwkprobe.ko`，5464 字节）：
  dmesg 原文：`suwkprobe: register_kprobe(kallsyms_lookup_name) rc=0` … `已 unregister(kprobe 可用)`。
  ⇒ **自研模块可以在本机挂 kprobe、并且能把非导出符号的运行时地址捞出来** —— 这是 KSU 路线的最后一道
  "能不能"的门，现在它是绿的。

  偏移**全部实测**（照 `vfcs-misc-core.ko: vfcs_reserved_block_init` 的形状：
  `memset(sp,0,0x88)` + `stp xzr,x8,[sp,#0x28]`，x8 = `&"kallsyms_lookup_name"`）：
  `sizeof(struct kprobe)=136`、**`addr @ 40`**、**`symbol_name @ 48`**、`opcode @ 88`。
  注册成功后内核写回的字段（本 boot）：`+40 = 0xffffffe5c73fbae0`（= kallsyms_lookup_name 的运行时地址；
  本 boot slide `25b7000000` ⇒ 运行时 text 基址 `0xffffffe5c7100000`，落在区间内 ✓）、
  `+0x78 = 0xffffffe5c73fbae4`（addr+4，单步槽）、`+0x58 = 0xd104c3ff`（被保存的原指令）。
  ⇒ 以后要任何内核符号：**register_kprobe(名字) → 读 offset 40 → unregister**，不需要 kallsyms 导出。

  为什么这一发不会把机器打崩（下次设计同类探针照这个套）：布局错 ⇒ `symbol_name` 读到 0 ⇒
  `register_kprobe` 直接 `-ENOENT` 返回、什么都没注册；只有 `rc==0` 才调 unregister，
  而那时 list/hlist 是**内核自己写进我们缓冲区的**，它按同一套偏移读回去天然一致。
- **2026-09-30 08:1x ★★自我更正：先前"远端树的 ABI 断言全过"是假阳性，撤回。**
  我用两条**互相矛盾**的断言（`sizeof(struct module)!=960` 与 `!=896`）做测试，结果两条都"通过"
  ⇒ **`CC=clang` 下这套 5.4 的 `BUILD_BUG_ON` 不生效**（5.4 在 `__OPTIMIZE__` 分支走
  `__compiletime_assert` + `__attribute__((error))`，clang 不做那个可达性诊断）。
  ⇒ 以后在这棵树上做编译期断言，**必须用会硬失败的形式**：
  `typedef char chk[1 - 2*(cond)];`（负长度数组，任何编译器都会报错），
  或者干脆 `apt install dwarves` 用 `pahole -C <类型> <.o>` **直接读布局**（比断言更有信息量）。
  （另注：`pahole` 在 `abi_check.o` 里找不到 `module`/`kprobe` 类型 —— 只引用字段的 TU 不一定
  emit 这些 struct 的 DWARF，要读布局得构造一个真正的实例对象。）

  **实测到的真问题**：远端那棵树 `make olddefconfig` 之后 **`.config` 里已经没有 `CONFIG_CFI_CLANG`**
  （它 `depends on CC_HAS_KCFI`，Debian clang 14 没有 Android 的 kCFI ⇒ 被静默降级）。
  后果两条：① 树算出的 `sizeof(struct module)=896`，而设备是 **960**（厂商 .ko 的
  `.gnu.linkonce.this_module` 实测 960，且我们手搓的 960 字节模块真机加载成功 ⇒ 两个独立证据），
  拿这棵树编的模块会被内核**越界写坏 64 字节**；② 产物里没有 `__cfi_check`，上机即 panic。
  ⇒ **路线 B（真编 KSU）的前提是拿到厂商那套 Android clang 11.0.2 (r383902b)**，
  不是"装个 clang 就行"。这一步没做成之前，**路线 A（手搓，全部段和字节自己控制）是唯一可用路径**，
  而它已经在真机上跑通了阶段 0/1/2。
  ★`kmod/check_ko.py` 这次是**真的**挡住了两个上机会炸的问题（896 太小 + 没有 `__cfi_check`）
  —— 这就是它存在的意义，别为了省事把闸门调松。


- **2026-09-30 08:3x 断言换成硬失败形式后，拿到了精确结论**（`kmod/abi_check.c` 现在用
  `typedef char chk[(cond)?1:-1]`，clang 无法忽略）：在"Debian clang 14 + 设备 config"这棵树上，
  10 条里 **4 条报错**：`sizeof(struct module)`、`init@392`、`exit@888`、`CONFIG_CFI_CLANG`；
  而 **`name@24` 与 `struct kprobe` 三条(addr@40 / symbol_name@48 / size=136)全过**
  ⇒ 差异**只**出在 CFI 相关字段（CFI 被 olddefconfig 丢掉 ⇒ `struct module` 少 64 字节、
  尾部字段整体错位），kprobe 的布局与设备一致（这条对我们是好消息：阶段 1/2 的偏移不依赖 CFI）。
  ⇒ 下一步就是把厂商 clang(`android11-release` 分支的 `clang-r383902b`)拉下来重跑同一组断言，
  **预期 10/10 全过**；过不了就说明还有别的 config 差异，届时逐条对着 `pahole` 读布局。

- **2026-9-30 08:3x 路线 B 的构建树：三层前提，逐层实测**（用 `char (*a)[N] = 1;` 让 clang 把
  **实际数值**写进诊断，比反复猜断言快得多 —— 这招记下来）：

  | 尝试 | 结果 |
  |---|---|
  | mainline 5.4.281 + Debian clang14 | `CONFIG_CFI_CLANG` **不存在**（ACK 下游特性），`struct module` 896 |
  | mainline + 厂商 clang r383902b | 厂商 clang **不支持 `-fsanitize=kcfi`**（实测 `unsupported argument 'kcfi'`）；且设备的 CFI 其实是**老式 clang CFI**（`CC_FLAGS_CFI := -fsanitize=cfi -fsanitize-cfi-cross-dso`，厂商 .ko 里的 `.cfi_jt` 就是它的 jump table）⇒ 之前口头说的"kCFI"是措辞错误 |
  | ACK `android12-5.4.281_r00` + 强制 `LTO_CLANG+THINLTO+CFI_CLANG` + clang14 | CFI 配上了(`have_cfi` 过)，但 `struct module` 仍 **896**、`init@376`、`exit@824`；而设备是 **960 / 392 / 888** |

  ⇒ **结论：ACK 树不够，缺的 64 字节来自厂商(vivo/QC)对 `struct module` 自己的改动**，
  与 config、编译器、CFI 都无关。`name@24` 与 `struct kprobe` 三条(136/40/48)全对 ⇒
  漂移只发生在 `name` 之后的那段字段里。
  ⇒ 路线 B 剩下的两条路：**(B1)** 拿 vivo 的 GPL 内核源码（PD2220/SM7325 有公开义务）当构建树；
  **(B2)** 用 ACK 树编 KSU，然后**后处理产物**：把 `.gnu.linkonce.this_module` 换成我们自己
  960 字节 + `init@392/exit@888` 的那份（`suwprobe.c` 里的 `struct suw_this_module` 已经是正确形状），
  并同步改掉它的重定位。B2 的风险是 KSU 代码里若有 `THIS_MODULE->某字段` 的读操作，偏移会错。

- **2026-09-30 08:4x KSU 源码调研结论（子代理报告 + 我自己抽查要点）**：
  ① `tiann/KernelSU` main 的 `kernel/Kconfig` 确实是 tristate，`kernel/Makefile` 就是
     `make -C $(KDIR) M=$(MDIR) modules` ⇒ **官方支持外部模块构建**；CI 用 `Ylarod/ddk-min` 镜像，
     但只覆盖 5.10~6.18，**没有 5.4**。
  ② `kernel/core/init.c` **原生带 late-load 分支**（`ksu_late_loaded = current->pid != 1`、
     跳过 kprobe hooks、并且会**自动 `setenforce(true)`**）⇒ 我们要的那条"enforcing 下按 app 授权"
     是它已有能力，不用自己发明。**这是路线 B 最大的价值点。**
  ③ 它的 `kernel/infra/symbol_resolver.c` 是**链接期直接调用 `kallsyms_lookup_name()`**，
     没有 kprobe 兜底 ⇒ 本机没导出它 ⇒ **必须把 resolver 改成我们那招**（kprobe 解析地址，已实测可用）。
  ④ 它的 CI 会 `sed` 掉 modpost 的 `check_exports()`，并且 `tools/check_symbol.c` 断言产物
     `__versions` 段大小为 **0**（官方 LKM 不带 CRC）⇒ **这套做法在本机必死**
     （`MODVERSIONS=y` + `MODULE_FORCE_LOAD` 未开 ⇒ 无版本信息就是 `-ENOEXEC`）。
     我们必须反过来：**保留 CRC，用离线 `Module.symvers_dev`**（这条已实测 CRC 逐条正确）。
  ⑤ KSU 不用 ftrace：LSM 是直改 `security_hook_list` 指针 + `__static_call_update`，
     syscall 是直补表 ⇒ 它对我们的"accept-all `__cfi_check`"依赖点是**它自己被内核回调的那些函数指针**。
  ⑥ 非 GKI 口径互相矛盾（官方文档一处说 1.0+ 放弃非 GKI、另一处说 4.14+ 可手动构建）；
     KernelSU-Next 明确 LKM 只到 GKI2.0(5.10+)、4.19~5.4 要 in-tree。SukiSU-Ultra 声称 backport 到 4.14
     且有 LKM 章节，但 **5.4 模块态可行性未证实**。

- **2026-09-30 11:2x 路线 B 的构建管线：机制已打通，但被**结构体偏移**判死（除非拿到厂商源码）**
  1. 管线本身**全绿**（离线）：`kbuild(mainline 5.4.281 + 我们的 Module.symvers_dev)` →
     `obj-m += mod.o; mod-objs := a.o cfi_stub.o`(注意 `obj-m += a.o b.o` 是**两个模块**，踩过) →
     `python kmod/fix_this_module.py` 把 `this_module` 从 896 扩到 960 并**按符号名**把
     `init_module`/`cleanup_module` 的重定位搬到 392/888 → `check_ko.py` 判"可以上机"。
     产物里 `__cfi_check` 由 `kmod/cfi_stub.c` 提供(nm 确认 `T __cfi_check`)。
  2. **但是**：让编译器报出实际偏移(`char (*a)[N] = 1;` 这招)后，
     `offsetof(struct task_struct, cred)` 树给 **1736 = 0x6C8**，而设备真机实测是 **0x848**
     （见 `analysis/GHOST-CRED-SWEEP-20260928.md`，两处独立记录）⇒ 差 384 字节。
     `struct cred` 内部也对不上（树 `security=120/fsgid=36`）。
     ⇒ **厂商同样改过 `task_struct`/`cred`**（QC/vivo 加的字段 + 那些被 olddefconfig 丢掉的
     `CC_HAS_*` 相关 config 都会移动偏移）。KSU 的代码大量读写这些结构体 ⇒
     拿 ACK/mainline 树编出来的 KSU 上机**不是"不工作"，是写坏内存**。
  3. ⇒ 路线 B 的**硬前提**是"与厂商逐字一致的内核源码"。今天探过的三条路：
     `gpl.vivo.com`/`source.vivo.com` 不解析、官网 `/about-vivo/gpl` 404、搜索引擎无镜像 ⇒ **未拿到**。
     可行的下一步是向 vivo 提 GPL 源码请求(要机型 PD2220 / 内核 5.4.281-qgki)，或找第三方镜像。
  4. ⇒ **路线 A（手搓）反而是当前唯一安全的内核侧路径**：我们的模块之所以能安全被内核回调，
     恰恰因为它**不碰任何厂商结构体** —— 用的每个偏移(`struct module` 960/24/392/888、
     `struct kprobe` 136/40/48)都是**在这台设备上量出来的**，不是从树里算的。
     以后写任何内核侧代码都守这条：**只用实测偏移；要用没量过的结构体字段，先想办法在设备上量。**

- **2026-09-30 12:0x ★第 13 次窗口（slide `22f7200000`）：阶段 0/1/2/3/4a 全过，4b 把机器打崩了**
  证据：`kmod/evidence_0930_1159.log`。
  * 阶段 0 复现：`suwprobe` rc=0 + init 的 printk 出现。
  * 阶段 1+2：两个符号各解析一次，`kallsyms_lookup_name=0xffffffe3075fbae0`、
    `module_kallsyms_lookup_name=0xffffffe3075f5698`，**差 0x6448**，与离线
    `embedded-kallsyms.txt`(0x103fbae0-0x103f5698) 一致；且 `观测-链接期 = 0x22F7200000`
    = bootstrap 独立求出的本 boot slide ⇒ 三方互校通过（第二次，跨 boot 复现）。
    ★修正：源码里那句"离线应等于 0xa448"是我口算错的，真值是 **0x6448**（已改）。
  * 阶段 3：`kallsyms_lookup_name` **从模块里直接调用成功**，解析出
    `commit_creds=0x…51f154`、`prepare_kernel_cred=0x…51f67c`、`override_creds=0x…51f4bc`、
    `sys_call_table=0x…930ffd8`、`set_memory_rw=0x…4d610c`、`module_enable_ro=0x…5f4874`；
    返回 0 的有 `put_cred`(static inline)、`register_ftrace_function`、`text_poke_bp`、
    `flush_icache_range`(5.4 arm64 真名是 `__flush_icache_range`) ⇒ **"未导出符号可运行时解析"这条彻底成立**。
    自校验：用它解析它自己，结果与 kprobe 给的逐字节相同。
  * **阶段 4a ✓✓（route A 的基石）**：`suwhook.ko` 的
    `pre 命中 #1 pc=0xffffffe30778ed8c` + `post 命中 pc=0xffffffe30778ed90`
    ⇒ **手搓模块的 kprobe handler 确实被内核调用**；`post 的 pc = pre 的 pc + 4`(单步槽)；
    于是 `struct kprobe` 的 **pre@64 / post@72** 由"树算出"升级为"设备实测"。
  * **阶段 4b ✗（把设备打崩，设备自行重启回 Enforcing）**：`suwperm.ko` 在 post_handler 里
    写 `regs->regs[0] = -EPERM`。现象：4a 版(只打印)完全没事，**一改寄存器就重启**。
    候选原因（**未定，别再猜着上机**）：
      ① 我们自声明的 `struct suw_pt_regs{u64 regs[31];sp;pc;pstate;}` 布局与厂商内核不符
         ⇒ 写 `regs[0]` 实际写坏了真帧里的别的东西；
      ② 钩子挂在 `__arm64_sys_mkdirat` 上**全系统生效**，某个进程 mkdir 被 EPERM 可能触发
         framework 重启/看门狗；
      ③ post_handler 的调用约定/参数与假设不同。
    ⇒ **下一步必须先读 `/sys/fs/pstore/`**（pstore 跨重启保留，但只有 root 能读）——
       下次窗口第一件事就是 `cat /sys/fs/pstore/console-ramoops*`，把 panic 原文钉下来再决定。
    ⇒ 顺带的纪律：**改寄存器的实验要挑"只有我们会触发、且失败无害"的目标函数**，
       不要挂 `mkdirat` 这种全系统都在用的。
    ★**残留**：因为是崩溃重启，`cm57/round9_cleanup.sh` 没跑 ⇒ `/data/adb/su`(0700 root)
      又留在 /data 上了（shell 连 stat 都 EACCES，删不动）。`/data/local/tmp` 本轮文件已手工清空。
      ⇒ 下次激活时 `su_layer_install.sh` 开头的 `--policy reset` 会把内容抹掉，
      但**目录本身**仍要等下一次有 root 窗口时 `rm -rf /data/adb/su` 才清得掉。

- **2026-09-30 12:1x vivo GPL 源码调研（子代理 + 我本人抽查）**：
  * 门户真实可用：`https://opensource.vivo.com/`（HTTP 200）。但"无需登录即可枚举"这句
    **我复现不了**：`POST /api/project/getProjectPage` 返回 `{"code":10003,"msg":"系统错误"}`
    ⇒ 需要先取 token（站里只有 `/api/auth/token` + 图形验证码）。**别把它当"可直接爬"**。
  * **已用一手证据核实**：GitHub 镜像 `vivo-source-mirror/T1_IQOO_Z6_5G`（api.github 200）
    的 `Makefile` = `VERSION=5 PATCHLEVEL=4 SUBLEVEL=86` ⇒ **vivo 为该机型家族公开的源码是 5.4.86**，
    不是我们的 `5.4.281-qgki-g2a88cd145def`。门户里也没有 PD2220/V2220 条目。
    唯一公开联系方式：`mobileOSS@vivo.com`（响应周期未证实）。
  * ★**更值钱的替代路（未测）**：同 SoC 的第三方 **qgki** 树
    `github.com/NothingOSS/android_kernel_msm-5.4_nothing_sm7325` 有 5.4.242 / 5.4.289 分支
    （另有 Mesa-Labs / Atom-X 的 sm7325 树）。若厂商那 64 字节差异来自 **QC qgki 补丁 + config**
    而不是 vivo 私有改动，那么这类树配上我们的设备 config 就可能把
    `struct module`(960/392/888) 与 `task_struct->cred`(0x848) **逐字节复现**。
    判据现成：`kmod/abi_check.c` 的硬断言 + `kmod/abi_dump2.c` 问数法，全程不碰设备。

- **2026-09-30 12:3x 路线 B 的"公开树"这条路判死（四棵树全部对不上）**
  用同一组硬断言 + 问数法测过：

  | 树 | 编译器 | `struct module` | `offsetof(task_struct,cred)` |
  |---|---|---|---|
  | **设备真机** | (厂商 clang11+LTO+CFI) | **960** / name@24 / init@392 / exit@888 | **0x848 = 2120** |
  | mainline 5.4.281 | Debian clang14 | 896（init 在 336） | 0x6C8 = 1736 |
  | ACK android12-5.4.281_r00 | clang14 + 强制 LTO/CFI(`have_cfi` 这次过了) | 896 | 未测(同上量级) |
  | Nothing `sm7325/v/mr` = 5.4.289 | clang11(r383902b) | 896 | **0x808 = 2056** |
  | Nothing `sm7325/u/mr` = 5.4.242 | clang11(r383902b) | 896 | **0x808 = 2056** |

  两点观察：① 同 SoC 的第三方 qgki 树把 `cred` 从 0x6C8 拉到 **0x808**，离设备的 0x848 只差 **64 字节**
  —— 说明"平台差异"能靠 QC 树补上大部分，**剩下的 64 字节是 vivo 自己的 config/补丁**；
  ② 这几棵树的 `.config` 里 `CONFIG_CFI_CLANG`/`CONFIG_LTO_CLANG` 都留不住（`olddefconfig` 按
  `CC_HAS_*` 探测重新剥掉），而 LTO/CFI 恰好就是给 `struct module`/`task_struct` 加字段的那类开关
  ⇒ **不排除"只差一套能跑 LTO+CFI 的 clang"**，但继续试编译器版本已是低收益高耗时的方向。
  ⇒ **决定：路线 B 暂停**，等 vivo 源码（`mobileOSS@vivo.com`）或有新证据再说；
  资源投到路线 A（**只用实测偏移**，上面表格就是实测偏移的一部分）。

- **2026-09-30 13:2x ★路线 B 的"等 vivo 源码"这个口径作废**（本轮全程离线，没碰设备、没花额度）。
  详见 **`kmod/ROUTE-B-OFFSET-INVERSION.md`**，一句话：需要的是**偏移**不是源码，而偏移能量出来 ——
  ① `pahole`(设备同 config 的树 + 文件作用域实例逼出 DWARF) + ② `kmod/task_anchors_from_rela.py`
  (init_task 一次给出 **48 条**实测锚点) + ③ `kmod/off_diff.py`(单调 δ 对齐)。
  结果：`task_struct` 的 δ(设备−QC树) 是个**两级阶梯** —— thread_info 区 **+56**、
  `sched_task_group` 起整条尾部 **+64**，**29/29 锚点落在阶梯上**(`dl.deadline@0x468` 也对上：
  QC 树 `sched_dl_entity dl@992` + `deadline@72` = 1064，+64 = 0x468 ✓) ⇒ 只剩中段 **+8**
  未夹细(范围 `normal_prio(树132) .. sched_task_group(树984)`)。
  `struct module`：`name@24` 一致、`init` **+24**、`exit` 再 **+40** ⇒ 但这几个字段是**内核侧**在读，
  KSU 只关心 name/init/exit 三个位置 ⇒ 这条路本来就安全(沿用 `fix_this_module.py`)。
  ★顺带纠正一条被用了两天的标签错误：**`real_parent` 声明在 `parent` 之前** ⇒
  `0x6a0=real_parent, 0x6a8=parent, 0x6b0=children, 0x6c0=sibling, 0x6d0=group_leader`，
  旧表的 `tasks@0x6b0` 是错的(树的 `tasks` 在 984 之前的头部区)。偏移没错所以提权链照用，
  但"抢 `init_task.tasks.prev` 拿最新 task"这个说法**作废**，别再拿它当依据。
  ★成因也已点名：设备 config 里有 **179 个该树没有对应 Kconfig 符号的开关**(全厂商私有：
  `RSC_*`/`SLA_STAIC_COLLECT`/`EZRAM*`/`VFCS_*`/`VIVO_*`/`BLOCK_NON_GKI`/`BLK_FATE_QOS`…)
  ⇒ 公开树永远对不上，**这是机理不是意外**。而公开那份 5.4.86 镜像只有 **22/179** 有实现
  ⇒ 帮不上；`sched.h` diff 只加在**尾巴**(call_jiffies/fate_lock，都在 cred 之后，不动偏移)，
  `module.h`/`cred.h`/`asm/thread_info.h` diff = 0 行。
  ⇒ 下一步 = **G4**：扫 `mrs SP_EL0` 后的 `ldr/str [x?,#imm]` 直方图量 thread_info(纯离线)；
  再往后才是"窗口里 dump init_task 原始字节"这条实测兜底。

- **2026-09-30 13:5x G4 完成（`kmod/ti_scan.py` → `kmod/layout/ti_scan2.txt`）**：δ=+56 不是"陌生字段"，
  而是**厂商把 `thread_info` 改成 0x60 字节、并把 `stack_canary` 搬进 ti(+0x50)** —— 证据是
  `[x<sp_el0>,#0x50]` 在全 text 出现 **5194 次**（= 每个函数序言的 per-task canary），而 QC 树的
  `stack_canary` 在 `task_struct+1624`。尾段又拿到**第二种独立证据**（getppid→0x6a0=真 real_parent、
  setpgid→0x6d0=group_leader、find_vpid→0x6f8、kpti→0x5e8、umask→0x870、close→0x878、
  newuname/setns→0x880、cred→0x848 共 272 次）⇒ rela 表与代码语义互证。
  **只剩中段 +8**（`normal_prio(树 132) .. sched_task_group(树 984)`）没夹细。
  两条工具账（都踩过）：`mrs xN, SP_EL0` 的原词 = **`0xd5384100|Rt`**（我按 `0xd5384200` 扫，21MB 只命中 1 次
  ⇒ "命中少得离谱"本身就是判据）；capstone 的 `disasm()` **遇到解不出的字节就停**，且"mrs 后第一次访存"必须加
  **基址寄存器未被改写**(`regs_write`) 的规则，否则把别人的 `[xN,#imm]` 记成 current 的账。

## 8. 待办（下次接手从这里开始）

**下次开机只要两条命令**（阶段 0/1/2/3 一发跑完 + 自动离线核对）：
```bash
bash suw_apk/bootstrap.sh --punch        # 需要 I_KNOW=1；铺 payload + 求 slide + 打链 + 自动装层
I_KNOW=1 bash kmod/dev_round.sh          # 装 suwprobe/suwkprobe/suwksyms 三个模块，抓 dmesg，
                                         # 再用 kmod/verify_addr.py 拿本 boot slide 与
                                         # analysis/embedded-kallsyms.txt 逐符号核对
bash cm57/round9_cleanup.sh              # 收尾：删 /data/adb/su + 清 /data/local/tmp + reboot
```
（`kmod/*.ko` 全部由 `bash kmod/build.sh <名字>` 产出，且**过不了 `check_ko.py` 就不让上机**。）

0. **阶段 3.5 的离线那半已经做完并通过（2026-09-30 05:0x，不花窗口）**：
   模块解析到的 `kallsyms_lookup_name = 0xffffffe5c73fbae0`，
   `analysis/embedded-kallsyms.txt` 里 `T kallsyms_lookup_name = 0xffffffc0103fbae0`，
   两者之差 = **0x25b7000000 = 本 boot 的 slide** ⇒ 三方互咬（perf 求的 slide / 离线 kallsyms / 模块内 kprobe）。
   还差的"第二个符号"版本：下次窗口里顺手多解析一个（比如 `module_kallsyms_lookup_name`
   链接期 `0xffffffc0103f5698`），同一发里做完，别单花一发。

0. **路线 B 的前置：拿到厂商内核源码**（`task_struct->cred` 树 0x6C8 vs 设备 0x848 已经把它判死，
   见上面 11:2x 那条）。三条已探过的路都不通 ⇒ 剩下的是向 vivo 提 GPL 请求(机型 PD2220 /
   `5.4.281-qgki-g2a88cd145def`)。**在拿到之前不要投入 KSU 移植**。
0a. **阶段 4 的判据已经写好并过离线闸门**（`bash kmod/build.sh suwhook` / `suwperm`）：
    `suwhook.ko` 的 handler **只打印**，用来确认 `struct kprobe` 的 `pre@64/post@72`
    （依据：136/40/48 三个值"设备实测"与"树算出"一致 ⇒ 该结构体厂商没动；厂商 .ko 显式清零
    `[sp,#0x40]` 是独立佐证）；只有 4a 确认了，才允许 `suwperm.ko` 去写 `regs[0]`
    （它把 `mkdir` 改成 `-EPERM`，并带**装钩子前/中/后**三段成对控制）。
    跑法：`bash kmod/dev_round.sh`（阶段 4 调设备侧 `kmod/dev_hooks_test.sh`，避免嵌套引号）。
    ★激活后 shell(uid 2000) 不在白名单 ⇒ 先在超级用户页把 `(uid 2000)` 那一格打开再跑
    （`dev_round.sh` 会明确报这个情况，不会静默失败）。
0b. **路线 A 的下一步（不依赖厂商源码）**：把"enforcing 下按 app 给 root"要用的每个偏移
   **先在设备上量出来**（我们已有 `kmod/suwksyms.c` 能解析任意符号地址 + 手搓模块能跑代码）。
   最小闭环需要的量测清单：`security_hook_list` 的表地址与元素布局、`selinux_state.enforcing`
   的偏移、`cred` 里 uid 系列(已有 0x20/0x24 的旧记录，**要重测**)、`task_struct` 的 `cred` 槽(0x848 已有)。
1. 阶段 3：真编 KSU 模块形态（SukiSU/ReSukiSU 这类仍留非 GKI 路径的分支）。
   构建环境 = hermes-remote（`python cli.py exec`，root+apt；缺 `gcc-aarch64-linux-gnu/flex/bison`）。
   ★我们自带的 `__cfi_check`（accept-all）是这条路的通用逃生口，**比对齐 clang 版本的 type id 靠谱得多**
   —— 真编 KSU 时也要把它换/补上，否则它自己的 kprobe/ftrace 回调一样过不了 CFI。
   ★另外 KSU 依赖的符号定位问题已经解决（见上面阶段 2），它内部那套 `kallsyms_lookup_name`
   查找技巧我们可以原样换成"register_kprobe + 读 offset 40"。
2. 阶段 3.5（新增，必须先做）：拿两个**不同**的符号各注册一次、互校地址是否与
   `analysis/embedded-kallsyms.txt` 的链接期地址 + 本 boot slide 对得上 ——
   现在只验了"能拿到一个看着像 text 的值"，还没做**跨符号一致性**校验。
3. 阶段 4：`setenforce 1` 之后还能按 app 授权 —— 这才是这条线相对现有 su 层的唯一硬收益。
4. 收尾纪律不变：`bash cm57/round9_cleanup.sh` → reboot。
   本轮（第 12 次，slide `25b7000000`）阶段 0/1/2 判据已齐 ⇒ **已收尾**。
