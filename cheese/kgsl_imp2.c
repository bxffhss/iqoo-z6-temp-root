/* kgsl_imp2.c — GPUOBJ_IMPORT 修正测试: priv 必须是指向值的指针
 * 结构: {u64 priv_ptr@0; u64 priv_len@8; u64 flags@16; u64 type@24}
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
    int kfd=open("/dev/kgsl-3d0",O_RDWR); if(kfd<0){printf("open %d\n",errno);return 1;}
    int fnull=open("/dev/null",O_RDWR);
    int fzero=open("/dev/zero",O_RDWR);
    printf("kgsl=%d null=%d zero=%d\n\n", kfd, fnull, fzero);
    unsigned int fdv; unsigned long long v64;
    struct { unsigned long long priv, priv_len, flags, type; } p;
    struct { int fd; unsigned ty; unsigned len; } cases[] = {
        {0, 3, 4}, {0, 2, 8}, {0, 2, 4}, {0, 3, 8}, {0, 1, 4},
    };
    int fds[3] = {fnull, fzero, kfd};
    for (int i = 0; i < 3; i++) {
        for (unsigned c = 0; c < sizeof(cases)/sizeof(cases[0]); c++) {
            fdv = (unsigned)fds[i]; v64 = (unsigned long long)fds[i];
            memset(&p,0,sizeof(p));
            p.priv     = (cases[c].len==4) ? (unsigned long long)(uintptr_t)&fdv
                                           : (unsigned long long)(uintptr_t)&v64;
            p.priv_len = cases[c].len;
            p.type     = cases[c].ty;
            errno=0;
            int r = ioctl(kfd, CMD_IMPORT, &p);
            printf("fd=%d(%s) type=%u len=%u -> ret=%d errno=%d %s\n",
                   fds[i], i==0?"null":(i==1?"zero":"kgsl"), cases[c].ty, cases[c].len, r, errno,
                   errno==524?"(ENOTSUPP)":(errno==22?"(EINVAL)":(errno==14?"(EFAULT)":(errno==9?"(EBADF)":""))));
        }
    }
    close(kfd); printf("\ndone alive\n"); return 0; }
