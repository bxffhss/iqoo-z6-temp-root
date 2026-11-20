#!/system/bin/sh
# w310_mgr.sh —— 第 107 发的主判据前置腿：把 root 授给**第二个 app**(官方 Manager 自己，uid=10104)。
#   为什么要选它：它是除 Termux 之外**唯一我们不需要新代码就能驱动**的 app —— libsu 的 RootService
#   在进程启动时就会去 exec `su` 并**用管道**收发结果(=交付说明里那条"能用的形状")，
#   所以"它能不能起来"直接回答"apk_data_file 那一支的通用性是不是只对 Termux 成立"。
#   ★域故意填 `u:r:ksu:s0`(与官方 UI 下发的同一个值) ⇒ 让 rc67 的解析失败回退去接管，走的是交付路径。
O=/data/local/tmp/w310_mgr.out
exec >>"$O" 2>&1
K=/data/local/tmp/ksuctl88
echo "=== W310 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "  授之前名单: $($K allowlist 2>&1 | tr -d '\000' | grep -a -E 'NEW_GET_ALLOW_LIST|allow\[' | tr '\n' '|')"
$K mgr 2>&1 | tr -d '\000' | grep -a GET_MANAGER_APPID
echo "STAGE1 done"
echo "  setprof 10104 me.weishu.kernelsu u:r:ksu:s0 的回执："
$K setprof 10104 me.weishu.kernelsu u:r:ksu:s0 2>&1 | tr -d '\000' | tail -6
echo "STAGE2 done"
echo "  授之后名单: $($K allowlist 2>&1 | tr -d '\000' | grep -a -E 'NEW_GET_ALLOW_LIST|allow\[' | tr '\n' '|')"
echo "  10104 单独问一次: $($K granted 10104 2>&1 | tr -d '\000' | tail -2)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
