/* suwbind.c —— 窗口内模块 runner 的挂载底座：直接调 mount(2)/umount2(2)。
 *
 * 为什么要自己写：本机 toybox 0.8.9-android 的 `mount` **没有 bind 支持**
 *   (usage 只有 `[-afFrsvw] [-t TYPE] [-o OPTION,] [[DEVICE] DIR]`，任何 `-o bind`/`--bind`
 *    都退化成 "mount: bad /etc/fstab"、rc=1) ⇒ 用命令行挂会在窗口里静默失败。
 *   这一发只有 3~5 分钟，所以必须离线就把这条路钉死。(2026-10-01 preflight_module.sh 实测)
 *
 * ★判据口径：失败一定要看 **errno**，不看 rc 也不看输出；成功一定要**独立复读**
 *   (/proc/self/mountinfo 里有没有那条 + 目标内容是否真的变了)。
 *
 * 用法:
 *   suwbind <src> <dst>              MS_BIND 挂载(默认；ro bind 用 --ro)
 *   suwbind --ro <src> <dst>         bind 后再以只读语义挂(second bind + remount)
 *   suwbind --umount <dst>           umount2(dst, MNT_DETACH)
 *   suwbind --check <dst>            只查 /proc/self/mountinfo 里有没有这个挂载点
 * 编译: $NDKCL -O2 -static -o suwbind cm57/suwbind.c
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>

static int has(const char *path, const char *needle)
{
    char buf[4096];
    int fd = open(path, O_RDONLY);
    int found = 0;
    ssize_t n;
    char *p;

    if (fd < 0) {
        printf("  (打不开 %s errno=%d(%s))\n", path, errno, strerror(errno));
        return -1;
    }
    while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
        buf[n] = 0;
        p = strstr(buf, needle);
        if (p) { found = 1; break; }
    }
    close(fd);
    return found;
}

int main(int argc, char **argv)
{
    const char *mode = "bind";
    int rc, e;
    unsigned long flags;

    if (argc < 2) {
        fprintf(stderr, "用法: suwbind [--ro|--umount|--check] <src> <dst>|<dst>\n");
        return 2;
    }
    if (argv[1][0] == '-' && argv[1][1] == '-') {
        mode = argv[1] + 2;
        argv++;
        argc--;
    }

    if (!strcmp(mode, "umount")) {
        if (argc < 2) { fprintf(stderr, "--umount 需要目标\n"); return 2; }
        rc = umount2(argv[1], MNT_DETACH);
        e = errno;
        printf("umount2(%s, MNT_DETACH) rc=%d errno=%d(%s)\n", argv[1], rc, e, strerror(e));
        printf("  复读 mountinfo: %d 条还指着它\n", has("/proc/self/mountinfo", argv[1]));
        return rc ? 1 : 0;
    }
    if (!strcmp(mode, "check")) {
        if (argc < 2) { fprintf(stderr, "--check 需要目标\n"); return 2; }
        rc = has("/proc/self/mountinfo", argv[1]);
        printf("check %s mountinfo 命中=%d (1=挂着, 0=没挂, -1=读不到)\n", argv[1], rc);
        return rc == 1 ? 0 : 1;
    }
    if (argc < 3) { fprintf(stderr, "%s 需要 src 与 dst\n", mode); return 2; }

    {   /* 先把参数形状自证一遍：路径必须存在，否则窗口里撞到的是 ENOENT 而不是 EPERM */
        struct stat st;
        if (stat(argv[1], &st)) {
            printf("src %s stat 失败 errno=%d(%s)\n", argv[1], errno, strerror(errno));
            return 3;
        }
        if (stat(argv[2], &st)) {
            printf("dst %s stat 失败 errno=%d(%s) ⇒ bind 要求目标已存在\n",
                   argv[2], errno, strerror(errno));
            return 3;
        }
        printf("src=%s(dst=%s 是 %s)\n", argv[1], argv[2],
               S_ISDIR(st.st_mode) ? "目录" : "文件");
    }

    flags = MS_BIND | MS_REC;
    rc = mount(argv[1], argv[2], NULL, flags, NULL);
    e = errno;
    printf("mount(MS_BIND|MS_REC) rc=%d errno=%d(%s)\n", rc, e, strerror(e));
    if (rc == 0) {
        printf("  复读 mountinfo 命中=%d\n", has("/proc/self/mountinfo", argv[2]));
        if (!strcmp(mode, "ro")) {
            /* bind 之后再降级只读(MS_REMOUNT 必须带 MS_BIND 才不会重挂文件系统) */
            rc = mount(argv[1], argv[2], NULL, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_REC, NULL);
            e = errno;
            printf("  remount-ro rc=%d errno=%d(%s)\n", rc, e, strerror(e));
        }
    }
    return rc ? 1 : 0;
}
