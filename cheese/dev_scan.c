/* dev_scan.c — 描述符二分扫描: 哪种组合能让 hid-multitouch 在真机绑定?
 * 用法: ./dev_scan <mode>
 *  mode 0: wptp only
 *  mode 1: wptp + pad118
 *  mode 2: wptp + rep3(248)
 *  mode 3: wptp + pad118 + rep3(248)   (= dev_oob3)
 *  mode 4: wptp + pad118 + rep3(4095)  (= cred_zero5 style)
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <linux/filter.h>

#define EVSZ 4380
static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

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

static void build_desc(int mode) {
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    unsigned char rep3[16];
    int rep3_len;
    unsigned char rep3_248[8] = { 0x85,0x03, 0x75,0x08, 0x95,0xF8, 0xB1,0x03 };
    unsigned char rep3_4095[16] = { 0x85,0x03, 0x75,0x08,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03 }; /* 简化: 765B */
    (void)rep3_4095;
    unsigned char rep3_big[20] = { 0x85,0x03, 0x75,0x08, 0x95,0xFF, 0xB1,0x03,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03 }; /* 1020B */
    int pos=0, i=0, insA=-1;
    while(i<(int)sizeof(wptp)-5){
        if(wptp[i]==0x09&&wptp[i+1]==0x59&&wptp[i+2]==0x25&&wptp[i+3]==0x02
           &&wptp[i+4]==0xB1&&wptp[i+5]==0x02){insA=i+6;break;}
        i++;
    }
    memcpy(desc+pos,wptp,insA); pos+=insA;
    if (mode==1||mode==3||mode==4) { memcpy(desc+pos,pad118,6); pos+=6; }
    if (mode==2) { memcpy(desc+pos,rep3_248,8); pos+=8; }
    if (mode==3) { memcpy(desc+pos,rep3_248,8); pos+=8; }
    if (mode==4) { memcpy(desc+pos,rep3_big,20); pos+=20; }
    memcpy(desc+pos,wptp+insA,sizeof(wptp)-insA); pos+=sizeof(wptp)-insA;
    desc_len = pos;
}

static int create_legacy(int fd){
    memset(ev,0,EVSZ);
    wr32(0,0);
    strncpy((char*)(ev+4), "scan", 127);
    strncpy((char*)(ev+132), "virt-0", 63);
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev+260,&p,8);
    wr16(268,(uint16_t)desc_len);
    wr16(270,0x0003);
    wr32(272,0x1234); wr32(276,0x5678); wr32(280,1);
    ssize_t w = write(fd,ev,EVSZ);
    return w>0 ? 0 : -1;
}

/* 找 newest 0003:1234:5678.* 并打印 driver */
static void check_bind(void) {
    DIR *d = opendir("/sys/bus/hid/devices");
    if (!d) { printf("  /sys/bus/hid EACCES\n"); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "0003:1234:5678", 14) == 0) {
            char path[512], link[512];
            snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/driver", e->d_name);
            ssize_t n = readlink(path, link, sizeof(link)-1);
            if (n > 0) { link[n] = 0; printf("  %s -> %s\n", e->d_name, link); }
            else printf("  %s -> (no driver)\n", e->d_name);
        }
    }
    closedir(d);
}

int main(int argc, char **argv) {
    int mode = argc > 1 ? atoi(argv[1]) : 3;
    setvbuf(stdout, NULL, _IONBF, 0);
    build_desc(mode);
    printf("mode=%d desc_len=%u\n", mode, desc_len);

    int ufd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (ufd < 0) { printf("open: %s\n", strerror(errno)); return 1; }
    if (create_legacy(ufd) < 0) { printf("create failed\n"); return 1; }
    printf("CREATE ok, waiting events (6s)...\n");

    int answered = 0;
    for (int t = 0; t < 300; t++) {
        struct timeval tv = {0, 20000};
        fd_set rf; FD_ZERO(&rf); FD_SET(ufd, &rf);
        if (select(ufd+1, &rf, NULL, NULL, &tv) <= 0) continue;
        ssize_t rr = read(ufd, ev, EVSZ);
        if (rr <= 0) continue;
        uint32_t type = rd32(0);
        printf("  event type=%u\n", type);
        if (type == 9 || type == 13) {
            uint8_t rnum = ev[8];
            printf("    rnum=%u\n", rnum);
            /* 应答, rnum=2 时 oob */
            int oob = (rnum == 2);
            memset(ev,0,EVSZ);
            wr32(0, type == 9 ? 10 : 14);
            wr32(4, rd32(4));
            wr16(8, 0);
            wr16(10, oob ? 128 : 1);
            ev[12] = oob ? 3 : 0;
            write(ufd, ev, EVSZ);
            answered++;
        }
    }
    printf("answered=%d\n", answered);
    check_bind();
    sleep(3);
    memset(ev,0,EVSZ); wr32(0,1);
    write(ufd, ev, EVSZ);
    printf("destroyed\n");
    return 0;
}
