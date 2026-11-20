#!/system/bin/sh
# su_a_test.sh v2 — A 方案(白名单授权点)判定矩阵。在临时 root 窗口里由靶子亲生孩子以 uid0 跑。
# ★ v2 修了 v1 的挂死: 每一次 su/sudbin 调用都必须 `</dev/null` —— shim 的 relay 会把 stdin
#   当交互输入往 daemon 灌, 而在 ishell 里 stdin 是那条 adb pty; 不重定向就会永久阻塞在
#   select/wait 上(v1 就卡死在 T5 的后台那发, 白占了一个 root 窗口)。
L=/data/local/tmp/su_a_test.log
D=/data/local/tmp
SUD=$D/sudbin
rm -f $L $D/su.audit $D/sud.log /data/adb/su/su.policy
exec >> $L 2>&1
echo "=== A方案判定 开始 uptime=$(cat /proc/uptime) ==="
id
echo "getenforce=$(getenforce)"

# 统一入口: asu <uid> <gid> <命令> ⇒ 以该 uid 调 su, stdin 关闭
asu() { $D/asuid "$1" "$2" $SUD -c "$3" </dev/null 2>&1; echo "  rc=$?"; }

echo "--- 0) 起 daemon(监督循环; 初始策略只有 uid=0 ⇒ 别人全拒) ---"
setsid nohup sh -c 'while :; do '$D'/sudbin --daemon; sleep 2; done' </dev/null >>$D/sud.log 2>&1 &
sleep 2
echo "daemon pidof=$(pidof sudbin)"
ls -ld /data/adb /data/adb/su /data/adb/su/su.policy 2>&1
echo "初始策略:"; cat /data/adb/su/su.policy

echo "--- T7 uid2000 能不能自己读/写策略(必须不能, 否则白名单形同不存在) ---"
$D/asuid 2000 2000 cat /data/adb/su/su.policy </dev/null; echo "  T7_read_rc=$?"
$D/asuid 2000 2000 sh -c 'echo uid=2000 >> /data/adb/su/su.policy' </dev/null; echo "  T7_write_rc=$?"
$D/asuid 2000 2000 ls -ld /data/adb/su </dev/null; echo "  T7_ls_rc=$?"

echo "--- T1 默认拒绝: uid2000(adb shell) 与某个 app uid 都调 su ⇒ 期望 rc=126 ---"
APP=$($SUD --policy show >/dev/null 2>&1; awk '$1=="com.user.app"{print $2; exit}' /data/system/packages.list)
[ -n "$APP" ] || APP=10183
[ -n "$APP" ] && echo "com.user.app 的 uid = $APP (从 /data/system/packages.list 现场取)"
asu 2000 2000 id
asu $APP $APP id

echo "--- T2 热加白名单(不重启 daemon) ⇒ 期望 rc=0 且 uid=0(root) ---"
$SUD --policy add uid=2000
$SUD --policy show
asu 2000 2000 'id; grep -E "Uid|CapEff" /proc/self/status'

echo "--- T3 撤销 ⇒ 期望立刻回到 rc=126(证明每请求重读策略, 没有缓存) ---"
$SUD --policy del uid=2000
asu 2000 2000 id

echo "--- T4 粒度: 只给 $APP, 邻近 uid 必须仍被拒 [不是全放行] ---"
$SUD --policy add uid=$APP
asu $APP $APP id
NEXT=$((APP + 1))
asu $NEXT $NEXT id

echo "--- T5 并发: 两路各 sleep 3, 串行实现=6s / fork-per-conn=3s ---"
# /proc/uptime 第一列是 "476.46" 这种**带小数**的秒, 直接进 $(( )) 会让 toybox sh 报
# "unexpected '.'" 并且整个脚本从这里断掉(前几轮的 T6/T8 就是这么没跑成的) ⇒ 先取整数部分
up_int() { cut -d' ' -f1 /proc/uptime | cut -d. -f1; }
t0=$(up_int)
$D/asuid $APP $APP $SUD -c 'sleep 3; echo CONCUR-A' </dev/null >>$L 2>&1 &
PA=$!
sleep 1
$D/asuid $APP $APP $SUD -c 'echo CONCUR-B' </dev/null
# ★ 这里**不能用裸 wait**: 它等的是"所有子进程", 而第 0 步起的 daemon 监督循环永不退出
#   ⇒ 前两轮就是卡在这(两轮 root 窗口白占)。改成只等这一个 pid, 且带硬上限。
i=0
while [ $i -lt 12 ] && kill -0 $PA 2>/dev/null; do sleep 1; i=$((i+1)); done
t1=$(up_int)
echo "T5_耗时=$((t1 - t0))s  (3=fork-per-conn 生效, 6=还在串行; i=$i 是轮询秒数)"

echo "--- T6 SIGPIPE 回归: 调用方只取前两行就收工, daemon 必须还活着 ---"
$D/asuid $APP $APP $SUD -c 'i=0; while [ $i -lt 500 ]; do echo line$i; i=$((i+1)); done' </dev/null | head -2
sleep 1
echo "T6_daemon_pidof=$(pidof sudbin)"
asu $APP $APP 'echo STILL_ALIVE_AFTER_SIGPIPE'
echo "T6 之后僵尸数=$(ps -A -o PID,STAT,NAME | grep -c '\[sudbin\]')"

echo "--- T8 端到端(app 看得见的路径): tmpfs 覆盖 /product/bin 放 su, 裸名调用 ---"
mkdir -p $D/prod_keep
cp -f /product/bin/* $D/prod_keep/ 2>&1
mount -t tmpfs -o rw,mode=0755 tmpfs /product/bin; echo "  mount_rc=$?"
cp -f $D/prod_keep/* /product/bin/
cp -f $D/sudbin /product/bin/su
chmod 755 /product/bin/*
ls -l /product/bin
grep ' /product/bin ' /proc/mounts
$SUD --policy add uid=2000
$D/asuid 2000 2000 sh -c 'command -v su; su -c id' </dev/null 2>&1; echo "  T8_shell_rc=$?"
$SUD --policy del uid=2000
$D/asuid 2000 2000 sh -c 'su -c id' </dev/null 2>&1; echo "  T8_after_revoke_rc=$?(期望 126)"
$SUD --policy add uid=$APP
$D/asuid $APP $APP sh -c 'su -c id; id' </dev/null 2>&1; echo "  T8_app_rc=$?(期望 0, 且第二行 id 仍是被授予的那个 uid)"

echo "--- T9 真 app 当小白鼠(com.suw.manager 自己的 uid, 不是模拟) ---"
APPUID=$(awk '$1=="com.suw.manager"{print $2; exit}' /data/system/packages.list)
echo "  com.suw.manager 的 uid = ${APPUID:-未找到}"
if [ -n "$APPUID" ]; then
  $SUD --policy reset
  $D/asuid $APPUID $APPUID $SUD -c id </dev/null 2>&1; echo "  T9_denied_rc=$? (期望 126: 白名单里没有它)"
  $SUD --policy add uid=$APPUID
  $D/asuid $APPUID $APPUID $SUD -c id </dev/null 2>&1; echo "  T9_allow_rc=$? (期望 0)"
  am start -n com.suw.manager/.MainActivity >/dev/null 2>&1
  sleep 5
  input tap 540 959            # 刷新状态 + 策略 + 账本(1080x2388 实测中心)
  sleep 3
  screencap -p /data/local/tmp/suw_app_granted.png
  echo "  截图 rc=$? size=$(ls -l /data/local/tmp/suw_app_granted.png | awk '{print $5}')"
fi

echo "--- 审计日志(整段, 这就是管理器的账本) ---"
cat $D/su.audit

echo "--- 9) 收尾: 撤掉 su 层与策略目录 ---"
umount /product/bin; echo "  umount_rc=$? 残留挂载=$(grep -c 'product/bin' /proc/mounts)"
pkill -f 'sudbin --daemon'; sleep 1
echo "收尾后 pidof=$(pidof sudbin)"
rm -rf /data/adb/su $D/prod_keep $D/sud.log
echo "uptime=$(cat /proc/uptime) getenforce=$(getenforce)"
echo "=== A方案判定 结束 ==="
sync
