#!/system/bin/sh
# =============================================================
#  iQOO Z6 临时 root —— 纯 shell 一键（无电脑、无 adb 侧脚本）
#  机型 : iQOO Z6 / V2220A (PD2220) / Android 14 **user** 版 / 5.4.281-qgki / SM7325
#  环境 : 由 Stellar / Shizuku 这类 app 提供的 shell（uid 2000，等价 adb shell）
#  用法 : /system/bin/sh /sdcard/z6root/z6root.sh
#  性质 : 免解 BL、不刷机、临时 root；重启即失效，重跑即复活
#  授权 : 全程用**官方 KernelSU 管理器**（未改装的 APK）点开关
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
chmod 755 "$TMP/ksuctl" "$TMP/ksuctl88" "$TMP/ksu_post.sh" "$TMP/pr" "$TMP/perfips" "$TMP/shd" "$TMP/sustatic" "$TMP/w135_fix.sh" 2>/dev/null

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
$TMP/ksu_shbin $TMP/ksu_two_profiles $TMP/ksu_ap_key $TMP/ksu_allow_shell \
$TMP/ksu_skip_insmod $TMP/ksu_ring_end $TMP/ksu_nosuw"
rm -f $SWITCH_FILES 2>/dev/null
sleep 1
say "  开关复证（应全部 No such file；清单件数=$(echo $SWITCH_FILES | wc -w)）：$(ls $SWITCH_FILES 2>&1 | tr '\n' ' ')"
# ★官方 Manager 首页的"支持/不支持"是**启动时一次性分支**，驱动 fd 晚到它也不重查 ⇒ 必须让 stage 起
#   0.4s 抢装看门狗，而那个看门狗只在这个文件存在时才起。没有它 = 用户打不开授权页 = 没有授权入口。
touch "$TMP/ksu_race_fd"
say "  抢装看门狗开关：$(ls -l "$TMP/ksu_race_fd" | tr -s ' ')"

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
    [ -n "$(pidof shd)" ] || die "agent 没起来 ⇒ 后面的 bind 派不动(注：不 bind su 也能用绝对路径那条改道路，但这一版仍走 agent)"
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

echo REHEARSAL_STOP（预演到这里就停，第 7 步 punch 绝不执行）
exit 0
