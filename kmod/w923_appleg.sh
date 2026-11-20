#!/system/bin/sh
# w923_appleg.sh — #209 机制判别（宿主＝run-as com.termux ⇒ uid 10667，已在名单里）。
# 一手形状：同一个 shell 直写 /system/bin/su 出 root(Y1/Y2)，但它 fork 的子 shell 里同一条字面量
# rc=127(Y3)，脚本被解释后再执行也 rc=127(Y4/Y5)。★上一发(w922)又排除了"字符串/改道坏了"：
# env 那格报的是 execve 自己的 ENOENT，而 C7 证明子 shell 能 execve 存在的程序。
# 这一发要分开的三件事：
#   (甲) 子 shell 有没有真的发出 execve —— 环里 SU0/SD3/SD5 会不会出现
#   (乙) 直写为什么能成 —— 是不是"本 shell 的 argv 字符串"这条路径
#   (丙) 能不能用**别的落点**绕开（A7 直接 exec 改道目标本身）
# ★注意宿主域＝runas_app，不是交付用的 untrusted_app_25；这一发只回答 shell/ko 那条轴，
#   域那条轴要复现时再回 Termux 真终端跑同一份脚本。
HA=/data/data/com.termux/files/home
A=$HA/w923.out
R=$HA/w923_ring.txt

{
  echo "H0 date=$(date) up=$(cut -d' ' -f1 /proc/uptime)"
  echo "H1 id=[$(id)]"
  echo "H2 ctx=[$(cat /proc/self/attr/current 2>&1)]"
  echo "H3 seccomp=[$(grep -a -E 'Seccomp|NoNewPrivs' /proc/self/status 2>&1 | tr '\n' ' ')]"
  echo "H4 enf=[$(cat /sys/fs/selinux/enforce 2>&1)] mod=$(grep -c '^kernelsu ' /proc/modules 2>&1)"
  echo "H5 su exists? $(/system/bin/ls -l /system/bin/su 2>&1 | head -1)"
} > $A 2>&1

echo "A1_BEGIN(直写＝已知能成) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "A1 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A2_BEGIN(子 shell 裸写＝已知挂) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/system/bin/su -c id' >> $A 2>&1
echo "A2 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A3_BEGIN(env 直接 execve) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/env /system/bin/su -c id >> $A 2>&1
echo "A3 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A4_BEGIN(子 shell 带 exec 内建) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c 'exec /system/bin/su -c id' >> $A 2>&1
echo "A4 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A6_BEGIN(正对照：子 shell exec 存在的程序) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/system/bin/toybox id' >> $A 2>&1
echo "A6 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A7_BEGIN(丙：直接 exec 改道目标本体 kd) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/ls -lZ /data/local/tmp/kd >> $A 2>&1
/data/local/tmp/kd -c id >> $A 2>&1
echo "A7 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A8_BEGIN(丙2：子 shell 里 exec kd) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/sh -c '/data/local/tmp/kd -c id' >> $A 2>&1
echo "A8 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "A9_BEGIN(直写第二次，同窗正对照) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c id >> $A 2>&1
echo "A9 rc=$? END up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1

echo "B1_BEGIN(用 A1 那条 root 通道把环捞出来) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
/system/bin/su -c '/system/bin/dmesg -t > /data/data/com.termux/files/home/w923_ring.txt 2>&1' >> $A 2>&1
echo "B1 rc=$? ring_bytes=$(/system/bin/ls -l $R 2>&1 | /system/bin/awk '{print $5}')" >> $A 2>&1
echo "BZ_END date=$(date) up=$(cut -d' ' -f1 /proc/uptime)" >> $A 2>&1
