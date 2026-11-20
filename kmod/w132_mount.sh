#!/system/bin/sh
# w132_mount.sh —— 把静态 su 挂到 **/product/bin**（第二十三发；第 22 发盖 /system/bin 的教训）。
#
# 第 22 发实测：`mount --bind <newbin> /system/bin` 本身全绿(499/499 项、sh 跑得动、
#   /vendor/bin/sh 也跑得动、/system/bin/su 成了真文件)，**但之后框架废了**：
#   `service list` 只剩 0 个服务、`am` 报 `Can't find service: activity`、u0_a 进程数 0
#   ⇒ 起不了新 app ⇒ 最关键的"app 域按 PATH 找 su"那一格反而测不了。重启才恢复(327 个服务)。
#   所以这一发把目标从 /system/bin 换成 /product/bin：
#     ① 它在 A11 base PATH 里排在**最前面**(`execvp("su")` 第一个就命中它)；
#     ② 它只有 3~4 项，框架运行时根本不依赖它(不像 /system/bin 里住着 sh/linker64/app_process)；
#     ③ 把"框架还活着"升级成**一等判据**，而且**不过就自动 umount 回退**。
#
# 授权仍然只在内核：su → @suwshd → shd v4 问内核 UID_GRANTED_ROOT → 转交驱动 fd → GRANT_ROOT。
# 全程不碰那个坏掉的 stat/faccessat 钩子(#47 是被绕开，不是被修好)。
L=${OUT:-/data/local/tmp/w132_mount.out}
TARGET=${TGT:-/product/bin}
NB=/data/local/tmp/pbin
SRC=/data/local/tmp/sustatic
CTL=/data/local/tmp/ksuctl87

{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) target=$TARGET ====="

echo "--- [0] 挂载之前的基线(负对照地基) ---"
echo "PRE_SU=$TARGET/su: $(ls -l $TARGET/su 2>&1)"
echo "PRE_N=$(ls -A $TARGET 2>/dev/null | wc -l)"
SVC0=$(service list 2>/dev/null | head -1)
echo "SVC_BEFORE=$SVC0"

echo "--- [1] 造副本目录(root 侧 cp -a ⇒ 那些 shell stat 不到的条目也拿得到) ---"
rm -rf "$NB"; mkdir -p "$NB"
cp -a "$TARGET/." "$NB/" 2>/dev/null
echo "CP_N=$(ls -A $NB | wc -l)  (要 >= PRE_N=$(ls -A $TARGET 2>/dev/null | wc -l))"
cp $SRC "$NB/su" && echo "CP_SU_OK" || echo "CP_SU_FAIL"
chmod 755 "$NB" "$NB/su"
ls -l "$NB" | tail -5

echo "--- [2] bind ---"
mount --bind "$NB" "$TARGET"
BRC=$?
echo "BIND_RC=$BRC"
if [ $BRC -ne 0 ]; then echo "MOUNT_FAIL"; exit 1; fi
grep -a " $TARGET " /proc/self/mountinfo | cut -c1-150

echo "--- [3] ★一等判据：框架还活着吗(第 22 发就是这一格没测，导致后面全废) ---"
SVC1=$(service list 2>/dev/null | head -1)
echo "SVC_AFTER=$SVC1"
PM1=$(pm list packages -3 2>/dev/null | wc -l)
echo "PM3_COUNT=$PM1  (第 22 发之前测过：正常应是几百)"
echo "SH_ALIVE=$(/system/bin/sh -c 'echo yes' 2>&1)"
echo "SU_AT_TARGET=$(/system/bin/ls -l $TARGET/su 2>&1)"
echo "N_AFTER=$(ls -A $TARGET | wc -l)"

# 回退条件：服务数掉到 0 / pm 数掉到 0 / 目标目录项数变少 / su 不在
case "$SVC1" in *"Found 0"*) SVC_BAD=1;; *) SVC_BAD=0;; esac
if [ "$SVC_BAD" = 1 ] || [ "${PM1:-0}" = 0 ] || [ "$(/system/bin/sh -c 'echo yes')" != "yes" ]; then
    echo "FRAMEWORK_FAIL ⇒ 立即 umount 回退(不把机器留在坏状态)"
    umount "$TARGET"; echo "ROLLBACK_UMOUNT_RC=$?"
    echo "SVC_ROLLED_BACK=$(service list 2>/dev/null | head -1)"
    echo "RESULT=ROLLED_BACK"
    exit 1
fi
echo "FRAMEWORK=OK"

echo "--- [4] 挂载后立刻跑同一条探针(名单应当已由 PC 侧点通) ---"
U=$(cat /data/local/tmp/w132_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
AP=$(cat /data/local/tmp/w132_apath.txt 2>/dev/null)
[ -n "$AP" ] || AP="/sbin:/system/sbin:/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin"
$CTL supath "$U" "$AP" su -c id >/data/local/tmp/w132_inmount.txt 2>&1
echo "INMOUNT_RC=$?"
sed 's/^/  /' /data/local/tmp/w132_inmount.txt
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
