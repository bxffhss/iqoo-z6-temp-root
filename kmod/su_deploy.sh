#!/system/bin/sh
# su_deploy.sh —— 社区 su 路线的最后一格：让普通 app 在 PATH 里找到 /system/bin/su
#
# 背景（2026-11-09 实测边界，dmesg 逐条对过 fs/overlayfs/super.c）：
#   · KernelSU 正常安装时是 ksud 在开机 post-fs-data 往 /system/bin "加"一个 su；
#     我们这条 LKM 路线是**开机后**才 insmod，ksud 那一段早过了 ⇒ /system/bin/su 从来没有过。
#   · 往 ro 的 /system 里加文件只能挂 overlay。本机 overlay 能用的 upper 只有一种：
#       f2fs  ✗  ovl_dentry_weird() 拒（super.c:ovl_mount_dir_noesc）
#       tmpfs ✗  CONFIG_TMPFS_XATTR 未开 ⇒ 无 security xattr，SELinux 挂不上（EOPNOTSUPP）
#       ext4  ✓  镜像 + loop（Magisk 同款）；CONFIG_BLK_DEV_LOOP / EXT4_FS_SECURITY / mke2fs 本机都有
#   · **只增不删**：lower 仍是 erofs 的 /system/bin，只是多一个 su。
#     回退＝`umount /system/bin`；重启也自动清（窗口态，不落盘）。
#
# 用法：root 下执行；幂等（已部署就只报"已在位"）。
#   开关：/data/local/tmp/ksu_su_deploy 存在，或 SU_DEPLOY=1
# 返回：0＝已就位；1＝失败（lower 未被破坏）
SRC=${SU_SRC:-/data/local/tmp/ksu_su}
IMG=${SU_IMG:-/data/local/tmp/ovl_ext4.img}
MNT=${SU_MNT:-/data/local/tmp/ovl_ext4_mnt}
LOGF=${SU_LOGF:-/data/local/tmp/ksu_su_deploy.log}
: > "$LOGF"
say() { echo "[$(date +%H:%M:%S)] $*" >>"$LOGF"; }

say "=== su_deploy 起 uid=$(id -u) up=$(cut -d' ' -f1 /proc/uptime) enforce=$(getenforce) ==="

if [ -x /system/bin/su ]; then
    say "已在位：$(ls -l /system/bin/su | tr -s ' ') ⇒ 无事可做"
    exit 0
fi
if [ ! -x "$SRC" ]; then
    say "! 源 $SRC 不存在或不可执行 ⇒ 放弃"
    exit 1
fi

mkdir -p "$MNT" || { say "! mkdir $MNT 失败"; exit 1; }

# 1) ext4 镜像（64 MB 够放几百个 su）
if [ ! -f "$IMG" ]; then
    dd if=/dev/zero of="$IMG" bs=1048576 count=64 >>"$LOGF" 2>&1 || { say "! dd 失败"; exit 1; }
    mke2fs -t ext4 -F -q "$IMG" >>"$LOGF" 2>&1 || { say "! mke2fs 失败"; exit 1; }
    say "镜像就绪 $(ls -l "$IMG" | tr -s ' ')"
fi

# 2) loop
LOOP=$(losetup -j "$IMG" 2>/dev/null | cut -d: -f1 | head -1)
if [ -z "$LOOP" ]; then
    LOOP=$(losetup -f 2>/dev/null)
    if [ -z "$LOOP" ]; then say "! 无空闲 loop"; exit 1; fi
    losetup "$LOOP" "$IMG" >>"$LOGF" 2>&1 || { say "! losetup 失败"; exit 1; }
fi
say "loop=$LOOP"

# 3) 挂 ext4
if ! grep -q " $MNT " /proc/mounts; then
    mount -t ext4 -o rw,noatime "$LOOP" "$MNT" >>"$LOGF" 2>&1 || { say "! mount ext4 失败"; exit 1; }
fi
mkdir -p "$MNT/upper" "$MNT/work" 2>>"$LOGF"
cp "$SRC" "$MNT/upper/su" || { say "! cp su 失败"; exit 1; }
chown 0:0 "$MNT/upper/su" 2>>"$LOGF"
chmod 0755 "$MNT/upper/su" 2>>"$LOGF"
if command -v chcon >/dev/null 2>&1; then
    chcon u:object_r:system_file:s0 "$MNT/upper/su" 2>>"$LOGF"
fi
say "upper: $(ls -l "$MNT/upper/su" 2>&1 | tr -s ' ')"

# 4) 挂 overlay（只加不减）
if ! grep -q " /system/bin " /proc/mounts; then
    mount -t overlay overlay -o "lowerdir=/system/bin,upperdir=$MNT/upper,workdir=$MNT/work" /system/bin >>"$LOGF" 2>&1
    MRC=$?
    if [ $MRC -ne 0 ]; then
        say "! overlay 挂载失败 rc=$MRC（lower 未动，可继续用旧路径）"
        exit 1
    fi
    say "overlay 已挂"
fi

# 5) 验证：只增不删 —— lower 里的基础件必须都还在
if [ -x /system/bin/su ] && [ -x /system/bin/sh ] && [ -x /system/bin/id ]; then
    say "OK su=$(ls -l /system/bin/su | tr -s ' ') which=[$(command -v su)]"
    exit 0
fi
say "! 挂后 /system/bin 结构异常 ⇒ 立刻回退 overlay"
umount /system/bin >>"$LOGF" 2>&1
say "回退 rc=$?"
exit 1
