# 踩坑速查

> **这份文档只记录"不报错但结论错"和"直接崩"的坑。**
> 每一个都真实发生过，都带**判据**（怎么一眼看出自己踩了）。
>
> **改代码前扫一眼对应的分类**；遇到"数据看着对但结论不对"时，来 §9 看看。

---

## 目录

| 分类 | 什么时候看 |
|---|---|
| [§1 编码与序列化](#1-编码与序列化) | 中文乱码、文件解析失败、`.cmd` 报错 |
| [§2 PowerShell 语言陷阱](#2-powershell-语言陷阱) | 值不对、循环不执行、判断恒假 |
| [§3 驱动与内核（实体机）](#3-驱动与内核实体机) | 加载/卸载驱动、kread 读不到数据 |
| [§4 VM 沙箱（vmrun / guest）](#4-vm-沙箱vmrun--guest) | vmrun 静默失败、guest 不响应 |
| [§5 kread 读内核对象](#5-kread-读内核对象) | 拿不到 DRIVER_OBJECT |
| [§6 静态反汇编（rizin）](#6-静态反汇编rizin) | 反汇编结果不对、识别不到跳转表 |
| [§7 动态验证（matrix / payload）](#7-动态验证matrix--payload) | 每个码都"成功"或都 87 |
| [§8 测试与门禁](#8-测试与门禁) | 门禁突然红了 |
| [§9 方法论级教训](#9-方法论级教训) | **最值钱的一节** |

---

## §1 编码与序列化

### 1.1 中文变乱码 / `The string is missing the terminator`

**症状**：解析器报一堆 `using`/`DllImport` 的假错；引擎表现为 `availability.X=false`、
`loadErrors` 有原文、verb 返回"依赖未就绪"。

**原因**：文件丢了 UTF-8 BOM，PS 5.1 按 GBK 解析 → 中文吞引号 → 整份文件解析失败。

**修法**：跑 `tests\Fix-Encoding.ps1`。

**纪律**：**编辑工具（edit/write）每次重写都会丢 BOM**，改完立刻跑 `Fix-Encoding`。

**判据**：先看 BOM 字节与 `Parser::ParseFile` 的 `parseErrors` 数，
**不要先怀疑语法/here-string**。

### 1.2 `.cmd` 必须纯 ASCII

`.cmd` 出现在 `Fix-Encoding` 的检查范围里（`badCmd=0` 要求）。中文注释会破坏批处理解析。

### 1.3 profile 的 `out` 不必写

实测 rtcore64 的 `out` 与 `in` **7 个字段完全一致**（驱动把整个输入回填）。
默认"= in 的镜像"即可；`layout.method` 也能从码算出：`ioctl & 3`。

---

## §2 PowerShell 语言陷阱

### 2.1 只读自动变量（`$pid` / `$home` / `$host` …）

```powershell
$pid = 123    # ✗ Cannot overwrite variable PID（只读）
```

**PS 5.1 只读名单**：`$pid`、`$host`、`$home`、`$true`、`$false`、`$ExecutionContext`、
`$PSVersionTable`、`$PSCulture`、`$PSUICulture`、`$PSHome`、`$ShellId`、`$ConsoleFileName`。

`tests\Lint-PowerShell.ps1` 会提前抓出来。

### 2.2 `$Args` 阴影

简单函数里用 `$Args` 当形参 → **被自动变量 `$args` 静默顶掉**（绑成空 `Object[]`，不报错）。

**修法**：`[Alias('Args')][object]$ArgBag`；高级函数（带 `[Parameter()]`）不受影响。

**历史事故**：`Add-LctPending` 因此让**全站"应用"发空 `{}`**，而 7 道门禁全绿照不出来。

### 2.3 `0xFFFFFFFF` 是 `int32 = -1`

```powershell
if ($c -gt 0xFFFFFFFF) { ... }        # ✗ 对任何正数都成立 → 循环立刻 break
[uint64]0xFFFFFFFF                    # ✗ 抛 Cannot convert "-1" to UInt64
[math]::Pow(2, 32)                    # ✓ 或直接写 4294967296
```

**实测**：`vm.discover` 的 `count=0` 就是这个。

### 2.4 `0xC0000000` 是 `int32 = -1073741824`

```powershell
[K]::CreateFileW($path, 0xC0000000, ...)                    # ✗ 传给 uint32 形参抛异常 → 静默失败
$access = [System.Convert]::ToUInt32('C0000000', 16)        # ✓
```

### 2.5 `[ordered]@{ x = @() }` 是固定大小数组

对它 `.Add()` 抛 `Collection was of a fixed size`。

**修法**：用独立的 `New-Object System.Collections.ArrayList` 收集，最后赋给 hash 的 key。

### 2.6 ★ `[pscustomobject]` ≠ `IDictionary` —— 最隐蔽的一个

**这是本轮最贵的坑**，直接导致"每个码都返回 87，看起来全无效"。

```powershell
# profile 里写的是： "presets": { "readSize": 4, "offset": 0 }
# 读出来是 OrderedDictionary（不是 PSCustomObject）

# ✗ 遍历 PSObject.Properties 拿到的是字典自己的属性：
foreach ($p in $raw.PSObject.Properties) { $vals[$p.Name] = $p.Value }
#   → Count=2, IsReadOnly=False, Keys=..., Values=..., IsFixedSize=..., SyncRoot=..., IsSynchronized=...
#   → 键值对（readSize/offset）一个都没拿到 → payload 全 0

# ✓
if ($raw -is [System.Collections.IDictionary]) {
    foreach ($k in $raw.Keys) { $vals[[string]$k] = $raw[$k] }
} else {
    foreach ($p in $raw.PSObject.Properties) { $vals[[string]$p.Name] = $p.Value }
}
```

**后果链**：`presets` 丢 → `readSize=0` → **驱动空转** → 结论全假。

**判据**：payload 编码出来后，**先看 `readSize` 字段的字节是不是非 0**
（RTCore64 在 offset 24）。全 0 就先怀疑 presets 没进来。

**同一种数据在两条路径上处理不一致** —— `Get-LctVmProp` 判了 `IDictionary`，
`New-LctVmPack` 没判。**看到"某个值在 A 处能读到、B 处读不到"时，先查类型分派**。

### 2.7 单引号字符串不能跨行

```powershell
$n = '第一行
第二行'          # ✗ ParserError: Unexpected token
```

跨行用 here-string，或数组 `-join`。

**here-string 开头必须紧跟换行**：`@'` + 立刻换行（`@''` 或 `@'''` 都会报
`No characters are allowed after a here-string header`）。

### 2.8 `$(...)` 在双引号字符串里会被宿主立即求值

生成"含 `$(if ...)` 的 PowerShell 代码"时，如果外层用双引号，`$(...)` 会被**当前进程**算掉
（报 `$x is not recognized`）。用单引号 here-string，或拆成中间变量。

### 2.9 `-LeafBase` 是 PowerShell 6+ 的参数

PS 5.1 用 `[IO.Path]::GetFileNameWithoutExtension()`。

### 2.10 ★ `$内核地址 -gt 0` 恒为 false

判断"是不是有效内核地址"时**不能写 `-gt 0`**（内核地址作为 `Int64` 是负数）。

```powershell
# ✗
if ([LctAnchor]::IsKernel($fp) -and $drvStart -gt 0) { $rva = $fp - $drvStart }
# ✓
if ([LctAnchor]::IsKernel($fp) -and [LctAnchor]::IsKernel($drvStart)) { $rva = $fp - $drvStart }
```

**实测后果**：`RVA` 恒为 -1 → 28 项 `MajorFunction` 全部被判成"不在驱动内"，
而**实际读出来的值是对的** —— 数据对、判断错，特别误导。

### 2.11 `ArrayList.Add` 会污染函数返回值

`$list.Add($x)` 返回新索引 → 如果这是函数的最后一句，返回就变成 `[0,1,{...}]`。

**一律写**：`$null = $list.Add($x)`。

**同类**：函数里写 `return , @($arrayList)` 时，调用方 `@(f)` 只有 1 个元素
（`@()` 不会递归展开）。需要"把数组作为整体塞进 JSON 值"才用 `,`，否则 `return $collection`。

---

## §3 驱动与内核（实体机）

### 3.1 ★ kread 单次只支持 1/2/4 字节

```
size=1 → 4D           ✓      size=4 → 4D 5A 90 00  ✓
size=2 → 4D 5A        ✓      size=3/5/8/16/32/64 → 全 0  ✗
```

`DeviceIoControl` 返回 `True`、`bytesReturned=48`，**但驱动根本没读**。

**这个坑害过一次严重误判**：读 `FILE_OBJECT+0x08`（8 字节）得到全 0，于是断定
"Win10 19045 混淆了句柄表的 `Object` 字段"，还写进了文档。**真相是自己的读法错了。**

**判据**：先用 `size=4` 读 ntoskrnl 基址的 `MZ`，确认 kread 通，再谈别的。

**读任意长度必须循环**（按 4 字节对齐再切片），实测 **4ms / 64 字节**。

### 3.2 读"看起来像内核地址"的垃圾值 → 蓝屏

曾写「dump entry，逐 qword 检查 `Type==4`」的逻辑，对 entry 里**每个负数**都去读 ——
`0xFFFFFFFF002A0028` 这种垃圾值指向未映射页 → **BSOD 0x50 (PAGE_FAULT_IN_NONPAGED_AREA)**，
VM 崩了两次。

**教训**：
- 地址预检：**负数 + 高 16 位全 F**（`$v -lt 0 -and ((($v -shr 48) -band 0xFFFF) -eq 0xFFFF)`）
- **不要"逐 qword 扫"**，只读**已知偏移**
- 有风险的读**只做一次**，不要放在循环里

### 3.3 `sc stop` 后立即 `sc delete` → 服务卡在"标记删除"

下次 `sc create` 失败，表现成"驱动没加载"，但错误被 `$null =` 吞掉看不见。

**修法**：服务名加随机后缀，或 `stop` 后 `Start-Sleep` 再 `delete`。

### 3.4 ★ 僵尸驱动占设备名

反复加载同一驱动，`sc delete` 后 `\Device\<name>` 符号链接**可能还在**
（`DriverObject` 引用计数没归零，通常是测试脚本异常退出时泄漏了 `CreateFile` 的 handle）。

**症状**：`driverName` 显示的是**上一次**的服务名（而不是这次创建的）；
`MajorFunction: 28 项中 0 个落在驱动内`。

**修法**：
- **`CloseHandle` 必须放 `finally`**（异常也要关）
- 每次测试用**唯一的服务名**
- 状态可疑时**回滚快照**（比反复 `sc stop/delete` 可靠）

### 3.5 自定义驱动加载的口径

**不做签名或状态的前置校验** —— 交给操作系统判定：
- test-signing 未开 ⇒ 未签名驱动被拒（`577 Windows cannot verify the digital signature`）
- test-signing 已开 ⇒ 正常加载

`applied=true` 只代表**动作已执行**，**是否真的加载成功以系统返回为准**。

**保留的约束（都与签名无关，只为「不出事 / 能回滚」）**：
1. 启动类型默认 `demand`；`system`/`boot` 必须显式 override
2. 同名服务已存在 ⇒ 默认拒绝覆盖（先备份注册表键与画像）
3. 卸载**只删服务项、不删 `.sys` 文件**，并生成 `revert.cmd`
4. Secure Boot 开启时**拒绝开启 test-signing**（协议不允许）

---

## §4 VM 沙箱（vmrun / guest）

### 4.1 中文用户名在 vmrun 命令行里乱码

`C:\Users\时\lct` 传到 guest 变成 `C:\Users\鏃禱lct`。**guest 侧所有路径必须 ASCII**（用 `C:\lct\`）。

### 4.2 `runProgramInGuest -File <脚本>` 静默不执行

必须用 `-Command "& '<path>'"`。

### 4.3 空密码不行

`vmrun` 拒绝空密码（VIX API 硬限制）：`Error: The guest OS does not support empty passwords`。

### 4.4 Defender 拦截驱动加载（`sc start` 返回 225）

`225 = ERROR_VIRUS_INFECTED`。修法：`Add-MpPreference -ExclusionPath 'C:\lct'`，
**然后重新 push 驱动文件**（被拦的那个已被隔离/删除，光加排除不够）。

### 4.5 guest 侧脚本过旧 ⇒ 所有变异结果一模一样

主机改了 `guest-probe.ps1` 但 guest 还是旧版，旧版静默忽略新参数（`LCT_INHEX`）。

**修法**：`vm.matrix` / `vm.batch` 每次跑前都自动重新 push 一遍 probe 脚本。

### 4.6 `revertToSnapshot` 会关机再恢复，但**不会自动启动**

回滚后症状：`vmrun list` 显示 0 台在跑、`checkToolsState` 返回 **`installed`**、
后续所有 guest 操作报 `The virtual machine is not powered on`。

**修法**：回滚后**主动 `vmrun start <vmx> nogui`**，再等 tools（给足 3 分钟）。

### 4.7 BSOD 之后 `checkToolsState` 可能短暂仍报 `running`

据此判断"只是挂起"并继续探测 → 连撞两次，把 VM 打进恢复界面。

**修法**：超时后**多等 6 秒**复查 + 用 `vmrun list` 确认 VM 是否真的消失。

### 4.8 `Start-Process` 传中文路径会被 mangle

子进程读不到 VM 配置（报"未配置 guest 用户或密码"），而直接调用同一个函数报 `ready=True`。
**修法**：用 harness 自己的后台 job，或全程走 `Invoke-LctVmRun`。

---

## §5 kread 读内核对象

### 5.1 完整链路（实测通过）

```
CreateFile("\\.\RTCore64")                              → handle
NtQuerySystemInformation(SystemExtendedHandleInformation) → 句柄记录
    .Object = FILE_OBJECT
FILE_OBJECT   + 0x08 = DEVICE_OBJECT
DEVICE_OBJECT + 0x08 = DRIVER_OBJECT
DRIVER_OBJECT + 0x18 = DriverStart      (== DllBase)
DRIVER_OBJECT + 0x20 = DriverSize
DRIVER_OBJECT + 0x38 = DriverName       (UNICODE_STRING)
DRIVER_OBJECT + 0x70 = MajorFunction[0..27]
DRIVER_OBJECT + 0xE0 = MajorFunction[14]  ← IRP_MJ_DEVICE_CONTROL
```

**`KLDR_DATA_TABLE_ENTRY` 实测偏移**（Win10 19045 x64）：

```
+0x00 InLoadOrderLinks    +0x30 DllBase       ← 已验证
+0x18 ExceptionTableSize  +0x40 SizeOfImage   ← 已验证
+0x58 BaseDllName         ← 已验证
+0x70 Spare               ← 不是 DRIVER_OBJECT（见 5.3）
```

**自校验（四条，全过才认）**：

| 检查 | 期望 |
|---|---|
| `DRIVER_OBJECT.Type` (+0x00) | `== 4` |
| `DriverStart` | `== KLDR_DATA_TABLE_ENTRY.DllBase` |
| `DriverStart` 处 | 有 `MZ` |
| `MajorFunction[14] - DriverStart` | 落在 `0..DriverSize` |

### 5.2 `_DEVICE_OBJECT` 里没有 `DeviceName` 字段

`DEVICE_OBJECT + 0x30` 读到的不是名字。设备名走 `DRIVER_OBJECT.DriverName`(+0x38)，
或解析 `OBJECT_HEADER` 的 NameInfo。

### 5.3 两条**走不通**的路（别再试）

**路径 A（句柄表 → 一切）**：Win10 19045 上 `SystemExtendedHandleInformation.Object`
**其实是有效的**（实测 `0xFFFFAD0884B70320`，`ObjectTypeIndex=0x24`）。
**之前判断"被混淆"是错的** —— 是 §3.1 的读法错。

**路径 B（`KLDR_DATA_TABLE_ENTRY + 0x70`）**：`Spare` 指向
`{+0x30=0x6000, +0x40="PEAU"}` 的内部结构，**不是 `DRIVER_OBJECT`**。

### 5.4 `PsLoadedModuleList` 的地址要解析导出表

解析 ntoskrnl 的 PE 导出表（**二分查找**，导出名按字节序排列）：
**3ms / 191 次 kread**。然后用 `EnumDeviceDrivers` 按名字找 ntoskrnl 基址
（**不要用 `SystemModuleInformation(11).ImageBase`** —— 那个地址读出来全 0）。

---

## §6 静态反汇编（rizin）

### 6.1 ★ `pd` 遇跳转就停；`pD` 才是按字节

```bash
rizin -q -c 'pd 40 @ 0x11450' x.sys    # 40 条指令，但遇到 jne 就停 → 只出 13 条
rizin -q -c 'pD 400 @ 0x11450' x.sys   # 400 字节 → 出 106 条，能看到完整 add/cmp/跳转表
```

**IOCTL 分派函数开头就有一个 `jne`**（`cmp byte [rax], 0xe; jne ...`），
所以用 `pd` 永远看不到后面的 `add eax, imm32` / `cmp eax, imm` ——
会误判成"没有 IOCTL 分派"。

### 6.2 必须关两个开关

```bash
-e asm.lines=false   # 否则行首是 ┌─< │ 图形字符，正则全废
-e scr.color=0       # 否则行里混 ESC[32m，肉眼看不见但正则匹配不到
```

### 6.3 `@ 11450` 会被当十进制

`@ 11450` = `0x2CBA`，反汇编出来全是 `invalid`。必须 `@ 0x11450`。

### 6.4 跳转表是**两级**的，不是教科书式一级

```
movzx  rax, byte [r8 + rax]        ← ① 字节表：每项是 case 组号（不是偏移！）
movsxd rax, dword [r8 + rax*4]     ← ② 偏移表：每组一个 4 字节偏移
add    rax, r8                     ← ③ target = caseBase + offset
jmp    rax
```

**只看到 `movsxd ... jmp rax` 就当成一级表会算错**。

**实测（rtcore64）**：

| 表 | RVA | 内容 |
|---|---|---|
| 字节表 | `0x1A20` | 85 项，值域 0..18（18 = 默认分支） |
| 偏移表 | `0x19D4` | 19 项 dword |
| case 基址 | `0x14B6` | |

**映射结果**：18 个有效码 → 18 个分支；67 个无效码 → 默认分支 `0x19B6`。

---

## §7 动态验证（matrix / payload）

### 7.1 ★ `presets` 为空 ⇒ 驱动全程空转

`presets={}` → 所有字段 0 → `readSize=0` → **驱动什么都不读，直接返回成功**。
于是矩阵里一堆 `ok-data` 看起来"无害"，其实根本没干活。**结论全是假的。**

**实测对照**：

| 用例 | readSize | 结果 |
|---|---|---|
| `addr=1` | **0** | `ok-data, ret=48, 非MZ` ← 空转 |
| `addr=1` | 4 | **挂起（timeout）** |
| `addr=1` | 1 | **挂起（timeout）** |

**判据**："这段代码真的在干活吗？" —— 没有明确的"非空输出/真实副作用"证据，
就不要把它当结论。`fromprobe` 会扫 `1/4/8/16` 找"能让返回数据非全 0"的值当 preset。

**根因**（本轮）：presets 是 `OrderedDictionary`，遍历方式错了 → 见 §2.6。

### 7.2 扰动幅度决定生死

- 用 `0xFF` 改 `offset` 字段 → 驱动按 4GB 偏移访问 → **直接 BSOD**（真发生过）
- 用 **`+1` 温和扰动** → 同样的字段能被识别，**且不崩**

默认温和；`-Aggressive` 才用极值（能探出"无边界检查"，但会崩）。

### 7.3 码表模式下 `addr=0` 会让每个码都返回 87

RTCore64 对地址做了 NULL 检查。而 profile 的 `presets` 通常只有 `readSize`/`offset`，
**没有 `addr`**（地址是运行时才知道的）。

**所以码表模式必须自动给"地址类字段"填 `@ntoskrnl`**：

```
字段名匹配 (?i)^(addr|address|base|ptr|pointer|target)$ 且 presets 里没有 → 填 '@ntoskrnl'
```

**实测**：填之前 3 个码全 87；填之后 `0x80002048`(kread) 立刻 `ok-data, ret=48`。

### 7.4 同一个 payload 不能用于所有码

`0x80002000` 是**有效码**（有独立分支），但用 kread 的 payload 发出去是 `error 87`。

**这不是 bug** —— 它说明不同分支需要不同参数。要做完整码表验证，
需要**每个分支自己的 payload**（下一步方向）。

### 7.5 `87` 的不可区分性只能缓解，不能消除

`ERROR_INVALID_PARAMETER` 可能是"不认这个码"，也可能是"认了但参数不对"。

**缓解**：发两个不同 payload（全 `0x00` / 全 `0x01`），如果响应不同 ⇒ 码在处理参数。
**根治**：静态跳转表（§6.4）—— 表就是答案，"不可区分"根本不存在。

---

## §8 测试与门禁

### 8.1 ★ 测试的"环境假设"要跟着功能走

`DriverAccuracyTest` 原本假设：**只要存在动态记录，triage 就必须升到 `confirmed`**。

但跑过码表模式后，动态记录的 `worst` 可能是 **`error`**（码有效、但 payload 不是它要的参数）——
**这是合法结论**，不构成高危证据。

**修法**：按 `worst` 分档 —— 只有 `crash`/`timeout` 才要求 `confirmed` + `finalRisk >= 0.99`。

**教训**：表现成"加个新功能后某个不相关的门突然红了"时，**先查测试里的环境假设**。

### 8.2 门禁的 flake 要区分

`CtlSimplifyTest` 曾在 10 分钟的整体跑里偶发失败（exit=9），但单跑和顺序跑都过。
**判据**：单跑 + 顺序跑 + 整体跑三种都复现才算真 bug。

### 8.3 测试会污染运行数据

`vm.matrix` 落盘的动态记录（`var\vm\driver-dynamic\<sha>.json`）会影响
`DriverAccuracyTest` 的判定。测试前后要意识到这个耦合。

---

## §9 方法论级教训

### 9.1 ★★ 别把自己的 bug 归因成系统行为

我最初读 `FILE_OBJECT + 0x08`（8 字节）得到全 0，**直接断定**
「19045 混淆了句柄表的 `Object` 字段」，还写进了本文档。**这个结论是错的。**

真相：`Object` 一直是有效地址，**是我用 8 字节读、而驱动只支持 1/2/4，导致空转**。

**验证顺序（照这个顺序查，别跳步）**：

```
1. 读一个【已知有内容】的地址（ntoskrnl 基址的 MZ）→ kread 本身通吗？
2. 打印接口返回的【其他字段】（ObjectTypeIndex / GrantedAccess / Pid）→ 记录本身对吗？
3. 用【多种读法】（不同 size）交叉验证 → 是"读不到"还是"读不对"？
4. 最后才怀疑系统做了手脚。
```

**这次如果先做第 2 步（打印全部字段），一眼就能看到 `Object` 非 0**，
根本不会产生那个错误结论。

### 9.2 数据对、判断错，最难查

`$内核地址 -gt 0`（§2.10）、`0xFFFFFFFF` 当上界（§2.3）都属于这一类：
**读出来的值完全正确，但判断条件写错了**，于是结论荒谬。

**判据**：当"底层数据看着对、但上层结论不对"时，**优先查判断条件而不是数据源**。

### 9.3 静默失败比崩溃难查一个数量级

本项目的坑大部分是**不报错**的：
- `runProgramInGuest -File` 静默不执行（§4.2）
- `sc delete` 卡住、错误被 `$null =` 吞掉（§3.3）
- `presets` 丢、驱动空转、看起来"成功"（§7.1）
- `pd` 遇跳转停、少反汇编了 90%（§6.1）

**纪律**：**不要用 `$null =` 吞掉可能是错误的输出**。要么打印，要么在异常时打印。

### 9.4 「先猜后验」不如「先锚定再精读」

这是四步闭环的来源（见 `docs/WORKFLOW.md`）。

旧路径每一层都在猜，误差层层累积；新路径第一步就拿到**确定的东西**，后面每一步都在缩减范围。

**推论**：**静态分析不是"扫描器"，是"单点精读器"** ——
一旦知道该读哪里，"覆盖率 5.6%"这个问题就不存在了。
