#!/bin/bash
# v2：把"每个符号 grep 一次全树"改成"每棵树只 grep 一次建索引"，并顺带补嵌套类型 dump。
# 跑法(远端，必须脱管，否则 web shell 超时会把它杀掉)：
#   setsid nohup bash /home/lucy/remote_cfgdiff2.sh </dev/null >/dev/null 2>&1 &
# 然后反复 tail /home/lucy/cfgdiff2.log
LOG=/home/lucy/cfgdiff2.log
exec > "$LOG" 2>&1
echo "START $(date)"
DEV=/root/k/config_dev.txt
grep -E '^[A-Z0-9_]+=[ym]' "$DEV" | cut -d= -f1 | sort -u > /tmp/dev_on.txt
echo "设备 config =y/=m 符号数: $(wc -l < /tmp/dev_on.txt)"

for T in linux-5.4.281 ack nothing_sm7325_v_mr nothing_sm7325_u_mr; do
  TREE=/root/k/$T
  [ -d "$TREE" ] || continue
  OUT=/home/lucy/cfgdiff_$T.txt
  echo "########## $T" > "$OUT"
  [ -f "$TREE/.config" ] || { echo "  没有 .config" >> "$OUT"; continue; }
  echo "  建 Kconfig 符号索引..."
  grep -rhoE '^[[:space:]]*config[[:space:]]+[A-Za-z0-9_]+' "$TREE" --include='Kconfig*' 2>/dev/null \
    | awk '{print $2}' | sort -u > /tmp/ksym_$T.txt
  echo "  索引大小: $(wc -l < /tmp/ksym_$T.txt)"
  grep -E '^[A-Z0-9_]+=[ym]' "$TREE/.config" | cut -d= -f1 | sort -u > /tmp/tree_on.txt
  comm -23 /tmp/dev_on.txt /tmp/tree_on.txt > /tmp/missing_$T.txt
  echo "  设备有而该树 .config 没有的符号数: $(grep -c . /tmp/missing_$T.txt)" >> "$OUT"
  comm -23 /tmp/missing_$T.txt /tmp/ksym_$T.txt > /tmp/vpriv_$T.txt
  comm -12 /tmp/missing_$T.txt /tmp/ksym_$T.txt > /tmp/depoff_$T.txt
  echo "  [A] 树里无此 Kconfig 符号(= 厂商私有，olddefconfig 会静默丢掉它的字段): $(grep -c . /tmp/vpriv_$T.txt)" >> "$OUT"
  sed 's/^/      /' /tmp/vpriv_$T.txt >> "$OUT"
  echo "  [B] 符号在、但依赖被关(可以强制打开后重算布局): $(grep -c . /tmp/depoff_$T.txt)" >> "$OUT"
  sed 's/^/      /' /tmp/depoff_$T.txt >> "$OUT"
  echo "--- $T 的 [A] 名单(前 80):"
  head -80 /tmp/vpriv_$T.txt
  echo "  进度: $(date)"
done

echo "########## 补嵌套类型 dump(夹逼 task_struct 中段 + struct module)"
NEST="sched_dl_entity thread_info module_kobject module_layout sched_rt_entity plist_node cred param_list"
for T in nothing_sm7325_v_mr ack; do
  D=/root/k/layout_$T
  OBJ=""; for c in dw.lto.o dw.o; do [ -f "$D/$c" ] && OBJ="$D/$c" && break; done
  [ -z "$OBJ" ] && continue
  F=/home/lucy/layout3_$T.txt; : > "$F"
  for S in $NEST; do echo "===== $S ($T)" >> "$F"; pahole -C "$S" "$OBJ" >> "$F" 2>&1; done
  echo "  OK $T -> $F ($(wc -l < "$F") 行)"
done
echo "END $(date)"
