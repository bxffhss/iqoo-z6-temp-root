/* ==== ① 本机存在但未导出的符号：运行时解析（v3）====
 * ★两版失败的教训(md §6.11/§6.12)：
 *   v1 手抄原型 ⇒ 4 个 `conflicting types`(本树 change_pid 三参且 task 在前、kallsyms_lookup 五参含
 *      char **modname、ns_get_path 返回 void*、mntns_operations 要 const)。
 *   v2 用 `__typeof__` + **函数式宏** ⇒ 宏把*声明*也改写：
 *      `extern int ksys_unshare(unsigned long unshare_flags);` 被展开成"定义"，
 *      报 `redefinition of 'p_ksys_unshare' with a different type: 'int' vs 'int (*)(unsigned long)'`。
 *   ⇒ 定论：**函数不能用宏别名**(声明点会被改写)。改成"在 kernel/infra/dev_syms.c 里定义**同名转发函数**"，
 *     内核头里那句 extern 声明自然绑到我们的定义 ⇒ 产物里不再有这些未定义引用。
 *     只有**数据对象**用对象式宏 `(*p)`：那种展开在声明处正好得到我们需要的指针声明，
 *     且使用侧 `&x` 拿到真地址、`x.field` 拿到解引用。
 */
#include <linux/user.h>
#include <linux/pid.h>
#include <linux/kallsyms.h>
#include <linux/task_work.h>
#include <linux/proc_ns.h>
#include <linux/ns_common.h>
#include <linux/sched.h>
#include <linux/mm_types.h>
#include <linux/fs.h>

/* --- 数据对象：类型由内核头导出(__typeof__)，抄不错 --- */
extern __typeof__(init_task) *ksu_p_init_task;
#define init_task     (*ksu_p_init_task)
extern __typeof__(init_mm) *ksu_p_init_mm;
#define init_mm       (*ksu_p_init_mm)
extern __typeof__(tasklist_lock) *ksu_p_tasklist_lock;
#define tasklist_lock (*ksu_p_tasklist_lock)
extern __typeof__(mntns_operations) *ksu_p_mntns_operations;
#define mntns_operations (*ksu_p_mntns_operations)

/* selinux_blob_sizes 只在 selinux 私有头 objsec.h:151 声明(模块可见路径外) ⇒ 显式写；
 * `selinux_state` **不能**做别名：它和结构体 tag 同名(`struct selinux_state`)，预处理会连 tag 一起
 * 替换 ⇒ security.h 全崩。它仅有的 3 处使用改在 selinux/selinux.c 里显式写 ksu_p_selinux_state->…。*/
struct lsm_blob_sizes;
extern struct lsm_blob_sizes *ksu_p_selinux_blob_sizes;
#define selinux_blob_sizes (*ksu_p_selinux_blob_sizes)
struct selinux_state;
extern struct selinux_state *ksu_p_selinux_state;

int ksu_dev_syms_init(void);   /* 必须在任何使用之前调用(core/init.c 里注入) */

#endif /* _KSU_COMPAT54_H */
