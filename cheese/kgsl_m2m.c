/* kgsl_m2m.c — 实测 CP_MEM_TO_MEM 拷贝长度语义(cntl 字段) */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <string.h>
#include "adrenaline.h"

static int fd; static uint64_t g_clsz;
static uint32_t *ib; static uint64_t ib_ga;
static uint8_t *buf; static uint64_t buf_ga; static uint32_t ctx;
static void cvac(void *a, void *b){ char*s=(char*)((uintptr_t)a&~(g_clsz-1));
  for(;s<(char*)b;s+=g_clsz) __asm volatile("dc cvac, %0"::"r"(s):"memory"); __asm volatile("dsb ish":::"memory"); }
static void civac(void *a, void *b){ char*s=(char*)((uintptr_t)a&~(g_clsz-1));
  for(;s<(char*)b;s+=g_clsz) __asm volatile("dc civac, %0"::"r"(s):"memory"); __asm volatile("dsb ish":::"memory"); }
static int submit(uint64_t ga, uint32_t size, uint32_t *ts){
    struct kgsl_command_object c; struct kgsl_gpu_command r;
    memset(&c,0,sizeof(c)); c.flags=KGSL_CMDLIST_IB; c.gpuaddr=ga; c.size=size;
    memset(&r,0,sizeof(r)); r.context_id=ctx; r.cmdsize=sizeof(c); r.numcmds=1; r.cmdlist=(unsigned long)&c;
    int e=ioctl(fd,IOCTL_KGSL_GPU_COMMAND,&r); if(ts)*ts=r.timestamp; return e; }
static void wait_ts(uint32_t ts){ struct{uint32_t c,t,to;}w={ctx,ts,3000}; ioctl(fd,_IOWR(0x09,0x07,char[12]),&w); }
static int mapb(void **h,size_t len,uint64_t *ga){
    void*p=mmap(NULL,len,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(p==MAP_FAILED) return 1; memset(p,0,len);
    struct kgsl_map_user_mem m; memset(&m,0,sizeof(m));
    m.len=len; m.hostptr=(unsigned long)p; m.memtype=KGSL_USER_MEM_TYPE_ADDR;
    if(ioctl(fd,IOCTL_KGSL_MAP_USER_MEM,&m)) return 1;
    *h=p; *ga=m.gpuaddr; return 0; }

int main(void){
    setvbuf(stdout,NULL,_IONBF,0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0":"=r"(ctr)); g_clsz=4<<((ctr>>16)&0xf);
    fd=open("/dev/kgsl-3d0",O_RDWR|O_CLOEXEC); if(fd<0) return 1;
    mapb((void**)&ib,0x1000,&ib_ga); mapb((void**)&buf,0x20000,&buf_ga);
    struct kgsl_drawctxt_create cr={.flags=0x1812}; ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE,&cr); ctx=cr.drawctxt_id;
    printf("# ib_ga=0x%llx buf_ga=0x%llx\n",(unsigned long long)ib_ga,(unsigned long long)buf_ga);

    /* src = buf+0x10000, 填 1024 个 pattern */
    uint32_t *src=(uint32_t*)(buf+0x10000);
    for(int i=0;i<1024;i++) src[i]=0xDEAD0000u+i;
    cvac(buf+0x10000, buf+0x10000+4096);

    /* dst 区 = buf+0x8000, 每次先清零 */
    uint32_t *dst=(uint32_t*)(buf+0x8000);
    /* 变体: (count, extra dword) 组合测 size 字段 */
    struct { uint32_t cnt; uint32_t cntl; uint32_t extra; } variants[] = {
        {5,0,0},{6,0,256},{6,0,4},{7,0,256},{7,0x100,256},
        {5,0x01000000u,0},{5,0x00010000u,0},{5,256,0},{5,4,0},{5,0x20000000u,0},{5,0x40000000u,0}
    };
    uint32_t ts=0;
    for(unsigned k=0;k<sizeof(variants)/sizeof(variants[0]);k++){
        memset(dst,0,0x4000); cvac(buf+0x8000,buf+0x8000+0x4000);
        uint32_t *c=ib;
        *c++=cp_type7_packet(CP_MEM_TO_MEM,variants[k].cnt);
        *c++=variants[k].cntl;
        *c++=lower_32_bits(buf_ga+0x8000); *c++=upper_32_bits(buf_ga+0x8000);
        *c++=lower_32_bits(buf_ga+0x10000); *c++=upper_32_bits(buf_ga+0x10000);
        for(uint32_t e=variants[k].cnt; e>5; e--) *c++=variants[k].extra;
        uint32_t dw=(uint32_t)(c-ib); cvac(ib,(char*)ib+dw*4);
        if(submit(ib_ga,dw*4,&ts)){ printf("cnt=%u cntl=0x%08x extra=%u submit FAIL\n",variants[k].cnt,variants[k].cntl,variants[k].extra); continue; }
        wait_ts(ts);
        civac(buf+0x8000,buf+0x8000+0x4000);
        unsigned n=0; while(n<1024 && dst[n]==(0xDEAD0000u+n)) n++;
        printf("cnt=%u cntl=0x%08x extra=%u -> copied %u dwords (dst[0]=0x%08x)\n",
               variants[k].cnt,variants[k].cntl,variants[k].extra,n,dst[0]);
    }
    printf("done\n"); return 0; }
