# POC_REPORT.md 勘误与增量实证

- 日期：2026-11-16
- 基线：`main` @ `0574414`（tag `1.1.3`）
- 范围：对 `POC_REPORT.md` 逐条复核，标注错误、过度推断与遗漏
- 新增工具：`tools/poc/decibel_write_probe.swift`（只读）

本文件不替代 `POC_REPORT.md`，只修正其中不可靠的部分。凡未在本文件列出的条目，视为复核通过。

---

## 1. 结论层面的错误

### E1. "内置扬声器只能降级 SOFTWARE" —— 错误

**原文**（§3.3）：

> Apple 内置扬声器的 `ConvertScalarToDecibels` 实测返回恒定 -63.5（不可用），所以**内置扬声器只能走 A3 的降级分支或 A1**。这是本报告最重要的技术约束。

**复核结果**：结论不成立。`ConvertScalarToDecibels` 不可用只说明"不能做正向 scalar→dB 任意换算"，它并不是 HARDWARE 模式的必要条件。

`kAudioLevelControlPropertyDecibelValue` 是另一个属性，实测**全部设备可写**（见 §2.1）。因此 HARDWARE 模式可以：

1. 代理 scalar → `dB_target = 48·√s − 48`（已知公式，无需 API）
2. 直接写物理设备的 `kAudioLevelControlPropertyDecibelValue`
3. 由 HAL 自己用设备曲线把 dB 换算回该设备的 scalar

这条路径完全绕过 `ConvertScalarToDecibels`，也完全绕过"逐设备适配曲线"。原文遗漏了它，导致把可行方案判定为不可行。

**影响等级**：高。该错误会直接导致 HARDWARE 模式被错误地排除或过度复杂化。

---

### E2. "SOFTWARE 语义正确（自洽）" —— 自相矛盾

**原文**（§3.4）：

| 模式 | API 层 | 语义正确性 | 判定 |
|---|---|---|---|
| SOFTWARE（现状） | 可行 | 正确（自洽） | **可行，保留** |

**复核结果**：同一份报告的 §3.2 已经证明 SOFTWARE 模式下"系统显示 dB"与"实际增益 dB"在 scalar=0.05 时相差 28.93 dB。既然两者不一致，就不能称为"自洽"。

这正是 issue #9 的根因，而不是一个"正确但保留"的实现。原文的 §3.2 与 §3.4 必须择一。

**正确表述**：SOFTWARE 的**控制流**是自洽的（只有一个增益来源），但**曲线映射**不自洽（UI dB ≠ 实际 dB）。

---

### E3. "同 scalar 下响度差可达 5–35 dB" —— 数值错误

**原文**（§0 结论摘要）：

> 同 scalar 下响度差可达 5–35 dB

**复核结果**：按 `96·√s − 96` 与 `48·(s−1)` 计算，偏差为：

| scalar | 1.00 | 0.75 | 0.50 | 0.30 | 0.10 | 0.05 |
|---|---:|---:|---:|---:|---:|---:|
| 偏差 (dB) | 0.00 | −0.86 | −4.12 | −9.82 | −22.44 | −28.93 |

在可操作区间 `s ∈ [0.05, 1.0]` 内，偏差范围是 **0 ～ −28.93 dB**。"5–35 dB" 的两个端点都没有依据。

只有把 `s` 外推到 0.01 才会出现约 −38.9 dB，而该区间用户几乎不会停留。

**正确表述**：同 scalar 下，系统显示的 dB 比实际增益高 0 ～ 29 dB。

---

## 2. 事实层面的补充

### 2.1 新增实测：dB 属性可写性（本轮新增证据）

工具：`tools/poc/decibel_write_probe.swift`（只查 `HasProperty` / `IsPropertySettable` / `DecibelRange`，**不写入任何属性**）

实测输出（Host 未运行，本机现状）：

| 设备 | control | dB range | 当前 dB | 当前 scalar | dB 可写 | scalar 可写 |
|---|---|---:|---:|---:|---|---|
| LG ULTRAGEAR+ (SoundBridge) | 146 | −96.0 … 0.0 | −27.00 | 0.5166 | **yes** | yes |
| PHL 279M1RV (SoundBridge) | 141 | −96.0 … 0.0 | 0.00 | 1.0000 | **yes** | yes |
| BlackHole 16ch | 76, 78 | −64.0 … 0.0 | −55.45 | 0.1337 | **yes** | yes |
| Mac mini扬声器 | 97 | −63.5 … 0.0 | −22.85 | 0.4098 | **yes** | yes |

**结论**：`kAudioLevelControlPropertyDecibelValue` 在本机全部 4 台设备上均可写，包括 `ConvertScalarToDecibels` 不可用的内置扬声器。

---

### 2.2 新增实测：设备曲线族其实高度一致

原文只比较了"代理 vs 内置扬声器"，未识别出规律。用实测锚点反解：

| 设备 | dB range | scalar | 实测 dB | 假设 Pow2 反算 | 误差 |
|---|---|---:|---:|---:|---:|
| LG 代理 | −96…0 | 0.5166 | −27.00 | 96·0.71875 − 96 = −27.00 | 0.00 |
| Mac mini扬声器 | −63.5…0 | 0.4098 | −22.85 | 63.5·0.64016 − 63.5 = −22.85 | 0.00 |
| BlackHole 16ch | −64…0 | 0.1337 | −55.45 | Pow2 预测 −40.6（**不符**） | — |
| BlackHole 16ch | −64…0 | 0.1337 | −55.45 | 线性预测 −64·(1−0.1337) = −55.44 | 0.01 |

**结论**：

- Apple 原生设备与 libASPL 代理设备使用**同一条 Pow2Over1 曲线**，差异只在 dB range（96 / 63.5）。
- BlackHole（第三方 aspl 实现）使用**线性 dB 曲线**。
- 所以"曲线不等价"的准确描述是"**曲线形状可能不同、range 一定不同**"，不能简化为"shape 相同、range 不同"，也不能反过来。

**这条发现的意义**：任何"统一公式换算法"都必须先逐设备验证曲线形状，而"直接写 dB"方案不需要知道形状。这进一步支持 E1 的结论。

---

### 2.3 新增实证：OnStartIO 覆盖由"推断"升级为"实测"

原文 §7.2 把 OnStartIO 覆盖列为"由代码推断（未运行时验证）"。本轮在 driver 的调试日志中找到直接证据。

来源：`/tmp/soundbridge-driver-debug.log`（201 行，属主 `_coreaudiod`，1.1.2 驱动写入）

```
OnStartIO() client #1 (state: Disconnected)
OnStartIO: Connected on attempt 1 (uid=1E6D4678-...)
OnStartIO: synced VolumeControl value=0.517
OnStartIO() client #1 (state: Disconnected)
OnStartIO: synced VolumeControl value=0.517
OnStartIO() client #1 (state: Uninitialized)          ← 控件被重建
OnStartIO: synced VolumeControl value=1.000           ← 音量被抬到 100%
SoundBridgeVolumeControl: volume changed to 0.517 (raw=69)   ← Host 随后回写
```

**结论**：当 `VolumeControl` 被重建（`state: Uninitialized`）时，`rawVolume_` 回到 `MaxRawVolume`，`OnStartIO` 把 `scalar = 1.0` 写入共享内存。存在一个"突然全音量"的窗口，随后由 Host 回写修复。

**验证等级**：L5（真实设备、真实日志、真实时序）。

**修正**：原文"IO 重启可把音量从持久化值抬升到 1.0"的表述应改为"**控件重建时**必然抬升到 1.0；控件未重建时不会"。

---

### 2.4 补充：`volume_scalar` 初值与代理控件初值不是同一个数

原文 §3.4 并列了"代理 scalar = 1.0000 / Shared Memory = 0.350000 / 无持久化记录"，但未指出这三个数的来源差异：

| 值 | 来源 | 初始化位置 |
|---|---|---|
| 1.0 | `aspl::VolumeControl::rawVolume_(params_.MaxRawVolume)` | libASPL `VolumeControl.cpp:19` |
| 0.35 | `atomic_init(&mem->volume_scalar, 0.35f)` | `RFSharedAudio.h:206` |
| 0.35 | `VolumePersistence.defaultVolume` | `VolumePersistence.swift:19` |

三者分属三个进程/三个生命周期。这不是"矛盾"，而是**三个独立权威源**的必然结果。原文称之为"状态矛盾"容易误导为偶发 bug，实际是结构性问题。

---

## 3. 描述不准确但不影响结论的条目

### E4. 实时回调"存在动态内存分配" —— 条件成立，非每帧

**原文 §3.6 / §7.1**：`AudioRenderer.render()` 存在实时回调中的动态内存分配风险。

**复核**（`AudioRenderer.swift:106-114`）：

```swift
if tempBuffer.count < needed {
    tempBuffer = [Float](repeating: 0, count: needed)   // 仅扩容时分配
} else {
    for i in 0..<needed { tempBuffer[i] = 0 }           // 稳态：O(n) 清零，不分配
}
```

**修正**：稳态下不分配，仅在回调帧数超过历史最大值时分配一次。真正的实时风险是：

1. 每帧 O(n) 全量清零（可改为按写入长度清零）
2. `rf_ring_read(mem, &tempBuffer, ...)` 把 `inout [Float]` 隐式桥接为 `float*`，会触发数组独占性检查
3. `tempBuffer.withUnsafeMutableBufferPointer` 同样有独占性检查

这些都需要 Instruments 实测才能定性，原文的"动态分配"是过度归因。

---

### E5. `smoothingCoeff = 0.995` 不是 10 ms

**原文**（未明说，但代码注释声称）：`// ~10ms at 48kHz`

**复核**：一阶低通时间常数 `τ = 1/(1−0.995) = 200 samples`，48 kHz 下为 **4.17 ms**，不是 10 ms。

规格书要求 8–10 ms 淡入淡出，因此该系数本身也不满足要求。Phase 2.2 需要重新标定。

---

### E6. `underrun 0.13%` 的计算口径未定义

**原文 §7.5**：`underrun_count = 1013` / `frames_read = 749568`（约 0.13%）。

**复核**：分子是"事件次数"，分母是"帧数"，两者量纲不同，相除得到的比值没有物理意义。它既不是"丢帧比例"也不是"回调失败率"。

**修正**：应分别报告 `underrun_count / io_callback_count`（失败回调占比）与 `underrun_frames / total_frames`（丢帧占比）。当前协议只记录 `underrun_count`，**没有 underrun_frames 字段**，所以丢帧占比无法计算。这是 Phase 2.4 需要补的统计字段。

---

## 4. 架构层面的遗漏

### M1. OnStartIO 重试会阻塞 17 秒（新发现）

`Plugin.cpp:419-490`：

```
MAX_RETRIES = 15, BASE_DELAY_MS = 30
delay = 30ms × 2^min(attempt-1, 6)
```

累计退避：30 + 60 + 120 + 240 + 480 + 960 + 1920×8 = **17 250 ms**

当 Host 未运行、共享内存文件缺失时，任何 App 调用 `start IO` 都会在 HAL 内阻塞约 **17 秒**。

原文把"僵尸设备"仅描述为"用户可选中一个无音频消费者的设备"，没有指出选中后的实际后果是**播放器卡死**。这是 1.2.0 必须先解决的问题，优先级高于"设备列表是否干净"。

---

### M2. `restartCoreAudio()` 必然失败（新发现）

`main.swift:288-301` 在 Host 退出时执行 `/usr/bin/killall coreaudiod`。

**实测**：

```
$ ps -o user,pid,comm -p <coreaudiod pid>
USER          PID COMM
_coreaudiod   777 /usr/sbin/coreaudiod
$ whoami
USER
```

`coreaudiod` 属主为 `_coreaudiod`，当前用户无权限发信号。该调用必然返回非 0，日志会记录 `Restarted coreaudiod (status 1)` 但不影响任何状态。

**后果**：代码里"退出时清理僵尸设备"的兜底机制**从未生效过**。

---

### M3. "僵尸代理设备"的准确机制（修正原文 §7.5）

原文给出的解释是"Host 退出后代理设备仍存在"。本轮用 unified log 找到更准确的机制。

驱动日志（`log show --predicate 'subsystem == "com.soundbridge.driver"' --last 8h --info`，每秒一条）：

```
SyncDevices: skipping stale entry uid=<private> (no host heartbeat)
SyncDevices: desired=0 current=0
```

**关键点**：

1. `desired=0 current=0` —— driver **内部已经没有该设备**，移除逻辑工作正常
2. 同时 `decibel_write_probe` 仍枚举到 "LG ULTRAGEAR+ (SoundBridge)" 与 "PHL 279M1RV (SoundBridge)"

**所以僵尸设备的根因不是"driver 没移除"，而是"driver 移除了，但 coreaudiod 仍向 HAL 客户端报告该设备对象"。**

`libASPL` 的 `Plugin::RemoveDevice()` 确实调用了
`NotifyPropertiesChanged({kAudioObjectPropertyOwnedObjects, kAudioPlugInPropertyDeviceList})`
（`vendor/libASPL/src/Plugin.cpp:204`），通知已发出，但 coreaudiod 的缓存没有收敛。

这是 Phase 2.5 的核心调查对象。原文"用户可选中一个无音频消费者的设备"的描述方向对，但归因错了。

---

### M4. 代理固定 48 kHz / 2 ch 与物理采样率解耦，会产生双次 SRC（新发现）

- `Plugin.cpp:1051-1052`：代理设备 `SampleRate = 48000`、`ChannelCount = 2`，硬编码
- `SharedMemoryManager.swift:48`：共享内存用 `SoundBridgeConfig.activeSampleRate`，即**物理设备**的采样率

当物理设备为 96 kHz 时，链路变为：

```
App → 代理 48k → driver SRC 48→96 → ring(96k) → Host 96k → 物理 96k
```

App 侧由 coreaudiod 先把 44.1k 重采样到 48k，driver 再重采样到 96k，**两次 SRC 串联**。

放开内置扬声器（44.1 kHz）与蓝牙设备后，这个问题会从"少见"变成"常见"。原文未涉及。

---

### M5. 协议头里的 `256` 常量是错的（新发现）

`RFSharedAudio.h:115`：

```c
uint8_t _reserved[256 - 148 - sizeof(RFEQSnapshot)];   // 60 bytes
```

按实际字段偏移重算：

| 字段 | offset | size |
|---|---:|---:|
| `volume_scalar` | 144 | 4 |
| `mute_state` | 148 | 4 |
| `eq_sequence` | 152 | 4 |
| `eq_snapshot` | **156** | 48 |
| `_reserved` | 204 | 60 |
| **sizeof** | | **264** |

`eq_snapshot` 的实际偏移是 **156**，不是 148。按注释意图（header = 256）应为 `256 − 156 − 48 = 52` 字节。

当前表达式让 header 变成 264 而不是 256，**注释与实现差 8 字节**。虽然 `sizeof` 与实际 mmap 大小一致（`rf_shared_audio_size()` 用 `sizeof`），运行时不会崩，但：

- Phase 2.1 要往 `_reserved` 里塞新字段，必须先修这个基数
- 否则迁移时会算错剩余空间

原文只说"reserved = 60 字节"，没有发现这个基数错误。

---

### M6. `header_size` 从未被校验（新发现）

`ValidateConnection()`（`Plugin.cpp:725-756`）只检查：

1. `protocol_version != RF_AUDIO_PROTOCOL_VERSION` → 拒绝
2. `rf_is_sample_rate_supported(sample_rate)` → 拒绝
3. `channels == 0 || channels > RF_MAX_CHANNELS` → 拒绝

**没有检查 `header_size`**，也没有检查 `bytes_per_frame` / `format`。

原文 §6.2 称"有 `header_size` 字段用于运行时校验"，这是**不成立的**。该字段目前是死字段。

**后果**：Phase 2.1 若只扩字段不改版本号，老 driver 会接受新 host 的内存布局，产生静默错位。

---

## 5. 环境事实的更新

| 项 | 原文 | 现状（本轮复核） |
|---|---|---|
| 已装驱动 | 1.1.2（2026-03-19） | 仍为 1.1.2，`/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` |
| Host 运行状态 | 未运行 | 仍未运行（`pgrep -x SoundBridgeHost` 无结果） |
| `/tmp` 残留 | 存在 | 仍存在，时间戳 `Nov 16 16:39`，未变 |
| 三份 `RFSharedAudio.h` | 需同步 | **MD5 完全相同**（`d30af007730df2651900d959f0dbb60c`），当前无差异 |
| 其他已装 HAL 驱动 | 未记录 | BlackHole16ch、ParrotAudioPlugin、eqMac 同时存在 |

---

## 6. 复核通过、无需修改的条目

以下结论本轮独立复核后确认成立：

- 代理设备 dB range = −96…0，1 raw = 1 dB，Pow2Over1（`s=0.5166 → −27.00` 精确）
- Host 增益 `dB = (s−1)×48`，`volumeRangeDB = 48.0`（`Constants.swift:31`）
- 设备过滤只保留"无可写 scalar"的设备（`DeviceDiscovery.swift:115-121`）
- 控制文件实际只有 LG 与 PHL，内置扬声器不在其中
- 两条音量路径同时存在（软件增益 + `forwardProxyVolumeToPhysical`）
- `CreateProxyDevice` 使用空的 `VolumeControlParameters{}`
- 1.1.2 与 1.1.3 在 `VolumeControlParameters` / `OnStartIO` / `volume_scalar` 默认值三处一致
- `HostHeartbeatFresh` 与 `SyncDevices` 在 1.1.2 与 1.1.3 完全一致（diff 无输出）

---

## 7. 对 Phase 2 计划的直接影响

| 编号 | 影响 | 对应阶段 |
|---|---|---|
| E1 | HARDWARE 模式改用"直接写 dB"，不再需要逐设备曲线适配 | 2.2 |
| E3 | issue #9 的验收标准应写"UI dB 与实际 dB 差 < 1 dB"，不是"5–35 dB" | 2.2 |
| E4 | 实时性改造的目标应从"消除分配"改为"消除逐帧 O(n) 清零与独占性检查" | 2.4 |
| E5 | 平滑系数需重新标定到 8–10 ms | 2.2 |
| E6 | 协议需补 `underrun_frames` 才能统计丢帧率 | 2.4 |
| M1 | OnStartIO 重试窗口必须缩短，列为 P0 | 2.1 / 2.5 |
| M2 | 移除无效的 `killall coreaudiod`，改为显式孤儿检测 | 2.5 |
| M3 | 僵尸设备的调查方向从 driver 改为 coreaudiod 列表收敛 | 2.5 |
| M4 | 双次 SRC 需在 1.2.0 明确"接受"或"改造" | 2.4 |
| M5/M6 | 协议扩展前先修 reserved 基数、补 `header_size` 校验 | 2.1 |
