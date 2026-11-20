/* kgsl_setinfo.c — 反推 GPUOBJ_SET_INFO(0x4c,32B) 结构
 * 推测: {u64 id@0; u64 flags@8; u32 type@16; u32 metadata_len@20; u64 metadata@24}
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
#define CMD_ALLOC 0xc0300945u
#define CMD_SET   0xc020094cu
static int fd; static unsigned char meta[256];
int main(void){
    fd=open("/dev/kgsl-3d0",O_RDWR); if(fd<0){printf("open fail %d\n",errno);return 1;}
    memset(meta,0x22,sizeof(meta));
    unsigned char a[64]; memset(a,0,sizeof(a));
    unsigned long long sz=0x1000, fl=0, vl=0x1000;
    memcpy(a+0,&sz,8); memcpy(a+8,&fl,8); memcpy(a+16,&vl,8);
    if(ioctl(fd,CMD_ALLOC,a)){printf("alloc fail %d\n",errno);return 1;}
    unsigned id; memcpy(&id,a+32,4);
    printf("对象 id=%u\n\n",id);
    printf("== 扫 type(flags=0, metadata=0) ==\n");
    for(int ty=0; ty<8; ty++){
        unsigned char b[64]; memset(b,0,sizeof(b));
        unsigned long long t=id; memcpy(b+0,&t,8);
        unsigned int tyv=ty, ml=0; memcpy(b+16,&tyv,4); memcpy(b+20,&ml,4);
        errno=0; int r=ioctl(fd,CMD_SET,b);
        printf("  type=%d ret=%d errno=%d\n", ty, r, errno);
    }
    printf("\n== 扫 flags(以 type=1) ==\n");
    for(int fi=0; fi<6; fi++){
        unsigned long long fs[]={0,1,2,4,8,0x10};
        unsigned char b[64]; memset(b,0,sizeof(b));
        unsigned long long t=id; memcpy(b+0,&t,8);
        memcpy(b+8,&fs[fi],8);
        unsigned int tyv=1, ml=0; memcpy(b+16,&tyv,4); memcpy(b+20,&ml,4);
        errno=0; int r=ioctl(fd,CMD_SET,b);
        printf("  flags=0x%llx type=1 ret=%d errno=%d\n", fs[fi], r, errno);
    }
    printf("\n== 带 metadata 指针(len=16, type=1, flags=0) ==\n");
    for(int fi=0; fi<4; fi++){
        unsigned char b[64]; memset(b,0,sizeof(b));
        unsigned long long t=id; memcpy(b+0,&t,8);
        unsigned int tyv=1, ml=16; memcpy(b+16,&tyv,4); memcpy(b+20,&ml,4);
        unsigned long long mp=(unsigned long long)(uintptr_t)meta; memcpy(b+24,&mp,8);
        errno=0; int r=ioctl(fd,CMD_SET,b);
        printf("  ret=%d errno=%d\n", r, errno);
        break;
    }
    close(fd); printf("\ndone alive\n"); return 0; }
