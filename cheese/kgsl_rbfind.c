/* kgsl_rbfind.c — 确认 CP_RB_BASE
 * A: 读 0x200-0x21f, 提交前后对比 → 识别 WPTR/RPTR(是否随提交推进)
 * B: 候选 RB 基址(ptr<<2 / 0x400000 等)读 32 dwords → 看是否为 PM4 包流
 * C: 补扫 0x500-0x57f, 0x900-0x97f 可读寄存器
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
#include "adrenaline.h"

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

/* 读 n 个寄存器 → out[base_dw + i] */
static void read_regs(uint16_t *regs, int n, uint32_t base_dw) {
    uint32_t *c = ib;
    for (int i = 0; i < n; i++) {
        *c++ = cp_type7_packet(0x3e, 3);
        *c++ = regs[i];
        *c++ = lower_32_bits(out_ga + 4*(base_dw + (uint32_t)i));
        *c++ = upper_32_bits(out_ga + 4*(base_dw + (uint32_t)i));
    }
    uint32_t dw = (uint32_t)(c - ib);
    cvac(ib, (char*)ib + dw*4);
    uint32_t ts = 0;
    if (submit(ib_ga, dw*4, &ts)) { printf("reg read submit FAIL\n"); return; }
    wait_ts(ts);
    civac(out + base_dw, out + base_dw + n);
}

/* 从 GPU VA 读 n 个连续 dword → out[base_dw + i] (一包一 dword) */
static void read_mem(uint64_t va, int n, uint32_t base_dw) {
    uint32_t *c = ib;
    for (int i = 0; i < n; i++) {
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 4*(base_dw + (uint32_t)i)); *c++ = upper_32_bits(out_ga + 4*(base_dw + (uint32_t)i));
        *c++ = lower_32_bits(va + 4*(uint64_t)i);                  *c++ = upper_32_bits(va + 4*(uint64_t)i);
    }
    uint32_t dw = (uint32_t)(c - ib);
    cvac(ib, (char*)ib + dw*4);
    uint32_t ts = 0;
    if (submit(ib_ga, dw*4, &ts)) { printf("mem read submit FAIL va=0x%llx\n", (unsigned long long)va); return; }
    wait_ts(ts);
    civac(out + base_dw, out + base_dw + n);
}
static void submit_dummy(int dwords) {
    uint32_t *c = ib;
    for (int i = 0; i < dwords/2; i++) { *c++ = cp_type7_packet(CP_NOP, 1); *c++ = 0; }
    uint32_t dw = (uint32_t)(c - ib);
    cvac(ib, (char*)ib + dw*4);
    uint32_t ts = 0;
    if (submit(ib_ga, dw*4, &ts)) { printf("dummy submit FAIL\n"); return; }
    wait_ts(ts);
}
/* PM4 包流似然: type7 头(bit29:31=7) 且 count 合理 */
static int pm4_score(uint32_t *w, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) { uint32_t v = w[i];
        uint32_t type = (v >> 29) & 0x7; uint32_t cnt = (v >> 16) & 0x3FFF;
        if (type == 7 && cnt > 0 && cnt < 4096) s++;
        if (type == 0 || type == 4) s++; }
    return s;
}

int main(void){
    setvbuf(stdout,NULL,_IONBF,0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0":"=r"(ctr)); g_clsz=4<<((ctr>>16)&0xf);
    fd=open("/dev/kgsl-3d0",O_RDWR|O_CLOEXEC); if(fd<0){printf("open fail\n");return 1;}
    mapb((void**)&ib,0x1000,&ib_ga); mapb((void**)&out,0x10000,&out_ga);
    struct kgsl_drawctxt_create cr={.flags=0x1812}; ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE,&cr); ctx=cr.drawctxt_id;
    printf("# ib_ga=0x%llx out_ga=0x%llx ctx=0x%x\n",(unsigned long long)ib_ga,(unsigned long long)out_ga,ctx);

    /* ---- A: 0x200-0x21f 提交前后 ---- */
    uint16_t regs[32]; for(int i=0;i<32;i++) regs[i]=0x200+i;
    uint32_t snap[32];
    read_regs(regs,32,0x100); memcpy(snap,out+0x100,32*4);
    printf("== A1 初始 0x200-0x21f ==\n");
    for(int i=0;i<32;i++) if(snap[i] && snap[i]!=0xdeafbead) printf("  0x%03x = 0x%08x\n",0x200+i,snap[i]);

    submit_dummy(8); submit_dummy(8);
    read_regs(regs,32,0x100);
    printf("== A2 两次 dummy(各 8 dwords) 后 delta ==\n");
    for(int i=0;i<32;i++) if(snap[i]!=0xdeafbead){
        uint32_t now=out[0x100+i];
        if(now!=snap[i]) printf("  0x%03x: 0x%08x -> 0x%08x  (delta %d)\n",0x200+i,snap[i],now,(int)(now-snap[i]));
    }
    read_regs(regs,32,0x100);
    printf("== A3 再读一次(稳定?) ==\n");
    for(int i=0;i<32;i++) if(snap[i]!=0xdeafbead && out[0x100+i]!=snap[i])
        printf("  0x%03x: 0x%08x -> 0x%08x\n",0x200+i,snap[i],out[0x100+i]);

    /* ---- B: 候选 RB 基址内存 dump ---- */
    uint64_t cands[] = { 0x400000ULL, 0x0ULL, 0x100000ULL, 0x1000000ULL, 0xfff00000ULL,
                         0x4000000000ULL, 0x8000000000ULL };
    printf("\n== B 候选区域 dump(前 32 dwords / score) ==\n");
    for (unsigned k = 0; k < sizeof(cands)/sizeof(cands[0]); k++) {
        memset(out+0x200,0,32*4); cvac(out+0x200,out+0x200+32*4);
        read_mem(cands[k], 32, 0x200);
        printf("  VA 0x%llx score=%d :", (unsigned long long)cands[k], pm4_score(out+0x200,32));
        for (int i = 0; i < 12; i++) printf(" %08x", out[0x200+i]);
        printf("\n");
    }

    /* ---- C: 补扫 0x500-0x57f, 0x900-0x97f ---- */
    printf("\n== C 补扫(仅打印非 deafbead 非零) ==\n");
    for (uint32_t base = 0x500; base <= 0x900; base += 0x400) {
        for (int b = 0; b < 128; b += 32) {
            uint16_t r32[32]; for(int i=0;i<32;i++) r32[i]=(uint16_t)(base+b+i);
            read_regs(r32,32,0x300);
            for(int i=0;i<32;i++){ uint32_t v=out[0x300+i];
                if(v && v!=0xdeafbead) printf("  REG 0x%03x = 0x%08x\n", base+b+i, v); }
        }
    }
    printf("done alive\n"); return 0; }
