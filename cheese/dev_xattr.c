/* dev_xattr.c — setxattr 同步分配/释放 176B (kmalloc-192) 可用性测试 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/xattr.h>

int main(void){
    const char *path = "/data/local/tmp/pwn_f";
    int fd = open(path, O_RDWR|O_CREAT, 0600);
    printf("open=%d errno=%d\n", fd, errno);
    if (fd < 0) return 1;
    close(fd);
    char buf[176]; memset(buf,'X',sizeof buf);
    int r = setxattr(path, "user.pwn", buf, 176, 0);
    printf("setxattr=%d errno=%d\n", r, errno);
    char rb[200]; memset(rb,0,sizeof rb);
    r = getxattr(path, "user.pwn", rb, 176);
    printf("getxattr=%d errno=%d val0=%c\n", r, errno, r>0?rb[0]:'?');
    return 0;
}
