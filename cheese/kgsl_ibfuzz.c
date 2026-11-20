/* kgsl_ibfuzz.c — 暴力确定 0x10(ISSUEIBCMDS) 的真实结构体布局
 * 变量: ioctl size(决定 ioctl 号) / issueib 字段布局 / ibdesc 布局
 * 判据: submit=0 且 canary 正常且 GPU 存活 = 该组合被内核正确接受
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
static int canary(void) {
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = (uint32_t)((buf_ga+0x800)&0xFFFFFFFFu); *c++ = (uint32_t)((buf_ga+0x800)>>32);
    *c++ = 0xCAFEBABEu;
    uint32_t dw=(uint32_t)(c-ib); cvac(ib,(char*)ib+dw*4);
    *(uint32_t*)((char*)buf+0x800)=0; cvac((char*)buf+0x800,(char*)buf+0x804);
    uint32_t ts=0; int r=submit_4a(ib_ga,dw*4,&ts);
    if(!r){ wait_ts(ts,3000); civac((char*)buf+0x800,(char*)buf+0x804); }
    return *(uint32_t*)((char*)buf+0x800)==0xCAFEBABEu ? 1 : 0;
}
#define REQ(size) _IOWR(0x09, 0x10, size)

int main(void){
    setvbuf(stdout,NULL,_IONBF,0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0":"=r"(ctr)); g_clsz=4<<((ctr>>16)&0xf);
    fd=open("/dev/kgsl-3d0",O_RDWR|O_CLOEXEC); if(fd<0){printf("open fail\n");return 1;}
    mapb((void**)&buf,0x1000,&buf_ga); mapb((void**)&ib,0x1000,&ib_ga);
    struct kgsl_drawctxt_create cr={.flags=0x1812}; ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE,&cr); ctx=cr.drawctxt_id;
    printf("# buf_ga=0x%llx ctx=0x%x\n",(unsigned long long)buf_ga,ctx);
    {
        typedef struct { uint32_t drawctxt_id, pad; uint64_t ibdesc_addr; uint32_t numibs, timestamp, flags, pad2; } issueib_t;
        printf("# REQ(32)=0x%08lx  _IOWR(0x09,0x10,issueib_t)=0x%08lx  sizeof=%zu\n",
               (unsigned long)REQ(32), (unsigned long)_IOWR(0x09,0x10,issueib_t), sizeof(issueib_t));
        /* 用与 kgsl_lvl0 完全相同的写法再打一次 */
        issueib_t is; unsigned char d[64]; memset(d,0,sizeof(d)); memset(&is,0,sizeof(is));
        *(uint64_t*)(d+0)=buf_ga; *(uint32_t*)(d+16)=64;
        is.drawctxt_id=ctx; is.ibdesc_addr=(uint64_t)(uintptr_t)d; is.numibs=1;
        int r=ioctl(fd,_IOWR(0x09,0x10,issueib_t),&is);
        printf("# lvl0-写法复现: ret=%d errno=%d ts=%u\n", r, r?errno:0, is.timestamp);
    }
    /* buf: NOP 雪橇 */
    for(int i=0;i<32;i++){ buf[i*2]=cp_type7_packet(CP_NOP,1); buf[i*2+1]=0; }
    cvac(buf,(char*)buf+0x100);

    /* ibdesc 三种布局(放在栈上) */
    struct { int kind; int sz; } ibdesc_kinds[] = {
        {0,24},  /* {u64 gpuaddr; u64 hostptr; u32 sizedwords; u32 ctrl} */
        {1,12},  /* {u32 gpuaddr; u32 sizedwords; u32 ctrl} */
        {2,16},  /* {u64 gpuaddr; u32 sizedwords; u32 ctrl} */
    };
    unsigned int sizes[] = {8u,12u,16u,20u,24u,28u,32u,36u,40u,44u,48u,52u,56u,60u,64u,72u,80u,96u};

    for (unsigned k=0;k<1;k++) {
      for (unsigned s=0;s<sizeof(sizes)/sizeof(sizes[0]);s++) {
        unsigned char p[64]; memset(p,0,sizeof(p));
        unsigned char d[64]; memset(d,0,sizeof(d));
        uint64_t daddr;
        if (ibdesc_kinds[k].kind==0) {
            *(uint64_t*)(d+0)=buf_ga; *(uint64_t*)(d+8)=0;
            *(uint32_t*)(d+16)=64; *(uint32_t*)(d+20)=0;
        } else if (ibdesc_kinds[k].kind==1) {
            *(uint32_t*)(d+0)=(uint32_t)buf_ga; *(uint32_t*)(d+4)=64; *(uint32_t*)(d+8)=0;
        } else {
            *(uint64_t*)(d+0)=buf_ga; *(uint32_t*)(d+8)=64; *(uint32_t*)(d+12)=0;
        }
        daddr=(uint64_t)(uintptr_t)d;
        /* 布局A: {u32 ctx; u32 pad; u64 ibdesc_addr; u32 numibs; u32 ts; u32 flags; u32 pad2} (cheese,32B) */
        *(uint32_t*)(p+0)=ctx; *(uint32_t*)(p+4)=0;
        *(uint64_t*)(p+8)=daddr;
        *(uint32_t*)(p+16)=1; *(uint32_t*)(p+20)=0; *(uint32_t*)(p+24)=0; *(uint32_t*)(p+28)=0;
        int r=ioctl(fd, REQ(sizes[s]), p);
        int e=errno;
        uint32_t ts=*(uint32_t*)(p+20);
        int alive = 1;
        if (r==0) { wait_ts(ts,2000); alive=canary(); }
        printf("ibdesc=%d size=%2u -> ret=%d errno=%2d ts=%u alive=%d %s\n",
               ibdesc_kinds[k].kind, sizes[s], r, r?e:0, ts, alive,
               (r==0&&alive)?"<<< 被接受且无故障":"");
        fflush(stdout);
      }
    }
    printf("done\n"); return 0; }
