# Java UI（Swing）— 架构与实测

> 目标：把"每次动作 2.2 秒、界面假死"的 WinForms 前端，换成一个**常驻 worker + 异步 + 批量填充 + 懒加载**的 Java 界面。
> 后端一行没改：仍然走 `core/Engine.psm1` 的 54 个 verb，测试门禁全部保留。

## 目录

```
ui-java/
  build.cmd           javac 编译（JDK only，无第三方依赖）
  run.cmd             启动界面（会把工作目录切到项目根，worker 才能找到 core\worker.ps1）
  selftest.cmd        无界面自检（打印 METRIC，供门禁断言）
  src/lctui/
    Json.java         极简 JSON 解析/序列化（JDK 没有 JSON，引 Gson 就要下载 jar）
    WorkerClient.java 常驻 worker 客户端：起一次 powershell.exe，之后 stdin/stdout 一行一条 JSON
    Engine.java       异步门面：线程池执行 → 结果回 Swing EDT（界面永不冻结）
    Ui.java           Swing 界面：懒加载页面 / 忙碌条 / 批量表格 / 6 个页面
    SelfTest.java     无界面性能自检
core/worker.ps1       常驻引擎 worker（导入模块一次，循环处理请求）
tests/JavaUiTest.ps1  门禁（编译 + 自检 + 延迟阈值 + 无残留）
```

## 四条需求的落点

| 需求 | 实现 | 实测 |
|---|---|---|
| ① 常驻 worker | `core/worker.ps1` + `WorkerClient`：进程只起一次，模块只导入一次；每条请求 stdout 一行 JSON | 启动导入 **1625 ms**（一次性），之后 `engine.verbs` 连续 20 次平均 **5.65 ms**（原架构 2200 ms/次） |
| ② 异步 + 忙碌提示 | 所有调用走 `Engine.callUi`（后台线程池 → `invokeLater` 回 EDT）；调用期间状态栏显示不确定进度条 + "执行 xxx …" | UI 线程从不阻塞；`run()` 里统一 `busy()/idle()` |
| ③ 表格批量填充 | `Ui.ItemModel extends AbstractTableModel`，`setItems()` 一次性 `fireTableStructureChanged` | 445 条驱动服务 / 251 进程 / 394 设备对象，一次填充 |
| ④ 按页懒构建 | `showPage()` 第一次选中某页时才 `build(key)`，之后复用 | 启动只建导航；6 个页面按需创建 |

## 协义（worker ⇄ UI）

```
→ {"verb":"engine.verbs"}
← {"ok":true,"verb":"engine.verbs","data":{...},"warnings":[],"errors":[],"workerMs":93}
→ {"verb":"driver.ctl.send","args":{"profile":"x","action":"kread","payload":"{...}"},"apply":true}
→ {"verb":"__ping"}                       ← 就绪探测（worker 回 {"ok":true,"pong":true}）
```

- 一律 **UTF-8**（worker 显式设置 `[Console]::Input/OutputEncoding`；否则 Windows 控制台默认 GBK，中文会乱码）。
- worker 的 **stdout 只允许出现 JSON 行**：`Import-Module` 的"未获批准动词"提示会污染协议，已在 worker 里把 verbose/warning/information 全掐掉；客户端还额外跳过任何非 `{` 开头的行（记进 stderr 尾巴），不让协议被一条提示判死。
- 单线程串行处理（引擎本身不是并发的）；Java 侧用线程池排队，保证 UI 不阻塞。

## 界面

左侧导航 6 页：概览 / 驱动加载 / 驱动 Profile / 对象图映射 / 进程 / 通用控制台。

- **概览**：`engine.verbs` 能力表 + availability + worker 启动耗时。
- **驱动加载**：`driver.status` / `driver.list`（批量表格）/ 行详情。
- **驱动 Profile**：`driver.profile.list` 表格 → 选中后 `profile.show` / `validate`（可带 .sys 做指纹比对）/ `driver.devices` / `profile.draft` / `ctl.send` **预览**（不发 IOCTL）/ **应用**（二次确认对话框后才 `-Apply`）。
- **对象图映射**：`driver.map`，可填服务名（留空=全量），结果表 + PnP 权威旁证 + 引擎的边界说明原文。
- **进程**：`process.list` 批量表格。
- **通用控制台**：任意 verb + args JSON，预览/应用两段式 —— 保证 54 个 verb 全都可达，不会因为界面没做页面而缺席。

## 已知边界 / 注意

1. **worker 是单例串行**：多个请求会排队（每条几毫秒，够用）；要真正并发得开 worker 池，目前不需要。
2. **首次启动要等 1.6 秒**（导入 12 个模块）。期间界面已可见、导航禁用、状态栏显示 "worker 启动中…"，不冻结（启动在后台线程）。
3. **`driver.map` 单次约 0.7–1.1 秒**是它自己的活（枚举对象目录 + CIM 查询），不是 IPC 开销。
4. **WinForms 界面（`ui/ConfigUI.ps1`）保留未删**：两者共用同一后端与同一套测试；Java UI 是并行新增，不是替换。
5. 首次运行需要 JDK 21（本机 `D:\DevTools\jdk`，Temurin 21.0.11）；`javac` 必须带 `-encoding UTF-8`（源码含中文），且 **Java 源码不能带 BOM**（javac 会报 `非法字符: '\ufeff'`）。

## 怎么跑

```bat
ui-java\build.cmd        rem 编译（改完源码后）
ui-java\run.cmd         rem 启动界面
ui-java\selftest.cmd    rem 无界面自检（打印 METRIC）
```

门禁：`tests\JavaUiTest.ps1` 已登记进 `tests\Run-AllGates.ps1`。
