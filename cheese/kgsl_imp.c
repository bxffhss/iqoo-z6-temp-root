/* kgsl_imp.c — GPUOBJ_IMPORT(0x48,32B) 可达性验证
 * 结构(推断): {u64 priv@0; u64 priv_len@8; u64 flags@16; u64 type@24}
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>
#define CMD_IMPORT 0xc0200948u
int main(void){
    int fd=open("/dev/kgsl-3d0",O_RDWR); if(fd<0){printf("open dev %d\n",errno);return 1;}
    int f=open("/dev/null",O_RDWR);
    printf("kgsl fd=%d, /dev/null fd=%d\n\n", fd, f);
    struct { unsigned long long priv, priv_len, flags, type; } p;
    unsigned char small[16]; memset(small,0,sizeof(small));
    struct { unsigned long long a, b; } t2;

    for (int ty = 0; ty < 6; ty++) {
        memset(&p,0,sizeof(p));
        p.priv = (ty==3) ? (unsigned long long)f : (unsigned long long)(uintptr_t)&t2;
        p.priv_len = (ty==3) ? 4 : 8;
        p.type = ty;
        errno=0;
        int r = ioctl(fd, CMD_IMPORT, &p);
        printf("type=%d priv=0x%llx len=%llu -> ret=%d errno=%d %s\n",
               ty, p.priv, p.priv_len, r, errno,
               errno==25?"(未实现)":(errno==22?"(EINVAL/校验拒绝)":""));
    }
    /* 再用 uid 2000 能拿到的 dma-buf: /dev/kgsl 自身对象 fd? 试 /dev/ashmem */
    int ash=open("/dev/ashmem",O_RDWR);
    printf("\n/dev/ashmem fd=%d\n", ash);
    if(ash>=0){
        memset(&p,0,sizeof(p));
        p.priv=ash; p.priv_len=4; p.type=3;
        errno=0; int r=ioctl(fd,CMD_IMPORT,&p);
        printf("type=3 priv=ashmem -> ret=%d errno=%d\n", r, errno);
    }
    close(fd); printf("done alive\n"); return 0; }
