#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_rc82b.py —— rc82b 产物验收（纯只读）。
   核对：见证节点编进去了、只在 ksu_dev_syms_init 里创建、report 段与 rc80/rc82_kp 仍等价、
   源码已还原、sucompat.o 未被动过。
"""
import sys
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
H = "/home/lucy"

CMD = r"""
echo "=== ① 三把 ko 的 size / md5 ==="
ls -l /home/lucy/kernelsu_rc80_cmp.ko /home/lucy/kernelsu_rc82_kp.ko /home/lucy/kernelsu_rc82b.ko
md5sum /home/lucy/kernelsu_rc80_cmp.ko /home/lucy/kernelsu_rc82_kp.ko /home/lucy/kernelsu_rc82b.ko

echo "=== ② rc82b 见证节点字节搜索（grep -ac，不能用 strings）==="
K=/home/lucy/kernelsu_rc82b.ko
for s in 'ksu_kp_stat' 'param=%u started=%u hits=%lu now_enforcing=%d' 'KSUKEEP' \
         'ksu_keep_permissive' 'KSUKEEP 已启动' 'ksu_enforce_get_raw'; do
  printf '  [%s] = %s\n' "$s" "$(grep -ac "$s" "$K")"
done
echo "  --- 三把 ko 对比 ksu_kp_stat / KSUKEEP ---"
for k in kernelsu_rc80_cmp.ko kernelsu_rc82_kp.ko kernelsu_rc82b.ko; do
  printf '  %-28s kp_stat=%s KSUKEEP=%s\n' "$k" \
    "$(grep -ac 'ksu_kp_stat' /home/lucy/$k)" "$(grep -ac 'KSUKEEP' /home/lucy/$k)"
done

echo "=== ③ rc82b 关键符号（nm -S）==="
aarch64-linux-gnu-nm -S --defined-only $K | grep -E 'ksu_(kp_|enforce_|killscan_run|.*_report|dev_syms_init|fd_install_run|sym_addr)'
echo "  --- module_param 条目 ---"
aarch64-linux-gnu-nm $K | grep -E '__param_ksu_keep_permissive|__mod_ksu_keep|ksu_kp_stat'

echo "=== ④ report/killscan 段：三把 ko 的 size 对照（应逐一全同）==="
for k in kernelsu_rc80_cmp.ko kernelsu_rc82_kp.ko kernelsu_rc82b.ko; do
  echo "  --- $k"
  aarch64-linux-gnu-nm -S --defined-only /home/lucy/$k | \
    grep -E 'ksu_(killscan_run|lsmhook_report|slottbl_report|pcode_report|uts_report|sym_addr)' | \
    awk '{printf "     %-28s size=%s\n", $4, $2}'
done

echo "=== ⑤ ksu_dev_syms_init 里真的调了 proc_create 吗（objdump -dr 看重定位）==="
aarch64-linux-gnu-objdump -dr $K 2>/dev/null | \
  awk '/<ksu_dev_syms_init>:/{f=1} f{print} f&&/^$/{exit}' | \
  grep -E 'R_AARCH64_CALL26|R_AARCH64_ADR|proc_create|ksu_kp_stat|bl\t' | head -25

echo "=== ⑥ 源码还原终态（应与 .rc82bbak 同 md5）==="
md5sum /root/k/ksu/kernel/selinux/selinux.c /root/k/ksu/kernel/selinux/selinux.c.rc82bbak \
       /root/k/ksu/kernel/infra/dev_syms.c /root/k/ksu/kernel/infra/dev_syms.c.rc82bbak
echo -n "  rc82 残留 = "; grep -c 'ksu_keep_permissive' /root/k/ksu/kernel/infra/dev_syms.c

echo "=== ⑦ sucompat.o 终态 mtime ==="
stat -c '  %y  %n' /root/k/ksu/kernel/feature/sucompat.o
""" 
r = api.exec(CMD, timeout=300)
print("rc=%s started=%s timed_out=%s" % (r.exit_code, r.started, r.timed_out), flush=True)
print(r.stdout[:20000], flush=True)
if r.stderr.strip():
    print("STDERR:", r.stderr[:800], flush=True)
