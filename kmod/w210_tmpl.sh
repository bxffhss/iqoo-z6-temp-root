#!/system/bin/sh
# w210_tmpl.sh —— root 侧短腿：把自制模板放进**官方 ksud 认的那个目录**，并立刻用官方那条 CLI 自读一遍。
#   为什么要"自读一遍"(§6.211 的已知答案样本)：Manager 列模板走的是
#     `libksud.so profile list-templates` → `get-template <id>`(KsuCli.kt:588~598)，
#   文件名必须**等于 id**、JSON 里必须有 `id`(profile.rs:22~55 + TemplateInfo.fromJSON 的 getString("id"))。
#   这两格错了，页面上就是"没有模板"，会被误读成"自制模板这条路不通"。
# ★这一腿只做装机+自证，不碰 UI；UI 那半在 PC 侧走(见 §6.211 的判据表)。
O=/data/local/tmp/w210_tmpl.out
exec >"$O" 2>&1
D=/data/adb/ksu/profile/templates
ID=vivoshell.root
LIB=$(ls /data/app/*/me.weishu.kernelsu-*/lib/arm64/libksud.so 2>/dev/null | head -1)
echo "=== W210 装自制模板 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
echo "本腿身份: attr_current=[$(cat /proc/self/attr/current 2>&1)] cap=[$(grep -m1 CapEff /proc/self/status | tr -s ' ')]"
mkdir -p "$D" 2>&1
cat >"$D/$ID" <<'JEOF'
{
    "id": "vivoshell.root",
    "name": "Vivo Shell Domain (self-made)",
    "author": "local",
    "description": "Same as the official *.root templates but with context u:r:shell:s0, because this device's base policy has no u:r:ksu:s0 domain (late-loaded LKM on a vivo user build).",
    "uid": 0,
    "gid": 0,
    "groups": ["SHELL"],
    "context": "u:r:shell:s0",
    "namespace": "INHERITED",
    "flags": ["NO_NEW_PRIVS"],
    "capabilities": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID", "CAP_SETGID", "CAP_SETUID", "CAP_NET_BIND_SERVICE", "CAP_NET_RAW", "CAP_SYS_ADMIN", "CAP_SYS_PTRACE", "CAP_SYS_RAWIO", "CAP_SYS_CHROOT", "CAP_SYS_MODULE", "CAP_SYS_BOOT", "CAP_SYS_RESOURCE", "CAP_SYS_TTY_CONFIG", "CAP_MKNOD", "CAP_KILL", "CAP_SYSLOG", "CAP_AUDIT_WRITE"]
}
JEOF
chmod 644 "$D/$ID" 2>/dev/null
echo "--- 落盘 ---"
ls -lZ "$D" 2>&1
echo "字节=$(wc -c <"$D/$ID" 2>/dev/null) 行=$(wc -l <"$D/$ID" 2>/dev/null)"

echo "--- ★用官方那条 CLI 自读(格式对不对以此为准) ---"
echo "LIBKSUD=[$LIB]"
if [ -n "$LIB" ]; then
    echo "list-templates 输出:"; "$LIB" profile list-templates 2>&1 | sed 's/^/    /'
    echo "get-template 回执 rc 前 3 行:"; "$LIB" profile get-template "$ID" 2>&1 | head -3 | sed 's/^/    /'
    echo "  (rc=$?)"
else
    echo "  !! 找不到 libksud.so(官方没装?) —— 那这条腿的自证作废，只能靠页面"
fi
echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
chmod 666 "$O" 2>/dev/null
