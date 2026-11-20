#!/system/bin/sh
# =============================================================
#  iQOO Z6 临时 root —— 纯 shell 一键（无电脑、无 adb 侧脚本）
#  机型 : iQOO Z6 / V2220A (PD2220) / Android 14 **user** 版 / 5.4.281-qgki / SM7325
#  环境 : 由 Stellar / Shizuku 这类 app 提供的 shell（uid 2000，等价 adb shell）
#  用法 : /system/bin/sh /sdcard/z6root/z6root.sh
#         要换目标 app：Z6TARGET_PKG=com.xxx /system/bin/sh /sdcard/z6root/z6root.sh（uid 一律现取）
#  性质 : 免解 BL、不刷机、临时 root；重启即失效，重跑即复活
#  授权 : ★默认走「免界面入口」(B 形状，第 31/32 发两发判正)——名单里那条**就是目标 app 自己**，
#         装载那一刻它已有 root 壳，不用装额外 APK、不用点任何开关；
#         取不到那个 uid ⇒ **自动退回 A 形状**（名单主条目=suw，靠官方 KernelSU 管理器点开关），
#         并且当场把"退回了"打在明面，不静默换形状。
#  -------------------------------------------------------------
#  ★铁律（照 z5root 那套写死，别再靠人记）：
#   1) 一次开机只够一次 punch ⇒ 本 boot 打过了（或 /proc/modules 里已有 kernelsu）就**先重启**再跑；
#   2) KSU 载入后不要 rmmod、不要重跑 punch；要重来 = reboot；
#   3) slide 是 per-boot 的，只能现解；解不出来就停，**绝不猜**；
#   4) 载荷与本目录 MANIFEST 的 md5 逐条不符就停（两端核对，不看命令退出码）；
#   5) root 只在本次开机有效；用完 reboot ⇒ 回到出厂态（临时 root 不持久）。
#  ★拿到 root 的入口是**绝对路径**：/system/bin/su -c '<命令>'
#   （裸敲 `su` 命中的是 /product/bin/su，而内核改道只匹配 /system/bin/su 这个路径字符串 ⇒ 不提权）
#  =============================================================

SRC=/sdcard/z6root
TMP=/data/local/tmp
KO_NAME=kernelsu.ko
LOG=$TMP/ksu_stage.log
PLOG=$TMP/punch.log
MANAGER=com.suw.manager
OFFICIAL=me.weishu.kernelsu
LOAD_MAX=${LOAD_MAX:-3}
SHD_PORT=${SHD_PORT:-31339}

say() { echo "$1"; }
die() { echo "[x] $1"; echo "[x] 已停：没有产物就没有发生，别继续往下猜"; exit 1; }

say "==================================================="
say " iQOO Z6 临时 root（纯 shell 一键）"
say "==================================================="

# ---------- 0) 身份与起点 ----------
U=$(id -u)
[ "$U" = 2000 ] || say "  [!] uid=$U（预期 2000=shell）⇒ 继续，但判据按你的身份读"
UP=$(cut -d' ' -f1 /proc/uptime)
MOD=$(grep -c kernelsu /proc/modules)
ENF=$(getenforce)
BID=$(cat /proc/sys/kernel/random/boot_id)
say "  up=$UP mod=$MOD enforce=$ENF boot_id=$BID"
[ "$MOD" = 0 ] || die "本 boot 已经有 kernelsu 模块（铁律 1）⇒ 先 reboot，再重跑本脚本"
[ -d "$SRC" ] || die "找不到 $SRC（把 z6root 整个目录放到 /sdcard/ 下，见教程第 1 步）"

# ---------- 1) 载荷核对：拷到 /data/local/tmp 并逐条比 md5 ----------
if [ ! -f "$SRC/MANIFEST" ]; then
    die "缺 $SRC/MANIFEST（打包时生成的清单；别只拷 z6root.sh）"
fi
say "-- 1) 铺载荷（两端 md5 核对）--"
# 清单每行 = <设备上名> <字节> <md5>
while read DEVNAME SZ MD5; do
    [ -n "$DEVNAME" ] || continue
    case "$DEVNAME" in \#*) continue ;; esac
    [ -f "$SRC/$DEVNAME" ] || die "包里缺 $DEVNAME"
    LM=$(md5sum "$SRC/$DEVNAME" | cut -d' ' -f1)
    [ "$LM" = "$MD5" ] || die "$DEVNAME 包内 md5=$LM 与清单=$MD5 不符 ⇒ 包被改过或拷坏了"
    cp -f "$SRC/$DEVNAME" "$TMP/$DEVNAME" || die "拷 $DEVNAME 到 $TMP 失败"
    RM=$(md5sum "$TMP/$DEVNAME" | cut -d' ' -f1)
    [ "$RM" = "$MD5" ] || die "$DEVNAME 落到 $TMP 后 md5=$RM 与清单=$MD5 不符"
    say "  ok $DEVNAME $RM"
done < "$SRC/MANIFEST"
chmod 755 "$TMP/ksuctl" "$TMP/ksuctl88" "$TMP/ksu_post.sh" "$TMP/pr" "$TMP/perfips" "$TMP/shd" "$TMP/sustatic" "$TMP/w135_fix.sh" "$TMP/w450_close.sh" 2>/dev/null

# uname -s 仍是 Linux ⇒ 这个 boot 还没被相0 污染（slide 缓存有效性的判据）
UN=$(uname -s)
say "  uname -s = [$UN]（Linux ⇒ 本 boot 未打过）"

# ---------- 2) uid 现取（卸载重装就换号，绝不写死） ----------
say "-- 2) uid 现取 --"
UID_S=$(pm list packages -U | grep -w "$MANAGER" | grep -o 'uid:[0-9]*' | cut -d: -f2)
[ -n "$UID_S" ] || die "查不到 $MANAGER 的 uid（没装那个白名单管理器？）⇒ 先按教程装 APK"
UID_M=$(pm list packages -U | grep -w "$OFFICIAL" | grep -o 'uid:[0-9]*' | cut -d: -f2)
[ -n "$UID_M" ] || die "查不到官方管理器 $OFFICIAL 的 uid ⇒ 先装 $SRC/KernelSU_manager.apk"
say "  suw=$UID_S  官方管理器=$UID_M"
echo "$UID_S $UID_M" > "$TMP/ksa_uids.txt" || die "写 ksa_uids.txt 失败"
chmod 666 "$TMP/ksa_uids.txt"
RD=$(cat "$TMP/ksa_uids.txt")
[ "$RD" = "$UID_S $UID_M" ] || die "ksa_uids.txt 读回=[$RD] 与写入不符"

# ---------- 3) 清同名产物（跨 boot 同名会把下一发的读数造假） ----------
say "-- 3) 清同名产物并复证 --"
rm -f "$LOG" "$PLOG" "$TMP/dmesg.live" "$TMP/ksu_ring_end.txt" "$TMP/w135_fix.out" "$TMP/shd.log"
sleep 2
ls "$LOG" "$PLOG" "$TMP/ksu_ring_end.txt" 2>&1 | sed 's/^/  复证：/'

# ---------- 3.5) 形状整理：改道落点从 args 反推；实验开关一律删掉；官方管理器要能看见驱动 ----------
say "-- 3.5) 形状整理 --"
# ★落点/标签不许靠人记（§6.228⑨）：ksu_ksud_path 不是 /dev/ksud 时，stage 需要这两个文件才知道
#   "把 ksud 复制到哪、贴什么标签"。标签默认**只能 plain s0**：带 MLS 类别在执法下挡掉 app 的 execute(rc=126，第 104 发)。
KSUD_P=$(tr ' ' '\n' < "$TMP/ksu_args.txt" | sed -n 's/^ksu_ksud_path=//p')
if [ -n "$KSUD_P" ] && [ "$KSUD_P" != /dev/ksud ]; then
    echo "$KSUD_P" > "$TMP/ksu_redirect_dst"
    echo "u:object_r:apk_data_file:s0" > "$TMP/ksu_redirect_con"
    say "  改道落点从 args 反推＝dst=$(cat "$TMP/ksu_redirect_dst") con=$(cat "$TMP/ksu_redirect_con")"
else
    rm -f "$TMP/ksu_redirect_dst" "$TMP/ksu_redirect_con"
    say "  ksu_ksud_path=[${KSUD_P:-<args 里没给>}] ⇒ 不铺落点（stage 装载前那段 cp/chcon 不会跑）"
fi
# ★实验形状的所有开关都删干净：任何一把残留都会把这一跑静悄悄换成另一种形状
#   ★清单只写一遍，删与复证都从同一个变量取——原来两处各写一份字面量，删 10 个只复证 6 个，
#     残留的 4 把没人看(例 120 同族：同一个计数不许有两个生产者)。#145 的 ksu_nosuw 也在这张表里。
SWITCH_FILES="$TMP/ksu_quiet_after_insmod $TMP/ksu_quiet_fixcfi $TMP/ksu_dom $TMP/ksu_dom_map \
$TMP/ksu_shbin $TMP/ksu_two_profiles $TMP/ksu_ap_key $TMP/ksu_allow_shell $TMP/ksu_fd_keepalive \
$TMP/ksu_skip_insmod $TMP/ksu_ring_end $TMP/ksu_nosuw \
$TMP/ksu_fd_keepalive.sh $TMP/ksu_fd_keepalive.log"
rm -f $SWITCH_FILES 2>/dev/null
sleep 1
say "  开关复证（应全部 No such file；清单件数=$(echo $SWITCH_FILES | wc -w)）：$(ls $SWITCH_FILES 2>&1 | tr '\n' ' ')"

# ---------- 3.6) ★免界面入口(B)：把名单那条写成**目标 app 自己**（#145 达成，第 31/32 发两发判正） ----------
#   为什么这一步必须在开关复证**之后**：上面那张清单里就有 ksu_nosuw，先删后铺才谈得上"这一跑是什么形状"。
#   ★契约（§6.365 用二进制定案，写在 stage 侧）：开关内容必须是「<uid> <包名>」两段，uid 一律现取（重装就换）；
#     取不到 ⇒ **不写这个开关** ⇒ 这一跑就是 A 形状，并且当场把"退回了"打在明面（例 116/142：默认形状不许静默换）。
say "-- 3.6) 入口形状(1=免 suw/免界面，0=带 suw/靠界面) --"
Z6TARGET_PKG=${Z6TARGET_PKG:-com.termux}
Z6B=0
Z6UID=$(pm list packages -U 2>/dev/null | grep -a "^package:$Z6TARGET_PKG uid:" | tail -1 | sed 's/.*uid://' | tr -dc '0-9')
case "$Z6UID" in '' | 0 ) Z6UID="" ;; esac
if [ -n "$Z6UID" ]; then
    printf '%s %s\n' "$Z6UID" "$Z6TARGET_PKG" > "$TMP/ksu_nosuw"
    Z6RB=$(cat "$TMP/ksu_nosuw" 2>/dev/null)
    Z6NW=$(wc -w < "$TMP/ksu_nosuw" 2>/dev/null | tr -dc '0-9')
    Z6NB=$(wc -c < "$TMP/ksu_nosuw" 2>/dev/null | tr -dc '0-9')
    if [ "$Z6RB" = "$Z6UID $Z6TARGET_PKG" ] && [ "$Z6NW" = 2 ]; then
        Z6B=1
        say "  ★免 suw 开关已铺并读回：内容=[$Z6RB] 词数=$Z6NW 字节=$Z6NB ⇒ 这一跑走 B 形状（名单只写目标 app，bind 由 stage 自己做）"
    else
        rm -f "$TMP/ksu_nosuw"
        say "  [!] 开关写了但读回不符（实得[$Z6RB] 词数=$Z6NW）⇒ 已删掉，这一跑按 A 形状走"
    fi
else
    say "  [!] 现取不到 [$Z6TARGET_PKG] 的 uid（pm list packages -U 里没有『package:$Z6TARGET_PKG uid:』这一行）⇒ **不写开关**，这一跑按 A 形状走（名单主条目=suw，靠界面点开关）"
fi
say "  入口形状=$Z6B（1=免 suw/免界面，0=带 suw）目标包=$Z6TARGET_PKG 现取 uid=${Z6UID:-<没取到>}"

# ★官方 Manager 首页的"支持/不支持"是**启动时一次性分支**，驱动 fd 晚到它也不重查 ⇒ 必须让 stage 起
#   0.4s 抢装看门狗，而那个看门狗只在这个文件存在时才起。没有它 = 用户打不开授权页 = 没有授权入口。
touch "$TMP/ksu_race_fd"
# ★本发实验件(§6.394/#170)：手动把常驻补装开关铺回来，让"唯一变量=ko 版本"成立
touch "$TMP/ksu_fd_keepalive"
say "  抢装看门狗开关：$(ls -l "$TMP/ksu_race_fd" | tr -s ' ')"
# ★RACE 那条只活 75×0.4 秒≈30 秒，而 Manager 那一屏是**启动时一次性查询** ⇒ 30 秒之后任何一次 Manager
#   重启(用户自己关又开、系统回收、软重启)都会退回"不支持"——这一格 §6.388 用常驻补装(FDKA)修好了，
#   但**10-22 22:4x 起这把开关退回默认不铺**，原因不是它没修好牌子，而是第 38 发现场把它暴露出一条我自己造的洞：
#     常驻循环会给"新出现的 pid"排队补装驱动 fd，而 pidof zygote64 在这台机上会返回 zygote 刚 fork、
#     还没改名的瞬时子进程；给这种进程排的活可能直到它 do_exit 才跑，那时 exit_files() 已把
#     current->files 置 NULL(kernel/exit.c:855 早于 :860)，而 ksu_install_fd()→get_unused_fd_flags()→
#     __alloc_fd()(fs/file.c:480) 一路没有 !files 防护 ⇒ 踩空指针。那一发正是 insmod 后 ≈170 秒整机复位。
#     机制在源码层已证成，那一发的归因还差一手(无 pstore、dropbox 对 shell 拒读)。
#   ⇒ 带 !current->files 护栏的 ko 编出来并认证之前，交付默认不踩这条路。想要牌子常驻的人自己承担风险：
#     touch /data/local/tmp/ksu_fd_keepalive 之后再跑本脚本(它自己会写 WRITEFAIL/GIVEUP，不会闷着)。
say "  常驻补装开关：默认**不铺**(§6.394 那条洞；要牌子常驻就自己 touch $TMP/ksu_fd_keepalive)"

# ---------- 4) 起 root agent（suw 的白名单里加上它自己的 uid） ----------
say "-- 4) 起 agent --"
cd "$TMP" || die "进不了 $TMP"
OLD_SHD=$(pidof shd)
if [ -n "$OLD_SHD" ]; then
    # 10-20 预演一手：第二个 shd 会因端口被占而打"两个通道都起不来, 退出"⇒ 复用而不是报错(幂等，例 88 那一族)
    say "  agent 已在跑(pid=$OLD_SHD) ⇒ 复用，不再起第二个"
else
    setsid nohup "$TMP/shd" "$SHD_PORT" 1800 "$UID_S" </dev/null >>"$TMP/shd.log" 2>&1 &
    sleep 3
    say "  agent 回执：$(tail -2 "$TMP/shd.log" 2>/dev/null | tr '\n' ' ')"
    #   ★失败出口按入口形状分两支（例 105：收尾/降级不许排在失败出口之后）：A 形状的 bind 要靠它派单 ⇒ 停；
    #     B 形状的 bind 由 stage 自己做、它的白名单又是 suw 的 uid ⇒ 这一跑**不依赖 agent**，只 warn 不停。
    if [ -z "$(pidof shd)" ]; then
        if [ "$Z6B" = 1 ]; then
            say "  [!] agent 没起来，但 B 形状不依赖它（bind 归 stage，派单也不走 suw）⇒ 继续"
        else
            die "agent 没起来 ⇒ 后面的 bind 派不动(注：不 bind su 也能用绝对路径那条改道路，但这一版仍走 agent)"
        fi
    fi
fi

# ---------- 5) slide 现解（#146：设备侧自解，不再需要电脑） ----------
say "-- 5) 解 slide --"
for NEED in slide_solve.sh ksu_slide.awk slide_ctl.txt perfips; do
    [ -s "$TMP/$NEED" ] || die "第 5 步要的载荷 [$NEED] 不在 $TMP（清单没铺全？）⇒ 停"
done
CACHE="$TMP/ipk_$BID.txt"
if [ -f "$CACHE" ] && [ -s "$CACHE" ]; then
    SLIDE=$(grep -oE '^SLIDE [0-9a-f]+' "$CACHE" | awk '{print $2}')
    say "  命中本 boot 缓存(boot_id=$BID)"
else
    # ★perfips 自己**只打候选行**(k <hex> 与 N=…)，它从来不打 SLIDE——SLIDE 一直是
    #   PC 侧 analysis/slide_pc.py 算出来的(#146 就是把那份算法搬进 ksu_slide.awk)。
    #   所以这里必须先采样再交给驱动；直接把 perfips 的输出当结果是第一版的错。
    "$TMP/perfips" 25 > "$TMP/ipk_raw.txt" 2>&1
    RAWN=$(LC_ALL=C awk '{print $NF}' "$TMP/ipk_raw.txt" | LC_ALL=C grep -acE '^[0-9a-f]{16}$')
    sh "$TMP/slide_solve.sh" "$TMP/ipk_raw.txt" "$TMP/slide_ctl.txt" "$TMP/ksu_slide.awk" > "$TMP/ipk.txt" 2>&1
    SRC=$?
    SLIDE=$(grep -oE '^SLIDE [0-9a-f]+' "$TMP/ipk.txt" | awk '{print $2}')
    if [ "$SRC" = 0 ] && [ -n "$SLIDE" ]; then
        cp "$TMP/ipk.txt" "$CACHE"
    else
        say "  求解器输出（全文）："
        sed 's/^/    /' "$TMP/ipk.txt"
        say "  一手计数：原始采样里 16 位 hex 的样本=$RAWN 个；文件 $TMP/ipk_raw.txt(已留)"
        die "没解出 slide ⇒ 停（铁律 3：绝不猜）。NOSLIDE 只有三种成因：①样本太少＝没采到核文本；②正对照表与本 boot 的 kallsyms 不符＝包过期；③候选不唯一。求解器已经把是哪一种打在上面了"
    fi
fi
[ -n "$SLIDE" ] || die "slide 为空 ⇒ 停"
case "$SLIDE" in *[!0-9a-f]*) die "slide 含非 hex 字符 [$SLIDE] ⇒ 停" ;; esac
say "  slide=$SLIDE"

# ---------- 6) 等负载 ----------
say "-- 6) 等负载（开机风暴里 punch 失败率明显高）--"
I=1
while [ "$I" -le 24 ]; do
    L1=$(cut -d' ' -f1 /proc/loadavg)
    INT_L=$(echo "$L1" | cut -d. -f1)
    [ -n "$INT_L" ] || INT_L=99
    if [ "$INT_L" -le "$LOAD_MAX" ]; then
        say "  负载够低：load1=$L1 up=$(cut -d' ' -f1 /proc/uptime)"
        break
    fi
    [ $((I % 4)) = 0 ] && say "    还在等：load1=$L1"
    I=$((I + 1))
    sleep 15
done
[ "$I" -le 24 ] || say "  [!] 等满 6 分钟负载仍高 ⇒ 照打（失败率会高），或稍后重跑本脚本"

# ---------- 7) punch（花掉本 boot 唯一一发） ----------
say "-- 7) punch：这一步起不可回退，成功与否都算这一 boot 用掉了 --"
setsid nohup sh -c "$TMP/pr $SLIDE hammer hijack shape2 sen victim shell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 post=$TMP/ksu_post.sh > $PLOG 2>&1; echo RC=\$? >> $PLOG" </dev/null >/dev/null 2>&1 &
J=1
while [ "$J" -le 20 ]; do
    [ -f "$PLOG" ] && { say "  pr 已起跑（$PLOG 出现）"; break; }
    J=$((J + 1)); sleep 5
done
[ -f "$PLOG" ] || die "punch.log 没出现 ⇒ 看 $TMP/shd.log 与 dmesg，别再重跑 punch（铁律 1）"

# ---------- 8) 等 stage 到判据⑥（agent fd 就位 = root 通道可用） ----------
say "-- 8) 等判据⑥（最多约 17 分钟）--"
K=1
SIX=0
while [ "$K" -le 200 ]; do
    sleep 5
    SIX=$(grep -c '判据⑥' "$LOG" 2>/dev/null)
    [ -n "$SIX" ] || SIX=0
    if [ "$SIX" != 0 ]; then
        say "  判据⑥ 到了（第 $((K * 5)) 秒）"
        break
    fi
    [ $((K % 12)) = 0 ] && say "    还在等判据⑥… up=$(cut -d' ' -f1 /proc/uptime)"
    K=$((K + 1))
done
[ "$SIX" != 0 ] || { tail -6 "$PLOG" | sed 's/^/    punch: /'; die "没等到判据⑥ ⇒ 很可能空枪（本 boot 唯一一发已花掉）：reboot 后重跑"; }

# ---------- 9) bind su（交付必要一步：没它 app 侧只有 ENOENT） ----------
if [ "$Z6B" = 1 ]; then
    #   ★B 形状下这一格**不派 suw 单**（§6.366 副作用②：名单里没有 suw，派了也没人接，只会白等 80 秒）；
    #     bind 由 stage 自己在 Permissive 相里做，证人还是那三行，只是来源换成 $LOG。
    say "-- 9) bind su：本形状由 stage 自己做（不派 suw 单），证人取自 $LOG --"
    M=1
    while [ "$M" -le 20 ]; do
        grep -aq 'NOSUW_BIND_RC' "$LOG" 2>/dev/null && { say "  stage 的 bind 证人出现了（第 $((M * 4)) 秒）"; break; }
        M=$((M + 1)); sleep 4
    done
    grep -aE '前置闸一|前置闸二|NOSUW_BIND_RC|NOSUW_SU_AT_TGT|NOSUW_CP_N|NOSUW_HEALTH' "$LOG" 2>/dev/null | tail -6 | cut -c1-170 | sed 's/^/    /'
    grep -aq 'NOSUW_HEALTH=OK' "$LOG" 2>/dev/null || say "  [!] 没读到 NOSUW_HEALTH=OK ⇒ bind 那一格按**没测到**算，别当成功"
else
    say "-- 9) bind su（经 agent 派 w135_fix.sh）--"
    am start -f 0x4000000 -n "$MANAGER/.MainActivity" --es auto ksuarm --es cmd "@sushd:$TMP/w135_fix.sh" >/dev/null 2>&1
    M=1
    while [ "$M" -le 20 ]; do
        grep -q '===== DONE' "$TMP/w135_fix.out" 2>/dev/null && { say "  w135_fix 跑到 DONE"; break; }
        M=$((M + 1)); sleep 4
    done
    grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' "$TMP/w135_fix.out" 2>/dev/null | cut -c1-110 | sed 's/^/    /'
fi

# ---------- 10) 内核侧证人（只读 stage 自己打的那几行，不再塞仪器腿） ----------
say "-- 10) 内核名单 / 加冕 / 实参 三证（来源＝$LOG）--"
grep -aE 'insmod rc|Crowning|★insmod 实参原文|allowlist:|granted\[' "$LOG" 2>/dev/null | tail -8 | cut -c1-170 | sed 's/^/    /'
CNT=$(grep -a 'allowlist: NEW_GET_ALLOW_LIST rc=0' "$LOG" 2>/dev/null | tail -1 | grep -oE 'count=[0-9]+ total=[0-9]+')
say "  名单权威那行=[$CNT]（默认形状应为 count=1 total=1；读不到就留着，别自己解释）"
# ★10-20 第 28 发一手：这里原来是对整份日志"裸抓 count="再取末行，于是抓到了一次 EPERM 探测行的 count=512 total=0
#   (那是一次 EPERM 探测，不是名单读数)当成答案打印出来 ⇒ 一个会误导用户的证人。计数要连来源一起登记。

# ---------- 11) 交给用户（两种入口各有自己的收尾句，不许共用一行文案＝例 106） ----------
if [ "$Z6B" = 1 ]; then
    say "-- 11) 本形状**不用打开任何界面**：名单里那条就是目标 app 自己 --"
    say "  直接在 [$Z6TARGET_PKG] 的终端里敲：/system/bin/su -c id | cat"
    say "  期望：uid=0(root) … context=u:r:shell:s0（一手＝第 31/32 发；★窗口内 enforce=Permissive，这句不是执法态）"
    say "  ★运行中改授权目前没有入口：要加/换 app 就 reboot 后带 Z6TARGET_PKG=<包名> 重跑本脚本（一发只够一个 boot）"
    say "  用完收尾（包里自带这条 root 侧腿，别只靠 reboot）：在 root 壳里跑 sh $TMP/w450_close.sh"
    say "      它卸掉 /product/bin 的挂载并删 /data/adb/ksu/.allowlist 与 /data/adb/ksud，读数落 /sdcard/w450_close.txt"
    say "      ★验收只看一行：rm_allow_rc=0（没有这行就是没删掉）。不删的后果不是脏，是**形状被偷换**——"
    say "      .allowlist 跨 boot 留着，下一次装载时 ko 会把它读进活表（§6.366/#153）。"
    say "  然后 reboot 一次回到出厂态（临时 root 不持久）。"
else
    say "-- 11) 打开官方 KernelSU 管理器 --"
    am start -n "$OFFICIAL/.MainActivity" >/dev/null 2>&1
    say "  已尝试拉起。首页应显示「工作中」/版本 32601-2；"
    say "  然后：超级用户页 → 打开某个 app 的开关 → 在那个 app 的终端里敲："
    say "      /system/bin/su -c id"
    say "  期望：uid=0(root) … context=u:r:shell:s0（默认形状）。看不到输出就加管道：/system/bin/su -c id | cat"
    say ""
    say "用完：adb 没有了也没关系—— reboot 一次就回到出厂态（临时 root 不持久，重启失效）。"
fi
say "=== Z6ROOT_DONE up=$(cut -d' ' -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enforce=$(getenforce) ==="
