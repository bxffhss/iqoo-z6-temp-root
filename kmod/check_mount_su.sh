#!/bin/bash
# check_mount_su.sh —— **只读**判定"挂载路线交付 su"(ATT=24)的证据，不改设备状态。
# 用法：ATT=24 I_KNOW=1 bash kmod/w103_su.sh   然后  bash kmod/check_mount_su.sh [日志]
#
# 三态必须互斥，这是整发唯一的价值：
#   态① 未挂载            ⇒ errno=2      (文件不在)
#   态② 挂载 + 名单内     ⇒ uid=0(root)  (文件在 且 内核放行)
#   态③ 挂载 + 撤名单     ⇒ not-allowed  (文件在 但 内核不放行)  ← 上一发就是这一格没立住
# 任何一态与另一态的标记同时出现 ⇒ 判据不成立(第 22/23 发各踩过一次，见 §6.124⑤)。
#
# ★第 24 发抓到判据脚本**自己**的假阳性：驱动脚本的段落标题里写着
#   `(c′) ★态③：…必须是 agent 拒(not-allowed)，**不能**是 errno=2`，于是 `grep errno=2` / `grep not-allowed`
#   直接命中**标签本身** ⇒ 一条 FAIL 是凭空来的。固化：断言只能认**设备侧回执的形态**
#   (`SUPATH-EXECVP-FAIL …`、`su: agent 拒绝: ERR …`)，而且只在 B 子段里认，不认整段。
set -u
export LC_ALL=C        # 日志里有中文：不锁 locale 时 awk 会报 multibyte 警告并按字节切
cd "$(dirname "$0")/.." || exit 1
LOG=${1:-}
if [ -z "$LOG" ]; then
    for f in $(ls -t kmod/w103_att24.log kmod/w103_att22*.log 2>/dev/null); do LOG=$f; break; done
fi
[ -n "$LOG" ] && [ -f "$LOG" ] || { echo "[x] 找不到日志(第 1 参数或 kmod/w103_att24.log)"; exit 2; }
# 清洗：只删控制字节。**不要**用 `tr -cd` 白名单 —— 它会把中文关键字一起吃掉 ⇒ 全绿被判 FAIL(§6.115②)
tr -d '\000-\010\013\014\016-\037\177' <"$LOG" > /tmp/cms.log
LOG=/tmp/cms.log

seg() {   # seg <起始标记> <结束标记>
    awk -v a="$1" -v b="$2" '
        !got && index($0,a){got=1; next}
        got && b!="" && index($0,b){exit}
        got{print}' "$LOG"
}
bonly() { printf '%s
' "$1" | awk '/--- B\)/{g=1;next} /--- C\)/{exit} g'; }
S1=$(seg "(a′)" "(b) 挂载")
B1=$(bonly "$S1")
SM=$(seg "(b) 挂载" "(b′)")
SF=$(seg "(b′)" "(c) 撤名单")
S3=$(seg "(c) 撤名单" "(d) 收尾")   # ★从 (c) 起切：allow=0 的回执打在 (c) 段里
B3=$(bonly "$S3")
ST=$(seg "(d) 收尾" "")

fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
echo "日志: $LOG"
echo "段长: 态①=${#S1} 挂载=${#SM} 框架复核=${#SF} 态③=${#S3} 卸载=${#ST}"
echo

echo "--- 0. 段落都在(空段=那一格根本没跑，不能算通过) ---"
EMPTY=""
for n in "态①:$S1" "挂载:$SM" "态③:$S3" "卸载:$ST"; do
    v=${n#*:}; if [ "${#v}" -gt 40 ]; then ok "${n%%:*} 段有内容"; else bad "${n%%:*} 段是空的 ⇒ 那一格没测"; EMPTY=1; fi
done
if [ -n "$EMPTY" ]; then
    echo
    echo "[x] 有空段 ⇒ 后面那些"否定式断言"(没出 root / 不是 ENOENT)会在空输入上白送 PASS，"
    echo "    所以整份判据不作数。先确认日志段名与 ATT=24 的 echo 标题对得上。"
    exit 1
fi

echo "--- 1. 态①：未挂载 ⇒ 唯一解释是文件不在(errno=2)，且绝不能出 root ---"
echo "$B1" | grep -aq "SUPATH-EXECVP-FAIL name=\[su\] errno=2" && ok "B 子段回执 errno=2" || bad "未挂载态没报 errno=2"
if echo "$B1" | grep -aq "uid=0(root)"; then bad "态① 的 B 子段出了 root ⇒ PATH 不只给了一项，钩子进来了"; else ok "态① B 子段没出 root"; fi
if echo "$S1" | grep -aq "uid=0(root)"; then ok "C 子段(含 /system/bin)按预期被钩子接住 ⇒ 这条对照就在演示为什么不能用 PATH 探针"; else bad "C 子段没出 root ⇒ 改道那半格没证到"; fi

echo "--- 2. 挂载本身 + 框架健康(第 22 发就是这一格没测导致整发报废) ---"
echo "$SM" | grep -aq "BIND_RC=0" && ok "BIND_RC=0" || bad "mount --bind 没成功"
echo "$SM" | grep -aq "HEALTH=OK" && ok "HEALTH=OK" || bad "HEALTH 不是 OK(或 RESULT=ROLLED_BACK)"
echo "$SM" | grep -aq "RESULT=ROLLED_BACK" && bad "脚本自己回退了" || true
echo "$SM" | grep -aq "SVC_SHELL=Found 0" && bad "shell 域服务数=0 ⇒ 框架真的坏了" || ok "shell 域服务数非 0"
echo "$SM" | grep -aqE "SVC_SHELL=Found [1-9]" && ok "$(echo "$SM" | grep -ao 'SVC_SHELL=.*' | head -1)" || bad "没读到 shell 域服务数"
echo "$SM" | grep -aq "SU_AT_TGT=.*su$" && ok "/product/bin/su 成了真文件" || bad "挂载点上看不到 su"

echo "--- 3. 态②：挂载 + 名单内 ⇒ uid=0(root)，且驱动 fd 不漏进 shell ---"
echo "$SM" | grep -aq "uid=0(root)" && ok "挂载+放行 ⇒ uid=0(root)" || bad "挂载+放行拿不到 root"
echo "$SM" | grep -aq "granted=1" && ok "回执里有内核回读 granted=1" || bad "没有 granted=1 的回读(授权来源没证)"
echo "$SM" | grep -aA2 "\[3b\]" | grep -aqqE "^ *0 *$" 2>/dev/null || true
if echo "$SM" | grep -aA2 "\[3b\]" | grep -aqq "^ *0 *$"; then ok "变 root 后 /proc/self/fd 里 ksu_driver 计数=0"; else bad "[3b] 没读到 0(可能把驱动 fd 漏进了 shell)"; fi

echo "--- 4. PC 侧独立复核：挂载状态下框架确实还能起 app ---"
echo "$SF" | grep -aqE "Found [1-9][0-9]* services" && ok "service list 非 0" || bad "service list 是 0"
echo "$SF" | grep -aq "Starting: Intent" && ok "am start 真起了一次 app" || bad "am start 没成功 ⇒ 挂载仍然把框架弄坏了"

echo "--- 5. 态③(整发的关键)：挂载 + 撤名单 ⇒ 必须是 agent 拒绝，不能是 errno=2 ---"
echo "$B3" | grep -aq "^ *su: agent 拒绝: ERR not-allowed" && ok "B 子段回执 = agent 按内核名单拒绝" || bad "没看到 not-allowed **回执行** ⇒ 负对照不成立"
echo "$B3" | grep -aq "SUPATH-EXECVP-FAIL" && bad "撤名单态的 B 子段出现 EXECVP-FAIL ⇒ 文件不在了，测的不是鉴权" || ok "B 子段不是 EXECVP-FAIL(文件仍在)"
echo "$B3" | grep -aq "uid=0(root)" && bad "撤了名单还能拿 root ⇒ 授权面漏了" || ok "撤名单后拿不到 root"
echo "$S3" | grep -aq "allow=0" && ok "回执里有 allow=0 那次 SETPROF" || bad "没证到名单确实撤了"

echo "--- 6. 收尾：先 umount 成功再删源，且回到原状 ---"
echo "$ST" | grep -aq "MOUNT_LEFT=0" && ok "MOUNT_LEFT=0" || bad "还挂着"
echo "$ST" | grep -aq "SU_GONE=.*No such file" && ok "su 又变回不存在" || bad "su 没跟着卸掉"
echo "$ST" | grep -aq "RM_DIRS_OK" && ok "源目录已删(且是在 umount 之后)" || bad "源目录没删或顺序不对"
echo "$ST" | grep -aq "uid=0(root)" && bad "卸载后探针居然还能拿 root" || ok "卸载后拿不到 root"

echo
[ $fail = 0 ] && echo "=== 全绿：挂载路线三态判据成立(所有 app 可见 su，授权只在内核) ===" || echo "=== 有 FAIL，见上 ==="
exit $fail
