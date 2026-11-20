#!/system/bin/sh
# v21：在 susm 之前先跑 **ksuctl grant(=GRANT_ROOT)** —— 它只对当前进程执行
#      escape_with_root_profile()，完全不碰 sucompat(filp_open/改寄存器/嵌套 execveat)，
#      所以“连续四发死在 sumark 那一秒”这件事第一次有了一个能单独证伪的分支。
# v18：第一优先判据改成 **susm(不带 fd、不发 reboot)** —— 二十四/二十五发都是'体面关机'死的，
#      死点紧贴 drive_fd 的四次真 reboot()，所以先把这个变量从危险步骤里摘掉；
#      顺带 hook_mask 开成 0x3(setresuid+execve)，让'内核自己给换 uid 的进程打标'这条路可用。
# v17：加一段风暴溯源(取证 init 是不是源头 → 给 init 摘标 → 用 BN 计数看是否止住)。
# ksu_one_stage.sh v16 —— 一个 boot 只试一档（md §6.44~§6.46）
# v16：① 名单 key 换真包名 com.suw.manager(抗 prune)；② su 之前 sleep 3 再复测 granted
#      —— 第二十三发就是'加载成功但被 prune 删光'，两次询问之间 1 翻成 0。
# v15：把 printk 限流打开(burst/interval 是 /proc/sys knob，root 能写)，否则改道与调度器出口的
#      那些行全被 10 句/5 秒吃掉 ⇒ '到底走没走'看不出来(第二十二发就是这么含混过去的)。
# v14：先测 uid 10284(名单算数的那条路)，再测 2000(预言:死在 SD1)；判据里加 SD0/SD1/SD3/SD4/SD5 与 X8。
# v12→v13 的两处改动都来自第十九发的现场：
#  ① **活落盘太粗，等于没抓到**：第十九发最后一次 dmesg 落在 up=1325.048，
#     而脚本最后一行是 23:05:23(≈up1325.6)，之后 0.3~1.5s 内整机就没了 ⇒
#     `KSUBEAT SU0..SU4` 一条都没进文件。**改成 0.2s 一轮 + 每轮带 uptime 心跳**：
#       心跳停在哪、最后一条内核打印是什么，就把"panic(有 oops)"和"硬死锁(没打印，watchdog 咬)"分开。
#     为了跑得动，每轮只追加 dmesg 尾部 50000 字节(整份 2MB 每秒重读本身就是负载)。
#  ② **sysfs 闸门在这台机子上不存在**：`/sys/module/kernelsu/parameters/` 整目录都没有
#     (`cat` 连 `ksu_hook_mask` 都报 No such file)，⇒ v12 的 A/B/C 三档"改参数"**其实一次都没生效**，
#     第十九发跑的已经是**全开路径**(`escape_with_root_profile()` 真执行了)。
#     ⇒ 这一发不再依赖 sysfs：闸门只用 insmod 参数，一个 boot 一个组合。
#  ③ 组合的选择：`allow_shell` 默认**不传**(§6.42：传了以后 uid 2000 永远走 default profile)，
#     名单里两条 seed 已在第十九发被内核接受(`prune uid: 2000/10284`) ⇒ 这次就是
#     "uid 2000 用自己那条 profile(域 u:r:shell:s0) + 全开 su 路径"这一发。
# 老规矩：永不 rmmod、永不 `dmesg -c`、每步 sync、收尾再落整份。
S=$(cat /data/local/tmp/ksu_stage.txt 2>/dev/null)
[ -n "$S" ] || S=7
ARGS=$(cat /data/local/tmp/ksu_args.txt 2>/dev/null)
EXTRA=""
[ -f /data/local/tmp/ksu_allow_shell ] && EXTRA="allow_shell=1"
OUT=/data/local/tmp/ksu_stage.log
KO=/data/local/tmp/kernelsu.ko
CTL=/data/local/tmp/ksuctl
ALLOW=/data/adb/ksu/.allowlist
FULL=/data/local/tmp/dmesg_full.txt
LIVE=/data/local/tmp/dmesg.live
DOM=${DOM:-u:r:shell:s0}
DM='tilayout|uaccessprobe|KSUSTEP|KSUBEAT|dev_syms|apfmt|load_allow|prune uid|allowlist version|dispatcher|sys_call_table|patch syscall|reboot kprobe|hook_manager|register_|umount|sucompat|setuid|tp_marker|manage_mark|sys_execve su|Unknown symbol|disagrees|Unable to handle|BUG|Oops|Internal error|Call trace|CFI|watchdog|panic'
: > "$OUT"; : > "$FULL"; : > "$LIVE"
exec >> "$OUT" 2>&1
chmod 666 "$OUT" "$FULL" "$LIVE" 2>/dev/null
log() { echo "[$(date +%H:%M:%S)] $*"; sync; }
upt() { cut -d' ' -f1 /proc/uptime; }
snap() { dmesg > "$FULL" 2>/dev/null; dmesg 2>/dev/null | tail -c 50000 >> "$LIVE" 2>/dev/null; sync; }

log "=== 起点 stage=$S args=[$ARGS] extra=[$EXTRA] dom=$DOM up=$(upt) ==="
log "id=$(id -u) enforce=$(getenforce) uname=$(uname -s)"
log "ko md5=$(md5sum $KO | awk '{print $1}') ksuctl md5=$(md5sum $CTL | awk '{print $1}')"

log "----- ① 名单：两条显式 profile(2000/10284)，域=$DOM -----"
mkdir -p /data/adb/ksu
# ★★key 必须写**真包名**：ksu_prune_allowlist() 会拿 package 名去校验 uid，
#   第二十三发用的假 key(app_uid/shell_uid) 在 insmod 后 0.27s 就被整条删掉，
#   之后 granted 一律翻成 0 ⇒ su 分支在 SD1 静默放弃(见 §6.46)。
"$CTL" mkallow /data/local/tmp/a10284.bin 10284 com.suw.manager "$DOM"
cp /data/local/tmp/a10284.bin "$ALLOW"
chmod 644 "$ALLOW"; chmod 711 /data/adb /data/adb/ksu 2>/dev/null
cp /data/local/tmp/ksud /data/adb/ksud; chmod 755 /data/adb/ksud
log "allow=$(wc -c < $ALLOW) 字节(单条目应当 792) ksud=$(ls -l /data/adb/ksud 2>&1)"
echo 8 4 1 8 > /proc/sys/kernel/printk 2>/dev/null
log "----- 本 boot 只发这一档 -----"
log "----- ①′ 关掉 printk 限流：F2/E1/E2/E3/SD3/SD5 全是 pr_*_ratelimited，"
log "      而本机默认 burst=10/interval=5s ⇒ 第二十二发恰好 F2=10 条就断了线，"
log "      于是'15723 到底有没有被改道、调度器走了哪条出口'全部被限流吃掉。"
log "      ★这两个是 /proc/sys 的 knob，root 能写(不同于 /sys/module/*/parameters 不存在)"
cat /proc/sys/kernel/printk_ratelimit /proc/sys/kernel/printk_ratelimit_ratelimit 2>&1 | tr '
' ' '; echo " <- 改之前"
echo 100000 > /proc/sys/kernel/printk_ratelimit 2>/dev/null
echo 0 > /proc/sys/kernel/printk_ratelimit_ratelimit 2>/dev/null
log "      改之后 = $(cat /proc/sys/kernel/printk_ratelimit 2>&1)/$(cat /proc/sys/kernel/printk_ratelimit_ratelimit 2>&1) (burst/interval)"
sync

log "----- ② 起活落盘(0.2s 一轮 + 心跳) -----"
# ★v23 换流式读法：`dmesg` 每次要把整份环形缓冲(本机 2MB，还被厂商触摸屏日志刷爆)拷一遍，
#   0.05s 的循环跟不上 ⇒ 第二十九/三十发的落盘点落后死点 0.5 秒以上，SD/SU 那几行就是这么丢的。
#   /proc/kmsg 是**阻塞式逐条**读，dd 每读到一个块就 write 一次(无用户态缓冲) ⇒ 崩溃前最多
#   丢十几行，而且几乎不花 CPU。root 才能读(本机 root 窗口里 klogctl 已实测可用)。
( while :; do
    echo "--- HB up=$(upt) ---" >> "$LIVE" 2>/dev/null
    # ★count=1：每来一条就 write 一次。用 16 会让 dd 一直阻塞在"凑满 16 块"，
    #   消息稀疏时整条信道就僵住(第三十二发因此比死点早哑 13.7 秒)。
    dd if=/proc/kmsg bs=512 count=1 2>/dev/null >> "$LIVE"
    sync
  done ) &
LV=$!
log "live dumper pid=$LV"

insmod "$KO" ksu_stage=$S $EXTRA $ARGS
RC=$?
log "insmod rc=$RC up=$(upt) lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')]"
log "sysfs 参数目录实况: $(ls /sys/module/kernelsu/ 2>&1 | tr '\n' ' ')"
log "===== 第一判据：sys_call_table 那笔写 ====="
grep -E 'KSUBEAT (P1|P2|P3|P4|A )|patch syscall|registered syscall hook|sys_enter tracepoint|mark-running' "$LIVE" | tail -14
log "符号/布局: $(grep -E 'dev_syms|apfmt|tilayout' "$LIVE" | tail -2 | tr '\n' '|')"
sync

if [ "$RC" = 0 ]; then
    log "===== ★★零、上一次(第二十八发)到底是怎么死的：看厂商 fuel-gauge 的重启计数 ====="
    dmesg 2>/dev/null | grep -E 'wdt_reset_count|partial_reset|full_reset' | head -3
    log "===== ★★一、只测 escape：ksuctl grant(=KSU_IOCTL_GRANT_ROOT) ====="
    log "      do_grant_root 不看 arg，直接对**当前进程**跑 escape_with_root_profile()，"
    log "      perm=allowed_for_su ⇒ 子进程先把 ruid 降到 10284(名单里)再发这个 ioctl。"
    log "      这条路**不经过 sucompat**(没有 filp_open/改寄存器/嵌套 execveat)"
    log "      ⇒ 死在这一步 = 凶手单独在 escape 里面；活了且 uid 变 0 = escape 是好的。"
    "$CTL" grant 10284
    log "grant 跑完，退出码=$? up=$(upt)"
    dmesg 2>/dev/null | grep -E 'allow root for|KSUBEAT (X[0-9A-C]|SU[0-9])|Failed to cache|sulog' | tail -18
    sync
    log "===== ★★第一优先判据：**不带 fd、不发 reboot** 的 su 触发器 susm (up=$(upt)) ====="
    log "      原理：本树 __NR_setresuid=147 正是 ksu_hook_mask bit0 挂的号 ⇒"
    log "      进程 setresuid 到名单里的 uid，**内核自己**给它打标(=真实 app 的形状)，随后 execve su 被改道。"
    log "      这一发把 hook_mask 开成 0x3(setresuid+execve)，所以 bit0 这次是挂上的。"
    log "      ★判读：errno=2 ⇒ 没被拦截；38 ⇒ 被调度器判死；打出 uid=0 ⇒ 成功拿到内核授权"
    log "      ★先把**脚本自己这个 sh** 的标摘掉：第二十六发里它一直是带标的(继承链上带的)，"
    log "      于是每条 fork/exec 都过调度器(一小时 297 万次 handler、583 条 BN)，"
    log "      既盖住判据也可能把机器拖进看门狗。摘掉后只有 susm 自己(靠 setresuid 让内核打标)在链路上。"
    "$CTL" mark unmark "$$"
    log "摘标后 mark get \$\$ = $("$CTL" mark get "$$" | tail -1)"
    /data/local/tmp/susm 10284 "id"
    log "susm 跑完，退出码=$? up=$(upt)"
    dmesg 2>/dev/null | tail -c 50000 >> "$LIVE"
    log "susm 的内核侧回响:"
    dmesg 2>/dev/null | grep -E 'handle_setresuid|marked task|KSUBEAT (F|F2|BN|SD[0-9]|SU[0-9]|X[0-9A-C])' | tail -24
    sync
    log "===== 控制面 ====="
    "$CTL" fmt
    "$CTL" info
    "$CTL" allowlist
    "$CTL" granted 10284
    "$CTL" granted 2000
    log '===== ★★风暴溯源：标是从谁身上传下来的？(第二十四发有 100+ 个 uid 0 的 sh 在被改道) ====='
    "$CTL" mark get 1
    "$CTL" mark get "$$"
    log '改道过的 pid 清单:'
    dmesg 2>/dev/null | grep -oE 'BN dispatcher entered.*pid=[0-9]+' | grep -oE '[0-9]+$' | sort -u | head -12
    "$CTL" mark unmark 1
    log '给 init 摘标后: mark get 1 ='"$("$CTL" mark get 1 | tail -1)"
    log '摘之前 BN 条数='"$(dmesg 2>/dev/null | grep -c 'KSUBEAT BN')"
    sleep 2
    dmesg 2>/dev/null | grep -oE 'BN dispatcher entered.*pid=[0-9]+' | grep -oE '[0-9]+$' | sort -u > /data/local/tmp/bn_before.txt
    log '摘之后 BN 条数='"$(dmesg 2>/dev/null | grep -c 'KSUBEAT BN')"
    log '摘之后新改道过的 pid(与之前对比用)已存 /data/local/tmp/bn_before.txt'
    log "===== ★prune 探针：等 3s 让包观察者跑完，再问一次 granted ====="
    sleep 3
    "$CTL" granted 10284
    log "prune 条数=$(dmesg 2>/dev/null | grep -c 'prune uid:') 内核侧加载/裁剪证据:"
    dmesg 2>/dev/null | grep -E 'load_allow_uid|set root profile|uid :|prune uid|Crowning' | tail -8
    log "===== 判据计数(活落盘) ====="
    for k in 'KSUBEAT SD0' 'KSUBEAT SD1' 'KSUBEAT BN' 'KSUBEAT SD3' 'KSUBEAT SD4' 'KSUBEAT SD5' 'KSUBEAT F sys_enter' 'KSUBEAT F2' 'KSUBEAT B ' 'KSUBEAT G mark' 'KSUBEAT C1' 'KSUBEAT SU0' 'KSUBEAT SU1' 'KSUBEAT SU2' 'KSUBEAT SU3' 'KSUBEAT SU4' 'KSUBEAT X8' 'sys_execve su found' 'SHIM uid' 'Unable to handle' 'Call trace'; do
        printf '  %s =' "$k"; grep -c "$k" "$LIVE" 2>/dev/null
    done
    sync
    log "===== ★第二十七发定案：setresuid 这条路**结构性不可用**——bit0 是 syscall hook，"
    log "      只有**已经带标**的进程才会被改道到它 ⇒ 没标进程 setresuid 根本不会被看到(实测 uid=10284 仍 ENOENT)。"
    log "      ⇒ 打标只能走 MANAGE_MARK(要 fd ⇒ 走 reboot 传输)，所以 sumark 是唯一入口。"
    log "      ★这一发把 insmod 参数写成 ksu_no_escape=1：sucompat 照做"改道+取 fd+filp_open+重写寄存器+嵌套 execveat"，"
    log "      但**跳过 escape_with_root_profile()** ⇒ 如果活了并打出 SHIM uid=10284，"
    log "      就证明整条拦截/重写链是通的，凶手被关在 escape 里面。"
    log "===== ★★passfd：把驱动 fd 用 SCM_RIGHTS 递给一个已降权进程，由它自己 GRANT_ROOT ====="
    log "      为什么必须要这条：真 app 发不出 reboot 魔数(app 域 reboot=SIGSYS，且 5.4 没有
      seccomp action cache 可放开) ⇒ fd 只能由外部递给它。supercall 的权限判在 ioctl 当时
      (按 current_uid)，所以传 fd 是合法的。"
    "$CTL" passfd 10284
    log "passfd rc=$? ⇒ 看子进程那行 uid 是否从 10284 变 0"
    sync
    log "===== ★★step5（本发主判据）：一个 syscall hook 都不挂(hook_mask=0x0)，纯靠 supercall 拿 root ====="
    log "      流程 = 已降权进程(ruid=10284，模拟 app)自己发 reboot 魔数拿 fd → GRANT_ROOT。"
    log "      意义：suw APK 的 JNI 直接走这条路就不需要 /system/bin/su，也就不碰现在必炸机器的 execve 改写。"
    "$CTL" step 5 10284
    log "step5 rc=$? ⇒ 看它打印的 uid 是否从 10284 变成 0"
    sync
    log "===== ★★把 sumark 拆成三小步(§6.51③)：哪一步之后 HB 停住，凶手就在哪一步 ====="
    log "--- step1: 只 drive_fd + 打标 + sleep(不动 uid、不 execve) up=$(upt)"
    "$CTL" step 1 10284
    log "step1 rc=$? 最末 HB: $(tail -1 "$LIVE" | cut -c1-40)"
    sync
    log "--- step2: 打标 + setresuid(10284×3) + sleep(看 else 分支会不会反向摘标) up=$(upt)"
    "$CTL" step 2 10284
    log "step2 rc=$? 最末 HB: $(tail -1 "$LIVE" | cut -c1-40)"
    sync
    log "--- step4(对照，放在 step3 之前)：打标 + 降 uid + execve 一个**不是 su** 的路径 up=$(upt)"
    "$CTL" step 4 10284
    log "step4 rc=$? 最末 HB: $(tail -1 "$LIVE" | cut -c1-40)"
    sync
    log "  ★读法：step4 活 + step3 死 ⇒ 死在'su 命中之后'；step4 也死 ⇒ 与 su 分支无关"
    log "--- step3: 上面全做 + execve(/system/bin/su) up=$(upt)"
    "$CTL" step 3 10284 "id"
    log "step3 rc=$? 最末 HB: $(tail -1 "$LIVE" | cut -c1-40)"
    log "再落一次整份 dmesg(把 step 之后的内核行也留下来)"
    dmesg > "$FULL" 2>/dev/null
    dmesg 2>/dev/null | tail -c 50000 >> "$LIVE"
    sync
    log "SU 与 su 相关的全部内核行:"
    grep -E 'KSUBEAT (SU|G|B|C1|D)|sys_execve su|sucompat|escape|Unable|Call trace|BUG|Internal error' "$LIVE" | tail -40
    kill $LV 2>/dev/null
    log "===== 不 rmmod ====="
fi
log "===== 收尾：整份 dmesg (up=$(upt)) ====="
if [ -f /data/local/tmp/ksu_cleanup ]; then
    log "===== ★★不留持久化：删掉 KSU 侧全部落地文件(标记文件 ksu_cleanup 存在才做) ====="
    rm -rf /data/adb/ksu /data/adb/ksud
    rm -f /data/local/tmp/kernelsu.ko /data/local/tmp/susm /data/local/tmp/a10284.bin \
          /data/local/tmp/allow.bin /data/local/tmp/ksu_args.txt /data/local/tmp/ksu_stage.txt \
          /data/local/tmp/ksu_post.sh /data/local/tmp/dmesg.live /data/local/tmp/ksu_allow_shell \
          /data/local/tmp/ksu_cleanup /data/local/tmp/bn_before.txt
    log "删完(ksu_stage.log/ksuctl 故意留着：前者是判据、后者还要读判据):"
    log "  /data/adb=[$(ls -l /data/adb 2>&1 | tr '\n' ' ')]"
    log "  tmp 残留=[$(ls /data/local/tmp 2>/dev/null | grep -iE 'kernelsu|ksu_|susm|allow.bin' | tr '\n' ' ')]"
    log "  模块还在(本 boot 内): lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')] ⇒ 重启即消失"
    sync
fi
dmesg > "$FULL" 2>/dev/null
dmesg 2>/dev/null | tail -c 200000 >> "$LIVE" 2>/dev/null
sync
grep -E "$DM" "$FULL" | tail -70
log "=== 结束(能到这行=本 boot 活下来了) ==="
chmod 666 "$OUT" "$FULL" "$LIVE" 2>/dev/null
sync
