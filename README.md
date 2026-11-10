> ## 本仓库是「MCP 工具」，不是恶意项目
>
> LocalConfigTool 是一个 Windows 系统分析与本地配置管理工具，同时是一个标准
> **MCP（Model Context Protocol）服务器**（`tools\McpServer.ps1`，JSON-RPC over stdio）。
> 它不自我传播、不隐藏、不窃取数据；写操作默认只预览，必须显式 `-Apply`，
> AI 场景还需人给一次性确认短语；每次写入前自动备份、可回滚、全程审计。
>
> ## 公开版与完整版的差别（只差两样「具体载荷」）
>
> **工具本体与能力完整保留**：68 个 verb、驱动/对象图/profile 引擎、WDAC、AI 接入、MCP、UI、23 道门禁测试。
>
> 只把下面两样改为**使用者自备**：
> - 某个具体 CVE 的**可执行 exploit** → `plugins\cve-2026-49176` 是占位实现（用 `-PocDir` 指向你自己的 PoC）
> - **现成的漏洞驱动下载链** → `samples\catalog.json` 的真实 URL / SHA256 已清空（填你自己的）
>
> 因为「具备驱动加载能力」和「预置某个具体 exploit」是两件事：前者是**工具**
> （火绒剑同样自带驱动、能操作内核），后者属于**具体利用代码**，不适合随公开仓库分发。
>
> ## 使用边界
>
> - 仅在**你完全拥有处置权**的机器上使用（虚拟机 / 快照最佳）
> - 驱动加载与内核操作有蓝屏风险，工具默认**只预览**，必须显式 `-Apply`
> - 使用者自行承担全部责任；请勿用于未授权的系统

---
# LocalConfigTool

> ## 一个 MCP 工具，不是恶意项目
>
> LocalConfigTool 是一个 Windows **系统分析与本地配置管理工具**，同时是一个标准的
> **MCP（Model Context Protocol）服务器**：AI 宿主（Claude Desktop / Cursor / DSH 等）可以
> 通过 JSON-RPC over stdio 挂载它，用自然语言驱动系统操作。
>
> 它**不是**恶意软件 / 攻击载荷：
>
> - 不自我传播、不隐藏、不驻留、不窃取数据
> - **不预置**任何 exploit 或漏洞驱动二进制（样本按需获取，且强制 SHA256 校验）
> - 所有写操作**默认只预览**，必须显式 `-Apply`；AI 场景还需人给一次性确认短语
> - 每次写入前自动备份、可回滚、全程审计日志（`var\logs\`）
> - 用完可一键清理（`driver.cleanup` 只卸本工具加载过的服务）
>
> 定位类似火绒剑（HRSword）这类系统分析工具：**把系统能力交给使用者，由使用者决定做什么**。
> 它不是"自动帮你攻击"的东西，而是"把系统内部摊开给你看、让你操作，并且允许你反悔"的工具。

## 三种用法

| 用法 | 入口 | 说明 |
|---|---|---|
| **图形界面** | `ui-java\run.cmd`（需 JDK 21）或 `run-ui.cmd` | Java Swing 界面，7 页 |
| **命令行** | `engine.cmd -Verb <verb> [-ArgsFile <json>] [-Apply]` | 68 个 verb，与界面等价 |
| **MCP（给 AI 用）** | `tools\McpServer.ps1` | JSON-RPC over stdio，暴露 4 个工具 |


## MCP 接口（本项目的核心身份之一）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\McpServer.ps1
```

标准 **JSON-RPC 2.0 over stdio**（每行一条消息），暴露 4 个工具（渐进披露，不把 68 个 verb 塞给模型）：

| 工具 | 作用 |
|---|---|
| `lct_manifest` | 能力清单：每个 verb 的 `mutating` / `needsElevation` / `blockedNow` + 预置流程 + 安全规则 |
| `lct_status` | 当前权限画像：`isAdmin` / `integrityLevel` / `canLoadDriver` |
| `lct_plan` | 一句话目标 → 有序执行计划（只读；为第一个可执行写步骤发一次性确认短语） |
| `lct_call` | 执行 verb；`mutating` + `apply=true` 必须带人给的 `confirm` 短语 |

**为什么 AI 需要这一层**：AI 直接裸调引擎也能跑，但拿不到"现在能不能做 / 该按什么顺序做"的元信息，
也绕不过确认闸门。MCP 层把这两件事固化成协议。详见 `docs\AI-INTERFACE.md`。

```
run-ui.cmd / ui-java\run.cmd  →  图形界面
engine.cmd                    →  引擎命令行（界面也是调它）
tools\McpServer.ps1           →  MCP 服务器（AI 宿主挂载）
plugins\                      →  插件（每个插件一个目录 + plugin.json）
presets\                      →  预设包（数据驱动，加 JSON 即可扩展）
var\                          →  日志、备份、已下载样本（运行数据：不入库、勿分发）
```

## 快速开始

**界面**：双击 `run-ui.cmd`（界面里所有写操作默认只**预览**，要再点一次「应用」并确认才落盘）。

**命令行**（界面能做的命令行都能做）：

```bat
engine.cmd engine.verbs
engine.cmd account.status -Out text
engine.cmd account.admin -ArgsFile "%TEMP%\args.json" -Apply
engine.cmd plugins.list
```

参数含引号/反斜杠时**务必走文件**：

```powershell
@{ path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; name = 'ProductName' } |
  ConvertTo-Json -Compress | Set-Content "$env:TEMP\args.json" -Encoding UTF8
```
```bat
engine.cmd registry.get -ArgsFile "%TEMP%\args.json"
```
> 内联 JSON（`-Args '{"path":"HKCU:\\Software"}'`）在**跨进程命令行层**会被转义规则破坏
> （实测报 `Invalid JSON primitive: HKCU.`），所以引擎专门提供 `-ArgsFile`。界面固定用文件通道。

## 现有能力（`engine.verbs` 可自描述，界面据此生成）

| 分类 | verb | 说明 |
|---|---|---|
| 账户与登录 | `account.status` | 账户 / 管理员组 / UAC / 自动登录 快照 |
| | `account.admin` | 内置 Administrator 启用 / 禁用 |
| | `account.uac` | UAC 开关（改 EnableLUA、提示行为等四项，**需重启生效**） |
| | `account.autologon` | 自动登录开关（口令只从 `passwordFile` 读） |
| 注册表 | `registry.get` / `registry.set` / `registry.delete` | 任意路径读 / 写 / 删（支持 String/ExpandString/DWord/QWord/MultiString/Binary） |
| 预设包 | `presets.list` / `presets.show` / `presets.apply` | 数据驱动的预设项，可整包或单项预览/应用 |
| 提权工具 | `plugins.list` / `plugins.show` / `plugins.run` | 列出 / 看详情 / 预览命令 / 执行（执行需 `-Apply`） |
| 备份 | `backup.list` / `backup.show` / `backup.restore` | 列出 / 看详情 / 预览或执行还原 |
| 引擎 | `engine.verbs` | 自描述：verb 表、可用性、装载错误、路径、是否提权 |

## 安全设计（这几条是工具的地基）

1. **默认只预览**：所有写类 verb 不带 `-Apply` 时**绝不落盘**，只回显 `changes`（含 before/after）。
2. **先备份后写**：真实写入前必定先建备份，结果里给出 `backupId`；`var\backups\<id>\` 内含
   `meta.json` + 注册表 `.reg` 导出（若备份时键不存在，则记 `.reg.absent`，还原时会把该键删掉）。
3. **可回滚**：`backup.restore -Apply` 走 `reg import` / 删键；账户类改动另存快照
   `account-before.json`，由账户模块还原（口令不可还原，会在 `warnings` 说明）。
4. **不永久删除**：文件/目录删除只走**回收站**（`Move-LctToRecycleBin`）；注册表键删除用
   `Remove-LctRegistryKeyTree`（刻意不用 `Remove-Item`——本机删除守卫会拦截，且这是铁律）。
5. **不碰口令**：自动登录口令只从文件读，绝不进命令行、日志、备份 meta、返回 JSON
   （备份只记 `hasPassword`），并在 `warnings` 里提示 `AutoAdminLogon` 明文存盘的风险。
6. **插件显式执行**：`plugins.run` 不带 `-Apply` 只回显解析后的命令行，**不启动任何进程**；
   执行需要显式加 `-Apply`。
7. **日志**：每次调用都写 `var\logs\engine-YYYYMMDD.log`（JSON Lines），返回里的 `log` 字段给出路径。

## 插件规范（后端可插拔的底座）

`plugins\<id>\plugin.json`：

```json
{
  "id": "cve-2026-49176",
  "name": "CVE-2026-49176 WalletService 提权",
  "version": "1.0",
  "description": "本地提权 PoC（WalletService → SYSTEM）",
  "risk": "lab-only",
  "note": "仅限自有测试环境使用",
  "entry": { "kind": "ps1", "path": "run.ps1" },
  "params": [
    { "name": "timeout", "title": "超时(秒)", "type": "int", "required": false, "default": 120, "help": "上限 600" }
  ],
  "outputs": [ "成功后看 PoC 运行目录下 payload\\result.txt 的 user=SYSTEM" ]
}
```

- `entry.kind` 支持 `ps1` / `exe`；`path` 相对插件目录。
- 参数替换用 `{name}` 占位；`type=secret` 的参数在日志与返回 JSON 里只显示 `***`。
- 放一个新目录进去就等于新增一个工具，界面下拉里会出现。

## 预设包规范

`presets\<任意名>.json`（可以是单个包，也可以是包数组）：

```json
{
  "id": "account-login",
  "name": "账户与登录",
  "description": "UAC / 内置 Administrator / 自动登录",
  "risk": "medium",
  "items": [
    { "id": "uac-off", "title": "关闭 UAC", "summary": "需重启", "verb": "account.uac", "args": { "enable": false } }
  ]
}
```

## 自测与维护命令

```bat
rem 端到端验收（只动 HKCU 一次性键，退出码=失败项数）
powershell -NoProfile -ExecutionPolicy Bypass -File tests\SelfTest.ps1

rem 编码归一化：给丢了 BOM 的 .ps1/.psm1/.json/.md 补 BOM，并检查 .cmd 是否纯 ASCII
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Fix-Encoding.ps1

rem 前端自检（不开窗口，验证界面能构建且引擎可达）
powershell -NoProfile -ExecutionPolicy Bypass -File ui\ConfigUI.ps1 -SelfCheck
```

## 常见问题

- **中文变乱码 / 脚本报 “The string is missing the terminator”**：文件丢了 BOM，Windows
  PowerShell 5.1 会按 GBK 读。跑一次 `tests\Fix-Encoding.ps1` 即可；用编辑工具改完含中文的文件后都要跑。
- **参数报 `Invalid JSON primitive`**：用了内联 JSON。改用 `-ArgsFile`。
- **UAC 改完没生效**：需要重启（`account.uac` 会在 `warnings` 里说明）。
- **`account.admin` 无效**：需要管理员权限；结果里 `errors`/`warnings` 会说明，界面「概览」页显示是否提权。
- **`engine.verbs` 的 `availability` 有 false**：对应模块装载失败，`loadErrors` 里有原文（界面「概览」页直接显示）。

## 目录

| 路径 | 作用 |
|---|---|
| `core\Engine.ps1` / `Engine.psm1` | 引擎 CLI + verb 分发表（唯一入口） |
| `core\Logging.psm1` | 路径 / 日志 / Result / 回收站 / 注册表键删除 / reg.exe 路径转换 |
| `core\Backup.psm1` | 备份创建、列举、还原 |
| `core\Registry.psm1` | 通用注册表读写 |
| `core\Accounts.psm1` | 账户 / UAC / 自动登录 |
| `core\Plugins.psm1` | 插件发现、校验、预览、执行 |
| `ui\ConfigUI.ps1` | 旧 WinForms 界面（仍可运行，不再更新；当前主界面见 `ui-java\`） |
| `presets\`、`plugins\` | 预设包、提权工具插件 |
| `docs\CONTRACT.md` | 接口契约（冻结）：Result 形状、verb 清单、模块签名、安全铁律 |
| `docs\ARCHITECTURE.md` | 架构与模块依赖约定 |
| `var\logs`、`var\backups` | 日志与备份（可用环境变量 `LCT_VAR_DIR` 重定向，测试隔离用） |

## 验收门（五项，全绿才算交付）

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tests\SelfTest.ps1            rem 引擎端到端（退出码=失败项数）
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Lint-PowerShell.ps1     rem 静态陷阱检查
powershell -NoProfile -ExecutionPolicy Bypass -File tests\UiPageSmoke.ps1         rem UI 页面填充驱动
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Fix-Encoding.ps1        rem 编码归一化（幂等）
powershell -NoProfile -ExecutionPolicy Bypass -File ui\ConfigUI.ps1 -SelfCheck    rem 前端构建 + 引擎可达
```

五条退出码全为 0 才算绿。

⚠ **`-SelfCheck` 只构建控件、不执行页面填充逻辑**，所以它绿 **不等于** 界面能点。
界面相关的回归请看 `tests\UiPageSmoke.ps1`：它会真正调用 6 个页面的 `Update-Lct*` 填充函数
（本轮真实事故就是这样漏掉的——`$pid` 只读变量赋值藏在预设页填充里）。

## 踩坑速查（都是真实发生过的）

- **界面弹 `Cannot overwrite variable PID …（该变量为只读变量或常量）`**
  —— 把局部变量命名成了 PowerShell **只读自动变量**。实测 PS 5.1 只读名单：
  `$pid`、`$host`、`$home`、`$true`、`$false`、`$ExecutionContext`、`$PSVersionTable`、
  `$PSCulture`、`$PSUICulture`、`$PSHome`、`$ShellId`、`$ConsoleFileName`。改个名字即可；
  `tests\Lint-PowerShell.ps1` 会提前抓出来。
- **简单函数里用 `$Args` 当参数名** —— 会被自动变量 `$args` **静默顶掉**（`-Args <对象>` 绑成空
  `Object[]`，不报错），需要参数包时写 `[Alias('Args')][object]$ArgBag`；高级函数（带
  `[Parameter(...)]`）不受影响。lint 也查这一条。
- **中文变乱码 / `The string is missing the terminator`** —— 文件丢了 UTF-8 BOM，PS 5.1 按 GBK 解析。
  跑 `tests\Fix-Encoding.ps1`。
- **参数报 `Invalid JSON primitive`** —— 用了内联 JSON；改用 `-ArgsFile`。
- **`engine.verbs` 的 `availability` 有 false** —— 对应模块装载失败，`loadErrors` 里有原文。
## 自定义驱动加载（2026-10-26 新增）

**口径**：指定一个 `.sys`，把它加载起来。**不对驱动做签名或状态的前置校验** —— 签名与否交给操作系统判定：
- test-signing 未开 ⇒ 未签名驱动会被系统拒绝，`sc start` 返回 `577 Windows cannot verify the digital signature`；
- test-signing 已开 ⇒ 正常加载。

工具**把系统的返回原文照抄给你**（`data.verdict{exitCode,message}`）。注意：`applied=true` 只代表**动作已执行**，
**是否真的加载成功以系统返回为准**（工具不替系统下结论）。

### 命令行
```bat
engine.cmd driver.status                          rem 前提现状：Secure Boot / test-signing / DSE / 驱动数与运行数
engine.cmd driver.info  -ArgsFile args.json       rem {"path":"D:\\my.sys"}         只读：hash + 签名摘要（仅信息）
engine.cmd driver.load  -ArgsFile args.json       rem {"path":"D:\\my.sys","name":"mydrv","startType":"demand"}
engine.cmd driver.load  -ArgsFile args.json -Apply
engine.cmd driver.verify -ArgsFile args.json      rem {"name":"mydrv"}   三档结论 + 系统事件原文
engine.cmd driver.stop   -ArgsFile args.json -Apply
engine.cmd driver.unload -ArgsFile args.json -Apply
```
界面同理：第 9 页「驱动加载」，主区就是「指定驱动并加载」，结果区显示系统的 `exitCode` 与 `message` 原文。

### 保留的唯一约束（都与签名无关，只为「不出事 / 能回滚」）
1. 启动类型默认 `demand`（手动）；`system` / `boot`（开机即载）**必须显式 override** —— 那才是能把机器搞到
   开不了机的高危路径。
2. 同名服务已存在 ⇒ 默认拒绝覆盖（`override` 才允许，且先备份该服务的注册表键与画像）。
3. 卸载**只删服务项、不删 `.sys` 文件**，并生成 `revert.cmd`（含原始 binPath/start 类型与重建命令）。
4. 所有动作默认预览、写审计日志；删除一律走回收站。
5. `driver.testsigning` 可开可关（写前记录原值、结果提示**需重启生效**）；**Secure Boot 开启时拒绝开启
   test-signing**（协议不允许，如实说明原因）。

### 本机实测前提（2026-10-26）
`Secure Boot=False` · `testsigning=Yes`（已开启、立即生效）· `nointegritychecks=No` · VBS=0 · HVCI 未运行 ·
`System32\drivers` 可写 ⇒ **本机此刻即可加载 test-signed / 未签名驱动**，无需重启。