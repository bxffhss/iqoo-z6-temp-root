/* w974_roundtrip.c — 用 libsepol **公开** API 做"二进制策略原样往返"试验（#216 的前提）。
 * ★为什么要试这条：我上一版 `w957` 直接调**内部** `policydb_read()` 对这个件返回 rc=−1，
 *   而设备上同一份件 `sesearch` 数得出 72,813 条 allow ⇒ **件是可解析的，错的多半是我的入口**。
 *   setools 4.4 的 CLI 走的是公开包装 `sepol_policydb_create/read`（它会设 handle、按 type+vers 走 compat 路径），
 *   所以这一版只改一件事：**用公开 API 读，再用公开 API 写**，然后比字节。
 * 判读（三条，缺一说"未测"）：
 *   A. 读通？(rc>=0)            —— 不通⇒入口假设错，回到"取 AOSP 那份 libsepol"
 *   B. 写出来**与原件逐字节相同**？ —— 相同⇒"以厂商件为底、只 insert 不 delete"这条路的**地基成立**
 *   C. 不相同但大小相同？        —— 只说明"有差异"，差异内容要用差分器量，**不许读成"没事"**
 * 用法: w974_roundtrip <in.pol> <out.pol>   （exit 0=字节相同；3=读写通了但不同；4=失败）
 */
#include <sepol/policydb.h>
#include <sepol/policydb/policydb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *slurp(const char *path, size_t *out) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror("open 输入"); return NULL; }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *b = malloc((size_t)n);
    if (!b) { fclose(f); return NULL; }
    size_t got = fread(b, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { fprintf(stderr, "读不全 %zu/%ld\n", got, n); free(b); return NULL; }
    *out = (size_t)n;
    return b;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: %s <in.pol> <out.pol>\n", argv[0]); return 2; }
    size_t n = 0;
    char *buf = slurp(argv[1], &n);
    if (!buf) return 2;
    unsigned magic = 0, word1 = 0;
    memcpy(&magic, buf, 4); memcpy(&word1, buf + 4, 4);
    printf("R0 输入 %zu B magic=0x%08x modver/policyvers=%u\n", n, magic, word1);

    sepol_policydb_t *db = NULL;
    if (sepol_policydb_create(&db) < 0) { fprintf(stderr, "R1 create 失败\n"); return 4; }
    sepol_policy_file_t *pf = NULL;
    if (sepol_policy_file_create(&pf) < 0) { fprintf(stderr, "R1 file_create 失败\n"); return 4; }
    sepol_policy_file_set_mem(pf, buf, n);
    int rc = sepol_policydb_read(db, pf);
    printf("R1 公开 API sepol_policydb_read rc=%d\n", rc);
    if (rc < 0) { fprintf(stderr, "R1 读不通 ⇒ 入口假设错（需要 AOSP 那份 libsepol 或别的调用序列）\n"); return 4; }
    printf("R2 type=%d version=%u\n", sepol_policydb_get_type(db), sepol_policydb_get_vers(db));

    size_t outn = 0;
    sepol_policy_file_set_mem(pf, NULL, 0);
    rc = sepol_policydb_write(db, pf);
    printf("R3 sepol_policydb_write rc=%d\n", rc);
    if (rc < 0) return 4;
    sepol_policy_file_get_len(pf, &outn);
    char *out = malloc(outn ? outn : 1);
    memcpy(out, sepol_policy_file_get_mem(pf), outn);
    FILE *w = fopen(argv[2], "wb");
    if (!w) { perror("打开输出"); return 4; }
    fwrite(out, 1, outn, w); fclose(w);
    printf("R4 写出 %zu B（输入 %zu B）\n", outn, n);
    if (outn == n && memcmp(out, buf, n) == 0) { printf("R5 ★逐字节相同 ⇒ 空 delta 往返保真，#216 地基成立\n"); return 0; }
    printf("R5 ★不相同（大小%s）⇒ 不许当'没事'；差异内容由差分器量\n", outn == n ? "同、内容不同" : "也不同");
    return 3;
}
