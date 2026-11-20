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
    echo "  未给 QUIET ⇒ 不铺 quiet 开关＝**交付(非 quiet)形状**；若这一格写的是 quiet，现在就停下去补，别开枪"
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
adb reboot
for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 10; done
sleep 40
# ★§6.307：dmesg.live 是唯一能判"从没打印"的全量件，而它每发开头就被下面这行删掉
#   ⇒ 145/147 那一发的装载期现场已经永久丢了。改法：上一发若还留着，先改名存档、不删。
PREV=$(A "wc -c < /data/local/tmp/dmesg.live 2>/dev/null" | tr -dc '0-9')
if [ -n "${PREV:-}" ] && [ "$PREV" != "0" ]; then
    TAG=$(A "date +%m%d-%H%M" | tr -dc '0-9-')
    A "mv -f /data/local/tmp/dmesg.live /data/local/tmp/dmesg.live.prev_$TAG" >/dev/null
    echo "  ★上一发的 dmesg.live($PREV 字节)没删，改名为 /data/local/tmp/dmesg.live.prev_$TAG ⇒ pull 清单里带上它，存完再删"
fi
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/dmesg.live" >/dev/null
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
    [ "${SIX:-0}" = "0" ] && { echo "  ⇒ 空枪(这一 boot 唯一一发已经花在 punch 上，不重打)：reboot 重来"; echo "     判据(§6.290 闩锁)：本 boot 见过 Permissive + 现在 enf=$ENF + pr 没了 + 无 [POST]"; echo "  ⇒ adb reboot"; exit 5; }
fi
A "grep -aE 'insmod rc|allowlist version|uts:' /data/local/tmp/ksu_stage.log | tail -4" | cut -c1-150 | sed 's/^/    /'

echo "=== 4) ★窗口中段就把 /data/adb 脚印清掉(规矩：别留到收尾，收尾时通道常已经死，§6.161④) ==="
adb push kmod/w165b_adb_clean.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w165b_adb_clean.sh; rm -f /data/local/tmp/w165b_adb_clean.out" >/dev/null
fire "@sushd:/data/local/tmp/w165b_adb_clean.sh" 10
if WAITFOR /data/local/tmp/w165b_adb_clean.out 20 "===== DONE"; then
    A "grep -aE '清之前|清之后' /data/local/tmp/w165b_adb_clean.out" | cut -c1-170 | sed 's/^/    /'
else
    echo "    [!] 清理没跑成(通道没接活) ⇒ 记进 #71，下一发窗口中段再来"
fi

echo "=== 5) bind su(交付的必要一步：没它 app 侧只有 ENOENT) ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'

echo "=== 5.5) ★已知死腿：把 Termux 加进名单(suw 的 @setprof) —— 从 #95 起内核必拒，只当读数跑 ==="
#   §6.231②/#95/第 110、111 发都读到 `SETPROF … rc=-1 errno=1(Operation not permitted)`：
#   **SET_APP_PROFILE 只接受 manager appid(官方 Manager，本机 uid 10104) 来写**，suw 与 root 腿都不行。
#   ⇒ 这一格真正能走的只有官方 UI：`bash kmod/ui_grant.sh <搜索词> <现取的uid> <包名>`(§6.237 已在窗口里跑通)。
#   留着这条腿只为了**每次把"它被拒"这件事打在明面上**，别拿它的 rc 当"已授权"。
A "am force-stop $SUW" >/dev/null; sleep 1
A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"@setprof:$TGTUID:1:$TGT\"" >/dev/null 2>&1
sleep 10
A "cat /sdcard/Android/data/$SUW/files/ksu_grant.txt 2>/dev/null | tr -d '\\000' | grep -a SETPROF | tail -2" | cut -c1-165 | sed 's/^/    /'
echo "    ▲ 期望就是 errno=1(EPERM) ⇒ 要授权请跑 kmod/ui_grant.sh，不是这一步"

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

echo "=== 8) 交付默认自愈(别再拿'已还原'当结论) ==="
if [ "${ARGS_KEEP:-0}" = 1 ]; then
    echo "  ARGS_KEEP=1 ⇒ 保留本轮 args：$(cat kmod/ksu_args.txt)"
else
    cp kmod/ksu_args.txt.bak_delivery kmod/ksu_args.txt
    if diff kmod/ksu_args.txt kmod/ksu_args.txt.bak_delivery >/dev/null 2>&1; then
        echo "  已还原默认并 diff 复证 ✓：$(cat kmod/ksu_args.txt)"
    else
        echo "  ★还原后 diff 仍不一致 ⇒ 这一句不算数，手工查 $(cat kmod/ksu_args.txt)"
    fi
fi
