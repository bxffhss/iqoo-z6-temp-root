#!/system/bin/sh
# w377_su_probe.sh —— 第 134 发(Cell Z)的行为半格：**装载时写进 `.allowlist` 的第二个 uid 能不能真拿到 root**。
#   三判据 + 正/负对照(用户规矩)：
#     [A] 对照正例 uid=10319(com.suw.manager，交付一直有的那条) ⇒ 期望 uid=0(root)
#     [B] 本格    uid=10667(com.termux，**这一发的第二条记录**，来自磁盘文件而非运行时授权) ⇒ 期望 uid=0(root)
#     [C] 负对照  uid=10817(com.termux.api，**不在名单里**) ⇒ 期望被拒(不能出 uid=0)
#   ★只走 `su` 动词=写死 execve("/system/bin/su")(§6.124②：它**不能**当"文件可见性"判据)——
#     本发问的不是可见性，是"内核按 uid 放不放行"，所以用它正合适；可见性另有一支 supath(设备上没 ksuctl87 ⇒ 这发不做)。
CTL=/data/local/tmp/ksuctl86
[ -x "$CTL" ] || CTL=/data/local/tmp/ksuctl88
L=/data/local/tmp/w377_su_probe.out
{
    echo "===== w377 su probe up=$(cut -d' ' -f1 /proc/uptime) ====="
    echo "CTL=$CTL  shd=[$(pidof shd)]  mod=$(lsmod 2>/dev/null | grep -ci kernelsu)  enf=$(cat /sys/fs/selinux/enforce)"
    echo "uid 现值: $(pm list packages -U 2>/dev/null | grep -aE 'com.suw.manager|com.termux$|com.termux.api' | tr '\n' ' ')"
    for SPEC in "A_对照正例_10319 10319" "B_本格_10667 10667" "C_负对照_10817 10817"; do
        NAME=$(echo "$SPEC" | cut -d' ' -f1); U=$(echo "$SPEC" | cut -d' ' -f2)
        echo "--- [$NAME] uid=$U 走 /system/bin/su -c id ---"
        OUT=$("$CTL" su "$U" "/system/bin/su -c id" 2>&1); RC=$?
        echo "rc=$RC out=$(echo "$OUT" | tr '\n' '|' | cut -c1-220)"
    done
    echo "===== 结束 up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L" 2>/dev/null
