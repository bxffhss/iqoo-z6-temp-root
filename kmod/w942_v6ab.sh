#!/system/bin/sh
# w942_v6ab.sh — v6 与交付槽 v3 的**同窗 A/B**（宿主＝run-as com.termux，uid 10667 已授权，Permissive 段）。
# 三件事一起量才读得出结论：①出不出 root(契约通了没) ②stderr 有没有那行诊断 ③一格提权判定都没放宽。
# ★两支都从同一个目录跑(/data/local/tmp)，只差字节 ⇒ "文件存在性"这一维被钉死(§6.451 的教训)。
# ★rc 必须来自被测件本身：先取 rc，再用 head 截展示用的一行(上一发我吃过一次管道末端 rc＝例 184⑤同族)。
HA=/data/data/com.termux/files/home
A=$HA/w942.out
U() { cut -d' ' -f1 /proc/uptime; }
V6=/data/local/tmp/suv6
V3=/product/bin/su
one() { # $1=BIN $2=标签 $3..=参数
  b=$1; l=$2; shift 2
  err=$( "$b" "$@" 2>&1 >/dev/null </dev/null )
  out=$( "$b" "$@" 2>/dev/null </dev/null )
  rc=$?
  first=$(printf '%s\n' "$out" | /system/bin/head -1)
  e1=$(printf '%s\n' "$err" | /system/bin/head -c 70)
  echo "  $l rc=$rc out=[$first] stderr_len=${#err} stderr=[$e1]" >> $A 2>&1
}
{
  echo "V0 date=$(date) up=$(U) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "V1 v6md5=$(/system/bin/md5sum $V6 2>&1 | cut -c1-32) v3md5=$(/system/bin/md5sum $V3 2>&1 | cut -c1-32)"
} > $A 2>&1
echo "== v3（交付槽那份，基线）" >> $A 2>&1
one "$V3" "v3 -c id"      -c id
one "$V3" "v3 0 id"       0 id
one "$V3" "v3 -v"         -v
one "$V3" "v3 -M -c id"   -M -c id
echo "== v6（诊断进开关 + AOSP uid 前缀拼接）" >> $A 2>&1
one "$V6" "v6 -c id"      -c id
one "$V6" "v6 0 id"       0 id
one "$V6" "v6 root id"    root id
one "$V6" "v6 -v"         -v
one "$V6" "v6 -M -c id"   -M -c id
echo "== v6 开了诊断开关(该出现那行 stderr)" >> $A 2>&1
err=$(SUW_SU_DEBUG=1 "$V6" -c id 2>&1 >/dev/null)
echo "  v6 debug开关 stderr_len=${#err} stderr=[$(printf '%s\n' "$err" | /system/bin/head -c 90)]" >> $A 2>&1
echo "VZ_END up=$(U)" >> $A 2>&1
