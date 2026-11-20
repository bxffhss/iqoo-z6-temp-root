#!/usr/bin/env bash
# run_slide.sh — #146 设备侧 slide 求解器的**双向**自测（离线，不开枪、不碰设备）。
#
# 为什么这条线必须有自测：求解器是唯一一个"错了不报错"的部件——它若解出错 slide，
# punch 会拿着错的基址去改内核，症状是机器直接复位，看起来像"这一发运气不好"，
# 而真实原因是包里的表或算术过期。所以判据不是"它打出了数"，而是
# **它对已知答案那一对必须逐字对，且每个失败形状必须自己说不解**。
#
# 六道格子：
#   ① 真数据标定对(第 28 发那一次采样) ⇒ 必须 SLIDE 0000002521000000，且命中数与 PC 侧同为 16
#   ② 合成夹具(带**进位**的 slide：低段相加溢出 2^32) ⇒ 必须解出造它时用的那个值
#      ★这一格是专打"64 位当 double 用"的：不拆两段就会在进位处丢低位而不自知
#   ③ 全 0 命中的垃圾样本(用户态地址) ⇒ 必须 NOSLIDE 且退出码 2
#   ④ 表头 step_dec 写成 hex 的 200000(=十进制二十万，非 2 的幂) ⇒ 必须拒绝(真机第一跑就是这个错)
#   ⑤ 表头 CONSTS 行被删 ⇒ 驱动必须拒绝，不许自己编一个常量
#   ⑥ 原始输出里混入脏行(时间戳/统计行) ⇒ 解出的 slide 必须与干净版**同一个**
set -u
export PYTHONUTF8=1
cd "$(dirname "$0")/../.." || exit 1
W=kmod/_tmp_selftest_rdst/slide_self
rm -rf "$W"; mkdir -p "$W"
DR=kmod/w433_slide_solve.sh
AK=kmod/w435_slide.awk
CTL=$W/ctl.txt
CAL=analysis/ipk_z6_1020_2215.txt

N=0
chk() { N=$((N + 1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [FAIL] $1"; FAILED=1; fi; }
FAILED=0

[ -s "$CAL" ] || { echo "  [x] 缺标定对 $CAL ⇒ 自测无法进行(这一格必须有真数据)"; exit 1; }

echo "=== 0) 现算正对照表（与打包同一条生成路径）==="
python kmod/w436_mkctl.py analysis/kallsyms_g2a88cd145def.txt "$CTL" > "$W/mkctl.out" 2>&1
chk "①生成器 rc=0 且表里 ≥5 条窗口" "$( { [ -s "$CTL" ] && [ "$(grep -acvE '^#|^$' "$CTL")" -ge 5 ]; } && echo 1 || echo 0)"
chk "①b 表头三常量齐(address 16 位 hex / step 十进制)" "$(grep -aqE '^# CONSTS link_text=[0-9a-f]{16} link_etext=[0-9a-f]{16} step_dec=[0-9]+$' "$CTL" && echo 1 || echo 0)"

echo "=== ① 真数据标定对 ⇒ 必须复现 PC 侧那次答案 ==="
cp "$CAL" "$W/raw1.txt"
sh "$DR" "$W/raw1.txt" "$CTL" "$AK" > "$W/out1.txt" 2>&1; R1=$?
chk "②退出码 0" "$([ "$R1" = 0 ] && echo 1 || echo 0)"
chk "③SLIDE 逐字等于标定值 0000002521000000" "$(grep -aqx 'SLIDE 0000002521000000' "$W/out1.txt" && echo 1 || echo 0)"
chk "④第一名命中数与 PC 侧一致(16)" "$(grep -aq 'slide=+0000002521000000 正对照命中= *16' "$W/out1.txt" && echo 1 || echo 0)"
chk "⑤主簇大小/窗口数与 PC 侧一致(401 / 9 个)" "$(grep -aq '样本 468(主簇 401' "$W/out1.txt" && grep -aq '正对照窗口 9 个' "$W/out1.txt" && echo 1 || echo 0)"
chk "⑥中间文件已清(不留 .samp)" "$([ ! -e "$W/raw1.txt.samp" ] && echo 1 || echo 0)"

echo "=== ② 合成夹具：带进位的 slide ==="
# 造一个低段相加必溢出 2^32 的 slide：link_text 低段=0x10080000，取 s_lo=0xF0000000 ⇒ 进位。
# ★期望值由**造夹具那段代码自己写进 exp2.txt**(数据，不是文案)，shell 只读那个文件——
#   第一版我在这里手写了个 hex 常量又用 ${VAR:2} 切片去比，切片切错一位照样"比得过"的可能存在。
python - "$CTL" "$W/raw2.txt" "$W/exp2.txt" <<'PY'
import io, sys
ctl, out, exp = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [l.split() for l in io.open(ctl, encoding='utf-8') if l.strip() and not l.startswith('#')]
TEXT = 0xffffffc010080000
slide = 0x25_f0000000                   # 低段 0xF0000000 + TEXT 低段 0x10080000 ⇒ 必进位
base = TEXT + slide
lines = []
for a, ln, nm in rows:
    a = int(a, 16); ln = int(ln)
    for k in range(20):                 # 每个正对照窗口内撒 20 个点 ⇒ 主簇一定由这些函数撑着
        lines.append(base + (a - TEXT) + (k * 4) % ln)
    for k in range(4):                  # 紧贴窗口外再撒几个：考"边界不许松"
        lines.append(base + (a - TEXT) + ln + k * 8)
for k in range(60):                     # 主簇区间内的噪声(窗口外)
    lines.append(base + 0x300000 + k * 0x2001)
for k in range(40):                     # 一坨离得很远的地址(模拟模块区)：考分簇，别让它当上主簇
    lines.append(base + 0x40000000 + k * 0x10)
lines = sorted(set(lines))
io.open(out, 'w', encoding='utf-8', newline='\n').write('\n'.join('k %016x' % x for x in lines) + '\n')
io.open(exp, 'w', encoding='utf-8', newline='\n').write('%016x\n' % slide)
print('夹具：样本 %d 行，期望 slide=%016x' % (len(lines), slide))
PY
EXP2=$(tr -d '\r\n' < "$W/exp2.txt")
[ ${#EXP2} = 16 ] || { echo "  [x] 期望值长度不对 [$EXP2] ⇒ 夹具自己坏了"; FAILED=1; }
sh "$DR" "$W/raw2.txt" "$CTL" "$AK" > "$W/out2.txt" 2>&1; R2=$?
chk "⑦合成夹具解出造它时用的 slide(进位路径正确)" "$(grep -aqx "SLIDE $EXP2" "$W/out2.txt" && echo 1 || echo 0)"
MC=$(sed -n 's/^.*主簇 \([0-9]\{1,\}\).*/\1/p' "$W/out2.txt" | head -1)
chk "⑦b 主簇确实是「那些函数」撑起来的那一坨(现取数字≥180，不靠正则形状)" "$([ "${MC:-0}" -ge 180 ] && echo 1 || echo 0)"
chk "⑦c 主簇数字是从自己打印的那行现取的(取不到就必须判红，不许静默当 0)" "$([ -n "$MC" ] && echo 1 || echo 0)"
chk "⑧合成夹具的退出码 0" "$([ "$R2" = 0 ] && echo 1 || echo 0)"

echo "=== ③~⑤ 失败形状必须自己说不解 ==="
python - "$W/raw3.txt" <<'PY'
import io, sys
io.open(sys.argv[1], 'w', encoding='utf-8', newline='\n').write(
    '\n'.join('k 0000005b%08x' % i for i in range(600)) + '\n')   # 全用户态地址 ⇒ 高半区一个都没有
PY
sh "$DR" "$W/raw3.txt" "$CTL" "$AK" > "$W/out3.txt" 2>&1; R3=$?
chk "⑨垃圾样本 ⇒ NOSLIDE" "$(grep -aq '^NOSLIDE' "$W/out3.txt" && echo 1 || echo 0)"
chk "⑩NOSLIDE 时退出码必须是 2(不许 0)" "$([ "$R3" = 2 ] && echo 1 || echo 0)"
chk "⑪NOSLIDE 时**不许**同时打出 SLIDE 行" "$(! grep -aq '^SLIDE ' "$W/out3.txt" && echo 1 || echo 0)"

# ⑫a 真机第一跑那个原错：hex 的 200000 当十进制喂 ⇒ <1MB 那道先拦住
sed 's/step_dec=[0-9]*/step_dec=200000/' "$CTL" > "$W/ctl4.txt"
sh "$DR" "$W/raw1.txt" "$W/ctl4.txt" "$AK" > "$W/out4.txt" 2>&1; R4=$?
chk "⑫a 步长 200000(<1MB) ⇒ 拒绝并点名 step_dec" "$([ "$R4" = 2 ] && grep -aq 'step_dec' "$W/out4.txt" && echo 1 || echo 0)"
chk "⑫a2 失败输出**只有一句** NOSLIDE(第一版 BEGIN 报错后 END 又补一句『没有一条窗口』＝自相矛盾两行，这一格就是它的牙)" "$([ "$(grep -ac '^NOSLIDE' "$W/out4.txt")" = 1 ] && echo 1 || echo 0)"
# ⑫b ≥1MB 但不是 2 的幂(0x1E8480) ⇒ 必须走"2 的幂"那道(否则等于第二道牙从没被测过)
sed 's/step_dec=[0-9]*/step_dec=2000000/' "$CTL" > "$W/ctl4b.txt"
sh "$DR" "$W/raw1.txt" "$W/ctl4b.txt" "$AK" > "$W/out4b.txt" 2>&1; R4B=$?
chk "⑫b 步长 2000000(≥1MB 非 2 的幂) ⇒ 由『2 的幂』那道拦住" "$([ "$R4B" = 2 ] && grep -aq '不是 2 的幂' "$W/out4b.txt" && echo 1 || echo 0)"

grep -av '^# CONSTS ' "$CTL" > "$W/ctl5.txt"                          # 删表头
sh "$DR" "$W/raw1.txt" "$W/ctl5.txt" "$AK" > "$W/out5.txt" 2>&1; R5=$?
chk "⑬缺 CONSTS 表头 ⇒ 驱动拒绝(不许自己编常量)" "$([ "$R5" = 2 ] && grep -aq 'CONSTS' "$W/out5.txt" && echo 1 || echo 0)"

sed 's/step_dec=[0-9]*/step_dec=1/' "$CTL" > "$W/ctl6.txt"             # 步长小于 1MB
sh "$DR" "$W/raw1.txt" "$W/ctl6.txt" "$AK" > "$W/out6.txt" 2>&1; R6=$?
chk "⑭步长 <1MB ⇒ 拒绝(候选会多到扫不完，且说明表坏了)" "$([ "$R6" = 2 ] && grep -aq 'step_dec' "$W/out6.txt" && echo 1 || echo 0)"

echo "=== ⑥ 原始输出混脏行 ⇒ 答案不许变 ==="
{ echo "启动时间戳 1792502572"; echo "N=1023"; echo ""; sed 's/^/  /' "$W/raw1.txt"; echo "k 不是十六进制的行"; } > "$W/raw7.txt"
sh "$DR" "$W/raw7.txt" "$CTL" "$AK" > "$W/out7.txt" 2>&1
chk "⑮脏行版与干净版解出同一个 slide" "$([ "$(grep -aoxE 'SLIDE [0-9a-f]+' "$W/out1.txt")" = "$(grep -aoxE 'SLIDE [0-9a-f]+' "$W/out7.txt")" ] && echo 1 || echo 0)"
chk "⑯样本计数没被脏行灌水(仍是 468)" "$(grep -aq '样本 468' "$W/out7.txt" && echo 1 || echo 0)"

echo
echo "共 $N 项断言；$([ "$FAILED" = 0 ] && echo 'PASS 全绿' || echo 'FAIL 有红')"
[ "$FAILED" = 0 ] || exit 1
exit 0
