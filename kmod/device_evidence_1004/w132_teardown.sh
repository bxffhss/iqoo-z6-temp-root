#!/system/bin/sh
# w132_teardown.sh —— 收尾：卸掉 /product/bin 上的挂载并**当场证明回到原状**。
#   最后一格负对照：文件又没了 ⇒ 同一条 supath 探针必须退回 errno=2。
L=${OUT:-/data/local/tmp/w132_teardown.out}
TARGET=${TGT:-/product/bin}
CTL=/data/local/tmp/ksuctl87
U=$(cat /data/local/tmp/w132_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
AP=$(cat /data/local/tmp/w132_apath.txt 2>/dev/null)
[ -n "$AP" ] || AP="/sbin:/system/sbin:/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin"
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) target=$TARGET ==="
    grep -a " $TARGET " /proc/self/mountinfo | cut -c1-140
    umount "$TARGET" >/data/local/tmp/w132_um.err 2>&1
    echo "UMOUNT_RC=$?  $(cat /data/local/tmp/w132_um.err 2>/dev/null)"
    echo "MOUNT_LEFT=$(grep -ac " $TARGET " /proc/self/mountinfo)"
    echo "N_AFTER=$(ls -A $TARGET 2>/dev/null | wc -l)"
    echo "SU_GONE=$(ls -l $TARGET/su 2>&1)"
    echo "SVC_AFTER=$(service list 2>/dev/null | head -1)"
    echo "--- 负对照(最后一格)：文件不在了，同一条探针必须 errno=2 ---"
    $CTL supath "$U" "$AP" su -c id 2>&1
    echo "RC=$?"
    rm -rf /data/local/tmp/pbin /data/local/tmp/subin /data/local/tmp/newbin && echo "RM_DIRS_OK"
    echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
