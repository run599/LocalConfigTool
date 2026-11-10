package lctui;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 极简 JSON（解析 + 序列化）。不引第三方依赖：JDK 自带没有 JSON，而引 Gson/Jackson 要下载 jar，
 * 这个工具要求"开箱即用"，所以自带一个够用的实现。
 *
 * 约定：对象 -> LinkedHashMap<String,Object>；数组 -> ArrayList<Object>；
 *       整数 -> Long；小数 -> Double；字符串 -> String；true/false -> Boolean；null -> null。
 */
public final class Json {

    private final String s;
    private int i;

    private Json(String s) { this.s = s; }

    public static Object parse(String text) {
        if (text == null) throw new IllegalArgumentException("JSON 为 null");
        Json p = new Json(text);
        p.ws();
        Object v = p.value();
        p.ws();
        if (p.i != p.s.length()) throw new IllegalArgumentException("JSON 尾部有多余内容（位置 " + p.i + "）");
        return v;
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> parseObject(String text) {
        Object v = parse(text);
        if (!(v instanceof Map)) throw new IllegalArgumentException("期望 JSON 对象，实际是 " + typeName(v));
        return (Map<String, Object>) v;
    }

    public static List<Object> parseArray(String text) {
        Object v = parse(text);
        if (!(v instanceof List)) throw new IllegalArgumentException("期望 JSON 数组，实际是 " + typeName(v));
        return castList(v);
    }

    @SuppressWarnings("unchecked")
    public static List<Object> castList(Object v) { return (List<Object>) v; }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> castMap(Object v) { return (Map<String, Object>) v; }

    public static String typeName(Object v) {
        if (v == null) return "null";
        if (v instanceof Map) return "object";
        if (v instanceof List) return "array";
        if (v instanceof String) return "string";
        if (v instanceof Boolean) return "boolean";
        return "number";
    }

    // ---------------- 解析 ----------------

    private void ws() {
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++;
            else break;
        }
    }

    private char peek() {
        if (i >= s.length()) throw new IllegalArgumentException("JSON 意外结束");
        return s.charAt(i);
    }

    private Object value() {
        char c = peek();
        switch (c) {
            case '{': return obj();
            case '[': return arr();
            case '"': return str();
            case 't': lit("true"); return Boolean.TRUE;
            case 'f': lit("false"); return Boolean.FALSE;
            case 'n': lit("null"); return null;
            default: return num();
        }
    }

    private void lit(String expect) {
        if (!s.startsWith(expect, i)) throw new IllegalArgumentException("非法字面量 @" + i);
        i += expect.length();
    }

    private Map<String, Object> obj() {
        Map<String, Object> m = new LinkedHashMap<>();
        i++; // {
        ws();
        if (peek() == '}') { i++; return m; }
        while (true) {
            ws();
            String k = str();
            ws();
            if (peek() != ':') throw new IllegalArgumentException("对象缺少 ':' @" + i);
            i++;
            ws();
            m.put(k, value());
            ws();
            char c = peek();
            if (c == ',') { i++; continue; }
            if (c == '}') { i++; return m; }
            throw new IllegalArgumentException("对象里期望 ',' 或 '}' @" + i);
        }
    }

    private List<Object> arr() {
        List<Object> a = new ArrayList<>();
        i++; // [
        ws();
        if (peek() == ']') { i++; return a; }
        while (true) {
            ws();
            a.add(value());
            ws();
            char c = peek();
            if (c == ',') { i++; continue; }
            if (c == ']') { i++; return a; }
            throw new IllegalArgumentException("数组里期望 ',' 或 ']' @" + i);
        }
    }

    private String str() {
        if (peek() != '"') throw new IllegalArgumentException("期望字符串 @" + i);
        i++;
        StringBuilder b = new StringBuilder();
        while (true) {
            if (i >= s.length()) throw new IllegalArgumentException("字符串未闭合");
            char c = s.charAt(i++);
            if (c == '"') return b.toString();
            if (c != '\\') { b.append(c); continue; }
            char e = s.charAt(i++);
            switch (e) {
                case '"': b.append('"'); break;
                case '\\': b.append('\\'); break;
                case '/': b.append('/'); break;
                case 'b': b.append('\b'); break;
                case 'f': b.append('\f'); break;
                case 'n': b.append('\n'); break;
                case 'r': b.append('\r'); break;
                case 't': b.append('\t'); break;
                case 'u': {
                    String hex = s.substring(i, i + 4);
                    i += 4;
                    b.append((char) Integer.parseInt(hex, 16));
                    break;
                }
                default: throw new IllegalArgumentException("未知转义 \\" + e);
            }
        }
    }

    private Object num() {
        int start = i;
        if (peek() == '-') i++;
        boolean frac = false;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c >= '0' && c <= '9') { i++; continue; }
            if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { if (c == '.' || c == 'e' || c == 'E') frac = true; i++; continue; }
            break;
        }
        String t = s.substring(start, i);
        if (t.isEmpty() || t.equals("-")) throw new IllegalArgumentException("非法数字 @" + start);
        try {
            if (!frac) return Long.valueOf(Long.parseLong(t));
        } catch (NumberFormatException ignored) { }
        return Double.valueOf(Double.parseDouble(t));
    }

    // ---------------- 序列化 ----------------

    public static String write(Object v) {
        StringBuilder b = new StringBuilder();
        writeValue(b, v);
        return b.toString();
    }

    private static void writeValue(StringBuilder b, Object v) {
        if (v == null) { b.append("null"); return; }
        if (v instanceof String) { writeString(b, (String) v); return; }
        if (v instanceof Boolean) { b.append(v.toString()); return; }
        if (v instanceof Number) {
            if (v instanceof Double || v instanceof Float) {
                double d = ((Number) v).doubleValue();
                if (d == Math.rint(d) && !Double.isInfinite(d)) b.append((long) d);
                else b.append(d);
            } else b.append(v.toString());
            return;
        }
        if (v instanceof Map) {
            b.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
                if (!first) b.append(',');
                first = false;
                writeString(b, String.valueOf(e.getKey()));
                b.append(':');
                writeValue(b, e.getValue());
            }
            b.append('}');
            return;
        }
        if (v instanceof List) {
            b.append('[');
            boolean first = true;
            for (Object o : (List<?>) v) {
                if (!first) b.append(',');
                first = false;
                writeValue(b, o);
            }
            b.append(']');
            return;
        }
        writeString(b, String.valueOf(v));
    }

    private static void writeString(StringBuilder b, String s) {
        b.append('"');
        for (int k = 0; k < s.length(); k++) {
            char c = s.charAt(k);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        b.append('"');
    }
}
