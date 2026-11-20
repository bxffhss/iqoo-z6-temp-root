#!/bin/bash
# w133_live.sh —— **不重开机**，在现有活窗口里把"挂载路线"的三态判据一次跑完。
# 用法：bash kmod/w133_live.sh
# 前提：本 boot 已 punch、ko 已加载、agent(shd) 已由 stage 以 root 起好并装了驱动 fd。
# 判据三态(PATH 只给挂载点一项 ⇒ 钩子插不进来)：
#   errno=2     ⇒ 文件不在
#   uid=0(root) ⇒ 文件在且内核名单放行
#   not-allowed ⇒ 文件在但内核名单没放行   ← 撤名单的负对照必须是这一态
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }
TU=${TU:-10667}; TP=${TP:-com.termux}; TGT=${TGT:-/product/bin}
OUTD=kmod/w103_evidence; mkdir -p "$OUTD"
fire() {   # fire <动词> <等多久>
    A "am force-stop com.suw.manager" >/dev/null
    sleep 1
    A "am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null
    sleep "$2"
}
run() {   # run <脚本> <等多久> <标签> <回执文件>
    local F=${4:-/data/local/tmp/w133_probe.out}
    A "rm -f $F" >/dev/null
    fire "@sushd:/data/local/tmp/$1" "$2"
    echo "----- $3 ($1) -----"
    A "cat $F 2>&1" | sed 's/^/  /'
}

for f in kmod/w133_probe.sh kmod/w133_mount.sh; do
    MSYS_NO_PATHCONV=1 adb push "$f" "/data/local/tmp/$(basename "$f")" >/dev/null 2>&1
done
A "chmod 755 /data/local/tmp/w133_probe.sh /data/local/tmp/w133_mount.sh; echo $TU > /data/local/tmp/w132_tuid.txt" >/dev/null
echo "=== 现场 ==="
A "echo up=\$(cat /proc/uptime) mod=\$(grep -c kernelsu /proc/modules) agent=[\$(pidof shd)] ksuctl87=\$(md5sum /data/local/tmp/ksuctl87 2>&1 | cut -c1-32)" | sed 's/^/  /'

echo "=== 1) 名单点亮 $TP(uid=$TU) ==="
fire "@setprof:$TU:1:$TP" 10
A "grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1" | sed 's/^/  /'

echo "=== 2) 挂载**之前**的三态基线 ==="
run w133_probe.sh 16 "挂载前"

echo "=== 3) 挂载 $TGT ==="
run w133_mount.sh 30 "挂载" /data/local/tmp/w133_mount.out

echo "=== 4) PC 侧独立复核框架(不靠脚本自己说) ==="
A "service list 2>/dev/null | head -1; pm list packages -3 2>/dev/null | wc -l; ls -l $TGT/su 2>&1" | sed 's/^/  /'
echo "  真的用 am 起一次 app："
A "am force-stop com.suw.manager; sleep 1; am start -n com.suw.manager/.MainActivity" | grep -aiE "Starting|Error|Exception|Can't" | sed 's/^/    /'

echo "=== 5) 挂载**之后**的三态(期望 B 段出 uid=0(root)) ==="
run w133_probe.sh 16 "挂载后"

echo "=== 6) 撤名单 ==="
fire "@setprof:$TU:0:$TP" 10
A "grep -a 'allow=0' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1" | sed 's/^/  /'
echo "=== 7) 撤名单之后再测(期望 B 段 = not-allowed，而**不是** errno=2) ==="
run w133_probe.sh 16 "撤名单后"

echo "=== 8) 收尾：卸载 + 证明回到原状 ==="
A "umount $TGT; echo UMOUNT_RC=\$?; ls -l $TGT/su 2>&1; rm -rf /data/local/tmp/pbin" | sed 's/^/  /'
echo "=== 9) 卸载后最后一态(期望 errno=2) ==="
run w133_probe.sh 16 "卸载后"

for f in w133_probe.out w133_mount.out; do
    MSYS_NO_PATHCONV=1 adb pull "/data/local/tmp/$f" "$OUTD/w24_$f" >/dev/null 2>&1 && echo "已存证 $OUTD/w24_$f"
done
echo "=== 完 ==="
