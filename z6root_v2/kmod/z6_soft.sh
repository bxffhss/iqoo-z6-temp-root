#!/bin/bash
# z6_soft.sh — 软重启（只重启 framework/zygote，不卸载 ko）
#   目的：让 LSPosed 重新注入 / 让框架重建，而无需重跑 exploit（不花 punch）。
#   ★前提：窗口活着且 root 腿(@sushd)还活着（即"踢框架之前"）。踢过框架后 @sushd 已死，本脚本无法派单。
#   ★之后：shd(idle=0) 与维持件 b8_keep 是 setsid+cgroup 脱离的，会扛过软重启并自动恢复
#           su / 管理器「工作中[越狱模式]」；LSPosed 若模块还在则随 zygote 重建自动重新注入。
set -u
export MSYS_NO_PATHCONV=1
export PATH="/c/adb/platform-tools:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
[ -f config.sh ] && . ./config.sh   # 可选：预设 ADB/DEV
ADB="${ADB:-adb}"; A(){ "$ADB" "$@"; }
ap(){ A shell "$1" 2>/dev/null | tr -d '\r'; }

echo "==== z6_soft  软重启 ===="
MOD=$(ap "grep -c kernelsu /proc/modules"); MOD=${MOD:-0}
[ "$MOD" = "1" ] || { echo "[x] 没有活窗口(mod=$MOD) ⇒ 先 bash kmod/z6_on.sh"; exit 3; }

cat > /tmp/z6_soft_dev.sh <<'EOS'
exec >/data/local/tmp/z6_soft.out 2>&1
echo "id=$(id) up=$(cut -d' ' -f1 /proc/uptime)"
SS=$(pidof system_server); Z64=$(pidof zygote64); Z32=$(pidof zygote)
echo "targets ss=$SS z64=$Z64 z32=$Z32"
kill -9 $SS $Z64 $Z32 2>/dev/null
echo "kick rc=$?"
echo "===== DONE ====="
EOS
A push /tmp/z6_soft_dev.sh /data/local/tmp/z6_soft_dev.sh >/dev/null 2>&1
A shell "chmod 755 /data/local/tmp/z6_soft_dev.sh" >/dev/null 2>&1

echo "  派单踢框架（adb 会短暂掉线，framework 数秒后回来）"
A shell "am force-stop com.suw.manager; sleep 1; am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd '@sushd:/data/local/tmp/z6_soft_dev.sh'" >/dev/null 2>&1
sleep 5
echo "  等 adb 回来..."
for i in $(seq 1 40); do A get-state 2>/dev/null | grep -q device && { echo "  adb back ~$((i*4))s"; break; }; sleep 4; done
sleep 2
echo "  现状: mod=$(ap 'grep -c kernelsu /proc/modules') / shd=$(ap 'pidof shd') / mgr=$(ap 'pidof me.weishu.kernelsu')"
echo "  若 su/越狱模式没自动回，跑 bash kmod/z6_after.sh 补"
