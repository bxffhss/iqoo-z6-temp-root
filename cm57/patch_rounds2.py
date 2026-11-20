# -*- coding: utf-8 -*-
"""pr.c 第 2 步: main 侧的"回合推进"(一笔有效写 = 一颗幽灵)。"""
import io

p = 'pr.c'
s = io.open(p, encoding='utf-8').read()

helper = r'''
/* ============ 回合制: 一幽灵 = 一笔有效写 ============ */
static void make_ghost(void) {
  for (int i = 0; i < 30; i++) {
    errno = 0;
    long r = fx(N, FCMP, 1, (struct timespec *)1, PI, 0);
    if (r == -1 && errno == EDEADLK) return;      /* 回滚走 remove_waiter ⇒ 留下幽灵 */
    usleep(100000);
  }
  say("× 造幽灵失败(30 次没拿到 EDEADLK)\n");
  stop_all = 1;
}

static int next_round(int *phase, int *rounds) {   /* 0 = 别再打了 */
  *phase += 1; *rounds = 0;
  __atomic_store_n(&h_phase, *phase, __ATOMIC_RELEASE);
  if (*phase > MAX_ROUNDS) { say("× 到回合上限(%d) ⇒ 收工\n", MAX_ROUNDS); return 0; }
  __atomic_store_n(&h_round_end, 1, __ATOMIC_RELEASE);
  int w = 0;                                       /* 等 W 交回回合(它要重新睡进 futex) */
  while (__atomic_load_n(&st_ghost, __ATOMIC_ACQUIRE) != 0 && w++ < 250) usleep(20000);
  make_ghost();
  w = 0;                                           /* 等 W 超时返回 ⇒ 幽灵成型 */
  while (__atomic_load_n(&st_ghost, __ATOMIC_ACQUIRE) != 1 && w++ < 500) usleep(20000);
  say("[R] === 回合 %d 开始(新幽灵已造好) ===\n", *phase);
  return !stop_all;
}

int main(int argc, char **argv) {'''
anchor = '\nint main(int argc, char **argv) {'
assert anchor in s
s = s.replace(anchor, helper, 1)

old_adv = 'phase++; rounds = 0; __atomic_store_n(&h_phase, phase, __ATOMIC_RELEASE);'
n = s.count(old_adv)
assert n >= 3, n
s = s.replace(old_adv, 'if (!next_round(&phase, &rounds)) break;')

io.open(p, 'w', encoding='utf-8').write(s)
print('ok-part2 (替换了 %d 处回合推进)' % n)
