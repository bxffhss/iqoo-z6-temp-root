#!/system/bin/sh
# w922_shell_leg.sh — #209 机制判别，跑在 adb shell(uid 2000, allow_shell=1)这一侧。
# 一手事实：同一个 shell 里 /system/bin/su 直写两次都出 root(Y1/Y2)，但它 fork 的子 shell 里
# 同一条字面量 rc=127(Y3)，连"另一个脚本文件被解释后执行"(Y4/Y5)也一样 ⇒ 差别在**执行者这个任务**，
# 不在字符串。这一发把两件事分开：
#   (甲) 子 shell 到底能不能 execve 任何东西(C7/C8 正对照)
#   (乙) 环里那次 execve 有没有被 ko 看见(SD5/SD3 会印，SU0 没印＝没走到 su 匹配)
# 每格前后都打 up=，好和整环快照逐条成对。只在 Permissive 段跑。
A=/data/local/tmp/w922.out
{
  echo "Q0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime) id=[$(id)]"
  echo "Q0b enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "Q0c self pid=$$ ppid=$PPID comm=$(cat /proc/self/comm)"
} > $A 2>&1

echo "C1_BEGIN up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "C1 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C2_BEGIN(子 shell 裸写) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/system/bin/su -c id' >> $A 2>&1
echo "C2 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C3_BEGIN(env 直接 execve) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/env /system/bin/su -c id >> $A 2>&1
echo "C3 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C4_BEGIN(子 shell 带 exec 内建) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c 'exec /system/bin/su -c id' >> $A 2>&1
echo "C4 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C5_BEGIN(su 这条路径到底存不存在) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/ls -l /system/bin/su >> $A 2>&1
echo "C5 rc=$?" >> $A 2>&1
/system/bin/ls -l /product/bin/su >> $A 2>&1
echo "C5b rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C7_BEGIN(甲-正对照：子 shell 能 execve 存在的程序吗) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/system/bin/toybox id' >> $A 2>&1
echo "C7 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C8_BEGIN(子 shell exec 一个 shell 脚本) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/system/bin/sh /data/local/tmp/w922b.sh' >> $A 2>&1
echo "C8 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C9_BEGIN(本 shell 再来一次直写＝同窗正对照) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "C9 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "C10_BEGIN(整环里属于我的那几行，现读) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/dmesg -t 2>&1 | /system/bin/grep -aE "KSUBEAT (SU0|SD3|SD5|SU4)" | /system/bin/tail -25 >> $A 2>&1
echo "C10 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "QZ_END date=$(date) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
