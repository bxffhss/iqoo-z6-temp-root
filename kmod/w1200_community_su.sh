#!/system/bin/sh
# w1200_community_su.sh —— §6.582 社区 su 判据（**在 rc78 + ksu_hook_mask=0x1a 的窗口里跑**，由 @sushd 以 root 起手）
#
# 要证的形状（三条正向 + 两条负向，全部"文件真的不存在"前提下成立）：
#   ① /system/bin/su **不存在**（lower erofs 读，ls 必须 No such file）——证明下面那些不是静态文件给的
#   ② 授权 uid 的 access()/stat() 看得见 su：`[ -x /system/bin/su ]` → 真；`ls -l /system/bin/su` → 打出 ksud 的 mode/size
#      （＝faccessat(48) / newfstatat(79) 两个钩子在改道；只开 bit1 的旧形状下这两条必为假）
#   ③ 授权 uid 的 `su -c id` → uid=0
#   负向：未授权 uid 2000 上同样三条必须**全假**（否则是把 allowlist 那道门拆了，不是伪装）
#
# ★为什么用 asuid 而不是 `su`：asuid 从 root 起手、setuid 到目标 uid 后 exec，绕开"谁来当第一个 su"这个鸡生蛋问题；
#   它的输出本身不是判据（§6.580：10342/10667 那两组已经判过），这一发只看 sucompat 的伪装面。
OUT=/data/local/tmp/w1200_community_su.out
exec >"$OUT" 2>&1
echo "===== w1200 社区 su 判据 $(date) ====="
echo "up=$(cut -d' ' -f1 /proc/uptime)  id=$(id)"
echo "mod=[$(grep -i kernelsu /proc/modules | tr -s ' ')]"
echo "enf=$(getenforce)  hookmask=[$(cat /sys/module/kernelsu/parameters/ksu_hook_mask 2>/dev/null)]"
echo "--- ① /system/bin/su 必须不存在（这是本发的前提，false 则整段作废）---"
ls -l /system/bin/su 2>&1
echo "  exists=$([ -e /system/bin/su ] && echo YES || echo NO)"
echo "--- overlay 也必须是 0（静态 su 那条已废弃）---"
mount | grep -c ' /system/bin ' | sed 's/^/  overlay_on_system_bin=/'
echo
for U in 10667 10342 2000; do
    if [ "$U" = "2000" ]; then TAG="NEG(未授权 shell)"; else TAG="POS(已授权)"; fi
    echo "===== uid=$U  $TAG ====="
    asuid "$U" /system/bin/sh -c '
        echo "  id=[$(id)]"
        if [ -x /system/bin/su ]; then echo "  ②access([-x /system/bin/su])=OK"; else echo "  ②access([-x /system/bin/su])=FAIL"; fi
        if [ -f /system/bin/su ]; then echo "  ②stat([-f])=OK"; else echo "  ②stat([-f])=FAIL"; fi
        echo "  ②ls -l /system/bin/su → [$(ls -l /system/bin/su 2>&1)]"
        echo "  ②which su → [$(which su 2>&1)]"
        echo "  ③su -c id → [$(su -c id 2>&1)] rc=$?"
    ' 2>&1
    echo
done
echo "===== 判据（人工照抄，脚本不自判） ====="
echo "  正：10667/10342 → access=OK、stat=OK、ls 打出 ksud、which=/system/bin/su、su -c id 出 uid=0(root)"
echo "  负：2000 → access=FAIL、stat=FAIL、which 空、su 报 not found（且 /system/bin/su 仍不存在）"
echo "===== DONE ====="
chmod 666 "$OUT" 2>/dev/null
