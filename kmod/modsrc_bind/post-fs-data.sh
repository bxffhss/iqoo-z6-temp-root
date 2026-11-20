#!/system/bin/sh
# 模块自己的挂载(等价于 KSU 开机做的 magic mount，但**由脚本在窗口里做**)。
# 三条已实测的钉子，都写在这里：
#   ① 只 bind /product/bin：盖 /system/bin 会把服务列表清空、起不了新 app(§6.124)
#   ② 源目录必须带 /product/bin 的**原有内容**(cp -a)：里面原有 3 项，缺了会破坏依赖它们的启动
#   ③ 收尾必须"先 root 侧 umount 成功、再删源"(PC 侧 umount 必 EPERM，§6.124⑤)
L=/data/local/tmp/modsu.log
{
  echo "===== MODSU up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) ====="
  TGT=/product/bin; NB=/data/local/tmp/pbin
  echo "BEFORE n=$(ls -A $TGT | wc -l) su=[$(ls $TGT/su 2>&1 | head -1)]"
  grep -aq pbin /proc/self/mountinfo && { echo "已挂着 ⇒ 不重复挂"; exit 0; }
  rm -rf $NB; mkdir -p $NB
  cp -a $TGT/. $NB/ ; echo "COPY_N=$(ls -A $NB | wc -l)"
  cp /data/local/tmp/sustatic $NB/su && chmod 755 $NB $NB/su
  mount --bind $NB $TGT; echo "BIND_RC=$?"
  echo "AFTER su=[$(ls -l $TGT/su 2>&1 | cut -c1-52)] n=$(ls -A $TGT | wc -l)"
  echo "MOUNTINFO=$(grep -c pbin /proc/self/mountinfo)"
  echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >$L 2>&1
chmod 666 $L
