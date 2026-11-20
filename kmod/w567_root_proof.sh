#!/system/bin/sh
# w567_root_proof.sh —— 执法态下由 **root** 跑的取证腿(经 `/system/bin/su -c <这一个词>` ⇒ 不被 sh -c 的词切法坑)。
#   三件独立证人：①把 `id` 的结果落到一个 root 自己创建、末尾 chmod 666 的件里(内容由 root 写，屏幕上的字由 Termux 自己的 cat 打印)；
#                 ②把靶子文件从 644 改成 600(属主是 shell:shell，uid 10667 的 Termux 无权 chmod ⇒ 做到的人只能是 root)；
#                 ③自己带时刻/状态读数。
OUT=/data/local/tmp/w567_root.out
PROBE=/data/local/tmp/w567_probe
: > "$OUT"
/system/bin/id >> "$OUT" 2>&1
echo "enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) dom=$(cat /proc/self/attr/current | tr -d '\000')" >> "$OUT"
echo "ls_probe_before=$(ls -l $PROBE 2>&1)" >> "$OUT"
/system/bin/chmod 600 "$PROBE" 2>>"$OUT"
echo "chmod_rc=$?" >> "$OUT"
echo "ls_probe_after=$(ls -l $PROBE 2>&1)" >> "$OUT"
sync
chmod 666 "$OUT" 2>/dev/null
echo "W567_DONE out=$(wc -c < $OUT)"
