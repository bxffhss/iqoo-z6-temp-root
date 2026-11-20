#!/bin/bash
# w178_leg.sh —— #78 的**一腿**：在活窗口里把 policeprobe 跑在交付态 su shell 上，拉回来数 EPERM。
#   ★为什么不是"同一发里翻开关"：`kobject_del(&THIS_MODULE->mkobj.kobj)`(core/init.c:209，我们自己在 init 里摘的)
#     把 `/sys/module/kernelsu/` 整个摘走 ⇒ `ksu_capclamp` 只能在 **insmod 那一刻**由参数定，运行时写不进去。
#     所以单变量对照=**两发窗口**，差别只有 `kmod/ksu_args.txt` 里那一个 `ksu_capclamp=0/1`
#     (go.sh 会把这份 args 的 md5 打进日志 ⇒ 用的是哪一份，存证自己会说话)。
#   用法：bash kmod/w178_leg.sh off      # args 里带 ksu_capclamp=0 的那一发(期望 cap1=ffffffff、POL 11 条 EPERM)
#         bash kmod/w178_leg.sh on       # 默认(clamp=1)那一发(期望 cap=0x3fffffffff、POL 0 条 EPERM)
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
MODE=${1:-on}
L=$EV/w178_$MODE.txt

echo "=== 0) 窗口与载荷 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }
echo "  args(本机) = $(cat kmod/ksu_args.txt)"
echo "  args(设备) = $(A 'cat /data/local/tmp/ksu_args.txt 2>/dev/null')  md5=$(A 'md5sum /data/local/tmp/ksu_args.txt' | cut -c1-32)"
adb push cm57/policeprobe kmod/w177_ch.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/policeprobe /data/local/tmp/w177_ch.sh; rm -f /data/local/tmp/pp_su.txt" >/dev/null
LM=$(md5sum cm57/policeprobe | cut -c1-32); RM=$(A "md5sum /data/local/tmp/policeprobe" | cut -c1-32)
[ "$LM" = "$RM" ] || { echo "  [x] 探针设备=$RM 本机=$LM ⇒ 停(两发必须同一份仪器)"; exit 3; }
echo "  ok policeprobe $LM"

echo "=== 1) Termux 里 su 跑探针($MODE 腿) ==="
bash kmod/w177_termux.sh > "$EV/w178_$MODE.termux.log" 2>&1
echo "  Termux 驱动日志尾: $(tail -2 "$EV/w178_$MODE.termux.log" | tr '\n' ' ' | cut -c1-150)"

echo "=== 2) root 侧补 chmod(那一句常常敲不进 Termux) 再拉回来 ==="
A "am force-stop $SUW" >/dev/null; sleep 1
A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/w177_ch.sh\"" >/dev/null 2>&1
sleep 9
A "cat /data/local/tmp/pp_su.txt" > "$L" 2>/dev/null
[ -s "$L" ] || { echo "  [x] 没拉回来(文件为空)⇒ 这一腿不算"; exit 4; }
echo "  存证=$L 行数=$(wc -l < "$L") 结尾=$(tail -1 "$L" | cut -c1-40)"
grep -aq "policeprobe DONE" "$L" || echo "  [警告] 没有 DONE 行 ⇒ 可能是半截存证(例39)"

echo "=== 3) 读数 ==="
grep -aE "^\[起点\]|^\[终点\]" "$L" | sort -u | cut -c1-210 | sed 's/^/  /'
echo "  POL 组 EPERM=$(grep -a '^POL ' "$L" | grep -ac 'errno=1 ') / CTRL 组 EPERM=$(grep -a '^CTRL ' "$L" | grep -ac 'errno=1 ')"
echo "  POL 组逐条: $(grep -a '^POL ' "$L" | awk '{printf "%s=%s ", $2, $5}' | cut -c1-190)"
case "$MODE" in
  off) echo "  期望：cap_eff=ffffffffffffffff 且 POL EPERM=11、CTRL EPERM=0" ;;
  on)  echo "  期望：cap_eff=0000003fffffffff 且 POL EPERM=0、CTRL EPERM=0" ;;
esac
