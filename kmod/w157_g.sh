#!/system/bin/sh
# w157_g.sh —— 内核侧独立读数：官方 Manager 的那次授权，到底有没有真写进 ko 的名单?
#   与"截图上开关绿了"是两个来源：这份读的是 ko 自己的答复(`ksuctl granted <uid>` / `mgr` / `info`)。
# ★uid 从文件里读，不用 sed 往脚本里塞：上一版就是 `sed -i s/__TGT__/10667/g` **没生效**，
#   于是 `ksuctl granted __TGT__` 被解析成 **uid=0** 打回 `granted=0` ——
#   一个非数字参数静默变成"root 的授权状态"，看着完全像一条真结论(记忆例33 那一族的新变体)。
#   ⇒ 现在：读不到 3~6 位纯数字就**明打 bad-uid 并拒绝问**。
L=/data/local/tmp/w157_g.out
{
    echo "=== G up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) ==="
    T=$(cat /data/local/tmp/w157_tgt.uid 2>/dev/null | tr -dc '0-9')
    case "$T" in
      [0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
      *) T="" ;;
    esac
    echo "  目标 uid=[$T](空=读不到，下面不会去问 ksuctl)"
    for c in /data/local/tmp/ksuctl87 /data/local/tmp/ksuctl; do
        if [ -x "$c" ]; then
            echo "用 $c:"
            "$c" mgr 2>&1 | grep -a GET_MANAGER_APPID | cut -c1-140
            if [ -n "$T" ]; then
                "$c" granted "$T" 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-140
            else
                echo "  bad-uid ⇒ granted 这一格按没测到算"
            fi
            break
        fi
        echo "  (没有可执行的 $c)"
    done
    echo "=== DONE ==="
} >"$L" 2>&1
chmod 666 "$L"
