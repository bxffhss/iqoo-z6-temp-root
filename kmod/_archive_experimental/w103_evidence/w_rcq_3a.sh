#!/system/bin/sh
# w_rcq_3a.sh — 目标③ 3a 框架格：在临时 root 窗里把真实社区模块 rcq(m_rcq) 装进 /data/adb/modules，
#   并以 uid=0 跑该模块 service.sh 的"具体 root 动作"（proc sysctl 加固写），证脚本以 root 执行且产物可观测/可还原。
#   经 @sushd 由 suw manager 以 uid=0 执行（fire() 派发）。
#
# ★安全口径（与 rcq service.sh 字面一致但只取安全子集）：
#   只跑 service.sh 里"root 才写得的 proc sysctl 加固"那 5 行（kptr_restrict/dmesg_restrict/suid_dumpable/
#   core_pattern/perf_event_paranoid）——可观测、重启即还原、不落盘持久。
#   ★显式排除 service.sh 的自隐藏/自改行，根因：
#     · setenforce 1        —— 会把临时 root 窗翻回 Enforcing、打断 root 通道；
#     · chmod 000 /proc/ksu —— 把"我们自己的 ko"节点藏掉，自伤；
#     · resetprop ro.* 风暴 / settings put —— 二者都可能跨 reboot 持久，违反"不留过夜/不留尾巴"；
#     · chmod 000 /proc/kallsyms|modules|debugfs —— 自隐藏；
#     · chmod 777 …/I_am_taffy + exec —— 那是 customize.sh 从 c1.zip 提取的 payload，我们没提取也不该跑未知码。
#   这些是刻意的安全裁剪，已在 PC 侧与账本如实登记。
OUT=/data/local/tmp/rcq_3a.out
: > "$OUT"
log(){ echo "$*" >> "$OUT"; }

log "=== UID 证明（@sushd 派发 ⇒ 应为 0）==="
log "uid=$(id -u) euid=$(id -u) name=$(id -un) context=$(id -Z 2>/dev/null || echo n/a)"

MOD=/data/adb/modules/m_rcq
SRC=/data/local/tmp/rcq_mod
log "=== 安装真实模块 m_rcq 到 $MOD ==="
rm -rf "$MOD"
mkdir -p "$MOD"
cp -r "$SRC/." "$MOD"/ 2>/dev/null
chmod 0755 "$MOD"
chmod 0644 "$MOD/module.prop" 2>/dev/null
chmod 0755 "$MOD/service.sh" 2>/dev/null
log "module.prop 存在=$( [ -f "$MOD/module.prop" ] && echo YES || echo NO )"
log "module.prop 头三行："
head -3 "$MOD/module.prop" >> "$OUT" 2>&1
log "模块目录项数=$(ls -la "$MOD" 2>/dev/null | wc -l)"

# ★模块 service.sh 的具体 root 动作（proc sysctl 加固，与 rcq service.sh 字面一致）；逐条捕 rc＋before/after
set_one() {
  local path="$1" val="$2" name="$3" b a
  b=$(cat "$path" 2>/dev/null)
  echo "$val" > "$path" 2>/dev/null; local rc=$?
  a=$(cat "$path" 2>/dev/null)
  log "$name: before=$b write_rc=$rc after=$a"
}
log "=== 跑模块 service.sh 的 proc sysctl 加固行（uid=0）==="
set_one /proc/sys/kernel/kptr_restrict 2 kptr_restrict
set_one /proc/sys/kernel/dmesg_restrict 1 dmesg_restrict
set_one /proc/sys/fs/suid_dumpable 0 suid_dumpable
set_one /proc/sys/kernel/core_pattern 0 core_pattern
set_one /proc/sys/kernel/perf_event_paranoid 2 perf_event_paranoid

# ★根属名 marker 产物（visible artifact，证脚本以 root 落地文件）
log "=== 根属名 marker 产物 ==="
echo "RCQ m_rcq service.sh 以 uid=$(id -u) 在临时 root 窗执行 @ $(date)" > "$MOD/RCQ_RAN_AS_ROOT.flag"
chown root:root "$MOD/RCQ_RAN_AS_ROOT.flag" 2>/dev/null
chmod 0644 "$MOD/RCQ_RAN_AS_ROOT.flag"
log "marker=$(ls -l "$MOD/RCQ_RAN_AS_ROOT.flag" 2>/dev/null)"

# ★清理模块，避免留尾巴：kernel 模块位置 /data/adb/modules 是持久分区，kernelsu 卸载后无人加载它，
#   留着就是我们的磁盘脚印（违反"不留过夜/不留尾巴"）。所有判正凭据已写进上面的 $OUT，清掉不影响读数。
log "=== 清理模块(不留尾巴) ==="
rm -rf "$MOD" 2>/dev/null
log "模块已清理=$( [ -d "$MOD" ] && echo NO || echo YES )"

log "=== END up=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1) ==="
exit 0
