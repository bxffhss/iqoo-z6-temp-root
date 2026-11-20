#!/system/bin/sh
# su_layer_install.sh — 只做"把 su 层装好并给 manager app 授权", **不拆**(留给窗口外的 UI 取证)。
# 拆的动作改由最后的 reboot 完成(挂载/daemon/策略文件全是易失的)。
L=/data/local/tmp/su_layer.log
D=/data/local/tmp
SUD=$D/sudbin
rm -f $L $D/su.audit $D/sud.log /data/adb/su/su.policy
exec >> $L 2>&1
echo "=== 装 su 层 开始 uptime=$(cat /proc/uptime) ==="
id; echo "getenforce=$(getenforce)"

echo "--- 1) tmpfs 覆盖 /product/bin 并放 su ---"
mkdir -p $D/prod_keep
cp -f /product/bin/* $D/prod_keep/ 2>&1
mount -t tmpfs -o rw,mode=0755 tmpfs /product/bin; echo "  mount_rc=$?"
cp -f $D/prod_keep/* /product/bin/
cp -f $D/sudbin /product/bin/su
chmod 755 /product/bin/*
ls -l /product/bin; grep ' /product/bin ' /proc/mounts

echo "--- 2) 起 daemon + 初始策略(只 uid=0) ---"
APPUID=$(awk '$1=="com.suw.manager"{print $2; exit}' /data/system/packages.list)
echo "  com.suw.manager uid=$APPUID"
# 控制面第二道闸: 只有这个 uid 能用 CTRL(还得带 token)。目录 0700 root ⇒ 别的 uid 改不了这个文件,
# 而"我是哪个 uid"是内核给的、app 伪造不了。少了这一步, 光凭 APK 里的 token 任何 app 都能自加白名单。
if [ -n "$APPUID" ]; then
  mkdir -p /data/adb/su; chmod 700 /data/adb/su
  printf '# 允许使用控制面的 uid\nuid=%s\n' "$APPUID" > /data/adb/su/su.ctrl
  chmod 600 /data/adb/su/su.ctrl
  echo "  已写 /data/adb/su/su.ctrl: $(cat /data/adb/su/su.ctrl | tr -d '\n')"
else
  echo "  !! 没找到 com.suw.manager 的 uid ⇒ su.ctrl 不写(控制面退回只认 token)"
fi
setsid nohup sh -c 'while :; do '$D'/sudbin --daemon; sleep 2; done' </dev/null >>$D/sud.log 2>&1 &
sleep 2
echo "  daemon pidof=$(pidof sudbin)"
$SUD --policy reset; $SUD --policy show

echo "--- 3) 给 manager app 授权(它自己的 uid) ---"
$D/asuid $APPUID $APPUID $SUD -c id </dev/null 2>&1; echo "  授权前 rc=$? (期望 126)"
$SUD --policy add uid=$APPUID
$D/asuid $APPUID $APPUID $SUD -c id </dev/null 2>&1; echo "  授权后 rc=$? (期望 0)"

echo "--- 4) 保持窗口: 打印现场后直接退出(su 层与 daemon 留在系统里等 UI 取证) ---"
echo "  pidof=$(pidof sudbin) 挂载=$(grep -c 'product/bin' /proc/mounts) uptime=$(cat /proc/uptime)"
echo "LAYER_READY uid=$APPUID"
sync
