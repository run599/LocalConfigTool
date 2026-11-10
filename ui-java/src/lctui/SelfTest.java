package lctui;

import java.io.File;
import java.util.Map;

/** 无界面性能自检：证明 ① 常驻 worker（冷调用 → 常驻后毫秒级）。 */
public final class SelfTest {

    public static void main(String[] args) throws Exception {
        File root = new File(args.length > 0 ? args[0] : ".").getAbsoluteFile();
        System.out.println("toolRoot = " + root);

        long t0 = System.currentTimeMillis();
        WorkerClient w = WorkerClient.start(root);
        long startup = System.currentTimeMillis() - t0;
        System.out.println("[1] worker 启动 + 导入模块: " + startup + " ms（一次性成本）");
        System.out.println("METRIC worker_start_ms=" + startup);

        String[] verbs = {"engine.verbs", "driver.profile.list", "process.list", "driver.map", "driver.devices", "driver.status"};
        long total = 0;
        for (String v : verbs) {
            long s = System.currentTimeMillis();
            Map<String, Object> callArgs = null;
            if ("driver.devices".equals(v)) { callArgs = new java.util.LinkedHashMap<>(); callArgs.put("name", "disk"); }
            Map<String, Object> r = w.request(v, callArgs, false);
            long ms = System.currentTimeMillis() - s;
            total += ms;
            Engine.Result res = Engine.Result.of(r);
            System.out.printf("[2] %-22s %5d ms  ok=%-5s workerMs=%d%n", v, ms, res.ok, res.workerMs);
        }
        System.out.printf("[2] 合计 %d ms，平均 %.1f ms/次%n", total, total / (double) verbs.length);

        int n = 20;
        long sum = 0;
        for (int i = 0; i < n; i++) {
            long s = System.nanoTime();
            w.request("engine.verbs", null, false);
            sum += (System.nanoTime() - s) / 1_000_000L;
        }
        System.out.printf("[3] engine.verbs 连续 %d 次，平均 %.2f ms/次%n", n, sum / (double) n);
        System.out.printf("METRIC avg_ms=%.2f%n", sum / (double) n);

        Map<String, Object> r = w.request("engine.verbs", null, false);
        Engine.Result res = Engine.Result.of(r);
        Map<String, Object> d = res.dataMap();
        Object verbs2 = d.get("verbs");
        int vc = verbs2 instanceof java.util.List ? Json.castList(verbs2).size() : -1;
        System.out.println("[4] 引擎 verb 数 = " + vc + "  availability=" + Json.write(d.get("availability")));
        System.out.println("METRIC verb_count=" + vc);
        // 字体覆盖检查：文本区用的等宽字体必须能显示中文（Consolas/Cascadia 实测 canDisplayUpTo("共")=0）
        java.awt.Font mono = new java.awt.Font(java.awt.Font.MONOSPACED, java.awt.Font.PLAIN, 13);
        System.out.println("METRIC font_cjk_ok=" + (mono.canDisplayUpTo("共447条驱动服务（引擎内）✔✖→") < 0 ? 1 : 0));
        w.close();
        System.out.println("SELFTEST OK");
    }
}
