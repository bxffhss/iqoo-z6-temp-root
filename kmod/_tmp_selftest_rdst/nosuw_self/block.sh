# ★★§6.361/#145 的仪器开关 `NOSUW`（**默认关**：设备侧文件不在 ⇒ 名单形状与第 29 发逐字相同）：
#   ★§6.365 之后契约改了一处：**条目不是"官方 Manager 自己"**（那条被三个独立二进制证人判成设计上无效——
#     名单闸里对 manager 恒真、名单读数里对 manager 恒隐、它的 root profile 走 use_default、装载循环对它零特判），
#     而是**开关文件里那一个目标 app**：文件内容＝`<uid> <包名>` 两段，由 go.sh §1.69b 开枪前 `pk_uid` 现取后写入并两端复证。
#   ★形状不对(词数≠2／uid 不是纯数字／包名带非法字符) ⇒ **不改形状**、本发按交付形状算，并打一条 [!] —— 绝不猜一个 uid 进名单。
MGRPKG=me.weishu.kernelsu
ENT_UID=$SUWID
ENT_KEY=$APKEY
NOSUW=0
if [ -e /data/local/tmp/ksu_nosuw ]; then
    NSW=$(cat /data/local/tmp/ksu_nosuw 2>/dev/null | tr -d '\r' | head -1)
    NW=$(printf '%s' "$NSW" | wc -w | tr -dc '0-9')
    NU=$(printf '%s' "$NSW" | cut -d' ' -f1)
    NP=$(printf '%s' "$NSW" | cut -d' ' -f2)
    case "$NU" in '' | 0 | *[!0-9]* ) NU=0 ;; esac
    case "$NP" in '' | *[!a-z0-9._-]* ) NP="" ;; esac
    if [ "${NW:-0}" != 2 ] || [ "$NU" = 0 ] || [ -z "$NP" ]; then
        log "  [!] NOSUW 开关文件形状不对(现读=[$NSW] 词数=$NW uid=[$NU] 包名=[$NP]) ⇒ **不改形状**，本发按交付形状算(格 N1 没测到)"
    else
        NOSUW=1
        ENT_UID=$NU
        ENT_KEY=$NP
    fi
    log "  ★NOSUW 开关读回=$(ls -l /data/local/tmp/ksu_nosuw 2>&1 | tail -1) 内容=[$NSW] ⇒ 生效=$NOSUW"
fi
