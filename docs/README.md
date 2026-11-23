# SoundBridge 工程文档

本目录是 SoundBridge 的**唯一**工程文档位置。历史上独立的
`SoundBridge-Research/` 研究目录已退役，其长期有效的内容并入此处；逐批次的实现
报告、审计与验证归档不随仓库发布（见 §6）。

文档只描述**当前已实现**的架构与**实际执行过**的验证。凡未验证的事项一律标注
为未验证，不用推断代替证据。

> **1.2.0 发布说明**：1.2.0 已于 2026-11-21 在 GitHub Releases 正式发布，并在
> 发布验证机上完成端到端安装与运行验证。发布事实、权威哈希与原始证据见
> [release/SoundBridge-1.2.0-Final-Release-Report.md](release/SoundBridge-1.2.0-Final-Release-Report.md)；
> 发布后仍未解决的问题见 [risks/Known-Limitations.md](risks/Known-Limitations.md) 的 §2A。

---

## 1. 产品定位

SoundBridge 是一个 macOS 菜单栏应用，为**固定音量**的 HDMI / DisplayPort
显示器提供系统级软件音量控制与 EQ。

系统把这些显示器的音量滑块置灰，因为设备本身不提供硬件音量。SoundBridge
在应用与物理设备之间插入一个虚拟音频驱动（AudioServerPlugIn），把系统输出
改道到该驱动，由 Host 进程做增益、EQ 与格式适配后再交给物理设备。用户看到的
仍然是系统音量滑块与键盘音量键。

- 无内核扩展（不加载 kext）。
- 分发：**完全未签名、未公证、无自动更新**（发布策略，见
  [Known-Limitations](risks/Known-Limitations.md) L-13）。这不是 ad-hoc 签名。
- 版本号 `VERSION` = `1.2.0`；共享音频协议版本 `0x00020200`。

## 2. 架构总览

```
┌───────────────┐   preferences / control   ┌──────────────────┐
│ SoundBridge   │──────────────────────────►│ SoundBridge Host │
│ App (menu bar)│                           │ (user process)   │
└───────┬───────┘                           └────┬────────┬────┘
        │ mmap (EQ / volume state)               │        │ AudioUnit render
        │                                        │        │
        ▼                                        ▼        ▼
  /tmp/soundbridge-<ownerUID>-<deviceUID>     DSP (EQ)  physical device
        ▲                                        ▲
        │ mmap + ring write                      │
┌───────┴────────┐    HAL callback    ┌─────────┴──────────┐
│ SoundBridge    │◄───────────────────│ coreaudiod /       │
│ Driver (.driver)│   (libASPL)        │ apps audio output  │
└────────────────┘                    └────────────────────┘
```

数据面是**一块文件映射的共享内存**：固定 320 字节头 + 二次幂帧数的单生产者
单消费者（SPSC）Ring Buffer。Driver 是唯一 Producer，Host 是唯一 Consumer。

音频主链：`coreaudiod` → libASPL `Device` → `OnWriteMixedOutput` →
`rf_ring_write` → Host `AudioRenderer.render` → `rf_ring_read` → DSP / 增益 /
反交织 → 物理设备。控制面：App 与 Host 通过同一块映射交换 EQ 与音量状态；
Driver 通过 `/tmp` 下的控制文件与 Host 交换设备列表与音量状态。

完整说明见 [architecture/SoundBridge-1.2.0-Architecture.md](architecture/SoundBridge-1.2.0-Architecture.md)。

### 2.1 主题与文档对照

| 主题 | 权威文档 |
|---|---|
| 系统组件与职责边界 | [architecture](architecture/SoundBridge-1.2.0-Architecture.md) §2 |
| 音频处理链路（格式转换 / SRC / 漂移补偿） | [architecture](architecture/SoundBridge-1.2.0-Architecture.md) §2、[driver README](../packages/driver/README.md) |
| 共享内存协议与 ABI | [architecture](architecture/SoundBridge-1.2.0-Architecture.md) §3、§10 |
| Ring Buffer 契约 | [engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md) |
| Producer 准入与所有权 | [engineering/Admission-Ownership.md](engineering/Admission-Ownership.md) |
| Driver 回调准入与排空 | [engineering/Callback-Lifecycle.md](engineering/Callback-Lifecycle.md)、[CallbackGate-Memory-Model.md](engineering/CallbackGate-Memory-Model.md) |
| Mapping 退役与 Quarantine | [engineering/Mapping-Retirement.md](engineering/Mapping-Retirement.md) |
| Host / Driver 生命周期与崩溃恢复 | [engineering/SharedMemory-Lifecycle.md](engineering/SharedMemory-Lifecycle.md)、[architecture](architecture/SoundBridge-1.2.0-Architecture.md) §8–§9 |
| 实时音频安全（回调内不得做什么） | [CallbackGate-Memory-Model.md](engineering/CallbackGate-Memory-Model.md) §10、[Known-Limitations](risks/Known-Limitations.md) §3.1 |

### 2.2 ABI 速查

| 项 | 值 |
|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200`（十进制 131584） |
| `RF_SHARED_AUDIO_HEADER_SIZE` | `320` bytes |
| `audio_data` 起始偏移 | `320` |
| Admission 块 | `admission_state` @256、`admission_epoch` @264、`producer_owner_token` @272、`admission_claim_seq` @280 |
| 共享头副本 | 4 份，SHA-256 必须相同 |
| 版本号 | `VERSION` = `1.2.0` |

数值以 [architecture](architecture/SoundBridge-1.2.0-Architecture.md) §10 为准，并由
`tools/check_protocol_layout.sh`（C11 + C++17）与
`tools/sync_shared_header.sh --check` 在每次 `make build` 前强制校验。

## 3. 文档地图（当前有效）

| 文档 | 内容 | 状态 |
|---|---|---|
| [architecture/SoundBridge-1.2.0-Architecture.md](architecture/SoundBridge-1.2.0-Architecture.md) | 唯一现行架构说明：组件、共享内存、Ring、准入、退役、启动/停止、崩溃恢复、ABI | 维护中 |
| [engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md) | Ring 契约、容量、内存序 | 维护中 |
| [engineering/Admission-Ownership.md](engineering/Admission-Ownership.md) | Admission 状态机与 Producer 唯一性 | 维护中 |
| [engineering/Callback-Lifecycle.md](engineering/Callback-Lifecycle.md) | 回调准入 / 排空 / RAII 租约 | 维护中 |
| [engineering/Mapping-Retirement.md](engineering/Mapping-Retirement.md) | 退役前提、唯一 munmap 入口、Quarantine | 维护中 |
| [engineering/SharedMemory-Lifecycle.md](engineering/SharedMemory-Lifecycle.md) | incarnation 全生命周期与崩溃恢复 | 维护中 |
| [engineering/CallbackGate-Memory-Model.md](engineering/CallbackGate-Memory-Model.md) | C++ 内存模型证明与 lock-free 保证 | 维护中 |
| [development/DEVELOPMENT_GUIDE.md](development/DEVELOPMENT_GUIDE.md) | 环境、构建、测试、发布命令、代码地图、贡献规则、故障排查 | 维护中 |
| [risks/Known-Limitations.md](risks/Known-Limitations.md) | 已知缺陷、已知限制、未验证项、环境风险、发布后登记（§2A） | 维护中 |
| [release/SoundBridge-1.2.0-Final-Release-Report.md](release/SoundBridge-1.2.0-Final-Release-Report.md) | 1.2.0 发布证据：哈希、安装、驱动加载、功能与稳定性 | **冻结（权威证据）** |
| [release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md](release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md) | 发布后验证摘要（英文）：下载完整性、安装、未签名驱动加载、功能、31 分钟稳定性、两项未测 | **冻结（发布后记录）** |
| [release/SoundBridge-1.2.0-Release-Checklist.md](release/SoundBridge-1.2.0-Release-Checklist.md) | 发布检查单（每次发布复用） | 维护中 |
| [release/SoundBridge-1.2.1-Product-Quality-Report.md](release/SoundBridge-1.2.1-Product-Quality-Report.md) | 未发布 1.2.1 工作的三项 P1 修复报告：根因、改动、测试与命令、NOT VERIFIED 清单 | 一次性记录（**未发布**） |
| [release/SoundBridge-Hardware-Realtime-Operator-Runbook.md](release/SoundBridge-Hardware-Realtime-Operator-Runbook.md) | `tools/hardware-validation/` 的操作手册：前置条件、场景 H1–H8、执行步骤、停止条件与收尾检查 | 维护中 |
| [release/SoundBridge-Hardware-Realtime-Result-Schema.json](release/SoundBridge-Hardware-Realtime-Result-Schema.json) | `sb-hw-validate` 输出 `result.json` 的结构定义与字段语义 | 维护中 |

## 4. 已发布资产（不要就地改写）

下面两份文档在发布时被 workflow 复制进 `dist/` 并随 GitHub Release 上传，其内容
与用户下载到的文件字节一致。改动它们会让仓库与已发布资产不一致：

| 文件 | 发布时 SHA-256 | 说明 |
|---|---|---|
| [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) | `01ad029bedb2…b9a782` | 安装/卸载指南；§5.3 的「未签名驱动能否加载」写于发布前，其现状见 Known-Limitations U-17 |
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | `21d8105e54b5…ebf34a` | 1.2.0 变更说明；§4.1 与 §5 的 NOT_VERIFIED 结论写于发布前，现状见 Known-Limitations §2A |

规则：**下一次发布（1.2.1）时**再更新这两份文档并重新上传；在此之前它们作为
1.2.0 的历史快照保留，当前状态以 Known-Limitations 与最终发布报告为准。两个路径
不得移动——`.github/workflows/release.yml` 直接读取 `docs/INSTALLATION_GUIDE.md` 与
`docs/RELEASE_NOTES.md` 并校验版本号。

> **状态更新（未发布的 1.2.1 工作）**：为交付卸载流程与发布说明，
> `INSTALLATION_GUIDE.md` §9（英文重写）与 `RELEASE_NOTES.md` 的
> 「1.2.1 (unreleased)」一节已在工作树中写入，因此仓库内这两个文件**不再与上表
> SHA-256 一致**。已发布的 1.2.0 版本仍以 GitHub Release 上传件为准，上表哈希作为
> 历史记录保留。这次改写**未发布**，也不改动 1.2.0 的任何验证结论。

## 5. 验证状态

平台：macOS 27.2.1（`26B131`）/ arm64，Apple clang 21.0.0，Apple Swift 6.4.2；
Driver 为 universal（`x86_64 arm64`）Release 构建。

下表是「哪一层被验证」的分层结论；逐项原始证据在最终发布报告，面向读者的英文
摘要在 [Post-Release Validation Addendum](release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md)。

| 层次 | 状态 | 证据 |
|---|---|---|
| 协议 / Ring / 准入 / 退役（自动化） | `TESTS PASSED` | `make test` 内的 `check_protocol_layout.sh`、`sync_shared_header.sh --check` 与 Host 测试套件；机制见 [engineering/](engineering/) |
| Host / App 全量回归 | `TEST_VERIFIED` | 1.2.0 发布前 `make test` 退出码 0，Host 379 / App 253（报告 §6）；该批次原始输出随阶段报告移出仓库（§6） |
| 1.2.0 发布物真实性 | `VERIFIED` | 公开下载与本地权威哈希逐项一致 |
| 安装与载荷一致性 | `VERIFIED` | `installer` 安装；109/109 文件字节一致 |
| 未签名驱动加载 | `VERIFIED — 单机、限定环境` | `HALS_RemotePlugInRegistrar` + 驱动 PID（报告 §18） |
| 功能 K1–K4 | `VERIFIED` | 播放、音量/静音、运行时 EQ（报告 §21） |
| 恢复 K5a / K5b | `VERIFIED` | SIGTERM 有序停机；App 重启后驱动自动重连 |
| 稳定性 K6 | `VERIFIED（31 分 01 秒）` | 89,320,455 帧，播放期零欠载/零溢出（报告 §22） |
| 设备移除 / GUI 安装路径 / 其他 macOS 与 Intel | `NOT_VERIFIED` | [Known-Limitations](risks/Known-Limitations.md) §2A |

**未验证项不因归档或发布而消失**，统一登记在
[risks/Known-Limitations.md](risks/Known-Limitations.md)。

## 6. 阶段报告（不在本仓库）

逐批次的实现报告、审计、验证归档与迁移清单（`P1`–`P4`、`docs/1.2.0/`、
`docs/verification/`、`Documentation-Migration-Manifest.md`、`manifests/` 等 39 份）
已从本目录移出。它们记录的是当时的阶段状态（早期章节里出现过协议 `0x00020100`
与带 ad-hoc 签名的 RC），不代表当前 ABI 或当前发布策略；其技术结论已并入下列
正式文档，需要追溯过程记录时查 Git 历史（`v1.2.0` 及更早的提交仍完整包含它们）。

| 曾由阶段报告承载的内容 | 现行位置 |
|---|---|
| 协议 / Ring / 准入 / 退役的自动化结论 | [engineering/](engineering/) |
| 默认输出治理、音量转发、音频主链 | [architecture](architecture/SoundBridge-1.2.0-Architecture.md) §2、§8–§9 |
| EQ 映射恢复与持久化 | [architecture](architecture/SoundBridge-1.2.0-Architecture.md)、[Known-Limitations](risks/Known-Limitations.md) §2A / §2B |
| 风险登记与关闭依据 | [risks/Known-Limitations.md](risks/Known-Limitations.md)（§0 关闭项、§2A 发布后登记、§2B 未发布工作） |
| 发布链、未签名策略、发布证据 | [release/](release/)、[Known-Limitations](risks/Known-Limitations.md) L-13 |
| 真机验证证据（安装、驱动加载、功能、31 分钟稳定性） | [release/SoundBridge-1.2.0-Final-Release-Report.md](release/SoundBridge-1.2.0-Final-Release-Report.md) |

新的阶段性过程记录写在提交说明或本地归档里，不写进本目录。

### 6.1 2026-11-23 移出的第二批（DSP / Host+CoreAudio / 硬件实时）

同一规则适用于随后产生的三批阶段文档，共 10 份：仓库级审计
`SoundBridge-API-Audit-Handbook.md` 与 `SoundBridge-Main-Flow-Walkthrough.md`；
`release/` 下的 `SoundBridge-Core-Engineering-Audit.md`、
`SoundBridge-DSP-Engine-Code-Audit-Report.md`、
`SoundBridge-DSP-Engine-Remediation-Report.md`、
`Host-CoreAudio-Realtime-Execution-Path.md`、
`SoundBridge-Host-CoreAudio-Realtime-Validation-Report.md`、
`SoundBridge-Host-CoreAudio-Integration-Findings.md`、
`SoundBridge-Hardware-Realtime-Readiness-Assessment.md`、
`SoundBridge-Hardware-Realtime-Validation-Report-A2A4.md`。

其中的技术结论去向：

| 曾由这批报告承载的内容 | 现行位置 |
|---|---|
| DSP 整改后的正确性与并发结论、统计字段与 ABI 承诺 | 代码与测试本身（`packages/dsp`）、[engineering/](engineering/)、[architecture](architecture/SoundBridge-1.2.0-Architecture.md) §10 |
| Host 渲染路径的实时安全分类与测量结论 | [engineering/CallbackGate-Memory-Model.md](engineering/CallbackGate-Memory-Model.md) §10、`make test` 的 Host 套件 |
| 硬件实时验证已执行 / 未执行的边界与数字 | [risks/Known-Limitations.md](risks/Known-Limitations.md) §2C、U-6、U-15 |
| 验证工具的使用方式与输出格式 | [Operator Runbook](release/SoundBridge-Hardware-Realtime-Operator-Runbook.md)、[Result Schema](release/SoundBridge-Hardware-Realtime-Result-Schema.json) |

**未执行的验证不因报告移出而消失**：采样率 / 缓冲区矩阵、设备移除、可听性与
`p99.9` 的缺口一律登记在 [Known-Limitations](risks/Known-Limitations.md)。

## 7. 维护规则

- 新的工程文档一律写入本目录，不再创建独立研究目录。
- 修改共享头 / 协议 / Ring 语义时，必须同时更新
  [architecture](architecture/SoundBridge-1.2.0-Architecture.md) 与对应
  [engineering](engineering/) 文档，并跑 `make protocol-check`。
- 风险状态变化（包括关闭）必须登记到 [risks/Known-Limitations.md](risks/Known-Limitations.md)，
  不能让「已解决」只留在聊天记录里。
- 已发布资产（§4）只在下一次发布时更新。
- 阶段报告不进入本目录（§6）；需要更正任何已发布结论时，在正式文档里写新结论，
  而不是翻出历史报告改写。
- 构建与测试命令只在 [development/DEVELOPMENT_GUIDE.md](development/DEVELOPMENT_GUIDE.md)
  维护，其他文档引用它而不复制命令。
