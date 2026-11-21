# SoundBridge 1.2.0 — Phase 2.0 实施计划

- 日期：2026-11-16
- 基线：`main` @ `0574414`（tag `1.1.3`）
- 目标版本：1.2.0
- 本阶段范围：工程现状复核 + 实施计划。**未修改任何生产代码。**
- 配套文件：`docs/1.2.0/POC_ERRATA.md`（对 PoC 报告的勘误与增量实证）

---

## 0. 执行摘要

### 0.1 复核结论

| 项目 | 结论 |
|---|---|
| 仓库基线 | 与 `0574414` 一致，`origin/main` 同步，无用户未提交改动（仅 `.qoder/`、`AUDIT_REPORT.md`、`POC_REPORT.md`、`tools/poc/`、`docs/` 未跟踪） |
| 子模块 | `libASPL` @ `633e0f7` 已初始化 |
| 三份协议头 | **MD5 完全相同**，当前无差异，但仍是三份物理副本 |
| 构建 | DSP / Driver / Host / App 四者全部通过（本轮实测） |
| 测试 | DSP 1 组通过；App 46 个 XCTest 通过；**Host 无 testTarget；Driver 无测试；CI 不跑测试** |
| PoC 结论 | 7 项主要结论中 **4 项成立、2 项需修正、1 项被推翻**（详见 `POC_ERRATA.md`） |
| 新增 P0 问题 | 2 个（OnStartIO 阻塞 17 s、Host 退出清理机制必然失败） |

### 0.2 最重要的三个判断

**判断 1：HARDWARE 模式比 PoC 报告描述的简单得多。**

`POC_REPORT.md` 判定"内置扬声器只能降级 SOFTWARE"，因为 `ConvertScalarToDecibels` 返回恒定值。本轮只读探针证明：`kAudioLevelControlPropertyDecibelValue` 在全部 4 台设备上**均可写**（含内置扬声器）。因此 HARDWARE 模式可以"算好 dB 直接写"，不需要 `ConvertScalarToDecibels`，不需要逐设备曲线适配。

**判断 2：issue #9 可以用两处改动根治。**

代理曲线是 `dB = 96·√s − 96`，Host 增益是 `dB = 48·(s−1)`，两者在 `s=0.05` 时相差 28.93 dB。把代理参数改为 `{MaxRaw=48, MinDB=−48}`（代理变成 `48·√s − 48`），把 Host 公式改为 `48·(√s − 1)`，两者**完全一致**。改动量：Driver 一个参数、Host 一行公式。

**判断 3：僵尸设备的根因不在 driver。**

unified log 显示 driver 侧 `desired=0 current=0`（已正确移除），但 HAL 客户端仍能枚举到两个代理设备。问题在 coreaudiod 的列表收敛。同时，Host 用于兜底的 `killall coreaudiod` 因权限不足**从未生效**。

---

## 1. 现状复核

### 1.1 仓库与构建

```
HEAD        0574414  ci: rename the release job now that it no longer notarizes
tag 1.1.3   9790a6d
submodule   633e0f7  packages/driver/vendor/libASPL (v3.1.2-1-g633e0f7)
```

| 组件 | 命令 | 结果 |
|---|---|---|
| DSP 构建 | `cmake --build packages/dsp/build` | OK（4 个 target） |
| DSP 测试 | `ctest --output-on-failure` | 1/1 passed，0.01 s |
| Driver 构建 | `cmake --build packages/driver/build` | OK（`SoundBridgeDriver`） |
| Host 构建 | `swift build -c release`（packages/host） | OK，0.28 s |
| App 构建 | `swift build -c release --triple arm64-apple-macosx` | OK，0.26 s |
| App 测试 | `swift test` | 46 XCTest passed（19 + 27） |

**构建约束**：`packages/host/Package.swift` 使用

```swift
.linkedLibrary("soundbridge_dsp"),
.unsafeFlags(["-L../../packages/dsp/build"]),
```

即 Host 通过相对路径链接 DSP 的预编译产物，SwiftPM 不知道这个依赖。**必须先进 DSP，再进 Host**，且从 `packages/host` 目录执行。CI 与本地脚本都依赖此顺序。

### 1.2 三份协议头

| 路径 | MD5 |
|---|---|
| `packages/driver/include/RFSharedAudio.h` | `d30af007730df2651900d959f0dbb60c` |
| `packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h` | 同上 |
| `apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h` | 同上 |

当前完全一致，但维护方式是人工复制。Phase 2.1 必须收敛。

**协议头实测布局**（本轮按字段重算，与 `sizeof` 一致）：

| 字段 | offset | size |
|---|---:|---:|
| `protocol_version` | 0 | 4 |
| `header_size` | 4 | 4 |
| `sample_rate` … `host_capabilities` | 8 | 36 |
| `creation_timestamp` | 48 | 8 |
| `format_change_counter` … `format_mismatch_count` | 56 | 64 |
| `driver_connected` / `host_connected` | 120 | 8 |
| `driver_heartbeat` / `host_heartbeat` | 128 | 16 |
| `volume_scalar` | 144 | 4 |
| `mute_state` | 148 | 4 |
| `eq_sequence` | 152 | 4 |
| `eq_snapshot` | 156 | 48 |
| `_reserved` | 204 | 60 |
| **sizeof** | | **264** |

`_reserved[256 − 148 − sizeof(RFEQSnapshot)]` 的基数 `148` 应为 `156`（`eq_snapshot` 的真实偏移）。这是 Phase 2.1 的前置修正项。

### 1.3 当前架构与数据流

```
┌────────────────────────────────────────────────────────────────┐
│ App (SwiftUI)                                                  │
│   VolumeController  → 读写代理设备的 kAudioDevicePropertyVolumeScalar
│   BasicEQView       → 3 段 (Bass/Mids/Treble) → 写 EQ 共享内存
└───────────────┬────────────────────────────────────────────────┘
                │ CoreAudio HAL
┌───────────────▼────────────────────────────────────────────────┐
│ coreaudiod                                                     │
│   ┌──────────────────────────────────────────────────────────┐ │
│   │ SoundBridgeDriver (HAL plugin, 1.1.2 installed)           │ │
│   │   SyncDevices()  读 /tmp/soundbridge-devices.txt 每 1 s    │ │
│   │     + Darwin notification com.soundbridge.devices-changed  │ │
│   │     + HostHeartbeatFresh() 15 s 超时                       │ │
│   │   CreateProxyDevice()  固定 48000 Hz / 2 ch                │ │
│   │   SoundBridgeVolumeControl : aspl::VolumeControl           │ │
│   │     params{} → −96…0 dB, Pow2Over1, 1 raw = 1 dB           │ │
│   │     SetRawValueImpl → rf_store_volume_scalar               │ │
│   │   OnStartIO → rf_store_volume_scalar(控件当前值)  ★覆盖点  │ │
│   └──────────────────────────────────────────────────────────┘ │
└───────────────┬────────────────────────────────────────────────┘
                │ /tmp/soundbridge-<physicalUID>  (RFSharedAudio, mmap)
┌───────────────▼────────────────────────────────────────────────┐
│ SoundBridgeHost (Swift)                                        │
│   DeviceDiscovery  → 只接受"无可写 scalar"的设备  ★过滤点       │
│   DeviceRegistry   → 写控制文件 + Darwin notify                 │
│   ProxyDeviceManager                                           │
│     autoSelectProxy     读物理音量 → 写代理   ★方向 1          │
│     restoreVolumeState  持久化 → 代理         ★方向 2          │
│     forwardProxyVolumeToPhysical 代理 → 物理  ★方向 3          │
│     forwardProxyMuteToPhysical    代理 → 物理 mute             │
│   AudioRenderer.render                                         │
│     EQ → gain = 10^((s−1)·48/20)              ★方向 4          │
└───────────────┬────────────────────────────────────────────────┘
                │ AudioUnit (HALOutput) @ 物理设备采样率
┌───────────────▼────────────────────────────────────────────────┐
│ Physical Device                                                │
└────────────────────────────────────────────────────────────────┘
```

**音量权威状态共 4 个，写入方向交错**：

| # | 状态 | 持有者 | 写入者 |
|---|---|---|---|
| 1 | `VolumeControl::rawVolume_` | driver | 用户（音量键/HAL）、Host（`setDeviceVolume`） |
| 2 | `RFSharedAudio::volume_scalar` | 共享内存 | driver（`SetRawValueImpl`、`OnStartIO`）、Host（`rf_store_volume_scalar` 待确认） |
| 3 | `VolumePersistence` 磁盘 | Host | `forwardProxyMuteToPhysical`、`forwardProxyVolume…` |
| 4 | 物理设备实际音量 | 硬件 | `forwardProxyVolumeToPhysical` |

这是 1.2.0 的核心问题域。

### 1.4 设备能力实测（本机）

| 设备 | 传输 | 通道 | scalar 可写 | dB 可写 | dB range | 曲线形状 |
|---|---|---:|---|---|---|---|
| Mac mini扬声器 | BuiltIn | 2 | 是 | **是** | −63.5…0 | Pow2（实测吻合） |
| LG ULTRAGEAR+ | DisplayPort | 8 | 否 | 否 | — | — |
| PHL 279M1RV | HDMI | 2 | 否 | 否 | — | — |
| BlackHole 16ch | Virtual | 16 | 是 | 是 | −64…0 | 线性（实测吻合） |
| 多输出设备 | Aggregate | 2 | 否 | 否 | — | — |
| LG 代理 | — | 2 | 是 | 是 | −96…0 | Pow2 |
| PHL 代理 | — | 2 | 是 | 是 | −96…0 | Pow2 |
| USB DAC / AirPods / 蓝牙 | — | — | **NOT TESTED** | | | |

---

## 2. 问题清单

严重度定义：

- **P0**：会破坏音频、导致静音/爆音、或阻塞用户操作
- **P1**：功能缺失或行为错误，用户可感知但有规避方式
- **P2**：体验/维护性问题

### 2.1 P0

| ID | 问题 | 证据 | 等级 |
|---|---|---|---|
| **P0-1** | 音量存在 4 个权威状态，互相覆盖 | `Plugin.cpp:462-476`；实测日志 `OnStartIO: synced VolumeControl value=1.000` | L5 |
| **P0-2** | 代理曲线与 Host 曲线不一致，同 scalar 下差 0～28.93 dB（issue #9） | `VolumeCurve.cpp:14-21` + `AudioRenderer.swift:178`；`s=0.05` 时代理 −74.53 / Host −45.60 | L4 |
| **P0-3** | 两条音量路径同时存在，放开过滤后必然双重衰减 | `ProxyDeviceManager.swift:755-776` + `AudioRenderer.swift:178` | L2（路径存在），L5（待放开过滤后验证） |
| **P0-4** | Host 退出后代理设备残留，选中后无声 | unified log `desired=0 current=0` + HAL 仍枚举 2 个代理 | L5 |
| **P0-5** | `OnStartIO` 重试累计阻塞 17.25 s | `Plugin.cpp:419-490`，`30ms × 2^n` × 15 次 | L1 + L5（日志中未命中重试分支） |
| **P0-6** | `restartCoreAudio()` 权限不足，清理机制从未生效 | `main.swift:288-301`；`coreaudiod` 属主 `_coreaudiod` | L5 |

### 2.2 P1

| ID | 问题 | 证据 |
|---|---|---|
| **P1-1** | 设备过滤以"有无可写 scalar"为唯一判据，内置扬声器被排除 | `DeviceDiscovery.swift:115-121`；控制文件仅 2 条 |
| **P1-2** | 代理固定 48k/2ch 与物理采样率解耦，产生双次 SRC | `Plugin.cpp:1051-1052` + `SharedMemoryManager.swift:48` |
| **P1-3** | 无采样率/格式变化监听 | `DeviceMonitor.swift:57-88` 只注册 2 个属性 |
| **P1-4** | 实时回调逐帧 O(n) 清零 + 数组独占性检查 | `AudioRenderer.swift:108-114`、`:133`、`:162` |
| **P1-5** | Mute 硬切无淡出；平滑时间常数为 4.17 ms（非注释所称 10 ms） | `AudioRenderer.swift:176-203`、`:20` |
| **P1-6** | 协议三份副本、`header_size` 从未校验、`_reserved` 基数错误 | `RFSharedAudio.h:115`、`Plugin.cpp:725-756` |
| **P1-7** | 三处"设备有无音量"判定实现不一致 | `DeviceDiscovery.swift:462` 用 `HasProperty`+`IsSettable`；`VolumeController.swift:644` 只用 `HasProperty`；`VolumeController.swift:140` 硬编码 `isFixedVolumeDevice = true` |
| **P1-8** | `Constants.swift` 注释与实现不符（"16 steps × 3 dB"） | `Constants.swift:27-31` vs driver 日志 raw 逐个变化 |
| **P1-9** | underrun 统计口径不可用（缺 `underrun_frames`） | `RFSharedAudio.h` 无该字段 |
| **P1-10** | EQ 只有 3 段，无预设管理 | `BasicEQView.swift`（95 行） |

### 2.3 P2

| ID | 问题 |
|---|---|
| P2-1 | Host 无 testTarget，Phase 2.1 的 10 项单测缺少载体 |
| P2-2 | CI 不运行任何测试（`release.yml` 只有构建/签名/发布） |
| P2-3 | Driver 无任何测试 |
| P2-4 | 仅支持单设备桥接 |
| P2-5 | 无诊断导出能力 |
| P2-6 | `RF_DebugLog` 每次 `fopen`/`fclose`，且写 `/tmp` |
| P2-7 | 设备能力与 CoreAudio 对象 ID 绑定，重启后失效（缺乏按 UID 的缓存） |

---

## 3. 模块依赖关系

```
                    ┌─────────────────────────┐
                    │ RFSharedAudio.h (协议)   │  ← Phase 2.1 收敛为单一源
                    └───────┬─────────────────┘
            ┌───────────────┼──────────────────┐
            ▼               ▼                  ▼
      Driver/Plugin.cpp  Host/AudioRenderer  App/shim.c
            │               │
            ▼               ▼
    VolumeControl 参数   音量状态模型          ← Phase 2.1 / 2.2
    OnStartIO 逻辑       VolumeMode 枚举
            │               │
            │               ▼
            │        ProxyDeviceManager
            │          ├─ 能力模型 (Phase 2.2)
            │          ├─ 模式选择 (Phase 2.2)
            │          └─ 曲线/dB 写入 (Phase 2.2)
            │               │
            ▼               ▼
    Device 生命周期      DeviceDiscovery   ← Phase 2.3
    SyncDevices          DeviceRegistry
    RemoveDevice 收敛    EQ 配置持久化
            │               │
            ▼               ▼
    coreaudiod 列表      AudioEngine / DeviceMonitor  ← Phase 2.4
```

**修改顺序约束**：

1. 协议必须先定型（2.1），否则 2.2 的 `volume_mode` 无载体
2. 音量状态必须先收敛（2.1），否则 2.2 的模式互斥会在脏状态上实现
3. 模式互斥必须先完成（2.2），否则 2.3 放开过滤会立刻暴露双重衰减
4. 生命周期必须先修（2.5 的 M1/M2 部分），否则 2.3 放开过滤后用户会遇到更多"选中即卡 17 秒"

> 建议把 **P0-5（OnStartIO 阻塞）** 与 **P0-6（无效 killall）** 提前到 2.1 一并处理，因为它们不依赖音量模型，且是放开设备过滤的前置条件。

---

## 4. 关键技术决策

### D1. 音量曲线统一方案

**现状**

| 侧 | 公式 | 范围 |
|---|---|---|
| 代理（driver） | `dB = 96·√s − 96` | 96 dB |
| Host 增益 | `dB = 48·(s−1)` | 48 dB |

**候选方案**

| 方案 | 改动 | 优点 | 缺点 |
|---|---|---|---|
| **A（推荐）统一为 48 dB Pow2** | Driver: `VolumeControlParameters{MaxRaw=48, MinDB=−48}`；Host: `dB = 48·(√s−1)` | UI dB == 实际 dB；步进感知自然；改动最小（1 参数 + 1 行） | 动态范围从 96 缩到 48（但 Host 本来就只有 48） |
| B 统一为 96 dB Pow2 | Host: `dB = 96·√s − 96` | 保留 96 dB 深度 | 同 scalar 下响度整体变小 5–29 dB，用户感知为"音量被改小了"，需要重新校准 |
| C 覆写 `GetDecibelValue()` | Driver: 重写虚函数，`dB = 48·(s−1)` | 不动 Host | `DecibelRange` 仍报 −96…0，与 `DecibelValue` 不自洽，系统音量 HUD 会错乱 |

**推荐 A。** 理由：

- 唯一一个"零额外概念"的方案：代理与 Host 用同一条曲线，`UI 显示值 == 实际衰减值`
- 48 dB 与现有 Host 行为一致，用户听感不跳变
- `libASPL` 的传动函数在 `dB range > 30` 时才启用（`VolumeCurve.cpp:383`），48 > 30，所以 `{MaxRaw=48, MinDB=−48}` 仍然得到 Pow2 曲线，不需要改子模块

**必须写入代码的约束**：`VolumeCurve::ConvertRawToScalar` 里 `if (mIsApplyingTransferFunction && (theDBRange > 30.0f))`。若未来把范围缩到 ≤30 dB，曲线会**静默退化为线性**。必须在 `VolumeControlParameters` 构造处加静态断言/注释。

### D2. HARDWARE 模式实现方式

**推荐：直接写 dB，不写 scalar，不做曲线换算。**

```
代理 scalar s
  → dB_target = 48·√s − 48        （D1 后，与代理上报完全一致）
  → clamp 到物理设备 DecibelRange
  → AudioObjectSetPropertyData(physControl,
       kAudioLevelControlPropertyDecibelValue, dB_target)
```

**依据**（本轮实测，`tools/poc/decibel_write_probe.swift`）：

- 4 台设备（含内置扬声器）的 `kAudioLevelControlPropertyDecibelValue` 全部 `settable = yes`
- 不需要 `ConvertScalarToDecibels`（内置扬声器上不可用）
- 不需要假设物理曲线形状（Apple 是 Pow2，BlackHole 是线性，各不相同）

**降级条件**：若 `DecibelValue` 不可写 → 该设备强制 `SOFTWARE`，并在 UI 标注。

**clamp 损失**：代理 −48 dB，物理 −63.5 / −64 dB，`dB_target` 恒在物理范围内，**无损失**。这是选 D1 方案 A 的额外收益（若保留 96 dB 则会在 −63.5 处截断）。

### D3. 代理设备采样率是否跟随物理设备

**建议：1.2.0 不改，记录为已知限制。**

原因：

- 改为跟随需要在 `SyncDevices` 里把采样率写进控制文件，且 driver 侧 `CreateProxyDevice` 要按设备重建；`Device` 对象的格式变更会触发 coreaudiod 的整套 IO 重配置，风险高于收益
- 双次 SRC 只在物理设备为 88.2k/96k/176.4k/192k 时出现，当前主力场景（HDMI 48k、内置 44.1k）影响有限
- 1.2.0 已承载 P0-1～P0-6，不宜再引入格式协商

**1.2.0 内的补偿**：在 `AudioEngine.setupWithDevice` 记录一条明确日志，说明当前存在双次 SRC；`PHASE2_4_REPORT.md` 中列为"已知限制"。

### D4. 协议收敛方式

**推荐：单一源 + 构建期拷贝。**

`packages/shared/include/RFSharedAudio.h` 作为唯一源，Host / Driver / App 三处由构建脚本拷贝并校验。

不使用 symlink（Xcode 打包、`git archive`、CI 缓存均可能破坏 symlink）。

不使用 SwiftPM 的 `headerSearchPath` 指向仓库外目录（`unsafeFlags` 已存在，再加路径会让包不可复用）。

**构建期校验**：在 `Makefile` 的 `build` 目标前加一步 `diff`，三份不一致则失败。CI 同样加一步。

### D5. Host 测试基础设施

**必须新增 `testTarget`。** 当前 `packages/host/Package.swift` 无 `testTarget`，Phase 2.1 要求的 10 项单测没有载体。

**设计**：把音量状态模型抽成不依赖 CoreAudio 的纯 Swift 类型（`VolumeState`、`VolumeMode`、`DeviceAudioCapabilities`），放在 `SoundBridgeHost` 内，测试通过 `@testable import` 访问。CoreAudio 交互保持不可测（或通过协议抽象注入）。

**不做**：不为 CoreAudio 引入 mock 框架。规格书要求"测试应使用可注入的状态和模拟环境"，可用轻量协议 + 手工 fake 实现。

---

## 5. 分阶段实施计划

### Phase 2.1 音量状态与共享内存基础

**目标**：建立唯一、可恢复的音量状态；协议可安全扩展；顺手修掉两个阻塞型 P0。

**改动范围**

| 文件 | 改动 |
|---|---|
| `packages/shared/include/RFSharedAudio.h`（新建） | 唯一源；修正 `_reserved` 基数；新增 `volume_mode`/`state_initialized`/`state_revision`/`underrun_frames`（占用 60 字节 reserved） |
| `packages/driver/include/RFSharedAudio.h` 等 3 处 | 改为构建期拷贝产物，不再手工维护 |
| `Makefile` + `.github/workflows/release.yml` | 拷贝 + 一致性校验步骤 |
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020000` → `0x00020100`（语义变化必须提版本） |
| `Plugin.cpp:725-756` `ValidateConnection` | 增加 `header_size == sizeof(RFSharedAudio)` 校验；不匹配时记录 error 并拒绝 |
| `Plugin.cpp:462-476` `OnStartIO` | 改为"仅在 `state_initialized == 0` 时才允许用控件值初始化共享内存"，否则保留 Host 已确定的值 |
| `Plugin.cpp:419-490` 重试循环 | `MAX_RETRIES` 15 → 2，`BASE_DELAY_MS` 30 → 50（总阻塞 17.25 s → 50 ms）；累计失败直接返回 `kAudioHardwareNotRunningError` |
| `SharedMemoryManager.swift` | 初始化时写 `state_revision = 1`、`state_initialized = 0`；扩展字段写入顺序固定 |
| 新增 `VolumeState.swift` | 纯数据模型：`requested_scalar` / `applied_gain` / `is_muted` / `mode` / `revision` / `initialized` |
| `packages/host/Package.swift` | 新增 `testTarget: SoundBridgeHostTests` |

**初始化优先级（必须实现为显式函数，不能靠调用顺序隐式保证）**

```
1. 用户持久化配置（VolumePersistence.load）
2. 已完成初始化的 Host 运行时状态（state_initialized == 1）
3. 安全默认值（0.35，与现有 defaultVolume 一致）
```

**新增单元测试（10 项，对应规格书 §6.5）**

1. 默认状态初始化
2. 持久化音量恢复
3. IO 启动不覆盖音量
4. IO 重启保持音量
5. Host 重启恢复
6. Driver/Host 协议版本一致
7. 协议版本不一致
8. `struct_size` 不一致
9. 未初始化状态不被当作有效音量
10. `state_revision` 单调递增

**验收条件**

- 三份头文件由构建脚本生成，`md5` 一致
- `sizeof(RFSharedAudio)` 变化被显式记录，`header_size` 校验生效
- `OnStartIO` 不再无条件覆盖（用 `state_initialized` 判定）
- 上述 10 项单测通过
- DSP / Driver / Host / App 全部构建通过
- HDMI / DisplayPort 现有链路未被破坏（回归：Host 启动后默认输出切到代理，音频不中断）

**回滚**：`git revert` 单个 commit。协议版本号变更会使新旧 driver/host 互相拒绝连接（`ValidateConnection` 精确匹配），因此必须同批发布；回滚时 driver 与 host 必须一起回滚。

---

### Phase 2.2 音量控制架构

**目标**：单一音量路径、模式互斥、曲线统一（D1）、Mute 平滑。

**改动范围**

| 文件 | 改动 |
|---|---|
| `Plugin.cpp:1064-1065` | `aspl::VolumeControlParameters{}` → `{MinRaw=0, MaxRaw=48, MinDB=−48, MaxDB=0}`，附"dB range 必须 > 30"注释 |
| `AudioRenderer.swift:178` | `powf(10, (s−1)·48/20)` → `powf(10, (48·sqrt(s) − 48)/20)` |
| `AudioRenderer.swift:20` | `smoothingCoeff` 按 8–10 ms 重新标定：τ=9 ms @48k → `coeff = exp(−1/(0.009·48000)) ≈ 0.99769` |
| `AudioRenderer.swift:176-203` | Mute 改为"目标增益 0 + 平滑淡出"，移除硬切分支；unmute 从当前值平滑上升 |
| 新增 `VolumeMode.swift` | `enum VolumeMode { case software, hardware }` |
| 新增 `DeviceAudioCapabilities.swift` | `hasVolumeControl` / `volumeWritable` / `decibelWritable` / `hasMuteControl` / `validationLevel` |
| 新增 `VolumePolicy.swift` | 模式选择器：能力不足 → `software`；含断言 `hardware ⇒ softwareGain == 1.0` |
| `ProxyDeviceManager.swift:755-776` | `forwardProxyVolumeToPhysical` 仅在 `mode == .hardware` 时执行；`software` 模式直接 `assertionFailure` |
| `ProxyDeviceManager.swift:219-226` | `autoSelectProxy` 里的"物理→代理"同步，改为只读取**初始值**，且不覆盖已持久化的用户值 |
| `Constants.swift:27-31` | 修正注释：删除"16 steps × 3 dB"的错误描述，改为说明 Pow2 曲线与 `dB range` 约束 |
| `VolumeController.swift:644` | 能力判定统一为 `HasProperty` + `IsPropertySettable`，与 `DeviceDiscovery` 对齐 |
| `VolumeController.swift:140` | 移除 `isFixedVolumeDevice = true` 硬编码，改为按物理设备能力实测 |
| 新增 `tools/diag/volume_trace.swift` | 记录 9 项：代理 scalar / requested / applied_gain / physical volume / mode / mute / revision / 事件来源 / 时间戳 |

**新增断言与测试**

- `assert(mode == .hardware → appliedGain == 1.0)`
- `assert(mode == .software → 未调用 setDeviceVolume)`
- 事件回路检测：连续 3 次同值写入视为回路，记录 error

**验收条件**

- SOFTWARE 模式不写物理设备音量（用 `volume_trace` 证明 `physical volume` 在 SOFTWARE 下不变）
- HARDWARE 模式 `applied_gain` 恒为 1.0
- 代理 dB 与 Host 增益在 6 个锚点（1.00/0.75/0.50/0.30/0.10/0.05）上差 < 0.5 dB
- 无无限事件回路（`volume_trace` 连续 5 分钟无重复写入）
- Mute/Unmute 平滑（波形上无阶跃；听感 L6 待人工）
- IO 重启、设备切换后音量一致
- **尚未实机验证项必须显式标注**

**回滚**：`git revert`。注意 driver 参数变化会改变代理的 dB 上报，回滚后 App 显示会回到 −96…0 语义。

---

### Phase 2.3 全设备 EQ 接入

**目标**：放开过滤，但按设备类型分类，不做无条件放开。

**改动范围**

| 文件 | 改动 |
|---|---|
| `DeviceDiscovery.swift:114-121` | 移除"有可写 scalar 就跳过"；改为 `DeviceCategory` 分类函数 |
| 新增 `DeviceCategory` | `.builtIn` / `.usb` / `.hdmi` / `.displayPort` / `.bluetooth` / `.airPlay` / `.virtual` / `.aggregate` / `.unknown`，各带 `proxyable: Bool` |
| 新增 `DeviceFilter.swift` | 规则集中：排除 SoundBridge 自身、BlackHole 等已知虚拟设备、Aggregate；其余按 category 决定 |
| 新增 `DeviceRegistry.swift`（或扩展现有） | 每设备记录 UID / name / transport / sampleRate / channels / format / volumeCapabilities / mode / EQ 配置 / 连接状态 |
| `DeviceRegistry` 更新机制 | 设备拔出时同步移除条目，控制文件与 registry 原子一致 |
| `BasicEQView.swift` | 3 段 → 10 段 |
| 新增 `EqualizerSettingsView.swift` | 10 段独立调节、启用/禁用、预设、恢复默认、每设备独立保存 |
| 新增 `EQPreset.swift` | 预设模型与持久化（按 `physicalUID` 索引） |

**验收条件**

- 内置扬声器可以进入代理链路（控制文件出现其 UID）
- HDMI / DisplayPort 行为不退化
- 拔插时列表正确更新，无残留条目
- 不代理 SoundBridge 自身设备，无发现循环
- 每台设备可独立保存 EQ，切换后恢复
- 10 段参数正确传入 DSP（用 `soundbridge_dsp_*` 回读验证）
- **USB DAC / AirPods 未实测，保持 NOT TESTED**

**回滚**：`git revert`。放开过滤是行为变更，回滚后内置扬声器重新被排除。

---

### Phase 2.4 实时音频与格式兼容

**目标**：实时回调无意外分配；采样率/格式变化可感知并安全重建。

**改动范围**

| 文件 | 改动 |
|---|---|
| `AudioRenderer.swift:106-114` | 预分配固定最大工作区（`4096 × 8`），不再在回调中 `[Float](repeating:…)`；清零改为只清 `framesRead × channels` |
| `AudioRenderer.swift:133` | `rf_ring_read(mem, &tempBuffer, …)` 改为 `withUnsafeMutableBufferPointer` 取基址后传入，避免隐式桥接 |
| `DeviceMonitor.swift:49-90` | 增加 `kAudioDevicePropertyNominalSampleRate`、`kAudioDevicePropertyStreamConfiguration`、`kAudioDevicePropertyDeviceIsAlive` 监听 |
| `AudioEngine.swift:99-125` | 格式变化走"停止 → 重建 → 恢复"的显式路径，不在回调内重建 |
| `RFSharedAudio.h` | 新增 `underrun_frames`（P1-9） |
| DSP | 新增 SRC 基准测试（音质/成本/延迟/混叠），**先测再决定是否替换** |
| 新增 `docs/1.2.0/SRC_BENCHMARK.md` | 基准结果 |

**验收条件**

- Instruments（Time Profiler + Allocations）证明 render 回调稳态无 malloc
- 采样率变化能被识别并触发重建（手动在 Audio MIDI Setup 改采样率验证）
- 格式变化后音频恢复，无静音
- SRC 基准测试完成，有明确结论（保留或替换）
- EQ 不产生不可接受削波（用满增益 + 0 dBFS 扫频验证）
- underrun/overrun 有可比较口径（`underrun_count/callback_count` 与 `underrun_frames/total_frames`）

**回滚**：分别 revert。实时性改动与格式监听互相独立。

---

### Phase 2.5 设备生命周期与稳定性

**目标**：解决 P0-4 / P0-6，明确状态机，消除残留。

**改动范围**

| 文件 | 改动 |
|---|---|
| `main.swift:288-301` | 删除 `restartCoreAudio()`（无效） |
| `main.swift:265-286` `cleanup()` | 改为：写"host 已停止"标记 → unlink 控制文件 → Darwin notify → unlink 共享内存 → 等待 driver 收敛（轮询 `driver_connected == 0`，最多 1.5 s） |
| `Plugin.cpp:1024-1040` | `SoundBridgeGlobalState` 增加 `session_id`、`host_pid`、`host_start_time` |
| `Plugin.cpp:1144-1187` `HostHeartbeatFresh` | 增加 PID/启动时间校验，避免 PID 重用误判 |
| `Plugin.cpp:1189-1229` `SyncDevices` | 移除设备后主动重试 `NotifyPropertiesChanged`（间隔 100/300/700 ms），并记录 coreaudiod 是否收敛 |
| 新增 driver 侧孤儿检测 | 控制文件不存在 + 所有 heartbeat 陈旧 → 主动 `RemoveDevice` 全部代理，并把状态写日志 |
| `SoundBridgeApp.swift:756-767` | Host 退出处理：区分离线类型（正常/崩溃/启动失败），最多重启 3 次，指数退避，失败后 UI 明确提示 |
| 新增 `HostSupervisor.swift` | 重启策略与状态上报 |
| `SettingsWindow.swift` | 增加"诊断"分区（版本、协议版本、设备列表、残留检测、导出日志） |

**需要先调研的问题（不能直接改代码）**

1. `Plugin::RemoveDevice` 已调用 `NotifyPropertiesChanged`，但 HAL 客户端仍枚举到设备 → coreaudiod 的收敛条件是什么？是否需要 `DestroyDevice` 而非仅从列表移除？
2. `driver_connected` / `host_connected` 的语义边界：谁写、何时清、陈旧值如何判定
3. `coreaudiod` 重启后的设备恢复行为（需人工配合重启）
4. 睡眠唤醒后 `AudioObjectAddPropertyListener` 失效的处理（现有 `reregisterVolumeForwarding` 是否足够）

**验收条件**

- Host 正常退出不留下代理设备（HAL 客户端枚举为空）
- Host `kill -9` 后，15 s 内代理设备从 HAL 列表消失（这是当前未达到的目标）
- 不误删其他实例资源
- Host 崩溃后 App 有明确 UI 反馈，重启有次数上限
- 睡眠唤醒后音频链路自动恢复
- 设备切换稳定

**回滚**：`git revert`。`cleanup()` 简化后回滚风险低。

---

## 6. 文件修改计划总表

| 文件 | 2.1 | 2.2 | 2.3 | 2.4 | 2.5 |
|---|:-:|:-:|:-:|:-:|:-:|
| `packages/shared/include/RFSharedAudio.h`（新建） | ● | | | ● | |
| `packages/driver/include/RFSharedAudio.h` | ● | | | ● | |
| `packages/host/.../RFSharedAudio.h` | ● | | | ● | |
| `apps/mac/.../RFSharedAudio.h` | ● | | | ● | |
| `Makefile` / `release.yml` | ● | | | | |
| `packages/driver/src/Plugin.cpp` | ● | ● | | | ● |
| `packages/host/Package.swift` | ● | | | | |
| `VolumeState.swift`（新） | ● | ● | | | |
| `VolumeMode.swift`（新） | | ● | | | |
| `DeviceAudioCapabilities.swift`（新） | | ● | ● | | |
| `VolumePolicy.swift`（新） | | ● | | | |
| `AudioRenderer.swift` | | ● | | ● | |
| `ProxyDeviceManager.swift` | | ● | ● | | |
| `Constants.swift` | | ● | | | |
| `VolumeController.swift` | | ● | ● | | |
| `DeviceDiscovery.swift` | | | ● | | |
| `DeviceFilter.swift`（新） | | | ● | | |
| `DeviceRegistry.swift` | | | ● | | |
| `BasicEQView.swift` | | | ● | | |
| `EqualizerSettingsView.swift`（新） | | | ● | | |
| `EQPreset.swift`（新） | | | ● | | |
| `DeviceMonitor.swift` | | | | ● | ● |
| `AudioEngine.swift` | | | | ● | |
| `main.swift` | | | | | ● |
| `SoundBridgeApp.swift` | | | | | ● |
| `HostSupervisor.swift`（新） | | | | | ● |
| `SettingsWindow.swift` | | | | | ● |
| `CHANGELOG.md` / `README.md` | | | | | ● |

---

## 7. 测试与验证矩阵

### 7.1 验证等级

| 级别 | 含义 | 1.2.0 中的用途 |
|---|---|---|
| L1 | 静态源码分析 | 逻辑复核、路径确认 |
| L2 | 单元测试 | 状态模型、协议校验、模式互斥 |
| L3 | Mock CoreAudio | 能力模型、降级路径 |
| L4 | 真实 CoreAudio 属性测试 | 能力探测、dB 可写性（本轮已完成） |
| L5 | 真实设备行为验证 | 音量写入生效、设备拔插、IO 重启 |
| L6 | 人工听感验证 | Mute pop、EQ 音质、SRC 音质 |

### 7.2 各阶段覆盖

| 能力 | 2.1 | 2.2 | 2.3 | 2.4 | 2.5 |
|---|---|---|---|---|---|
| 协议版本/大小校验 | L2 | | | | |
| 音量状态机 | L2 | L2 | | | |
| 曲线一致性 | L2 | L2 + **L4** | | | |
| 模式互斥 | | L2 + L3 | | | L5 |
| dB 直写物理设备 | | **L4** + L5 | | | |
| Mute 平滑 | | L2 | | | **L6** |
| 设备过滤 | | | L2 + **L5** | | |
| 10 段 EQ | | | L2 + L5 | | **L6** |
| 实时无分配 | | | | L1 + Instruments | |
| 采样率变化 | | | | L2 + **L5** | |
| 设备残留 | | | | | **L5** |
| Host 崩溃恢复 | | | | | L5 |

### 7.3 当前不可执行的验证

| 项目 | 原因 |
|---|---|
| USB DAC 全链路 | 设备未连接 → **NOT TESTED** |
| AirPods / 蓝牙全链路 | 设备未连接 → **NOT TESTED** |
| 音量键归属 | 需重装驱动 + 重启 coreaudiod + 切默认输出（需用户授权） |
| 听感类（pop / 响度 / 音质） | 需人工 |
| 睡眠唤醒 | 需人工 |
| coreaudiod 重启后的恢复 | 需人工 |

---

## 8. 回滚策略

| 场景 | 方式 | 注意 |
|---|---|---|
| 单阶段代码回滚 | `git revert <commit>` | 每个 Phase 一个 commit |
| 协议不兼容回滚 | driver + host 必须**同批**回滚 | `ValidateConnection` 精确匹配版本号，新旧混用会拒绝连接并导致无声 |
| 驱动回滚（用户侧） | `tools/uninstall_driver.sh` + 重装旧版 | 需重启 coreaudiod |
| 设备过滤回滚 | revert 2.3 | 内置扬声器重新被排除 |
| 曲线回滚 | revert 2.2 | App 显示回到 −96…0 语义 |
| 数据库/配置回滚 | `VolumePersistence` 新增 key 加默认值，旧版本读到未知 key 忽略 | 不做破坏性迁移 |

**不可逆操作清单**（不在 1.2.0 内执行）：修改 `RF_AUDIO_PROTOCOL_VERSION` 后的正式发布、删除旧协议兼容分支、修改 `libASPL` 子模块。

---

## 9. 需要人工确认的决策

| ID | 决策 | 推荐 | 影响 |
|---|---|---|---|
| **Q1** | 音量曲线统一方案选 A / B / C | **A**（48 dB Pow2） | 决定 issue #9 的修复方式与用户听感 |
| **Q2** | HARDWARE 模式是否采用"直接写 dB" | **是** | 若否，需要逐设备曲线适配，工作量翻倍且内置扬声器仍需降级 |
| **Q3** | 1.2.0 是否允许改 driver 的 `VolumeControlParameters` | **是** | 否则只能走方案 B/C |
| **Q4** | 是否接受 1.2.0 存在"双次 SRC"（物理 96k 时） | **接受，记为已知限制** | 若否，2.4 需追加格式协商，范围显著扩大 |
| **Q5** | 是否允许在开发期重装 1.1.3 驱动（需 sudo + 重启 coreaudiod） | **需要授权** | 否则 P0-4 与音量键归属无法验证 |
| **Q6** | Phase 2.5 是否允许 `kill -9` Host 做崩溃测试 | **需要授权** | 否则"异常退出残留"只能靠代码推断 |
| **Q7** | Host 测试基础设施放在 2.1 还是单独立项 | **放 2.1**（阻塞项） | 若否，2.1 的 10 项单测无法落地 |
| **Q8** | 1.2.0 是否包含 10 段 EQ UI | **包含**（规格书 P1） | 若否，2.3 范围缩小，版本可提前 |

---

## 10. 需要人工实机验证的内容

以下是代码无法自证的项，需在具备条件时由人工执行并回报。

### 10.1 前置条件（会中断音频）

```bash
# 1) 构建并安装 1.1.3+ 驱动（需管理员密码，会重启 coreaudiod）
cd /path/to/SoundBridge
make sign
sudo cp -R packages/driver/build/SoundBridgeDriver.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod

# 2) 启动 Host
cd packages/host && ./.build/release/SoundBridgeHost
```

### 10.2 验证项

| # | 验证内容 | 方法 | 达标标准 |
|---|---|---|---|
| V1 | 音量键作用于哪个对象 | 按音量键，同时抓 `/tmp/rf_header_probe` 与 `audio_probe.swift` | 能明确写出"代理 scalar 变化，物理设备是否变化" |
| V2 | IO 重启是否跳音量 | 音量拉到 0.2，触发一次 IO 重启，抓快照 | 与 `POC_ERRATA.md` M1 描述一致 |
| V3 | Mute/Unmute 是否有 pop | 人工听 | 无可闻 pop |
| V4 | Host 崩溃后设备残留 | `kill -9` Host，等 20 s，枚举设备 | 代理设备从 HAL 列表消失 |
| V5 | 内置扬声器进入代理后音质 | 人工听 | 与直连无可辨差异（EQ 关闭时） |
| V6 | 采样率切换 | Audio MIDI Setup 改物理设备采样率 | 音频恢复，无静音 |
| V7 | 睡眠唤醒 | 合盖 30 s 后唤醒 | 音频自动恢复 |
| V8 | HARDWARE 模式下 dB 写入生效 | 必须**人工听感 + 硬件音量指示**确认 | 不能只看 API 返回 |

### 10.3 本轮已完成（无需重复）

| 项目 | 结果 | 等级 |
|---|---|---|
| 设备 scalar 可读写矩阵 | 4 台设备实测 | L4 |
| 设备 dB 属性可写性 | 全部可写 | L4 |
| 曲线形状反解 | 代理/内置 = Pow2，BlackHole = 线性 | L4 |
| `OnStartIO` 覆盖 | 日志实证 | L5 |
| driver 侧设备移除逻辑 | `desired=0 current=0` | L5 |
| `killall coreaudiod` 权限 | 必然失败 | L5 |
| 协议布局 | 264 字节，字段偏移已确认 | L1 |

---

## 11. 建议的提交计划

```
Phase 2.1  fix(audio): unify volume state and shared memory protocol
Phase 2.2  refactor(audio): introduce mutually exclusive volume control modes
Phase 2.3  feat(eq): enable EQ for supported physical audio devices
Phase 2.4  perf(audio): improve real-time rendering and format handling
Phase 2.5  fix(audio): improve host lifecycle and device recovery
```

**每个 commit 前必须执行**

```bash
git diff --check
git status
git diff --stat
git diff
```

**不提交**：`build/`、`.build/`、`/tmp/soundbridge-*`、`tools/poc/` 产生的二进制、任何设备序列号。

**不自动执行**：`git push`、创建 Release、修改版本号。

---

## 12. 风险登记

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 协议版本变更后新旧 driver/host 混用 → 无声 | 高 | 高 | 同批发布；App 启动时比对驱动版本，不一致阻止进入音频路径并提示重装 |
| `VolumeControlParameters` 改动导致代理 dB 上报变化，用户感知音量变小 | 中 | 中 | 选方案 A 保持 48 dB 总衰减，与现状一致 |
| 放开过滤后双重衰减未完全消除 | 中 | 高 | 2.2 的模式互斥先行；2.3 验收前用 `volume_trace` 逐设备验证 |
| coreaudiod 列表收敛无法在 1.2.0 解决 | 中 | 中 | 降级为"App 启动时检测孤儿并提示重启 coreaudiod"，并在 `PHASE2_5_REPORT.md` 显式记录未解决 |
| 内置扬声器进入代理后音质下降（双次 SRC） | 中 | 中 | EQ 关闭时走 bit-perfect 直通路径（现有逻辑已支持 `targetGain==1.0`），并记录已知限制 |
| `libASPL` 子模块被误改 | 低 | 高 | 显式禁止；如必须改，fork 并固定 commit |
| 无 Host 单测导致回归 | 高 | 中 | 2.1 先建 testTarget；CI 增加测试步骤 |

---

## 13. 本阶段产出物

| 文件 | 内容 |
|---|---|
| `docs/1.2.0/PHASE2_IMPLEMENTATION_PLAN.md` | 本文件 |
| `docs/1.2.0/POC_ERRATA.md` | PoC 报告勘误与增量实证 |
| `tools/poc/decibel_write_probe.swift` | dB 可写性只读探针 |

**未修改任何生产代码。**

---

## 14. 下一步

本阶段结束，等待确认。

Phase 2.1 开始前需要：

1. 确认 §9 的 Q1–Q8
2. 决定是否建立 Host `testTarget`（Q7）
3. 决定是否授权 V1/V2/V4 的实机验证（Q5/Q6）
