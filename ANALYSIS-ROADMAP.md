# 驱动分析的现状、粗糙程度与演进方向

> **本文回答三个问题**：当前的驱动分析能力有多粗糙（可量化）、为什么粗糙、接下来该往哪走。
> **本文不包含**：具体实现（在 `core\DriverProfiles.psm1` / `core\DriverAudit.psm1`）、VM 方案细节、反汇编方案（明确不做，见 §6）。

---

## 0. 结论先行

1. **静态分析（`driver.profile.draft` / `driver.batch.scan`）是粗筛，不是判定。** 它的精度只够"把 500 个缩到 25 个"，不够说"这个有漏洞"。
2. **动态验证（`driver.use` + `ctl.send`）才是判定。** "我发了命令，它执行了"是事实；"我看了代码觉得没校验"是猜测。
3. **所以：静态粗糙不致命，动态能力才是这个项目的护城河。**
4. **当前最大的缺口不是精度，是"精度测试"** —— 24 道门禁全是结构测试（ok=true / 字段齐全 / 不崩），没有一道测"判断准不准"。

---

## 1. 现状：三处可量化的粗糙

### 1.1 IOCTL 候选 = 字节模式匹配，完全不看控制流

```powershell
# core\DriverProfiles.psm1 L1612
$rxCmp = [regex]'\x3D[\s\S]{4}|\x81[\xF8-\xFF][\s\S]{4}|...'
```

扫描机器码里像 `CMP reg, imm32` 的字节，把那个立即数当 IOCTL 码。这意味着：

- 不知道这个常量**是否真的被用于 dispatch 比较**
- 不知道这个函数**是否从 `IRP_MJ_DEVICE_CONTROL` 可达**
- 实测：`acpi.sys` 64 个候选、`rtcore64` 6 个候选，**tier 全是 `possible`** —— 分层规则实际没起到区分作用

**这不是"分析"，是"找长得像的东西"。**

### 1.2 `confidence` 的权重是拍的，且各项高度相关

```
0.10 基础 + 0.15 PE解析 + 0.10 导入表 + 0.05 内核API
+ 0.08 设备名 + 0.15 xref + 0.20 高可信IOCTL + 0.05 输入提示
```

- **没有任何校准依据**（没跑过 ground truth）
- `PE 解析成功 → 导入表 → 有内核 API` 是几乎必然的链条，**同一件事计了三次分**
- 结果：`0.63` vs `0.68` 的差距**不反映危险度**，只反映"文件结构完整度"

### 1.3 【已修】IOCTL 候选的 tier 分层其实从未生效（符号 bug）

`$imm` 是 `uint32`（正数），旧代码 `$high = $imm64 -band 0xF0000000` 算出来是 `+2147483648`；
而比较用的字面量 `0x80000000` 在 PowerShell 里是 **Int32 = -2147483648**。
**符号不一致 → 永远不相等**，于是所有候选都掉进 `possible`，`likely` 分支形同虚设。

- 修前实测：`acpi.sys` 64 个候选 **全 possible**、`rtcore64` 6 个 **全 possible**
- 修法：改用高 4 位判断（`($imm -shr 28) -band 0xF ∈ {8,9,A,C}` + DeviceType 合理 + Function 非 0），绕开符号问题
- 修后实测：`rtcore64` 2 likely / 5 possible，`acpi` 14 likely / 50 possible

> **附：签名统计经实测是正确的。** `acpi.sys` / `ntfs.sys` / `tcpip.sys` 批量扫均返回 `Valid` + `microsoft-signed`。
> 早期本文里"批量路径读空签名"的判断是基于旧版本数据的**误判**，已纠正——这也是"没有精度测试就容易误判"的实例。

### 1.5 【踩坑】OrderedDictionary 的键不在 `PSObject.Properties` 里

`profile` 和 `presets` 解析出来都是 `OrderedDictionary`。对它取 `PSObject.Properties.Name`
拿到的是**字典自身的属性**（`Count` / `Keys` / `Values` / `IsReadOnly`…），**不是字段名**。

后果：`Get-LctProbeProp $prof 'actions'` 永远返回 `$null`，表现为"profile 里没有 actions"。

修法：先判 `$Bag -is [System.Collections.IDictionary]`，用 `$Bag.Contains($Name)` + `$Bag[$Name]` 取值。
遍历同理（用 `.Keys`，不要用 `.PSObject.Properties`）。

### 1.4 `confidence` 度量的是"分析完整度"，不是"危险度"

修完 tier 后暴露一个更根本的问题：

| 驱动 | confidence | 实际情况 |
|---|---|---|
| `rtcore64.sys` | **0.83** | 真有任意内核读漏洞 |
| `acpi.sys` | **0.93** | 正常系统驱动 |
| `ntfs.sys` | **0.93** | 正常系统驱动 |

**正常驱动分更高**——因为它文件大、导入表完整、设备名多、xref 多。
`confidence` 度量的是"我把它看懂了多少"，**不是"它有多危险"**。

修法：新增独立的 `riskScore`（只由危险信号构成），`triage` 改用它判定：

```
criticalDevice（暴露物理内存）   +0.60
likely IOCTL 数量                +0.05 × N（上限 +0.20）
命中已知样本                     +0.10
系统自带驱动（System32\drivers）  -0.20
```

修后实测：

| 驱动 | riskScore | confidence | triage |
|---|---|---|---|
| `rtcore64.sys` | **0.8** | 0.83 | **investigate** |
| `acpi.sys` | 0.2 | 0.93 | weak |
| `ntfs.sys` | 0.2 | 0.93 | weak |

**顺序正确了。** 两个指标各司其职：`confidence` 说明分析可靠性，`riskScore` 说明危险度。

---

## 2. 为什么会粗糙：不是技术不够，是开发方式

| 现实 | 后果 |
|---|---|
| **任务驱动**：功能"能跑通 + 门禁过"就算完成 | 精度无人验收 |
| **24 道门禁全是结构测试** | **没有一道测判断准确率** |
| **没有 ground truth**（无标注驱动集） | 所有权重、阈值都是猜的 |
| **广度优先**：69 个 verb | 每个都是浅实现 |

**"门禁全绿" ≠ "判断准确"。** 这是当前最危险的状态：项目看起来质量很高（24 道门禁全过），但它验证的是"功能存在"，不是"结论正确"。

---

## 3. 对"漏洞分析"定位的影响

用粗糙的静态分析直接冒充漏洞判定，会出现：

| 失效 | 原因 |
|---|---|
| **漏报** | 真正的入口可能是 `MOV` 而非 `CMP`，提取不到 |
| **误报** | 正常功能驱动的 IOCTL 被当危险（不看控制流） |
| **不可解释** | `0.63` 说不出为什么，无法申诉也无法复核 |

用户如果拿这个结果去筛驱动，**会被误导**——这比"没有工具"更糟。

---

## 4. 关键判断：动态验证绕过静态粗糙

| 静态分析（粗糙） | 动态验证（不依赖静态精度） |
|---|---|
| "猜这个常量是 IOCTL 码" | **直接把码发过去，看有没有反应** |
| "猜这个设备名是入口" | **枚举 `\Device\` 下的对象，逐个试打开** |
| "猜参数结构" | **发畸形包，看崩不崩 / 越不越界** |

**fuzzing 的本质就是"不需要精确知道，发一堆过去看哪个有反应"。**

`ERROR_INVALID_FUNCTION` = 不认这个码；`ERROR_INVALID_PARAMETER` = 认了但参数不对；返回数据 = 通了；蓝屏 = 校验缺失的铁证。

**IOCTL 码甚至可以暴力枚举**：从驱动常量里提取一批候选码 → 全发一遍看哪个返回不是 `ERROR_INVALID_FUNCTION`。**这一步不需要任何静态精度。**

---

## 5. 修正清单

### 5.1 该修（粗糙直接造成的硬伤）

| # | 项 | 说明 | 成本 | 状态 |
|---|---|---|---|---|
| 1 | ~~签名统计 bug~~ | 实测无误（早期文档误判），无需修 | — | ✅ 已核实 |
| 2 | **IOCTL 候选 tier 分层** | 真 bug：符号不一致导致全掉 `possible`；已改用高 4 位判断 | 1 小时 | ✅ **已修** |
| 3 | **`confidence` / `riskScore` 分离** | confidence 测分析完整度、riskScore 测危险度；triage 改用 riskScore | 半天 | ✅ **已做** |
| 4 | **ground truth 校准** | 22 个 CVE 驱动哈希（LOLDrivers CSV）+ 30 个系统驱动做基线；实测安全驱动 riskScore ≤ 0.2、rtcore64 = 0.8，阈值 0.4 有 2 倍边际 | 半天 | ✅ **已做** |
| 5 | **精度门禁** | `tests\DriverAccuracyTest.ps1`（11 断言）：零假阳性 / 真阳性 / ground truth 合法 / 阈值自洽 / 已知样本命中 / 不刷屏 | 半天 | ✅ **已做（第 25 道门禁）** |

### 5.2 不该修（动态验证会绕过）

- 反汇编器（不需要）
- 精确控制流 / 数据流分析（不需要）
- 完美的设备名自动发现（枚举 + 逐个试打开就够）

### 5.3 该补（当前完全缺失）

**精度测试**：门禁里加一道"用 ground truth 跑分类，准确率必须 ≥ 阈值"。

> 没有这道，永远不知道粗糙到什么程度；有了它，粗糙程度变成一个**可观测的数字**，而不是"感觉"。

---

### 5.4 第一版校准结果（2026-11-12 实测）

**ground truth 构成**：
- 已知安全：30 个微软签名系统驱动（`%SystemRoot%\System32\drivers`，零风险）
- 已知有洞：22 个 CVE 驱动哈希（LOLDrivers CSV，`tests\fixtures\accuracy\known-cve-sha256.txt`）
- 本地真样本：`rtcore64-01aa278b.sys`（之前实测过 kread 成功读回内核 MZ）

**实测分布**：

| 对象 | riskScore | 判定 |
|---|---|---|
| 30 个系统驱动 | max **0.2**（32 个里 30 个都是 0.2） | 全部 benign/weak |
| `rtcore64.sys` | **0.8** | investigate |

**结论**：
- 假阳性 = **0**（系统驱动无一 ≥ 0.4）
- 阈值 0.4 有 **2 倍安全边际**（安全上限 0.2，真漏洞 0.8）
- 分界自洽：`<0.15` benign / `0.15-0.4` weak / `≥0.4` investigate（门禁 ACC-4 校验）

**诚实的局限**：
- 召回率**未验证**——只有 1 个本地真样本（rtcore64）。22 个 CVE 哈希目前只用于"如果本地恰好有这些文件则必须被判高危"，**没有下载它们的二进制**（避免杀软拦截和体积成本）
- 要验证召回，需要把 22 个漏洞驱动下载到隔离环境跑一遍——**这是下一步可选动作**

### 5.5 【已完成】VM 沙箱层（driver.vm.*，2026-11-12）

**为什么必须有它**：静态分析只能猜"这可能是 IOCTL"，真正的判定是把命令发过去。但内核驱动出错 = 整机蓝屏，所以执行必须放在**一次性 VM** 里。

**落地形态**（主机编排 + guest 执行，全部走 vmrun）：

```
主机 driver.vm.*                       VM (guest)
┌────────────────────┐   vmrun 调用    ┌──────────────────────┐
│ config / status    │ ──────────────►│ guest-probe.ps1      │
│ prepare / push     │  copyFile       │  - sc create/start   │
│ probe / snapshot   │  runProgram     │  - 取 ntoskrnl 基址  │
│                    │ ◄────────────── │  - 发 IOCTL          │
└────────────────────┘  结果/超时      │  - 写 result.json    │
                                        └──────────────────────┘
```

**实测结果**（rtcore64，Win10 1809 guest）：

```
driver.vm.probe -Apply
  → verdict = ok-data    crashed = False
  → guest: device=\\.\RTCore64  ioctl=0x80002048  ret=48  err=0
  → outHex = ... 4D-5A-90-00 ...        ← MZ 头，内核内存真读出来了
```

**崩溃语义**：`runProgramInGuest` 超时 / VMware Tools 掉线 / result.json 不更新 → 判 `crash`。**崩溃是结论，不是失败。**

**踩坑（全部实测，不在 VM 里重踩一遍会白费半天）**：

| # | 坑 | 症状 | 修法 |
|---|---|---|---|
| 1 | vmrun 空密码被拒 | `does not support empty passwords` | 给账号设密码（VIX API 硬限制） |
| 2 | 中文用户名乱码 | `C:\Users\鏃禱lct` | 全部用 ASCII 路径 |
| 3 | `runProgramInGuest -File` 不生效 | 返回空、脚本没跑 | 用 `-Command "& '<path>'"` |
| 4 | `[uint32]0x80002048` 抛异常 | 所有 IOCTL 假 87 | `[Convert]::ToUInt32('80002048',16)` |
| 5 | `[UInt64]` 转内核地址抛异常 | 地址写不进 buffer | 用 `[Int64]`（位模式相同） |
| 6 | PowerShell 调 C# `out` 参数抛 | 全 -1002 | C# 返回**结果对象** |
| 7 | Defender 拦驱动加载 | `sc start 失败 225` | `Add-MpPreference -ExclusionPath`，然后**重新 push**（旧文件被隔离） |
| 8 | `ArrayList.Add()` 返回值污染 | `data` 变成 `[0,1,{...}]` | 所有 `.Add(` 前加 `$null = ` |

### 5.6 【已完成】完整变异矩阵（driver.vm.matrix，2026-11-12）

一条命令把 `ctl.variants` 生成的变异**逐个送进 VM 执行**，输出完整矩阵。

```powershell
'{"profile":"rtcore64-01aa278b","action":"kread"}' > a.json
engine.cmd -Verb driver.vm.matrix -ArgsFile a.json -Apply
```

**实测结果（rtcore64 kread，Win10 1809 guest）**：

| 变异 | 结果 | 结论 |
|---|---|---|
| `baseline` | ok-data, ret=48, 含 `4D 5A 90 00` | 功能确认，读到内核 MZ |
| `size-zero` | ok-data, 全 0 | **不检查 0 长度** |
| `size-one` | ok-data, 只回 1 字节 `4D` | 精确按请求长度返回 |
| `size-over` (5) | ok-data, 5 字节 | 不检查越界 |
| `size-max` (0xFFFFFFFF) | ok-data | **不检查 4GB 长度** |
| `addr-null` | **error, Win32=87** | **检查了 NULL 指针**（这块校验做对了） |
| `addr-low` (0x1) | **timeout 30s，VM 还活着** | **没校验低地址有效性** |

**这是"校验不完整"的动态实证**：驱动防住了 `addr == 0`，但没防 `addr == 1`。静态反汇编只能看到"有个 cmp"，动态才能看到"cmp 之后还是崩了"。

**crash 与 timeout 必须分开**（实测教训）：
- `crash` = VMware Tools 掉线，VM 真被打死
- `timeout` = 单条超时但 VM 存活（IOCTL 挂起）
- 两者都是缺陷证据，但严重程度不同，混在一起会夸大结论

**其他工程细节**：
- 每条**独立超时**（默认 60s），一条挂起不会拖死整个矩阵
- 一旦 `crash`/`timeout` 就**停止后续**（已经挂了，继续跑没意义）
- 执行前**自动刷新** guest 的 probe.ps1（踩过坑：主机脚本改了但 guest 是旧版，旧版静默忽略新参数，表现为所有变异结果一模一样）

**安全边界**：
- 密码只存 DPAPI 加密文件（`var\vm\secret.dat`），解出来只用于 `-gp`，**不写日志**
- `push`/`probe`/`snapshot` 默认只预览，`-Apply` 才执行
- **不做自动回滚**（回滚会丢弃 VM 当前状态，必须由人决定）

### 5.7 【已完成】动态结论反哺静态分诊（2026-11-13）

**问题**：`batch.scan` 的 `riskScore` 是静态猜的；`vm.matrix` 是动态实测的。两者各说各话。

**闭环**：`vm.matrix` 跑完把结论落到 `var\vm\driver-dynamic\<sha256>.json`，
`batch.scan` 扫同一个文件时读它，算出 `finalRisk`（证据级危险度）并升级 `triage`。

**反哺规则**（动态 > 静态，因为实测结论强一个数量级）：

| 动态结论 | finalRisk | triage | 含义 |
|---|---|---|---|
| `crash` / `timeout` | **1.0** | **`confirmed`** | 实测确认有缺陷，静态分不重要了 |
| `error`（畸形包被拒） | riskScore × 0.5 | investigate / weak | 驱动**有**校验，静态猜测降权 |
| `ok-data` 全成功 | min(1, riskScore+0.35) | investigate | 畸形包也照单全收 = **无校验** |
| `no-device` | 不变 | 不变 | 设备没打开，结论不适用 |

**实测闭环**：

```
driver.vm.matrix -Apply
  → 落盘 01AA278B...F1FD.json（worst=timeout，7 条结果）

driver.batch.scan（同一个 rtcore64）
  → riskScore(静态) = 0.8      ← 保留，便于对比
  → finalRisk(综合) = 1.0
  → triage = confirmed          ← 从 investigate 升级
  → reason = 「动态确认：timeout（rtcore64-01aa278b/kread）」
```

**为什么保留两个分**：`riskScore` 是静态猜测，`finalRisk` 是证据级。留着对比才能看出"静态猜得准不准"——这本身就是校准数据。

**分诊优先级**：`confirmed`（实测确认）> `investigate`（静态可疑）> `weak` > `benign`。

### 5.8 【已完成】静态模型重定位：从"判定器"到"排序器"（2026-11-13）

**触发问题**：「静态是不是太弱了？」

**用数据回答**——拆开 rtcore64 的 `riskScore = 0.8`：

| 分项 | 分值 | 性质 |
|---|---|---|
| `criticalDevice`（设备名含 PhysicalMemory） | **0.60** | 一个**字符串匹配** |
| `likelyIoctl`（正则数出 2 个候选） | 0.10 | 唯一算"分析"的部分 |
| `knownSample`（哈希命中清单） | 0.10 | **查表** |

**75% 来自字符串匹配，真正的分析只占 12.5%。**

**致命假阴性**：一个和 rtcore64 同类、但设备不叫 `PhysicalMemory`、哈希不在清单里的驱动
→ `riskScore = 0.1` → `benign` → **根本不值得看**。

**但"加危险 API 计数"是错的方向**（差点做错）。实测：

| 驱动 | 危险 API 个数 | 实际情况 |
|---|---|---|
| tcpip.sys | **3**（KeStackAttachProcess / MmProbeAndLockPages / ZwOpenProcess） | 完全正常 |
| rtcore64 | **1**（MmMapIoSpace） | 漏洞 |

**正常网络驱动比漏洞驱动更可疑**——因为那些 API 是常规操作。

**真正有区分度的是组合**（三项同时满足，是逻辑推理不是过拟合）：

```
① 导入 MmMapIoSpace（非 Ex 变体）  → 有能力映射物理内存
② 有设备名候选                    → 暴露设备给用户态（没有 = 用户态够不着 = 不可能 BYOVD）
③ 导入总数 < 4                    → 实现极简
```

实测四项完全分开：

| 驱动 | ① | ② | ③ | 判定 |
|---|---|---|---|---|
| rtcore64 | ✓ | ✓ RTCore64 | 2 | **命中** |
| amdgpio2 | ✓ | **✗ 无设备名** | 2 | 不命中 |
| amdsbs | ✓ | **✗ 无设备名** | 2 | 不命中 |
| amdpsp | ✓ | ✓ amdpsp | 2 | 命中（值得测） |
| acpi / ntfs / tcpip | ✗ | — | — | 不命中 |

**改后效果（61 个驱动实测）**：`investigate = 2`（rtcore64 + amdpsp）、`confirmed = 1`、**待测率 3.3%**。
即使把 `criticalDevice` 和 `knownSample` 都抹掉，rtcore64 仍能靠 `0.4 + 0.1 = 0.5` 判 `investigate`。

**阈值同时从 0.40 降到 0.25**：静态的 KPI 应该是**召回**不是精度——VM 里多测一个驱动 40 秒，漏掉一个漏洞的代价是无穷。

**为什么不做反汇编**（关键决策）：

| 方案 | 依赖 | 部署影响 |
|---|---|---|
| IDA Pro | 商业授权 | 不可分发 |
| radare2 | ~50MB 二进制 | 要装、要配路径 |
| Ghidra | JDK + ~500MB | 客户机没有 |
| Capstone | .dll / Python 包 | PowerShell 调不了 |

而"分析 IOCTL 分派"最低限度需要 **x86-64 指令长度解码器**（300–500 行，覆盖子集，永远不完美）。
更关键的是：**收益已被动态覆盖**——`vm.matrix` 已经在用实测拿"校验缺失"的结论（`addr-null→87`、`addr-low→timeout`），比静态推断硬。

**结论**：静态不追求"分析"，只做**排序**（决定先测谁）；判定交给动态。
将来若做反汇编，只做**可选插件**（检测到 rizin 就用，没有就降级），绝不进主路径。

### 5.9 【已完成】诚实性修正：IOCTL 候选不再参与打分（2026-11-13）

**触发**：用 rizin 实测发现 `ioctlCandidates` 是**结构性失效**，不是精度低。

**证据链**（详见 `docs/DESIGN-RIZIN.md`）：

| 检查 | 结果 |
|---|---|
| 文件里搜 `0x80002048` 小端字节 | **0 处** |
| 反汇编 33 条 `cmp` 里 | 没有它 |
| 真实分派 | `add eax,-0x80002000` + `cmp eax,0x54` + **跳转表** + `jmp rax` |
| 动态验证 | 官方码 ok-data；随机码 `0xDEADBEEF` → 87 |

**跳转表是编译器对 `switch` 的默认生成方式**，所以这个正则在整个真实驱动世界里基本没信息量。

**改了什么**：

| 位置 | 改动 |
|---|---|
| `evidence.ioctlCandidates[].xrefHint` | `heuristic` → `heuristic-cmp` |
| `evidence` 新增 | `ioctlCandidatesMethod='heuristic-cmp'`、`ioctlCandidatesReliability='low'` |
| `draft.notes` 新增 | 明确写"对跳转表分派的驱动完全失效" |
| `confidence` | IOCTL 候选 `+0.20/+0.05` → **`+0.05`**（"扫到了"是事实，但不可靠） |
| `riskScore` | likelyIoctl **不再参与打分** |
| `batch.scan` 输出 | 新增 `ioctlReliability` 字段 |

**效果对比**：

| 驱动 | 改前 riskScore | 改后 | 原因 |
|---|---|---|---|
| rtcore64 | 1.0 | **1.0** | criticalDevice 0.6 + importSignal 0.4（真信号） |
| acpi | 0.2（weak） | **0（benign）** | 0.2 全来自 14 个噪音候选 |
| ntfs | 0.2（weak） | **0（benign）** | 0.2 全来自 38 个噪音候选 |

**代价与收益**：
- 代价：静态分只剩 **3 个真信号**（`criticalDevice` / `knownSample` / `importSignal`），对大多数驱动都是 0 分，**区分度下降**
- 收益：不再用"这个驱动有 38 个 IOCTL 候选"骗自己——那是噪音

**回归锁**：`DriverBatchTest` 新增 TB-14（4 断言）——候选多的驱动 `riskScore` 必须仍为 0，且必须带 `ioctlReliability=low`。

### 5.10 【已完成】跳转表分派识别（2026-11-13）

**目标**：把 `ioctlCandidates` 从"噪音"修成"真实的 IOCTL 码范围"。

**最终方案**（不是纯 rizin，也不是纯字节扫描）：

```
① 字节扫描找锚点：movsxd reg, dword [base+reg*4] 的编码（快，全文件毫秒级）
② rizin 只反汇编锚点前 104 字节（有指令边界，准）
③ 从反汇编文本读 add/sub(eax,imm) → 基址；cmp(eax,N) → 表大小
```

**为什么不能纯字节扫描算基址**：`3B 05 00 00 8B 40` 里的 `05` 是 **ModRM 字节**，
会被误当成 `add eax, imm32`——实测把基址算成 `0xBF750000`（真值 `0x80002000`）。
**没有指令边界就必然误匹配。**

**为什么不能 rizin 全量反汇编**：实测 20KB `.text` 要 16 秒、100KB 超 90 秒。
而且**去掉 `-A` 反而慢 6 倍**（101 秒 vs 16 秒）——`-A` 先建代码边界，之后 `pD` 才快。

**性能对比**：

| 方案 | rtcore64 | 20KB 驱动 | 100KB 驱动 |
|---|---|---|---|
| rizin 全量 `pD` | 0.5s | 16s | **>90s 超时** |
| 字节锚点 + 104 字节窗口 | **336ms** | ~340ms | ~340ms |

**实测结果（rtcore64，14KB）**：

```
dispatch.hit   = True
dispatch.base  = 0x80002000
dispatch.count = 85
dispatch.range = 0x80002000..0x80002054      ← 真值（动态验证：0x80002048 = kread）
method         = bytes-anchor+rizin-window
```

**覆盖率实测（18 个"有设备名"的驱动）**：**命中 1 / 18（5.6%）**

| 情况 | 数量 | 说明 |
|---|---|---|
| 命中 | 1（rtcore64） | 有完整跳转表 |
| 有 `movsxd` 但链条不全 | 4（ntfs/tcpip/ClipSp/AppvVemgr/FsWriteBack64） | 可能用了别的分派形态 |
| 完全没有 `movsxd` | 13 | 不用 jmp-table 分派 |

**这是真实情况**：漏洞驱动通常**小而简**（rtcore64 才 14KB，只做读写内存），
功能驱动（fltMgr/ntfs/tcpip）不需要简单分派。所以能力对**目标人群**有效，但覆盖面窄。

**降级路径**：没有 rizin 时只报 `hit=true`（确认有跳转表结构）+ `degraded=true`，
**不猜基址**（`base='?'`）。**识别不出就说不知道，不编造。**

**边界验证的诚实结论（重要局限）**：

动态实测静态提取的范围边界：

| IOCTL 码 | 动态结果 |
|---|---|
| `0x80002048`（范围内，已知 kread） | **ok-data，读到 MZ** ✓ |
| `0x80002000` / `0x80002054`（范围内边界） | error 87 |
| `0x80002055` / `0x80001FFF`（范围外） | error 87 |

**87 无法区分"码不在表里"和"码在表里但参数不对"**——所以
"边界内外可区分"这个更强的验证**不成立**。
能确认的只有：**范围来自真实反汇编，且必含已知有效码**。
"范围内每个码都有有效 handler"仍需逐条动态验证。

### 5.11 【已完成】差分探测推字段布局（driver.vm.fields，2026-11-13）

**目标**：profile 的另一半——`in` 字段布局——能不能自动推出来。

**方法**（纯动态，零依赖）：
```
1. 建立 baseline（addr 用 guest 内核基址、readSize=4）
2. 逐 4 字节块改动，重发 IOCTL
3. 比较：verdict/返回值变 → 强有效；只有该块自身输出变 → 回填噪音；全不变 → padding
```

**实测（rtcore64，48 字节 payload，12 块，66.7 秒）**：

| 块 | 判定 | 对应 profile 字段 |
|---|---|---|
| offset 0 / 4 | active-weak（回填噪音） | pad0 |
| offset 8 / 12 | **masked**（被 patch 遮罩） | addr（确实是字段，但被 addr patch 覆盖） |
| offset 16 | active-weak | pad1 |
| **offset 20** | **active-strong** | **offset** ✓ |
| **offset 24** | **active-strong** | **readSize** ✓ |
| offset 28 | padding | value（可能只写不读） |
| offset 32..44 | active-weak | pad3 |

**自动推出 3/4 个真字段**（offset / readSize / addr），只有 `value` 漏掉。

## 三条血泪教训（都是踩出来的）

**① 扰动量决定生死 —— 不要用 0xFF**

第一次用 `0xFF` 扰动 `offset` 字段（20）→ 驱动按 4GB 偏移访问 → **直接 BSOD，VM 进了恢复界面**。

改成 **`+1` 温和扰动**后：同样的字段能被识别为 `active-strong`，**且不崩**。

`-Aggressive` 才用 0xFF（能探出"无边界检查"这类最严重问题，但会 BSOD）。

**② `crashed` 判定不能只看 `checkToolsState`**

BSOD 后 Windows 在重启，`checkToolsState` 可能**短暂仍报 running**。当时我们据此判定"只是挂起"，于是继续探测 → 连撞两次。

修正：超时后**多等 6 秒**复查 + 用 `vmrun list` 确认 VM 是否真的消失。

**③ 输出比较必须排除「自身回填区」**

很多 buffered IOCTL 会把整个输入结构回填到输出（rtcore64 的 out 和 in 布局完全一样）。
那样改**任何**字节都会改 outHex —— 全被判成 active。

修正：只比较该块**之外**的输出字节变了没有。真影响内容的才算 `active-strong`。

**降级保护**：
- `-SafeMode` 只探前 16 字节（相对不容易越界）
- 遇到崩溃**立刻停**（不再"尝试恢复继续"——那个假设是错的）

**局限（诚实）**：推得出「哪些偏移是字段、多宽」，推不出**语义**（是 addr 还是 size）。那个还得人命名。

### 5.12 【已完成】批量矩阵 + 崩溃自动恢复（driver.vm.batch，2026-11-14）

**目标**：从"一次测一个驱动"到"扫一个目录自动测完"。

**两件事必须解决**：

**① 任务收集**：只有**有 profile** 的驱动才可测（profile 是执行的前提）

```
-Dir <目录>       扫 .sys → 算 sha256 → 匹配 var\driver-profiles\*.json 的 target.sha256
-Profiles <id列表> 直接给 profile id（在 var\samples\ 找对应 .sys）
```

实测 `-Dir` 扫 2 个驱动 → 只有 rtcore64 有 profile，acpi **正确跳过**并说明原因。

**② 崩溃自动恢复**

```
检测到 crash → revertToSnapshot → 启动 VM → 等 tools → 重建环境 → 继续下一个
```

**踩的坑（关键）**：`revertToSnapshot` 会把 VM **关机再恢复，但不自动启动**。

实测症状：回滚后 `vmrun list` 显示 0 台在跑、`checkToolsState` 返回 **`installed`**（不是 running），后续所有 guest 操作报 `The virtual machine is not powered on`。

修法：回滚后**主动 `vmrun start <vmx> nogui`**，再等 tools（给足 3 分钟）。

**实测结果（1 个驱动，含崩溃）**：

```
总耗时 1.3 分钟
rtcore64: crashed=True  recovered=True  okData=5 error=1 timeout=1
VM: running（恢复后继续可用）
```

**恢复时间预算**：revert ~5s + start ~5s + 等 tools ~5-40s + 重建环境 ~10s ≈ **20-60 秒/次崩溃**。

**安全设计**：
- 没给 `-Snapshot` 时，崩溃**直接停**（无法把 VM 恢复到干净状态，继续只会连锁失败）
- `-MaxMinutes` 兜底（防止跑飞）
- `-MaxDrivers` 限制批量规模

**局限**：目前只有 rtcore64 一个 profile，所以批量实际只测 1 个。要真正批量，得先有更多审定过的 profile（`driver.profile.draft` + 人工确认 + `driver.vm.fields` 辅助）。

### 5.13 【已完成】破解「没 profile 就没法测」的死结（2026-11-14）

**问题**：动态能力全建好了，但只有 1 个 profile 可测。静态挑出来的驱动，正因为没 profile 而测不了。

**两条破解路径都实现了**：

**① `driver.vm.discover`（暴力扫 IOCTL 码）**

不需要任何前提，遍历码范围 + 观察响应：

| 响应 | 判定 |
|---|---|
| `ok-data` | **确定是这个码**（功能执行成功） |
| `ERROR_INVALID_FUNCTION(1)` | 确定不认这个码 |
| 其他错误码（如 1450 ERROR_NO_SYSTEM_RESOURCES） | **码有效**但调用失败（强信号） |
| `ERROR_INVALID_PARAMETER(87)` | **无法区分**"认了但参数不对"和"不认" |
| 崩溃/超时 | 该码越界/死锁（有效证据但危险） |

**候选分两档**（诚实标注不确定性）：
- `strongCandidates`：accepted / other-error / timeout
- `weakCandidates`：87 —— 可能包含被 NULL 检查掩盖的真码

**实测（rtcore64，16 码，69 秒）**：
```
0x80002040  1450（强）    0x80002048  87（弱，但这是真的 kread！）
0x8000204C  1450（强）    其余        87
```
**已知限制**：全 0 payload 会被 NULL 检查掩盖（kread 在 addr=0 时返回 87，看起来和不认码一样）。要确认弱候选得配合 `vm.fields`。

**② `driver.profile.fromprobe`（探测 → 可审定 profile）**

自动填的部分（**从 107 行降到改 3 行**）：

| 字段 | 来源 |
|---|---|
| `target.sha256` / `fileName` | 算 |
| `locate.candidates` | 静态扫（注意：是 PSCustomObject，要取 `.text`） |
| `actions[].ioctl` | 参数 / dispatch 范围 |
| `actions[].in` | 两轮差分探测 + **相邻块合并** |
| `actions[].out` | **默认不写 = in 的镜像**（实测 rtcore64 7 个字段完全一致） |
| `layout.method` | **`ioctl & 3`**（0=buffered 1=in-direct 2=out-direct 3=neither） |
| `presets` | baseline |

**两轮探测是必需的**（实测）：
```
轮 1 无 patch：payload 全 0 → 能探到 addr（addr=0 得 87，addr=1 行为变）
轮 2 有 patch：把 addr 槽位换成 guest 内核基址 → baseline 才能成功 → 探到 readSize 等
```

**自动推导 patch**：用轮 1 合并后的第一个确认字段当 patch 偏移 —— rtcore64 实测自动得到 `8:8`（正好是 addr 的正确位置和宽度）。

**相邻块合并**（关键）：探测粒度是 4 字节，一个 u64 字段会表现成两块相邻 active-strong。不合并会把 `addr(u64@8)` 拆成 `field_8 + field_12`，而且**自动推导的 patch 只剩 4 字节 → baseline 必失败**（踩过）。

**实测结果（rtcore64，117 秒，自动推导 patch）**：
```
no-patch:        strong=2  → 8/12 → 合并成 field_8 (u64)
with-patch(8:8): strong=1  → 24

生成布局: pad_0(8) + field_8(u64) + pad_16(8) + field_24(u32) + pad_28(20)
真实对照: pad0(8) + addr(u64) + pad1(4) + offset(4) + readSize(4) + value(4) + pad3(16)
```

**自动找出 addr 和 readSize**（2/5 个真字段），漏了 `offset`（改动不改变"是否 87" → 看起来像 padding）和 `value`（只写不读）。

**安全设计**：产物带 `source.needsReview=true` + `probeGenerated=true` —— **不能直接执行**，必须先人工改字段名 + 确认 risk 再删掉 needsReview。

**P3（一次性 profile，不落盘）现状**：`fromprobe` 已覆盖核心需求（探测 → 落盘 → 审定）；"完全不落盘直接测"的形态尚未实现，因为审定这一步本身就是安全边界。

### 5.14 【已完成】不再要求「人工审定」（2026-11-14，定位修正）

**用户指出一个根本问题**：

> VM 存在的意义就是「不用审定也不会出事」。要求人审定 = 要求他懂 Windows 内核 = 这恰恰是工具该消除的门槛。

**这个批评是对的，而且我错在更基础的地方** —— 查下来那套「不能直接执行」的护栏：

```
Test-LctDriverProfile 只检查 draft.needsReview（静态草案块）
而我写的 source.needsReview —— 全代码库零引用
```

**即：文档里要求人审定，代码里根本没拦。一个既没用又添堵的设计。**

## 安全边界的正确位置

| 场景 | 代价 | 需要审定 |
|---|---|---|
| VM 里 push 驱动 | 回滚 30 秒 | 不需要 |
| VM 里发任意 IOCTL | 回滚 30 秒 | 不需要 |
| VM 里崩十次 | 30 秒 × 10 | 不需要 |
| **VM 结论 → 实体机动刀** | **用户机器蓝屏** | **必须** |

**护栏只该有一道，放在最后那一步。** 之前把它提前到第一步，等于让人先考个内核证。

## 三处改动

**① `fromprobe` 去掉 needsReview**

改成 `verifiedInVm: true` + `readyForVm: true`。产物**直接可用**。

**② `vm.matrix` 接受探测产物（真正的拦路虎）**

发现真正拦住探测产物的不是 needsReview，而是：

```
profile 的 in 字段里既没有地址字段也没有长度字段，无法自动变异
```

`New-LctCtlPayloadVariants` 靠**正则匹配字段名**（`addr|address|base`、`size|length|len`）识别语义，探测产物的 `field_8` 不匹配就拒绝。

**修法：加「无语义通用变异」降级路径** —— 对每个**数值字段**挨个试 `0 / 1 / 最大值`。

这其实**覆盖面更广**（不依赖"猜对哪个是 addr/size"）。实测 rtcore64 生成 7 条（baseline + field_8×3 + field_24×3）。

**③ 新增 `driver.vm.explore`（全自动探索）**

```
push → discover 扫码 → fromprobe 探布局 → matrix 跑变异 → 能力报告
```

**不需要 profile，不需要审定。** 实测 97 秒出报告。

## 实测发现（explore 的价值证明）

用探测产物直接跑 matrix，得到：

```
field_8-one   (addr=1)                  → ok-data, 返回 48 字节
field_8-max   (addr=0xFFFFFFFFFFFFFFFF) → ok-data, 返回 48 字节
baseline      (addr=0)                  → error 87
```

**addr=1 和 addr=全F 都成功返回 48 字节** —— 完全不校验地址。

⚠️ **但有一个矛盾要交代**：手工测 `addr=1` 时是 **timeout（驱动挂起）**，而 matrix 里 `field_8-one` 是 `ok-data`。说明**探测产物的值可能没有正确传到驱动**（编码或用例构造有 bug）。这个必须查清，否则结论不可信。

## explore 当前的局限

**发现能力受限**：`discover` 里 `87` 无法区分"认了码但参数不对"和"不认码"，导致真码 `0x80002048` 落在弱候选里，被 `maxCodes` 截断掉。

实测（count=8, maxCodes=1）：
```
discover: accepted=0 otherError=1 invalidParam=7
probes:   0x80002004(字段0)     ← 试错了码
theCode=  (空)                   ← 没找到真码
```

**改进方向**：discover 用**多 payload 变体**（全 0 / 全 1 / 全 FF）替代单一全 0，从而区分 87 vs 行为变化。代价是每码 3 倍时间。

### 5.15 【已修复】探测产物的两个真 bug（2026-11-14）

上一节写的「addr=1 和 addr=全F 都成功返回 48 字节 → 完全不校验地址」**是错的**。查清后是两个真 bug。

## Bug 1：presets 为空 → 驱动全程 no-op

**现象**：matrix 里 `field_8-one`（addr=1）返回 `ok-data, ret=48`，手工测 `addr=1, readSize=4` 却 **timeout**。

**排查**：把 matrix 的实际编码拿出来看，`addr=1` 落在 offset 8-15 **完全正确**。差异在 **readSize**：

| 用例 | readSize | 结果 |
|---|---|---|
| addr=1 | **0** | `ok-data, ret=48, 非MZ` ← 什么都不读，直接成功 |
| addr=1 | 4 | **挂起（timeout）** |
| addr=1 | 1 | **挂起（timeout）** |

**根因**：探测产物的 `presets` 是空的 → 所有字段默认 0 → `readSize=0` → **驱动全程空转**。
于是 matrix 里一堆"ok-data"看起来无害，其实根本没干活。**真实 profile 的 `presets` 是 `{readSize:4}`，正是因为不给 size 就测不出东西。**

**修法：presets 扫描**。探测完字段后，对每个确认字段试 `1/4/8/16`，找"能让返回数据非全 0"的值：

```
field_8 被 patch 覆盖，跳过
field_24=1 让返回数据非全 0 ✓   →   presets = {"field_24": 1}
```

**验证（修复后真跑 matrix）**：

```
baseline        error 87    ← addr=0（NULL 检查）
field_8-zero    error 87    ← addr=0
field_8-one     timeout     ← addr=1 + readSize=1 → 挂起  ✅ 与手工测一致
```

**「编码不一致」到此澄清：编码一直是对的，错的是用例参数。**

## Bug 2：对齐把 48 变 52

**现象**：探测产物编码后 **52 字节**，驱动期望 48。

**根因**：`ConvertTo-LctPrfBuffer` 每字段按 `min(字段大小, align=8)` 对齐。

```
探测产物: pad_0(8) + field_8(u64,8) + pad_16(8) + field_24(u32,4) + pad_28(20)
                                                              ↑ 从 28 开始
对齐: 28 % 8 = 4 → 填充 4 字节 → pad_28 实际从 32 开始 → 总长 52
真实 profile: pad3 从 32 开始（4+4+4+4 正好凑齐），不触发填充
```

**修法**：布局生成改成**按目标偏移逐字节铺 padding**：

- 8 字节 padding 块**只在 cursor 是 8 的倍数时**用（否则它自己会被对齐推走 —— 实测在偏移 28 放 8 字节块 → 28%8=4 → 填充到 32 → 长度失控）
- 其余位置用 1 字节 padding（step=min(1,8)=1，任何偏移都对齐）

**验证**：所有变异编码长度 **48 字节**，`baseline offset 24-27 = 01000000`（preset 生效）。

## 顺带修的一个低级错误

`Invoke-LctVmFromProbe` 里从来没调 `Test-LctVmReady`，导致 presets 扫描时 `$ready` 是 null → `Join-Path $gdP ...` 报 `Cannot bind argument to parameter 'Path' because it is an empty string`。

## 教训

**「看起来有效」和「真的在干活」是两件事。** 探测产物一开始就能跑出"ok-data"，但那是因为 `readSize=0` 让驱动什么都不做。**没有 presets 扫描，整套动态验证的结论都是假的。**

### 5.16 【已修复】discover 的发现能力：多 payload 对比（2026-11-14）

**问题**：`87` 无法区分「认了码但参数不对」和「不认码」，真码 `0x80002048` 落在弱候选里被 `maxCodes` 截断。

实测（单 payload 全 0）：
```
discover: accepted=0 otherError=1 invalidParam=7
0x80002048  → 87（真码，但和"不认"长得一样）
```

**修法**：每个码发 **2 个 payload**（全 0 / 全 0x01），比较响应。

**原理**：全 0 会被 NULL 检查拦成 87；全 0x01 是「非 NULL 但无效」的值。
如果两次响应**不同**，说明这个码**确实在处理参数** → `param-sensitive`（强信号）。

**实测结果（8 个码，96 秒）**：

| 码 | 判定 | zeros | ones |
|---|---|---|---|
| `0x80002048` | **accepted** | 87 | **ok-data** ← 真码找到了 |
| `0x80002044` | **timeout** | 87 | **挂起** ← 有效码 |
| `0x8000204C` | **accepted** | 1450 | **ok-data** |
| `0x80002040` | other-error | 1450 | 1450 |
| `0x80002050`~`0x5C` | invalid-param | 87 | 87 ← 真正无效 |

**强候选从 2 个变成 4 个，且包含了真码。**

**代价**：每码 2 次（时间 ×2），8 码 96 秒 → 64 码约 13 分钟。对全自动探索可接受。

**副产品发现**：`0x80002048` 在 `addr=0x0101010101010101`（无效地址）+ `readSize=0x01010101`（巨大长度）下返回 **ok-data** —— 说明驱动**不校验地址有效性**，读失败也不报错。（需进一步确认返回的数据内容。）

### 5.17 【已完成】完整 explore 端到端实测（2026-11-14）

**参数**：`count=64, maxCodes=3, timeoutSec=10`，驱动 rtcore64（无 profile 前提下）。

**结果：14.4 分钟，全自动出能力报告**：

```
sha256=01AA278B...  dispatch=0x80002000..0x80002054
设备名: \Device\PhysicalMemory | \DosDevices\RTCore64 | \Device\RTCore64

discover（64 个码，多 payload 对比）:
  accepted=2  otherError=2  invalidParam=58  timeout=2  crash=0

fromprobe:
  0x80002048  字段=2   ← 真码
  0x8000204C  字段=2   ← 也有效
  0x80002004  字段=0   ← 试错

theCode = 0x80002048   ← 自动选中真码
profile 已生成
```

**能力报告（机器自动产出）**：
- 发现 2 个功能可用的 IOCTL 码
- 另有 2 个码被处理但调用失败（说明码有效）
- 存在会让驱动挂起/崩溃的 IOCTL 码
- 确定可用码 `0x80002048`，布局已探出 2 个字段

**这是完整的价值闭环**：给一个 `.sys`，**不需要 profile、不需要人审定**，14 分钟拿到"它能做什么"。

## 过程中修的两个 bug

**① explore 的最后一码覆盖问题**

`fromprobe` 每次写同一个 profile 文件；explore 试了 3 个码，**最后一个（探不到字段的空产物）覆盖前面成功的**。

修：探到字段就**立刻定案并停止**后续探测。

**② 读取 profile 的坑（不是代码 bug，是我诊断时写错）**

我用 `$np.actions.($np.actions.PSObject.Properties.Name[0])` 读 action，一度误判"产物是空的"。
实际落盘 JSON 完全正确：

```
"actions": { "auto": { "ioctl": "0x80002048", "in": [ ... 6 个 padding ... ], "presets": {} } }
```

**教训**：诊断时先看原始 JSON 文本，别只看自己解析出来的对象。

## 一个不稳定的现象（诚实记录）

**重跑时 `confirmed=0`**（探不到字段），而同参数在完整 explore 那次是 `字段=2`。

**推测**：VM 里驱动状态不干净（前面的 timeout 让驱动卡在某个状态，`sc stop/delete` 不足以完全恢复）。

**建议**：跑 explore 前先回滚快照，而不是只清服务。这条待后续验证。

## 6. 演进路线

```
阶段 1  修 bug + 建 ground truth + 校准 confidence + 精度门禁
          产出：静态分诊的准确率从"未知"变成"可测的数字"

阶段 2  payload 变异生成器 + 单驱动 probe                    ← 【已完成 2a】
          从 profile 的 in 布局生成：合法包 / 边界值(size=0,±1) / 畸形包(无效地址、0xFFFFFFFF)
          ctl.probe：逐级升级发送，记录每次返回
          产出：单驱动的"校验缺失"实证（不需要 VM，手动快照即可）

          ✅ 2a 已完成（2026-11-12）：driver.ctl.variants + driver.ctl.probe
             * variants：纯逻辑，从 in 布局生成 11 条变异（baseline / size×4 / addr×5 / 跨页×1）
             * probe：默认只预览（sent=0），-Apply 才真发；逐条记录 verdict
                （ok-data / error-param / error-invalid / timeout / crash）
             * 实测（rtcore64 kread）：11 条变异全部生成正确，probe 预览 11/11 verdict=preview
             * 门禁：DriverProbeTest 19 断言；总门禁 26 道
             * 踩坑：OrderedDictionary 的键不在 PSObject.Properties 里（profile/presets 都中招）

阶段 3  batch.probe 编排
          多驱动循环 + 自动 cleanup + 崩溃标记（崩溃 = 结论，不是失败）
          产出：一批驱动的可复现结论

阶段 4  VM 崩溃隔离
          心跳检测 + 快照回滚
          产出：无人值守批量验证
```

**关键**：阶段 2 就能产出"漏洞确认"级别的结论，且不依赖任何基础设施。阶段 4 只是为了"批量"和"无人值守"。

---

## 7. 负空间声明（本文没讲什么）

- **没讲反汇编方案** —— 明确不做：成本 3-6 个月，做出来也不如 IDA/Ghidra，且动态验证已能覆盖判定需求
- **没讲 VM 具体选型**（Hyper-V / VMware / VirtualBox）—— 属于阶段 4 的决策，届时再定
- **没讲 payload 变异的具体生成规则** —— 属于阶段 2 的实现细节
- **没讲 ground truth 从哪来** —— 需要从公开 CVE 驱动（RTCore64 / NTIOLib / CPU-Z 等）+ 系统驱动 + 自建样本里凑，具体清单待定

---

## 8. 一句话

**静态分析粗糙是事实，但它不是"要不要改"的问题，而是"靠什么绕过"的问题。**

静态粗糙 → 只当粗筛，不当法官。
动态验证 → 这才是护城河，而且它不吃静态精度。

**最该补的不是精度，是"精度测试"** —— 让粗糙程度变成一个可观测的数字。
