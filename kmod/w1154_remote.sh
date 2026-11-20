#!/bin/bash
# w1154 远端跑手(0 枪，构建机)：用**宿主 gcc** 编 w1154_host_probe(里面 include 的就是上机那份核心)，
# 然后把它指到那 11 件夹具上跑，印出与设备腿同格式的读数。
# 输入件由本地包装 put 进来：/home/lucy/w1154_{main.c,core.h,fix.tar}
set -u
D=/home/lucy/w1154
rm -rf "$D"; mkdir -p "$D"
echo "BEGIN $(date)"
echo "MACHINE=$(uname -m)  CC=$(gcc -dumpversion 2>/dev/null)"

echo; echo "=== 1) 三份输入的 md5(缺任何一份就不跑) ==="
for f in w1154_main.c w1154_core.h w1154_fix.tar; do
  [ -s /home/lucy/$f ] || { echo "!! /home/lucy/$f 不在或是空的 ⇒ 停"; exit 1; }
  cp /home/lucy/$f "$D/$f" || { echo "!! 拷 $f 失败"; exit 1; }
  echo "MD5_$f=$(md5sum "$D/$f" | cut -d' ' -f1)"
done
mkdir -p "$D/fix" && tar -xf "$D/w1154_fix.tar" -C "$D/fix" || { echo "!! 解包失败"; exit 1; }
cp "$D/w1154_core.h" "$D/w1151_sepolicy_core.h"   # ← 主源里 include 的就是这个名字，别改成副本
NFBIN=$(ls "$D/fix"/*.bin 2>/dev/null | wc -l)
echo "FIXTURES_BINS=$NFBIN  (判据：=11)"
[ "$NFBIN" = 11 ] || { echo "!! 夹具不是 11 件 ⇒ 停"; exit 1; }
# ★逐件印 `FIXMD5 <md5> <名字>`(不是粘成一行)：本地要**逐行比对**，粘成一行就得在空格里做解析——
#   这种"证据格式"的省事最后都会变成一条读错的账。
(cd "$D/fix" && md5sum *.bin | awk '{print "FIXMD5", $1, $2}')

echo; echo "=== 2) 编(-Wall -Wextra -Werror；警告一律不当通过) ==="
cd "$D"
gcc -std=gnu11 -O2 -Wall -Wextra -Werror -o w1154_host_probe w1154_main.c 2> build.log
RC=$?
echo "HOST_MAKE_RC=$RC"
ERRN=$(grep -cE ': error: ' build.log); WARNN=$(grep -cE ': warning: ' build.log)
echo "DIAG_ERR=$ERRN DIAG_WARN=$WARNN"
sed -n '1,25p' build.log
[ "$RC" -eq 0 ] || { echo "!! 编不过 ⇒ 判负"; exit 1; }

echo; echo "=== 3) 跑(11 格 + 变体 ok9@8) ==="
./w1154_host_probe "$D/fix" 2>&1 | tee "$D/run.txt"
grep -q '^HOST end$' "$D/run.txt" || { echo "!! 没跑到 HOST end ⇒ 判负"; exit 1; }
NP=$(grep -c '^PROBE ' "$D/run.txt"); NM=$(grep -c 'MISSING' "$D/run.txt")
echo "PROBE_LINES=$NP MISSING=$NM  (判据：NP=12 且 MISSING=0)"
[ "$NP" = 12 ] && [ "$NM" = 0 ] || { echo "!! 覆盖不全 ⇒ 判负"; exit 1; }
echo "VERDICT=ok"; echo "END $(date)"
