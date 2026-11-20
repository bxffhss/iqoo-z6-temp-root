#!/usr/bin/env bash
# w427_cell_prep.sh —— #117 剩下那半格（"看得见字的 root 终端"）**开枪前的参数现取＋整条命令组装**。
#   ★为什么要有它（例 116/126 那一族的反面）：那一枪要两串"调用者运行时所在的 SELinux 上下文"，
#     而这两串**跨 boot/跨重装都会变**（MLS 类别由 uid 推出来），照抄文档里的串＝拿上一发的参数开枪。
#     所以参数只能现取；而且整条命令由本脚本**打印**出来给人贴，不让人手拼（手拼就会漏 SHBIN／漏两串之一）。
#   本脚本**只读只打印，绝不开枪**：不 punch、不 insmod、不 reboot，也不写设备侧任何开关文件。
#     它跑完只是把"下一步该贴的那几行"准备好；开枪仍要人自己按 I_KNOW=1 那一条。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
PKGS=${PKGS:-com.suw.manager com.termux}
fail=0

echo "=== 0) 设备现态（这一格要的是 mod=0 的干净基线；不是就先别开枪）==="
A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) bid=$(cat /proc/sys/kernel/random/boot_id)'
M=$(A 'grep -c kernelsu /proc/modules' | tr -dc '0-9')
[ "${M:-x}" = 0 ] || { echo "  [!] mod=$M ⇒ 设备上已经有 ko，先把这一窗收尾(§0 的收尾命令)再回来"; fail=1; }
# ★第二条记录只能由 ksuctl88 生成(§6.155：设备上那份旧 ksuctl 会**静默丢掉**多余的三元组 ⇒ 白烧一枪)
K88=$(A 'ls -l /data/local/tmp/ksuctl88 2>&1 | tr -s " " | cut -d" " -f1,5')
case "$K88" in
    -rwx* ) echo "  ksuctl88 在：[$K88] ⇒ 两条目分支有料(push_ksu 还会重推＋比 md5)" ;;
    * ) echo "  [x] ksuctl88 读到的形状=[$K88] ⇒ 两条目分支会静默退回单条目，这一格就不成立 ⇒ 停"; fail=1 ;;
esac

echo "=== 1) uid 现取（卸载重装就换号，别抄文档）==="
UIDS=$(A "pm list packages -U")
declare -A U
for pkg in $PKGS; do
    # ★必须按整行精确匹配：`grep -w package:com.termux` 会把 `com.termux.api` 也捞进来
    #   (`.` 是单词边界)，于是 uid 取到两个值、组装出的 DOM_MAP 中间夹一个换行——
    #   第一版就是这么差的(靠"两条"那道检查没拦住，因为它数的是"像样的行数"而不是"整串的形状")。
    line=$(printf '%s\n' "$UIDS" | grep -a "^package:$pkg uid:[0-9]*$")
    n=$(printf '%s\n' "$line" | grep -ac .)
    [ "$n" = 1 ] || { echo "  [x] $pkg 的包名行匹配到 $n 条(应为 1 条；有同名前缀的包？) ⇒ 停"; fail=1; continue; }
    uid=$(printf '%s' "$line" | sed -n 's/.*uid:\([0-9]*\)$/\1/p')
    [ -n "$uid" ] || { echo "  [x] $pkg 读不到 uid ⇒ 停"; fail=1; continue; }
    U[$pkg]=$uid
    echo "  $pkg uid=$uid"
done

echo "=== 2) 上下文串现取（不在跑就先拉起来再读；读不到就停，不许猜）==="
declare -A C
for pkg in $PKGS; do
    ctx=$(A "for p in \$(pidof $pkg); do cat /proc/\$p/attr/current | tr -d '\\000'; echo; done" | tr -d ' \r' | grep -a '^u:' | head -1)
    if [ -z "$ctx" ]; then
        echo "  [$pkg] 没在跑 ⇒ 拉起来重读一次"
        A "monkey -p $pkg -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
        sleep 6
        ctx=$(A "for p in \$(pidof $pkg); do cat /proc/\$p/attr/current | tr -d '\\000'; echo; done" | tr -d ' \r' | grep -a '^u:' | head -1)
    fi
    case "$ctx" in
        u:* ) echo "  [$pkg] ctx=$ctx" ;;
        * ) echo "  [x] [$pkg] 读不到上下文串(实得=[$ctx]) ⇒ 停：这一枪的参数不能猜"; fail=1 ;;
    esac
    C[$pkg]=$ctx
done

echo "=== 3) 组装 DOM_MAP 并按 go.sh 的五道校验预检（go.sh 自己还会再验一遍）==="
MAP=""
for pkg in $PKGS; do
    [ -n "${U[$pkg]:-}" ] && [ -n "${C[$pkg]:-}" ] || continue
    [ -n "$MAP" ] && MAP="$MAP;"
    MAP="$MAP${U[$pkg]}=${C[$pkg]}"
done
# ★整串形状闸（不是"数像样的行数"）：第一版让 `10667\n10817=…` 这种夹换行的串过了预检，
#   因为那道只 grep 出"条数=2"就放行；换行到了 go.sh 那边是 base64 铺成**三行文件**，
#   dom_for 那条 `^uid ` 就永远配不上 ⇒ 静悄悄少一条映射，比直接报错更坏。
SHAPE_OK=$(printf '%s' "$MAP" | grep -cE '^[0-9]+=u:[^;[:space:]]+;[0-9]+=u:[^;[:space:]]+$')
if [ "$SHAPE_OK" != 1 ]; then
    echo "  [x] DOM_MAP 整串形状不合格(要 10342=u:…;10667=u:…，实得=[$MAP]) ⇒ 停"
    echo "      现算的两串：${U[com.suw.manager]:-?}=${C[com.suw.manager]:-?} ／ ${U[com.termux]:-?}=${C[com.termux]:-?}"
    fail=1
fi
BAD=$(printf '%s' "$MAP" | tr -d -- '-A-Za-z0-9._,:;=')
if [ -n "$BAD" ]; then echo "  [x] 组装出的串含非法字符 [${BAD}] ⇒ 停"; fail=1; fi
if [ "${#MAP}" -gt 300 ]; then echo "  [x] DOM_MAP 总长 ${#MAP} 异常(串可能被截断或粘错) ⇒ 停"; fail=1; fi
N=$(printf '%s' "$MAP" | tr ';' '\n' | grep -acE '^[0-9]+=u:.+')
[ "$N" = 2 ] || { echo "  [x] 期望两条 <uid>=<u:…>，实得 $N 条 ⇒ 停"; fail=1; }
if [ "${C[com.suw.manager]}" = "${C[com.termux]}" ]; then
    echo "  [!] 两串相同 ⇒ 这一格的形状差没了(两条记录会同域)；先想清楚要不要照打(不算错，但结论会退化)"
fi
# ★第二条记录的**生产者**：设备侧开关 /data/local/tmp/ksu_two_profiles 不存在 ⇒ stage 走单条目分支
#   (§6.155/§6.156 那条)⇒"每条记录各自的域"这一格根本不成立，而 go.sh 里没人造这个文件(例 116：形状词没生产者)。
TWO_PKG=${TWO_PKG:-com.termux}
TWO_UID=${U[$TWO_PKG]:-}
if [ -z "$TWO_UID" ]; then
    echo "  [x] 追加条目要的 $TWO_PKG 没读到 uid ⇒ 停(这一格必须有第二条记录)"
    fail=1
else
    TWO_SPEC="$TWO_UID:$TWO_PKG"
    echo "  追加条目(要写进开关 ksu_two_profiles)=[$TWO_SPEC]  ★主条目(suw ${U[com.suw.manager]:-?})由 stage 自己写、不在开关里"
fi
echo "  预检$( [ "$fail" = 0 ] && echo 通过 || echo 未通过 )：DOM_MAP=$MAP"

echo
echo "=== 4) 下一步照贴这几行（本脚本一行都没执行）==="
echo "--- (a) 开枪（实验形状：两把开关都给；args 一律不动）---"
echo "I_KNOW=1 DOM_MAP='$MAP' SHBIN=/data/local/tmp/zzsh bash kmod/go.sh"
echo "    ★zzsh 要在**开枪前**由 adb shell 铺好(shell 域能 cp 不能贴标签，标签由 stage 在 Permissive 期贴)："
echo "      adb shell 'rm -f /data/local/tmp/zzsh; cp /system/bin/sh /data/local/tmp/zzsh; chmod 755 /data/local/tmp/zzsh'"
echo "    ★第二条记录的开关($TWO_SPEC)：不给 ⇒ stage 走单条目分支，这一格直接不成立(§6.156)。铺完必须逐字读回："
echo "      adb shell 'printf %s $TWO_SPEC > /data/local/tmp/ksu_two_profiles; cat /data/local/tmp/ksu_two_profiles; echo; ls -l /data/local/tmp/ksu_two_profiles'"
echo "--- (b) 判活之后（跟随器过线）再跑这三条腿，顺序不能换 ---"
echo "    1. @sushd 腿(要 root 的都排在这儿)：先 chmod 755 再派单"
echo "       adb shell 'chmod 755 /data/local/tmp/<你的腿>.sh; am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"@sushd:/data/local/tmp/<你的腿>.sh\"'"
echo "    2. 最后一条 @sushd 腿＝恢复执法：kmod/w426_enforce.sh（之后 @sushd 全部会 errno=13）"
echo "    3. 判据腿走不需要 socket 的那条：--es cmd \"@su:id; cat /proc/self/attr/current\"（打 suw 那一次）"
echo "       ★注意这条的调用者是 suw(uid 10342)，它只证 suw 那一条记录的域；Termux 那条不能由它代打"
echo "    4. Termux 那条要打在**它自己的终端**里(否则『看得见字』无从判)："
echo "       adb shell 'am start -n com.termux/.app.TermuxActivity; sleep 3; input text su; input keyevent 66; sleep 3'"
echo "       判据＝screencap 存图 + uiautomator dump 里出现 # 提示符与其后命令的输出(空格要用 %s，别用 %20)"
echo "--- (c) 这一格真正的末端判据（缺一边都不算答案）---"
echo "    正：两条记录各自的壳里 id=uid=0 且 attr/current 逐字等于上面那个 uid 对应的那一串；"
echo "        而『看得见字』＝Termux 屏上出现 # 提示符与该命令的输出 ⇒ 判据取**截图/uiautomator**，不取文件字节数"
echo "    负：★这一格两条 uid 都在映射表里 ⇒ 发内**拿不到**『没映射⇒退回全局 DOM』那半边；"
echo "        那半边只在离线自测 run_dommap.sh(④/⑤) 里证。想在发内拿到负半边就得只给一条映射，那是另一格，别混进这一格(例 119)"
echo "--- (d) 收尾：卸载→清载荷→reboot→复核（临时 root 不留过夜）；之后要核的参数已随转录存证 ---"

[ "$fail" = 0 ] && echo "=== w427_cell_prep：参数已现取、命令已组装（没执行任何东西）===" || echo "=== w427_cell_prep：有红项 ⇒ 先修，别开枪 ==="
[ "$fail" = 0 ]
