#!/system/bin/sh
# dev_hooks_test.sh — 路线 A 的两块基石，跑在设备上(root 窗口内)，由 kmod/dev_round.sh 推上去执行。
# 分成 a/b 两步是刻意的：**先证明 handler 会被调用(只打印)**，再允许它去改寄存器；
# 偏移没被 4a 确认之前，4b 那种"写 regs[0]"的动作不允许跑。
cd /data/local/tmp || exit 1

echo "== 4a: 手搓模块的 kprobe handler 到底会不会被内核调用(只打印, 不改任何东西) =="
./modbin ins suwhook.ko
sleep 1
mkdir /data/local/tmp/suwhook_dir
echo "  mkdir rc=$?  (期望 0 —— 这个钩子只打印)"
rmdir /data/local/tmp/suwhook_dir 2>/dev/null
sleep 1
dmesg | grep -a 'suwhook:' | tail -8
./modbin rm suwhook

echo "== 4b: 钩子能否改变系统调用结果(= route A 需要的原语) + 成对控制 =="
mkdir /data/local/tmp/tpair
echo "  装钩子前 mkdir rc=$?  (期望 0)"
rmdir /data/local/tmp/tpair 2>/dev/null
./modbin ins suwperm.ko
sleep 1
mkdir /data/local/tmp/tpair
echo "  装钩子后 mkdir rc=$?  (期望非 0：被 post_handler 改成 -EPERM)"
rmdir /data/local/tmp/tpair 2>/dev/null
./modbin rm suwperm
sleep 1
mkdir /data/local/tmp/tpair
echo "  卸载之后 mkdir rc=$?  (期望 0：恢复原样，排除'本来就一直失败')"
rmdir /data/local/tmp/tpair 2>/dev/null
dmesg | grep -a 'suwperm:' | tail -8
echo "== 残留检查 =="
./modbin ls | grep -E 'suw' || echo "  (无 suw* 模块残留)"
