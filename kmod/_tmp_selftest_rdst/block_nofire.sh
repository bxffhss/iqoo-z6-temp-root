fire() {
    # ★§6.312 格 W 专用：`NOFIRE=1` ⇒ **只 force-stop、不发扳机**（那三处 fire() 的 `am start --es auto ksuarm`
    #   正是 suw 自动化 execve 的来源＝148/151 里"suw 动手"的真相是我的腿在扳它）。默认关＝交付链一字不变。
    if [ -n "${NOFIRE:-}" ]; then
        A "am force-stop $SUW" >/dev/null; sleep 1
        echo "  ★NOFIRE=$NOFIRE ⇒ 跳过 am start(扳机)；读回 pidof $SUW=[$(A "pidof $SUW" | tr -d '\r' | tr -s ' ')]"
        return 0
    fi
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
