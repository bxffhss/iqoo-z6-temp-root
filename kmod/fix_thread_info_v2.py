#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重写设备上 `struct thread_info` 的布局补丁到 **v2**（md §6.34）。

为什么必须重写而不是再打一层 pad：v1 的字段位置是**猜的**（"上游顺序 + 中间插 pad"），
而真机反汇编给出的是完全不同的位置：

  _copy_to_user:            mrs x8, sp_el0
                            ldr x10, [x8, #0x40]   ;  ← addr_limit 在 **0x40**（上游 0x08）
                            ... adds/cmp ... sbcs xzr, x11, x10   ; 就是 access_ok 的上界

  _raw_spin_lock_irqsave:   mrs x9, sp_el0
                            ldr w10, [x9, #0x50]   ;  ← preempt_count 在 **0x50**
                            add w10, w10, #1
                            str w10, [x9, #0x50]

  _copy_to_user / 130 处:   ldr x12, [x8]          ;  ← flags 仍在 0x00

⇒ v1 把 addr_limit 放在 8、把 0x50 当成 stack_canary ⇒ **我们模块里每一次 access_ok
   都拿垃圾值当上界** ⇒ 第十三发实测：`copy_to_user` / `put_user` / 自写的读一字节
   三条路对栈/静态/malloc/mmap 四种用户地址**全部 EFAULT**（`KSUBEAT D … copy_to_user=4
   put_user=-14 readback1=-14`）。这不是 VMA、不是方向、不是权限，就是这一个偏移。
⇒ 另外：之前当证据的"sp_el0 访存 5194 次落在 0x50 ⇒ 那是 per-task stack canary"
   **判错了** —— 5194 次就是 preempt_count（内核里最热的每任务计数）。真正的
   stack protector 位置来自厂商 clang 参数 `-mstack-protector-guard-offset=1424`(=0x590)，
   那是 **task_struct 相对**的，不在 thread_info 里。

做法：把 `struct thread_info { … };` 整块替换成下面这版（**只保证偏移对，不追求源码形似**，
这也是本项目一贯的 padded-header 口径）。幂等：靠 `__KSU_TI_V2` 标记。
"""
import io
import re
import sys

TREE = sys.argv[1] if len(sys.argv) > 1 else "/root/k/nothing_sm7325_v_mr"
P = TREE + "/arch/arm64/include/asm/thread_info.h"

V2 = '''struct thread_info {
	/* __KSU_TI_V2 —— 偏移全部来自真机 Image 反汇编(md §6.34)，不是上游位置。
	 * 结论：vivo 在 addr_limit **之前**插了 0x38 字节厂商字段，后面的相对顺序与上游一致，
	 *       于是 addr_limit/ttbr0/preempt_count/shadow_call_stack 依次落在 0x40/0x48/0x50/0x58，
	 *       整块 sizeof = 0x60（与 .rela 量到的 thread_info 大小吻合）。
	 * 四个字段都**必须保留**：`asm/uaccess.h:134` 读 ->ttbr0、SCS 相关头读 ->shadow_call_stack，
	 *       少一个就直接编译不过(inline 函数体也会被解析)。 */
	unsigned long	flags;		/* 0x00  实测: ldr x12,[x8] + tbz w12,#0x1a */
	char		__ksu_ti_pad0[0x40 - 8];
	mm_segment_t	addr_limit;	/* 0x40  实测: _copy_to_user 的 access_ok 上界 */
#ifdef CONFIG_ARM64_SW_TTBR0_PAN
	u64		ttbr0;		/* 0x48  实测: el1_ia/el1_undef 走 [x8,#0x48](17 处) */
#endif
	union {
		u64	preempt_count;	/* 0x50  实测: _raw_spin_lock_irqsave 的 32 位 RMW */
		struct {
#ifdef CONFIG_CPU_BIG_ENDIAN
			u32	need_resched;
			u32	count;
#else
			u32	count;
			u32	need_resched;
#endif
		} preempt;
	};
#ifdef CONFIG_SHADOW_CALL_STACK
	void		*shadow_call_stack;	/* 0x58（0x54 那处 resched_curr 命中 = need_resched ✓） */
#endif
};
'''

s = io.open(P, encoding="utf-8", errors="replace").read()
if "__KSU_TI_V2" in s:
    print("  = 已经是 v2, 跳过")
    sys.exit(0)

m = re.search(r"(?ms)^struct thread_info \{.*?^\};\n", s)
if not m:
    print("  !! 找不到 struct thread_info { ... }; 整块，不动")
    sys.exit(1)
old = m.group(0)
print("  替换前那块的字段:")
for ln in old.splitlines():
    if ln.strip() and not ln.strip().startswith("/*"):
        print("    " + ln.strip()[:78])
s = s[:m.start()] + V2 + s[m.end():]
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("  -> 已写入 v2 (%s)" % P)
print("  校验: grep -n '__KSU_TI_V2' -A 3 %s | head -6" % P)
