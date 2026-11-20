#!/bin/bash
echo '--- 找 ksuctl88 的源码 ---'
ls -l /home/lucy/ksuctl88.c /home/lucy/cm57/ksuctl88.c 2>/dev/null
F=$(find /home/lucy /root -maxdepth 3 -name 'ksuctl88.c' 2>/dev/null | head -1)
echo "源码=[$F]"
[ -n "$F" ] && grep -n "ver\|VER\|784\|magic\|MAGIC\|app_profile" "$F" | head -25
echo '--- 二进制里能不能看到版本号写在第 4 字节 ---'
python3 - <<'PY'
import subprocess,struct
p='/home/lucy/ksuctl88'
b=open(p,'rb').read()
print('二进制字节数=',len(b))
PY
echo '--- 设备上那份名单的头 8 字节(如果还能读到) ---'
ls -l /data/adb/ksu/.allowlist 2>&1 | head -2
echo END
