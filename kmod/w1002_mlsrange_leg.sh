#!/system/bin/sh
# w1002_mlsrange_leg.sh —— #219（一腿到底）：subject 用 **Termux 的 su 子进程**（run-as 那条路是第 62 发验过的），
#   唯一变量＝profile 里那条域串的 **MLS 范围**：`u:r:shell:s0` vs `u:r:shell:s0-s0:c0.c1023`。
#   量它能不能读一个**只差类别**的兄弟目录。顺带把"shell 是不是 mlstrustedsubject"用行为判掉
#   （那条旧 claim 的原始凭据是我用错 seinfo 得到的空读数，md §6.468/例 187①）。
# ★为什么不走 `$SU -c`：腿自己 uid=0，而名单里是 app uid ⇒ 从 root 再 su 一次可能被拒；
#   run-as→env su 是**已经跑通过**的形状(§6.451/6.460)，所以三量全走它，不发明第二条路。
# ★每段 sync（这台机的窗说没就没）；结构上不碰 /sys/fs/selinux/load。
L=/data/local/tmp/w1002_mlsrange.out
H=/data/data/com.termux/files
CTL=/data/local/tmp/ksuctl88
PKG=com.termux
: > $L
sync
say() { echo "$1" >> $L; }
say "BEGIN up=$(cat /proc/uptime) enf=$(cat /sys/fs/selinux/enforce 2>&1) id=$(id 2>&1)"

# uid 现取（重装就换，本仓口径④）
UID_T=$(pm list packages -U 2>/dev/null | grep -a "^package:$PKG " | sed 's/.*uid://')
say "uid_现取=$UID_T  (来自 pm list packages -U)"
if [ -z "$UID_T" ]; then say "[x] 取不到 $PKG 的 uid ⇒ 停"; chmod 666 $L; sync; exit 1; fi

RULER='a=$(ls -d /data/data/com.termux/files/W99_P9 2>&1); ra=$?; b=$(ls -d /data/data/com.termux/files/W99_Q9 2>&1); rb=$?; echo "CTX=$(cat /proc/self/attr/current 2>&1) Uid=$(cat /proc/self/status 2>/dev/null | grep -a ^Uid: | tr -s \  ) P9_rc=$ra Q9_rc=$rb Q9msg=[$b]"'
measure() {
  run-as $PKG sh -c "/system/bin/env /system/bin/su -c '$RULER'" >> $L 2>&1
  say "  ($1) 上面那行的 run-as/su 链 rc=$?"
}

# 1) 铺尺（Permissive 段做；同 type/同 owner/同 mode，唯一差别＝类别）
mkdir -p $H/W99_P9 $H/W99_Q9; chmod 700 $H/W99_P9 $H/W99_Q9
echo x > $H/W99_P9/in.txt; echo x > $H/W99_Q9/in.txt
/system/bin/chcon u:object_r:app_data_file:s0 $H/W99_P9 $H/W99_P9/in.txt
/system/bin/chcon u:object_r:app_data_file:s0:c93,c257 $H/W99_Q9 $H/W99_Q9/in.txt
say "P9=$(ls -dZ $H/W99_P9 2>&1 | tr -s ' ')"
say "Q9=$(ls -dZ $H/W99_Q9 2>&1 | tr -s ' ')"

# 2) 先按交付形状给 Termux 一条 s0 的 profile，再翻执法
$CTL setprof "$UID_T" $PKG u:r:shell:s0 >> $L 2>&1
say "GRANT_s0_rc=$?"
sync
echo 1 > /sys/fs/selinux/enforce 2>>$L
say "FLIP_rc=$? enf=$(cat /sys/fs/selinux/enforce 2>&1) getenforce=$(getenforce 2>&1)"
sync

# 3) A 基线（域=s0）
say "--- A 基线 u:r:shell:s0 ---"
measure A
sync

# 4) B 只加宽 MLS 范围（type/role 一字不动）
$CTL setprof "$UID_T" $PKG u:r:shell:s0-s0:c0.c1023 >> $L 2>&1
say "SETPROF_wide_rc=$?"
say "名单回读=$( $CTL allowlist 2>&1 | tr -d '\n' | cut -c1-170)"
sync; sleep 2
say "--- B 加宽 u:r:shell:s0-s0:c0.c1023 ---"
measure B
# 趁加宽把尺删掉（MLS 挡属主 unlink 是第 62/63 发一手，别留删不掉的尾巴）
run-as $PKG sh -c "/system/bin/env /system/bin/su -c 'rm -rf $H/W99_P9 $H/W99_Q9; ls -d $H/W99_P9 $H/W99_Q9 2>&1 | tr -s \" \"" >> $L 2>&1
say "CLEAN_rc=$?"
sync

# 5) C 收回原域（负对照：域回 s0；尺已删 ⇒ 读不到应是 No such file，不是 Permission denied）
$CTL setprof "$UID_T" $PKG u:r:shell:s0 >> $L 2>&1
say "SETPROF_back_rc=$?"
sync; sleep 2
say "--- C 收回 s0（尺已删，期望 No such file） ---"
measure C
say "终态 enf=$(cat /sys/fs/selinux/enforce 2>&1) 名单=$( $CTL allowlist 2>&1 | tr -d '\n' | cut -c1-170)"
say "END up=$(cat /proc/uptime)"
chmod 666 $L
sync
