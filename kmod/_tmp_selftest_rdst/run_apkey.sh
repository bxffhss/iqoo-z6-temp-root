#!/usr/bin/env bash
# §6.313⑦ 仪器 selftest：`AP_KEY`（主那条名单记录的 key/包名）能不能单独拨，且**默认不给时行为逐字不变**。
# 三条腿，全部"双向"验收：
#   A 腿＝go.sh 的 1.66 段（不给⇒只清开关文件；给⇒把那串铺进去；非法字符⇒rc=3 且一条 adb 都不发）；
#   B 腿＝stage 的名单段（无开关⇒主条目仍是 com.suw.manager；有开关⇒写进去的那串，且故意带 \r 要剥掉）；
#   C 腿＝两条目分支（追加那条**自己带 key**，不许被 AP_KEY 覆盖）。
# 对被抽出的代码唯一的改写＝把设备侧绝对路径 `/data/local/tmp` 换成临时目录（sed 一次替换＋断言替换确实发生）。
set -u
cd "$(dirname "$0")/../.." || exit 9
ROOT=$(pwd)
W=$(mktemp -d)
fail=0

# ---------- A 腿：go.sh 的 1.66 段 ----------
sed -n '/=== 1.66)/,/=== 1.65)/p' kmod/go.sh > "$W/a_blk.sh" || exit 8
grep -q 'AP_KEY' "$W/a_blk.sh" || { echo "FAIL A 腿抽出的块里没有 AP_KEY(锚点错了)"; exit 7; }
NA=$(grep -c 'ksu_ap_key' "$W/a_blk.sh")
echo "A 腿：抽出 $(wc -l < "$W/a_blk.sh") 行，提到 ksu_ap_key 的行数=$NA"
[ "$NA" -ge 3 ] || { echo "FAIL A 腿块里 ksu_ap_key 只出现 ${NA} 行(改动没落进 1.66 段)"; exit 7; }

cat > "$W/a_run.sh" <<'S'
A() { echo "ADB[$*]" >> "$LOG"; }
. "$BLK"
S

a_run() { # $1=AP_KEY(可空) $2=期望含 $3=期望不含 $4=期望 rc
    : > "$W/a_log.txt"
    local out rc
    if [ -n "$1" ]; then
        out=$( AP_KEY="$1" BLK="$W/a_blk.sh" LOG="$W/a_log.txt" bash "$W/a_run.sh" 2>&1 ); rc=$?
    else
        out=$( env -u AP_KEY BLK="$W/a_blk.sh" LOG="$W/a_log.txt" bash "$W/a_run.sh" 2>&1 ); rc=$?
    fi
    local p=OK n=OK
    grep -qF -- "$2" "$W/a_log.txt" || p=MISS
    [ -n "$3" ] && grep -qF -- "$3" "$W/a_log.txt" && n=BAD
    [ "$rc" = "$4" ] || n="BAD(rc=$rc 期望 $4)"
    { [ "$p" = OK ] && [ "$n" = OK ]; } || fail=1
    echo "  [$p/$n] AP_KEY=[${1:-<未给>}] ⇒ 命令里应含「$2」忌含「${3:-无}」 rc=$rc(期望 $4)"
    sed 's/^/            /' "$W/a_log.txt"
    grep -a '非法字符' <<<"$out" | sed 's/^/            /'
}
echo "=== A1 默认关：只清开关文件，不写 ==="
a_run '' 'rm -f /data/local/tmp/ksu_ap_key' "> /data/local/tmp/ksu_ap_key" 0
echo "=== A2 给 AP_KEY=com.termux：把那串铺进开关文件，不走 rm 分支 ==="
a_run 'com.termux' "printf '%s' 'com.termux' > /data/local/tmp/ksu_ap_key" 'rm -f /data/local/tmp/ksu_ap_key' 0
echo "=== A3 非法字符(带分号)：rc=3 且一条 adb 命令都不发 ==="
: > "$W/a_log.txt"
out=$( AP_KEY='com.termux;reboot' BLK="$W/a_blk.sh" LOG="$W/a_log.txt" bash "$W/a_run.sh" 2>&1 ); rc=$?
NL=$(grep -c 'ADB\[' "$W/a_log.txt")
if [ "$rc" = 3 ] && [ "$NL" = 0 ]; then
    echo "  [OK/OK] 非法 AP_KEY ⇒ rc=3(期望 3) 且未发任何 adb 命令(0 行)"
else
    echo "  [BAD] rc=$rc(应为 3) 已发 adb 命令=$NL 行(应为 0)"; fail=1
fi
grep -a '非法字符' <<<"$out" | sed 's/^/            /'

# ---------- B/C 腿：stage 的 APKEY 赋值 ＋ 名单段 ----------
sed -n '/^APKEY=/,+1p' kmod/ksu_one_stage.sh > "$W/b_head.sh"
sed -n '/^log "  ★AP_KEY 生效证人/,/^cp \/data\/local\/tmp\/a_\$SUWID.bin/p' kmod/ksu_one_stage.sh | sed '$d' > "$W/b_blk.sh"
grep -q '^APKEY=' "$W/b_head.sh" || { echo "FAIL B 腿头块没抽到 APKEY 赋值行(锚点错了)"; exit 7; }
grep -q '"\$APKEY"' "$W/b_blk.sh" || { echo "FAIL 名单段没引用 \"\$APKEY\"(改动没落进去)"; exit 7; }
grep -q 'ksu_two_profiles' "$W/b_blk.sh" || { echo "FAIL 名单段没抽到两条目分支(范围错了)"; exit 7; }
BE=$(grep -c '/data/local/tmp' "$W/b_head.sh" "$W/b_blk.sh" | awk -F: '{s+=$2} END{print s}')
echo "B/C 腿：头块 $(wc -l < "$W/b_head.sh") 行 / 名单段 $(wc -l < "$W/b_blk.sh") 行，待替换的设备路径=$BE"
[ "$BE" -ge 6 ] || { echo "FAIL 设备路径只数到 $BE 处(锚点抽出的范围太小)"; exit 7; }
sed -i 's#/data/local/tmp#'"$W"'#g' "$W/b_head.sh" "$W/b_blk.sh"
grep -q '/data/local/tmp' "$W/b_head.sh" "$W/b_blk.sh" && { echo "FAIL 替换后仍有设备绝对路径"; exit 7; }

printf '#!/bin/sh\necho "MKALLOW $*"\n' > "$W/ctl"
# ★名字必须叫 ksuctl88：名单段第 275 行会**自己再赋值** CTL2=…/ksuctl88，我外面设的会被顶掉
cp "$W/ctl" "$W/ksuctl88"; chmod 755 "$W/ctl" "$W/ksuctl88"

b_run() { # $1=开关内容(空=不放文件) $2=ksu_two_profiles 内容(空=不放) $3=MGRID $4=主条目期望 key
    rm -f "$W/ksu_ap_key" "$W/ksu_two_profiles"
    [ -n "$1" ] && printf '%s\r\n' "$1" > "$W/ksu_ap_key"   # 故意带 \r：验 tr -d 真剥掉
    [ -n "$2" ] && printf '%s\n' "$2" > "$W/ksu_two_profiles"
    local out
    out=$( W="$W" MGRID="$3" bash -c '
        log() { echo "LOG$*"; }
        PKG=com.suw.manager; SUWID=10667; DOM=u:r:shell:s0
        CTL="'"$W"'/ctl"
        . "'"$W"'/b_head.sh"
        . "'"$W"'/b_blk.sh"
    ' 2>&1 )
    local p=OK
    grep -q "MKALLOW mkallow $W/a_10667.bin 10667 $4 " <<<"$out" || p=MISS
    [ "$p" = OK ] || fail=1
    echo "  [$p] 开关=[${1:-<不放>}] two_profiles=[${2:-<不放>}] MGRID=$3 ⇒ 主条目 key 应为「$4」"
    grep -aE 'MKALLOW|生效证人' <<<"$out" | sed 's/^/            /' | cut -c1-190
        LASTMK=$(grep -a 'MKALLOW' <<<"$out" | tail -1)
}
echo "=== B1 无开关文件：主条目必须仍是 com.suw.manager（交付链逐字不变） ==="
b_run '' '' 0 'com.suw.manager'
echo "=== B2 开关=com.termux(文件里带 \\r)：主条目 key 必须＝com.termux ==="
b_run 'com.termux' '' 0 'com.termux'
echo "=== C1 两条目分支＋开关：主条目用开关那串，追加那条仍用它自己的 key(不许被覆盖) ==="
b_run 'com.termux' '10104:me.weishu.kernelsu' 10104 'com.termux'
grep -q '10104 me.weishu.kernelsu u:r:shell:s0' <<<"$LASTMK" && echo "  [OK] 追加条目 key=me.weishu.kernelsu 未被 AP_KEY 覆盖" || { echo "  [BAD] 追加条目没带上它自己的 key"; fail=1; }

echo "=== 语法检查（设备侧 mksh 由外层「sh -n」另跑，见 runbook §40 前置） ==="
for f in kmod/go.sh kmod/ksu_one_stage.sh kmod/w184_sample.sh; do
    bash -n "$f" && echo "  bash -n $f rc=0" || { echo "  bash -n $f FAIL"; fail=1; }
done
echo "=== 采样腿的连续证人（例 117：两次点读不算） ==="
grep -q 'suw=\[%s\]' kmod/w184_sample.sh && grep -q 'pidof com.suw.manager' kmod/w184_sample.sh \
    && echo "  [OK] suw=[…] 列 ＋ pidof com.suw.manager 都在(每 3 秒一条)" || { echo "  [BAD] 采样腿没有 suw 连续证人"; fail=1; }
rm -rf "$W" "$ROOT/mkdir_probe_ignored" 2>/dev/null
echo "=== 结论：AP_KEY/名单/采样腿 selftest $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
