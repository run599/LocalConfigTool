# LocalConfigTool · BYOVD 驱动分析平台

> **给一个 `.sys`，回答一个问题：「它能做什么」。**
>
> 自动跑完「动态锚定 → 静态精读 → 表枚举 → 反哺动态」四步，输出它支持哪些 IOCTL 码、
> 每个码进哪个分支、哪些参数会让它崩。**不需要人懂内核结构，也不需要人审定**（VM 里崩了回滚 30 秒）。
>
> 同时保留完整的 **Windows 本地配置管理**能力（账户 / 注册表 / 进程 / WDAC），
> 那些是项目第一代的产品，仍在维护 —— 见 [第 5 节](#5-系统配置能力46-个-verb第一代仍在维护)。
>
> ---
>
> **本文是入口**。细节见 `docs/`（地图：`docs/00-INDEX.md`）：
> 方法论 `docs/WORKFLOW.md` · 契约 `docs/CONTRACT.md` · 架构 `docs/ARCHITECTURE.md` · 踩坑 `docs/PITFALLS.md`。

---

## 0. 这是什么

**这个项目有两代**，理解它们的区别比读任何细节都重要：

| | **第一代：本地配置工具**（2026-10） | **第二代：驱动分析平台**（2026-11） |
|---|---|---|
| 干什么 | 改账户 / 注册表 / UAC / 进程 / WDAC | 分析第三方内核驱动能做什么 |
| 怎么干 | 直接操作，每次写入先备份 | **VM 沙箱里实测 + 静态反汇编** |
| verb 数 | 46 | **40** |
| 需要什么 | 管理员权限 | **一个 VMware + 一个快照** |
| 需要人懂内核吗 | 不需要 | **不需要** ← 这是第二代的核心目标 |

**为什么会有第二代**：第一代做到"能加载任意驱动"之后，下一个问题就是
"这个驱动能干什么、参数长什么样、哪些输入会崩" —— 那是内核逆向的活，
而内核逆向的门槛高到让工具失去意义。

**第二代的答案**：把这些活放进虚拟机，用机器去试，人只需要看结论。

---

## 1. 核心方法论：四步闭环

这是整个第二代的技术骨架。**每一步都消除上一步的前置条件**，而且
**动态不是用来"验证静态"，而是给静态一个精确的起点**。

```
① 动态锚定   driver.vm.anchor            9 秒     → IRP_MJ_DEVICE_CONTROL 的精确 RVA
       ↓   （不再猜"从哪开始反汇编"）
② 静态精读   driver.desasm.function      247ms    → IOCTL 基址 / 表大小 / 跳转表地址
       ↓   （不再全量扫 .text）
③ 表枚举     driver.desasm.dispatchmap   392ms    → 18 个有效码 → 各自的分支 RVA
       ↓   （不再盲扫码范围）
④ 反哺动态   driver.vm.matrix -Codes     13 秒    → 每个码的实际行为
```

### 实测（rtcore64 / Win10 19045）

| 步 | 拿到什么 | 耗时 |
|---|---|---|
| ① | `driverName=\Driver\RTCore64`<br>`MajorFunction[0/2/14] = RVA 0x1450`<br>能力面：`CREATE/CLOSE/DEVICE_CONTROL=true`，`READ/WRITE=false` | **9s**（79 次 kread） |
| ② | `ioctlBase=0x80002000`<br>`tableSize=85`<br>`jumpTableKind=two-level`<br>`irpTypeCheck=0xE` | **247ms** |
| ③ | **18 个有效码 → 18 个分支**<br>`0x80002048`→`0x14B6`、`0x8000204C`→`0x1526`<br>67 个无效码→默认分支 `0x19B6` | **392ms** |
| ④ | `0x80002048` → `ok-data, ret=48`（读到了内核地址） | **13s / 3 码** |

**合计约 1 分钟**，从"一个文件"到"18 个精确码 + 每个的行为"。

### 对比原来（猜 + 盲试）

| 旧路径 | 耗时 | 结论 |
|---|---|---|
| `driver.vm.discover` 暴力扫 64 码 | **13 分钟** | 只找到 2 个 accepted，58 个 `87` 不可区分 |
| rizin 全量扫 `.text` | **90 秒**（超时） | 覆盖率 5.6% |
| **四步闭环** | **~1 分钟** | **18 个码 + 每个的分支地址** |

> **`87` 不可区分这个困扰了整个项目的问题，在静态跳转表面前根本不存在 —— 表就是答案。**

### 每一步在做什么（技术要点）

**① 锚定**：借一个已知可控的漏洞驱动（RTCore64）的 kread 原语，
走 `handle → FILE_OBJECT → DEVICE_OBJECT → DRIVER_OBJECT → MajorFunction[]`，
直接读出**这个设备怎么分派 IRP**。三项自校验必须全过才认（`Type==4`、`DriverStart==DllBase`、`DriverStart` 处有 `MZ`）。

> **坑**：RTCore64 的 kread **单次只支持 1/2/4 字节**。传 8 会"成功但没读"（返回全 0），
> 看起来像"地址无效"。必须循环读 4 字节拼块（4ms / 64 字节）。

**② 精读**：拿到 RVA 后，**只反汇编那一个函数**（默认 512 字节），
自动从指令模式里读结论：

```
add eax, 0x7FFFE000  → IOCTL 基址 = 0x100000000 - 0x7FFFE000 = 0x80002000
cmp eax, 0x54        → 表大小 = 0x54 + 1 = 85
movzx + movsxd + jmp → 两级跳转表（不是教科书式的一级表）
```

**③ 表枚举**：把两张表读出来，直接算每个码去哪 —— **这一步不需要再反汇编**。

**④ 反哺**：用 ③ 的精确码列表跑 `vm.matrix`，每个码一条任务。

> `driver.vm.explore` 是**全自动兜底**：拿不到锚点时（比如驱动不支持 kread、
> 或者根本没有 `DEVICE_OBJECT`）走暴力扫，14 分钟出报告。它不再是主路径。

---

## 2. 三种用法

| 用法 | 入口 | 说明 |
|---|---|---|
| **图形界面** | `ui-java\run.cmd`（需 JDK 21） | Java Swing，7 页 |
| **命令行** | `engine.cmd -Verb <verb> [-ArgsFile <json>] [-Apply]` | 86 个 verb，与界面等价 |
| **MCP（给 AI 用）** | `tools\McpServer.ps1` | JSON-RPC 2.0 over stdio，暴露 4 个工具 |

### 完整流程（命令行走一遍）

```bat
:: 0) 配置 VM（一次性；密码走 DPAPI，不落明文）
engine.cmd -Verb driver.vm.config -ArgsFile vm.json -Apply

:: 1) 推驱动 + 锚定
echo {"sysPath":"D:\\x.sys","device":"\\\\.\\RTCore64"} > a.json
engine.cmd -Verb driver.vm.anchor -ArgsFile a.json -Apply
::   → ioctlDispatchRva = 0x1450

:: 2) 精读那一个函数
echo {"path":"D:\\x.sys","rva":"0x1450"} > b.json
engine.cmd -Verb driver.desasm.function -ArgsFile b.json
::   → ioctlBase=0x80002000, tableSize=85

:: 3) 枚举表
engine.cmd -Verb driver.desasm.dispatchmap -ArgsFile b.json
::   → 18 个有效码 + 各自分支

:: 4) 按精确码验证
echo {"profile":"my-profile","action":"kread","codes":"0x80002000,0x80002048"} > c.json
engine.cmd -Verb driver.vm.matrix -ArgsFile c.json -Apply
```

**不想一步步来**：`driver.vm.explore -ArgsFile a.json -Apply`（全自动，14 分钟）。

### MCP 接口（4 个工具）

| 工具 | 作用 |
|---|---|
| `lct_manifest` | 能力清单：每个 verb 的 `mutating`/`needsElevation`/`blockedNow` + 预置流程 + 安全规则 |
| `lct_status` | 当前权限画像：`isAdmin` / `integrityLevel` / `canLoadDriver` |
| `lct_plan` | 一句话目标 → 有序执行计划（为第一个写步骤发一次性确认短语） |
| `lct_call` | 执行 verb；`mutating` + `apply=true` 必须带人给的 `confirm` 短语 |

**为什么 AI 需要这一层**：裸调引擎也能跑，但拿不到"现在能不能做 / 该按什么顺序做"的元信息，
也绕不过确认闸门。MCP 层把这两件事固化成协议。

---

## 3. 驱动分析能力（40 个 verb，第二代主体）

### 3.1 四步闭环（见第 1 节）

| verb | 作用 | 实测 |
|---|---|---|
| `driver.vm.anchor` | kread 读 `DRIVER_OBJECT` → `MajorFunction[]` → 能力面 | 9s |
| `driver.desasm.function` | 只反汇编一个函数，自动提取 IOCTL 基址/表大小/跳转表 | 247ms |
| `driver.desasm.dispatchmap` | 读跳转表，每个码 → 分支 RVA | 392ms |
| `driver.vm.matrix -Codes` | 按精确码表逐个实测（不再是盲扫） | 13s / 3 码 |

### 3.2 兜底与辅助

| verb | 作用 |
|---|---|
| `driver.vm.discover` | 暴力扫 IOCTL 码（无锚点时用；多 payload 对比破解 `87` 不可区分） |
| `driver.vm.fields` | 差分探测：逐块改 payload，推出 in 字段布局 |
| `driver.profile.fromprobe` | 探测结果 → 可用 profile（自动填 method/out/presets） |
| `driver.vm.explore` | 全自动：push → discover → fromprobe → matrix（14 分钟） |

### 3.3 VM 沙箱（13 个 verb）

**为什么必须在 VM 里**：畸形 IOCTL 会让整机蓝屏。VM 里代价是 **30 秒回滚**，
于是"试错"的成本趋近于零 —— **这就是"不需要人审定"的根据**。

| verb | 作用 |
|---|---|
| `driver.vm.config` / `status` | 配置 VMware 路径/VMX/凭据；查看就绪状态 |
| `driver.vm.prepare` | 一次性环境准备（建目录 + Defender 排除） |
| `driver.vm.push` | 把驱动推到 guest |
| `driver.vm.probe` | 单条 IOCTL 实测 |
| `driver.vm.snapshot` | 快照 list / create / revert |
| `driver.vm.batch` | 批量矩阵；**崩溃后自动回滚 → 启动 → 重建 → 继续** |

### 3.4 实体机操作（危险，默认只预览）

| verb | 作用 |
|---|---|
| `driver.load` / `start` / `stop` / `unload` | 加载/启动/停止/卸载驱动（只删服务项，不删 `.sys`） |
| `driver.devices` / `driver.map` | 枚举设备对象 / 设备-驱动关系图 |
| `driver.kernelbase` | 取 ntoskrnl 基址 |
| `driver.profile.*` | profile 的 list/show/validate/save/draft |
| `driver.ctl.send` / `verify` | 发 IOCTL / 校验 |
| `driver.batch.scan` | 目录批量静态分诊（风险排序） |
| `driver.verify` / `info` / `status` / `list` / `cleanup` | 状态查询与清理 |

---

## 4. 安全模型

### 4.1 VM 内 vs 实体机（这是最关键的分界）

```
在 VM 里测        →  不需要审定。崩了回滚快照 30 秒。   ← 第二代的主战场
应用到实体机       →  必须人复核。这里的错误代价是用户机器蓝屏。
```

之前把「实体机安全铁律」整套搬到 VM 场景是**定位错误** ——
那些护栏的成本前提是"一次错误 = 用户机器蓝屏"，而 VM 里一次错误的代价是"回滚 30 秒"。

### 4.2 五条铁律（代码里真的在拦）

1. **写操作默认只预览** —— 46/86 个 verb 是 mutating，不 `-Apply` 就什么都不发生
2. **AI 场景必须人在回路** —— 一次性确认短语 `I-UNDERSTAND-<8hex>`：10 分钟有效、绑定 verb+args、用后即焚
3. **写入先备份、可回滚** —— 每次改系统前自动备份，`backupId` 进结果
4. **失败如实上报** —— 系统返回码（577/193/1053…）原样照抄，拿不准就写"状态不明"
5. **用完清理** —— `driver.cleanup` 只卸本工具加载过的服务

### 4.3 危险动作的额外闸门

| 动作 | 闸门 |
|---|---|
| bsod 级 IOCTL | 默认禁用，需 `-OverrideBsod`（连预览都拒） |
| 驱动写（kwrite） | 无原值不写 |
| 弱驱动识别 | profile 的 `target.sha256` 指纹不符即拒 |
| **VM 内操作** | **不需要审定**（见 4.1） |
| WDAC 强制部署 | 审计优先；命中系统目录 / 无 allow 机制 / 缺救命绳一律拒 |

---

## 5. 系统配置能力（46 个 verb，第一代，仍在维护）

| 前缀 | 数量 | 用途 |
|---|---|---|
| `account.*` | 4 | 账户状态 / 管理员组 / UAC / 自动登录 |
| `registry.*` | 3 | 注册表 get / set / delete（写入先备份） |
| `process.*` | 10 | 清单 / 详情 / 终止 / 看门狗 / IFEO 加载阻断 |
| `wdac.*` | 9 | 状态 / 规则增删 / 策略构建校验 / 部署回滚 / 验证 |
| `plugins.*` | 3 | **提权链第一段**：插件清单 / 详情 / 执行 |
| `presets.*` | 3 | 预设包（数据驱动） |
| `backup.*` | 3 | 备份列表 / 详情 / 回滚 |
| `samples.*` | 2 | 样本库（下载 + 强制 SHA256 校验） |
| `capability.*` / `engine.*` | 2 | 权限画像 / verb 自描述 |
| `ai.*` | 7 | manifest / plan / do / run / translate / auto / cred |

### 两段式权限跃迁（第一代的核心设计）

```
普通用户 ──(提权插件 plugins.run)──> 管理员/SYSTEM ──(driver.use + ctl.send)──> 内核任意读写
         ↑ 起点必须是非提权                            ↑ 起点必须是管理员/SYSTEM
```

**两段的权限前提正好相反**，所以完整链路只能是「先提权，再加载驱动」。

---

## 6. 扩展方式

### 6.1 驱动 profile（纯数据）

**纯数据，不会写代码也能接一个新驱动**：

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

**不想手写**：`driver.profile.fromprobe` 或 `driver.vm.explore` 自动生成。

`layout.method` 可从码本身算：`ioctl & 3`（0=buffered 1=in-direct 2=out-direct 3=neither）。

### 6.2 插件（第一段：提权/任意工具）

```
plugins\my-tool\
    plugin.json     ← 清单：id / name / risk / entry / params
    run.ps1         ← 入口：非提权上下文运行，退出码约定
```

`plugins.run` 默认只预览，`-Apply` 才真跑。实例见 `plugins\cve-2026-49176\`。

### 6.3 预设包

`presets\*.json` —— 数据驱动的批量配置，加 JSON 即扩展。

---

## 7. 目录与验收

```
core\          引擎（19 个模块；驱动分析：Drivers / DriverProfiles / DriverVm / DriverProbe）
plugins\       插件（提权 / 任意工具）
presets\       预设包（数据驱动）
samples\       样本库规则（只放 URL/哈希/风险，不放可执行载荷）
ui-java\       Java Swing 界面（维护中）
ui\            旧 WinForms 界面（保留可运行，不再更新）
tools\         McpServer.ps1（AI 宿主挂载）
  vm-agent\    guest 侧脚本（probe / anchor）—— 推送到 VM 里执行
docs\          文档（见 docs\00-INDEX.md）
var\           运行数据：日志/备份/样本/DPAPI 凭据 —— 不入库、勿分发
```

```bat
tests\Run-AllGates.ps1      :: 28 道门禁
```

门禁覆盖：编码 / Lint / 自测 / 界面 / 进程 / WDAC / 驱动 / profile / 对象图 / Java UI /
能力 / AI 三层 / 云 API / 样本库 / 插件 SDK / 简化输出 / 批量分诊 / 准确率校准 /
变异生成 / **VM 沙箱（63 断言，含崩溃恢复）** / **锚点（7 断言）** / **精读+表枚举（21 断言）**。

---

## 免责声明

- 仅在**你完全拥有处置权**的机器上使用（虚拟机 / 快照最佳）
- 驱动加载与内核操作有蓝屏风险，工具默认**只预览**
- 不自我传播、不隐藏、不驻留、不窃取数据；**不预置** exploit 或漏洞驱动二进制
- 使用者自行承担全部责任；请勿用于未授权的系统
