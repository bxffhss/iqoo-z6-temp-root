/* commtop.c — 只读: 把 /proc/sla 窗口里那张"每任务一条"的表的 **comm 全集**列出来。
 * 起因(2026-09-28, m1 轮): 子进程按 comm 找到了 W 的记录(8 条一致), 但按 main 的 comm
 * ("gm3c62", 也试过 "pr")一条都没找到 ⇒ 不知道表里 main 那行到底长什么样 ⇒ 别猜, 直接印。
 * 需要 permissive(enforcing 下 /proc/sla 连 stat 都 EACCES)。只读, 不 punch, 秒级。
 * 编译: 同 pr.c 的 NDK 命令。用法: commtop [窗口MB] [要搜的子串] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <sys/stat.h>

static sigjmp_buf jb;
static volatile int jon;
static void onbus(int s) { (void)s; if (jon) siglongjmp(jb, 1); }
static uint64_t q(unsigned char *b, size_t o) { uint64_t v; memcpy(&v, b + o, 8); return v; }
#define COMM 40
#define MAXD 3000

static char names[MAXD][17];
static uint64_t ptrs[MAXD];
static int cnts[MAXD], nd;

static int find_or_add(const char *c, uint64_t v) {
  for (int i = 0; i < nd; i++)
    if (!memcmp(names[i], c, 16)) { cnts[i]++; return i; }
  if (nd >= MAXD) return -1;
  memcpy(names[nd], c, 16); names[nd][16] = 0; ptrs[nd] = v; cnts[nd] = 1;
  return nd++;
}

int main(int argc, char **argv) {
  size_t MB = argc > 1 ? (size_t)strtol(argv[1], NULL, 0) : 1024;
  const char *want = argc > 2 ? argv[2] : NULL;
  int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open 失败 errno=%d(%s) ⇒ 需要 permissive\n", errno, strerror(errno)); return 1; }
  unsigned char *m = MAP_FAILED; size_t L = 0;
  for (size_t s = MB << 20; s >= (16u << 20); s >>= 1) {
    m = mmap(NULL, s, PROT_READ, MAP_SHARED, fd, 0);
    if (m != MAP_FAILED) { L = s; break; }
  }
  if (m == MAP_FAILED) { printf("mmap 失败\n"); return 1; }
  struct sigaction sa; memset(&sa, 0, sizeof sa);
  sa.sa_handler = onbus; sigemptyset(&sa.sa_mask); sigaction(SIGBUS, &sa, NULL);
  size_t np = L / 4096u;
  unsigned char *ok = calloc(np + 1, 1);
  size_t okp = 0;
  for (size_t i = 0; i < np; i++) {
    jon = 1;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = m[i * 4096u]; (void)c; ok[i] = 1; okp++; }
    jon = 0;
  }
  printf("[CT] len=%zuMB 可读=%zuMB\n", L >> 20, (okp * 4096u) >> 20);
  fflush(stdout);
  size_t nread = 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i] || (i + 1 < np && !ok[i + 1])) continue;
    for (size_t o = i * 4096u; o + COMM + 16 <= (i + 2) * 4096u && o + COMM + 16 <= L; o += 8) {
      uint64_t v;
      jon = 1;
      if (sigsetjmp(jb, 1) != 0) { jon = 0; break; }
      v = q(m, o); nread++;
      jon = 0;
      if ((v >> 48) != 0xffffULL || (v & 7)) continue;
      const unsigned char *c = m + o + COMM;
      /* 合法 comm = 前 t 个可打印 + 第 t 个是 NUL(1<=t<=15), 且不全为 0 */
      int t = 0, bad = 0;
      while (t < 16 && c[t] >= 0x20 && c[t] <= 0x7e) t++;
      if (t < 2 || t > 15 || c[t] != 0) bad = 1;
      if (bad) continue;
      char nm[17]; memcpy(nm, c, 16); nm[16] = 0;
      if (want) { if (!strstr(nm, want)) continue; }
      else { }
      int idx = find_or_add(nm, v);
      if (idx >= 0 && want) printf("[CT] 命中 comm=[%s] ptr=%016llx 窗口偏移=+%zu (0x%zx)\n",
                                   nm, (unsigned long long)v, o, o);
    }
  }
  printf("[CT] 扫了 %zu 个 8 字节槽, 去重后 %d 种 comm\n", nread, nd);
  /* 打印出现次数最多的前 40 种 */
  for (int pass = 0; pass < 1; pass++) {
    for (int n = 0; n < nd && n < 40; n++) {
      int best = 0;
      for (int i = 0; i < nd; i++) if (cnts[i] > cnts[best]) best = i;
      printf("   #%02d cnt=%-4d comm=[%s] ptr=%016llx\n", n + 1, cnts[best], names[best],
             (unsigned long long)ptrs[best]);
      cnts[best] = 0;
    }
  }
  return 0;
}
