#!/bin/bash
# 找出"设备 config 里有(=y/=m)，但该树 olddefconfig 之后没了"的开关，并区分两种原因：
#   (1) 树里根本没有这个 Kconfig 符号  ⇒ 厂商私有(要 vivo 源码才能表达它的字段)
#   (2) 符号在、但依赖没满足被关掉      ⇒ 可以强制打开后重算布局
# 这条直接回答"64 字节从哪来"，不用猜。
# 用法：bash /home/lucy/remote_cfgdiff.sh   然后取回 /home/lucy/cfgdiff_<树>.txt
LOG=/home/lucy/cfgdiff.log
exec > "$LOG" 2>&1
echo "START $(date)"
DEV=/root/k/config_dev.txt
sort -u -o /tmp/dev_on.txt <(grep -E '^[A-Z0-9_]+=[ym]' "$DEV" | cut -d= -f1)
echo "设备 config 里 =y/=m 的符号数: $(wc -l < /tmp/dev_on.txt)"

for T in linux-5.4.281 ack nothing_sm7325_v_mr nothing_sm7325_u_mr; do
  TREE=/root/k/$T
  [ -d "$TREE" ] || continue
  OUT=/home/lucy/cfgdiff_$T.txt
  : > "$OUT"
  echo "########## $T" | tee -a "$OUT"
  if [ ! -f "$TREE/.config" ]; then echo "  没有 .config" | tee -a "$OUT"; continue; fi
  sort -u -o /tmp/tree_on.txt <(grep -E '^[A-Z0-9_]+=[ym]' "$TREE/.config" | cut -d= -f1)
  echo "  该树 .config =y/=m 数: $(wc -l < /tmp/tree_on.txt)"
  MISSING=$(comm -23 /tmp/dev_on.txt /tmp/tree_on.txt)
  echo "  设备有而树没有的符号数: $(echo "$MISSING" | grep -c . )" | tee -a "$OUT"
  n_nosym=0; n_dep=0
  for S in $MISSING; do
    if grep -rqE "^[[:space:]]*config[[:space:]]+$S\b" "$TREE" --include=Kconfig* --include=Kconfig.debug 2>/dev/null; then
      n_dep=$((n_dep+1)); echo "  [有符号但被关] $S" >> "$OUT"
    else
      n_nosym=$((n_nosym+1)); echo "  [树里无此 Kconfig 符号 = 厂商私有] $S" >> "$OUT"
    fi
  done
  echo "  小结: 厂商私有 $n_nosym 个 / 依赖被关 $n_dep 个" | tee -a "$OUT"
  grep -E '厂商私有' "$OUT" | head -60 | tee -a "$LOG"
done
echo "END $(date)"
