#!/system/bin/sh
# w161_suredir_test.sh —— 诊断 A 的严谨收口：在 0x0 窗口里，绕过已坏的官方 UI，
#   直接验证 ko 的"授权核心 + GRANT_ROOT 交付"对【已授权 uid】是否成立、对【未授权 uid】是否拒绝。
#   跑法：经由 @sushd 通道以 root(uid 0) 身份执行（com.suw.manager 预授权通道）。
OUT=/data/local/tmp/w161_suredir_test.out
K=/data/local/tmp/ksuctl
{
echo "=== SU_REDIR_TEST up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) ==="
echo "CHAN_PROBE uid=$(id -u)  (0 => @sushd root 通道存活)"
echo "--- ① granted 基线：期望 10342(suw,预授权)=1；10349/10475/10261(标准 app)=0 ---"
for u in 10342 10349 10475 10261; do
  echo "granted $u : $($K granted $u 2>&1 | grep -a UID_GRANTED_ROOT | tr -d '\r')"
done
echo "--- ② setprof 10349 从 root 侧试写（信息性：若 only_manager 则必 EPERM，证明非官方 UI 无可授权入口）---"
echo "setprof 10349 : $($K setprof 10349 com.omarea.vtools - 2>&1 | tr -d '\r')"
echo "granted 10349 after setprof : $($K granted 10349 2>&1 | grep -a UID_GRANTED_ROOT | tr -d '\r')"
echo "--- ③ passfd 10342（预授权 => 期望 GRANT_ROOT rc=0 且 uid 变 0）：正向证人，ko 授权核心可用 ---"
$K passfd 10342 1 2>&1 | tr -d '\r'
echo "--- ④ passfd 10349（未授权 => 期望 GRANT_ROOT rc=-1 EPERM 且 uid 仍为 10349）：反向证人，白名单确实卡人 ---"
$K passfd 10349 1 2>&1 | tr -d '\r'
echo "=== DONE ==="
} > "$OUT" 2>&1
chmod 666 "$OUT"
