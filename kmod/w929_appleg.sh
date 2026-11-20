#!/system/bin/sh
# w929_appleg.sh — 同一份参数契约矩阵，但这次跑在 **sustatic v5**(0e52b665) 上（w928 刚热换的槽）。
# 和 w927(v3, f7a441d2) 逐格对，只为一件事：#192/#208 那几格(-v / -M / uid 前缀 / 分开 argv 的多词 -c)
# 到底是"代码没实现"还是"实现了但没上机"。回退由 w930 那条腿做(cp+mv，靠 md5 复证)。
HA=/data/data/com.termux/files/home
A=$HA/w929.out
U() { cut -d' ' -f1 /proc/uptime; }
SU=/product/bin/su

{
  echo "H0 date=$(date) up=$(U) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "H1 slot md5=$(/system/bin/md5sum $SU 2>&1) (期望 0e52b665=v5)"
} > $A 2>&1

cell() {
  lbl=$1; shift
  echo "V_${lbl}_BEGIN up=$(U)" >> $A 2>&1
  out=$( "$@" 2>&1 </dev/null )
  rc=$?
  echo "V_${lbl} rc=$rc out=[$(printf '%s' "$out" | /system/bin/head -2 | /system/bin/tr '\n' '|')]" >> $A 2>&1
}

cell dashv       "$SU" -v
cell c_single    "$SU" -c id
cell c_multi_one "$SU" -c 'id; echo SECOND'
cell c_split_argv "$SU" -c ls -l /data/local/tmp/kd
cell uid0_id     "$SU" 0 id
cell root_c_id   "$SU" root -c id
cell dashM       "$SU" -M -c id
cell mountmaster "$SU" --mount-master -c id
cell dashmc      "$SU" -mc id
cell piped_shell /system/bin/sh -c "printf 'id\nexit\n' | $SU"
cell child_mksh  /system/bin/sh -c "su -c 'id'"
cell v_request   "$SU" -V

echo "BZ_END date=$(date) up=$(U)" >> $A 2>&1
