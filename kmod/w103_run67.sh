#!/system/bin/sh
# 第二个来源/第二个对象的触发器：给 uid 10667(非 Manager 的被授权 app)跑 su，
# 看它的 SELinux 域会不会跟 Manager(10319 走 default_root_profile，域解不出 u:r:ksu:s0)不一样。
L=/data/local/tmp/w103_run67.out
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) 对象 uid=10667 ==="
    # ★单词版：上一发这里塞的是 `id; cat /proc/self/status | grep ...; cat attr/current` 这种多语句，
    #   结果只有 SHIM-ESC 两行回来、命令本身没输出 ⇒ 先排除"是我自己的引号/管道的错"。
    /data/local/tmp/ksuctl86 su 10667 id
    echo "rc=$?"
} >"$L" 2>&1
chmod 666 "$L"
