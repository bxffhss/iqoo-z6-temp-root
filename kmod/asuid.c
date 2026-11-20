/* asuid <uid> <cmd> [args...]  —— 以 root 运行，setuid(<uid>) 后 exec 指定命令。
 * 用于从 @sushd(root) 以某个具体 uid 的上下文执行（测 su、测 ksuctl88 setprof 的 manager 门）。 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <grp.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: asuid <uid> <cmd> [args..]\n"); return 2; }
    uid_t u = (uid_t)strtol(argv[1], NULL, 10);
    setgroups(0, NULL);
    setgid(u);
    if (setuid(u) != 0) { fprintf(stderr, "asuid: setuid(%d) failed\n", (int)u); }
    execv(argv[2], &argv[2]);
    perror("asuid: exec");
    return 127;
}
