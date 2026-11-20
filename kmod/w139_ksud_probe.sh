#!/system/bin/sh
# w139_ksud_probe.sh —— 官方 v3.3.0 的独立 ksud 能不能在我们这份晚加载 ko 上跑起来、
#   能不能装模块。（第 34 发已证：Manager 调 `libksud.so debug su` 时被 app 域 seccomp 用
#   SIGSYS 打死在 syscall 142=reboot；而**我们 root 侧跑 reboot(142) 是通的**，所以换 root 侧试。）
#
# 一手依据(strings 抽出来的)：ksud 自带 **late-load** 模式
#   `( late-load --post-magica --package-name ` / `post_magic` / `skip_svc` / `persist_only`
#   `.backup/.magisk` / `init.magisk.rc` / `overlay/init.magisk.rc`
#   ⇒ "内核模块在开机之后才加载"正是官方 ksud 支持的场景。
#   特性名：su_compat / kernel_umount / sulog / adb_root / selinux_hide / webview_zygote_umount
#   提权口名：root_execve / sucompat / ioctl_grant_root
#
# ★两条雷照旧不碰：`ksud sepolicy patch|apply`(本机必硬复位)、`rmmod`。
L=${OUT:-/data/local/tmp/w139_ksud.out}
# ★文件名必须避开 `ksud`：push_ksu.sh 会把**我们自己的 shim** 推成 /data/local/tmp/ksud
#   （第 35 发就是这么把官方 ksud 换成 shim 还跑完了一整份回执，差点当成"官方 ksud 跑不动"）。
K=/data/local/tmp/ksud_official
NEED_MD5=9cc94ff59388b09dd6d4097d25a1f83b
ZIP=/sdcard/Download/LSPosed-2.2.0.zip
# ★timeout 必须小：ksuctl 的 sushd 有 KSU_SUSHD_DEADLINE=100 秒的时限，整条脚本超时会腰斩。
T() { timeout 12 "$@" 2>&1; echo "  rc=$?"; }
{
echo "===== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ====="
chmod 755 "$K" 2>/dev/null
GOT=$(md5sum $K 2>/dev/null | awk '{print $1}')
echo "KSUD_MD5=$GOT  大小=$(stat -c %s $K 2>/dev/null)  (要求 $NEED_MD5)"
[ "$GOT" = "$NEED_MD5" ] || { echo "ARTIFACT_WRONG ⇒ 停手，这一发不算(别把 shim 当官方 ksud)"; exit 1; }
echo "ARTIFACT_OK"
echo "CTX=$(cat /proc/self/attr/current)  SECCOMP=$(awk '/^Seccomp:/{print $2}' /proc/self/status)"
echo "MOD=$(grep -c kernelsu /proc/modules)  ENFORCE=$(cat /sys/fs/selinux/enforce)"

echo "--- [0] 能不能拿到驱动 fd(这是成败前提) ---"
echo "  本进程 fd 里的 ksu 驱动: $(ls -l /proc/self/fd 2>/dev/null | grep -ac ksu_driver)"
echo "  触发口: $(ls -l /proc/ksu_install_fd 2>&1 | tail -1)"

echo "--- [1] ksud 的权威 CLI(无参数 → usage) ---"
$K
echo "  rc=$?"
echo "--- [1b] ksud --help ---"
T $K --help

echo "--- [2] 它眼里的内核状态 ---"
echo "  [ksud module ls]"; T $K module ls
echo "  [feature check su_compat]"; T $K feature check su_compat
echo "  [feature check kernel_umount]"; T $K feature check kernel_umount

echo "--- [3] 造目录后试装模块 ---"
mkdir -p /data/adb/modules /data/adb/ksu/bin /data/adb/service.d 2>/dev/null
echo "  zip 在不在: $(ls -l $ZIP 2>&1 | tail -1)"
echo "  [ksud module install]"; T $K module install "$ZIP"
echo "  装完之后 /data/adb/modules:"; ls -l /data/adb/modules 2>&1 | head -8

echo "--- [4] late-load / post-magic 这条路(strings 里见过) ---"
echo "  [ksud late-load --help]"; T $K late-load --help
echo "  (post-fs-data 故意不跑：它会真做 magic mount，超时预算也不够)"

echo "--- [5] 挂载现状(模块生效的唯一硬判据) ---"
grep -a " /data/adb/modules\|magic" /proc/self/mountinfo | cut -c1-140 | head -8
echo "MOUNTINFO_ABOVE"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
