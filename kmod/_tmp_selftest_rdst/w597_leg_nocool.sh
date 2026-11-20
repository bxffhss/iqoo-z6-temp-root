#!/system/bin/sh
# w625_seedrestart.sh —— **不重 punch** 把 Manager 首页那块牌子刷回来的腿(root 侧跑；10-23 第 49 发 §6.407 **判正**，现已随 z6root 包发货)。
#   为什么要"重启一次"：§6.406 一手——官方 Manager 首页是**进程启动时一次性查询**，
#   fd 晚到刷不亮(实测：fd 已在表里、只把它顶回前台 ⇒ 仍 `不支持`)。
#   ⇒ 所以形状＝`force-stop` → 起来后**用极短节拍**(0.1s，第 48 发输在 1s 节拍上)盯到新 pid 就立刻写触发口，
#      让 fd 早于它自己的那次查询；一轮不中就再来一轮，最多 ROUNDS 轮。
#   ★护栏照抄 w600：只写 **cmdline 逐字含包名且不含 zygote** 的 pid；永不碰 zygote/system_server。
#   ★有界：ROUNDS 是**最多试几轮**(默认 6)，本轮 fd 一到位就收工；不常驻、不留孤儿。
#   ★分工：这条腿只保证"fd 抢在那次查询之前写进去"，**牌子亮没亮要另外读**——PC 侧用 `kmod/w603_home_cell.sh`(焦点断言＋无障碍树)，
#     用户/包内形状就直接看管理器首页；读数自己判：腿会打 `SR-ROUND r=… pid=… fd=…`(fd 到位) 或"2.5s 内没见着 fd"。
#     没亮就再调一次本腿(每次调用＝一次重启尝试)⇒ 全过程每步都有独立读数，不靠脚本自己下结论。
#   ★第 49 发一手：4 次调用**全部第 1 轮**命中(腿内部 0.34 秒)，恢复后不碰它 5.5 分钟仍 `工作中`；反向两格(无生产者重启)都退回 `不支持`。
# ★★10-24 #180 新增两道**硬闸**(一手＝§6.409 用户实测：牌子约 0.5 分钟退、他连着重复执行这条腿 ⇒ 手机硬复位，token=PS_HOLD)：
#   ①冷却 COOL 秒(默认 150)内不再做 force-stop；②本 boot 最多调用 MAXRUNS 次(默认 6)，超了就只报状态不动进程。
#   为什么不能靠"人看见暗了再敲"：这条腿每次调用最坏 fork ≈90 次(等 pid 40 拍 + 读 fd 25 拍×2)再叠两次 `am`，
#   那就是 §6.198 那一族"root 壳 fork-exec 风暴"的形状；而它亮的时长(≈30s)天然比人的反应快 ⇒ 只会越敲越密。
#   ★还有一格短路：如果**当前活着的 Manager 就是上次这条腿种过 fd 的那个 pid**、fd 也还在它的表里 ⇒ 直接收工(SR-ALREADY)，
#     因为"那个进程活着牌子就亮"(§6.407)，再 force-stop 一次只会把一个亮着的牌子敲成暗的、逼出下一次调用。
#   闸的凭据落在 /data/local/tmp/w625_lock(0644，shell 也读得到 ⇒ "为什么被拒"有独立证人，不用重跑)。
#   ★两把闸都可以显式松开(给我自己的测量腿用，包里的命令永远走默认)：位置参数 3=COOL 秒、4=MAXRUNS 次，
#     例如 PC 侧一发内要连打三次就喂 `6 0.1 0 999`。默认值是交付形状，不由环境变量决定(根壳里带不出 env)。
#   ★测量用另有 `/data/local/tmp/w625_nogate` 这个标记文件：`su -c` 只吃第一个词(例 167)⇒ 派单那条路带不进位置参数，
#     而"腿被自己的闸拒了"和"腿坏了"长得一模一样(例 168 那一族)。有这个标记就把两把闸松成 0/无限并打 `SR-NOGATE`，
#     读数里留痕。包里**没有**任何生产者铺它，收尾件把它和锁文件一起删(它是脚印，不是工具)。
# ★这条腿在交付形状里是**从 root 壳里跑的**(`/system/bin/su -c <本件>`)，而那层的 PATH 不含 /system/bin 全套
#   (一手：root 壳里 `getenforce`/`umount` 都找不到) ⇒ 自己不补齐 PATH 的话，`am`/`pidof` 直接 127，
#   症状会长得跟"牌子恢复不了"一模一样。放在最前面，块内所有外部件都靠它解析。
PATH=/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH
export PATH
PKG=me.weishu.kernelsu
ROUNDS=${1:-6}
STEP=${2:-0.1}
COOL=${3:-150}
MAXRUNS=${4:-6}
NG=/data/local/tmp/w625_nogate
NOGATE=0
if [ -e "$NG" ]; then NOGATE=1; COOL=0; MAXRUNS=999999; fi
L=/data/local/tmp/w625_seedrestart.out
LOCK=/data/local/tmp/w625_lock
PORT=/proc/ksu_install_fd
{
    echo "=== SR 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) rounds=$ROUNDS step=$STEP cool=$COOL maxruns=$MAXRUNS SR-NOGATE=$NOGATE ==="
    if [ ! -e "$PORT" ]; then echo "  !! 触发口不在 ⇒ 这一发什么都刷不亮，直接退(不算负结论)"; echo "===== DONE NO-PORT"; exit 5; fi
    # ★清场(例 167：先查被测对象此刻有没有**别的生产者**)：w161 那条 0.4s 看门狗要是还活着，
    #   它自己就能抢赢 ⇒ "牌子亮了"根本不能算 w625 的功劳。只认 pid 文件，不用 pgrep -f(会朝自己开枪)。
    for PF in /data/local/tmp/w161_fdwatch.pid /data/local/tmp/w600_mgrwatch.pid; do
        if [ -f "$PF" ]; then
            OLD=$(tr -dc '0-9' < "$PF")
            case "$OLD" in '' | *[!0-9]*) OLD="" ;; esac
            if [ -n "$OLD" ] && [ -d "/proc/$OLD" ]; then
                CL2=$(tr '\0' ' ' < "/proc/$OLD/cmdline" 2>/dev/null)
                kill -9 "$OLD" 2>/dev/null
                echo "  清场: 杀掉 $PF 记的 pid=$OLD(rc=$?) cmdline=[$CL2] 之后还在=$([ -d "/proc/$OLD" ] && echo 是 || echo 否)"
            else
                echo "  清场: $PF 里没有活进程(值=[$OLD])"
            fi
        else
            echo "  清场: $PF 不存在(本来就没有别的生产者)"
        fi
    done
    # ---------- ★#180 两道硬闸(冷却 + 每-boot 预算) + 一格"已在位就别动它" ----------
    #   节拍只用 /proc/uptime 的整秒：单调、跨 boot 归零。设备钟会 NTP 步进(10-14 实测一发内 +31s→+57s)，
    #   拿它算冷却会自己造出"还差很多/早就过了"两种假读数 ⇒ 不用。
    NOW=$(cut -d'.' -f1 /proc/uptime); NOW=${NOW:-0}
    LAST=0; RUNS=0; LPID=""
    if [ -f "$LOCK" ]; then
        LAST=$(grep -a '^coolup=' "$LOCK" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
        RUNS=$(grep -a '^runs=' "$LOCK" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
        LPID=$(grep -a '^pid=' "$LOCK" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
    fi
    LAST=${LAST:-0}; RUNS=${RUNS:-0}
    MP=$(pidof "$PKG" 2>/dev/null | cut -d' ' -f1)
    case "$MP" in '' | *[!0-9]*) MP="" ;; esac
    MN=0
    [ -n "$MP" ] && MN=$(ls -l "/proc/$MP/fd" 2>/dev/null | grep -ac ksu_driver)
    echo "  闸读数: now=${NOW}s 锁内 coolup=$LAST runs=$RUNS/max=$MAXRUNS 锁内pid=$LPID 当前pid=${MP:-无} 其ksu_driver条目=${MN:-0} 锁文件=$([ -f "$LOCK" ] && echo 在 || echo 不在)"
    if [ "$NOW" -lt "$LAST" ]; then
        echo "  uptime 往回走($LAST→$NOW)⇒ 这是新 boot ⇒ runs 归零"
        RUNS=0; LAST=0
    fi
    if [ "$RUNS" -ge "$MAXRUNS" ]; then
        echo "  !! 本 boot 已调用 $RUNS 次(每次=真做过一回 force-stop)，到预算($MAXRUNS)⇒ **这一次不做 force-stop、不写触发口**。"
        echo "     原因不是保守：§6.409 一手就是这个动作连着敲之后硬复位的(PS_HOLD)。要继续就把手机整机重启后重跑 z6root。"
        echo "  SR-BUDGET runs=$RUNS max=$MAXRUNS pid=${MP:-0} fd=${MN:-0}"
        echo "===== DONE 拒绝-预算 up=$NOW"
        exit 0
    fi
    if [ -n "$MP" ] && [ "$MP" = "$LPID" ] && [ "${MN:-0}" != "0" ]; then
        echo "  ★当前活着的 Manager 就是上次这条腿种过 fd 的那个 pid，fd 也还在它表里 ⇒ **不动任何进程**，直接收工。"
        echo "     §6.407：那个进程活着牌子就一直亮。若首页看着是暗的，先把它切到前台看一眼；"
        echo "     真被系统换掉了(pid 变了)再敲同一条命令(过了冷却才算一次)。"
        echo "  SR-ALREADY pid=$MP fd=$MN coolup=$LAST now=$NOW"
        echo "===== DONE 已在位 up=$NOW"
        exit 0
    fi
    if [ "$LAST" -gt 0 ]; then
        LEFT=$((NOW - LAST)); [ "$LEFT" -lt 0 ] && LEFT=0
        if [ "$LEFT" -lt "$COOL" ]; then
            WAIT=$((COOL - LEFT))
            echo "  !! 距上次它真的重启过管理器只过了 ${LEFT}s，冷却要 ${COOL}s ⇒ **这一次不做 force-stop、不写触发口**(还差 ${WAIT}s)。"
            echo "     这期间 root 本身没坏：/system/bin/su -c id 照样出 uid=0(root)；暗的只是那一屏。"
            echo "===== DONE 拒绝-冷却 up=$NOW"
            exit 0
        fi
    fi
    r=0
    while [ "$r" -lt "$ROUNDS" ]; do
        r=$((r + 1))
        am force-stop "$PKG" >/dev/null 2>&1
        am start -n "$PKG/.ui.MainActivity" >/dev/null 2>&1
        t=0; P=""
        while [ "$t" -lt 40 ]; do            # 最多 ~4s 等新 pid 出现(0.1s 一拍)
            P=$(pidof "$PKG" 2>/dev/null | cut -d' ' -f1)
            case "$P" in '' | *[!0-9]*) P="" ;; esac
            [ -n "$P" ] && break
            sleep "$STEP"; t=$((t + 1))
        done
        if [ -z "$P" ]; then echo "  第 $r 轮：没等到 pid ⇒ 下一轮"; continue; fi
        CL=$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null)
        case "$CL" in
            *zygote*) echo "  第 $r 轮 守卫拒 pid=$P cmdline=[$CL]"; continue ;;
            *"$PKG"*) : ;;
            *) echo "  第 $r 轮 守卫拒 pid=$P cmdline=[$CL]"; continue ;;
        esac
        # ★这一行以前写成 `… >> "$L"`，而整块本身就是 `> "$L" 2>&1` ⇒ 同一个文件两个写者(块的 fd 会把它盖掉)，
        #   第 49 发实测"已写 pid=…(等了 N 拍)"那行真的没了，只剩 SR-ROUND ⇒ 一律改用块的标准输出。
        echo "$P" > "$PORT" && echo "  第 $r 轮 up=$(cut -d' ' -f1 /proc/uptime) 已写 pid=$P(等了 $t 拍)"
        # ★锁在这一刻就落(不等 fd)：闸拦的是"这次 force-stop 风暴"，它已经发生了；
        #   写完立刻读回，"冷却凭什么"这条才有独立证人(否则只有内存里的变量，事后无从核对)。
        printf 'coolup=%s\nruns=%s\npid=%s\n' "$NOW" "$((RUNS + 1))" "$P" > "$LOCK"
        chmod 644 "$LOCK" 2>/dev/null
        k=0
        while [ "$k" -lt 25 ]; do           # 读回：fd 到位就停(最多 ~2.5s)
            N=$(ls -l "/proc/$P/fd" 2>/dev/null | grep -ac ksu_driver)
            [ "${N:-0}" != "0" ] && { echo "    第 $r 轮 fd 到位(第 $k 拍)N=$N ⇒ 该轮成功"; break; }
            sleep "$STEP"; k=$((k + 1))
        done
        [ "${N:-0}" = "0" ] && echo "    第 $r 轮 2.5s 内没见着 fd(回调没跑?目标被冻?)⇒ 下一轮"
        echo "  SR-ROUND r=$r pid=$P fd=${N:-0}"
        break   # 本轮 fd 已到位就收工：牌子亮没亮由 PC 侧读，不亮就再调一次本腿
    done
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) 用了 $r 轮"
} > "$L" 2>&1
chmod 666 "$L"
