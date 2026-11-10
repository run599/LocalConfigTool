# LocalConfigTool 接口契约（冻结版 v1）

> 本文件由 Lead 冻结。**任何模块不得改动本文件；如需变更，先在共享任务里提出。**
> 所有实现必须严格符合本契约，否则前端与引擎会对不上。

## 1. 目标与分层

把本地安全配置与提权工具做成**前后端分离**的工具：

```
前端（ui\ConfigUI.ps1，WinForms）   ← 只做「渲染 / 收集输入 / 显示结果」
        │  仅通过进程调用引擎 CLI，传 JSON 入参，收 JSON 出参
        ▼
引擎（core\Engine.ps1 + Engine.psm1） ← 唯一入口，负责参数解析、verb 分发、编排备份
        │  调用各能力模块（纯函数，不弹窗、不交互）
        ▼
能力模块：Registry / Accounts / Plugins / Backup / Logging / Presets
        │
        ▼
插件（plugins\<id>\plugin.json + 入口）← 用户自行放入的提权工具，显式调用才运行
```

铁则：**前端不得实现任何后端逻辑；后端不得弹任何窗口或要求交互输入。**

## 2. 目录结构（`%USERPROFILE%\Desktop\LocalConfigTool\`）

| 路径 | 归属 | 说明 |
|---|---|---|
| `core\Logging.psm1` | Lead | 公共工具：路径、日志、Result 构造、回收站、注册表键删除 |
| `core\Backup.psm1` | Lead | 备份创建/列举/还原（注册表导出 + 账户快照存储） |
| `core\Registry.psm1` | task-1 | 通用注册表读写 |
| `core\Accounts.psm1` | task-1 | 账户 / UAC / 自动登录 |
| `core\Plugins.psm1` | task-2 | 插件发现、校验、预览、执行 |
| `core\Engine.psm1` | Lead | 汇总 import + verb 分发表 |
| `core\Engine.ps1` | Lead | CLI 入口（解析 `-Verb/-Args/-Apply/-Out`） |
| `engine.cmd` / `run-ui.cmd` | Lead / task-3 | 双击入口 |
| `presets\account-login.json` | task-1 | 账户与登录预设包 |
| `plugins\cve-2026-49176\*` | task-2 | 样例提权插件 |
| `ui\ConfigUI.ps1` | task-3 | WinForms 前端 |
| `tests\SelfTest.ps1` | Lead | 端到端自测 |
| `var\logs\`、`var\backups\` | 运行时 | 日志与备份（可被 `LCT_VAR_DIR` 环境变量重定向，测试用） |
| `docs\CONTRACT.md`、`README.md`、`ARCHITECTURE.md` | Lead | 文档 |

## 3. Result 结构（**每个 verb 必须返回且只返回这一个 JSON 对象**）

```json
{
  "ok": true,
  "verb": "registry.set",
  "applied": false,
  "changes": [ { "kind": "registry", "target": "HKCU:\\Software\\X", "name": "Y",
                 "before": "1", "after": "2", "note": "" } ],
  "warnings": ["..."],
  "errors": [],
  "backupId": "20261025-193000-registry.set-ab12cd",
  "log": "C:\\...\\var\\logs\\engine-20261025.log",
  "data": {}
}
```

- `ok` = `errors` 为空。**预览（未落盘）也算 `ok=true`，只是 `applied=false`。**
- `applied`：本次是否真的写入。
- `changes[].kind` 取值：`registry` | `account` | `plugin` | `backup` | `note`。
- `data`：verb 各自的负载（见第 5 节）。
- 一律用 `New-LctResult`（见第 4 节）构造，不要手搓。

## 4. 公共函数（core\Logging.psm1，Lead 提供，直接调用，不要改）

| 函数 | 说明 |
|---|---|
| `Get-LctToolRoot` | 工具根目录（`core\` 的父目录） |
| `Get-LctVarDir` | `var\` 目录；若设置了环境变量 `LCT_VAR_DIR` 则用它（测试隔离用），并保证 `logs\`/`backups\` 存在 |
| `Get-LctLogPath` | 当天日志文件路径 `var\logs\engine-YYYYMMDD.log` |
| `New-LctId -Prefix <s>` | 生成 `yyyyMMdd-HHmmss-<prefix>-<rand6>` |
| `Write-LctLog -Verb <s> -Level info\|warn\|error\|change -Message <s> [-Data <obj>]` | 追加一行 JSON 日志，返回日志路径 |
| `New-LctResult -Verb <s> [-Applied] [-Changes @()] [-Warnings @()] [-Errors @()] [-BackupId <s>] [-Data <obj>]` | 构造第 3 节的 Result |
| `Test-LctElevated` | 当前进程是否已提权（bool） |
| `Move-LctToRecycleBin -Path <p> [-Directory]` | **唯一允许的删除方式**：送回收站 |
| `Remove-LctRegistryKeyTree -Path <HKCU:\...>` | 删除注册表子键树（内部用 .NET，**不要用 `Remove-Item`**） |
| `ConvertTo-LctJson -Object <o> [-Depth 8]` | 统一 JSON 序列化 |

`core\Backup.psm1`（Lead 提供）：

| 函数 | 说明 |
|---|---|
| `New-LctBackup -Verb <s> [-Args <o>] [-RegistryPaths @()] [-AccountSnapshot <o>]` | 创建备份目录，导出注册表为 `.reg`；键原本不存在时写 `<file>.reg.absent` 记录「原本无此键」；有账户快照时写 `account-before.json`。返回 `@{ id; dir; files }` |
| `Get-LctBackupList` | 列出所有备份（id/created/verb/files） |
| `Get-LctBackup -Id <s>` | 读单个备份的 meta + 文件清单 |
| `Restore-LctBackup -Id <s> [-Apply]` | 还原**注册表**部分：`.reg` → `reg import`；`.reg.absent` → 删除该键。返回 Result（`data.accountSnapshot` 有值时不处理账户，交由 Engine 调 `Restore-LctAccountState`） |
| `Remove-LctBackup -Id <s>` | 删除备份目录 → **回收站** |

## 5. verb 清单（冻结）

CLI：`Engine.ps1 -Verb <v> -Args <json字符串|@文件路径> [-Apply] [-Out json|text]`

| verb | Args 字段 | 返回 data |
|---|---|---|
| `engine.verbs` | — | `[{verb,summary,args:[{name,type,required}],mutating:bool}]`（前端据此自动生成界面） |
| `presets.list` | — | `[{id,name,description,risk,items:[{id,title,summary,verb,args}]}]` |
| `presets.show` | `preset` | 单个预设包详情 |
| `presets.apply` | `preset`,`item`(可选),`itemArgs`(可选) | 计划步骤 + 执行结果（每步一个 change） |
| `registry.get` | `path`,`name`(可选) | `{path,name,type,value}`；键/值不存在时 `ok=false` |
| `registry.set` | `path`,`name`,`value`,`type`(String\|ExpandString\|DWord\|QWord\|MultiString\|Binary) | `{path,name,type,value}` |
| `registry.delete` | `path`,`name` | `{path,name,removed:bool}` |
| `account.status` | — | `{user,users,groups,uac,autologon}`（见 §6） |
| `account.admin` | `enable`(bool) | `{name:"Administrator",enabledBefore,enabledAfter}` |
| `account.uac` | `enable`(bool) | `{values:{...}}` |
| `account.autologon` | `enable`(bool),`user`, `passwordFile`(仅 enable 需要) | `{enabled,user,hasPassword}`（**永不返回密码**） |
| `plugins.list` | — | `[{id,name,version,risk,description,params,path}]` |
| `plugins.show` | `plugin` | 单个插件详情（含 entry 解析后的绝对路径） |
| `plugins.run` | `plugin`, `params`(对象), `timeout`(秒，上限 600) | 预览时 `{command,resolvedParams}`；执行时 `{exitCode,logPath,stdoutTail,stderrTail,command}` |
| `backup.list` | — | 同 `Get-LctBackupList` |
| `backup.show` | `id` | 单个备份详情 |
| `backup.restore` | `id` | 还原结果（含账户快照还原） |

**写类 verb**（`registry.set/delete`、`account.*`、`presets.apply`、`plugins.run`、`backup.restore`）默认只预览；只有 `-Apply` 才落盘/执行。
`plugins.run` 即使 `-Apply` 也**不会**自动执行第二个插件；一次调用只执行一个。

## 6. `account.status` 的 data 形状（前端按此渲染）

```json
{ "user": { "name":"时", "domain":"DESKTOP-X", "isAdminToken":false, "inAdminGroup":true },
  "users": [ {"name":"Administrator","enabled":false,"isAdmin":true,"description":""} ],
  "groups": { "Administrators": ["DESKTOP-X\\时","DESKTOP-X\\Administrator"] },
  "uac": { "enableLUA":1, "consentPromptBehaviorAdmin":5, "promptOnSecureDesktop":1,
           "enableInstallerDetection":1, "path":"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" },
  "autologon": { "enabled":false, "user":"", "hasPassword":false,
                 "path":"HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" } }
```

## 7. 安全铁律（违反即返工）

1. **预览优先**：写类 verb 无 `-Apply` 时绝对不许落盘；预览也必须给出准确的 `before`/`after`。
2. **先备份后写**：任何真实写入前必须先 `New-LctBackup`，并把 `backupId` 填进 Result。
3. **不碰密码**：`account.autologon` 的口令只从 `passwordFile` 读；不得出现在命令行参数、日志、备份 meta、Result 里（备份 meta 只记 `hasPassword`）。同时必须在 `warnings` 里说明 `AutoAdminLogon` 明文存盘的风险，并提示更安全的 Sysinternals Autologon（LSA secret）。
4. **不永久删除**：文件/目录删除只用 `Move-LctToRecycleBin`；注册表键删除用 `Remove-LctRegistryKeyTree`（**禁止 `Remove-Item`**，本机有删除守卫会拦截）。
5. **不改系统更新/遥测/安全组件**：本版预设只覆盖「账户与登录」。不要自作主张添加其它类别的预置项。
6. **原子性**：一次写多个值必须要么全成要么回滚到 `before`，失败时 `ok=false` 并在 `errors` 说明。
7. **幂等**：重复 apply 同一操作不应报错（值已一致时 `changes` 里 `note` 标「无变化」）。

## 8. 编码与写法约定

- `.ps1` / `.psm1` / `.md` / `.json` 一律 **UTF-8 带 BOM** 保存；`.cmd` 一律纯 ASCII。
  （原因：Windows PowerShell 5.1 会把无 BOM 的文件按 ANSI/GBK 解析，中文注释与字符串会乱码——本项目已因此踩过坑。Lead 会做一次全量 BOM 归一化，但你提交前应自查。）
- 所有模块必须能在 **Windows PowerShell 5.1** 下运行（目标运行环境就是它）。
- 模块内不要 `Set-StrictMode`（避免影响别的模块）。
- 不要依赖第三方模块；只用 .NET BCL + Windows 自带工具。
- 每个模块顶部写简短注释：职责、作者(task-id)、导出函数列表。

## 9. 验收方式

1. `powershell -NoProfile -ExecutionPolicy Bypass -File tests\SelfTest.ps1`
   —— 覆盖：预览不落盘、apply 落盘、备份生成、还原回滚、预设加载、插件预览不执行、`engine.verbs` 自描述。
2. `powershell -NoProfile -ExecutionPolicy Bypass -File ui\ConfigUI.ps1 -SelfCheck` → 打印 `OK`，退出码 0。
3. 全部测试在 `LCT_VAR_DIR` 指向临时目录下跑一遍，确认不污染 `var\`。
## 10. 修订记录与补充约定（2026-10-25 集成期新增，均为实测结论）

1. **参数通道**：引擎 CLI 新增 `-ArgsFile <路径>`。含引号/反斜杠的 JSON **必须**走文件通道；
   内联 `-Args '<json>'` 在跨进程命令行层会被转义规则破坏（实测报 `Invalid JSON primitive: HKCU.`）。
   `-Args @文件` 与 `-Args <文件>` 仍可用。前端固定用 `-ArgsFile`。
2. **模块返回值两种风格都接受**：模块可返回「完整 Result」或「裸数据」，引擎的 `Use-LctModuleReturn`
   会统一：Result 原样透传（**不再包一层**，否则前端拿到 `data.data.value` 双层结构），裸数据包成 Result。
   getter 建议返回裸数据（契约 §5 的 data 形状）；action 建议返回完整 Result。
3. **跨模块导入必须带 `-Global` 且有守卫**：
   ```powershell
   if ((Test-Path -LiteralPath $lctLoggingModule) -and (-not (Get-Command New-LctResult -ErrorAction SilentlyContinue))) {
       Import-Module $lctLoggingModule -Force -Global -ErrorAction Stop
   }
   ```
   模块作用域里**不带 `-Global`** 的 `Import-Module -Force` 会把已全局加载的同名模块「抢」进本模块作用域，
   **导致全局注册被撤掉**（实测：`New-LctResult`/`Remove-LctRegistryKeyTree` 等集体消失，且 `Get-Module Logging` 看不到）。
   引擎在所有能力模块装载完之后，还会再 `-Global` 重导一次 Logging 兜底。
4. **不要用 `Get-Command` 探测跨模块函数是否存在**：在模块作用域下会误报（实测可用性报 false 而函数实际可调用）。
   可用性以「**模块是否装载成功**」为准（`$script:LctLoaded`）；缺函数交给 `try/catch`，
   由引擎把 `CommandNotFoundException` 转成「依赖未就绪：…」，并由 `engine.verbs.data.loadErrors` 给出装载失败原文。
5. **输出序列化深度**：引擎出口用 `ConvertTo-Json -Depth 12`（`ConvertTo-LctJson` 默认 8）。
   深度不足会把嵌套数组压成字符串（`"System.Object[]"`）、嵌套对象压成空，前端会看到 `users=1` 这类假象。
6. **编码**：改完含中文的 `.ps1/.psm1/.json/.md` **必须**跑 `tests\Fix-Encoding.ps1`。
   编辑工具重写文件会丢 BOM；丢 BOM 时 PS 5.1 按 GBK 解析，中文会吞掉引号 → **整个文件解析失败**。
7. **前台验收**：`tests\SelfTest.ps1` 退出码 = 失败项数；`ui\ConfigUI.ps1 -SelfCheck` 必须打印 OK 且退出码 0。
8. **简单函数禁止用 `$Args` 作参数名**（backend-accounts 自查发现并实测，2026-10-25）：
   没有 `[Parameter()]` 特性的**简单函数**里，形参 `$Args` 会被自动变量 `$args` 顶掉 ——
   `-Args <对象>` 会静默绑成空 `Object[]` 且**不报错**（实测 `count=0`），接收方读不到任何字段。
   后果是「快照还原」这类逻辑会静默跳过：回滚看似成功，其实 Administrator/UAC/自动登录都没还原。
   需要接收参数包时写成 `[Alias('Args')][object]$ArgBag`。
   **高级函数（带 `[Parameter(Mandatory)]` 等特性）不受影响**：引擎的 `Invoke-LctEngine`、
   `New-LctBackup`、`Restore-LctBackup` 都是高级函数（已实测 `backup meta.args` 正常）；
   `Engine.ps1` 从一开始就用 `[Alias('Args')][string]$ArgsJson`，正好避开这个陷阱。
## 11. 新增能力：进程监控 / 加载阻断 / WDAC（2026-10-26，Lead 冻结）

### 11.1 权限模型（用户明确：直接用漏洞提权得到的 SYSTEM）
- 引擎/界面**不自己造 SYSTEM**：以调用者当前权限运行即可（本机常态是提权管理员；需要 SYSTEM 时
  走已有的提权插件或 `schtasks /ru SYSTEM` 承载，工具只如实上报当前身份与失败原因）。
- **不假装能杀一切**：PPL/受保护进程（如 `MsMpEng`、`csrss`、`lsass`）用户态永远杀不掉，
  `process.kill` 必须把 `OpenProcess(PROCESS_TERMINATE)` 的失败原因如实返回（access denied ≠ 不存在）。

### 11.2 `core\Processes.psm1`（新模块，导出）
| 函数 | 说明 |
|---|---|
| `Get-LctProcessList -Name -User -IncludeSystem -Limit` | 进程快照（pid/name/user/session/path/wsMB/cpu/startTime/是否关键进程） |
| `Get-LctProcessDetail -Id` | 单进程详情 + **能否取得 PROCESS_TERMINATE** 的实测结论 + 是否疑似受保护 |
| `Stop-LctProcess -Id -Name -Path -Override -Apply` | 终止（默认预览）；**关键/安全软件目标必须 `-Override` 且记日志** |
| `Start-LctProcessWatch -Targets -IntervalSec -DurationSec` | **会话内**看门狗：被杀后复活再杀；单实例；到点/停止即结束 |
| `Get-LctProcessWatchStatus` / `Stop-LctProcessWatch` / `Get-LctProcessWatchLog` | 监控状态 / 停止 / 事件日志 |
| `Set-LctProcessBlock -Path -Reason -Apply` / `Remove-LctProcessBlock -Path -Apply` | **IFEO 重定向**：让目标程序根本无法启动（可秒级回滚；须同时处理 `Wow6432Node` 视图） |
| `Get-LctProcessBlockList` | 当前由本工具设置的重定向清单 |

铁律：
1. **不落地任何持久化**：看门狗只在当前会话/进程内循环，引擎退出即停；不装服务、不注册自启、不隐藏。
2. 目标必须**显式指定**（pid/name/path），**禁止通配与"杀全部"**。
3. **关键进程与安全软件名单**（至少含 `MsMpEng`、`NisSrv`、`MsSense`、`csrss`、`lsass`、`services`、
   `smss`、`wininit`、`winlogon`、`dwm`、`svchost`、`System`、`Registry`、`SgrmBroker`、`audiodg`
   以及本机已安装的安全软件进程如 `Avira*`）**必须 `-Override` 才允许终止**，并写 `warnings` 与审计日志。
4. 看门狗重杀前必须**按 name/path 复核目标身份**，避免 pid 复用误杀。
5. `Set-LctProcessBlock` 写注册表前必须 `New-LctBackup`（记录原值/原不存在），并支持 `Remove` 完整回滚。

### 11.3 `core\Wdac.psm1`（新模块，导出）
| 函数 | 说明 |
|---|---|
| `Get-LctWdacStatus` | CI 强制状态 / 现有策略 / Secure Boot / VBS / 策略文件路径（只读） |
| `Get-LctWdacRules` / `Add-LctWdacRule` / `Remove-LctWdacRule` | 维护自管黑名单（`var\wdac\rules.json`）：path / fileName / hash |
| `New-LctWdacPolicy -Mode audit\|enforce -ScanPath -StagingDir` | 用 ConfigCI 生成策略 XML + `.cip`，**全部落在 `var\wdac\staging\`** |
| `Test-LctWdacPolicy -XmlPath` | **安全校验**：缺 allow-all/误开强制 等危险情形必须**拒绝**并说明；缺 `Advanced Boot Options Menu`/`Boot Audit On Failure` 必须告警 |
| `Deploy-LctWdacPolicy -XmlPath -ConfirmText -Apply` | 全量备份现有 `CodeIntegrity` 策略 → 部署 → 写 `revert.cmd` + 恢复说明；**强制模式必须显式 confirm** |
| `Restore-LctWdacPolicy -Stamp -Apply` | 按备份戳恢复/移除策略（预览优先） |
| `Get-LctWdacVerify` | 重启后校验：CI 状态 + `Microsoft-Windows-CodeIntegrity/Operational` 事件（判定策略是否真的放行其余程序） |

铁律：
1. **默认 audit**：`New-LctWdacPolicy` 不带 `-Mode enforce` 时保留 `Enabled:Audit Mode`。
2. **无法证明安全就不许强制**：`Test-LctWdacPolicy` 判定「策略无任何 allow 机制」⇒
   禁止强制部署（只允许 audit），并把原因写进 `errors`。
3. **必须先备份**：`Deploy` 前把现有 `SiPolicy.p7b`/`CiPolicies\Active\*` 复制到
   `var\backups\wdac-<stamp>\`，并生成 `revert.cmd`（含离线恢复说明：F8 → 启动设置 → 禁用强制，或 WinRE）。
4. **`-ScanPath` 必填**：缺省时**拒绝执行**（`New-CIPolicy` 默认全盘+卷影扫描，实测会跑很久且产出巨大 XML）。
5. 策略必须包含 `Enabled:Advanced Boot Options Menu` 与 `Enabled:Boot Audit On Failure`（坏策略的救命绳）。
6. 一切部署/回滚都要 `Write-LctLog`；UI 必须显示「**需重启生效**」与恢复步骤。

### 11.4 新增 verb（`engine.verbs` 自描述同步更新）
`process.list` / `process.detail` / `process.kill` / `process.watch.start` / `process.watch.status` /
`process.watch.stop` / `process.watch.log` / `process.block.set` / `process.block.remove` / `process.block.list` /
`wdac.status` / `wdac.rules.list` / `wdac.rules.add` / `wdac.rules.remove` / `wdac.policy.build` /
`wdac.policy.validate` / `wdac.deploy` / `wdac.revert` / `wdac.verify`
### 11.5 函数签名（Engine 已按此接线，实现方必须一致）

```powershell
# Processes.psm1
Get-LctProcessList  -Name <string> -User <string> -IncludeSystem <switch> -Limit <int>
Get-LctProcessDetail -Id <int>
Stop-LctProcess      -Id <int> -Name <string> -Path <string> -Override <switch> -Apply
Start-LctProcessWatch -Targets <string[]> -IntervalSec <int> -DurationSec <int>
Get-LctProcessWatchStatus      # 无参
Stop-LctProcessWatch           # 无参
Get-LctProcessWatchLog         # 无参
Set-LctProcessBlock    -Path <string> -Reason <string> -Apply
Remove-LctProcessBlock -Path <string> -Apply
Get-LctProcessBlockList        # 无参

# Wdac.psm1
Get-LctWdacStatus              # 无参
Get-LctWdacRules               # 无参
Add-LctWdacRule    -Kind <path|fileName|hash> -Value <string> -Reason <string> -Apply
Remove-LctWdacRule -Kind <path|fileName|hash> -Value <string> -Apply
New-LctWdacPolicy  -Mode <audit|enforce> -ScanPath <string> -Apply     # -Mode 默认 audit
Test-LctWdacPolicy -XmlPath <string>
Deploy-LctWdacPolicy -XmlPath <string> -Mode <audit|enforce> -ConfirmText <string> -Apply
Restore-LctWdacPolicy -Stamp <string> -Apply
Get-LctWdacVerify              # 无参
```

约定：`-Id`/`-Limit` 为 0 表示不限；`-Mode` 缺省 `audit`；`-Apply` 缺省即预览。
`Set-LctProcessBlock` 的 `-Path` 接受完整 exe 路径或纯文件名（后者按 IFEO 惯例只取文件名）。
### 11.6 已知形状陷阱：getter 返回裸数组时的 JSON 折叠（backend-wdac 实测，2026-10-26）

`Use-LctModuleReturn` 对「裸数组」返回值只做一层 `-Data $R` 包装，而 **`ConvertTo-Json` 会把空数组
折成 `null`、把单元素数组折成裸对象**（多元素才保留数组）。因此像 `wdac.rules.list` 这种直接返回
数组的 verb，`data` 会出现**三种形态**（都没有 `items` 键）：

| 规则条数 | `data` |
|---|---|
| 0 | `null` |
| 1 | 单个对象（`id/kind/value/reason/added`） |
| n ≥ 2 | 数组 |

**消费方必须归一化**：`@($resp.data)`（ui-expansion 已这样做，0/1/n 全覆盖）。
**不要用 `(,$R)` 之类“防折叠”包装** —— 实测它会产出 `{"value":[],"Count":0}` 这种 PowerShell
数组适配器形状，比原问题更糟（Lead 试过并已撤回）。
更彻底的修法是模块侧返回包装对象（参考 `process.block.list` 的 `{items,count,byUsCount,...}`），
但那会改变既有形状、影响已对接的 UI，故保持现状并在此备案。

另：`process.list` 返回的是 `{identity,items[],count,matched,truncated,...}` 的**包装对象**
（形状稳定，不受上述折叠影响）；`process.block.list` 同理。新增 getter 时**优先返回包装对象**。
### 10.9 实例与教训：一个「7 道门全绿却是坏的」全站性 bug（2026-10-26）

**实例**：`Add-LctPending`（原作者 task-3）是**简单函数**却把参数名写成 `$Args` ⇒ 被自动变量 `$args`
静默顶掉 ⇒ **所有页面**的「待应用」参数包都是空的 `{}`；`Invoke-LctApplyPending` 把空包发给引擎 ⇒
注册表 / 账户 / 预设 / 插件 / 备份**以及新增两页**的「应用」全部失败或空跑。而当时
`SelfTest ALL GREEN`、`UiPageSmoke GREEN`、`-SelfCheck OK` —— **7 道门全绿照不出来**。

**修法**：`[Alias('Args')][object]$ArgBag`（调用点 `-Args <对象>` 无需修改）；并在
`Invoke-LctApplyPending` 加护栏：verb 声明了必填参数而参数包为空 ⇒ **中止并提示「请重新预览」**，
绝不静默向引擎发空 `{}`。

**为什么门禁没抓到**：`-SelfCheck` 只构建控件；`UiPageSmoke` 当时只断言「登记了 N 条」。
**已补的两条护栏（都不要删）**：
1. `tests\UiPageSmoke.ps1`：断言待应用项的参数包**带真实载荷**（`ConvertTo-Json` 后必须同时含
   `preset` 与 `item`）。修复前该断言会看到 `[]` 而判 FAIL。
2. `tests\Lint-PowerShell.ps1`：修正「advanced 函数」的判定 —— PowerShell AST 会把 `[string]` 这类
   **类型约束**也算进 `$p.Attributes`，旧判据（"有属性就算 advanced"）因此把
   `param([string]$Page, $Args, ...)` 误判为 advanced 而**永远漏检**。现改为
   「有 `[CmdletBinding()]` 或某形参带 `[Parameter()]` 才算 advanced」，非 advanced 函数里任何
   形参名等于 `Args` 一律报问题；并新增 `-SelfTest`（6 条 AST 用例，其中 2 种正确写法必须不误报）。
   同批还新增「**解析失败**」规则（文件不可解析是最响的问题，Lint 直接报出来）。

**通用教训**：任何「预览 → 待应用 → 应用」链路，验收必须断言**待应用项里到底装了什么**——
只断言「登记了 1 条」是**假绿**。另：插入代码块时注意 PowerShell 允许 `}` 换行接 `else`，
但 `else` 必须紧跟**它自己的** `if`；把新语句插到 `if` 与 `else` 之间会产生孤儿 `else`（本会话踩过）。
## 12. 插件 SDK v2（P0 扩展性重构）——Lead 冻结接口（2026-10-26）

设计全文见 `docs\PLUGIN-SDK.md`。本节只钉**实现方必须逐字一致的接口**。

### 12.1 新增模块 `core\PluginSdk.psm1`（导出**恰好 7 个**：下面代码块逐一点名，以此为准）

```powershell
Get-LctPluginKindRegistry                 # -> hashtable: kind -> [pscustomobject]@{ name; isolation; needsApply; entryRequired[]; summary }
Get-LctPluginCapabilityTable              # -> hashtable: capability -> [pscustomobject]@{ name; risk='low|medium|high'; needsConfirm=[bool]; summary }
Test-LctPluginManifestV2 -Obj <obj> -Dir <string> -Id <string>
      # -> [pscustomobject]@{ ok; errors=@(); warnings=@(); manifestVersion=[int];
      #                       engineApiOk=[bool]; capabilities=@(); kinds=@(); degraded=[bool] }
Test-LctPluginIntegrity  -Dir <string> -Integrity <obj>      # -> @{ ok; errors=@(); checked=@() }
Test-LctPluginEngineApi  -Requirement <string> -EngineApi <string>   # -> @{ ok; errors=@(); reason }
Get-LctPluginChecksum    -Path <string>                      # -> @{ ok; sha256; size; error }
Get-LctPluginEngineApiVersion                             # -> '1.0'（无参、只读、不抛；§12.2 第 5 条说的“可查”就是它）
```

### 12.2 硬性语义（违反即返工）

1. **本模块任何函数都不得 throw**：一律返回 `ok=false` + `errors`（引擎依赖这个做可读降级）。
2. `capabilities` 里出现**能力表之外**的名字 ⇒ `ok=false`（点名缺哪个）；`kinds`/`entry.kind` 不在
   种类注册表里 ⇒ `ok=false`。
3. **路径安全**：`entry.path`、`integrity.sha256` 的键、`lifecycle.*` 的命令里出现的相对路径，
   只要含 `..` ⇒ `ok=false`。
4. **v1 兼容**：清单缺 `manifest`/`engineApi`/`capabilities` ⇒ `ok=true`、`degraded=true`，
   并在 `warnings` 里说明「按 v1 规则运行」。**不得**因为缺 v2 字段就拒绝老插件。
5. `engineApi` 为形如 `>=1.0 <2.0` 的区间；引擎版本常量 `1.0`（由 `Get-LctPluginEngineApiVersion` 无参只读返回，当前值 '1.0'，任何情况下不得 throw）。
   不满足 ⇒ `engineApiOk=false`（仍 `ok=true`，由调用方决定是否拒绝；`degraded` 时为 true）。
6. `integrity.sha256` 与实际不符 ⇒ `ok=false`；文件不存在 ⇒ `ok=false`。
7. `Get-LctPluginKindRegistry` 的初始内容（P0）：`ps1`（子进程）、`exe`（子进程）。
   **加种类 = 加一条表项**，解析器与执行器不得再出现 kind 的硬编码分支。
8. `Get-LctPluginCapabilityTable` 的初始内容（P0，命名空间化）：
   `read.process` `write.process` `read.registry` `write.registry` `read.fs` `write.fs`
   `account.change` `service.control` `network.out`（risk 与 needsConfirm 由实现方按语义填，
   但 `write.process`/`write.registry`/`account.change`/`service.control` 必须 `needsConfirm=true`）。
9. 全部文案中文；文件 UTF-8 带 BOM；**PowerShell 5.1 可运行**；不要 `Set-StrictMode`；
   形参名不得用 `$Args`（契约 §10.8）；不得用只读自动变量名（§10.6）。

### 12.3 集成点（Lead 负责改，实现方不要碰）

- `core\Plugins.psm1` 的 `Get-LctPluginManifest` 在原有 v1 解析之后，**有条件地**调用
  `Test-LctPluginManifestV2`（函数不存在则跳过 ⇒ 保证可独立落地）；
- `Invoke-LctPlugin` 的 kind 分派改为查 `Get-LctPluginKindRegistry`；
- `tests\Run-AllGates.ps1` 增加两道门：`tests\Lint-Plugin.ps1`、`tests\PluginSdkTest.ps1`。

集成已完成（Lead 实测）：

1. `plugins.*` 的参数键是 **`plugin`**（不是 `id`）；`plugins.run` 需 `-Apply` 才真执行。
2. `plugins.run` 的 `data` 键实测为
   `exitCode, logPath, stdoutTail, stderrTail, command, resolvedParams, timeout, timedOut, durationSeconds`；
   **不是 `data.stdout`**（`docs\PLUGIN-SDK.md` §7 已同步更正）。P1 加字段只增不改。
3. v1 插件：`manifestVersion=1 / degraded=true / engineApiOk=true / capabilities=()` + 3 条 v1 warnings；
   v2 清单：`manifestVersion=2 / degraded=false`。`plugins.show` 已按 §12.3 暴露
   `manifestVersion/degraded/capabilities/kinds/engineApiOk/sdkWarnings`。
4. 门禁已扩到 **9 道**（原 7 道 + `Lint-Plugin` + `PluginSdkTest`），实测 9/9 PASS。

### 12.4 边界（写死，不因后续需求放宽）

本 SDK **不得**提供：加载任意内核载荷、执行任意内核命令、绕过签名强制（改 testsigning / 关
VBS·HVCI / 碰 DSE / 写 nointegritychecks）、隐藏或伪装、针对安全产品（杀软·EDR·反作弊）的
停止/屏蔽/绕过流程。`driver` 类若将来实现，仅限 `docs\PLUGIN-SDK.md` §10 的「允许项」。

## 12. 新增能力：自定义驱动加载（2026-10-26，按操作者口径冻结）

### 12.1 口径（操作者明确要求）
- 功能就是「**指定一个 .sys，把它加载起来**」。
- **不对驱动做任何前瞻门槛**：不要求已签名、不要求任何状态；**签名与否交给操作系统自己判定**——
  未签名且 DSE 生效时系统会拒绝（典型 `sc start` 返回 **577 Windows cannot verify the digital
  signature**），工具**照抄回显该错误**；若 test-signing 已开启则正常加载。
- 因此 `driver.load` 的**唯一**门槛是「启动类型 / 服务名冲突」这类**稳定性与可回滚性**保护，**与签名无关**。

### 12.2 本机前提（实测 2026-10-26，决定它现在就能用）
```
Secure Boot                 = False
bcdedit testsigning         = Yes      ← 已开启，无需重启即生效
bcdedit nointegritychecks   = No
VBS=0 · HVCI 未运行 · WDAC/CI 策略未强制
C:\Windows\System32\drivers 可写 = True
sc.exe / bcdedit.exe / Get-AuthenticodeSignature 可用；无 lctdrv* 服务名占用
```
⇒ **本机此刻即可加载 test-signed / 未签名驱动**；签名判定只是「信息」，不是「门槛」。

### 12.3 `core\Drivers.psm1` 导出（签名钉死，Engine 按此接线）
| 函数 | 说明 |
|---|---|
| `Get-LctDriverStatus` | Secure Boot / testsigning / nointegritychecks / VBS / 驱动总数与运行数 / 自管服务清单（只读） |
| `Get-LctDriverList -Name` | 驱动服务清单：name / state / startType / path / sha256 / Authenticode 摘要（**仅信息**） |
| `Get-LctDriverFileInfo -Path` | 单个 .sys 的 hash + 签名摘要 + 是否 test-signed（**仅信息，不作为门槛**） |
| `Load-LctDriver -Path -Name -StartType -Stage -Override -Apply` | **主功能**：注册（若不存在）+ 启动；返回 SCM 真实结果与错误原文 |
| `Start-LctDriver -Name -Apply` | 仅启动已有服务；回传 OS 判定原文 |
| `Stop-LctDriver -Name -Apply` | 停止（不删服务项） |
| `Remove-LctDriverService -Name -Apply` | stop + 删除服务项 + 生成 revert.cmd（**不删 .sys 文件**） |
| `Set-LctDriverTestSigning -Enable -Disable -Apply` | `bcdedit /set testsigning on|off`；记录原值；Secure Boot=True 时**拒绝开启**；标注**需重启生效** |
| `Get-LctDriverVerification -Name` | 加载后复核：服务实际状态 + 是否真的运行 + 系统事件（7000/7026/219）原文 |

### 12.4 铁律（违反即返工）
1. 默认**只预览**，`-Apply` 才真做；每个动作写审计日志（`Write-LctLog`）。
2. **启动类型默认 `demand`（手动）**；`system` / `boot` **必须 `-Override`**（开机即载是蓝屏/无法启动的高危路径），
   命中时结果里必须红字标注后果。
3. 注册前若**同名服务已存在** ⇒ **拒绝覆盖**（除非 `-Override`，且先备份该服务的注册表键与画像）。
4. 卸载**只删服务项，绝不删 `.sys` 文件**；删除前 `sc stop`；生成 `revert.cmd`（含重建命令与原始参数）。
5. **原样回传系统判定**：把 SCM/内核的返回码与错误文本照抄（577 / 1058 / 1053 / 2 / 1 / 127 / 0xC000012F 等），
   **不美化、不吞掉、不猜测**；`applied=true` 只代表我们执行了动作，**加载成功与否以系统返回为准**。
6. `testsigning` 开关：写 `bcdedit` 前记录原值；**Secure Boot=True 时拒绝开启**并说明原因；结果必须提示**需重启生效**。
7. **测试不得真的加载任何内核代码**：用「无效镜像」走完 注册→启动→卸载 全链路，
   断言拿到的是 OS 的真实拒绝原因，并断言服务项与系统状态**零残留**。
8. 禁止直接永久删除（一律走 Move-LctToRecycleBin / 回收站；见 §10 删除铁律）；文件 UTF-8 带 BOM；改完必跑 `tests\Fix-Encoding.ps1` 与 `tests\Lint-PowerShell.ps1`；
   **不得用只读自动变量作变量名**（`$pid`/`$host`/…），不要用 `$Args` 作简单函数形参名。

### 12.5 新增 verb
`driver.status` / `driver.list` / `driver.info` / `driver.load` / `driver.start` / `driver.stop` /
`driver.unload` / `driver.testsigning` / `driver.verify`
## 13. 驱动通用化：契约通用 + 配置通用（2026-10-27，按操作者提问冻结）

### 13.1 结论（先说答案）
驱动的控制接口**不自描述**（`.sys` 里没有 IOCTL 元数据、设备名无标准），所以"通用加载器"只有两条路：
**① 对方遵守我们的 ABI（自研驱动）；② 为每个驱动写一份「适配描述」(driver profile)（第三方/漏洞驱动）。
通用的是「描述格式 + 执行引擎」，不是驱动本身。** 任何声称"任意驱动拿来就能执行任意命令"的设计都是
在骗人——除非它把每个驱动都逆向一遍。

### 13.2 分层（核心：能力层不许为每个驱动写一遍 exec）
```
L4 能力层（与驱动无关）：exec.cmd / kill.protected / kread / kwrite / patch.dse / load.driver …
L3 内核原语层（少量、明确、必须可 dry-run）：kread / kwrite / phys_rw / msr / call / map_section
L2 适配层 = 每驱一份 profile（纯数据）：定位法 + IOCTL + 结构布局 + 调用约定 + 指纹 + 风险等级
L1 驱动层：自研 / 第三方 / 漏洞驱动
```
**关键决策**：`exec.cmd` **不建立在"驱动能执行命令"上**，而是建立在 **1~2 个最普遍的原语**（首选任意内核读写）
之上，由**一个通用用户态 stager** 完成：内核原语 → 提权到 SYSTEM / 解 PPL → **用户态起进程**。
理由（实测常识）：从内核直接 `ZwCreateUserProcess` 极脆（CSRSS 通知依赖、IRQL/上下文限制、漏洞驱动的
调用线程常不允许），而"内核改 token + 用户态起进程"只依赖一个稳定原语，**换驱动不用改一行命令执行代码**。

### 13.3 「驱动在哪」= 两层，分开解
**A. `.sys` 文件路径（注册表权威，已实测）**：
`HKLM\SYSTEM\CurrentControlSet\Services\<name>\ImagePath` → 解析 `System32` / `\SystemRoot` 前缀；
为空则回退 `System32\drivers\<name>.sys`；再不行按 **SHA256** 去 `DriverStore\FileRepository` 反查。
**B. 控制入口（设备对象名）**，按可用性排序：
1. **设备接口 GUID** + `CM_Get_Device_Interface_List`（最通用：客户端不需要知道名字）；
2. **符号链接候选集**（profile 声明 `\??\X` / `\\.\X` / 通配），用 `CreateFile` + **canary IOCTL 握手**逐个验证；
3. **自动发现**：`NtOpenDirectoryObject` + `NtQueryDirectoryObject` 枚举 `\Device`、`\GLOBAL??`，
   再用 `NtQueryObject` 把设备映射回**驱动对象 → 服务名**（本机实测：文件系统 API 枚举 `\Device` 失败
   "句柄无效"，**必须走 NT API**；但 `CreateFile "\\.\Nsi"` 成功，证明用户态入口可达）；
4. **兜底且危险**：IOCTL 盲扫（假定 METHOD_BUFFERED）。METHOD_NEITHER 驱动一碰可能立刻蓝屏 ⇒
   **默认禁用、单发、标 `riskLevel=bsod`、并要求先建还原点**。

### 13.4 profile 格式（数据，必须是可校验的）
```jsonc
{
  "id": "rtcore64-1.3.1",
  "kind": "driver-profile",
  "engineApi": 2,
  "target": { "sha256": "<.sys 指纹，必填；可加 sha256AnyOf[]>" , "fileName": "RTCore64.sys" },
  "locate": {
    "strategy": "symlink|interfaceGuid|serviceImagePath",
    "candidates": ["\\??\\RTCore64", "\\??\\RTCore*"],
    "interfaceGuid": "{...}",
    "serviceNameHint": "RTCore64"
  },
  "handshake": { "action": "ping", "expect": { "ioctl": "0x80002000", "minOutBytes": 4 } },
  "actions": {
    "kread":  { "ioctl": "0x80002048", "in":  [{"name":"addr","type":"u64"}], "out": [{"name":"value","type":"bytes","len":8}] },
    "kwrite": { "ioctl": "0x8000204C", "in":  [{"name":"addr","type":"u64"},{"name":"value","type":"bytes","len":8}] }
  },
  "layout": { "method": "buffered|neither|inout", "align": 8, "endian": "little" },
  "risk": { "level": "low|medium|bsod", "notes": "写坏地址会立刻蓝屏；写前必须记录原值" },
  "requires": { "restart": false, "admin": true, "elevation": "admin|system" }
}
```
**profile 只描述"怎么调用"，不含任何可执行代码。** 类型集合（首版）：`u8/u16/u32/u64/i32/i64/bytes(len|lenOf|lenFrom)/cstr/guid/handle`。

### 13.5 新增 verb
`driver.profile.list`（可带 `-Source builtin|user|plugin`）
`driver.profile.show -Id`
`driver.profile.validate -Id|-Path`（schema + 指纹 + 沙盒校验；**不碰内核**）
`driver.profile.draft -Path <.sys>`（静态草案：PE 解析 → 设备名字符串 → dispatch handler → 候选 IOCTL/输入大小）
`driver.profile.save -Id -Json -Override`（**另存 profile 到 `var\driver-profiles\**：默认只预览；先校验后写盘；同名需 -Override 且覆盖前**复制**进 `var\backups\`；写 UTF-8 **不带 BOM**、读取侧 BOM 容错；写完回读比对）
`driver.devices -Name <service>`（registry 解出文件路径 + 候选入口 `\??`/接口 + `CreateFile` 可用性）
`driver.ctl.send -Profile -Action -Payload -Apply`（**通用原语执行器**：定位设备 → 打包 → DeviceIoControl → 解包）
`driver.ctl.verify -Profile`（canary/握手：证明"这个设备确实是这个驱动且能通"）

### 13.6 铁律（违反即返工）
1. **默认预览**：`ctl.send` 不带 `-Apply` 只打印将发送的 IOCTL 与缓冲区十六进制；所有动作写审计日志。
2. **profile 必须过 validate 才允许执行**；`target.sha256` 与实际文件不符 ⇒ **拒绝**（布局错版本必蓝屏）。
3. **写类原语必须记原值并可还原**：`kwrite` 强制返回 `before` 并生成还原脚本；原语层不得提供"不带还原的写"。
4. **`risk.level=bsod` 的动作默认禁用**，需显式 `-OverrideBsod` + 结果红字标注；盲扫类动作另需 `-IUnderstand`.
5. **不实现"绕过系统强制策略"的默认路径**：WDAC/DSE 相关动作只做**如实探测与风险分级**，实际改由操作者按其判断显式触发。
6. **静态草案只是草案**：`draft` 产出必须带 `confidence` 与 `needsReview=true`，不得被当作可用 profile 直接执行。
7. **driver.profile.save 的额外铁律**：先校验后写盘（不合法拒绝）、同名需 `-Override` 且覆盖前**复制备份**（不删原文件）、写 UTF-8 **不带 BOM** 且读取侧必须 BOM 容错（`TrimStart([char]0xFEFF)`）、**写完回读比对**（不一致不许报成功）、只允许写 `var\driver-profiles\`。
7. 测试**不得对任何真实设备发未知 IOCTL**（会蓝屏）：测试只允许 (a) 对不存在的设备断言错误分类；
   (b) 用 `driver.ctl.send` 的预览路径断言缓冲区打包正确；(c) 用**假设备名**断言定位失败而不是硬发。