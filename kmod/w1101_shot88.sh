#!/bin/bash
# w1101_shot88.sh —— 第 88 发＝#226 两枪串联的**第二枪**：在**死后的第一个 boot**里，第一条 root 腿只读 pstore。
#   这一发买的东西(§6.514)：把 (a)"我们那类死没走 `panic()`(hard hang / watchdog→PMIC ⇒ 没人往 pstore 写)"
#   与 (b)"走了 `panic()`，但记录被中间那次 warm reboot 的 console 注册 zap 掉"分开。
#   第 86 发读的是"死 ⟶ 两次软重启 ⟶ 才读"，所以那个 `PS_FILES=0` 只配写"未证"；**这一发把"读"搬到死亡紧邻的那个 boot**。
#   ★读法(两种结果都算数)：
#     ①出现 `dmesg-ramoops-0`/`console-ramoops-0` ⇒ **第一次拿到那次死的现场**(fault PC／回溯)，"为什么崩"这条线当场有硬料；
#     ②`PS_FILES=0` ⇒ 能说"死后的第一个 boot 里也没有可读记录"⇒ 强烈指向 (a)，但对 (b) 里"console 那一区被本 boot 注册时抹"
#       仍未排除(它只能由**区布局**来判断，所以链侧额外现读 DT 的 `ramoops` 节点与 `/proc/cmdline`)；
#     ③腿的 `DMESG_hits_noself`(例 217)＝剔掉我自己之后的真命中——只认这个数，不认旁边那个原始命中数。
#   ★四把"这确实是死后第一个 boot"的硬闸(缺一不发)：标记件在(＝真的串联)／`hist` 与标记件**逐字相同**(中间没人软重启)／
#     `ro.boot.bootreason` 不含 `shell`／本 boot `kernelsu=0`(枪还没花)。另外 `up` 超 2400 秒只**警告**不拒(机器慢不是罪)。
#   ★用 go.sh 的两把开关：`NOREBOOT=1`(§6.515 新增：不软重启就在当前 boot 开窗——用原来那条无条件 reboot 就等于先把证据抹了)
#     ＋`LEG1ONLY=1`(派完腿就跳过第 4~7 步；那几步与这一格无关，且会把 /data/adb 与 bind su 的形状搅进来＝记**未测**)。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-88}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
#   ★同 w1100：这把闸要测的是"**有没有定义**"而不是"非空"——空值照样让 msys 关掉路径转换(11-02 第 87 发两次 0 消耗的成因)。
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕是空值) ⇒ 拒跑：空值会让 msys 关掉路径转换，链里的 python 夹具会拿到没转换的 /tmp 路径而假红"; exit 3; fi
MK=$EV/w1100_death_marker.txt

echo "[1/5] ★串联身份闸：这一 boot 是不是"死后的第一个""
[ -f "$MK" ] || { echo "[x] 没有 $MK ⇒ 第 87 发没跑(或标记件丢了)⇒ 不开这一枪：孤零零开一扇窗读 pstore 又是第 86 发那个形状"; exit 1; }
grep -q '^MARK_HIST=' "$MK" || { echo "[x] 标记件没有 MARK_HIST ⇒ 拒"; exit 1; }
MKS=$(sed -n 's/^MARK_KERNEL_START=//p' "$MK"); MKH=$(sed -n 's/^MARK_HIST=//p' "$MK")
MPLEG=$(sed -n 's/^MARK_PLEG=//p' "$MK"); MPLEGOUT=$(sed -n 's/^MARK_PLEGOUT=//p' "$MK"); MPLEGMD5=$(sed -n 's/^MARK_PLEG_MD5=//p' "$MK")
echo "  标记件：kernel起点≈$MKS hist=[$MKH] 腿=$MPLEG 本机md5=$MPLEGMD5"
LM=$(md5sum kmod/w1098_pstore_leg.sh | cut -d' ' -f1)
echo "  本机腿现算 md5=$LM  标记件登记=$MPLEGMD5"
[ "$LM" = "$MPLEGMD5" ] || { echo "[x] 腿在第 87 发之后被我改过 ⇒ 那一发铺的形状与这支不是同一件，拒(要么重铺要么承认换了被测面)"; exit 1; }
HIST_NOW=$(A "getprop persist.sys.boot.reason.history")
#   ★这条闸原来写成"hist 整串逐字相等"，**拦对形状却拦错成因**(11-02 第 88 发实测)：
#     `persist.sys.boot.reason.history` 在**同一个 boot 内是逐渐拼齐的**——标记件写于 up=175(那时只有 `cold,charger,…` 一条)，
#     到 up≈270 已变成三条(旧的两轮也回来了) ⇒ "整串恒等"在这个属性上根本不成立，会把合法的"死后第一个 boot"判成"重启过"。
#     真正不随时间变的量是：**最新那一条**＋**本次 kernel 的起点**。所以判"没重启"要拿这两把尺：
#       ①最新条目必须＝标记件当时的最新条目(旧条目被补进来不影响它)；
#       ②`date − up` 必须≈标记件里的 kernel 起点(容差 300 秒；真重启会差几分钟到几小时，不会只差几秒)。
#   ★★上一条修正本身又踩一次(11-02 第 88 发实测)：`persist.sys.boot.reason.history` 的条目之间是**换行**不是空格，
#     所以 `cut -d' ' -f1` 等于没切⇒ 又把合法 boot 判成"重启过"(第二次 0 消耗)。取"最新那条"必须**先把换行归一成空格**再取第一个 token。
firsttok() { printf '%s' "$1" | tr '\n\r' '  ' | tr -s ' ' | cut -d' ' -f1; }
MKNOW=$(firsttok "$HIST_NOW")
MKNEW=$(firsttok "$MKH")
[ "$MKNOW" = "$MKNEW" ] || { echo "[x] boot.reason.history 的**最新条目**变了(标记件 [$MKNEW] → 现读 [$MKNOW]) ⇒ 中间确实又复位/重启过一次，这一 boot 不是死后第一个，读了也白读"; echo "      标记件整串=[$MKH]"; echo "      现读整串=[$HIST_NOW]"; exit 1; }
BR=$(A "getprop ro.boot.bootreason"); UP=$(A "cut -d' ' -f1 /proc/uptime"); MOD0=$(A "grep -c '^kernelsu ' /proc/modules")
case "${UP%.*}" in ''|*[!0-9]*) echo "[x] 读不到当前 boot 的 up(设备没在线？)⇒ 拒：这一发的每一步都依赖"确实是刚才那次复位回来的 boot""; exit 1 ;; esac
echo "  现读：bootreason=[$BR] up=$UP kernelsu=$MOD0 enf=$(A getenforce)"
case "$BR" in *shell*) echo "[x] 当前 boot 的 bootreason 带 shell ⇒ 这是**软重启**起来的 boot，不是那次复位自己回来的，拒"; exit 1 ;; esac
[ "$MOD0" = 0 ] || { echo "[x] 当前 boot 已经有 kernelsu 在 ⇒ 这一 boot 的枪已花过(脏 boot)，拒"; exit 1; }
NOW=$(A "date +%s"); START=$((NOW - ${UP%.*}))
DIFF=$((START - MKS)); [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
echo "  本次 kernel 起点≈$START(标记件给 $MKS，差 $((START - MKS)) 秒)"
case "$NOW" in ''|*[!0-9]*) echo "[x] 设备钟读不成数字(=$NOW)⇒ 没法判'同一个 boot'，拒"; exit 1 ;; esac
#   ★容差 300 秒：同一个 boot 里 `date − up` 会因为 NTP 步进差出几十秒(本机实测一晚 +31→+57 秒)，
#     而**真重启**会差出几分钟以上(冷启延迟就 100 多秒)⇒ 300 秒这把尺分得开"同一个 boot"与"又重启了一次"。
[ "$DIFF" -le 300 ] || { echo "[x] kernel 起点与标记件差 $DIFF 秒(>300)⇒ 这已经不是那次复位直接回来的那个 boot 了，读了也白读"; exit 1; }
echo "  ★两把尺同意：最新历史条目没变＋kernel 起点差 $DIFF 秒 ⇒ 这就是**死后的第一个 boot**"
if [ "${UP%.*}" -gt 2400 ]; then echo "  [!] up=$UP 已经大于 2400 秒 ⇒ 记录可能被本 boot 自己的 console 写覆盖的风险升高(只警告，不拒)"; fi

echo "[2/5] 只读腿四把闸(设备上那一份还得是刚才那份)"
PERM=$(A "ls -l $MPLEG 2>/dev/null" | awk 'NR==1{print $1}'); LBL=$(A "ls -Zd $MPLEG 2>/dev/null" | awk 'NR==1{print $1}')
DEVMD5=$(A "md5sum $MPLEG 2>/dev/null" | cut -d' ' -f1)
#   ★同上：这条串以 `/system/bin/sh` 开头，必须显式带 MSYS_NO_PATHCONV=1，否则 msys 转换路径 ⇒ 永远 SHN=BAD(第 87 发实测)。
SHN=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $MPLEG >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
echo "  权限=$PERM 标签=$LBL 设备md5=$DEVMD5 $SHN"
[ "${PERM:3:1}" = x ] || { echo "[x] 腿没 x 位(复位后权限可能被改)⇒ 重铺一次再跑本链"; exit 1; }
case "$LBL" in *:s0) : ;; *) echo "[x] 标签不是 plain s0 ⇒ 不开枪(带类别挡 execute＝#114)"; exit 1 ;; esac
[ "$DEVMD5" = "$LM" ] || { echo "[x] 设备上不是本机这支腿 ⇒ 拒(§6.155 旧件会静默换形状)"; exit 1; }
grep -q SHN=OK <<<"$SHN" || { echo "[x] 腿没过设备语法闸 ⇒ 不开枪"; exit 1; }

echo "[3/5] 开窗：NOREBOOT=1(就在这一 boot，不软重启)＋LEG1ONLY=1(派完腿就停)＋1 枪"
echo "  开枪前 pstore 面先看一眼(shell 侧多半读不到，读不到本身也是形状)：$(A "ls /sys/fs/pstore 2>&1" | tr '\n' '|' | cut -c1-160)"
NOREBOOT=1 LEG1ONLY=1 LEG1=$MPLEG LEG1OUT=$MPLEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1101_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO"; tail -4 $EV/w1101_shot${SHOT}_go.log | sed 's/^/  go: /'
[ "$GO" = 0 ] || echo "  [!] go.sh rc=$GO ⇒ 先看日志再判(这一发的窗口可能因为不是新 boot 而起不来；**别在没窗的情况下猜**)"

echo "[4/5] 收 pstore＋链侧现读区布局(判 (b) 那支要用)"
A "cat $MPLEGOUT 2>/dev/null" > $EV/w1098_pstore_shot${SHOT}.out 2>&1
rm -rf $EV/w1098_records_shot${SHOT} 2>/dev/null
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w1098_pstore $EV/w1098_records_shot${SHOT} 2>&1 | tail -1
echo "  抄回来的文件数=$(ls $EV/w1098_records_shot${SHOT} 2>/dev/null | wc -l) 明细："
ls -l $EV/w1098_records_shot${SHOT} 2>/dev/null | tail -12 | sed 's/^/    /'
echo "  ---- 腿的原始读数(★只认 hits_noself；派生判断留给主机侧)----"
grep -aE 'BEGIN|ARM=|BOOTREASON|BOOT_HIST|MOUNT_|CFG_rc|CFG_PSTORE|DMESG_|NEG_CTRL|FILE |PS_FILES|ENFORCE_NOW|MODULES_|\[x\]|END up=' \
  $EV/w1098_pstore_shot${SHOT}.out | cut -c1-300 | sed 's/^/    /'
echo "  ---- 链侧：ramoops 的区布局与命令行(这是 (b) 那支唯一能离线判的东西)----"
echo "    DT 目录=$(A "ls /proc/device-tree/reserved-memory/ 2>&1" | tr '\n' '|' | cut -c1-200)"
for n in reg size console-size record-size pmsg-size ftrace-size mem-type; do
    echo "    ramoops/$n = $(A "od -An -tx1 /proc/device-tree/reserved-memory/ramoops/$n 2>&1" | tr -s ' ' | tr '\n' '|' | cut -c1-90)"
done
echo "    cmdline=$(A "cat /proc/cmdline" | tr ' ' '\n' | grep -aiE 'ramoops|pstore|mem' | tr '\n' '|' | cut -c1-240)"
echo "    pstore 挂载=$(A "grep -a ' pstore ' /proc/mounts 2>&1" | cut -c1-200)"
echo "    抄回来的记录 md5："; md5sum $EV/w1098_records_shot${SHOT}/*ramoops* 2>/dev/null | sed 's/^/      /' || echo "      (没有 ramoops 件可算 md5＝这一格是空面)"

echo "[5/5] 关窗(证据已经在本机上了，这时候才可以软重启把机器收回基线)"
A "svc power stayon false" >/dev/null
adb reboot; adb wait-for-device; sleep 20
echo "  基线：getenforce=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules")"
rm -f "$MK" 2>/dev/null; echo "  标记件已删(用过了；留着会让下一次误当"还在串联"里)读回=$([ -f "$MK" ] && echo 还在 || echo 已删)"
echo "SHOT${SHOT}_DONE 证件：$EV/w1101_shot${SHOT}_go.log $EV/w1098_pstore_shot${SHOT}.out $EV/w1098_records_shot${SHOT}/ $EV/w1100_death_marker.txt(已删)"
