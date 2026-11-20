#!/system/bin/sh
# w165_adb_clean.sh —— 删掉我们在 /data/adb 里留下的脚印(名单文件 / ksud / 中间产物)。
#   为什么单独一份：这些文件 shell 身份删不动(/data/adb 是 root 0700，`ls /data/adb/modules` 就吃过 Permission denied)，
#   而 stage 被中途打断时(第六十八发：机器在判据⑥之后自己复位)它的收尾根本没机会跑 ⇒
#   名单里还留着三条 profile。没有模块时它们是"死数据"，但**它是量产机**，不该长期留着。
# ★必须在窗口内(有 root)跑；跑不到就要在日志里写明"这次没清"。
L=/data/local/tmp/w165_adb_clean.out
{
    echo "=== CLEAN up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "  清之前：$(ls -l /data/adb/ksu/.allowlist /data/adb/ksud 2>&1 | tr '\n' ' ')"
    echo "  /data/adb 目录内容：$(ls -A /data/adb 2>&1 | tr '\n' ' ')"
    rm -f /data/adb/ksu/.allowlist /data/adb/ksud 2>&1 | sed 's/^/  rm: /'
    rmdir /data/adb/ksu 2>/dev/null && echo "  rmdir /data/adb/ksu OK"
    rm -f /data/local/tmp/a_*.bin /data/local/tmp/allow.bin /data/local/tmp/ksu_two_profiles 2>&1 | sed 's/^/  rm: /'
    echo "  清之后：$(ls -l /data/adb/ksu/.allowlist /data/adb/ksud 2>&1 | tr '\n' ' ')"
    echo "  /data/adb 目录内容：$(ls -A /data/adb 2>&1 | tr '\n' ' ')"
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
