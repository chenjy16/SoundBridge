# SoundBridge 1.2.0 — Phase 2.1 实施报告

- 基线提交：`0574414`（main，与 origin/main 同步，0 ahead / 0 behind）
- 子模块 libASPL：`633e0f70203edd87d320fc5a3cae901e1363aac5`（v3.1.2-1-g633e0f7，**未修改**）
- 版本号：仓库中所有 `VERSION` / `Info.plist` 均**未修改**（仍为 1.1.3）
- 实施范围：Phase 2.1-A ~ 2.1-F，未触及 Phase 2.2 及以后的内容
- 完成状态：**测试与构建全部通过，但存在 2 项需人工确认的发布风险（见第 6 章）**

---

## 1. 实施摘要

### 1.1 修改了什么

| 方向 | 内容 |
|---|---|
| 协议单一源 | 新增 `packages/shared/include/RFSharedAudio.h` 作为唯一权威源，其余三份副本由 `tools/sync_shared_header.sh` 生成，`make protocol-check` 在构建前强制校验 |
| 协议布局 | 修正 `_reserved` 长度表达式的错误基数（148 → 156 的语义），固定头从 264 字节收敛为**256 字节**；新增 `volume_mode` / `state_initialized` / `state_revision` / `underrun_frames` 四个字段；20 条 `static_assert` 钉住每个 offset 与 `sizeof` |
| 协议版本 | `RF_AUDIO_PROTOCOL_VERSION` 由旧值提升为 `0x00020100` |
| 跨语言校验 | `rf_validate_header()` / `rf_validate_result_string()` 放进共享头，Driver 的 `ValidateConnection()` 与 Host 测试执行同一份 C 代码 |
| 音量曲线 | Driver `aspl::VolumeControlParameters` 改为 `0..48` raw / `-48..0` dB；Host 侧新增 `VolumeTaper` 实现 `dB = 48*sqrt(s) - 48`、`gain = 10^(dB/20)`；两端由测试逐 raw step 对齐 |
| 状态模型 | 新增 `VolumeMode.swift`、`VolumeState.swift`（`VolumeState` / `VolumeStateResolver` / `VolumeStateStore` / `VolumeStatePersisting`） |
| IO 启动覆盖 | `OnStartIO` 不再把控件默认值 1.0 写进共享内存；改为 `rf_sync_driver_volume_state()` 的 ADOPTED / SEEDED / REJECTED 三态握手 |
| 重试阻塞 | `OnStartIO` 共享内存获取从 15 次指数退避（最坏 17 250 ms）降为 3 次尝试 / 50 ms 基础延迟（最坏 150 ms），并加 `static_assert` 上限 |
| Host 启动路径 | `SharedMemoryManager` 区分 created / recoveredFromCrash / replacedUninitialized / replacedIncompatible 四种来源；`main.swift` 增加 Step 7.5 采纳已提交状态 |
| 测试基础设施 | Host 新增 `SoundBridgeHostTests` testTarget，49 项测试；`make test` 改为 protocol-check + DSP + Host + App 四级 |
| CI | `.github/workflows/release.yml` 新增协议检查与三套测试步骤 |

### 1.2 没有修改什么

- libASPL 子模块源码：零改动，子模块指针未变。
- 设备发现过滤条件（`DeviceDiscovery`）：未删除、未放宽。
- HARDWARE 音量模式：未启用，`VolumeMode.hardware` 只是声明 + 协议字段占位。
- 全设备 EQ 接入、10 段 EQ UI：未触碰。
- 版本号、`Info.plist`、`CMakeLists.txt` 中的版本字符串：未修改。
- 未执行 `sudo` / 安装或卸载 Driver / `killall coreaudiod` / `kill -9` / 切换默认音频设备 / 修改用户音频配置。
- 未执行 `git add` / `commit` / `push`，未创建 Release。

### 1.3 已解决的问题

1. **IO 重启音量跳到 100%**：根因是 `VolumeControl` 构造时 `rawVolume_ = MaxRawVolume`，旧 `OnStartIO` 无条件把 `GetScalarValue()`（1.0）写入共享内存。现在共享内存中已提交的状态优先，控件只被"推入"而不再回写。
2. **Host 与 Driver 音量曲线不一致（最大约 29 dB）**：Host 曾用线性 `(scalar - 1) * 48` 映射，驱动实际走 libASPL 的 Pow2 曲线。现在两端统一为 `dB = 48*sqrt(s) - 48`。
3. **三份协议头人工维护**：收敛为唯一源 + 生成脚本 + 构建前一致性检查。
4. **协议头内部不自洽（264 vs 注释承诺的 256）**：修正 `_reserved` 基数并逐字段 static_assert。
5. **OnStartIO 失败路径阻塞 HAL 启动 17.25 秒**：降为 150 ms 上限并加编译期上限断言。
6. **Host 每次启动无条件重置音量状态**：改为 persisted > recovered-from-crash > 0.35 的显式解析，并用 `state_initialized` 区分"种子值"与"已提交状态"。
7. **C 与 Swift 的标量净化规则不一致**（实现过程中发现）：`rf_sanitize_volume_scalar` 原先把 +Inf 夹到 1.0，Swift 侧则回退到 fallback。已统一为"非有限值 → 调用方 fallback"，并有跨语言一致性测试。

### 1.4 仍然存在的问题

1. **协议版本升级不会触发驱动重装**（发布级风险）。`DriverInstaller.installDriver()` 只做 `isDriverInstalled()` 文件存在性判断，没有版本比较。1.1.3 → 1.2.0 升级后旧驱动仍在 `/Library/Audio/Plug-Ins/HAL`，会因 `protocol_version` 不等被新 Host 拒绝，设备不可用。修复需要改 App 的安装判定（属于 §10 禁止的"安装/卸载 Driver"范围，本阶段未执行）。
2. `SharedMemoryManager.probeExisting()` 的**文件级**恢复路径（unlink → 重建 → 读回已提交状态）没有单元测试覆盖；被测的是它依赖的状态解析逻辑与 C 访问器。
3. HARDWARE 模式、物理设备 `DecibelValue` 写入的实机验证、设备过滤放开、coreaudiod 残留、USB DAC / AirPods、双次 SRC —— 全部维持 Phase 2.0 状态，未在本阶段推进。

---

## 2. 文件修改清单

### 2.1 新增：`packages/shared/include/RFSharedAudio.h`（唯一协议源）

- **原问题**：三份头文件靠人工同步，且头内 `_reserved` 用错误基数计算长度，导致 struct 实际 264 字节而注释承诺 256 字节；`header_size` 语义（固定头长度 vs 整体长度）没有定义。
- **修改方案**：以原 `packages/driver/include/RFSharedAudio.h` 为底稿建立唯一源，把语义定义、字段布局、访问器、校验器全部收拢在此。
- **关键实现**：
  - 版本 `0x00020100`；`RF_SHARED_AUDIO_HEADER_SIZE 256u`；`_reserved[RF_SHARED_AUDIO_HEADER_SIZE - 228]`（= 28 字节）。
  - `header_size` 明确等于固定头长度，且 `sizeof(RFSharedAudio) == RF_SHARED_AUDIO_HEADER_SIZE`（由 static_assert 保证，二者是同一个量而不是两个）。
  - 新增字段 `volume_mode@204`、`state_initialized@208`、`state_pad0@212`（显式填充，保证 `state_revision` 8 字节对齐）、`state_revision@216`、`underrun_frames@224`。
  - 新增 `RF_VOLUME_DB_MIN/MAX/RANGE`、`RF_VOLUME_RAW_MIN/MAX/RANGE`、`RF_VOLUME_MODE_SOFTWARE/HARDWARE`，并附 `dB range > 30` 的编译期断言。
  - 新增 `RFVolumeStateSnapshot`（24 字节）、`RFValidateResult`、`RFVolumeSyncOutcome`。
  - 新增访问器 `rf_sanitize_volume_scalar` / `rf_is_volume_state_initialized` / `rf_read_volume_state` / `rf_publish_volume_state` / `rf_get_state_revision` / `rf_get_volume_mode` / `rf_get_underrun_frames` / `rf_validate_header` / `rf_validate_result_string` / `rf_sync_driver_volume_state`。
  - `rf_ring_read` 的欠载分支新增 `underrun_frames` 累计（原来只累计欠载次数）。
- **修改原因**：协议正确性是本阶段的第一优先级；唯一源 + 编译期断言是唯一能防止两端布局漂移的方式。

### 2.2 生成：三份协议副本

- `packages/driver/include/RFSharedAudio.h`
- `packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h`
- `apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h`

三份内容与唯一源逐字节相同（`cmp` 比较，不用 mtime），由 `tools/sync_shared_header.sh` 生成。**不使用符号链接**：driver 会被打包进系统 bundle，Swift 包的 `Sources` 会被 `create_app_bundle.sh` 拷贝，链路在打包后不可靠。

### 2.3 新增：`tools/sync_shared_header.sh`

- **原问题**：无同步机制。
- **关键实现**：`sync` 写入副本；`--check` 只比较不写入，发现漂移时列出 MISSING / DRIFT 并以非 0 退出。
- **修改原因**：`make build` / `make protocol-check` / CI 都需要一个不会静默通过的检查。

### 2.4 新增：`tools/check_protocol_layout.sh`

- **原问题**：仅有"副本一致"无法证明协议本身自洽（例如把头文件改成只能在 C++ 下编译，或改了版本号却没人注意）。
- **关键实现**：用 `clang -std=c11 -Wall -Wextra -Werror` 编译探针 TU，内含 `#error` 版本/头长断言与 `sizeof` 断言，随后用 `clang++ -std=c++17` 再编译一次；最后打印完整字段偏移表。
- **修改原因**：让"结构体大小检查"和"版本号检查"成为可执行检查，而不仅依赖构建系统的 side effect。

### 2.5 `packages/driver/src/Plugin.cpp`

- **原问题**：
  1. `OnStartIO` 在拿到共享内存后无条件把 `VolumeControl` 的当前值写进共享内存——控件刚被重建时该值是 1.0，于是 IO 重启音量跳到 100%。
  2. 共享内存获取用 15 次指数退避，最坏累计 17 250 ms，全部发生在 HAL 的 StartIO 路径上。
  3. `ValidateConnection()` 手写四项校验，与 Host 的期望没有共享实现。
  4. 代理音量范围是 libASPL 默认的 0..96 raw / -96..0 dB，与 Host 的 48 dB 曲线不匹配。
- **修改方案**：
  1. 新增 `SyncVolumeStateWithSharedMemory()`：调用共享头里的 `rf_sync_driver_volume_state()`，按 ADOPTED / SEEDED / REJECTED 三种结果分别处理并分别打日志；只有 SEEDED（首次 bootstrap）才允许写共享内存。
  2. `MAX_START_IO_ATTEMPTS = 3`（含首次）、`START_IO_BASE_DELAY_MS = 50`，并 `static_assert(START_IO_MAX_BLOCKING_MS <= 300)`。
  3. `ValidateConnection()` 改为 `rf_validate_header()`，失败日志包含结果字符串、protocol、header_size、sample_rate、channels。
  4. `CreateProxyDevice()` 显式构造 `aspl::VolumeControlParameters{0, 48, -48, 0}`，并附 `volume taper` 常量与 `dB range > 30` 的 static_assert。
- **关键实现细节**：
  - `SoundBridgeVolumeControl` / `SoundBridgeMuteControl` 新增 `RestoreFromSharedMemory()`，内部用 `std::atomic<bool> suppress_shared_memory_write_` 抑制 `SetRawValueImpl` / `SetIsMutedImpl` 把量化后的值回写共享内存（48 个 raw 步长的量化误差会污染 Host 提交的精确值）。
  - 实时回调路径（`SetRawValueImpl`）仍然只写 `volume_scalar` / `mute_state` 传输字段，**不碰** `state_revision` / `state_initialized`，因此无法伪造一次提交。
- **修改原因**：这是 §6、§7 的直接需求；把手写分支搬进共享头，是为了让测试覆盖的就是驱动实际执行的代码。

### 2.6 新增：`packages/host/Sources/SoundBridgeHost/Audio/VolumeMode.swift`

- 定义 `software = 0` / `hardware = 1`，`protocolValue` 与 `RF_VOLUME_MODE_*` 对齐，`init(protocolValue:)` 对未知值回退到 `.software`（绝不回退到 `.hardware`）。

### 2.7 新增：`.../Audio/VolumeTaper.swift`

- **原问题**：Host 的增益公式内联在 `AudioRenderer` 里，且与驱动曲线不一致；没有任何地方定义"标量 → dB → 线性增益"的唯一实现。
- **关键实现**：`rangeDB = 48`、`rawSteps = 48`、`decibels(forScalar:)`、`gain(forScalar:)`、`scalar(forRawStep:)`（复刻 libASPL `ConvertRawToScalar`）、`rawStep(forScalar:)`（复刻量化）、`sanitize(_:fallback:)`。
- **修改原因**：两端公式必须来自同一处定义并被测试钉死；文件头注释明确写下"dB range ≤ 30 时 libASPL 静默退化为线性"的陷阱。

### 2.8 新增：`.../Audio/VolumeState.swift`

- 内容：`VolumeState`（requestedScalar / appliedGain / isMuted / mode / revision / initialized）、`VolumeStatePersisting` 协议、`VolumeStateResolver`（persisted > recovered > safeDefault）、`RFVolumeStateSnapshotLike`（把 C 快照类型擦除，便于纯 Swift 测试）、`VolumeStateStore`（NSLock 保护，`initialize` 必增 revision，`commit` 值未变则不增）。
- **修改原因**：§5 要求状态模型尽可能纯粹、可测；把 C 类型擦除后，状态测试不需要映射文件。

### 2.9 `.../Memory/SharedMemoryManager.swift`

- **原问题**：`createMemory` 无条件 `unlink` 后重建，崩溃前提交的状态被丢弃；初始化值直接取持久化默认值。
- **修改方案**：新增 `SharedMemoryOrigin` 四分类；`probeExisting()` 以 `O_RDONLY` 只映射 256 字节头部做只读探测（不映射音频负载），校验 `protocol_version` / `header_size` 后尝试 `rf_read_volume_state`；解析顺序交给 `VolumeStateResolver`；最终用 `rf_publish_volume_state()` 提交一次，使 Driver 首次 `OnStartIO` 就能看到 `state_initialized == 1`。
- **新增接口**：`publishVolumeState(for:scalar:muted:mode:)`、`readVolumeState(for:) -> RFVolumeStateSnapshotLike?`、`origins` 字典（诊断/测试用）。

### 2.10 `.../Audio/AudioRenderer.swift`

- **原问题**：增益公式内联且与驱动曲线不一致。
- **修改方案**：改为 `VolumeTaper.gain(forScalar: VolumeTaper.sanitize(rf_load_volume_scalar(mem), fallback: 0.0))`；补正 `smoothingCoeff` 注释（0.995 @ 48 kHz ≈ 4.2 ms 时间常数，不是 10 ms）。
- **修改原因**：共享内存里的标量在 Phase 2.1 之后是"曲线的输入"而不是"线性滑块行程"；同时保证 NaN/Inf 不会进入实时增益乘法。

### 2.11 `.../Constants.swift`

- `volumeRangeDB` 从 `let 48.0` 改为计算属性，指向 `VolumeTaper.rangeDB`，避免出现第二个 48。

### 2.12 `.../Services/VolumePersistence.swift`

- `class VolumePersistence: VolumeStatePersisting`；新增 `loadIfPresent(uid:) -> DeviceVolumeState?`（缺失时返回 `nil` 而不是默认值——返回默认值会掩盖可恢复的共享内存状态）；`defaultVolume` 改为指向 `VolumeState.defaultScalar`。

### 2.13 `.../Devices/ProxyDeviceManager.swift`

- `restoreVolumeState(proxyDeviceID:physicalUID:override:)` 新增 `override` 参数：调用方可以传入已从共享内存读回的状态，避免用持久化默认值覆盖恢复值。

### 2.14 `.../Devices/DeviceMonitor.swift`

- 设备热插拔时 `createMemory(for:persistence:)` 传入 `proxyManager.volumePersistence`，使重新出现的设备与首次启动走同一条解析顺序。

### 2.15 `.../main.swift`

- 新增 `volumeStateStore`；Step 3 传 `persistence`；新增 Step 7.5 把已提交状态采纳为 Host 运行时权威（只读共享内存，不再重复写入）；post-start re-apply 改为从共享内存读值并作为 `override` 传入。

### 2.16 `packages/host/Package.swift`

- 新增 `.testTarget(name: "SoundBridgeHostTests", dependencies: ["SoundBridgeHost", "CSoundBridgeAudio"], path: "Tests/SoundBridgeHostTests")`。
- 依赖 `CSoundBridgeAudio` 是刻意的：协议测试要执行驱动编译的同一份 C inline 代码。

### 2.17 新增：`packages/host/Tests/SoundBridgeHostTests/`

- `VolumeTaperTests.swift`（12 项）：曲线参考点、gain 定义、单调性、逐 raw step 的跨端一致性、量化往返、边界 / NaN / ±Inf / 极端值。
- `VolumeStateTests.swift`（18 项）：默认状态、持久化恢复、恢复优先级、未初始化状态拒绝、revision 单调性、NaN 不推进 revision、mode 协议值。
- `SharedMemoryProtocolTests.swift`（19 项）：协议常量与布局、版本/头长/采样率/通道数拒绝、IO 启动采纳已提交音量、控件重建后保持、首次 bootstrap 只发生一次、拒绝时不写块、revision 归属、C/Swift 净化器一致、`underrun_frames` 累计。

### 2.18 `Makefile`

- 新增 `protocol-check` / `dsp-build` / `test-dsp` / `test-host` / `test-app`；`test` 改为依赖 `protocol-check test-dsp test-host test-app`；`build` 与 `quick` 以 `protocol-check` 为前置。

### 2.19 `.github/workflows/release.yml`

- 在通用架构构建之后、打包之前新增四步：`make protocol-check` / `make test-dsp` / `make test-host` / `make test-app`。放在构建之后是为了让 CMake 缓存已经是 universal 配置。

---

## 3. 共享内存协议

### 3.1 版本与对齐

| 项 | 值 |
|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020100` |
| `RF_SHARED_AUDIO_HEADER_SIZE` | 256 字节 |
| `sizeof(RFSharedAudio)` | 256 字节 |
| `alignof(RFSharedAudio)` | 8 字节 |
| `offsetof(audio_data)` | 256 字节（柔性数组，紧随固定头） |
| 结构体总大小 | 头部 256 B + `ring_capacity_frames × channels × bytes_per_sample` |
| 对齐规则 | 自然对齐（由成员类型决定：最大对齐需求来自 `uint64_t` = 8）；`state_revision` 前的 `state_pad0` 是为显式对齐而存在的字段，不是历史遗留 |

`header_size` 的语义在本次修订中被明确定义为**固定头长度**（`RF_SHARED_AUDIO_HEADER_SIZE`），不是整个映射长度；映射长度由 `rf_shared_audio_size()` 单独计算。两者不再混用同一个名字。

### 3.2 最终字段表（`tools/check_protocol_layout.sh` 实测输出）

```
protocol version : 0x00020100
header size      : 256 bytes
sizeof(struct)   : 256 bytes
alignof(struct)  : 8 bytes
audio_data offset: 256 bytes
volume taper     : 48 raw steps, 48.0 dB range (Pow2 branch requires > 30 dB)

field                    offset   size
protocol_version              0      4
header_size                   4      4
sample_rate                   8      4
channels                     12      4
format                       16      4
bytes_per_sample             20      4
bytes_per_frame              24      4
ring_capacity_frames         28      4
ring_duration_ms             32      4
driver_capabilities          36      4
host_capabilities            40      4
creation_timestamp           48      8
format_change_counter        56      8
write_index                  64      8
read_index                   72      8
total_frames_written         80      8
total_frames_read            88      8
overrun_count                96      8
underrun_count              104      8
format_mismatch_count       112      8
driver_connected            120      4
host_connected              124      4
driver_heartbeat            128      8
host_heartbeat              136      8
volume_scalar               144      4
mute_state                  148      4
eq_sequence                 152      4
eq_snapshot                 156     48
volume_mode                 204      4
state_initialized           208      4
state_pad0                  212      4
state_revision              216      8
underrun_frames             224      4
_reserved                   228     28
audio_data                  256      -
```

与 Phase 2.0 报告给出的 offset 表（0/4/48/120/124/128/136/144/148/152/156/204）逐项一致；唯一变化是 `_reserved` 从错误的 60 字节修正为 28 字节，头部总长 264 → 256。

### 3.3 布局变化记录

| 项 | 1.1.3（旧） | 1.2.0（新） |
|---|---|---|
| `_reserved` 长度表达式 | `256 - 148 - sizeof(RFEQSnapshot)` = 60 | `RF_SHARED_AUDIO_HEADER_SIZE - 228` = 28 |
| 固定头大小 | 264（注释承诺 256） | 256 |
| 新增字段 | 无 | volume_mode / state_initialized / state_pad0 / state_revision / underrun_frames |
| 协议版本 | 旧值 | `0x00020100` |

旧表达式的错误在于基数取 148（`mute_state` 的结束位置），而 `eq_snapshot` 实际从 156 开始，多留了 8 字节。

### 3.4 编译期断言结果

`RFSharedAudio.h` 内 20 条断言（`static_assert` 与 `_Static_assert` 两个分支内容完全一致）：

- offset 断言 17 条：`protocol_version`=0、`header_size`=4、`creation_timestamp`=48、`driver_connected`=120、`host_connected`=124、`driver_heartbeat`=128、`host_heartbeat`=136、`volume_scalar`=144、`mute_state`=148、`eq_sequence`=152、`eq_snapshot`=156、`volume_mode`=204、`state_initialized`=208、`state_revision`=216、`underrun_frames`=224、`_reserved`=228、`audio_data`=256。
- 尺寸断言 3 条：`sizeof(RFSharedAudio)`=256、`sizeof(RFEQSnapshot)`=48、`sizeof(RFVolumeStateSnapshot)`=24。
- 曲线断言 1 条：`RF_VOLUME_DB_RANGE > 30.0f`（防止 Pow2 曲线静默退化）。
- `Plugin.cpp` 另有 3 条：`VOLUME_DB_MAX - VOLUME_DB_MIN > 30`、`VOLUME_RAW_MAX > VOLUME_RAW_MIN`、`START_IO_MAX_BLOCKING_MS <= 300`。

全部断言在 C11 与 C++17 下编译通过（`tools/check_protocol_layout.sh` 两种语言各编译一次，Driver 构建再次验证 C++17）。

### 3.5 新字段的读写责任、默认值与原子性

| 字段 | 类型 | 写者 | 读者 | 默认值 | 原子性 |
|---|---|---|---|---|---|
| `volume_scalar` | `_Atomic float` | Host（提交）、Driver（HAL 控制路径） | Host 渲染回调、Driver | 0.35f | release 写 / acquire 读 |
| `mute_state` | `_Atomic int32_t` | 同上 | 同上 | 0 | release / acquire |
| `volume_mode` | `_Atomic uint32_t` | **仅 Host** | Driver | `RF_VOLUME_MODE_SOFTWARE` | release / acquire |
| `state_initialized` | `_Atomic uint32_t` | **Host**；Driver 仅在 `== 0` 时 bootstrap 一次 | Driver | 0 | release / acquire（latch） |
| `state_revision` | `_Atomic uint64_t` | **仅 `rf_publish_volume_state()`** | Host、Driver | 0 | `fetch_add`（release） |
| `underrun_frames` | `_Atomic uint32_t` | Driver（`rf_ring_read` 欠载分支） | Host 遥测 | 0 | `fetch_add` |
| `state_pad0` | `uint32_t` | `rf_shared_audio_init()` 一次 | 无 | 0 | 非原子（不对应语义状态） |

约束：

- `state_revision` 只有 `rf_publish_volume_state()` 能推进，且严格 +1；Driver 的实时路径不调用它。
- `state_initialized` 只在数据、mode、revision 全部 release 写入之后才置 1，读侧 acquire 到 1 就保证能看到那一批值。
- Host 与 Driver 没有对同一字段的无约束写入：Driver 对 `volume_scalar` 的写入是 HAL 客户端的用户操作，Host 对它的写入是恢复/提交；两者都通过 release 存储，最后一个写入者胜出，不存在撕裂。
- 不使用"把普通整数包一层就叫原子"的做法：所有原子字段在 C 侧是真正的 `_Atomic`，Swift 侧完全不直接触碰（`ClangImporter` 会丢弃 `_Atomic` 成员），只能经过共享头里的 inline 访问器。

### 3.6 `ValidateConnection` 的校验内容

`rf_validate_header()` 依次校验：非空 → `protocol_version` 全等 → `header_size == 256` → 采样率属于支持列表 → `1 <= channels <= RF_MAX_CHANNELS`。失败时：

- Driver：`RF_DebugLog` + `RF_LOG_ERROR` 输出结果字符串与四个字段的实际值，随后 `Disconnect()`，不再读写该映射；
- Host：`probeExisting()` 将其归类为 `replacedIncompatible`，`unlink` 后重建；
- 任何路径都不会"尽力attach"，也不会静默忽略协议错误。

---

## 4. 音量状态模型

### 4.1 状态权威性

| 状态 | 职责 | Phase 2.1 中的地位 |
|---|---|---|
| Host `VolumeStateStore`（Runtime） | 运行期权威：`requestedScalar` + 派生 `appliedGain` + `isMuted` + `mode` + `revision` | **权威** |
| 用户持久化配置 `VolumePersistence` | 记录用户上一次明确选择的值，跨启动使用 | 初始化的最高优先级来源 |
| 共享内存 `volume_scalar` / `mute_state` / `volume_mode` / `state_revision` | Driver ↔ Host 的传输与提交记录 | 传输通道 + 崩溃恢复依据 |
| Driver `VolumeControl` raw value | 向 HAL 客户端暴露的可控接口，必须与共享内存一致 | 从属：被推入，不回写 |
| 物理设备实际音量 | 设备自身状态 | **SOFTWARE 模式下不是权威**（Phase 2.2 才进入路由模型） |

规则：任意模块都不能再"随手覆盖"音量的唯一写入口是 `rf_publish_volume_state()`（Host）与 `rf_store_volume_scalar()`（Driver 的 HAL 用户操作，不提交 revision）。

### 4.2 初始化优先级

`VolumeStateResolver.resolve(persisted:recovered:)`：

1. `persisted`（`loadIfPresent` 返回非 nil）→ `source = .persisted`；
2. `recovered`（共享内存里 `state_initialized == 1`）→ `source = .recovered`；
3. 安全默认 `0.35` → `source = .safeDefault`。

`loadIfPresent` 与 `load` 的差别是关键的：`load` 会在缺失时返回 0.35，从而掩盖可恢复的共享内存状态并静默重置音量。

共享内存的四种情形（`SharedMemoryOrigin`）：

| 情形 | 判定 | 处理 |
|---|---|---|
| `created` | 文件不存在（`ENOENT`） | 新建，按优先级提交 |
| `recoveredFromCrash` | 头部有效且 `state_initialized == 1` | 采纳其 scalar/mute/mode，提交为新的 revision |
| `replacedUninitialized` | 头部有效但 `state_initialized == 0` | 视为无有效状态，按优先级重新提交 |
| `replacedIncompatible` | 长度 < 256、版本不等、或 `header_size` 不等 | 丢弃，重建，绝不解码未知布局 |

### 4.3 Driver / Host 的读写责任

- **Host**：唯一有权提交状态的一方。`createMemory()` 提交一次初始状态；此后用户操作通过 `VolumeStateStore.commit()`（值不变则不推进 revision）后调用 `SharedMemoryManager.publishVolumeState()`。
- **Driver**：只在 `state_initialized == 0` 时 bootstrap 一次（`OnStartIO`，持有 `io_mutex_`，且 `state_initialized` latch 后不可重入）。其余时间只写传输字段。
- **App**：Phase 2.1 不参与音量提交（EQ 仍是 App → Host 单向）。

### 4.4 revision 规则

1. 只有 `initialize()` / `commit()` / `rf_publish_volume_state()` 会推进；
2. 每次严格 +1（`&+` 回绕语义与 C 侧 `fetch_add` 一致）；
3. 值未变化时不推进（60 Hz 拖拽不会把计数器刷爆）；
4. 非法输入（NaN / ±Inf）被拒绝时不推进；
5. `initialize()` 即使 scalar 相同也一定推进——设备切换意味着所有者换了；
6. 不存在 Host / Driver 竞争写入同一个计数的路径。

### 4.5 IO 重启恢复流程

```
HAL 客户端 StartIO
  → OnStartIO（io_mutex_ 下）
    → OpenSharedMemory + ValidateConnection
    → SyncVolumeStateWithSharedMemory
        → rf_sync_driver_volume_state(mem, control_scalar, control_muted, &snapshot)
            ADOPTED  : 共享内存已提交 → 用 snapshot 覆盖控件（不回写、不加 revision）
            SEEDED   : 未提交 → 用控件当前值提交一次（revision +1，initialized latch）
            REJECTED : 头部不合法 → 什么都不读、什么都不写，控件保持原状
        → volumeControl_->RestoreFromSharedMemory(snapshot.scalar)   （suppress 回写）
        → muteControl_->RestoreFromSharedMemory(snapshot.muted != 0) （suppress 回写）
```

覆盖的场景：首次启动（SEEDED）、正常 IO 启动（ADOPTED）、IO 停止后重启（ADOPTED）、`VolumeControl` 重建（ADOPTED）、Host 重启（Host 侧重新提交，Driver ADOPTED）、共享内存重建（Host 判断 origin 后重新提交）。

### 4.6 Host 重启恢复流程

```
Host 启动
  → createMemory(persistence:)
      → probeExisting() 只读映射 256 字节头部
      → unlink + 新建 + rf_shared_audio_init（volume_scalar=0.35, initialized=0）
      → VolumeStateResolver.resolve(persisted:loadIfPresent(uid), recovered:probe)
      → rf_publish_volume_state（revision=1, initialized=1）
  → [Step 7.5] 读回已提交状态 → VolumeStateStore.initialize（revision 继续递增）
```

正常退出路径会 `unlink` 文件，因此"存在且已提交"等价于"上一次是崩溃或被强杀"。

---

## 5. 测试结果

构建与测试均在本机执行（macOS 26.x SDK / Apple Silicon，Debug 测试 + Release 构建）。

| 项目 | 命令 | 结果 |
|---|---|---|
| 协议副本一致性 | `./tools/sync_shared_header.sh --check` | **已通过** — 4 份文件逐字节相同 |
| 协议布局/版本 C11 | `./tools/check_protocol_layout.sh` | **已通过** — `-Wall -Wextra -Werror` 无警告 |
| 协议布局/版本 C++17 | 同上 | **已通过** |
| DSP build | `make dsp-build` | **已通过** |
| DSP test | `make test-dsp`（ctest） | **已通过** — 1/1 `soundbridge_dsp_tests` |
| Driver build | `cmake --build packages/driver/build` | **已通过** — 4 条警告均为 libASPL `Stream.hpp` 既有的 `-Wreorder-init-list`，与本次改动无关 |
| Host build | `swift build -c release`（packages/host） | **已通过** |
| Host test | `swift test`（packages/host） | **已通过** — 3 个 suite / 49 项 / 0 失败 |
| App build | `swift build -c release`（apps/mac/SoundBridgeApp） | **已通过** |
| App test | `swift test`（apps/mac/SoundBridgeApp） | **已通过** — 27 项 XCTest + 9 组 SwiftCheck 属性测试（各 100 次迭代） |
| `git diff --check` | — | **已通过**（无输出） |
| CI 实际运行 | GitHub Actions | **未执行** — `release.yml` 仅在 release published 时触发，本地无法运行；已按静态检查确认语法与步骤顺序 |
| 实机音频验证 | — | **未执行**（§10 禁止安装/卸载驱动、重启 coreaudiod；本阶段也不引入实机行为变更以外的能力） |

### 5.1 §8 要求的 10 项状态测试对应关系

| # | 要求 | 覆盖测试 | 结果 |
|---|---|---|---|
| 1 | 默认状态初始化 | `VolumeStateTests.testSeedStateIsNotInitialized` / `testDefaultScalarIsSharedByAllThreeDefinitions` / `testFreshStoreResolvesToSafeDefault` | 通过 |
| 2 | 持久化音量恢复 | `testPersistedVolumeWinsOverEverything` / `testPersistedMuteStateSurvives` / `testPersistedGarbageIsSanitised` | 通过 |
| 3 | IO 启动不覆盖有效音量 | `SharedMemoryProtocolTests.testDriverIOStartAdoptsCommittedVolume` / `testDriverIOStartKeepsMuteState` | 通过 |
| 4 | IO 重启保持音量 | `testDriverIOStartSurvivesControlRebuild`（3 次 start/stop，控件每次重置为 1.0） | 通过 |
| 5 | Host 重启恢复 | `VolumeStateTests.testRecoveredStateUsedWhenNothingPersisted` / `testStoreAdoptsRecoveredStateOnlyOnce` / `testRecoveredStateIsSanitisedToo`（文件级 probe 未测，见 5.3） | 通过（部分） |
| 6 | Driver / Host 协议版本一致 | `SharedMemoryProtocolTests.testProtocolConstantsArePinned` / `testVolumeTaperConstantsMatchProtocolHeader` + `sync_shared_header.sh --check` | 通过 |
| 7 | 协议版本不一致 | `testProtocolVersionMismatchIsRejected` | 通过 |
| 8 | struct size 不一致 | `testHeaderSizeMismatchIsRejected`（264 → 拒绝） | 通过 |
| 9 | 未初始化状态不被当作有效音量 | `VolumeStateTests.testUninitializedRecoveredStateIsIgnored` + `SharedMemoryProtocolTests.testFreshBlockIsValidButUncommitted` / `testTransportWriteDoesNotCommit` | 通过 |
| 10 | state revision 单调递增 | `VolumeStateTests.testInitializeAlwaysBumpsRevision` / `testCommitBumpsRevisionOnlyOnRealChange` / `testCommitIsMonotonicAndFinite` / `testCommitRejectsNaNWithoutMovingRevision` / `SharedMemoryProtocolTests.testPublishAdvancesRevisionByOne` | 通过 |

### 5.2 音量曲线测试（§8 末段）

`VolumeTaperTests` 中：

- 参考点 `dB = 48*sqrt(s) - 48`：s = 1.00 / 0.75 / 0.50 / 0.30 / 0.10 / 0.05 / 0.00 → 0 / -6.4308 / -14.0589 / -21.7093 / -32.8211 / -37.2669 / -48.0000 dB（容差 0.001）。
- `gain = pow(10, dB/20)`：对同一组输入逐点验证（容差 1e-6）。
- 跨端一致性：对驱动的全部 49 个 raw step，`VolumeTaper.decibels(scalar(forRawStep: raw))` 与 `-48 + raw` 相差 < 0.0005 dB；`rawStep(forScalar: scalar(forRawStep: raw)) == raw` 全部成立。
- 边界与非法输入：0 / 1 / 负数 / >1 / 极大有限值 / NaN / ±Inf；非有限值一律回退到 fallback（渲染路径的 fallback 为 0.0，即静音），并断言 `gain` 恒有限、恒在 `[0, 1]`。
- C/Swift 净化器一致性：同一组输入下 `rf_sanitize_volume_scalar` 与 `VolumeTaper.sanitize` 结果完全相同。

### 5.3 未覆盖 / 无法验证的内容

- **文件级崩溃恢复**：`SharedMemoryManager.probeExisting() → unlink → 重建 → 读回` 这条链路没有单元测试。被测的是它依赖的全部纯逻辑（`VolumeStateResolver`、`rf_read_volume_state`、`rf_validate_header`）。补测需要临时 shm 路径注入。
- **`OnStartIO` 的 C++ 端到端**：`SyncVolumeStateWithSharedMemory()` 本身没有 C++ 单测（驱动无测试目标）。它现在只是 `rf_sync_driver_volume_state()` 的薄封装，而后者被 Swift 测试完整覆盖；`suppress_shared_memory_write_` 回写抑制、真实 `aspl::VolumeControl` 行为、`OnStartIO` 的重试计时都**未**被自动化测试覆盖。
- **实机行为**：音量按键实际手感、Safari/系统音量同步、设备热插拔后的音量保持，均需人工验证，本阶段未做。

---

## 6. 风险与遗留问题

### 6.1 发布级风险（需人工决策）

1. **协议升级不会触发驱动重装。**
   `DriverInstaller.installDriver()` 第 64 行只判断 `isDriverInstalled()`（`/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` 是否存在），没有版本比较。1.1.3 用户升级到 1.2.0 后，旧驱动（协议 0x00020000 或更早）仍在位，新 Host 会判定 `replacedIncompatible` 反复重建共享内存，而旧驱动会拒绝连接 —— 结果是**代理设备无声**。
   最小修复建议（留给人工确认，本阶段禁止执行）：在 `DriverInstaller` 增加版本比较（读取已安装 bundle 的 `CFBundleShortVersionString` 与 `Bundle.main` 内置驱动版本比较），不一致则走一次安装流程（需要管理员授权 → 属于禁止项，必须由用户执行）。

2. **旧版 App 与新驱动不兼容。** 反向同理：若用户只升级驱动不升级 App，旧 App 用 `MemoryLayout<RFSharedAudio>.size` 做下界比较（264 > 256），会通过检查但读到错误偏移。实际不会发生（驱动随 App 分发），但发布说明中应写明"驱动与 App 必须同版本"。

### 6.2 Phase 2.0 遗留、本阶段未推进

| 项 | 状态 |
|---|---|
| HARDWARE 音量模式 | **未实现**。`VolumeMode.hardware` 与 `RF_VOLUME_MODE_HARDWARE` 只是协议占位，任何代码路径都不会选中它 |
| 物理设备 `DecibelValue` 写入 | **未完成完整实机验证**。Phase 2.0 只证明了属性可写，不代表物理音量响应正确 |
| 设备过滤 | **未放开**。`DeviceDiscovery` 的过滤条件原样保留 |
| coreaudiod 设备残留 | **未完整解决**。驱动反复增删设备后 `system_profiler` 仍可能残留条目 |
| USB DAC / AirPods / 蓝牙设备 | **未测试**（当前环境未连接） |
| 双次 SRC | 仍为已知限制（驱动内部一次 + Host/驱动之间的采样率协商缺失） |
| 驱动无自动化测试目标 | 仍无。C++ 侧只能靠共享头里的 inline 代码被 Swift 测试间接覆盖 |

### 6.3 已知的实现取舍

- `rf_publish_volume_state()` 每次都 +1 revision，包括"Host 重启后重新提交同一个值"。这是有意的：重启后的提交是新事实（旧映射已被 unlink），不应伪装成同一次提交。
- `state_pad0` 是显式填充字段而非 `uint8_t` 数组，目的是让 `state_revision` 落在 8 字节边界上，同时不引入隐式填充字节。
- `underrun_frames` 与既有 `underrun_count` 并存（次数 vs 帧数），没有替换旧字段，避免影响 App 的遥测读取。

---

## 7. 下一阶段建议（Phase 2.2 准备事项，不执行）

1. **先修驱动安装的版本门禁**（6.1 第 1 条）。这是 1.2.0 能否发版的前提，且必须在 Phase 2.2 引入更多 ABI 变化之前解决。
2. **建立设备能力模型的最小骨架**：`VolumeMode` 已经就位，Phase 2.2 需要的是"哪些设备允许 HARDWARE、依据是什么（`kAudioLevelControlPropertyDecibelValue` 可写 + 可读回 + dB 范围覆盖）"，并且要有一条**实机验证清单**而不是"属性可写即成功"。
3. **补上文件级恢复测试**：给 `SharedMemoryManager` 注入可配置的 shm 路径，让 `recoveredFromCrash` / `replacedUninitialized` / `replacedIncompatible` 三条分支各有一条测试。
4. **补一条驱动侧集成点**：为 `rf_sync_driver_volume_state()` + `suppress_shared_memory_write_` 增加可在 CI 运行的 C++ 测试（哪怕只是把 `Plugin.cpp` 里的两个控件类抽成不依赖 libASPL 的纯逻辑）。
5. **记录 HARDWARE 切换的实测基线**：在真实 USB DAC / AirPods / 内建扬声器上分别记录"属性写入前后"的物理音量变化，作为 Phase 2.2 的对照组。
6. **双次 SRC 的定量分析**：在切换 HARDWARE 模式之前先确认采样率路径，否则会把 SRC 引入的失真误判为音量曲线问题。

---

## 附：本阶段 Git 状态

- 未执行 `git add` / `commit` / `push`，未创建 tag / Release。
- 子模块指针未变（`633e0f7`）。
- 无生成二进制文件被纳入改动（`packages/*/build`、`.build` 均在 `.gitignore` 内）。
- 无版本号修改。
- 已存在的工作区未跟踪内容（`.qoder/`、`AUDIT_REPORT.md`、`POC_REPORT.md`、`docs/`、`tools/poc/`）保持原样，未被清理或覆盖。
