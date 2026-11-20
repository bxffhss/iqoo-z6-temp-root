/* ksu_su —— 最小"标准契约" su：open("/dev/ksud") + ioctl(KSU_IOCTL_GRANT_ROOT) 提权到 root，再 exec 目标命令。
 * 契约：su                 -> /system/bin/sh
 *       su -c CMD          -> sh -c CMD
 *       su 0 CMD [args..]  -> exec CMD args   (libsu 常用形式)
 *       su CMD [args..]    -> exec CMD args
 * 与 libsu 的约定：无 root 时向 stderr 打印一行错误并 exit 非 0（libsu 据此判"无 root"）。
 */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>

#define KSU_IOCTL_GRANT_ROOT 0x4B01

int main(int argc, char **argv) {
    int fd = open("/dev/ksud", O_RDWR);
    if (fd < 0) fd = open("/dev/ksud", O_RDONLY);
    if (fd < 0) { fprintf(stderr, "su: cannot open /dev/ksud: %s\n", strerror(errno)); return 1; }
    if (ioctl(fd, KSU_IOCTL_GRANT_ROOT) != 0) {
        fprintf(stderr, "su: permission denied (not in allowlist): %s\n", strerror(errno));
        return 1;
    }
    close(fd);

    /* 此刻已是 root（GRANT_ROOT 改了 cred）。下面按契约 exec 目标。 */
    if (argc < 2) { execl("/system/bin/sh", "sh", (char *)NULL); }
    else if (strcmp(argv[1], "-c") == 0 && argc >= 3) {
        execl("/system/bin/sh", "sh", "-c", argv[2], (char *)NULL);
    } else if (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0) {
        execl("/system/bin/sh", "sh", "-c", "echo ksu_su 1.0 (/dev/ksud)", (char *)NULL);
    } else if (strcmp(argv[1], "0") == 0 && argc >= 3) {
        execvp(argv[2], &argv[2]);   /* libsu 的 `su 0 sh -c …`：sh 是裸名，须走 PATH */
    } else {
        execvp(argv[1], &argv[1]);
    }
    perror("su: exec");
    return 127;
}
