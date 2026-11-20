#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_a_prime.py —— A′(单变量重编 rc82b) 的**纯只读**第二步 preflight。
   与 probe_rc82b.py 互补：那个查构建环境，这个查
     ① ksu_dev_syms_init() 的调用时机（见证节点能否放在 report 序列之前）
     ② .o 的真实 mtime 与 .cmd 依赖（如何冻结 sucompat.o 不被 make 顺带重编）
     ③ dev_syms_init / 现有 proc 节点的写法（照抄模板）
   不上传、不编译、不改任何远端文件。
"""
import sys, time
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

CMD = r"""
echo "=== ① ksu_dev_syms_init 定义/调用点 ==="
grep -rn 'ksu_dev_syms_init' /root/k/ksu/kernel --include=*.c --include=*.h 2>/dev/null | head -20
echo "=== ② init.c 关键行号索引 ==="
grep -n 'dev_syms\|KSUBEAT\|KSUSTEP\|killscan\|fd_install\|kobject_del' /root/k/ksu/kernel/core/init.c | head -60
echo "=== ③ 全部 .o 的 mtime（按时间排序）==="
find /root/k/ksu/kernel -name '*.o' -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' | sort
echo "=== ④ sucompat.o / .cmd / .c 精确 mtime ==="
ls -l --time-style=full-iso /root/k/ksu/kernel/feature/sucompat.o /root/k/ksu/kernel/feature/.sucompat.o.cmd /root/k/ksu/kernel/feature/sucompat.c 2>&1
echo "=== ⑤ .sucompat.o.cmd 依赖头部 ==="
head -c 1500 /root/k/ksu/kernel/feature/.sucompat.o.cmd 2>&1; echo
echo "=== ⑥ dev_syms_init 函数体（403-470）==="
sed -n '403,470p' /root/k/ksu/kernel/infra/dev_syms.c
echo "=== ⑦ 现有 proc 节点写法模板（ksu_slots 附近 930-975）==="
sed -n '925,975p' /root/k/ksu/kernel/infra/dev_syms.c
echo "=== ⑧ Kbuild 三个关键 .o 条目 ==="
grep -n 'dev_syms\|sucompat\|selinux' /root/k/ksu/kernel/Kbuild
echo "=== ⑨ selinux.c 全文（7208 B，确认 include 与裸接口插入点）==="
sed -n '1,60p' /root/k/ksu/kernel/selinux/selinux.c
"""

for attempt in range(3):
    try:
        r = api.exec(CMD, timeout=240)
        print("rc=%s started=%s timed_out=%s elapsed=%.1fs" %
              (r.exit_code, r.started, r.timed_out, r.elapsed), flush=True)
        print(r.stdout[:18000], flush=True)
        if r.stderr.strip():
            print("STDERR:", r.stderr[:600], flush=True)
        break
    except Exception as e:
        print("attempt %d failed: %s" % (attempt + 1, e), flush=True)
        time.sleep(2)
