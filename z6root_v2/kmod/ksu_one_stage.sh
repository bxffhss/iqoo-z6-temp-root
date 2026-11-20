#!/system/bin/sh
# ksu_one_stage.sh v30 —— v29.1 + **信号探针提前**(md §6.65)：
#   第四十七发的教训：窗口从 insmod 起只有 ~3.5 分钟，而 ftrace 探针当时挂在最末尾的
#   "模块战线 runner"里 ⇒ 机器在它跑到之前就复位了，等于没挂。
#   ⇒ 现在：判据④之前挂 signal_generate/signal_deliver + stacktrace，拿到 armed 报告后
#     立刻落盘；模块战线仍在最后(它已经复现过两次，掉一发不心疼)。
#   顺带：外部证据那段等的 pattern 是"子进程 pid="，而 v30 的 JNI 黑匣子印的是
#   "子进程 5573 被信号 9 杀死" ⇒ 永远等不到，白烧 90s 窗口，一并修。
# ksu_one_stage.sh v29 —— v28 + 窗口内模块 runner(md §6.62)；此前修正：
#   ① 判据①(insmod 一返回就 grep 活落盘)本机**总是空**：dumper 是 dd 逐条异步写，
#      那些行还没落文件 ⇒ 第三十六发里 P1/P2/A readback 整段没印出来，而事后 dmesg 全在。
#      ⇒ 现在先 sleep 2 再读，仍空就从 dmesg 兜一次(同一判据，换来源)。
#   ② 自己造的 execve 风暴：catch_root_thread 每线程起 3 个 grep、外层每 3s 一轮，
#      再加 PC 侧驱动器同样扫法 25 轮 ⇒ 数千次 fork，而 rc27 的 KSUBEAT F 对**每次 execve**
#      都打一行；第三十六发脚本跑完 ~1.5 分钟后机器复位(当时正在跑那些扫描)。
#      ⇒ 现在一条 glob + 一次 grep，后处理降到每 4 轮(≈12s)，PC 侧只扫 3 轮。
# ksu_one_stage.sh v27 —— 一个 boot 只试一档；这一档只剩一个目标(md §6.59)：
#   让**真 app**(com.suw.manager, uid 10284, untrusted_app 域)从 shell 域 agent 手里接过
#   KernelSU 的驱动 fd，然后自己 ioctl(GRANT_ROOT) 变成 uid 0
#   ⇒ 这就是"最后我只需要使用 KernelSU 授权"的那一步。
# v26 及之前：内核侧 escape 已复现 4 次(§6.53~§6.56)；`execve(/system/bin/su)` 那一支判死
#   (§6.57 = 瞬间静默复位)，所以这一发**不再跑 susm/step1..5** —— 把整个窗口留给 app 端到端。
#   上一版全文留在 ksu_one_stage_v26.sh，别在这儿考古。
# 保留的每一段都是判据，不是装饰：
#   ① sys_call_table 那笔写的回执(P1/P2/P4 + A readback)
#   ② 正对照 `ksuctl grant 10284`：内核侧 escape 仍然好 ⇒ 若 app 失败而它成功，问题在用户态链路
#   ③ 负对照由 **PC 侧**跑 `shd --ksugrant`(uid 2000)：名单外的 uid 光有 fd 也必须被拒
#   ④ 外部一手证据：app 线程授权成功后**驻留 25s**(suwksu_jni.c 的 PARK_SEC)，这期间本脚本从
#      /proc/<app_pid>/task/*/status 抓 `Uid 0` —— 看见才算"内核真改了 cred"，而不是 app 自报
#   ⑤ agent 侧确认 `shd --ksufd`：递出去的 fd 由**第二个进程** ioctl 得动(GET_INFO=always_allow)
#   ⑥ 活落盘(每条一写 + 心跳)：这一支历史上出过"瞬间静默复位"，不落盘等于没抓到
# ★SELinux 前提(2026-10-01 预检实测)：enforcing 下 untrusted_app connectto shell 域的 abstract
#   unix = EACCES(预检就是这个)，而 punch 后本 boot 是 **Permissive**(历发起点行都印着
#   enforce=Permissive) ⇒ app→@suwshd 在这一发里连得上；若起点行是 Enforcing，
#   后面 app 侧 connect 失败**不是 KSU 的锅**，是 SELinux 没让连。
# 老规矩：永不 rmmod、永不 `dmesg -c`、每步 sync、收尾再落整份、有 ksu_cleanup 标记才做清理。
S=$(cat /data/local/tmp/ksu_stage.txt 2>/dev/null)
[ -n "$S" ] || S=7
ARGS=$(cat /data/local/tmp/ksu_args.txt 2>/dev/null)
EXTRA=""
[ -f /data/local/tmp/ksu_allow_shell ] && EXTRA="allow_shell=1"
OUT=/data/local/tmp/ksu_stage.log
KO=/data/local/tmp/kernelsu.ko
CTL=/data/local/tmp/ksuctl
SHD=/data/local/tmp/shd
ALLOW=/data/adb/ksu/.allowlist
FULL=/data/local/tmp/dmesg_full.txt
LIVE=/data/local/tmp/dmesg.live
# ★uid 从 push 阶段探测来的文件读(卸载重装就换号：10284→10308 差点把整发判据全打空)
SUWID=$(cut -d" " -f1 /data/local/tmp/ksa_uids.txt 2>/dev/null)
[ -n "$SUWID" ] || SUWID=10284
MGRID=$(cut -d" " -f2 /data/local/tmp/ksa_uids.txt 2>/dev/null)
[ -n "$MGRID" ] || MGRID=0
PKG=com.suw.manager
# ★★§6.313⑦（格 X 的仪器开关）：主那条记录的 key(包名字符串)以前是**写死 $PKG** 的——
#   我只按配置改 uid，key 从来不跟着走 ⇒ 第 151 发那格其实是"uid=10667 却写着 com.suw.manager"
#   这种**名字与 uid 不匹配**的形状（例 117：模板里"我没打算改"的那个字段）。
#   现在：设备侧存在 /data/local/tmp/ksu_ap_key(一行=要用的包名) ⇒ 用它覆盖；**默认没有这个文件 ⇒ 逐字保持老行为**。
#   生效证人＝下面紧挨着打的 `AP_KEY 生效证人` 那行 ＋ ksuctl 自己那行 `wrote … key=…` ＋ 落盘件偏移 4..67 的 hexdump。
APKEY=$(head -1 /data/local/tmp/ksu_ap_key 2>/dev/null | tr -d '\r\n')
[ -n "$APKEY" ] || APKEY=$PKG
APP_REPORT=/sdcard/Android/data/$PKG/files/ksu_grant.txt
APP_COPY=/data/local/tmp/app_ksu.txt
# ★★§6.350/#117：形状词"名单那条记录的域=X"以前**没有生产者**——下面这行读的是**设备侧环境变量** DOM，
#   而整条工具链里没有任何一条腿会设它 ⇒ 除了我手敲(例 116/175 那一族：静默换形状、不报错)，永远取默认。
#   现在：设备侧存在 /data/local/tmp/ksu_dom(一行=要用的 SELinux 上下文串) ⇒ 用它覆盖；
#   **没有这个文件／文件为空 ⇒ 逐字保持老行为(u:r:shell:s0，交付形状)**。
#   生效证人三段：①下面「★DOM 生效证人」那行(我这边打算用什么) ②ksuctl 自己打的 `profile: … domain=`
#   (写进 .bin 的是什么) ③事后 root 腿在提权壳里 `cat /proc/self/attr/current`(内核真给的是什么)。
#   ②③缺一不可——只打①就是"入口证人当末端证人"(例 118)。
DOMF=$(head -1 /data/local/tmp/ksu_dom 2>/dev/null | tr -d '\r\n')
DOM=${DOMF:-${DOM:-u:r:shell:s0}}
# ★★§6.353/#117 下一格的前置：`DOM` 一整窗只有一个值 ⇒ 两个 app 的原域串不同就没法同时"各自留在自己域"
#   (第 26 发一手：`mkallow` 把所有条目的 domain 都写成同一个 `$DOM`)。
#   现在加一张**按 uid 的映射表**：设备侧 `/data/local/tmp/ksu_dom_map`，一行=`<uid> <上下文串>`
#   (uid 只有数字、串里不许有空格 ⇒ 两字段用第一个空格切开不会歧义)。
#   ★默认没有这个文件 ⇒ `dom_for` 就是原样回吐 `$DOM` ⇒ **交付形状与第 26 发之前逐字相同**。
DOMMAP=/data/local/tmp/ksu_dom_map
dom_for() { # $1=uid ⇒ 该条记录要用的域；映射里没有就退回 $DOM
    _d=$(grep -a "^$1 " "$DOMMAP" 2>/dev/null | head -1 | cut -d" " -f2- | tr -d '\r\n')
    if [ -n "$_d" ]; then echo "$_d"; else echo "$DOM"; fi
}
# ==== DOM 段结束（专属自测 kmod/_tmp_selftest_rdst/run_dom.sh / run_dommap.sh 就切到这一行为止；
#      ★这一段整体是"没有开关文件 ⇒ 逐字等于老行为"，别往里加会改变默认值的动作）====
WAIT_LOOPS=${WAIT_LOOPS:-240}          # 240 * 3s = 12 分钟上限，等不到也照常收尾
DM='KILLSCAN|tilayout|uaccessprobe|KSUSTEP|KSUBEAT|dev_syms|apfmt|load_allow|prune uid|allowlist version|dispatcher|sys_call_table|patch syscall|reboot kprobe|hook_manager|register_|umount|sucompat|setuid|tp_marker|manage_mark|sys_execve su|Unknown symbol|disagrees|Unable to handle|BUG|Oops|Internal error|Call trace|CFI|watchdog|panic'
: > "$OUT"; : > "$FULL"; : > "$LIVE"
exec >> "$OUT" 2>&1
chmod 666 "$OUT" "$FULL" "$LIVE" 2>/dev/null
log() { echo "[$(date +%H:%M:%S)] $*"; sync; }
upt() { cut -d' ' -f1 /proc/uptime; }

FT=/sys/kernel/tracing
[ -d "$FT/events/signal" ] || FT=/sys/kernel/debug/tracing

# ftrace_arm —— 把"谁在杀我的 root 子进程"这个问题交给内核自己回答。
#   signal_generate 记录里的 comm/pid 是**发送方**(事件在发送方上下文里打)，
#   signal_deliver 里的才是接收方 ⇒ 两个都开：前者给"谁发的"，后者给
#   "什么时候真落到 suwrootd 头上、si_code 是多少"。options/stacktrace 让每个事件
#   带一段内核栈 ⇒ 栈里那个函数名就是凶手(厂商反 root？memcg？seccomp？)。
# v32 的教训(第四十九发)：这一版之前 arm 里写了 `: > set_ftrace_filter`，而那个文件在本机
#   根本不存在(没编 CONFIG_FUNCTION_TRACER)⇒ **`:` 是 POSIX 特殊内建，它的重定向失败会让
#   非交互 shell 直接退出** ⇒ 子 shell 当场死，最后一行 `echo 1 > tracing_on` 没跑 ⇒
#   trace 里 0 条记录(444 字节全是表头)。⇒ 现在：①不碰那个文件；②tracing_on 放最后但
#   每条都可能失败的写都带 2>/dev/null 且不用 `:`；③挂完立刻回读 tracing_on 自证。
#
# ★这一发的正题：force_sig 的 **x30 = 它的返回地址**。上一发的 options/stacktrace 里
#   force_sig 之上两格只解析成 `__cfi_check`(KCFI 的跳转表：return address 落在跳转表里，
#   按 kallsyms 查就撞到那个巨型符号头上)⇒ 符号名查不出来。LR 是一个硬数值，谁也糊不了：
#   同一发里把 /proc/kallsyms 也 dump 下来，回 PC 上按地址区间精确算出是哪个函数。
ftrace_arm() {
    if [ ! -d "$FT/events/signal" ]; then
        log "  ftrace: 没有 $FT/events/signal ⇒ 这一发不带信号探针"
        return
    fi
    (
        cd "$FT" || exit
        echo 6144 > buffer_size_kb 2>/dev/null
        echo "sig == 9" > events/signal/signal_generate/filter 2>/dev/null
        echo "comm == \"suwrootd\" || comm == \"com.suw.manager\"" > events/signal/signal_deliver/filter 2>/dev/null
        echo 1 > options/stacktrace 2>/dev/null
        echo 1 > events/signal/signal_generate/enable 2>/dev/null
        echo 1 > events/signal/signal_deliver/enable 2>/dev/null
        if [ -w kprobe_events ]; then
            # ★写法必须是 p:GRP/EV。上一发只写了一个名字(`p:kpfs force_sig`)，内核把它当成
            #   "kprobes 组里一个叫 kpfs 的事件"(cat kprobe_events 印的就是 p:kprobes/kpfs)，
            #   而我 enable 的是 events/kpfs/force_sig/enable ⇒ 探针挂上了却没开 ⇒ 零命中。
            echo "p:kpf/fs force_sig sig=%x0 lr=%x30 w0=-4(%x30):x32 w1=-8(%x30):x32 w2=-12(%x30):x32 w3=+4(%x30):x32" > kprobe_events 2>/dev/null
            echo "p:kpf/fi force_sig_info_to_task sig=%x0 lr=%x30" >> kprobe_events 2>/dev/null
            echo "p:kpf/bf arm64_force_sig_fault sig=%x0 lr=%x30" >> kprobe_events 2>/dev/null
            echo "p:kpf/fj force_signal_inject sig=%x0 lr=%x30" >> kprobe_events 2>/dev/null
            echo "p:kpf/die die" >> kprobe_events 2>/dev/null
            echo "p:kpf/fps fpsimd_save" >> kprobe_events 2>/dev/null
            echo "p:kpf/safe safesetid_task_fix_setuid" >> kprobe_events 2>/dev/null
            # 受害者那一次 openat 由内核侧自证(只看 suwrootd，不然全系统 openat 会把缓冲冲掉)
            echo "p:kpf/oa __arm64_sys_openat" >> kprobe_events 2>/dev/null
            echo "comm == \"suwrootd\"" > events/kpf/oa/filter 2>/dev/null
            # ===== v50：exec 路径的返回值探针，★逐条注册并把失败回执打出来 =====
            #   v49 的教训：整批 `echo ... >> kprobe_events 2>/dev/null` 把失败全吞了，
            #   结果"零命中"到底是"没注册"还是"没走到"分不清(上一发就是这样白烧的)。
            for ev in "r:kpf/xv __arm64_sys_execve ret=\$retval:x32"                       "r:kpf/xbc do_execveat_common ret=\$retval:x32"                       "r:kpf/sbc security_bprm_check ret=\$retval:x32"                       "r:kpf/sbh search_binary_handler ret=\$retval:x32"                       "r:kpf/bcf bprm_creds_from_file ret=\$retval:x32"; do
                NAME=$(echo "$ev" | cut -d/ -f2 | cut -d" " -f1)
                ERR=$(echo "$ev" >> kprobe_events 2>&1)
                if [ -d "events/kpf/$NAME" ]; then
                    echo "comm == \"suwrootd\" || comm == \"KSU_EXEC\"" > "events/kpf/$NAME/filter" 2>/dev/null
                    log "  探针 $NAME 注册 OK"
                else
                    log "  探针 $NAME 注册失败: $ERR"
                fi
            done
            log "  kprobe_events 全量: $(cat kprobe_events 2>&1 | xargs echo)"
            echo 1 > events/kpf/enable 2>/dev/null
        fi
        # suwrootd 的完整 syscall 序列：证明"死在 openat 里"不是 app 自报的口径
        echo "comm == \"suwrootd\"" > events/raw_syscall/sys_enter/filter 2>/dev/null
        echo 1 > events/raw_syscall/sys_enter/enable 2>/dev/null
        echo 1 > tracing_on
    )
    log "  挂上: gen=[$(cat $FT/events/signal/signal_generate/filter 2>&1 | tr '\n' ' ')] kp=[$(cat $FT/kprobe_events 2>&1 | tr '\n' ' ' | cut -c1-150)]"
    log "       on=[$(cat $FT/tracing_on 2>&1)] kpf组=[$(cat $FT/events/kpf/enable 2>&1)] raw_syscall=[$(cat $FT/events/raw_syscall/sys_enter/enable 2>&1)] stacktrace=[$(cat $FT/options/stacktrace 2>&1)] buf=$(cat $FT/buffer_size_kb 2>&1)K"
    if [ ! -e /data/local/tmp/ksu_quiet ]; then echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null; fi
    # ★kptr_restrict=2 时连 root 读 /proc/kallsyms 都是一堆 0(第五十发的 kallsyms 全零)
    #   ⇒ 先关它，否则 kprobe 抓到的 LR 数值回来没人认得。
    echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null
    cat /proc/sys/kernel/tainted > /data/local/tmp/ksu_tainted_before.txt 2>/dev/null
    cp /proc/kallsyms /data/local/tmp/ksu_kallsyms.txt 2>/dev/null
    chmod 666 /data/local/tmp/ksu_kallsyms.txt /data/local/tmp/ksu_tainted_before.txt 2>/dev/null
    sync
    log "  kallsyms=$(wc -l < /data/local/tmp/ksu_kallsyms.txt 2>/dev/null) 行 ratelimit=[$(cat /proc/sys/kernel/printk_ratelimit 2>&1)] tainted前=[$(cat /data/local/tmp/ksu_tainted_before.txt 2>/dev/null)] kptr=[$(cat /proc/sys/kernel/kptr_restrict 2>&1)]"
    touch /data/local/tmp/ksu_ftrace_armed
    chmod 666 /data/local/tmp/ksu_ftrace_armed 2>/dev/null
}

# ftrace_dump —— 立刻落盘：这个 boot 随时可能没，trace 只在内存里等于没有。
ftrace_dump() {
    (
        cd "$FT" 2>/dev/null || exit
        cat trace > /data/local/tmp/ksu_ftrace.txt
        echo 0 > tracing_on
        echo 0 > events/signal/signal_generate/enable
        echo 0 > events/signal/signal_deliver/enable
        echo 0 > events/kpf/enable 2>/dev/null
        echo 0 > events/raw_syscall/sys_enter/enable 2>/dev/null
        echo > kprobe_events 2>/dev/null
        echo 0 > options/stacktrace 2>/dev/null
    )
    chmod 666 /data/local/tmp/ksu_ftrace.txt 2>/dev/null
    log "  ftrace 落盘 $(wc -c < /data/local/tmp/ksu_ftrace.txt 2>/dev/null) 字节 / $(wc -l < /data/local/tmp/ksu_ftrace.txt 2>/dev/null) 行"
    log "  ----- SIGKILL 生成点(发送方 comm/pid + 内核栈) -----"
    grep -A14 -E 'signal_generate.*sig=9' /data/local/tmp/ksu_ftrace.txt 2>/dev/null | head -70 | sed 's/^/    /'
    log "  ----- kprobe 命中(★lr= 是自定义字段，只有我们那几个探针里有) -----"
    grep -E 'lr=0x|lr=-?[0-9]' /data/local/tmp/ksu_ftrace.txt 2>/dev/null | head -25 | sed 's/^/    /'
    log "  ----- suwrootd 的 syscall 序列(raw_syscall/kpf-oa，内核侧自证死在哪个调用里) -----"
    grep -i 'suwrootd' /data/local/tmp/ksu_ftrace.txt 2>/dev/null | grep -E 'sys_enter|oa:' | head -30 | sed 's/^/    /'
    log "  tainted 后=[$(cat /proc/sys/kernel/tainted 2>&1)] (前=$(cat /data/local/tmp/ksu_tainted_before.txt 2>/dev/null)；TAINT_DIE=bit7⇒+128, TAINT_WARN=bit9⇒+512)"
    log "  ----- 投递到 suwrootd / app 的那几行 -----"
    grep -E 'signal_deliver' /data/local/tmp/ksu_ftrace.txt 2>/dev/null | head -20 | sed 's/^/    /'
    sync
}

# 外部证据：把 app 进程里所有 uid=0 的线程挖出来。★必须逐线程读 —— commit_creds 只改
# current 线程(patch_ksu_escape_steps.py 的 X7/X8 就是单线程语义)，读 /proc/<pid>/status
# 只看得到线程组 leader(还是 10284)，那会把成功读成失败。
# ★★扫法(第三十六发的教训)：以前这里对每个线程起 3 个 grep，外层还每 3s 扫一轮 ⇒
#   一场我自己造出来的 execve 风暴，而 rc27 内核对每次 execve 都打一条 KSUBEAT F。
#   现在靠 shell glob 一次读完 + 只在需要时起 grep，且外层降到每 4 轮(≈12s)一次。
catch_root_thread() {
    P="$1"
    [ -n "$P" ] || return 0
    # ★必须有 /status：少它就是把每个线程目录当文件读，toybox grep 只会回
    #   `grep: /proc/PID/task/TID: Is a directory` ⇒ Uid 行一条也没有(第四十发复核)
    U=$(grep -h '^Uid:' /proc/$P/task/*/status 2>/dev/null)
    [ -n "$U" ] || return 0
    H=$(printf '%s\n' "$U" | grep -c $'^Uid:\t0\t')
    if [ "$H" != "0" ] && [ -n "$H" ]; then
        log "  ★外部证据: app pid=$P 有 $H 个线程 Uid=0: $(printf '%s\n' "$U" | grep $'^Uid:\t0\t' | tr '\n' '|')"
        return 0
    fi
    return 0
}

# ★★第九十七发(窗口 97, 2026-10-03 00:27 一手)的教训：payload 那一笔越界写把
#   `init_uts_ns.name.sysname` 的**最后一字节**改成了 NUL ⇒ `uname -s` 读出来是 `Linu`。
#   ART 在每个新进程的静态初始化里都有一句 `Check failed: strcmp(uts.sysname,"Linux")==0`
#   (art::IsKernelVersionAtLeast ← libart 的 _GLOBAL__sub_I_mark_compact.cc ← linker64
#   call_constructors)，于是这一发的窗口里**任何 app 都起不来**(logcat 里 artd 直接 SIGABRT，
#   `pidof com.suw.manager` 永远空)⇒ 所有 app 侧/UI 判据被打成"零报告"，看起来像管理面的 bug。
#   这一笔以 root 试过了：**写不动**(见下面第九十八发的更正)，所以现在它只是"读数+心跳"。
#   真正修的是 ko 侧 `/proc/ksu_fixuts`(rc51 起)：直接把那块 .data 里的 6 个字节写回去。
#   ★第九十八发更正(窗口 98 一手)：这台机把 `/proc/sys/kernel/ostype` 编成 **0444**(同目录
#   hostname 还是 0644)，sysctl 的写检查按表里的 .mode 走 ⇒ **uid 0 也吃 EACCES**
#   (`can't create /proc/sys/kernel/ostype: Permission denied`)。
fix_uts() {
    O=$(cat /proc/sys/kernel/ostype 2>&1)
    if [ "$O" = Linux ]; then
        log "  uts: sysname=[$O] 正常，不动"
        return 0
    fi
    ERR=$(echo Linux >/proc/sys/kernel/ostype 2>&1)
    N=$(cat /proc/sys/kernel/ostype 2>&1)
    log "  uts: sysname=[$O] -> 写回 ostype(报错=[$ERR]) -> 复读 [$N] uname -s=[$(uname -s)]"
    if [ "$N" = Linux ]; then
        log "  ★uts 已修好 ⇒ app 能起，app/UI 判据可用"
    else
        log "  !! 还是坏的 ⇒ 本发的 app/UI 判据不可能成立，别在它身上耗窗口"
    fi
    sync
}

log "=== 起点 v61 stage=$S args=[$ARGS] extra=[$EXTRA] dom=$DOM suwid=$SUWID mgr=$MGRID up=$(upt) ==="
# ★★§6.361/#145 的仪器开关 `NOSUW`（**默认关**：设备侧文件不在 ⇒ 名单形状与第 29 发逐字相同）：
#   ★§6.365 之后契约改了一处：**条目不是"官方 Manager 自己"**（那条被三个独立二进制证人判成设计上无效——
#     名单闸里对 manager 恒真、名单读数里对 manager 恒隐、它的 root profile 走 use_default、装载循环对它零特判），
#     而是**开关文件里那一个目标 app**：文件内容＝`<uid> <包名>` 两段，由 go.sh §1.69b 开枪前 `pk_uid` 现取后写入并两端复证。
#   ★形状不对(词数≠2／uid 不是纯数字／包名带非法字符) ⇒ **不改形状**、本发按交付形状算，并打一条 [!] —— 绝不猜一个 uid 进名单。
MGRPKG=me.weishu.kernelsu
ENT_UID=$SUWID
ENT_KEY=$APKEY
NOSUW=0
if [ -e /data/local/tmp/ksu_nosuw ]; then
    NSW=$(cat /data/local/tmp/ksu_nosuw 2>/dev/null | tr -d '\r' | head -1)
    NW=$(printf '%s' "$NSW" | wc -w | tr -dc '0-9')
    NU=$(printf '%s' "$NSW" | cut -d' ' -f1)
    NP=$(printf '%s' "$NSW" | cut -d' ' -f2)
    case "$NU" in '' | 0 | *[!0-9]* ) NU=0 ;; esac
    case "$NP" in '' | *[!a-z0-9._-]* ) NP="" ;; esac
    if [ "${NW:-0}" != 2 ] || [ "$NU" = 0 ] || [ -z "$NP" ]; then
        log "  [!] NOSUW 开关文件形状不对(现读=[$NSW] 词数=$NW uid=[$NU] 包名=[$NP]) ⇒ **不改形状**，本发按交付形状算(格 N1 没测到)"
    else
        NOSUW=1
        ENT_UID=$NU
        ENT_KEY=$NP
    fi
    log "  ★NOSUW 开关读回=$(ls -l /data/local/tmp/ksu_nosuw 2>&1 | tail -1) 内容=[$NSW] ⇒ 生效=$NOSUW"
fi
T0=$(date +%s)      # ★判"报告是不是本发写的"只看 mtime ≥ T0：预检(不花窗口那两次)已经留过一份旧文件
log "id=$(id -u) enforce=$(getenforce) uname=$(uname -s)"
fix_uts
log "enforce 判读: Permissive ⇒ app→@suwshd 连得上; Enforcing ⇒ app 侧 connect 必 EACCES(SELinux, 与 KSU 无关)"
log "ko md5=$(md5sum $KO | awk '{print $1}') ksuctl md5=$(md5sum $CTL | awk '{print $1}') shd md5=$(md5sum $SHD 2>/dev/null | awk '{print $1}')"
log "agent: pidof shd=[$(pidof shd)]"

log "----- ⓪ 上一发的现场：pstore 里那份 console-ramoops(内核 panic 时最后打印的东西) -----"
# ★为什么这一格现在必须抓：第九十/九十一发两次都是"机器当场重启、什么读数都没留下"。
#   设备侧唯一的**跨重启**内核日志就是 pstore/ramoops(shell 读不到：目录 0700 root)，
#   而 post 这一发正好有 root ⇒ 开机第一件事就是把它抄出来，再决定要不要继续冒险。
#   顺序也重要：**先抄证据，再做危险动作**。
mkdir -p /data/local/tmp/ps && chmod 777 /data/local/tmp/ps 2>/dev/null
for p in /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/console-ramoops /sys/fs/pstore/dmesg-ramoops-0; do
    if [ -f "$p" ]; then
        B=$(basename "$p")
        cp "$p" "/data/local/tmp/ps/$B" 2>/dev/null
        chmod 666 "/data/local/tmp/ps/$B" 2>/dev/null
        log "  抄到 $p -> /data/local/tmp/ps/$B ($(wc -c < /data/local/tmp/ps/$B 2>/dev/null) 字节)"
        log "  尾部 40 行:"
        tail -40 "/data/local/tmp/ps/$B" 2>/dev/null | sed 's/^/      /'
        log "  关键行(Bug|Unable to handle|pc :|Call trace|kernel BUG|Internal error):"
        grep -aE 'Unable to handle|Bug|kernel BUG|Internal error|pc :|Call trace|CFIFIX|ksu_patch|patch_text' \
            "/data/local/tmp/ps/$B" 2>/dev/null | tail -25 | sed 's/^/      /'
    else
        log "  $p 不存在"
    fi
done
ls -l /sys/fs/pstore/ 2>&1 | sed 's/^/  pstore 目录: /' | head -6
sync

log "----- ① 名单：真包名 key(抗 prune)，域=$DOM -----"
mkdir -p /data/adb/ksu
log "  ★NOSUW 入口证人：名单主条目=(uid=$ENT_UID, key=$ENT_KEY) 开关生效=$NOSUW (0=交付形状逐字同第 29 发)  ★ksa_uids 现读=[suw=$(cut -d' ' -f1 /data/local/tmp/ksa_uids.txt 2>/dev/null) mgr=$(cut -d' ' -f2 /data/local/tmp/ksa_uids.txt 2>/dev/null)]"
    log "  ★AP_KEY 生效证人：主条目 uid=$ENT_UID key=[$ENT_KEY]  ★开关文件=$(ls -l /data/local/tmp/ksu_ap_key 2>/dev/null || echo '不在⇒用默认 '$PKG'(§6.313⑦)')"
log "  ★DOM 生效证人：主条目 uid=$SUWID 域=[$(dom_for "$SUWID")]  ★全局 DOM=[$DOM] 开关文件=$(ls -l /data/local/tmp/ksu_dom 2>/dev/null || echo '不在⇒用默认 u:r:shell:s0(交付形状，§6.350)') 映射文件=$(ls -l $DOMMAP 2>/dev/null || echo '不在⇒每条都用上面那个全局 DOM(§6.353)') 映射内容=[$(cat $DOMMAP 2>/dev/null | tr '\n' '|')]"
# ★★key 必须写**真包名**：ksu_prune_allowlist() 会拿 package 名去校验 uid，
#   第二十三发用的假 key(app_uid/shell_uid) 在 insmod 后 0.27s 就被整条删掉，
#   之后 granted 一律翻成 0 ⇒ su 分支在 SD1 静默放弃(见 §6.46)。
if [ -f /data/local/tmp/ksu_two_profiles ] && [ -n "$MGRID" ] && [ "$MGRID" != 0 ]; then
    # ★§6.154：SET_APP_PROFILE 的 perm 是 **only_manager**(不是 manager_or_root)——一手：
    #   root(uid 0, u:r:kernel:s0) 发过去 `rc=-1 errno=1(EPERM)`。所以"给官方 Manager 换 su 域"
    #   没有运行期的口子，只能走 insmod 时那份 .allowlist(内核 init 期 load_allowlist 读 N 条)。
    #   开关=设备侧存在 /data/local/tmp/ksu_two_profiles(由 shot 脚本决定，默认不开 ⇒ 老行为不变)。
    log "  ksu_two_profiles 在 ⇒ 名单里同时写 $SUWID(suw) 与 $MGRID(官方 Manager)，域都是 $DOM"
    # ★§6.155 的一手教训：这里必须点 **ksuctl88**(它才有多条目 mkallow)。上一发走的就是这条分支，
    #   但 $CTL=/data/local/tmp/ksuctl 是设备上那份 2.2MB 的**旧二进制**⇒ 多出来的三元组被它静默丢掉，
    #   stage 日志老实打了 `8 + 784 = 792 字节`(旧格式)，名单还是 1 条 ⇒ 整发白烧。
    # ★§6.156 再加一层：开关文件里可以写**一串** `uid:包名`(空格分开)，默认只有官方 Manager 那一条。
    #   为什么要有"第三条无关 uid"当**正对照**：第六十六发两条目文件(1576B)写对了、也 cp 进
    #   /data/adb/ksu/.allowlist 了，但内核 `NEW_GET_ALLOW_LIST count=1` 只认了 suw 那条 ⇒
    #   到底是"多条目格式内核根本不收"还是"Manager 这个 uid 被特殊对待"，必须一次分开：
    #   count=3 ⇒ 格式没问题、Manager 的 profile 落了但 su 路径不查它；
    #   count=2(缺 10317) ⇒ 只有 Manager 那条被丢；count=1 ⇒ 读第二条就停(格式/尺寸问题)。
    CTL2=/data/local/tmp/ksuctl88
    # ★★§6.282 的教训(第 131 发一手)：这一段以前**复用**了 EXTRA 和 ARGS 两个变量——
    #   EXTRA 的本职是"额外的 insmod 参数"(第 40/41 行)，ARGS 的本职是"ksu_args.txt 的内容"(第 39 行)，
    #   而 insmod 那一行(现在第 424 行)用的是 `$EXTRA $ARGS` ⇒ 只要开这个开关，
    #   **喂给内核的模块参数就被换成 `10319:com.suw.manager 10319 com.suw.manager u:r:shell:s0`**，
    #   args 文件里那五条一个都没进去(mass_mark 回默认 1 ⇒ 装载期全量遍历跑了；ksu_ksud_path 回默认)。
    #   ⇒ 名单用的变量改成毫不相干的两个名字，别再碰 EXTRA/ARGS。
    PROFSPEC=$(cat /data/local/tmp/ksu_two_profiles 2>/dev/null)
    [ -n "$PROFSPEC" ] || PROFSPEC="$MGRID:me.weishu.kernelsu"
    MKTOK=""
    for spec in $PROFSPEC; do
        U2=${spec%%:*}; K2=${spec#*:}
        case "$U2" in '' | *[!0-9]*) continue ;; esac
        [ -n "$K2" ] || continue
        MKTOK="$MKTOK $U2 $K2 $(dom_for "$U2")"
    done
    log "      开关内容=[$PROFSPEC] ⇒ mkallow 追加=[$MKTOK]  ★insmod 参数仍是 args 文件那份=[$ARGS](§6.282 修)"
    if [ -x "$CTL2" ] && [ -n "$MKTOK" ]; then
        "$CTL2" mkallow /data/local/tmp/a_$SUWID.bin $SUWID "$APKEY" "$(dom_for "$SUWID")" $MKTOK
    else
        log "  !! 两条目分支没成立(CTL2=$CTL2 可执行=$([ -x "$CTL2" ] && echo y || echo n), MKTOK=[$MKTOK]) ⇒ 退回单条目，这一发的名单判据作废"
        "$CTL" mkallow /data/local/tmp/a_$SUWID.bin $SUWID "$APKEY" "$(dom_for "$SUWID")"
    fi
    # ★★2026-11-13 02:0x 一手事故：本分支把名单写进 `a_$SUWID.bin`，可下面第 363 行那句
    #   `cp /data/local/tmp/a_$ENT_UID.bin "$ALLOW"` 用的是 **ENT_UID**。只要同时开了 NOSUW
    #   （ENT_UID=目标 app，例如 Termux 10667），cp 复制到的就是**上一发遗留的单条目文件**
    #   ⇒ 实测落盘 `count=1 allow[0]=10667`，suw 与三个 app 全不在名单（granted 全 0），
    #   而日志里"两条目分支成立"和"NOSUW 开关生效=1"同时为真——两条腿各自都报成功，结果却是错的。
    #   ⇒ 本分支既然以 suw 为主条目，就必须把 ENT_* 拨回 suw，让后面统一那句 cp 拿到正确文件。
    ENT_UID=$SUWID
    ENT_KEY=$APKEY
    log "  ★两条目分支：ENT_* 已拨回主条目 (uid=$ENT_UID, key=$ENT_KEY) ⇒ 后面的 cp 取的是 a_$ENT_UID.bin"
else
    #   ★NOSUW=0 时 ENT_UID=$SUWID、ENT_KEY=$APKEY ⇒ 这一行与第 29 发**逐字等价**；
    #     NOSUW=1 时同一个调用写的是 (官方 Manager 的 uid, me.weishu.kernelsu, 它的域)。
    "$CTL" mkallow /data/local/tmp/a_$ENT_UID.bin "$ENT_UID" "$ENT_KEY" "$(dom_for "$ENT_UID")"
    log "  ★mkallow 已写：件=/data/local/tmp/a_$ENT_UID.bin 条目=($ENT_UID, $ENT_KEY, 域=$(dom_for "$ENT_UID"))"
fi
if [ "$ENT_KEY" != "$PKG" ]; then
    RD=$(od -An -c -j4 -N64 /data/local/tmp/a_$ENT_UID.bin 2>/dev/null | tr -s " ")
    log "  ★落盘件 key 字段读回(偏移 4..67 前 40 字节)：[$RD]"
fi
cp /data/local/tmp/a_$ENT_UID.bin "$ALLOW"
log "  ★落盘读回：$ALLOW 字节=$(wc -c < "$ALLOW" 2>/dev/null) 条目=(uid=$ENT_UID, key=$ENT_KEY)  ★单条目形状应为 792 B"
chmod 644 "$ALLOW"; chmod 711 /data/adb /data/adb/ksu 2>/dev/null
cp /data/local/tmp/ksud /data/adb/ksud; chmod 755 /data/adb/ksud
# ★v57(md §6.109)：rc55 起 ksud 的路径是 insmod 期参数 `ksu_ksud_path`。这里**两份都放**：
#   /data/adb/ksud 是默认值(跨重启还在 ⇒ 收尾必须删)；/dev/ksud 在 tmpfs(重启自动没 ⇒
#   不用删，于是 stage 收尾之后 `su` 仍然可用)。用哪一份由 ksu_args.txt 里那个参数决定。
# ★社区化(2026-11-09)：rc 谱系现在由 ko 注册 /dev/ksud 字符设备（stock KSU 的 su 入口）。
#   这一句原先把 sustatic 二进制 cp 到 /dev/ksud，**会埋掉内核字符设备** ⇒ 标准 su/官方 Manager
#   open("/dev/ksud") 命中普通文件而 ENOTTY。现改为只 chmod 0666（保证任意 app 能 open；授权门是
#   allowlist 不是文件权限），绝不再覆盖节点。su 客户端二进制仍以 /data/adb/ksud(上行)为准。
chmod 0666 /dev/ksud 2>/dev/null || true
# ★v62(#109/md §6.222)：改道目标还能再挪——执法下 app 唯一能 exec 的是**它自己数据目录里那份**(§6.221②)。
#   所以设备上放一个 `/data/local/tmp/ksu_redirect_dst`(一行=一个路径)，就在 insmod **之前**把同一份
#   shim 也放到那个落点、并把属主跟着父目录(否则 app 自己读不到)。没有这个文件 ⇒ 本段完全不动原状。
#   ★落点在 /data 上(不是 tmpfs)⇒ 重启不会自己没，收尾腿必须 rm。
if [ -f /data/local/tmp/ksu_redirect_dst ]; then
    RDST=$(head -1 /data/local/tmp/ksu_redirect_dst 2>/dev/null)
    if [ -n "$RDST" ]; then
        RDIR=${RDST%/*}
        mkdir -p "$RDIR" 2>/dev/null
        cp /data/local/tmp/ksud "$RDST" 2>/dev/null; RCOPY=$?
        ROWN=$(stat -c '%u:%g' "$RDIR" 2>/dev/null)
        [ -n "$ROWN" ] && chown "$ROWN" "$RDST" 2>/dev/null
        chmod 755 "$RDST" 2>/dev/null
        # ★v63(#113/§6.225)：光有落点不够——执法下 app exec 这个目标要过**三条**权限
        #   (`file:execute` + **`file:execute_no_trans`** + `open`/`read`)。实测：
        #     `app_exec_data_file` 缺 execute_no_trans ⇒ 执法下 rc=126(§6.224)；
        #     `apk_data_file`(`allow appdomain … execute execute_no_trans … open read`) ⇒ 执法下出 root(§6.225)。
        #   ⇒ 标签也交给 stage 贴(此刻还是 Permissive，chcon 才贴得动)，设备上放
        #     `/data/local/tmp/ksu_redirect_con` 一行=一个 context；没这个文件就完全维持 v62 行为。
        if [ -f /data/local/tmp/ksu_redirect_con ]; then
            RCON=$(head -1 /data/local/tmp/ksu_redirect_con 2>/dev/null)
            if [ -n "$RCON" ]; then
                chcon "$RCON" "$RDST" 2>/dev/null; RCR=$?
                log "      改道目标标签=$RDST con=$RCON chcon=$RCR 现值=$(ls -lZd "$RDST" 2>&1 | tr -s ' ' | cut -d' ' -f1,5)"
            fi
        fi
        log "      改道目标 extra=$RDST cp=$RCOPY chown=$ROWN 标签=$(ls -lZ "$RDST" 2>&1 | cut -c1-140)"
    else
        log "      [!] ksu_redirect_dst 在但是空的 ⇒ 不改道，照旧只有 /dev/ksud"
    fi
fi
log "      ksud 两份: $(ls -l /data/adb/ksud 2>&1 | tail -1 | cut -d' ' -f1,5,9) | $(ls -l /dev/ksud 2>&1 | tail -1 | cut -d' ' -f1,5,9)"
# ★★§6.352/#117 的第二把生产者补的一腿：`SHBIN` 开关(`/data/local/tmp/ksu_shbin`，go.sh §1.69 铺)指的那个壳，
#   **标签必须由这一期贴**——21:0x 一手：shell 域自己 `chcon … apk_data_file` 会被拒(`Permission denied`)，
#   而执法下 app 域 exec 它要过 `execute`+`execute_no_trans`+`open`/`read` 三条，实测只有 `apk_data_file` 这档过(§6.225)。
#   ★没有那个开关 ⇒ 这一段一行都不跑 ⇒ 交付形状逐字不变。贴在 insmod 之前 ⇒ 早于任何一次 su 尝试。
if [ -f /data/local/tmp/ksu_shbin ]; then
    SBIN=$(head -1 /data/local/tmp/ksu_shbin 2>/dev/null | tr -d '\r\n')
    if [ -n "$SBIN" ]; then
        chcon u:object_r:apk_data_file:s0 "$SBIN" 2>/dev/null; SCHR=$?
        chmod 755 "$SBIN" 2>/dev/null
        log "      ★SHBIN 目标贴标签：[$SBIN] chcon=$SCHR 现值=$(ls -lZd "$SBIN" 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9)"
        log "      ★SHBIN 目标本阶段先跑一下(Permissive，只证这支能跑，不证 app 域能 exec)：$( "$SBIN" -c 'echo SHBIN_EXEC_OK uid=$(id -u)' 2>&1 | tr -d '\n' )"
    else
        log "      [!] ksu_shbin 在但是空的 ⇒ v4 那边自己会退回默认，本段不贴标签"
    fi
fi
log "allow=$(wc -c < $ALLOW) 字节(单条目应当 792) ksud=$(ls -l /data/adb/ksud 2>&1)"
echo 8 4 1 8 > /proc/sys/kernel/printk 2>/dev/null

log "----- ①′ 关掉 printk 限流：本机默认 burst=10/interval=5s，第二十二发的判据就是这么被吃掉的"
log "      ★这两个是 /proc/sys 的 knob，root 能写(不同于 /sys/module/*/parameters 整目录不存在)"
cat /proc/sys/kernel/printk_ratelimit /proc/sys/kernel/printk_ratelimit_ratelimit 2>&1 | tr '
' ' '; echo " <- 改之前"
# ★§6.121：这两个 knob 一关，**内核里所有 `pr_*_ratelimited` 就等于不限量**。
#   第一百一十九发我因此得出错误结论：rc58 把入口回执改成限流之后"照样死"⇒ 我以为洪印被否，
#   其实限流被我自己关了(那一份环形缓冲里 `stash=48` 的 BN 行有 12331 条)。
#   ⇒ 留一个开关：设备上放 /data/local/tmp/ksu_quiet 就**保持默认限流**(用来验洪印是不是凶手)。
if [ -e /data/local/tmp/ksu_quiet ]; then
    log "      ksu_quiet 在 ⇒ 不动 printk 限流(保持 burst=10/5s，让 pr_*_ratelimited 真的生效)"
else
    echo 100000 > /proc/sys/kernel/printk_ratelimit 2>/dev/null
    echo 0 > /proc/sys/kernel/printk_ratelimit_ratelimit 2>/dev/null
fi
log "      改之后 = $(cat /proc/sys/kernel/printk_ratelimit 2>&1)/$(cat /proc/sys/kernel/printk_ratelimit_ratelimit 2>&1) (burst/interval)"
sync

log "----- ② 起活落盘(每条一写 + 心跳) -----"
# ★`dmesg` 每次要把整份环形缓冲(本机 2MB，还被厂商触摸屏日志刷爆)拷一遍，循环跟不上 ⇒
#   第二十九/三十发的落盘点落后死点 0.5 秒以上，SD/SU 那几行就是这么丢的。
#   /proc/kmsg 是**阻塞式逐条**读；★必须 count=1 —— 用 16 会让 dd 一直阻塞在"凑满 16 块"，
#   消息稀疏时整条信道就僵住(第三十二发因此比死点早哑 13.7 秒)。root 才读得动。
#   ★第九十发的账：这一条不带 sleep 的死循环 + 每条一次全盘 `sync`，就是两次 HARD_RESET 前
#   dmesg.live 尾部那 ~130 次/秒 `uid=0 comm=sh` execve 风暴的来源(kmsg 被厂商日志刷爆时它永不阻塞)。
#   ⇒ 三条只减自身开销、不改信道语义的收口：`read` 取 uptime(不吃 fork)、sync 改成每 8 条一次、
#   每轮垫 0.05s 把最坏频率钉死在 ~20 次/秒(相对第三十二发"比死点早哑 13.7 秒"仍 negligible)。
( HB_N=0
  while :; do
      read U rest < /proc/uptime
      echo "--- HB up=$U ---" >> "$LIVE" 2>/dev/null
      dd if=/proc/kmsg bs=512 count=1 2>/dev/null >> "$LIVE"
      HB_N=$((HB_N + 1))
      [ $((HB_N % 8)) -eq 0 ] && sync
      sleep 0.05
  done ) &
LV=$!
log "live dumper pid=$LV"

# ★§6.120：上面这个 dumper 会在收尾被 `kill $LV`，于是"死前最后几行"经常根本没落盘
#   (第一百一十九发我因此把"日志停在 572s、事件在 591s"读成"死前没有回执")。
#   ⇒ 再起一个**脱离会话**的备份信道：`setsid` 让它不在这个进程组里，收尾的 kill 打不到它；
#   每 2 秒用 `dmesg`(读环形缓冲，与 /proc/kmsg 不互斥) **整份覆盖** + sync ⇒ 复位后最多丢 2 秒。
setsid sh -c '
  i=0
  while [ $i -lt 30000 ]; do
    dmesg > /data/local/tmp/dmesg2.log.tmp 2>&1
    mv -f /data/local/tmp/dmesg2.log.tmp /data/local/tmp/dmesg2.log 2>/dev/null
    sync
    i=$((i + 1))
    sleep 1          # 覆盖周期=判据的分辨率(§6.121①)：2 秒会整段丢掉死前最后 <2 秒
  done
' >/dev/null 2>&1 &
log "备份信道(setsid 常驻 dmesg2.log) pid=$!"

log "----- ②′ PCODE 正对照：insmod **之前**先给 __arm64_sys_openat 挂一个 kprobe -----"
# rc42 的 PCODE 读数靠"函数入口第一条指令是不是 BRK #0x004(=0xD4200080)"来认 kprobe。
# 判据必须自带正对照，否则"什么都没找到"和"读数器坏了"长得一模一样：
#   ⇒ 这一发里 `__arm64_sys_openat w0=D4200080` 必须成立(是我们自己刚挂的)；
#   ⇒ 同一条路上别的函数若也出现 D4200080，而我们只挂了这一个 ⇒ 那个就是厂商的探针。
(
    cd /sys/kernel/tracing 2>/dev/null || cd /sys/kernel/debug/tracing 2>/dev/null
    echo 'p:kpf0/oa __arm64_sys_openat' >>kprobe_events 2>&1
    echo 1 >events/kpf0/enable 2>&1
    echo "  挂上与否: $(grep -c 'kpf0/oa' kprobe_events 2>/dev/null) enable=$(cat events/kpf0/enable 2>/dev/null)"
) >"/data/local/tmp/pcode_ctl.txt" 2>&1
log "  $(cat /data/local/tmp/pcode_ctl.txt 2>/dev/null | tr '\n' '|')"
sync

    # ★★§6.265④ 第 3 条的**减变量开关**：设备上放 `/data/local/tmp/ksu_skip_insmod`(内容随意) ⇒ 这一发**只 punch、不 insmod**。
    #   用途：把"punch 后 +16~30 秒 PS_HOLD 冷启动"到底是 (I) 我们 ko 之后那条路径 还是 (II) 电源/协处理器侧，一次分开。
    #   读法：跳过时后面所有"刚 insmod 完"的快照都读不到东西，**那是预期的空，不是失败**；判据只看一件事——
    #         这一 boot 的窗口**活没活过 30 分钟**(看 `w356_storm.out` 曲线里 mod 恒 0 且 HB 一路往上)。
    #   ★默认不开(文件不存在 ⇒ 原样走)，别把它留在设备上：留着=下一发默认不加载 ko。
    if [ -e /data/local/tmp/ksu_skip_insmod ]; then
        log "----- ★ksu_skip_insmod 在 ⇒ **这一发只 punch 不 insmod**(减变量对照，§6.265④) -----"
        RC=99; log "insmod 被跳过 rc 记为 $RC(约定：99=没跑) up=$(upt) lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')]"
        log "★这一发的判据只有一条：这台机器活没活过 30 分钟。活过 ⇒ 死亡系于 insmod 之后那条路；仍死 ⇒ 与 ko 无关，转电源侧(#93)"
        # ★打一行"判据⑥"只为让 go.sh 第 3 步的就绪闸继续往下走(它认这行)；**别把它读成 fd 装好了**——这发没有 ko。
        log "===== 判据⑥(★跳过版：这里没有 ko、没有 fd，只为让 go.sh 往下走) ====="
        sync
        chmod 666 "$OUT" "$FULL" "$LIVE" 2>/dev/null
        log "=== 结束(能到这行=本 boot 活下来了；判据要看它离 insmod 该发生的时刻多久) ==="
        sync
        exit 0
    fi
    # ★§6.282：把**真正交给内核的那串**打出来，别再只信第 223 行那句"args 文件的内容"。
    log "----- ★insmod 实参原文=[ksu_stage=$S $EXTRA $ARGS killguard=1]（args 文件=[$ARGS] extra=[$EXTRA]）-----"
    insmod "$KO" ksu_stage=$S $EXTRA $ARGS killguard=1   # ★rc30：只在 scanmod(=vr) 里挂**一处**跳过探针；scanall 关掉(rc29 的教训：到处挂=在热路径上单步)
RC=$?
log "insmod rc=$RC up=$(upt) lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')]"
log "sysfs 参数目录实况: $(ls /sys/module/kernelsu/ 2>&1 | tr '\n' ' ')"
# ★社区化(2026-11-09)：/dev/ksud 字符设备是 **insmod 时**由 rc77 的 misc_register 建出来的；
#   setup 段(第 374 行)那次 `chmod 0666 /dev/ksud` 跑在 insmod **之前**、节点还不存在 ⇒ 静默失效，
#   而 insmod 后 ueventd 按默认 0600 建节点（miscdevice.mode 在 Android 下被 ueventd 忽略）。
#   ⇒ 必须在这里（insmod 刚返回、节点已存在）补一次 chmod 0666，否则非 root 的 su open 会被 EACCES。
#   只在节点真的存在时补；insmod 失败(RC!=0)则节点不在、跳过（不掩盖失败）。
if [ -e /dev/ksud ]; then
    chmod 0666 /dev/ksud 2>/dev/null
    log "      ★/dev/ksud 权限补正(insmod 后)：$(ls -l /dev/ksud 2>&1 | tr -s ' ')"
else
    log "      ★/dev/ksud 不存在(insmod RC=$RC) ⇒ 跳过权限补正"
fi
# ★★已废弃(2026-11-09 §6.582)：**不再**往 /system/bin 放静态 su。
#   历史：曾用 overlay+ext4 镜像把 su 落到 /system/bin（配方留在 kmod/su_deploy.sh），但 Momo 一测就报
#   "找到可执行程序 su / 分区挂载异常 / 存在 /system/bin/su" —— 那是 Magisk 的形状，不是 KernelSU 的形状。
#   KernelSU 自己**没有**全局静态 su：`feature/sucompat.c` 把 "/system/bin/su" 这个**路径**在 syscall 入口
#   改道到 ksu_ksud_path，靠内核伪装让 app 看到 su。代价只是 ksu_hook_mask 要开 bit3(newfstatat)+bit4(faccessat)，
#   让 access()/stat() 也走伪装（只开 bit1=execve 时，access 先 ENOENT ⇒ 才被迫造文件）。
#   ⇒ 这里彻底关死：即使开关文件在也不执行，只留一行证人，防止以后误开又踩回 Momo 那条。
if [ -f /data/local/tmp/ksu_su_deploy ] || [ "${SU_DEPLOY:-0}" = "1" ]; then
    log "      ★su 部署开关在，但**社区路线已废弃静态 su** ⇒ 拒绝执行（改由内核 sucompat 提供 su；见 §6.582）"
else
    log "      ★su 部署：已废弃（社区路线=内核 sucompat 伪装路径，不落静态 su）"
fi
# ★§6.273 那一格：**ko 已经加载**，但 insmod 之后我们这一侧**一个 supercall 都不发**。
#   为什么要有这一格：rc67 在装载时跑了整轮全线程遍历(第 123 发 `w358_dmesg.live`：183 行逐任务 `tp_marker:`，
#   且 `ksu_mass_mark=0` 那道闸**没拦住**——闸在 `_locked()` 外面那层，而装载/钩子路径直接调 `_locked`)。
#   致命配置里唯一"能延迟发作"的具体形状就是**再来一轮遍历**，而"再来一轮"是**我们自己的 allowlist/mgr/granted 快照**踢的。
#   ⇒ 这一发把这些快照全部跳过，只留两个读数：①这台机器活不活过 +30 分钟；②`dmesg2.log` 尾部 `tp_marker:` 行数(>0=遍历又跑了)。
#   ★开关在**设备侧**这个文件；insmod 之前起好的两条落盘腿(活落盘/备份信道)不受影响，会继续记到复位为止。
if [ -e /data/local/tmp/ksu_quiet_after_insmod ]; then
    log "----- ★ksu_quiet_after_insmod 在 ⇒ insmod 之后**零 supercall**(§6.273 那一格)，名单/王座/granted 全部不读 -----"
    log "  此刻 up=$(upt) lsmod=[$(lsmod | grep -i kernelsu | tr -s ' ')] RC=$RC ⇒ 判据只看存活时间与 dmesg 尾部行数"
    # ★§6.288(第 135 发开枪前补的腿)：整环 ~2 MB 在遍历 burst 下只活几百秒，而 PC 侧 `adb shell dmesg` 在
    #   **Enforcing** 下是 `klogctl: Permission denied`(quiet 发整程执法)⇒ 装载期证人只能由**root 的 stage**
    #   在 insmod 刚返回这一刻自己 dump。`mass mark`/`mark-running` 两个计数＝`ksu_mass_mark=0` **生效**的直接证人。
    dmesg > /data/local/tmp/ksu_ring_load.txt 2>/dev/null
    chmod 666 /data/local/tmp/ksu_ring_load.txt 2>/dev/null
    RL=/data/local/tmp/ksu_ring_load.txt
    log "  ★整环装载快照 up=$(upt) 行数=$(wc -l < $RL 2>/dev/null) 最老ts=$(grep -aoE '\[[ ]*[0-9]+\.[0-9]+\]' $RL 2>/dev/null | head -1) 最新ts=$(grep -aoE '\[[ ]*[0-9]+\.[0-9]+\]' $RL 2>/dev/null | tail -1)"
    log "  ★生效证人计数 tp_marker=$(grep -ac 'tp_marker:' $RL 2>/dev/null) massmark_off=$(grep -ac 'mass mark' $RL 2>/dev/null) markrun_off=$(grep -ac 'mark-running' $RL 2>/dev/null) load_allow_uid=$(grep -ac load_allow_uid $RL 2>/dev/null) ADD_TRY_UMOUNT=$(grep -ac ADD_TRY_UMOUNT $RL 2>/dev/null) dispatcher=$(grep -ac 'dispatcher entered' $RL 2>/dev/null)"
    log "  命中行(最多 6 行，供事后复核计数不是筛子骗人)："
    grep -aE 'tp_marker:|mass mark|mark-running|load_allow_uid|ADD_TRY_UMOUNT' $RL 2>/dev/null | tail -6 | cut -c1-150 | sed 's/^/      /'
    # ★★§6.297 新增的**半步开关**（第 140 发把墙定成「ko 被加载」×「装载后没人接手」，而 137 一手显示
    #   "接手"里最早、最具体的一个**内核动作**＝把厂商 vr 改道的 syscall 桩写回本体）：
    #   开关文件在**设备侧** `/data/local/tmp/ksu_quiet_fixcfi`；它**不是超调用**，是**我们自己 ko 的 proc 写**
    #   (`/proc/ksu_fixcfi`：3=openat/execve/execveat，4=clone/setuid/setresuid)，所以能在"零 supercall"的 quiet 窗里单独跑。
    #   ★这一格**只做这件事**：不装 agent fd、不发 allowlist/mgr/granted、不 bind /product/bin、不 exec ksud。
    if [ -e /data/local/tmp/ksu_quiet_fixcfi ]; then
        log "----- ★半步(§6.297)：只做 fixcfi 写回，其余照旧一件都不做 -----"
        log "  动手前 up=$(upt) 开关实况=$(ls /data/local/tmp/ksu_quiet_fixcfi 2>&1 | tr -d '\n') proc口=[$(ls -l /proc/ksu_fixcfi 2>&1 | cut -c1-60)]"
        log "  动手前 CFIFIX 实况: $(cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CFIFIX [^|]*' | wc -l) 行(应当已经带 B-> 改道)"
        # ★§6.298⑤ 第 4 条欠账：光数行数分不出"改道/没改道"⇒ 把这 8 行**原文**打出来(带 B-> 目标与"在模块文本段=")
        log "  动手前原文(最多 12 行)："
        cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CFIFIX [^|]*' | head -12 | cut -c1-155 | sed 's/^/      /'
        echo 3 > /proc/ksu_fixcfi 2>/dev/null
        log "  echo 3(openat/execve/execveat) rc=$? up=$(upt)"
        echo 4 > /proc/ksu_fixcfi 2>/dev/null
        log "  echo 4(clone/setuid/setresuid) rc=$? up=$(upt)"
        # ★生效证人（接收方回读，不是"我写了所以一定成"）：写回后再读一遍，数这三类回执
        cat /proc/ksu_slots > /data/local/tmp/ksu_slots.dump.txt 2>&1
        chmod 666 /data/local/tmp/ksu_slots.dump.txt 2>/dev/null
        log "  ★写回后 CFIFIX 计数 已写回=$(grep -ac '桩已写回' /data/local/tmp/ksu_slots.dump.txt 2>/dev/null) 不用改=$(grep -ac '不用改' /data/local/tmp/ksu_slots.dump.txt 2>/dev/null) 总行=$(grep -ac CFIFIX /data/local/tmp/ksu_slots.dump.txt 2>/dev/null) 字节=$(wc -c < /data/local/tmp/ksu_slots.dump.txt 2>/dev/null)"
        grep -a 'CFIFIX' /data/local/tmp/ksu_slots.dump.txt 2>/dev/null | tail -8 | cut -c1-150 | sed 's/^/      /'
        log "  ★判据只有一条：这台机器活不活过 insmod+30 分；上面两行 rc 与'已写回'计数是**前置闸**(没写成=这发作废)"
    fi
    # ★§6.334/#135：死前整环 dump。开关文件由 go.sh 的 RING_END_DUMP 铺(默认关⇒这段完全不执行)。
    #   为什么放这里：要判的是"死发到底走没走进 su 路径"，而 SU0/SD4/SU1 这三行本来就会打(§6.334 源码一手)
    #   ⇒ 编新 ko 没有新观测点，缺的只是**更接近死亡时刻的一份整环**。
    #   ★这条腿只用 stage 自己(root)，**不 fire suw**（一 fire 就把"suw 整窗没运行"那一维改掉了，#135 预登记里写死的）。
    #   代价登记清楚：比 quiet 的定义多 sleep/dmesg/head/grep 几个 exec；同一窗里采样腿本来就有 ~1200 次 exec ⇒ 不是承重变量。
    if [ -e /data/local/tmp/ksu_ring_end_dump ]; then
        RED_N=$(head -1 /data/local/tmp/ksu_ring_end_dump 2>/dev/null | tr -dc '0-9')
        case "$RED_N" in ''|*[!0-9]*) RED_N=200 ;; esac
        log "----- ★RING_END 腿在跑：开关实况=$(ls -l /data/local/tmp/ksu_ring_end_dump 2>&1 | tr -s ' ' | cut -c1-70) 目标=再等 ${RED_N}s 后 dump 整环 -----"
        log "  dump 之前：up=$(upt) dmesg.live 行数=$(wc -l < /data/local/tmp/dmesg.live 2>/dev/null)"
        sleep "$RED_N"
        dmesg > /data/local/tmp/ksu_ring_end.txt 2>/dev/null
        chmod 666 /data/local/tmp/ksu_ring_end.txt 2>/dev/null
        REND=/data/local/tmp/ksu_ring_end.txt
        log "  ★dump 完 up=$(upt) 整环行数=$(wc -l < $REND 2>/dev/null) 最老ts=$(grep -aoE '\[[ ]*[0-9]+\.[0-9]+\]' $REND 2>/dev/null | head -1) 最新ts=$(grep -aoE '\[[ ]*[0-9]+\.[0-9]+\]' $REND 2>/dev/null | tail -1)"
        log "  ★判据本体(逐词数，别只靠筛子)：SU0=$(grep -ac 'KSUBEAT SU0' $REND 2>/dev/null) SD4=$(grep -ac 'KSUBEAT SD4' $REND 2>/dev/null) SU1=$(grep -ac 'KSUBEAT SU1' $REND 2>/dev/null) prune=$(grep -ac 'prune uid' $REND 2>/dev/null) load=$(grep -ac 'load_allow_uid' $REND 2>/dev/null)"
        log "  命中行原文(最多 12 行)："
        grep -aE 'KSUBEAT (SU0|SU1|SD4)|prune uid|load_allow_uid' $REND 2>/dev/null | tail -12 | cut -c1-150 | sed 's/^/      /'
        sync
    fi
    log "===== 判据⑥(★静默版：ko 在，但这一发故意不装 agent fd、不发超调用，只为让 go.sh 往下走) ====="
    sync
    chmod 666 "$OUT" "$FULL" "$LIVE" 2>/dev/null
    log "=== 结束(quiet 版；能到这行=insmod 之后我们没再踢任何东西) ==="
    sync
    exit 0
fi
# ★★§6.157 新增的必做动作：**名单/王座/granted 的快照必须在 insmod 刚返回这一秒读**。
#   第六十九发一手：insmod rc=0 于 up=629、lsmod 里明明有 `kernelsu 196608 0`，
#   而 up=731 时模块已经没了(`/proc/modules` 没有它、`/proc/ksu_install_fd` 也消失了、stage 进程也没了，
#   机器却没重启 —— uptime 是连续的)。⇒ PC 侧那种"等 stage 跑完判据⑥再去读"的顺序，
#   在模块短命的场合只会读到"模块已经没了"的空读数，然后被误当成"名单没装进去"。
log "----- 名单/王座快照(刚 insmod 完) -----"
KSU88=${CTL2:-/data/local/tmp/ksuctl88}
if [ -x "$KSU88" ]; then
    log "  allowlist: $($KSU88 allowlist 2>&1 | grep -aE 'NEW_GET_ALLOW_LIST|allow\[' | tr '\n' '|' | cut -c1-260)"
    log "  mgr: $($KSU88 mgr 2>&1 | grep -a GET_MANAGER_APPID | cut -c1-120)"
    for spec in $(cat /data/local/tmp/ksu_two_profiles 2>/dev/null) $ENT_UID:$ENT_KEY; do
        u2=${spec%%:*}
        case "$u2" in '' | *[!0-9]*) continue ;; esac
        log "  granted[$u2] $($KSU88 granted "$u2" 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-100)"
    done
else
    log "  !! $KSU88 不在 ⇒ 名单快照没读成(这一发的名单判据按没测到算)"
fi
# ★#55/#39 的采样开关(设备侧存在 /data/local/tmp/ksu_life_probe 才做，默认不影响任何老跑法)：
#   ① 把**上一场复位**留下的 pstore 抢救进 /data —— `/sys/fs/pstore` 是 root 0700 挂载，shell 连 ls 都
#      吃 Permission denied(今晚两次拿不到现场就是这个原因)，而 /data/local/tmp 跨重启还在、chmod 之后
#      复位回来不用 root 也能读 ⇒ 机器再掉也不丢现场；
#   ② 起一个 setsid 的寿命采样器，记录"模块消失的那一刻"前后的 mod/enforce/load1。
if [ -e /data/local/tmp/ksu_life_probe ]; then
    mkdir -p /data/local/tmp/pstore_copied 2>/dev/null
    cp -a /sys/fs/pstore/. /data/local/tmp/pstore_copied/ 2>/data/local/tmp/pstore_copy.err
    chmod -R a+r /data/local/tmp/pstore_copied 2>/dev/null
    log "  pstore 抢救: [$(ls /data/local/tmp/pstore_copied 2>&1 | tr '\n' ' ')] err=$(head -c 120 /data/local/tmp/pstore_copy.err 2>/dev/null)"
    ( setsid nohup /system/bin/sh /data/local/tmp/w166_life.sh >/dev/null 2>&1 </dev/null & )
    log "  寿命采样器已起(setsid) 脚本=$(ls -l /data/local/tmp/w166_life.sh 2>&1 | tail -1)"
fi
# ★rc38 的教训：SLOTTBL/KILLSCAN 这类 **init 期**打印会被活落盘(dd 逐块)整段错过
#   ⇒ 唯一抓得住的时机是"insmod 刚返回"这一刻直接读环形缓冲(判据①本来就是这么抓 P1/P2/P4 的)
# ★rc40/五十一版改口径：读数同时进内核静态缓冲 ⇒ `cat /proc/ksu_slots` 才是主判据，dmesg 只兜底。
#   第八十四发的教训：活落盘只活了 0.11 秒就跟着 post 一起没了，"抓住 insmod 那一秒"不能当唯一凭据。
log "SLOTTBL 快照(/proc/ksu_slots): $(cat /proc/ksu_slots 2>&1 | tr '\n' '|')"
# ★★第九十四发定稿的必做动作：把 vr 改过的三条 CFI 跳板(openat/execve/execveat)**恢复成出厂值**。
#   `echo 3` = 只改桩里那条 B 的目标，`sys_call_table` 一个字都不动 ⇒ 与出厂语义等价、KCFI 校验不受影响
#   (第九十/九十一发往表项里塞"裸本体地址"的两种写法都把机器打 PS_HOLD 重启，原因见 §6.93②)。
#   不做这一步，后面所有"escape 过的任务"都只能拿到一个"uid 0 但 open/execve 一律 EPERM"的空壳。
if [ -e /proc/ksu_fixcfi ]; then
    echo 3 >/proc/ksu_fixcfi 2>&1
    log "★fixcfi(只改桩) 已触发 rc=$? ⇒ 复读："
    # ★§6.118：原来这条 grep 只留"桩已写回"一种结果 ⇒ "认不出/跳过/不是 B 形态/不用改"全被静默吃掉，
    #   于是"只看到 3 条 CFIFIX"被我错读成"新加的那两条没处理"。判据不许带筛子：印全部。
    cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CFIFIX [^|]*' | sed 's/^/    /'
    # 原始量整份留盘，PC 侧事后想怎么查都行(/proc 是易失的，机器一重启就没了)
    cat /proc/ksu_slots > /data/local/tmp/ksu_slots.dump.txt 2>&1
    chmod 666 /data/local/tmp/ksu_slots.dump.txt 2>/dev/null
    log "  /proc/ksu_slots 已导出 = $(wc -c </data/local/tmp/ksu_slots.dump.txt 2>/dev/null) 字节"
    sync
		# ★★#73(§6.169/§6.170)：c=4 = 把 vr 也改过的 clone(220)/setuid(146)/setresuid(147) 三条桩写回本体。
		#   不做这一步，su 出来那个 shell 就是"uid 0、域对、但一条外部命令都跑不了"(mksh 每条命令都要 fork)。
		#   §6.170 的一手对照：写回前 fork/setuid/setresuid 全 EPERM；写回后同一发里三格全 OK，
		#   /proc/ksu_cfiscan 的状态读数从 25 条被管变成 22 条，Termux 里 su 之后 id 才真跑出来。
		#   与上面 c=3 同一手法(只改桩里那条 B，表项一个字不动) ⇒ 风险等级=交付流程本来每发都在跑的那一笔。
		echo 4 >/proc/ksu_fixcfi 2>&1
		log "★fixcfi c=4(clone/setuid/setresuid) 已触发 rc=$? ⇒ 新增 CFIFIX 复读(不带筛子)："
		cat /proc/ksu_slots 2>&1 | tr "\n" "|" | grep -ao "CFIFIX [^|]*" | tail -12 | sed "s/^/    /"
		cat /proc/ksu_slots > /data/local/tmp/ksu_slots.dump.txt 2>&1
		chmod 666 /data/local/tmp/ksu_slots.dump.txt 2>/dev/null
		sync
else
    log "  /proc/ksu_fixcfi 不在 ⇒ 这一发的 ko 不带 CFIFIX(判据②/④预期全 EPERM)"
fi
# ★★第九十八发(窗口 98)一手：uts 这一笔**用户态写不动** —— 这台机把 /proc/sys/kernel/ostype 编成
#   0444(同目录 hostname 还是 0644)，而 sysctl 按表里的 .mode 判写权限，**uid 0 也 EACCES**：
#   `can't create /proc/sys/kernel/ostype: Permission denied`。⇒ 只能让 ko 自己写那块 .data(rc51 起
#   有 /proc/ksu_fixuts)：`echo 1` = 先把 sysname/release/machine 三件套咬合验证一遍，再写 6 个字节。
if [ -e /proc/ksu_fixuts ]; then
    echo 1 >/proc/ksu_fixuts 2>&1
    log "★fixuts 已触发 rc=$?"
    cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'UTS [^|]*' | sed 's/^/    /'
    sync
else
    log "  /proc/ksu_fixuts 不在 ⇒ 这一发的 ko 不带 UTS 修复(app 起不来，UI 判据作废)"
fi
fix_uts   # ★再确认一次：insmod 自己那笔写也可能碰 uts(同一份 payload 的落点是随机的)
dmesg 2>/dev/null | grep -aE 'SLOTTBL|KILLSCAN|tilayout' | head -26
log "===== 判据①：sys_call_table 那笔写 ====="
# ★v28：活落盘是 dd 逐条**异步**写的，insmod 一返回就去 grep 必然什么都没有(v27 就是空的)
sleep 2
grep -E 'KSUBEAT (P1|P2|P3|P4|A )|patch syscall|registered syscall hook|sys_enter tracepoint|mark-running' "$LIVE" | tail -14
N1=$(grep -c 'KSUBEAT A ' "$LIVE" 2>/dev/null)
if [ "$N1" = "0" ]; then
    log "  活落盘还没跟上 ⇒ 直接从 dmesg 兜一次(同一判据，另一个来源)"
    dmesg 2>/dev/null | grep -E 'KSUBEAT (P1|P2|P4|A )|patch syscall|reboot kprobe registered' | tail -10
fi
log "符号/布局: $(grep -E 'dev_syms|apfmt|tilayout' "$LIVE" | tail -2 | tr '\n' '|')"
sync

if [ "$RC" = 0 ]; then
    log "===== 判据②：正对照 ksuctl grant 10284(内核侧 escape 好不好，先钉死) ====="
    log "      do_grant_root 不看 arg，直接对**当前进程**跑 escape_with_root_profile()，"
    log "      perm=allowed_for_su ⇒ 子进程先把 ruid 降到 10284(名单里)再发这个 ioctl。"
    log "      这条路**不经过 sucompat**(没有 filp_open/改寄存器/嵌套 execveat) ⇒ 与必炸的 su 支路无关。"
    "$CTL" grant $SUWID
    log "grant rc=$? up=$(upt)"
    dmesg 2>/dev/null | grep -E 'allow root for|KSUBEAT (X[0-9A-C]|SU[0-9])|Failed to cache|sulog' | tail -18
    sync

    log "===== 控制面(fmt/info/allowlist/granted) ====="
    "$CTL" fmt
    "$CTL" info
    "$CTL" allowlist
    "$CTL" granted $SUWID
    "$CTL" granted 2000
    log "===== ★prune 探针：等 3s 让包观察者跑完，再问一次 granted ====="
    sleep 3
    "$CTL" granted $SUWID
    log "prune 条数=$(dmesg 2>/dev/null | grep -c 'prune uid:') 内核侧加载/裁剪证据:"
    dmesg 2>/dev/null | grep -E 'load_allow_uid|set root profile|uid :|prune uid|Crowning' | tail -8
    sync

    log "===== 判据⑤：agent 侧确认 —— 以 root 走一遍 KSUFD 客户端(只看 GET_INFO，不授权) ====="
    log "      只证明'递出去的 fd 在另一个进程里 ioctl 得动'；这里的 uid 0 是 root 自己，不算 app 的证据。"
    if [ -x "$SHD" ]; then
        "$SHD" --ksufd
        log "--ksufd rc=$? up=$(upt)"
    else
        log "!! $SHD 不在 ⇒ agent 侧确认这一环缺(不影响 app 那一环，但少一条对照)"
    fi
    sync

    log "===== 起 root 侧 su 守护(§6.69③/§6.72③) ====="
    log "      为什么必须是它：app 那个任务靠 escape 变 uid 0 会被厂商模块 vr 杀掉(§6.69)，"
    log "      就算把杀软成 SIGCONT，它接着 execve 还会被 EPERM(§6.72)；而这个守护是窗口里"
    log "      \"生下来就是 root\"的进程 —— 同一个 boot 里它 exec 几千次都没人拦。"
    log "      授权判定不在守护里写规则：它拿 SO_PEERCRED 的发起 uid 问内核 UID_GRANTED_ROOT，"
    log "      也就是**只认 KSU 白名单**(名单说没有就没有)。" 
    # ★§6.213③/#103：把守护**换成 shell 域起**。
    #   为什么要换：以前它继承 stage 那个 root 任务的域 `u:r:kernel:s0`，而那个域在 **Enforcing 下连 exec 都不行**
    #   (§6.212③ 一手：`getenforce/cut/ls/sed` 全部 `inaccessible or not found`) ⇒ 整条 root 通道只在
    #   "被 punch 打开的 Permissive 窗口"里活着，凡是"执法态下能不能读 X"的问题都问不出来。
    #   `u:r:shell:s0` 是这台机基础策略里**真实存在**的域，root+shell 在执法下照样能 exec ⇒ 通道不再怕执法。
    #   负对照：`AGENT_DOMAIN=` (空串) ⇒ 退回老办法(继承 kernel 域)，两跑只差这一个变量。
    #   ★例58 的账：这一发改完之后就可以合法地 `setenforce 1` 做实验，但**恢复动作不许是 root 腿**
    #   (shell 域在执法下大概写不动 enforce) ⇒ 恢复 = `adb reboot`(shell 身份就够，不依赖 root 通道)。
    AGENT_DOMAIN=${AGENT_DOMAIN:-u:r:shell:s0}
    if [ -n "$AGENT_DOMAIN" ] && command -v runcon >/dev/null 2>&1; then
        ( setsid nohup runcon "$AGENT_DOMAIN" "$CTL" sushd changeme </dev/null >>/data/local/tmp/sushd.log 2>&1 & )
        log "  sushd 走 runcon [$AGENT_DOMAIN] 起(§6.214/#103)"
    else
        ( setsid nohup "$CTL" sushd changeme </dev/null >>/data/local/tmp/sushd.log 2>&1 & )
        log "  sushd 按老办法起(AGENT_DOMAIN 空 或 这台机没有 runcon)"
    fi
    # ★§6.123③：**agent(shd) 必须由本 stage 以 root 起**。
    #   原来它是 PC 侧用 adb shell 起的 ⇒ uid 2000；而 shd v4 放行第三方 uid 要问内核
    #   `UID_GRANTED_ROOT`，那条 ioctl 的权限是 `manager_or_root`(`current_uid()==0 || is_manager()`)
    #   ⇒ uid 2000 问不动 ⇒ 一律 EPERM ⇒ Termux 里 `su` 得到 `agent 拒绝: ERR not-allowed`(屏幕实拍)。
    #   root 版 shd 自己也不能靠 reboot 魔数拿 fd(uid 0 被 forbid_system_uid 拒) ⇒ 用 /proc/ksu_install_fd 装。
    if [ -e /proc/ksu_install_fd ] && [ -x /data/local/tmp/shd ]; then
        for p in $(pidof shd); do kill -9 "$p" 2>/dev/null; done   # 抢 abstract 名字，只能有一个持有者
        sleep 1
        ( setsid nohup /data/local/tmp/shd 31339 2147483647 "$MGRID" </dev/null >>/data/local/tmp/shd.log 2>&1 & )  # 持久：idle 1800→2147483647，活到硬重启(用户 02:2x 定，贴合社区常驻模型)
        sleep 3
        SPID=$(pidof shd | awk '{print $1}')
        if [ -n "$SPID" ]; then
            echo "$SPID" > /proc/ksu_install_fd 2>/dev/null \
                && log "  agent(root) pid=$SPID uid=$(awk '/^Uid/{print $2}' /proc/$SPID/status) 已装驱动 fd" \
                || log "  ★agent pid=$SPID 的 fd 没装上(静态 su 会拿到 ERR)"
        else
            log "  !! agent 没起来 ⇒ 静态 su 这条路这一发不可用"
        fi
    fi
    log "===== 判据⑥(v48 改法，md §6.81)：官方 Manager 的 fd 用 /proc 触发口装，顺序自由 ====="
    log "      rc35 只能在 insmod 那一刻装(参数 setter 里不能干活、sysfs 被我们自己 kobject_del 摘了)，"
    log "      于是\"先起 Manager→insmod→重启 Manager 重查\"走不通：新 pid 没 fd，老 pid 缓存的是 -1。"
    log "      rc36 加了 /proc/ksu_install_fd(0600，root 可写) ⇒ 现在可以 insmod 之后再起、再装。"
    # MGRPKG 在上面的 NOSUW 开关块里定义(只留一处，避免两份口径分叉)
    log "      触发口在不在: $(ls -l /proc/ksu_install_fd 2>&1 | tail -1)"
    grep -a "KSUFDINST 触发口" "$LIVE" 2>/dev/null | tail -2
    # ★第 32 发的一手事实：stage 是 root 跑的，而 **root 域 `am start` 报 `Can't find service: activity`**
    #   （vivo 对非 shell 域隐藏服务列表，与 Z5 教程记的"root 域 service list 看到 0 个服务"同一条）。
    #   ⇒ 原来这三行里 MPID 永远是空 ⇒ `/proc/ksu_install_fd` 从没被写过 ⇒ 官方 Manager 拿不到驱动 fd
    #   ⇒ 首页永远"不支持"，跟"加冕成没成"根本无关。
    #   正解：换 shell 域起它（原来那条留作兜底），并**轮询等 pid**——PC 侧起来的也算，谁先起来都能装 fd。
    # ★§6.193②：但"起来之后再装"这条顺序**官方页不认**——`「不支持 GKI」那一屏是启动时一次性分支`，
    #   fd 晚到它也不重查(今晚实测：fd 已在它 fd 表里，页面照旧；杀掉重起并被抢装 ⇒ 立刻变「工作中 [越狱模式]」)。
    #   ⇒ 开关文件 `/data/local/tmp/ksu_race_fd` 存在时，**先起 0.4s 抢装看门狗，再起 UI**，让 fd 赶在它那次查询之前。
    #   默认关：不动交付链的形状(与 rc63 那版逐字相同)，官方 Manager 预装进机器才需要开。
    if [ -e /data/local/tmp/ksu_race_fd ]; then
        ( i=0; LASTP=""
          while [ "$i" -lt 75 ]; do
              i=$((i + 1))
              P=$(pidof $MGRPKG 2>/dev/null | cut -d' ' -f1)
              case "$P" in ''|*[!0-9]*) P="" ;; esac
              if [ -n "$P" ] && [ "$P" != "$LASTP" ]; then
                  if echo "$P" > /proc/ksu_install_fd 2>/dev/null; then
                      log "      RACE 抢装 pid=$P (第 $i 轮，约 $((i * 4 / 10))s)"
                  else
                      log "      RACE 写触发口失败 pid=$P(触发口可能还没建好)"
                  fi
                  LASTP="$P"
              fi
              sleep 0.4
          done ) &
        log "      RACE 看门狗已起(父 shell 继续去 am start；开关=/data/local/tmp/ksu_race_fd)"
    fi
    # ===== §FDKA：把"30 秒抢装"升级成"种进 zygote ⇒ 之后每个 app 一出生就带着驱动 fd" =====
    #   为什么这样修(2026-10-22，一手远端 /root/k/ksu/kernel/supercall/dispatch.c)：
    #   ①官方 Manager 那一屏"支持/不支持"是**启动时一次性分支**(§6.193②)，fd 晚到它不重查 ⇒
    #      75×0.4s 那条看门狗治的是"赶在查询之前"，不是"以后都在"：Manager 被杀重开、或框架软重启
    #      (kill -9 zygote64，§6.385 那格实测过它不掉 root 但会杀掉 app)之后，牌子就退回"不支持"。
    #   ②app 是从 zygote **fork 出来的、不走 execve** ⇒ 只要 zygote 的 fd 表里有它，
    #      之后每一个 app 进程**出生时就带着**，谁先查询都看得见 ⇒ 不再有时间窗。
    #   ③安全面读实了，不是靠注释：dispatch 每个动词都挂 perm_check，不过就 -EPERM(第 887-891 行)；
    #      always_allow 只有 GET_INFO/GET_INFO_LEGACY/CHECK_SAFEMODE 这类信息项，
    #      GRANT_ROOT 是 allowed_for_su(只认 su-session fd)、名单/profile 全是 manager_or_root/only_manager
    #      ⇒ "每个 app 都拿着一个 permissions=0 的驱动 fd"**不放宽能力面**。
    #   ★默认关：开关文件不存在就整个块不执行(交付形状一字不动)；开关文件本身＝kill switch，
    #     删掉它循环会自己退，不留孤儿进程。fd 是 O_CLOEXEC(supercall.c:86) ⇒ 别指望它穿过 execve，
    #     这条路只覆盖 zygote 系的 app；shd/agent 那种 execve 起来的仍要走上面那次单独补装。
    # FDKA-BEGIN  ← 自测(run_fdkeepalive.sh)抽这一段字节来跑，不许在两处各写一份(例 120 同族)
    # ★10-22 20:4x 一手缺陷(第 38 发真机凭据抓出来的，md §6.391)：这台机上 `pidof zygote64` **不唯一**——
    #   zygote 刚 fork、还没改名的子进程也叫 `zygote64`，而 pidof 的输出顺序是 /proc 的 readdir 序(不是 pid 大小)。
    #   原来取第一个 ⇒ 种子可能落在瞬时子进程上，真 zygote 反而没刷(日志里 `INST Z` 的 pid 一路变就是这个)。
    #   唯一判据：**真 zygote 的父亲是 init(ppid=1)**；那些瞬时子进程的父亲是 zygote 自己。
    #   兜底：一个 ppid=1 都没有 ⇒ 退回第一个数字候选，但**明打 FALLBACK**(只打一次)，不静默当没事。
    #   注：`cut -f4` 取 ppid 的前提是 comm 里没有空格(实测真 zygote 的 comm=`main`)。
    #   ★定义必须在 `fd_keepalive_loop` **外面**：起循环前的"当场种一次"也要用它，而函数体只在被调用时才展开。
    pick_zygote() {
        Q0=""; QN=0
        for Q in $(pidof "$1" 2>/dev/null); do
            case "$Q" in ''|*[!0-9]*) continue ;; esac
            QN=$((QN + 1)); [ -n "$Q0" ] || Q0="$Q"
            if [ "$(cut -d' ' -f4 "${PRCK:-/proc}/$Q/stat" 2>/dev/null | tr -dc '0-9')" = 1 ]; then echo "$Q"; return 0; fi
        done
        [ -n "$Q0" ] || return 1
        [ "${FBL:-0}" = 0 ] && { echo "FDKA ZG_FALLBACK pid=$Q0 候选数=$QN 没有一个 ppid=1" >> "${LOGK:-/dev/null}"; FBL=1; }
        echo "$Q0"; return 0
    }
    fd_keepalive_loop() {
        SWK="$1"; TRK="$2"; ZK="$3"; MK="$4"; IVK="${5:-5}"; FMAXK="${6:-24}"; LOGK="$7"; PRCK="${8:-/proc}"
        LZK=0; LMK=0; FK=0; NK=0; FBL=0
        echo "FDKA START up=$(cut -d' ' -f1 /proc/uptime) interval=${IVK}s pid=$$ switch=$(ls $SWK 2>&1 | tail -1)" >> "$LOGK"
        while : ; do
            NK=$((NK + 1))
            [ -e "$SWK" ] || { echo "FDKA STOP 开关没了(第 $NK 轮) ⇒ 自己退出" >> "$LOGK"; return 0; }
            ZP2=$(pick_zygote "$ZK")
            MP2=$(pidof "$MK" 2>/dev/null | cut -d' ' -f1)
            case "$ZP2" in ''|*[!0-9]*) ;; *)
                if [ "$ZP2" != "$LZK" ]; then
                    if echo "$ZP2" > "$TRK" 2>/dev/null; then
                        echo "FDKA INST Z pid=$ZP2 第 $NK 轮 up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOGK"; LZK="$ZP2"; FK=0
                    else
                        FK=$((FK + 1)); echo "FDKA WRITEFAIL Z pid=$ZP2 连续失败=$FK" >> "$LOGK"
                    fi
                fi ;;
            esac
            case "$MP2" in ''|*[!0-9]*) ;; *)
                if [ "$MP2" != "$LMK" ]; then
                    if echo "$MP2" > "$TRK" 2>/dev/null; then
                        echo "FDKA INST M pid=$MP2 第 $NK 轮 up=$(cut -d' ' -f1 /proc/uptime)" >> "$LOGK"; LMK="$MP2"; FK=0
                    else
                        FK=$((FK + 1)); echo "FDKA WRITEFAIL M pid=$MP2 连续失败=$FK" >> "$LOGK"
                    fi
                fi ;;
            esac
            [ "$FK" -ge "$FMAXK" ] && { echo "FDKA GIVEUP 连续 $FK 次写不进 ⇒ 触发口/ko 可能没了，退出" >> "$LOGK"; return 3; }
            sleep "$IVK"
        done
    }
    # FDKA-END
    if [ -e /data/local/tmp/ksu_fd_keepalive ]; then
        # 先把 zygote 当场种一次(不靠循环的第一轮，省掉一个 5 秒空窗)，再起常驻循环。
        #   ★10-22 20:4x：这里也换成 `pick_zygote`(原来 `pidof | cut -f1` 在同一条一手缺陷上是同一颗雷)；
        #     它读 ppid 需要 LOGK/PRCK 有值 ⇒ 先赋全局，别等函数被调用才赋。
        LOGK=/data/local/tmp/ksu_fd_keepalive.log; PRCK=/proc; FBL=0
        ZP0=$(pick_zygote zygote64)
        case "$ZP0" in ''|*[!0-9]*) log "      FDKA !! 现读不到 zygote64 的 pid ⇒ 当场那次没做(循环仍会盯)" ;; *)
            echo "$ZP0" > /proc/ksu_install_fd 2>/dev/null \
                && log "      FDKA 已把驱动 fd 种进 zygote64 pid=$ZP0(之后 fork 的每个 app 都自带)" \
                || log "      FDKA ★种 zygote 失败(触发口不在?)⇒ 后面看循环的 WRITEFAIL 计数" ;;
        esac
        # ★循环的字节**只有一份**：从 stage 自己身上抽出 FDKA-BEGIN..END 那段，落成独立 helper 再后台跑。
        #   (第一版这里写成 `sh -c '. .../ksu_one_stage.sh'` ⇒ 那会把整条 stage 重跑一遍＝重新 insmod、
        #    重新打漏洞，是致命的；改成自我抽取后既没有第二份实现，也不会重放任何动作。)
        SELF="$0"; [ -f "$SELF" ] || SELF=/data/local/tmp/ksu_one_stage.sh
        HELPER=/data/local/tmp/ksu_fd_keepalive.sh
        LOGK=/data/local/tmp/ksu_fd_keepalive.log
        #   ★marker 用字符类写(`BE[GIN]`/`EN[D]`)：否则这一行本身就含 marker，sed 会自我匹配、
        #     抽取范围一路吞到文件末尾(第一版就是这么坏的，抽出来 17361 字节)。
        sed -n '/# FDKA-BE[GIN]/,/# FDKA-EN[D]/p' "$SELF" > "$HELPER"
        printf '%s\n' 'fd_keepalive_loop /data/local/tmp/ksu_fd_keepalive /proc/ksu_install_fd zygote64 me.weishu.kernelsu "${FDKA_INTERVAL:-5}" "${FDKA_FAIL_MAX:-24}" /data/local/tmp/ksu_fd_keepalive.log "${FDKA_PROC:-/proc}"' 'exit $?' >> "$HELPER"
        chmod 755 "$HELPER" 2>/dev/null
        HB=$(wc -c < "$HELPER" 2>/dev/null)
        log "      FDKA helper 自我抽取：$HELPER 字节=$HB md5=$(md5sum $HELPER 2>/dev/null | cut -c1-32)(0 字节＝抽取失败，绝不起循环)"
        if [ "${HB:-0}" -gt 200 ] 2>/dev/null; then
            setsid nohup sh "$HELPER" </dev/null >>"$LOGK" 2>&1 &
            sleep 2
            if grep -aq 'FDKA START' "$LOGK" 2>/dev/null; then
                log "      FDKA 循环在跑(日志有 START 行)：$(grep -a 'FDKA ' $LOGK | tail -2 | tr '\n' '|')"
            else
                log "      FDKA ★循环没留下 START 行 ⇒ 这一格未成立(日志 $(wc -c < $LOGK 2>/dev/null) 字节)，别当它在跑"
            fi
        else
            log "      FDKA ★helper 抽取不成(字节=$HB) ⇒ 不起循环；牌子仍只有 RACE 那 30 秒"
        fi
    else
        log "      FDKA 开关不在 ⇒ 整块不做(交付形状不变)"
    fi
    runcon u:r:shell:s0 am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1
    am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1
    MPID=""
    for q in $(seq 1 40); do
        sleep 3
        MPID=$(pidof $MGRPKG | cut -d' ' -f1)
        [ -n "$MPID" ] && { log "      轮询 $((q*3))s 后拿到 Manager pid=$MPID"; break; }
    done
    [ -n "$MPID" ] || log "      !! 等满 120s 仍没有 Manager 进程 ⇒ fd 装不上，这一格不算"
    log "      官方 Manager pid=[$MPID]  (root 侧 am start 起不来是已知的，起不来就 PC 侧来)"
    if [ -n "$MPID" ]; then
        echo "$MPID" > /proc/ksu_install_fd 2>/dev/null && log "      已 echo $MPID > /proc/ksu_install_fd" || log "      ★写触发口失败 ⇒ 这一格没成立"
        sleep 3
        grep -a "KSUFDINST" "$LIVE" 2>/dev/null | tail -5
        log "      判据：应当出现 \"回调跑在 pid=$MPID comm=[weishu.kernelsu] 里 => fd=N\""
    fi
    # ===== ★ksu_keep_auto：让"常驻补装"在开窗时自己起来（默认关 ⇒ 交付形状逐字不变）=====
    #   为什么要有它：fd 只属于"那一个进程"，管理器被回收/被划掉后再打开就回「不支持」，
    #   而补装腿原来要人手敲一条 `am start … "@sushd:… b8_keep.sh"` —— 这一步最容易漏，
    #   漏了就会被误判成"这套东西不稳"。stage 自己就是 root，直接 setsid 起，开窗完即常驻。
    #   ★准入条件（别放宽）：b8_keep 稳态只做一件事——`pidof`；pid 不变就一个字节都不写。
    #     会 force-stop/重启 App 的腿（w625_seedrestart）绝不许这样常驻，那是 fork 风暴的形状。
    #   ★kill switch：/data/local/tmp/b8_keep。收窗件必须删它（它也把这个开关一起删）。
    #   ★22:58 一手：`adb push` 会把目标建成 0666（**没有执行位**），而我第一版这里的判据写的是 `[ -x ]`、
    #     且 chmod 排在判据之后 ⇒ 永远进不来，日志只会打"开关不在或不可执行"（当晚那一窗就这么空跑了一次）。
    #     ⇒ 判据改成 `[ -f ]`，chmod 提前，真正起的时候一律 `sh 脚本`（执行位无关）。
    if [ -e /data/local/tmp/ksu_keep_auto ] && [ -f /data/local/tmp/b8_keep.sh ]; then
        chmod 755 /data/local/tmp/b8_keep.sh
        : > /data/local/tmp/b8_keep
        # 去重：同一窗口里派多次会叠成多个循环（22:58 实测一次派单出现两个 root 实例）
        for _kp in $(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print $1}'); do
            kill "$_kp" 2>/dev/null
        done
        setsid /system/bin/sh /data/local/tmp/b8_keep.sh >/dev/null 2>&1 &
        sleep 2
        KP=$(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print $1}' | tr '\n' ',')
        log "  ★KEEP_AUTO 已起：pid=[$KP] 开关=$(ls -l /data/local/tmp/b8_keep 2>&1 | cut -c1-40)"
        log "  ★KEEP_AUTO 日志=$(grep -a -e START -e INJ /data/local/tmp/b8_keep.log 2>/dev/null | tail -2 | tr '\n' '|')"
        [ -n "$KP" ] || log "  [!] KEEP_AUTO 没留下进程 ⇒ 这一格按没起来算(不影响装载)"
    else
        log "  ksu_keep_auto 开关不在或 b8_keep.sh 不可执行 ⇒ 不起常驻补装(交付形状不变)"
    fi
    sync
    log "  sushd: pid=[$(pidof ksuctl | tr ' ' ',')] 日志 $(wc -c < /data/local/tmp/sushd.log 2>/dev/null) 字节"
    # ★#103 的判据不是"runcon 没报错"，而是**守护自己的真实上下文**(例49/例52：取值那格要能区分"没值"和"取不到")。
    #   上一版写的是 `ps -AZ`——这台机的 toybox 不认这个拼法(报 "MZ is not an option")，静默变空 ⇒ 等于没测(例59 同族)。
    #   改成直接读 `/proc/<pid>/attr/current`：不依赖 ps 的参数口径，也不依赖 PATH。
    for p in $(pidof ksuctl); do
        log "      pid=$p 域=[$(cat /proc/$p/attr/current 2>&1)] 命令=[$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-60)]"
    done
    head -4 /data/local/tmp/sushd.log 2>/dev/null | sed 's/^/      /'
    # ★★§6.360③/#145：NOSUW=1 ⇒ bind 由 stage 自己在这段 Permissive 相里做掉(原来靠 suw 的 @sushd 派发)。
    #   ★只做 w135_fix.sh 的 [2] 那块，并且**前置一条硬闸：mountinfo 里必须一条 pbin 都没有**才许 bind——
    #   在"源目录已删但仍挂着"那个坏态上叠一层 bind 正是 w135_fix 被造出来的原因(例 105：修复动作不许排在坏态之后还继续做)。
    #   末端证人＝NOSUW_BIND_RC / NOSUW_SU_AT_TGT / NOSUW_HEALTH 三行；NOSUW=0 时这一整块不执行(交付形状逐字不变)。
    if [ "$NOSUW" = 1 ]; then
        log "----- ★NOSUW：bind /product/bin 归 stage(不派给 suw) -----"
        # ★§6.426：bind 的源从 /data/local/tmp/pbin 挪进 **root-only 的 /data/adb/ksu/pbin**。
        #   今晚一手：旧位置谁都能 rm -rf(普通脚本/app 都删得动) ⇒ 源被删后 bind 变 `/local/tmp/pbin//deleted`
        #   ⇒ **整层 /product/bin 在进程眼里是空目录**，而官方 Manager 的 su 只有裸串 `su`(dex 里没有任何绝对 su 路径)
        #   ⇒ 它那支 PATH 解析命中的就是这里。名字仍叫 pbin：下面那条 mountinfo 硬闸的 grep 不用改。
        NB2=/data/adb/ksu/pbin
        ML=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null)
        SB2=/data/local/tmp/sustatic
        log "  前置闸一：mountinfo 里 pbin 行数=$ML  ★必须=0 才许 bind"
        log "  前置闸二：bind 的源 $SB2 字节=$(wc -c < $SB2 2>/dev/null) md5=$(md5sum $SB2 2>/dev/null | cut -c1-32)  ★必须非空(这条腿在 insmod 之后跑，源是谁推的要说得清)"
        if [ ! -s "$SB2" ]; then
            log "  [x] $SB2 不在或为空 ⇒ **不做 bind**（宁可这一格判据没测到，也不挂一个空壳进 /product/bin）"
        elif [ "${ML:-1}" = 0 ]; then
            rm -rf "$NB2"; mkdir -p "$NB2"
            cp -a /product/bin/. "$NB2/" 2>/dev/null
            cp "$SB2" "$NB2/su" 2>/dev/null
            chmod 755 "$NB2" "$NB2/su" 2>/dev/null
            mount --bind "$NB2" /product/bin
            log "  NOSUW_BIND_RC=$?  NOSUW_SU_AT_TGT=$(ls -l /product/bin/su 2>&1 | tail -1)"
            # ★§6.426 第二段：把落点副本收进 root-only 目录，再拉起**维持循环**(开关文件＝kill switch；节拍 20 秒、上限 200 次、
            #   连续 3 次修不好就 GIVEUP——§6.198 那次 fork 风暴连着敲出过 PS_HOLD，所以绝不做成 1 秒节拍)。
            cp "$SB2" /data/adb/ksu/sustatic 2>/dev/null
            : > /data/local/tmp/ksu_pbin_keep 2>/dev/null
            nohup /system/bin/sh /data/local/tmp/w774_pbin_keeper.sh >/dev/null 2>&1 &
            log "  NOSUW_KEEPER_PID=$(cat /data/local/tmp/w774_keeper.log 2>/dev/null | head -1 | cut -c1-40) 开关=$(ls -l /data/local/tmp/ksu_pbin_keep 2>&1 | cut -c1-46) rootonly源=$(ls -ld /data/adb/ksu/pbin 2>&1 | cut -c1-44)"
            log "  NOSUW_CP_N=$(ls -A $NB2 2>/dev/null | wc -l) NOSUW_HEALTH=$([ "$(/system/bin/sh -c 'echo yes' 2>&1)" = yes ] && echo OK || echo DEAD)"
            log "  挂载读回=$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-120 | tr '\n' '|')"
            # ★★B4 一手(11-12 17:0x)：官方 Manager 的"获取 Root 失败"是**进程启动时一次性分支**——
            #   它在上面那次 am start(up≈860) 就查过一次 su，而 bind 到 up≈880 才完成 ⇒ 那一屏永远消不掉。
            #   实测两条死路：①重造 Activity(同进程 --activity-clear-top) 不重查，两轮后仍是「获取 Root 失败」；
            #   ②重启进程会丢驱动 fd ⇒ 直接退回「不支持」(fd 是 LKM 牌子的硬需求，光有 su 不够)。
            #   ⇒ 正解只有一条：**让 su 与 fd 在它出生前都在**——bind 完成后重起一次，并且
            #   **先开 0.2s 抢装循环再 am start**(与 RACE 同一机制，只是这次循环是为了这一次起机而开的)。
            #   生效证人＝NOSUW_RACE2 抢装 pid=… ／ NOSUW_MGR2_PID=… ／ NOSUW_MGR2_FD=(该 pid 的回调条数)
            log "  ★NOSUW：bind 已完成 ⇒ 重起官方 Manager(su 与 fd 都必须在它出生前就位)"
            runcon u:r:shell:s0 am force-stop $MGRPKG >/dev/null 2>&1
            am force-stop $MGRPKG >/dev/null 2>&1
            sleep 1
            ( i=0; LP=""
              while [ "$i" -lt 60 ]; do
                  i=$((i+1))
                  P2=$(pidof $MGRPKG 2>/dev/null | cut -d' ' -f1)
                  case "$P2" in ''|*[!0-9]*) P2="" ;; esac
                  if [ -n "$P2" ] && [ "$P2" != "$LP" ]; then
                      if echo "$P2" > /proc/ksu_install_fd 2>/dev/null; then
                          log "      NOSUW_RACE2 抢装 pid=$P2 第 $i 轮"
                      else
                          log "      NOSUW_RACE2 写口失败 pid=$P2 第 $i 轮"
                      fi
                      LP="$P2"
                  fi
                  sleep 0.2
              done ) &
            sleep 0.2
            runcon u:r:shell:s0 am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1
            am start -n $MGRPKG/.ui.MainActivity >/dev/null 2>&1
            sleep 4
            M2=$(pidof $MGRPKG 2>/dev/null | cut -d' ' -f1)
            log "  NOSUW_MGR2_PID=$M2  NOSUW_MGR2_FD=$(grep -a KSUFDINST "${LIVE:-/dev/null}" 2>/dev/null | grep -ac "pid=$M2")  NOSUW_MGR2_SU=$(ls -l /product/bin/su 2>&1 | tail -1)"
        else
            log "  [x] 有残留挂载($ML 行) ⇒ **不做 bind**，也不去 umount：这一发的 bind 判据按没测到算"
        fi
    fi
    log "===== 信号探针(必须在 app 触发之前挂，杀发生在触发之后) ====="
    ftrace_arm
    log "===== 回归对照：passfd 10284(内核侧那条，已复现 4 次) ====="
    log "      与 app 那条唯一的区别 = 收 fd 的是 ksuctl 的 fork 子进程(单线程、非 app 域)，"
    log "      所以'app 失败而 passfd 成功'只可能是 app 域/SELinux/多线程语义差异，不再是内核侧。"
    "$CTL" passfd $SUWID 6   # ★第 3 个参数=授权后再活 6s 并每秒 open 一次 /data/local/tmp(§6.68 的分叉判据)
    log "passfd rc=$? ⇒ 看子进程那行 uid 是否从 10284 变 0"
    APP_PID=$(pidof $PKG | cut -d' ' -f1)
    log "===== 判据④：等 app 侧报告(PC 侧 `am start --es auto ksuarm` 触发)，上限 $((WAIT_LOOPS * 3))s ====="
    log "触发前 app pid=[$APP_PID] 报告文件=$APP_REPORT"
    fix_uts   # ★app 是在这一步才起来的 ⇒ uts 坏了就等于这一格白等(窗口 97 整发就是这么废的)
    i=0
    while [ "$i" -lt "$WAIT_LOOPS" ]; do
        if [ -f "$APP_REPORT" ]; then
            SZ=$(wc -c < "$APP_REPORT" 2>/dev/null)
            MT=$(stat -c %Y "$APP_REPORT" 2>/dev/null)
            [ -n "$SZ" ] && [ "$SZ" -gt 300 ] && [ -n "$MT" ] && [ "$MT" -ge "$T0" ] && break
        fi
        if [ $((i % 4)) = "0" ]; then           # ★每 4 轮(≈12s)扫一次，别自己造 execve 风暴
            APP_PID=$(pidof $PKG | cut -d' ' -f1)
            catch_root_thread "$APP_PID"
            if [ $((i % 20)) = "0" ]; then fix_uts; fi   # 兼心跳：这行印"正常，不动"=uts 一直是好的
        fi
        i=$((i + 1))
        sleep 3
    done
    log "等了 $((i * 3))s，app 报告 = $(ls -l $APP_REPORT 2>&1 | tr -s ' ')"
    if [ -f "$APP_REPORT" ]; then
        cp "$APP_REPORT" "$APP_COPY" 2>/dev/null
        chmod 666 "$APP_COPY" 2>/dev/null
        log "----- app 侧报告全文 -----"
        cat "$APP_REPORT"
    else
        log "!! 没有 app 报告 ⇒ 触发没到位(am start 失败 / 进程没起 / JNI 没加载)，本发拿不到 app 侧结论"
    fi
    sync
    log "===== 外部证据(第三个来源)：等 armed 版报告，按它印的子进程 pid 读 /proc ====="
    # ★v29 修正：以前读的是 APP_COPY(握手版副本，里面永远没有"子进程 pid=")⇒ 这一格永远跳过
    w=0
    while [ $w -lt 6 ]; do
        grep -q '父进程侧: 子进程' "$APP_REPORT" 2>/dev/null && break
        w=$((w + 1)); sleep 2
    done
    log "  等 armed 版报告用了 $((w * 2))s (报告 $(wc -c < "$APP_REPORT" 2>/dev/null) 字节)"
    KIDP=$(grep -oE '子进程 (pid=)?[0-9]+' "$APP_REPORT" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    if [ -n "$KIDP" ]; then
        log "  子进程 pid=$KIDP 的 Uid 行 = [$(grep -m1 '^Uid:' /proc/$KIDP/status 2>&1 | cut -c1-40)]"
        log "  CapEff = [$(grep -m1 '^CapEff:' /proc/$KIDP/status 2>&1 | tr -d '	')]  comm=[$(cat /proc/$KIDP/comm 2>&1)]"
        log "  State  = [$(grep -m1 '^State:' /proc/$KIDP/status 2>&1)]"
        log "  ★读不到(No such file)=子进程已退出；一直在且 State=D ⇒ 就是 §6.63 那个 FUSE 堵死"
    else
        log "  报告里没有『子进程 pid=』⇒ 这一格跳过(armed 触发没到位?)"
    fi
    # ★子进程留在**普通文件系统**(f2fs，不是 FUSE)上的两份东西：自己的日志 + exec 的输出
    log "===== 信号探针落盘(等 PC 侧发 dump 口令，上限 150s：fast+daemon 两支都要覆盖) ====="
    d=0
    while [ $d -lt 75 ]; do
        [ -e /data/local/tmp/ksu_dump_now ] && break
        sleep 2
        d=$((d + 1))
    done
    log "  等 dump 口令用了 $((d * 2))s"
    ftrace_dump
    log "----- 子进程产物：模块能不能用 root 跑命令就看 suw_cmd.out 这一格 -----"
    for f in /data/local/tmp/suw_child.log /data/local/tmp/suw_cmd.out /data/data/com.suw.manager/files/child.log /data/local/tmp/suw_cmd_fast.out /data/local/tmp/suw_cmd_daemon.out; do
        if [ -f "$f" ]; then
            chmod 666 "$f" 2>/dev/null
            log "  $f:"
            sed 's/^/      /' "$f"
        else
            log "  $f 不存在 ⇒ 子进程没走到那一步"
        fi
    done
    if grep -q 'uid=0(root)' /data/local/tmp/suw_cmd.out 2>/dev/null; then
        log "  ★★★ app 生的 root 子进程成功 exec 并以 uid 0 运行 ⇒ 模块的 su 原语成立"
    else
        log "  suw_cmd.out 里没有 uid=0(root) ⇒ 这一格没成立，看 suw_child.log 里的 exec 失败行"
    fi

    log "===== 外部证据收尾：再扫一次 app 的线程 uid，并列出全部线程 uid 分布 ====="
    APP_PID=$(pidof $PKG | cut -d' ' -f1)
    log "app pid=[$APP_PID] 线程数=$(ls /proc/$APP_PID/task 2>/dev/null | wc -l)"
    catch_root_thread "$APP_PID"
    grep -h '^Uid:' /proc/$APP_PID/task/*/status 2>/dev/null | sort | uniq -c | head -10
    sync

    log "===== 内核侧对账：KSUBEAT X*(escape 内部阶梯) 最近 30 行 ====="
    grep -E 'KSUBEAT X[0-9A-C]' "$LIVE" | tail -30
    log "===== 判据计数(活落盘) ====="
    for k in 'KSUBEAT P1' 'KSUBEAT P4' 'KSUBEAT A ' 'patch syscall' 'KSUBEAT SU0' 'KSUBEAT SU4' 'KSUBEAT X0' 'KSUBEAT X7' 'KSUBEAT X8' 'KSUBEAT XA' 'KSUBEAT XB' 'KSUBEAT XC' 'KSUBEAT BN' 'KSUBEAT SD1' 'sys_execve su found' 'Unable to handle' 'Call trace'; do
        printf '  %s =' "$k"; grep -c "$k" "$LIVE" 2>/dev/null
    done
    sync
    log "===== 模块战线(窗口内 runner，marker 驱动) ====="
    log "      为什么能在这里做：模块从来不是\"管理器\"加载的，是 root 侧 runner 加载的 ⇒"
    log "      不需要第三方 Manager，也不需要啃 seccomp。边界见 §6.61/§6.62。"
    if [ -f /data/local/tmp/testmod.zip ]; then
        rm -rf /data/local/tmp/mod
        mkdir -p /data/local/tmp/mod
        unzip -o -q /data/local/tmp/testmod.zip -d /data/local/tmp/mod 2>&1 | head -3
        log "  解开: $(find /data/local/tmp/mod -type f 2>/dev/null | tr '
' ' ')"
        sh /data/local/tmp/ksu_module_apply.sh /data/local/tmp/mod
        log "  apply rc=$? up=$(upt)"
        log "----- apply 日志全文 -----"
        cat /data/local/tmp/ksu_mod_apply.log 2>&1
        sync
        log "----- 清场(不留持久化) -----"
        sh /data/local/tmp/ksu_module_teardown.sh /data/local/tmp/mod
        log "  teardown rc=$?"
        cat /data/local/tmp/ksu_mod_teardown.log 2>&1
        sync
    else
        log "  没有 /data/local/tmp/testmod.zip ⇒ 这一发不带模块(不影响授权判据)"
    fi

    log "===== 判据⑤(v43 新增)：官方 Manager UI ↔ KSU 名单闭环，等 PC 侧 marker ksu_ui_done，上限 ${UI_LOOPS:-60}x10s ====="
    log "      口径：目标是\"最后我只需要使用 kernelsu 授权\"。insmod 时内核自报过"
    log "      'Crowning manager: me.weishu.kernelsu(uid=10758)' ⇒ 官方 Manager 过了 ko 的签名校验。"
    log "      这一格要的是**双向**：UI 关掉的瞬间 granted 必须变 0，打开必须变回 1。"
    rm -f /data/local/tmp/ksu_ui_done /data/local/tmp/ksu_ui_track.txt 2>/dev/null
    touch /data/local/tmp/ksu_ui_track.txt 2>/dev/null
    n=0
    # ★上限从 60x10s 砍到 3x10s：官方 UI 那条支路 §6.81 已经判死(它靠 libsu RootService 起 root
    #   进程枚举应用，而那条支路被 vr 挡死)，留这三格只是走个形式，别把 10 分钟窗口喂给它。
    while [ ! -e /data/local/tmp/ksu_ui_done ] && [ $n -lt ${UI_LOOPS:-3} ]; do
        n=$((n + 1))
        {
            echo "-- t+$((n * 10))s up=$(upt)"
            /data/local/tmp/ksuctl mgr 2>&1
            /data/local/tmp/ksuctl granted $SUWID 2>&1
            /data/local/tmp/ksuctl granted $MGRID 2>&1
            /data/local/tmp/ksuctl allowlist 2>&1 | head -8
        } >>/data/local/tmp/ksu_ui_track.txt 2>&1
        sync
        if [ $((n % 6)) -eq 0 ]; then
            log "  心跳 t+$((n * 10))s granted10284=[$(grep -o 'granted=[0-9]*' /data/local/tmp/ksu_ui_track.txt | tail -2 | tr '\n' ' ')]"
        fi
        sleep 10
    done
    log "  UI 闸门退出：marker=$([ -e /data/local/tmp/ksu_ui_done ] && echo 有 || echo 无) n=$n"
    log "----- ksu_ui_track.txt 的阶梯(granted/名单长度 随 UI 点开关而变) -----"
    grep -E 'UID_GRANTED_ROOT|NEW_GET_ALLOW_LIST|^-- t' /data/local/tmp/ksu_ui_track.txt 2>/dev/null | tail -45
    sync

    kill $LV 2>/dev/null
    log "===== 不 rmmod(本 boot 内留着，重启即消失) ====="
fi
log "===== 收尾：整份 dmesg (up=$(upt)) ====="
if [ -f /data/local/tmp/ksu_cleanup ]; then
    log "===== ★★不留持久化：删掉 KSU 侧全部落地文件(有 ksu_cleanup 标记才做) ====="
    rm -rf /data/adb/ksu /data/adb/ksud
    rm -f /data/local/tmp/kernelsu.ko /data/local/tmp/susm /data/local/tmp/a10284.bin \
          /data/local/tmp/allow.bin /data/local/tmp/bn_before.txt
    # ★§6.285：这里原来还 rm 了 dmesg.live，而脚本末尾(≈第 840 行)才 `dmesg | tail -c 200000 >> "$LIVE"`
    #   ⇒ 顺序反了：活落盘整段(含装载期)被我们自己销毁，拉回来的那份按构造只剩整环尾块。
    #   dmesg.live 是纯日志、没有能力，PC 侧收尾会删；别再在这里删它。
    # ★v29.1：**不再删 ksu_post.sh / ksu_args.txt / ksu_stage.txt / ksu_cleanup**。
    #   第四十五发就是被这个脚枪废掉的：上一发的清理把 post 脚本自己删了，而我没重推 ⇒
    #   链打穿、pr 报 [DONE] RC=0，但**没有 post 可跑** ⇒ stage 日志一行都没有，整发白烧。
    #   这些文件没有能力(纯脚本+参数)，删它们对'不留持久化'零收益、只埋雷；要清的是
    #   /data/adb/ksu 与 /data/adb/ksud(名单+ksud)、ko、susm 这些能落地的东西。
    log "留着不动: ksu_stage.log(判据) / app_ksu.txt(app 报告副本) / ksuctl+shd(工具) —— 都由 PC 侧 pull 完再随重启失去意义"
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
