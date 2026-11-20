#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_rc82b.py —— A(rc82b 全量重编) 的**纯只读** preflight。
   不上传、不编译、不改任何远端文件；只把决策所需的事实捞回来。
   用法：python3 probe_rc82b.py
"""
import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")


def show(title, cmd, timeout=180, limit=9000):
    print("\n===== %s =====" % title, flush=True)
    r = api.exec(cmd, timeout=timeout)
    print("rc=%s started=%s timed_out=%s elapsed=%.1fs" %
          (r.exit_code, r.started, r.timed_out, r.elapsed), flush=True)
    print(r.stdout[:limit], flush=True)
    if r.stderr.strip():
        print("STDERR:", r.stderr[:800], flush=True)


print("PING:", api.ping(), flush=True)

show("① 源码树状态 / 锚点 / rc82 残留 / 备份", r"""
cd /root/k/ksu || exit 1
echo "--- git status (前 40)"; git status --short 2>&1 | head -40
for f in /root/k/ksu/kernel/selinux/selinux.c /root/k/ksu/kernel/infra/dev_syms.c /root/k/ksu/kernel/core/init.c; do
  echo "--- $f"; ls -l "$f" 2>&1
done
echo "--- 备份文件"; ls -l /root/k/ksu/kernel/selinux/selinux.c.rc82bak /root/k/ksu/kernel/infra/dev_syms.c.rc82bak 2>&1
echo "--- md5 当前 vs 备份"
md5sum /root/k/ksu/kernel/selinux/selinux.c /root/k/ksu/kernel/selinux/selinux.c.rc82bak \
       /root/k/ksu/kernel/infra/dev_syms.c /root/k/ksu/kernel/infra/dev_syms.c.rc82bak 2>&1
echo "--- 锚点/残留计数"
echo -n "SEL getenforce锚点="; grep -c '^bool getenforce(void)' /root/k/ksu/kernel/selinux/selinux.c
echo -n "DEV fd_install锚点="; grep -c '^void ksu_fd_install_run(void)' /root/k/ksu/kernel/infra/dev_syms.c
echo -n "SEL rc82残留(ksu_enforce_get_raw)="; grep -c 'ksu_enforce_get_raw' /root/k/ksu/kernel/selinux/selinux.c
echo -n "DEV rc82残留(ksu_keep_permissive)="; grep -c 'ksu_keep_permissive' /root/k/ksu/kernel/infra/dev_syms.c
""")

show("② init.c 调用链（140-235）", "sed -n '140,235p' /root/k/ksu/kernel/core/init.c", limit=12000)

show("③ killscan 定义位置与实现", r"""
echo "--- 定义在哪"; grep -rn 'ksu_killscan_run\|ksu_fd_install_run' /root/k/ksu/kernel --include=*.c --include=*.h 2>&1 | head -30
echo "--- killscan 实现(前 90 行)"; f=$(grep -rl 'void ksu_killscan_run' /root/k/ksu/kernel --include=*.c | head -1); echo "FILE=$f"; [ -n "$f" ] && grep -n 'void ksu_killscan_run' "$f" | head -1 | cut -d: -f1 | xargs -r -I{} sh -c 'sed -n "{},$(({}+90))p" '"$f"
""", limit=12000)

show("④ 构建产物现状（.o 数量 / mtime 分布 / sucompat.c）", r"""
echo "--- .o 数量"; find /root/k/ksu/kernel -name '*.o' | wc -l
echo "--- .o mtime 分布(按天)"; find /root/k/ksu/kernel -name '*.o' -printf '%TY-%Tm-%Td\n' | sort | uniq -c
echo "--- 关键源码 mtime"; ls -l --time-style=full-iso /root/k/ksu/kernel/feature/sucompat.c /root/k/ksu/kernel/selinux/selinux.c /root/k/ksu/kernel/infra/dev_syms.c /root/k/ksu/kernel/core/init.c /root/k/ksu/kernel/Kbuild 2>&1
echo "--- 现役 ko"; md5sum /root/k/ksu/kernel/kernelsu.ko /home/lucy/kernelsu_rc82_kp.ko 2>&1; ls -l --time-style=full-iso /root/k/ksu/kernel/kernelsu.ko
echo "--- Kbuild 里 kernelsu-objs 行数"; grep -c 'kernelsu-objs' /root/k/ksu/kernel/Kbuild
echo "--- Kbuild 是否有 clean 目标"; grep -n 'clean' /root/k/ksu/kernel/Kbuild | head -20
echo "--- /home/lucy 可写与容量"; touch /home/lucy/.probe_rc82b && rm -f /home/lucy/.probe_rc82b && echo WRITABLE; df -h /home/lucy | tail -1
""")

show("⑤ make clean 会删什么（dry-run，绝不动手）", r"""
cd /root/k/nothing_sm7325_v_mr && make -n -C /root/k/nothing_sm7325_v_mr M=/root/k/ksu/kernel \
  src=/root/k/ksu/kernel CONFIG_KSU=m ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld clean 2>&1 | head -60
""", timeout=240, limit=9000)

show("⑥ 5.4 内核 /proc API（决定见证节点怎么写）", r"""
echo "--- proc_create 签名"; grep -n 'proc_create\|struct proc_ops\|struct file_operations' /root/k/nothing_sm7325_v_mr/include/linux/proc_fs.h | head -30
echo "--- 内核版本"; grep -m1 '^VERSION\|^PATCHLEVEL\|^SUBLEVEL' /root/k/nothing_sm7325_v_mr/Makefile | head -5; cat /root/k/nothing_sm7325_v_mr/include/config/kernel.release 2>/dev/null
echo "--- KSU 里现成的 proc_create 用例"; grep -rn 'proc_create\|proc_ops\|single_open' /root/k/ksu/kernel --include=*.c | head -30
""", limit=9000)

print("\n===== PROBE DONE =====", flush=True)
