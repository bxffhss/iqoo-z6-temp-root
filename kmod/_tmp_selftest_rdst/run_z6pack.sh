#!/usr/bin/env bash
# run_z6pack.sh —— z6root 一键包的**离线**忠实性闸（不碰设备、不开窗）。
#   为什么值得单独测：这个包宣称"镜像已验证的链"，而镜像的全部风险都在**抄漏/抄错**上
#   （例 111/116/126：驱动方式一变，某个副作用静悄悄没了 ⇒ 跑成另一种形状还不报错）。
#   所以这里测的不是"脚本语法对不对"（那由设备 mksh `sh -n` 管），而是：
#     ①punch 的参数串与 bootstrap 里那条**逐 token 相同**（除了 $TMP/$SLIDE 这两个必然不同的占位）；
#     ②交付形状的四把必备件都在这条路上：落点从 args 反推、抢装看门狗、实验开关全删、判据⑥有等待；
#     ③清单里每个载荷都被脚本真用到（没有"包里有但没人读"的孤儿件，也没有"用了但包里没"的缺件）；
#     ④非注释行里不许有反引号（例 76 第三次复发就是这么把证人文案吃掉的）；
#     ⑤可执行件一律带 $TMP 全路径；⑥计数证人要锁来源那一行；
#     ⑦slide 设备侧自解三件齐、表与 kallsyms/PC 求解器同源（#146）；
#     ⑧FDKA(常驻补装驱动 fd)在包侧真被打开、开关进了删净清单、且包内 stage 与源逐字节同一份。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=$(mktemp -d)
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

Z=kmod/z6root.sh
P=suw_apk/bootstrap.sh
K=z6root/MANIFEST
[ -r "$Z" ] || { echo "[x] 被测件不在：$Z"; exit 1; }
[ -r "$P" ] || { echo "[x] 对照件不在：$P"; exit 1; }
[ -r "$K" ] || { echo "[x] 清单不在：$K ⇒ 先跑 bash kmod/w431_pack_z6root.sh"; exit 1; }

# ---------- ① punch 参数串逐 token 对表 ----------
# 对照件里那条：'./pr $SLIDE hammer hijack shape2 sen victim shell ph2=0 ... post=/data/local/tmp/ksu_post.sh'
grep -a 'post=' "$P" | grep -aoE 'pr \$SLIDE .*post=[^ ]+ksu_post\.sh' | head -1 \
    | sed 's#pr \$SLIDE ##; s#post=/data/local/tmp/ksu_post.sh##; s#  *# #g; s# ##g' > "$W/ref_tokens"
# 被测件里那条
grep -a 'post=' "$Z" | grep -aoE 'pr \$SLIDE .*post=\$TMP/ksu_post\.sh' | head -1 \
    | sed 's#pr \$SLIDE ##; s#post=\$TMP/ksu_post.sh##; s#  *# #g; s# ##g' > "$W/our_tokens"
REF=$(cat "$W/ref_tokens"); OUR=$(cat "$W/our_tokens")
[ -n "$REF" ] || { echo "[x] 对照件的 punch 行没切出来(锚失效) ⇒ 下面的比对无意义"; exit 1; }
[ -n "$OUR" ] || { echo "[x] 被测件的 punch 行没切出来(锚失效)"; exit 1; }
echo "  对照 tokens=[$REF]"
echo "  本包 tokens=[$OUR]"
chk "①punch 参数与 bootstrap 那条**逐字相同**(slide/post 两个占位除外)" "$([ "$REF" = "$OUR" ] && echo 1 || echo 0)"
# 有牙的反证：故意少一个 token 必须不等(否则这条断言是摆设)
SHORT=$(printf '%s' "$OUR" | sed 's/hijack//')
chk "①b 反证：去掉一个 token 后必须判不等(证明①真在比内容)" "$([ "$REF" != "$SHORT" ] && [ -n "$SHORT" ] && echo 1 || echo 0)"
chk "①c shots/maxr/rounds 三档都带上了(少任何一档=punch 形状变)" "$(printf '%s' "$OUR" | grep -q 'shots=25' && printf '%s' "$OUR" | grep -q 'maxr=8' && printf '%s' "$OUR" | grep -q 'rounds=200' && echo 1 || echo 0)"

# ---------- ② 交付形状的四把必备件 ----------
chk "②落点/标签从 args 反推(不靠我记得，§6.228⑨)" "$(grep -aq 'ksu_ksud_path=' "$Z" && grep -aq 'ksu_redirect_dst' "$Z" && echo 1 || echo 0)"
chk "②标签必须是 plain s0(带类别在执法下挡 execute，第 104 发)" "$(grep -aqF 'u:object_r:apk_data_file:s0"' "$Z" && ! grep -aqE 'apk_data_file:s0:c' "$Z" && echo 1 || echo 0)"
chk "②抢装看门狗开关要 touch(否则官方 Manager 首页=不支持⇒用户没有授权入口)" "$(grep -aq 'touch "$TMP/ksu_race_fd"' "$Z" && echo 1 || echo 0)"
SW_MISS=""
for s in ksu_quiet_after_insmod ksu_quiet_fixcfi ksu_dom ksu_dom_map ksu_shbin ksu_two_profiles ksu_ap_key ksu_skip_insmod; do
    grep -aq "$s" "$Z" || SW_MISS="$SW_MISS $s"
done
chk "②实验开关全被删(quiet/dom/dom_map/shbin/two_profiles/ap_key/skip_insmod) 缺=[${SW_MISS:-无}]" "$([ -z "$SW_MISS" ] && echo 1 || echo 0)"
#   ★原来这道查的是字面量 `rm -f "$TMP/ksu_quiet_after_insmod"`；#145 之后删与复证共用 $SWITCH_FILES
#     (两处各写一份字面量时会"删 11 复证 6"，残留没人看) ⇒ 现在要求：清单只定义一次，rm 与 ls 都点它。
SWDEF=$(grep -ac '^SWITCH_FILES=' "$Z")
chk "②删了还要读回，而且删/复证共用同一份清单(SWITCH_FILES 定义=$SWDEF 次，rm 与 ls 都点它)" \
    "$([ "$SWDEF" = 1 ] && grep -aqF 'rm -f $SWITCH_FILES' "$Z" && grep -aqF 'ls $SWITCH_FILES' "$Z" && echo 1 || echo 0)"
chk "②判据⑥有等待循环，等不到就明说这是空枪且本 boot 已花掉" "$(grep -aq '判据⑥' "$Z" && grep -aqF '唯一一发已花掉' "$Z" && echo 1 || echo 0)"
chk "②起点闸：mod≠0 直接停(铁律 1，不许同 boot 重打)" "$(grep -aqF '[ "$MOD" = 0 ]' "$Z" && grep -aq '先 reboot' "$Z" && echo 1 || echo 0)"
chk "②slide 解不出来必须停(绝不猜)" "$(grep -aqF '没解出 slide' "$Z" && echo 1 || echo 0)"
chk "③交付口径写的是绝对路径(裸 su 命中 /product/bin/su＝静态 su→agent 那条路：执法下不提权、Permissive 窗内实测提权 ⇒ 判据一律用绝对路径)" "$(grep -aq '/system/bin/su -c' "$Z" && grep -aq '/product/bin/su' "$Z" && echo 1 || echo 0)"

# ---------- ③ 清单 ↔ 消费者 对表 ----------
#   ★"消费者"是两个：z6root.sh 自己，以及被它铺上去的 stage(ksu_one_stage.sh)——
#     ksu_stage.txt/ksud/kernelsu.ko 这些是 stage 读的，只查前者会把正常包判成孤儿(假红)。
# ★豁免表必须是**机器可查**的(例 129：豁免标记自己也要有牙)：每条写"名字:给谁用"，
#   且这个名字**确实出现在清单里**才有效——清单里没它就说明这条豁免是悬空的(下面单独一格判)。
#   为什么这两个算"有人读"：`教程.txt` 是给人读的文档；`suw_manager.apk` 是教程第 2 步让用户手工装的
#   (脚本自己不装 APK)——它们天生不会出现在 z6root.sh 的字符串里。
NOCON="教程.txt:给人读的文档 suw_manager.apk:教程第2步手工装"
MISS=""; WHO=""; dangling=""
while read D SZ MD5; do
    [ -n "$D" ] || continue
    if grep -aq "$D" "$Z"; then
        WHO="$WHO $D:z6root"
    elif grep -aq "$D" kmod/ksu_one_stage.sh; then
        WHO="$WHO $D:stage"
    elif printf '%s
' $NOCON | grep -aq "^$D:"; then
        WHO="$WHO $D:$(printf '%s
' $NOCON | grep -a "^$D:" | cut -d: -f2)"
    else
        MISS="$MISS $D"
    fi
done < "$K"
for e in $NOCON; do
    n=${e%%:*}; grep -aq "^$n " "$K" || dangling="$dangling $n"
done
chk "③清单里每个载荷都有指名消费者或**在豁免表里**(缺=$MISS 悬空豁免=$dangling) 缺件＝拷过去也没人读" "$([ -z "$MISS" ] && [ -z "$dangling" ] && echo 1 || echo 0)"
# 反夹具：随便造一个没人读的名字塞进清单，同一条检查必须报缺(证明它不是摆设)
cp "$K" "$W/K2"; printf 'zz_no_consumer_zz 1 deadbeef\n' >> "$W/K2"
M2=""
while read D SZ MD5; do
    grep -aq "$D" "$Z" || grep -aq "$D" kmod/ksu_one_stage.sh || printf '%s
' $NOCON | grep -aq "^$D:" || M2="$M2 $D"
done < "$W/K2"
chk "③b 反夹具：往清单里塞一个没人读的名字 ⇒ 必须报缺(实报[${M2:-空}])" "$([ "$M2" = " zz_no_consumer_zz" ] && echo 1 || echo 0)"
echo "  消费者归属：$WHO"

# ---------- ④ 反引号(非注释行) ----------
NB=$(grep -v '^[[:space:]]*#' "$Z" | grep -c '`')
chk "④非注释行里反引号必须 0(实得 $NB)——echo 里它会真执行" "$([ "$NB" = 0 ] && echo 1 || echo 0)"
# 收尾句必须存在(它是这一跑的唯一"我跑完了"证人)
chk "④有自带时刻的收尾句 Z6ROOT_DONE(判据不能只看退出码)" "$(grep -aq 'Z6ROOT_DONE' "$Z" && echo 1 || echo 0)"

# ---------- ⑤ 可执行件一律要带 $TMP 全路径（10-20 预演一手：裸写 perfips 得到 `inaccessible or not found`） ----------
BARE=$(grep -cE '^[[:space:]]+(pr|perfips|shd|ksuctl|ksuctl88|sustatic|ksud|ksu_post\.sh|w135_fix\.sh)[[:space:]]' "$Z"; true)
chk "⑤没有裸调用的载荷件(实得 ${BARE:-0} 行)——mksh 的 PATH 里不含 \".\"，裸写必失败" "$([ "${BARE:-0}" = 0 ] && echo 1 || echo 0)"
chk "⑤b 正对照：TMP 全路径那两条调用真存在(证明上一条不是拿空判据蒙过)" "$(grep -aqF '"$TMP/perfips" 25' "$Z" && grep -aqF '"$TMP/pr" ' "$Z" && echo 1 || echo 0)"
# 反夹具：造一份把 perfips 改成裸调用的副本 ⇒ ⑤ 必须报红(否则这条断言是摆设)
sed 's#"\$TMP/perfips" 25#perfips 25#' "$Z" > "$W/bare.sh"
B2=$(grep -cE '^[[:space:]]+(pr|perfips|shd|ksuctl|ksuctl88|sustatic|ksud|ksu_post\.sh|w135_fix\.sh)[[:space:]]' "$W/bare.sh"; true)
chk "⑤c 反夹具：把全路径改成裸调用 ⇒ 同一条检查必须报红(实得 $B2 行)" "$([ "${B2:-0}" -ge 1 ] && echo 1 || echo 0)"

# ---------- ⑥ 计数类证人必须连"来源那一行"一起锁死（第 28 发一手：`count=0` 那次假证人） ----------
chk "⑥名单读数取自『allowlist: NEW_GET_ALLOW_LIST rc=0』那一行(不是随便 grep count=)" "$(grep -aqF "allowlist: NEW_GET_ALLOW_LIST rc=0" "$Z" && echo 1 || echo 0)"
chk "⑥b 反夹具：老的『裸抓 count=』那种写法不许回来(它会抓到 EPERM 那行的 count=512)" "$(grep -aqF "grep -aoE 'count=[0-9]+'" "$Z" && echo 0 || echo 1)"

# ---------- ⑦ slide 设备侧自解（#146）：包里必须自带求解器，且第 5 步是"把采样交给驱动" ----------
#   为什么这一组值得测：slide 是全链条唯一"错了不报错还烧一发"的输入(错的基址交给 punch ⇒
#   症状只是机器复位)。而第一版的形状是"perfips 自己会打 SLIDE"——那是我对 PC 侧算法的
#   **错误印象**(perfips 从来只打候选行)，所以这里既查"三件齐/表形状对"，也查
#   "老那句错误口径没回来"。
chk "⑦包内三件齐：slide_solve.sh／ksu_slide.awk／slide_ctl.txt" "$([ -s z6root/slide_solve.sh ] && [ -s z6root/ksu_slide.awk ] && [ -s z6root/slide_ctl.txt ] && echo 1 || echo 0)"
chk "⑦b 清单里也登记了这三件(漏登记=设备上第 1 步不会拷它)" "$(grep -aq '^slide_solve\.sh ' z6root/MANIFEST && grep -aq '^ksu_slide\.awk ' z6root/MANIFEST && grep -aq '^slide_ctl\.txt ' z6root/MANIFEST && echo 1 || echo 0)"
NW=$(grep -acvE '^#|^$' z6root/slide_ctl.txt)
chk "⑦c 正对照窗口条数 ≥5(实得 $NW)" "$([ "${NW:-0}" -ge 5 ] && echo 1 || echo 0)"
chk "⑦d 表头进制形状对(地址 16 位 hex、step 是十进制)" "$(grep -aqE '^# CONSTS link_text=[0-9a-f]{16} link_etext=[0-9a-f]{16} step_dec=[0-9]+$' z6root/slide_ctl.txt && echo 1 || echo 0)"
chk "⑦e z6root 第 5 步真的调驱动" "$(grep -aqF '"$TMP/slide_solve.sh"' "$Z" && echo 1 || echo 0)"
chk "⑦f 反夹具：『把 perfips 输出直接当求解结果』那句老口径不许回来(它只打过候选行，从没打过 SLIDE)" "$(grep -aqF '"$TMP/perfips" 25 > "$TMP/ipk.txt"' "$Z" && echo 0 || echo 1)"
# 单一来源：正对照名单必须由生成器从 PC 求解器里**抠**出来，而不是两处各抄一份
chk "⑦g 生成器里不抄函数名(它只从 slide_pc.py 抠 CTRL)" "$(grep -aq 'el0_svc_common' kmod/w436_mkctl.py && echo 0 || echo 1)"
chk "⑦h 正对照：PC 求解器里确有那份名单(上一条才不是空判据)" "$(grep -aq 'el0_svc_common' analysis/slide_pc.py && echo 1 || echo 0)"
KS=analysis/kallsyms_g2a88cd145def.txt
NMISS=0
while read -r A L NM; do
    case "$A" in ''|\#*) continue ;; esac
    grep -aq "^$A " "$KS" || NMISS=$((NMISS + 1))
done < z6root/slide_ctl.txt
chk "⑦i 表里每条地址都在出货 kallsyms 里(表与树没分叉；漏 $NMISS 条)" "$([ "$NMISS" = 0 ] && echo 1 || echo 0)"
# 反夹具：把表里第一个地址改成"最后一位 +1" ⇒ 同一条检查必须报红(否则它是空判据)
FIRST=$(grep -av '^#\|^$' z6root/slide_ctl.txt | head -1 | cut -d' ' -f1)
LAST=${FIRST: -1}
if [ "$LAST" = f ]; then BAD16="${FIRST%?}0"; else BAD16="${FIRST%?}f"; fi
[ ${#BAD16} = 16 ] && [ "$BAD16" != "$FIRST" ] || { echo "  [BAD] 反夹具自己造不出合法的不同地址 [$FIRST→$BAD16]"; fail=1; }
{ echo "# CONSTS x"; echo "$BAD16 256 fake"; } > "$W/ctl_bad.txt"
M2=0
while read -r A L NM; do case "$A" in ''|\#*) continue ;; esac; grep -aq "^$A " "$KS" || M2=$((M2 + 1)); done < "$W/ctl_bad.txt"
chk "⑦j 反夹具：改掉一位 hex 的地址 ⇒ 同一条检查必须抓到(实得漏 $M2 条)" "$([ "$M2" -ge 1 ] && echo 1 || echo 0)"

# ---------- ⑧ FDKA(常驻补装驱动 fd)：包侧**默认不铺这把开关**，但删净清单和同一份代码仍必须在 ----------
#   ★10-22 22:4x 转过一次向：第 38 发暴露出常驻循环可能给"正在退出的 pid"排队补装 fd，而那条回调一路
#     没有 !current->files 防护(§6.394)⇒ 带护栏的 ko 认证之前，交付默认不踩。
#   ★10-23 再转一次向(§6.400)：护栏编好并认证过了，但**这条仍然不升默认**——第 39/43 两发的一手内核行显示
#     每往 zygote 种一次 fd，那个 zygote 就在 0.23~0.77 秒内 SIGABRT(6/6 配对；没开的 12 份日志 0 条)
#     ⇒ 这条路本身会把框架打进崩溃循环，牌子也照样常驻不了。所以 ⑧a3 把"危害警示在两处分都在"钉成牙。
#   为什么这组牙还要留着：
#   ①误伤——把 RACE 那把**入口**开关也一起删了 ⇒ 用户根本打不开授权页(所以 ⑧a2 单独钉它还在)；
#   ②默认不铺 ≠ 不删：用户自己 touch 过就跨 boot 留着，下一发形状被静默换掉 ⇒ 必须仍在 SWITCH_FILES 里；
#   ③包里塞的是旧 stage ⇒ 那段代码/那份 pick_zygote 根本不在设备上。
awk '/^SWITCH_FILES=/{f=1} /^rm -f \$SWITCH_FILES/{f=0} f' "$Z" > "$W/switch_block.txt"
FDKA_TOUCH='touch "$TMP/ksu_fd_keepalive"'
chk "⑧a 常驻补装开关**默认不铺**(包里无那句 touch)+明面写了'默认**不铺'并指回 §6.400/§6.394(不许静默换形状)" "$(! grep -aqF "$FDKA_TOUCH" "$Z" && grep -aqF '默认**不铺**' "$Z" && grep -aqF '6.400' "$Z" && grep -aqF '6.394' "$Z" && echo 1 || echo 0)"
chk "⑧a2 反误伤：抢装看门狗那把**入口**开关仍照铺(删了它＝没有授权页)，实得该行=$(grep -aF 'touch "$TMP/ksu_race_fd"' "$Z" | head -1)" "$(grep -aqF 'touch "$TMP/ksu_race_fd"' "$Z" && echo 1 || echo 0)"
chk "⑧a3 §6.400 那条**危害警示**两处分都在：入口件写了 SIGABRT＋'别 touch'，教程写了 SIGABRT＋'建议别开'(实得 入口=$(grep -ac 'SIGABRT' "$Z") 教程=$(grep -ac 'SIGABRT' z6root/教程.txt))" "$(grep -aqF 'SIGABRT' "$Z" && grep -aqF '别 touch $TMP/ksu_fd_keepalive' "$Z" && grep -aqF 'SIGABRT' z6root/教程.txt && grep -aqF '建议别开' z6root/教程.txt && echo 1 || echo 0)"
sed '/SIGABRT/d' z6root/教程.txt > "$W/jc_no_abortwarn.txt"
chk "⑧a4 反夹具：把那句 SIGABRT 警示删掉 ⇒ ⑧a3 同一条检查必须报红(实得剩余 $(grep -ac 'SIGABRT' "$W/jc_no_abortwarn.txt") 行)" "$(grep -aqF 'SIGABRT' "$W/jc_no_abortwarn.txt" && echo 0 || echo 1)"
chk "⑧b SWITCH_FILES 那段里也列了它(默认不铺≠不删：用户自己铺过就跨 boot 留着)；实得 $(wc -l <"$W/switch_block.txt") 行)" "$(grep -aqF '$TMP/ksu_fd_keepalive' "$W/switch_block.txt" && echo 1 || echo 0)"
chk "⑧c 反夹具：那段清单本身非空且**不含**一个不存在的名字(证明 ⑧b 比的是内容不是空判据)" "$(grep -aq 'ksu_quiet_after_insmod' "$W/switch_block.txt" && ! grep -aqF '$TMP/ksu_no_such_switch_xyz' "$W/switch_block.txt" && [ -s "$W/switch_block.txt" ] && echo 1 || echo 0)"
cp "$Z" "$W/z_fdka_on.sh"; printf '%s\n' "$FDKA_TOUCH" >> "$W/z_fdka_on.sh"
chk "⑧d 反夹具：把那句 touch 加回去 ⇒ ⑧a 同一条检查必须报红(实得加回后 grep 命中=$(grep -acF "$FDKA_TOUCH" "$W/z_fdka_on.sh"))" "$([ "$(grep -acF "$FDKA_TOUCH" "$W/z_fdka_on.sh")" -ge 1 ] && echo 1 || echo 0)"
M_SRC=$(md5sum kmod/ksu_one_stage.sh | cut -c1-32); M_PKG=$(md5sum z6root/ksu_post.sh | cut -c1-32)
chk "⑧e 包内 ksu_post.sh 与源 stage **逐字节同一份**($M_PKG)⇒ FDKA 只有一份实现" "$([ "$M_SRC" = "$M_PKG" ] && echo 1 || echo 0)"
chk "⑧f 反夹具：数的是 FDKA 那对锚点成对出现(实得 begin=$(grep -ac '# FDKA-BEGIN' z6root/ksu_post.sh) end=$(grep -ac '# FDKA-END' z6root/ksu_post.sh))" "$([ "$(grep -ac '# FDKA-BEGIN' z6root/ksu_post.sh)" = 1 ] && [ "$(grep -ac '# FDKA-END' z6root/ksu_post.sh)" = 1 ] && echo 1 || echo 0)"
chk "⑧g 交付文案(教程)写了常驻开关**默认不铺**并给出那把开关的确切路径" "$(grep -aqF '默认不铺' z6root/教程.txt && grep -aqF 'touch /data/local/tmp/ksu_fd_keepalive' z6root/教程.txt && echo 1 || echo 0)"
chk "⑧g2 交付文案不许把牌子写成'整个开机期间存活'(默认那条窗口只有 ≈30 秒)" "$(! grep -aqF '整个开机期间存活' z6root/教程.txt && echo 1 || echo 0)"
sed '/默认不铺/d' z6root/教程.txt > "$W/jc_no_defaultoff.txt"
chk "⑧g3 反夹具：删掉那句'默认不铺' ⇒ ⑧g 同一条检查必须报红(实得剩余 $(grep -ac '默认不铺' "$W/jc_no_defaultoff.txt") 行)" "$(grep -aqF '默认不铺' "$W/jc_no_defaultoff.txt" && echo 0 || echo 1)"
chk "⑧h 同一份文案里那句『这个 root 不持久、重启失效』还在(不许把新形状写成持久化)" "$(grep -aqF '这个 root 不持久、重启失效' z6root/教程.txt && echo 1 || echo 0)"
sed '/这个 root 不持久/d' z6root/教程.txt > "$W/jc_no_persist.txt"
chk "⑧i 反夹具：删掉那句 ⇒ ⑧h 同一条检查必须报红" "$(grep -aqF '这个 root 不持久、重启失效' "$W/jc_no_persist.txt" && echo 0 || echo 1)"

# ===== ⑨ #176 那条「牌子恢复腿」必须随包发货(§6.407 判正之后它就成了交付的一部分；下次重打包把它静默丢掉＝形状换了不报错) =====
chk "⑨a 打包器映射里有 w625_seedrestart.sh 这一件(源=kmod/…，包内同名)" "$(grep -aqF '[kmod/w625_seedrestart.sh]=w625_seedrestart.sh' kmod/w431_pack_z6root.sh && echo 1 || echo 0)"
M_L=$(md5sum kmod/w625_seedrestart.sh | cut -c1-32); M_P=$(md5sum z6root/w625_seedrestart.sh 2>/dev/null | cut -c1-32)
chk "⑨b 包内确有此件且与仓库那份逐字节同一份($M_P)" "$([ -n "$M_L" ] && [ "$M_L" = "$M_P" ] && echo 1 || echo 0)"
#   ★⑨c 的形状在 10-25 换过一次：入口件原来**硬写**一串 chmod 名字(第 54 发被我改成引号粘连 ⇒ 三只腿静默没 x 位)，
#     现在改成**从 MANIFEST 现数**。于是这条检查的契约也换成「清单里有这个名字 ＋ 入口件有那句现数循环」两半，
#     两半各配一把反夹具(⑨e 抽清单、⑨e2 抽循环)——否则它就是摆设。
chk "⑨c 那条腿会拿到 x 位：清单里有它，且入口件用的是**从清单现数**的 chmod 循环(没 x 位＝root 也 EACCES，症状长得跟『恢复不了』一模一样)" \
    "$(grep -aqF 'w625_seedrestart.sh' z6root/MANIFEST && grep -aq 'case "$N" in \*\.sh)' kmod/z6root.sh && echo 1 || echo 0)"
chk "⑨d 两条出口的文案都写了那条恢复命令(入口件用 \$TMP，教程用绝对路径)" "$(grep -aqF 'su -c $TMP/w625_seedrestart.sh' kmod/z6root.sh && grep -aqF 'su -c /data/local/tmp/w625_seedrestart.sh' z6root/教程.txt && echo 1 || echo 0)"
grep -av 'w625_seedrestart.sh' z6root/MANIFEST > "$W/mf_no_w625"
chk "⑨e 反夹具：从**清单**里抽掉那条腿 ⇒ ⑨c 的同一个「现数」比法必须报红(实得删后清单命中=$(grep -acF 'w625_seedrestart.sh' "$W/mf_no_w625"))" \
    "$([ "$(grep -acF 'w625_seedrestart.sh' "$W/mf_no_w625")" = 0 ] && echo 1 || echo 0)"
grep -av 'case "$N" in' kmod/z6root.sh > "$W/z6_no_loop.sh"
chk "⑨e2 反夹具：把入口件那句现数循环抽掉 ⇒ ⑨c 必须报红(实得删后循环命中=$(grep -ac 'case "$N" in \*\.sh)' "$W/z6_no_loop.sh"))" \
    "$([ "$(grep -ac 'case "$N" in \*\.sh)' "$W/z6_no_loop.sh")" = 0 ] && echo 1 || echo 0)"
sed '/kmod\/w625_seedrestart.sh]=w625_seedrestart.sh/d' kmod/w431_pack_z6root.sh > "$W/pack_no_leg.sh"
chk "⑨f 反夹具：把映射那行删掉 ⇒ ⑨a 同一条检查必须报红(实得删后命中=$(grep -acF '[kmod/w625_seedrestart.sh]=w625_seedrestart.sh' "$W/pack_no_leg.sh"))" "$([ "$(grep -acF '[kmod/w625_seedrestart.sh]=w625_seedrestart.sh' "$W/pack_no_leg.sh")" = 0 ] && echo 1 || echo 0)"
chk "⑨g 这条腿自己不常驻(有界 ROUNDS＋无 while : ; do ⇒ 用户敲一次就退，不留后台)" "$(grep -aqF 'ROUNDS=${1:-6}' kmod/w625_seedrestart.sh && ! grep -aqF 'while : ; do' kmod/w625_seedrestart.sh && echo 1 || echo 0)"
chk "⑨h 这条腿自带 PATH 补齐(root 壳 PATH 里没有 am/pidof ⇒ 127 会伪装成『恢复不了』)" "$(grep -aqF 'PATH=/system/bin:/system/xbin' kmod/w625_seedrestart.sh && echo 1 || echo 0)"

# ===== ⑨i~ 10-24 #180：连敲硬闸(§6.409 用户连着敲之后硬复位)。★下面这几条一律量**包内那一份**，
#         不是仓库那份——例 159 那笔账就是"改了源、包内还是旧的"，量源等于没验交付件。=====
PL=z6root/w625_seedrestart.sh
gate_vals() { sed -n 's/^COOL=${3:-\([0-9]*\)}$/\1/p; s/^MAXRUNS=${4:-\([0-9]*\)}$/\1/p' "$1" | tr '\n' ' '; }
GV=$(gate_vals "$PL"); GC=$(echo "$GV" | cut -d' ' -f1); GM=$(echo "$GV" | cut -d' ' -f2)
chk "⑨i 包内那条腿里三把闸的读数词元齐(SR-COOL/SR-BUDGET/SR-ALREADY，实得=$(for t in SR-COOL SR-BUDGET SR-ALREADY; do grep -aq "$t" "$PL" && printf 1 || printf 0; done))" \
    "$(c=0; for t in SR-COOL SR-BUDGET SR-ALREADY; do grep -aq "$t" "$PL" && c=$((c + 1)); done; [ "$c" = 3 ] && echo 1 || echo 0)"
chk "⑨j 包内那条腿的默认值抽得出两个数(抽不到⇒下面那条一致性牙没有证人，实得=[$GV])" "$([ -n "$GC" ] && [ -n "$GM" ] && echo 1 || echo 0)"
chk "⑨k 包内教程第 8 条写的秒数($GC)与次数($GM)＝包内那条腿的默认(文案与代码分开漂＝用户照文案敲会被拒，读起来像腿坏)" \
    "$(grep -aq "${GC} 秒" z6root/教程.txt && grep -aq "${GM} 次" z6root/教程.txt && echo 1 || echo 0)"
sed 's/^COOL=${3:-[0-9]*}$/COOL=${3:-41}/' "$PL" > "$W/leg_cool41.sh"
GC41=$(gate_vals "$W/leg_cool41.sh" | cut -d' ' -f1)
chk "⑨l 反夹具：把**包内**那份腿的冷却默认改成 41 ⇒ ⑨k 同一个比法必须报红(实得 抽到=$GC41，教程里『41 秒』=$(grep -aq "${GC41} 秒" z6root/教程.txt && echo 命中 || echo 没命中))" \
    "$([ "$GC41" != "$GC" ] && ! grep -aq "${GC41} 秒" z6root/教程.txt && echo 1 || echo 0)"
chk "⑨m 腿的闸凭据与测量标记都被收尾件删(w625_lock/w625_nogate 都在名单里；新开关要同时配删净的生产者)" \
    "$(grep -aqF '/data/local/tmp/w625_lock ' kmod/w558_rm3.sh && grep -aqF '/data/local/tmp/w625_nogate ' kmod/w558_rm3.sh && echo 1 || echo 0)"
sed 's#/data/local/tmp/w625_lock #/data/local/tmp/x #' kmod/w558_rm3.sh > "$W/rm_no_lock.sh"
chk "⑨n 反夹具：从名单里把那个 token 换成别的 ⇒ ⑨m 同一条比法必须报红(实得删后命中=$(grep -acF '/data/local/tmp/w625_lock ' "$W/rm_no_lock.sh"))" \
    "$([ "$(grep -acF '/data/local/tmp/w625_lock ' "$W/rm_no_lock.sh")" = 0 ] && echo 1 || echo 0)"
chk "⑨o 松闸标记 w625_nogate 在包里**没有任何生产者**(除腿自己那一行代码；它只能由我的测量件铺)" \
    "$([ "$(grep -ral w625_nogate z6root/ | grep -av 'w625_seedrestart.sh' | wc -l)" = 0 ] && echo 1 || echo 0)"
chk "⑨p 包内那条腿被 MANIFEST 盖住(条目在清单里，字节与 md5 由 ③ 那段逐条比)" \
    "$(grep -aqF 'w625_seedrestart.sh' z6root/MANIFEST && echo 1 || echo 0)"

# ===== ⑩ 10-24：包里那支 ko 必须是"打包器映射指的那一支"，而且必须是**带 files==NULL 护栏**的那一支 =====
#   为什么这条不能省：ko 是包里最大的一件、也是唯一一件"漂了不会自己报错"的载荷——§6.394 那堵墙(null deref⇒PS_HOLD)
#   在 rc73 里已关，在 rc67 里开着；如果哪天有人把映射改回 rc67(或把默认漂回去)，包照样打得出来、清单照样逐条绿。
SRC_KO=$(sed -n 's#^[[:space:]]*\[kmod/\(kernelsu_rc[0-9][0-9a-z]*\)\.ko\]=kernelsu\.ko.*#\1#p' kmod/w431_pack_z6root.sh | head -1)
chk "⑩a 打包器映射里能读出出货 ko 是哪一支(实得=[$SRC_KO]，映射行必须恰好 1 行，实得=$(grep -acE '^[[:space:]]*\[kmod/kernelsu_rc[0-9][0-9a-z]*\.ko\]=kernelsu\.ko' kmod/w431_pack_z6root.sh) 行)" "$([ -n "$SRC_KO" ] && [ "$(grep -acE '^[[:space:]]*\[kmod/kernelsu_rc[0-9][0-9a-z]*\.ko\]=kernelsu\.ko' kmod/w431_pack_z6root.sh)" = 1 ] && echo 1 || echo 0)"
M_SK=$(md5sum "kmod/$SRC_KO.ko" 2>/dev/null | cut -c1-32); M_PK=$(md5sum z6root/kernelsu.ko 2>/dev/null | cut -c1-32)
chk "⑩b 包内 kernelsu.ko 与映射源件逐字节同一份(源=kmod/$SRC_KO.ko $M_PK)" "$([ -n "$M_SK" ] && [ "$M_SK" = "$M_PK" ] && echo 1 || echo 0)"
G_SK=$(grep -ac NULLFILES "kmod/$SRC_KO.ko"); G_67=$(grep -ac NULLFILES kmod/kernelsu_rc67.ko)
chk "⑩c 出货那支里有 files==NULL 护栏的打印串(实得 $SRC_KO=$G_SK 条；负对照 rc67=$G_67 条⇒这条不是恒绿)" "$([ "$G_SK" -ge 1 ] && [ "$G_67" = 0 ] && echo 1 || echo 0)"
sed 's#^[[:space:]]*\[kmod/kernelsu_rc[0-9][0-9a-z]*\.ko\]=kernelsu\.ko#    [kmod/kernelsu_rc67.ko]=kernelsu.ko#' kmod/w431_pack_z6root.sh > "$W/pack_rc67.sh"
FB=$(sed -n 's#^[[:space:]]*\[kmod/\(kernelsu_rc[0-9][0-9a-z]*\)\.ko\]=kernelsu\.ko.*#\1#p' "$W/pack_rc67.sh" | head -1)
chk "⑩d 反夹具：把映射漂回 rc67(无护栏那支)⇒ ⑩c 同一条判据必须报红(实得回退后=$FB，它的 NULLFILES 条数=$(grep -ac NULLFILES "kmod/$FB.ko"))" "$([ "$(grep -ac NULLFILES "kmod/$FB.ko")" = 0 ] && echo 1 || echo 0)"

# ===== ⑬ 10-25 第 55 发（0 枪抓到两处一手缺陷，都转成了牙）=====
#   一手①：上一版入口件那句 chmod 被改成**引号粘连**(`" "$TMP/w774_pbin_keeper.sh"$TMP/w135_fix.sh"`)
#     ⇒ keeper／w135_fix／w450_close 三只**没拿到 x 位**，而末尾 `2>/dev/null` 把失败咽掉、包照样打得出来、清单照样逐条绿。
#     这就是例 176② 那一族：交付形状里腿是被 `/system/bin/su -c <绝对路径>` 直接 execve 的，没 x 位＝`exit=126`。
#     ⇒ 修法＝x 位**从 MANIFEST 现数**，以后往映射表加件不必再动这一行(契约只留一处)。
GL=$(grep -an 'case "$N" in \*\.sh)' kmod/z6root.sh | head -1 | cut -d: -f1)
GR=$(grep -an 'done < "$SRC/MANIFEST"' kmod/z6root.sh | tail -1 | cut -d: -f1)
chk "⑬a 入口件的 x 位改成从 MANIFEST 现数(循环体行=$GL ≤ 读完清单行=$GR)" \
    "$([ -n "$GL" ] && [ -n "$GR" ] && [ "$GL" -le "$GR" ] && echo 1 || echo 0)"
#   ★形状要说准：正常的多参数写法是 `"$TMP/a" "$TMP/b"`(闭引号-空格-开引号)，**不是**缺陷；缺陷是**两个名字粘在一起**
#     `"$TMP/a.sh"$TMP/b.sh"`。所以这里数的是 `\$TMP/名字\"\$TMP` 这种粘连，别拿 `" "` 当判据(第一次就数出 7 处假阳性)。
#   ★还要**先剔注释**：这一版的说明文字里就引了那个坏形状当反面教材，连注释一起数就永远红(第二次踩)。
NG=$(grep -av '^[[:space:]]*#' kmod/z6root.sh | grep -acE '\$TMP/[A-Za-z0-9_.]+"\$TMP')
chk "⑬b 入口件的**可执行行**里不许有『两个名字粘在一起』的 chmod 参数(实得 $NG 处)" "$([ "$NG" = 0 ] && echo 1 || echo 0)"
sed 's#^chmod 755 "\$TMP/ksuctl" "\$TMP/ksuctl88"#chmod 755 " "$TMP/ksuctl"$TMP/ksuctl88"#' kmod/z6root.sh > "$W/entry_glued.sh"
NFIX=$(grep -av '^[[:space:]]*#' "$W/entry_glued.sh" | grep -acE '\$TMP/[A-Za-z0-9_.]+"\$TMP')
chk "⑬c 反夹具：造一份粘连形状的入口件 ⇒ ⑬b 同一条比法必须报红(实得副本可执行行命中=$NFIX，原文件=$NG)" \
    "$([ "$NFIX" -ge 1 ] && [ "$NG" = 0 ] && echo 1 || echo 0)"
#   一手②：包内收尾腿原来 `umount` 失败照样 `rm -rf` 源 ⇒ mountinfo 当场成 `…/pbin//deleted`＝整层 `/product/bin` 空壳
#     (第 54 发被这条腿自己复现过一次；今晚那扇窗也是这个形状)。⇒ 三件顺序必须是：删 kill switch → umount → 判定挂载行=0 → 才删源。
CL=kmod/w450_close.sh
SW=$(grep -anF '/data/local/tmp/ksu_pbin_keep' "$CL" | head -1 | cut -d: -f1)
UM=$(grep -anF '/system/bin/umount /product/bin' "$CL" | head -1 | cut -d: -f1)
IF=$(grep -an 'if \[ "${ML:-1}" = 0 \]' "$CL" | head -1 | cut -d: -f1)
RM=$(grep -anF 'rm -rf /data/adb/ksu/pbin' "$CL" | head -1 | cut -d: -f1)
chk "⑬d 收尾腿顺序闸：删开关($SW) < umount($UM) < 判定挂载行=0($IF) < 才许删源($RM)" \
    "$([ -n "$IF" ] && [ "$SW" -lt "$UM" ] && [ "$UM" -lt "$IF" ] && [ "$IF" -lt "$RM" ] && echo 1 || echo 0)"
awk -v n="$IF" 'NR==n {print "    rm -rf /data/adb/ksu/pbin /data/adb/ksu/sustatic; echo 粘到判定之前"} {print}' "$CL" > "$W/close_glued.sh"
RM2=$(grep -anF 'rm -rf /data/adb/ksu/pbin' "$W/close_glued.sh" | head -1 | cut -d: -f1)
IF2=$(grep -an 'if \[ "${ML:-1}" = 0 \]' "$W/close_glued.sh" | head -1 | cut -d: -f1)
chk "⑬e 反夹具：把删源粘到判定**之前**⇒ ⑬d 同一条比法必须报红(实得副本 删源行=$RM2 判定行=$IF2)" \
    "$([ "$RM2" -lt "$IF2" ] && echo 1 || echo 0)"
chk "⑬f 维持件的开关与日志都在收尾腿的删净名单里(开关=$(grep -acF '/data/local/tmp/ksu_pbin_keep' "$CL") 日志=$(grep -acF '/data/local/tmp/w774_keeper.log' "$CL"))" \
    "$([ "$(grep -acF '/data/local/tmp/ksu_pbin_keep' "$CL")" -ge 1 ] && [ "$(grep -acF '/data/local/tmp/w774_keeper.log' "$CL")" -ge 1 ] && echo 1 || echo 0)"
CH=$(grep -anF 'chmod 666 /sdcard/w450_close.txt' "$CL" | head -1 | cut -d: -f1)
E1=$(grep -an '=== CLOSE' "$CL" | head -1 | cut -d: -f1)
chk "⑬g 收尾腿的产物权限排在**第一条读数之前**(chmod 行=$CH < 首行读数=$E1；第 54 发那条腿就是排反了才读不到)" \
    "$([ -n "$CH" ] && [ -n "$E1" ] && [ "$CH" -lt "$E1" ] && echo 1 || echo 0)"
chk "⑬h 交付文案(教程)写了这三句新形状：开关自退／挂载行没收回就不许删源／看 MOUNT_LEFT" \
    "$(grep -aqF 'killswitch_rm_rc=0' z6root/教程.txt && grep -aqF '没卸成就不许删 bind 的源' z6root/教程.txt && grep -aqF 'MOUNT_LEFT=0' z6root/教程.txt && echo 1 || echo 0)"
sed '/没卸成就不许删 bind 的源/d' z6root/教程.txt > "$W/jc_no_gate.txt"
chk "⑬i 反夹具：从包内教程里删掉那句「不许删源」⇒ ⑬h 同一条比法必须报红(实得副本命中=$(grep -acF '没卸成就不许删 bind 的源' "$W/jc_no_gate.txt"))" \
    "$([ "$(grep -acF '没卸成就不许删 bind 的源' "$W/jc_no_gate.txt")" = 0 ] && echo 1 || echo 0)"
if cmp -s kmod/w450_close.sh z6root/w450_close.sh; then SAME=1; else SAME=0; fi
chk "⑬j 包内那条收尾腿与仓库源件逐字节同一份(实得 same=$SAME)" "$SAME"

# ===== ⑭ 10-25 第 55 发：第 0 步那条铁律闸不许把「缺读数」说成「已有模块」=====
#   一手(0 枪)：我在 app 域(Termux)里跑一键 ⇒ `grep: /proc/modules: Permission denied`，MOD 是空串，
#   而旧写法 `[ "$MOD" = 0 ] || die "本 boot 已经有 kernelsu 模块"` 照样 die，并把"没有读数"报成"已经装载"。
#   拦下来是对的(那一枪没打出去)，但**文案是假的**——例 174/178 那一族：缺读数与读数不能共用一句话。
#   ★同样要**先剔注释**：那句旧写法现在正躺在我写的说明里(⑬b 第二次兑现同一课)。
chk "⑭a 入口件第 0 步分成三支(0／非数字／其余)，且**可执行行**里不再用『不等于 0 就是已有模块』那种写法" \
    "$(grep -aqF "''|*[!0-9]*)" kmod/z6root.sh && grep -aqF '这不是「已经装载」，是「没有读数」' kmod/z6root.sh && ! (grep -av '^[[:space:]]*#' kmod/z6root.sh | grep -qF '[ "$MOD" = 0 ] || die') && echo 1 || echo 0)"
grep -avF "''|*[!0-9]*)" kmod/z6root.sh > "$W/entry_two_branch.sh"
chk "⑭b 反夹具：把『非数字』那一支抽掉 ⇒ ⑭a 同一条比法必须报红(实得副本剩三支命中=$(grep -acF "''|*[!0-9]*)" "$W/entry_two_branch.sh"))" \
    "$([ "$(grep -acF "''|*[!0-9]*)" "$W/entry_two_branch.sh")" = 0 ] && echo 1 || echo 0)"
chk "⑭c 教程写清了宿主必须是 uid=2000 的 shell(不是任何 app 的 shell)" \
    "$(grep -aqF 'adb shell（uid=2000 的 shell 宿主）' z6root/教程.txt && grep -aqF '不是"已经装载"' z6root/教程.txt && echo 1 || echo 0)"

[ "$fail" = 0 ] && echo "=== run_z6pack：$nchk 项全绿 PASS ===" || echo "=== run_z6pack：$nchk 项里有红 FAIL ==="
[ "$fail" = 0 ]
