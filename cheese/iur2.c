/* iur2.c — io_uring 5.4 authoritative probe (official v5.4 uapi layout) */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <sys/syscall.h>

#define IORING_OFF_SQ_RING  0ULL
#define IORING_OFF_CQ_RING  0x8000000ULL
#define IORING_OFF_SQES     0x10000000ULL
#define IORING_ENTER_GETEVENTS 1U

/* --- official v5.4 uapi structs (hand-written to avoid bionic mismatch) --- */
struct io_sqring_offsets {
    uint32_t head, tail, ring_mask, ring_entries, flags, dropped, array, resv1;
    uint64_t resv2;
};
struct io_cqring_offsets {
    uint32_t head, tail, ring_mask, ring_entries, overflow, cqes;
    uint64_t resv[2];
};
struct io_uring_params {
    uint32_t sq_entries, cq_entries, flags, sq_thread_cpu, sq_thread_idle, features;
    uint32_t resv[4];
    struct io_sqring_offsets sq_off;   /* @40 */
    struct io_cqring_offsets cq_off;   /* @80 */
};  /* total 120 bytes */
struct io_uring_sqe {
    uint8_t opcode, flags;
    uint16_t ioprio;
    int32_t fd;
    uint64_t off, addr;
    uint32_t len;
    uint32_t rw_flags;
    uint64_t user_data;
    uint16_t buf_index;
    uint8_t pad[6];
};  /* 64 bytes */
struct io_uring_cqe { uint64_t user_data; int32_t res; uint32_t flags; };

static long sys_setup(unsigned n, void *p){ return syscall(425, n, p); }
static long sys_enter(unsigned fd, unsigned to_submit, unsigned min_c,
                      unsigned flags, void *sig){
    return syscall(426, fd, to_submit, min_c, flags, sig);
}

int main(void){
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    long fd = sys_setup(4, &p);
    printf("setup fd=%ld errno=%d\n", fd, errno);
    if (fd < 0) return 1;

    printf("sq_entries=%u cq_entries=%u features=0x%x\n",
           p.sq_entries, p.cq_entries, p.features);

    /* raw dump of full 144 bytes */
    unsigned char *b = (unsigned char *)&p;
    for (int i = 0; i < 144; i++){ if (i%16==0) printf("\n[%03d]", i); printf(" %02x", b[i]); }
    printf("\n");

    /* official-layout parse */
    struct io_sqring_offsets so = p.sq_off;
    struct io_cqring_offsets co = p.cq_off;
    printf("sq_off: head=%u tail=%u mask=%u entries=%u flags=%u dropped=%u array=%u\n",
           so.head, so.tail, so.ring_mask, so.ring_entries, so.flags, so.dropped, so.array);
    printf("cq_off: head=%u tail=%u mask=%u entries=%u overflow=%u cqes=%u\n",
           co.head, co.tail, co.ring_mask, co.ring_entries, co.overflow, co.cqes);

    if (so.array == 0 || co.cqes == 0){ printf("!! official layout still invalid\n"); return 2; }

    /* mmap SQ ring / CQ ring / SQEs */
    size_t sq_sz = so.array + p.sq_entries * 4;
    size_t cq_sz = co.cqes + p.cq_entries * 16;
    size_t sqe_sz = p.sq_entries * 64;
    unsigned char *sq = mmap(NULL, sq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, IORING_OFF_SQ_RING);
    unsigned char *cq = mmap(NULL, cq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, IORING_OFF_CQ_RING);
    unsigned char *sqes = mmap(NULL, sqe_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, IORING_OFF_SQES);
    printf("mmap SQ(%zu)=%p errno=%d\n", sq_sz, sq, errno);
    printf("mmap CQ(%zu)=%p errno=%d\n", cq_sz, cq, errno);
    printf("mmap SQE(%zu)=%p errno=%d\n", sqe_sz, sqes, errno);
    if (sq==MAP_FAILED || cq==MAP_FAILED || sqes==MAP_FAILED) return 3;

    volatile uint32_t *sq_head = (uint32_t*)(sq + so.head);
    volatile uint32_t *sq_tail = (uint32_t*)(sq + so.tail);
    uint32_t sq_mask = *(uint32_t*)(sq + so.ring_mask);
    uint32_t *sq_array = (uint32_t*)(sq + so.array);
    volatile uint32_t *cq_head = (uint32_t*)(cq + co.head);
    volatile uint32_t *cq_tail = (uint32_t*)(cq + co.tail);
    uint32_t cq_mask = *(uint32_t*)(cq + co.ring_mask);
    struct io_uring_cqe *cqes = (struct io_uring_cqe*)(cq + co.cqes);
    printf("sq_mask=%u cq_mask=%u sq_tail=%u sq_head=%u cq_tail=%u cq_head=%u\n",
           sq_mask, cq_mask, *sq_tail, *sq_head, *cq_tail, *cq_head);

    /* helper: submit one sqe and wait for its cqe */
    #define SUBMIT_WAIT(ud_expect) do { \
        uint32_t t = *sq_tail; \
        sq_array[t & sq_mask] = t & sq_mask; \
        *(volatile uint32_t*)sq_tail = t + 1; \
        long r = sys_enter((unsigned)fd, 1, 1, IORING_ENTER_GETEVENTS, NULL); \
        printf("  enter(to_submit=1)=%ld errno=%d\n", r, errno); \
        uint32_t ch = *cq_head, ct = *cq_tail; \
        if (ct > ch){ \
            struct io_uring_cqe *e = &cqes[ch & cq_mask]; \
            printf("  CQE: user_data=0x%llx res=%d flags=%u (expect 0x%llx)\n", \
                   (unsigned long long)e->user_data, e->res, e->flags, (unsigned long long)(ud_expect)); \
            *(volatile uint32_t*)cq_head = ct; \
        } else printf("  no CQE (head=%u tail=%u)\n", ch, ct); \
    } while(0)

    /* ---- test 1: NOP ---- */
    printf("[test1] NOP:\n");
    struct io_uring_sqe *e = (struct io_uring_sqe*)(sqes + ((*sq_tail) & sq_mask) * 64);
    memset(e, 0, 64);
    e->opcode = 0; e->user_data = 0x1234;
    SUBMIT_WAIT(0x1234);

    /* ---- test 2: READV from /dev/zero ---- */
    printf("[test2] READV /dev/zero:\n");
    int zfd = open("/dev/zero", O_RDONLY);
    printf("  zfd=%d\n", zfd);
    static char rbuf[0x100];
    static struct iovec iov = { rbuf, sizeof(rbuf) };
    e = (struct io_uring_sqe*)(sqes + ((*sq_tail) & sq_mask) * 64);
    memset(e, 0, 64);
    e->opcode = 1 /*READV*/; e->fd = zfd; e->off = 0;
    e->addr = (uint64_t)(uintptr_t)&iov; e->len = 1; e->user_data = 0x5678;
    SUBMIT_WAIT(0x5678);
    printf("  rbuf[0..7]=%02x %02x %02x %02x %02x %02x %02x %02x (00=read executed)\n",
           rbuf[0],rbuf[1],rbuf[2],rbuf[3],rbuf[4],rbuf[5],rbuf[6],rbuf[7]);

    /* ---- test 3: READV with bad user address -> expect EFAULT in res ---- */
    printf("[test3] READV bad addr (expect res=-14 EFAULT):\n");
    static struct iovec badiov = { (void*)0x1000, 0x100 };
    e = (struct io_uring_sqe*)(sqes + ((*sq_tail) & sq_mask) * 64);
    memset(e, 0, 64);
    e->opcode = 1; e->fd = zfd; e->off = 0;
    e->addr = (uint64_t)(uintptr_t)&badiov; e->len = 1; e->user_data = 0x9abc;
    SUBMIT_WAIT(0x9abc);

    return 0;
}
