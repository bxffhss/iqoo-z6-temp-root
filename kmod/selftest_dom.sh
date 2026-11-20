#!/bin/bash
# selftest_dom.sh —— #53 判据脚本的**双向验证**(记忆里的规矩：判据脚本要能自己证明自己会 FAIL)。
#   GOOD 夹具 ⇒ check_dom_su.sh 必须退 0；
#   BAD  夹具 ⇒ 必须退非 0，且**每一条坏味道都被点名**(域没落地 / 段为空 / 没有 -22 回执 /
#              app 基线已经 uid=0 / 没卸载)。只测"全绿"的判据等于没测。
set -u
cd "$(dirname "$0")/.."
T=kmod/.selftest_dom
fail=0
say() {   # ★函数最后一条语句必须是"成功"的：上一版以 `[ "$1" = FAIL ] && …` 收尾，
    #   PASS 分支时它求值为假 ⇒ **函数返回非 0** ⇒ 调用处 `&& say PASS || say FAIL` 把两条都打了
    #   (看起来像"判据既点名又没点名")。这条自己踩的坑，正是本文件要防的那一类。
    echo "  [$1] $2"
    if [ "$1" = FAIL ]; then fail=$((fail+1)); fi
    return 0
}

rm -rf "$T"; mkdir -p "$T/good" "$T/bad"

# ---------- GOOD：域真的落地(kernel→shell)，负对照有 -22，Seccomp 2→0，撤名单被拒 ----------
cat > "$T/good.log" <<'EOF'
    本轮 enforce=Permissive —— Permissive 是我们自己 punch 的 sen 相造成的
    [11:00:00.000] SETPROF uid=10667 allow=1 key=com.termux domain=u:r:zzz_no_such_domain:s0: rc=0 errno=0(Success)
    [11:00:01.000] SETPROF uid=10667 allow=1 key=com.termux domain=u:r:shell:s0: rc=0 errno=0(Success)
    [11:00:02.000] SETPROF uid=10667 allow=0 key=com.termux domain=-: rc=0 errno=0(Success)
    BIND_RC=0
    UMOUNT_RC=0
    Found 327 services:
    收尾复核: up=118 mod=0 enf=Enforcing 挂载=0
    存证 w28_neg
    存证 w28_shell
    存证 w28_app0
    存证 w28_app1
    存证 w28_revoked
EOF
# ★夹具形状必须与设备侧**真实回执**一致：载荷是零 fork 的 domprint(`=== DOM uid=0 …` + `CTX=[…]`)，
#   而且 [B]/[C] 分段标记要在 —— check_dom_su.sh 的 bs() 只取 [B] 到 [C] 之间(整份文件里
#   有内核侧 `prof_uid=0 gid=0` 那种行，拿 `uid=0 ` 当判据会凭空命中它)。
printf -- '--- [B] 判据 ---\n=== DOM uid=0 euid=0 gid=0\nCTX=[u:r:kernel:s0]\nSeccomp=0\n--- [C] 内核侧 ---\n[ 1.0] KernelSU: security_secctx_to_secid u:r:zzz_no_such_domain:s0 -> sid: 0, error: -22\n' > "$T/good/w28_neg"
printf -- '--- [B] 判据 ---\n=== DOM uid=0 euid=0 gid=0\nCTX=[u:r:shell:s0]\nSeccomp=0\n--- [C] 内核侧 ---\n' > "$T/good/w28_shell"
printf -- '=== DOM uid=10308\nCTX=[u:r:untrusted_app:s0:c52]\nSeccomp:\t2\n' > "$T/good/w28_app0"
printf -- 'uid=0(root) gid=0(root)\nCTX=[u:r:untrusted_app:s0:c52]\nSeccomp:\t0\n' > "$T/good/w28_app1"
printf -- '--- [B] 判据 ---\n=== DOM uid=10667\nsu: agent 拒绝: ERR not-allowed\n--- [C] 内核侧 ---\n' > "$T/good/w28_revoked"

echo "=== 正夹具(期望全绿) ==="
E="$T/good" bash kmod/check_dom_su.sh "$T/good.log" > "$T/good.out" 2>&1
rc=$?
if [ $rc = 0 ] && ! grep -q FAIL "$T/good.out"; then say PASS "全绿夹具退 0"; else say FAIL "全绿夹具退 $rc"; tail -20 "$T/good.out"; fi

# ---------- BAD：域没落地(仍是 kernel) + 段为空 + 无 -22 + 基线已 uid=0 + 没卸载 ----------
cat > "$T/bad.log" <<'EOF'
    本轮 enforce=Permissive
    [11:00:00.000] SETPROF uid=10667 allow=1 key=com.termux domain=u:r:zzz_no_such_domain:s0: rc=0
    [11:00:01.000] SETPROF uid=10667 allow=1 key=com.termux domain=u:r:shell:s0: rc=0
    BIND_RC=0
    Found 327 services:
    存证 w28_neg
    存证 w28_shell
    存证 w28_app0
    存证 w28_app1
    存证 w28_revoked
EOF
printf -- '--- [B] 判据 ---\n=== DOM uid=0\nCTX=[u:r:kernel:s0]\nSeccomp=0\n--- [C] 内核侧 ---\n' > "$T/bad/w28_neg"   # 缺 -22 那行
printf -- '--- [B] 判据 ---\n=== DOM uid=0\nCTX=[u:r:kernel:s0]\n--- [C] 内核侧 ---\n' > "$T/bad/w28_shell"          # 域没落地(还留起点域)
printf -- '=== DOM uid=0\nCTX=[u:r:untrusted_app:s0]\nSeccomp:\t2\n' > "$T/bad/w28_app0"                            # 基线里已经 uid=0
printf -- '=== DOM uid=10308\nSeccomp:\t2\n' > "$T/bad/w28_app1"                                                    # su 后 Seccomp 仍是 2
printf -- '--- [B] 判据 ---\n=== DOM uid=0\n--- [C] 内核侧 ---\n' > "$T/bad/w28_revoked"                             # 撤名单还给 root

echo "=== 负夹具(期望每一处坏味道都被点名) ==="
E="$T/bad" bash kmod/check_dom_su.sh "$T/bad.log" > "$T/bad.out" 2>&1
rc=$?
[ $rc != 0 ] && say PASS "坏夹具退非 0($rc)" || say FAIL "坏夹具居然退 0 ⇒ 判据是假的"
# ★断言只认 **FAIL 分支的文案**(上一版我拿 ok 分支的字去 grep，7 处全"没点名"——
#   那不是判据坏，是**自检脚本自己**的假阴性；这类"验证器验错了地方"要当场认清)
for pat in "内核侧找不到任何提到我们那个域字符串的行" "自填的域" "基线里出现了 uid=0" "su 之后 Seccomp" "撤了名单这个 uid 还出 uid=0" "没有 agent 拒绝" "没有卸载回执" "没证到名单撤过"; do
    grep -q "$pat" "$T/bad.out" && say PASS "点名: $pat" || say FAIL "没点名: $pat"
done


# ---------- STALE：文件都在，但日志**没承认拉过** app0/app1 ⇒ 必须报"旧存证不算证据" ----------
mkdir -p "$T/stale"
sed 's/^    存证 w28_app0$//; s/^    存证 w28_app1$//' "$T/bad.log" > "$T/stale.log"
cp "$T/bad/"* "$T/stale/" 2>/dev/null
echo "=== 第三套夹具：跨发存证闸(期望被点名) ==="
E="$T/stale" bash kmod/check_dom_su.sh "$T/stale.log" > "$T/stale.out" 2>&1
rc=$?
[ $rc != 0 ] && say PASS "缺存证行的夹具退非 0($rc)" || say FAIL "缺存证行居然退 0 ⇒ 那道闸是假的"
grep -q "旧存证不算证据" "$T/stale.out" && say PASS "点名: 旧存证不算证据" || say FAIL "没点名: 旧存证不算证据"
grep -q "w28_app0" "$T/stale.out" && say PASS "被点名的正是缺行那份(app0)" || say FAIL "没提到 w28_app0"

echo
[ $fail = 0 ] && echo "=== 双向验证通过：判据既能全绿也能逐条报错 ===" || echo "=== 判据脚本本身有问题($fail 条) ==="
exit $fail
