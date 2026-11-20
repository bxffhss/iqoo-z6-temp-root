#!/bin/bash
# go.sh —— 一条命令把这台机从冷boot带到"su 可用"，并在窗口中段顺手清掉 /data/adb 脚印。
#   为什么要有它：目标(路线 C)已经交付，但每次都要手抄 push→reboot→等负载→punch→等 stage→bind→验，
#   漏一步就白等 18 分钟。这个脚本把那串固化下来，**每一步都带回执**，任何一步不成就直接说"没成+为什么"。
#   ★跑法：I_KNOW=1 bash kmod/go.sh        （会 reboot + punch）
#   ★收法：I_KNOW=1 bash kmod/w161_teardown.sh   （root 侧卸载 → 清 → reboot → 复核）
#   ★窗口内想手敲：adb shell → am start -n com.termux/.app.TermuxActivity（Termux 里 su → uid=0）
set -u
cd "$(dirname "$0")/.." || exit 1
# ★§6.290：空枪判据抽到 kmod/blank_gate.sh 当**唯一真源**(自测也 source 同一份 ⇒ 漂移不可能)，
#   缺这个文件就停手——宁可不开窗，也不要退回到那份会把"还在飞"判成"空枪"的旧逻辑。
. kmod/blank_gate.sh
type blank_now >/dev/null 2>&1 || { echo "[x] kmod/blank_gate.sh 里没有 blank_now ⇒ 停(别用旧判据开窗)"; exit 6; }
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 reboot + punch)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
# ★#165 换来的规矩(10-22 第 36 发)：**长跑件的退出码必须落盘**。
#   那晚我把"第 4~8 步没跑"归因成"detached 被回收"，读完源码才看到空枪分支自己 `exit 5`——"进程不在了＋日志不再长"
#   对**自己退**和**被人收掉**是同一个读数。有了这个件，两者从此有两个不同产物：
#   `go_rc.txt` 在 ⇒ 件自己走完或从分支退出(里面就是那个 rc)；件在而 `go_rc.txt` 不在 ⇒ 是被外部收掉的。
GO_RC_FILE="$EV/go_rc.txt"
trap 'rc=$?; echo "GO_RC=$rc at $(date "+%F %T")" | tee -a "$GO_RC_FILE"' EXIT
SUW=com.suw.manager
TGT=com.termux
CTL=/data/local/tmp/ksuctl88
fire() {
    # ★§6.312 格 W 专用：`NOFIRE=1` ⇒ **只 force-stop、不发扳机**（那三处 fire() 的 `am start --es auto ksuarm`
    #   正是 suw 自动化 execve 的来源＝148/151 里"suw 动手"的真相是我的腿在扳它）。默认关＝交付链一字不变。
    if [ -n "${NOFIRE:-}" ]; then
        A "am force-stop $SUW" >/dev/null; sleep 1
        echo "  ★NOFIRE=$NOFIRE ⇒ 跳过 am start(扳机)；读回 pidof $SUW=[$(A "pidof $SUW" | tr -d '\r' | tr -s ' ')]"
        return 0
    fi
    A "am force-stop $SUW" >/dev/null; sleep 1
    #   ★★已知不一致(第 30 发登记，未改)：收尾件 `w161_teardown.sh` 的 `fire()` 带 `-f 0x4000000`(CLEAR_TOP)，
    #     这一条不带。原因＝这条是**交付链的扳机**，第 22/24/25 发都是拿它现在的样子认证过的；
    #     给它加旗＝换形状，必须由下一发零开关回归自己判(#142)，不许离线偷改。
    #     代价已量化在第 5.5 步：那里我另写了一条带旗的 `am start`(诊断腿，不动交付链)，因为 suw 已被第 4 步起活，
    #     不带 CLEAR_TOP 时 extras 会被整条丢掉(§6.364 仪器账②：本窗 5.5 的派单**零新增行**)。
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 1) 起点体检(没 punch 之前先把不该有的东西确认成没有) ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) uts=$(uname -s) 挂载=$(grep -c "product/bin" /proc/mounts)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" = 0 ] || { echo "[x] 起点就有模块 ⇒ 说明上一发没收尾，先跑 w161_teardown.sh"; exit 3; }
[ "$(A 'getenforce')" = "Enforcing" ] || echo "  [!] 起点不是 Enforcing(可能还留着上发的窗口)，照旧往下走"
TGTUID=$(pk_uid "$TGT"); SUWUID=$(pk_uid "$SUW")
for v in TGTUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 取不到($X) ⇒ 停：uid 写错整发判据都会打空"; exit 3;; esac; done
echo "  Termux=$TGTUID suw=$SUWUID"

echo "=== 1.5) 本轮 args 由参数决定，不靠我手改文件(§6.226：今天四次'已还原'用嘴说) ==="
#   用法：ARGS_FILE=kmod/ksu_args.txt.enf_apk I_KNOW=1 bash kmod/go.sh
#   开窗时把指定那份拷成交付文件；第 8 步结束后**自动还原默认**并 diff 复证(除非 ARGS_KEEP=1)。
if [ -n "${ARGS_FILE:-}" ]; then
    [ -f "$ARGS_FILE" ] || { echo "[x] ARGS_FILE 不存在：$ARGS_FILE"; exit 2; }
    cp "$ARGS_FILE" kmod/ksu_args.txt && echo "  本轮 args 取自 $ARGS_FILE：$(cat kmod/ksu_args.txt)"
    # ★§6.289：还原**不能只排在第 8 步**。空枪分支走 `exit 5`，崩溃/被 Ctrl-C 都不经过第 8 步
    #   ⇒ `kmod/ksu_args.txt` 会停在实验形状上(第 135 发实测停在只有 `ksu_mass_mark=0` 那一份)，
    #   下一发若不带 ARGS_FILE 就等于"交付窗跑默认参数"＝照着**死亡形状**跑。用 EXIT 兜住所有出口。
    trap '[ "${ARGS_KEEP:-0}" = 1 ] || { cp kmod/ksu_args.txt.bak_delivery kmod/ksu_args.txt 2>/dev/null && echo "  [EXIT 兜底] 交付 args 已还原：$(md5sum kmod/ksu_args.txt | cut -d" " -f1)"; }' EXIT
else
    echo "  未给 ARGS_FILE ⇒ 用仓库里现有的 ksu_args.txt：$(cat kmod/ksu_args.txt)"
fi

echo "=== 1.6) 改道落点与标签从 args 反推，不靠我记得那两行 echo(§6.228⑨) ==="
#   ksu_ksud_path 不是 /dev/ksud 时，stage 需要 ksu_redirect_dst(把 ksud 复制到哪) + ksu_redirect_con(贴什么标签)。
#   ★标签默认**只能 plain s0**：第 104 发实测带类别(s0:c100,c200)在执法下挡掉 app 的 execute(rc=126)。
#   要复现那一格请显式 REDIRECT_CON=u:object_r:apk_data_file:s0:c100,c200 —— 那是实验，不是交付形状。
KSUD_P=$(tr ' ' '\n' < kmod/ksu_args.txt | sed -n 's/^ksu_ksud_path=//p')
# ★§6.301⑤/runbook §26 的仪器开关，**默认关 ⇒ 交付链行为逐字不变**。
#   为什么需要它：这一段是"从当前生效的 args 反推落点"，所以**少给 `ksu_ksud_path` 的那几发会顺手把
#   dst/con 删掉 ⇒ stage 装载前那段 `cp ksud→落点 + chown + chcon` 整块不跑**（§6.301③ 的共变源）。
#   格 H 要把"参数串出现在 insmod 命令行里"与"落点被铺过"这两件事分开，就得只补后者。
#   ★优先级：args 里给了 `ksu_ksud_path` ⇒ **以 args 为准**，本开关不得覆盖它（免得把交付形状改掉）。
if [ -z "$KSUD_P" ] && [ -n "${REDIRECT_DST:-}" ]; then
    KSUD_P="$REDIRECT_DST"
    echo "  ★REDIRECT_DST=$KSUD_P 覆盖生效(args 里没给 ksu_ksud_path) ⇒ 本发装载前会铺落点(实验格 H)"
elif [ -n "${REDIRECT_DST:-}" ] && [ "$KSUD_P" != "$REDIRECT_DST" ]; then
    echo "  [!] REDIRECT_DST=$REDIRECT_DST 被忽略：args 里已有 ksu_ksud_path=$KSUD_P(以 args 为准)"
fi
if [ -n "$KSUD_P" ] && [ "$KSUD_P" != /dev/ksud ]; then
    CON=${REDIRECT_CON:-u:object_r:apk_data_file:s0}
    A "echo $KSUD_P > /data/local/tmp/ksu_redirect_dst; echo $CON > /data/local/tmp/ksu_redirect_con"
    echo "  已写 dst/con，设备上读回复证：$(A 'cat /data/local/tmp/ksu_redirect_dst /data/local/tmp/ksu_redirect_con' | tr '\n' ' ')"
else
    A "rm -f /data/local/tmp/ksu_redirect_dst /data/local/tmp/ksu_redirect_con"
    echo "  ksu_ksud_path=${KSUD_P:-<args 里没给>} ⇒ 已清掉 dst/con，免得上一发的残留生效"
    # ★§6.290 注：原来这行末尾写着"(tmpfs 默认口)"，**那是错的**——远端真树 `kernel/runtime/ksud.h:6` 是
    #   `#define KSUD_PATH "/data/adb/ksud"` ⇒ args 不给时 ko 找的是 /data/adb/ksud(tmpfs 那条是**给了参数**
    #   之后的交付形状，#41/#56)。写清楚免得下一次再把"默认"读成 tmpfs(§6.282 那条结论以此为准)。
fi

echo "=== 1.66) ★AP_KEY＝主那条名单记录的 key(包名字符串)；默认不给＝交付形状逐字不变（§6.313⑦/例 117） ==="
#   为什么要有它：stage 里主条目一直是 `uid=$SUWID key=com.suw.manager`，改 uid 时 key **不跟着走**
#   ⇒ 第 151 发那格其实是"名字与 uid 不匹配"。格 X 要的是"只改 key"的单变量对，所以这个字段必须能单独拨。
if [ -n "${AP_KEY:-}" ]; then
    case "$AP_KEY" in
        *[!A-Za-z0-9._-]*|'' ) echo "[x] AP_KEY=[$AP_KEY] 含非法字符(只允许 字母数字 . _ -) ⇒ 停，别把串注进设备侧命令" ; exit 3 ;;
    esac
    A "printf '%s' '$AP_KEY' > /data/local/tmp/ksu_ap_key" >/dev/null
    A "ls -l /data/local/tmp/ksu_ap_key" | tr -s ' ' | sed 's/^/  AP_KEY='"$AP_KEY"' ⇒ /'
    echo "  开关内容读回=[$(A "cat /data/local/tmp/ksu_ap_key" | tr -d '\r\n')]  ★必须与上面 AP_KEY 逐字相同"
    echo "  ★生效证人＝stage 里那行「★AP_KEY 生效证人：主条目 uid=… key=[$AP_KEY]」＋ksuctl 自己打的 wrote … key=…（事后 grep 复证）"
else
    A "rm -f /data/local/tmp/ksu_ap_key" >/dev/null
    echo "  未给 AP_KEY ⇒ 不铺开关文件，stage 用默认 key=com.suw.manager（交付形状）"
fi

echo "=== 1.65) ★QUIET=1 才把那两个 quiet 开关铺上（§6.310：第 149/150 发我漏 touch ⇒ 跑成了交付形状） ==="
#   一手教训：`ksu_quiet_after_insmod`/`ksu_quiet_fixcfi` 在工具链里**没有任何生产者**，历史上全靠我手敲；
#   收窗时又会把它们删掉 ⇒ 下一发忘了 touch 就静悄悄变成"非 quiet"，而 runbook 里那一格写的是 quiet。
#   开关默认关（交付链行为逐字不变）；给了 QUIET=1 ⇒ touch 两个并**读回 ls**（没有产物就没有发生）。
if [ -n "${QUIET:-}" ]; then
    A "touch /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi; ls -l /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi" | tr -s ' ' | sed 's/^/  QUIET='"$QUIET"' ⇒ /'
    echo "  ★本格是 quiet 形状：装载后 stage 必须打印「★ksu_quiet_after_insmod 在」这一行才算生效（事后用 grep 复证）"
else
    # ★第 23 发抓出来的活危险：quiet 两个开关**没有生产者清理**就会跨 boot 活着 ⇒ 下一发忘带 QUIET=1 会静悄悄跑成 quiet
    #   （例 116/175 那一族；AP_KEY/RING_END_DUMP 都有 else-rm，QUIET 漏了）
    A "rm -f /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi; ls /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi 2>&1 | tr -d '\n'" | sed 's/^/  未给 QUIET ⇒ 已清开关并读回：/'
    echo " ⇒ 本格＝**交付(非 quiet)形状**；若这一格写的是 quiet，现在就停下去补，别开枪"
fi

echo "=== 1.67) ★RING_END_DUMP=<秒> 才铺"死前整环 dump"开关（§6.334/#135：判 SU0 是漏抓还是真没走到） ==="
#   为什么要有这一把：出货 ko 在 su 路径上本来就连打 SU0→SD4→SU1 三行(§6.334)，所以"编带打印的 ko"没有新观测点；
#   要解的是**抓取可靠性**——把整环 dump 推到 insmod+~<秒> 秒(死线之前最近的时刻)再读一次。
#   ★只用 root 侧自己的 shell(stage)，**不 fire suw**（一 fire 就把"suw 整窗没运行"那一维改掉了，§6.184/#135）。
#   开关默认关＝交付形状逐字不变；给了值⇒写文件并**读回 cat/ls**（没有产物就没有发生，例 116）。
if [ -n "${RING_END_DUMP:-}" ]; then
    case "$RING_END_DUMP" in
      ''|*[!0-9]*) echo "  [x] RING_END_DUMP 只收纯数字(秒)，收到的是[$RING_END_DUMP] ⇒ 停，一条 adb 都不发" >&2; exit 3 ;;
    esac
    if [ "$RING_END_DUMP" -lt 30 ] || [ "$RING_END_DUMP" -gt 900 ]; then
        echo "  [x] RING_END_DUMP 要在 30..900 秒之间(要落在 insmod 之后、死线之前)，收到 $RING_END_DUMP ⇒ 停" >&2; exit 3
    fi
    A "printf 'RING_END=%s\n' '$RING_END_DUMP' > /data/local/tmp/ksu_ring_end_dump" >/dev/null
    A "ls -l /data/local/tmp/ksu_ring_end_dump; cat /data/local/tmp/ksu_ring_end_dump" | tr -s ' ' | sed 's/^/  RING_END_DUMP='"$RING_END_DUMP"' ⇒ /'
    echo "  ★生效证人看 stage：必须出现「★RING_END 腿在跑」与「★dump 完 up=」这两行，事后 grep 复证"
else
    A "rm -f /data/local/tmp/ksu_ring_end_dump" >/dev/null
    echo "  未给 RING_END_DUMP ⇒ 不铺开关＝收尾/形状逐字不变（这一发不做死前 dump）"
fi

echo "=== 1.68) ★DOM=<SELinux 上下文串> 才铺「名单那条记录的域」开关（§6.350/#117：形状词「域=X」以前没有生产者） ==="
#   为什么要有它：#117 那一格要的形状是「提权后的壳留在**调用者自己那个域**」，而工具链里唯一能定域的
#   旋钮是 stage 的 $DOM——它读**设备侧环境变量**，而没有任何腿去设 ⇒ 这一格的历史状态其实是「永远 shell 域」，
#   要改域只能我手敲(例 116/175：静默换形状、不报错)。现在：给 DOM ⇒ 铺开关文件并**读回**；不给 ⇒ rm -f 并复证。
#   ★只动名单记录的 profile 域，**不碰 ksu_args.txt 那五条**(args 与名单条目数是已证的共变轴，别混)。
if [ -n "${DOM:-}" ]; then
    case "$DOM" in
        *[!-A-Za-z0-9._,:]*|'' ) echo "  [x] DOM=[$DOM] 含非法字符(只允许 字母数字 . _ , : -) ⇒ 停，别把串注进设备侧命令" ; exit 3 ;;
        u:* ) ;;
        * ) echo "  [x] DOM=[$DOM] 不是「u:r:xxx:s0」那种上下文串(必须以 u: 开头) ⇒ 停" ; exit 3 ;;
    esac
    if [ "${#DOM}" -gt 80 ]; then
        echo "  [x] DOM 长度 ${#DOM} > 80 ⇒ 停(ksuctl 那边按结构体字段长度拒收，别到设备上才发现)" ; exit 3
    fi
    A "printf '%s' '$DOM' > /data/local/tmp/ksu_dom" >/dev/null
    A "ls -l /data/local/tmp/ksu_dom" | tr -s ' ' | sed "s|^|  DOM=$DOM ⇒ |"
    echo "  开关内容读回=[$(A "cat /data/local/tmp/ksu_dom" | tr -d '\r\n')]  ★必须与上面 DOM 逐字相同"
    echo "  ★生效证人三段＝stage 那行「★DOM 生效证人：主条目域=[$DOM]」＋ksuctl 自己打的 profile:…domain= ＋事后 root 腿的 cat /proc/self/attr/current"
else
    A "rm -f /data/local/tmp/ksu_dom; ls /data/local/tmp/ksu_dom 2>&1 | tr -d '\n'" | sed 's/^/  未给 DOM ⇒ 已清开关并读回：/'
    echo " ⇒ 本格＝**交付形状(域=u:r:shell:s0)**；若这一格预登记写的是「改域」，现在就停下来补开关，别开枪"
fi

echo "=== 1.68b) ★DOM_MAP=<uid=域[;uid=域…]> 才铺「每条名单记录各自的域」映射（§6.353/#117 下一格的前置） ==="
#   为什么要有它：第 26 发证窄之后剩一个形状上做不到的事——`DOM` 一整窗一个值，而 stage 的 `mkallow`
#   会把**所有**条目的 domain 都写成同一个 `$DOM` ⇒ "suw 留自己的域 × Termux 留自己的域"没法同时成立。
#   格式：分号分开多条，每条 `数字uid=上下文串`(串里不许空格)；铺成设备侧 `/data/local/tmp/ksu_dom_map`
#   的 `uid 空格 串` 一行一条(★两字段用第一个空格切，uid 只能是数字 ⇒ 不会与串里的 `:`/`,` 歧义)。
#   ★默认不给 ⇒ 不铺文件 ⇒ stage 的 `dom_for` 原样回吐 `$DOM` ⇒ 与第 26 发及以前**逐字同形**。
if [ -n "${DOM_MAP:-}" ]; then
    # ★非法字符检查用 `tr -d` 而不是 case：case 的**模式里含 `;`** 会被 bash 当成语句结束符
    #   (`syntax error near unexpected token ';'`，本机现场抓的)，而 `;` 恰恰是我格式里"多条分隔符"必须允许的字符。
    _bad=$(printf '%s' "$DOM_MAP" | tr -d -- '-A-Za-z0-9._,:;=')
    if [ -n "$_bad" ]; then
        echo "  [x] DOM_MAP 含非法字符 [$_bad](只允许 字母数字 . _ , : ; = -) ⇒ 停，别把串注进设备侧命令" ; exit 3
    fi
    _dm_lines=''
    IFS=';' read -ra _DM <<<"$DOM_MAP"
    for tok in "${_DM[@]}"; do
        [ -n "$tok" ] || continue
        case "$tok" in
            *=* ) ;;
            * ) echo "  [x] DOM_MAP 的一段 [$tok] 里没有 = (格式＝<数字uid>=<上下文串>，多条用分号) ⇒ 停" ; exit 3 ;;
        esac
        _u=${tok%%=*}; _c=${tok#*=}
        case "$_u" in
            '' | *[!0-9]* ) echo "  [x] DOM_MAP 的一段 [$tok] 的 uid 部分不是纯数字 ⇒ 停" ; exit 3 ;;
        esac
        case "$_c" in
            u:* ) ;;
            * ) echo "  [x] DOM_MAP 里 uid=$_u 的串 [$_c] 不以 u: 开头 ⇒ 停" ; exit 3 ;;
        esac
        if [ "${#_c}" -gt 80 ]; then echo "  [x] uid=$_u 的域串长度 ${#_c} > 80 ⇒ 停" ; exit 3; fi
        _dm_lines="$_dm_lines$_u $_c
"
    done
    [ -n "$_dm_lines" ] || { echo "  [x] DOM_MAP 给了但一段都没有(解析后为空) ⇒ 停" ; exit 3; }
    B64=$(printf '%s' "$_dm_lines" | base64 | tr -d '\r\n')
    A "echo $B64 | base64 -d > /data/local/tmp/ksu_dom_map" >/dev/null
    echo "  铺上去的映射(本机算的原文)："
    printf '%s' "$_dm_lines" | sed 's/^/    /'
    echo "  设备侧读回=[$(A "cat /data/local/tmp/ksu_dom_map" | tr '\r\n' '||' | sed 's/|$//')]"
    echo "  本机算的读回基准=[$(printf '%s' "$_dm_lines" | tr '\n' '|' | sed 's/|$//')]  ★两边要逐字相同"
    A "wc -c < /data/local/tmp/ksu_dom_map" | tr -dc '0-9' | sed 's/^/  设备侧字节=/'
    echo ""
    echo "  ★生效证人＝stage 那行「★DOM 生效证人：主条目 uid=… 域=[…] 映射文件=… 映射内容=[…]」＋每条「profile: … domain=」(ksuctl 自己打的)"
else
    A "rm -f /data/local/tmp/ksu_dom_map; ls /data/local/tmp/ksu_dom_map 2>&1 | tr -d '\n'" | sed 's/^/  未给 DOM_MAP ⇒ 已清映射文件并读回：/'
    echo " ⇒ 本格＝每条记录的域都等于全局 DOM(没给 DOM 就是 u:r:shell:s0，交付形状)"
fi

echo "=== 1.69) ★SHBIN=<绝对路径> 才铺「提权壳 exec 哪个二进制」开关，并把交付槽换成 v4（§6.351/#117：第二把生产者） ==="
#   为什么要有它：#117 那格的第二个形状词「exec app 自己的静态壳」以前**没有实现动作**——v3 的
#   `SHBIN` 是编译期常量 `/system/bin/sh`(cm57/su_static.c:51)，而在 app 域下执行它已被 §6.226 判死。
#   v4 改成 `SU_SHBIN`(env) > `/data/local/tmp/ksu_shbin`(设备侧文件) > 默认；★两个都不给 ⇒ 目标逐字仍是
#   `/system/bin/sh`，**交付形状不变**。这里给的就是"铺文件＋选二进制"那两半，缺一样这一格就静悄悄跑成别的形状。
#   ★为什么换的是**另一支二进制的名字**：`cm57/sustatic`(v3，md5 f7a441d2…)是交付链注册过的那支，
#     而我不能证明今天这套 flag 逐字重现它 ⇒ 重编产物只走 `cm57/sustatic_v4` 这个名字(一个名字一个来源，例 110/113)。
SHIM_SRC=cm57/sustatic
if [ -n "${SHBIN:-}" ]; then
    case "$SHBIN" in
        *[!A-Za-z0-9._/:+-]*|'' ) echo "  [x] SHBIN=[$SHBIN] 含非法字符(只允许 字母数字 . _ / : + -) ⇒ 停，别把串注进设备侧命令" ; exit 3 ;;
        /* ) ;;
        * ) echo "  [x] SHBIN=[$SHBIN] 不是绝对路径 ⇒ 停" ; exit 3 ;;
    esac
    if [ "${#SHBIN}" -gt 120 ]; then
        echo "  [x] SHBIN 长度 ${#SHBIN} > 120(v4 那边装不进 shbin[128]) ⇒ 停" ; exit 3
    fi
    [ -f cm57/sustatic_v4 ] || { echo "  [x] 要开 SHBIN 就得推 v4，但本机没有 cm57/sustatic_v4 ⇒ 先跑 bash cm57/build_sustatic.sh" ; exit 3; }
    A "printf '%s' '$SHBIN' > /data/local/tmp/ksu_shbin" >/dev/null
    A "ls -l /data/local/tmp/ksu_shbin" | tr -s ' ' | sed "s|^|  SHBIN=$SHBIN ⇒ |"
    echo "  开关内容读回=[$(A "cat /data/local/tmp/ksu_shbin" | tr -d '\r')]  ★必须与上面 SHBIN 逐字相同"
    SHIM_SRC=cm57/sustatic_v4
    echo "  ⇒ 第 5 步要推的二进制改成 $SHIM_SRC(不是交付槽那份 v3)；生效证人＝那支自己无条件打的「su: shbin=[…] 来源=…」那行"
else
    A "rm -f /data/local/tmp/ksu_shbin; ls /data/local/tmp/ksu_shbin 2>&1 | tr -d '\n'" | sed 's/^/  未给 SHBIN ⇒ 已清开关并读回：/'
    echo " ⇒ 本格＝**交付形状(shim＝v3 cm57/sustatic，exec 目标＝/system/bin/sh)**"
fi
# ★§6.353：给了 SHBIN 就得**连 push_ksu 那条链一起切**——su 改道真正 exec 的那支是
#   `push_ksu.sh` 以 `SHIM` 推上去、**改名叫 `ksud`**、再由 stage `cp` 成 `kd` 的那份
#   （第 26 发一手：只切第 5 步那份 `/data/local/tmp/sustatic` 根本测不到 su 改道那条路，
#     当时是靠 root 腿手工把 `kd` 换成 v4 才拿到读数）。不给 ⇒ SHIM 还是 v3，逐字不变。
export SHIM="$SHIM_SRC"
echo "  ⇒ push_ksu 将推的 shim＝$SHIM（su 改道链与 bind 链同一支，别再分叉）"

echo "=== 1.69b) ★NOSUW=1 才铺「名单里只有目标 app ＋ bind 归 stage」这套形状（§6.360/#145；★契约改动＝§6.365，格 N1 预登记＝runbook §87） ==="
#   为什么做成开关而不是直接改默认：第 29 发刚把交付形状认证完(§6.361)；直接改默认会让那份认证当场
#   不存在，而且下一发说不清是哪个变量翻的(例 111/117)。不给 ⇒ stage 里 ENT_*/bind 两块逐字等价于老形状。
#   ★这个开关的**全部**副作用都列在这儿(例 100：开关要先列全部副作用)：
#     ①名单**唯一**那条从 (suw 现取 uid, com.suw.manager) 换成 (**目标 app 现取 uid, 目标包名**)。
#        ★以前这里硬写"官方 Manager 自己"，§6.365 用三个独立证人把它判成设计上无效(名单闸对它恒真、
#          名单读数对它恒隐、它的 root profile 走 use_default、装载循环对它零特判) ⇒ 现在的目标由
#          `NOSUW_PKG` 给，默认＝`$TGT`(com.termux)，uid **开枪前现取**(§6.354 那条"参数现取"的规矩)。
#     ②bind /product/bin 由 stage 自己在 Permissive 相做 ⇒ 第 5 步的 @sushd 派发必须跳过(见 ③)；
#     ③bind 的源 /data/local/tmp/sustatic 原来是在第 5 步(**insmod 之后**)才推的 ⇒ 这里提前推＋两端 md5 硬闸，
#       否则 stage 那侧只会看到"源不存在"这一格直接弃权(工具顺序错，不是机制失败)。
if [ -n "${NOSUW:-}" ]; then
    adb push "$SHIM_SRC" /data/local/tmp/sustatic >/dev/null 2>&1
    LN=$(md5sum "$SHIM_SRC" | cut -c1-32); RN=$(A "md5sum /data/local/tmp/sustatic" | cut -c1-32)
    echo "  bind 的源已提前推：$SHIM_SRC 本机 md5=$LN 设备 md5=$RN"
    [ "$LN" = "$RN" ] || { echo "[x] 设备上 /data/local/tmp/sustatic 与本机 $SHIM_SRC 不符 ⇒ 停(别拿错的壳去 bind su)"; exit 3; }
    A "chmod 755 /data/local/tmp/sustatic" >/dev/null
    #   ★开关内容＝`<uid> <包名>`(stage 只认形状，形状不对就打 [!] 不改形状)。本机源必须在**仓库内**
    #     (Windows adb 看不见 MSYS 路径 ⇒ 喂 /tmp 会静默推空 rc=0)，推完要**读回设备字节数＋两端 md5**。
    NOSUW_PKG=${NOSUW_PKG:-$TGT}
    NUID=$(pk_uid "$NOSUW_PKG")
    case "$NUID" in '' | *[!0-9]* )
        echo "[x] NOSUW 目标包 [$NOSUW_PKG] 的 uid 现取失败(=[$NUID]) ⇒ 停：绝不猜一个 uid 进名单"
        exit 3 ;;
    esac
    printf '%s %s\n' "$NUID" "$NOSUW_PKG" > kmod/_tmp_nosuw_switch.txt
    [ -s kmod/_tmp_nosuw_switch.txt ] || { echo "[x] 本机开关文件是空的 ⇒ 停"; exit 3; }
    adb push kmod/_tmp_nosuw_switch.txt /data/local/tmp/ksu_nosuw >/dev/null 2>&1
    SL=$(md5sum kmod/_tmp_nosuw_switch.txt | cut -c1-32); SR=$(A "md5sum /data/local/tmp/ksu_nosuw" | cut -c1-32)
    SB=$(A "wc -c < /data/local/tmp/ksu_nosuw" | tr -dc '0-9')
    echo "  开关已铺：内容=[$(tr -d '\n' < kmod/_tmp_nosuw_switch.txt)] 本机 md5=$SL 设备 md5=$SR 设备字节=${SB:-取不到}"
    [ "$SL" = "$SR" ] || { echo "[x] 设备上的 ksu_nosuw 不是本机这份(Git Bash 谎报那一族) ⇒ 停"; exit 3; }
    A "ls -l /data/local/tmp/ksu_nosuw" | tr -s ' ' | sed 's/^/  NOSUW 开关读回=/'
    echo "  ★生效证人＝stage 那行「★NOSUW 入口证人：名单主条目=(uid=$NUID, key=$NOSUW_PKG) 开关生效=1」"
    echo "            ＋「★mkallow 已写：件=… 条目=(uid, key, 域)」＋「★落盘读回：/data/adb/ksu/.allowlist 字节=」"
    echo "            ＋bind 那三行「NOSUW_BIND_RC= / NOSUW_SU_AT_TGT= / NOSUW_HEALTH=」"
    echo "  ★形状不对时 stage 打 [!] 并**不改形状** ⇒ 那一发按交付形状算(＝格 N1 没测到)，不许写成正/负"
    NOSUW_ON=1
else
    A "rm -f /data/local/tmp/ksu_nosuw; ls /data/local/tmp/ksu_nosuw 2>&1 | tr -d '\n'" | sed 's/^/  未给 NOSUW ⇒ 已清开关并读回：/'
    echo " ⇒ 本格＝交付形状(名单主条目＝suw；bind 在第 5 步经 @sushd 派发)，与第 22/24/25/26/29 发同"
    NOSUW_ON=0
fi

echo "=== 1.7) ★官方 Manager 要能用，就得让 stage 起「抢装看门狗」：touch 这个开关(第 111 发钉出来的) ==="
#   一手事实(§6.193②/§6.237)：官方首页的"支持/不支持"是**启动时一次性分支**，驱动 fd 晚到它也不重查；
#   而 stage 只在 `/data/local/tmp/ksu_race_fd` 存在时才起 0.4s 抢装(75 轮≈30s)。
#   没有它 ⇒ 官方永远"不支持" ⇒ 超级用户页与底部导航条都不存在 ⇒ `ui_grant.sh` 走不了路。
A "touch /data/local/tmp/ksu_race_fd; ls -l /data/local/tmp/ksu_race_fd" | tr -s ' ' | sed 's/^/  /'

echo "=== 2) push + reboot + 等负载 + punch ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|ok ksud|\[x\]" | sed 's/^/  /'
adb push kmod/w161_g2.sh kmod/w165b_adb_clean.sh /data/local/tmp/ >/dev/null 2>&1
adb push cm57/ksuctl88 /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w161_g2.sh /data/local/tmp/w165b_adb_clean.sh $CTL" >/dev/null
LM=$(md5sum cm57/ksuctl88 | cut -c1-32); RM=$(A "md5sum $CTL" | cut -c1-32)
[ "$LM" = "$RM" ] || { echo "[x] 设备上 ksuctl88 不是本机这份(设备=$RM 本机=$LM) ⇒ 停(§6.155：旧二进制会静默丢参数)"; exit 3; }
# === 2a) NOREBOOT 开关（§6.515 第 88 发专用；默认关＝交付形状一字不变） ===
#   ★为什么要有它：有一类读数**只活在"当前这个 boot"里**。第 87 发那种"我们自己把它打死"之后，
#     "死后的第一个 boot"是"那次死到底走没走 panic()"唯一还可能带内的证人(§6.512/§6.514)，
#     而原来这条无条件的 `adb reboot` 等于**先把要读的东西抹掉**(ramoops 的 buffer 在新 kernel 注册时被 zap)。
#   ★它自带一把"当前 boot 是干净的"闸：本 boot 若已经开过窗(kernelsu 已在 /proc/modules)，
#     那"1 boot 只 1 枪"就已经花掉了——在脏 boot 上再开窗只会把两枪的读数混成一条，直接拒。
if [ -n "${NOREBOOT:-}" ]; then
    MOD0=$(A 'grep -c "^kernelsu " /proc/modules')
    echo "  ★NOREBOOT=$NOREBOOT ⇒ 跳过 adb reboot＋起机等待，直接在**当前 boot**开窗"
    echo "    当前 boot 自证：up=$(A 'cut -d" " -f1 /proc/uptime') bootreason=[$(A 'getprop ro.boot.bootreason')] kernelsu=$MOD0"
    echo "    hist=[$(A 'getprop persist.sys.boot.reason.history')]"
    [ "$MOD0" = 0 ] || { echo "[x] 当前 boot 已经有 kernelsu 在 ⇒ 这一 boot 的枪可能已花过，NOREBOOT 不许在脏 boot 上开窗"; exit 3; }
else
    adb reboot
    for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
    until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 10; done
    sleep 40
fi
# === 2a-end) ===
# ★§6.307：dmesg.live 是唯一能判"从没打印"的全量件，而它每发开头就被下面这行删掉
#   ⇒ 145/147 那一发的装载期现场已经永久丢了。改法：上一发若还留着，先改名存档、不删。
PREV=$(A "wc -c < /data/local/tmp/dmesg.live 2>/dev/null" | tr -dc '0-9')
if [ -n "${PREV:-}" ] && [ "$PREV" != "0" ]; then
    TAG=$(A "date +%m%d-%H%M" | tr -dc '0-9-')
    A "mv -f /data/local/tmp/dmesg.live /data/local/tmp/dmesg.live.prev_$TAG" >/dev/null
    echo "  ★上一发的 dmesg.live($PREV 字节)没删，改名为 /data/local/tmp/dmesg.live.prev_$TAG ⇒ pull 清单里带上它，存完再删"
fi
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/dmesg.live /data/local/tmp/ksu_ring_end.txt" >/dev/null
# ★删完要"等一个节拍再复查"，而且必须把**上一发同名产物**一起清掉：`ksu_ring_end.txt` 是 RING_END 腿写的，
#   没人清就会跨 boot 留着 ⇒ 下一发(哪怕没开这腿)pull 到它就是把旧环当本次读数(例 77/95/153)。
#   这一行不接 /dev/null：三行 `No such file` 就是这条清理的读回产物(没有产物就没有发生，例 109)。
sleep 2
A "ls /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/ksu_ring_end.txt" 2>&1 | sed 's/^/  清理复证：/'
for i in $(seq 1 40); do
    L1=$(A "cat /proc/loadavg" | cut -d. -f1)
    [ "${L1:-99}" -le 3 ] && { echo "  负载够低：load1=$L1 up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"; break; }
    [ $((i % 6)) = 0 ] && echo "    还在等: load1=$L1"
    sleep 15
done
# ★#55(§6.184)：punch 之前先起一个 3s 采样器，把 `getenforce` / `pidof pr` / 两份日志的长度按时间轴记下来。
#   动机是第一百一十九发的一手读数：`[SEN]` 写 1→0 之后约 4 分钟 `getenforce` 自己回 `Enforcing`、`pr` 退出、`[POST]` 从没出现
#   ⇒ "空枪"与"enforce 回跳"很可能是同一件事的两面。谁先谁后，这份时间轴会直接给答案(不靠猜)。
adb push kmod/w184_sample.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w184_sample.sh; rm -f /data/local/tmp/w184_sample.out" >/dev/null
A "setsid nohup /data/local/tmp/w184_sample.sh >/dev/null 2>&1 </dev/null &" >/dev/null
echo "  #55 采样器已起(3s 一行，最多 400 行)：/data/local/tmp/w184_sample.out"
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/go_bootstrap.txt" 2>&1
# ★§6.291：这一份原来**每发覆盖同一个文件名** ⇒ 想比对两发的 slide 扫描差别时，前一发已经没了(136 就是这么丢的)。
#   稳定名继续留着方便看，另外按钟点存一份(不需要新输入，也不会与例 97 的同名重建问题纠缠)。
BTAG=$(date +%m%d-%H%M)   # ★只取一次钟点：一行里调两次 `date` 会跨分钟错位，两个名字就对不上(env-gotchas 记过)
cp "$EV/go_bootstrap.txt" "$EV/go_bootstrap_$BTAG.txt" 2>/dev/null && echo "  bootstrap 现场另存：go_bootstrap_$BTAG.txt"
echo "  bootstrap 退出码=$?"; tail -2 "$EV/go_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5; [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }; done

# ★§6.292：分诊前先锚定"这一 boot 的身份"。rc82_kp 第 1 发(11-13 17:34:47)的教训：
#   insmod 后整机 HARD_RESET/PS_HOLD 硬复位，复位后的**全新 boot** 天然满足 §6.290 闩锁三条件
#   (Enforcing / pr 没了 / 无 [POST]) ⇒ go.sh 把"ko 把机器打重启了"误读成"提权没成功／空枪"。
#   ⇒ 这里存 boot_id + bootreason，分诊时比对；**纯诊断增强，不改 exit 5、不改开火形状**。
BOOT0=$(A "cat /proc/sys/kernel/random/boot_id 2>/dev/null" | tr -dc 'a-zA-Z0-9-')
BR0=$(A 'getprop ro.boot.bootreason' | tr -d '\r')
echo "  #6.292 boot 锚点: boot_id=${BOOT0:0:8} bootreason=[$BR0]"
echo "=== 3) 等 stage 到判据⑥(agent fd 装好 = root 通道可用) ==="
SIX=0; EARLY=0; BLANK=0; SAWPER=0
for i in $(seq 1 200); do sleep 5
    SIX=$(A "grep -ac '判据⑥' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${SIX:-0}" != "0" ] && { echo "  判据⑥ 到了 (t+$((i*5))s)"; break; }
    # ★§6.290：空枪判据原来只看"有 [SEN] 无 [POST]"，**但 `[SEN]` 里含翻转之前那两行**
    #   (`打之前的 MAC 关卡…开了 0 格`) ⇒ 提权还在飞的时候就被判成空枪(第 135 发一手：判空在
    #   t+245s，曲线里真正翻转在 up=502.94 晚约 180 秒；且 up=641 时 pr 还活着)。
    #   ⇒ 改成三段闩锁：①这一 boot **见过 Permissive**(SAWPER，等价于"翻转真发生过"，纯 ASCII 无 CJK 匹配风险)；
    #   ②现在**已回到 Enforcing**(§6.119 的 robust 信号：生效位被人写回 1 ⇒ 这发确实做不下去)；
    #   ③pr 不在且无 `[POST]`。三者齐了再连确认两次才算空枪，否则**等满 17 分钟**(慢≠空)。
    ENF=$(A getenforce | tr -d '\r')
    [ "$ENF" = "Permissive" ] && SAWPER=1
    if [ $i -ge 48 ]; then
        PA=$(A "pidof pr" | tr -dc '0-9')
        POSTN=$(A "grep -acF '[POST]' /data/local/tmp/punch.log 2>/dev/null" | tr -dc '0-9')
        if blank_now "$SAWPER" "$ENF" "$PA" "${POSTN:-0}"; then
            BLANK=$((BLANK+1))
            [ $BLANK -ge 2 ] && { echo "  [!] t+$((i*5))s：翻转确实发生过、enf 已回 Enforcing、pr 没了且无 [POST] ⇒ 判为空枪"; EARLY=1; break; }
            echo "    (疑似空枪第 $BLANK 次确认，再等一轮)"
        else
            [ $((i % 24)) = 0 ] && echo "      (空枪候选不成立：sawper=$SAWPER enf=$ENF pr=[${PA:-空}] post=${POSTN:-?})"
            BLANK=0
        fi
    fi
    [ $((i % 12)) = 0 ] && echo "    还在等：up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1) uts=$(A 'uname -s')"
done
if [ "${SIX:-0}" = "0" ]; then
    # ★§6.292：判「空枪」之前先排除"等待期间换了一个 boot"。硬复位后的新 boot 会让
    #   §6.290 闩锁假阳性，且硬复位会抹掉内核日志 ⇒ 必须趁现在把现场捞回来。
    BOOT1=$(A "cat /proc/sys/kernel/random/boot_id 2>/dev/null" | tr -dc 'a-zA-Z0-9-')
    BR1=$(A 'getprop ro.boot.bootreason' | tr -d '\r')
    BRH=$(A 'getprop persist.sys.boot.reason.history' | tr -d '\r')
    if [ -n "${BOOT0:-}" ] && [ -n "$BOOT1" ] && [ "$BOOT0" != "$BOOT1" ]; then
        echo "  ★★★ HARD_RESET_DURING_WAIT：等待期间设备换了一个 boot ⇒ 下面『空枪』的判定无效！"
        echo "     起: boot_id=${BOOT0:0:8} bootreason=[${BR0:-?}]"
        echo "     终: boot_id=${BOOT1:0:8} bootreason=[${BR1:-?}]"
        echo "     hist=[${BRH:-?}]"
        echo "     ⇒ 真事件是 ko/机器把设备打重启了；§6.290 闩锁在复位后的新 boot 上天然成立。"
        echo "     ⇒ 强制归档（硬复位抹日志前捞回，前缀 hard_${BTAG}_）："
        for f in $(A "ls /data/local/tmp/dmesg.live* /data/local/tmp/w184_sample.out /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log 2>/dev/null" | grep '^/data/local/tmp/'); do
            n=${f##*/}
            adb pull "$f" "$EV/hard_${BTAG}_$n" >/dev/null 2>&1 \
              && echo "       + $n ($(wc -c < "$EV/hard_${BTAG}_$n" 2>/dev/null) B)" \
              || echo "       - $n (拉不到)"
        done
        A "dmesg" > "$EV/hard_${BTAG}_dmesg_now.txt" 2>/dev/null
        echo "       + dmesg_now ($(wc -c < "$EV/hard_${BTAG}_dmesg_now.txt" 2>/dev/null) B，新 boot 的内核日志)"
        echo "     ⇒ 请把 hard_${BTAG}_* 与 stage/punch 时间戳对齐；别按『空枪』reboot 了事。"
    else
        echo "  #6.292 boot 身份未变(${BOOT1:0:8}) ⇒ 同一 boot，空枪判定适用"
    fi
    echo "[!] 没到判据⑥就走到分诊：走的是$([ "${EARLY:-0}" = 1 ] && echo '**早退(闩锁三件齐)**' || echo '**等满 ~17 分钟**')这条路 ⇒ 先分诊：**是 pr 真退出了，还是机器出事/提权还在飞？**"
    A "grep -aE '\[SEN\]|\[POST\]|LEAK|insmod rc' /data/local/tmp/punch.log 2>/dev/null | tail -4" | cut -c1-160 | sed 's/^/    punch: /'
    PRALIVE=$(A "pidof pr" | tr -dc '0-9')
    ENF=$(A getenforce); UP=$(A "cut -d\" \" -f1 /proc/uptime" | cut -d. -f1)
    echo "    pr 进程=$([ -n "$PRALIVE" ] && echo 还活着 || echo 已退出)  enf=$ENF up=$UP"
    # ★§6.182 那版"同一 boot 里重打一发"到此**收回**，两个理由都是硬的：
    #   ① `suw_apk/bootstrap.sh` 自己写着「--punch 会花掉本 boot 唯一一发且有重启风险」(第 9/115 行)
    #      ⇒ 同 boot 再 punch 是我们自己判定过不该做的事，不该为了省 10 分钟破例；
    #   ② 第一百一十九发实测：判为空枪的那一刻 `getenforce` 已经是 **Enforcing** ⇒ pr 不是"早退"，
    #      而是**生效位被人写回 1 之后做不下去**了 ⇒ 同一 boot 里再来一次也只是等同一堵墙。
    #   所以现在只把 #55 的时间轴捞回来，然后照旧 reboot。
    A "cat /data/local/tmp/w184_sample.out 2>/dev/null" > "$EV/w184_blank_sample.txt"
    echo "    #55 采样：行数=$(wc -l < "$EV/w184_blank_sample.txt" 2>/dev/null) 头 2 行 / 尾 6 行："
    head -2 "$EV/w184_blank_sample.txt" 2>/dev/null | sed 's/^/      /'
    tail -6 "$EV/w184_blank_sample.txt" 2>/dev/null | sed 's/^/      /'
    echo '    (要看 pr 退场与 enf 回跳谁在先，就比对这几行里 pr=[] 第一次出现的位置与 enf=Enforcing 的位置)'
    [ "${SIX:-0}" = "0" ] && { echo "  ⇒ 空枪(这一 boot 唯一一发已经花在 punch 上，不重打)：reboot 重来"; echo "     判据(§6.290 闩锁)：本 boot 见过 Permissive + 现在 enf=$ENF + pr 没了 + 无 [POST]"; echo "  ⇒ 建议现在手动跑 adb reboot 清状态(★本分支**没有执行它**，下面直接 exit 5)"; exit 5; }
fi
A "grep -aE 'insmod rc|allowlist version|uts:' /data/local/tmp/ksu_stage.log | tail -4" | cut -c1-150 | sed 's/^/    /'

# === 3.5) ★LEG1＝"判据⑥刚到手"这一瞬间就派一支 root 腿（默认不给＝交付形状一字不变） ===
#   凭据(§6.468 第 65 发一手)：判据⑥到手在 up≈600，go.sh 后面第 4~8 步一路吃到 up≈683，我在 up≈684 才派腿，
#   设备 up≈841 就 HARD_RESET ⇒ 腿(含 suw 冷启动那 10~30 秒)只分到 ~150 秒，**什么都没跑成**
#   (out 文件不存在，而同 boot 15:29 的 root 写件 ksu_stage.log/punch.log 都活下来了 ⇒ "没跑"是可核的缺席证据，
#    不是丢写)。⇒ 最想要的腿必须排在**判据⑥之后第一件事**，而不是排在 go.sh 跑完之后。
# ★★第 68 发一手的自保闸：`ksu_quiet_after_insmod` 在 ⇒ stage 走的是**静默版**，它自己那行就写着
#   『判据⑥(★静默版：ko 在，但这一发故意不装 agent fd、不发超调用，只为让 go.sh 往下走)』。
#   ⇒ 那盏「就绪」灯根本不是**通道**就绪：@sushd 没人听，腿一句都不会执行(out 件不存在＝可核的缺席证据)。
#   我的错：把 QUIET 从「参数夹逼那批链」顺手抄进了「要派腿的链」。这里加闸，免得下一个我再犯。
if [ -n "${LEG1:-}" ]; then
    QS=$(A "ls /data/local/tmp/ksu_quiet_after_insmod 2>/dev/null")
    QLINE=$(A "grep -ac '静默版' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    if [ -n "$QS" ] || [ "${QLINE:-0}" != "0" ]; then
        echo "=== 3.5) LEG1 给了但这一发是 quiet 形状 ⇒ **不派腿**(开关文件在=$([ -n "$QS" ] && echo 是 || echo 否), stage 静默版行数=${QLINE:-0})"
        echo "      静默版不装 agent fd ⇒ @sushd 没人听；派下去只会拿到一句都没执行的空证件(第 68 发一手)"
        LEG1=
    fi
fi
# === 3.5a) 自保闸结束(这行是给 kmod/_tmp_selftest_rdst/run_quietguard.sh 抽块用的锚，别删) ===
if [ -n "${LEG1:-}" ]; then
    echo "=== 3.5) 立即派 LEG1=$LEG1 ==="
    case "$LEG1" in
        /data/local/tmp/*.sh ) : ;;
        * ) echo "  [x] LEG1 必须是 /data/local/tmp/ 下的 .sh 绝对路径 ⇒ 不派(别把串注进设备侧命令)" ;;
    esac
    if [ -z "${LEG1OUT:-}" ]; then
        echo "  [x] 没给 LEG1OUT(腿自己写的 out 件) ⇒ 不派：没有等待目标就等于用『没输出』当通过"
    elif [ "${LEG1#/data/local/tmp/}" = "$LEG1" ]; then
        echo "  [x] LEG1 形状不合(要 /data/local/tmp/ 开头) ⇒ 不派"
    else
        if [ -n "${LEG1MD5:-}" ]; then
            DEVMD5=$(A "md5sum $LEG1 2>/dev/null" | cut -d' ' -f1)
            echo "  腿件两端对表：本机=$LEG1MD5 设备=$DEVMD5"
            [ "$DEVMD5" = "$LEG1MD5" ] || { echo "  [x] 设备上不是本机这支腿(§6.155：旧件会静默换形状) ⇒ 不派"; LEG1=1; }
        fi
        # ★★第 69 发一手的第二道自保闸：腿在设备上必须是**可执行**的。
        #   凭据：sushd.log 里那句 `请求来自 uid=10342 … cmd=[/data/local/tmp/w1018_mlsrange_leg.sh]`
        #   后面跟着 `已回给 … exit=126(有输出)` + `KSU_EXEC: … can't execute: Permission denied`
        #   ⇒ 通道是好的、授权也答了 granted=1，死在 execve：**root 也要文件里至少有一个 x 位**
        #      (adb push 落 0666，一个都没有)。而 go.sh 自己第 4 步那批腿一直是「push 完立刻 chmod 755」
        #      (见下面 w165b_adb_clean 那三行) ⇒ 我这个 LEG1 钩子把 chmod 那一行抄漏了。
        #   规矩：派之前就地补 x 位，并且**读回**；读回还是没有 x ⇒ 不派(派下去只会再拿一发空枪)。
        #   ★整块排在 md5 那格**之后**且要 md5 已经通过才做：不然 LEG1 已被置成字面量 1，
        #     我这条 ls 就会去探 `/data/local/tmp` 里一个叫 "1" 的文件(第 69 发 selftest 抓到的形状)。
        #   ★读法用 ls -l 的第 1 列(权限串)取**属主 x 位**，不用 `stat -c %a`：
        #     stat 失败时错误行里带着路径本身(如 `/data/local/tmp/w1018_…`)，我用 tr -dc '0-7' 收数字
        #     会收到 `10187` 这种尾巴是 7 的串 ⇒ 把「读不到」判成「有 x 位」＝假绿。
        #     ls 失败时第 1 列是 `ls:` ⇒ 取不到 x ⇒  fail-closed。
        if [ "${LEG1:-0}" != 1 ]; then
        PERM=$(A "ls -l $LEG1 2>/dev/null" | awk 'NR==1{print $1}')
        XBIT=${PERM:3:1}
        case "$XBIT" in x|s|t) : ;; * ) A "chmod 755 $LEG1" >/dev/null; PERM=$(A "ls -l $LEG1 2>/dev/null" | awk 'NR==1{print $1}'); XBIT=${PERM:3:1} ;; esac
        echo "  腿的设备侧权限=$PERM(派之前现取；补过 x 位就重取一次) 属主 x 位=[${XBIT:-空}]"
        case "$XBIT" in
            x|s|t ) : ;;
            * ) echo "  [x] 腿在设备上没有 x 位(权限=$PERM) ⇒ **不派**：execve 必 EACCES(第 69 发一手 exit=126)"
                 LEG1=1 ;;
        esac
        fi
        if [ "${LEG1:-0}" != 1 ]; then
            A "rm -f $LEG1OUT" >/dev/null
            fire "@sushd:$LEG1" 3
            if WAITFOR "$LEG1OUT" 60 "END up="; then
                A "cat $LEG1OUT" > "$EV/leg1_out.txt" 2>&1
                echo "  ★腿跑完，全文存 $EV/leg1_out.txt(=$(wc -l < "$EV/leg1_out.txt") 行)"
                grep -aE 'insmod_rc|PARAM rt_|MODULES_LINE|POLICY_UNCHANGED|WR_rc|ko_md5|\[x\]|\[!!\]' "$EV/leg1_out.txt" | cut -c1-160 | sed 's/^/    /'
            else
                echo "  [!] 60 轮(约 5 分钟)内没等到 $LEG1OUT 的 END ⇒ 这格记**未测**，不许把『没输出』读成通过"
            fi
        else
            echo "  [x] 前置没齐(md5 或 x 位) ⇒ **不派**：这一段整块跳过，别把派下去的空证件当读数"
            echo "      ★顺带修掉旧缺陷：上面 md5 那格原本只把 LEG1 置成 1 就往下 fire，等于把字面量『1』当脚本派下去"
        fi
    fi
else
    echo "=== 3.5) 未给 LEG1 ⇒ 不派腿(交付形状逐字不变) ==="
fi

# === 3.9) ★LEG1ONLY=1 ⇒ 派完 LEG1 就跳过第 4~7 步（默认不给＝交付形状一字不变） ===
#   为什么要有它：#219 那一格的腿**自己会把执法翻回 1**（要测的就是执法下的支配），而 §关窗铁律
#   要求"恢复执法排在所有 root 腿之后"。第 4~6 步都是 root 腿(清 /data/adb／bind su／读名单)，
#   翻完之后它们必然红(§6.441：exec bind 里的 su ⇒ EACCES)，那不是被测坏了，是**仪器排在被测后面**。
#   ⇒ 与其留一串会误导的红灯，不如显式跳过并把这几格记**未测**。
if [ "${LEG1ONLY:-0}" = 1 ]; then
    echo "=== 3.9) LEG1ONLY=1 ⇒ 跳过第 4~7 步(清 /data/adb／bind su／G2 名单／可用判定) ==="
    echo "  ★这几格本轮＝**未测**，不许把缺席读成通过；直接走第 8 步自愈还原。"
    SKIP4=1
fi
if [ "${SKIP4:-0}" != 1 ]; then
echo "=== 4) ★窗口中段就把 /data/adb 脚印清掉(规矩：别留到收尾，收尾时通道常已经死，§6.161④) ==="
adb push kmod/w165b_adb_clean.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w165b_adb_clean.sh; rm -f /data/local/tmp/w165b_adb_clean.out" >/dev/null
fire "@sushd:/data/local/tmp/w165b_adb_clean.sh" 10
if WAITFOR /data/local/tmp/w165b_adb_clean.out 20 "===== DONE"; then
    A "grep -aE '清之前|清之后' /data/local/tmp/w165b_adb_clean.out" | cut -c1-170 | sed 's/^/    /'
else
    echo "    [!] 清理没跑成(通道没接活) ⇒ 记进 #71，下一发窗口中段再来"
fi

echo "=== 5) bind su(★§6.566：默认不再做；SU_BIND=1 才恢复全局裸 su 供给) ==="
#   ★推哪一支由 §1.69 定：没给 SHBIN ⇒ `cm57/sustatic`(v3，交付槽逐字不变)；给了 ⇒ `cm57/sustatic_v4`。
#     设备上的名字**始终是 /data/local/tmp/sustatic**(下游 w135_fix.sh/挂载脚本都点这个名字)，
#     所以"换了哪一支"只能靠**两端 md5** 这条硬闸读回来，不能靠我说(例 100：配置生效要从被推的那侧核)。
adb push "$SHIM_SRC" /data/local/tmp/sustatic >/dev/null 2>&1
LS=$(md5sum "$SHIM_SRC" | cut -c1-32); RS=$(A "md5sum /data/local/tmp/sustatic" | cut -c1-32)
echo "  shim 来源=$SHIM_SRC 本机 md5=$LS 设备 md5=$RS"
[ "$LS" = "$RS" ] || { echo "[x] 设备上 /data/local/tmp/sustatic 不是本机 $SHIM_SRC ⇒ 停(别拿错的壳去 bind su)"; exit 3; }
if [ "${NOSUW_ON:-0}" = 1 ]; then
    # ★跳过而不是"两边都做"：bind 两次会把这一格变成另一种形状(而且第二次的源目录已带着上一次的 su)。
    #   等新证人：stage 在自己那一段里打 NOSUW_BIND_RC；**取不到就明说"bind 判据没测到"**，不许拿"没输出"当通过。
    echo "  ★NOSUW=1 ⇒ 本步的 @sushd 派发跳过(bind 归 stage，见 §1.69b 副作用②)"
    WAITFOR /data/local/tmp/ksu_stage.log 24 "NOSUW_BIND_RC"
    NL=$(A "grep -ac NOSUW_BIND_RC /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    echo "  stage 侧 bind 证人行数=${NL:-0}(要 1；0 ⇒ stage 那两条前置闸有一条没过 ⇒ bind 判据按没测到算)"
    A "grep -aE 'NOSUW_BIND_RC|NOSUW_SU_AT_TGT|NOSUW_HEALTH|前置闸|不做 bind' /data/local/tmp/ksu_stage.log | cut -c1-150" | sed 's/^/    /'
    [ "${NL:-0}" = 1 ] || echo "  [!] bind 这一格没成立 ⇒ 这一发的 su 可用性判据作废，只能读名单/存活那两半"
else
    #   ★§6.566 用户决策(22:5x)：临时 root **不全局放 su**。
    #     默认形状不再跑 w135_fix.sh ⇒ 不会把 sustatic bind 成 /product/bin/su ⇒ 常见 su 路径全 clean
    #     (Momo 的文件面)。代价写死在交付口径：第三方 app 的裸 `su`/`Runtime.exec("su")` 会 ENOENT；
    #     授权 app 仍走绝对路径 /system/bin/su 的改道(§6.451 A3：`env` 绕过 mksh 预检)＋内核白名单。
    #     SU_BIND=1 才逐字重放下面这段老形状(实验/兼容用)，默认关＝一线不挂全局 su。
    if [ "${SU_BIND:-0}" = 1 ]; then
        adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
        A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
        fire "@sushd:/data/local/tmp/w135_fix.sh" 8
        WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
        A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'
    else
        echo "  ★SU_BIND 未给 ⇒ 跳过 w135_fix.sh：/product/bin/su 不落地，常见 su 路径保持全 clean"
        echo "    (要老形状给 SU_BIND=1；本步仍照常推 /data/local/tmp/sustatic，下游名字不缺)"
    fi
fi

echo "=== 5.5) ★已知死腿：把 Termux 加进名单(suw 的 @setprof) —— 从 #95 起内核必拒，只当读数跑 ==="
#   §6.231②/#95/第 110、111 发都读到 `SETPROF … rc=-1 errno=1(Operation not permitted)`：
#   **SET_APP_PROFILE 只接受 manager appid(官方 Manager，本机 uid 10104) 来写**，suw 与 root 腿都不行。
#   ⇒ 这一格真正能走的只有官方 UI：`bash kmod/ui_grant.sh <搜索词> <现取的uid> <包名>`(§6.237 已在窗口里跑通)。
#   留着这条腿只为了**每次把"它被拒"这件事打在明面上**，别拿它的 rc 当"已授权"。
if [ "${NOSUW_ON:-0}" = 1 ]; then
    echo "    ★NOSUW=1 ⇒ 整格跳过：这格的取证方式是**给 suw 派单**，而本发形状的定义就是\"不派 suw 单\"(§1.69b 副作用②)"
else
    #   ★`ksu_grant.txt` 是**固定名、跨 boot 累计**的 app 报告(例 101 同族：`tail -N` 会把上一发当本发)——
    #     第 30 发就是在这读到 `[16:43:36.952]` 那种不属本窗的行，那格读数当时**无法归因**。
    #     现在：先数派单前的行数 ⇒ 只看新增的那几行 ⇒ 并且必须有被触发方自己打的入口证人(『授权自检 … cmd=[@setprof:…]』)才算落地。
    GFILE="/sdcard/Android/data/$SUW/files/ksu_grant.txt"
    N0=$(A "wc -l < $GFILE 2>/dev/null" | tr -dc '0-9'); N0=${N0:-0}
    A "am force-stop $SUW" >/dev/null; sleep 1
    #   ★`-f 0x4000000`(CLEAR_TOP)是第 24 发抓出来的必需项：suw 已经活着时 `am start` 走
    #     "delivered to currently running top-most instance" 那条支路，MainActivity 不是 singleTop ⇒ extras 整个被丢。
    #     第 30 发就是在这**没落地**(报告里本窗零新增行)，而收尾件那份 `fire()` 早就带了这颗旗——同一个坑修了一处漏一处。
    A "am start -f 0x4000000 -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@setprof:$TGTUID:1:$TGT\"" >/dev/null 2>&1
    sleep 10
    NEW=$(A "tr -d '\\000' < $GFILE 2>/dev/null | tail -n +$((N0+1))" | tr -d '\r')
    NEWN=$(printf '%s\n' "$NEW" | grep -ac . | tr -d ' ')
    echo "    派单前 $N0 行 ⇒ 本次新增 $NEWN 行(要看入口证人『授权自检 … cmd=[@setprof:…]』在不在新增里)"
    printf '%s\n' "$NEW" | grep -aE '授权自检|SETPROF' | cut -c1-165 | sed 's/^/    /'
    [ "$NEWN" = 0 ] && echo "    [!] 零新增 ⇒ 派单没落地(例 126 那一族)：这格按\"没测到\"记，不许拿旧行当本窗读数"
    echo "    ▲ 期望就是 errno=1(EPERM) ⇒ 要授权请跑 kmod/ui_grant.sh，不是这一步"
fi

echo "=== 6) 内核侧读名单(不靠界面)：★默认只有 suw 自己，Termux/app 的格子要由 ui_grant.sh 补 ==="
A "echo $TGTUID > /data/local/tmp/w161_u1.uid; echo $SUWUID > /data/local/tmp/w161_u2.uid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
fire "@sushd:/data/local/tmp/w161_g2.sh" 8
WAITFOR /data/local/tmp/w161_g2.out 20 "=== DONE ==="
A "grep -aE 'GET_MANAGER_APPID|uid=' /data/local/tmp/w161_g2.out | head -4" | cut -c1-150 | sed 's/^/    /'

# ★#55 的**对照样本**要在成功路径也拉回来(§6.190：今晚那份成功样本因为只在空枪路径拉，
#   成功窗口里它一直躺在设备上，最后被我清理时一起删了)。带时间戳，别覆盖既有那份。
SS="$EV/w184_success_sample_$(date +%m%d-%H%M).txt"   # ★名字只算一次：原来两遍 $(date) 会跨分钟错位，而 `wc -l < "$EV"/…*.txt`  glob 命中多个文件 ⇒ ambiguous redirect
A "cat /data/local/tmp/w184_sample.out 2>/dev/null" > "$SS"
echo "  #55 成功路径对照样本已存 $SS 行数=$(wc -l < "$SS" 2>/dev/null | tr -dc '0-9')"
echo "=== 7) 可以用了吗 ==="
echo "  现在：mod=$(A 'grep -c kernelsu /proc/modules') enf=$(A getenforce) up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"
echo "  ★要让某个 app 能用 su：先跑授权(内核名单默认只有 suw)——"
echo "      adb shell pm list packages -U | grep -a <包名>        # uid 现取，重装就换"
echo "      bash kmod/ui_grant.sh <搜索词> <uid> <包名>            # 会自己抢装 fd 并重试到 32601-2"
echo "  Termux 里手敲：/system/bin/su -c id | cat  ⇒ 期望 uid=0(root)"
echo "    起 Termux：adb shell am start -n $TGT/.app.TermuxActivity"
echo "  ★窗口不持久(设计如此)：用完就 I_KNOW=1 bash kmod/w161_teardown.sh   (卸载→清→reboot→复核)"
echo "  ★别把窗口留着过夜；机器是量产机。"
fi   # ← if [ "${SKIP4:-0}" != 1 ] 的收尾(LEG1ONLY=1 时上面第 4~7 步整段跳过；本轮那几格＝未测)

echo "=== 8) 交付默认自愈(别再拿'已还原'当结论) ==="
if [ "${ARGS_KEEP:-0}" = 1 ]; then
    echo "  ARGS_KEEP=1 ⇒ 保留本轮 args：$(cat kmod/ksu_args.txt)"
else
    cp kmod/ksu_args.txt.bak_delivery kmod/ksu_args.txt
    AM=$(md5sum kmod/ksu_args.txt | cut -d' ' -f1)
    BM=$(md5sum kmod/ksu_args.txt.bak_delivery | cut -d' ' -f1)
    # ★第 72 发抓出的**没牙形状**：原来这里是 `cp 备份 现件` 之后 `diff 现件 备份`＝自己拷自己再比，
    #   恒等、永远绿，却打印"已还原默认并 diff 复证 ✓"⇒ 一个只会放行的判据(例 187①)，而且它把
    #   "设备侧到底有没有回到默认"这句话**替我说了**(实际上根本没说过)。⇒ 现在只声明它真做到的那半。
    if [ "$AM" = "$BM" ]; then
        echo "  本机 args 已复位(现算两份 md5 相等＝$AM)：$(cat kmod/ksu_args.txt)"
    else
        echo "  ★本机 args 没复位(两端 md5 不等 $AM / $BM) ⇒ 手工查"
    fi
    echo "  ★**设备侧未复证**：我们的 ko 摘了 /sys/module/kernelsu(sysfs 口没了)，运行期参数读不回来；"
    echo "    设备回到默认的唯一凭据是下一次装载时 insmod 传的现值(会印在 stage 日志里)，不是这一句。"
fi
