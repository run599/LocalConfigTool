package lctui;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * 常驻引擎 worker 的客户端（① 常驻 worker）。
 *
 * 只起一次 powershell.exe + 导入一次模块；之后每条请求都是 stdin 一行 JSON / stdout 一行 JSON。
 * 实测：冷调用 ~2.2 秒/次；常驻后 0~10 毫秒/次。
 *
 * 线程模型：worker 是单线程串行的，所以这里用一把锁把请求串起来；
 * UI 侧再通过 Engine 的线程池排队，因此界面永不被阻塞（② 异步）。
 */
public final class WorkerClient implements AutoCloseable {

    private final Process proc;
    private final BufferedWriter stdin;
    private final BlockingQueue<String> lines = new ArrayBlockingQueue<>(64);
    private final Object lock = new Object();
    private final Deque<String> stderrTail = new ArrayDeque<>();
    private final long startMillis;
    private volatile boolean closed;
    private volatile String lastError = "";
    private final File toolRoot;

    private WorkerClient(Process proc, File toolRoot) {
        this.proc = proc;
        this.toolRoot = toolRoot;
        this.startMillis = System.currentTimeMillis();
        this.stdin = new BufferedWriter(new OutputStreamWriter(proc.getOutputStream(), StandardCharsets.UTF_8));

        Thread reader = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(proc.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    if (!lines.offer(line)) {
                        // 队列满说明没人消费（不该发生）；丢掉最旧的，保证协议不卡死
                        lines.poll();
                        lines.offer(line);
                    }
                }
            } catch (IOException ignored) {
            } finally {
                // 进程结束：投递一个哨兵，让等待中的请求立即失败而不是永远等
                lines.offer("");
            }
        }, "lct-worker-stdout");
        reader.setDaemon(true);
        reader.start();

        Thread err = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(proc.getErrorStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    synchronized (stderrTail) {
                        stderrTail.addLast(line);
                        while (stderrTail.size() > 200) stderrTail.removeFirst();
                    }
                }
            } catch (IOException ignored) {
            }
        }, "lct-worker-stderr");
        err.setDaemon(true);
        err.start();
    }

    public static WorkerClient start(File toolRoot) throws IOException {
        File worker = new File(toolRoot, "core" + File.separator + "worker.ps1");
        if (!worker.isFile()) throw new IOException("找不到 worker 脚本: " + worker.getAbsolutePath());
        String psExe = defaultPowerShell();
        ProcessBuilder pb = new ProcessBuilder(psExe,
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", worker.getAbsolutePath(),
                "-ToolRoot", toolRoot.getAbsolutePath());
        pb.directory(toolRoot);
        pb.redirectErrorStream(false);
        Process p = pb.start();
        WorkerClient c = new WorkerClient(p, toolRoot);
        try {
            c.ping(120_000);
        } catch (RuntimeException e) {
            c.close();
            throw new IOException("worker 启动失败：" + e.getMessage() + c.stderrHint(), e);
        }
        return c;
    }

    public static String defaultPowerShell() {
        String root = System.getenv("SystemRoot");
        if (root != null) {
            File f = new File(root, "System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (f.isFile()) return f.getAbsolutePath();
        }
        return "powershell.exe";
    }

    public File toolRoot() { return toolRoot; }

    public long startupMillis() { return System.currentTimeMillis() - startMillis; }

    public boolean isAlive() { return !closed && proc.isAlive(); }

    public String lastError() { return lastError; }

    public String stderrHint() {
        synchronized (stderrTail) {
            if (stderrTail.isEmpty()) return "";
            StringBuilder b = new StringBuilder("（worker stderr 末尾: ");
            int n = 0;
            for (String s : stderrTail) {
                if (n++ >= 5) break;
                b.append(s).append(" | ");
            }
            b.append("）");
            return b.toString();
        }
    }

    public void ping(long timeoutMs) {
        Map<String, Object> r = request("__ping", null, false, timeoutMs);
        if (r == null || !Boolean.TRUE.equals(r.get("pong"))) {
            throw new RuntimeException("ping 未得到 pong 回应");
        }
    }

    /** 同步请求（内部串行）。返回引擎 Result 的 Map；协议层失败抛 RuntimeException。 */
    public Map<String, Object> request(String verb, Map<String, Object> args, boolean apply, long timeoutMs) {
        synchronized (lock) {
            if (closed) throw new RuntimeException("worker 已关闭");
            if (!proc.isAlive()) {
                lastError = "worker 进程已退出";
                throw new RuntimeException(lastError + stderrHint());
            }
            Map<String, Object> req = new LinkedHashMap<>();
            req.put("verb", verb);
            if (args != null && !args.isEmpty()) req.put("args", args);
            if (apply) req.put("apply", Boolean.TRUE);
            String payload = Json.write(req);
            try {
                stdin.write(payload);
                stdin.write('\n');
                stdin.flush();
            } catch (IOException e) {
                lastError = "写入 worker 失败: " + e.getMessage();
                throw new RuntimeException(lastError, e);
            }
            lines.clear();
            String line = null;
            try {
                // 防御：worker 的 stdout 可能混入非 JSON 的杂散输出（例如 PowerShell 的提示），
                // 一律跳过并记进 stderr 尾巴，绝不因此把整个协议判死。
                long deadline = System.currentTimeMillis() + timeoutMs;
                while (true) {
                    long remain = deadline - System.currentTimeMillis();
                    if (remain <= 0) { line = null; break; }
                    String cand = lines.poll(remain, TimeUnit.MILLISECONDS);
                    if (cand == null) { line = null; break; }
                    String tt = cand.trim();
                    if (tt.isEmpty()) { continue; }
                    if (tt.startsWith("{")) { line = cand; break; }
                    synchronized (stderrTail) {
                        stderrTail.addLast("[stdout-noise] " + tt);
                        while (stderrTail.size() > 200) stderrTail.removeFirst();
                    }
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new RuntimeException("等待 worker 回应被中断", e);
            }
            if (line == null) {
                lastError = "等待 worker 回应超时（" + timeoutMs + "ms）";
                throw new RuntimeException(lastError);
            }
            if (line.isEmpty()) {
                lastError = "worker 没有回应就退出了";
                throw new RuntimeException(lastError + stderrHint());
            }
            try {
                return Json.parseObject(line);
            } catch (RuntimeException e) {
                lastError = "worker 回应不是合法 JSON: " + trim(line, 300) + " / " + e.getMessage();
                throw new RuntimeException(lastError, e);
            }
        }
    }

    public Map<String, Object> request(String verb, Map<String, Object> args, boolean apply) {
        return request(verb, args, apply, 180_000);
    }

    private static String trim(String s, int n) {
        if (s == null) return "";
        return s.length() <= n ? s : s.substring(0, n) + "…";
    }

    @Override
    public void close() {
        synchronized (lock) {
            if (closed) return;
            closed = true;
            try { stdin.close(); } catch (IOException ignored) { }
            try {
                if (!proc.waitFor(3, TimeUnit.SECONDS)) proc.destroy();
            } catch (InterruptedException e) {
                proc.destroy();
                Thread.currentThread().interrupt();
            }
            if (proc.isAlive()) proc.destroyForcibly();
        }
    }

    /** 便捷：把任意值转成 UI 文本（数组按行拼接）。 */
    public static String text(Object v) {
        if (v == null) return "";
        if (v instanceof List) {
            List<Object> l = Json.castList(v);
            if (l.isEmpty()) return "";
            StringBuilder b = new StringBuilder();
            for (Object o : l) b.append(text(o)).append('\n');
            return b.toString();
        }
        if (v instanceof Map) return Json.write(v);
        return String.valueOf(v);
    }

    public static List<Object> list(Object v) {
        if (v == null) return new ArrayList<>();
        if (v instanceof List) return Json.castList(v);
        List<Object> one = new ArrayList<>();
        one.add(v);
        return one;
    }
}
