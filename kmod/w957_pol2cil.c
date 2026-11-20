/* w957_pol2cil.c — 把**二进制策略**（设备 live 导出 / odm 盘上的 precompiled_sepolicy）反编译成 CIL。
 * ★入口点是现场验过的，不是猜的（§6.456 那两条仪器教训）：
 *   实测魔数＝0xf97cff8c ＝ libsepol 的 **module 制式 policydb**（Android 的 precompiled_sepolicy 就是这种，
 *   §6.453 事实一）。`sepol_module_package_read()` 走不通——它要的是**外面包一层 module package** 的件，
 *   报错原文 `wrong magic number for module package: expected 0xf97cff8f, got 0xf97cff8c` 就是这个不匹配。
 *   ⇒ 正确形状＝`policydb_init` + `policydb_read`(PF_USE_MEMORY) + `sepol_kernel_policydb_to_cil`（kernel_to_cil.h:5）。
 * 为什么需要它（#216）：#213 判负＝"拿 .cil 重编 base"会少 502 个三元组（拆掉厂商的闸）。
 *   剩下唯一"只加不减"的形状＝**以厂商二进制件为底**：binary → CIL →(+delta.cil)→ secilc → patch，
 *   再用 `kmod/w953b_rule_diff_probe.py` 按 (源,目标,类) 三元组双向差**自证**：
 *   `厂商有、我们没有` 必须 = 0，`只在我们` 必须恰好等于我加的条数。装前不过这条线就不装。
 * 用法: w957_pol2cil <in.pol>          → CIL 打到 stdout
 *       w957_pol2cil <in.pol> --info   → 只报读到的制式与规模（先看兼容性）
 * 编译（远端 Debian12）: gcc -O2 -Wall w957_pol2cil.c -o w957 /usr/lib/x86_64-linux-gnu/libsepol.a
 */
#include <sepol/policydb.h>
#include <sepol/policydb/policydb.h>
#include <sepol/kernel_to_cil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAGIC_BASE 0xf97cff8fu
#define MAGIC_MOD  0xf97cff8cu

static char *slurp(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror("打开输入件"); return NULL; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); fprintf(stderr, "seek 失败(不是普通文件?)\n"); return NULL; }
    long n = ftell(f);
    if (n <= 0) { fclose(f); fprintf(stderr, "件长度 0/不可测 ⇒ 不读\n"); return NULL; }
    rewind(f);
    char *buf = malloc((size_t)n);
    if (!buf) { fclose(f); fprintf(stderr, "内存不足(%ld B)\n", n); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { fprintf(stderr, "只读到 %zu/%ld B ⇒ 件不完整，不用\n", got, n); free(buf); return NULL; }
    *out_len = (size_t)n;
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: %s <二进制策略> [--info]\n", argv[0]); return 2; }
    size_t len = 0;
    char *buf = slurp(argv[1], &len);
    if (!buf) return 2;
    unsigned int magic = 0;
    memcpy(&magic, buf, 4);
    fprintf(stderr, "W0 输入=%s 字节=%zu 魔数=0x%08x(%s)\n", argv[1], len, magic,
            magic == MAGIC_MOD ? "module 制式 policydb" : magic == MAGIC_BASE ? "base 制式 policydb" : "未知制式");
    if (magic != MAGIC_MOD && magic != MAGIC_BASE) {
        fprintf(stderr, "W0 ★魔数不是这两种 ⇒ 不出件（不猜）\n");
        return 3;
    }

    policydb_t db;
    policy_file_t pf;
    memset(&db, 0, sizeof(db));
    memset(&pf, 0, sizeof(pf));
    if (policydb_init(&db) < 0) { fprintf(stderr, "policydb_init 失败\n"); return 3; }
    pf.type = PF_USE_MEMORY;
    pf.data = buf;
    pf.len = 0;
    pf.size = len;
    int rc = policydb_read(&db, &pf, 0);
    if (rc < 0) {
        fprintf(stderr, "policydb_read 失败 rc=%d ⇒ 不出件（libsepol 3.4 与件的 modver 不兼容？§6.453：modver 8）\n", rc);
        policydb_destroy(&db);
        return 4;
    }
    /* ★打印的字段名是**从 policydb.h 现场核对过的**：这版结构里只有 `policyvers/mls/handle_unknown/target_platform`
       与 `p_types/p_classes/p_roles/p_users`（**没有** `mod_policy`、**没有** `p_syms`——我上一版两个都凭印象写，gcc 直接报错）。 */
    fprintf(stderr, "W1 读到：policyvers=%u mls=%d handle_unknown=%u target_platform=%d types=%u classes=%u roles=%u users=%u\n",
            db.policyvers, db.mls, db.handle_unknown, db.target_platform,
            db.p_types.nprim, db.p_classes.nprim, db.p_roles.nprim, db.p_users.nprim);
    if (argc >= 3 && strcmp(argv[2], "--info") == 0) { policydb_destroy(&db); return 0; }

    rc = sepol_kernel_policydb_to_cil(stdout, &db);
    if (rc < 0) { fprintf(stderr, "sepol_kernel_policydb_to_cil 失败 rc=%d ⇒ 不出件\n", rc); policydb_destroy(&db); return 5; }
    policydb_destroy(&db);
    return 0;
}
