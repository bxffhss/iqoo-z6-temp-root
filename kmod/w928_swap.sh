#!/system/bin/sh
# w928_swap.sh — 把交付槽里的 su 从 sustatic v3(f7a441d2) 热换成 v5(0e52b665)，只为量
#   #192/#208 那三格参数契约(-v / -M / uid 前缀)在真机上的差别；**回退靠维持件自己**：
#   删掉活文件 ⇒ keeper 从 $SRC 重新 cp 回 v3，顺手复证一次 #186 的"第 9 秒自己回来"。
# ★本脚本报的"哪条 bind 在生效"是现场读出来的，不凭仓库印象：§6.426 把源挪进 /data/adb/ksu/pbin，
#   但第 60 发的 mountinfo 那行写的是 /local/tmp/pbin(＝/data/local/tmp/pbin)，两者必须先分清。
# ★★不要读 /proc/kmsg(它会一直阻塞＝上一发 w926 卡死的真因，不是远端失败)。
O=/data/local/tmp/w928.out
V5=/data/local/tmp/w928_v5.bin
{
  echo "S0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
  echo "-- S1 现场：两处 pbin 与 bind 源"
  grep -a pbin /proc/self/mountinfo 2>&1 | cut -c1-140
  ls -l /data/local/tmp/pbin 2>&1 | head -6
  ls -l /data/adb/ksu/pbin 2>&1 | head -6
  echo "-- S2 三个候选文件的 md5"
  md5sum /product/bin/su /data/local/tmp/pbin/su /data/adb/ksu/pbin/su /data/adb/ksu/sustatic $V5 2>&1
  echo "-- S3 keeper 在不在跑"
  ls -l /data/local/tmp/w774_keeper.log 2>&1 | head -2
  tail -3 /data/local/tmp/w774_keeper.log 2>&1
} > $O 2>&1

# 找出生效的那条 bind 的真实目录（mountinfo 里 pbin 的源路径）
SRC_DIR=$(grep -a pbin /proc/self/mountinfo 2>/dev/null | head -1 | cut -d' ' -f4 | sed 's|/local/tmp/pbin|/data/local/tmp/pbin|; s|/adb/ksu/pbin|/data/adb/ksu/pbin|')
{
  echo "S4 bind 源目录=[$SRC_DIR]"
} >> $O 2>&1

if [ ! -d "$SRC_DIR" ]; then
  { echo "S5 SKIP: 源目录不存在 ⇒ 未换(不是换失败)"; } >> $O 2>&1
  chmod 666 $O 2>&1
  exit 0
fi

{
  echo "-- S6 热换：cp→chmod→mv(同目录 rename，避开 ETXTBSY)"
  cp $V5 $SRC_DIR/su.v5new 2>&1
  chmod 755 $SRC_DIR/su.v5new 2>&1
  chown root:root $SRC_DIR/su.v5new 2>&1
  mv $SRC_DIR/su.v5new $SRC_DIR/su 2>&1
  echo "S6 mv rc=$?"
  echo "-- S7 换后读回"
  ls -l /product/bin/su 2>&1
  md5sum /product/bin/su $SRC_DIR/su 2>&1
  echo "S7 期望=0e52b665fa7492e806fe56f32d95e0a1"
} >> $O 2>&1
chmod 666 $O 2>&1
