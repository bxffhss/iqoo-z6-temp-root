#!/system/bin/sh
# name_test.sh —— 验证"su 这个名字"到底是谁的需求。
#   做法：把同一个二进制复制成另一个名字，放回 /product/bin（bind 的源目录），
#   然后用 NP管理器的 uid 去跑它：①用原名 su ②用怪名 ③从 PATH 里 `command -v` 看得到谁。
OUT=/data/local/tmp/name_test.out
SRC=/product/bin/su
ALT=/product/bin/ksuhelper
{
  echo "=== 1) 造一个改名副本 ==="
  cp "$SRC" "$ALT" 2>&1 && chmod 755 "$ALT" && ls -l "$ALT"
  echo "=== 2) 内核层：名字重要吗（都用 uid=10475 起） ==="
  echo "-- 原名 su --"
  /data/local/tmp/asuid 10475 "$SRC" -c id 2>&1 | tail -2
  echo "-- 怪名 ksuhelper --"
  /data/local/tmp/asuid 10475 "$ALT" -c id 2>&1 | tail -2
  echo "=== 3) app 层：PATH 里能找到哪些名字 ==="
  echo "PATH=$PATH"
  echo "command -v su        -> $(command -v su 2>&1)"
  echo "command -v ksuhelper -> $(command -v ksuhelper 2>&1)"
  echo "=== 4) 收尾：删掉副本 ==="
  rm -f "$ALT"; ls -l "$ALT" 2>&1 | tail -1
  echo "DONE"
} > "$OUT" 2>&1
