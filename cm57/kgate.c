/* kgate.c — 测"不动分区的内核级运行时修补"在这台机器上开到哪一格。
 * 链路: tracefs 建 kprobe -> bpf map/prog 加载 -> perf_event_open(动态 tracepoint id)
 *       -> PERF_EVENT_IOC_SET_BPF -> 触发 -> 回读 map。
 * 正对照: 程序里 bpf_probe_read 读 linux_banner+slide 的 64 字节, 期望回读到 "Linux version"。
 * 反向对照: 同一形状改调 helper 142 (bpf_probe_write_kernel), 用 verifier 的话定性它存不存在。
 * 用法: kgate <slide-hex> [probe-func]        (默认把探针挂在 do_sys_open)
 * ★ 退出前一定摘掉 kprobe: 挂在 do_sys_open 的 handler 会在 W 的 CPU 上跑,
 *   把覆盖层的微秒级节拍搅掉(与地雷 6 同源), 别把它留在设备上跑下一轮。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/bpf.h>
#include <linux/perf_event.h>

#define TRACE_DIR "/sys/kernel/tracing"
#define KEV       TRACE_DIR "/kprobe_events"
#define LINUX_BANNER_STATIC 0xffffffc01210f698ULL   /* analysis/kallsyms_g2a88cd145def.txt */
#define VAL_SZ 64
#define PNAME  "gtc"

static long xbd(int cmd, void *attr, size_t sz) { return syscall(SYS_bpf, cmd, attr, sz); }

static int read_file(const char *p, char *buf, int cap) {
  int fd = open(p, O_RDONLY);
  if (fd < 0) return -1;
  int n = 0, r;
  while (n < cap - 1 && (r = read(fd, buf + n, cap - 1 - n)) > 0) n += r;
  buf[n] = 0;
  close(fd);
  return n;
}
static int write_file(const char *p, const char *s) {
  int fd;
  if (s[0]) fd = open(p, O_WRONLY | O_APPEND);
  else fd = open(p, O_WRONLY | O_TRUNC);
  if (fd < 0) return -1;
  int r = s[0] ? (int)write(fd, s, strlen(s)) : 0;
  int e = errno;
  close(fd);
  errno = e;
  return r < 0 ? -1 : 0;
}
static void show(const char *step, long rc) {
  printf("[%s] rc=%ld errno=%d(%s)\n", step, rc, rc < 0 ? errno : 0,
         rc < 0 ? strerror(errno) : "OK");
}

/* 手工展开 64 位立即数(内核宏 BPF_LD_IMM64 一次吐两条指令, 在语句里不能直接用)。
 * NDK 的 <linux/bpf.h> 没有 BPF_RAW_INSN/BPF_MOV64_* 这些构造宏, 所以按稳定的字节编码自己拼: */
#define I(CODE, DST, SRC, OFF, IMM) \
  ((struct bpf_insn){ .code = (CODE), .dst_reg = (DST), .src_reg = (SRC), \
                      .off = (OFF), .imm = (IMM) })
#define OP_LD_IMM64   0x18   /* BPF_LD|BPF_DW|BPF_IMM      */
#define OP_ST_MEM_DW  0x7a   /* BPF_ST|BPF_DW|BPF_MEM(0x60) */
#define OP_MOV64_X    0xbf   /* BPF_ALU64|BPF_X|BPF_MOV    */
#define OP_MOV64_K    0xb7   /* BPF_ALU64|BPF_K|BPF_MOV    */
#define OP_ADD64_K    0x07   /* BPF_ALU64|BPF_K|BPF_ADD    */
#define OP_JEQ_K      0x15   /* BPF_JMP|BPF_JEQ|BPF_K      */
#define OP_CALL       0x85   /* BPF_JMP|BPF_CALL           */
#define OP_EXIT       0x95   /* BPF_JMP|BPF_EXIT           */
#define R0 0
#define R1 1
#define R2 2
#define R3 3
#define R10 10
#ifndef BPF_PSEUDO_MAP_FD
#define BPF_PSEUDO_MAP_FD 1
#endif
#ifndef BPF_FUNC_map_lookup_elem
#define BPF_FUNC_map_lookup_elem 1
#endif
#ifndef BPF_FUNC_probe_read
#define BPF_FUNC_probe_read 4
#endif

static void ld_imm(struct bpf_insn *p, int *i, int dst, int src, uint64_t imm) {
  p[(*i)++] = I(OP_LD_IMM64, dst, src, 0, (int32_t)imm);
  p[(*i)++] = I(0, 0, 0, 0, (int32_t)(imm >> 32));
}

/* r1=map, key=0 查 map; 查到了 bpf_probe_read(dst=map值, 64, src); r0=0 退出 */
static int build_prog(struct bpf_insn *ins, uint64_t src, int map_fd, int helper) {
  int i = 0;
  ld_imm(ins, &i, R1, BPF_PSEUDO_MAP_FD, (uint64_t)(uint32_t)map_fd);
  ins[i++] = I(OP_ST_MEM_DW, R10, 0, -16, 0);
  ins[i++] = I(OP_MOV64_X, R2, R10, 0, 0);
  ins[i++] = I(OP_ADD64_K, R2, 0, 0, -16);
  ins[i++] = I(OP_CALL, 0, 0, 0, BPF_FUNC_map_lookup_elem);
  ins[i++] = I(OP_JEQ_K, R0, 0, 7, 0);                 /* 跳距在 .off 不在 .imm: r0==0 => i14 */
  ins[i++] = I(OP_MOV64_X, R1, R0, 0, 0);
  ins[i++] = I(OP_MOV64_K, R2, 0, 0, VAL_SZ);
  ld_imm(ins, &i, R3, 0, src);
  ins[i++] = I(OP_CALL, 0, 0, 0, helper);
  ins[i++] = I(OP_MOV64_K, R0, 0, 0, 0);
  ins[i++] = I(OP_EXIT, 0, 0, 0, 0);
  ins[i++] = I(OP_MOV64_K, R0, 0, 0, 1);               /* i14 */
  ins[i++] = I(OP_EXIT, 0, 0, 0, 0);
  return i;
}

static int try_load(struct bpf_insn *ins, int cnt, int kern_version, char *logbuf, int logcap) {
  union bpf_attr a;
  memset(&a, 0, sizeof(a));
  a.prog_type = BPF_PROG_TYPE_KPROBE;
  a.insn_cnt = cnt;
  a.insns = (uint64_t)(uintptr_t)ins;
  a.license = (uint64_t)(uintptr_t) "GPL";
  a.kern_version = kern_version;
  if (logbuf) { a.log_level = 1; a.log_size = logcap; a.log_buf = (uint64_t)(uintptr_t)logbuf; }
  return (int)xbd(BPF_PROG_LOAD, &a, sizeof(a));
}

static int parse_kver(void) {
  char s[128]; unsigned M = 5, m = 4, p = 0;
  if (read_file("/proc/sys/kernel/osrelease", s, sizeof s) > 0)
    sscanf(s, "%u.%u.%u", &M, &m, &p);
  return (int)((M << 16) + (m << 8) + p);
}

int main(int argc, char **argv) {
  uint64_t slide = argc > 1 ? strtoull(argv[1], 0, 16) : 0;   /* ★base16: slide 是 13cc200000 这种, base0 会在第一个非十进制字符截断 */
  const char *fn = argc > 2 ? argv[2] : "do_sys_open";
  char logbuf[131072], cur[512], ev[96], rm[32];
  uint64_t banner = LINUX_BANNER_STATIC + slide;
  int map_fd = -1, prog_fd = -1, perf_fd = -1, i;
  int krd_ok = 0, setbpf_ok = 0, kprobe_ok = 0, pwrite_present = 0, loaded = -1, pwrite_tested = 0;
  struct bpf_insn ins[24];
  int cnt = 0;

  printf("[id] uid=%d euid=%d  slide=%llx  banner=%016llx  probe=%s\n", (int)getuid(),
         (int)geteuid(), (unsigned long long)slide, (unsigned long long)banner, fn);
  { char st[512]; if (read_file("/proc/self/status", st, sizeof st) > 0) {
      char *p = strstr(st, "CapEff:"); if (p) printf("[id] %.*s\n", 32, p); } }

  { union bpf_attr a; memset(&a, 0, sizeof a);
    a.map_type = BPF_MAP_TYPE_ARRAY; a.key_size = 4; a.value_size = VAL_SZ; a.max_entries = 1;
    map_fd = (int)xbd(BPF_MAP_CREATE, &a, sizeof a);
    show("S1 BPF_MAP_CREATE", map_fd); }

  { int have = read_file(KEV, cur, sizeof cur);
    if (have > 0 && strstr(cur, PNAME)) write_file(KEV, "-:" PNAME "\n");
    snprintf(ev, sizeof ev, "p:%s %s\n", PNAME, fn);
    int r = write_file(KEV, ev);
    show("S3 kprobe_events write", r);
    kprobe_ok = (r == 0);
    if (!kprobe_ok) { have = read_file(KEV, cur, sizeof cur);
      printf("[S3] 表里现在: '%.200s' (errno=%d)\n", have > 0 ? cur : "", errno); } }

  if (map_fd >= 0) {
    cnt = build_prog(ins, banner, map_fd, BPF_FUNC_probe_read);
    prog_fd = try_load(ins, cnt, 0, logbuf, sizeof logbuf);
    if (prog_fd < 0) {
      int kv = parse_kver();
      printf("[S2] kern_version=0 不行 => 换 0x%x 重试\n", kv);
      prog_fd = try_load(ins, cnt, kv, logbuf, sizeof logbuf);
    }
    show("S2 BPF_PROG_LOAD", prog_fd);
    if (prog_fd < 0 && logbuf[0]) printf("[S2 verifier] %.400s\n", logbuf);
    loaded = prog_fd;
    { int f2 = -1;
      if (map_fd >= 0) {
        cnt = build_prog(ins, banner, map_fd, 142 /* BPF_FUNC_probe_write_kernel */);
        f2 = try_load(ins, cnt, 0, logbuf, sizeof logbuf);
        pwrite_tested = 1;
        show("S2b helper 142 probe_write_kernel", f2);
        { int L = (int)strlen(logbuf);   /* verifier 的结论在日志尾部, 只打头看不到 */
          if (L > 0) printf("[S2b verifier tail] %s\n", L > 300 ? logbuf + L - 300 : logbuf); }
        pwrite_present = (f2 >= 0);
        if (f2 >= 0) close(f2);
      } }
  }

  int tp_id = -1;
  { char s[64]; int n = read_file(TRACE_DIR "/events/kprobes/" PNAME "/id", s, sizeof s);
    if (n > 0) tp_id = atoi(s);
    printf("[S4] events/kprobes/%s/id = %d\n", PNAME, tp_id); }

  if (tp_id >= 0 && prog_fd >= 0) {
    struct perf_event_attr pa;
    memset(&pa, 0, sizeof pa);
    /* ★ 动态 kprobe 事件走 perf 的正确写法: type=PERF_TYPE_TRACEPOINT, config=<事件 id>。
     *   上一版把 type 直接填成 tp_id => perf_event_open 报 ENOENT, 那不是门不通, 是我用错。 */
    pa.type = PERF_TYPE_TRACEPOINT; pa.config = tp_id;
    pa.size = sizeof pa; pa.sample_period = 1; pa.sample_type = PERF_SAMPLE_RAW;
    pa.wakeup_events = 1;
    perf_fd = (int)syscall(SYS_perf_event_open, &pa, 0, -1, -1, 0);
    show("S5 perf_event_open(kprobe tp)", perf_fd);
    if (perf_fd >= 0) {
      int r = ioctl(perf_fd, PERF_EVENT_IOC_SET_BPF, prog_fd);
      show("S6 PERF_EVENT_IOC_SET_BPF", r);
      setbpf_ok = (r == 0);
      if (setbpf_ok) {
        ioctl(perf_fd, PERF_EVENT_IOC_ENABLE, 0);
        for (i = 0; i < 60; i++) { int fd = open("/proc/self/cmdline", O_RDONLY); if (fd >= 0) close(fd); }
        ioctl(perf_fd, PERF_EVENT_IOC_DISABLE, 0);
        union bpf_attr a; uint32_t key = 0; unsigned char val[VAL_SZ];
        memset(&a, 0, sizeof a); memset(val, 0, sizeof val);
        a.map_fd = map_fd; a.key = (uint64_t)(uintptr_t)&key;
        a.value = (uint64_t)(uintptr_t)val;
        int lr = (int)xbd(BPF_MAP_LOOKUP_ELEM, &a, sizeof a);
        show("S8 BPF_MAP_LOOKUP_ELEM", lr);
        printf("[S8] map[0] = ");
        for (i = 0; i < 24; i++) printf("%02x", val[i]);
        printf("\n[S8] 当字符串 = [%.24s]\n", (char *)val);
        krd_ok = (lr == 0 && !memcmp(val, "Linux version", 13));
      }
    }
  }

  /* ★ 顺序很重要: perf fd / prog fd 必须**先**关, 否则 kprobe 事件仍被引用,
   *   `-:gtc` 会报 EBUSY(2026-09-29 实测) ⇒ 探针留在 do_sys_open 上,
   *   它的 handler 会在下一轮的微秒级窗口里跑 ⇒ 把覆盖层节拍搅掉。 */
  if (perf_fd >= 0) { close(perf_fd); perf_fd = -1; }
  if (prog_fd >= 0) { close(prog_fd); prog_fd = -1; }

  if (kprobe_ok) {
    snprintf(rm, sizeof rm, "-:%s\n", PNAME);
    int r = write_file(KEV, rm);
    show("清理 kprobe", r);
    if (r < 0) { r = write_file(KEV, ""); printf("[清理] 改用整表清空 rc=%d\n", r); }
    { int n = read_file(KEV, cur, sizeof cur);
      printf("[清理] kprobe_events 现在 = '%.120s'\n", n > 0 ? cur : ""); }
  }
  if (perf_fd >= 0) close(perf_fd);
  if (prog_fd >= 0) close(prog_fd);
  if (map_fd >= 0) close(map_fd);

  printf("[KGATE] KPROBE_CREATE=%s BPF_MAP=%s BPF_PROG_LOAD=%s SET_BPF=%s "
         "BPF_KERNEL_READ=%s PROBE_WRITE_KERNEL=%s\n",
         kprobe_ok ? "PASS" : "FAIL", map_fd >= 0 ? "PASS" : "FAIL",
         loaded >= 0 ? "PASS" : "FAIL", setbpf_ok ? "PASS" : "FAIL",
         krd_ok ? "PASS" : "FAIL", pwrite_tested ? (pwrite_present ? "PRESENT" : "ABSENT") : "NOTTESTED");
  { int fd = open("/data/local/tmp/kgate.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) { char line[256];
      snprintf(line, sizeof line,
               "[KGATE] uid=%d KPROBE=%s MAP=%s PROG=%s SETBPF=%s KREAD=%s PWRITE=%s\n",
               (int)getuid(), kprobe_ok ? "PASS" : "FAIL", map_fd >= 0 ? "PASS" : "FAIL",
               loaded >= 0 ? "PASS" : "FAIL", setbpf_ok ? "PASS" : "FAIL",
               krd_ok ? "PASS" : "FAIL", pwrite_tested ? (pwrite_present ? "PRESENT" : "ABSENT") : "NOTTESTED");
      if (write(fd, line, strlen(line)) > 0) fsync(fd);
      close(fd); } }
  return krd_ok ? 0 : 2;
}
