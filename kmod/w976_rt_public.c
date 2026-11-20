/* w976_rt_public.c — #216 地基的**判决试验**：只用 libsepol **公开** API 把厂商二进制策略读进来、再原样写回去，比字节。
 * 前两版的错在哪（都是我没核 API 就动手，同族＝例 187③）：
 *   `w957`：内部 `policydb_read` ＋没声明制式 ⇒ rc=−1；
 *   `w975`：补了 handle 仍 rc=−1（顺带暴露 `sepol_handle_destroy` 的参数不是 `**`，那是 abort 的原因，与结论无关）。
 *   ⇒ 差别在 setools 走的是公开包装，而且**读之前先 `sepol_policydb_set_typevers(..., SEPOL_POLICY_KERN)`**——
 *     内核制式与模块制式的头/表布局不同，不声明就没法解。这一版就是补这一步。
 * 写：`sepol_policy_file_set_mem(pf, 我自己给的缓冲, 容量)` → `sepol_policydb_write` → `sepol_policy_file_get_len`
 *     （公开 API 没有 get_mem，所以容量我自己给，够用就行）。
 * 判读三条，缺一说"未测"：A 读通？ B 写出来与原件**逐字节相同**？ C 不同就报差异位置，**不许读成"没事"**。
 */
#include <sepol/policydb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: %s <in.pol> <out.pol>\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *buf = malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "读不全\n"); return 2; }
    fclose(f);
    unsigned magic = 0, w1 = 0;
    memcpy(&magic, buf, 4); memcpy(&w1, buf + 4, 4);
    printf("P0 输入 %zu B magic=0x%08x 第二字=%u\n", (size_t)n, magic, w1);

    sepol_policy_file_t *pf = NULL;
    sepol_policydb_t *db = NULL;
    if (sepol_policy_file_create(&pf) < 0) { fprintf(stderr, "P1 file_create 失败\n"); return 3; }
    if (sepol_policydb_create(&db) < 0) { fprintf(stderr, "P1 db_create 失败\n"); return 3; }
    int rc = sepol_policydb_set_typevers(db, SEPOL_POLICY_KERN);      // ★关键的一步（前两版都漏了）
    printf("P1 set_typevers(KERN) rc=%d\n", rc);
    sepol_policy_file_set_mem(pf, buf, (size_t)n);
    rc = sepol_policydb_read(db, pf);
    printf("P2 sepol_policydb_read rc=%d\n", rc);
    if (rc < 0) { fprintf(stderr, "P2 仍读不通 ⇒ 本机这份 libsepol 认不了这版制式；#216 要另找 libsepol 来源\n"); return 4; }

    size_t cap = (size_t)n * 2 + 4096;
    char *out = malloc(cap);
    memset(out, 0, cap);
    /* 写出两条都试（第一条在我这儿返回 0 字节，说明内存输出得让 libsepol 自己分配；
       公开 API 本来就有 `sepol_policy_file_set_fp` ⇒ 直接写文件流最省事，也最不容易被我用法带偏） */
    sepol_policy_file_t *pf2 = NULL;
    if (sepol_policy_file_create(&pf2) < 0) { fprintf(stderr, "P3 pf2 失败\n"); return 3; }
    FILE *wf = fopen(argv[2], "wb");
    if (!wf) { perror("打开输出"); return 3; }
    sepol_policy_file_set_fp(pf2, wf);
    rc = sepol_policydb_write(db, pf2);
    fflush(wf);
    long written = ftell(wf);
    fclose(wf);
    size_t outn = 0;
    sepol_policy_file_get_len(pf2, &outn);
    printf("P3 sepol_policydb_write(经 set_fp) rc=%d ftell=%ld get_len=%zu（输入 %zu B）\n", rc, written, outn, (size_t)n);
    if (rc < 0 || written <= 0) { fprintf(stderr, "P3 写不出来 ⇒ 未测\n"); return 4; }
    /* 比字节：重新读回文件，不信任内存里的 out */
    FILE *rf = fopen(argv[2], "rb");
    if (!rf) { perror("回读输出"); return 3; }
    fseek(rf, 0, SEEK_END); long rn = ftell(rf); rewind(rf);
    outn = (size_t)(rn > 0 ? rn : 0);
    out = realloc(out, outn ? outn : 1);
    if (fread(out, 1, outn, rf) != outn) { fprintf(stderr, "回读不全 ⇒ 未测\n"); fclose(rf); return 4; }
    fclose(rf);
    if (outn == (size_t)n && memcmp(out, buf, outn) == 0) {
        printf("P4 ★逐字节相同 ⇒ 空 delta 往返保真：#216『以厂商件为底、只 insert 不 delete』的地基成立\n");
        return 0;
    }
    long first = -1;
    for (size_t i = 0; i < (outn < (size_t)n ? outn : (size_t)n); i++) if (out[i] != buf[i]) { first = (long)i; break; }
    printf("P4 ★不相同（大小%s，首个差异偏移=%ld）⇒ 不许读成'没事'，要用三元组差分量语义\n",
           outn == (size_t)n ? "相同" : "不同", first);
    return 3;
}
