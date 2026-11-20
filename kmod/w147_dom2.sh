#!/system/bin/sh
# ★★★ 这一类脚本的规矩(第 45 发用 11.9GB 的日志换来)：
#   开头是**脚本级** `exec >"$L"` 时，末尾**绝对不能再 `cat "$L"`** ——
#   cat 读的就是自己的 stdout ⇒ 读到的字节又被写回同一个文件 ⇒ **永远读不到 EOF**，
#   文件每轮翻倍(实测涨到 11.9GB 把 G 盘写满，`sed: No space left on device`)。
#   安全的两种写法：① 用块级重定向 `{ … } >"$L" 2>&1` 再在**块外** cat(如 w133_probe.sh)；
#   ② 脚本级 exec 就只写不回显，由**驱动侧**去 cat(下面这种)。
# w147_dom2.sh —— #53 的**极简版**(窗口只剩几分钟时用)：只回答一个问题——
#   "SET_APP_PROFILE 里自填的 selinux_domain 到底落不落地"，判据只有 attr/current 一行。
# ★不再用函数：这台机的 /system/bin/sh 是 mksh，**`r` 是它的预定义别名(=fc -e -)**，
#   我上一版把判据函数叫 `r()`，于是每一行都变成 `fc: history functions not available`
#   (整段判据没跑，而 WHO/CTX 那几行照常输出 ⇒ 看起来像"测到了但没差异")。
export PATH=/system/bin:/system/xbin:/product/bin
echo "=== DOM2 up=$(cut -d' ' -f1 /proc/uptime) enf=$(getenforce) ==="
/system/bin/id
cat /proc/self/attr/current; echo
grep -aE '^CapEff|^Seccomp:' /proc/self/status
echo "看哪个域：上面第二行若 = 期望域 ⇒ profile 的域真的落地；若还是起点域 ⇒ 没落地"
echo "=== DOM2-DONE ==="
