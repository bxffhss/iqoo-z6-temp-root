/* w975_pol2cil2.c — 接着 #216 的"读不动"往下挖一层：上一版 `w957` 用内部 `policydb_read` 返回 rc=−1 **且不吐任何错误**。
 * 排除掉两个假设后只剩一个没试：①魔数对（实测 `0xf97cff8c`＝`SELINUX_MODULE_MAGIC`）；②版本在范围内
 * （实测件里 modver=8，而本机 libsepol 的 `MOD_POLICYDB_VERSION_MAX=21`）。
 * ⇒ 本版的唯一改动＝**把 handle 装上**（`sepol_handle_create()` ＋ `db.handle`/`pf.handle`）：
 *   libsepol 的 ERR()/dbg 全走 handle，没有 handle 时既有可能是**提前 bail**，也是"为什么一句话都没打印"的原因。
 * 读通之后立刻 `sepol_kernel_policydb_to_cil` 出 CIL ⇒ 就能跑 #216 要的**空 delta 往返**：
 *   binary→CIL→secilc→binary，再用 `w953b` 按 (源,目标,类) 三元组与原件双向差 ⇒ 必须 0/0。
 * 用法: w975_pol2cil2 <in.pol> [--info|--cil]
 */
#include <sepol/policydb.h>
#include <sepol/policydb/policydb.h>
#include <sepol/context.h>
#include <sepol/kernel_to_cil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: %s <in.pol> [--info|--cil]\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("打开输入件"); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *buf = malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "读不全\n"); return 2; }
    fclose(f);

    sepol_handle_t *h = sepol_handle_create();          // ★这一版的关键
    if (!h) { fprintf(stderr, "handle_create 失败\n"); return 3; }
    // 不调 sepol_handle_set_msg()：3.4 的 `sepol_handle_create` 默认已把消息打到 stderr，
    // 而我没核过它的第三个参数形状（本机 `grep extern.*sepol_handle_set_msg` 也没命中）⇒ 少写一行没把握的调用。

    policydb_t db;
    policy_file_t pf;
    memset(&db, 0, sizeof db);
    memset(&pf, 0, sizeof pf);
    if (policydb_init(&db) < 0) { fprintf(stderr, "policydb_init 失败\n"); return 3; }
    pf.handle = h;            // ★只挂在这儿：实测 3.4 的 `policydb_t` **没有 `handle` 成员**（上一版写 db.handle=h 直接编译不过），
                              //   而 libsepol 的错误全走 `fp->handle` ⇒ 我上一版把 pf memset 成 NULL＝**失败必定静默**，这就是"不吐一个字"的成因。
    pf.type = PF_USE_MEMORY;
    pf.data = buf;
    pf.len = 0;
    pf.size = (size_t)n;

    unsigned magic = 0, modver = 0;
    memcpy(&magic, buf, 4); memcpy(&modver, buf + 4, 4);
    fprintf(stderr, "W0 输入=%zu B magic=0x%08x modver=%u handle=%p\n", (size_t)n, magic, modver, (void *)h);
    int rc = policydb_read(&db, &pf, 1);
    fprintf(stderr, "W1 policydb_read rc=%d  (装了 handle 之后)\n", rc);
    if (rc < 0) {
        fprintf(stderr, "W2 仍读不通 ⇒ 入口假设不止一个错；#216 的地基要另找路（AOSP 那份 libsepol）\n");
        policydb_destroy(&db);
        sepol_handle_destroy(&h);
        return 4;
    }
    fprintf(stderr, "W2 读通：policyvers=%u mls=%d handle_unknown=%u target_platform=%d types=%u classes=%u roles=%u users=%u\n",
            db.policyvers, db.mls, db.handle_unknown, db.target_platform,
            db.p_types.nprim, db.p_classes.nprim, db.p_roles.nprim, db.p_users.nprim);
    if (argc >= 3 && strcmp(argv[2], "--info") == 0) { policydb_destroy(&db); sepol_handle_destroy(&h); return 0; }
    rc = sepol_kernel_policydb_to_cil(stdout, &db);
    fprintf(stderr, "W3 sepol_kernel_policydb_to_cil rc=%d\n", rc);
    policydb_destroy(&db);
    sepol_handle_destroy(&h);
    return rc < 0 ? 5 : 0;
}
