#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc17：fd 回填的诊断 + 兜底(md §6.33)。

第十二发一手现场(stage=4, rc16)：
  KSUBEAT C1 reboot kprobe hit: frame=…d30 real_regs=…ec0 frame_x0=…ec0   ← PT_REAL_REGS 是对的
  KSUBEAT C2 magics: m1=0xdeadbeef m2=0xcafebabe want=…/… x3=0x7ffd55240c  ← 魔数匹配、outp 就是用户指针
  KernelSU: [17723] install ksu fd: 3                                       ← fd 真的装进进程了
  KernelSU: install ksu fd reply err                                        ← 只有"把 fd 号回传"这步失败
⇒ 传输层其余环节**全部工作**；而且更糟的是 KSU 的回错路径会 `ksu_close_fd(fd)` 把刚装的 fd 关掉
   ⇒ 用户态两头空。这一发要同时拿"为什么"和"绕过它"：
   1) 三条独立探针：`copy_to_user`(原路) / `put_user`(另一条实现:单字存储) /
      `ksu_copy_from_user_nofault` 从**同一个地址读一字节**(区分"这块内存根本不可达"与"只是写不进去")；
   2) 默认**不再关 fd**(新参数 `ksu_fd_reply_strict`，默认 0=不关)
      ⇒ 就算三条全废，用户态还能扫 `/proc/self/fd` 认出 `[ksu_driver]` 拿到 fd(ksuctl 已实现 scan)；
   3) 所有结果打在一行 `KSUBEAT D` 里 ⇒ 一发窗口就够定案。
幂等：靠 tag。
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
F = M + "/supercall/supercall.c"

OLD = ('    if (copy_to_user(tw->outp, &fd, sizeof(fd))) {\n'
       '        pr_err("install ksu fd reply err\\n");\n'
       '        ksu_close_fd(fd);\n'
       '    }\n')

NEW = '''    {
        int probe = -1;
        int r1 = (int)copy_to_user(tw->outp, &fd, sizeof(fd));
        int r2 = r1 ? put_user(fd, (int __user *)tw->outp) : 0;
        int r3 = ksu_copy_from_user_nofault(&probe, (int __user *)tw->outp, 1);

        pr_info("KSUBEAT D reply: outp=%px copy_to_user=%d put_user=%d readback1=%d probe=%d fd=%d strict=%d\\n",
                tw->outp, r1, r2, r3, probe, fd, ksu_fd_reply_strict);
        if (r1 && r2 && ksu_fd_reply_strict) {
            pr_err("install ksu fd reply err + strict=1 ⇒ 关掉 fd\\n");
            ksu_close_fd(fd);
        } else if (r1 && r2) {
            pr_info("KSUBEAT D keep fd=%d：两条写路都不行，但**不关** ⇒ 用户态可扫 /proc/self/fd 认 [ksu_driver]\\n", fd);
        }
    }
'''

PARAM_OLD = "static void ksu_install_fd_tw_func(struct callback_head *cb)\n"
PARAM_NEW = '''/* 回填失败时是否照上游那样把 fd 关掉。默认 0 = **不关**：
 * 本机实测"回填这一步"三条路都可能不通(见 md §6.33)，而 fd 本身是装好的；
 * 留着 fd，用户态还能靠 /proc/self/fd 认出 "[ksu_driver]" 拿到它 ⇒ 别让清理动作变成自毁。 */
static bool ksu_fd_reply_strict;
module_param(ksu_fd_reply_strict, bool, 0600);

''' + PARAM_OLD

s = io.open(F, encoding="utf-8", errors="replace").read()
n = 0
for tag, old, new in (("KSUBEAT D", OLD, NEW),
                      ("module_param(ksu_fd_reply_strict", PARAM_OLD, PARAM_NEW)):
    if tag in s:
        print("  = 已有, 跳过 %s" % tag)
        continue
    c = s.count(old)
    if c != 1:
        print("  !! 锚点命中 %d 次, 不动: %s" % (c, tag))
        continue
    s = s.replace(old, new, 1)
    n += 1
    print("  + %s" % tag)
io.open(F, "w", encoding="utf-8", newline="\n").write(s)
print("写了 %d 处 -> %s" % (n, F))
