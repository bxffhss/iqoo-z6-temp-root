#!/usr/bin/env bash
# run_ringend.sh —— 给"死前整环 dump"这条腿做**双向离线自测**（不碰设备、不花钱）。
#   被测两段：①`go.sh` 的 §1.67（RING_END_DUMP 开关：铺文件＋读回；默认关＝只 rm 不铺；非法值/超范围 ⇒ rc=3 且**一条 adb 都不发**）
#             ②`ksu_one_stage.sh` 里 quiet 分支末的 dump 腿（开关文件不在⇒**一个字都不做**；在⇒等 N 秒后 dump 并逐词数 SU0/SD4/SU1/prune/load）
#   规矩（例 88/105/116/125）：幂等自测必须含"第一遍真的改了"那一格；"不加就坏"要有反例；跑被测段用 `source` 不用 `bash`（桩函数继承不到）。
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
W=$(mktemp -d)
fail=0

# ---------- 切两段出来 ----------
awk '/^echo "=== 1\.67\)/{f=1} /^echo "=== 1\.7\)/{f=0} f' kmod/go.sh > "$W/a.sh"
AN=$(wc -l < "$W/a.sh")
[ "$AN" -ge 15 ] || { echo "[x] 没切出 go.sh 的 1.67 段(行数=$AN) ⇒ 锚点失效"; exit 1; }
awk '/# ★§6\.334\/#135：死前整环 dump/{f=1} f && /^    fi$/{print; exit} f' kmod/ksu_one_stage.sh > "$W/b.sh"
BN=$(wc -l < "$W/b.sh")
[ "$BN" -ge 12 ] || { echo "[x] 没切出 stage 的 dump 腿(行数=$BN) ⇒ 锚点失效"; exit 1; }
echo "切片：go.sh 段=$AN 行，stage 腿=$BN 行"

# 设备路径整段换到临时目录，并**断言替换条数**（不数条数=不知道有没有漏网的路径写到真设备上）
for f in a.sh b.sh; do
    N1=$(grep -c '/data/local/tmp/' "$W/$f")
    sed -i 's#/data/local/tmp/#'"$W"'/#g' "$W/$f"
    N2=$(grep -c '/data/local/tmp/' "$W/$f")
    [ "$N2" = 0 ] || { echo "[x] $f 里还剩 $N2 条设备绝对路径(原 $N1 条) ⇒ 会写到真设备，停"; exit 1; }
    echo "  $f：设备路径 $N1 条已全部改写"
done
# stage 腿里 dump 的目标文件名也换一个（免得和 go 腿的开关文件混名）
sed -i 's#ksu_ring_end.txt#ring_end_dump.txt#g' "$W/b.sh"

NCHK=0
chk() { NCHK=$((NCHK+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

# ---------- A 腿：go.sh 的 §1.67 ----------
a_run() { # $1=RING_END_DUMP 值(空=不给) $2=期望 rc  $3=tag
    local v=$1 want=$2 tag=$3
    : > "$W/a_$tag.log"; : > "$W/a_$tag.calls"
    (
        cd "$W" || exit 1
        A() { echo "A[$1]" >> "$W/a_$tag.calls"
            # 切出来的这几条命令全是 printf/ls/cat/rm，路径已整段换进临时目录 ⇒ 就地执行，
            # 这样"开关文件真被写出来"与"cat 读回把内容打进明面"两格才有真产物可验(例 109/125)
            eval "$1"; }
        adb_out() { :; }
        RING_END_DUMP="$v" source "$W/a.sh" > "$W/a_$tag.out" 2>&1
    ) ; rc=$?          # ★RC 必须在子 shell **外面**取：被测段里有 `exit 3`，在里面永远打不出这行
    echo "RC=$rc" >> "$W/a_$tag.out"
    echo "----- A/$tag (RING_END_DUMP='${v:-}') -----"
    sed 's/^/    /' "$W/a_$tag.out" | head -6
    local got; got=$(sed -n 's/.*RC=\([0-9]*\).*/\1/p' "$W/a_$tag.out")
    chk "  rc=$got(期望 $want)" "$([ "${got:-x}" = "$want" ] && echo 1 || echo 0)"
}
echo
echo "=== A 腿（开关本身） ==="
a_run "" 0 off
N=$(grep -c 'printf' "$W/a_off.calls"); chk "默认关：没铺开关文件(printf 调用=$N，期望 0)" "$([ "$N" = 0 ] && echo 1 || echo 0)"
chk "默认关：发了 rm 清跨 boot 残留" "$(grep -aq 'rm -f '"$W"'/ksu_ring_end_dump' "$W/a_off.calls" && echo 1 || echo 0)"
chk "默认关：读回那行说明'形状逐字不变'" "$(grep -aq '未给 RING_END_DUMP' "$W/a_off.out" && echo 1 || echo 0)"
chk "默认关：设备上确实没有开关文件" "$([ ! -e "$W/ksu_ring_end_dump" ] && echo 1 || echo 0)"

a_run 200 0 on
chk "开：写了开关文件且内容=RING_END=200" "$([ -e "$W/ksu_ring_end_dump" ] && grep -qa 'RING_END=200' "$W/ksu_ring_end_dump" && echo 1 || echo 0)"
chk "开：cat 读回把内容打进明面" "$(grep -aq 'RING_END=200' "$W/a_on.out" && echo 1 || echo 0)"
chk "开：打了'stage 必须出现两行生效证人'的提示" "$(grep -aq '★RING_END 腿在跑' "$W/a_on.out" && echo 1 || echo 0)"
rm -f "$W/ksu_ring_end_dump"

a_run '200;reboot' 3 inj
N=$(grep -c '^A\[' "$W/a_inj.calls"); chk "注入型非法值：rc=3 且**一条 adb 都没发**(A 调用=$N)" "$([ "$N" = 0 ] && echo 1 || echo 0)"
chk "注入型非法值：没留下开关文件" "$([ ! -e "$W/ksu_ring_end_dump" ] && echo 1 || echo 0)"

a_run 10 3 rng
chk "超范围(10 秒)：rc=3 拦下" "$(grep -aq '30..900' "$W/a_rng.out" && echo 1 || echo 0)"
rm -f "$W/ksu_ring_end_dump"

# ---------- B 腿：stage 的 dump 腿 ----------
echo
echo "=== B 腿（stage 里的 dump 与逐词计数） ==="
b_run() { # $1=开关文件内容(空=不放文件) $2=tag
    local v=$1 tag=$2
    rm -f "$W/ksu_ring_end_dump" "$W/ring_end_dump.txt" "$W/dmesg.live"
    if [ -n "$v" ]; then printf '%s\n' "$v" > "$W/ksu_ring_end_dump"; fi
    : > "$W/b_$tag.out"
    (
        cd "$W" || exit 1
        log() { echo "$1" >> "$W/b_$tag.out"; }
        upt() { echo "123.45"; }
        dmesg() { cat "$W/fake_ring.txt"; }      # ★用生产件行形状(<N.N>＋KernelSU:)喂真计数腿
        source "$W/b.sh" >> "$W/b_$tag.out" 2>&1   # ★真 stage 顶部有 `exec >>"$OUT" 2>&1`，裸 stdout 也进日志 ⇒ harness 要接住
    )
    echo "----- B/$tag (开关=[${v:-无}]) -----"
    sed 's/^/    /' "$W/b_$tag.out"
}
# 假整环：2 行 SU0、1 行 SD4、1 行 SU1、1 行 load_allow_uid、0 行 prune（★`<6>` 前缀那种行形状也放一条，防例 121）
printf '%s\n' \
 '[  100.100000] KernelSU: load_allow_uid, name: com.suw.manager, uid: 10342, allow: 1' \
 '<6>[  100.200000] KernelSU: KSUBEAT SU0 su found: pid=999 comm=su uid=10342 no_escape=1 no_cred_override=1' \
 '[  100.300000] KernelSU: KSUBEAT SU0 su found: pid=998 comm=su uid=10342 no_escape=1 no_cred_override=1' \
 '[  100.400000] KernelSU: KSUBEAT SD4 su 命中，开始拿 fd: pid=998 uid=10342' \
 '[  100.500000] KernelSU: KSUBEAT SU1 before filp_open: tmp_fd=7 no_cred_override=1' \
 '[  100.600000] KernelSU: KSUBEAT SD1 decline: uid=0 是 system uid' > "$W/fake_ring.txt"
b_run "" absent
N=$(wc -l < "$W/b_absent.out")
chk "开关不在⇒这段一个字都不做(输出行数=$N，期望 0)" "$([ "$N" = 0 ] && echo 1 || echo 0)"
chk "开关不在⇒没产出 dump 件" "$([ ! -e "$W/ring_end_dump.txt" ] && echo 1 || echo 0)"

b_run "RING_END=0" present
chk "开：dump 腿打了'★RING_END 腿在跑'" "$(grep -aq '★RING_END 腿在跑' "$W/b_present.out" && echo 1 || echo 0)"
chk "开：打了'★dump 完'与逐词计数行" "$(grep -aq '★dump 完' "$W/b_present.out" && grep -aq '判据本体' "$W/b_present.out" && echo 1 || echo 0)"
chk "★牙：计数真从件里数出来(SU0=2 SD4=1 SU1=1 load=1 prune=0，含 <6> 前缀行也没漏)" \
    "$(grep -aq 'SU0=2 SD4=1 SU1=1 prune=0 load=1' "$W/b_present.out" && echo 1 || echo 0)"
chk "★牙：命中行原文也落进了日志(带缩进数到 2 行 SU0)" "$([ "$(grep -ac '^ *\[ *[0-9]*\.\|      \[  100' "$W/b_present.out" >/dev/null 2>&1; grep -ac '      \[  100' "$W/b_present.out")" -ge 2 ] && echo 1 || echo 0)"

echo
[ "$fail" = 0 ] && echo "=== run_ringend 自测 PASS($NCHK 项，条数由 chk 自己数) ===" || echo "=== FAIL($NCHK 项里有红) ==="
echo "临时件留在 $W"
exit "$fail"
