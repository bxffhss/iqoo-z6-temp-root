#!/usr/bin/env bash
# run_dumpleg.sh —— 给收尾件新增的 **T2.8(诊断 dump：pull＋gzip 存证，之后 T3 才删设备侧)** 做离线双向自测(不碰设备)。
#   五格：①两件都在且两端 md5 相符 ⇒ 必须"存下 2"、留 .gz、原始件已删、**解回来 md5 对得上**；
#         ②两端 md5 不符 ⇒ 本机那份必须被删(不许留坏读数)；
#         ③adb 谎报成功、本机 0 字节 ⇒ 不许留空存证件；
#         ④设备侧本来没有 ⇒ 只许记"没有"，一条 artifacts 都不许产生；
#         ⑤压缩件解回不符 ⇒ 必须**删压缩件、留原始件**(不能两头都丢)。
#   ★切片边界的牙(例 88/116)：切片里必须有 gunzip 与计数器，且**不许把 T3 的 rm 吞进来**(吞了就变成"先删再 pull")。
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
W=$(mktemp -d)
mkdir -p "$W/kmod/w103_evidence"
awk '/=== T2\.8\)/{f=1} /=== T3\)/{f=0} f' kmod/w161_teardown.sh > "$W/block.sh"
[ -s "$W/block.sh" ] || { echo "[x] 没能切出 T2.8 ⇒ 起点锚失效"; exit 1; }
grep -q 'gunzip -c' "$W/block.sh" || { echo "[x] 切片里没有解回那一步 ⇒ 起点锚错了"; exit 1; }
grep -q 'DP_OK=' "$W/block.sh" || { echo "[x] 切片里没有计数器 ⇒ 内容不对"; exit 1; }
grep -q 'rm -f /data/local/tmp/w161_' "$W/block.sh" && { echo "[x] 切片把 T3 的 rm 吞进来了 ⇒ 终点锚失效，那样顺序就反了"; exit 1; }
echo "切片行数=$(wc -l < "$W/block.sh")"
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

# 造两份合成原件(放仓库内，不放 /tmp——Windows adb 看不见 MSYS 路径)
mk_dump() { printf 'LINE1 abc\nCFIFIX x\nLINE3 def\n' > "$ROOT/kmod/_tmp_selftest_rdst/dp_$1.txt"; }
mk_dump a; mk_dump b
#   ★两份夹具内容必须**不同**(原来两者逐字节相同 ⇒ MA=MB，"pull 拿错件"这种错根本过不了 md5 闸，
#     这一格看着有牙其实没牙；⑥那格就是靠这个差别才真能判"接没接上腿")。
printf 'PREV-B 与 dp_a 不同的内容\n' >> "$ROOT/kmod/_tmp_selftest_rdst/dp_b.txt"
MA=$(md5sum "$ROOT/kmod/_tmp_selftest_rdst/dp_a.txt" | cut -c1-32)
MB=$(md5sum "$ROOT/kmod/_tmp_selftest_rdst/dp_b.txt" | cut -c1-32)

run_case() { # $1=tag $2=模式 ok|mismatch|empty|absent|gzbad|prev|zerofix  [$3=设备侧现数到的 dmesg.live.prev_* 名单]
    : > "$W/out_$1.txt"
    mkdir -p "$W/c$1/kmod/w103_evidence"
    (
        cd "$W/c$1" || exit 1
        MODE="$2"
        PF="${3:-}"      # ★上一发全量件改名后的现数名单：§6.364 抓到"go.sh:295 那句宣称没有生产者"，这条腿就是它的正对照
        # 桩用 grep -q 显式分派(第一版用嵌套 case，分派不中且错误被出货件里的 >/dev/null 吞掉，
        # 看着像"腿没跑"其实是我读不到 ⇒ 现在把桩自己的诊断写到 stub.log，断言不依赖它，但人看得见)
        A() {
            local c="$1"
            echo "A[$MODE] $c" >> "$W/stub.log"
            case "$c" in
                *'ls -1 /data/local/tmp/dmesg.live.prev_'*) printf '%s\n' "$PF"; return;;
                *'wc -c <'*)
                    [ "$MODE" = absent ] && { echo ""; return; }
                    [ "$MODE" = zerofix ] && { echo 0; return; }
                    if printf '%s' "$c" | grep -q 'ksu_ftrace\.txt'; then echo 24; else echo 12; fi; return;;
                *'md5sum'*)
                    if [ "$MODE" = mismatch ]; then echo 'deadbeefdeadbeefdeadbeefdeadbeef  x';
                    elif printf '%s' "$c" | grep -q 'ksu_ftrace\.txt'; then echo "$MA  x";
                    else echo "$MB  x"; fi; return;;
            esac
            echo STUB
        }
        adb() {
            local last="" a TGT
            for a in "$@"; do last="$a"; done
            echo "ADB[$MODE] $* -> last=$last" >> "$W/stub.log"
            case "$*" in
                *pull*)
                    if [ "$MODE" = empty ]; then : > "$last"; echo "empty 支：造 0 字节到 $last" >> "$W/stub.log"
                    elif [ ! -f "$ROOT/kmod/_tmp_selftest_rdst/dp_a.txt" ]; then echo "夹具文件不存在!" >> "$W/stub.log"
                    else
                        if printf '%s' "$*" | grep -q 'ksu_ftrace\.txt'; then TGT="$ROOT/kmod/_tmp_selftest_rdst/dp_a.txt"; else TGT="$ROOT/kmod/_tmp_selftest_rdst/dp_b.txt"; fi
                        cp "$TGT" "$last" 2>>"$W/stub.log" || echo "cp 失败 $TGT -> $last" >> "$W/stub.log"
                    fi
                    return 0;;
            esac
            echo "ADBJ $*"
        }
        gunzip() { if [ "$MODE" = gzbad ]; then echo 'CORRUPTED'; else command gunzip "$@"; fi; }
        # ★只把**要收的清单**整行缩成两件(桩按这两个名字分派)，其余文本逐字不动。
        #   (第一版这里用了 `s|ksu_ftrace.txt ksu_ftrace_armed.*|…|`，`.*` 把 DP_LIST 的收尾引号一起吞了
        #    ⇒ 未闭合引号，报错报到 22 行的 echo 上——"错误行"不是"错误处"，别照着报错行去改出货件)
        sed 's|^DP_LIST=.*|DP_LIST="ksu_ftrace.txt ksu_ftrace_armed $PREV_LIST"|' "$W/block.sh" > "$W/block2.sh"
        source "$W/block2.sh" > "$W/out_$1.txt" 2>&1
    )
    echo "----- case $1 (mode=$2) -----"
    sed 's/^/    /' "$W/out_$1.txt" | tail -8
}

run_case ok      ok
run_case mism    mismatch
run_case zero    empty
run_case gone    absent
run_case gzb     gzbad
run_case prev    ok       "dmesg.live.prev_1020-2353"
run_case zfix    zerofix

GZ1=$(ls "$W"/cok/kmod/w103_evidence/ 2>/dev/null | grep -acE '\.gz$' | tr -d ' ')
RAW1=$(ls "$W"/cok/kmod/w103_evidence/ 2>/dev/null | grep -a w421 | grep -avE '\.gz$' | grep -ac . | tr -d ' ')
SUM1=$(grep -oE '存下=[0-9]+｜设备侧本来没有=[0-9]+｜零字节开关件=[0-9]+｜不成立=[0-9]+' "$W/out_ok.txt" | tail -1)
chk "①两件都存下且没有失败项(计数行=$SUM1)" "$(printf '%s' "$SUM1" | grep -q '存下=2｜设备侧本来没有=0｜零字节开关件=0｜不成立=0' && echo 1 || echo 0)"
chk "①两件都留 .gz、原始件都删掉(gz=$GZ1 raw=$RAW1)" "$([ "$GZ1" = 2 ] && [ "$RAW1" = 0 ] && echo 1 || echo 0)"
chk "①那行里写了『解回一致』" "$(grep -aq '解回一致' "$W/out_ok.txt" && echo 1 || echo 0)"
GB=$(ls "$W"/cmism/kmod/w103_evidence/ 2>/dev/null | grep -acE 'w421' | tr -d ' ')
chk "②md5 不符：本机没留下坏读数(w421 原始件计数=$GB)" "$([ "$GB" = 0 ] && echo 1 || echo 0)"
chk "②md5 不符：打出不符硬话" "$(grep -aq '两端 md5 不符' "$W/out_mism.txt" && echo 1 || echo 0)"
chk "③0 字节：打『不许留空存证件』且零产物(实数=$(ls "$W"/czero/kmod/w103_evidence/ 2>/dev/null | grep -ac w421 | tr -d ' '))" "$(grep -aq '没测到' "$W/out_zero.txt" && echo 1 || echo 0)"
SU4=$(grep -oE '设备侧本来没有=[0-9]+' "$W/out_gone.txt" | tail -1)
AR4=$(ls "$W"/cgone/kmod/w103_evidence/ 2>/dev/null | grep -ac 'w421' | tr -d ' ')
chk "④设备没有：只记『没有』($SU4)且存证目录零产物(产物=$AR4)" "$(printf '%s' "$SU4" | grep -q '没有=2' && [ "$AR4" = 0 ] && echo 1 || echo 0)"
chk "⑤压缩件解回不符：删压缩件、留原始件" "$(grep -aq '压缩件解回 md5 不符' "$W/out_gzb.txt" && echo 1 || echo 0)"
RAW5=$(ls "$W"/cgzb/kmod/w103_evidence/ 2>/dev/null | grep -a w421 | grep -avE '\.gz$' | grep -ac . | tr -d ' ')
GZ5=$(ls "$W"/cgzb/kmod/w103_evidence/ 2>/dev/null | grep -acE '\.gz$' | tr -d ' ')
chk "⑤原始件确实还在(数到 $RAW5)且压缩件被删掉(数到 $GZ5)" "$([ "$RAW5" -ge 1 ] && [ "$GZ5" = 0 ] && echo 1 || echo 0)"
#   ★⑥⑦(§6.364 新加的两格)：设备侧现数到的 `dmesg.live.prev_*` **必须真的进 pull 腿**，
#     而 0 字节开关件**不许**记成"不成立"(第 30 发就是被它打出 存下=15｜不成立=3 的假话)。
SUM6=$(grep -oE '存下=[0-9]+｜设备侧本来没有=[0-9]+｜零字节开关件=[0-9]+｜不成立=[0-9]+' "$W/out_prev.txt" | tail -1)
GZ6=$(ls "$W"/cprev/kmod/w103_evidence/ 2>/dev/null | grep -acE '\.gz$' | tr -d ' ')
HAS6=$(grep -ac 'dmesg.live.prev_1020-2353' "$W/out_prev.txt" | tr -d ' ')
chk "⑥现数名单接到腿上：计数行三件($SUM6)、gz=$GZ6、prev 那名字在输出里出现过($HAS6 次)" "$(printf '%s' "$SUM6" | grep -q '存下=3｜设备侧本来没有=0｜零字节开关件=0｜不成立=0' && [ "$GZ6" = 3 ] && [ "$HAS6" -ge 1 ] && echo 1 || echo 0)"
chk "⑥反面对照：没喂 prev 名单时不许凭空多收一件(out_ok 里出现 prev 名字＝接错线)" "$([ "$(grep -ac 'dmesg.live.prev' "$W/out_ok.txt" | tr -d ' ')" = 0 ] && echo 1 || echo 0)"
SUM7=$(grep -oE '存下=[0-9]+｜设备侧本来没有=[0-9]+｜零字节开关件=[0-9]+｜不成立=[0-9]+' "$W/out_zfix.txt" | tail -1)
AR7=$(ls "$W"/czfix/kmod/w103_evidence/ 2>/dev/null | grep -ac 'w421' | tr -d ' ')
chk "⑦0 字节开关件：记进『零字节开关件』而不是『不成立』($SUM7)，且零产物(产物=$AR7)" "$(printf '%s' "$SUM7" | grep -q '存下=0｜设备侧本来没有=0｜零字节开关件=2｜不成立=0' && [ "$AR7" = 0 ] && echo 1 || echo 0)"
rm -f "$ROOT/kmod/_tmp_selftest_rdst/dp_a.txt" "$ROOT/kmod/_tmp_selftest_rdst/dp_b.txt"

echo
[ "$fail" = 0 ] && echo "=== run_dumpleg 自测 PASS($nchk 项，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
echo "临时件留在 $W(手看再删)"
[ "$fail" = 0 ]
