#!/bin/bash
# w171_run.sh —— #73 第一步的一条命令：把 rc61 的"全表扫 vr 管几条 syscall"读数拿回来。
#   前提：窗口已经起来(I_KNOW=1 KO=kmod/kernelsu_rc61.ko bash kmod/go.sh)。全程纯读。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
RUN=/data/local/tmp/w171_cfiscan.sh
L=$EV/w171_cfiscan.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }

echo "=== 0) 窗口/ko 版本 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }
[ -n "$(A 'ls /proc/ksu_cfiscan 2>/dev/null')" ] || echo "  [!] /proc/ksu_cfiscan 不在(设备侧读不到也正常，它是 0600 root)；真触发时若报 no file 就是 ko 不是 rc61"

echo "=== 1) 推 + 核 md5 ==="
adb push kmod/w171_cfiscan.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $RUN; rm -f /data/local/tmp/w171_cfiscan.out" >/dev/null
LM=$(md5sum kmod/w171_cfiscan.sh | cut -c1-32); RM=$(A "md5sum $RUN" | cut -c1-32)
[ "$LM" = "$RM" ] && echo "  ok w171_cfiscan.sh $LM" || { echo "[x] 设备侧不是本机这份(设备=$RM 本机=$LM)"; exit 3; }

echo "=== 2) 触发扫描 + 收报告 ==="
fire "@sushd:$RUN" 6
for i in $(seq 1 24); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w171_cfiscan.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && { echo "      跑完了($((i*5))s 轮询)"; break; }
    sleep 5
done
A "cat /data/local/tmp/w171_cfiscan.out" > "$L" 2>/dev/null
echo "  存证=$L 行数=$(wc -l < "$L")"
grep -aE "^=== CF|我们的 ko|触发|VRCFI|===== DONE|\[x\]" "$L" | cut -c1-190
echo
echo "  ★读法：只有'B 或桩+8 的 .quad 解析到模块名 vr'才算被管；正对照=openat/execve/execveat 三条仍在名单里。"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
