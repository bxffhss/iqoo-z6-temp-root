#!/system/bin/sh
# w103_neg.sh —— **负对照**：让一个**不在名单里**的 uid 去敲 su，必须拿不到 root。
#   为什么必须有这一发(§"执行类判据要三判据+正对照")：正判据("授权的 uid 敲 su 出 uid=0")
#   单独看不能排除"改道其实是全局后门、谁都给 root"这个失败模式 —— 那正是最坏的一种回退。
#   10999 落在普通 app 的 uid 段(>10000，不会被 forbid_system_uid 提前拒)，但没人授权过它。
#   期望：内核走 `SD1/名单不命中` ⇒ 回落原实现 ⇒ `/system/bin/su` 不存在 ⇒ ENOENT/127。
L=/data/local/tmp/w103_run.out
{
    echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=10999 (名单外) cmd=[id] ==="
    /data/local/tmp/ksuctl86 su 10999 id
    echo "rc=$?"
} >"$L" 2>&1
chmod 666 "$L"
