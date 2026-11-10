# LocalConfigTool 插件 SDK 与扩展性设计（v2 方案）

> 本文回答一个问题：**怎样让这个工具的扩展性变得"舒服"**。
> 结论先行：v1 的插件契约只有 5 个短板是真痛点（种类单一、无能力声明、无结构化输出、
> 无生命周期、无清单信任），其余都能靠增量补齐。方案见 §3–§9，实施顺序见 §11。

---

## 1. v1 现状（逐项实测，作为基准）

清单 `plugins\<id>\plugin.json` 的字段（由 `Get-LctPluginManifest` 读取并校验）：

| 字段 | 规则 |
|---|---|
| `id` | 必填，`^[A-Za-z0-9][A-Za-z0-9.\-_]*$` |
| `name` / `version` | 可省（回退 id / `0.0.0`） |
| `risk` | 只允许 `lab-only` / `high` / `medium`，非法则回退 `high` |
| `entry.kind` | **只允许 `ps1` / `exe`**，其他直接 throw |
| `entry.path` | 不得含 `..`（禁止越出插件目录） |
| `entry.args` | 字符串数组，逐个传给入口 |
| `params[]` | 每个含 name/title/type/required/default/secret/help |
| `outputs[]` | 纯文本说明（**不参与任何校验或契约**） |

执行链（`Invoke-LctPlugin`）：默认只预览；带 `-Apply` 才起子进程；超时控制；超时后
`Stop-LctProcessTree` 杀进程树；捕获 stdout / stderr / exitCode；`secret` 参数打码。

**已经做得好的**：预览/-Apply 闸门、参数校验与打码、超时与进程树清理、路径越界防护、
`risk` 分级、样例插件即文档。

## 2. 让扩展"不舒服"的 12 个具体点

| # | 问题 | 后果 |
|---|---|---|
| 1 | `entry.kind` 只有 `ps1`/`exe`，属**硬编码白名单** | 加一类能力就要改引擎代码（本次加 driver 就卡在这） |
| 2 | 插件**不能声明自己的 verb** | 只能"点一次跑一个脚本"，无法像 `registry.get` 那样被组合/被 UI 反射 |
| 3 | 无 `capabilities` 声明 | 引擎无法按"这个插件会写注册表/会杀进程/会装驱动"做**默认拒绝**与分级提示 |
| 4 | 输出只有 stdout/stderr/exitCode 三个字符串 | 调用方要各自写正则解析；无稳定字段、无 `changes/before/after` |
| 5 | 无生命周期概念 | 装完要手动记"怎么卸"；无 install/start/stop/uninstall 幂等动作 |
| 6 | 无 `engineApi` 版本门槛 | 插件升级/引擎升级互相踩；老插件在新引擎上静默走错分支 |
| 7 | 无完整性校验 | 清单/入口被换掉无从发现（只有 `..` 防护） |
| 8 | 全部能力都是"新起一个子进程" | 需要**长生命周期**的能力（看门狗、驱动服务）无处安放 |
| 9 | 无 settings 持久化 | 每次都要重填参数 |
| 10 | 无清单 lint / SDK 自测 | 清单写错要到运行时才炸 |
| 11 | 无并发/缓存 | 插件多了每次列目录都要重新解析 |
| 12 | 无错误分类 | "依赖没装"与"参数错"与"目标拒绝"混在一个字符串里 |

## 3. 设计原则（按优先级）

1. **能力声明 + 默认拒绝**：插件必须声明 `capabilities`，引擎按 `permissions` 逐项放行。
2. **故障局部化**：一个插件坏掉不许影响引擎/其他插件（verb 命名空间 + 隔离执行）。
3. **结构化输出**：所有插件返回统一 Result（复用契约 §3），`outputs[]` 只描述**文本**，字段另有 schema。
4. **可审计**：每次启用/运行/卸载都进 `var\logs`，含谁、何时、参数（打码）、结果。
5. **可回滚**：任何"安装类"动作必须自带卸载路径，且卸载前先备份/留痕。
6. **零信任清单**：清单与入口都可校验（哈希 + 可选签名 + 版本）。
7. **增量兼容**：`plugin.json` v1 插件**继续可用**，不强迫迁移。
8. **不新增"逃生舱"**：任何插件机制都不得提供隐藏、规避安全产品、绕过系统强制策略的能力。

## 4. 清单 v2（`plugin.json`，v1 是其子集）

```jsonc
{
  "manifest": 2,                        // 清单版本；缺省=1（v1 兼容路径）
  "engineApi": ">=1.0 <2.0",            // 引擎 API 门槛（语义化区间）
  "id": "driver-lab",
  "name": "驱动实验室（示例）",
  "version": "1.0.0",
  "description": "对显式指定的驱动做预检/装载/卸载（不支持任意载荷）",
  "risk": "high",                       // 兼容 v1 取值；v2 另加 "info"|"low"
  "capabilities": ["kernel.driver.install", "kernel.driver.start", "kernel.driver.stop"],  // 见 §6
  "kinds": ["driver"],                  // 本插件用到的入口种类，便于引擎预检
  "entry": { "kind": "driver", "path": "payload\\lab.sys", "serviceName": "LctLabDrv" },
  "lifecycle": {                        // 可选；每个动作都必须幂等
    "preflight": "run.ps1 -Action preflight",
    "install":   "run.ps1 -Action install",
    "start":     "run.ps1 -Action start",
    "stop":      "run.ps1 -Action stop",
    "uninstall": "run.ps1 -Action uninstall"
  },
  "verbs": [                            // 可选；让插件以 verb 形式暴露（§7）
    { "name": "status", "summary": "查看驱动服务状态", "mutating": false, "args": [] }
  ],
  "settings": [ /* 与 v1 params[] 同构，但会持久化到 var\plugins\<id>.json */ ],
  "permissions": { "requireElevated": true, "requireApply": true, "confirmText": "" },
  "integrity": { "sha256": { "payload\\lab.sys": "…" } },   // 可选；不符则拒绝
  "compat": { "osBuild": ">=19041", "arch": ["x64"], "notes": "…" }
}
```

**v1 → v2 迁移**：v1 插件原样可跑（引擎按 `manifest` 缺省=1 走老路径）。迁移只需补
`manifest` / `engineApi` / `capabilities` 三个键，其余字段名不变。

## 5. 入口种类矩阵（把硬编码白名单换成"种类注册表"）

| kind | 隔离级别 | 适用 | 备注 |
|---|---|---|---|
| `ps1` | 子进程（现状） | 一次性动作 | 保持现状，永久支持 |
| `exe` | 子进程（现状） | 原生小工具 | 保持现状 |
| `psm1` | 子进程内 hosted（复用 `WatchHost` 模式） | 需要**长生命周期**（看门狗、监控） | 宿主负责寿命与状态文件 |
| `driver` | **只做管理**，见 §10 | 驱动开发/分析/加固 | 铁律见 §10；**不含任意载荷装载** |

实现方式：`$script:LctPluginKindHandlers = @{ ps1 = …; exe = …; psm1 = …; driver = … }`，
`entry.kind` 查表；未注册种类 → `ok=false` + 可读错误（而不是像现在这样 throw 在清单解析处）。
**加新种类 = 加一条表项，不改解析器**（这是"舒服"的核心）。

## 6. 能力模型（capabilities）

命名空间化常量，引擎侧硬编码表（插件只能"申请"，不能自定义）：

```
read.process / write.process / read.registry / write.registry / read.fs / write.fs
account.change / service.control / kernel.driver.install / kernel.driver.start / kernel.driver.stop
policy.wdac / network.out
```

引擎规则：
1. 未声明的能力被调用 → **拒绝**（`ok=false`，错误里点名缺哪个能力）；
2. `kernel.*` / `policy.wdac` / `write.registry(HKLM)` 等高风险能力：UI 必须**逐条列出**再让用户点确认；
3. 所有能力调用写审计日志（含能力名、目标、结果）；
4. 能力表由**引擎**维护，插件清单里的多余/未知能力 → 拒绝装载该插件。

## 7. verb 命名空间与 Result 契约

- 插件 verb 暴露为 `plugin.<id>.<verb>`，与内置 verb 同一张 `engine.verbs` 表（带 `owner` 字段）；
- 插件 verb 必须返回契约 §3 的 Result（`ok/applied/changes/warnings/errors/data/backupId/log`）；
- 引擎把插件的输出放进 `data.stdoutTail` / `data.stderrTail`（**不是 `data.stdout`** ——
  P0 实测字段名见下），另附 `data.exitCode` / `data.command` / `data.logPath` /
  `data.resolvedParams` / `data.timedOut` / `data.durationSeconds`，**不再要求调用方正则解析 stdout**。

  实测（`plugins.run -Apply`，v2 参考插件，PS 5.1）的 `data` 键：
  `exitCode, logPath, stdoutTail, stderrTail, command, resolvedParams, timeout, timedOut, durationSeconds`。
  P1 要做「结构化输出」时**只增不改**：在这组字段之外再加 `data.json`（入口声明了输出 schema 才填充），
  绝不动 `stdoutTail`（那是 v1 兼容面）；
- 预览/应用语义与内置 verb 完全一致（`-Apply` 才落盘）；
- 错误分类固定为：`依赖未就绪` / `参数错误` / `目标拒绝` / `策略拒绝` / `超时` / `未知`。

## 8. 生命周期与回滚

每个"安装类"动作必须满足：

1. `preflight` 返回**将要做什么**（预览，零副作用）；
2. `install` 前**先备份**（`New-LctBackup`），返回 `backupId`；
3. `uninstall` 必须能回到 install 前状态；
4. 每个动作幂等：重复 install 返回 `applied=false` + 说明"已存在"；
5. 卸载/删除文件只走 `Move-LctToRecycleBin`，注册表键只走 `Remove-LctRegistryKeyTree`（删除铁律）；
6. 恢复说明写进 `var\plugins\<id>\recovery.txt`（给未来的自己看）。

## 9. 测试与验收（缺这个，"扩展舒服"就是空话）

1. **清单 lint**：`tests\Lint-Plugin.ps1` —— 校验 schema、能力名合法、路径不越界、sha256 与实际相符；
2. **SDK 自测**：`tests\PluginSdkTest.ps1` —— 用内置的 fixture 插件覆盖 4 种 kind 的
   预览/应用/幂等/错误分类/超时/进程树清理；
3. **dry-run harness**：把插件目录复制到临时目录再跑（不污染真实 `plugins\`）；
4. **每个插件必须附验收清单**（模板）：预览零副作用证据 / 应用后前后对比 / 回滚证据 / 日志留痕；
5. 把上述三项接进 `tests\Run-AllGates.ps1`（做成第 8–10 道门）。

## 10. `driver` 类插件的铁律（边界写死）

**允许的**（管理/分析/加固向）：

- `driver.list` / `driver.detail`：已加载与已安装驱动清单；签名状态（`Get-AuthenticodeSignature`
  + WinVerifyTrust 结果）、签名者、WHQL/测试签名/未签名三分类、路径、文件版本、SHA256、
  服务状态与启动类型；**已知漏洞驱动**比对（本地静态名单，可由用户扩充）；
- `driver.service.{install,start,stop,delete}`：**仅针对用户在 UI 上显式选定的单个驱动文件**，
  且必须满足：路径显式、非系统目录、SHA256 与清单一致、**已由可信证书签名**
  （测试签名须用户显式确认且工具只提示"当前处于 test-signing"而**不代其开启**）；
- `driver.blocklist.status` / `driver.harden`：检查并（可选）启用 Microsoft 漏洞驱动阻止名单，
  以及**通过已有的 WDAC 模块生成 deny 策略**来阻止指定驱动加载（与 §11.x WDAC 能力天然衔接）；
- 一切动作：预览优先、备份、审计日志、卸载/恢复说明。

**明确不做**（写死，不接受"加上就好"）：

- 不提供、不生成、不内置任何**可以执行任意命令的内核载荷代码**；
- 不提供 BYOVD 漏洞驱动清单/下载/用法，也不做"选一个驱动来干掉某安全软件"这类流程；
- 不提供任何**绕过签名强制**的能力（不改 `testsigning`、不关 VBS/HVCI、不碰 DSE、不写
  `nointegritychecks`），也不为未签名驱动"想办法让它能装"；
- 不做隐藏（不改服务名/描述伪装、不隐藏驱动、不清理痕迹）、不做卸装后的"残留规避"；
- 不提供针对安全产品（杀软/EDR/反作弊）的停止、屏蔽、绕过、卸载类流程。

理由不是"技术上做不到"，而是这类能力**无法满足本项目对其它能力一贯要求的两条**：
(a) 结果可解释，(b) 动作可回滚。内核载荷一旦执行，卸载不构成撤销。

## 11. 实施顺序（建议）

| 阶段 | 内容 | 产出 | 影响面 |
|---|---|---|---|
| P0 | 种类注册表 + 能力模型骨架 + 清单 v2（v1 兼容） | 引擎改动 ~150 行；`docs\PLUGIN-SDK.md` | 低（老插件不动） |
| P1 | 结构化输出 + verb 命名空间 + settings 持久化 | 引擎 + UI 插件页 | 中 |
| P2 | `psm1` 常驻 kind（复用 WatchHost）+ 清单 lint/SDK 自测接进门禁 | 3 道新门 | 低 |
| P3 | `driver` 管理类（§10 允许项） | 新插件 + UI 页 | 中 |
| P4 | 插件索引缓存 + 并发 | 引擎 | 低 |

**验收**：每一步都要有"预览零副作用 / 应用后对比 / 回滚"三件证据，并接进
`tests\Run-AllGates.ps1`。