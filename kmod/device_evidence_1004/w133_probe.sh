#!/system/bin/sh
# w133_probe.sh —— **钩子插不进来**的可见性探针（第 23 发的教训之后重做）。
#
# 第 22/23 发两次都被同一个机制骗：execvp("su") 会按 PATH **逐个试 execve**，
# 而我们 ko 的 execve 钩子匹配的是**字符串** "/system/bin/su" —— 它在 /product/bin 那一项落空之后
# 命中 /system/bin 那一项并改道 ⇒ **文件根本不存在也照样出 root**。
# ⇒ 只要 PATH 里有 /system/bin，这条探针测的就是"钩子行不行"，不是"文件在不在"。
#
# 修法：PATH 只给 **/product/bin** 一项。于是
#   errno=2      ⇒ 文件不在（唯一解释）
#   uid=0(root)  ⇒ 文件在 **且** 内核名单放行
#   not-allowed  ⇒ 文件在 **但** 内核名单没放行   ← 这才是"撤名单"的负对照
# 三态互斥，判据才立得住。
L=${OUT:-/data/local/tmp/w133_probe.out}
CTL=/data/local/tmp/ksuctl87
U=$(cat /data/local/tmp/w132_tuid.txt 2>/dev/null); [ -n "$U" ] || U=10667
TGT=$(cat /data/local/tmp/w133_tgt.txt 2>/dev/null); [ -n "$TGT" ] || TGT=/product/bin
{
    echo "=== probe up=$(cut -d' ' -f1 /proc/uptime) uid=$U tgt=$TGT ==="
    echo "AGENT_PID=[$(pidof shd)]"
    echo "GRANT=$(grep -a SETPROF /sdcard/Android/data/com.suw.manager/files/ksu_grant.txt 2>/dev/null | tail -1 | cut -c1-95)"
    echo "--- A) 以目标 uid 看这个文件(存在性 + DAC，不经过钩子) ---"
    $CTL supath "$U" "/system/bin" ls -l "$TGT/su" 2>&1 | grep -aE "SUPATH|ls:|su$"
    echo "--- B) 钩子进不来的 PATH 查找：PATH=$TGT 只有一项 ---"
    $CTL supath "$U" "$TGT" su -c /system/bin/id 2>&1 | grep -aE "SUPATH|uid=|SHIM|not-allowed|拒绝|errno"
    echo "--- C) 对照：app 真实 PATH(含 /system/bin) ⇒ 无论文件在不在都会被钩子接住 ---"
    $CTL supath "$U" "/sbin:/system/sbin:/product/bin:/system_ext/bin:/system/bin:/vendor/bin" su -c /system/bin/id 2>&1 | grep -aE "SUPATH-EXECVP|uid=0|errno=2"
    echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
