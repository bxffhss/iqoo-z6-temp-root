#!/system/bin/sh
# 给 @sushd: 用的"无空格"命令：守护把 cmd 按空格切词，带参数会被截断(窗口 100 一手：
#   `cmd=[/data/local/tmp/ksuctl]` —— 后面 `granted 10667` 整个没了，exit=2 打的是 usage)。
# 所以要把"内核侧第二个来源"跑起来，就把它写成一个脚本，cmd 只留一个 token。
# ★同一个脚本可以在"加白名单前后"各调一次：变的是内核状态，不是脚本内容。
L=/data/local/tmp/w100_g.out
# uid 从文件里取(.cmd 只能给一个 token，参数没法跟在后面)
TUID=$(cat /data/local/tmp/w100_tuid.txt 2>/dev/null)
[ -n "$TUID" ] || TUID=10667
{
    echo "--- up=$(cut -d' ' -f1 /proc/uptime) 目标 uid=$TUID ---"
    /data/local/tmp/ksuctl granted $TUID
    /data/local/tmp/ksuctl granted 10319
    /data/local/tmp/ksuctl allowlist 2>&1 | head -6
} >"$L" 2>&1
chmod 666 "$L"
