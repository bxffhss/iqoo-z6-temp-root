#!/system/bin/sh
# mod_probe.sh — 在临时 root 窗口里判定"外部 .ko 能不能被本机内核接受"
# 由 cm57/round4.sh 通过 ishell 喂进来执行(靶子线程亲生的孩子 = uid0+全 caps)。
# 判据全部落盘(panic/掉会话也读得到), 主机侧 adb pull/cat 回读。
L=/data/local/tmp/mod_probe.log
D=/data/local/tmp
MD=/vendor/lib/modules/5.4-gki
rm -f $L $D/dm_before.txt $D/dm_after.txt $D/cands.txt $D/loaded.txt \
      $D/trunc.ko $D/vend_try.ko $D/vend_loaded.ko $D/loaded_by_us.txt
exec >> $L 2>&1

echo "=== mod_probe 开始 uptime=$(cat /proc/uptime) ==="
id
echo "getenforce=$(getenforce)"
grep -E 'CapEff|Se:' /proc/self/status
echo "uname=$(uname -a)"
echo "[SNAP] /product/bin 挂载数=$(grep -c 'product/bin' /proc/mounts) (本轮不该有 su 层残留)"

echo "--- 1) 当前已加载模块 ---"
wc -l < /proc/modules
cut -d' ' -f1 /proc/modules | sort > $D/loaded.txt
head -12 /proc/modules

echo "--- 2) 厂商 .ko 库存与未加载候选 ---"
echo "目录 $MD 文件数=$(ls $MD 2>/dev/null | wc -l)"
for f in $MD/*.ko; do
  n=${f%.ko}; n=${n##*/}
  grep -qx "$n" $D/loaded.txt || echo "$f"
done > $D/cands.txt
echo "未加载的 .ko 数=$(wc -l < $D/cands.txt)"
head -20 $D/cands.txt

echo "--- 3) dmesg 基线(root 下这条通道应当可用) ---"
dmesg > $D/dm_before.txt 2>&1
echo "dm_before 行数=$(wc -l < $D/dm_before.txt)"

# 挑惰性命候选(无对应硬件/纯调度器/纯格式模块 ⇒ 即使真加载了也没有副作用)
echo "--- 4) 逐个尝试 finit_module(最多 3 个候选, 成功即停) ---"
tries=0
for n in asix ax88179_178a bfq kyber brd loop i2c-dev vcan ppp_generic; do
  f=$MD/$n.ko
  [ -f "$f" ] || continue
  grep -qx "$n" $D/loaded.txt && { echo "[SKIP] $n 本来就加载着"; continue; }
  tries=$((tries+1))
  [ $tries -gt 3 ] && { echo "[STOP] 已试满 3 个, 停"; break; }
  echo "### try#$tries $n ($f)"
  $D/mod info $f
  $D/mod ins $f
  rc=$?
  dmesg > $D/dm_after.txt 2>&1
  b=$(wc -l < $D/dm_before.txt)
  echo "--- dmesg delta (从第 $((b+1)) 行起) ---"
  tail -n +$((b+1)) $D/dm_after.txt
  echo "--- end delta ---"
  cp $D/dm_after.txt $D/dm_before.txt
  if [ $rc -eq 0 ]; then
    echo "[OK] $n 已加载 state=$(cat /sys/module/$n/initstate 2>/dev/null)"
    grep "^$n " /proc/modules | head -3
    $D/mod rm $n
    echo "$n" > $D/loaded_by_us.txt
    echo "*** 判定: 外部 .ko 可被本机接受(insmod 门开着) ***"
    break
  fi
done
[ $tries -eq 0 ] && echo "[WARN] 一个候选都没试到(库存/命名不符), 本轮判据无效"

echo "--- 5) 负对照: 截断的 .ko 必须**不**成功(证明 errno 判据非恒真) ---"
C1=$(head -1 $D/cands.txt)
if [ -n "$C1" ]; then
  head -c 4096 "$C1" > $D/trunc.ko 2>&1
  ls -l $D/trunc.ko
  $D/mod ins $D/trunc.ko
else
  echo "[WARN] 没有候选文件可做负对照"
fi

echo "--- 6) 取两份厂商 .ko 供主机离线解析(CRC/vermagic 交叉验证) ---"
if [ -n "$C1" ]; then
  cp "$C1" $D/vend_try.ko && echo "[COPY] vend_try.ko <= $C1"
  $D/mod info $D/vend_try.ko
fi
for n in $(cat $D/loaded.txt); do
  if [ -f "$MD/$n.ko" ]; then
    cp "$MD/$n.ko" $D/vend_loaded.ko && echo "[COPY] vend_loaded.ko <= $MD/$n.ko (该模块**已加载** ⇒ 它的 CRC 必然与内核一致)"
    $D/mod info $D/vend_loaded.ko
    break
  fi
done

echo "--- 7) 收尾登记: 本轮改动了什么 ---"
ls -l $D/mod $D/mod_probe.sh $D/vend_try.ko $D/vend_loaded.ko $D/trunc.ko 2>/dev/null
echo "当前 /proc/modules 行数=$(wc -l < /proc/modules)"
echo "uptime=$(cat /proc/uptime) getenforce=$(getenforce)"
echo "=== mod_probe 结束 ==="
sync
