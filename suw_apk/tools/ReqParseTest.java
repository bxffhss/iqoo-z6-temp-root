import java.text.SimpleDateFormat;
import java.util.*;
import java.util.regex.*;

/* 不装 APK 也能验"最近请求"这一行的解析与渲染：把设备上的审计原文当输入。
 *   adb exec-out "su -c 'tail -n 300 /data/local/tmp/su.audit'" > tools/audit.txt
 *   adb shell "cut -d' ' -f1 /proc/uptime" | tr -d '\r' | sed 's/^/UP=/' >> tools/audit.txt
 *   javac -encoding UTF-8 --release 8 tools/ReqParseTest.java && java -Dfile.encoding=UTF-8 ReqParseTest tools/audit.txt
 * 这里的 callerOf/whenOf/reqLine 与 MainActivity 里的是同一段逻辑(手抄) —— 改了那边要同步改这里。 */
public class ReqParseTest {
  static class Req { final String proc; final int up; Req(String p, int u) { proc = p; up = u; } }
  static Map<Integer, Req> allowByUid = new LinkedHashMap<>();
  static Map<Integer, Req> denyByUid = new LinkedHashMap<>();
  static int curUpSec = -1, lastPolicyChangeUp = -1;

  static String cmdOf(String ln, String key) {
    Matcher m = Pattern.compile("(^| )" + key + "\\[([^\\]]*)\\]").matcher(ln);
    if (!m.find()) return "";
    String s = m.group(2);
    int i = s.indexOf('/');                       // 形如 comm/cmdline, comm 里不会有 '/'
    return i >= 0 ? s.substring(i + 1) : "";
  }

  static String firstTok(String cmdline) {
    for (String t : cmdline.split(" ")) {
      if (t.isEmpty()) continue;
      int sl = t.lastIndexOf('/');
      return sl >= 0 ? t.substring(sl + 1) : t;
    }
    return "";
  }

  static String pkgOfPath(String cmdline) {
    Matcher dp = Pattern.compile("/data/(?:data|user/\\d+)/([^/]+)/").matcher(cmdline);
    return dp.find() ? dp.group(1) : null;
  }

  static String callerOf(String ln) {
    String pc = cmdOf(ln, "parent=");
    String tok = firstTok(pc);
    if (tok.isEmpty()) {
      Matcher cm = Pattern.compile("comm=\\[([^\\]]*)\\]").matcher(ln);
      if (cm.find()) tok = cm.group(1);
    }
    String owner = pkgOfPath(pc);
    if (!tok.isEmpty() && tok.contains(".")) return tok;
    if (owner != null) return owner + "(" + tok + ")";
    String gc = cmdOf(ln, "gparent=");
    String gt = firstTok(gc);
    String relay = tok.isEmpty() ? "?" : tok;
    if (!gt.isEmpty() && gt.contains(".")) return gt + "(经 " + relay + " 中转)";
    if (pkgOfPath(gc) != null) return pkgOfPath(gc) + "(经 " + relay + " 中转)";
    return tok.isEmpty() ? "(读不到进程名)" : tok + "(看不到发起包)";
  }

  static String whenOf(int up) {
    if (up < 0 || curUpSec < 0) return "时间未知";
    int ago = curUpSec - up; if (ago < 0) ago = 0;
    String rel = ago < 60 ? ago + " 秒前" : (ago < 3600 ? ago / 60 + " 分钟前" : ago / 3600 + " 小时前");
    long ms = System.currentTimeMillis() - ago * 1000L;
    return rel + " (" + new SimpleDateFormat("HH:mm", Locale.US).format(new Date(ms)) + ")";
  }

  static String reqSeg(Req r, boolean allow) {
    return (allow ? "允许 su" : "拒绝 su") + " ← " + r.proc + " · " + whenOf(r.up);
  }

  static String reqLine(int uid) {
    Req a = allowByUid.get(uid), d = denyByUid.get(uid);
    if (a == null && d == null) return null;
    Req last = (a == null) ? d : (d == null ? a : (a.up >= d.up ? a : d));
    Req older = last == a ? d : a;
    String s = "该 uid 最近一次请求: " + reqSeg(last, last == a);
    if (older != null) s += "\n更早一次: " + reqSeg(older, older == a);
    if (lastPolicyChangeUp >= 0 && last.up >= 0 && last.up < lastPolicyChangeUp)
      s += "（早于最近一次改策略，可能是旧记录）";
    return s;
  }

  public static void main(String[] args) throws Exception {
    String audit = new String(java.nio.file.Files.readAllBytes(
        new java.io.File(args[0]).toPath()), "UTF-8").replace("\r", "");
    Pattern ver = Pattern.compile("(ALLOW|DENY)\\s+uid=(\\d+)");
    Pattern upt = Pattern.compile("^\\[(\\d+)\\.\\d+\\]");
    Pattern pop = Pattern.compile("op=(add|del|reset)");
    for (String ln : audit.split("\n")) {
      Matcher ut = upt.matcher(ln);
      int up = ut.find() ? Integer.parseInt(ut.group(1)) : -1;
      if (up >= 0 && ln.contains("CTRL") && pop.matcher(ln).find())
        if (up > lastPolicyChangeUp) lastPolicyChangeUp = up;
      Matcher m = ver.matcher(ln);
      if (!m.find()) continue;
      int u = Integer.parseInt(m.group(2));
      Req r = new Req(callerOf(ln), up);
      if ("ALLOW".equals(m.group(1))) allowByUid.put(u, r); else denyByUid.put(u, r);
    }
    Matcher um = Pattern.compile("UP=(\\d+)").matcher(audit);
    curUpSec = um.find() ? Integer.parseInt(um.group(1)) : -1;
    System.out.println("curUpSec=" + curUpSec + " lastPolicyChangeUp=" + lastPolicyChangeUp
        + " allow=" + allowByUid.size() + " deny=" + denyByUid.size());
    Set<Integer> all = new TreeSet<>();
    all.addAll(allowByUid.keySet()); all.addAll(denyByUid.keySet());
    for (int u : all) System.out.println("uid=" + u + " | " + reqLine(u));
  }
}
