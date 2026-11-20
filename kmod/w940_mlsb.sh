#!/system/bin/sh
# w940_mlsb.sh — #211 的一窗内 A/B：同一把尺子（run-as com.termux，uid 10667，域 runas_app）在两种执法态下各量一次同一组落点。
#   A=/data/data/com.omarea.vtools（0777 那格＝正对照） B=/data/data/com.termux（自家 DAC 就该通） C=/data/data（0771 负对照，证明尺子有牙）
#   读法：Permissive 段 A/B 通、C 红，翻执法后 A 由通变红 ⇒ 挡路的是 SELinux；A 两态都红 ⇒ SELinux 出局。
# v2 修掉两处**仪器**缺陷（第 61 发的两份件就是被它们打散的）：
#   ①原稿在 `{ … } > $O` 组里又用 `>> $O` ⇒ 两个写者各记各的偏移，后面的行**覆盖**前面的行（标签与读数被拆成两截）。
#     现在只有一个写者：cell() 里全部裸 echo，由组重定向落盘。
#   ②原稿 `ls … | head -2` 之后取 `$?`＝**head 的 rc**，永远 0 ⇒ "取不到"会被读成"通"。现在 rc 取 ls 自己的。
#   ★空输出写 EMPTY＝未测，绝不写成结论。
HA=/data/data/com.termux/files/home
O=$HA/w940.out
cell() { # $1=标签 $2=路径
  out=$(/system/bin/ls -l "$2" 2>&1)
  rc=$?
  st=$(/system/bin/stat -c '%a %U:%G %C' "$2" 2>&1)
  h2=$(printf '%s\n' "$out" | /system/bin/head -2 | /system/bin/tr '\n' '|')
  [ -z "$h2" ] && h2=EMPTY
  echo "  $1 ls_rc=$rc ls=[$h2]"
  echo "  $1 stat=[$st]"
}
{
  echo "N0 host=runas uid=$(id -u) enf=[$(cat /sys/fs/selinux/enforce 2>&1)] date=$(date)"
  echo "N1_A vtools:"
  cell A /data/data/com.omarea.vtools
  echo "N1_B own termux:"
  cell B /data/data/com.termux
  echo "N1_C data_data negative control:"
  cell C /data/data
  echo "NZ_END date=$(date)"
} > $O 2>&1
