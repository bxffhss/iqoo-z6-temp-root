#!/system/bin/sh
# w131_mount_su.sh —— 把静态 su 变成 **/system/bin/su 这个真文件**，让所有 app 的 PATH 都能看见它。
#
# 配方来自酷安 Z5 分享包(scripts/z5_setup.txt)：`mount --bind <副本目录> /system/bin`。
# 它正好修掉我们自己 §6.116~§6.122 两次翻车的原因：
#   翻车① 只做了符号链接农场 ⇒ /vendor/bin/* 是指向 /system/bin 的符号链接，盖上去之后它们全断；
#   翻车② 盖住的目录里没有 linker64 ⇒ /system/bin/sh 自己都 exec 不动 ⇒ adb/重启都要物理长按。
# 这里的做法是**先把 /system/bin 整份复制**再盖，所以 sh / linker64 / 那 499 项一个都不少。
# 先试 overlay(只加一个 su，零复制、零遮蔽)，失败再退回"全量复制 + bind"。
#
# 授权仍然只在内核里：这里的 su 是我们自己的静态 su(连 @suwshd，agent 问内核 UID_GRANTED_ROOT)。
# 跑之前 agent(shd) 必须已经以 root 起好并装上驱动 fd —— stage v61 那一段负责。
#
# 给 root 侧跑。判据全部 ASCII 标签，方便 PC 侧 grep。

L=${OUT:-/data/local/tmp/w131_mount.out}
CTL=/data/local/tmp/ksuctl86
SUB=/data/local/tmp/subin      # overlay 的额外下层：只放 su
NB=/data/local/tmp/newbin      # bind 的下层：/system/bin 的全量副本
SRC=/data/local/tmp/sustatic   # 静态 su 本体

{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="

echo "--- [0] 前置：装之前 /system/bin/su 必须不存在(这是负对照的地基) ---"
if [ -e /system/bin/su ]; then echo "PRE_STATE=PRESENT !! 已经有 su，这一发的负对照不成立"; else echo "PRE_STATE=ABSENT"; fi
echo "SRC_MD5=$(md5sum $SRC 2>&1 | awk '{print $1}')"
echo "SRC_HEAD=$(head -c 20 $SRC | od -An -tx1 | tr -d ' \n')"
echo "  (第 17-18 字节应是 0200=ET_EXEC；能不能跑由后面'实跑得动'判，不在这里猜)"

echo "--- [1] 准备 su 所在目录 ---"
rm -rf "$SUB"; mkdir -p "$SUB" || echo "MKDIR_SUB_FAIL"
cp $SRC "$SUB/su" && echo "CP_SUB_OK" || echo "CP_SUB_FAIL"
chmod 755 "$SUB" "$SUB/su"
ls -lZ "$SUB" 2>&1 | tail -2

echo "--- [2] 试 overlay(不复制、只叠加) ---"
mount -t overlay overlay -o lowerdir="$SUB":/system/bin /system/bin
OVRC=$?
if [ $OVRC -eq 0 ]; then
    echo "MOUNT_KIND=overlay OVRC=0"
else
    echo "OVERLAY_FAIL OVRC=$OVRC ⇒ 退回全量复制 + bind"
    rm -rf "$NB"; mkdir -p "$NB"
    echo "  开始 cp -a /system/bin/. (约 51MB / 499 项)"
    cp -a /system/bin/. "$NB/" 2>/dev/null
    echo "  cp 完 NB 里=$(ls -A $NB | wc -l) 项 (期望 >= 499)"
    cp $SRC "$NB/su" && echo "CP_NB_OK" || echo "CP_NB_FAIL"
    chmod 755 "$NB" "$NB/su"
    mount --bind "$NB" /system/bin
    BRC=$?
    echo "MOUNT_KIND=bind BRC=$BRC"
    [ $BRC -ne 0 ] && echo "MOUNT_ALL_FAIL"
fi

echo "--- [3] 挂载后：/system/bin 上到底挂着什么(会不会被别的 tmpfs 盖掉，§6.116 的坑) ---"
grep -a ' /system/bin ' /proc/self/mountinfo
echo "MOUNTINFO_ABOVE"

echo "--- [4] 安全判据：盖上去之后 sh 还跑得动吗 / 目录还在不在(这两条不过就别走开) ---"
SH_ALIVE=$(/system/bin/sh -c 'echo yes' 2>&1)
echo "SH_ALIVE=$SH_ALIVE"
BIN_COUNT=$(ls /system/bin 2>/dev/null | wc -l)
echo "BIN_COUNT=$BIN_COUNT"
LINKER=$(/system/bin/toybox test -e /system/bin/linker64 && echo PRESENT || echo MISSING)
echo "LINKER=$LINKER"
VENDOR_SH=$(/vendor/bin/sh -c 'echo yes' 2>&1)
echo "VENDOR_SH=$VENDOR_SH"
echo "LS_THROUGH=$(/system/bin/ls /system/bin/su 2>&1)"

# ★自动回退：这三条任何一条不过，说明我们把 /system/bin 弄坏了 —— 立刻 umount，
#   否则 adb shell / adb reboot 都会失效(§6.116 那次就是靠物理长按电源才救回来)。
if [ "$SH_ALIVE" != "yes" ] || [ "$LINKER" != "PRESENT" ] || [ "$BIN_COUNT" -lt 400 ]; then
    echo "SAINTY_FAIL ⇒ 立即 umount 回退"
    umount /system/bin; echo "UMOUNT_RC=$?"
    echo "AFTER_ROLLBACK_SH=$(/system/bin/sh -c 'echo yes' 2>&1)"
    echo "RESULT=ROLLED_BACK"
    echo "===== DONE(rolled back) up=$(cut -d' ' -f1 /proc/uptime) ====="
    exit 1
fi
echo "SAINTY=OK"

echo "--- [5] 正判据：/system/bin/su 现在是个真文件，任何 app 的 PATH 都能命中它 ---"
ls -l /system/bin/su 2>&1
echo "SU_PRESENT=$([ -x /system/bin/su ] && echo YES || echo NO)"

echo "--- [6] 以 Termux 的 uid 走 PATH 找 su(不是写全路径)，看它能不能变 root ---"
U=${TUID:-10667}
echo "$U" > /data/local/tmp/w131_tuid.txt   # 后面的独立探针脚本从这里取 uid，不靠环境变量传
echo "  名单状态由 PC 侧控制；这里只跑一次并留回执(权威判据是 app 域那条 @suprobe:)"
$CTL su "$U" "id" >/data/local/tmp/w131_asuid.txt 2>&1
echo "ASUID_RC=$?"
sed 's/^/  /' /data/local/tmp/w131_asuid.txt

echo "--- [7] 收尾办法(窗口内) ---"
echo "  umount /system/bin   # 或干脆重启；重启一定干净"
echo "  rm -rf $SUB $NB"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
