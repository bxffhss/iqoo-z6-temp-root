#!/system/bin/sh
# w164_al.sh —— root 侧读"名单里有几条、都是谁"，并顺手确认王座没被两条目名单冲掉。
#   为什么单独一份：`ls /proc/<app>/fd` 这类读数 shell 身份拿不到(§6.154 的误判就是这么来的)，
#   名单/王座必须用 ksuctl88 在 root 通道里问内核。
L=/data/local/tmp/w164_al.out
CTL=/data/local/tmp/ksuctl88
{
    echo "=== AL up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) ==="
    [ -x "$CTL" ] || { echo "  !! 没有 $CTL"; echo "===== DONE"; exit 0; }
    echo "  名单文件: $(ls -l /data/adb/ksu/.allowlist 2>&1 | tail -1)"
    "$CTL" allowlist 2>&1 | grep -aE "NEW_GET_ALLOW_LIST|allow\[" | head -10 | cut -c1-120 | sed 's/^/  /'
    "$CTL" mgr 2>&1 | grep -a GET_MANAGER_APPID | cut -c1-140 | sed 's/^/  /'
    for f in /data/local/tmp/w164_u1.uid /data/local/tmp/w164_u2.uid; do
        T=$(cat "$f" 2>/dev/null | tr -dc '0-9')
        case "$T" in
          [0-9][0-9][0-9] | [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
          *) echo "  $f: bad-uid ⇒ 这一格按没测到算"; continue ;;
        esac
        echo "  $( "$CTL" granted "$T" 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-120 )"
    done
    echo "  内核自己读名单的那几行(dmesg.live)："
    grep -aE "load_allow_uid|allowlist version|invalid app_profile" /data/local/tmp/dmesg.live 2>/dev/null | tail -6 | cut -c1-150 | sed 's/^/    /'
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
