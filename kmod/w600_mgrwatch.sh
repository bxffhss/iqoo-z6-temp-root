#!/system/bin/sh
# w600_mgrwatch.sh —— **常驻**版"只盯官方 Manager 补装驱动 fd"的看门狗(§6.405 那一发的被测件)。
#   跟 w161_fdwatch.sh 的差别只有三点，都是这一发要的：
#     ①**没有 400 次上限** ⇒ 跑过抢装窗口之后还在盯(这才叫"常驻到硬重启前")；
#     ②**每轮读回证人**：`/proc/<pid>/fd` 里 `ksu_driver` 的个数 ⇒ "装没装上"不靠牌子猜；
#     ③**开关文件就是 kill switch**(删掉⇒循环自己退，不用 pkill、不留孤儿)⇒ 同一 boot 内做得出反对照。
#   ★两条硬护栏(§6.394 源码层证成／#239 一手)：只写 **cmdline 逐字含包名且不含 zygote** 的 pid
#     ⇒ 拒掉"zygote 刚 fork 还没改名"的瞬时子进程，也**永不**把 zygote/system_server 交给触发口
#     (§6.400 那 0.23~0.77 秒 SIGABRT 的正是种 zygote 那一半)；连续 30 轮读不到 fd ⇒ 明写 GIVEUP 并 rc=3 退出。
#   W600_* 那组变量是给离线自检用的(w602)，默认值就是真机形状；FAKE_FD/FAKE_PORT 不落地也能测出行为。
PKG=me.weishu.kernelsu
SW=${W600_SW:-/data/local/tmp/ksu_mgr_watch}
L=${W600_L:-/data/local/tmp/w600_mgrwatch.log}
PIDF=${W600_PIDF:-/data/local/tmp/w600_mgrwatch.pid}
LIMIT=${W600_LIMIT:-0}          # 0=常驻；>0 只给离线自检用
FAKE_FD=${W600_FAKE_FD:-}       # 设了就用这个固定 fd 数，不去读 /proc
FAKE_PID=${W600_FAKE_PID:-}     # 设了就不 pidof，直接当"看到的 Manager pid"

mgr_guard_ok() {  # $1=cmdline 文本；返回 0=允许写触发口
    case "$1" in
        *zygote*) return 1 ;;
        *"$PKG"*) return 0 ;;
        *) return 1 ;;
    esac
}

# ===== 自检入口(离线，两壳都能跑：bash 与设备 mksh) =====
if [ "${1:-}" = selfcheck ]; then
    n=0
    for c in "me.weishu.kernelsu" "$PKG --magica" "zygote64 me.weishu.kernelsu" "app_process / com.x" "" "me.weishu."; do
        mgr_guard_ok "$c"; echo "  guard[$c] rc=$?"
    done
    echo "  期望：前两条 rc=0(收)，后四条 rc=1(拒：含 zygote／不含包名／空／前缀不够)"
    case "$(mgr_guard_ok 'zygote64 me.weishu.kernelsu'; echo $?)" in 1) n=$((n+1));; esac
    case "$(mgr_guard_ok 'app_process x'; echo $?)" in 1) n=$((n+1));; esac
    case "$(mgr_guard_ok "$PKG"; echo $?)" in 0) n=$((n+1));; esac
    echo "SELF 断言数=$n(满 3 才算三条形状都对)"
    [ "$n" = 3 ] || { echo "SELF FAIL"; exit 1; }
    echo "SELF PASS"; exit 0
fi

echo $$ > "$PIDF"; chmod 666 "$PIDF" "$SW" 2>/dev/null
: > "$L" 2>/dev/null; chmod 666 "$L" 2>/dev/null
{
    echo "=== MGRWATCH 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) 开关=$SW 触发口=$(ls /proc/ksu_install_fd 2>&1 | tail -1) ==="
} >> "$L"
LAST=""; FAINTR=0; i=0; installs=0
while [ -e "$SW" ]; do
    i=$((i + 1))
    U=$(cut -d' ' -f1 /proc/uptime)
    if [ -n "$FAKE_PID" ]; then P="$FAKE_PID"; else
        P=$(pidof "$PKG" 2>/dev/null | cut -d' ' -f1)
    fi
    case "$P" in '' | *[!0-9]*) P="" ;; esac
    if [ -n "$P" ]; then
        if [ -n "$FAKE_FD" ]; then CL="$PKG"; else CL=$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null); fi
        if ! mgr_guard_ok "$CL"; then
            echo "$U 守卫拒 pid=$P cmdline=[$CL] ⇒ 绝不写触发口" >> "$L"; P=""
        fi
    fi
    if [ -n "$P" ]; then
        if [ -n "$FAKE_FD" ]; then N="$FAKE_FD"; else
            N=$(ls -l "/proc/$P/fd" 2>/dev/null | grep -ac ksu_driver)
        fi
        if [ "$P" != "$LAST" ]; then
            if [ -n "$FAKE_FD" ]; then echo "$U [FAKE] 本该 echo $P > /proc/ksu_install_fd" >> "$L"; else
                echo "$P" > /proc/ksu_install_fd 2>>"$L" || echo "$U 写触发口失败 pid=$P" >> "$L"
            fi
            installs=$((installs + 1)); LAST="$P"; FAINTR=0
            echo "$U 已排队新 pid=$P(第 $installs 次)当时 fd数=$N" >> "$L"
        elif [ "${N:-0}" = "0" ]; then
            FAINTR=$((FAINTR + 1))
            [ "$FAINTR" = 1 ] && echo "$U pid=$P 还见不到 ksu_driver ⇒ 再排一次" >> "$L"
            [ -n "$FAKE_FD" ] || echo "$P" > /proc/ksu_install_fd 2>>"$L"
            if [ "$FAINTR" -ge 30 ]; then
                echo "$U ★GIVEUP pid=$P 连续 30 轮读不到 fd ⇒ 不再假装守护(退 3)" >> "$L"; chmod 666 "$L"; exit 3
            fi
        else
            [ "$FAINTR" != 0 ] && { echo "$U pid=$P 现在见到 ksu_driver fd=$N(补装生效,此前连败 $FAINTR 轮)" >> "$L"; FAINTR=0; }
        fi
    fi
    [ "$LIMIT" != 0 ] && [ "$i" -ge "$LIMIT" ] && break
    sleep 1
done
{
    echo "=== MGRWATCH 停 up=$(cut -d' ' -f1 /proc/uptime) 共 $i 轮 installs=$installs 开关还在=$([ -e "$SW" ] && echo Y || echo N) ==="
    rm -f "$PIDF"
} >> "$L"
chmod 666 "$L"
