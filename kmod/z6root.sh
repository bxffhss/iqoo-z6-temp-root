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
#  ★拿到 root 的入口是**绝对路径**：/system/bin/su -c '<命令>'（内核改道＋白名单）
#   ★§6.566 默认**零全局 su**：不再把 sustatic bind 成 /product/bin/su ⇒ 常见 su 路径全 clean，
#     第三方 app 的裸 `su` 会 ENOENT；要老形状给 SU_BIND=1 重跑（实验/兼容用）。
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
UP=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
MOD=$(grep -c kernelsu /proc/modules 2>/dev/null)
ENF=$(/system/bin/getenforce 2>/dev/null)
BID=$(cat /proc/sys/kernel/random/boot_id)
say "  up=${UP:-读不到} mod=${MOD:-读不到} enforce=${ENF:-读不到} boot_id=$BID"
#   ★第 55 发一手(0 枪，被自己这条闸拦下来才发现)：这里原来是 `[ "$MOD" = 0 ] || die "本 boot 已经有 kernelsu 模块"`。
#     在**读不动 /proc 的宿主**里(app 域，例 Termux：`grep: /proc/modules: Permission denied`)`MOD` 是**空串**，
#     于是照样 die，还把"缺读数"报成"已有模块"＝**假归因**(例 174/178 那一族：缺读数≠读数，两者不许共用一句话)。
#     ⇒ 现在分三支：0＝放行；非数字/空＝**宿主不对**(明写要 uid=2000 的 shell 宿主)；非 0＝铁律 1 真拦。
case "$MOD" in
    0) : ;;
    ''|*[!0-9]*) die "读不到 /proc/modules(mod=[$MOD]) ⇒ 这不是「已经装载」，是「没有读数」：本脚本要跑在**能读 /proc、能写 /data/local/tmp 的宿主**里(uid=2000 的 shell：adb shell 或等价物)；app 域两道都被 SELinux 挡" ;;
    *) die "本 boot 已经有 kernelsu 模块(mod=$MOD，铁律 1)⇒ 先 reboot，再重跑本脚本" ;;
esac
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
chmod 755 "$TMP/ksuctl" "$TMP/ksuctl88" "$TMP/pr" "$TMP/perfips" "$TMP/shd" "$TMP/sustatic" "$TMP/ksud" 2>/dev/null
# ★第 55 发一手(0 枪抓到)：上一版这句被我改成**引号粘连**(`" "$TMP/w774_pbin_keeper.sh"$TMP/w135_fix.sh"`)
#   ⇒ keeper／w135_fix／w450_close 三只**没拿到 x 位**，而末尾 `2>/dev/null` 把失败咽掉了、整句照样"看起来跑过"。
#   这正是例 176② 那一族：交付形状里腿是被 `/system/bin/su -c <绝对路径>` 直接 execve 的，没 x 位＝`exit=126`。
#   ⇒ 改成**从 MANIFEST 现数**：清单里有几个 `.sh` 就 chmod 几个——以后往打包映射里加件不必再动这一行(契约只留一处)，
#     并且下面那行读数把真正拿到 x 位的名字打出来，谁漏了一眼就看得到。
SHL=""
while read -r N _O; do
    case "$N" in *.sh) /system/bin/chmod 755 "$TMP/$N" 2>/dev/null; SHL="$SHL $N" ;; esac
done < "$SRC/MANIFEST"
say "  chmod 的 .sh 件=[$(grep -ac '\.sh' "$SRC/MANIFEST") 条清单命中] 实到=[$SHL ]"
for P in $SHL; do
    M=$(ls -l "$TMP/$P" 2>/dev/null | cut -c1-11)
    case "$M" in *x*) : ;; *) say "    [x] $P 模式=$M ⇒ **没拿到 x 位**(打字腿会 exit=126)" ;; esac
done
# ↑★w625 必须拿到 x 位：交付形状里它是被 `/system/bin/su -c <绝对路径>` **直接 execve** 的，
#   没有任何 x 位的文件 root 也 EACCES(一手：@sushd 派 0666 的腿只留一行 exit=126)⇒ 光拷过去不算铺好。

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
say "  抢装看门狗开关：$(ls -l "$TMP/ksu_race_fd" | tr -s ' ')"
# ★RACE 那条只活 75×0.4 秒≈30 秒，而 Manager 那一屏是**启动时一次性查询** ⇒ 30 秒之后任何一次 Manager
#   重启(用户自己关又开、系统回收、软重启)都会退回"不支持"。想把牌子拉长的那条路(常驻补装 FDKA＝往 zygote
#   种驱动 fd)**已判死，别开**——10-23 第 39/43 两发的一手读数(md §6.400)：
#     每一条 `init: Service 'zygote' (pid X) received signal 6` 里的 X **都是刚被排队补装的那个 pid**，
#     延迟 0.23~0.77 秒，两发合计 6/6 配对；而 FDKA 没开的 12 份日志里这种 abort＝0。
#     ⇒ 种下去的那个 zygote 半秒内自杀，之后 fork 的 app 什么也继承不到 ⇒ 牌子根本拉不长
#     (这就是 #168② 三次都拍不到的原因，不是"没拍到")。
#   这条循环另外还踩过一条内核洞(§6.394：给正在 do_exit 的任务排活时 current->files 已是 NULL，而
#   ksu_install_fd()→__alloc_fd() 一路没有 !files 防护)，rc73 已把护栏编进 ko；但第 43 发实测
#   `NULLFILES skip`＝0(整环覆盖到死亡前 1.8 秒，5/5 排队都配对了回调)⇒ 那条梯从用户态打不到，
#   真正在伤的是上面那条用户态 SIGABRT。
#   ⇒ 交付默认不铺这把开关。想要牌子常驻得换机制(不往 zygote 种 fd)，别 touch $TMP/ksu_fd_keepalive。
say "  常驻补装开关：默认**不铺**(§6.400 实测：种进 zygote 的驱动 fd 会让它在 0.3~0.8 秒内 SIGABRT⇒牌子拉不长；别 touch $TMP/ksu_fd_keepalive)"

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
    #   ★§6.566 用户决策：临时 root **不全局放 su**。默认不跑 w135_fix.sh ⇒ 不落地
    #     /product/bin/su ⇒ 常见 su 路径全 clean(Momo 文件面)。代价＝第三方 app 裸 `su` ENOENT；
    #     授权 app 仍走 /system/bin/su 改道＋内核白名单。SU_BIND=1 才逐字重放老形状。
    if [ "${SU_BIND:-0}" = 1 ]; then
        say "-- 9) bind su（经 agent 派 w135_fix.sh；SU_BIND=1 实验形状）--"
        am start -f 0x4000000 -n "$MANAGER/.MainActivity" --es auto ksuarm --es cmd "@sushd:$TMP/w135_fix.sh" >/dev/null 2>&1
        M=1
        while [ "$M" -le 20 ]; do
            grep -q '===== DONE' "$TMP/w135_fix.out" 2>/dev/null && { say "  w135_fix 跑到 DONE"; break; }
            M=$((M + 1)); sleep 4
        done
        grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' "$TMP/w135_fix.out" 2>/dev/null | cut -c1-110 | sed 's/^/    /'
    else
        say "-- 9) ★默认零全局 su：跳过 bind(§6.566) --"
        say "  /product/bin/su 不落地；常见 su 路径全 clean；授权 app 走 /system/bin/su 改道"
        say "  要老形状给 SU_BIND=1 重跑本脚本(实验/兼容用)"
    fi
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
    say "  首页牌子退回 不支持 时(自己杀过管理器或被系统回收)，敲这条恢复——不重跑本脚本、不用电脑："
    say "      /system/bin/su -c $TMP/w625_seedrestart.sh"
    say "      判据＝它自己打的那行 SR-ROUND r=1 pid=<新进程号> fd=1（fd=1＝已在该进程 fd 表里读回 ksu_driver），随后首页回到 工作中/版本：32601-2"
    say "      (一手＝10-23 第 49 发 §6.407：4 次调用全部第 1 轮命中，约 11 秒)"
    say "      ★三条规矩(10-24 #180 加的，一手＝用户连着敲这条腿之后手机硬复位)：牌子亮着就别敲；两条之间隔够 150 秒；"
    say "      一个开机内最多 6 次。违反时它自己退回，读数分别是 SR-ALREADY(已在位，没动进程)/SR-COOL(还差 N 秒)/SR-BUDGET(到次数)——"
    say "      被拒不是坏：那期间 su 照常出 uid=0，暗的只是首页那一屏。凭据落在 /data/local/tmp/w625_lock，三条都在腿里，不靠我记得。"
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
    say "  ★首页那块牌子退回 不支持 时(自己杀过管理器或被系统回收)：/system/bin/su -c $TMP/w625_seedrestart.sh"
    say "      判据＝它打的那行 SR-ROUND r=1 pid=… fd=1，随后回到 工作中/32601-2（一手＝§6.407，4/4 第 1 轮命中）"
    say "      ★别把它当刷新键按：亮着时敲它，它会认出当前进程就是上次种过 fd 的那个并打 SR-ALREADY，什么都不做；"
    say "      两次真重启之间要隔 150 秒(不然打 SR-COOL)，一个 boot 累计到 6 次就打 SR-BUDGET 停手——连着 force-stop 就是硬复位的形状。"
    say ""
    say "用完：adb 没有了也没关系—— reboot 一次就回到出厂态（临时 root 不持久，重启失效）。"
fi
say "=== Z6ROOT_DONE up=$(cut -d' ' -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enforce=$(getenforce) ==="
