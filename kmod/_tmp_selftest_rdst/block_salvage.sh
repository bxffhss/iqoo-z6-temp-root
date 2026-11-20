# ★§6.307：dmesg.live 是唯一能判"从没打印"的全量件，而它每发开头就被下面这行删掉
#   ⇒ 145/147 那一发的装载期现场已经永久丢了。改法：上一发若还留着，先改名存档、不删。
PREV=$(A "wc -c < /data/local/tmp/dmesg.live 2>/dev/null" | tr -dc '0-9')
if [ -n "${PREV:-}" ] && [ "$PREV" != "0" ]; then
    TAG=$(A "date +%m%d-%H%M" | tr -dc '0-9-')
    A "mv -f /data/local/tmp/dmesg.live /data/local/tmp/dmesg.live.prev_$TAG" >/dev/null
    echo "  ★上一发的 dmesg.live($PREV 字节)没删，改名为 /data/local/tmp/dmesg.live.prev_$TAG ⇒ pull 清单里带上它，存完再删"
fi
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/dmesg.live" >/dev/null
