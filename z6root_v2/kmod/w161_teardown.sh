#!/bin/bash
# w161_teardown.sh —— #61 的收尾：root 侧先 umount 成功再删源 → 杀看门狗 → 清载荷 → reboot → 复核。
#   规矩：临时 root 不留过夜。任何一格没证到都不构成"先把窗口留着"的理由。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
fire() { A "am force-stop com.suw.manager" >/dev/null; sleep 1
         # ★`-f 0x4000000`(CLEAR_TOP)是第 24 发抓出来的必需项：收尾时 suw 已经跑了一整窗，
         #   `am start` 会走 "delivered to currently running top-most instance" 这条支路，
         #   而本机的 MainActivity 不是 singleTop ⇒ 那条路**不把 extras 交给 onNewIntent**，
         #   `--es auto ksuarm` 被整个丢掉(实测：报告里只多出 `arm=0 cmd=[@list]` 的 UI 刷新行，
         #   sushd.log 零新增)。加上 CLEAR_TOP 才会真起新实例并带上 extra。
         A "am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }

echo "=== T1) 杀看门狗(它每 0.4s 抢一次 pidof，别留着) ==="
A 'for p in $(pgrep -f w161_fdwatch.sh 2>/dev/null); do kill -9 "$p"; done; echo KILLED'
echo "=== T2) root 侧卸载：先 umount 成功再删源 ==="
adb push kmod/w135_off.sh /data/local/tmp/w135_off.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w135_off.sh; rm -f /data/local/tmp/w135_off.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_off.sh" 8
WAITFOR /data/local/tmp/w135_off.out 40 "===== DONE"
A "grep -aE 'MOUNT_LEFT|SU_GONE|RM_DIRS_OK' /data/local/tmp/w135_off.out | cut -c1-110" | sed 's/^/    /'
echo "=== T2.5) 趁 root 还活着清 /data/adb 脚印(shell 删不动，stage 被打断时也不会替你清) ==="
adb push kmod/w165b_adb_clean.sh /data/local/tmp/w165b_adb_clean.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w165b_adb_clean.sh; rm -f /data/local/tmp/w165b_adb_clean.out" >/dev/null
fire "@sushd:/data/local/tmp/w165b_adb_clean.sh" 8
ADB_CLEAN_OK=0
if WAITFOR /data/local/tmp/w165b_adb_clean.out 20 "===== DONE"; then ADB_CLEAN_OK=1; fi
A "cat /data/local/tmp/w165b_adb_clean.out" | cut -c1-165 | sed 's/^/    /'
echo "=== T2.5b) ★B 入口(免 suw)下上面两条 @sushd 腿必「等满」⇒ 名单文件会偷换下一发的形状(§6.366／#153) ==="
#   「等满」不等于"没事发生"：/data/adb/ksu/.allowlist 若还留着，**下一发 insmod 时 ko 会把它读进活表**
#   ⇒ 形状被上一发远程设定，比普通同名残留更硬。旧版这里彻底静默(第 30/31 发都是我事后手动读回才发现)。
#   ★默认不自动敲 Termux(要在前台起 app、走输入法)；给 CLOSEFALLBACK=1 才走替代腿。没给也**必须把风险打在明面**。
if [ "$ADB_CLEAN_OK" = 1 ]; then
    echo "  root 腿已落地 ⇒ 不需要替代腿"
else
    if [ "${CLOSEFALLBACK:-0}" = 1 ]; then
        echo "  CLOSEFALLBACK=1 ⇒ 走 root 侧替代腿(格 N1 形状里＝Termux 那个 su 壳)"
        adb push kmod/w450_close.sh /data/local/tmp/w450_close.sh >/dev/null 2>&1
        CL_L=$(md5sum kmod/w450_close.sh | cut -c1-32); CL_R=$(A "md5sum /data/local/tmp/w450_close.sh" | cut -c1-32)
        echo "  替代腿两端 md5：本机=$CL_L 设备=$CL_R"
        if [ "$CL_L" != "$CL_R" ]; then
            echo "  [!] 设备上 w450_close.sh 不是本机这份 ⇒ **一个键都不敲**(带 rm 的远端件没核实就不许跑)"
        else
            A "chmod 755 /data/local/tmp/w450_close.sh; rm -f /sdcard/w450_close.txt" >/dev/null
            #   ★两条敲键都短(`su` 与 `sh <路径>`)：长命令里的重定向号会被输入法吃掉(§6.366①)，所以 `exec >` 写在脚本内部
            A "am start -n com.termux/.app.TermuxActivity" >/dev/null; sleep 5
            A "input text su" >/dev/null; A "input keyevent 66" >/dev/null; sleep 3
            A "input text 'sh%s/data/local/tmp/w450_close.sh'" >/dev/null; A "input keyevent 66" >/dev/null; sleep 12
            if [ -n "$(A "grep -a 'rm_allow_rc=0' /sdcard/w450_close.txt 2>/dev/null")" ]; then
                A "cat /sdcard/w450_close.txt" | cut -c1-165 | sed 's/^/    /'
                echo "  [OK] 替代腿落地：名单文件已删＋读回(整段读数在上面)"
            else
                echo "  [!] 替代腿没读到 rm_allow_rc=0 ⇒ **名单文件是否删掉＝未知**：下一发开窗前必须手删并读回，别直接开窗"
            fi
        fi
    else
        echo "  [!] 没给 CLOSEFALLBACK 且 @sushd 腿没落地 ⇒ **名单文件是否还在＝未知**(shell 读不到 /data/adb)"
        echo "      下一发开窗前必须处理：要么在带 root 的窗口里删掉并读回，要么这轮就用 CLOSEFALLBACK=1 重跑收尾(§6.366／#153)"
    fi
fi
echo "=== T2.6) ★ROOTPROBE=1 才跑：#124 那两笔"只有 root 窗才做得到"的读数(补档案，不卡结论，§6.329) ==="
RP_TAG=$(date +%m%d-%H%M)          # ★名字只算一次(glob 多命中/跨分钟错位都记过)
RP_OUT=kmod/w103_evidence/w407_rootprobe_$RP_TAG.txt
if [ "${ROOTPROBE:-0}" = 1 ]; then
    MSYS_NO_PATHCONV=1 adb push kmod/w407_rootprobe.sh /data/local/tmp/w407_rootprobe.sh >/dev/null 2>&1
    A "chmod 755 /data/local/tmp/w407_rootprobe.sh; rm -f /data/local/tmp/w407_rootprobe.out" >/dev/null
    LM=$(md5sum kmod/w407_rootprobe.sh | cut -c1-32); RM=$(A "md5sum /data/local/tmp/w407_rootprobe.sh" | cut -c1-32)
    if [ "$LM" != "$RM" ]; then
        echo "  [x] 设备上 w407_rootprobe.sh 不是本机这份(设备=$RM 本机=$LM) ⇒ **不发这一腿**(它带 rm，不能拿没核实的远端件跑)；这一格记\"没测到\""
    else
        echo "  ROOTPROBE=$ROOTPROBE ⇒ 两端 md5=$LM 推送件实况=$(A "ls -l /data/local/tmp/w407_rootprobe.sh | tr -s ' ' | cut -c1-60")"
        fire "@sushd:/data/local/tmp/w407_rootprobe.sh" 8
        if WAITFOR /data/local/tmp/w407_rootprobe.out 20 "=== DONE ==="; then
            A "cat /data/local/tmp/w407_rootprobe.out" > "$RP_OUT"
            echo "  落盘=$RP_OUT 行数=$(wc -l < "$RP_OUT")"
            A "grep -aE 'ROOTPROBE up=|★总行数|不在表里|com.suw.manager|删之后|uid=10342' /data/local/tmp/w407_rootprobe.out | cut -c1-160" | sed 's/^/    /'
        else
            echo "  [x] 探针没到 DONE ⇒ 这一格记\"没测到\"(root 通道可能已经没了)，不许拿空件当读数"
        fi
    fi
else
    echo "  未给 ROOTPROBE ⇒ 跳过＝收尾形状逐字不变(交付链行为不受影响)；这一格的开关在环境变量上，默认关(§6.329)"
fi
echo "=== T2.7) ★CFIFIX 原件「ksu_slots.dump.txt」：**删之前**先 pull(第 24 发的欠账：我删前没 pull＝例 113 那一族) ==="
#   三条规矩写死在里面：①先探 shell 读不读得动(别猜，也别把"文件在"当成"能取走")；②pull 完**读回本机**字节数与计数
#   (Git Bash 会把 adb 的远端路径重写并谎报成功)；③失败只登记、**绝不阻断收尾**(窗口必须收，证据次要)。
SL_TAG=$(date +%m%d-%H%M)
SL_OUT=kmod/w103_evidence/w412_ksu_slots_$SL_TAG.txt
echo "  原件实况=$(A "ls -l /data/local/tmp/ksu_slots.dump.txt 2>&1 | tr -s ' ' | cut -c1-90")"
SL_RD=$(A "head -c 16 /data/local/tmp/ksu_slots.dump.txt 2>/dev/null | wc -c" | tr -dc '0-9')
echo "  shell 能读的字节数(探 16 头)=[${SL_RD:-读不到}] 设备侧 CFIFIX 行数=$(A "grep -ac CFIFIX /data/local/tmp/ksu_slots.dump.txt 2>/dev/null" | tr -dc '0-9')"
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/ksu_slots.dump.txt "$SL_OUT" >/dev/null 2>&1
SL_LM=""; SL_RM=""
if [ -f "$SL_OUT" ] && [ -s "$SL_OUT" ]; then
    SL_LM=$(md5sum "$SL_OUT" | cut -c1-32); SL_RM=$(A "md5sum /data/local/tmp/ksu_slots.dump.txt" | cut -c1-32)
    echo "  ★落盘=$SL_OUT 字节=$(wc -c < "$SL_OUT") CFIFIX行=$(grep -ac CFIFIX "$SL_OUT") 桩已写回=$(grep -ac '桩已写回' "$SL_OUT") 不用改=$(grep -ac '不用改' "$SL_OUT")"
    echo "  ★两端 md5：本机=$SL_LM 设备=$SL_RM"
    if [ "$SL_LM" != "$SL_RM" ]; then
        echo "  [!] 两端 md5 不符 ⇒ 本机这份**不许当读数**(Git Bash 重写远端路径并谎报成功那一族)，这一格改记\"没测到\""
        rm -f "$SL_OUT"
    fi
else
    [ -f "$SL_OUT" ] && rm -f "$SL_OUT"   # ★0 字节也算失败：不许留空存证件(例 109/自测③那条牙)
    echo "  [x] 没 pull 到(权限/文件不在/Git Bash 谎报) ⇒ 这格记\"没测到\"，收尾照走；stage 转录里那两处「已触发 rc=0」＋6 条「桩已写回」仍是低一级的证人"
fi
echo "=== T2.8) 交付形状自己的诊断 dump：**先 pull＋gzip 存证**，再让 T3 删设备侧(§6.343：这批以前跨 boot 留着＝同名造假) ==="
#   与 T2.7 同三条规矩：先探可读性／pull 后读回本机字节＋两端 md5／失败只登记**绝不阻断收尾**。
#   ★再加第四条：压缩件必须**解回来比 md5** 才算存下，然后才删本机原始件；对不上就留原始件、删压缩件。
#   ★go.sh:295 那句"上一发全量件改名成 dmesg.live.prev_<TAG> ⇒ pull 清单里带上它"以前**没有生产者**(例 116 同族：
#     形状词没人实现)——这里现补：名字由设备侧现数，喂进下面同一条 pull 腿，T3 才许按 glob 删它。
PREV_LIST=$(A "ls -1 /data/local/tmp/dmesg.live.prev_* 2>/dev/null" | tr -d '\r' | sed 's|.*/||' | tr '\n' ' ')
#   ★10-22 18:2x 再加 §FDKA 那三件(开关本体/helper/日志)：包里现在**默认铺这把开关**，它们就成了每发的新脚印，
#     而 `/data/local/tmp` 活过重启——不列进来就是"靠下一次顺手清"(我们登记过的坏形状)。件不存在时同一条腿只计 SKIP。
DP_LIST="ksu_ftrace.txt ksu_ftrace_armed ksu_kallsyms.txt ksu_tainted_before.txt ksu_mod_before.txt ksu_mod_mounts.txt ksu_mod_teardown.log ksu_ui_track.txt ksu_race_fd ksu_redirect_dst ksu_redirect_con ksu_stage.log punch.log ipk.txt app_ksu.txt shd.log sushd.log ksuctl_hold.out pcode_ctl.txt ksu_post.sh w184_sample.out dmesg.live dmesg2.log dmesg_full.txt ksu_fd_keepalive ksu_fd_keepalive.sh ksu_fd_keepalive.log $PREV_LIST"
DP_TAG=$(date +%m%d-%H%M)_$$   # ★加进程号：只到分钟会在"同一分钟里两次收尾"时互相覆盖/删错(自测就是这么撞上的)
DP_OK=0; DP_SKIP=0; DP_ZERO=0; DP_BAD=0
for dpm in $DP_LIST; do
    DPR="/data/local/tmp/$dpm"
    DPSZ=$(A "wc -c < $DPR 2>/dev/null" | tr -dc '0-9')
    if [ -z "$DPSZ" ]; then DP_SKIP=$((DP_SKIP+1)); continue; fi
    # ★0 字节的**开关件**(ksu_race_fd/ksu_ftrace_armed…)本来就是它自己 touch 出来的形状证人，pull 回来必然是空——
    #   把它记成"不成立"会让计数行骗人(第 30 发就是这么打出 存下=15｜不成立=3)。它没资格当读数，单独一格。
    if [ "$DPSZ" = 0 ]; then DP_ZERO=$((DP_ZERO+1)); continue; fi
    DP_RAW="kmod/w103_evidence/w421_${DP_TAG}_${dpm}"
    mkdir -p kmod/w103_evidence
    MSYS_NO_PATHCONV=1 adb pull "$DPR" "$DP_RAW" >/dev/null 2>&1
    if [ ! -s "$DP_RAW" ]; then
        rm -f "$DP_RAW"
        echo "  [x] $dpm 设备侧 $DPSZ 字节，本机 pull 到 0 ⇒ 记『没测到』，不许留空存证件"
        DP_BAD=$((DP_BAD+1)); continue
    fi
    DPL=$(md5sum "$DP_RAW" | cut -c1-32); DPD=$(A "md5sum $DPR" | cut -c1-32)
    if [ "$DPL" != "$DPD" ]; then
        rm -f "$DP_RAW"
        echo "  [!] $dpm 两端 md5 不符(本机=$DPL 设备=$DPD) ⇒ 这份不许当读数，删本机件"
        DP_BAD=$((DP_BAD+1)); continue
    fi
    gzip -c "$DP_RAW" > "$DP_RAW.gz" 2>/dev/null
    DPB=$(gunzip -c "$DP_RAW.gz" 2>/dev/null | md5sum | cut -c1-32)
    if [ "$DPB" = "$DPL" ]; then
        rm -f "$DP_RAW"
        echo "  [存] $dpm 设备 $DPSZ B ⇒ 本机 md5=$DPL ⇒ 解回一致 ⇒ 留 $DP_RAW.gz($(wc -c < "$DP_RAW.gz") B)"
        DP_OK=$((DP_OK+1))
    else
        rm -f "$DP_RAW.gz"
        echo "  [!] $dpm 压缩件解回 md5 不符 ⇒ 删压缩件、**留原始件**($DP_RAW, $(wc -c < "$DP_RAW") B)"
        DP_BAD=$((DP_BAD+1))
    fi
done
echo "  T2.8 计数(由脚本自己加，不是我数的)：存下=$DP_OK｜设备侧本来没有=$DP_SKIP｜零字节开关件=$DP_ZERO｜不成立=$DP_BAD"
echo "=== T3) 清 w16x 载荷(shell 侧就能删，目录属 shell) ==="
#   ★删与复证共用下面这两串(#139 那笔账：原来 rm 是一串字面量、复证是另一串 grep 模式，两边名字不同 ⇒
#     "删 22 个、复证只看 11 类"，漏下的那些静悄悄跨 boot 留着＝下一发拿旧件当读数，例 116/120 同族)。
#   ★T3_RM 里有证人价值的件都先过 T2.8(pull＋两端 md5＋解回比)才走到这里删(例 113：删前没 pull＝永久丢)。
#   ★只删我们这条链推上去的名字；/sdcard/z6root*(用户自己拷的交付包)、brevent/shizuku/scene-daemon(别人的东西)不在这张表里。
T3_GLOB='/data/local/tmp/w161_* /data/local/tmp/w162_* /data/local/tmp/w163_* /data/local/tmp/w164_* /data/local/tmp/a_*.bin /data/local/tmp/ipk_*.txt /data/local/tmp/dmesg.live.prev_* /sdcard/w417*.xml /sdcard/w161.xml /sdcard/w161b.xml /sdcard/w161c.xml'
T3_RM='/data/local/tmp/w165_adb_clean.sh /data/local/tmp/w165_adb_clean.out /data/local/tmp/w407_rootprobe.sh /data/local/tmp/w407_rootprobe.out /data/local/tmp/kernelsu.ko /data/local/tmp/w135_fix.sh /data/local/tmp/w135_off.sh /data/local/tmp/w135_fix.out /data/local/tmp/w135_off.out /data/local/tmp/ksu_two_profiles /data/local/tmp/sustatic /data/local/tmp/kd /data/local/tmp/ksud /data/local/tmp/perfips /data/local/tmp/pr /data/local/tmp/pr.log /data/local/tmp/slide_solve.sh /data/local/tmp/slide_ctl.txt /data/local/tmp/ksu_slide.awk /data/local/tmp/ksu_slots.dump.txt /data/local/tmp/ksu_ftrace.txt /data/local/tmp/ksu_ftrace_armed /data/local/tmp/ksu_kallsyms.txt /data/local/tmp/ksu_tainted_before.txt /data/local/tmp/ksu_mod_before.txt /data/local/tmp/ksu_mod_mounts.txt /data/local/tmp/ksu_mod_teardown.log /data/local/tmp/ksu_ui_track.txt /data/local/tmp/ksu_ui_done /data/local/tmp/ksu_race_fd /data/local/tmp/ksu_redirect_dst /data/local/tmp/ksu_redirect_con /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/ksu_ring_end.txt /data/local/tmp/ksu_ring_end_dump /data/local/tmp/ipk.txt /data/local/tmp/ipk_raw.txt /data/local/tmp/app_ksu.txt /data/local/tmp/shd.log /data/local/tmp/ksuctl_hold.out /data/local/tmp/pcode_ctl.txt /data/local/tmp/ksa_uids.txt /data/local/tmp/ksu_dom /data/local/tmp/ksu_dom_map /data/local/tmp/ksu_shbin /data/local/tmp/ksu_ap_key /data/local/tmp/ksu_allow_shell /data/local/tmp/ksu_skip_insmod /data/local/tmp/ksu_ring_end /data/local/tmp/ksu_quiet /data/local/tmp/ksu_quiet_after_insmod /data/local/tmp/ksu_quiet_fixcfi /data/local/tmp/ksu_nosuw /data/local/tmp/sushd.log /data/local/tmp/ksu_post.sh /data/local/tmp/w184_sample.out /data/local/tmp/dmesg.live /data/local/tmp/dmesg2.log /data/local/tmp/dmesg_full.txt /data/local/tmp/ksu_args.txt /data/local/tmp/w450_close.sh /data/local/tmp/ksu_fd_keepalive /data/local/tmp/ksu_fd_keepalive.sh /data/local/tmp/ksu_fd_keepalive.log /data/local/tmp/w572_root_proof.sh /data/local/tmp/w572_probe /data/local/tmp/w579_enforce.sh /data/local/tmp/w589_watch_arm.out /data/local/tmp/w589_live.log /data/local/tmp/w590_enf_marker.sh /data/local/tmp/w590_enf_marker /data/local/tmp/w590_enf.out /data/local/tmp/w558_list.txt /data/local/tmp/dmesg2.log.tmp /data/local/tmp/w161_fdwatch.log /data/local/tmp/w161_fdwatch.pid /data/local/tmp/w161_r0.txt /data/local/tmp/w205_list.out /data/local/tmp/ksu_keep_auto /data/local/tmp/b8_keep /data/local/tmp/b8_keep.log /data/local/tmp/b8_keep.sh /data/local/tmp/b8_mgr.sh /data/local/tmp/b8_pin.out /data/local/tmp/b8_pin.sh /data/local/tmp/b8_verify.out /data/local/tmp/b8_verify.sh /data/local/tmp/b8_su.out /data/local/tmp/b8_su.sh /data/local/tmp/b8_setup.out'
A "rm -f $T3_GLOB $T3_RM; echo RM_DONE"
T3_LEFT=$(A "for f in $T3_RM $T3_GLOB; do if [ -e \"\$f\" ]; then echo \"\$f\"; fi; done" | tr -d '\r' | grep -a / | tr '\n' ' ')
T3_N=$(printf '%s\n' $T3_RM $T3_GLOB | wc -l | tr -dc '0-9')
if [ -z "$T3_LEFT" ]; then
    echo "    [OK] 复证：名单 $T3_N 条(与上面那条 rm 同源，不是另写的模式)全部删净"
else
    echo "    [!] 复证：这些还在 ⇒ 记台账、别当已清：$T3_LEFT"
fi
#   ★`pbin` 是 stage 用 root 身份建的目录(里面还留着 bind 的那份 su 拷贝)，shell 删不动(父目录可 rmdir，但非空且不属 shell)；
#     正常收尾由 T2 的 root 腿(w135_off.sh)删。本发 root 通道没有 ⇒ 这里只能**如实登记它还在**，不许打"清干净了"。
#   ★第 32 发上机抓出来的假读数：原来写的是 `ls -A /data/local/tmp/pbin 2>&1 | wc -l` ⇒ **目录不存在时那行报错也被数成"1 件"**，
#     于是打出"pbin 里剩 1 件"，而复位后复查是 `No such file or directory`＝根本没有那个目录(例 98/103 同族：报错行不是文件)。
#     现在先判目录在不在：不在 ⇒ 直说"目录已不在"；在 ⇒ 数**不含 stderr** 的条目数。
PBIN_STATE=$(A "if [ -d /data/local/tmp/pbin ]; then ls -A /data/local/tmp/pbin 2>/dev/null | wc -l; else echo GONE; fi" | tr -dc '0-9GONE')
if [ "$PBIN_STATE" = GONE ]; then
    echo "    登记：/data/local/tmp/pbin **目录已不在**(本发 root 侧那条腿删掉了它 ⇒ #151 这一格判正)"
else
    echo "    登记：/data/local/tmp/pbin 里剩 ${PBIN_STATE:-读数取不到} 件(root 侧件，shell 删不动；下一发有 root 通道时由 w135_off.sh 收走)"
fi
echo "=== T4) reboot + 复核出厂态 ==="
adb reboot
for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = "1" ]; do sleep 10; done
sleep 20
A 'echo 复核: up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) 挂载=$(grep -c pbin /proc/self/mountinfo) bin=$(ls -A /product/bin | wc -l) su=$(ls /product/bin/su 2>&1 | head -1)' | sed 's/^/  /'
echo "=== T5) 复位后**再读一次**、有就再清一次：固定名写者会在 rm 之后把名字重建(例 97 第二次实测：第 31 发 dmesg2.log 的 mtime 比 T3 的「删净复证」还晚) ==="
#   ★名单只写一遍：删与复证都从 T5_FIX 派生(旧写法是这里再手抄一条 grep 模式＝两个生产者)。
#   ★标题这行原来用了反引号包 dmesg2.log ⇒ 双引号里真的执行了它(例 76 第 N 次复发，是离线自测切出这块时
#     报「dmesg2.log: command not found」才发现的，见 §6.367)，现在一律写成明文。
T5_FIX="dmesg.live dmesg2.log dmesg_full.txt w184_sample.out ksu_args.txt punch.log ksu_stage.log sushd.log shd.log ksu_nosuw ksu_race_fd ksu_fd_keepalive ksu_fd_keepalive.sh ksu_fd_keepalive.log ksu_keep_auto b8_keep b8_keep.log"
T5_CHK() { A "for f in $T5_FIX; do if [ -e /data/local/tmp/\$f ]; then echo /data/local/tmp/\$f; fi; done" | tr -d '\r' | grep -a / | tr '\n' ' '; }
T5_N=$(printf '%s\n' $T5_FIX | wc -l | tr -dc '0-9')
T5_LEFT=$(T5_CHK)
if [ -z "$T5_LEFT" ]; then
    echo "  [OK] 复位后复读：$T5_N 个固定名一个都不在"
else
    echo "  复位后还在(＝rm 之后被重建或漏删)：$T5_LEFT ⇒ 再删一次，等一个节拍再复读"
    A "rm -f $(printf '%s' "$T5_LEFT")" >/dev/null
    sleep 5
    T5_LEFT2=$(T5_CHK)
    if [ -z "$T5_LEFT2" ]; then
        echo "  [OK] 复读：现在都删净了(第一次复证之所以绿，是因为写者当时还活着——见 §6.366④)"
    else
        echo "  [!] 仍在：$T5_LEFT2 ⇒ 复位后仍有东西在写这些名字(不该发生) ⇒ 记台账、别当已清"
    fi
fi
