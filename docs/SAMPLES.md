# 样本库（预置规则）：不会自己找驱动的人，也能拿到能用的驱动

> 这个工具是给**不想/不会自己去找漏洞驱动**的人用的。所以"预置规则"是必须的：
> 打开界面就能看到有哪些驱动可用、对应什么 CVE、能干什么、风险多高，点一下就能拿到。

## 边界（这条线必须一直守住）

| 仓库里放什么 | 仓库里**不放**什么 |
|---|---|
| ✅ 规则：名称、CVE、来源 URL、SHA256、适用系统、能力、风险等级 | ❌ 可执行的漏洞驱动二进制、CVE 利用载荷 |

原因很简单：**规则是知识，载荷是武器**。规则的再分发没有法律风险，把厂商的漏洞驱动打包进你的仓库分发则有；
而用户拿到的体验是一样的——点一下就下载、校验、可用。

## 用起来长什么样

```
界面 第 3 页「样本库」
  ① 刷新目录（samples.list）        看到所有条目 + 本机是否已获取 + 哈希是否对得上
  ② 预览（不下载）                   只打印计划：从哪下、期望哈希、落到哪
  ③ 获取并校验                      真下载 → 强制 SHA256 → 不符直接丢弃（回收站）
  ④ 生成 profile                    拿到文件后立刻静态起草（confidence / needsReview）

命令行
  core\Engine.ps1 -Verb samples.list
  '{"id":"rtcore64-01aa278b"}' > a.json
  core\Engine.ps1 -Verb samples.get -ArgsFile a.json          # 预览
  core\Engine.ps1 -Verb samples.get -ArgsFile a.json -Apply   # 真下载 + 校验

AI
  ai.manifest 里已经包含这两个 verb；AI 可以直接"帮我取 RTCore64 并起草 profile"
```

获取成功后：

```
var\samples\<id>.sys     ← 载荷本体
var\samples\<id>.json    ← 来源记录（URL / 哈希 / 大小 / 时间 / 审计用）
```

## 目录格式（`samples\catalog.json`）

```json
{
  "schema": 1,
  "entries": [
    {
      "id": "rtcore64-01aa278b",
      "name": "RTCore64.sys（MSI Afterburner 4.6.2.15658）",
      "cve": ["CVE-2019-16098"],
      "tags": ["byovd", "lpe", "kernel-rw"],
      "os": ["Windows 10 19045"],
      "capability": ["任意内核内存读写"],
      "risk": "high",
      "verified": false,
      "url": "<your-driver-url>",
      "sha256": "<your-sha256>",
      "notes": "（示例：填入你自己的实测结论）"
    }
  ]
}
```

- **`sha256` 是硬门槛**：空哈希的条目（占位）会被拒绝，错误信息直接告诉你"没有哈希就没法校验"。
- 用户可以在 `var\samples\catalog.local.json` 里追加/覆盖条目（同 id 以本地为准），不需要改仓库文件。

## 加一个条目的正确姿势

1. 拿到文件（自己合法取得的），`Get-FileHash <file> -Algorithm SHA256` 算哈希；
2. 把 `id / name / cve / risk / url / sha256` 填进 `samples\catalog.json`（或 `var\samples\catalog.local.json`）；
3. 跑一次 `samples.get` 预览确认 URL 与哈希；
4. 真获取一次，确认哈希门通过、`var\samples\<id>.sys` 出现；
5. 实测 `driver.load`（本机 testsigning 已开），确认行为后把 `verified` 改成 `true`，并在 `notes` 写清实测结论。

## 安全提醒（会写进条目 notes）

- 加载漏洞驱动后，**本机任何用户都能借此拿到内核权限**；测完立刻 `driver.unload`。
- 未知 IOCTL 不要盲发：先 `driver.profile.draft`（只读）→ 人审定 → `profile.validate` 过指纹 → `ctl.send` 预览核对字节 → 才 `-Apply`。
- 加载/卸载需要管理员；普通权限下引擎会拦住并提示"请先提权"（见 `docs\CAPABILITY-ROUTES.md`）。

## 内置条目

| id | 状态 | 说明 |
|---|---|---|
| `rtcore64-01aa278b` | ✅ 可用（verified） | RTCore64，本机实测过：load 成功、kread 读回 ntoskrnl `MZ`、设备 `\Device\RTCore64` |
| `placeholder-intel-ntiolib` | ⬜ 占位 | 无 URL/哈希，`samples.get` 会拒绝；填好后启用 |
| `placeholder-cpuz` | ⬜ 占位 | 同上 |

## 测试

`tests\SamplesTest.ps1`（24 断言，已进 `Run-AllGates`）：
目录可读、id 严格校验（穿越/盘符/分隔符/超长全拒）、哈希格式校验、**预览不落盘**、
占位条目拒、**哈希不符丢弃且无残骸**、哈希正确才落盘并写来源记录、未知 id 拒、只写 `var\samples`。
全部用本地临时文件，**不访问网络**、不加载驱动、不发 IOCTL。
