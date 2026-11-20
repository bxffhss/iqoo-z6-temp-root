/* macgate.c — 只读地量"哪些格子真的被 SELinux 拦"。
 * 起因(2026-09-28, 自查): pr.c 里 mac_probe() 的判据可能是**恒真**的 —— sen16/sen22 的
 * [MAC:before](那是 enforcing 状态、一发都没打之前)就已经"开了 2 格"(tracing_on /
 * buffer_size_kb 都能 open+write)。若某格在 enforcing 下就通得过, 它就不是 MAC 关卡
 * ⇒ "★★★ MAC 真的失效了 ★★★" 这句结论无效, 必须换判据。
 * 本工具**不写坏任何东西**: 写入一律"原值写回"(先读后写同值), 且 core_pattern 只试 open 不写。
 * 用法: macgate            (enforcing 基线); 提权/permissive 之后再跑一次做对比。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/xattr.h>

static void one(const char *p, int mode /*0=RDONLY,1=RDWR*/, int restore) {
  struct stat st;
  int ok = stat(p, &st) == 0;
  printf("%-40s ", p);
  if (ok) printf("mode=%04o uid=%d gid=%d | ", st.st_mode & 07777, st.st_uid, st.st_gid);
  else printf("stat=FAIL(%s) | ", strerror(errno));
  errno = 0;
  int fd = open(p, mode | O_CLOEXEC);
  if (fd < 0) { printf("open=-1 errno=%d(%s)\n", errno, strerror(errno)); return; }
  char b[128];
  memset(b, 0, sizeof b);
  ssize_t r = read(fd, b, sizeof b - 1);
  int er = errno;
  printf("open=OK read=%zd", r);
  if (r > 0) {
    char s[64];
    size_t n = r < (ssize_t)sizeof(s) - 1 ? (size_t)r : sizeof(s) - 1;
    memcpy(s, b, n); s[n] = 0;
    for (size_t i = 0; i < n; i++) if (s[i] == '\n') s[i] = ' ';
    printf(" 内容=[%s]", s);
  } else printf(" readerrno=%d(%s)", er, strerror(er));
  if (restore && r > 0) {                      /* 原值写回 = 不留改动 */
    lseek(fd, 0, SEEK_SET);
    ssize_t w = write(fd, b, r);
    printf(" | 原值写回=%zd errno=%d(%s)", w, errno, strerror(errno));
  } else if (restore) {
    printf(" | 没读到东西⇒不写");
  }
  printf("\n");
  close(fd);
}

int main(void) {
  printf("[macgate] uid=%d euid=%d gid=%d  (与 pr.c 的 mac_probe 用同一批格子)\n",
         getuid(), geteuid(), getgid());
  one("/proc/kcore", O_RDONLY, 0);
  one("/proc/sla/wlan_stats", O_RDONLY, 0);
  one("/dev/ashmem", O_RDONLY, 0);
  one("/proc/1/environ", O_RDONLY, 0);
  one("/dev/kmsg", O_RDONLY, 0);
  one("/sys/kernel/tracing/tracing_on", O_RDWR, 1);
  one("/sys/kernel/tracing/buffer_size_kb", O_RDWR, 1);
  one("/sys/kernel/tracing/trace", O_RDWR, 0);   /* 不写回: 往 trace 里写东西会污染 ring */
  one("/sys/kernel/tracing/kprobe_events", O_RDWR, 1);
  one("/proc/sys/kernel/core_pattern", O_RDWR, 0);   /* 只试 open, 绝不写 */
  const char *f = "/data/local/tmp/macgate_file";
  int fd = open(f, O_CREAT | O_WRONLY | O_TRUNC, 0600);
  if (fd >= 0) { ssize_t q = write(fd, "x", 1); (void)q; close(fd); }
  errno = 0;
  int r = setxattr(f, "security.ghost_test", "1", 1, 0);
  printf("setxattr(security.ghost_test) = %d errno=%d(%s)\n", r, errno, strerror(errno));
  errno = 0;
  r = setxattr(f, "user.ghost_test", "1", 1, 0);
  printf("setxattr(user.ghost_test)     = %d errno=%d(%s)\n", r, errno, strerror(errno));
  unlink(f);
  return 0;
}
