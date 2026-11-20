# -*- coding: utf-8 -*-
# 向今日工作日志追加 §6.583 小结（append-only）
import io, os

P = r'G:\项目\Windows管理\usb\临时root\.workbuddy\memory\2026-11-09.md'
assert os.path.exists(P), P
body = u'''
## 21:1x–21:5x rc78／0x1a 上机一发（§6.583）——判据全空，但拿到一条硬否证

- 用户"现在开枪"：teardown(TD_RC=0) → push(rc78 `16b6c7c2`／args `7f2a8606`(0x1a)／ksud `f7a441d2`) → `go.sh KO=kmod/kernelsu_rc78.ko`。枪数 10，`load` 仍 7，`selinux/load` 零写入。
- 通的部分：`insmod rc=0 up=928.70`；`/dev/ksud` 0666(10,78)（**chmod 顺序那条交付 bug 这一发真的好了**，日志写"权限补正(insmod 后)"）；`P1` 补丁 ×5 全 rc=0；逃逸腿 `X0…XC` 完整；**`passfd` rc=0 → 子进程 uid=0，活到 t+6s**。
- 不通的部分：`go.sh` 第 4/6 步各 60s 无 `DONE`（`@sushd` 通道 21:38:20 后不再应答）⇒ 三个 su 判据一条都没测到。
- **关键否证**：采样器 199 样本 `up` 376→1016 单调无回落、`mod=1`，但 `KSUBEAT BN dispatcher`=**0**。落盘腿是 `dd if=/proc/kmsg` 全量不过滤，同窗口 `P1`/`X` 行都在，且 ko 里该串 grep=1 ⇒ **改道从未发生**，"bit3/bit4 热路径把机器拖死"这条假设被抽掉地基。
- **死亡**：`PS_HOLD` 硬复位；新 boot 起点设备钟 21:39:40（date 21:51:48 − up 728.02）⇒ 距 insmod ≈88–95 秒。★不是 0.1 秒、也不是 37 秒。死因仍未定（pstore 空、dmesg 快照只到 up=935.8、事故后无第二次复位）。
- **根因链**：`ksu_register_syscall_hook()` 注释"不改 sys_call_table，只靠 sys_enter 跟踪点"＋`dev_syms.c:255` 找不到 `sys_enter` 就 -ENOENT＋本机 `CONFIG_FTRACE_SYSCALLS is not set`、tracefs 无 `events/raw_syscall/sys_enter` ⇒ **分发机制与这台内核不匹配**。
- **修掉的**：`kmod/ksu_args.txt` 被 `go.sh` 第 8 步自愈回滚成 0x2（`67199f48`），与登记/出货包 `7f2a8606` 不一致 ⇒ 从 `z6root.zip` 内 `z6root/ksu_args.txt` 取字节写回，`.bak_delivery` 同步，两份现均 `7f2a8606`／107 B。
- **待修（下一轮，零枪）**：①`KSUBEAT BN` 裸 `pr_info` → 限流/删（否则改道一生效就 console 洪印）；②分发改回"直接改 sys_call_table 三条目＋保存原指针"，handler 里 `ksu_syscall_table[orig_nr]` 必须改成调保存的原指针（否则改表即自递归）；③改完跑 `w413` 整闸，再谈第 11 发。
'''
with io.open(P, 'a', encoding='utf-8') as f:
    f.write(body)
print('DAILY_APPEND_OK bytes=%d' % len(body.encode('utf-8')))
