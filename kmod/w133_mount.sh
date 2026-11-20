#!/system/bin/sh
# w133_mount.sh —— 把静态 su 挂到 /product/bin，并且**用对**框架健康判据。
#
# 第 23 发的假警报：root 侧脚本里跑 `service list` 得到 `Found 0 services:` 就把挂载回退了。
# 那不是挂载造成的 —— **vivo 对非 shell 域隐藏服务列表**(Z5 教程同一手记：root 域 `service list`
# 看到 0 个服务，必须 `runcon u:r:shell:s0` 才读得到)。本机当场对拍过：
#   adb shell(域 shell)   → Found 327 services
#   root 侧脚本(域 kernel) → Found 0 services      ← 与挂载无关
# ⇒ 健康判据必须写成 `runcon u:r:shell:s0 service list`。
L=${OUT:-/data/local/tmp/w133_mount.out}
TGT=${TGT:-/product/bin}
NB=/data/local/tmp/pbin
SRC=/data/local/tmp/sustatic
CTL=/data/local/tmp/ksuctl87
echo "$TGT" > /data/local/tmp/w133_tgt.txt
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) tgt=$TGT ====="
echo "SELF_CTX=$(cat /proc/self/attr/current)"
echo "--- [0] 基线 ---"
echo "PRE_SU=$(ls -l $TGT/su 2>&1)"
PRE_N=$(ls -A $TGT | wc -l); echo "PRE_N=$PRE_N"
echo "SVC_SHELL_BEFORE=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
echo "SVC_ROOT_BEFORE=$(service list 2>/dev/null | head -1)   # ★这条本来就是 0，不能当判据"
echo "--- [1] 副本 ---"
rm -rf "$NB"; mkdir -p "$NB"
cp -a "$TGT/." "$NB/" 2>/dev/null
cp $SRC "$NB/su" && echo "CP_SU_OK" || echo "CP_SU_FAIL"
chmod 755 "$NB" "$NB/su"
echo "CP_N=$(ls -A $NB | wc -l)"
echo "--- [2] bind ---"
mount --bind "$NB" "$TGT"; echo "BIND_RC=$?"
grep -a " $TGT \|/product/bin " /proc/self/mountinfo | cut -c1-140
echo "--- [3] ★健康判据(用对域) ---"
echo "SH_ALIVE=$(/system/bin/sh -c 'echo yes' 2>&1)"
echo "N_AFTER=$(ls -A $TGT | wc -l)  (要 >= $PRE_N)"
echo "SU_AT_TGT=$(ls -l $TGT/su 2>&1)"
echo "SVC_SHELL_AFTER=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
echo "PM3=$(runcon u:r:shell:s0 pm list packages -3 2>/dev/null | wc -l)"
BAD=""
[ "$(/system/bin/sh -c 'echo yes' 2>&1)" != "yes" ] && BAD="$BAD SH_DEAD"
[ "$(ls -A $TGT | wc -l)" -lt "$PRE_N" ] && BAD="$BAD LOST_ENTRIES"
case "$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)" in *"Found 0"*) BAD="$BAD SVC_ZERO";; esac
if [ -n "$BAD" ]; then
    echo "HEALTH_FAIL[$BAD] ⇒ umount 回退"
    umount "$TGT"; echo "ROLLBACK_RC=$?"
    echo "RESULT=ROLLED_BACK"; exit 1
fi
echo "HEALTH=OK"
echo "--- [4] 挂载后立刻跑钩子进不来的探针 ---"
$CTL supath "$(cat /data/local/tmp/w132_tuid.txt)" "$TGT" su -c /system/bin/id 2>&1
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
