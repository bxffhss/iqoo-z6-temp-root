#!/system/bin/sh
# w1006_probe139.sh —— 用**还开着的这扇窗**做两件不花钱的事：
#   ①把 w1002 留下的尺删净（MLS 可能连属主都挡，第 62/63 发一手 ⇒ 趁现在还是 root 腿先删）；
#   ②把上一发那三个 `Segmentation fault`(rc=139) 与 SET_APP_PROFILE 的 EPERM **拆开定位**：
#     到底是 run-as、还是 env su、还是我的引号嵌套；以及 ksuctl 眼里的"调用方是谁"。
# ★不装模块、不碰 /sys/fs/selinux/load、不改 enforce。每段 sync。
L=/data/local/tmp/w1006_probe139.out
H=/data/data/com.termux/files
CTL=/data/local/tmp/ksuctl88
: > $L
sync
say() { echo "$1" >> $L; }
say "BEGIN up=$(cat /proc/uptime) enf=$(cat /sys/fs/selinux/enforce) id=$(id 2>&1)"

say "--- 1) 清尺 ---"
rm -rf $H/W99_P9 $H/W99_Q9
say "rm_rc=$?  读回=$(ls -d $H/W99_P9 $H/W99_Q9 2>&1 | tr -s '\n' ' ')"
sync

say "--- 2) ksuctl 眼里的调用方与名单 ---"
$CTL info 2>&1 | head -6 | sed 's/^/  info: /' >> $L
$CTL granted 2>&1 | head -8 | sed 's/^/  granted: /' >> $L
sync

say "--- 3) 139 的三段隔离（每段单独跑，取 rc 的方式＝先捕获再取，不用管道末端） ---"
o=$(run-as com.termux /system/bin/id 2>&1); r=$?
say "3a run-as+id rc=$r out=[$(printf '%s' "$o" | tr -s '\n' ' ' | cut -c1-90)]"
o=$(run-as com.termux /system/bin/ls -d $H/W99_P9 2>&1); r=$?
say "3b run-as+ls(不存在的目录) rc=$r out=[$(printf '%s' "$o" | tr -s '\n' ' ' | cut -c1-90)]"
o=$(/system/bin/env /system/bin/su -c id 2>&1); r=$?
say "3c root 腿里直接 su -c id rc=$r out=[$(printf '%s' "$o" | tr -s '\n' ' ' | cut -c1-110)]"
o=$(/system/bin/su 0 id 2>&1); r=$?
say "3d su 0 id rc=$r out=[$(printf '%s' "$o" | tr -s '\n' ' ' | cut -c1-110)]"
sync

say "--- 4) 再试一次 setprof，但把调用方与 errno 记全 ---"
U=$(pm list packages -U 2>/dev/null | grep -a '^package:com.termux ' | sed 's/.*uid://')
say "uid=$U"
o=$($CTL setprof "$U" com.termux u:r:shell:s0-s0:c0.c1023 2>&1); r=$?
say "setprof rc=$r out=[$(printf '%s' "$o" | tr -s '\n' ' ' | cut -c1-150)]"
sync
say "END up=$(cat /proc/uptime)"
chmod 666 $L
sync
