/* sp.c — KASLR slide 的**正对照**负载: 只反复打一个指定的 syscall。
 *
 * 为什么需要它: slide.py 靠"热点名字像不像热路径"来选候选, 而候选之间只差 2MB,
 * 错位的候选也会把样本映到另一批**看起来也合理**的符号上(9/27 就选错了:
 * 真候选区间内 452/467, 被选的那个 443/447)。
 * 正对照不留解释空间: 如果我让设备只跑 `getppid()`, 那么样本**必须**落在
 *   el0_sync / el0_svc / el0_svc_common / ret_to_user / __arm64_sys_getppid
 * 这几个链接期地址 + slide 的窗口里; 错 2MB 的候选会一个都落不进去。
 *
 * 用法: sp <syscall_nr> [秒]
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <time.h>

int main(int argc, char **argv) {
  long nr = argc > 1 ? strtol(argv[1], NULL, 0) : 173;   /* 默认 getppid */
  int secs = argc > 2 ? atoi(argv[2]) : 30;
  struct timespec t0, t;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  unsigned long n = 0;
  for (;;) {
    syscall(nr);
    syscall(nr);
    syscall(nr);
    syscall(nr);
    n += 4;
    if ((n & 0xFFFF) == 0) {
      clock_gettime(CLOCK_MONOTONIC, &t);
      if (t.tv_sec - t0.tv_sec >= secs) break;
    }
  }
  printf("nr=%ld loops=%lu\n", nr, n);
  return 0;
}
