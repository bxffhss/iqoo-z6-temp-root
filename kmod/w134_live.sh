#!/bin/bash
# w134_live.sh —— 把"三态判据"用**修好的载荷**重跑一遍（PATH 只给挂载点一项 ⇒ 内层命令必须写绝对路径）。
# 用法：bash kmod/w134_live.sh
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }
TU=${TU:-10667}; TP=${TP:-com.termux}; TGT=${TGT:-/product/bin}
fire() {
    A "am force-stop com.suw.manager" >/dev/null; sleep 1
    A "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null; sleep "$2"
}
run() {   # run <脚本> <等待> <标签> <回执文件>
    local F=$4
    A "rm -f $F" >/dev/null
    fire "@sushd:/data/local/tmp/$1" "$2"
    echo "----- $3 -----"
    A "cat $F 2>&1" | sed 's/^/  /'
}
MSYS_NO_PATHCONV=1 adb push kmod/w133_probe.sh /data/local/tmp/w133_probe.sh >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb push kmod/w133_mount.sh /data/local/tmp/w133_mount.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w133_probe.sh /data/local/tmp/w133_mount.sh; echo $TU > /data/local/tmp/w132_tuid.txt" >/dev/null
echo "现场: $(A 'echo up=$(cat /proc/uptime) mod=$(grep -c kernelsu /proc/modules) agent=$(pidof shd) 已挂=$(grep -c " /product/bin " /proc/self/mountinfo)')"

echo "=== 0) 未挂载态：B 段必须 errno=2 ==="
run w133_probe.sh 16 "未挂载" /data/local/tmp/w133_probe.out

echo "=== 1) 点亮名单并挂载 ==="
fire "@setprof:$TU:1:$TP" 10
run w133_mount.sh 30 "挂载" /data/local/tmp/w133_mount.out

echo "=== 2) 挂载+名单内：B 段必须 uid=0(root) ==="
run w133_probe.sh 16 "挂载+已授权" /data/local/tmp/w133_probe.out

echo "=== 3) 挂载+撤名单：B 段必须被 agent 拒(not-allowed)，不能是 errno=2 ==="
fire "@setprof:$TU:0:$TP" 10
run w133_probe.sh 16 "挂载+撤名单" /data/local/tmp/w133_probe.out

echo "=== 4) 框架独立复核(挂载还挂着的时候) ==="
A "service list 2>/dev/null | head -1; pm list packages -3 2>/dev/null | wc -l" | sed 's/^/  /'
A "am force-stop com.suw.manager; sleep 1; am start -n com.suw.manager/.MainActivity" | grep -aiE "Starting|Error|Can't" | sed 's/^/  /'

echo "=== 5) 收尾 ==="
A "umount $TGT; echo UMOUNT_RC=\$?; ls -l $TGT/su 2>&1; rm -rf /data/local/tmp/pbin; echo up=\$(cat /proc/uptime)" | sed 's/^/  /'
for f in w133_probe.out w133_mount.out; do
    MSYS_NO_PATHCONV=1 adb pull "/data/local/tmp/$f" "kmod/w103_evidence/w25_$f" >/dev/null 2>&1 && echo "存证 w25_$f"
done
echo "=== 完 ==="
