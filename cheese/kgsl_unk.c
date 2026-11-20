/* kgsl_unk.c — 未命名/未知 ioctl 的读写字段探测(零填充 vs 图案填充) */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>
struct e { unsigned int cmd; unsigned int size; unsigned char nr; };
static struct e T[] = {
 {0xc0180920,24,0x20},{0x40080921,8,0x21},{0x40080924,8,0x24},{0xc018092f,24,0x2f},
 {0xc0200933,32,0x33},{0xc0300934,48,0x34},{0xc0080935,8,0x35},{0xc0480936,72,0x36},
 {0x40200937,32,0x37},{0xc0300957,48,0x57},{0xc0100958,16,0x58},{0x40280959,40,0x59},
 {0xc010095a,16,0x5a},{0x4010095b,16,0x5b},{0xc010095c,16,0x5c},{0x4004095d,4,0x5d},
};
static void dw(const unsigned char *b,int n){for(int i=0;i<n;i+=8){unsigned long long v;memcpy(&v,b+i,8);printf(" [%02d]0x%016llx",i,v);if(i%24==16)printf("\n           ");}printf("\n");}
int main(void){
    int fd=open("/dev/kgsl-3d0",O_RDWR); if(fd<0){printf("open fail %d\n",errno);return 1;}
    unsigned char b[128];
    printf("nr   cmd         size | zero: ret/errno        | 0xA5: ret/errno\n");
    for(unsigned i=0;i<sizeof(T)/sizeof(T[0]);i++){
        memset(b,0,sizeof(b)); errno=0; int r0=ioctl(fd,T[i].cmd,b); int e0=errno;
        unsigned char z[128]; memcpy(z,b,128);
        memset(b,0xA5,sizeof(b)); errno=0; int r1=ioctl(fd,T[i].cmd,b); int e1=errno;
        printf("0x%02x 0x%08x %4d | %3d/%-4d               | %3d/%-4d\n",T[i].nr,T[i].cmd,T[i].size,r0,e0,r1,e1);
        printf("   zero-out:"); dw(z,24);
        printf("   a5-out  :"); dw(b,24);
        fflush(stdout);
    }
    close(fd); printf("\ndone alive\n"); return 0; }
