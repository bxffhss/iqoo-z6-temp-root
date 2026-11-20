/* w1151 — #238 部件①：解 ksud `SET_SEPOLICY` 那条"原子规则命令流"。
 *
 * 线格式是一件一手现读出来的，出处两处(构建机 /root/k/ksu)：
 *   uapi/selinux.h:6-29            —— cmd/subcmd 的数值
 *   userspace/ksud/src/sepolicy.rs:653 cmd_expected_argc()、:665 encode_policy_object()、:679 append_atomic_statement()
 * 每条语句 = u32 cmd | u32 subcmd | cmd_expected_argc(cmd) 个参数；
 * 每个参数   = u32 长度 | 长度个字节 | 1 个 NUL。长度 0 ＝ None/All(只有那一个 NUL)。
 * Rust 用的是 to_ne_bytes ⇒ 这台 aarch64 上是小端，故这里只认小端。
 *
 * ★这一层只做**结构与取值域**的把关，不碰任何 SS 结构(§6.539 的形状：图在用户态算，ko 只解与存)。
 * ★本文件必须在"宿主自测"与"模块"里编到**同一份**——它不 include 任何东西，类型自带，
 *   这样自测跑的就是将来上机的那段码，不是它的摹本。
 */
#ifndef W1151_SEPOLICY_CORE_H
#define W1151_SEPOLICY_CORE_H

typedef unsigned char w1151_u8;
typedef unsigned int w1151_u32;
typedef unsigned long long w1151_u64;

#define W1151_ARGC_MAX 5u
#define W1151_ARG_MAX 256u
#define W1151_STMT_MAX 512u
#define W1151_IN_MAX 65536ull

#define W1151_OK 0u
#define W1151_E_EMPTY 1u          /* 长度为 0 的流：ksud 在 policies.is_empty() 时根本不发 */
#define W1151_E_TRUNC_HDR 2u      /* 剩不到 8 字节，凑不出一对 cmd/subcmd */
#define W1151_E_UNKNOWN_CMD 3u    /* cmd 不在 1..9 ⇒ argc 无从知道，后面全是猜 */
#define W1151_E_TRUNC_ARGLEN 4u   /* 参数长度字段都读不满 */
#define W1151_E_ARGLEN_BIG 5u     /* 单个参数超过 W1151_ARG_MAX */
#define W1151_E_TRUNC_ARGBODY 6u  /* 说好的字节数(含收尾 NUL)不在流里 */
#define W1151_E_NO_NUL 7u         /* 那一个 NUL 不是 NUL ⇒ 我的偏移会一路漂 */
#define W1151_E_TOO_MANY 8u       /* 语句条数超过调用方给的格子数 */
#define W1151_E_BAD_SUBCMD 9u     /* cmd 认得，subcmd 不在 ksud 会写出的取值里 */
/* ★这里原本还有一条"收尾没正好吃完"(NOT_EXACT)。它走不进去：
 *   每一圈要么在加 8/4/alen+1 之前先证 len-pos 够，要么直接拒 ⇒ pos 永不越过 len，
 *   循环只在 pos>=len 时退出，也就是 pos==len。留一条进不去的分支＝让尺看着比实际厚
 *   (§39 那一手：闸门控的是走不进去的成功分支)。故删。
 *   参数体内有 NUL 那条是真走得进的(长度 5、字节 "sh\0l"、收尾仍 0)，留做拒收项。 */
#define W1151_E_ARG_HAS_NUL 10u   /* 参数体内有 NUL ⇒ 那不是 ksud 写的"一个字符串" */
#define W1151_E_INPUT_BIG 11u     /* 整条流超过 W1151_IN_MAX ⇒ 先拦总量，别拿单参数的尺去量它 */

struct w1151_arg {
	w1151_u32 off; /* buf 内字节起点 */
	w1151_u32 len; /* 不含收尾 NUL；0 ⇒ None/All */
};

struct w1151_stmt {
	w1151_u32 cmd;
	w1151_u32 subcmd;
	w1151_u32 argc;
	struct w1151_arg arg[W1151_ARGC_MAX];
};

struct w1151_report {
	w1151_u32 why;    /* W1151_OK 表示整条流干净 */
	w1151_u32 n;      /* 解出/解到第几条 */
	w1151_u64 bad_at; /* 出事的那个字节偏移 */
	w1151_u32 max_arg_len; /* 顺带量到的最长参数，给调用方当尺 */
};

/* ksud 写不出别的 argc：这张表就是 cmd_expected_argc() 的逐行翻译。 */
static w1151_u32 w1151_cmd_argc(w1151_u32 cmd)
{
	switch (cmd) {
	case 1: /* NORMAL_PERM   : source,target,class,perm */
	case 8: /* TYPE_CHANGE   : source,target,class,default_type */
		return 4;
	case 2: /* XPERM         : source,target,class,operation,perm */
	case 7: /* TYPE_TRANSITION: source,target,class,default_type,object(可 None) */
		return 5;
	case 3: /* TYPE_STATE    : type */
	case 6: /* ATTR          : name */
		return 1;
	case 4: /* TYPE          : name,attr */
	case 5: /* TYPE_ATTR     : type,attr */
		return 2;
	case 9: /* GENFSCON      : fs_name,partial_path,fs_context */
		return 3;
	default:
		return 0;
	}
}

/* subcmd 的取值域同出一处：ksud 只在这些值里选，别的一律写不出来。
 * 4/5/6/7/9 那几条 Rust 里是 `subcmd: 0` 写死的。 */
static int w1151_subcmd_ok(w1151_u32 cmd, w1151_u32 sub)
{
	switch (cmd) {
	case 1:
		return sub >= 1 && sub <= 4; /* allow/deny/auditallow/dontaudit */
	case 2:
		return sub >= 1 && sub <= 3; /* allowxperm/auditallowxperm/dontauditxperm */
	case 3:
		return sub >= 1 && sub <= 2; /* permissive/enforce */
	case 8:
		return sub >= 1 && sub <= 2; /* type_change/type_member */
	case 4:
	case 5:
	case 6:
	case 7:
	case 9:
		return sub == 0;
	default:
		return 0;
	}
}

static w1151_u32 w1151_le32(const w1151_u8 *p)
{
	return (w1151_u32)p[0] | ((w1151_u32)p[1] << 8) | ((w1151_u32)p[2] << 16) |
	       ((w1151_u32)p[3] << 24);
}

/* 返回 0 ＝ 整条流干净；非 0 ＝ 拒，细节全在 rep 里。
 * 拒的时候 out 里有前 n 条**已经**解完的语句，但调用方只许在 why==0 时把它们当真。 */
static int w1151_decode_stream(const w1151_u8 *buf, w1151_u64 len,
			       struct w1151_stmt *out, w1151_u32 out_max,
			       struct w1151_report *rep)
{
	w1151_u64 pos = 0;
	w1151_u32 n = 0;

	rep->why = W1151_OK;
	rep->n = 0;
	rep->bad_at = 0;
	rep->max_arg_len = 0;

	if (len == 0) {
		rep->why = W1151_E_EMPTY;
		return -1;
	}
	if (len > W1151_IN_MAX) {
		/* 先拦住总量；单参数的上限是另一回事(下面的 ARGLEN_BIG) */
		rep->why = W1151_E_INPUT_BIG;
		rep->bad_at = W1151_IN_MAX;
		return -1;
	}

	while (pos < len) {
		w1151_u32 cmd, sub, argc, i;
		struct w1151_stmt *s;

		if (len - pos < 8) {
			rep->why = W1151_E_TRUNC_HDR;
			rep->bad_at = pos;
			return -1;
		}
		cmd = w1151_le32(buf + pos);
		sub = w1151_le32(buf + pos + 4);
		argc = w1151_cmd_argc(cmd);
		if (argc == 0) {
			rep->why = W1151_E_UNKNOWN_CMD;
			rep->bad_at = pos;
			return -1;
		}
		if (!w1151_subcmd_ok(cmd, sub)) {
			rep->why = W1151_E_BAD_SUBCMD;
			rep->bad_at = pos + 4;
			return -1;
		}
		if (n >= out_max) {
			rep->why = W1151_E_TOO_MANY;
			rep->bad_at = pos;
			return -1;
		}
		s = &out[n];
		s->cmd = cmd;
		s->subcmd = sub;
		s->argc = argc;
		pos += 8;

		for (i = 0; i < argc; i++) {
			w1151_u32 alen, k;

			if (len - pos < 4) {
				rep->why = W1151_E_TRUNC_ARGLEN;
				rep->bad_at = pos;
				return -1;
			}
			alen = w1151_le32(buf + pos);
			pos += 4;
			if (alen > W1151_ARG_MAX) {
				rep->why = W1151_E_ARGLEN_BIG;
				rep->bad_at = pos - 4;
				return -1;
			}
			/* 长度之外还要落得下那 alen 个字节**加上**收尾 NUL */
			if (len - pos < (w1151_u64)alen + 1) {
				rep->why = W1151_E_TRUNC_ARGBODY;
				rep->bad_at = pos;
				return -1;
			}
			if (buf[pos + alen] != 0) {
				rep->why = W1151_E_NO_NUL;
				rep->bad_at = pos + alen;
				return -1;
			}
			for (k = 0; k < alen; k++) {
				if (buf[pos + k] == 0) {
					rep->why = W1151_E_ARG_HAS_NUL;
					rep->bad_at = pos + k;
					return -1;
				}
			}
			s->arg[i].off = (w1151_u32)pos;
			s->arg[i].len = alen;
			pos += (w1151_u64)alen + 1;
			if (alen > rep->max_arg_len)
				rep->max_arg_len = alen;
		}
		for (i = argc; i < W1151_ARGC_MAX; i++) {
			s->arg[i].off = 0;
			s->arg[i].len = 0xffffffffu; /* "这条语句没这个槽位"，跟 len=0 的 None/All 分开 */
		}
		n++;
		rep->n = n;
	}

	/* 走到这里 pos==len 是上面每条边界加起来的必然结果，不再单列一格"没吃完"。 */
	rep->n = n;
	return 0;
}

/* 给调用方打一条"这条流该有多少字节"的独立算式：
 * Σ over 语句 (8 + Σ over 参数 (5 + strlen(参数)))。
 * ★自测用它当第三方证人：它跟解码器不是同一条路径(一个数期望长度、一个走字节)，
 *   两处对不上就说明我把 cmd_expected_argc 或参数框大小记错了。 */
static w1151_u64 w1151_expect_bytes(const struct w1151_stmt *st, w1151_u32 n)
{
	w1151_u64 t = 0;
	w1151_u32 i, j;

	for (i = 0; i < n; i++) {
		t += 8;
		for (j = 0; j < st[i].argc; j++)
			t += 5 + st[i].arg[j].len;
	}
	return t;
}

#endif /* W1151_SEPOLICY_CORE_H */
