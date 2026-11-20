#!/system/bin/sh
# w966_mlsab.sh — #214 的读数腿（**翻执法之后**跑，不依赖 root）：量 w967 造的那两格，把 TE 与 MLS 分开。
# ★为什么必须在执法态：Permissive 段 MAC 只记不拦 ⇒ 两格都通＝**没有判别力的读数**（例 184①那个形状）。
# ★尺子（单变量）：同一 uid(10667)、同一域(`runas_app`)、同一类型(`app_data_file:dir`)，**只有 MLS 类别不同**：
#     P=s0（subject 必支配）／Q=s0:c93,c257（subject 只有 c512,c768 ⇒ 不可能支配）
#   ⇒ 执法下「P 通、Q 拒」＝挡路的是 **MLS**；「P 也拒」＝MLS 解释不了 ⇒ 回到 **TE 缺规则**。
#   另附 vtools 那格当**交叉对照**（第 61 发 #211 量到的就是它；它是否可 run-as 不影响主判据）。
# ★取 rc 一律"先裸取、再裁剪"（`| head` 之后 `$?` 是 head 的＝例 186③，已有静态闸 w951）；空读数写 EMPTY＝未测。
O=/data/local/tmp/w966.out
D=/data/data/com.termux/files
U() { cut -d' ' -f1 /proc/uptime 2>&1; }
cell() { # $1=标签 $2=落点（一律 run-as com.termux，同域同类别）
  local out rc
  out=$(run-as com.termux /system/bin/ls -l "$2" 2>&1); rc=$?
  local st; st=$(run-as com.termux /system/bin/stat -c '%a %U:%G %C' "$2" 2>&1)
  [ -n "$out" ] || out=EMPTY
  [ -n "$st" ] || st=EMPTY
  echo "  $1 ls_rc=$rc first=[${out%%$'\n'*}]"
  echo "  $1 stat=[$st]"
}
{
  echo "H0 date=$(date) up=$(U)"
  enf=$(cat /sys/fs/selinux/enforce 2>&1)
  echo "H1 执法态读数=$enf（单次取值，H6 的分支与判读都只看这一个数）  ★必须=1 才是判据跑；=0 时本跑只是正对照"
  echo "H2 主判据 A＝类别够（P：app_data_file:s0）:"
  cell P_dir $D/MLS_P_plain
  cell P_file $D/MLS_P_plain/inner.txt
  echo "H3 主判据 B＝类别不够（Q：app_data_file:s0:c93,c257，同类型同属主同 mode）:"
  cell Q_dir $D/MLS_Q_cats
  cell Q_file $D/MLS_Q_cats/inner.txt
  echo "H4 负对照（DAC 就该红的格：别人家的家目录，0700）:"
  cell OTHER /data/data/com.omarea.vtools
  echo "H5 判读提示（由人读，不由脚本自断）:"
  echo "   P_dir ls_rc=0 且 Q_dir ls_rc!=0 ⇒ MLS 是那道闸；delta 要动类别/mlstrusted，不该加 allow runas_app app_data_file"
  echo "   P_dir ls_rc!=0 ⇒ MLS 解释不了 ⇒ 回到 TE 缺规则那一支"
  echo "   任何一格 EMPTY 或读不到 ⇒ 该格记「未测」"
  echo "H6 清理策略：只有**执法态那一跑**才删（Permissive 这跑是正对照，删了就没得对比了）"
  if [ "$enf" = "1" ]; then
    echo "   ★动手删（Termux 自己 uid 删自己家；执法后 root 删不动，所以只能这么做）:"
    run-as com.termux /system/bin/rm -f $D/MLS_P_plain/inner.txt $D/MLS_Q_cats/inner.txt 2>&1
    run-as com.termux /system/bin/rmdir $D/MLS_P_plain $D/MLS_Q_cats 2>&1
    echo "   复证(该报 No such file)：$(run-as com.termux /system/bin/ls -d $D/MLS_P_plain $D/MLS_Q_cats 2>&1 | head -1)"
  else
    echo "   跳过删除（enf=$enf）⇒ 两格留着，翻执法后再跑一次本腿"
  fi
  echo "HZ_END up=$(U) date=$(date)"
} > $O 2>&1
chmod 666 $O 2>&1
