#!/system/bin/sh
# w731_root_sampler.sh —— 第 52 发的 root 侧采样器(判据 4/6 的一半)：只读 /proc 与 dmesg，**绝不碰 UI**。
#   ★为什么要"自己甩后台"而不是一格一次 rleg：每次 `@sushd:` 派单都会把 suw 顶到前台 ⇒ 被测的 Manager 丢焦点
#     ⇒ 读到的牌子就是仪器自己造的假读数(记忆那条"每读完要拉回前台"在这里等于把干扰做成了节拍)。
#     所以只派**一次**：外层立刻交 DONE，循环以 `--loop` 模式被 nohup 甩后台。
#   ★形状第二条(本轮现场踩出来的)：**循环体绝不套 `sh -c '...'`** —— 内层那些单引号会与外层配对，
#     `bash -n` 照样过但语义已经变了(例 176 那一族：语法过≠形状对)。⇒ 用"自己带参数再叫自己一次"这条干净路子。
#   ★每条读数自己带 `up=`(排序只认同源 up)；产物名固定 ⇒ 派前 rm，一份一发(例 176④：同名的第二次调用会覆盖第一次)。
L=${W731_L:-/data/local/tmp/w731_root.txt}
D=${W731_DMSG:-/data/local/tmp/w731_dmesg.txt}
PIDF=${W731_PIDF:-/data/local/tmp/w731_root.pid}
OUT=${W731_OUT:-/data/local/tmp/w731_root_sampler.out}
PKG=${W731_PKG:-me.weishu.kernelsu}
N=${W731_N:-34}          # 34 轮 × 15 秒 ≈ 8.5 分钟(用户报的量级是 0.5 分钟，这里放大 16 倍再采)
STEP=${W731_STEP:-15}

# ===== 抽取那组字段：自检与被测走**同一份函数**，不另写一遍(否则自测绿≠读数对) =====
kb_total() { printf '%s\n' "$1" | grep -ac .; }
kb_q()     { printf '%s\n' "$1" | grep -ac 'queued self fd'; }
kb_seen()  { printf '%s\n' "$1" | grep -ac 'seen Manager'; }
kb_dup()   { printf '%s\n' "$1" | grep -a 'dupskip n=' | tail -1 | grep -ao 'n=[0-9]*' | tr -dc '0-9'; }
kb_tot()   { printf '%s\n' "$1" | grep -a 'queued self fd' | tail -1 | grep -ao 'total=[0-9]*' | tr -dc '0-9'; }
kb_cap()   { printf '%s\n' "$1" | grep -ac 'KSUBIRTH cap'; }
kb_su()    { grep -acE 'KSUBEAT (SU0|SD4|SU1)' "$1" 2>/dev/null | tr -dc '0-9'; }
kb_sig6()  { grep -ac 'received signal 6' "$1" 2>/dev/null | tr -dc '0-9'; }

if [ "${1:-}" = selfcheck ]; then      # 离线自检：PC bash 与设备 mksh 都能跑，不碰 /proc
    echo "=== W731 selfcheck(离线：证的是抽取形状，不是真机读数) ==="
    # 夹具落哪儿要**按平台现选**(这条是自己踩出来的：写死 /data/local/tmp 在 PC 上跑 selfcheck 会整组判红)
    if [ -d /data/local/tmp ]; then FXD=/data/local/tmp/w731_fix.txt; else FXD=${TMPDIR:-/tmp}/w731_fix.txt; fi
    FIX=${W731_FIX:-$FXD}
    printf '%s\n' \
        "[ 100.1] KSUBIRTH seen Manager pid=9 uid=10104 start=1 total=3 slots=3 - queue" \
        "[ 100.2] KSUBIRTH queued self fd pid=9 comm=[usap64] total=3 slots=3" \
        "[ 101.0] KSUBIRTH dupskip n=4096 pid=9 - already queued for this exact process" \
        "[ 102.0] KSUBIRTH dupskip n=78849 pid=12 - already queued for this exact process" \
        "[ 103.0] KernelSU: KSUBEAT SU0 redirect ok" \
        "[ 103.1] KernelSU: KSUBEAT BN dispatcher entered" \
        "[ 104.0] KernelSU: KSUBEAT F sys_enter fired" \
        "[ 105.0] some vendor line that must not count" \
        "[ 106.0] KSUBIR" > "$FIX"
    KL=$(grep -a KSUBIRTH "$FIX")
    fail=0
    chk() { if [ "$2" = "$3" ]; then echo "  [OK] $1 = $2"; else echo "  [BAD] $1 = [$2] 应为 [$3]"; fail=1; fi; }
    chk KSUBIRTH_行数 "$(kb_total "$KL")" 4     # ★现数过：夹具九行里含 KSUBIRTH 的只有 4 行；末那条半行 `KSUBIR` 不算(4 不是 5)
    chk queued "$(kb_q "$KL")" 1
    chk seen "$(kb_seen "$KL")" 1
    chk dupskip_n "$(kb_dup "$KL")" 78849      # ★取**末**条(时间序)，不是取最大/最小
    chk total现值 "$(kb_tot "$KL")" 3
    chk cap "$(kb_cap "$KL")" 0                # ★夹具里一条没踢 ⇒ 0(也反证"字段缺失不会被读成非零")
    chk SU链 "$(kb_su "$FIX")" 1               # ★只有 SU0 进这列；`BN dispatcher`/`F sys_enter` 不许进
    chk signal6 "$(kb_sig6 "$FIX")" 0
    rm -f "$FIX" 2>/dev/null
    [ "$fail" = 0 ] || { echo "[x] 抽取形状不对 ⇒ 这条腿的读数一律不可用"; exit 1; }
    echo "  节拍=$STEP 秒 × $N 轮 = 约 $((N * STEP)) 秒；真读数只看 $L"
    echo "PASS"
    exit 0
fi

if [ "${1:-}" = "--loop" ]; then
    i=0
    while [ "$i" -lt "$N" ]; do
        i=$((i + 1))
        UP=$(cut -d ' ' -f1 /proc/uptime)
        P=$(pidof "$PKG" 2>/dev/null | cut -d ' ' -f1)
        if [ -z "$P" ]; then
            echo "$i up=$UP pid=无 !!!Manager 不在——这本身就是要记的事件" >> "$L"
            sleep "$STEP"
            continue
        fi
        FDK=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver)
        FDT=$(ls -1 /proc/$P/fd 2>/dev/null | grep -ac .)
        SEC=$(grep -aE '^Seccomp:' /proc/$P/status 2>/dev/null | tr -dc '0-9')
        COM=$(tr -d '\0' < /proc/$P/cmdline 2>/dev/null | cut -c1-34)
        dmesg > "$D" 2>/dev/null
        KL=$(grep -a KSUBIRTH "$D" 2>/dev/null)
        BYTES=$(wc -c < "$D" 2>/dev/null | tr -dc '0-9')
        echo "$i up=$UP pid=$P fd_ksu=$FDK fd_总数=$FDT Seccomp=${SEC:-读不到} comm=[${COM:-无}] dmesg字节=${BYTES:-0} KSUBIRTH_总=$(kb_total "$KL") queued=$(kb_q "$KL") seen=$(kb_seen "$KL") dupskip_n=$(kb_dup "$KL") total现值=$(kb_tot "$KL") cap=$(kb_cap "$KL") SU链=$(kb_su "$D") signal6=$(kb_sig6 "$D")" >> "$L"
        sleep "$STEP"
    done
    echo "END up=$(cut -d ' ' -f1 /proc/uptime) 行数=$(grep -ac . "$L") 末行=[$(tail -1 "$L" | cut -c1-90)]" >> "$L"
    exit 0
fi

# ===== 默认那一趟：只把循环甩后台，然后立刻交回执 =====
echo "=== W731 起 up=$(cut -d ' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) N=$N STEP=$STEP 产物=$L ===" > "$OUT"
rm -f "$L" "$PIDF" "$D" 2>/dev/null
SELF=$0
[ -f "$SELF" ] || SELF=/data/local/tmp/w731_root_sampler.sh
nohup sh "$SELF" --loop >/dev/null 2>&1 &
echo $! > "$PIDF"
sleep 2
echo "  后台已起：pidfile=$PIDF 内容=$(cat $PIDF 2>/dev/null)；循环件=$(test -f "$L" && echo 在 || echo 还没有)" >> "$OUT"
echo "  ★第一拍要 $STEP 秒后才落 $L(现在还没有=正常，不是失败)；这 $((N * STEP)) 秒里**别再派任何 rleg 腿**(suw 顶前台会改掉焦点)，导航只由 w732 那两格做" >> "$OUT"
echo "  ★分家口径：牌子灭的那一行要跟这里**同 up** 对齐 pid / fd_ksu / Seccomp / SU链 —— 单边读数一律不下结论" >> "$OUT"
echo "=== DONE ===" >> "$OUT"
