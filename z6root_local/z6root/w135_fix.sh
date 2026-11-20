#!/system/bin/sh
# w135_fix.sh —— 把 /product/bin 从"源目录被删掉但仍挂着"的坏态救回来，然后补最后一态判据。
#
# 两处操作错误(都记进 §6.124⑤)：
#   ① `umount` 我放在 PC 侧(adb shell, uid 2000) ⇒ 没有 CAP_SYS_ADMIN ⇒ EPERM，挂载根本没卸掉；
#      紧接着 `rm -rf /data/local/tmp/pbin` 就把**还挂着的源目录**删了 ⇒ /product/bin 变成指向已删目录。
#   ② 挂载点判据 `grep " /product/bin " /proc/self/mountinfo` 读不到东西：`/product` 是指向
#      `/system/product` 的符号链接，mountinfo 里记的是**规范化之后**的路径 ⇒ 要按源目录名(pbin)找。
# ⇒ 收尾必须 root 侧做，而且**先 umount 成功、再删目录**，顺序不能反。
L=${OUT:-/data/local/tmp/w135_fix.out}
TGT=/product/bin
NB=/data/local/tmp/pbin
SRC=/data/local/tmp/sustatic
CTL=/data/local/tmp/ksuctl87
U=$(cat /data/local/tmp/w132_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
echo "--- [0] 现在挂着的是哪个源(按源目录名找，不按 /product/bin 字面) ---"
grep -a "pbin\|/product/bin" /proc/self/mountinfo | cut -c1-150
echo "MOUNT_LINES=$(grep -ac "pbin" /proc/self/mountinfo)"
echo "--- [1] root 侧逐个 umount，直到没有为止 ---"
i=1
while [ $i -le 5 ]; do
    grep -aq pbin /proc/self/mountinfo || break
    umount "$TGT" >/data/local/tmp/w135_um.err 2>&1
    echo "  umount#$i rc=$? $(cat /data/local/tmp/w135_um.err 2>/dev/null)"
    umount -l "$TGT" >/dev/null 2>&1 && echo "  (试过 lazy)"
    i=$((i+1))
done
echo "MOUNT_LEFT=$(grep -ac pbin /proc/self/mountinfo)"
echo "BACK_TO_N=$(ls -A $TGT 2>/dev/null | wc -l)  (原始应是 3)"
echo "SU_GONE_NOW=$(ls -l $TGT/su 2>&1)"
[ "$(grep -ac pbin /proc/self/mountinfo)" != "0" ] && { echo "STILL_MOUNTED ⇒ 停手，交人工重启"; exit 1; }

echo "--- [2] 干净重建 ---"
rm -rf "$NB"; mkdir -p "$NB"
cp -a "$TGT/." "$NB/" 2>/dev/null
echo "CP_N=$(ls -A $NB | wc -l) (要 = $(ls -A $TGT | wc -l))"
cp $SRC "$NB/su" && chmod 755 "$NB" "$NB/su" && echo "CP_SU_OK"
mount --bind "$NB" "$TGT"; echo "BIND_RC=$?"
echo "SU_AT_TGT=$(ls -l $TGT/su 2>&1)"
echo "SVC_SHELL=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
echo "HEALTH=$([ "$(/system/bin/sh -c 'echo yes' 2>&1)" = yes ] && echo OK || echo DEAD)"

echo "--- [3] ★最后一态：挂载 + 名单内，PATH 只给挂载点一项 ⇒ 期望 uid=0(root) ---"
echo "GRANT=$(grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt | tail -1 | cut -c1-95)"
$CTL supath "$U" "$TGT" su -c /system/bin/id 2>&1
echo "--- [3b] 顺带：变 root 之后驱动 fd 有没有漏进 shell(期望 0) ---"
$CTL supath "$U" "$TGT" su -c "/system/bin/ls /proc/self/fd" 2>&1 | grep -ac ksu_driver
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
