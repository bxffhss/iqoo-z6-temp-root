# rc76 候选 vs rc74c 出货 ko — 离线二进制差异清单（0 枪、纯读文件）

- 生成：2026-11-08 23:3x，本机 Python 3.13 解析 ELF64-LE section header / `.modinfo` / `.symtab`，**不执行任何 ko、不碰设备、不连远端**。
- 用途：C 档立项方案 `kmod/PLAN-C-rc76-ship-20261108.md` §4.3「形状契约变更非改一行」的一手依据；也是 C1「把候选登记成可复现资产」的清单。
- 权威件：出货 `kmod/kernelsu_rc74c.ko`、候选 `kmod/w103_evidence/kernelsu_rc76_candidate.ko`。**本清单不新增/不改动任何 ko**。

## 1. 尺寸与标识

| 项 | rc74c（出货） | rc76（候选） | 差 |
|---|---|---|---|
| 字节 | 5,113,968 | 5,334,608 | **+220,640** |
| md5 | `324eda4dcb5d41ecb6763a5192ea9c31` | `6b59fc859290a826921db6a014478a15` | 不同 |
| ELF section 数 | 55 | 55 | 0（section 名集合**逐字相同**） |

⇒ 同样的 55 个 section、没有新增段名；多出来的 220,640 B 落在既有段内（代码/数据/符号串），不是"外挂一个新模块"。

## 2. ★未定义符号（内核依赖）— 这条最影响"能否升出货默认"

| 项 | rc74c | rc76 |
|---|---|---|
| 未定义符号数 | 158 | **167** |

rc76 **新增 9 个**内核未定义符号：
`kstrtoull`、`param_get_uint`、`param_ops_long`、`param_ops_ulong`、`proc_remove`、`simple_read_from_buffer`、`vfree`、`vmalloc`、`vsnprintf`

⇒ 语义：装载面引入了 proc 文件读写（`proc_remove`/`simple_read_from_buffer`）、动态内存（`vmalloc`/`vfree`）、参数解析（`kstrtoull`/`param_*`）与格式化（`vsnprintf`）。
⇒ **对照 §6.430**：rc74c 当年升默认的一条硬判据是"未定义符号 158 条＝rc73 的 158 条 ⇒ **零新增内核依赖**"。rc76 **不满足这条**——它有 9 个新依赖。这 9 个都是通用内核导出符号（§6.569 已在真机 `/proc/kallsyms` 见过 `security_load_policy` 等在场、`insmod rc=0` 判正），所以**不是阻塞**，但"drop-in 零新增依赖"这个说法不能给 rc76 用，升默认时要重新走一遍依赖核对。

## 3. insmod 参数（`.modinfo` 的 `parm=` 行）

| 项 | rc74c | rc76 |
|---|---|---|
| `parm=` 条数 | 17 | **19** |
| modinfo 总行数 | 58 | 91 |

rc76 **新增 2 个**：`ld_cap`、`ld_key`。
共同 17 个：`killguard`、`ksu_capclamp`、`ksu_domain_fallback`、`ksu_ksud_path`、`ksu_mgr_birth_cap`、`ksu_mgr_birth_fd`、`ksu_mgr_birth_rate`、`ksu_no_cred_override`、`ksu_no_disable_seccomp`、`ksu_no_escape`、`ksu_no_mark_threads`、`ksu_no_sulog`、`ksu_stat_off`、`ksu_trace_print`、`scanall`、`scanmod`、`scannop`。

★**订正**：`sp_arm` **不在 `.modinfo` 的 `parm=` 里**（两个 ko 都没有）——它不是标准 module_param。§6.569/§6.574 用的 `ARGS_FILE=kmod/ksu_args_rc76_load.txt` 里写了 `sp_arm=1 ld_key=0x504F4C44 ld_cap=16777216`；其中只有 `ld_key`/`ld_cap` 是这里的注册参数。⇒ 立项方案 §4.3 那句"装载面激活需三个 insmod 参数"应读作"**两个注册参数 + 一个由 ko 自行解析的 `sp_arm` 开关**"；改注册 args 时这三者要一起对表，别只数 `.modinfo`。

## 4. 可打印串里的装载面符号

| 项 | rc74c | rc76 |
|---|---|---|
| `ld_*` 去重数 | 4 | **38** |
| `ksu_*` 去重数 | 419 | 423 |

rc76 新增的 `ld_*`（34 个）：
`ld_arm_live`、`ld_arm_want`、`ld_armed`、`ld_buf`、`ld_cap`、`ld_ctl_fops`、`ld_ctl_pde`、`ld_ctl_write`、`ld_fault`、`ld_go`、`ld_h`、`ld_have`、`ld_img_fops`、`ld_img_len`、`ld_img_pde`、`ld_img_read`、`ld_img_sum`、`ld_img_write`、`ld_key`、`ld_kp_addr`、`ld_live`、`ld_load_rc`、`ld_post_len`、`ld_post_sum`、`ld_pre_len`、`ld_pre_sum`、`ld_proc`、`ld_seq`、`ld_setup`、`ld_state`、`ld_sym_addr`、`ld_sym_rc`、`ld_why`、`ld_writes`

⇒ 与 §6.567 记的"候选 36 个、出货 2 个"是同一批符号（计数口径略差：那次按 `ld_[A-Za-z0-9_]+` 全串扫、这次按词边界去重），**结论一致**：候选带了完整的 `ld_img_*`/`ld_sym_*`/`ld_load_rc`/`ld_armed`/`ld_go` 装载子系统，出货件没有。

## 5. 对 C 档立项的净结论

1. rc76 **不是** rc74c 的零差异替换：+220,640 B、+9 个内核未定义符号、+2 个注册参数、+34 个 `ld_*` 符号。
2. 装载面**默认不激活**（`sp_arm` 不在 `.modinfo`、`ld_key`/`ld_cap` 有注册参数但实验里靠 `ARGS_FILE` 显式给 `sp_arm=1`）；要变交付默认必须改注册 args `67199f48…`＝`DELIVERY §0` 三条凭据之一。
3. 已有真机判正只覆盖**实验形状**（`KO=`+`ARGS_FILE` 隔离，§6.567/568/569/574），**不覆盖**"换出货 ko 后默认形状的一键包"⇒ C2/C5 那两发不能省。
4. 升出货默认前须补一条离线核对：这 9 个新符号在目标内核 `5.4.281-qgki` 的 `/proc/kallsyms` 里都在（§6.569 已证三符号解析路径 `syms_ok`，但没逐个点这 9 个名字）。

## 6. 复现方式（0 枪、可重跑）

纯 Python 标准库即可：读 ELF64-LE 头 `e_shoff@0x28`/`e_shentsize,e_shnum,e_shstrndx@0x3A`，遍历 64 B section header，取 `.shstrtab`/`.modinfo`/`.symtab`（`sh_entsize=24`，`st_shndx==0` 即未定义），再用 `re.findall(rb'[ -~]{4,}')` 扫可打印串统计 `ld_`/`ksu_`。本清单是**一次性只读分析**，没有落生成器脚本（避免给 `w413` 新增已登记件）。

## 7. 自身仪器纠错留痕（按项目纪律）

第一版把 `.modinfo` 参数用 `r'(?:^|\0)([A-Za-z0-9_]+)='` 抓 ⇒ 只抓到 `key=value` 形态，**漏掉 `parm=name:desc` 形态**，于是打出"rc76 新增参数＝无"的假读数。改用按 `parm=` 前缀解析后得到真值 `17→19、新增 ld_cap/ld_key`。⇒ 与 §6.437 那两处"仪器嘴"同族：**按形态解析的件，形态要先从真件现取**。
