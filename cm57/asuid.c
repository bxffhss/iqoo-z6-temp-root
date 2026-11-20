/* asuid.c — 以指定 uid/gid 起一条命令(给白名单做判定用的"客户端替身")。
 * 为什么需要它: 白名单是按 **调用方的 uid** 判的, 而在 root 窗口里我们只有自己(uid0);
 * 拿真 app 做判定要么依赖 app 自己调 su、要么依赖 `am start`(root 会话里 am 报
 * "Can't find service: activity" ⇒ 得起两段)。用一个 setuid 掉分uid 的进程直接调 su,
 * 判据最短、可重复、且能精确模拟"某个 app 的 uid"。
 * 用法: asuid <uid> <gid> <命令...>
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "用法: asuid <uid> <gid> <cmd> [args...]\n"); return 2; }
  uid_t u = (uid_t)strtoul(argv[1], 0, 10);
  gid_t g = (gid_t)strtoul(argv[2], 0, 10);
  if (setgroups(0, 0) != 0) fprintf(stderr, "[asuid] setgroups: %s\n", strerror(errno));
  if (setgid(g) != 0) { fprintf(stderr, "[asuid] setgid %d: %s\n", g, strerror(errno)); return 1; }
  if (setuid(u) != 0) { fprintf(stderr, "[asuid] setuid %d: %s\n", u, strerror(errno)); return 1; }
  if (getuid() != u) { fprintf(stderr, "[asuid] 降权没生效: getuid=%d\n", (int)getuid()); return 1; }
  execvp(argv[3], argv + 3);
  fprintf(stderr, "[asuid] exec %s: %s\n", argv[3], strerror(errno));
  return 127;
}
