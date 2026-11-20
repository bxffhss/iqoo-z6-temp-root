#!/usr/bin/env bash
# w810_window_watch.sh —— 第 56 发的**空窗采样器**：全程只用 adb shell 的**只读**命令。
#   ★为什么必须"只读＋不派腿"：这一发要测的就是"没人碰它的时候，窗口会不会自己断"。
#     任何 root 腿／UI 动作都会把归因污染掉（第 55 发正是这样：死前 ring 里 96% 是我们 ko 自己打的，
#     而 root sh 的 execve 以 ~31 次/秒 在跑）。所以这发**先量寿命，再补别的格**。
#   ★三个硬计数（都不需要 root）：
#     ①`/proc/stat` 的 `processes` ＝累计 fork 数 ⇒ 增量/秒＝**fork 风暴**（记忆那条：shell 侧就有独立于 root 的进程活动信道）；
#     ②`dmesg2.log` 里我们 ko 那行 `fired#N` 的**末值** ⇒ 增量/秒＝**我们 sys_enter 回调的触发速率**（被动成本）；
#     ③`logcat -b crash` 的**增量** ⇒ 谁在反复崩（判"Manager 起 root 服务→libksud.so 被 seccomp 打死→重启"这条链）。
#   ★10-25 第 58 发前加三键（用户问"vr 反复开枪＋我们一直挡 ⇒ 是不是费电"，答它要靠数不靠推理）：
#     ④`CPUT`＝`/proc/stat` 的 cpu 行原样（user/nice/**sys**/idle/iow/irq/**softirq**）⇒ 两次采样的差＝
#       **"机器这段时间真烧了多少 CPU"**，kprobe/tracepoint 陷入都记在 sys+irq 里。★这是"耗电"的正牌代理：
#       `/sys/class/power_supply/battery/*` 对 shell 是 **Permission denied**(一手)，而 `dumpsys battery` 的
#       `level` 一小时才动 1 格 ⇒ 45 分钟的窗里它**量不到东西**，只留 `level/voltage` 当旁证。
#     ⑤`SOFT`/`SOFTP`＝`KILLSOFT: 已把第 N 次 SIGKILL 改成 SIGCONT` 与 `KILLSOFT: 放行 N 次` 的末值
#       ⇒ **vr 到底开了几枪**就数这个（★别再拿 rc30/31 那两串 199,777/324,577 当"开枪数"——那是
#       vr **通用间接出口**被路过的次数，且 rc32 起那条根本不注册探针；一手勘误在 md §6.435）。
#     ⑥`LVL`＝`dumpsys battery` 的 level/voltage（旁证，见④的理由）。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

MIN=${1:-36}
STEP=${2:-60}
TAG=${3:-shot56}
EV=kmod/w103_evidence/shot56
CSV=$EV/w810_${TAG}.csv
mkdir -p "$EV"

A() { timeout 25 adb shell "$1" 2>/dev/null | tr -d '\r'; }

: > "$CSV"
# ★★表头与正文必须**同处产生**：smoke4 一手——这份表头是上一版留下的，里面多一个 `last_sd1`(正文只有
#   tail_sd1/tail_sysenter 两个计数)，而首列名 `up` 盖住的其实是 `epoch` ⇒ 名与值**错开一整列**。
#   旧产物 `w810_shot56.csv` 也带着这个错位，事后按列名读它会把 up 当 epoch、epoch 当 up。
echo "epoch,up,enforce,mod,fork_processes,ctxt,mgr_pid,fired,tail_sd1,tail_sysenter,keeper_lines,keeper_last,crash_lines,killssoft,killssoft_pass,cpu_ticks,batt,note" >> "$CSV"
echo "=== w810 起 标签=$TAG 计划=${MIN}分 间隔=${STEP}秒 产物=$CSV ==="

END=$(( $(date +%s) + MIN * 60 ))
GONE=0; ROUND=0; BOOT_SEEN=""
while [ "$(date +%s)" -lt "$END" ]; do
    ROUND=$((ROUND + 1))
    UP=$(A "cut -d' ' -f1 /proc/uptime")
    if [ -z "$UP" ]; then
        GONE=$((GONE + 1))
        echo "  轮$ROUND up=[无读数] ⇒ **adb 掉了**(记为事件，第 $GONE 次)"
        # 列数必须与表头一致(19 列，含首列 epoch)——少写逗号会让整份 CSV 错位，那是仪器自己造的假读数
        echo "$(date +%s),GONE,,,,,,,,,,,,,,,,,${NOTE:-}" >> "$CSV"
        sleep "$STEP"; continue
    fi
    # 复位检测：uptime 倒退
    NOTE=""
    if [ -n "$BOOT_SEEN" ]; then
        INT=$(printf '%s' "$UP" | cut -d. -f1)
        PRE=$(printf '%s' "$BOOT_SEEN" | cut -d. -f1)
        [ "${INT:-999999}" -lt "${PRE:-0}" ] && NOTE="★uptime 倒退 ⇒ 本 boot 已复位(新 up=$UP)"
    fi
    BOOT_SEEN="$UP"
    ENF=$(A "cat /sys/fs/selinux/enforce")
    MOD=$(A "grep -c kernelsu /proc/modules")
    ST=$(A "grep -aE '^process(es)? ' /proc/stat; grep -a '^ctxt ' /proc/stat" | tr '\n' ' ')
    FORK=$(printf '%s' "$ST" | grep -aoE 'process(es)? +[0-9]+' | grep -aoE '[0-9]+' | head -1)
    CTXT=$(printf '%s' "$ST" | grep -aoE 'ctxt +[0-9]+' | grep -aoE '[0-9]+' | head -1)
    MGR=$(A "pidof me.weishu.kernelsu" | cut -d' ' -f1)
    FIRED=$(A "tail -c 200000 /data/local/tmp/dmesg2.log 2>/dev/null | grep -ao 'fired#[0-9]*' | tail -1" | grep -ao '[0-9]*')
    T=$(A "tail -c 200000 /data/local/tmp/dmesg2.log 2>/dev/null")
    SD1=$(printf '%s' "$T" | grep -ac 'SD1 decline')
    SYE=$(printf '%s' "$T" | grep -ac 'KSUBEAT F sys_enter')
    KL=$(A "grep -ac . /data/local/tmp/w774_keeper.log 2>/dev/null")
    KLAST=$(A "tail -1 /data/local/tmp/w774_keeper.log 2>/dev/null | cut -c1-58")
    CR=$(A "logcat -b crash -d -t 2000 2>/dev/null | grep -ac 'Fatal signal'")
    # ★⑤vr 到底开了几枪：只有 `KILLSOFT` 那两个末值才是答案(改信号＝真开枪；放行＝不是那一处)。
    #   ★别再把 rc30/31 那两串 199,777/324,577 读成"开枪次数"——那是 vr **通用间接出口**被路过的条数，
    #   且 rc32 起那条探针根本不注册(见 md §6.435)。
    SOFT=$(A "grep -a 'KILLSOFT: 已把第' /data/local/tmp/dmesg2.log 2>/dev/null | tail -1" | grep -aoE '第 [0-9]+ 次' | grep -aoE '[0-9]+')
    SOFTP=$(A "grep -a 'KILLSOFT: 放行' /data/local/tmp/dmesg2.log 2>/dev/null | tail -1" | grep -aoE '放行 [0-9]+ 次' | grep -aoE '[0-9]+')
    # ★④CPU 记账＝"这台机器这段时间真烧了多少"的正牌代理(单位＝USER_HZ 节拍)。
    #   ★别用 `tr ' ' '#'`＋`sed 's/##*//g'`：那会把数字**挤成一坨**(smoke 一手：cpu140478232091…)⇒ 用 -s 压缩成逗号。
    #   ★★落 CSV 时必须**加引号**：这一格自带 10 个逗号，不加引号 18 列会变 27 列(smoke3 一手)，事后没法按列读。
    CPUT=$(A "grep -a '^cpu ' /proc/stat" | tr -s ' ' ',' | sed 's/^cpu,//;s/,$//')
    # ★⑥电量只当旁证：battery sysfs 对 shell 是 Permission denied，dumpsys 的 level 一小时才动一格
    #   ★过滤在**本机**做(上一版把 grep 塞进远端再 tr -d ' \n'，结果连 `Max charging voltage` 一起粘成一坨)
    BATT=$(A "dumpsys battery 2>/dev/null" | grep -aoE '^[[:space:]]*(level|voltage|current_max|status):[[:space:]]*[0-9]+' | tr -d ' ' | tr '\n' ';')
    # ★★跨 boot 残留闸(smoke 一手抓到两次)：dmesg2.log/keeper.log 都是**固定文件名的旧件**，本次开机没开窗时
    #   它们照样读出"fired=286141157、keeper=144"这种**上一 boot 的末值** ⇒ 不加这道闸就是把旧账当现值。
    #   ★★算必须**全在设备侧**：第一版我用本机 `date +%s` 减设备 uptime 再比设备 mtime ⇒ 两把钟差 30~60 秒
    #     (记忆里那条"同一 boot 内都会漂")把闸**静默判成"本次开机的"**(smoke2 一手：mtime=1792916174 而设备
    #     开机点=1792916206，本该报 STALE 却没报)。⇒ 现在设备内自算，单引号防本机展开。
    STALE=$(A 'e=$(date +%s); u=$(cut -d" " -f1 /proc/uptime | cut -d. -f1); b=$((e-u));
for f in /data/local/tmp/dmesg2.log /data/local/tmp/w774_keeper.log; do
  m=$(stat -c %Y "$f" 2>/dev/null)
  if [ -z "$m" ]; then echo "无件:$(basename "$f")"; elif [ "$m" -lt "$b" ]; then echo "STALE:$(basename "$f")(mtime=$m<开机点=$b)"; fi
done' | tr '\n' '|')
    [ -n "$NOTE" ] && STALE="${STALE:+$STALE|}$NOTE"
    echo "$(date +%s),${UP},${ENF:-?},${MOD:-?},${FORK:-?},${CTXT:-?},${MGR:-无},${FIRED:-?},${SD1:-?},${SYE:-?},${KL:-?},\"${KLAST}\",${CR:-?},${SOFT:-?},${SOFTP:-?},\"${CPUT:-?}\",\"${BATT:-?}\",${STALE}" >> "$CSV"
    echo "  轮$ROUND up=$UP enf=${ENF:-?} mod=${MOD:-?} fork=${FORK:-?} mgr=${MGR:-无} fired=${FIRED:-?} 尾段SD1=${SD1:-?} 尾段enter=${SYE:-?} keeper=${KL:-?} crash=${CR:-?} 改信号=${SOFT:-?} 放行=${SOFTP:-?} batt=[${BATT:-?}] ${STALE:-件是本次开机的} $NOTE"
    [ -n "$NOTE" ] && { echo "  ★★★ 抓到复位：$NOTE ⇒ 记下轮号，前面那一行的 fork/fired 增量就是死前的速率" ; }
    sleep "$STEP"
done
echo "=== w810 完：$ROUND 轮，期间 adb 掉线 $GONE 次；读数在 $CSV ==="
# ★★形状闸(契约的生产者)：上一版把 cpu_ticks 的 10 个逗号裸写进 CSV ⇒ 表头 18 列、正文 27 列，
#   事后按列读整份错位(例 181④"契约写两处就会漂一处"的另一种形状：写了一处但没人校)。
#   现在每轮都用 csv 解析器数一遍，不齐就在终端打 BAD 并把不一致的轮号列出。
PYTHONUTF8=1 python - "$CSV" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], encoding='utf-8', errors='replace')))
if not rows:
    print("  [形状闸] BAD 空文件"); sys.exit(1)
n = len(rows[0]); bad = [i for i, r in enumerate(rows[1:], 2) if len(r) != n]
print(f"  [形状闸] 表头 {n} 列，{len(rows)-1} 行数据，列数不齐的行={bad if bad else '无'} ⇒ {'OK' if not bad else 'BAD'}")
PY

