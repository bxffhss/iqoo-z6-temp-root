# 阶段 4 开火清单 — 2026-11-15 01:5x（用户授权「收窗重开打阶段 4」）

> 目标：LSPosed Manager「已激活 / 2.2.0 (7854) / API 102」+ `serial: []` + `inject_state:1`。
> 依据：`LSPOSED_INJECT_RUNBOOK.md` §4.5（阶段 3 注入已成功）/§4.6（下一发方案）。
> 本发只补 **Z5 阶段 4**，且用「设备侧总控 + cgroup 加固」绕开 `@sushd` 腿被 framework 重建清掉的问题。

## 0. 已完成

| 步骤 | 结果 |
|---|---|
| Phase 0 收窗 | `w161_teardown.sh` `RC=0`（6m49s），日志 `TEARDOWN_20261115_0150.log` |
| 独立复核出厂态 | `boot_id=35996755`、`Enforcing`、`mod=0`、无 `su`/`ksud`/`kd`、`T5` 17 个固定名全清 |
| 交付基线 | `ko=98bf405273e8652cdb7fffcc3fe42dc2`、`ksu_args.txt` 与 `.bak_delivery` 均 `fec3d301…` |
| Phase 1 开窗 | `I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko bash kmod/go.sh`，日志 `STAGE4_WINOPEN_0158.log`，push 形状三项全对 |

⚠️ 收窗 T2/T2.5 的 `@sushd` 腿「等满」、`pbin` 剩 4 件（root 侧件，shell 删不动）——属已知残留，
按 §6.366 记在账，不阻断本发。`w165b_adb_clean.sh` 只删 `su/.suwtest/ksud/ksu`，
**`/data/adb/modules/` 保留** ⇒ 两个模块不必重装。

## 1. 开窗后必做的核对（等 GO_RC=0 再动）

```
# ① 窗口形状
adb shell "echo boot_id=\$(cat /proc/sys/kernel/random/boot_id); echo up=\$(cut -d' ' -f1 /proc/uptime); \
  echo boot_completed=\$(getprop sys.boot_completed); echo enf=\$(cat /sys/fs/selinux/enforce); \
  echo mod=\$(grep -c kernelsu /proc/modules); echo ksud=\$(ls /dev/ksud 2>&1); \
  echo su=\$(ls /product/bin/su 2>&1)"

# ② 模块目录是否完好（收窗不清 modules，但要读回证）
adb shell "ls -la /data/adb/modules/zygisksu/bin/ /data/adb/modules/zygisk_lsposed/ 2>&1 | head -40"
# 期望：zygiskd/zygiskd64/lib64/*.so 在；zygisk_lsposed/daemon、lspd、zygisk/*.so、dex2oat64 在

# ③ ★module.prop 是否被 daemon 写过（写过则 verify1 会拒，总控脚本 start_zn 会自动从 zip 恢复）
adb shell "cat /data/adb/modules/zygisksu/module.prop 2>&1 | grep -a '^description='"
```

## 2. 推件（开窗后、发扳机前）

```
# probe2.jar（md5 248d7f8ffb1f6e42dbd99e468f4eba05，与 Z5 教程附录 B 一致）
adb push kmod/... n/a → 直接从 Z5 files 推：
adb push "iqooz5/z5_share/z5_share/files/probe2.jar" /data/local/tmp/probe2.jar
adb push "kmod/z6_stage4.sh"  /data/local/tmp/z6_stage4.sh
adb push "kmod/z6_launch.sh"  /data/local/tmp/z6_launch.sh
adb shell "chmod 755 /data/local/tmp/z6_stage4.sh /data/local/tmp/z6_launch.sh; \
           chmod 644 /data/local/tmp/probe2.jar; md5sum /data/local/tmp/probe2.jar"
# 两端 md5 必须都是 248d7f8f…
```

## 3. 发扳机（`@sushd` 腿，窗口内唯一 root 通道）

```
export MSYS_NO_PATHCONV=1
adb shell "am force-stop com.suw.manager"; sleep 1
adb shell "am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm \
           --es cmd '@sushd:/data/local/tmp/z6_launch.sh'"
# 轮询 grep -ac '===== DONE' /data/local/tmp/z6_launch.out，然后 cat 读回
```

`z6_launch.sh` 只做三件事：核前置件 → 双 fork `setsid` 起总控 → 立即返回 DONE。
**总控 `z6_stage4.sh` 完全脱离**（cgroup2 迁到 `/sys/fs/cgroup/z6stage`、memcg 根、`oom_score_adj=-1000`），
框架重建期间不依赖 adb / `@sushd`，全程写 `/data/local/tmp/z6_stage4.log`(0666)。

## 4. 总控脚本做什么（两轮，Z5 全套本就是两次框架重启）

每轮：`start_zn`（自动从 zip 恢复 module.prop 修 verify1）→ `start_lspd`（`system_server` 域双 fork）
→ `poke`（probe2 打针）→ `kick`（杀 system_server+zygote64+zygote）→ 等 framework 回来
→ 补起被清的 daemon → `guard 150`（每 1s 读 `serial`，不是 `[]` 就重打针）→ `verify`。
`serial: []` 出现即 `SUCCESS` 退出；否则进第 2 轮。

## 5. 主机侧双保险

设备总控若也被清，`bash kmod/z6_guard_host.sh 150` 从主机侧零 root 打针守 `serial`
（probe2 是 `LocalSocket` 客户端，adb shell 域即可；读 `service list` 用 `runcon u:r:shell:s0`）。

## 6. 验收（全绿才算成）

```
adb shell "timeout 8 /data/adb/modules/zygisksu/bin/zygiskd status 2>&1 | \
  grep -aE 'version:|inject_state|zygote_states|modules_with_issue'"
adb shell "runcon u:r:shell:s0 service list | grep -a serial"      # 期望 serial: []
adb shell "pidof lspd"                                             # 期望 2 个 PID
adb shell "cat /data/adb/modules/zygisksu/module.prop | grep -a description"  # ✅zygote, ✅zygote_secondary
adb shell "awk '{print \$22}' /proc/\$(pidof zygote64)/stat"         # start_ticks 明显 > 开窗时值
# UI：am start -n org.lsposed.manager/.ui.activity.MainActivity → uiautomator dump → 「已激活」
```

## 7. 收窗（无论成败）

`I_KNOW=1 bash kmod/w161_teardown.sh`；本发 root 腿在踢框架后大概率断 ⇒ T2/T2.5 会等满，
收尾走**无 root 分支 `adb reboot`**，复核 `mod=0 / Enforcing / 无 su / 无 kd`。
结果（含失败）写进 `LSPOSED_INJECT_RUNBOOK.md` §4.7 + `.workbuddy/memory/2026-11-15.md`。

## 8. 口径纪律

- 判「成功」必须对齐**当前阶段**：阶段 3 看 `✅zygote`/`zygote_states:2`，阶段 4 看 `serial: []` + UI「已激活」。
- `znctl status` 连不上 = daemon 死了，**不是**注入没发生；别再拿它当否据。
- 别再写「PPID=1 就安全」；也别再写「framework 全重建连根清掉 PPID=1」（无证据）。
- 所有探测脚本里禁 `pkill -f lspd`（会自杀），用 `for p in $(pidof lspd); do kill -9 $p; done`。
- 长流程每一步留落盘读数；网络波动时先做状态核对再重跑，别盲目重发。
