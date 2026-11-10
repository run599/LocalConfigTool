# core\driver-profiles\ —— 内置驱动 profile 目录

本目录放**随工具分发**的驱动 profile（`*.json`，纯数据）。它允许为空。

## 为什么需要 profile

驱动控制接口**不自描述**：`.sys` 里没有 IOCTL 元数据，设备名也没有标准。所以"通用加载器"只有两条路：

1. **自研驱动遵守我们发布的 ABI**（那么 ABI 就是文档，profile 只是把它写成数据）；
2. **每个第三方/漏洞驱动一份 profile**，描述"怎么调用它"。

通用的是**格式 + 执行引擎**，不是驱动本身。任何声称"任意驱动拿来就能执行任意命令"的说法都在骗人。

## 本版不预置任何真实驱动的 profile

**这是刻意的**：一个未经人工确认 IOCTL 语义与输入结构的 profile，`-Apply` 一下就可能立刻蓝屏。
所以内置目录留空，请用 `driver.profile.draft` 生成草案、人工审定后再收藏：

```
driver.profile.draft  -Path <某.sys>          # 静态、只读：PE 解析 → 设备名候选 → IOCTL 候选 → confidence
driver.profile.save   -Id <id> -Json <草案>   # 默认只预览；-Apply 写 user 来源：var\driver-profiles\<id>.json
driver.profile.validate -Id <id> -Path <.sys> # schema + target.sha256 指纹门 + 内存沙盒（不碰内核）
driver.devices        -Name <service>         # 注册表解 .sys 路径 + 候选入口 CreateFile 可用性（不发 IOCTL）
driver.ctl.send       -Profile <id> -Action <a> -Payload <json>   # 默认只预览（打印 IOCTL + 缓冲区十六进制）
driver.ctl.send       ... -Apply              # 真发 DeviceIoControl
```

三个来源（`driver.profile.list -Source builtin|user|plugin`）：

| 来源 | 目录 | 谁写 |
|---|---|---|
| `builtin` | `core\driver-profiles\*.json`（本目录） | 随工具分发，`driver.profile.save` **不会**写这里 |
| `user` | `var\driver-profiles\*.json` | `driver.profile.save`（写入 UTF-8 **无 BOM** JSON） |
| `plugin` | `plugins\<id>\driver-profiles\*.json` | 插件自带 |

读取侧对 BOM 容错（`TrimStart([char]0xFEFF)` 之后再 `ConvertFrom-Json`）。

## profile 形状（契约 docs\CONTRACT.md §13.4）

```jsonc
{
  "id": "rtcore64-1.3.1",
  "kind": "driver-profile",
  "engineApi": 2,
  "target": { "sha256": "<.sys 的 SHA-256，必填>", "sha256AnyOf": ["<可选：多个受支持版本>"], "fileName": "RTCore64.sys" },
  "locate": { "strategy": "symlink|interfaceGuid|serviceImagePath", "candidates": ["\\??\\RTCore64"], "interfaceGuid": "{...}", "serviceNameHint": "RTCore64" },
  "handshake": { "action": "ping", "expect": { "ioctl": "0x80002000", "minOutBytes": 4 } },
  "actions": {
    "kread":  { "ioctl": "0x80002048", "kind": "read",  "in": [{"name":"addr","type":"u64"}], "out": [{"name":"value","type":"bytes","len":8}] },
    "kwrite": { "ioctl": "0x8000204C", "kind": "write", "readBack": "kread",
                "in": [{"name":"addr","type":"u64"},{"name":"value","type":"bytes","len":8}] }
  },
  "layout": { "method": "buffered|neither|inout", "align": 8, "endian": "little" },
  "risk": { "level": "low|medium|bsod", "notes": "写坏地址立刻蓝屏；写前必须记录原值" },
  "requires": { "restart": false, "admin": true, "elevation": "admin|system" }
}
```

* **纯数据**：不含任何可执行代码。schema 会拒绝 `$(`、反引号、`Invoke-*`、`Add-Type` 等片段，引擎**永不 eval** profile 内容。
* **类型（首版）**：`u8/u16/u32/u64/i32/i64/bytes(len|lenFrom|lenOf)/cstr(可带 len 容量)/guid/handle`。
  * `len`：定长；`lenFrom`：长度 = **前一个字段的值**（长度前缀）；`lenOf`：长度 = 前一个字段的**字节大小**。
  * **小端**打包；每个字段按 `min(字段大小, layout.align)` 对齐（`align` 必须是 2 的幂，≤ 64）。
    （`guid` 用 Windows 内存布局：Data1/2/3 小端、Data4 原序。）
* **动作闸门**：
  * `risk.level=bsod` 的动作默认禁用，必须显式 `-OverrideBsod`（结果里红字/`[高危]` 提示 + 审计日志）。
  * `kind=blindscan`（盲扫）另需 `-IUnderstand`；首版不允许 `-Apply` 盲扫。
  * `layout.method=neither`（METHOD_NEITHER：驱动直接解引用用户指针）自动按 bsod 风险处理。
  * **写类动作无原值不写**：`readBack`（或 `kind=read` 且输入字段重合的动作）读不到原值 ⇒ 拒绝执行写；
    写成功后必生成还原脚本（`var\driver-profiles\restore\` 下的 `.ps1` / `.cmd` / `.json`）。
* **指纹门**：`target.sha256` 与实际 `.sys` 不符 ⇒ 一律拒绝（布局错版本必蓝屏），`-SkipFingerprint`
  只在"文件定位不到"时可用；`.sys` 缺失时默认拒绝执行。

## 安全语义（必须遵守）

1. `driver.ctl.send` **默认只预览**：不 `CreateFile` 设备、不发任何 IOCTL，只打印将发送的 IOCTL 与缓冲区十六进制。
2. **预览/校验/设备探测永不对真实设备发未知 IOCTL**（未知 IOCTL 可能立刻蓝屏）。
3. 执行路径**只用 profile 声明的候选入口**；`driver.devices` 里那些按服务名派生的候选只用于排查，
   不会拿去写。
4. 设备对象名 ↔ 驱动服务名在用户态**没有权威映射**，工具只按名字匹配并如实报告（匹配不上就是 0），不猜。