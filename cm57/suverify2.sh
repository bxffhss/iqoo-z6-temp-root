#!/system/bin/sh
# suverify2.sh — 由 uid 2000 跑: (A) app 那种"裸名 su"调用; (B) 用 su 装 kprobe 观察 setresuid
L=/data/local/tmp/suverify2.log
{
  echo "=== A) 裸名 su(app 的 PATH, 不带绝对路径) uid=$(id -u) ==="
  env PATH=/product/bin:/apex/com.android.runtime/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin sh -c 'command -v su; su -c id'
  echo "rcA=$?"
  echo
  echo "=== B) 用 su 装 kprobe 看 app 启动时有没有 setresuid(否证 patch-zygote 捷径) ==="
  /product/bin/su -c 'echo 0 > /sys/kernel/tracing/trace; echo "p:sures __arm64_sys_setresuid" >> /sys/kernel/tracing/kprobe_events; echo 1 > /sys/kernel/tracing/events/kprobes/sures/enable; echo 1 > /sys/kernel/tracing/tracing_on; echo "表=[$(cat /sys/kernel/tracing/kprobe_events)]"'
  echo "--- 由 uid2000 起 app ---"
  am force-stop com.user.app
  am start -n com.user.app/.MainActivity
  sleep 4
  /product/bin/su -c 'echo "sures 命中行数=$(grep -c sures: /sys/kernel/tracing/trace)"; grep -m6 sures: /sys/kernel/tracing/trace; echo 0 > /sys/kernel/tracing/events/kprobes/sures/enable; echo "-:sures" > /sys/kernel/tracing/kprobe_events; echo "摘完=[$(cat /sys/kernel/tracing/kprobe_events)]"'
  echo "rcB=$?"
  echo
  echo "=== C) 现场 ==="
  grep product /proc/mounts
  getenforce
} > $L 2>&1
tr -d '\000' < $L
