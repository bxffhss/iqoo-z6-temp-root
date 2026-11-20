#!/system/bin/sh
# w933_modules.sh — 目标③（能不能装社区模块）的第一步：先把**现场**读清楚，不装任何东西。
# 为什么现在能做：su 那条 root 腿在执法下仍给 uid=0（§6.451 B1）；★但产物**不能落 /data/local/tmp**
# （0771＋shell 域零 capability ⇒ root 建不了文件，本发一手），所以落点用 /data/adb（root 自己的目录）
# 并 chmod 666，让 adb 侧按名字读回。
# ★★这发只读不写模块：不碰 /data/adb/modules 的内容、不跑 `ksud post-fs-data`（Z5 那包明文写着
#   那条会内核卡死＋硬复位＝我们 §6.322 那堵墙的第三方凭据）。
O=/data/adb/w933.out
{
  echo "M0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
  echo "M1 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "-- M2 模块目录现场"
  ls -la /data/adb/modules 2>&1
  echo "-- M3 有没有待装的 zip/更新（modules_update 里是什么）"
  ls -laR /data/adb/modules_update 2>&1 | head -20
  echo "-- M4 每个在架模块的 module.prop 与脚本清单（只看，不改）"
  for d in /data/adb/modules/*; do
    [ -d "$d" ] || continue
    echo "MOD=[$d]"
    cat "$d/module.prop" 2>&1
    ls -l "$d" 2>&1 | head -12
    for f in system.prop post-fs-data.sh service.sh uninstall.sh sepolicy.rule; do
      [ -f "$d/$f" ] && echo "   有 $f ($(/system/bin/ls -l "$d/$f" | /system/bin/awk '{print $5}') B)"
    done
    echo "   skip_mount=$(cat "$d/skip_mount" 2>/dev/null | wc -c) disabled=$(cat "$d/disable" 2>/dev/null | wc -c)"
  done
  echo "-- M5 ksud 在不在跑、以什么身份"
  ps -A -o PID,PPID,USER,NAME 2>&1 | grep -a -E "ksud|shd" | grep -a -v grep
  echo "-- M6 我们 ko 认不认模块（GET_INFO 那侧的形状：/data/adb/ksu 与 libadbroot）"
  ls -l /data/adb /data/adb/ksu /data/adb/ksu/lib 2>&1 | head -24
  echo "-- M7 挂载现场：模块有没有真的挂上过"
  grep -a -E "modules|/data/adb/ksu" /proc/self/mountinfo 2>&1 | head -12
  echo "MZ_END date=$(date) up=$(cut -d' ' -f1 /proc/uptime)"
} > $O 2>&1
chmod 666 $O 2>&1
echo "WRC=$?"
