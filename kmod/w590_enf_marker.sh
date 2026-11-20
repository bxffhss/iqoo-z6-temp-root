#!/system/bin/sh
# w590_enf_marker.sh —— #164 的**属主判据**载荷：由 app 侧敲 `/system/bin/su -c /data/local/tmp/w590_enf_marker.sh`(单个 token ⇒ 避开 #208 的 `sh -c` 只吃第一个词)。
# ★主判据押在**这个新文件的属主**上，不押屏幕、也不押 .out 能不能被 adb 读到：
#   uid=0      ⇒ su 真的将 cred 换成了 root(提权成立)
#   uid=10667  ⇒ 没提权(被拒或改道没生效)
#   属主这一件事由 **PC 侧无 root 的 `stat`** 独立读回 ⇒ 证人不需要 root 腿(恢复执法之后 root 腿关门也能读)。
# 同一发里 Permissive 与 Enforcing 各敲一次 ⇒ A 臂天然是**正对照**(判别式必须会动，否则 B 臂的"没提权"不算数)。
M=/data/local/tmp/w590_enf_marker
L=/data/local/tmp/w590_enf.out
{
    echo "=== W590 up=$(cut -d' ' -f1 /proc/uptime) ==="
    echo "  mac=$(getenforce 2>&1) enforce_file=$(cat /sys/fs/selinux/enforce 2>&1)"
    id
    echo "  self_attr=$(cat /proc/self/attr/current 2>&1)"
    echo "  ppid_cmd=$(cat /proc/$PPID/cmdline 2>&1 | tr '\0' ' ')"
    echo "  fd_ksu=$(ls -l /proc/self/fd 2>&1 | grep -c ksu_driver)"
    rm -f "$M" 2>&1
    touch "$M" 2>&1
    echo "  marker_touch_rc=$?"
    ls -lZ "$M" 2>&1
} > "$L" 2>&1
chmod 666 "$L" 2>&1
chmod 666 "$M" 2>&1
{
    echo "  SELFSTAT=$(ls -l "$M" 2>&1)"
    echo "===== DONE uid=$(id -u)"
} >> "$L" 2>&1
