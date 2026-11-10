package lctui;

import javax.swing.BorderFactory;
import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JOptionPane;
import javax.swing.JPasswordField;
import javax.swing.JPanel;
import javax.swing.JProgressBar;
import javax.swing.JScrollPane;
import javax.swing.JSplitPane;
import javax.swing.JTable;
import javax.swing.JTextArea;
import javax.swing.JTextField;
import javax.swing.ListSelectionModel;
import javax.swing.SwingUtilities;
import javax.swing.UIManager;
import javax.swing.border.TitledBorder;
import javax.swing.table.AbstractTableModel;
import java.awt.BorderLayout;
import java.awt.CardLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.Font;
import java.awt.GridLayout;
import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * LocalConfigTool 的 Java(Swing) 界面。
 *
 * 四件事是本文件的核心（对应需求 ①②③④）：
 *   ① 常驻 worker：启动时后台拉起 core\worker.ps1，导入一次模块，之后每条请求 0~10ms（不再是 2.2 秒/次）
 *   ② 异步 + 忙碌提示：所有引擎调用走 Engine.callUi（后台线程池 → 结果回 EDT），界面永不冻结
 *   ③ 表格批量填充：ItemModel.setItems() 一次性 fireTableStructureChanged，不逐行 addRow
 *   ④ 按页懒构建：页面在第一次被选中时才创建（build* 只在 showPage 里调用一次）
 *
 * 本界面不含任何后端逻辑：所有动作都经 worker 调引擎 verb，字段名与 core/*.psm1 对齐。
 */
public final class Ui {

    private static final String[] KEYS = {"overview", "ai", "samples", "drivers", "profiles", "drivermap", "processes", "console"};
    private static final String[] TITLES = {"概览", "AI 助手", "样本库", "驱动加载", "驱动 Profile", "对象图映射", "进程", "通用控制台"};

    private Engine engine;
    private WorkerClient worker;
    private JFrame frame;
    private JList<String> nav;
    private final CardLayout cards = new CardLayout();
    private final JPanel cardPanel = new JPanel(cards);
    private final Map<String, JPanel> pages = new LinkedHashMap<>();
    private final JLabel status = new JLabel("worker 启动中…");
    private final JProgressBar busyBar = new JProgressBar();
    private final JLabel latency = new JLabel("");
    private long workerStartMs = -1L;
    private Map<String, Object> verbsInfo;

    public static void main(String[] args) {
        SwingUtilities.invokeLater(() -> new Ui().start());
    }

    // ==================== 启动 ====================

    private void start() {
        try { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()); } catch (Exception ignored) { }
        UIManager.put("Label.font", font(13, Font.PLAIN));
        UIManager.put("Button.font", font(13, Font.PLAIN));
        UIManager.put("Table.font", font(13, Font.PLAIN));
        UIManager.put("TableHeader.font", font(13, Font.BOLD));

        frame = new JFrame("LocalConfigTool · Java UI（常驻 worker · 异步 · 懒加载）");
        frame.setDefaultCloseOperation(JFrame.DO_NOTHING_ON_CLOSE);
        frame.addWindowListener(new java.awt.event.WindowAdapter() {
            @Override public void windowClosing(java.awt.event.WindowEvent e) {
                try { if (engine != null) engine.close(); } catch (Exception ignored) { }
                try { if (worker != null) worker.close(); } catch (Exception ignored) { }
                frame.dispose();
            }
        });
        frame.setSize(1300, 840);
        frame.setLocationRelativeTo(null);
        frame.setLayout(new BorderLayout());

        nav = new JList<>(TITLES);
        nav.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        nav.setFont(font(14, Font.PLAIN));
        nav.addListSelectionListener(e -> {
            if (e.getValueIsAdjusting()) return;
            int i = nav.getSelectedIndex();
            if (i >= 0) showPage(KEYS[i]);
        });
        JPanel west = new JPanel(new BorderLayout());
        JLabel brand = new JLabel(" LocalConfigTool");
        brand.setFont(font(15, Font.BOLD));
        brand.setBorder(BorderFactory.createEmptyBorder(12, 10, 10, 10));
        west.add(brand, BorderLayout.NORTH);
        west.add(new JScrollPane(nav), BorderLayout.CENTER);
        west.setPreferredSize(new Dimension(186, 0));
        frame.add(west, BorderLayout.WEST);
        frame.add(cardPanel, BorderLayout.CENTER);

        JPanel south = new JPanel(new BorderLayout(10, 0));
        south.setBorder(BorderFactory.createEmptyBorder(4, 10, 6, 10));
        busyBar.setIndeterminate(true);
        busyBar.setVisible(false);
        busyBar.setPreferredSize(new Dimension(150, 14));
        latency.setFont(font(12, Font.PLAIN));
        latency.setForeground(new Color(0x55, 0x55, 0x55));
        JPanel left = new JPanel(new FlowLayout(FlowLayout.LEFT, 8, 0));
        left.add(busyBar);
        left.add(status);
        south.add(left, BorderLayout.WEST);
        south.add(latency, BorderLayout.EAST);
        frame.add(south, BorderLayout.SOUTH);

        frame.setVisible(true);
        nav.setEnabled(false);

        // ① 后台启动常驻 worker：界面立刻可用，就绪后再点亮导航
        Thread boot = new Thread(() -> {
            try {
                long s = System.currentTimeMillis();
                WorkerClient w = WorkerClient.start(new File(".").getAbsoluteFile());
                long cost = System.currentTimeMillis() - s;
                Engine e = new Engine(w);
                SwingUtilities.invokeLater(() -> {
                    worker = w;
                    engine = e;
                    workerStartMs = cost;
                    busyBar.setVisible(false);
                    status.setText("worker 就绪（导入耗时 " + cost + " ms，之后每条请求 ~毫秒）");
                    nav.setEnabled(true);
                    nav.setSelectedIndex(0);
                });
            } catch (Exception ex) {
                SwingUtilities.invokeLater(() -> {
                    busyBar.setVisible(false);
                    status.setText("worker 启动失败");
                    JOptionPane.showMessageDialog(frame,
                            "无法启动常驻 worker：\n" + ex.getMessage()
                                    + "\n\n请确认 core\\worker.ps1 存在、powershell.exe 可用。",
                            "启动失败", JOptionPane.ERROR_MESSAGE);
                });
            }
        }, "lct-worker-boot");
        boot.setDaemon(true);
        boot.start();
    }

    // ==================== ④ 懒构建 + ② 忙碌态 ====================

    private void showPage(String key) {
        JPanel p = pages.get(key);
        if (p == null) {
            busy("构建页面：" + key + " …");
            try {
                p = build(key);
                pages.put(key, p);
                cardPanel.add(p, key);
            } catch (RuntimeException ex) {
                idle();
                JOptionPane.showMessageDialog(frame, "页面构建失败：" + ex, key, JOptionPane.ERROR_MESSAGE);
                return;
            }
            idle();
        }
        cards.show(cardPanel, key);
    }

    private JPanel build(String key) {
        switch (key) {
            case "overview": return buildOverview();
            case "ai": return buildAi();
            case "samples": return buildSamples();
            case "drivers": return buildDrivers();
            case "profiles": return buildProfiles();
            case "drivermap": return buildDriverMap();
            case "processes": return buildProcesses();
            case "console": return buildConsole();
            default: return new JPanel();
        }
    }

    // ==================== 页面：AI 助手（把一句话变成有序步骤并逐步执行） ====================
    //
    // 这一页就是"普通人只用 AI"的入口：
    //   ① 输入目标 → ai.plan（只读）→ 得到有序步骤 + 一次性确认短语
    //   ② 逐步执行：只读步骤直接跑；写步骤弹确认框，并把 plan 的短语交给 ai.run
    // 顺序（先提权、再加载驱动）由引擎的 plan 保证，界面不自己发明流程。
    private JPanel buildAi() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        final ItemModel model = new ItemModel();
        final JTable t = table(model, 150);
        final JTextArea out = area(true);
        final JTextField goal = field("用一句话说你要做什么，例如：提权到system然后加载我的驱动");
        // 模型服务配置：本地 Ollama / OpenAI 兼容（DeepSeek、Kimi、智谱…）/ Anthropic（Claude）/ 自定义
        // 密钥走 ai.cred（DPAPI 当前用户加密），不写进 Preferences、不进日志
        final java.util.prefs.Preferences prefs = java.util.prefs.Preferences.userNodeForPackage(Ui.class);
        final String[] PROV_LABELS = { "本地 Ollama", "OpenAI 兼容（DeepSeek/Kimi/智谱）", "Anthropic（Claude）", "自定义" };
        final String[] PROV_IDS = { "ollama", "openai", "anthropic", "custom" };
        final JComboBox<String> providerBox = new JComboBox<>(PROV_LABELS);
        final JTextField ollamaEp = field("服务地址，例如 https://api.deepseek.com/v1");
        final JTextField ollamaModel = field("模型名，例如 deepseek-chat");
        final JPasswordField keyField = new JPasswordField(16);
        keyField.setToolTipText("云端 API Key（本地 Ollama 不需要）；点「🔑 保存密钥」用 DPAPI 加密保存");
        ollamaEp.setColumns(22);
        ollamaModel.setColumns(12);
        ollamaEp.setText(prefs.get("ollama.endpoint", "http://127.0.0.1:11434"));
        ollamaModel.setText(prefs.get("ollama.model", "qwen2.5:7b"));
        String savedProv = prefs.get("ai.provider", "ollama");
        for (int pi = 0; pi < PROV_IDS.length; pi++) { if (PROV_IDS[pi].equals(savedProv)) { providerBox.setSelectedIndex(pi); break; } }
        // 注意：监听器最后加，避免初始化时把已保存的地址/模型覆盖成预设值
        providerBox.addActionListener(e -> {
            int si = providerBox.getSelectedIndex();
            prefs.put("ai.provider", PROV_IDS[si]);
            if (si == 0) { ollamaEp.setText("http://127.0.0.1:11434"); ollamaModel.setText("qwen2.5:7b"); }
            else if (si == 1) { ollamaEp.setText("https://api.deepseek.com/v1"); ollamaModel.setText("deepseek-chat"); }
            else if (si == 2) { ollamaEp.setText("https://api.anthropic.com"); ollamaModel.setText("claude-3-5-haiku-latest"); }
        });
        ollamaEp.getDocument().addDocumentListener(new javax.swing.event.DocumentListener() {
            public void insertUpdate(javax.swing.event.DocumentEvent e) { prefs.put("ollama.endpoint", ollamaEp.getText().trim()); }
            public void removeUpdate(javax.swing.event.DocumentEvent e) { prefs.put("ollama.endpoint", ollamaEp.getText().trim()); }
            public void changedUpdate(javax.swing.event.DocumentEvent e) { }
        });
        ollamaModel.getDocument().addDocumentListener(new javax.swing.event.DocumentListener() {
            public void insertUpdate(javax.swing.event.DocumentEvent e) { prefs.put("ollama.model", ollamaModel.getText().trim()); }
            public void removeUpdate(javax.swing.event.DocumentEvent e) { prefs.put("ollama.model", ollamaModel.getText().trim()); }
            public void changedUpdate(javax.swing.event.DocumentEvent e) { }
        });
        final java.util.List<Map<String, Object>> steps = new ArrayList<>();
        final int[] idx = {0};
        final String[] phrase = {""};
        final String[] phraseVerb = {""};

        JPanel top = card("AI 助手（ai.plan 出计划 → 逐步执行；顺序与前置条件由引擎保证）");
        top.add(row(goal,
                new JLabel("服务"), providerBox, ollamaEp, ollamaModel, keyField,
                btn("🔑 保存密钥", () -> {
                    String prov = PROV_IDS[providerBox.getSelectedIndex()];
                    String k = new String(keyField.getPassword()).trim();
                    if (k.isEmpty()) { out.setText("先把 API Key 填进密钥框（云端需要；本地 Ollama 不需要）"); return; }
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("action", "set");
                    a.put("provider", prov);
                    a.put("key", k);
                    run("ai.cred", a, true, r -> {
                        if (r.ok) {
                            out.setText("✅ 密钥已保存（DPAPI 当前用户加密，明文不落盘、不进日志）\n" + Json.write(r.dataMap()));
                            keyField.setText("");
                        } else {
                            out.setText("❌ 保存失败：" + r.errorsText());
                        }
                    });
                }),
                btn("🔌 测试连接", () -> {
                    String ep = ollamaEp.getText().trim();
                    String mdl = ollamaModel.getText().trim();
                    String prov = PROV_IDS[providerBox.getSelectedIndex()];
                    if (ep.isEmpty() || mdl.isEmpty()) { out.setText("先填服务地址和模型名"); return; }
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("text", "帮我看看现在什么权限");
                    a.put("endpoint", ep);
                    a.put("model", mdl);
                    if (!"custom".equals(prov)) a.put("provider", prov);
                    a.put("timeoutSec", 20);
                    out.setText("正在测试 " + ep + " …");
                    run("ai.translate", a, false, r -> {
                        if (r.ok) {
                            out.setText("✅ 连接正常（" + s(r.dataMap().get("provider")) + "，" + s(r.dataMap().get("ms")) + " ms）\n"
                                    + "模型把它理解成：" + s(r.dataMap().get("goal")));
                        } else {
                            out.setText("❌ 连接失败：\n  " + r.errorsText());
                        }
                    });
                }),
                btn("⚡ 一键完成（翻译+计划+执行）", () -> {
                    String raw = goal.getText().trim();
                    if (raw.isEmpty()) { out.setText("先写一句话（大白话就行，例如：把 rtcore64 挂上去读一下内核头）"); return; }
                    String ep = ollamaEp.getText().trim();
                    String mdl = ollamaModel.getText().trim();
                    String prov = PROV_IDS[providerBox.getSelectedIndex()];
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("text", raw);
                    if (!ep.isEmpty() && !mdl.isEmpty()) {
                        a.put("endpoint", ep);
                        a.put("model", mdl);
                        if (!"custom".equals(prov)) a.put("provider", prov);
                        a.put("timeoutSec", 60);
                    }
                    out.setText("正在理解你的话…");
                    run("ai.auto", a, false, r0 -> {
                        Map<String, Object> d0 = r0.dataMap();
                        StringBuilder b = new StringBuilder();
                        b.append("原话：").append(raw).append('\n');
                        b.append("理解成：").append(s(d0.get("goal"))).append('\n');
                        b.append("（模型翻译：").append(Boolean.TRUE.equals(d0.get("translated")) ? "用了" : "没用/失败").append("）\n\n");
                        int cnt = 0;
                        for (Object o : WorkerClient.list(d0.get("plan"))) {
                            Map<String, Object> m = Json.castMap(o);
                            cnt++;
                            b.append(String.format("  %s. %-20s %s%n", s(m.get("n")), s(m.get("verb")),
                                    Boolean.TRUE.equals(m.get("mutating")) ? "[写]" : "[读]"));
                        }
                        if (cnt == 0) { out.setText(b.toString() + "\n（没识别出可执行步骤，换个说法再试）"); return; }
                        String ph = s(d0.get("confirmPhrase"));
                        int yes = JOptionPane.showConfirmDialog(frame,
                                b.toString() + "\n确认短语：" + ph + "\n\n现在执行吗？（标 [写] 的会真的发生）",
                                "人确认：一键完成", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                        if (yes != JOptionPane.YES_OPTION) { out.setText(b.toString() + "\n（已取消，未执行任何动作）"); return; }
                        Map<String, Object> a2 = new LinkedHashMap<>(a);
                        a2.put("apply", Boolean.TRUE);
                        a2.put("confirm", ph);
                        run("ai.auto", a2, false, r2 -> {
                            Map<String, Object> d2 = r2.dataMap();
                            StringBuilder rb = new StringBuilder();
                            rb.append("执行结果（").append(s(d2.get("goal"))).append("）\n\n");
                            for (Object o : WorkerClient.list(d2.get("results"))) {
                                Map<String, Object> m = Json.castMap(o);
                                rb.append(String.format("  %s. %-20s ok=%s%n", s(m.get("n")), s(m.get("verb")), s(m.get("ok"))));
                            }
                            if (!r2.errors.isEmpty()) rb.append("\n错误：\n  ").append(String.join("\n  ", r2.errors)).append('\n');
                            out.setText(rb.toString());
                            out.setCaretPosition(out.getDocument().getLength());
                        });
                    });
                }),
                btn("☁ 翻译成目标（让 Ollama 把大白话变成目标）", () -> {
                    String raw = goal.getText().trim();
                    if (raw.isEmpty()) { out.setText("先在上面写一句话（大白话就行，例如：把 rtcore64 挂上去读一下内核头）"); return; }
                    String ep = ollamaEp.getText().trim();
                    if (ep.isEmpty()) { out.setText("先填 Ollama 地址（本机 http://127.0.0.1:11434，或局域网机器）"); return; }
                    Map<String, Object> tr = new LinkedHashMap<>();
                    tr.put("text", raw);
                    tr.put("endpoint", ep);
                    tr.put("model", ollamaModel.getText().trim());
                    tr.put("timeoutSec", 60);
                    out.setText("正在让 Ollama 翻译…\n原话：" + raw);
                    run("ai.translate", tr, false, r -> {
                        StringBuilder b = new StringBuilder();
                        b.append("原话：").append(raw).append("\n\n");
                        if (r.ok) {
                            String g = s(r.dataMap().get("goal"));
                            b.append("我理解成：").append(g).append("\n\n");
                            b.append("（已回填到上面的输入框，接着点「★ 一键跑完」）\n");
                            if (!g.isEmpty()) goal.setText(g);
                        } else {
                            b.append("翻译失败：").append(r.errorsText()).append("\n\n");
                            b.append("可以：① 检查 Ollama 是否在跑（浏览器打开 ").append(ep).append(" 试试）\n");
                            b.append("        ② 或直接把它改写成工具认的写法（提权 / 加载驱动 / 读内核 / 清理）\n");
                        }
                        out.setText(b.toString());
                        out.setCaretPosition(0);
                    });
                }),
                btn("① 生成计划（ai.plan，只读）", () -> {
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("goal", goal.getText().trim());
                    run("ai.plan", a, false, r -> {
                        Map<String, Object> d = r.dataMap();
                        steps.clear();
                        idx[0] = 0;
                        for (Object o : WorkerClient.list(d.get("steps"))) if (o instanceof Map) steps.add(Json.castMap(o));
                        model.setItems(WorkerClient.list(d.get("steps")));
                        autoWidth(t);
                        phrase[0] = s(d.get("confirmPhrase"));
                        phraseVerb[0] = "";
                        if (d.get("confirmFor") instanceof Map) phraseVerb[0] = s(Json.castMap(d.get("confirmFor")).get("verb"));
                        StringBuilder b = new StringBuilder();
                        b.append("目标：").append(s(d.get("goal"))).append('\n');
                        b.append("当前：").append(Boolean.TRUE.equals(d.get("isAdmin")) ? "管理员" : "普通用户").append("（").append(s(d.get("integrityLevel"))).append("）\n");
                        b.append("步骤数：").append(s(d.get("stepCount"))).append('\n');
                        for (Map<String, Object> st : steps) {
                            b.append(String.format("  %s. %-20s %s %s %s%n", s(st.get("n")), s(st.get("verb")),
                                    Boolean.TRUE.equals(st.get("mutating")) ? "[写]" : "[读]",
                                    "need=" + s(st.get("needsElevation")),
                                    s(st.get("blockedNow")).isEmpty() ? "" : "⛔ " + s(st.get("blockedNow"))));
                            b.append("       ").append(s(st.get("why"))).append('\n');
                        }
                        b.append('\n').append("确认短语（写步骤要用）：").append(phrase[0].isEmpty() ? "（无需）" : phrase[0] + " ← 给 " + phraseVerb[0]).append('\n');
                        for (Object n : WorkerClient.list(d.get("notes"))) b.append("· ").append(s(n)).append('\n');
                        out.setText(b.toString());
                        out.setCaretPosition(0);
                    });
                }),
                btn("② 执行下一步", () -> {
                    if (steps.isEmpty()) { out.append("\n（还没有计划：先点①）\n"); return; }
                    if (idx[0] >= steps.size()) { out.append("\n（计划已执行完）\n"); return; }
                    Map<String, Object> st = steps.get(idx[0]);
                    String verb = s(st.get("verb"));
                    boolean mut = Boolean.TRUE.equals(st.get("mutating"));
                    String blocked = s(st.get("blockedNow"));
                    if (!blocked.isEmpty()) { JOptionPane.showMessageDialog(frame, "这一步现在被阻：\n" + blocked, verb, JOptionPane.WARNING_MESSAGE); return; }
                    Map<String, Object> args = new LinkedHashMap<>();
                    if (st.get("args") instanceof Map) for (Map.Entry<String, Object> e : Json.castMap(st.get("args")).entrySet()) args.put(e.getKey(), e.getValue());
                    if (mut) {
                        String confirm = verb.equals(phraseVerb[0]) ? phrase[0] : "";
                        if (confirm.isEmpty()) { JOptionPane.showMessageDialog(frame, "没有该步骤的确认短语：请重新点①生成计划。", verb, JOptionPane.WARNING_MESSAGE); return; }
                        int yes = JOptionPane.showConfirmDialog(frame,
                                "即将执行写操作（第 " + (idx[0] + 1) + "/" + steps.size() + " 步）：\n  " + verb
                                        + "\n  args=" + Json.write(args) + "\n\n确认短语：" + confirm,
                                "人确认：执行 " + verb, JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                        if (yes != JOptionPane.YES_OPTION) return;

                        Map<String, Object> call = new LinkedHashMap<>();
                        call.put("verb", verb);
                        call.put("args", args);
                        call.put("apply", Boolean.TRUE);
                        call.put("confirm", confirm);
                        run("ai.run", call, true, r -> {
                            out.append("\n─── 第 " + (idx[0] + 1) + " 步 " + verb + " ───\n");
                            out.append("ok=" + r.ok + " applied=" + r.applied + "\n");
                            if (!r.errors.isEmpty()) out.append("errors: " + String.join(" / ", r.errors) + "\n");
                            out.append(Json.write(r.data) + "\n");
                            out.setCaretPosition(out.getDocument().getLength());
                            idx[0]++;
                        });
                    } else {
                        Map<String, Object> call = new LinkedHashMap<>();
                        call.put("verb", verb);
                        call.put("args", args);
                        run("ai.run", call, false, r -> {
                            out.append("\n─── 第 " + (idx[0] + 1) + " 步 " + verb + "（只读）───\n");
                            out.append("ok=" + r.ok + "\n" + Json.write(r.data) + "\n");
                            out.setCaretPosition(out.getDocument().getLength());
                            idx[0]++;
                        });
                    }
                }),
                btn("③ 能力清单（ai.manifest）", () -> run("ai.manifest", null, false, r -> {
                    Map<String, Object> d = r.dataMap();
                    StringBuilder b = new StringBuilder();
                    b.append("verb 总数：").append(s(d.get("context") instanceof Map ? Json.castMap(d.get("context")).get("verbCount") : "")).append('\n');
                    b.append("预置流程：\n");
                    for (Object f : WorkerClient.list(d.get("flows"))) {
                        if (f instanceof Map) {
                            Map<String, Object> fm = Json.castMap(f);
                            b.append("  · ").append(s(fm.get("title"))).append("  (").append(s(fm.get("id"))).append(")\n");
                        }
                    }
                    b.append("\n安全规则：\n");
                    for (Object rr : WorkerClient.list(d.get("rules"))) b.append("  - ").append(s(rr)).append('\n');
                    out.setText(b.toString());
                    out.setCaretPosition(0);
                  })),
          
                  btn("★ 一键跑完（ai.do：一句话 → 执行 → 清理）", () -> {
                      Map<String, Object> a0 = new LinkedHashMap<>();
                      a0.put("goal", goal.getText().trim());
                      if (s(a0.get("goal")).isEmpty()) { out.setText("先在上面写一句话目标（例：加载 rtcore64 读内核头，最后清理）"); return; }
                      run("ai.do", a0, false, r0 -> {
                          Map<String, Object> d0 = r0.dataMap();
                          StringBuilder b = new StringBuilder();
                          b.append("目标：").append(s(d0.get("goal"))).append('\n');
                          b.append("当前：").append(Boolean.TRUE.equals(d0.get("isAdmin")) ? "管理员" : "普通用户").append('\n');
                          b.append("步骤：").append(s(d0.get("stepCount"))).append("（其中写操作 ").append(s(d0.get("mutatingCount"))).append(" 个）\n\n");
                          for (Object o : WorkerClient.list(d0.get("steps"))) {
                              Map<String, Object> m = Json.castMap(o);
                              b.append(String.format("  %s. %-20s %s%n", s(m.get("n")), s(m.get("verb")),
                                      Boolean.TRUE.equals(m.get("mutating")) ? "[写]" : "[读]"));
                              String ag = Json.write(m.get("args"));
                              if (!ag.isEmpty() && !"null".equals(ag)) b.append("       ").append(ag).append('\n');
                          }
                          String phraseDo = s(d0.get("confirmPhrase"));
                          boolean hasMut = !"0".equals(s(d0.get("mutatingCount")));
                          if (!hasMut) {
                              Map<String, Object> a1 = new LinkedHashMap<>();
                              a1.put("goal", a0.get("goal"));
                              a1.put("apply", Boolean.TRUE);
                              out.setText(b.toString() + "\n（没有写操作，直接执行…）\n");
                              run("ai.do", a1, false, r1 -> out.setText(b.toString() + "\n\n" + Json.write(r1.dataMap())));
                              return;
                          }
                          b.append("\n确认短语：").append(phraseDo);
                          int yes = JOptionPane.showConfirmDialog(frame,
                                  b.toString() + "\n\n现在执行吗？（标 [写] 的步骤会真的发生）",
                                  "人确认：一键执行", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                          if (yes != JOptionPane.YES_OPTION) { out.setText(b.toString() + "\n\n（已取消，未执行任何动作）"); return; }
                          Map<String, Object> a2 = new LinkedHashMap<>();
                          a2.put("goal", a0.get("goal"));
                          a2.put("apply", Boolean.TRUE);
                          a2.put("confirm", phraseDo);
                          out.setText(b.toString() + "\n\n执行中…");
                          run("ai.do", a2, false, r2 -> {
                              Map<String, Object> d2 = r2.dataMap();
                              StringBuilder rb = new StringBuilder();
                              rb.append("执行结果：成功 ").append(s(d2.get("okCount"))).append("/").append(s(d2.get("stepCount"))).append('\n');
                              rb.append("（上面的确认短语已消耗，一次性）\n\n");
                              for (Object o : WorkerClient.list(d2.get("results"))) {
                                  Map<String, Object> m = Json.castMap(o);
                                  rb.append(String.format("  %s. %-20s ok=%s%s%n", s(m.get("n")), s(m.get("verb")), s(m.get("ok")),
                                          Boolean.TRUE.equals(m.get("skipped")) ? " (跳过: " + s(m.get("reason")) + ")" : ""));
                              }
                              if (!r2.errors.isEmpty()) rb.append("\n错误：\n  ").append(String.join("\n  ", r2.errors)).append('\n');
                              Object cObj = d2.get("context");
                              if (cObj instanceof java.util.Map) {
                                  Map<String, Object> c = Json.castMap(cObj);
                                  rb.append("\n样本=").append(s(c.get("sampleId"))).append("   服务=").append(s(c.get("serviceName"))).append('\n');
                              }
                              out.setText(rb.toString());
                              out.setCaretPosition(out.getDocument().getLength());
                          });
                      });
                  })
          ), BorderLayout.NORTH);

          page.add(top, BorderLayout.NORTH);
        JSplitPane sp = new JSplitPane(JSplitPane.VERTICAL_SPLIT, scroll(t), scroll(out));
        sp.setResizeWeight(0.32);
        page.add(sp, BorderLayout.CENTER);
        return page;
    }

    private void busy(String msg) {
        busyBar.setVisible(true);
        status.setText(msg);
    }

    private void idle() {
        busyBar.setVisible(false);
        status.setText("就绪");
    }

    /** ② 异步调用：后台执行 → 结果回 EDT。界面在任何时刻都可交互。 */
    private void run(String verb, Map<String, Object> args, boolean apply, Consumer<Engine.Result> onOk) {
        if (engine == null) {
            status.setText("worker 还没就绪，请稍候");
            return;
        }
        busy("执行 " + verb + (apply ? " -Apply" : "（预览）") + " …");
        engine.callUi(verb, args, apply, (r, err) -> {
            idle();
            if (err != null) {
                status.setText(verb + " 失败：" + err);
                JOptionPane.showMessageDialog(frame, err, verb + " 调用失败", JOptionPane.ERROR_MESSAGE);
                return;
            }
            latency.setText("上次：" + verb + " 引擎内 " + r.workerMs + " ms");
            onOk.accept(r);
        });
    }

    // ==================== 通用控件 ====================

    private static Font font(int size, int style) {
        return new Font("Microsoft YaHei UI", style, size);
    }

    private static Font monoFont(int size) {
        // 实测（FontProbe）：Consolas / Cascadia Mono / Cascadia Code 的 canDisplayUpTo("共") = 0，
        // 它们没有 CJK 字形，中文会显示成 ?；而逻辑字体 Monospaced 自带回退链，
        // 中文和 ✔✖→ 都能画（canDisplayUpTo = -1）。所以等宽区域一律用 Monospaced。
        Font mono = new Font(Font.MONOSPACED, Font.PLAIN, size);
        if (mono.canDisplayUpTo("共条驱动服务（引擎内）✔✖→") >= 0) {
            Font yh = font(size, Font.PLAIN);
            if (yh.canDisplayUpTo("共条驱动服务") < 0) return yh;   // 极端兜底：宁可不等宽也要能读中文
        }
        return mono;
    }

    private JPanel card(String title) {
        JPanel p = new JPanel(new BorderLayout(6, 6));
        p.setBorder(BorderFactory.createTitledBorder(null, title, TitledBorder.LEFT, TitledBorder.TOP, font(13, Font.BOLD)));
        p.setBorder(BorderFactory.createCompoundBorder(BorderFactory.createEmptyBorder(4, 6, 6, 6), p.getBorder()));
        return p;
    }

    private JButton btn(String text, Runnable on) {
        JButton b = new JButton(text);
        b.setFont(font(13, Font.PLAIN));
        b.addActionListener(e -> on.run());
        return b;
    }

    private JTextField field(String tip) {
        JTextField f = new JTextField();
        f.setToolTipText(tip);
        f.setFont(font(13, Font.PLAIN));
        return f;
    }

    private JTextArea area(boolean mono) {
        JTextArea a = new JTextArea();
        a.setEditable(false);
        a.setFont(mono ? monoFont(12) : font(13, Font.PLAIN));
        a.setLineWrap(false);
        return a;
    }

    private JPanel row(JComponent... cs) {
        JPanel p = new JPanel(new FlowLayout(FlowLayout.LEFT, 6, 2));
        for (JComponent c : cs) p.add(c);
        return p;
    }

    private JScrollPane scroll(java.awt.Component c) { return new JScrollPane(c); }

    /** ③ 批量填充的表格模型：一次 setItems 完成，不逐行 addRow。 */
    static final class ItemModel extends AbstractTableModel {
        private List<Map<String, Object>> items = new ArrayList<>();
        private String[] cols = new String[0];

        void setItems(List<Object> raw) {
            List<Map<String, Object>> next = new ArrayList<>();
            if (raw != null) {
                for (Object o : raw) if (o instanceof Map) next.add(Json.castMap(o));
            }
            LinkedHashSet<String> keys = new LinkedHashSet<>();
            if (!next.isEmpty()) {
                for (Map.Entry<String, Object> en : next.get(0).entrySet()) {
                    Object v = en.getValue();
                    if (v instanceof Map || v instanceof List) continue;
                    keys.add(en.getKey());
                }
            }
            items = next;
            cols = keys.toArray(new String[0]);
            fireTableStructureChanged();   // 一次刷新，批量生效
        }

        Map<String, Object> item(int row) {
            return (row >= 0 && row < items.size()) ? items.get(row) : null;
        }

        int count() { return items.size(); }

        @Override public int getRowCount() { return items.size(); }
        @Override public int getColumnCount() { return cols.length; }
        @Override public String getColumnName(int c) { return label(cols[c]); }

        @Override public Object getValueAt(int r, int c) {
            Object v = items.get(r).get(cols[c]);
            if (v == null) return "";
            if (v instanceof Map || v instanceof List) return Json.write(v);
            return v;
        }

        private static String label(String key) {
            switch (key) {
                case "name": return "名称";
                case "state": return "状态";
                case "startMode": return "启动类型";
                case "signatureClass": return "签名";
                case "sha256": return "SHA256(前16)";
                case "path": return "路径";
                case "id": return "id";
                case "targetFileName": return "目标 .sys";
                case "riskLevel": return "风险";
                case "source": return "来源";
                case "actionCount": return "动作数";
                case "valid": return "schema";
                case "problem": return "备注";
                case "device": return "设备对象";
                case "driverObject": return "驱动对象";
                case "serviceName": return "服务";
                case "confidence": return "置信度";
                case "serviceVerified": return "服务已核验";
                case "pid": return "PID";
                case "processName": return "进程";
                case "workingSetMB": return "内存MB";
                case "cpuSeconds": return "CPU秒";
                case "pathName": return "镜像路径";
                case "stateText": return "状态";
                case "conclusion": return "结论";
                default: return key;
            }
        }
    }

    private JTable table(ItemModel m, int width) {
        JTable t = new JTable(m);
        t.setAutoResizeMode(JTable.AUTO_RESIZE_OFF);
        t.setRowHeight(22);
        t.setFont(font(13, Font.PLAIN));
        t.getTableHeader().setFont(font(13, Font.BOLD));
        return t;
    }

    private void autoWidth(JTable t) {
        for (int i = 0; i < t.getColumnCount(); i++) {
            javax.swing.table.TableColumn c = t.getColumnModel().getColumn(i);
            int w = 120;
            String n = c.getHeaderValue() == null ? "" : c.getHeaderValue().toString();
            if (n.contains("SHA256")) w = 150;
            else if (n.contains("路径") || n.contains("设备") || n.contains("驱动")) w = 260;
            c.setPreferredWidth(w);
        }
    }

    // ==================== 页面：概览 ====================

    private JPanel buildOverview() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        JPanel top = card("运行时");
        JLabel info = new JLabel();
        info.setFont(monoFont(12));
        top.add(info, BorderLayout.NORTH);
        JTextArea out = area(true);
        page.add(top, BorderLayout.NORTH);
        page.add(scroll(out), BorderLayout.CENTER);
        JPanel tools = row(
                btn("刷新能力表（engine.verbs）", () -> run("engine.verbs", null, false, r -> {
                    verbsInfo = r.dataMap();
                    Map<String, Object> d = r.dataMap();
                    Object avail = d.get("availability");
                    List<Object> verbs = WorkerClient.list(d.get("verbs"));
                    StringBuilder b = new StringBuilder();
                    b.append("toolRoot   = ").append(d.get("toolRoot")).append('\n');
                    b.append("varDir     = ").append(d.get("varDir")).append('\n');
                    b.append("elevated   = ").append(d.get("elevated")).append('\n');
                    b.append("verb 总数  = ").append(verbs.size()).append('\n');
                    b.append("worker 导入= ").append(workerStartMs).append(" ms（之后每条请求毫秒级）\n\n");
                    b.append("availability = ").append(Json.write(avail)).append("\n\n");
                    Map<String, Object> am = avail instanceof Map ? Json.castMap(avail) : new LinkedHashMap<>();
                    for (Map.Entry<String, Object> e : am.entrySet()) {
                        if (!Boolean.TRUE.equals(e.getValue())) b.append("  ✖ 模块未就绪: ").append(e.getKey()).append('\n');
                    }
                    Object loadErrors = d.get("loadErrors");
                    if (loadErrors != null && !Json.write(loadErrors).equals("[]")) {
                        b.append("\nloadErrors = ").append(Json.write(loadErrors)).append('\n');
                    }
                    b.append("\n—— verb 清单 ——\n");
                    for (Object v : verbs) {
                        if (v instanceof Map) {
                            Map<String, Object> vm = Json.castMap(v);
                            b.append(String.format("  %-26s %s %s%n", vm.get("verb"),
                                    Boolean.TRUE.equals(vm.get("mutating")) ? "[写]" : "[读]", vm.get("summary")));
                        } else b.append("  ").append(v).append('\n');
                    }
                    out.setText(b.toString());
                    out.setCaretPosition(0);
                    info.setText("worker 启动 " + workerStartMs + " ms · verb " + verbs.size() + " 个 · 常驻进程已复用");
                })));
        page.add(tools, BorderLayout.SOUTH);
        return page;
    }


    // ==================== 页面：样本库（预置规则 + 一键获取） ====================
    // 仓库里只有规则（URL/哈希/风险），载荷按需获取并强制校验 SHA256；文件只落在 var\samples\。
    private JPanel buildSamples() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        final ItemModel model = new ItemModel();
        final JTable t = table(model, 150);
        final JTextArea out = area(true);
        final JLabel tip = new JLabel("仓库里只有规则（URL / SHA256 / 风险），载荷按需获取且强制校验哈希；文件落在 var\\samples\\");
        tip.setFont(font(12, Font.PLAIN));
        tip.setForeground(new Color(0x55, 0x55, 0x55));
        JPanel top = card("样本库（samples.list / samples.get：获取必须过 SHA256 门，不符直接丢弃）");
        top.add(tip, BorderLayout.NORTH);
        top.add(row(
                btn("① 刷新目录（samples.list）", () -> run("samples.list", null, false, r -> {
                    model.setItems(r.items());
                    autoWidth(t);
                    Map<String, Object> d = r.dataMap();
                    out.setText("目录 " + s(d.get("count")) + " 条 · 可用 " + s(d.get("usable")) + " 条 · 已获取 " + s(d.get("fetched")) + " 条\n存储目录：" + s(d.get("storeDir")) + "\n\n");
                    for (Object n : WorkerClient.list(d.get("notes"))) out.append("· " + s(n) + "\n");
                    out.setCaretPosition(0);
                })),
                btn("② 预览（不下载）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    if (it == null) { out.setText("请先选中一行"); return; }
                    run("samples.get", one("id", s(it.get("id"))), false, r ->
                            out.setText("预览（applied=" + r.applied + "，未下载任何东西）\n\n" + Json.write(r.dataMap())));
                }),
                btn("③ 获取并校验（下载 + 哈希门）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    if (it == null) { out.setText("请先选中一行"); return; }
                    if (!Boolean.TRUE.equals(it.get("usable"))) {
                        JOptionPane.showMessageDialog(frame, "这一条不可用：" + s(it.get("blockedBy")), "样本库", JOptionPane.WARNING_MESSAGE);
                        return;
                    }
                    int yes = JOptionPane.showConfirmDialog(frame,
                            "即将下载：\n  " + s(it.get("name")) + "\n  " + s(it.get("url"))
                                    + "\n\n下载后会强制校验 SHA256，不符会直接丢弃。继续？",
                            "二次确认：获取样本", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                    if (yes != JOptionPane.YES_OPTION) return;
                    run("samples.get", one("id", s(it.get("id"))), true, r -> {
                        StringBuilder b = new StringBuilder();
                        b.append("applied=").append(r.applied).append('\n');
                        if (!r.errors.isEmpty()) b.append("errors:\n  ").append(String.join("\n  ", r.errors)).append('\n');
                        b.append('\n').append(Json.write(r.dataMap()));
                        out.setText(b.toString());
                        if (r.ok) run("samples.list", null, false, rr -> { model.setItems(rr.items()); autoWidth(t); });
                    });
                }),
                btn("④ 生成 profile（driver.profile.draft）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    if (it == null) { out.setText("请先选中一行"); return; }
                    String p = s(it.get("path"));
                    if (p.isEmpty() || !s(it.get("fetched")).isEmpty() && !Boolean.TRUE.equals(it.get("fetched"))) { out.setText("先获取样本（③）再生成 profile"); return; }
                    run("driver.profile.draft", one("path", p), false, r -> {
                        Map<String, Object> d = r.dataMap();
                        out.setText("confidence=" + s(d.get("confidence")) + "  needsReview=" + s(d.get("needsReview"))
                                + "\n（草案 actions 为空、不可直接执行；要发 IOCTL 必须人工审定后 driver.profile.save）\n\n" + Json.write(d));
                    });
                })
        ), BorderLayout.CENTER);
        page.add(top, BorderLayout.NORTH);
        JSplitPane sp = new JSplitPane(JSplitPane.VERTICAL_SPLIT, scroll(t), scroll(out));
        sp.setResizeWeight(0.6);
        page.add(sp, BorderLayout.CENTER);
        return page;
    }

    // ==================== 页面：驱动加载 ====================

    private JPanel buildDrivers() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        ItemModel model = new ItemModel();
        JTable t = table(model, 150);
        JTextArea detail = area(true);

        // ---- 权限横幅：两条路线的前置条件不同，这里必须在用户动手之前说清楚 ----
        // 路线「提权」从普通用户起步；路线「加载驱动」起点就要求管理员 ⇒ 未提权时驱动写操作必然失败。
        final JLabel banner = new JLabel("权限：读取中…");
        banner.setFont(font(13, Font.BOLD));
        banner.setBorder(BorderFactory.createEmptyBorder(6, 8, 6, 8));
        final Runnable refreshPriv = () -> run("capability.status", null, false, r -> {
            Map<String, Object> d = r.dataMap();
            boolean admin = Boolean.TRUE.equals(d.get("isAdmin"));
            String integ = s(d.get("integrityLevel"));
            String who = s(d.get("user"));
            if (admin) {
                banner.setForeground(new Color(0x1B, 0x5E, 0x20));
                banner.setText("权限：" + who + " · 管理员（完整性 " + integ + "）· 可以加载驱动");
            } else {
                banner.setForeground(new Color(0xB7, 0x1C, 0x1C));
                banner.setText("权限：" + who + " · 普通用户（完整性 " + integ + "）· 不能加载驱动 —— 请先提权（顺序见下）");
                Map<String, Object> prq = d.get("prerequisite") instanceof Map ? Json.castMap(d.get("prerequisite")) : new LinkedHashMap<>();
                detail.setText("【前置条件未满足】\n" + s(prq.get("hint")));
            }
        });

        JPanel top = card("驱动服务（driver.list · 只读取服务注册信息；不加载、不改系统）");
        top.add(banner, BorderLayout.NORTH);
        top.add(row(
                btn("① 驱动状态（driver.status）", () -> run("driver.status", null, false, r ->
                        detail.setText(Json.write(r.dataMap())))),
                btn("② 刷新列表（driver.list）", () -> run("driver.list", null, false, r -> {
                    model.setItems(r.items());
                    autoWidth(t);
                    detail.setText("共 " + model.count() + " 条驱动服务（引擎内 " + r.workerMs + " ms）");
                })),
                btn("③ 选中行详情", () -> {
                    int row = t.getSelectedRow();
                    Map<String, Object> it = model.item(row);
                    detail.setText(it == null ? "请先选中一行" : Json.write(it));
                }),
                btn("④ 刷新权限（capability.status）", refreshPriv)
        ), BorderLayout.CENTER);
        page.add(top, BorderLayout.NORTH);

        // ---- 加载驱动（写操作：预览 → 二次确认 → 应用）；未提权时引擎会拦住并给出顺序指引 ----
        JPanel loadCard = card("加载驱动（driver.load：预览不落盘；应用需要管理员/SYSTEM）");
        JTextField path = field("要加载的 .sys 完整路径，例如 C:\\Windows\\System32\\drivers\\disk.sys");
        JTextField svc = field("服务名（自定义，如 lcttest01）");
        javax.swing.JComboBox<String> startType = new javax.swing.JComboBox<>(new String[]{"demand", "system", "boot", "auto"});
        loadCard.add(row(path, svc, startType,
                btn("① 预览（driver.load）", () -> {
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("path", path.getText().trim());
                    if (!svc.getText().trim().isEmpty()) a.put("name", svc.getText().trim());
                    a.put("startType", String.valueOf(startType.getSelectedItem()));
                    run("driver.load", a, false, r -> detail.setText("预览（applied=" + r.applied + "）\n\n" + Json.write(r.dataMap())));
                }),
                btn("② 应用：加载（二次确认）", () -> {
                    if (path.getText().trim().isEmpty()) { detail.setText("请填 .sys 路径"); return; }
                    int yes = JOptionPane.showConfirmDialog(frame,
                            "即将注册并启动内核驱动服务：\n  路径=" + path.getText().trim()
                                    + "\n  服务名=" + (svc.getText().trim().isEmpty() ? "(自动)" : svc.getText().trim())
                                    + "\n  startType=" + startType.getSelectedItem()
                                    + "\n\n未签名/无效镜像会被系统拒绝（原文会回传）；加载后请及时用 driver.unload 清理。",
                            "二次确认：加载驱动", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                    if (yes != JOptionPane.YES_OPTION) return;
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("path", path.getText().trim());
                    if (!svc.getText().trim().isEmpty()) a.put("name", svc.getText().trim());
                    a.put("startType", String.valueOf(startType.getSelectedItem()));
                    run("driver.load", a, true, r -> {
                        StringBuilder b = new StringBuilder();
                        b.append("ok=").append(r.ok).append("  applied=").append(r.applied).append('\n');
                        Map<String, Object> d = r.dataMap();
                        Object v = d.get("verdict");
                        if (v instanceof Map) {
                            Map<String, Object> vm = Json.castMap(v);
                            b.append("系统判定：exitCode=").append(s(vm.get("exitCode")))
                                    .append("  systemAccepted=").append(s(vm.get("systemAccepted"))).append('\n');
                        }
                        if (!r.errors.isEmpty()) b.append("\nerrors:\n  ").append(String.join("\n  ", r.errors));
                        b.append("\n\n").append(Json.write(d));
                        detail.setText(b.toString());
                        // 未提权失败 ⇒ 这正是用户要的那个"提醒"
                        if (!r.ok) {
                            String all = String.join("\n", r.errors);
                            if (all.contains("提权")) {
                                JOptionPane.showMessageDialog(frame,
                                        "现在不能加载驱动：当前进程没有管理员/SYSTEM 权限。\n\n" + all,
                                        "需要先提权（顺序不能反）", JOptionPane.WARNING_MESSAGE);
                            }
                        }
                    });
                })
        ), BorderLayout.CENTER);
        page.add(loadCard, BorderLayout.SOUTH);

        JSplitPane sp = new JSplitPane(JSplitPane.VERTICAL_SPLIT, scroll(t), scroll(detail));
        sp.setResizeWeight(0.66);
        page.add(sp, BorderLayout.CENTER);

        // ④ 懒加载：页面建好后再拉一次权限（异步，不阻塞）
        SwingUtilities.invokeLater(refreshPriv);
        return page;
    }

    // ==================== 页面：驱动 Profile ====================

    private JPanel buildProfiles() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        ItemModel model = new ItemModel();
        JTable t = table(model, 150);
        JTextArea out = area(true);
        JTextField sysPath = field("可留空；填了 .sys 就做指纹比对（如 C:\\Windows\\System32\\drivers\\disk.sys）");
        JTextField service = field("服务名（driver.devices 用，如 disk / lctrtc64）");
        JTextField action = field("action 名（profile 里定义的，如 kread / probe）");
        JTextField payload = field("payload JSON，如 {\"addr\":\"0xFFFFF80142A00000\",\"readSize\":4}");

        JPanel top = card("profile 清单（driver.profile.list；选中行后可做详情/校验/设备/发送预览）");
        top.add(row(
                btn("① 刷新清单", () -> run("driver.profile.list", null, false, r -> {
                    model.setItems(r.items());
                    autoWidth(t);
                    out.setText("profile 共 " + model.count() + " 条（引擎内 " + r.workerMs + " ms）");
                })),
                btn("② 详情（profile.show）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    String id = it == null ? "" : s(it.get("id"));
                    if (id.isEmpty()) { out.setText("请先选中一个 profile"); return; }
                    run("driver.profile.show", one("id", id), false, r -> out.setText(Json.write(r.dataMap())));
                }),
                btn("③ 校验（profile.validate）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    String id = it == null ? "" : s(it.get("id"));
                    Map<String, Object> args = new LinkedHashMap<>();
                    if (!id.isEmpty()) args.put("id", id);
                    if (!sysPath.getText().trim().isEmpty()) args.put("path", sysPath.getText().trim());
                    if (args.isEmpty()) { out.setText("需要 profile id 或 .sys 路径"); return; }
                    run("driver.profile.validate", args, false, r -> {
                        out.setText((r.ok ? "✔ 校验通过\n" : "✖ 校验未过\n") + Json.write(r.dataMap())
                                + (r.errors.isEmpty() ? "" : "\n\nerrors:\n" + r.errorsText()));
                    });
                })
        ), BorderLayout.NORTH);
        page.add(top, BorderLayout.NORTH);

        JPanel mid = card("其他动作（设备定位 / 静态草案 / 通用原语；写操作一律先预览）");
        mid.add(row(
                sysPath,
                btn("设备（driver.devices）", () -> {
                    if (service.getText().trim().isEmpty()) { out.setText("请填服务名"); return; }
                    run("driver.devices", one("name", service.getText().trim()), false, r -> out.setText(Json.write(r.dataMap())));
                })
        ), BorderLayout.NORTH);
        mid.add(row(
                service,
                btn("静态草案（profile.draft，只读）", () -> {
                    String p = sysPath.getText().trim();
                    if (p.isEmpty()) { out.setText("请先在第一个框里填 .sys 路径"); return; }
                    run("driver.profile.draft", one("path", p), false, r -> {
                        out.setText("confidence=" + s(r.dataMap().get("confidence"))
                                + "  needsReview=" + s(r.dataMap().get("needsReview"))
                                + "（草案永远不能直接执行；actions 为空时引擎会拒绝另存）\n\n"
                                + Json.write(r.dataMap()));
                    });
                }),
                btn("① 发送预览（ctl.send，不发 IOCTL）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    String id = it == null ? "" : s(it.get("id"));
                    if (id.isEmpty() || action.getText().trim().isEmpty()) { out.setText("需要选中 profile 且填 action"); return; }
                    Map<String, Object> args = new LinkedHashMap<>();
                    args.put("profile", id);
                    args.put("action", action.getText().trim());
                    if (!payload.getText().trim().isEmpty()) args.put("payload", payload.getText().trim());
                    run("driver.ctl.send", args, false, r -> out.setText("applied=" + r.applied + "（预览，未发送）\n\n" + Json.write(r.dataMap())));
                }),
                btn("② 应用：发送（二次确认）", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    String id = it == null ? "" : s(it.get("id"));
                    if (id.isEmpty() || action.getText().trim().isEmpty()) { out.setText("需要选中 profile 且填 action"); return; }
                    int yes = JOptionPane.showConfirmDialog(frame,
                            "即将真正向驱动发送 IOCTL：\n  profile=" + id + "\n  action=" + action.getText().trim()
                                    + "\n  payload=" + payload.getText().trim()
                                    + "\n\n未确认语义的 IOCTL 可能导致蓝屏。确认继续？",
                            "二次确认：发送 IOCTL", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                    if (yes != JOptionPane.YES_OPTION) return;
                    Map<String, Object> args = new LinkedHashMap<>();
                    args.put("profile", id);
                    args.put("action", action.getText().trim());
                    if (!payload.getText().trim().isEmpty()) args.put("payload", payload.getText().trim());
                    run("driver.ctl.send", args, true, r -> out.setText("applied=" + r.applied + "\n\n" + Json.write(r.dataMap())
                            + (r.errors.isEmpty() ? "" : "\nerrors:\n" + r.errorsText())));
                })
        ), BorderLayout.CENTER);
        page.add(mid, BorderLayout.SOUTH);

        JSplitPane sp = new JSplitPane(JSplitPane.VERTICAL_SPLIT, scroll(t), scroll(out));
        sp.setResizeWeight(0.5);
        page.add(sp, BorderLayout.CENTER);
        return page;
    }

    // ==================== 页面：对象图映射 ====================

    private JPanel buildDriverMap() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        ItemModel model = new ItemModel();
        JTable t = table(model, 150);
        JTextArea out = area(true);
        JTextField service = field("服务名，可留空=全量（例如 disk / tcpip / KSecDD）");
        JLabel stats = new JLabel("—");
        stats.setFont(monoFont(12));

        JPanel top = card("对象图映射（driver.map：\\Device ↔ \\Driver ↔ 服务名；只读，附 PnP 权威旁证）");
        top.add(row(service, btn("查询（driver.map）", () -> {
            Map<String, Object> args = new LinkedHashMap<>();
            if (!service.getText().trim().isEmpty()) args.put("service", service.getText().trim());
            run("driver.map", args, false, r -> {
                Map<String, Object> d = r.dataMap();
                model.setItems(r.items());
                autoWidth(t);
                Map<String, Object> st = d.get("stats") instanceof Map ? Json.castMap(d.get("stats")) : new LinkedHashMap<>();
                stats.setText("设备对象 " + st.get("deviceObjects") + " · 驱动对象 " + st.get("driverObjects")
                        + " · 链接 " + st.get("linksTotal") + "（解析 " + st.get("linksResolved") + "）"
                        + " · 已映射 " + st.get("mapped") + " · 未映射 " + st.get("unresolved"));
                StringBuilder b = new StringBuilder();
                List<Object> pnp = WorkerClient.list(d.get("pnpDevices"));
                if (!pnp.isEmpty()) {
                    b.append("—— PnP 权威旁证（Win32_PnPEntity.Service）：").append(pnp.size()).append(" 个设备实例 ——\n");
                    for (Object p : pnp) {
                        if (p instanceof Map) {
                            Map<String, Object> pm = Json.castMap(p);
                            b.append("  [").append(s(pm.get("service"))).append("] ")
                                    .append(s(pm.get("deviceId"))).append("\n      ").append(s(pm.get("name"))).append('\n');
                        }
                    }
                    b.append('\n');
                }
                List<Object> notes = WorkerClient.list(d.get("notes"));
                if (!notes.isEmpty()) {
                    b.append("—— 引擎的边界说明 ——\n");
                    for (Object n : notes) b.append("  · ").append(s(n)).append('\n');
                }
                out.setText(b.toString());
                out.setCaretPosition(0);
            });
        })), BorderLayout.NORTH);
        top.add(stats, BorderLayout.SOUTH);
        page.add(top, BorderLayout.NORTH);

        JSplitPane sp = new JSplitPane(JSplitPane.VERTICAL_SPLIT, scroll(t), scroll(out));
        sp.setResizeWeight(0.7);
        page.add(sp, BorderLayout.CENTER);
        return page;
    }

    // ==================== 页面：进程 ====================

    private JPanel buildProcesses() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        ItemModel model = new ItemModel();
        JTable t = table(model, 140);
        JLabel info = new JLabel("—");
        JPanel top = card("进程（process.list）");
        top.add(row(
                btn("① 刷新（process.list）", () -> run("process.list", null, false, r -> {
                    model.setItems(r.items());
                    autoWidth(t);
                    info.setText("共 " + model.count() + " 个进程（批量填充，引擎内 " + r.workerMs + " ms）");
                })),
                btn("② 选中行详情", () -> {
                    Map<String, Object> it = model.item(t.getSelectedRow());
                    JOptionPane.showMessageDialog(frame, it == null ? "请先选中一行" : Json.write(it), "进程详情", JOptionPane.INFORMATION_MESSAGE);
                })
        ), BorderLayout.NORTH);
        top.add(info, BorderLayout.SOUTH);
        page.add(top, BorderLayout.NORTH);
        page.add(scroll(t), BorderLayout.CENTER);
        return page;
    }

    // ==================== 页面：通用控制台 ====================

    private JPanel buildConsole() {
        JPanel page = new JPanel(new BorderLayout(8, 8));
        JTextField verb = field("verb 名，例如 driver.status / wdac.status / backup.list");
        JTextArea argsArea = new JTextArea("{\n}");
        argsArea.setFont(monoFont(12));
        JTextArea out = area(true);
        JPanel top = card("通用控制台（任何 verb 都能从这里调；写操作必须先用「预览」）");
        top.add(row(verb,
                btn("预览（不带 -Apply）", () -> callGeneric(verb, argsArea, out, false)),
                btn("应用（带 -Apply，二次确认）", () -> {
                    int yes = JOptionPane.showConfirmDialog(frame, "确认带 -Apply 执行 " + verb.getText().trim() + " ？",
                            "二次确认", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE);
                    if (yes == JOptionPane.YES_OPTION) callGeneric(verb, argsArea, out, true);
                })
        ), BorderLayout.NORTH);
        page.add(top, BorderLayout.NORTH);
        JSplitPane sp = new JSplitPane(JSplitPane.VERTICAL_SPLIT, scroll(argsArea), scroll(out));
        sp.setResizeWeight(0.3);
        page.add(sp, BorderLayout.CENTER);
        return page;
    }

    private void callGeneric(JTextField verb, JTextArea argsArea, JTextArea out, boolean apply) {
        String v = verb.getText().trim();
        if (v.isEmpty()) { out.setText("请填 verb"); return; }
        Map<String, Object> args = new LinkedHashMap<>();
        String txt = argsArea.getText().trim();
        if (!txt.isEmpty() && !txt.equals("{}")) {
            try {
                Object parsed = Json.parse(txt);
                if (parsed instanceof Map) {
                    for (Map.Entry<String, Object> e : Json.castMap(parsed).entrySet()) args.put(e.getKey(), e.getValue());
                } else { out.setText("args 必须是 JSON 对象"); return; }
            } catch (RuntimeException ex) {
                out.setText("args 不是合法 JSON：" + ex.getMessage());
                return;
            }
        }
        run(v, args, apply, r -> {
            StringBuilder b = new StringBuilder();
            b.append("verb=").append(r.verb).append("  ok=").append(r.ok).append("  applied=").append(r.applied)
                    .append("  引擎内 ").append(r.workerMs).append(" ms\n");
            if (!r.errors.isEmpty()) b.append("errors:\n  ").append(String.join("\n  ", r.errors)).append('\n');
            if (!r.warnings.isEmpty()) b.append("warnings:\n  ").append(String.join("\n  ", r.warnings)).append('\n');
            b.append("\n—— data ——\n").append(Json.write(r.data));
            out.setText(b.toString());
            out.setCaretPosition(0);
        });
    }

    // ==================== 小工具 ====================

    private static String s(Object o) { return o == null ? "" : String.valueOf(o); }

    private static Map<String, Object> one(String k, Object v) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put(k, v);
        return m;
    }
}