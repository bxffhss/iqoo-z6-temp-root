#!/usr/bin/env bash
# w597_arm_selftest.sh —— 第 47 发那三条腿(属主判据 A/B)的**双向**静态闸。
#   ★为什么要给"打字腿"配静态牙：这几条腿的失败形状全是**静默**的——
#     空格写成 %20、命令里带了引号或 >、暖行用了 #、"文件必须不在"那道闸去 grep 路径本身
#     (而 ls 的错误消息里就带路径 ⇒ 不存在也命中)——每一种都会让 B 臂报出"没提权"这种**看起来像结论**的读数。
#   所以每条牙都配一个**正夹具**(必须过)和一个**负夹具**(必须被拒)，缺一边就红。
set -u
cd "$(dirname "$0")/.." || exit 1
T=kmod/_tmp_selftest_rdst; mkdir -p "$T"
ok=0; bad=0
say_ok()  { echo "  [OK] $1"; ok=$((ok+1)); }
say_bad() { echo "  [BAD] $1"; bad=$((bad+1)); }

# 一条牙 = 一个正则 + 该文件必须命中；再用一段"故意写坏"的夹具证明这个正则会拒
tooth() { # $1=说明 $2=被检文件 $3=必须存在的正则 $4=负夹具内容
    local name=$1 f=$2 pat=$3 neg=$4
    if ! grep -qaE "$pat" "$f"; then say_bad "$name：真件里找不到 [$pat]"; return; fi
    printf '%s\n' "$neg" > "$T/w597_neg.sh"
    if grep -qaE "$pat" "$T/w597_neg.sh"; then
        say_bad "$name：负夹具竟然也过了(说明这条牙没牙)"
    else
        say_ok "$name(正反两边都验过)"
    fi
    rm -f "$T/w597_neg.sh"
}

echo "=== 1) w591_su_arm.sh：打字形状 ==="
L=kmod/w591_su_arm.sh
[ -s "$L" ] || { echo "  [x] 没有 $L"; exit 1; }
# ★原来这条只 grep "任何一行 input text 里有 %s"，而暖行本身就带 %s ⇒ CMD 写成 %20 也能蒙过。改成**钉在 CMD 那一行**上。
tooth "CMD 那一行自己用 %s(不是 %20)" "$L" "^CMD='[^']*%s[^']*'$" "CMD='/system/bin/su%20-c%20/data/local/tmp/x.sh'"
tooth "空格用 %s 不用 %20" "$L" 'input text [^;]*%s' 'input text /system/bin/su%20-c%20/data/local/tmp/x.sh'
# ★这条原来写成 "^CMD='" ⇒ 只证明"有这么个赋值"，证明不了它干净(假牙)。改成：必须是**单引号包住的绝对路径、里面没有空格/引号/>**。
tooth "CMD 是单引号绝对路径且不含空格、引号、()、>(打字腿的形状)" "$L" "^CMD='/[^' ()>]*'$" "CMD='/system/bin/su -c /data/local/tmp/x.sh > /dev/null'"
tooth "暖行不用 #(mksh 词首注释会截断)" "$L" 'input text echo%swarm' 'input text %23warm; input keyevent 66'
tooth "存在性闸只认 PRESENT/ABSENT 整行" "$L" 'test -e \$M && echo PRESENT \|\| echo ABSENT' 'if A "ls $M" | grep -qa "$M"; then echo PRESENT; fi'

echo "=== 2) w590_enf_marker.sh：属主判据的形状 ==="
P=kmod/w590_enf_marker.sh
[ -s "$P" ] || { echo "  [x] 没有 $P"; exit 1; }
tooth "自己 touch marker" "$P" 'touch "\$M"' 'echo hi > "$L"'
tooth "落盘件 chmod 666(否则 adb 读不回)" "$P" 'chmod 666 "\$L"' '#!/system/bin/sh
id'
tooth "自报 id 与 uid=(属主读数的第二条腿)" "$P" '^ *id$' 'echo done'
tooth "远端路径全用绝对单前导 /" "$P" '^M=/data/local/tmp/' 'M=tmp/w590_marker'

echo "=== 3) w589_watch_arm.sh：证人必须在恢复执法**之前**就位 ==="
W=kmod/w589_watch_arm.sh
[ -s "$W" ] || { echo "  [x] 没有 $W"; exit 1; }
tooth "起的是 dmesg -w(流式)不是 dmesg -c" "$W" 'dmesg -w' 'dmesg -c > /dev/null'
tooth "打印 follower_pid(否则无法证明它真的在了)" "$W" 'follower_pid=\$FP' 'echo started'
tooth "日志 chmod 666(执法后只能 adb 侧读)" "$W" 'chmod 666 "\$LIVE"' '#!/system/bin/sh
nohup dmesg -wT > /data/local/tmp/x.log 2>&1 &'

echo "=== 4) 排序不变量(§6.406/§6.407 定的规矩)：**工具件**不许进清理名单(按 token 判，不按行) ==="
# 一手教训 1(§6.406)：第 47 发把 /data/local/tmp/w426_enforce.sh 收进 T3_RM ⇒ 第 48 发收尾把它删了，
#   "恢复执法不干活"的假象同一发演了两次。
# 一手教训 2(§6.407)：这一发才发现上一版这条牙**只查了生成名单那一半**——T3_RM 是"一行里全是 token"的形状，
#   按行首正则永远匹配不上 ⇒ 一条永远绿的牙比没有牙更糟(例 157/163 同族)。现在改成先取名单块、再按 token 精确比对。
KEEP49="w426_enforce.sh w165b_adb_clean.sh w558_rm3.sh w589_watch_arm.sh w625_seedrestart.sh"
# 同一个函数同时供"真读数"与"反夹具"用(例 157：夹具不许另写一套匹配式，否则它验的是夹具不是牙)
extract_lists() {
    {   grep -o "^T3_RM='[^']*'" "$1" | sed "s/^T3_RM='//; s/'\$//"
        sed -n '/^for F in /,/^done/p' "$2" | tr -d '\\'
    } | tr ' \n' '\n\n' | grep -a '^/data/local/tmp/'
}
member() { printf '%s\n' "$2" | grep -Fxc "$1"; }   # $1=完整路径 token，$2=名单
LISTS=$(extract_lists kmod/w161_teardown.sh kmod/w558_rm3.sh)
[ -n "$LISTS" ] || say_bad "抽取后名单是空的(⇒ 这条牙没有证人，别看它绿)"
say_ok "名单抽取出来 $(printf '%s\n' "$LISTS" | grep -ac .) 个 token(条数由产生者现数)"
for K in $KEEP49; do
    H=$(member "/data/local/tmp/$K" "$LISTS")
    if [ "${H:-0}" = 0 ]; then say_ok "工具件 $K 不在清理名单里(token 级比对)"
    else say_bad "工具件 $K 还在清理名单里(命中 $H)⇒ 收尾会吃掉下一发的腿"; fi
done
# 反夹具：两种"名单形状"都要被**同一个 extract_lists** 抓到(一行多 token 的 T3_RM 形状 ＋ 缩进续行形状)
printf "T3_RM='/data/local/tmp/x.sh /data/local/tmp/w625_seedrestart.sh'\n" > "$T/w597_neg1.txt"
printf "T3_RM='/data/local/tmp/w426_enforce.sh /data/local/tmp/x.out'\n" > "$T/w597_neg3.txt"
: > "$T/w597_neg_empty.sh"
printf 'for F in \\\n    /data/local/tmp/w589_watch_arm.sh \\\n    /data/local/tmp/y.out; do\ndone\n' > "$T/w597_neg2.sh"
A1=$(member "/data/local/tmp/w625_seedrestart.sh" "$(extract_lists "$T/w597_neg1.txt" "$T/w597_neg_empty.sh")")
A2=$(member "/data/local/tmp/w589_watch_arm.sh" "$(extract_lists "$T/w597_neg_empty.sh" "$T/w597_neg2.sh")")
A3=$(member "/data/local/tmp/w426_enforce.sh" "$(extract_lists "$T/w597_neg3.txt" "$T/w597_neg_empty.sh")")
rm -f "$T/w597_neg1.txt" "$T/w597_neg2.sh" "$T/w597_neg3.txt" "$T/w597_neg_empty.sh"
if [ "${A1:-0}" = 1 ] && [ "${A2:-0}" = 1 ] && [ "${A3:-0}" = 1 ]; then
    say_ok "反夹具生效：同一个抽取函数抓得到(T3_RM 末位＝$A1／续行＝$A2／T3_RM **首位**＝$A3)"
else say_bad "反夹具没被抓到(A1=$A1 A2=$A2 A3=$A3)⇒ 这条牙是假的(首位/末位被引号粘住就是这类的洞)"; fi

echo "=== 7) 第 49 发候选腿 w625_seedrestart.sh 的形状(有界＋守卫＋不常驻) ==="
Z=kmod/w625_seedrestart.sh
if [ -s "$Z" ]; then
    if grep -qa 'ROUNDS=\${1:-6}' "$Z" && grep -qa 'zygote' "$Z" && grep -qa 'chmod 666' "$Z"; then
        say_ok "w625 三口都在(有界默认 6 轮／守卫拒 zygote／落盘 666)"
    else say_bad "w625 少了三口之一 ⇒ 它可能常驻、也可能往 zygote 写"; fi
    if grep -qa 'while : ; do' "$Z"; then say_bad "w625 里有无限循环(它必须自己退)"; else say_ok "w625 无死循环(反夹具：真出现 while : 就会红)"; fi
else say_bad "没有 $Z"
fi

echo "=== 7b) #180 那三把闸必须在，且**腿/打包器/入口件**三处写的数一致 ==="
#   为什么单独一条：闸拦的是"用户连敲"，而用户是照**文案**敲的。腿里默认改成 30 而文案还写 150，
#   症状＝"这条腿拒了／不干活"，跟例 168 那一族"被自己的闸拒了却读成通道坏"一模一样。
gate_vals() {   # 从腿里现抽默认值(条数与取值都由产生者给，不抄我记得的数)
    # ★第一版写成 `^COOL=${3:\([0-9]*\)}` 漏了 `:-` ⇒ 抽出来是空的，cons 直接判"不一致"——
    #   那条 [BAD] 是**抽取器坏**，不是文案坏。抽取类读数打空要先怀疑匹配式(例 161)。
    sed -n 's/^COOL=${3:-\([0-9]*\)}$/\1/p; s/^MAXRUNS=${4:-\([0-9]*\)}$/\1/p' "$1" | tr '\n' ' '
}
cons() {        # 被测函数与反夹具**共用**这一条(例 170：夹具不复用被测函数就等于没验到)
    # $1=腿 $2=打包器 $3=入口件 ⇒ 输出 0=一致 1=不一致
    set -- "$1" "$2" "$3"
    V=$(gate_vals "$1"); C=$(echo "$V" | cut -d' ' -f1); M=$(echo "$V" | cut -d' ' -f2)
    [ -n "$C" ] && [ -n "$M" ] || return 1
    grep -qa "${C} 秒" "$2" || return 1
    grep -qa "${M} 次" "$2" || return 1
    grep -qa "${C} 秒" "$3" || return 1
    grep -qa "${M} 次" "$3" || return 1
    return 0
}
G3=0
for GT in SR-COOL SR-BUDGET SR-ALREADY; do grep -qa "$GT" "$Z" && G3=$((G3 + 1)); done
if [ "$G3" = 3 ]; then say_ok "三把闸的读数词元都在(3/3)：连敲有硬闸挡(§6.409 那发是连着敲之后硬复位的)"
else say_bad "只有 $G3/3 把闸 ⇒ 连敲没有硬闸挡"; fi
# ★这里踩过一次(记进例 170 那一族)：上面那个循环变量以前叫 T，把本件的临时目录 $T 顶成了 "SR-ALREADY"
#   ⇒ 两份反夹具 sed 写不出去、cons 拿到空文件"判不一致"，两条反夹具**假装生效**。所以现在每条都先断言夹具件在且非空。
fx() { # $1=夹具名 $2=sed 脚本 ⇒ 生成夹具并硬断言它真的生成了(空/缺 ⇒ 这条牙不作数)
    sed "$2" "$Z" > "$T/$1"
    if [ ! -s "$T/$1" ]; then say_bad "夹具 $1 没生成(空或缺)⇒ 用它做的反夹具不算数"; return 1; fi
    return 0
}
NV=$(gate_vals "$Z" | wc -w)
[ "$NV" = 2 ] || say_bad "抽取只拿到 $NV 个默认值(必须 2 个：冷却秒数＋次数上限)⇒ 这条一致性牙没有证人，别看它绿"
if cons "$Z" kmod/w431_pack_z6root.sh kmod/z6root.sh; then
    say_ok "腿默认($(gate_vals "$Z"))与打包器文案、入口件文案逐字一致(两处都要有那个秒数和次数)"
else say_bad "文案里的秒数/次数与腿的默认($(gate_vals "$Z"))不一致 ⇒ 用户照文案敲会被闸拒(读起来像腿坏了)"; fi
# 反夹具：只改腿里的默认，cons 必须当场红(证明这条牙真的在比数值，不是恒绿)
fx w597_leg_cool31.sh 's/^COOL=${3:-150}$/COOL=${3:-31}/' && {
    if cons "$T/w597_leg_cool31.sh" kmod/w431_pack_z6root.sh kmod/z6root.sh; then
        say_bad "反夹具没生效：把腿的冷却改成 31 秒，cons 还判一致 ⇒ 这条牙是恒绿的"
    else say_ok "反夹具生效：改腿的冷却默认(150→31)后 cons 判不一致"; fi
}
fx w597_leg_runs7.sh 's/^MAXRUNS=${4:-6}$/MAXRUNS=${4:-7}/' && {
    if cons "$T/w597_leg_runs7.sh" kmod/w431_pack_z6root.sh kmod/z6root.sh; then
        say_bad "反夹具没生效：把腿的次数上限改成 7，cons 还判一致"
    else say_ok "反夹具生效：改腿的次数上限(6→7)后 cons 判不一致"; fi
}
fx w597_leg_nocool.sh '/SR-COOL/d' && {
    G2=0
    for GT in SR-COOL SR-BUDGET SR-ALREADY; do grep -qa "$GT" "$T/w597_leg_nocool.sh" && G2=$((G2 + 1)); done
    if [ "$G2" = 2 ]; then say_ok "反夹具生效：删掉冷却闸那两行后，同一个计数器读出 $G2/3(不是恒 3)⇒ 上面那条 3/3 真的在数闸"
    else say_bad "反夹具不符期望(实得 $G2，应为 2)⇒ 那条 3/3 的计数不可信"; fi
}
echo "=== 汇总：[OK]=$([ $ok -gt 0 ] && echo $ok) [BAD]=$bad ==="
if [ $bad -gt 0 ]; then echo "FAIL(有牙不过 ⇒ 停)"; exit 1; fi
if [ $ok -lt 10 ]; then echo "FAIL(证据行太少 $ok ⇒ 像空跑)"; exit 1; fi
echo "PASS：w597 全部 $ok 条牙双向验过"
