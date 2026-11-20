#!/system/bin/sh
# w1018_mlsrange_leg.sh (v2) —— #219 只问一件事：**装载期 DOM 请求里那段 MLS 范围，落没落在在线 subject 上**。
# ★为什么这一格不答"范围能不能支配带类别的对象"(v1 的答案)——拿**活策略**(pol.live_1027＝282a6861，跨 boot 逐字节相同)
#   现查的三条硬事实(证件 kmod/w103_evidence/mlsattr_live_1028.txt，远端 host f7319012991c＋正控制 devpts∈mlstrustedobject 过)：
#     ① 89 条 mlsconstrain 里管 dir/file 的 20 条，**每一条都带 `( t1 == mlstrustedsubject )` 这一支**；
#     ② `shell` **就在** `mlstrustedsubject` 里(活策略现查，不是 CIL 文本推断)；
#     ③ `/data/local/tmp` 用的 `shell_data_file` **本身在 `mlstrustedobject` 里**。
#   ⇒ subject 一旦是 shell，MLS 约束恒满足 ⇒ 这把尺**绿也证不了范围在起作用、红也证不了不在**＝没有判别力(例 187①)。
#   支配关系那一半因此换给 **PC 侧 run-as**(域 `runas_app`，现查**不在**可信 subject 集合)去量＝"这台机此刻 MLS 确实在管"的正对照；
#   本腿只答"落没落"，并把措辞写死成落没落，不许被读成支配证明。
# ★第 70 发那两把尺(A 组)同时红的真因**仍未归因**：活策略里 `allow shell app_data_file:file {… read open getattr …}` **是在的**
#   ⇒ 不是"缺 TE 规则"；每条约束又豁免 mlstrustedsubject ⇒ 不是 MLS。⇒ 这一版把**每次读的 errno 文本**都收进日志
#   (`2>&9` 只是 dup，不 execve、不开新文件；v1 那句 `2>/dev/null` 恰好把唯一能分案的证人丢掉了)。
# ★★翻执法之后只用**内建＋重定向**(glob / read / dup)。执法前可以 exec(第 70 发连 flip 之后的 `cat /proc/uptime` 都 rc=0，
#   但本题不需要 exec，就按最保守的形状写，省得再拿一发去试"执法后还能不能 exec")。
# 结构上不碰 /sys/fs/selinux/load(#216-B 那一格)，不装任何模块，不改名单条目。
L=/data/local/tmp/w1018_mls.out
WANT_DOM=u:r:shell:s0-s0:c0.c1023
BASE_DOM=u:r:shell:s0
H=/data/data/com.termux/files
A_P=$H/W18_P
A_Q=$H/W18_Q
S_P=/data/local/tmp/w1018_sP
S_Q=/data/local/tmp/w1018_sQ
: > $L
sync
say() { echo "$1" >&9; }
# ★fd 9 在翻执法**之前**开好：SELinux 对 regular file 只在 open 时检查 ⇒ 之后写日志不再过 MAC；
#   同时它就是"errno 收集口"，任何 `2>&9` 的失败文本都落进同一份证件，顺序即配对(错误行紧跟着它那条 M_ 行)。
exec 9>> "$L"

# --- 0) 域读数：形状是这一发的第一件产物 -------------------------------------
# ★★v1 死在这里：`read` 遇到"EOF 且没有换行"会**返回 1 但已经把值赋进变量**(`/proc/self/attr/current` 就是这种文件)，
#   而 v1 写的是 `read … || DOM="(读不出)"` ⇒ 有效读数被自己的兜底覆盖掉。⇒ 规矩：**判空，不判 rc**。
RVAL=""
RCODE=0
rd() {  # rd <路径> ⇒ RVAL=第一行内容(可能为空)  RCODE=read 的 rc；★空才叫"读不出"
    RVAL=""
    { read -r RVAL < "$1"; } 2>&9
    RCODE=$?
}
rd /proc/self/attr/current
DOM_NOW=$RVAL
S0_RCODE=$RCODE
say "BEGIN up=$(cat /proc/uptime) enf=$(cat /sys/fs/selinux/enforce 2>&1)"
say "WANT_DOM=$WANT_DOM  BASE_DOM=$BASE_DOM"
say "S0 DOM_NOW=[$DOM_NOW] read_rc=$S0_RCODE  (判据看的是这个值，不是 rc)"
rd /proc/$PPID/attr/current
PARENT_DOM=$RVAL
say "S0 PARENT_DOM=[$PARENT_DOM] (父进程＝派我这一个的 root agent；它和我只差范围⇒DOM 落在子进程；两者相同⇒无从区分)"
IDZ=$(id -Z 2>&9); IDZ_RC=$?
say "S0 ID_Z=[$IDZ] id_rc=$IDZ_RC  (第二把独立读数：和 DOM_NOW 应当一致)"
say "S0 PPID_CMD=$(tr '\0' ' ' < /proc/$PPID/cmdline)"
say "S0 ENF_NOW=[$(cat /sys/fs/selinux/enforce 2>&1)]"
sync

# --- 1) 清掉历次留下的尺(两把 A 组只有 root 删得动，§6.460/§6.472 一手) -----
for D in $H/MLS_Q_cats $H/MLS_P_cats $H/W99_P9 $H/W99_Q9 $H/W18_P $H/W18_Q $S_P $S_Q; do
  if [ -e "$D" ]; then
    rm -rf "$D" 2>&9
    say "CLEANUP $D rm_rc=$? still=$([ -e "$D" ] && echo YES || echo NO)"
  else
    say "CLEANUP $D 不在(已净)"
  fi
done
sync

# --- 2) 铺两组尺(Permissive 段做)：同 owner 同 mode，**唯一差别＝类别** --------
# S 组＝仪器正控制：TE 现查齐、对象类型在 mlstrustedobject ⇒ 执法下**期望两把都绿**；红了就说明我的形状坏(不是 MLS)。
# A 组＝留给 PC 侧 run-as 的正对照(那把 subject 不在可信集合)＝"MLS 此刻在管"。
mkdir -p $S_P $S_Q $A_P $A_Q
chmod 700 $S_P $S_Q $A_P $A_Q
echo x > $S_P/in.txt
echo y > $S_Q/in.txt
echo a > $A_P/in.txt
echo b > $A_Q/in.txt
/system/bin/chcon u:object_r:shell_data_file:s0 $S_P $S_P/in.txt
say "CHCON_SP_rc=$?"
/system/bin/chcon u:object_r:shell_data_file:s0:c93,c257 $S_Q $S_Q/in.txt
say "CHCON_SQ_rc=$?"
/system/bin/chcon u:object_r:app_data_file:s0 $A_P $A_P/in.txt
say "CHCON_AP_rc=$?"
/system/bin/chcon u:object_r:app_data_file:s0:c93,c257 $A_Q $A_Q/in.txt
say "CHCON_AQ_rc=$?"
# ★★第 70 发只印了**目录**的标签，没印**被读那个文件**的标签 ⇒ 变量纯不纯当时无法作答。这一版四行目录＋四行文件全印。
for F in $S_P $S_Q $A_P $A_Q; do
  say "LBL dir [$F]=$(ls -dZ $F 2>&9 | tr -s ' ')"
  say "LBL file[$F/in.txt]=$(ls -dZ $F/in.txt 2>&9 | tr -s ' ')"
done
for F in $S_P/in.txt $S_Q/in.txt $A_P/in.txt $A_Q/in.txt; do
  say "DAC [$F]=($(stat -c '%a owner=%u group=%g' $F 2>&9))"
done
chmod 666 $L
sync

# --- 3) Permissive 段的正控制：同一 subject 此刻**能**读到全部四把 ----------
rd $S_P/in.txt; SP0=$RVAL; SP0_RC=$RCODE
rd $S_Q/in.txt; SQ0=$RVAL; SQ0_RC=$RCODE
rd $A_P/in.txt; AP0=$RVAL; AP0_RC=$RCODE
rd $A_Q/in.txt; AQ0=$RVAL; AQ0_RC=$RCODE
say "PRE S_P rc=$SP0_RC content=[$SP0] | S_Q rc=$SQ0_RC content=[$SQ0] | A_P rc=$AP0_RC content=[$AP0] | A_Q rc=$AQ0_RC content=[$AQ0]"
say "PRE_OK=$([ "$SP0_RC" = 0 ] && [ "$SQ0_RC" = 0 ] && [ "$AP0_RC" = 0 ] && [ "$AQ0_RC" = 0 ] && echo 1 || echo 0)  (★0⇒尺子本身就没铺对，下面所有红都不算证人)"
sync

# --- 4) 翻执法(本腿最后一件"要做在 Permissive 里"的事) ----------------------
echo 1 > /sys/fs/selinux/enforce 2>&9
say "FLIP_rc=$?"
sync

# --- 5) 执法下的量：全部内建＋重定向，errno 落 fd 9 ------------------------
rd /proc/self/attr/current
DOM_AFTER=$RVAL
say "DOM_AFTER=[$DOM_AFTER] read_rc=$RCODE"
rd $S_P/in.txt
SP1=$RVAL
say "M_SP rc=$RCODE content=[$SP1]  (S 组对照：plain s0，期望**通**)"
rd $S_Q/in.txt
SQ1=$RVAL
say "M_SQ rc=$RCODE content=[$SQ1]  (S 组主形：带类别 c93,c257；★shell∈mlstrustedsubject＋shell_data_file∈mlstrustedobject ⇒ 通了**不算**范围在起作用)"
rd $A_P/in.txt
AP1=$RVAL
say "M_AP rc=$RCODE content=[$AP1]  (A 组对照：Termux 家 plain s0；红＝未归因的厂商闸候选，见文件头★，不是 MLS)"
rd $A_Q/in.txt
AQ1=$RVAL
say "M_AQ rc=$RCODE content=[$AQ1]  (A 组带类别)"
set -- $A_Q/*
say "M_AQ_glob_n=$# first=[$1]  (glob＝getdents，不需要 exec；n=1 且 first 是字面量⇒列不出来)"
sync

# --- 6) 判据(只答"落没落"；带牙：读数空、读数走形都不许给结论) -------------
say "DOM_AGREE=$([ "$DOM_NOW" = "$IDZ" ] && echo 是 || echo 否)  (read 与 id -Z 两把独立读数应当一致)"
say "DOM_STABLE=$([ "$DOM_NOW" = "$DOM_AFTER" ] && echo 是 || echo 否)  (翻执法前后应当同一个域；不一致⇒中途有人换了域，本题读数不可用)"
if [ -z "$DOM_NOW" ]; then
  say "MLS_RANGE_VERDICT=未测(在线域读不出 read_rc=$S0_RCODE 且 id -Z=[$IDZ] ⇒ 本题没被问过)"
elif [ "$DOM_NOW" != "$DOM_AFTER" ]; then
  say "MLS_RANGE_VERDICT=未测(执法前=[$DOM_NOW] 执法后=[$DOM_AFTER] 两个读数不一致 ⇒ 先查谁在中途换域)"
elif [ "$DOM_NOW" = "$WANT_DOM" ]; then
  say "MLS_RANGE_VERDICT=判正(★装载期那段带范围的串**落在**在线 subject 上：DOM=[$DOM_NOW]) ※只证落没落；支配那一半按活策略对本 subject 恒无判别力，见文件头①②③"
elif [ "$DOM_NOW" = "$BASE_DOM" ]; then
  say "MLS_RANGE_VERDICT=判负(请求=[$WANT_DOM] 在线=[$BASE_DOM] ⇒ 范围被丢掉/归一化，DOM 这条路给不出带范围的 subject)"
else
  say "MLS_RANGE_VERDICT=未测(在线域=[$DOM_NOW] 既不是请求串也不是交付基线 ⇒ DOM 走形，先查装载期再谈本题)"
fi
say "MLS_SHELL_ARM=不适用(活策略现查：shell∈mlstrustedsubject，20/20 条 dir-file 约束都豁免它 ⇒ S/A 两组的绿红都**不能**读成范围在支配)"

# --- 7) 收尾：S 组 adb shell 删得动(TE 现查 shell 对 shell_data_file 有 unlink/remove_name)，链里负责删并读回；
#         A 组在 root-owned 0700 目录里，只有下一次开窗第一派 root 腿删得动(名单已进 kmod/w1014_b2_leg.sh 步骤 0)。
say "PENDING_CLEANUP=$A_P $A_Q (执法中不 exec rm) + $S_P $S_Q (PC 侧链删)"
U=$(cat /proc/uptime 2>/dev/null); URC=$?
say "END up=[$U] uptime_cat_rc=$URC"
sync
