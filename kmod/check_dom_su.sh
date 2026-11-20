#!/bin/bash
# check_dom_su.sh —— #53 的**只读**闸门：只判"SET_APP_PROFILE 自填的域落不落地"。
# 用法：ATT=25 I_KNOW=1 bash kmod/w103_su.sh > kmod/w103_att25.log 2>&1
#       bash kmod/check_dom_su.sh kmod/w103_att25.log
#       bash kmod/selftest_dom.sh          # ★判据自己的双向验证(正夹具退 0 / 坏夹具逐条点名)
#
# ★为什么不判"那个域在 enforcing 下能不能干活"：我们自己那一枪(pr 的 sen 相)在 punch 时就把
#   selinux_state.enforcing 写成 0 ⇒ **整窗 Permissive**(第 43/45/46 发一手)。MAC 不在场时
#   "哪个域都能读"是恒等式，拿域鉴别器当判据会得出"哪个域都能干活"的假结论。
#   ⇒ Permissive 时只判 `attr/current`(域切没切) 与 `Seccomp`(2→0)。
# ★三条自伤教训写死在这里：
#   ① 断言只认**设备侧回执形态**(`=== DOM uid=0 `、`CTX=[u:r:…]`、`su: agent 拒绝`)；
#   ② uid/域的断言**只看 [B] 段**：整份回执里有内核侧 `X2 profile: … prof_uid=0 gid=0`，
#      全局匹配 `uid=0 ` 会凭空命中它(第 46 发因此把"撤名单"误判成"名单失效")；
#   ③ 每段先判空，且**判空要在主 shell 里计数**：写成 `if s=$(seg …)` 会让 fail 自增丢在子 shell、
#      FAIL 文本还被命令替换吞掉(第 45 发 selftest 抓到的)。
LOG=${1:-kmod/w103_att25.log}
E=${E:-kmod/w103_evidence}
fail=0
ok()  { echo "  [ok] $*"; }
bad() { echo "  [FAIL] $*"; fail=$((fail+1)); }
export LC_ALL

need() {
    # ★两道闸：**这一发日志承认证据是本发拉的** + 文件非空。
    #   只查第二道会出事：存证文件名是固定的(w28_*)，上一发留的文件会跨发被当成本发结论读
    #   (第 50 发一手：空枪那一发读到了上一发的 w29_residue，报了个非常"有据"的 FAIL)。
    grep -aq "存证 $1" "$LOG" || { echo "  [FAIL] $1：本发日志里没有『存证 $1』⇒ 这一发没测到这一档，**旧存证不算证据**"; fail=$((fail+1)); return 1; }
    [ -s "$E/$1" ] || { echo "  [FAIL] $1 缺失或为空 ⇒ 这一档没测到，不许当阴性"; fail=$((fail+1)); return 1; }
    return 0
}
whole() { tr -d '\000' < "$E/$1"; }
bs() {   # 只取**加 su 那一段**([B] 到 [C] 之间)
    tr -d '\000' < "$E/$1" | awk '/\[B\]/{f=1} /\[C\]/{f=0} f'
}

echo "=== #53 域判据闸门  日志=$LOG ==="
[ -f "$LOG" ] || { echo "[x] 找不到驱动日志"; exit 2; }

ENF=$(grep -aoE "本轮 enforce=[A-Za-z]+" "$LOG" | tail -1 | cut -d= -f2)
echo "--- [0] 本轮 enforce 口径 = [$ENF] ---"
[ -n "$ENF" ] || bad "没读到 enforce 口径 ⇒ 判据的分母都没定"

echo "--- [1] 控制面：设备侧 SETPROF 回执里域确实各不相同 ---"
for d in u:r:zzz_no_such_domain:s0 u:r:shell:s0; do
    grep -aq "SETPROF uid=.*domain=$d" "$LOG" && ok "有 domain=$d 的回执" || bad "缺 domain=$d 的回执"
done
grep -aq "allow=0" "$LOG" && ok "有 allow=0(撤名单)的回执" || bad "没证到名单撤过"
grep -aq "allow=1" "$LOG" || bad "没有任何 allow=1 的 SETPROF ⇒ 控制面整条没跑"

echo "--- [2] 负对照(不存在的域)：su 仍要成功，但 CTX **必须保持起点域** ---"
if need w28_neg; then
    sb=$(bs w28_neg); sw=$(whole w28_neg)
    echo "$sb" | grep -aqE "=== DOM uid=0([[:space:]]|$)" && ok "负对照里 su 成功(说明提权与域无关)" || bad "负对照没出 '=== DOM uid=0' ⇒ 这一档断了，本档无效"
    echo "$sb" | grep -aqE "CTX=\[?u:r:zzz" && bad "内核居然把一个不存在的域设上去了(先看是不是读错了行)" || ok "CTX 没变成那个不存在的域"
    echo "$sb" | grep -aqE "CTX=\[?u:r:kernel:s0" && ok "起点域 kernel 保持 ⇒ setup_selinux 解不开时不切换" || bad "CTX 形状不认识: [$(echo "$sb" | grep -a CTX | head -1)]"
    # ★两条**任选其一**都能证"内核真的按我们给的域字符串在办事"，但要标清是哪条承的分：
    #   (a) 内核为我们那个串打了 `security_secctx_to_secid … -22`；
    #   (b) 内核的 profile 查找回执(X2/X6)里出现的 `domain=` 就是**我们填的那个不存在的串**。
    #   第 49 发的实情是 (b) 都没出现 ⇒ 说明那一枪的 su 事件的内核行**根本没被采集到**
    #   (限流/洪印/时间窗)，所以 runner 的 [C] 已改成 uid+时间窗双过滤；这条判据在下一发才有资格说"没发生"。
    if echo "$sw" | grep -aqE "secctx_to_secid u:r:zzz_no_such_domain"; then
        ok "★(a) 内核为我们填的串打了解不开回执 ⇒ SET_APP_PROFILE 按语义执行"
    elif echo "$sw" | grep -aqE "domain=u:r:zzz_no_such_domain"; then
        ok "★(b) 内核的 profile 回执里 domain= 就是我们填的那个串 ⇒ 按语义执行(解不开那行没抓到，可能是限流)"
    else
        bad "内核侧找不到任何提到我们那个域字符串的行 ⇒ 采集没到位(先查 [C] 的时间窗与限流)，本档不算证到"
    fi
fi

echo "--- [3] 正判据：domain=u:r:shell:s0 ⇒ 起点 kernel 必须变成 shell(可分辨的降级) ---"
if need w28_shell; then
    sb=$(bs w28_shell)
    echo "$sb" | grep -aqE "=== DOM uid=0([[:space:]]|$)" && ok "uid=0" || bad "没出 '=== DOM uid=0' ⇒ 提权这半格断了"
    if echo "$sb" | grep -aqE "CTX=\[?u:r:shell:s0"; then
        ok "★域真的切了：attr/current 从 kernel 变成 shell ⇒ profile 的 selinux_domain 生效"
    elif echo "$sb" | grep -aqE "CTX=\[?u:r:kernel:s0"; then
        bad "CTX 仍是起点域 ⇒ 自填的域没落地(这一格还开着，不是关掉了)"
    else
        bad "CTX 形状不认识: [$(echo "$sb" | grep -a CTX | head -1)]"
    fi
fi

echo "--- [4] app 来源两档：Seccomp 必须 2 → 0(su 之后解除 seccomp 才是窗口里真拿到的能力) ---"
if need w28_app0; then
    s=$(whole w28_app0)
    echo "$s" | grep -aqE "Seccomp[=:][[:space:]]*2" && ok "app 侧基线 Seccomp=2" || bad "app 基线的 Seccomp 不是 2: [$(echo "$s" | grep -a Seccomp | head -1)]"
    echo "$s" | grep -aqE "uid=0\(root\)|=== DOM uid=0([[:space:]]|$)" && bad "app 基线里出现了 uid=0 ⇒ 基线被污染" || ok "app 基线未提权"
fi
if need w28_app1; then
    s=$(whole w28_app1)
    echo "$s" | grep -aqE "uid=0\(root\)|=== DOM uid=0([[:space:]]|$)" && ok "app 来源加 su ⇒ uid=0" || bad "app 来源的 su 没通(Manager 走 default 模板，域不切是预期的)"
    echo "$s" | grep -aqE "Seccomp[=:][[:space:]]*0" && ok "★su 之后 Seccomp=0(§6.127 那类 'app 域 seccomp 杀 reboot(142)' 的失败在 su 之后不存在)" || bad "su 之后 Seccomp 没降到 0: [$(echo "$s" | grep -a Seccomp | head -1)]"
fi

echo "--- [5] 撤名单：同一个普通 uid 必须被拒 ---"
if need w28_revoked; then
    sb=$(bs w28_revoked)
    echo "$sb" | grep -aqE "=== DOM uid=0([[:space:]]|$)" && bad "撤了名单这个 uid 还出 uid=0 ⇒ 名单没起作用(或被别的 uid 顶了)" || ok "撤名单后 [B] 段没有 uid=0"
    { echo "$sb" | grep -aq "not-allowed" || echo "$sb" | grep -aq "拒绝"; } && ok "有 agent 拒绝的回执" || bad "没有 agent 拒绝的回执 ⇒ 本档没证到"
fi

echo "--- [6] 全程健康 ---"
grep -aq "BIND_RC=0" "$LOG" && ok "挂载 BIND_RC=0" || bad "没有 BIND_RC=0"
grep -aqE "umount#1 rc=0|MOUNT_LEFT=0|UMOUNT_RC=0" "$LOG" && ok "收尾卸载有回执" || bad "没有卸载回执(收尾可能把 /product/bin 弄坏)"
grep -aqE "Found [0-9]+ services" "$LOG" && ok "shell 域服务数在(框架没死)" || bad "没读到服务数 ⇒ 框架健康缺证"
grep -aqE "mod=0 .*enf=Enforcing" "$LOG" && ok "收尾复核：模块已卸 + 回到 Enforcing" || bad "收尾复核没读到 mod=0/enf=Enforcing ⇒ 机器可能还带着模块与 Permissive"

echo
if [ "$ENF" != Enforcing ]; then
    echo "=== 结论口径：本轮 Permissive ⇒ 只判'域落不落地'；'那个域能不能干活'在我们窗口内不可判 ==="
fi
[ $fail = 0 ] && echo "=== 全绿 ===" || echo "=== 有 $fail 条 FAIL，见上 ==="
exit $fail
