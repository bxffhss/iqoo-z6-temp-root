# B-SCOPE —— 交付口径决议：B 线走「场景开关」，社区路线与换内核两条都封存

> 决议时间：2026-11-12 20:5x。适用设备：iQOO Z6 / PD2220 / SM7325 / `5.4.281-qgki` / A14 user。
> 证据与来龙去脉见 `kmod/w103_evidence/B8_RESULT.md`、`kmod/b8_plan.md`、账本 ROUTE-B。

## 一、决议

| 选项 | 内容 | 决议 |
|---|---|---|
| **A** | `SU_BIND=1` + `ksu_two_profiles` + 出生前就位时序 | **采用**（作为**场景开关**，**不改交付默认**） |
| **B** | 社区路线：`ksu_hook_mask` 的 execve 改道（`0x02` / `0x1a`） | **封存**（实测必死，见 §三） |
| **C** | 换一个内核里原生带 KernelSU 的镜像 | **不可行**（BL 锁死，见 §四） |

一句话：**默认形状仍是 §6.566 的「零全局 su」；要给标准 app 用 root 时，显式 `SU_BIND=1` 开 A 形状，用完即关。**

## 二、A 形状的三条硬约束（不可破）

1. **su 只绑 `/product/bin`**，不往 `/system/bin`、`/system/xbin`、`/sbin` 扩——扩了才是真的"常见 su 路径全脏"。
2. **收窗必清并复证**：`I_KNOW=1 bash kmod/w161_teardown.sh` → 复核 `mod=0 / Enforcing / 无 /product/bin/su`。
3. **窗口不留过夜**；收窗后**必须删** `/data/local/tmp/ksu_two_profiles`（它是形状开关，留着会让下一发静默换名单）。

## 三、为什么封存 B（社区路线）

`ksu_hook_mask` 位定义（源码注释）：`bit0=setresuid / bit1=execve / bit2=execveat / bit3=newfstatat / bit4=faccessat`（位 3/4＝可见性钩子）。

- `0x02` = 只挂 execve 改道 = 经典 sucompat；
- `0x1a` = `0b11010` = execve 改道 + newfstatat + faccessat 可见性。

这两个正是"盘上不给 su 文件、但 app 以为有 su"的社区做法，**两种组合都试过**：只要以 ≳门槛速率执行到 `ksu_is_allow_uid_for_current()`，约 19.5 秒固定引信硬复位。死因已用三条独立证据闭环（机制二分／反汇编无凶手行／动态 trace 证 psi 单调↑＝纯聚合压力）。**不存在第三种同功能开关。**

> 顺带：旧交付包 `z6root_rc78_bak.zip` 里 `ksu_args.txt` 就是 `0x1a` —— 那个包不能直接跑。

### 三之二、11-12 22:02 的复验（rc81_order）：最后一条廉价优化也被否

账本上所有实验都在"**进入 decline 段之后**"做减法（cut / noslow / rate / nouid0），没人动过"**进 decline 段之前**的判定顺序"。22:02 补了这一格：

- 改法（`kmod/build_rc81_order.py`，纯插入 17 行、diff 删除 0）：在 `filename_user` 判空之后、`ksu_is_allow_uid_for_current()` 之前，先 `strncpy_from_user` 读 15 字节 + `memcmp(path, su_path)`；不是 `su` 就直接回家。**决策等价**（非 su 的 execve 两条顺序都落 orig），把"允许判定"从"每次 execve"降到"每次 exec su"。
- 结果：`kernelsu_rc81_order.ko`（`47e77a63`）`insmod rc=0 up=670.16`；采样器看到 `mod=1` 只在 up 677 / 683 / 689 三个点，**up≈690–700 就 PS_HOLD 硬复位**（`bootreason=[USB_CHARGER/PS_HOLD]`）。**寿命仍是 ~20–30 秒**，与原来 19.3–19.5 s 同量级。
- **这条负结果的真正价值**：它把死因从"做了哪件重活"收紧到"**只要有 per-execve 工作、且按全速率跑，就撑不住**"。三点曲线自洽：`cut=1`（什么都不做）→ ≥193.5 s；`rate=200`（0.2 次/s）→ ≥1384 s；本发（**每次 execve 都做，只是把重活换成 15 字节拷贝**）→ ~20 s。
- ⇒ 社区路线（`0x02`/`0x1a`）在本机**封存不变**；任何还想救它的方案，必须做到"**绝大多数 execve 完全不碰**"（例如靠 ftrace/kprobe 过滤而不是 syscall 表钩子），那已不是"改个顺序"的量级。

## 四、为什么 C 不可行（换内核）

设备侧只读读数：`ro.boot.verifiedbootstate=green`、`ro.boot.flash.locked=1`、`ro.boot.vbmeta.device_state=locked`、`ro.boot.veritymode=enforcing`、`user/debuggable=0`。

厂商侧：vivo/iQOO **不提供 BL 解锁**（iQOO 官方客服 2025-09-12 明确 "BL cannot be unlocked"；Bootloader Unlock Wall of Shame 把 Vivo/iQOO 列为"不可解锁"）。

即使解锁，还差三样：①PD2220 本机内核源码（现有 `nothing_sm7325_v_mr` 是别的机型）②5.4-qgki 上做 KernelSU backport（上游只支持 GKI 5.10+）③关 AVB/刷 vbmeta。而且最关键的假设——"原生内建的 sucompat 不会复现那个聚合压力崩"——**从未被验证**。⇒ 付出全部代价后仍可能崩，故不走。

**若将来需要"日常 root"**：换一台可解锁机型（Pixel / 一加 / 部分小米）做这件事，一天能出结论；不要在 PD2220 上耗。

## 五、A 形状的一页 runbook

```bash
# 1) 铺开关（uid 现取，别手抄）
adb shell sh /sdcard/z6root/b8_setup.sh          # 或 kmod/b8_setup.sh；看 /data/local/tmp/b8_setup.out 的 DONE

# 2) 开窗
I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko bash kmod/go.sh

# 3) 起常驻补装（root 腿）＋ 重起官方 Manager（fd 与 su 都要在它出生前到位）
adb shell am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/b8_keep.sh"
adb shell am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/b8_mgr.sh"

# 4) 三条硬读数
#    b8_verify.out：NEW_GET_ALLOW_LIST count=4 total=4；10342/10104/10349/10475/10261 全 granted=1
#    b8_su.out    ：每个 uid 后面是 uid=0(root)
#    UI           ：工作中 [越狱模式] ＋ 四页签 ＋ 超级用户角标 4，无「获取 Root 失败」

# 5) 收窗
I_KNOW=1 bash kmod/w161_teardown.sh
adb shell rm -f /data/local/tmp/ksu_two_profiles
```

## 六、别踩的坑（都已经踩过）

- `ksuctl88 granted <uid>` 从 adb shell 发恒 `EPERM/0`（perm=manager_or_root）⇒ **不是名单读数**。
- `ls /proc/<别的 uid>/fd` 恒空（DAC）⇒ **不是 fd 读数**；判 fd 只看 stage log 的 `RACE 抢装` / dmesg 的 `KSUFDINST`。
- `asuid` 必须**自己是 root** 才 setuid 得动；从 shell 起只会得到 uid=2000 的拒绝。
- **别开 FDKA**（`/data/local/tmp/ksu_fd_keepalive`）：往 zygote/随机瞬时子进程种 fd，会拖垮通道甚至触发 PMIC 硬复位。
- 重起官方 App 后**不要**再 force-stop 它：fd 只属于那一个进程，杀了就退回「不支持」。
