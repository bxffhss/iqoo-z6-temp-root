import io
import sys

P = "cm57/ksuctl.c"
s = io.open(P, encoding="utf-8").read()


def sub(old, new, tag):
    global s
    if s.count(old) != 1:
        sys.exit("ANCHOR FAIL [%s] count=%d" % (tag, s.count(old)))
    s = s.replace(old, new)
    print("ok [%s]" % tag)


# 1) 另给一个"只含名字"的宏(日志里继续用带 @ 的那个：相邻字符串字面量会自动拼)
sub(
    '#define KSU_SUSHD_PATH "@suwksu"',
    '#define KSU_SUSHD_PATH "@suwksu"\n'
    '/* abstract socket：sun_path[0]=0，后面直接放不带 @ 的名字(不占文件系统 inode)。\n'
    '   名字单独一个宏：以前写 `KSU_SUSHD_PATH + 1` 会被编译器当成"字符串加 int"报警。 */\n'
    '#define KSU_SUSHD_NAME "suwksu"\n'
    '#define KSU_SUSHD_NAMELEN ((socklen_t)(sizeof(KSU_SUSHD_NAME) - 1))',
    "名字宏",
)
sub(
    "\tmemcpy(a.sun_path + 1, KSU_SUSHD_PATH + 1, strlen(KSU_SUSHD_PATH) - 1);",
    "\tmemcpy(a.sun_path + 1, KSU_SUSHD_NAME, KSU_SUSHD_NAMELEN);",
    "memcpy",
)
sub(
    "\t\t (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(KSU_SUSHD_PATH) - 1)) < 0) {",
    "\t\t (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + KSU_SUSHD_NAMELEN)) < 0) {",
    "bind 长度",
)

# 2) bionic 不声明 pipe2 ⇒ pipe + FD_CLOEXEC(效果一样：exec 时原 fd 关，dup 出来的 1/2 留着)
sub(
    "\t\tif (pipe2(sv, O_CLOEXEC) < 0) {\n"
    "\t\t\tconst char *d = \"DENY pipe2 失败\\n\";\n"
    "\t\t\tif (write(cl, d, strlen(d)) < 0) { }\n"
    "\t\t\tclose(cl);\n"
    "\t\t\tcontinue;\n"
    "\t\t}",
    "\t\tif (pipe(sv) < 0) {\n"
    "\t\t\tconst char *d = \"DENY pipe 失败\\n\";\n"
    "\t\t\tif (write(cl, d, strlen(d)) < 0) { }\n"
    "\t\t\tclose(cl);\n"
    "\t\t\tcontinue;\n"
    "\t\t}\n"
    "\t\tfcntl(sv[0], F_SETFD, FD_CLOEXEC);\n"
    "\t\tfcntl(sv[1], F_SETFD, FD_CLOEXEC);",
    "pipe2 换 pipe",
)

io.open(P, "w", encoding="utf-8", newline="").write(s)
print("sushd 的编译问题已修")
