#!/system/bin/sh
# w_a_send.sh —— (A) root 腿：在 rc76 候选的窗里跑 ksuctl setsepol --send（真实 ioctl 一发）。
#   经 @sushd 由 suw manager 以 uid=0 执行 ⇒ 满足 do_set_sepolicy 的 only_root 检查。
#   退出码口径(ksuctl.c:398)：0=没发/内核回 rc>=0；1=拿不到 fd；2=用法/文件读不成；4=内核回负数。
#   真正区分在打出来的那行 SET_SEPOLICY fd= rc= errno=（clean=-EOPNOTSUPP/95，malformed=-EINVAL/22）。
OUT=/data/local/tmp/w_a_send.out
BIN=/data/local/tmp/ksuctl_a
echo "=== A: ksuctl setsepol a_ok1.bin --send（clean 命令流）===" > $OUT
$BIN setsepol /data/local/tmp/a_ok1.bin --send >> $OUT 2>&1
echo "exit=$?" >> $OUT
echo "=== B: ksuctl setsepol a_bad_len.bin --send（畸形）===" >> $OUT
$BIN setsepol /data/local/tmp/a_bad_len.bin --send >> $OUT 2>&1
echo "exit=$?" >> $OUT
echo "=== C: 读 /proc/ksu_sepol（解码面审计记录，最后一次写入的痕迹）===" >> $OUT
cat /proc/ksu_sepol >> $OUT 2>&1
echo "" >> $OUT
echo "=== DONE ===" >> $OUT
