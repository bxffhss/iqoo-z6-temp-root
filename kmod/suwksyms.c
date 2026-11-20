/* suwksyms.c — 阶段 3 探针：证明"手搓模块也能调用**未导出**的内核函数"
 *
 * 链路(前两级已在真机通过，见 kmod/PLAN.md §7)：
 *   register_kprobe(symbol_name="kallsyms_lookup_name") → 读 addr@40 → unregister
 *   ⇒ 拿到 kallsyms_lookup_name 的运行时地址(它**没被导出**，链接期引用不到)
 *   ⇒ 用它在运行时解析其它未导出符号，并**直接从我们模块里调用**
 *      (kCFI 只卡"内核间接调用我们"那个方向；我们模块是 NDK clang 编的、自身没有 kCFI 插桩，
 *       所以我们发起的调用不受检查 —— 这条已在 PLAN.md §6b 论证)
 *
 * 判据(离线核对，别只看"非零")：
 *   观测地址 - 本 boot slide == analysis/embedded-kallsyms.txt 里同名符号的链接期地址
 *   多个符号必须给出**同一个** slide 差值，否则说明偏移或调用有问题。
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
MODINFO("description", "suw stage3 unexported-symbol call probe");
MODINFO("name", "suwksyms");
MODINFO("depends", "");
MODINFO("srcversion", "SUWSTAGE3000000000000AA");

__asm__(".pushsection .plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .init.plt,\"ax\"\n\t.byte 0\n\t.popsection\n");
__asm__(".pushsection .text.ftrace_trampoline,\"ax\"\n\t.byte 0\n\t.popsection\n");

/* 只链接**导出**的四个符号；kallsyms_lookup_name 是运行时解析出来的 */
VERSYM(module_layout, 0xb7b3a75c);
VERSYM(printk, 0xc5850110);
VERSYM(register_kprobe, 0x3ce77caf);
VERSYM(unregister_kprobe, 0xeb3f8466);

extern int printk(const char *fmt, ...);
extern long register_kprobe(void *kp);
extern void unregister_kprobe(void *kp);

static unsigned long long KP[17];        /* sizeof(struct kprobe)=136 (实测) */
#define OFF_ADDR        40               /* 实测 */
#define OFF_SYMBOL_NAME 48               /* 实测 */

typedef unsigned long (*kln_fn)(const char *name);

static void kp_zero(void) { int i; for (i = 0; i < 17; i++) KP[i] = 0; }

static long kprobe_resolve(const char *name, unsigned long long *out) {
  long rc;
  kp_zero();
  KP[OFF_SYMBOL_NAME / 8] = (unsigned long long)name;
  rc = register_kprobe(KP);
  *out = (rc == 0) ? KP[OFF_ADDR / 8] : 0;
  if (rc == 0) unregister_kprobe(KP);
  return rc;
}

/* 这些是"KSU 式能力"真正要用的东西，全部**没有导出** ⇒ 只能走这条链 */
static const char *WANT[] = {
  "commit_creds", "prepare_kernel_cred", "override_creds", "put_cred",
  "sys_call_table", "register_ftrace_function", "text_poke_bp",
  "set_memory_rw", "flush_icache_range", "module_enable_ro",
};

__attribute__((section(".init.text"), noinline))
int init_module(void) {
  unsigned long long kl = 0;
  kln_fn kln;
  int i;
  long rc;

  rc = kprobe_resolve("kallsyms_lookup_name", &kl);
  printk("suwksyms: kprobe(kallsyms_lookup_name) rc=%ld addr=0x%016llx\n", rc, kl);
  if (rc != 0 || !kl) { printk("suwksyms: 拿不到 kallsyms_lookup_name，停\n"); return 0; }

  kln = (kln_fn)kl;                      /* ★直接调用未导出函数 */
  for (i = 0; i < (int)(sizeof(WANT) / sizeof(WANT[0])); i++) {
    unsigned long a = kln(WANT[i]);
    printk("suwksyms: kallsyms_lookup_name(%s) = 0x%016lx\n", WANT[i], a);
  }
  /* 自校验：同一个函数解析自己，应与 kprobe 给的值完全一致（两个独立通道互校） */
  printk("suwksyms: 自校验 kallsyms_lookup_name = 0x%016lx (kprobe 给的是 0x%016llx)\n",
         (unsigned long)kln("kallsyms_lookup_name"), kl);
  return 0;
}

__attribute__((section(".exit.text"), noinline))
void cleanup_module(void) { printk("suwksyms: exit\n"); }

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
  .name = "suwksyms",
  .init = init_module,
  .exit = cleanup_module,
};
