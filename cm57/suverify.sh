#!/system/bin/sh
# suverify.sh — 在 root 会话结束之后, 由 **uid 2000** 跑的取证: 证明 su 层不依赖会话、
# 且 PATH 裸名就能拿到 root(等价于第三方 app 的 Runtime.exec("su -c ..."))。
L=/data/local/tmp/suverify.log
Q='id; grep -E "Uid|CapEff" /proc/self/status; ls -l /data/system/packages.xml; head -c 24 /proc/1/environ; echo; cat /proc/self/attr/current'
{
  echo "=== suverify 开始 uid=$(id -u) 上下文=$(id -Z 2>/dev/null) uptime=$(cat /proc/uptime) ==="
  echo "--- [0] daemon 是否还活着(会话已死) ---"
  ps -A -o PID,UID,NAME | grep -w sud
  echo "--- [1] 绝对路径调用 ---"
  /product/bin/su -c "$Q"
  echo "rc1=$?"
  echo "--- [2] 用 app 的 PATH 走裸名 su(app 就是这么调的) ---"
  env PATH=/product/bin:/apex/com.android.runtime/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin sh -c "command -v su; su -c \"$Q\""
  echo "rc2=$?"
  echo "--- [3] 我(uid2000)自己仍然够不着的那些东西, 用来对照 ---"
  ls -l /data/system/packages.xml 2>&1 | head -1
  head -c 24 /proc/1/environ 2>&1 | head -1
  echo ""
  echo "--- [4] 现场: 挂载 + enforce 状态 ---"
  grep ' /product/bin ' /proc/mounts
  getenforce
  echo "--- [5] daemon 侧的授权取证行 ---"
  cat /data/local/tmp/sud.log
  echo "=== suverify 结束 ==="
} > $L 2>&1
cat $L
