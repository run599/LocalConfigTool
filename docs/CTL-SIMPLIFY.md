# IOCTL 操作简化（A + B + C）

> 目标：**不让小白写结构体 JSON**。以前发一个 IOCTL 要手写 48 字节结构体，现在最少的写法是一行
> `addr=@ntoskrnl`。

## B：payload 三种写法（都收）

```powershell
# ① JSON（老写法，仍然支持）
-Payload '{"addr":"0xFFFFF80142A00000","readSize":4}'

# ② 简写（推荐给小白）：key=value，逗号/分号/换行分隔
-Payload 'addr=0xFFFFF80142A00000,readSize=4'

# ③ 全省略：用 profile 里 action.presets 的默认值
-Payload ''            # 等价于不传
```

并且值里支持 **`@ntoskrnl`**：自动取内核基址（`psapi!EnumDeviceDrivers`），省掉"自己去查地址"：

```
-Payload 'addr=@ntoskrnl'      → addr 自动变成 0xFFFFF80142A00000（本机实测值）
```

也可以单独查：`Engine.ps1 -Verb driver.kernelbase`（只读）。

## A：profile 里的 `presets` 与 `require`

```json
"actions": {
  "kread": {
    "ioctl": "0x80002048",
    "require": ["addr"],                    // 必须由人给，预设不能代替
    "presets": { "readSize": 4, "offset": 0 },   // 其余字段自动补
    "in": [ ... 7 个字段 ... ],
    "out": [ ... ]
  }
}
```

- `presets` 降低输入量：只给 `addr`，`readSize`/`offset` 自动补。
- `require` 是**安全门**：这些字段不能靠默认值，必须人显式给。
- **额外硬门（本次新增）**：如果 action 既没有 `presets` 也没给 payload，而动作确实需要输入 ⇒ **拒绝执行**。
  原因很直接：字段会按 0 填充，等于向 **0 地址**发 IOCTL，几乎必然立刻蓝屏。

## C：目录条目自带已验证 profile，下载后自动落盘

`samples\catalog.json` 的条目可以带一个 `profile`（纯数据）。`samples.get -Apply` 在哈希校验通过后：

1. 把 profile 的 `target.sha256` 改成**实际文件的哈希**（目录里只是声明）；
2. `driver.profile.save` 落盘到 `var\driver-profiles\<id>.json`（内部先过 schema 校验）；
3. 若同名 profile 已存在 ⇒ **跳过**（不覆盖人工审定过的版本）。

于是「下载样本 → 立刻能发 action」这中间**没有手工步骤**。

配套改动：`driver.ctl.send` 定位 `.sys` 时，候选里新增了
`var\samples\<文件名>` 与 `var\samples\*.sys`（按 SHA256 精确匹配）——刚下载的样本不需要再手动指路。

## 小白完整流程（现在）

```powershell
# 1) 取样本（哈希不符直接丢弃）
'{"id":"rtcore64-01aa278b"}' > a.json
Engine.ps1 -Verb samples.get -ArgsFile a.json -Apply
#    → var\samples\rtcore64-01aa278b.sys + 自动落 profile

# 2) 加载（服务名自动推导）
'{"path":"<上面的 .sys>"}' > u.json
Engine.ps1 -Verb driver.use -ArgsFile u.json -Apply

# 3) 发一个动作（只预览；加 -Apply 才真发）
'{"profile":"rtcore64-01aa278b","action":"kread","payload":"addr=@ntoskrnl"}' > c.json
Engine.ps1 -Verb driver.ctl.send -ArgsFile c.json

# 4) 清理
Engine.ps1 -Verb driver.cleanup -Apply
```

## 测试

`tests\CtlSimplifyTest.ps1`（16 断言，已进 `Run-AllGates`）：本地目录条目（不联网）+ 假驱动文件，
验证 **C 自动落盘**、**A 的 require 拦截**（缺 addr 必须拒）、**B 简写/JSON/@ntoskrnl/presets**、
坏简写拒绝、`kernelbase`、重复获取不覆盖、清理无残留。**全程不发送任何 IOCTL、不加载驱动。**
