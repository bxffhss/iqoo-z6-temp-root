#!/system/bin/sh
# b8_setup.sh —— 开窗前铺两个开关文件（用**现取 uid**，不写死）。
#   为什么要它：①`ksu_two_profiles` 决定「名单里除了 suw 还追加谁」，内容必须是 `uid:包名` 且 uid 要现取
#   （卸载重装就换号，写死必错）；②`ksa_uids.txt` 是 stage 取 SUWID/MGRID 的唯一来源，收窗件会把它删掉，
#   所以每次开窗前得重新生成——少了它 stage 的名单会写空。
#   跑法（adb shell 或手机上任意 shell 宿主）：sh /sdcard/z6root/b8_setup.sh
#   产物：/data/local/tmp/ksu_two_profiles 、/data/local/tmp/ksa_uids.txt 、回执 /data/local/tmp/b8_setup.out
OUT=/data/local/tmp/b8_setup.out
uid_of() {
    pm list packages -U 2>/dev/null | sed -n "s/^package:$1 uid:\([0-9][0-9]*\).*/\1/p" | head -1
}
{
    echo "=== b8_setup $(date +%H:%M:%S) ==="
    SUW=$(uid_of com.suw.manager)
    MGR=$(uid_of me.weishu.kernelsu)
    S1=$(uid_of com.omarea.vtools)
    S2=$(uid_of com.wn.app.np)
    S3=$(uid_of me.piebridge.brevent)
    S4=$(uid_of com.termux)
    echo "suw=$SUW mgr=$MGR scene=$S1 np=$S2 brevent=$S3 termux=$S4"

    case "$SUW" in ''|*[!0-9]*) echo "[x] 取不到 com.suw.manager 的 uid ⇒ 停：它是名单主条目，没有它 root 腿就没有"; exit 3 ;; esac
    case "$MGR" in ''|*[!0-9]*) echo "[x] 取不到 me.weishu.kernelsu 的 uid ⇒ 停：名单里必须有官方 Manager"; exit 3 ;; esac

    printf '%s %s\n' "$SUW" "$MGR" > /data/local/tmp/ksa_uids.txt

    SPEC="$MGR:me.weishu.kernelsu"
    MISS=""
    NADD=0
    case "$S1" in ''|*[!0-9]*) MISS="$MISS Scene(com.omarea.vtools)" ;; *) SPEC="$SPEC $S1:com.omarea.vtools"; NADD=$((NADD+1)) ;; esac
    case "$S2" in ''|*[!0-9]*) MISS="$MISS NP(com.wn.app.np)" ;; *) SPEC="$SPEC $S2:com.wn.app.np"; NADD=$((NADD+1)) ;; esac
    case "$S3" in ''|*[!0-9]*) MISS="$MISS 黑域(me.piebridge.brevent)" ;; *) SPEC="$SPEC $S3:me.piebridge.brevent"; NADD=$((NADD+1)) ;; esac
    case "$S4" in ''|*[!0-9]*) MISS="$MISS Termux(com.termux)" ;; *) SPEC="$SPEC $S4:com.termux"; NADD=$((NADD+1)) ;; esac
    printf '%s' "$SPEC" > /data/local/tmp/ksu_two_profiles
    # ★缺失不许静默：没装的 app 就是名单里少一条，窗口照开、但那几个 app 用不了 root。
    #   （"静默降级"是这套东西最容易骗人的失败形态之一，所以要在这里喊出来。）
    if [ -n "$MISS" ]; then
        echo "[!] 没装 / 取不到 uid ⇒ 这几个**不进名单**（窗口照开，其余照用）：$MISS"
    fi
    echo "[i] ksu_two_profiles 里 $((NADD+1)) 条（官方 Manager 1 条 + 目标 app $NADD 条），加上 suw 主条目共 $((NADD+2)) 条"
    # ★让 stage 在装载完自己把常驻补装拉起来（省掉"每次开窗要记得手敲一条 am start"这一步，
    #   漏了就会被误判成"这套东西不稳"）。stage 侧只在有这个开关且 b8_keep.sh 可执行时才起。
    : > /data/local/tmp/ksu_keep_auto
    chmod 666 /data/local/tmp/ksu_keep_auto 2>/dev/null

    echo "--- ksa_uids.txt ---"; cat /data/local/tmp/ksa_uids.txt
    echo "--- ksu_two_profiles ---"; cat /data/local/tmp/ksu_two_profiles; echo
    echo "--- ksu_keep_auto ---"; ls -l /data/local/tmp/ksu_keep_auto 2>&1
    echo "--- 读回复证 ---"
    echo "ksa_uids 字节=$(wc -c < /data/local/tmp/ksa_uids.txt)  two_profiles 字节=$(wc -c < /data/local/tmp/ksu_two_profiles)"
    echo "DONE"
} > "$OUT" 2>&1
cat "$OUT"
