# AI 接入（让 AI 安全地编排本工具）

> 目标：普通人只说一句话，AI 就能按**正确顺序**（先提权 → 再加载驱动）把事办了，
> 而人保留最终确认权。

## 为什么需要这一层

AI 直接裸调 `Engine.ps1` 也能跑，但它不知道三件关键的事：

1. **现在能不能做**——当前是普通用户还是管理员？哪些 verb 会被拦住？
2. **该按什么顺序做**——提权插件要求**非提权**上下文，而加载驱动**要求管理员**，顺序反了就必然失败。
3. **什么时候必须停下来等人**——`sc create`、发 IOCTL 这类动作，AI 不该自己拍板。

所以本层提供三样东西：**机器可读清单**、**确定性计划**、**一次性确认闸门**。

## 三个引擎能力

| verb | 作用 | 副作用 |
|---|---|---|
| `ai.manifest` | 全部 58 个 verb 的 `mutating` / `needsElevation` / **`blockedNow`**（现在能不能做）+ 两条预置流程 + 安全规则 | 无 |
| `ai.plan` | 把一句目标转成**有序步骤**（含每步为什么、是否需要提权、当前是否被阻），并给第一个可执行的写操作发**一次性确认短语** | 无（只落一个 10 分钟的短语记录） |
| `ai.run` | 执行一个 verb；`mutating` + `apply=true` 时**必须**出示短语 | 取决于目标 verb |

```powershell
# 1) 看清单
powershell -NoProfile -ExecutionPolicy Bypass -File core\Engine.ps1 -Verb ai.manifest

# 2) 出计划（只读）
'{"goal":"提权到system然后加载我的驱动"}' > p.json
powershell -NoProfile -ExecutionPolicy Bypass -File core\Engine.ps1 -Verb ai.plan -ArgsFile p.json

# 3) 执行（只读 verb 不需要 confirm；写操作要带 confirm）
'{"verb":"driver.map"}' > c.json
powershell -NoProfile -ExecutionPolicy Bypass -File core\Engine.ps1 -Verb ai.run -ArgsFile c.json
```

## 计划长什么样（实测）

目标「提权到system然后加载我的驱动」，**当前是普通用户**时：

```
1. capability.status   [只读] 先看权限画像
2. plugins.run         [写]   普通用户 → SYSTEM（该插件要求非提权上下文，恰好符合）
3. capability.status   [只读] 确认 isAdmin=true 再继续
4. driver.load         [写]   加载驱动（这一步才允许）
5. driver.verify       [只读] 以系统返回为准，确认真的在运行
6. driver.unload       [写]   用完立即卸载（不删 .sys，生成 revert）
```

当前**已是管理员**时，第 2/3 步会被跳过，并在 `notes` 里说明「不需要再跑提权插件」——
这就是 `blockedNow` 与 `isAdmin` 的用处：AI 不用猜。

## 确认闸门（人在回路）

- `ai.plan` 为第一个可执行的写步骤发 `I-UNDERSTAND-<8hex>`；记录写在 `var\ai\pending\<hex>.json`，
  **10 分钟有效、绑定 verb+args、用后即焚**（改参数就必须重新 plan）。
- `ai.run` 在 `mutating && apply` 时校验：没有短语 → `confirmRequired=true` 拒绝；短语给错 verb/args → 拒绝；
  重复使用 → 拒绝。
- **诚实的边界**：有执行权的 AI 理论上能自己把短语回填。真正的护栏是「界面每次都弹确认框 + 审计日志」，
  本模块能做到的是**要求显式确认 + 全量留痕**，不假装能拦住自主 AI。

## MCP 服务器（推荐给 AI 宿主用）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\McpServer.ps1
```

JSON-RPC 2.0 over stdio（每行一条消息），暴露 **4 个工具**（渐进披露，不把 58 个 verb 塞给模型）：

| 工具 | 说明 |
|---|---|
| `lct_manifest` | 能力清单（含 `blockedNow`） |
| `lct_status` | 当前权限画像 |
| `lct_plan` | 目标 → 有序计划 + 确认短语 |
| `lct_call` | 执行 verb（写操作必须 `apply=true` + `confirm`） |

标准调用序列：`initialize` → `notifications/initialized`（通知，服务器**不回包**）→ `tools/list` → `tools/call`。
启动导入模块约 1.9 秒（一次性），之后每次调用毫秒级。每次调用都写 `var\logs\ai-mcp-<日期>.log`。

## 界面入口（Java UI 第 7 页「AI 助手」）

输入一句话 → `ai.plan` → 显示有序步骤与「当前是否被阻」→ **逐步执行**：
只读步骤直接跑；写步骤弹确认框并把 plan 给的短语传给 `ai.run`。

## 安全红线（写进 `ai.manifest.rules`）

1. 写操作默认只预览，执行必须 `-Apply` + 人工确认短语。
2. 驱动类写操作需要管理员；未提权时不要重试，先去提权。
3. **不要对未知驱动盲发 IOCTL**（可能蓝屏）：draft → 人审 → validate 过指纹 → 预览核对字节 → 才发。
4. 不做隐藏/规避安全产品；所有动作写审计日志。
5. 提权后留下的 SYSTEM 会话必须清理（`plugins.run` 的 PoC 会留 `cmd /K "title … SYSTEM Shell"`）。

## 测试

`tests\AiTest.ps1`（26 断言，已进 `Run-AllGates`）：
清单完整性、流程顺序、`needsElevation` 判定、计划只读且有顺序、短语落盘/校验/用后即焚、
`ai.run` 拒绝无确认与递归、以及 **MCP 全链路**（`tests\McpSmoke.ps1` 起真进程跑 initialize/tools/list/tools/call）。

## 大白话 → goal（本地 Ollama 翻译）

界面「AI 助手」页顶部可以填 **Ollama 地址**（本机 `http://127.0.0.1:11434`，或局域网，例如 `http://192.168.1.100:11434`）和**模型名**（如 `qwen2.5:7b`），配置会自动记住。

按钮「☁ 翻译成目标」把你说的大白话翻成工具认的 goal，并回填到输入框；然后点「★ 一键跑完」。

```powershell
# 命令行等价用法
'{"text":"帮我把 rtcore64 挂上去读一下内核头","endpoint":"http://127.0.0.1:11434","model":"qwen2.5:7b"}' > t.json
core\Engine.ps1 -Verb ai.translate -ArgsFile t.json
# → {"goal":"加载 rtcore64 驱动读内核头，最后清理", "mode":"llm", ...}
```

设计要点（都是故意的）：

- **只做翻译，不执行**：`ai.translate` 不碰系统、不写盘，产物只是"一句话目标"；
  真正执行仍走 `ai.plan` / `ai.do`，而写操作**必须由人确认一次性短语**。LLM 绕不过闸门。
- **连不上就明说**：`mode=error` + 错误里带地址与原因；加 `-Fallback` 则用原文当目标（不假装翻译过）。
- **输出清洗**：去代码块、去「目标：」前缀、去引号、只取第一行、限 80 字（`ConvertTo-LctAiGoalText`）。
- **编码**：不用 `Invoke-RestMethod`（响应头缺 charset 时会把 UTF-8 当 Latin-1，中文变乱码），
  改为拿原始字节 + 强制 UTF-8 解码。
- **测试不需要装 Ollama**：`tests\FakeOllama.ps1` 起一个假的 `/api/generate`（含 `Expect: 100-continue` 处理），
  `tests\AiTranslateTest.ps1` 用它验证正常/不可达/兜底/清洗/端到端。
## 云端 API（OpenAI 兼容 / Anthropic）

`ai.translate` 与 `ai.auto` 都支持三种协议，`provider` 可显式给，也可从地址自动推断：

| provider | 地址示例 | 协议路径 | 鉴权头 |
|---|---|---|---|
| `ollama` | `http://127.0.0.1:11434`（或局域网） | `/api/generate` | 无（有 key 时带 Bearer） |
| `openai` | `https://api.deepseek.com/v1`、`https://api.openai.com/v1`、`https://api.moonshot.cn/v1`、`https://open.bigmodel.cn/api/paas/v4` | `/v1/chat/completions`（或你给的完整 URL） | `Authorization: Bearer <key>` |
| `anthropic` | `https://api.anthropic.com` | `/v1/messages` | `x-api-key` + `anthropic-version: 2023-06-01` |

地址里出现 `openai`/`deepseek`/`moonshot`/`bigmodel`/`dashscope`/`/v1` ⇒ 自动按 openai 协议；
出现 `anthropic`/`claude` ⇒ anthropic；否则 ollama。

### 密钥怎么存

```powershell
# 保存（DPAPI 当前用户加密，写 var\ai\credential.json，磁盘上没有明文）
'{"action":"set","provider":"openai","key":"sk-你的key"}' > k.json
core\Engine.ps1 -Verb ai.cred -ArgsFile k.json

# 查看（只显示 provider / 长度 / 时间，不返回明文）
core\Engine.ps1 -Verb ai.cred

# 清除
'{"action":"clear","provider":"openai"}' > k.json
core\Engine.ps1 -Verb ai.cred -ArgsFile k.json
```

调用时**不用再传 key**：`Get-LctAiCredential` 会按 provider 解密注入。
换 Windows 用户或换机器需重新配（DPAPI 是用户/机器绑定的）。

### 一键完成（ai.auto）

```powershell
'{"text":"把 rtcore64 挂上去读一下内核头","endpoint":"https://api.deepseek.com/v1","model":"deepseek-chat"}' > a.json
core\Engine.ps1 -Verb ai.auto -ArgsFile a.json            # 翻译 + 出计划（不执行）
core\Engine.ps1 -Verb ai.auto -ArgsFile a.json -Apply      # 无 confirm ⇒ needConfirm
```

流程：`text → (配了模型就翻译) → goal → plan → (apply+confirm 才执行)`。
翻译失败不会挡住后面：按原文当目标继续，`translated=false` 会标出来。

### 错误提示

- `HTTP 401/403` → 提示用 `ai.cred` 配 Key
- `HTTP 404` → 提示 OpenAI 兼容要写到 `/v1` 这一级
- `HTTP 429` → 限流/额度
- 连不上 → 直接说“连不上”并给地址

### 界面

AI 页新增：**服务下拉**（本地 Ollama / OpenAI 兼容 / Anthropic / 自定义，切换自动填地址与模型）、
**密钥框**、**🔑 保存密钥**（走 `ai.cred`）、**🔌 测试连接**、**⚡ 一键完成**（翻译→计划→人确认→执行）。
地址/模型/服务选择存 Java Preferences；密钥只进 DPAPI 文件。