/* w1161 — #238 部件③「装载门」的**纯判定**：一张图现在能不能交给 `security_load_policy()`。
 *
 * ★为什么不自己发明第二套：这套次序与编号是从**第 96 发真跑过的那件探针**逐条搬来的
 *   (`kmod/w1140_polload.c:58-70` 的 `pl_why` 表＋`:226-269` 的判断段)，那一发的证件是
 *   `pl_why=0 / pl_load_rc=0`(＝一路走到装载并且内核收下)。⇒ 出货的门与那枚探针**必须报同一个号**，
 *   否则以后"窗里读到的 why=6"没法和"探针当年 why=6"对照，等于把已经买到的凭据扔掉。
 * ★本头里**一个常数都不背**：`SELINUX_MAGIC` 与 `strlen(POLICYDB_STRING)` 都由调用方传进来
 *   (内核那侧从设备自己的 `include/security.h`/`ss/policydb.h` 取值；宿主那侧从 `linux/magic.h` 取值)。
 *   上一版我就是凭记忆把魔数写成 `0x3000012`，而设备的图第一字是 `0xf97cff8c`——这类"记忆里的小端"
 *   只有现读能救(见 §6.549 那格：现读设备图头 = 8c ff 7c f9 / 串长 8 / "SE Linux" / vers 30)。
 * ★这里不碰内存、不碰符号、不碰 errno：那些都是调用方的事，本头只回答"该不该放行、拒在哪一格"。
 */
#ifndef W1161_POLGATE_H
#define W1161_POLGATE_H

typedef unsigned char w1161_u8;
typedef unsigned int w1161_u32;
typedef unsigned long long w1161_u64;

/* 与 w1140 的 `pl_why` 一字一一对应(名字加前缀，号不变)。 */
#define W1161_OK          0	/* 一路放行：成败之后看 security_load_policy 自己的 rc，别看这里 */
#define W1161_NOKEY       1	/* 钥匙不对(insmod 那一刻定下来的参数) */
#define W1161_SYM         2	/* 符号没解全 */
#define W1161_NOIMG       3	/* 还没交图，或那块缓冲出过事 */
#define W1161_TOOSMALL    4
#define W1161_TOOLONG     5
#define W1161_BADMAGIC    6
#define W1161_BADSTR      7	/* 头里那个"串长"字段不等于 strlen(POLICYDB_STRING) */
#define W1161_ARMMISMATCH 8	/* 没武装，或放行当下重读的活策略指纹 ≠ 武装值 */
#define W1161_ALLOC       9
#define W1161_FAULT      10	/* copy_from_user 出过事 ⇒ 缓冲不再可信 */
#define W1161_READPOL    11	/* 读活策略这一步自己就红了 ⇒ 甲尺读不到，判据不成立 */

/* 头里那几个偏移：一手数出来的"最小可解析头"(magic4＋串长4＋串体8＋vers 与其后 3 个 u32＝16)。
 * ★下限取 32 这个**结构值**，不取"手上第一份输入有多大"——例 226 那条：那样闸会把自己的合法输入拒掉。 */
#define W1161_HDR_MIN 32u
#define W1161_STRLEN_OFF 4u
#define W1161_VER_OFF 16u

struct w1161_req {
	int key_ok;		/* ① 钥匙(内核那侧＝pl_key == 'POLD'，0444 ⇒ 运行期开不了) */
	int syms_ok;		/* 装载要的那几个符号都解到了 */
	int have_img;		/* 图在缓冲里、没被 FAULT 弄脏、且不是零长 */
	int fault;		/* copy_from_user 出过事：在这条路上**并入 NOIMG**(探针 :236 的形状)，不是单独一格 */
	w1161_u64 len;		/* 交进来的字节数 */
	w1161_u64 cap;		/* 调用方算好的上限(内核那侧＝min(pl_cap, PL_MAX)) */
	w1161_u32 magic_want;	/* ★调用方传的 SELINUX_MAGIC */
	w1161_u32 taglen_want;	/* ★调用方传的 strlen(POLICYDB_STRING) */
	const w1161_u8 *head;	/* 图的前 W1161_HDR_MIN 个字节(len 不足时不会被读) */
	int readpol_ok;		/* 读活策略这一步没红 */
	int armed;		/* 武装标志 == 1 */
	w1161_u64 armed_sum;	/* 武装那一刻记下的活策略指纹 */
	w1161_u64 live_sum;	/* **此刻**重读活策略算出的同一个指纹 */
};

/* ★六个函数一律 `static inline`(11-07 改)：这份头同时被**内核桩**与宿主自测 include，而桩里只用得到
 *   其中五个——`w1161_policyvers` 在装载面没人调(门的判据不看版本号)。写成裸 `static` 会在内核那侧
 *   留下一个 `-Wunused-function`，而把它压掉的办法(-Wno-unused-function)会同时关掉整棵树上"我确实没用到"
 *   这把尺。⇒ 用 inline：不响，且尺还开着。★改这份头=改登记件，必须重跑 w1161 那一跑(不是"只改注释"，
 *   这次连 md5 都变了：见证件 v3→v4)。 */
/* 小端取一个 u32：设备的图就是这台机器的字节序(第 96 发一手)，这里只认小端。 */
static inline w1161_u32 w1161_le32(const w1161_u8 *p)
{
	return (w1161_u32)p[0] | ((w1161_u32)p[1] << 8) | ((w1161_u32)p[2] << 16) |
	       ((w1161_u32)p[3] << 24);
}

static inline w1161_u32 w1161_magic(const struct w1161_req *r)
{
	return w1161_le32(r->head);
}

static inline w1161_u32 w1161_taglen(const struct w1161_req *r)
{
	return w1161_le32(r->head + W1161_STRLEN_OFF);
}

static inline w1161_u32 w1161_policyvers(const struct w1161_req *r)
{
	return w1161_le32(r->head + W1161_VER_OFF);
}

/* ★次序就是探针的次序：钥匙 → 符号 → 图在不在(缓冲/脏/零长三样**合成一格**＝NOIMG，探针 :236 就是这么写的)
 *   → 太小 → 太大 → 魔数 → 串长 → 读活策略 → 武装比对。
 *   两样同时坏时，**先查的那把**说话；这一点在宿主自测里是逐对讲过的(T4)，不许靠运气。
 * ★`W1161_ALLOC`/`W1161_FAULT` 这里**永远不会返回**：那两个号在探针里属于"收图"那条路(:306/:317)，
 *   不是"放行"这条路。号留着是为了两张表能逐格对得上；缓冲脏了在这里仍报 NOIMG(＝"这块不能用")。 */
static inline int w1161_gate(const struct w1161_req *r)
{
	if (!r->key_ok)
		return W1161_NOKEY;
	if (!r->syms_ok)
		return W1161_SYM;
	if (!r->have_img || r->fault || r->len == 0)
		return W1161_NOIMG;
	if (r->len < W1161_HDR_MIN)
		return W1161_TOOSMALL;
	if (r->len > r->cap)
		return W1161_TOOLONG;
	if (w1161_magic(r) != r->magic_want)
		return W1161_BADMAGIC;
	if (w1161_taglen(r) != r->taglen_want)
		return W1161_BADSTR;
	if (!r->readpol_ok)
		return W1161_READPOL;
	if (!r->armed)
		return W1161_ARMMISMATCH;	/* 没武装：与"武装了但指纹不符"同格，因为修法一样＝重新 ARM */
	if (r->armed_sum != r->live_sum)
		return W1161_ARMMISMATCH;	/* 中途有人装载过(腿自己写 /sys/fs/selinux/load 也算)⇒ 自动失效 */
	return W1161_OK;
}

static inline const char *w1161_why_name(int why)
{
	switch (why) {
	case W1161_OK:
		return "OK";
	case W1161_NOKEY:
		return "NOKEY";
	case W1161_SYM:
		return "SYM";
	case W1161_NOIMG:
		return "NOIMG";
	case W1161_TOOSMALL:
		return "TOOSMALL";
	case W1161_TOOLONG:
		return "TOOLONG";
	case W1161_BADMAGIC:
		return "BADMAGIC";
	case W1161_BADSTR:
		return "BADSTR";
	case W1161_ARMMISMATCH:
		return "ARMMISMATCH";
	case W1161_ALLOC:
		return "ALLOC";
	case W1161_FAULT:
		return "FAULT";
	case W1161_READPOL:
		return "READPOL";
	default:
		return "?未知号(表里没有＝这份件与探针那张表分了家)";
	}
}

#endif /* W1161_POLGATE_H */
