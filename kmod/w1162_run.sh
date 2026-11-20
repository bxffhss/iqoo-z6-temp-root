#!/bin/bash
# w1162_run.sh —— 本地包装(0 枪)：rc76 候选桩(解码＋账＋**装载门**)送构建机编进出货同一条流水线。
#   用法：HRMT_CLI=hermes-remote1/cli.py bash kmod/w1162_run.sh [证件名] [超时秒]
# ★这一跑在**送件之前**先跑一次静态闸(w1162_wire_check.py --self)，量的就是即将上传的那份源；
#   静态闸红了就不送信——省一趟往返，更重要的是：编得过≠结构对，先查结构。
# ★两把"货没动"的尺都不背常数：出货 ko 现读两次(前后)对表；树里现役桩那份从**已登记的证件**里抓
#   (w1156_rc75_v5.txt 那行 `现役桩(出货那份)md5=`)，不是我记的。
set -u
export PYTHONUTF8=1
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1162_rc76_v1}"
T="${2:-1800}"
cd "$D" || exit 1
EV=kmod/w103_evidence
SHIP=$D/kmod/kernelsu_rc74c.ko
STUB=$D/kmod/ksu_dropped_stub_rc76.c
CORE=$D/kmod/w1151_sepolicy_core.h
REC=$D/kmod/w1155_sepol_record.h
GATE=$D/kmod/w1161_polgate.h
PIPE=$D/kmod/remote_ksu_rc74c.sh
WIRE=$D/kmod/w1162_wire_check.py
CERT95=$D/kmod/w103_evidence/w1156_rc75_v5.txt

for f in "$SHIP" "$STUB" "$CORE" "$REC" "$GATE" "$PIPE" "$WIRE" "$CERT95"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
L_STUB=$(md5sum "$STUB" | cut -d' ' -f1)
L_CORE=$(md5sum "$CORE" | cut -d' ' -f1)
L_REC=$(md5sum "$REC" | cut -d' ' -f1)
L_GATE=$(md5sum "$GATE" | cut -d' ' -f1)
L_PIPE=$(md5sum "$PIPE" | cut -d' ' -f1)
SHIP0=$(md5sum "$SHIP" | cut -d' ' -f1)
STUB_WANT=$(grep -ao '现役桩(出货那份)md5=[0-9a-f]\{32\}' "$CERT95" | head -1 | cut -d= -f2)
[ -n "$STUB_WANT" ] || { echo "!! 没能从证件里抓到现役桩的参照 md5 ⇒ 不许凭记忆填，停"; exit 1; }
echo "出货 ko 现读(跑之前)=$SHIP0 字节=$(wc -c <"$SHIP" | tr -dc '0-9')"
echo "候选桩=$L_STUB 核心=$L_CORE 记录层=$L_REC 门=$L_GATE 流水线=$L_PIPE"
echo "参照：树里现役桩(从 $CERT95 抓)=$STUB_WANT"

echo "=== [B] 静态闸：装载只可能从门后面发生(量的是即将上传的那份源) ==="
python "${WIRE#$D/}" --self > "$EV/${N}_wire.txt" 2>&1
WR=$?
echo "  wire rc=$WR"
grep -aq 'fails=0' "$EV/${N}_wire.txt" || { echo "!! 静态闸没绿 ⇒ 停(先看 $EV/${N}_wire.txt)"; exit 1; }
grep -aq 'VERDICT=w1162_wire_pass PASS' "$EV/${N}_wire.txt" || { echo "!! 静态闸缺 PASS 句 ⇒ 停"; exit 1; }
NW=$(grep -ac '^\[OK\] 变异 ' "$EV/${N}_wire.txt")
[ "$NW" = 7 ] || { echo "!! 七条变异只抓到 $NW 条 ⇒ 停(那把尺没牙，不能送件)"; exit 1; }
echo "  [ok] 静态闸绿：$(grep -ao 'SUM asserts=[0-9]* fails=[0-9]*' "$EV/${N}_wire.txt" | tail -1)，七条变异全被抓"

CLI="${HRMT_CLI:-$D/hermes-remote/cli.py}"; CFG="${HRMT_CONFIG:-$(dirname "$CLI")/config.json}"
{ [ -f "$CLI" ] && [ -f "$CFG" ]; } || { echo "!! 端点不对：CLI=$CLI CFG=$CFG"; exit 1; }
put_one() {
  local src="$1" dst="$2" out rc
  out=$(PYTHONUTF8=1 python "$CLI" --config "$CFG" put "$src" "$dst" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then echo "  [ok] put $dst rc=$rc"; else echo "  [BAD] put $dst rc=$rc ⇒ $(printf '%s' "$out" | tail -c 200)"; exit 1; fi
}
put_one "$PIPE" ksu_rc74c.sh
put_one "$STUB" w1162_stub.c
put_one "$CORE" w1162_core.h
put_one "$REC"  w1162_record.h
put_one "$GATE" w1162_gate.h
printf '%s\n' "$SHIP0" > "$EV/w1162_shipmd5.txt"
printf '%s\n' "$STUB_WANT" > "$EV/w1162_stubmd5.txt"
put_one "$EV/w1162_shipmd5.txt" w1162_shipmd5.txt
put_one "$EV/w1162_stubmd5.txt" w1162_stubmd5.txt

bash "$D/kmod/w999_runcap.sh" kmod/w1162_remote.sh "$N" "$T" > "$EV/${N}.wrap.log" 2>&1
echo "run rc=$?"
OUT="$EV/${N}.txt"
[ -f "$OUT" ] || { echo "!! 没有产物 $OUT ⇒ 判失败(看 $EV/${N}.wrap.log)"; tail -20 "$EV/${N}.wrap.log"; exit 1; }

BAD=0
g1() { grep -ao "^MD5_$1=[0-9a-f]\{32\}" "$OUT" | head -1 | cut -d= -f2; }
for pair in "w1162_stub.c=$L_STUB" "w1162_core.h=$L_CORE" "w1162_record.h=$L_REC" "w1162_gate.h=$L_GATE" "ksu_rc74c.sh=$L_PIPE" "w1162_shipmd5.txt=$(md5sum "$EV/w1162_shipmd5.txt" | cut -d' ' -f1)" "w1162_stubmd5.txt=$(md5sum "$EV/w1162_stubmd5.txt" | cut -d' ' -f1)"; do
  k=${pair%%=*}; want=${pair#*=}; got=$(g1 "$k")
  [ "$got" = "$want" ] && echo "[ok] 两端同 md5：$k" || { echo "[BAD] $k 远端=${got:-空} 本地=$want"; BAD=1; }
done
grep -aq "^SHIPPED_MD5_WANT=$SHIP0$" "$OUT" || { echo "[BAD] 远端没收到出货 md5 这个参照"; BAD=1; }
grep -aq '^  \[ok\] kernel/selinux 下没有 security.h' "$OUT" || { echo "[BAD] 撞名前提没验(那声 'security.h' 可能命中的不是 SS 那份)"; BAD=1; }
grep -aq 'DECL_CHECK security_load_policy=1' "$OUT" || { echo "[BAD] 树里那份头没数到 load 原型 ⇒ 我依赖的声明不成立"; BAD=1; }
grep -aq 'DECL_CHECK security_read_policy=1' "$OUT" || { echo "[BAD] 树里那份头没数到 read 原型"; BAD=1; }
grep -aq '^RC74C_RC=0' "$OUT" || { echo "[BAD] A 阶段流水线没跑完(候选无可比参照)"; BAD=1; }
grep -aq '可比性成立' "$OUT" || { echo "[BAD] A 阶段产物 ≠ 出货那份 ⇒ 环境漂了，B 的结果不能叫候选"; BAD=1; }
# ★五条 include 回执**锚在代码行首**：上一版的 `grep -qF` 撞上桩文件头注释里那句散文就放行，
#   代码里其实没有那行 ⇒ 真相烧完一轮编译才说(11-07)。这条尺与编不编得过无关，两条路径都得有。
IRT=$(grep -aoF '代码行=1' "$OUT" | wc -l | tr -dc '0-9')
[ "$IRT" = 5 ] && echo "[ok] 五条 include 都在代码里(注释里说过不算)" || { echo "[BAD] include 回执条数=$IRT(期望 5) ⇒ 有一条只写在注释里"; BAD=1; }
# ★编译那一格是**分支**不是红：编不过＝这一发的答案；而判据那一段因此根本没跑 ⇒
#   那些产物尺不许按「没有那一行」判成失败(11-07 就是这么把三条还原回执读成红的，现查树是干净的)。
NOC=0
grep -aq '^MAKE_B_RC=0$' "$OUT" || { NOC=1; echo "  [注] MAKE_B_RC≠0 ⇒ 远端在编译这一格收了；下面的产物尺**不跑**，答案＝这份桩编不过(看  cc: 那几行)"; }
if [ "$NOC" = 0 ]; then
  grep -aq '^B_LOG err=0' "$OUT" || { echo "[BAD] B 有 error"; BAD=1; }
  grep -aq '新增未定义符号逐条已在 Module.symvers' "$OUT" || { echo "[BAD] 新增符号没逐条验导出"; BAD=1; }
  # ★尺①的三条证人(11-07)：`symvers` 是 `<CRC>\t<符号>\t…` ⇒ 行首查符号那把永远命不中。
  #   正对照＋反夹具＋"夹具自证"必须由远端自己打出来；只有一条在 = 那把尺的形状没被自证过。
  for r in '正对照：vfree 查得到' '反夹具：w1162_bogus_sym 查不到' '新代码的进口符号 \[simple_read_from_buffer\] 确实新增'; do
    grep -aq "$r" "$OUT" || { echo "[BAD] 少尺①的证人 [$r]"; BAD=1; }
  done
  grep -aq 'SS/security_\* 外流=0' "$OUT" || { echo "[BAD] 有 SS 符号外流"; BAD=1; }
  grep -aq '装载面三个名字都没进未定义表' "$OUT" || { echo "[BAD] 装载面在链接期就直接引用了内核符号"; BAD=1; }
  grep -aqE '^  __cfi_check=1' "$OUT" || { echo "[BAD] __cfi_check 不是 1"; BAD=1; }
  grep -aq 'parmtype=ld_\* 条数=1[89]' "$OUT" || grep -aq 'parmtype=ld_\* 条数=[2-9][0-9]' "$OUT" || { echo "[BAD] 装载面的 18 个读数参数没全进 .modinfo"; BAD=1; }
  # ★尺②(11-07)：期望从"≥14 条"换成"逐条点名 13 条全中"＋cb 那一支走代码侧证人。
  grep -aq '解码面逐条点名 13 条：命中 13' "$OUT" || { echo "[BAD] 解码面 13 条参数没逐条点名到"; BAD=1; }
  grep -aq 'module_param_cb(sp_arm…) 计数=1' "$OUT" || { echo "[BAD] 没有 sp_arm 那句 cb 的代码侧证人"; BAD=1; }
  grep -aq '认不出来源的 0(必须 0)' "$OUT" || { echo "[BAD] 新符号里有对不上这份新代码的东西(或没先摘掉进口符号)"; BAD=1; }
  grep -aq '^VERDICT=ok' "$OUT" || { echo "[BAD] 远端总判据没到 ok"; BAD=1; }
  for s in "  串 [ksu_sepol_img]=" "  串 [ksu_sepol_ctl]=" "  串 [RESET]=" "  串 [ARM ]="; do
    grep -aqF "$s" "$OUT" || { echo "[BAD] 少了那行读数 [$s](节点名/命令词没进 rodata ⇒ 那段代码没被链进来)"; BAD=1; }
    # ★取数：先按**整段词元**切到 `=` 之后，再取**开头**那串数字。两版都错过：
    #   ①`grep -oF "$s" | sed 's/.*=//'` ⇒ -o 把行截到匹配处，值整条被切掉(恒空)；
    #   ②`grep -o '[0-9]\+$'` ⇒ 这行是 `…=1(必须 ≥1)`，值**不在行尾**(11-07 v3 又空一次)。
    LINE=$(grep -aF "$s" "$OUT" | head -1)
    C=$(printf '%s' "${LINE#*"$s"}" | grep -ao '^[0-9]\+')
    [ -n "$C" ] && [ "$C" -ge 1 ] && echo "[ok] 串读数 $s$C(≥1)" || { echo "[BAD] $s 的读数不是个数($C)"; BAD=1; }
  done
  grep -aqF '  串 [security_load_policy]=' "$OUT" || { echo "[BAD] 没数 kallsyms 那三个名字之一的串"; BAD=1; }
else
  grep -aq '^VERDICT=nocompile' "$OUT" || { echo "[BAD] 编不过却没把结局说出口(没有 VERDICT=nocompile)"; BAD=1; }
fi
# 树侧回执：两条路径现在都由同一个 report_tree 打 ⇒ 这里检查它**每次都打**
grep -aq '计数还原后=0' "$OUT" || { echo "[BAD] main.c 的还原回执没打(或不为 0)"; BAD=1; }
grep -aq '头的残留计数=0' "$OUT" || { echo "[BAD] 三个头的残留回执没打(或不为 0)"; BAD=1; }
A1=$(grep -ao '现役桩(出货那份)md5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
A2=$(grep -ao '桩还原 md5=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
[ -n "$A1" ] && [ "$A1" = "$A2" ] && [ "$A1" = "$STUB_WANT" ] && echo "[ok] 树里的桩还原成出货那份(且＝证件参照 $STUB_WANT)" || { echo "[BAD] 桩还原前后或与参照不符($A1→$A2，参照 $STUB_WANT)"; BAD=1; }

MD5B=$(grep -ao '^MD5_B=[0-9a-f]\{32\}' "$OUT" | head -1 | cut -d= -f2)
if [ -n "$MD5B" ]; then
  echo "  候选件远端 md5=$MD5B ⇒ 取回本地(只进证据目录，不进包)"
  PYTHONUTF8=1 python "$CLI" --config "$CFG" get w1162_kernelsu_rc76_candidate.ko "$EV/kernelsu_rc76_candidate.ko" >"$EV/${N}_get.log" 2>&1
  GR=$?
  LB=$(md5sum "$EV/kernelsu_rc76_candidate.ko" 2>/dev/null | cut -d' ' -f1)
  [ "$GR" = 0 ] && [ "$LB" = "$MD5B" ] && echo "[ok] 候选件两端同 md5：$LB 字节=$(wc -c <"$EV/kernelsu_rc76_candidate.ko" | tr -dc '0-9')" || { echo "[BAD] 候选件取回失败或 md5 不同(get rc=$GR 本地=${LB:-空})"; BAD=1; }
  [ -n "$MD5B" ] && [ "$MD5B" != "$SHIP0" ] && echo "[ok] 候选件 ≠ 出货件(反向断言：没把货覆盖)" || { echo "[BAD] 候选与出货同值 ⇒ 这条流水线根本没产出新东西"; BAD=1; }
fi
SHIP1=$(md5sum "$SHIP" | cut -d' ' -f1)
[ "$SHIP1" = "$SHIP0" ] && echo "[ok] 出货 ko 跑前后同值(货没动)" || { echo "[BAD] 出货 ko 被改了($SHIP0→$SHIP1)"; BAD=1; }

echo "=== 结论 ==="
if [ "$NOC" = 1 ]; then
  echo "VERDICT=w1162_nocompile 桩在这棵树的头下编不过 ⇒ 这一发答的是『接线能不能编译』那一格，产物尺未测(不是失败)；树侧三条回执见上面"
elif [ "$BAD" = 0 ]; then
  echo "VERDICT=w1162_green rc76 候选件编出来了：装载面接好且结构被静态闸证过(门在上游、桩不自己当法官、常数不凭记忆)，与出货那份只差换桩＋一行收尾；候选在 $EV/kernelsu_rc76_candidate.ko(未上机、未进包)"
else
  echo "VERDICT=w1162_red 见上面 [BAD]；每一条都是仪器或输入面的红，不是被测"
fi
exit 0
