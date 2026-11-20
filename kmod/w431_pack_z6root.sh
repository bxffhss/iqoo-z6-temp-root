#!/usr/bin/env bash
# w431_pack_z6root.sh —— 把"路线 B 交付链"打成 **z5root 那种纯 shell 一键包**（`z6root/`）。
#   为什么要有它（一手账在 md §6.356／runbook §80）：现在的跑法是 PC 侧 `go.sh` 编排
#   （push → reboot → 等负载 → punch → 等判据⑥ → bind → 读数）。对用户来说这等于"要一台电脑"，
#   而 z5 那条线已经证明：同一条链可以收成设备上 `/system/bin/sh /sdcard/z6root/z6root.sh` 一条命令。
#   ★这个脚本**只做打包与静态闸，绝不开枪**：包是不是真能一键跑通，要靠一发认证（形状差见下）。
#   ★形状声明（诚实边界）：包里**不带仪器腿**（w184 采样器 / dmesg.live 跟随器 / 诊断 dump / 25s 驻留判据），
#     所以它证的不是第 27 发那套"读数形状"，而是"用户形状" ⇒ 认证那一发的判据只有两条：
#       ①脚本自己打到 `=== Z6ROOT_DONE`；②之后在 app 里 `/system/bin/su -c id` 出 `uid=0`。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
OUT=${OUT:-z6root}

# 本地件 → 设备上的名字（设备侧 z6root.sh 按第二个字段核对 md5，所以这两列就是契约）
declare -A P=(
    [kmod/kernelsu_rc78.ko]=kernelsu.ko   # ★11-09 §6.582 社区路线出货＝rc78（＝上一版 rc77 的底 ＋ `feature/sucompat.c` 热路径去打印：faccessat/newfstatat 两个钩子删掉 9 条重复 `if (ksu_stat_off)`、13 条 `KSUBEAT FS0`、FS5 decline 与那条 `pr_info_ratelimited`，逻辑逐句等价；ko 5,107,568B md5 `16b6c7c2a6f2a770c12b53ae03a331bd`，与 rc77 比只少一个未定义符号 `___ratelimit`(打印删了)、未引入任何新符号。★配套 `ksu_args.txt` 把 `ksu_hook_mask` 由 `0x2` 改成 **`0x1a`**(bit1 execve ＋ bit3 newfstatat ＋ bit4 faccessat) ⇒ 内核在 `access()`/`stat()` 就把 `/system/bin/su` 改道到 `ksu_ksud_path`，app 侧**不需要任何静态 su、也不需要 overlay**——那两样正是 Momo 报"找到可执行程序 su／分区挂载异常"的形状)。★上一版＝rc77（＝rc74c ＋ stock `/dev/ksud` 字符设备：标准 su / 官方 Manager 走 `open("/dev/ksud")+ioctl(GRANT_ROOT=0x4B01)` 由内核 allowlist 授权；11-09 16:0x 已上机 GO_RC=0、17:0x 正负对照闭环并让官方 Manager 显示「工作中」）。回退＝把这一行指回 rc77(`2b1fd07e…`)或 rc74c(`324eda4d…`)。更早一版注释：rc74c(＝rc74b 的底 ＋ 出生安装两处修法：helper 名单排除 libksud.so/crash_dump64/debuggerd64，cap 64→4096 并改成"每秒速率窗"；一手依据＝第 56 发 §6.429：正常用一会儿就把 64 格烧光 ⇒ 新 Manager 进程 fd_ksu=0 ⇒ 牌子掉不支持)。**本发跑它、跑成才算认证**；回退只要改这一行指回 rc74b(`18750560…`)或 rc73(`34b3efa8…`)，两支都留仓。   # ★10-24 22:0x 起候选出货＝rc74b(＝rc73 的那条 files==NULL 护栏 ＋ 修正过的「出生即装驱动 fd」一段)：第 51 发判正去重/不泄漏、第 52 发复现并证「老进程也补装」。★**这份包还没过真机一键认证(#178＝第 53 发)，认证过的是上一份(rc73 `34b3efa8…`，第 38/44/45 发那批凭据)**。上一版 rc73 仍留仓(且与 rc67 只差那条护栏)，改这一行就指回去。
    [kmod/ksu_args.txt]=ksu_args.txt
    [kmod/ksu_stage.txt]=ksu_stage.txt
    [kmod/ksu_one_stage.sh]=ksu_post.sh
    [cm57/ksuctl]=ksuctl
    [cm57/ksuctl88]=ksuctl88
    [cm57/sustatic]=ksud            # ★改道目标那份：stage 会 cp 成 /data/adb/ksud 与 $RDST(§6.224①：交付槽只认 sustatic)
    [cm57/sustatic]=sustatic        # bind /product/bin/su 用的同一个名字(go.sh 第 5 步点这个)
    [cm57/prbin]=pr
    [cm57/perfips]=perfips          # ★设备上唯一副本；slide 只能现解，别当可有可无
    [kmod/w433_slide_solve.sh]=slide_solve.sh   # #146：slide 求解驱动(把 perfips 原始输出喂给 awk)
    [kmod/w435_slide.awk]=ksu_slide.awk         # #146：求解器本体，与 analysis/slide_pc.py 逐句对应
    [suw_apk/shdbin]=shd
    [kmod/w135_fix.sh]=w135_fix.sh
    [kmod/w450_close.sh]=w450_close.sh   # ★#145 的 B 形状收尾腿：名单里没有 suw ⇒ 派单没人接，删 .allowlist/ksud 只能在 root 壳里跑它(§6.368)
    [kmod/w625_seedrestart.sh]=w625_seedrestart.sh   # ★#176(§6.407 判正)：管理器首页牌子退回 `不支持` 后的恢复腿——不重 punch、不改 ko，root 壳里一条命令 ≈11 秒
    [kmod/w774_pbin_keeper.sh]=w774_pbin_keeper.sh   # ★§6.426：维持裸 su 落点(root-only 源＋低频重建)；stage bind 成功后用它兜住"源被删⇒整层空壳"
)
# ★包内**现算生成**的件(不是从仓库拷)：正对照窗口表。它必须每次打包重算——
#   手抄一次，将来换 SPL/换 ko 后地址变了而表没变，求解器只会 NOSLIDE 或解出错值。
GEN=( "slide_ctl.txt" )
# ★同一个本地件要落两个设备名(sustatic→ksud 与 →sustatic)，上面那行会被后写覆盖 ⇒ 单独列出来
EXTRA=( "cm57/sustatic|ksud" )
APKS=( "suw_apk/backup_official_kernelsu_v3.3.0.apk|KernelSU_manager.apk" "kmod/suw_manager_singletop_20261018.apk|suw_manager.apk" )

echo "=== 1) 本地件齐不齐 ==="
fail=0
KS=${KS:-analysis/kallsyms_g2a88cd145def.txt}     # 正对照表唯一的地址来源(出货那份)
for f in "${!P[@]}" "${APKS[0]%%|*}" "${APKS[1]%%|*}" kmod/z6root.sh kmod/w436_mkctl.py "$KS"; do
    if [ -f "$f" ]; then
        printf '  %-46s %10d B  %s\n' "$f" "$(wc -c <"$f")" "$(md5sum "$f" | cut -c1-32)"
    else
        echo "  [x] 缺 $f ⇒ 停（包里没有它，脚本会在设备上 die）"; fail=1
    fi
done
# sustatic→ksud 那条被字典覆盖掉了，这里补一行存在性
for e in "${EXTRA[@]}"; do
    L=${e%%|*}; [ -f "$L" ] || { echo "  [x] 缺 $L"; fail=1; }
done
[ "$fail" = 0 ] || exit 1

echo "=== 2) 铺 $OUT/ ==="
mkdir -p "$OUT"
rm -f "$OUT/MANIFEST"
for L in $(printf '%s\n' "${!P[@]}" | sort); do
    D=${P[$L]}
    if [ "$D" = "sustatic" ]; then
        # ksud 与 sustatic 两个名字都要（内容同一份）
        for N in ksud sustatic; do
            cp -f "$L" "$OUT/$N"
            printf '%s %d %s\n' "$N" "$(wc -c <"$OUT/$N")" "$(md5sum "$OUT/$N" | cut -c1-32)" >> "$OUT/MANIFEST"
        done
        continue
    fi
    cp -f "$L" "$OUT/$D"
    printf '%s %d %s\n' "$D" "$(wc -c <"$OUT/$D")" "$(md5sum "$OUT/$D" | cut -c1-32)" >> "$OUT/MANIFEST"
done
cp -f kmod/z6root.sh "$OUT/z6root.sh"

echo "=== 2b) 现算包内唯一的「知识」：slide_ctl.txt（正对照窗口表）==="
#   为什么每次打包都要重算：这张表是"哪些内核函数的链接期地址+宽度"，
#   换 SPL／换 ko 之后地址就变了，而表**不会报错**——它只会让求解器解出错 slide
#   或者直接 NOSLIDE。所以它是全包里唯一一份"生成物"，禁止手抄、禁止留档不改。
python kmod/w436_mkctl.py "$KS" "$OUT/slide_ctl.txt" || { echo "  [x] 现算失败 ⇒ 停"; exit 1; }
[ -s "$OUT/slide_ctl.txt" ] || { echo "  [x] slide_ctl.txt 空 ⇒ 停"; exit 1; }
NW=$(grep -acvE '^#|^$' "$OUT/slide_ctl.txt")
[ "$NW" -ge 5 ] || { echo "  [x] 正对照窗口只有 $NW 条(<5)⇒ 停"; exit 1; }
grep -aq '^# CONSTS link_text=[0-9a-f]\{16\} link_etext=[0-9a-f]\{16\} step_dec=[0-9]\+$' "$OUT/slide_ctl.txt" \
    || { echo "  [x] slide_ctl.txt 表头形状不对(地址要 16 位 hex、step 要十进制) ⇒ 停"; exit 1; }
printf '%s %d %s\n' slide_ctl.txt "$(wc -c <"$OUT/slide_ctl.txt")" "$(md5sum "$OUT/slide_ctl.txt" | cut -c1-32)" >> "$OUT/MANIFEST"
echo "  [OK] 现算出 $NW 条窗口，已进清单"

for a in "${APKS[@]}"; do
    cp -f "${a%%|*}" "$OUT/${a##*|}"
done

# 教程（照 z5root教程.txt 的形状写，但把我们这条线的两条铁律与"绝对路径"写死）
cat > "$OUT/教程.txt" <<'TXT'
iQOO Z6（V2220A / Android 14 user 版）免解 BL 临时 root —— 纯 shell 一键 教程
1. 把整个 z6root 目录拷贝到手机 /sdcard/ 下（MT 管理器 / 文件管理器都行）。
2. 装两个 APK：KernelSU_manager.apk（官方 KernelSU 管理器，未改装）；suw_manager.apk（本机授权链的白名单管理器，一次性装上即可）。
   ★这两装的是**兜底支**要用的：这一版默认走「免界面入口」——名单里那条就是你指定的那个 app 自己，
     装完 APK 不等于你要去点它。要换目标 app：`Z6TARGET_PKG=<包名> /system/bin/sh /sdcard/z6root/z6root.sh`（uid 每次现取）。
3. 手机**先重启一次**（一次开机只够一次提权尝试；跑过一次就必须重启再跑）。
4. 用 **adb shell（uid=2000 的 shell 宿主）**执行：
       /system/bin/sh /sdcard/z6root/z6root.sh
   ★宿主必须是能读 /proc、能写 /data/local/tmp 的 shell 域(adb shell 最直接；Stellar 之类"提供 shell 的 app"若跑在 app 域就不等价)：
     app 域里 `grep /proc/modules` 与写 /data/local/tmp 都会被 SELinux 挡，脚本会在第 0 步就停下并明写"读不到 /proc"——
     那是**没有读数**，不是"已经装载"(10-25 第 55 发一手：闸原先把空读数报成"本 boot 已有模块"，现已分三支)。
   看到最后一行 `=== Z6ROOT_DONE ... mod=1 ...` 就是载入成功。
   ★这一步不需要电脑：KASLR slide 是手机自己解的（第 5 步现采样现算，约 1 秒）。
   如果报 "[x] 没解出 slide ⇒ 停"：它上面就写了是哪一种原因（①样本太少=没采到内核文本；
   ②正对照表与本机 kallsyms 不符=包过期；③候选不唯一）。这三种都**只能重来**，
   脚本按铁律绝不会猜一个数往下走 ⇒ 先 reboot，开机后立刻重跑本脚本最稳。
5. **看第 4 步打出的那一行「入口形状=?」再决定要不要开界面**：
   - `入口形状=1`（默认）⇒ **什么都不用点**，直接跳到第 6 步。名单在装载那一刻就写好了。
   - 打了 `[!] …这一跑按 A 形状走` ⇒ 才需要：打开 KernelSU 管理器 → 超级用户 → 打开那个 app 的开关。
     （这句不是坏，是脚本按规矩退回：它现取不到那个包的 uid，就**不猜**、也不静默换形状。）
6. 在那个 app 的终端里敲（★必须是绝对路径）：
       /system/bin/su -c id
   期望：uid=0(root) gid=0(root) ... context=u:r:shell:s0
   裸敲 su 命中的是 /product/bin/su（静态 su→root agent 那条路）：执法态下它不提权（errno=13，已知形状不是坏了）；
   ★Permissive 窗口内实测它能出 root —— 所以别拿"裸 su 行不行"当判据，一律用上面的绝对路径。
7. 用完先收尾再 reboot（★`入口形状=1` 这一支必做）：在 root 壳里跑
       /system/bin/su -c 'sh /data/local/tmp/w450_close.sh'
   然后看 /sdcard/w450_close.txt 里有没有 `rm_allow_rc=0` —— 有就是名单文件删净了。
   ★跑它是为了**不留脚印**（名单里不留着你的 app），不是为了"防下一次换形状"：每次跑这个包都会用**当次**
     参数把那份文件整份重写（`ksuctl mkallow` 走截断写，一手读数＝装载前那行"落盘读回：…字节=792 条目=(uid,key)"），
     所以上一发的授权不会偷偷带进下一发。没跑它 reboot 也照样回出厂态。
   ★10-25 第 55 发起这条腿多做三件事（读数全在 /sdcard/w450_close.txt，它自己一开场就把该文件 chmod 666）：
     ①先把维持件的开关 `/data/local/tmp/ksu_pbin_keep` 删掉并等它自退 ⇒ 看 `killswitch_rm_rc=0` 与 `KEEPER_LEFT=退了`；
     ②卸 `/product/bin` 的挂载，**没卸成就不许删 bind 的源**（失败后照样删源会当场把 mountinfo 写成 `…/pbin//deleted`
       ＝整层 `/product/bin` 空壳、裸 su 与管理器落点一起没；一手＝第 54 发）⇒ 看 `umount_rc` 与 `MOUNT_LEFT=0`；
       若 `MOUNT_LEFT≠0`，它会明写"不删源"——那不是坏了：挂载不活过 reboot，那份源只有 root 读得动，
       下一发装载前脚本自己的前置闸会把它重建。
     ③名单文件仍然删净：`rm_allow_rc=0` 且 `ALLOW_LEFT=[… No such file or directory]`。
   最后 reboot 一次：这个 root 不持久、重启失效。
8. 管理器首页那块"支持 / 越狱模式"的牌子（★10-23 第 49 发实测口径，一手在 md §6.407；这一段替换了旧版"约 30 秒内显示支持、隔久了重跑 ui_grant 补装"的说法——那句是错的）：
   - **默认你什么都不用点**：脚本装载那一刻，stage 自己就把驱动 fd 抢装进了刚起来的管理器进程（一手日志 `RACE 抢装 pid=… (第 2 轮，约 0s)`），
     首页直接是「工作中 / 版本：32601-2 / 越狱模式」。
   - 牌子是**进程启动时一次性查询**：那个管理器进程活着它就一直亮；**你把它杀掉或系统把它回收了再打开，就退回"不支持"**。
     这不是 root 坏了——`/system/bin/su -c id` 照样出 uid=0(root)。晚到的 fd 也刷不亮一个已经在跑的进程（同一发实测）。
   - 退回以后恢复它，一条命令（★要 root，所以只在窗口里、reboot 之前有效）：
         /system/bin/su -c /data/local/tmp/w625_seedrestart.sh
     它自己做 `force-stop`→重开管理器→用 0.1 秒节拍盯到新进程就把 fd 装进去；判据看它自己打的那行
         SR-ROUND r=1 pid=<新进程号> fd=1        （fd=1＝已在该进程 fd 表里读回 ksu_driver）
     随后首页应回到「工作中 / 32601-2」。实测：4 次调用**全部第 1 轮命中**，从敲下到读完约 11 秒；
     恢复后不碰它 5.5 分钟仍然是亮的。
   - ★★别连着敲它，也别在它亮着的时候敲（10-24 加的三条硬规矩，一手＝用户按旧版教程连打多次后**手机硬复位**）：
       这条腿每敲一次就要"杀掉并重启管理器一回"＋在 0.1 秒节拍上轮询几十次，连着敲就是风暴。所以它自己带了闸，
       凭据落在 /data/local/tmp/w625_lock，四种读数各管一件事：
         SR-ALREADY  ＝ 当前活着的管理器就是上次种过 fd 的那个进程、fd 也还在 ⇒ 它**什么都没做**，这就是"亮着就别再敲"；
         SR-COOL     ＝ 距上次重启管理器不足 150 秒 ⇒ 本次不做 force-stop，等它报的剩余秒数过完再敲同一条命令；
         SR-BUDGET   ＝ 本次开机已经重启过 6 次 ⇒ 不再动进程；还想要牌子就整机重启后重跑 z6root.sh；
         SR-ROUND    ＝ 真的动手了(见上一格)。
       被拒不是坏：这期间 root 照常(/system/bin/su -c id 出 uid=0)，暗的只是那一屏。
       没打 `SR-ROUND`（或打"2.5s 内没见着 fd"）就等冷却过了再敲一次——它每次调用最多内部试 6 轮、不常驻、不留后台进程，也没有任何"自动"承诺。
   - 反向那两格也实测过：不带这条腿只重开管理器 ⇒ 一定退回 `不支持`（所以别把"重开就亮"当成机制在自动补）。
   - 那条常驻补装开关（`touch /data/local/tmp/ksu_fd_keepalive`）**默认不铺，也建议别开**：往 zygote 里种驱动 fd，
     那个 zygote 就在 0.3~0.8 秒内收 SIGABRT 自杀、框架跟着重启一轮（6 条一手内核行，每条 abort 的 pid 都是刚被种过的那个；
     没开这把开关的 12 份日志里 0 条）。⇒ 牌子不会因此常驻（zygote 一直换），机器反而更不稳；自己铺了就要负责删，收尾件会删净它和它的日志。
   ★这一版不做"开机自动回来"，那需要每次开机都先有一个 shell 级执行者，属于持久化；整机重启一定失效。
铁律：不要 rmmod；不要在同一次开机里重跑提权；要重来先重启；牌子恢复腿不要连着敲（第 8 条那三条闸就是为这条设的，被拒不是坏）。
TXT

# ★★清单必须盖住**目录里每一个文件**：以前 `z6root.sh`(一键入口)、两个 APK、`教程.txt` 都是"复制/生成完就完了"，
#   一行都没进 MANIFEST ⇒ 入口脚本被换成旧版、或官方 Manager APK 被换包，清单自审照样"[OK] 逐条通过"
#   (它逐的是清单那 16 条)——这就是例 140 那族"复证名单比删除名单小"，只不过这次是**认证清单比交付物小**。
hf() { printf '%s %d %s
' "$1" "$(wc -c <"$OUT/$1")" "$(md5sum "$OUT/$1" | cut -c1-32)" >> "$OUT/MANIFEST"; }
hf z6root.sh
for a in "${APKS[@]}"; do hf "${a##*|}"; done
hf 教程.txt
echo "=== 3) 清单与目录对表（条数由脚本现数，不是我手写的） ==="
NMAN=$(grep -ac . "$OUT/MANIFEST")
NLINK=$(printf '%s\n' "${!P[@]}" | wc -l)
NGEN=${#GEN[@]}
NCOV=$((NLINK + 1 + NGEN + ${#APKS[@]} + 2))     # 载荷 + sustatic 重名 1 + 现算件 + 两个 APK + 入口件与教程
echo "  MANIFEST 行数=$NMAN；期望=$NCOV(载荷 $NLINK＋sustatic 重名 1＋现算件 $NGEN＋APK ${#APKS[@]}＋入口件与教程 2)"
[ "$NMAN" = "$NCOV" ] || { echo "  [x] 清单条数与映射不符 ⇒ 停"; exit 1; }
# ★反夹具(例 142 的"每条没做都要配一格该做时>0")：目录里**多一个没进清单的文件**，这一格必须红
MISSFILE="$OUT/z6root_反夹具_不在清单里.txt"; : > "$MISSFILE"
if [ "$(ls "$OUT" | grep -av '^MANIFEST$' | wc -l)" != "$NMAN" ]; then
    echo "  [OK] 覆盖性反夹具生效：目录文件数($(ls "$OUT" | grep -av '^MANIFEST$' | wc -l))≠清单条数($NMAN) ⇒ 下面自审会逐条比，多的那个不会被算到"
fi
rm -f "$MISSFILE"
MISS=""
while read D SZ MD5; do
    [ -f "$OUT/$D" ] || MISS="$MISS $D(缺文件)"
    A=$(wc -c <"$OUT/$D"); [ "$A" = "$SZ" ] || MISS="$MISS $D(字节 $A≠$SZ)"
    M=$(md5sum "$OUT/$D" | cut -c1-32); [ "$M" = "$MD5" ] || MISS="$MISS $D(md5 不符)"
done < "$OUT/MANIFEST"
[ -z "$MISS" ] || { echo "  [x] 清单自审失败:$MISS ⇒ 停"; exit 1; }
echo "  [OK] 逐条字节+md5 自审通过（清单=$OUT/MANIFEST）"

echo "=== 4) 静态闸：设备侧 mksh 语法（要 adb 在线） ==="
if adb get-state 2>/dev/null | grep -q device; then
    MSYS_NO_PATHCONV=1 adb push "$OUT/z6root.sh" /data/local/tmp/w431_probe.sh >/dev/null 2>&1
    R=$(MSYS_NO_PATHCONV=1 adb shell 'sh -n /data/local/tmp/w431_probe.sh; echo RC=$?' 2>&1 | tr -d '\r' | tail -1)
    MSYS_NO_PATHCONV=1 adb shell 'rm -f /data/local/tmp/w431_probe.sh' >/dev/null 2>&1
    case "$R" in *RC=0) echo "  [OK] z6root.sh 过设备 mksh";; *) echo "  [x] z6root.sh 设备语法不过 ⇒ $R"; exit 1;; esac
    B=$(MSYS_NO_PATHCONV=1 adb shell 'ls /data/local/tmp/w431_probe.sh 2>&1' | tr -d '\r' | tail -1)
    echo "  读回：探针件已删＝[$B]"
else
    echo "  [!] adb 不在线 ⇒ 这一格**没跑**，别当通过（例 80）"
fi

echo "=== 5) 打分发件 $OUT.zip（★#175：本机 7z 把中文条目名按 GBK 写、不设 ZIP 的 UTF-8 标志 ⇒ 一律用 python zipfile） ==="
ls -l "$OUT" | sed 's/^/  /'
echo "  z6root.sh md5=$(md5sum "$OUT/z6root.sh" | cut -c1-32)"
PYTHONUTF8=1 python - "$OUT" <<'PY'
import os, sys, zipfile
root = sys.argv[1]
zp = root + ".zip"
names = sorted(n for n in os.listdir(root) if os.path.isfile(os.path.join(root, n)))
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
    for n in names:
        z.write(os.path.join(root, n), root + "/" + n)
# ★读回复证（不写完就算过）：条目数、以及"带非 ASCII 名字却没设 UTF-8 标志(0x800)"必须为 0
zs = zipfile.ZipFile(zp)
infos = zs.infolist()
bad = [i.filename for i in infos if any(ord(c) > 127 for c in i.filename) and not (i.flag_bits & 0x800)]
print("  包内条目=%d 目录文件=%d 缺 UTF-8 标志的非 ASCII 条目=%d 字节=%d"
      % (len(infos), len(names), len(bad), os.path.getsize(zp)))
for i in infos:
    print("    %-28s %9d" % (i.filename, i.file_size))
sys.exit(0 if (len(infos) == len(names) and not bad) else 1)
PY
[ $? = 0 ] || { echo "  [x] 分发件读回复证不符 ⇒ 停"; exit 1; }
echo "  zip md5=$(md5sum "$OUT.zip" | cut -c1-32)（用户解压到 /sdcard/ 即可，整目录名要保留）"
echo "=== 没做什么：没开枪、没上机跑这个包。包能不能一键跑通＝需要一发认证（判据见本文件头部两条）。 ==="
