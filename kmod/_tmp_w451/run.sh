TMP=${CT:-/data/local/tmp/w451/cx}
mkdir -p "$TMP"; rm -f "$TMP/ksu_nosuw"
if [ "${Z6PRE:-0}" = 1 ]; then mkdir -p "$TMP/ksu_nosuw"; fi
say(){ echo "$@"; }
pm(){ cat "$FIX"; }
# ---------- 3.6) ★免界面入口(B)：把名单那条写成**目标 app 自己**（#145 达成，第 31/32 发两发判正） ----------
#   为什么这一步必须在开关复证**之后**：上面那张清单里就有 ksu_nosuw，先删后铺才谈得上"这一跑是什么形状"。
#   ★契约（§6.365 用二进制定案，写在 stage 侧）：开关内容必须是「<uid> <包名>」两段，uid 一律现取（重装就换）；
#     取不到 ⇒ **不写这个开关** ⇒ 这一跑就是 A 形状，并且当场把"退回了"打在明面（例 116/142：默认形状不许静默换）。
say "-- 3.6) 入口形状(1=免 suw/免界面，0=带 suw/靠界面) --"
Z6TARGET_PKG=${Z6TARGET_PKG:-com.termux}
Z6B=0
Z6UID=$(pm list packages -U 2>/dev/null | grep -a "^package:$Z6TARGET_PKG uid:" | tail -1 | sed 's/.*uid://' | tr -dc '0-9')
case "$Z6UID" in '' | 0 ) Z6UID="" ;; esac
if [ -n "$Z6UID" ]; then
    printf '%s %s\n' "$Z6UID" "$Z6TARGET_PKG" > "$TMP/ksu_nosuw"
    Z6RB=$(cat "$TMP/ksu_nosuw" 2>/dev/null)
    Z6NW=$(wc -w < "$TMP/ksu_nosuw" 2>/dev/null | tr -dc '0-9')
    Z6NB=$(wc -c < "$TMP/ksu_nosuw" 2>/dev/null | tr -dc '0-9')
    if [ "$Z6RB" = "$Z6UID $Z6TARGET_PKG" ] && [ "$Z6NW" = 2 ]; then
        Z6B=1
        say "  ★免 suw 开关已铺并读回：内容=[$Z6RB] 词数=$Z6NW 字节=$Z6NB ⇒ 这一跑走 B 形状（名单只写目标 app，bind 由 stage 自己做）"
    else
        rm -f "$TMP/ksu_nosuw"
        say "  [!] 开关写了但读回不符（实得[$Z6RB] 词数=$Z6NW）⇒ 已删掉，这一跑按 A 形状走"
    fi
else
    say "  [!] 现取不到 [$Z6TARGET_PKG] 的 uid（pm list packages -U 里没有『package:$Z6TARGET_PKG uid:』这一行）⇒ **不写开关**，这一跑按 A 形状走（名单主条目=suw，靠界面点开关）"
fi
say "  入口形状=$Z6B（1=免 suw/免界面，0=带 suw）目标包=$Z6TARGET_PKG 现取 uid=${Z6UID:-<没取到>}"

# ★官方 Manager 首页的"支持/不支持"是**启动时一次性分支**，驱动 fd 晚到它也不重查 ⇒ 必须让 stage 起
#   0.4s 抢装看门狗，而那个看门狗只在这个文件存在时才起。没有它 = 用户打不开授权页 = 没有授权入口。
touch "$TMP/ksu_race_fd"
say "  抢装看门狗开关：$(ls -l "$TMP/ksu_race_fd" | tr -s ' ')"
# ★RACE 那条只活 75×0.4 秒≈30 秒，而 Manager 那一屏是**启动时一次性查询** ⇒ 30 秒之后任何一次 Manager
#   重启(用户自己关又开、系统回收、软重启)都会退回"不支持"。想把牌子拉长的那条路(常驻补装 FDKA＝往 zygote
#   种驱动 fd)**已判死，别开**——10-23 第 39/43 两发的一手读数(md §6.400)：
#     每一条 `init: Service 'zygote' (pid X) received signal 6` 里的 X **都是刚被排队补装的那个 pid**，
#     延迟 0.23~0.77 秒，两发合计 6/6 配对；而 FDKA 没开的 12 份日志里这种 abort＝0。
#     ⇒ 种下去的那个 zygote 半秒内自杀，之后 fork 的 app 什么也继承不到 ⇒ 牌子根本拉不长
#     (这就是 #168② 三次都拍不到的原因，不是"没拍到")。
#   这条循环另外还踩过一条内核洞(§6.394：给正在 do_exit 的任务排活时 current->files 已是 NULL，而
#   ksu_install_fd()→__alloc_fd() 一路没有 !files 防护)，rc73 已把护栏编进 ko；但第 43 发实测
#   `NULLFILES skip`＝0(整环覆盖到死亡前 1.8 秒，5/5 排队都配对了回调)⇒ 那条梯从用户态打不到，
#   真正在伤的是上面那条用户态 SIGABRT。
#   ⇒ 交付默认不铺这把开关。想要牌子常驻得换机制(不往 zygote 种 fd)，别 touch $TMP/ksu_fd_keepalive。
say "  常驻补装开关：默认**不铺**(§6.400 实测：种进 zygote 的驱动 fd 会让它在 0.3~0.8 秒内 SIGABRT⇒牌子拉不长；别 touch $TMP/ksu_fd_keepalive)"

BACK=$(grep -acE "不写开关|读回不符" "$LOGFILE")
echo "B=$Z6B C=[$(cat "$TMP/ksu_nosuw" 2>/dev/null)] F=$([ -e "$TMP/ksu_nosuw" ] && echo Y || echo N) BACK=$BACK"
