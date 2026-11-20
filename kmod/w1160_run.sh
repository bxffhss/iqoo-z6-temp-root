#!/bin/bash
# w1160_run.sh —— 本地包装(0 枪)：把 #241 的**候选二进制**放上设备、让它自己把 11 件夹具各读一遍，
#   拉回主机判读。★全程 dry(不带 --send)⇒ 不开驱动 fd、不 insmod、不碰 `/sys/fs/selinux/load`。
#   这一格买的是三件事：①"这台机的加载器肯装这份静态二进制"(第六十五发 PT_TLS 那一族)；
#   ②同一份纯逻辑在 aarch64 **用户态**的读数＝x86 宿主(§350)＝第 97 发内核(§347)三方对表；
#   ③判读件的牙(拿一份**改了数的**副本喂它，必须报红)。
# 用法：bash kmod/w1160_run.sh [证件名]
set -u
# ★GBK 控制台上 python 打「⇒」会抛 UnicodeEncodeError(10-18 一手：w408/w415 各炸一次)⇒ 判读件必须自己带这个
export PYTHONUTF8=1
D="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-w1160_dev_v1}"
# ★adb 的**本地**参数要相对路径(或 `G:/…` 那种 adb 直接认的写法)，不能用 `pwd` 给的 `/g/…`：
#   带 MSYS_NO_PATHCONV=1 就是"别替我转路径"，于是 adb 收到 `/g/项目/…` 一律 rc=1 且不告诉你为什么
#   (这一跑第一次就是这么全红的)。⇒ 下面所有 adb 参数一律用相对名，本地读写用绝对路径无妨。
cd "$D" || exit 1
EV=kmod/w103_evidence
BIN=cm57/ksuctl_241_v1
FIX=kmod/w1152_fixtures
LEG=kmod/w1160_leg.sh
CHK=kmod/w1160_dev_preview_check.py
TBL=$FIX/expect.txt
LEG97=$EV/w1153_leg_shot97.out
DEV=/data/local/tmp/w1160
RAW=$EV/${N}.raw.txt
LIST="ok1.bin ok3.bin ok9.bin ok600.bin bad_cmd.bin bad_sub.bin bad_nul.bin bad_inner.bin bad_len.bin bad_hdr.bin bad_tail.bin"

for f in "$BIN" "$LEG" "$CHK" "$TBL" "$LEG97"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
BAD=0
echo "本地 md5：候选件=$(md5sum "$BIN" | cut -d' ' -f1) 腿=$(md5sum "$LEG" | cut -d' ' -f1) 表=$(md5sum "$TBL" | cut -d' ' -f1)"

echo "=== [1] 设备在线闸(掉线就明说没跑，不许当通过) ==="
ST=$(MSYS_NO_PATHCONV=1 adb get-state 2>&1 | tr -d '\r' | tail -1)
if [ "$ST" != "device" ]; then
  echo "[BAD] adb 状态＝${ST:-空} ⇒ 这一格**没跑**，不是通过；先修连接再来"
  exit 1
fi
echo "  [ok] adb get-state=device"
echo "  设备侧现读(只读)：$(MSYS_NO_PATHCONV=1 adb shell 'getenforce; echo -n "enforce="; cat /sys/fs/selinux/enforce; echo; echo -n "kernelsu 计数="; ls /sys/module | grep -c kernelsu; id -u' 2>&1 | tr -d '\r' | tr '\n' ' ')"

echo "=== [2] 铺目录：先删净再复证(跨 boot 陈件会把读数造假) ==="
MSYS_NO_PATHCONV=1 adb shell "rm -rf $DEV" >/dev/null 2>&1
LEFT=$(MSYS_NO_PATHCONV=1 adb shell "ls -d $DEV 2>&1" | tr -d '\r' | tail -1)
case "$LEFT" in *"No such file"*) echo "  [ok] 旧目录已不在：$LEFT";; *) echo "  [BAD] 复证没通过，目录还在：$LEFT"; BAD=1;; esac
MSYS_NO_PATHCONV=1 adb shell "mkdir -p $DEV" >/dev/null 2>&1

echo "=== [3] push 并 chmod(★0666 没有 x 位，uid 也要 x ⇒ 上一版就栽在 exit=126) ==="
# ★push 失败要把**那句话**留在证件上：上一跑 12 个 push 全红而我把 stderr 丢了 ⇒ 红了说不出原因。
push_one() { # <本地相对路径> <远端绝对路径> <名字>
  local out rc m
  out=$(MSYS_NO_PATHCONV=1 adb push "$1" "$2" 2>&1); rc=$?
  # ★rc 要在**这条赋值**上当场取：写成 `m=$(adb … | tr … | tail -1); rc=$?` 拿到的是 tail 的 0
  #   (#215 那条"管道末端 rc"的规矩，这里差点又犯一次)
  m=$(printf '%s\n' "$out" | tr -d '\r' | tail -1)
  if [ "$rc" = 0 ]; then echo "    push $3 ok：$m"; else echo "    [BAD] push $3 rc=$rc ⇒ $m"; BAD=1; fi
}
push_one "$BIN" "$DEV/ksuctl_241" 候选件
push_one "$LEG" "$DEV/w1160_leg.sh" 腿件
for f in $LIST; do push_one "$FIX/$f" "$DEV/$f" "$f"; done
MSYS_NO_PATHCONV=1 adb shell "chmod 755 $DEV/ksuctl_241 $DEV/w1160_leg.sh; chmod 644 $DEV/*.bin" >/dev/null 2>&1
X=$(MSYS_NO_PATHCONV=1 adb shell "ls -l $DEV/ksuctl_241" 2>&1 | tr -d '\r' | tail -1)
case "$X" in *"rwxr-xr-x"*) echo "  [ok] 设备侧现读 x 位：$X";; *) echo "  [BAD] 二进制权限不是 0755：$X"; BAD=1;; esac

echo "=== [4] 两端 md5 逐件对表 ==="
LB=$(md5sum "$BIN" | cut -d' ' -f1)
RB=$(MSYS_NO_PATHCONV=1 adb shell "md5sum $DEV/ksuctl_241" 2>&1 | tr -d '\r' | cut -c1-32)
[ "$LB" = "$RB" ] && echo "  [ok] 候选件两端同 md5：$LB" || { echo "  [BAD] 候选件 本地=$LB 设备=$RB"; BAD=1; }
NN=0
for f in $LIST; do
  L=$(md5sum "$FIX/$f" | cut -d' ' -f1)
  R=$(MSYS_NO_PATHCONV=1 adb shell "md5sum $DEV/$f" 2>&1 | tr -d '\r' | cut -c1-32)
  if [ "$L" = "$R" ]; then NN=$((NN + 1)); else echo "  [BAD] $f 本地=$L 设备=${R:-读不到}"; BAD=1; fi
done
[ "$NN" = 11 ] && echo "  [ok] 11 件夹具两端同 md5(逐件比过 $NN/11)" || { echo "  [BAD] 夹具 md5 对上的只有 $NN/11"; BAD=1; }

echo "=== [5] 正对照「这份 aarch64 件在这台机上真跑得起来」(用不带副作用的 fmt) ==="
FMT_RAW=$(MSYS_NO_PATHCONV=1 adb shell "$DEV/ksuctl_241 fmt" 2>&1); FR=$?
FMT=$(printf '%s\n' "$FMT_RAW" | tr -d '\r')
printf '%s\n' "$FMT" | tail -2 | sed 's/^/    fmt: /'
if [ "$FR" = 0 ] && printf '%s\n' "$FMT" | grep -qa 'apfmt:'; then
  echo "  [ok] fmt 出数了 ⇒ 加载器接受了这份静态件(TLS 那一族过)"
else
  echo "  [BAD] fmt 没出数(rc=$FR)⇒ 这份件在这台机上根本跑不起来，后面全不算"
  BAD=1
fi

echo "=== [6] 跑腿并拉回 ==="
MSYS_NO_PATHCONV=1 adb shell "sh $DEV/w1160_leg.sh $DEV" > "$RAW" 2>&1
LRC=$?
echo "  腿 rc=$LRC 产物=$(wc -c <"$RAW" | tr -dc '0-9') 字节 RUN 块=$(grep -c '^RUN ' "$RAW" | tr -dc '0-9')"
[ "$LRC" = 0 ] || { echo "  [BAD] 腿非零退出"; BAD=1; }
grep -qa '^END leg v1' "$RAW" && echo "  [ok] 腿自己那条 END 在(没被截断)" || { echo "  [BAD] 没有 END ⇒ 流被截/中途死，读数不作数"; BAD=1; }
grep -qa '^RC ok1.bin 0' "$RAW" && echo "  [ok] 每件都留了 RC 行(例 235：\$? 要落地)" || echo "  [提示] 没抓到 RC ok1.bin 0 那一行"

echo "=== [7] PC 侧判读(正跑) ==="
python "$CHK" "$RAW" "$TBL" "$LEG97" > "$EV/${N}.txt" 2>&1
CRC=$?
sed 's/^/  /' "$EV/${N}.txt" | tail -16
if [ "$CRC" = 0 ] && grep -qa '^VERDICT=w1160_pass' "$EV/${N}.txt"; then
  echo "  [ok] 判读绿(退出码 $CRC)"
else
  echo "  [BAD] 判读红(rc=$CRC)⇒ 逐条分『被测差』还是『仪器差』再定性"
  BAD=1
fi

echo "=== [8] 判读件的牙：改一份副本喂它，必须报红 ==="
cp "$RAW" "$EV/${N}_mut.raw.txt"
sed -i 's/^PREVIEW dec=0 why=0 n=1 /PREVIEW dec=0 why=3 n=1 /' "$EV/${N}_mut.raw.txt"
python "$CHK" "$EV/${N}_mut.raw.txt" "$TBL" "$LEG97" > "$EV/${N}_mut.txt" 2>&1
MRC=$?
MB=$(grep -c '^\[BAD\]' "$EV/${N}_mut.txt" | tr -dc '0-9')
if [ "$MRC" != 0 ] && [ "${MB:-0}" -ge 1 ]; then
  echo "  [ok] 变异件被抓(rc=$MRC、[BAD] $MB 条)：$(grep -am1 '^\[BAD\]' "$EV/${N}_mut.txt" | cut -c1-92)"
else
  echo "  [BAD] 变异件仍 rc=$MRC/[BAD]=${MB:-0} ⇒ 那把判读尺是恒绿的空尺"
  BAD=1
fi
rm -f "$EV/${N}_mut.raw.txt" "$EV/${N}_mut.txt"

echo "=== [9] 收尾：设备侧只删我们这一格铺的东西，并复证 ==="
MSYS_NO_PATHCONV=1 adb shell "rm -rf $DEV" >/dev/null 2>&1
GONE=$(MSYS_NO_PATHCONV=1 adb shell "ls -d $DEV 2>&1" | tr -d '\r' | tail -1)
case "$GONE" in *"No such file"*) echo "  [ok] 删净并复证：$GONE";; *) echo "  [BAD] 复证说还在：$GONE"; BAD=1;; esac
echo "  收尾现读(只读)：$(MSYS_NO_PATHCONV=1 adb shell 'getenforce; echo -n "enforce="; cat /sys/fs/selinux/enforce; echo; echo -n "kernelsu 计数="; ls /sys/module | grep -c kernelsu' 2>&1 | tr -d '\r' | tr '\n' ' ')"

echo "=== 结论 ==="
if [ "$BAD" = 0 ]; then
  echo "VERDICT=w1160_green #241 候选件在设备 aarch64 用户态的读数判正(0 枪；未开窗、未 insmod、未写 load)"
else
  echo "VERDICT=w1160_red 上面每条 [BAD] 都是**仪器或输入面**的红，不是被测"
fi
exit 0
