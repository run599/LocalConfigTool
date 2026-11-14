# 文档地图

> 项目有两代（配置工具 + 驱动分析平台），文档因此分成了几类。
> **按角色找**比按文件名找快。

---

## 第一次接触

| 读什么 | 为什么 |
|---|---|
| **`README.md`** | 先看「这是什么」和「四步闭环」两节。**读完就够了**。 |
| `docs/WORKFLOW.md` | 想理解"为什么这么设计"（动态锚定 → 静态精读 → 表枚举 → 反哺） |

## 要改代码

| 读什么 | 为什么 |
|---|---|
| `docs/CONTRACT.md` | **接口契约**：Result 形状、verb 清单、模块签名、安全铁律。改之前必读 |
| `docs/ARCHITECTURE.md` | 分层、依赖方向、模块全景（19 个 `.psm1`） |
| 各 `core\*.psm1` 头部 | 每个模块开头的「职责 / 导出 / 铁律」三段说明 |
| `docs/PITFALLS.md` | **改之前扫一眼** —— 里面全是"不报错但结论错"的坑 |

## 要查某个具体问题

| 问题 | 去哪 |
|---|---|
| 某个 verb 怎么用 / 有哪些参数 | `engine.cmd -Verb engine.verbs`（自描述），或 `docs/CONTRACT.md` |
| 驱动分析怎么一步步做 | `docs/WORKFLOW.md` |
| profile 格式 / 字段类型 | `core\driver-profiles\README.md` |
| 自研驱动的 ABI | `docs/DRIVER-ABI.md` |
| AI / MCP 怎么接 | `docs/AI-INTERFACE.md` |
| Java UI 架构 | `docs/UI-JAVA.md` |
| 插件怎么写 | `docs/PLUGIN-SDK.md` |
| 样本库规则 | `docs/SAMPLES.md` |
| 两条能力路线与前置条件 | `docs/CAPABILITY-ROUTES.md` |
| IOCTL 操作简化（A/B/C） | `docs/CTL-SIMPLIFY.md` |

## 想了解历史

| 读什么 | 说明 |
|---|---|
| `docs/ANALYSIS-ROADMAP.md` | **历史演进记录**（43KB）。真实探索日记：怎么从"覆盖率 5.6%"走到"18 个精确码"。**不是使用文档** |
| `docs/DESIGN-RIZIN.md` | rizin 静态分析的设计说明（已实现） |

---

## 文档维护规则

1. **README 是唯一入口**，其余文档都要能从 README 或本文件到达
2. **数字要一致**：verb 数、门禁数写在 README / CONTRACT / ARCHITECTURE 里，改了一处要全改
   （有个简单检查：搜 `个 verb`，只允许出现 `86`（总数）、`13`（`driver.vm.*`）、`69`（历史对比表））
3. **PITFALLS 按主题归类，不按时间堆叠** —— 它是查阅手册，不是日记
4. **ANALYSIS-ROADMAP 可以按时间堆叠** —— 它本来就是日记
5. **每个坑要带判据**：不只说"会错"，要说"怎么一眼看出自己错了"

---

## 文件清单

```
README.md                      入口（两代总览 + 四步闭环 + 能力清单）
docs/
  00-INDEX.md                  本文件
  WORKFLOW.md                  ★ 四步闭环方法论（第二代核心）
  CONTRACT.md                  接口契约（Result / verb / 签名 / 铁律）
  ARCHITECTURE.md              分层与依赖（19 个模块）
  PITFALLS.md                  ★ 踩坑速查（按主题）
  ANALYSIS-ROADMAP.md          历史演进记录（日记）
  DESIGN-RIZIN.md              rizin 静态分析设计
  DRIVER-ABI.md                自研驱动 ABI 规格
  AI-INTERFACE.md              AI / MCP 接入
  PLUGIN-SDK.md                插件 SDK
  SAMPLES.md                   样本库规则
  CAPABILITY-ROUTES.md         两条能力路线
  CTL-SIMPLIFY.md              IOCTL 操作简化
  UI-JAVA.md                   Java UI
core/driver-profiles/README.md profile 目录与格式
```
