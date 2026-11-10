# 两条能力路线与前置条件（冲突处理）

> 一句话：**提权路线从普通用户起步，加载驱动路线起点就要管理员** —— 所以顺序只能是「先提权，再加载驱动」。
> 工具默认以普通权限运行，未提权时任何驱动写操作都会被拦住，并告诉你下一步该做什么。

## 两条路线

| | 路线 B：提权 | 路线 A：加载驱动 |
|---|---|---|
| 形态 | 把**漏洞组件当插件**用（`plugins\cve-2026-49176`） | `driver.load` 注册并启动内核驱动 |
| 起点 | 普通用户 | **管理员 / SYSTEM** |
| 终点 | 管理员 / SYSTEM | 内核能力（任意读写 / 执行） |
| 需要先提权吗 | 不需要（它本身就是提权） | **需要** |
| 工具里怎么触发 | 插件调用（预览 → 明确 `-Apply`） | 驱动页 / 通用控制台，预览 → 二次确认 → `-Apply` |

```
普通用户 ──(路线B：提权插件)──> 管理员/SYSTEM ──(路线A：driver.load)──> 内核原语
          ↑ 起点低                       ↑ 这里才允许写驱动
```

## 冲突在哪

- 工具本身**不包含**提权或内核能力，它只是把外部组件编排起来。
- 但 `sc create` / `sc start` / `bcdedit /set` 这些动作**必须**管理员权限才能做。
- 于是：普通权限下点「加载驱动」必然失败。旧实现只回一句「需要管理员权限」，用户不清楚是工具坏了还是缺了什么步骤 —— **这就是要修的冲突**。

## 工具怎么处理（已实现）

### 1) 新只读能力：`capability.status`

```
engine.cmd capability.status
→ data = {
    user, isAdmin, integrityLevel(Low|Medium|High|System), integritySid, integrityRid,
    canLoadDriver,                       // = isAdmin（决定驱动写操作能不能做）
    routes: [ {id:'elevate', requiresElevation:false, from:'普通用户',   to:'管理员/SYSTEM'},
              {id:'driver',  requiresElevation:true,  from:'管理员',     to:'内核能力'} ],
    prerequisite: { order:['elevate','driver'], ok, message, hint },
    capabilityMatrix: [ 每个能力是否需要提权、当前是否可用、原因 ],
    testsigning, secureBoot
  }
```

### 2) 统一闸门与提示（写操作被拦住时）

`core\Capabilities.psm1` 提供**纯函数** `Test-LctCapabilityDriverLoad -IsAdmin <bool>`；
`core\Drivers.psm1` 的三个写操作入口（`driver.load` / `driver.start` / `driver.unload`）都用它生成同一条提示：

> 需要管理员/SYSTEM 权限才能注册 / 启动内核驱动服务：当前进程是 Medium（未提权）；本次未做任何改动。
> 本工具默认以普通权限运行，无法注册/启动内核驱动 —— 请**先**用「提权」路线（把漏洞组件当插件加载，例如
> `plugins\cve-2026-49176`）把自己提升到管理员/SYSTEM，**再**回到本工具执行该操作；**顺序不能反**。

### 3) 界面（Java UI，页面「驱动加载」）

- 顶部**权限横幅**：绿色「管理员（High）· 可以加载驱动」/ 红色「普通用户（Medium）· 不能加载驱动 —— 请先提权」。
- 新增「加载驱动」表单（路径 / 服务名 / startType / ① 预览 / ② 应用+二次确认）。
- 应用失败且错误里含「提权」时，弹窗直接给出**顺序提示**，而不是让用户去猜。

## 验证

`tests\CapabilityTest.ps1`（21 断言，已登记进 `Run-AllGates`）：

- CT-1..3：`capability.status` 字段齐全、完整性级别与 `isAdmin` 自洽（S-1-16 的十进制映射）、两条路线与前置条件正确
- CT-4/5：纯函数闸门的**两个分支**（未提权 ⇒ 拦住 + `need-elevation` + 提示含「提权」「先」；已提权 ⇒ 放行）
- CT-6：`driver.load` 用的统一文案含动作顺序
- CT-7：只读，没有创建任何服务
- CT-8：verb 表登记且 `mutating=false`

## 实测结论（2026-10-29，真非管理员上下文）

用 `tools\RunAsStandardUser.ps1`（explorer 降权技巧，见该文件头注释）以 **Medium 完整性**跑引擎，实测：

| 项 | 结果 |
|---|---|
| 上下文 | `isAdmin=False`、`integrityLevel=Medium`（SID 十进制 8192） |
| `capability.status` | `canLoadDriver=False`、`prerequisite.ok=False`，提示含「请**先**提权…**再**加载…顺序不能反」 |
| `driver.load -Apply` | `ok=False`、`applied=False`、`elevated=False`；服务键 **未被创建**（零副作用） |
| 提权路线（`plugins.run -Apply`） | `exitCode=0`；PoC `payload\result.txt` 出现 `event=SYSTEM_SHELL_STARTED … user=SYSTEM` |
| 副作用 | PoC 会留下 **SYSTEM 身份 cmd.exe**（`cmd /K "title … & whoami"`），验证后必须手动终止；文档注册表已自动还原为原值（ExpandString） |

**结论：提权路线在普通权限下确实成立，因此「先提权、再加载驱动」这条顺序不是空话。**

走不通的方案（别再试）：`runas /trustlevel:0x20000`（受限令牌里 PowerShell 起不来）、
`TokenLinkedToken + DuplicateTokenEx + CreateProcessWithTokenW`（本机 1346/5）。
