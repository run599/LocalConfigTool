# LocalConfigTool

> **一个 MCP 工具，不是恶意项目。**
>
> Windows 系统分析与本地配置管理工具 + 标准 **MCP（Model Context Protocol）服务器**。
> AI 宿主（Claude Desktop / Cursor / DSH 等）通过 JSON-RPC over stdio 挂载它，用自然语言驱动系统操作。
>
> **不是恶意软件**：不自我传播、不隐藏、不驻留、不窃取数据；**不预置** exploit 或漏洞驱动二进制；
> 写操作默认只预览、必须显式 `-Apply`；每次写入前自动备份、可回滚、全程审计；用完可一键清理。
>
> 定位类似火绒剑（HRSword）：把系统能力交给使用者，由使用者决定做什么。
>
> ---
>
> **本文档是唯一的项目文档，包含理解与修改本项目所需的全部信息。没有第二个文件需要读。**
> 读完本文你就能理解这个项目的能力边界、安全模型和扩展方式。

---

## 0. 先看这个：能力全貌（两段式权限跃迁）

这是本项目最核心的设计，**不要把它当成"进程管理工具"**。

```
普通用户 ──(第一段：提权插件 plugins.run)──> 管理员/SYSTEM ──(第二段：driver.use + ctl.send)──> 内核任意读写
         ↑ 起点必须是非提权                               ↑ 起点必须是管理员/SYSTEM
```

| | **第一段：提权** | **第二段：内核** |
|---|---|---|
| 触发 | `plugins.run`（`plugins\cve-2026-49176`） | `driver.use` → `driver.verify` → `driver.ctl.send` |
| 起点 | **普通用户**（必须非提权） | **管理员 / SYSTEM** |
| 终点 | **管理员 / SYSTEM** | **内核原语（任意读写 / 执行）** |
| 代码位置 | `core\Plugins.psm1` + `plugins\` | `core\Drivers.psm1` + `core\DriverProfiles.psm1` |

**两段的权限前提正好相反**，这是关键：

```powershell
# core\Ai.psm1 L66 —— 提权插件必须在非提权上下文跑
if ($v -eq 'plugins.run') { return 'non-elevated' }
```

所以完整的链路只能是「**先提权，再加载驱动**」。`ai.plan` 会自动排出这个顺序；
`process.kill` 只是这条链上**最末端、最不值钱**的一环（同权限用户态终止），不是本项目的天花板。

> 更细的冲突处理与每步前置条件，在各模块头部注释里（`core\Plugins.psm1` / `core\Drivers.psm1`）。

---

## 1. 三种用法

| 用法 | 入口 | 说明 |
|---|---|---|
| **图形界面** | `ui-java\run.cmd`（需 JDK 21）或 `run-ui.cmd` | Java Swing，7 页 |
| **命令行** | `engine.cmd -Verb <verb> [-ArgsFile <json>] [-Apply]` | 83 个 verb，与界面等价 |
| **MCP（给 AI 用）** | `tools\McpServer.ps1` | JSON-RPC 2.0 over stdio，暴露 4 个工具 |

> 旧的 WinForms 界面（`ui\ConfigUI.ps1`）仍可运行，但不再更新。

### MCP 接口（4 个工具）

| 工具 | 作用 |
|---|---|
| `lct_manifest` | 能力清单：每个 verb 的 `mutating` / `needsElevation` / `blockedNow` + 预置流程 + 安全规则 |
| `lct_status` | 当前权限画像：`isAdmin` / `integrityLevel` / `canLoadDriver` |
| `lct_plan` | 一句话目标 → 有序执行计划（只读；为第一个可执行写步骤发一次性确认短语） |
| `lct_call` | 执行 verb；`mutating` + `apply=true` 必须带人给的 `confirm` 短语 |

**为什么 AI 需要这一层**：裸调引擎也能跑，但拿不到"现在能不能做 / 该按什么顺序做"的元信息，
也绕不过确认闸门。MCP 层把这两件事固化成协议。

### 命令行示例

```bat
engine.cmd -Verb engine.verbs          :: 83 个 verb 的完整清单（含参数）
engine.cmd -Verb capability.status     :: 当前权限（是否管理员 / 能否加载驱动）
engine.cmd -Verb samples.list          :: 样本库（预置规则）
engine.cmd -Verb ai.manifest           :: AI 可直接调用的能力
```

参数复杂时用文件传（避免引号/中文转义）：

```bat
echo {"goal":"加载 rtcore64 读内核头，最后清理"} > a.json
engine.cmd -Verb ai.plan -ArgsFile a.json
```

---

## 2. 83 个 verb 分组（46 写 / 37 只读）

| 前缀 | 数量 | 写操作 | 用途 |
|---|---|---|---|
| `capability.*` | 1 | 0 | 当前权限画像（`isAdmin` / `integrityLevel` / `canLoadDriver`） |
| `engine.*` | 1 | 0 | `engine.verbs` 自描述全部能力 |
| `account.*` | 4 | 3 | 账户状态 / 管理员组 / UAC / 自动登录 |
| `registry.*` | 3 | 2 | 注册表 get / set / delete（写入先备份） |
| `process.*` | 10 | 5 | 清单 / 详情 / 终止 / 看门狗（会话内）/ IFEO 加载阻断 |
| `wdac.*` | 9 | 5 | 状态 / 规则增删 / 策略构建校验 / 部署回滚 / 验证 |
| `driver`（本体） | 15 | 8 | 加载/启动/停止/卸载、设备与对象图、内核基址、清理 |
| `driver.profile.*` | 6 | 2 | profile 的 list/show/validate/save + **draft（静态起草）+ fromprobe（探测生成）** |
| `driver.ctl.*` | 4 | 3 | IOCTL 发送 / 校验 / **variants（变异生成）/ probe（逐条实测）** |
| `driver.vm.*` | 11 | 10 | **VM 沙箱层**（见第 2.5 节） |
| `driver.batch.*` | 1 | 0 | 批量静态分诊（目录 → 风险排序） |
| `samples.*` | 2 | 1 | 样本库（下载 + 强制 SHA256 校验） |
| `plugins.*` | 3 | 1 | **第一段核心**：插件清单 / 详情 / 执行 |
| `presets.*` | 3 | 1 | 预设包（数据驱动，加 JSON 即可扩展） |
| `backup.*` | 3 | 1 | 备份列表 / 详情 / 回滚 |
| `ai.*` | 7 | 4 | `manifest` / `plan` / `do` / `run` / `translate` / `auto` / `cred` |

---

## 2.5 VM 沙箱层（driver.vm.*，11 个 verb）

**为什么存在**：内核驱动的畸形 IOCTL 会让整机蓝屏。把这套操作放进虚拟机里跑，
**崩了回滚快照 30 秒就回来**，于是"试错"这件事的代价趋近于零。

**这一层不需要人懂内核**——这是它最重要的性质：

```
给一个 .sys  →  driver.vm.explore  →  14 分钟后拿到「它能做什么」的报告
```

| verb | 作用 |
|---|---|
| `driver.vm.config` / `status` | 配置 VMware 路径/VMX/guest 凭据（密码走 DPAPI，不落明文）；查看就绪状态 |
| `driver.vm.prepare` | 一次性环境准备（guest 建目录 + Defender 排除） |
| `driver.vm.push` | 把驱动推到 guest |
| `driver.vm.probe` | 单条 IOCTL 实测 |
| `driver.vm.matrix` | 变异矩阵逐条实测（每条独立超时，崩溃即停） |
| `driver.vm.fields` | **差分探测**：逐块改 payload，推出 in 字段布局（哪些偏移有效、多宽） |
| `driver.vm.discover` | **暴力扫 IOCTL 码**：没有 profile 时靠遍历码范围找入口（多 payload 对比破解 `87` 的不可区分性） |
| `driver.vm.batch` | 批量跑矩阵；**崩溃后自动回滚快照 → 启动 VM → 重建环境 → 继续** |
| `driver.vm.snapshot` | 快照列表 / 创建 / 回滚 |
| `driver.vm.explore` | **全自动探索**：push → 扫码 → 探布局 → 跑变异 → 出能力报告 |

### 自动化的演进链（每一层都消除了上一层的前置条件）

```
1. 人工写 profile            → 需要懂内核结构
2. profile.draft             → 自动给出设备名 / IOCTL 候选 / 导入表（仍不可执行）
3. vm.fields                 → 自动推出 in 字段布局（差分探测，2 分钟）
4. vm.discover               → 自动找到 IOCTL 码（不需要任何前提）
5. profile.fromprobe         → 合成可用 profile（自动填 method/out/presets）
6. vm.explore                → 上面全部串起来，一条命令出报告
```

**实测（rtcore64，14.4 分钟，全程无人工）**：

```
discover 64 个码 → accepted=2 / otherError=2 / invalidParam=58 / timeout=2
fromprobe        → 自动选中真码 0x80002048，探出 2 个字段
能力报告         → 「发现 2 个功能可用的 IOCTL 码」「存在会让驱动挂起/崩溃的码」
```

### 两条硬教训（写进代码注释，也写在这里）

**① 探测产物的 `presets` 不能为空**

`presets` 空 → 所有字段默认 0 → `readSize=0` → **驱动什么都不读，直接返回成功**。
于是矩阵里一堆 `ok-data` 看起来"无害"，其实根本没干活。**结论全是假的。**

现在 `fromprobe` 会扫 `1/4/8/16`，找"能让返回数据非全 0"的值当 preset。

**② 扰动幅度决定生死**

差分探测默认用 **`+1` 温和扰动**。用 `0xFF` 改 `offset` 字段会让驱动按 4GB 偏移访问 → **直接 BSOD**。
`-Aggressive` 才用极值（能探出"无边界检查"，但会崩）。

---

## 3. 安全模型（五条铁律，代码里真的在拦）

1. **写操作默认只预览** —— 46/83 个 verb 是 mutating，不 `-Apply` 就什么都不发生
2. **AI 场景必须人在回路** —— 一次性确认短语 `I-UNDERSTAND-<8hex>`：10 分钟有效、绑定 verb+args、用后即焚
3. **写入先备份、可回滚** —— 每次改系统前自动备份，`backupId` 进结果；驱动卸载只删服务项不删 `.sys`
4. **失败如实上报** —— 系统返回码（577 / 193 / 1053 …）原样照抄，拿不准就写"状态不明"，不美化
5. **用完清理** —— `driver.cleanup` 只卸本工具加载过的服务，后台确认系统状态复原

**危险动作的额外闸门**：

| 动作 | 闸门 |
|---|---|
| bsod 级 IOCTL | 默认禁用，需 `-OverrideBsod`（连预览都拒） |
| 驱动写（kwrite） | 无原值不写 |
| 弱驱动识别 | profile 的 `target.sha256` 指纹不符即拒 |
| 静态草案（draft） | `actions` 为空 + `needsReview=true` ⇒ 结构上不可执行 |
| **VM 内的操作** | **不需要审定** —— 崩了回滚快照即可。只有「把 VM 结论应用到实体机」才需要人复核 |
| WDAC 强制部署 | 审计优先；命中系统目录 / 无 allow 机制 / 缺救命绳一律拒 |

---

## 4. 扩展方式

### 插件（第一段：提权/任意工具）

```
plugins\my-tool\
    plugin.json     ← 清单：id / name / risk / entry / params
    run.ps1         ← 入口：收到参数，非提权上下文运行，退出码约定
```

`plugins.run` 默认只预览（解析出命令行但不执行），`-Apply` 才真跑。清单格式直接看 `plugins\example-v2-sysinfo\plugin.json`（可运行的实例）。

### 驱动 profile（第二段：内核操作）

**纯数据**，不会写代码也能接一个新驱动：

```json
{
  "id": "vendor-driver-<hash8>",
  "target": { "sha256": "<64 hex 指纹>", "fileName": "xxx.sys" },
  "locate": { "strategy": "symlink", "candidates": ["\\??\\DeviceName"] },
  "actions": {
    "kread": {
      "ioctl": "0x80002048",
      "in": [
        { "name": "pad0",     "type": "bytes", "len": 8 },
        { "name": "addr",     "type": "u64" },
        { "name": "pad1",     "type": "bytes", "len": 4 },
        { "name": "offset",   "type": "u32" },
        { "name": "readSize", "type": "u32" },
        { "name": "value",    "type": "u32" },
        { "name": "pad3",     "type": "bytes", "len": 16 }
      ],
      "presets": { "readSize": 4 }
    }
  },
  "layout": { "method": "buffered", "align": 8 },
  "risk": { "level": "bsod", "notes": "任意内核读写" }
}
```

指纹不符即拒。字段布局细节见 `core\DriverProfiles.psm1` 头部注释；自研驱动照 ABI 实现则**无需 profile**。

**不想手写？让机器探**：

```bat
engine.cmd -Verb driver.vm.explore -ArgsFile a.json -Apply
  :: a.json = {"sysPath":"...\\xxx.sys"}
  :: 14 分钟后输出：能用哪些 IOCTL 码 / 字段布局 / 哪些输入会崩
  :: 产物同时落盘成可用 profile（可直接 driver.vm.matrix 跑）
```

`layout.method` 也能从码本身算出来：`ioctl & 3`（0=buffered 1=in-direct 2=out-direct 3=neither），
`& 3 == 3` 意味着驱动直接操作用户态指针 —— **未验证前不要碰**。

### 预设包

`presets\*.json` —— 数据驱动的批量配置（如禁用型注册表项），加 JSON 即可扩展。

---

## 5. 目录

```
core\          引擎（19 个模块：Registry/Accounts/Processes/Wdac/Drivers/DriverProfiles/
               Samples/Plugins/PluginSdk/Ai/Capabilities/Backup/Logging/WatchHost/Engine…）
plugins\       插件（第一段：提权 / 任意工具）
presets\       预设包（数据驱动）
samples\       样本库规则（只放 URL/哈希/风险，不放可执行载荷）
ui-java\       Java Swing 界面（当前维护中）
ui\            旧 WinForms 界面（保留可运行，不再更新）
tools\         McpServer.ps1（AI 宿主挂载）+ 构建脚本
  vm-agent\    guest 侧探测脚本（guest-probe.ps1 等）—— 推送到 VM 里执行
docs\          参考资料（**不随本包分发**；需要时在完整源码里看）
var\           运行数据：日志/备份/已下载样本/DPAPI 凭据 —— 不入库、勿分发
engine.cmd     引擎入口
run-ui.cmd     界面入口
```

---

## 6. 关于本文档

**本文档是唯一文档。** 它的组织方式是「结论先行」：

- 第 0 节（两段式权限跃迁）是**最容易被误读的地方**，务必先读
- 第 2~4 节是能力清单与安全模型
- 第 5 节是目录结构
- 附录（文末）是**改代码时的硬约束**（Result 形状、安全铁律、编码约定、模块边界、未验证项）

更细的实现细节在各模块的头部注释里（每个 `core\*.psm1` 开头都有"职责/导出/铁律"三段说明）。

## 7. 验收（有测试时）

```bat
tests\Run-AllGates.ps1
```

27 道门禁（纯净代码包不含 `tests\`，完整源码包有）：编码 / Lint / 自测 / 界面 / 进程 / WDAC /
驱动 / profile / 对象图 / Java UI / 能力 / AI 三层 / 云 API / 样本库 / 插件 SDK / 简化输出 /
驱动批量分诊 / 准确率校准 / 变异生成 / **VM 沙箱（56 断言，含崩溃恢复）**。

---

## 免责声明

- 仅在**你完全拥有处置权**的机器上使用（虚拟机 / 快照最佳）
- 驱动加载与内核操作有蓝屏风险，工具默认**只预览**
- 使用者自行承担全部责任；请勿用于未授权的系统