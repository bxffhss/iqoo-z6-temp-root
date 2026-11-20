#!/usr/bin/env bash
# run_nosuw.sh — #145 那把 NOSUW 开关的**双向**离线自测（不碰设备、不开枪）。
#
# 为什么这一格必须有自测：NOSUW 一开就同时改两件事(名单主条目 + bind 的归属)，
# 而它的失败模式全是**静默**的：
#   · 开关块若排在 log() 定义之前 ⇒ 生效证人那几行根本不打印(我今晚第一版就是这样，被 bash -n 放行)；
#   · Manager 的 uid 取不到 ⇒ 若代码"猜"一个数进名单 ⇒ 症状只是"这一发运气不好"；
#   · go.sh 第 5 步若忘了跳过 ⇒ bind 做两次，第二次的源目录里已经带着上一次的 su ⇒ 形状变了没人说；
#   · stage 的 bind 若不看"源在不在" ⇒ 挂一个空壳进 /product/bin，比不挂更坏(看着像交付成功)。
# 所以：静态断言(A/B/C)＋**把开关块切出来真跑一遍**(D)＋反夹具(⑰⑱d)。
set -u
export PYTHONUTF8=1
cd "$(dirname "$0")/../.." || exit 1
W=kmod/_tmp_selftest_rdst/nosuw_self
rm -rf "$W"; mkdir -p "$W"
ST=kmod/ksu_one_stage.sh
GO=kmod/go.sh
Z=kmod/z6root.sh

nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }
ln() { grep -an "$1" "$2" | head -1 | cut -d: -f1; }

echo "=== A) stage：开关块的位置与内容 ==="
LLOG=$(grep -an '^log() {' "$ST" | head -1 | cut -d: -f1)
LSW=$(grep -an '仪器开关 `NOSUW`' "$ST" | head -1 | cut -d: -f1)
chk "①开关块排在 log() 定义**之后**(实得 log=$LLOG 开关=$LSW)——之前会静默丢掉证人行" "$([ -n "$LSW" ] && [ -n "$LLOG" ] && [ "$LSW" -gt "$LLOG" ] && echo 1 || echo 0)"
i1=$(grep -an '仪器开关 `NOSUW`' "$ST" | head -1 | cut -d: -f1)
i2=$(grep -an 'NOSUW 开关读回' "$ST" | head -1 | cut -d: -f1)
[ -n "$i1" ] && [ -n "$i2" ] || i2=$((i1+1))
sed -n "${i1},$((i2+1))p" "$ST" > "$W/block.sh"     # ★+1：块的收尾 `fi` 也要进来(少一行整块语法不过)
chk "②切片取得出且语法过(行数=$(wc -l < "$W/block.sh"))" "$(bash -n "$W/block.sh" 2>/dev/null && [ "$(wc -l < "$W/block.sh")" -ge 9 ] && echo 1 || echo 0)"
chk "③默认值＝ENT_UID=\$SUWID / ENT_KEY=\$APKEY(不给开关 ⇒ 交付形状逐字同第 29 发)" "$(grep -aq 'ENT_UID=$SUWID' "$ST" && grep -aq 'ENT_KEY=$APKEY' "$ST" && echo 1 || echo 0)"
chk "④uid 取不到时**不改形状**并打 [!](绝不猜 uid 进名单)" "$(grep -aql '不改形状' "$W/block.sh" && echo 1 || echo 0)"
LASTMK=$(grep -an '^ *"\$CTL" mkallow' "$ST" | tail -1 | cut -d: -f1)
MKLINE=$(sed -n "${LASTMK}p" "$ST")
chk "⑤单条目那一支的**调用行**(只数真调用，不数打了 mkallow 这个词的证人句)走 ENT_*［行 $LASTMK］" "$(echo "$MKLINE" | grep -aq 'a_\$ENT_UID.bin "\$ENT_UID" "\$ENT_KEY"' && echo 1 || echo 0)"
NOLD=$(grep -ac 'mkallow /data/local/tmp/a_\$SUWID.bin \$SUWID "\$APKEY"' "$ST")
chk "⑤b 两条目分支那两处**没被顺手改**(老字面量仍=2，实得 $NOLD)" "$([ "$NOLD" = 2 ] && echo 1 || echo 0)"
# 上面那条的"=1"是**两条目分支**里那份(它必须仍然按 suw 那条主记录写)，不许被顺手改掉
chk "⑥cp 进 .allowlist 的落点件跟着 ENT_UID 走" "$(grep -aq 'cp /data/local/tmp/a_\$ENT_UID.bin "\$ALLOW"' "$ST" && echo 1 || echo 0)"
chk "⑦落盘读回那句(字节数)存在——配置生效要从被写的那侧读回来(例 100)" "$(grep -aq '★落盘读回：\$ALLOW 字节=' "$ST" && echo 1 || echo 0)"

echo "=== B) stage：bind 那块的闸 ==="
IB=$(grep -an 'NOSUW：bind /product/bin 归 stage' "$ST" | head -1 | cut -d: -f1)
# ★切到"信号探针"那行**之前**为止：固定 +N 行会越界到下一个块，把别人的 umount/证人算进这一块(⑪就是这么误红的)
IE=$(( $(grep -an '信号探针(必须在 app 触发之前挂' "$ST" | head -1 | cut -d: -f1) - 1 ))
sed -n "${IB},${IE}p" "$ST" > "$W/bind.sh"
chk "⑧整块以 [ \"\$NOSUW\" = 1 ] 为闸(默认不执行 ⇒ 交付形状不变)" "$(grep -aq 'if \[ "\$NOSUW" = 1 \]; then' "$ST" && echo 1 || echo 0)"
chk "⑨前置闸一：mountinfo 里 pbin 必须=0 才许 bind" "$(grep -aq '前置闸一：mountinfo 里 pbin 行数=\$ML' "$W/bind.sh" && echo 1 || echo 0)"
chk "⑩前置闸二：bind 的源必须非空(不挂空壳)" "$(grep -aq 'if \[ ! -s "\$SB2" \]' "$W/bind.sh" && grep -aq '不做 bind' "$W/bind.sh" && echo 1 || echo 0)"
UM=$(grep -acE '^[[:space:]]*(umount|busybox umount)' "$W/bind.sh")
chk "⑪这一块里**没有 umount 这条动作**(实得 $UM 条；不许在坏态上顺手救，那是 w135_fix 的职责)——第一版我数的是整词，连自己那句'也不去 umount'的说明文字都算进去了" "$([ "$UM" = 0 ] && echo 1 || echo 0)"
chk "⑫三行末端证人齐(BIND_RC / SU_AT_TGT / HEALTH)" "$(grep -aq 'NOSUW_BIND_RC=' "$W/bind.sh" && grep -aq 'NOSUW_SU_AT_TGT=' "$W/bind.sh" && grep -aq 'NOSUW_HEALTH=' "$W/bind.sh" && echo 1 || echo 0)"
chk "⑬MGRPKG 只定义一处(两处就会分叉)" "$([ "$(grep -ac '^ *MGRPKG=me.weishu.kernelsu' "$ST")" = 1 ] && echo 1 || echo 0)"

echo "=== C) go.sh 生产者 与 包的清单 ==="
chk "⑭go.sh **新契约**(§6.365)：现取 uid＋把『<uid> <包名>』两段推到开关文件＋读回设备字节与两端 md5，且旧的空文件 touch 已消失(不许复活)" "$(grep -aqF 'NUID=$(pk_uid "$NOSUW_PKG")' "$GO" && grep -aqF 'kmod/_tmp_nosuw_switch.txt' "$GO" && grep -aqF '设备 md5=$SR' "$GO" && [ "$(grep -acF 'touch /data/local/tmp/ksu_nosuw' "$GO")" = 0 ] && echo 1 || echo 0)"
chk "⑭b 新契约的两道硬闸都在(取不到 uid ⇒ exit 3；两端 md5 不符 ⇒ exit 3)" "$(grep -aA3 'NUID=$(pk_uid' "$GO" | grep -aq 'exit 3' && grep -aA3 '设备 md5=$SR' "$GO" | grep -aq 'exit 3' && echo 1 || echo 0)"
chk "⑮go.sh：没给 ⇒ rm 残留 + 读回(跨 boot 不许留形状)" "$(grep -aq 'rm -f /data/local/tmp/ksu_nosuw; ls /data/local/tmp/ksu_nosuw' "$GO" && echo 1 || echo 0)"
chk "⑯go.sh：NOSUW=1 时**提前**推 bind 的源并做两端 md5 硬闸(stage 那块跑在 insmod 之后，源不存在就只能弃权)" "$(grep -aq 'bind 的源已提前推' "$GO" && grep -aA3 'bind 的源已提前推' "$GO" | grep -aq 'exit 3' && echo 1 || echo 0)"
NB=$(grep -ac 'fire "@sushd:/data/local/tmp/w135_fix.sh"' "$GO")
POS=$(grep -an 'fire "@sushd:/data/local/tmp/w135_fix.sh"' "$GO" | head -1 | cut -d: -f1)
EL=$(grep -an 'NOSUW=1 ⇒ 本步的 @sushd 派发跳过' "$GO" | head -1 | cut -d: -f1)
chk "⑰第 5 步的派发只有一份且排在 NOSUW 跳过之后(否则 bind 做两次＝另一种形状；实得份数=$NB 派发行=$POS 跳品行=$EL)" "$([ "$NB" = 1 ] && [ -n "$EL" ] && [ "$POS" -gt "$EL" ] && echo 1 || echo 0)"
chk "⑱读不到 bind 证人时明说'没测到'(不许拿没输出当通过)" "$(grep -aq 'bind 这一格没成立' "$GO" && echo 1 || echo 0)"
chk "⑲包里：ksu_nosuw 在删除清单里(包只跑交付形状)" "$(grep -aq '\$TMP/ksu_nosuw' "$Z" && echo 1 || echo 0)"
cnt=$(grep -ac 'ksu_quiet_after_insmod' "$Z")
chk "⑳包里：删与复证共用同一个变量(那句开关名只出现 1 次；实得 $cnt)" "$([ "$cnt" = 1 ] && echo 1 || echo 0)"
sed 's|say "  开关复证.*|say "  开关复证：$(ls "$TMP/ksu_dom" "$TMP/ksu_quiet_after_insmod" 2>\&1)"|' "$Z" > "$W/z_back.sh"
c2=$(grep -ac 'ksu_quiet_after_insmod' "$W/z_back.sh")
chk "⑳b 反夹具：把复证退回硬编码字面量 ⇒ 同一条检查必须报红(实得 $c2，要≥2)——第一版这条 sed 没匹配上，红的是夹具自己" "$([ "$c2" -ge 2 ] && echo 1 || echo 0)"

echo "=== D) 把开关块切出来真跑（默认关／加了／取不到 uid 三种形状）==="
S="$W/run_block.sh"
{   # 夹具垫片：设备侧路径换成 W 下，log/upt 用可数的桩。
  # ★SUWID/MGRID/APKEY 必须照 stage 的口径先seed(它们本来在 stage 上半部赋值)，
  #   否则切出来的块跑起来变量全空 ⇒ "空结果"会被读成"形状不对"，而真实原因是夹具没喂料(例 103)。
    echo 'TMPD='"$W"
    echo 'log() { echo "$*"; }'
    echo 'PKG=com.suw.manager'
    echo "SUWID=\$(cut -d' ' -f1 $W/uids 2>/dev/null); [ -n \"\$SUWID\" ] || SUWID=10284"
    echo "MGRID=\$(cut -d' ' -f2 $W/uids 2>/dev/null); [ -n \"\$MGRID\" ] || MGRID=0"
    echo 'APKEY=$(head -1 '"$W"'/ap_key 2>/dev/null | tr -d "\r\n"); [ -n "$APKEY" ] || APKEY=$PKG'
    sed 's|/data/local/tmp/ksu_nosuw|'"$W"'/switch_file|; s|/data/local/tmp/ksa_uids.txt|'"$W"'/uids|' "$W/block.sh"
    echo 'echo "RESULT NOSUW=$NOSUW ENT_UID=$ENT_UID ENT_KEY=$ENT_KEY"'
} > "$S"
bash -n "$S" || { echo "  [BAD] 夹具本身语法不过(那 D 组全不算测到)"; fail=1; }
[ -s "$W/switch_file" ] && rm -f "$W/switch_file"
printf '10342 10104\n' > "$W/uids"
R0=$(sh "$S" 2>&1)
chk "㉑不给开关 ⇒ NOSUW=0 且条目＝(10342, com.suw.manager)［实得 $(echo "$R0" | grep -a RESULT)］" "$(echo "$R0" | grep -aqx 'RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager' && echo 1 || echo 0)"
printf '10667 com.termux\n' > "$W/switch_file"
R1=$(sh "$S" 2>&1)
chk "㉒新契约(§6.365)：开关内容＝『<uid> <包名>』⇒ NOSUW=1 且条目＝(10667, com.termux)，**不再是 Manager 自己**［实得 $(echo "$R1" | grep -a RESULT)］" "$(echo "$R1" | grep -aqx 'RESULT NOSUW=1 ENT_UID=10667 ENT_KEY=com.termux' && echo 1 || echo 0)"
chk "㉓生效时把开关内容与读回都打在明面上(不是只改数不吭声)" "$(echo "$R1" | grep -aq 'NOSUW 开关读回' && echo "$R1" | grep -aq '内容=\[10667 com.termux\]' && echo 1 || echo 0)"
: > "$W/switch_file"          # ★旧形状(空文件 touch)在新契约下**必须弃权**：manager 条目已被判为无意义
R2=$(sh "$S" 2>&1)
chk "㉔空文件＝旧形状 ⇒ **NOSUW 退回 0**、条目仍是 suw［实得 $(echo "$R2" | grep -a RESULT)］" "$(echo "$R2" | grep -aqx 'RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager' && echo 1 || echo 0)"
chk "㉕并且当场打了 [!] 那句(形状不对就弃权，绝不猜 uid 进名单)" "$(echo "$R2" | grep -aq '不改形状' && echo 1 || echo 0)"
printf 'abc com.termux\n' > "$W/switch_file"
R3=$(sh "$S" 2>&1)
chk "㉖uid 段是垃圾串(abc) ⇒ 同样退回 0(非纯数字也要拦)［实得 $(echo "$R3" | grep -a RESULT)］" "$(echo "$R3" | grep -aqx 'RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager' && echo 1 || echo 0)"
printf '10667\n' > "$W/switch_file"
R4=$(sh "$S" 2>&1)
chk "㉖b 只有一段(词数≠2) ⇒ 退回 0：新契约要的是『uid 包名』两段" "$(echo "$R4" | grep -aqx 'RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager' && echo 1 || echo 0)"
printf '10667 Com.Termux!\n' > "$W/switch_file"
R5=$(sh "$S" 2>&1)
chk "㉖c 包名带非法字符(大写/空格/!) ⇒ 退回 0(整串形状闸，不是子串)" "$(echo "$R5" | grep -aqx 'RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager' && echo 1 || echo 0)"
printf '10667 com.termux\n' > "$W/switch_file"
RA=$(sh "$S" 2>&1 | grep -a RESULT); RB=$(sh "$S" 2>&1 | grep -a RESULT)
chk "㉗幂等：同一夹具跑两遍结果一致(开关状态不是靠上一次残留)" "$([ "$RA" = "$RB" ] && echo 1 || echo 0)"
#   ★㉘㉙(§6.364 第 30 发抓出来的两格)：NOSUW 形状下 go.sh 第 5.5 步**整格跳过**(它靠给 suw 派单取证)，
#     而默认形状下那条腿必须**按派单前的行数取增量**——它读的 `ksu_grant.txt` 是固定名跨 boot 累计件，
#     那一发就是在这读到 `[16:43:36.952]` 这种不属本窗的行(例 101 同族)。两条都是静态闸(不碰设备)。
GOS=kmod/go.sh
chk "㉘go.sh 5.5 有 NOSUW 跳过分支，且跳过那句文案点名§1.69b 副作用②" "$(grep -aq 'NOSUW=1 ⇒ 整格跳过' "$GOS" && echo 1 || echo 0)"
chk "㉙默认分支按增量读(有『派单前 N 行』的现数＋tail -n + 起点＋零新增硬话，三件齐)" "$(grep -aq 'N0=$(A "wc -l < $GFILE' "$GOS" && grep -aq 'tail -n +' "$GOS" && grep -aq '零新增' "$GOS" && echo 1 || echo 0)"
#   ★㉚第 30 发在这格抓到"同一个已知坑只修了一处"：收尾件的 `fire()` 早带 `-f 0x4000000`(suw 活着时 extras 会被整条丢掉)，
#     而 go.sh 第 5.5 步那条 `am start` 没带 ⇒ 本窗派单**零新增行**。诊断腿当场补旗；**交付链那颗扳机没动**(它带旗＝换形状，
#     要由 #142 的零开关回归自己判)，但把这个不一致**写进代码并在这里钉住**：三件齐才算过。
chk "㉚5.5 派单带 CLEAR_TOP＋交付链那颗裸写仍在(只此一处)＋不一致已在 go.sh 里登记" "$([ "$(grep -ac 'am start -f 0x4000000 -n \$SUW/.MainActivity' "$GOS")" = 1 ] && [ "$(grep -ac 'am start -n \$SUW/.MainActivity' "$GOS")" = 1 ] && grep -aq '已知不一致' "$GOS" && echo 1 || echo 0)"

echo
echo "共 $nchk 项断言；$([ "$fail" = 0 ] && echo 'PASS 全绿' || echo 'FAIL 有红')"
[ "$fail" = 0 ]
