/* suwhook.c — 路线 A 的第一块基石：**证明手搓模块的 kprobe handler 真的会被内核调用**。
 *
 * 为什么这一步非做不可：阶段 1 只证明了 `register_kprobe` 能成功 + 能解析符号地址，
 * 而那次注册**根本没挂 handler**(厂商那个 .ko 也是只取地址) ⇒ "内核会回调我们写的函数"
 * 这件事到现在为止还没有任何一手证据。route A 的整套"按 app 放行"都建立在它上面。
 *
 * 偏移来源（全部实测/交叉验证，不抄上游）：
 *   sizeof(struct kprobe)=136、addr@40、symbol_name@48 —— 设备实测(vfcs-misc-core.ko 的反汇编)
 *   与树算出(mainline 5.4.281 的 offsetof) **三值一致** ⇒ 该结构体厂商没动 ⇒
 *   于是可以采用树算出的其余字段：opcode@56 **pre_handler@64** **post_handler@72** fault@80 kp@88。
 *   独立佐证：厂商那个 .ko 在注册前显式清零 [sp,#0x40]（=64），正是"我不挂 pre_handler"的写法。
 *
 * 本模块**只打印、不改任何返回值、不写任何内核内存** ⇒ 就算偏移猜错，最坏情况也只是
 * "被当成 handler 用错误参数调用"，而函数体只做一次 printk，不解引用任何参数 ⇒ 安全。
 * 判据：从用户态 `mkdir` 触发被探函数，dmesg 里应出现 pre/post 各一行。
 */

#define VERMAGIC "5.4.281-qgki-g2a88cd145def SMP preempt mod_unload modversions aarch64"

#define MODINFO(tag, val) \
  __asm__(".pushsection .modinfo,\"a\"\n\t" \
          ".asciz \"" tag "=" val "\"\n\t" \
          ".popsection\n")

#define VERSYM(nm, crc) \
  __asm__(".pushsection __versions,\"a\"\n\t" \
          ".balign 8\n\t" \
          ".quad " #crc "\n\t" \
          "1:\n\t" \
          ".asciz \"" #nm "\"\n\t" \
          ".zero 56 - (. - 1b)\n\t" \
          ".popsection\n")

MODINFO("vermagic", VERMAGIC);
MODINFO("license", "GPL");
MODINFO("description", "suw route-A kprobe handler proof");
MODINFO("name", "suwhook");
MODINFO("depends", "");
MODINFO("srcversion", "SUWWHOOK0000000000000AA");

__asm__(".pushsection .plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .init.plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .text.ftrace_trampoline,\"ax\"\n\t.byte 0\n\t.popsection\n");

VERSYM(module_layout, 0xb7b3a75c);
VERSYM(printk, 0xc5850110);
VERSYM(register_kprobe, 0x3ce77caf);
VERSYM(unregister_kprobe, 0xeb3f8466);

extern int printk(const char *fmt, ...);
extern long register_kprobe(void *kp);
extern void unregister_kprobe(void *kp);

static unsigned long long KP[17];              /* sizeof(struct kprobe)=136 */
#define KP_ADDR       40
#define KP_SYMBOL     48
#define KP_PRE        64
#define KP_POST       72

/* arm64 的 pt_regs 是 ABI 帧，布局固定：x0..x30, sp, pc, pstate */
struct suw_pt_regs {
  unsigned long long regs[31];
  unsigned long long sp;
  unsigned long long pc;
  unsigned long long pstate;
};

static const char TARGET[] = "__arm64_sys_mkdirat";   /* 冷、可从用户态 mkdir 精确触发 */
static volatile long nhit;

static long pre_cb(void *p, struct suw_pt_regs *regs) {
  nhit++;
  printk("suwhook: pre 命中 #%ld pc=0x%llx (不解引用任何参数, 只证明被调到)\n",
         nhit, regs ? regs->pc : 0ULL);
  return 0;                       /* 0 = 不吞掉原调用 */
}

static void post_cb(void *p, struct suw_pt_regs *regs, unsigned long long flags) {
  printk("suwhook: post 命中 pc=0x%llx\n", regs ? regs->pc : 0ULL);
}

__attribute__((section(".init.text"), noinline))
int init_module(void) {
  long rc;
  KP[KP_SYMBOL / 8] = (unsigned long long)TARGET;
  KP[KP_PRE / 8]    = (unsigned long long)pre_cb;
  KP[KP_POST / 8]   = (unsigned long long)post_cb;
  rc = register_kprobe(KP);
  printk("suwhook: register_kprobe(%s) rc=%ld  ⇒ 去 mkdir 一个目录触发它\n", TARGET, rc);
  if (rc != 0) { KP[KP_PRE / 8] = 0; KP[KP_POST / 8] = 0; return 0; }
  return 0;                       /* 故意不失败：留着让测试脚本触发后再 rmmod */
}

__attribute__((section(".exit.text"), noinline))
void cleanup_module(void) {
  printk("suwhook: 共命中 %ld 次, unregister\n", nhit);
  unregister_kprobe(KP);
}

void __cfi_check(unsigned long long id, void *ptr, void *diag) {
  (void)id; (void)ptr; (void)diag;
}

struct suw_this_module {
  char pad0[24];
  char name[56];
  char pad1[392 - 80];
  int (*init)(void);
  char pad2[888 - 400];
  void (*exit)(void);
  char pad3[960 - 896];
};

__attribute__((section(".gnu.linkonce.this_module"), aligned(64)))
struct suw_this_module __this_module = {
  .name = "suwhook",
  .init = init_module,
  .exit = cleanup_module,
};
