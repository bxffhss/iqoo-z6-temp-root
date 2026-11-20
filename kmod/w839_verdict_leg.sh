#!/usr/bin/env bash
# w839_verdict_leg.sh —— 第 58 发 #193 的"判决腿"：**同一条窗里顺手跑，不加枪、不派 UI 动作**。
#   要分清的三件事(以前都被我并成一句"卡死")：
#     ①官方 Manager 自己死 = seccomp 的 SIGSYS(31)？还是 vr 的 SIGKILL(9)？⇒ 只看 **信号号**，别看命中词；
#     ②被授权 app 的 root 壳被杀 = vr 那一支(栈在受害者自己的 syscall 里)；
#     ③"终端卡死但进程没死" = 我们自己的形状(su 的管道交互) —— 这里用两条**并排**的管道腿判。
#   ★先断言前提：`mod!=1` 时所有读数一律打 **未测(不是掉牌)**，绝不产出一行"结论"(例 181①)。
#   ★fd 那格只有 root 腿读得到：/proc/<pid>/fd 是 500、属别的 uid，shell 侧读不到(不是"没装 fd")。
#   ★远端命令一律**单件事、无 $( )**：嵌在双引号里的 $() 会在我这台机器上先展开(记忆里栽过)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
EV=kmod/w103_evidence/shot58
mkdir -p "$EV"
OUT=$EV/w839_verdict.txt
: > "$OUT"

R() { timeout 30 adb shell "$1" 2>/dev/null | tr -d '\r'; }
log() { echo "$1" | tee -a "$OUT"; }

log "=== w839 判决腿 起 $(date '+%F %T') ==="

UP=$(R "cut -d' ' -f1 /proc/uptime")
MOD=$(R "grep -c kernelsu /proc/modules")
ENF=$(R "cat /sys/fs/selinux/enforce")
log "起点：up=${UP:-无读数} mod=${MOD:-?} enforce=${ENF:-?}"
if [ "$MOD" != "1" ]; then
    log "*** 前提不成立(mod=$MOD ≠ 1) ⇒ 本轮所有读数记【未测(不是掉牌)】，直接结束"
    exit 0
fi

# ---------- ①信号号：崩溃缓冲里到底是谁、死于哪个号 ----------
log ""
log "--- ① logcat -b crash：Fatal signal 行(最近 2000 条里) ---"
CR=$(R "logcat -b crash -d -t 2000")
printf '%s\n' "$CR" | grep -a 'Fatal signal' | tail -8 | sed 's/^/  /' | tee -a "$OUT"
N9=$(printf '%s\n' "$CR" | grep -ac 'Fatal signal 9')
N31=$(printf '%s\n' "$CR" | grep -ac 'Fatal signal 31')
KSUD=$(printf '%s\n' "$CR" | grep -ac 'libksud')
MAN=$(printf '%s\n' "$CR" | grep -ac 'me.weishu')
log "  计数：SIGKILL(9)=${N9:-0}  SIGSYS(31)=${N31:-0}  含 libksud=${KSUD:-0}  含 me.weishu=${MAN:-0}"

# ---------- ②Manager 现在的状态（活着才有 ②；死了就去看 ① 和 tombstone） ----------
log ""
log "--- ② Manager .pidof + 它的 SigPnd/Seccomp（root 腿才读得到 fd） ---"
MGR=$(R "pidof me.weishu.kernelsu" | cut -d' ' -f1)
if [ -z "$MGR" ]; then
    log "  Manager 当前没有 pid ⇒ 这一格记【未测】(进程不在，不是'牌子掉了')"
else
    log "  pid=$MGR"
    R "grep -aE '^(State|Uid|SigPnd|ShdPnd|Seccomp):' /proc/$MGR/status" | sed 's/^/    /' | tee -a "$OUT"
    R "/system/bin/su -c ls -l /proc/$MGR/fd" | grep -ac 'ksu_driver' | sed 's/^/    fd_ksu(root 腿读)＝/' | tee -a "$OUT"
fi

# ---------- ③我们那把挡枪今天到底动没动（KILLSOFT；旧词元当"没有生产者"的负对照） ----------
log ""
log "--- ③ dmesg2.log 里的两处计数 ---"
log "  ★新词元(货里真产)：KILLSOFT"
R "grep -ac 'KILLSOFT' /data/local/tmp/dmesg2.log" | sed 's/^/    KILLSOFT 行数＝/' | tee -a "$OUT"
R "grep -a 'KILLSOFT' /data/local/tmp/dmesg2.log" | tail -3 | sed 's/^/    /' | tee -a "$OUT"
log "  ★旧词元(rc30/31 的形状，货里不产)：KILLGUARD 已跳过 ⇒ 期望 0 行"
R "grep -ac 'KILLGUARD: 已跳过' /data/local/tmp/dmesg2.log" | sed 's/^/    行数＝/' | tee -a "$OUT"
log "  装载期那句谎报(证明它必打、不能当证人)："
R "grep -a '挂上跳过探针' /data/local/tmp/dmesg2.log" | tail -1 | sed 's/^/    /' | tee -a "$OUT"

# ---------- ④两条并排的管道腿（判"零输出 rc=1"那一格） ----------
log ""
log "--- ④ 管道 A/B：各自 timeout 15，把 rc 与字节数都记下来 ---"
for P in /system/bin/su /product/bin/su; do
    log "  [$P] 管道：printf 'id' | $P"
    S=$(R "printf 'id\n' | timeout 15 $P; echo RC=\$?")
    printf '%s\n' "$S" | sed 's/^/    /' | tee -a "$OUT"
    log "  [$P] 显式 -c：timeout 15 $P -c id"
    printf '%s\n' "$(R "timeout 15 $P -c id; echo RC=\$?")" | sed 's/^/    /' | tee -a "$OUT"
done
log "  正对照(应当仍是 uid=0)：timeout 15 /system/bin/su -c id"
printf '%s\n' "$(R "timeout 15 /system/bin/su -c id; echo RC=\$?")" | sed 's/^/    /' | tee -a "$OUT"

log ""
log "=== w839 完 $(date '+%F %T')  up=$(R "cut -d' ' -f1 /proc/uptime") mod=$(R "grep -c kernelsu /proc/modules") 产物=$OUT ==="
