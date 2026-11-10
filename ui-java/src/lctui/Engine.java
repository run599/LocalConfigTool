package lctui;

import javax.swing.SwingUtilities;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.BiConsumer;

/**
 * 引擎异步门面（② 异步 + 忙碌提示的基础）。
 *
 * 所有调用都丢到后台线程池，结果回调统一切回 Swing 的 EDT —— 界面永远不会被阻塞。
 * worker 本身是串行的，这里用 2 个线程排队足够（每条请求只要几毫秒）。
 */
public final class Engine implements AutoCloseable {

    private final WorkerClient worker;
    private final ExecutorService pool;

    public Engine(WorkerClient worker) {
        this.worker = worker;
        this.pool = Executors.newFixedThreadPool(2, r -> {
            Thread t = new Thread(r, "lct-engine");
            t.setDaemon(true);
            return t;
        });
    }

    public WorkerClient worker() { return worker; }

    public static final class Result {
        public final Map<String, Object> raw;
        public final boolean ok;
        public final boolean applied;
        public final String verb;
        public final Object data;
        public final List<String> errors;
        public final List<String> warnings;
        public final long workerMs;

        private Result(Map<String, Object> raw) {
            this.raw = raw;
            this.ok = Boolean.TRUE.equals(raw.get("ok"));
            this.applied = Boolean.TRUE.equals(raw.get("applied"));
            this.verb = raw.get("verb") == null ? "" : String.valueOf(raw.get("verb"));
            this.data = raw.get("data");
            this.errors = toStringList(raw.get("errors"));
            this.warnings = toStringList(raw.get("warnings"));
            long ms = 0;
            Object w = raw.get("workerMs");
            if (w instanceof Number) ms = ((Number) w).longValue();
            this.workerMs = ms;
        }

        public static Result of(Map<String, Object> raw) { return new Result(raw); }

        private static List<String> toStringList(Object v) {
            List<String> out = new ArrayList<>();
            for (Object o : WorkerClient.list(v)) if (o != null) out.add(String.valueOf(o));
            return out;
        }

        public String errorsText() { return String.join("\n", errors); }

        public String warningsText() { return String.join("\n", warnings); }

        public Map<String, Object> dataMap() {
            if (data instanceof Map) return Json.castMap(data);
            return new LinkedHashMap<>();
        }

        public List<Object> dataList() { return WorkerClient.list(data); }

        /** data.items（很多 verb 用 {items,count} 包装） */
        public List<Object> items() {
            Map<String, Object> d = dataMap();
            if (d.containsKey("items")) return WorkerClient.list(d.get("items"));
            if (data instanceof List) return Json.castList(data);
            return new ArrayList<>();
        }

        public String rawJson() { return Json.write(raw); }
    }

    public CompletableFuture<Result> call(String verb, Map<String, Object> args, boolean apply) {
        return CompletableFuture.supplyAsync(() -> {
            Map<String, Object> resp = worker.request(verb, args, apply);
            return Result.of(resp);
        }, pool);
    }

    /**
     * 异步调用并在 EDT 回调。done(result, errorText)：
     * 正常返回时 errorText 为 null；协议层/超时失败时 result 为 null、errorText 为原因。
     */
    public void callUi(String verb, Map<String, Object> args, boolean apply, BiConsumer<Result, String> done) {
        call(verb, args, apply).whenComplete((r, ex) -> SwingUtilities.invokeLater(() -> {
            if (ex != null) {
                Throwable cause = ex.getCause() == null ? ex : ex.getCause();
                done.accept(null, cause.getMessage() == null ? cause.toString() : cause.getMessage());
            } else {
                done.accept(r, null);
            }
        }));
    }

    @Override
    public void close() {
        pool.shutdownNow();
    }
}
