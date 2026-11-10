# LocalConfigTool 驱动 ABI 规格（v1）

> 面向「**自己写驱动**」的人：照着这份规格实现，加载后**无需任何 profile** 就能被本工具识别与调用。
> 面向「**第三方驱动（含漏洞驱动）**」：走 driver profile，见 `docs\CONTRACT.md` §13.4。
>
> 一句话结论：驱动控制接口**不自描述**，所以通用化只有两条路 —— **统一的 ABI（本文）** 或
> **每个驱动一份 profile**。通用的是这两套契约，不是驱动本身。

---

## 0. 设计取舍（为什么这样切）

| 决定 | 理由 |
|---|---|
| 内核面**尽量小**：默认只提供 **任意内核读写（kread/kwrite）** 原语 | 原语越小越好验证、越不容易蓝屏；能力全部上移到用户态 |
| **不在内核里直接起进程** | `ZwCreateUserProcess` 从内核发起极脆：依赖 CSRSS 通知、受驱动所在线程的 IRQL/上下文限制、很多驱动类型根本不允许 |
| 「执行任意命令」= **用户态 stager 建立在原语之上** | 内核改 token / 解 PPL → **用户态** `CreateProcessAsUser`。整条链只依赖 1~2 个原语，**换驱动不用改一行命令执行代码** |
| 版本化 + 能力位协商 | 工具**拒绝** ABI 不匹配的组合（布局错版本必然蓝屏） |
| **不做**：隐藏自身、对抗/规避安全产品、无长度限制的读写 | 这些不是"通用加载器"的一部分，且会让工具从"可回滚的管理工具"变成别的东西 |

---

## 1. 设备与符号链接

| 项 | 值 |
|---|---|
| 设备名 | `\Device\LctCtl` |
| 符号链接 | `\??\LctCtl`（用户态：`\\.\LctCtl`） |
| 设备接口 GUID | `{6C7A47B0-6D2A-4C4E-9E1F-2A5B7C8D9E01}` |

要求：
1. `IoCreateDevice(..., FILE_DEVICE_UNKNOWN, 0, FALSE, &dev)`（或 WDF 等价物）；
2. `IoCreateSymbolicLink(L"\??\LctCtl", L"\Device\LctCtl")`；
3. **注册设备接口**（`WdfDeviceCreateDeviceInterface` / `IoRegisterDeviceInterface`）。
   ——这一条让客户端可以用 `CM_Get_Device_Interface_List` **按 GUID 找到你**，不必猜名字；
   这是本工具首选的定位策略（`locate.strategy="interfaceGuid"`）。

---

## 2. IOCTL 表

全部 **METHOD_BUFFERED + FILE_ANY_ACCESS + DeviceType = FILE_DEVICE_UNKNOWN(0x22)**。
编码公式：`CTL_CODE(DeviceType, Function, Method, Access) = (DeviceType << 16) | (Access << 14) | (Function << 2) | Method`。

| 名称 | Function | 结果常量 | 用途 |
|---|---|---|---|
| `LCT_PING` | 0x800 | `0x00222000` | 握手：回 ABI 版本与能力位（**必须实现**） |
| `LCT_CAPS` | 0x801 | `0x00222004` | 单独取能力位/限额（可选） |
| `LCT_KREAD` | 0x802 | `0x00222008` | 任意内核读 |
| `LCT_KWRITE` | 0x803 | `0x0022200C` | 任意内核写（**必须回填写前原值**） |

> 工具侧**不需要**你告诉它这些数字：实现了本 ABI 的驱动，`driver.profile.draft` 可直接产出
> 可用 profile（因为设备名与 IOCTL 都是固定的）。

---

## 3. 结构布局（全部 8 字节对齐、小端）

`METHOD_BUFFERED` 下输入/输出**共用** `Irp->AssociatedIrp.SystemBuffer`；输入长度 =
`Parameters.DeviceIoControl.InputBufferLength`，输出长度 = `OutputBufferLength`。
**两个长度都必须先检查再动指针**（这是最常见的内核蓝屏点）。

```c
// ---- LCT_PING：无输入 ----
typedef struct _LCT_PING_OUT {
    ULONG Abi;          // 必须 = 1
    ULONG Version;      // 驱动自报版本（例如 0x00010002）
    ULONG Caps;         // 能力位，见 §4
    ULONG MaxTransfer;  // 单次读写字节上限；0 = 不限制（不推荐）
} LCT_PING_OUT;         // 16 字节

// ---- LCT_KREAD ----
typedef struct _LCT_KREAD_IN {
    ULONG64 Addr;       // 目标内核虚拟地址
    ULONG   Len;        // 请求字节数（必须 <= MaxTransfer）
} LCT_KREAD_IN;         // 12 -> 补齐 16

typedef struct _LCT_KREAD_OUT {
    ULONG Code;         // 0 = 成功；其它为 NTSTATUS
    ULONG Done;         // 实际拷贝字节数
    UCHAR Data[];       // 紧随其后，长度 = Done
} LCT_KREAD_OUT;

// ---- LCT_KWRITE ----
typedef struct _LCT_KWRITE_IN {
    ULONG64 Addr;
    ULONG   Len;
    UCHAR   Data[];     // 紧随其后，长度 = Len
} LCT_KWRITE_IN;

typedef struct _LCT_KWRITE_OUT {
    ULONG Code;
    ULONG Done;
    UCHAR Before[];     // ★ 写前原值，长度 = Done（本工具的"无原值不写"铁律靠它）
} LCT_KWRITE_OUT;
```

对齐建议：所有结构起始偏移 8 字节对齐；`Data[]`/`Before[]` 紧跟在头部之后（工具按
`offset = sizeof(header)` 解包，所以**不要**在头部里加隐藏填充以外的字段）。

---

## 4. 能力位（Caps）

| 位 | 名称 | 含义 |
|---|---|---|
| `0x1` | `CAP_KREAD` | 支持 `LCT_KREAD` |
| `0x2` | `CAP_EXEC` | 保留（将来"驱动侧执行"用；**默认不实现**） |
| `0x4` | `CAP_KWRITE` | 支持 `LCT_KWRITE` |
| `0x10` | `CAP_MAP_SECTION` | 保留（物理内存映射类原语） |

工具只调用 `Caps` 里声明过的能力；未声明就调用 ⇒ 工具的 `driver.profile.validate` 应报错（由 profile 侧保证）。

---

## 5. 安全要求（不满足，工具会拒绝使用）

1. **ACL**：设备对象只允许**已提权**的打开者；不要把 `FILE_ANY_ACCESS` 的 DACL 敞开给 `Everyone`。
2. **长度校验**：`Len <= MaxTransfer`、`Addr != 0`、`Data[]` 不得越出缓冲区；**不提供无长度限制的写**。
3. **准确 NTSTATUS**：失败要回准确状态码（别把 `STATUS_ACCESS_DENIED` 一律变成 `STATUS_UNSUCCESSFUL`），
   工具的 `errors` 分类依赖它。
4. **`LCT_KWRITE` 必须回填 `Before`**：工具在拿不到原值时**拒绝执行写**（`无原值不写`）；这一项认真实现，否则写路径根本不会被放行。
5. **不实现**：隐藏自身/进程/文件、hook SSDT、对抗或规避安全产品、绕过系统强制策略。
   本工具的定位是"可审计、可回滚的本地管理工具"，不做隐身。

---

## 6. 参考实现骨架（C 伪代码）

```c
NTSTATUS DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg) {
    drv->DriverStartIo = NULL;
    for (int i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++) drv->MajorFunction[i] = LctDispatchUnsupported;
    drv->MajorFunction[IRP_MJ_CREATE]           = LctDispatchCreate;   // 只放行已提权打开者
    drv->MajorFunction[IRP_MJ_CLOSE]            = LctDispatchClose;
    drv->MajorFunction[IRP_MJ_DEVICE_CONTROL]   = LctDispatchCtl;
    drv->DriverUnload                           = LctUnload;
    return LctCreateDevice(drv);   // IoCreateDevice + IoCreateSymbolicLink + 注册接口 GUID
}

NTSTATUS LctDispatchCtl(PDEVICE_OBJECT dev, PIRP irp) {
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);
    ULONG   inLen  = sp->Parameters.DeviceIoControl.InputBufferLength;
    ULONG   outLen = sp->Parameters.DeviceIoControl.OutputBufferLength;
    PVOID   buf    = irp->AssociatedIrp.SystemBuffer;
    NTSTATUS st = STATUS_INVALID_DEVICE_REQUEST;
    ULONG    done = 0;
    switch (sp->Parameters.DeviceIoControl.IoControlCode) {
    case LCT_PING:
        if (outLen >= sizeof(LCT_PING_OUT)) {
            LCT_PING_OUT* o = (LCT_PING_OUT*)buf;
            o->Abi = 1; o->Version = 0x00010002;
            o->Caps = CAP_KREAD | CAP_KWRITE; o->MaxTransfer = 0x1000;
            done = sizeof(LCT_PING_OUT); st = STATUS_SUCCESS;
        } else st = STATUS_BUFFER_TOO_SMALL;
        break;
    case LCT_KREAD: {
        if (inLen < sizeof(LCT_KREAD_IN)) { st = STATUS_INVALID_PARAMETER; break; }
        LCT_KREAD_IN* i = (LCT_KREAD_IN*)buf;
        LCT_KREAD_OUT* o = (LCT_KREAD_OUT*)buf;          // 复用同一缓冲区（输出侧）
        if (outLen < sizeof(LCT_KREAD_OUT) + i->Len) { st = STATUS_BUFFER_TOO_SMALL; break; }
        if (i->Len == 0 || i->Len > MAX_XFER) { st = STATUS_INVALID_PARAMETER; break; }
        UCHAR* dst = (UCHAR*)buf + sizeof(LCT_KREAD_OUT);
        ULONG64 want = i->Addr, got = 0;
        __try { for (; got < i->Len; ) { *(dst+got) = *(PUCHAR)(want+got); got++; } }
        __except (EXCEPTION_EXECUTE_HANDLER) { /* 部分拷贝 */ }
        o->Code = (got == i->Len) ? 0 : (ULONG)STATUS_PARTIAL_COPY;
        o->Done = got;  done = sizeof(LCT_KREAD_OUT) + got; st = STATUS_SUCCESS;
        break; }
    case LCT_KWRITE: {
        if (inLen < sizeof(LCT_KWRITE_IN)) { st = STATUS_INVALID_PARAMETER; break; }
        LCT_KWRITE_IN* i = (LCT_KWRITE_IN*)buf;          // 注意：输出与输入共用，先拷走原值再写
        if (i->Len == 0 || i->Len > MAX_XFER) { st = STATUS_INVALID_PARAMETER; break; }
        UCHAR* src = (UCHAR*)buf + sizeof(LCT_KWRITE_IN);
        UCHAR* before = ExAllocatePoolZero(NonPagedPool, i->Len, 'tcL');   // 先读原值
        ULONG64 a = i->Addr; ULONG got = 0;
        __try { for (; got < i->Len; ) { before[got] = *(PUCHAR)(a+got); got++; a = i->Addr + got; } }
        __except (EXCEPTION_EXECUTE_HANDLER) { }
        if (got != i->Len) { /* 原值拿不全 => 不写 */ st = STATUS_PARTIAL_COPY; break; }
        got = 0; a = i->Addr;
        __try { for (; got < i->Len; ) { *(PUCHAR)(a+got) = src[got]; got++; } }
        __except (EXCEPTION_EXECUTE_HANDLER) { }
        LCT_KWRITE_OUT* o = (LCT_KWRITE_OUT*)buf;        // ★ Before 就地回填
        o->Code = (got == i->Len) ? 0 : (ULONG)STATUS_PARTIAL_COPY;
        o->Done = got;
        RtlCopyMemory((UCHAR*)buf + sizeof(LCT_KWRITE_OUT), before, i->Len);
        ExFreePool(before);
        done = sizeof(LCT_KWRITE_OUT) + i->Len; st = STATUS_SUCCESS;
        break; }
    }
    irp->IoStatus.Status = st;
    irp->IoStatus.Information = done;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return st;
}
```

> 上面刻意保留了 `__try/__except` 与"原值拿不全就不写"的分支 —— 这两点是**可用性**前提：
> 写一个非法地址会让内核立刻 bugcheck，而本工具要求写路径必须能回滚。

---

## 7. 工具侧怎么把它用起来（无需 profile）

```
① driver.load   -ArgsFile a.json -Apply          # a.json: {"path":"C:\\Dev\\LctCtl.sys","name":"LctCtl"}
② driver.devices -ArgsFile b.json                # b.json: {"name":"LctCtl"}
   → 工具按「接口 GUID → 符号链接候选 → CreateFile canary」定位控制入口，并做错误分类
③ driver.profile.draft -ArgsFile c.json          # c.json: {"path":"C:\\Dev\\LctCtl.sys"}
   → 对本 ABI 驱动会直接产出**可用** profile（设备名与 IOCTL 都是本规格固定的）
④ driver.ctl.verify -ArgsFile d.json             # d.json: {"profile":"lctctl-abi"}
   → LCT_PING 握手：校验 Abi=1 / Version / Caps / MaxTransfer
⑤ driver.ctl.send -ArgsFile e.json               # e.json: {"profile":"lctctl-abi","action":"kread","payload":{"addr":"0xFFFFF800`00000000","len":16}}
   默认**只预览**（打印 IOCTL 与缓冲区十六进制）；加 -Apply 才真发
```

---

## 8. 与 profile 的关系（收束）

| 场景 | 需要的契约 | 谁来做 |
|---|---|---|
| **自己写的驱动** | **本文件（固定 ABI）** | 你按 §1–§6 实现 → 工具自动识别，profile 可自动生成（§7 ③） |
| **别人的驱动 / 漏洞驱动** | `driver profile`（`docs\CONTRACT.md` §13.4） | 每个驱动一份描述：定位法 + IOCTL + 结构布局 + 指纹 + 风险等级 |
| **能力（执行命令等）** | 建立在**内核原语**之上 | 工具用**通用用户态 stager**（内核改 token/解 PPL → 用户态起进程），与具体驱动无关 |

**结论**：`每个人驱动都不一样` 这件事，被**统一的 ABI** 或**统一的 profile 格式**吸收掉了 ——
这就是这个加载器"通用"的全部含义，也是它通用性的边界。