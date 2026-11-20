#!/system/bin/sh
echo "== holder of @suwksu inode 3476537 =="
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  for f in $p/fd/*; do
    if [ "$(readlink $f 2>/dev/null)" = "socket:[3476537]" ]; then
      echo "pid=$pid exe=$(readlink $p/exe 2>&1) cmd=$(tr '\0' ' ' <$p/cmdline 2>/dev/null)"
    fi
  done
done 2>/dev/null
echo "== app files 目录 =="
ls -l /data/data/com.suw.manager/files/ 2>&1 | head -25
echo "== app shared_prefs / 有没有 ksuctl/sushd 文件 =="
find /data/data/com.suw.manager -iname '*sushd*' -o -iname '*ksuctl*' -o -iname '*shd*' 2>/dev/null | head -20
echo "== app lib =="
ls -l /data/app/*/com.suw.manager*/lib/arm64/ 2>/dev/null | head
