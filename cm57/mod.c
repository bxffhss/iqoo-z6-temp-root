/* mod.c — 最小模块加载探针(2026-09-29)
 * 目的只有一个: 在临时 root 窗口里判定"外部 .ko 能不能被本机内核接受"。
 * 只用两个 syscall, 不依赖任何内核头文件 ⇒ NDK 静态编译即可。
 *
 *   ./mod ins  <path.ko>     finit_module(fd, "", 0)  → 打印 rc/errno
 *   ./mod rm   <name>        delete_module(name, 0)
 *   ./mod ls                 打印 /proc/modules
 *   ./mod state <name>       打印 /sys/module/<name>/initstate
 *   ./mod info <path.ko>     在裸文件里扫 vermagic=/srcversion=/depends= 并打印
 *
 * errno 读法(判定要看数字, 别只看"失败"):
 *   1 EPERM   = 能力/策略挡(我们 CapEff 全 1 ⇒ 应排除, 出现即厂商自建 LKM 门)
 *   13 EACCES = SELinux/DAC 挡(permissive + uid0 下应排除)
 *   8  ENOEXEC= ELF 形态问题(与被拒无关, 说明**已经进到格式解析**)
 *   22 EINVAL = 常见于 vermagic/模块格式串不对
 *   2  ENOENT = "Unknown symbol" / disagrees about version of symbol(CRC/namespace 门)
 *   71 EPROTO= .ko 压缩/ELF 段异常
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/types.h>

#ifndef __NR_finit_module
#define __NR_finit_module 278
#endif
#ifndef __NR_delete_module
#define __NR_delete_module 279
#endif

static int dump_file(const char *p, const char *tag) {
  char buf[512];
  FILE *f = fopen(p, "r");
  if (!f) { printf("[%s] open %s: %s\n", tag, p, strerror(errno)); return -1; }
  while (fgets(buf, sizeof(buf), f)) fputs(buf, stdout);
  fclose(f);
  return 0;
}

static int do_ins(const char *path) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) { printf("[INS] open %s: errno=%d(%s)\n", path, errno, strerror(errno)); return 1; }
  off_t sz = lseek(fd, 0, SEEK_END);
  lseek(fd, 0, SEEK_SET);
  errno = 0;
  long rc = syscall(__NR_finit_module, fd, "", 0);
  int e = errno;
  if (rc == 0)
    printf("[INS] %s size=%lld rc=0 OK_LOADED\n", path, (long long)sz);
  else
    printf("[INS] %s size=%lld rc=%ld errno=%d(%s)\n", path, (long long)sz, rc, e, strerror(e));
  close(fd);
  return rc == 0 ? 0 : 2;
}

static int do_rm(const char *name) {
  errno = 0;
  long rc = syscall(__NR_delete_module, name, 0);
  int e = errno;
  if (rc == 0) printf("[RM] %s rc=0 UNLOADED\n", name);
  else printf("[RM] %s rc=%ld errno=%d(%s)\n", name, rc, e, strerror(e));
  return rc == 0 ? 0 : 2;
}

static int do_state(const char *name) {
  char p[256];
  snprintf(p, sizeof(p), "/sys/module/%s/initstate", name);
  return dump_file(p, "STATE");
}

/* 在裸 .ko 里找字符串(不解析 ELF section, 够用且不需要头文件) */
static int do_info(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { printf("[INFO] open %s: %s\n", path, strerror(errno)); return 1; }
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 1; }
  long sz = ftell(f);
  rewind(f);
  if (sz <= 0 || sz > (8L << 20)) { printf("[INFO] bad size %ld\n", sz); fclose(f); return 1; }
  char *b = malloc((size_t)sz + 1);
  if (!b) { fclose(f); return 1; }
  size_t got = fread(b, 1, (size_t)sz, f);
  fclose(f);
  b[got] = 0;
  static const char *keys[] = { "vermagic=", "name=", "version=", "srcversion=",
                                "depends=", "retpoline=", "staging=", "intree=" };
  for (unsigned k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
    size_t kl = strlen(keys[k]);
    for (size_t i = 0; i + kl < got; i++) {
      if (memcmp(b + i, keys[k], kl) != 0) continue;
      size_t j = i;
      while (j < got && b[j] != 0) j++;
      printf("[INFO] %.*s\n", (int)(j - i), b + i);
      break;   /* 每个 key 只打印第一次命中 */
    }
  }
  printf("[INFO] bytes=%ld\n", (long)got);
  free(b);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    printf("usage: mod ins <k.o> | rm <name> | ls | state <name> | info <k.o>\n");
    return 2;
  }
  const char *c = argv[1];
  if (!strcmp(c, "ins") && argc >= 3) return do_ins(argv[2]);
  if (!strcmp(c, "rm") && argc >= 3) return do_rm(argv[2]);
  if (!strcmp(c, "ls")) return dump_file("/proc/modules", "LS");
  if (!strcmp(c, "state") && argc >= 3) return do_state(argv[2]);
  if (!strcmp(c, "info") && argc >= 3) return do_info(argv[2]);
  printf("usage: mod ins <k.o> | rm <name> | ls | state <name> | info <k.o>\n");
  return 2;
}
