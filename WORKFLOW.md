# 四步闭环：驱动分析方法论

> 这是本项目第二代的技术骨架。**读这一篇就够理解"为什么这么设计"**。
>
> 一句话：**不用猜，也不用盲试** —— 动态给静态一个精确起点，静态给出确定答案，再拿回去验证。

---

## 0. 为什么需要这套东西

### 旧路径的问题：每一层都在猜

```
① driver.profile.draft（静态）
   扫 PE 里的字符串/xref → 猜 6 个 IOCTL 候选，confidence 0.63
   ↓ 猜的

② driver.vm.discover（动态）
   暴力发 64 个 IOCTL 码 → 13 分钟 → accepted=2，58 个 87 不可区分
   ↓ 盲试的

③ rizin 全量 .text（静态）
   不知道从哪开始 → 只能全扫 → 5.6% 覆盖，100KB 要 90 秒（超时）
   ↓ 慢且不全的

④ driver.vm.matrix（动态）
   验证 ② 猜出来的码
   ↓ 验证的是"不确定的东西"
```

**误差层层累积**。最要命的是 ② 的 `87`（`ERROR_INVALID_PARAMETER`）：
驱动返回 87 可能是"不认这个码"，也可能是"认了但参数不对" —— **从外部无法区分**。

### 新路径：动态不是为了验证静态，是为了给静态一个起点

```
① 动态锚定    → 精确的 RVA（不是猜的）
② 静态精读    → 只反汇编那一个函数（不需要覆盖率）
③ 表枚举      → 表就是答案（不需要扫）
④ 反哺动态    → 验证确定的东西
```

**静态分析的角色变了**：从"全量扫描器"变成"单点精读器"。
**于是"覆盖率 5.6%"这个问题消失了** —— 因为只需要那一个函数。

---

## 1. ① 动态锚定：`driver.vm.anchor`

### 目标

拿到 `IRP_MJ_DEVICE_CONTROL` 分派函数的**精确地址**，以及这个驱动**支持哪些 IRP**。

### 原理

借一个已知可控的漏洞驱动（RTCore64）的 kread 原语，沿对象图走：

```
CreateFile("\\.\RTCore64")                              → handle
NtQuerySystemInformation(SystemExtendedHandleInformation) → 句柄记录
    .Object = FILE_OBJECT                               → FILE_OBJECT 的内核地址
FILE_OBJECT   + 0x08 = DEVICE_OBJECT
DEVICE_OBJECT + 0x08 = DRIVER_OBJECT
DRIVER_OBJECT + 0x18 = DriverStart      （== PE 的 ImageBase 重定位后）
DRIVER_OBJECT + 0x20 = DriverSize
DRIVER_OBJECT + 0x38 = DriverName       （UNICODE_STRING，\Driver\xxx）
DRIVER_OBJECT + 0x70 = MajorFunction[0..27]
DRIVER_OBJECT + 0xE0 = MajorFunction[14]  ← IRP_MJ_DEVICE_CONTROL
```

### 自校验（三条全过才认）

| 检查 | 期望 | 为什么 |
|---|---|---|
| `DRIVER_OBJECT.Type` (+0x00) | `== 4` | 结构偏移对不对 |
| `DriverStart` | `== KLDR_DATA_TABLE_ENTRY.DllBase`（交叉核对） | 拿到的是不是真基址 |
| `DriverStart` 处 | 有 `MZ` | 是不是真的 PE 映像 |
| `MajorFunction[14] - DriverStart` | 落在 `0..DriverSize` | 是不是真分派函数 |

**任一失败 → `ok=false`，不给结论。**

### 实测

```
driver.vm.anchor -Apply（rtcore64）
  9 秒（guest 内 4.4s，79 次 kread）
  driverName = \Driver\lctanchorE2E
  DriverStart = 0xFFFFF80A2EE70000  DriverSize = 0x6000
  ioctlDispatchRva = 0x1450

  MajorFunction（在驱动内的）:
    [0]  IRP_MJ_CREATE          RVA=0x1450
    [2]  IRP_MJ_CLOSE           RVA=0x1450
    [14] IRP_MJ_DEVICE_CONTROL  RVA=0x1450
```

**顺带拿到"能力面"**：`CREATE/CLOSE/DEVICE_CONTROL=true`，`READ/WRITE=false` ——
**在发第一个 IOCTL 之前就知道这个设备支不支持 IOCTL**，省掉一整轮无效测试。

### 两个致命坑

**① kread 单次只支持 1/2/4 字节**

```
size=1 → 4D           ✓      size=4 → 4D 5A 90 00  ✓
size=2 → 4D 5A        ✓      size=3/5/8/16/32/64 → 全 0  ✗
```

`DeviceIoControl` 返回 `True`、`bytesReturned=48`，**但驱动根本没读**。

**这个坑害过一次误判**：读 `FILE_OBJECT+0x08`（8 字节）得到全 0，于是断定
"Win10 19045 混淆了句柄表的 Object 字段"，还写进了文档。**真相是自己的读法错了。**

**判据**：先用 `size=4` 读 ntoskrnl 基址的 `MZ`，确认 kread 通，再谈别的。

**② 读"看起来像内核地址"的垃圾值 → 蓝屏**

曾写「dump entry，逐 qword 检查 Type==4」的逻辑，对每个负数都去读 ——
`0xFFFFFFFF002A0028` 这种垃圾值指向未映射页 → **BSOD 0x50**，VM 崩了两次。

**教训**：地址预检（负数 + 高 16 位全 F）、只读已知偏移、有风险的读只做一次。

---

## 2. ② 静态精读：`driver.desasm.function`

### 目标

给一个 RVA，**只反汇编那一个函数**（默认 512 字节），自动提取结论。

### 原理

**先手工解析 PE 拿映射**（不依赖 rizin）：

```
PE: ImageBase = 0x10000, .text VA = 0x1000
RVA 0x1450 → 文件偏移 0x850
```

**再用 rizin 反汇编那一段**（地址 = `ImageBase + RVA`）：

```bash
rizin -q -e asm.lines=false -e scr.color=0 \
      -c 'pD 512 @ 0x11450' x.sys
```

**然后从指令模式里读结论**：

```
mov  eax, [rax+0x18]        ← 读 IOCTL 码
add  eax, 0x7FFFE000        ← IOCTL 基址 = 0x100000000 - imm = 0x80002000
cmp  eax, 0x54              ← 表大小 = imm + 1 = 85
ja   ...
lea  r8, [0x11a20]          ← ① 字节表地址
movzx rax, byte [r8+rax]    ← 查 case 组
lea  r8, [0x119d4]          ← ② 偏移表地址
movsxd rax, dword [r8+rax*4]← 查 4 字节偏移
lea  r8, [0x114b6]          ← ③ case 基址
add  rax, r8
jmp  rax
```

**额外收获**：`cmp byte [rax], 0xe` → IRP 类型检查（`0x0E = IRP_MJ_DEVICE_CONTROL`）。

### 实测

```
driver.desasm.function -Rva 0x1450 -Bytes 400
  247ms（引擎内）  反汇编 106 条
  ioctlBase       0x80002000
  tableSize       85
  ioctlRange      0x80002000..0x80002054
  jumpTableKind   two-level
  irpTypeCheck    0xE = IRP_MJ_DEVICE_CONTROL
  leaTargets      0x11a20（字节表）, 0x119d4（偏移表）, 0x114b6（case 基址）
```

### 三个 rizin 坑

**① `pd` 遇跳转就停，`pD` 才是按字节**

```bash
pd 40 @ 0x11450   → 只出 13 条（遇到 jne 就断）
pD 400 @ 0x11450  → 出 106 条，能看到完整的 add/cmp/跳转表
```

**IOCTL 分派函数开头就有一个 `jne`**，所以用 `pd` 永远看不到后面的关键指令 ——
会误判成"没有 IOCTL 分派"。

**② 必须关两个开关**

```bash
-e asm.lines=false   # 否则行首是 ┌─< │ 图形字符，正则全废
-e scr.color=0       # 否则行里混 ESC[32m，肉眼看不见但正则匹配不到
```

**③ `@ 11450` 会被当十进制**

`@ 11450` = `0x2CBA`，反汇编出来全是 `invalid`。必须 `@ 0x11450`。

---

## 3. ③ 表枚举：`driver.desasm.dispatchmap`

### 目标

把 ② 找到的表读出来，**直接算出"哪个码进哪个分支"**。这一步不需要再反汇编。

### 原理：是**两级**表，不是一级

```
字节表[85]     每个码 -> case 组号        （movzx，每项 1 字节）
偏移表[group]  组号   -> 相对 case 基址的偏移（movsxd，每项 4 字节）
target = caseBase + offset[group]
```

**只看到 `movsxd ... jmp rax` 就以为是"一级跳转表"会算错** ——
`byte[rax]` 是**组号**，必须先过字节表。

### 实测

```
表            RVA      内容
字节表        0x1A20   85 项，值域 0..18（18 = 默认分支）
偏移表        0x19D4   19 项 dword
case 基址     0x14B6

driver.desasm.dispatchmap -Rva 0x1450
  392ms
  18 个有效分支 / 18 个有效码 / 67 个无效码 → 默认分支 0x19B6

  0x80002048 (kread)  → 0x14B6   ← 和手写 profile 完全一致
  0x8000204C (kwrite) → 0x1526   ← 同上
  0x80002000 → 0x1607    0x80002004 → 0x1633
  ...（另 14 个码各有独立分支）
```

**交叉验证**：已知的 kread/kwrite 码落在正确分支 → 逻辑正确。

### 这一步的真正意义

**它替代了 `driver.vm.discover`**：

| | `vm.discover` | `dispatchmap` |
|---|---|---|
| 耗时 | **13 分钟** | **392ms** |
| 找到的码 | 2 个 | **18 个** |
| 每个码去哪 | 不知道 | **精确 RVA** |
| `87` 不可区分 | 58 个 | **不存在** |

---

## 4. ④ 反哺动态：`driver.vm.matrix -Codes`

### 目标

用 ③ 的精确码列表跑矩阵，**每个码一条任务**。不再盲扫。

### 用法

```bat
echo {"profile":"my-profile","action":"kread","codes":"0x80002000,0x80002048"} > c.json
engine.cmd -Verb driver.vm.matrix -ArgsFile c.json -Apply
```

### 实测

```
3 个码，13 秒
  code-0x80002048  verdict=ok-data  ret=48    ← kread 读到内核地址
  code-0x80002000  verdict=error   err=87     ← 这个码有效，但需要不同的参数
  code-0x80002001  verdict=error   err=87     ← 无效码，符合预期
```

**`0x80002048` 用 kread 的 payload 拿到 `ok-data`** → 证明"精确码 + 正确 payload"这条链通了。

### 三个坑

**① `presets` 从 profile 读出来是 `OrderedDictionary`**

```powershell
# ✗ 遍历 PSObject.Properties 拿到的是字典自己的属性
foreach ($p in $raw.PSObject.Properties) { ... }
#   → Count/IsReadOnly/Keys/Values/IsFixedSize/SyncRoot/IsSynchronized
#   → readSize/offset 一个都没拿到 → payload 全 0

# ✓
if ($raw -is [System.Collections.IDictionary]) {
    foreach ($k in $raw.Keys) { $vals[[string]$k] = $raw[$k] }
}
```

**后果链**：`presets` 丢 → `readSize=0` → **驱动空转** → 每个码看起来都"成功" → **结论全假**。

**判据**：payload 编码出来后，**先看 `readSize` 字段的字节是不是非 0**
（RTCore64 在 offset 24）。如果全 0，先怀疑 presets 没进来。

**② 码表模式下 `addr=0` 会让每个码都返回 87**

RTCore64 对地址做了 NULL 检查。而 profile 的 `presets` 通常只有 `readSize`/`offset`，
**没有 `addr`**（地址是运行时才知道的）。

**所以码表模式必须自动给"地址类字段"填 `@ntoskrnl`**：

```
字段名匹配 (?i)^(addr|address|base|ptr|pointer|target)$ 且 presets 里没有 → 填 '@ntoskrnl'
```

**③ 同一个 payload 不能用于所有码**

`0x80002000` 是**有效码**（有独立分支），但用 kread 的 payload 发出去是 `error 87`。

**这不是 bug** —— 它说明不同分支需要不同参数。要做完整的码表验证，
需要**每个分支自己的 payload**（这是下一步的方向）。

---

## 5. 什么时候走兜底

四步闭环依赖两个前提：

1. **有一个能用的 kread 原语**（一个已知漏洞驱动的 profile）
2. **驱动有 `DEVICE_OBJECT`**（能 `CreateFile` 打开）

**任一不满足** → 退回 `driver.vm.discover`（暴力扫，14 分钟）。

| 场景 | 走哪条 |
|---|---|
| 有 RTCore64 之类的 kread 驱动 | **四步闭环**（~1 分钟） |
| 目标驱动不创建设备（minifilter / 纯回调） | 无 IOCTL 接口，本来也不是目标 |
| 目标驱动打不开设备 | `vm.discover` + 其他入口 |
| 只是想粗筛一批文件 | `driver.batch.scan`（纯静态） |

---

## 6. 已知局限（必须随文档携带）

| 局限 | 说明 |
|---|---|
| **依赖 kread 原语** | 没有已知可控的漏洞驱动 → 整个闭环不可用 |
| **只覆盖有设备的传统 WDM 驱动** | minifilter / WFP callout / 纯回调驱动没有 `DEVICE_OBJECT` |
| **结构偏移版本相关** | `DRIVER_OBJECT`/`DEVICE_OBJECT` 各版本不同，靠三项自校验兜住 |
| **kread 带宽 4 字节/次** | 读 100KB 约 6.4 秒（但只需要读几百字节） |
| **码表验证需要每分支 payload** | 现在只有 kread 的 payload，其余码会 87 |
| **x86 / ARM64 未验证** | 偏移都是 x64 的 |
| **读错地址会崩** | 所以只在 VM 里做；地址预检是硬要求 |

---

## 7. 附：完整实测时间线（rtcore64 / Win10 19045）

```
① anchor            9.0s    → ioctlDispatchRva 0x1450
② desasm.function   0.25s   → 基址 0x80002000 / 表 85 / 两级表
③ dispatchmap       0.39s   → 18 个码 + 18 个分支
   ─────────────────────────
   小计             9.6s

④ matrix（3 码）    13s     → 1 个 ok-data，2 个 87
④ matrix（18 码）   约 60s  → （未跑，线性估算）
```

**对比**：`vm.discover` 13 分钟 → 2 个 accepted；rizin 全量 90 秒 → 5.6% 覆盖。
