/* suwkprobe.c — 阶段 1+2 探针：模块能不能挂 kprobe，并借它把 kallsyms_lookup_name 的地址捞出来
 *
 * 形状是**照抄本机厂商模块**的，不是照抄上游：
 *   cm57/ko_all/vfcs-misc-core.ko 的 vfcs_reserved_block_init 里
 *     memset(sp, 0, 0x88)                    ⇒ sizeof(struct kprobe) = 136
 *     str  xzr, [sp, #0x40]
 *     stp  xzr, x8, [sp, #0x28]              x8 = &"kallsyms_lookup_name" ⇒ 字符串在偏移 48
 *     bl   register_kprobe
 *   也就是说 vivo 自己就是在用一个"非导出符号只能靠 kprobe 捞地址"的路子 ——
 *   这正是 KSU 非 GKI 分支的做法，所以这条通了才有后面。
 *
 * 安全性(为什么这一发不会把机器打崩)：
 *   - 布局对不对，**返回值自己会说话**：偏移错 ⇒ symbol_name 读到 0 ⇒ register_kprobe 直接
 *     -ENOENT 返回，什么都没注册，也就不需要 unregister；
 *   - 只有 rc==0(确实注册上了)才调 unregister_kprobe —— 而注册成功后 hlist/list 那些字段是
 *     **内核自己写进我们这块缓冲的**，它按同一套偏移读回去，天然一致。
 *   - 全程不写内核内存、不改任何全局状态。
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
MODINFO("description", "suw stage1/2 kprobe probe");
MODINFO("name", "suwkprobe");
MODINFO("depends", "");
MODINFO("srcversion", "SUWSTAGE10000000000000AA");

__asm__(".pushsection .plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .init.plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .text.ftrace_trampoline,\"ax\"\n\t.byte 0\n\t.popsection\n");

VERSYM(module_layout, 0xb7b3a75c);
VERSYM(printk, 0xc5850110);
VERSYM(register_kprobe, 0x3ce77caf);
VERSYM(unregister_kprobe, 0xeb3f8466);

extern int printk(const char *fmt, ...);
extern long register_kprobe(void *kp);      /* 只按"指针"用，不碰结构体定义 */
extern void unregister_kprobe(void *kp);

/* 136 字节 = sizeof(struct kprobe)，放 .bss 天然全零(= memset 那一步) */
static unsigned long long KP[17];
static const char T1[] = "kallsyms_lookup_name";
static const char T2[] = "module_kallsyms_lookup_name";

/* 厂商把字符串放在偏移 48、解析到的地址在偏移 40(都是实测) */
#define OFF_ADDR        40
#define OFF_SYMBOL_NAME 48

static void kp_zero(void) {
  int i;
  for (i = 0; i < 17; i++) KP[i] = 0;
}

/* 返回内核的 rc；*addr 只在 rc==0 时有意义 */
static long resolve(const char *name, unsigned long long *addr) {
  long rc;
  kp_zero();
  KP[OFF_SYMBOL_NAME / 8] = (unsigned long long)name;
  rc = register_kprobe(KP);
  *addr = (rc == 0) ? KP[OFF_ADDR / 8] : 0;
  if (rc == 0) unregister_kprobe(KP);
  return rc;
}

__attribute__((section(".init.text"), noinline))
int init_module(void) {
  unsigned long long a1 = 0, a2 = 0;
  long r1, r2;

  /* ★两个符号各解析一次：单点观测不算数，要能互相咬合
   *   (离线判据：观测值 - 本 boot slide == analysis/embedded-kallsyms.txt 里的链接期地址；
   *    第一发已实测 kallsyms_lookup_name 差值正好等于 slide 0x25b7000000) */
  r1 = resolve(T1, &a1);
  r2 = resolve(T2, &a2);
  printk("suwkprobe: %s rc=%ld addr=0x%016llx\n", T1, r1, a1);
  printk("suwkprobe: %s rc=%ld addr=0x%016llx\n", T2, r2, a2);
  /* 期望差值 = 0x103fbae0 - 0x103f5698 = **0x6448**（2026-09-30 真机实测就是这个值；
   * 这一行原先写的 0xa448 是我口算错的，别再拿它当"判据不通过"的依据） */
  printk("suwkprobe: 两地址差=0x%llx (离线应等于 0x103fbae0-0x103f5698=0x6448)\n",
         (a1 > a2) ? (a1 - a2) : (a2 - a1));
  return 0;
}

__attribute__((section(".exit.text"), noinline))
void cleanup_module(void) {
  printk("suwkprobe: exit\n");
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
  .name = "suwkprobe",
  .init = init_module,
  .exit = cleanup_module,
};
