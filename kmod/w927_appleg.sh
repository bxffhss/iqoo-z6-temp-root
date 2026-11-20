#!/system/bin/sh
# w927_appleg.sh — #192 su 参数契约矩阵，跑在"确实能用"的那条 su 上：/product/bin/su
# （＝包里的 sustatic，md5 f7a441d2；w925 已证：存在的文件谁都能 exec，包括 Android mksh 的子 shell）。
# 为什么现在值得跑：#209 已把"任意 app 授权不上"的墙归到"调用者在 execve 前先 stat"那一层，
# 那么交付剩下的缺口就只在**参数契约**——app 侧 suw/第三方 app 通常按 Magisk 的形状调 su。
# 每格只报 rc + 首行，别把整份输出灌进产物。宿主＝run-as com.termux（免打字）。
HA=/data/data/com.termux/files/home
A=$HA/w927.out
U() { cut -d' ' -f1 /proc/uptime; }
SU=/product/bin/su

{
  echo "H0 date=$(date) up=$(U) uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>&1)"
  echo "H1 su file: $(/system/bin/ls -l $SU 2>&1)"
} > $A 2>&1

cell() { # $1=标签 $2..=命令
  lbl=$1; shift
  echo "V_${lbl}_BEGIN up=$(U)" >> $A 2>&1
  out=$( "$@" 2>&1 </dev/null )
  rc=$?
  echo "V_${lbl} rc=$rc out=[$(printf '%s' "$out" | /system/bin/head -2 | /system/bin/tr '\n' '|')]" >> $A 2>&1
  echo "V_${lbl}_END up=$(U)" >> $A 2>&1
}

cell v_dashv    "$SU" -v
cell v_c_single "$SU" -c id
cell v_c_multi  "$SU" -c 'id; echo SECOND'
cell v_c_quoted "$SU" -c 'ls -l /data/local/tmp/kd'
cell v_uid0_id  "$SU" 0 id
cell v_root_c   "$SU" root -c id
cell v_dashM    "$SU" -M -c id
cell v_mountmaster "$SU" --mount-master -c id
cell v_pipe     /system/bin/sh -c "echo id | $SU"
cell v_childmksh_multi /system/bin/sh -c "su -c 'id'"
cell v_c_whoami "$SU" -c whoami
cell v_noargs_pipe /system/bin/sh -c "printf 'id\nexit\n' | $SU"

echo "BZ_END date=$(date) up=$(U)" >> $A 2>&1
