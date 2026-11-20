    # FDKA-BEGIN  ← 自测(run_fdkeepalive.sh)抽这一段字节来跑，不许在两处各写一份(例 120 同族)
    # ★10-22 20:4x 一手缺陷(第 38 发真机凭据抓出来的，md §6.391)：这台机上 `pidof zygote64` **不唯一**——
    #   zygote 刚 fork、还没改名的子进程也叫 `zygote64`，而 pidof 的输出顺序是 /proc 的 readdir 序(不是 pid 大小)。
    #   原来取第一个 ⇒ 种子可能落在瞬时子进程上，真 zygote 反而没刷(日志里 `INST Z` 的 pid 一路变就是这个)。
    #   唯一判据：**真 zygote 的父亲是 init(ppid=1)**；那些瞬时子进程的父亲是 zygote 自己。
    #   兜底：一个 ppid=1 都没有 ⇒ 退回第一个数字候选，但**明打 FALLBACK**(只打一次)，不静默当没事。
    #   注：`cut -f4` 取 ppid 的前提是 comm 里没有空格(实测真 zygote 的 comm=`main`)。
    #   ★定义必须在 `fd_keepalive_loop` **外面**：起循环前的"当场种一次"也要用它，而函数体只在被调用时才展开。
    pick_zygote() {
        Q0=""; QN=0
        for Q in $(pidof "$1" 2>/dev/null); do
            case "$Q" in ''|*[!0-9]*) continue ;; esac
            QN=$((QN + 1)); [ -n "$Q0" ] || Q0="$Q"
            if [ "$(cut -d' ' -f4 "${PRCK:-/proc}/$Q/stat" 2>/dev/null | tr -dc '0-9')" = 1 ]; then echo "$Q"; return 0; fi
        done
        [ -n "$Q0" ] || return 1
        [ "${FBL:-0}" = 0 ] && { echo "FDKA ZG_FALLBACK pid=$Q0 候选数=$QN 没有一个 ppid=1" >> "${LOGK:-/dev/null}"; FBL=1; }
        echo "$Q0"; return 0
    }
    fd_keepalive_loop() {
        SWK="$1"; TRK="$2"; ZK="$3"; MK="$4"; IVK="${5:-5}"; FMAXK="${6:-24}"; LOGK="$7"; PRCK="${8:-/proc}"
        LZK=0; LMK=0; FK=0; NK=0; FBL=0
        echo "FDKA START up=$(cut -d' ' -f1 /proc/uptime) interval=${IVK}s pid=$$ switch=$(ls $SWK 2>&1 | tail -1)" >> "$LOGK"
        while : ; do
            NK=$((NK + 1))
            [ -e "$SWK" ] || { echo "FDKA STOP 开关没了(第 $NK 轮) ⇒ 自己退出" >> "$LOGK"; return 0; }
            ZP2=$(pick_zygote "$ZK")
            MP2=$(pidof "$MK" 2>/dev/null | cut -d' ' -f1)
            case "$ZP2" in ''|*[!0-9]*) ;; *)
                if [ "$ZP2" != "$LZK" ]; then
                    if echo "$ZP2" > "$TRK" 2>/dev/null; then
                        echo "FDKA INST Z pid=$ZP2 第 $NK 轮 up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOGK"; LZK="$ZP2"; FK=0
                    else
                        FK=$((FK + 1)); echo "FDKA WRITEFAIL Z pid=$ZP2 连续失败=$FK" >> "$LOGK"
                    fi
                fi ;;
            esac
            case "$MP2" in ''|*[!0-9]*) ;; *)
                if [ "$MP2" != "$LMK" ]; then
                    if echo "$MP2" > "$TRK" 2>/dev/null; then
                        echo "FDKA INST M pid=$MP2 第 $NK 轮 up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOGK"; LMK="$MP2"; FK=0
                    else
                        FK=$((FK + 1)); echo "FDKA WRITEFAIL M pid=$MP2 连续失败=$FK" >> "$LOGK"
                    fi
                fi ;;
            esac
            [ "$FK" -ge "$FMAXK" ] && { echo "FDKA GIVEUP 连续 $FK 次写不进 ⇒ 触发口/ko 可能没了，退出" >> "$LOGK"; return 3; }
            sleep "$IVK"
        done
    }
    # FDKA-END
fd_keepalive_loop "kmod/_tmp_selftest_rdst/.fdk_work/sw" "kmod/_tmp_selftest_rdst/.fdk_work/trig" zygote64 me.weishu.kernelsu 1 "3" "kmod/_tmp_selftest_rdst/.fdk_work/log" "kmod/_tmp_selftest_rdst/.fdk_work/proc"
exit $?
