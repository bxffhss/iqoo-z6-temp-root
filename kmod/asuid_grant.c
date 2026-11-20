#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <grp.h>

/* KSU_IOCTL_GRANT_ROOT = _IOC(_IOC_NONE,'K',1,0) => 0x4B01 */
#define KSU_IOCTL_GRANT_ROOT 0x4B01

/* asuid_grant <uid>  —— 以 root 运行，先 setuid(<uid>) 再走 /dev/ksud 的 GRANT_ROOT。
 * 用途：验证"名单内的 uid 经 /dev/ksud ioctl 能拿到 uid=0"（rc77 社区 su 闭环最后一格）。
 * 若 <uid> 已在 .allowlist（如 suw 10342 granted=1）⇒ GRANT_ROOT 应 rc=0，fork 出的 id 应 uid=0。
 */
int main(int argc, char **argv) {
    if (argc > 1) {
        uid_t u = (uid_t)strtol(argv[1], NULL, 10);
        setgroups(0, NULL);
        setgid(u);
        if (setuid(u) != 0)
            printf("SETUID_FAIL uid=%d errno=%d(%s)\n", (int)u, errno, strerror(errno));
    }
    printf("uid=%d euid=%d\n", (int)getuid(), (int)geteuid());
    fflush(stdout);

    int fd = open("/dev/ksud", O_RDWR);
    if (fd < 0) fd = open("/dev/ksud", O_RDONLY);
    if (fd < 0) {
        printf("OPEN_FAIL errno=%d (%s)\n", errno, strerror(errno));
        return 2;
    }
    printf("open /dev/ksud ok fd=%d\n", fd);

    int r = ioctl(fd, KSU_IOCTL_GRANT_ROOT);
    printf("GRANT_ROOT rc=%d errno=%d(%s) after_uid=%d euid=%d\n", r, errno, strerror(errno), (int)getuid(), (int)geteuid());
    fflush(stdout);

    pid_t pid = fork();
    if (pid == 0) {
        execl("/system/bin/id", "id", (char *)NULL);
        execl("/bin/id", "id", (char *)NULL);
        _exit(127);
    } else if (pid > 0) {
        int st; waitpid(pid, &st, 0);
    }
    return 0;
}
