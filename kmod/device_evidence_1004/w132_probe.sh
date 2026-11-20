#!/system/bin/sh
# w132_probe.sh —— 可见性判据的**唯一合法探针**：以第三方 uid 走 PATH 找 `su` 并执行它。
#
# ★为什么不能用 ksuctl 的老 `su` 动词(第二十二发的教训，md §6.124②)：
#   那个动词写死 execve("/system/bin/su")，而我们 ko 的 execve 钩子(bit1)是在**路径解析之前**
#   改道的 ⇒ 文件根本不存在时它照样出 uid=0(root)。拿它当可见性判据 = 假阳性。
#   第二十二发 (a′) 那格"挂载前必须失败"就是这么废的：同一份回执里既有
#   `ls: /system/bin/su: No such file` 又有 `uid=0(root)`。
#
# supath 只做：fork → 降到 <uid> → setenv(PATH) → execvp("su")。不碰 ioctl、不碰驱动 fd、
# 不改任何标位 ⇒ PATH 里没有就是 errno=2，这才是"文件在不在"。
#
# 给 root 侧跑(@sushd:)。同一条命令在"挂载前 / 挂载后 / 撤名单后"各跑一次 ⇒ 唯一变量是
# 文件在不在、名单在不在。
L=${OUT:-/data/local/tmp/w132_probe.out}
CTL=/data/local/tmp/ksuctl87
U=$(cat /data/local/tmp/w132_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
# A11 标准 base PATH(init.rc 导出的那份，zygote 与 app 都从它继承)
AP=$(cat /data/local/tmp/w132_apath.txt 2>/dev/null)
[ -n "$AP" ] || AP="/sbin:/system/sbin:/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin"
{
    echo "=== probe up=$(cut -d' ' -f1 /proc/uptime) target_uid=$U ==="
    echo "TARGET_SU=$(ls -l /product/bin/su 2>&1)"
    echo "AGENT_PID=[$(pidof shd)]  (空 ⇒ 静态 su 一定拿不到 fd，这一发不算)"
    echo "GRANT_STATE=$(grep -a 'SETPROF' /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt 2>/dev/null | tail -1 | cut -c1-90)"
    echo "--- 探针本体：execvp(\"su\", {su,-c,id}) ---"
    $CTL supath "$U" "$AP" su -c id 2>&1
    echo "PROBE_RC=$?"
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
