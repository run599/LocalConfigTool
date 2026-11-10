# LocalConfigTool 架构与模块依赖约定

> 接口契约（Result 形状、verb 清单、函数签名、安全铁律）见 [CONTRACT.md](CONTRACT.md)。
> 本文只讲**分层、依赖方向、以及踩过的坑**。改动前请先读这两份。

## 1. 分层与数据流

```
┌──────────────────────────────────────────────┐
│ 前端 ui\ConfigUI.ps1（WinForms）             │  只做：渲染 JSON / 收集输入 / 显示 changes
│   · 无任何后端逻辑                           │  所有动作 → 调引擎 CLI
└───────────────┬──────────────────────────────┘
                │  子进程调用：-Verb X -ArgsFile <json文件> [-Apply] -Out json
                │  （参数走文件；stdout 只有一段 JSON；退出码 0=ok）
┌───────────────▼──────────────────────────────┐
│ 引擎 core\Engine.ps1（CLI）+ Engine.psm1     │  解析参数 → 分发 verb → 装载/降级 → 统一 Result
└───────────────┬──────────────────────────────┘
                │  直接函数调用（同进程）
    ┌───────────┼───────────┬────────────┬─────────────┐
    ▼           ▼           ▼            ▼             ▼
 Logging     Backup      Registry     Accounts      Plugins
 公共底座    备份/还原    注册表读写   账户/UAC/     插件发现/
                          自动登录      预览/执行
                │
                └── presets\*.json（数据，不写代码即可扩展）

 plugins\<id>\  ← 用户自行放入的提权工具（显式 -Apply 才运行）
```

**铁则**：前端不实现后端逻辑；后端不弹窗、不要求交互输入；引擎 stdout 只允许最终 JSON。

## 2. 依赖方向（单向，禁止反向）

```
Engine  →  Logging, Backup, Registry, Accounts, Plugins
Registry / Accounts / Plugins  →  Logging（路径、日志、Result、回收站、注册表键删除）
Backup  →  Logging（**刻意不认识 Accounts**）
Engine 负责把「备份里的账户快照」交给 Accounts 的 Restore-LctAccountState
```

反向依赖会成环，所以 Backup 只负责注册表部分，账户还原由引擎编排。

## 3. 跨模块调用必须遵守的三条（都是实测踩出来的）

1. **模块内要显式 Import 自己的依赖**
   ```powershell
   $lctLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
   if (Test-Path -LiteralPath $lctLoggingModule) { Import-Module $lctLoggingModule -Force -ErrorAction Stop }
   ```
   PowerShell 的**模块作用域不嵌套**，不会继承调用方的导入；不显式导入时，
   Backup 内部函数会报 `Get-LctVarDir is not recognized`。

2. **引擎统一用 `Import-Module -Force -Global`，并在最后把 Logging 再 `-Global` 重导一次**
   各能力模块内部还会自己 Import 一次 Logging（落在**它自己**的模块作用域），会把全局那份顶掉；
   所有模块装载完之后必须再全局重导一次，否则引擎自身看不到 `New-LctResult`。

3. **不要用 `Get-Command` 探测跨模块函数是否存在**
   在模块作用域下它会误报（实测：`availability.Logging=false`，但同一进程里 `New-LctResult` 实际可调用）。
   可用性判定改为「**模块是否装载成功**」（`$script:LctLoaded`），缺函数交给 `try/catch`，
   由引擎把 `CommandNotFoundException` 转成可读的「依赖未就绪：…」。

## 4. 装载器必须自给自足

**禁止在装载阶段调用被装载模块的函数。** 曾经在引擎装载循环的 `catch` 里调用 `Write-LctLog`：
一旦 Logging 装载失败，`catch` 自己抛异常 → `Engine.psm1` 整体装载失败 → 引擎完全无输出。
现在装载期只用 `$script:LctLoadErrors` 记录，`engine.verbs` 会把它们原样报给界面。

## 5. 引擎的降级语义（前端可依赖）

- 任何异常都不会抛出，一律变成 `ok=false` + `errors`（`Result` 形状恒定）。
- 模块缺失/函数缺失 → `errors` 里是「依赖未就绪：…」。
- `engine.verbs.data` 额外给出：
  `availability`（按模块装载成功判定）、`loadErrors`（装载失败原文）、`toolRoot`、`varDir`、`elevated`。
- 退出码：`ok=true` → 0，否则 1（`-Out text` 同样遵此）。

## 6. 参数通道（为什么要有 -ArgsFile）

| 通道 | 用法 | 可靠性 |
|---|---|---|
| `-ArgsFile <路径>` | 引擎读 JSON 文件 | **推荐**，引号/反斜杠原样保留 |
| `-Args @<路径>` | `@` 前缀当文件 | 可用 |
| `-Args <路径>` | 存在即按文件读 | 可用 |
| `-Args '<内联JSON>'` | 直接当 JSON 解析 | **脆弱**：跨进程命令行层会吃掉转义（`\\` 与 `"`），实测报 `Invalid JSON primitive` |

前端固定走 `-ArgsFile`；命令行里含反斜杠的路径也必须走文件。

## 7. 编码约定（本项目的头号坑）

- `.ps1` / `.psm1` / `.json` / `.md` 一律 **UTF-8 带 BOM**；`.cmd` 一律纯 ASCII。
- 原因：Windows PowerShell 5.1 把**无 BOM** 的文件按 ANSI/GBK 解析。中文被误解码后会吞掉引号，
  直接导致**整个模块解析失败**（报 `Unexpected token '鎻掍欢'`、`The string is missing the terminator`）。
- 编辑工具（edit/write）重写文件时**不写 BOM**，所以：**每次改完含中文的文件，都要跑**
  `tests\Fix-Encoding.ps1`（纯 ASCII 编写，即使全树乱码也能安全执行；会补 BOM 并检查 `.cmd`）。

## 8. 备份目录结构

```
var\backups\<yyyyMMdd-HHmmss>-<verb>-<rand>\
  meta.json              # verb / 时间 / 用户 / 是否提权 / 参数 / 文件清单 / notes
  reg\NN-<路径>.reg       # reg.exe export 的原始值（还原走 reg import）
  reg\NN-<路径>.reg.absent# 纯文本记录「备份时该键不存在」⇒ 还原时删掉该键（无 BOM！否则路径解析失配）
  account-before.json    # 账户/UAC/自动登录快照（口令只记 hasPassword）
```

## 9. 扩展方式

- **新增能力**：在对应模块加函数 → 在 `Engine.psm1` 的 `$script:LctVerbTable` 加一条自描述 →
  在 `Invoke-LctEngine` 的 `switch` 加一个分支。前端**无需改代码**（界面按自描述生成表单）。
- **新增预设包**：往 `presets\` 丢一个 JSON，引擎自动发现。
- **新增提权工具**：往 `plugins\` 建一个目录，写 `plugin.json` + 入口脚本，引擎自动发现。

## 10. 已知边界

- 账户类改动（UAC / Administrator / 自动登录）**需要管理员权限**，且 UAC 需**重启**才全面生效。
- `AutoAdminLogon` 的明文口令是既有机制的安全缺陷，工具只做开关并在 `warnings` 里提示替代方案。
- 自动登录口令**不可回滚**（不会写进备份），还原时会在 `warnings` 标注。
- 目前预设包只覆盖「账户与登录」这一类（用户明确要求）；其它类别请另加预设包，不要塞进现有包。
- 目标是 Windows PowerShell 5.1（系统自带）；未在 PS7 上验证过前端（引擎在 PS7 下可用）。
## WDAC 黑名单的实现依据（2026-10-26 实测交底，backend-wdac 提供）

「只拉黑某几个程序」在 WDAC 里的正确做法**不是**用 `New-CIPolicy -Level None -Deny` 从零生成——
Lead 实测该产物里 `<FileRules/>` 与 `<Signers/>` **都是空的**：既没有 allow 机制，也拦不住用户态程序。
本工具采用**微软官方 standalone deny 配方**：

1. 以 `%windir%\schemas\CodeIntegrity\ExamplePolicies\AllowAll.xml` 为**基底**（它提供真正的 allow 机制：
   产出 `<Allow FileName="*">` ×2 并被两个签名场景引用）；
2. 生成 deny 规则：path 类且目标存在 → 官方 `New-CIPolicyRule -Deny -FilePathRule <目标>`；
   fileName / hash / 目标不存在 → 直接写 `<Deny>` 节点（形状与 ConfigCI 自身输出一致）；
3. `Merge-CIPolicy` 合并后再 `ConvertFrom-CIPolicy` 转二进制（借 schema 校验挡掉形状错误）；
4. `Enabled:UMCI` 才会拦**用户态**程序；`Enabled:Audit Mode` = 审计模式；
   编号实测：3=Audit Mode、6=Unsigned SIP、9=Advanced Boot Options Menu、10=Boot Audit On Failure。
5. WDAC schema 的 RuleID 只允许 `ID_[A-Za-z0-9_]+`（含连字符会被 `ConvertFrom-CIPolicy` 拒绝）。

**当 `AllowAll.xml` 缺失时**退化为无 allow 机制的基底 ⇒ 该策略**只允许审计部署**，
强制部署会被 `Test-LctWdacPolicy` 的安全门拒绝。宁可拒绝，也不做「看着成功、实则把系统拦死」的事。

本机前提（实测）：**Secure Boot = False** ⇒ 未签名策略可加载；**`CiTool.exe` 不存在** ⇒ 只能走
legacy `%SystemRoot%\System32\CodeIntegrity\SiPolicy.p7b`，**重启才生效**；
`New-CIPolicy` **必须**带 `-ScanPath`（缺省会全盘 + 卷影扫描，既慢又产出巨大 XML）。
另：WDAC 默认忽略用户可写目录（Desktop/Temp/Users/ProgramData）里的 FilePath 规则，
这类目标应改用 hash 或 fileName 规则。

### 未验证项（务必记牢，不要当成已验证）
- **真实部署路径**（System32 写入、备份、`revert.cmd` 生成、复制后哈希校验与自动回滚）
  **只在代码层面成立，未在真机执行过** —— 测试按禁令只覆盖了预览/拒绝/零副作用路径。
- **「用户态黑名单」的拦截语义无法在重启前证明**：legacy 策略只在重启时加载。
  必须重启后跑 `wdac.verify` 看审计事件（3078/3080/3112 只能证明策略在评估文件），
  **并实测目标程序**，才算真正验证。
- 失败恢复路径：策略必带 `Advanced Boot Options Menu` + `Boot Audit On Failure`；
  部署前全量备份并生成 `revert.cmd`（含 F8 启动设置 / WinRE 离线恢复步骤）。