#!/bin/bash
# w1153_sepd_chain.sh —— 第 97 发＝#238 部件①的**上机预演**：把刚验过的解码核心(z6sepdec.ko)与
#   四把来源同形的命令流夹具带进一扇窗，逐格比"内核读数"与"PC 期望"。
#
# 问的只有一格：**同一段码在 aarch64 内核里跑出来的读数，是否与 x86 宿主上跑出的读数一致。**
# ★这一发**不改运行期安全策略**：不写 /sys/fs/selinux/ 任何东西、不调 security_load_policy、
#   不动出货 ko 的字节；探针件由腿自己 rmmod。⇒ 它不需要 #237 那两道 APPROVE 钥匙。
#
# ★读法(开枪前写死，七条，不许互相顶替)：
#   ① 没等到腿件里 `END up=` ⇒ **未测**(机器若在窗口里复位，那是另一栏账，按 bootreason＋采样器记)。
#   ② 腿印 `FAIL=ko 不在／期望表不在／ctl.txt 没给 KO_MD5／件 md5 不符／表 md5 不符` ⇒ **未测**
#      (腿自己拒了，什么都没解；这些是它的前置闸，不是被测)。
#   ③ 印 `insmod 非 0` ⇒ **未测**(探针没进去＝装载面/版本闸的事，另记，别写成"解码不一致")。
#   ④ 印 `GROUP_SKIP slots=…` ⇒ 那一组未测；其余组仍算，但 `pass` 的满分要按**跑到的组**折减后判。
#   ⑤ `IDENTITY=ok` ＋ `COUNTS pass=13 fail=0` ⇒ **判正**。
#   ⑥a 某格差在**决定性的三把**(why/n/bad_at)上，且那格 `ddrc=0`＋`in_md5/in_fnv` 与 PC 相同 ⇒
#      **判负＝跨架构读数不一致**(这一发的答案，负结果也值钱)。
#   ⑥b 某格只差在**派生的两把**(max_arg/lenmatch)上 ⇒ 那是**期望表(我自己的 Python 模型)红**，
#      **不是被测**，也不许直接判负：跨架构那一格交给 `w1154` 三方对表裁决(同一份 C 码在 x86 宿主上
#      读同一批字节；设备＝宿主而表≠两端 ⇒ 修模型；设备≠宿主 ⇒ 那才是发现)。
#      ★第 97 发就是这一格：`bad_len` 设备/宿主都给 max_arg=5，表写 0 ⇒ 模型红；把这条写死成两支，
#      就是为了"模型红"永远不许冒充"判负"。
#   ⑦ 任一格 `in_md5`/`in_fnv` 与 PC 那份不符，或 `ddrc≠0` ⇒ 那格算**仪器红**(字节没忠实送到)，
#      不许据此说"内核解错了"。
#
# 用法：SHOT=97 bash kmod/w1153_sepd_chain.sh           # 只到铺件＋六把闸(0 枪)
#       SHOT=97 I_KNOW=1 bash kmod/w1153_sepd_chain.sh  # 开窗派腿
#       REJUDGE=<归档腿件> bash kmod/w1153_sepd_chain.sh  # ★0 枪：拿已有的读数＋**现行**期望表重判
#         (修完模型不必再烧一发才能给它定性；这一支全程不碰 adb，也不 reboot)
#         ★重判的满分只认"按现行表逐格重算出来的 MATCH＝表行数"；腿自己那行 `COUNTS pass=<REDACTED>
#           是**开枪时那张表**的账，原样印出来当历史证人，但不当裁判(表修过它必然带旧账)。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-97}
DDEV=/data/local/tmp/w1152
FIXREPO=kmod/w1152_fixtures
LEGREPO=kmod/w1152_sepd_leg.sh
LEGDEV=$DDEV/w1152_sepd_leg.sh
LEGOUT=$DDEV/leg.out
KO_REPO=kmod/w103_evidence/z6sepdec_v1.ko
KO_DEV=$DDEV/z6sepdec.ko
KO_MD5_WANT=657cefa6380afc34dc00dffc30a1d344
TBLREPO=$FIXREPO/expect.txt
CTL=$DDEV/ctl.txt
CONSOLE=$EV/w1153_shot${SHOT}_console.txt
FULLPASS=	# ★满分不背常数：在[2/7]里从**现行表**算(每行一个 CASEOK ＋ EMPTY_CTRL ＋ RMMOD)
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
LEGARC=$EV/w1153_leg_shot${SHOT}.out	# ★判读只认这一份腿件；REJUDGE 模式把它换成归档件
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕空值) ⇒ 拒跑(例 218)"; exit 3; fi

# ===== 判读(步 7 与 REJUDGE 共用同一段代码：同一把尺，不许"重判"另写一套) =====
judge() {
  CNT=$(grep -a '^COUNTS pass=' "$LEGARC" | tail -1)
  PASSN=$(sed -n 's/^COUNTS pass=<REDACTED> .*/\1/p' <<<"$CNT"); FAILN=$(sed -n 's/.* fail=\([0-9]*\).*/\1/p' <<<"$CNT")
  echo "    腿的计数行=[$CNT] ⇒ pass=<REDACTED> fail=${FAILN:-空}"
  echo "    没过的格：$(grep -a '^CASEOK ' "$LEGARC" | awk '$3==0{print $2}' | tr '\n' ' ')"
  # ★★读法⑦(字节忠实性)＋⑥a/⑥b(分岔)在**同一趟**循环里算：分两趟就是两把尺，一改一漏就不同源。
  # ★★取数一律走 bash 自己的展开，不逐格调 sed/awk/grep：本机是 Windows＋Git Bash，一次 fork 上百毫秒，
  #   十二格 × 每格十次 fork 能把判读段拖成几十秒(专属自测第一次就是"卡住"在这——其实是慢，不是死)。
  declare -A TJ
  while read -r tn trest; do [ -n "$tn" ] && TJ[$tn]="$tn $trest"; done < <(grep -v '^#' "$TBLREPO")
  INSTR=0; DEC=0; DRV=0; MATCH=0; DECL=""; DRVL=""; SP=""; VV=""
  packs() { SP=";"; local tk; for tk in $1; do SP="$SP$tk;"; done; }   # `key=v …` → `;key=v;…`
  tkv()   { local t="${1#*;$2=}"; if [ "$t" = "$1" ]; then VV=""; else VV="${t%%;*}"; fi; }
  # ★★读法⑦的执行：逐格把"内核里那份 staged 字节的 md5/FNV"与 PC 期望表对表；对不上 ⇒ **仪器红**
  #   (字节没忠实送到)，绝不能算"内核解错了"。同一趟里再算⑥a/⑥b 的分岔：
  #     决定性三把(why/n/bad_at)差 ⇒ 真·跨架构不一致(判负，是发现)；
  #     派生两把(max_arg/lenmatch)差 ⇒ 期望表这个**模型**红(不是被测)，交给 w1154 三方对表裁决。
  # ★★取数前必须把行尾的 `want(…)` 摘掉：腿把那一条**开枪时的期望**原样回抄在同一行里，而 `sed '.*[ =]n='`
  #   这种贪婪写法会命中**最后一个** `n=`＝want 里那个。上一版不摘，就是在拿"腿自己 echo 的旧表"比"现行表"——
  #   真读数被架空，模型差还会被数成读数差(＝例 222/231③ 那一族的另一个身位，这次是我自己的判读段)。
  while read -r cl; do
    cl=${cl%% want(*}
    w=($cl); nm=${w[1]:-?}
    row=${TJ[$nm]:-}
    if [ -z "$row" ]; then echo "    [仪器红] $nm 不在现行表里 ⇒ 这一格没被对过，不许算进满分"; INSTR=1; continue; fi
    packs "$cl"; cs="$SP"; packs "$row"; ts="$SP"
    tkv "$cs" ddrc; drc="$VV"; tkv "$cs" in_md5; got="$VV"; tkv "$cs" in_fnv; gotf="$VV"
    tkv "$ts" md5; want="$VV"; tkv "$ts" fnv; wantf="$VV"
    if [ "$drc" != 0 ] || [ -z "$got" ] || [ "$got" != "$want" ] || [ -z "$gotf" ] || [ "$gotf" != "$wantf" ]; then
      echo "    [仪器红] $nm ddrc=${drc:-空} in_md5=${got:-空}/${want:-无} in_fnv=${gotf:-空}/${wantf:-无}"
      INSTR=1
    fi
    d=""; h=""; same=1
    for k in why n bad_at; do
      tkv "$cs" "$k"; dv="$VV"; tkv "$ts" "$k"; tv="$VV"
      { [ -n "$dv" ] && [ "$dv" = "$tv" ]; } || { d="$d $k(内${dv:-空}≠表${tv:-无})"; same=0; }
    done
    for k in max_arg lenmatch; do
      tkv "$cs" "$k"; dv="$VV"; tkv "$ts" "$k"; tv="$VV"
      { [ -n "$dv" ] && [ "$dv" = "$tv" ]; } || { h="$h $k(内${dv:-空}≠表${tv:-无})"; same=0; }
    done
    [ "$same" = 1 ] && MATCH=$((MATCH+1))
    [ -n "$d" ] && { DEC=$((DEC+1)); DECL="$DECL $nm[${d# }]"; }
    [ -n "$h" ] && { DRV=$((DRV+1)); DRVL="$DRVL $nm[${h# }]"; }
  done < <(grep -a '^CASE ' "$LEGARC")
  [ "$INSTR" = 0 ] && echo "    字节忠实性：每格 in_md5/in_fnv 都与 PC 那份同数，且 ddrc=0 ⇒ 送进去的就是它解的"
  ROWS=${ROWS:-$(grep -vc '^#' $TBLREPO | tr -dc '0-9')}
  echo "    分岔计数：决定性三把差的格=$DEC ｜ 只差派生两把的格=$DRV ｜ 六把全等的格=$MATCH/$ROWS"
  [ -n "$DECL" ] && echo "      ⑥a(读数差)：$DECL"
  [ -n "$DRVL" ] && echo "      ⑥b(模型差)：$DRVL ⇒ 那是期望表(仪器)红，跨架构那一格改跑 bash kmod/w1154_run.sh 三方对表定性"
  grep -aq '^IDENTITY=ok$' "$LEGARC" && IDT=1 || IDT=0
  grep -aq 'FAIL=insmod 非 0' "$LEGARC" && INSBAD=1 || INSBAD=0
  grep -aqE '^FAIL=(ko 不在|期望表不在|ctl.txt|件 md5|表 md5)' "$LEGARC" && REFUSE=1 || REFUSE=0
  # 控制格(与期望表无关，重判时照样算数)：空流那一格＋收尾 rmmod 那一格
  grep -aq '^CASEOK EMPTY_CTRL 1$' "$LEGARC" && grep -aq '^CASEOK RMMOD 1$' "$LEGARC" && CTROK=1 || CTROK=0
  if   [ "${READY:-1}" != 1 ]; then V="未测(读法①：腿两行没等到)"
  elif [ "$REFUSE" = 1 ]; then V="未测(读法②：腿的前置闸拒了，什么都没解)"
  elif [ "$INSBAD" = 1 ]; then V="未测(读法③：探针没装进去)"
  elif [ "$IDT" != 1 ]; then V="未测(读法②：件/表两端身份没对上，先修仪器)"
  elif [ "$INSTR" = 1 ]; then V="未测(读法⑦：有格的字节忠实性红，不能算被测)"
  elif [ "$CTROK" != 1 ]; then V="判据不齐(两把控制格没双双绿：EMPTY_CTRL/RMMOD)"
  elif [ "${REJ:-0}" = 1 ]; then
    # ★重判模式：腿自己那份 pass/fail 是**开枪时那张表**的账(表后来被修过就必然带旧账)，
    #   所以满分只认"按现行表逐格重算出来的 MATCH＝ROWS"，同时把旧账原样印出来当历史证人。
    echo "    重判口径：腿自计 pass=<REDACTED> ⇒ 现行表逐格重算 $MATCH/$ROWS"
    if [ "$MATCH" = "$ROWS" ]; then V="判正(REJUDGE＝0 枪重判：$ROWS 格六把读数与现行表全等)"; else V="判据不齐(重判 $MATCH/$ROWS；⑥a=$DEC ⑥b=$DRV)"; fi
  elif [ "${PASSN:-0}" = "$FULLPASS" ] && [ "${FAILN:-1}" = 0 ]; then V="判正"
  elif [ "$DEC" -gt 0 ]; then V="判负(读法⑥a：字节两端一致，而内核的 why/n/bad_at 与宿主期望不同＝跨架构不一致)"
  elif [ "$DRV" -gt 0 ]; then V="模型红(读法⑥b：期望表的派生格与内核读数不符＝仪器红；跨架构那一格由 w1154 三方对表裁决)"
  else V="判据不齐(pass=<REDACTED> fail=$FAILN)"; fi
  echo "  ★SHOT${SHOT}_SEPD=$V ｜ 口径：只答『aarch64 内核读数＝不＝宿主读数』，不答『规则能落地』(那是 #238 的 (2)(3) 段)"
  echo "  ★这一发**没碰** /sys/fs/selinux/，**没改**运行期策略，**没动**出货 ko 字节；探针由腿自己 rmmod。"
}

echo "[1/7] 离线总闸(链内现跑)＋陈旧源码闸"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.h' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

echo "[2/7] 现值(不背历史)：件/腿/表/11 件夹具各自的 md5 与字节数"
[ -s "$KO_REPO" ] || { echo "[x] 探针件不在仓库 ⇒ 不开窗"; exit 1; }
[ -s "$TBLREPO" ] || { echo "[x] 期望表不在(先跑 python kmod/w1152_sepd_fixtures.py) ⇒ 不开窗"; exit 1; }
KOM=$(md5sum $KO_REPO | cut -d' ' -f1); LMM=$(md5sum $LEGREPO | cut -d' ' -f1); TBM=$(md5sum $TBLREPO | cut -d' ' -f1)
echo "  ko=$KOM (登记期望=$KO_MD5_WANT)  腿=$LMM  表=$TBM"
[ "$KOM" = "$KO_MD5_WANT" ] || { echo "[x] 件与登记不符 ⇒ 停(要么重新登记，要么拿错件了)"; exit 1; }
NFIX=$(ls $FIXREPO/*.bin 2>/dev/null | wc -l | tr -dc '0-9')
echo "  夹具 $NFIX 件；表里行 $(grep -vc '^#' $TBLREPO) 条"
[ "$NFIX" = 11 ] || { echo "[x] 夹具不是 11 件 ⇒ 停(表与件不同源了)"; exit 1; }
# ★表里点名的每件夹具都要在，且 md5/字节都要等于表 ⇒ 一台机的两个数对不上就别开窗
MISS=0
while read -r line; do
  case "$line" in \#*) continue ;; esac
  fn=$(printf '%s\n' "$line" | sed -n 's/.* file=\([^ ]*\).*/\1/p')
  wm=$(printf '%s\n' "$line" | sed -n 's/.* md5=\([^ ]*\).*/\1/p')
  wb=$(printf '%s\n' "$line" | sed -n 's/.* bytes=\([^ ]*\).*/\1/p')
  [ -s "$FIXREPO/$fn" ] || { echo "  [x] 表点名要 $fn 但件不在"; MISS=1; continue; }
  gm=$(md5sum "$FIXREPO/$fn" | cut -d' ' -f1); gb=$(wc -c <"$FIXREPO/$fn" | tr -dc '0-9')
  [ "$gm" = "$wm" ] && [ "$gb" = "$wb" ] || { echo "  [x] $fn 本机现读 $gb/$gm ≠ 表里 $wb/$wm"; MISS=1; }
done < "$TBLREPO"
[ "$MISS" = 0 ] || { echo "[x] 夹具与期望表对不上 ⇒ 不开窗(重跑生成器，别改表)"; exit 1; }
echo "  夹具×表 全部同数(11 件、$(grep -vc '^#' $TBLREPO) 行)"
# ★★★满分**从现行表算**：表里每行一个 CASEOK，再加 EMPTY_CTRL 与 RMMOD 两格。
#   上一版这里钉死 `FULLPASS=<REDACTED> 12 行 ⇒ 真满分是 **14**：全对那一发会被我自己的常数
#   判成"判据不齐"(＝例 231③"错的正向要求比缺要求更坏")。常数会随夹具漂移，算出来的不会。
ROWS=$(grep -vc '^#' $TBLREPO | tr -dc '0-9'); FULLPASS=<REDACTED> + 2))
echo "  ★满分＝表行($ROWS)＋2(EMPTY_CTRL/RMMOD)＝$FULLPASS(由现行表算，不背历史)"
[ "$ROWS" = 12 ] || echo "  [!] 表行不是 12 ⇒ 夹具与表可能不同源了(仍按 $ROWS 算满分，但先核对生成器)"

if [ -n "${REJUDGE:-}" ]; then
  echo "[R] ★REJUDGE 模式(**0 枪**，全程不碰 adb)：拿归档读数＋**现行**期望表重判这一发"
  # ★为什么要这一支：期望表是我自己的模型，模型修好了不该再烧一发设备窗才能给它定性；
  #   但重判必须走**同一个 judge()**(否则"重判"就成了另写一把恒绿的尺)。
  [ -s "$REJUDGE" ] || { echo "[x] 归档腿件不在或为空 ⇒ 未测(不算重判过)"; exit 1; }
  LEGARC=$REJUDGE; REJ=1
  RJ_B=$(grep -acF 'BEGIN v1152' "$LEGARC" 2>/dev/null); RJ_E=$(grep -acF 'END up=' "$LEGARC" 2>/dev/null)
  READY=0; [ "${RJ_B:-0}" -ge 1 ] && [ "${RJ_E:-0}" -ge 1 ] && READY=1
  echo "  归档件里 BEGIN=$RJ_B END=$RJ_E ⇒ READY=$READY(读法①在归档件上同样算数)"
  judge
  echo "  ★本支没开窗、没派腿、没 reboot。"
  exit 0
fi

echo "[3/7] 设备侧只读基线＋清上一 boot 的同名残留(派腿前必须复证已删)"
# ★命令串放单引号变量里：写进 A "…$(…)" 会在**本机**展开(例 230①：印出过台式机的 uptime)。
BASE='getenforce; echo KERNELSU=$(grep -c "^kernelsu " /proc/modules 2>/dev/null); echo BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); echo UP=$(cut -d" " -f1 /proc/uptime 2>/dev/null); echo POLLOAD=$(ls -d /proc/w1151_in 2>&1 | head -1)'
B0=$(A "$BASE"); echo "$B0" | sed 's/^/    /'
grep -q '^BOOT=[0-9a-f-]\{8,\}' <<<"$B0" || { echo "[x] boot_id 没报回来(多半又是本机展开) ⇒ 不开窗"; exit 1; }
grep -q '^UP=[0-9]\+' <<<"$B0" || { echo "[x] 设备 uptime 读数空 ⇒ 不开窗"; exit 1; }
grep -q 'No such file' <<<"$B0" || { echo "[x] /proc/w1151_in 现在就存在(上一 boot 的探针没退干净？) ⇒ 不开窗"; exit 1; }
A "rm -rf $DDEV" >/dev/null
GONE=$(A "ls -d $DDEV 2>&1"); echo "  复证已删：$GONE"
case "$GONE" in *"No such file"*) : ;; *) echo "[x] 残留删不掉 ⇒ **不开窗**(派了就是拿陈件当读数)"; exit 1 ;; esac

echo "[4/7] 铺件＋六把闸(x 位／plain s0／腿与件两端 md5／表两端 md5／每件夹具两端 md5／设备 mksh sh -n)"
A "mkdir -p $DDEV/fixtures" >/dev/null
MSYS_NO_PATHCONV=1 adb push "$KO_REPO" $KO_DEV           2>&1 | tail -1 | sed 's/^/  push ko : /'
MSYS_NO_PATHCONV=1 adb push "$LEGREPO" $LEGDEV           2>&1 | tail -1 | sed 's/^/  push leg: /'
MSYS_NO_PATHCONV=1 adb push "$FIXREPO/." $DDEV/fixtures/ 2>&1 | tail -1 | sed 's/^/  push fix: /'
# ★期望表要**单独铺到腿读的那个路径**上：`push 目录/.` 会把 expect.txt 一起带进 fixtures/，
#   而腿读的是 $P/expect.txt ⇒ 第一次 dry run 就是这把闸(表两端必须同一份)把它自己拦住了，0 枪。
MSYS_NO_PATHCONV=1 adb push "$TBLREPO" $DDEV/expect.txt  2>&1 | tail -1 | sed 's/^/  push tbl: /'
A "printf 'KO=%s\nKO_MD5=%s\nTBL_MD5=%s\nOUT=%s\n' $KO_DEV $KOM $TBM $LEGOUT > $CTL; chmod 666 $CTL $KO_DEV $DDEV/expect.txt $DDEV/fixtures/*; chmod 755 $LEGDEV; cat $CTL" | sed 's/^/  ctl: /'
# ★腿要 755：§6.474 那一手就是 push 落 0666 把 uid 0 挡在 execve 外面(rc=126)。
P=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}'); LB=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
LM2=$(A "md5sum $LEGDEV 2>/dev/null" | cut -d' ' -f1); KM2=$(A "md5sum $KO_DEV 2>/dev/null" | cut -d' ' -f1)
TM2=$(A "md5sum $DDEV/expect.txt 2>/dev/null" | cut -d' ' -f1)
S=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
DEVFIX=$(A 'cd /data/local/tmp/w1152/fixtures 2>/dev/null && md5sum *.bin 2>/dev/null | tr "\n" ";"')
echo "  腿 权限=$P 标签=$LB 设备md5=$LM2 本机md5=$LMM $S"
echo "  ko 设备md5=$KM2 本机=$KOM ｜ 表 设备md5=$TM2 本机=$TBM"
echo "  设备上夹具：$DEVFIX" | cut -c1-300
[ "${P:3:1}" = x ] || { echo "[x] 腿没 x 位 ⇒ 不开窗(§6.474 那种空枪)"; exit 1; }
case "$LB" in *:s0) : ;; *) echo "[x] 腿标签不是 plain s0 ⇒ 不开窗(#114)"; exit 1 ;; esac
[ "$LM2" = "$LMM" ] || { echo "[x] 设备上不是本机这支腿 ⇒ 不开窗"; exit 1; }
[ "$KM2" = "$KOM" ] || { echo "[x] 设备上不是本机这枚探针 ⇒ 不开窗"; exit 1; }
[ "$TM2" = "$TBM" ] || { echo "[x] 设备上不是本机那份期望表 ⇒ 不开窗(表就是判据，两端必须同一份)" ; exit 1; }
grep -q SHN=OK <<<"$S" || { echo "[x] 腿没过设备语法闸 ⇒ 不开窗"; exit 1; }
# ★每件夹具都要在设备上对上号：表里点名的 unique 文件名逐个比(设备侧一次 md5sum 全拿)
M2=0
for fn in $(sed -n 's/.* file=\([^ ]*\).*/\1/p' $TBLREPO | sort -u); do
  wm=$(grep -m1 " file=$fn " $TBLREPO | sed -n 's/.* md5=\([^ ]*\).*/\1/p')
  grep -q "$fn" <<<"$DEVFIX" || { echo "  [x] 设备上没看到 $fn"; M2=1; }
  gm=$(tr ';' '\n' <<<"$DEVFIX" | grep " $fn\$" | cut -d' ' -f1)
  [ -n "$gm" ] && [ "$gm" = "$wm" ] || { echo "  [x] $fn 设备=$gm 本机=$wm"; M2=1; }
done
[ "$M2" = 0 ] || { echo "[x] 夹具送到设备后与本机不一致(push 没忠实到位) ⇒ 不开窗"; exit 1; }
A "ls -l $LEGOUT 2>&1" | grep -q 'No such file' || { echo "[x] 腿的 out 件已存在且删不掉 ⇒ 不开窗"; exit 1; }
echo "  六把闸全过。"

if [ "${I_KNOW:-}" != 1 ]; then
  echo "[5/7] ★没给 I_KNOW=1 ⇒ 到此为止(**0 枪**)。第 6~7 步只开窗派腿，不改策略，但仍要现场点头才烧一发。"
  A "rm -rf $DDEV" >/dev/null; echo "      已撤场：$(A "ls -d $DDEV 2>&1")"
  exit 0
fi

echo "[6/7] ★开窗(1 枪＝punch)＋派这一发唯一的那条腿"
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LMM" LEG1ONLY=1 I_KNOW=1 bash kmod/go.sh > $EV/w1153_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -3 $EV/w1153_shot${SHOT}_go.log | sed 's/^/  go: /'
READY=0; ROUND=0
for i in $(seq 1 100); do ROUND=$i
  B=$(A "grep -acF 'BEGIN v1152' $LEGOUT 2>/dev/null" | tr -dc '0-9')
  E=$(A "grep -acF 'END up=' $LEGOUT 2>/dev/null" | tr -dc '0-9')
  if [ "${B:-0}" -ge 1 ] && [ "${E:-0}" -ge 1 ]; then READY=1; echo "  腿跑完(第 $i 轮：BEGIN v1152 与 END 齐)"; break; fi
  [ "${B:-0}" = 0 ] && [ "${E:-0}" -ge 1 ] && echo "  [!] 第 $i 轮：有 END 没 BEGIN v1152 ⇒ 陈件，继续等真这一份"
  sleep 3
done
[ "$READY" = 1 ] || echo "  [!] 等满 $ROUND 轮没等到两行 ⇒ **未测**(读法①)"
A "cat $LEGOUT 2>/dev/null" > $EV/w1153_leg_shot${SHOT}.out 2>&1
B1=$(A "cat /proc/sys/kernel/random/boot_id 2>&1")
LB0=$(sed -n 's/^BEGIN v1152 up=[0-9]* boot_id=\([0-9a-f-]*\).*/\1/p' $EV/w1153_leg_shot${SHOT}.out | head -1)
echo "  boot 身份：腿自印=$LB0 go.sh 返回后读回=$B1 $( [ -n "$LB0" ] && [ "$LB0" = "$B1" ] && echo '⇒ 相等＝这条腿跑在我们正在读的这扇窗里' || echo '**不相等⇒这一格未测**' )"
MSYS_NO_PATHCONV=1 adb pull $DDEV $EV/w1153_records_shot${SHOT} 2>&1 | tail -1 | sed 's/^/  pull: /'
grep -aE '^(BEGIN v1152|LEG |IDENTITY|SLOTGRP|GROUP |CASE |CASEOK |EMPTY_CTRL|RMMOD|COUNTS|END )|FAIL=' $EV/w1153_leg_shot${SHOT}.out | cut -c1-320 | sed 's/^/    /'

echo "[7/7] 判读＋收尾 reboot 复核"
judge   # ★与 REJUDGE 模式同一个函数：重判不另写尺子


echo "  收尾：reboot 并复核基线(就绪只认 adb get-state=device ＋ getenforce 是可读的那两个值)"
adb reboot >/dev/null 2>&1; sleep 45
UP2=0
for i in $(seq 1 40); do
  ST=$(adb get-state 2>&1 | tr -d '\r' | tail -1)
  EN=$(A "getenforce" | tr -d '[:space:]')
  if [ "$ST" = device ] && { [ "$EN" = Enforcing ] || [ "$EN" = Permissive ]; }; then UP2=1; echo "  设备回来了(第 $i 轮，state=$ST getenforce=$EN)"; break; fi
  sleep 6
done
[ "$UP2" = 1 ] || echo "  [!!] 等满 40 轮仍未可读 ⇒ 记**未测**，人工接管(别按第二下 reboot)"
BASE_POST='getenforce; echo KERNELSU=$(grep -c "^kernelsu " /proc/modules 2>/dev/null); echo Z6=$(grep -c "^z6sepdec " /proc/modules 2>/dev/null); echo BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); echo W1152=$(ls -d /data/local/tmp/w1152 2>&1 | head -1)'
echo "    重启后：$(A "$BASE_POST" | tr '\n' ' ')"
A "rm -rf $DDEV" >/dev/null; echo "    撤场复证：$(A "ls -d $DDEV 2>&1")"
echo "CONSOLE 记：本件由 tee 生成 $CONSOLE"
