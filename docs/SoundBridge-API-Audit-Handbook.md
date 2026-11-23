# SoundBridge API 审阅手册

> **用途**：按"一个 API 一张卡片"的方式，给出每个核心接口的**契约、前置条件、失败语义、内存序、审阅检查点**，用于逐层核对实现是否与声明一致。
> **与导览的关系**：流程怎么走看 [SoundBridge-Main-Flow-Walkthrough.md](SoundBridge-Main-Flow-Walkthrough.md)；缺陷的完整证据看 [SoundBridge-Core-Engineering-Audit.md](release/SoundBridge-Core-Engineering-Audit.md)。本文回答的是"这个函数凭什么可以这样用"。
> **基线与免责**：`main` @ `eb45303f`，VERSION `1.2.0`，协议 `0x00020200`。所有"结论"标注三档：**[静态]** 仅由代码读出、**[实测]** 本次审计实际跑过、**[未验证]** 未取证。行号会漂移，函数名稳定。

---

## 目录

- [0. 怎么用这份手册](#0-怎么用这份手册)
- [1. 分层 API 地图](#1-分层-api-地图)
- [2. 共享内存协议 API](#2-共享内存协议-api)
- [3. DSP C API](#3-dsp-c-api)
- [4. Driver 内部 API](#4-driver-内部-api)
- [5. Host Swift API](#5-host-swift-api)
- [6. App 侧 API](#6-app-侧-api)
- [7. 七种"身份"的区别](#7-七种身份的区别)
- [8. API → 缺陷 → 测试 三向索引](#8-api--缺陷--测试-三向索引)
- [9. 审阅工作流与常见误判](#9-审阅工作流与常见误判)

---

## 0. 怎么用这份手册

三条审阅路径，按目的选：

| 你的目的 | 读法 |
| --- | --- |
| 读懂某个函数在干什么 | 直接跳到对应层的"卡片"，先看**契约**和**失败语义**两栏 |
| 判断某段代码是否正确 | 用卡片里的**审阅检查点**逐条对照，任何一条不成立就是一个 finding |
| 给某个缺陷写回归测试 | 跳到 [§8 三向索引](#8-api--缺陷--测试-三向索引)，从缺陷反查 API 和应有的断言 |

每张卡片固定五段，缺一段就说明这个 API 的契约不完整（本身就是一个可记录的问题）：

```
契约        —— 做什么、返回什么、谁调用
前置条件    —— 调用前必须为真的事（线程、锁、状态、生命周期）
失败语义    —— 失败时哪些东西被改、哪些不被改（"零副作用"是最重要的一栏）
内存序      —— 跨线程/跨进程的可见性与顺序保证
检查点      —— 审阅时可以用眼睛或测试验证的断言
```

---

## 1. 分层 API 地图

```
┌─ App (Swift) ────────────────────────────────────────────────┐
│ SharedMemoryMappingManager   EQController   VolumeController  │
│ HostSupervisor               DriverInstaller                  │
└───────────────────────────┬──────────────────────────────────┘
                            │ mmap 读写（只走 SharedMemoryMappingManager）
┌─ 协议层 (C11 header, 五份副本) ───────────────────────────────┐
│ RFSharedAudio.h  ——  结构体 + admission + ring + volume + EQ   │
└──────┬─────────────────────────────────────────┬─────────────┘
       │ 被 Driver 直接 include                  │ 被 Host 通过 CSoundBridgeAudio
┌──────▼─────────────┐                  ┌────────▼──────────────┐
│ Driver (C++)       │                  │ Host (Swift)           │
│ ControlProtocol    │                  │ SharedMemoryManager    │
│ MappingRetirement  │                  │ AudioRenderer          │
│ ProducerToken      │                  │ AudioEngine            │
│ Plugin.cpp (ASPL)  │                  │ ProxyDeviceManager     │
└──────┬─────────────┘                  └────────┬──────────────┘
       │                                          │
┌──────▼──────────────────────────────────────────▼──────────────┐
│ DSP (C ABI)  soundbridge_dsp.h  —— 静态库 libsoundbridge_dsp.a  │
└────────────────────────────────────────────────────────────────┘
```

实时性分级（决定"能不能在回调里调"）：

| 级别 | 含义 | 典型 API |
| --- | --- | --- |
| **RT** | 无分配、无锁、无系统调用、无日志 | `rf_ring_read`、`rf_ring_write`、`rf_producer_may_write`、`CallbackGate::TryEnter/Leave`、`soundbridge_dsp_process_*`、`rf_load_volume_scalar` |
| **RT-with-risk** | 声明 RT，实际含分配或日志 | `OnWriteMixedOutput` 的 `HandleFormatChange` / `resize` / `LogPeriodic`（D1） |
| **控制面** | 可在主队列/心跳队列调用，可加锁、可分配 | `createMemory`、`publishVolumeState`、`retireRenderPath`、`apply_preset` |
| **初始化** | 只允许在启动期调用一次 | `rf_shared_audio_init`、`rf_admission_open`、`rf_ring_prefill_before_publish`、`soundbridge_dsp_create` |

**通用审阅原则**：一个函数如果标注 RT，却在内部调用了分配、`os_log`、`stat`、`flock`、`malloc`，它就不是 RT——注释不能作为证据。

---

## 2. 共享内存协议 API

全部位于 [packages/shared/include/RFSharedAudio.h](../packages/shared/include/RFSharedAudio.h)。**五份副本必须逐字节一致**（`tools/sync_shared_header.sh --check`），任一副本漂移都会让两端对同一个字节偏移有不同解释。

### 2.1 初始化与校验

#### `rf_shared_audio_size(capacity_frames, channels, format)` — [:444](../packages/shared/include/RFSharedAudio.h#L444)

| 项 | 内容 |
| --- | --- |
| 契约 | 返回 mapping 应占的**总字节数** = 头 + 容量 × 帧字节数。Host 用它做 `ftruncate` |
| 前置 | 无 |
| 失败 | 无（纯计算） |
| 检查点 | ① 与 `sizeof(RFSharedAudio) + cap * bytes_per_frame` 相等；② Host 的 `ftruncate` 参数**必须**来自它，而不是自己算（否则 mapping 小于声明容量 → 越界） |

#### `rf_shared_audio_init(mem, sample_rate, channels, format, capacity)` — [:457](../packages/shared/include/RFSharedAudio.h#L457)

| 项 | 内容 |
| --- | --- |
| 契约 | 在**私有 staging inode** 上初始化整个头：协议版本、header_size、格式三件套、容量、admission=CLOSED、epoch=0、owner=0 |
| 前置 | 内存已 mmap 且尺寸 ≥ `rf_shared_audio_size(...)`；此 inode 尚未 rename 到公开路径 |
| 失败 | 无返回值。参数非法时写入的是一份"自洽但不可用"的头，由后续 `rf_validate_header` 拦住 |
| 检查点 | ① `protocol_version` 与 `header_size` 是编译期常量而非入参；② `admission_state` 初值必须是 `CLOSED`（若为 OPEN，`rf_admission_open` 会永久拒绝这个 mapping）；③ `write_index == read_index == 0` |

#### `rf_validate_header(mem)` — [:584](../packages/shared/include/RFSharedAudio.h#L584)

七个检查，顺序即优先级：

| 顺序 | 检查 | 返回 | 为什么必须在这一层 |
| --- | --- | --- | --- |
| 1 | `mem != NULL` | `RF_VALIDATE_NULL` | — |
| 2 | `protocol_version == RF_AUDIO_PROTOCOL_VERSION` | `..._PROTOCOL_VERSION` | 结构体布局可能已变，不允许"尽力兼容" |
| 3 | `header_size == 320` | `..._HEADER_SIZE` | 同上 |
| 4 | `rf_is_sample_rate_supported()` | `..._SAMPLE_RATE` | 白名单 6 个速率 |
| 5 | `1 ≤ channels ≤ 8` | `..._CHANNELS` | — |
| 6 | `capacity` 是 **2 的幂且非零** | `..._CAPACITY` | ring 用 `capacity-1` 做掩码；0 或非 2 的幂会让所有索引 UB（曾是 `% 0`） |
| 7 | `admission_state ∈ {0,1,2}` | `..._ADMISSION` | 未知状态无法推理，fail closed |

**检查点（重要）**：这个函数**不检查** `format`、`bytes_per_sample`、`bytes_per_frame`、mapping 实际长度。所以"我调了 `rf_validate_header` 所以安全"是错的——还要 `validateSharedMemory`（§4.1）。头注释称它是"the single implementation of the connection contract"，[静态] 这句话不准确，已记入审计 C4。

#### `rf_needs_format_change(mem, rate, ch, fmt)` — [:1546](../packages/shared/include/RFSharedAudio.h#L1546)

纯比较，无副作用。**检查点**：三个字段是**非原子**读——只能在控制面调用，不能在回调里作为"是否需要重配"的依据。

### 2.2 Admission 网关

状态机（Host 独占写权限）：

```
        rf_admission_open            rf_admission_begin_close
CLOSED ────────────────────► OPEN ─────────────────────────► CLOSING
   ▲                                                             │
   └──────────────── rf_admission_finalize_close ─────────────────┘
```

驱动**永远不能**改 `admission_state`；它只能通过 `rf_producer_claim/release` 改 `producer_owner_token`。

#### `rf_admission_open(mem, epoch)` — [:733](../packages/shared/include/RFSharedAudio.h#L733)

| 项 | 内容 |
| --- | --- |
| 契约 | 写入 epoch，然后 CLOSED → OPEN。成功返回 `RF_ADMISSION_OK` |
| 前置 | 当前状态为 CLOSED；`epoch != 0` |
| 失败 | `ERR_NULL` / `ERR_EPOCH` / `ERR_STATE`。**副作用**：状态检查在写 epoch **之前**；如果 CAS 失败，epoch 已被写入但仍返回 `ERR_STATE` |
| 内存序 | epoch: release store；state: acq_rel CAS。顺序保证"看到 OPEN 的驱动也看到完整头" |
| 检查点 | ① 两次并发 open 是否可能都成功？代码层面**可能**（两个线程都通过状态检查，都写 epoch，只有一个 CAS 成功）——但成功者写入的 epoch 可能已被失败者覆盖。这条竞争真实存在，**之所以不是缺陷**，是因为 Host 侧 `createMemory` 全程持 `mutationLock`（[SharedMemoryManager.swift:191](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L191)），并且跨进程有 `flock` 排除第二个 Host（审计 C1 = FALSE POSITIVE）。② 审阅时若发现任何**绕过 `mutationLock`** 的 `rf_admission_open` 调用点，C1 立刻从假阳性升级为真缺陷 |

#### `rf_producer_claim(mem, token)` — [:799](../packages/shared/include/RFSharedAudio.h#L799)

| 项 | 内容 |
| --- | --- |
| 契约 | admission==OPEN 且 owner 槽为空时占位；已持有同一 token 时幂等成功 |
| 前置 | 非实时线程（`OnStartIO`） |
| 失败 | ① admission 非 OPEN；② owner 被别的 token 占用。**副作用**：CAS 成功后若再次发现 admission 非 OPEN，会回滚 owner 并返回 false（这段回滚是必需的，否则会留下"已关闭 mapping 上的 owner"） |
| 内存序 | owner: acq_rel CAS；`claim_seq`: release fetch_add（仅诊断） |
| 检查点 | ① 幂等分支 `expected == token` 是"Stop→Start 同一 handler"的合法路径，**不要**把它当成"重复 claim 的错误"；② 任何在回调里调用 `rf_producer_claim` 的代码都是缺陷（它有 CAS 可能自旋） |

#### `rf_producer_may_write(mem, token, epoch)` — [:849](../packages/shared/include/RFSharedAudio.h#L849)

三个 acquire load，无 CAS、无分配 —— 这是回调节点唯一允许的 admission 检查。

**检查点**：三个条件缺一不可。特别注意 `epoch` 比较：token 在同一个 handler 生命周期内**不变**，所以只有 epoch 能把 token 绑定到"这一次 mapping 化身"。删掉 epoch 检查 = 允许旧 handler 写新 mapping。

#### `rf_admission_begin_close` / `rf_admission_finalize_close` — [:753](../packages/shared/include/RFSharedAudio.h#L753) / [:772](../packages/shared/include/RFSharedAudio.h#L772)

二者都对 `CLOSING`/`CLOSED` 幂等；`finalize` **拒绝跳过 CLOSING**（为了将来挂 drain 证明）。

**检查点**：CLOSING **不是** drain。它只拒绝新写入，对"已经越过检查、正在写"的回调毫无作用。真正的 drain 证明在驱动侧的 `CallbackGate`（§4.2），不在协议层。

### 2.3 Ring 缓冲

三个写入口，职责不同：

| 函数 | 谁调 | 闸门 |
| --- | --- | --- |
| `rf_ring_write_unchecked` [:924](../packages/shared/include/RFSharedAudio.h#L924) | 只允许 `rf_ring_write` 与 `rf_ring_prefill_before_publish` | 无 |
| `rf_ring_prefill_before_publish` [:1032](../packages/shared/include/RFSharedAudio.h#L1032) | Host，初始化期 | 要求 CLOSED 且 owner==0 |
| `rf_ring_write` [:1066](../packages/shared/include/RFSharedAudio.h#L1066) | Driver 回调 | `rf_producer_may_write` |

#### `rf_ring_write(mem, frames, n, token, epoch, out_dropped)`

| 项 | 内容 |
| --- | --- |
| 契约 | 写入最多 n 帧，返回实际写入帧数；`*out_dropped` = 丢弃帧数 |
| 失败语义 | **被拒绝时零副作用**：W、R、payload、统计全不动，`*out_dropped = n`。参数非法则 `*out_dropped = 0`。调用方用 `(return==0, dropped)` 区分"闸门拒绝"与"参数错误" |
| 溢出 | **Drop-New**：丢弃新帧，绝不覆盖已缓冲数据，绝不阻塞消费者 |
| 内存序 | `load read_index(acquire)` → 写 payload（plain）→ `store write_index(release)`。三个动作的顺序就是 SPSC 的正确性本身 |
| 检查点 | ① `write_index` 只在这一个函数里推进；② 它**从不写** `read_index`（若发现就是 Batch 1 之前的 Drop-Old 回归）；③ `capacity` 非 2 的幂时 fail-closed 返回 0；④ 整帧写入：两个声道要么都落要么都不落 |

#### `rf_ring_read(mem, out, n, out_zero_filled)`

| 项 | 内容 |
| --- | --- |
| 契约 | 读取最多 n 帧，返回实际消费帧数；不足部分**零填充**并计入 `underrun_*` |
| 失败语义 | 参数非法返回 0 且不动 ring；`available > capacity`（头损坏）时全静音、计 underrun、**不推进 R** |
| 关键细节 | 零填充的帧**不计入已消费**，`read_index` 只前进 `frames_to_read`。否则一次 underrun 会永久丢一段数据 |
| 内存序 | `load write_index(acquire)` → 读 payload（plain）→ `store read_index(release)` |
| 检查点 | ① `read_index` 只在这里推进；② 不写 `write_index`；③ 输出始终是 `n * channels` 个 float（不足补零），调用方可以无条件信任缓冲区已填满 |

#### 容量与索引的三个不变式

1. `capacity` 是 2 的幂，`0 < used ≤ capacity`
2. `write_index ≥ read_index`（回绕由 uint64 差值处理）
3. 两侧的 `total_frames_*` 只增不减，用于对账：稳态下 `written - read ≈ used`

### 2.4 心跳与连接观测

| API | 语义 | 检查点 |
| --- | --- | --- |
| `rf_update_driver_heartbeat` [:1214](../packages/shared/include/RFSharedAudio.h#L1214) | 计数 +1，并把 `driver_connected` 置 1 | 在**回调里**调用 → 只有真正产帧时才前进 |
| `rf_update_host_heartbeat` [:1219](../packages/shared/include/RFSharedAudio.h#L1219) | Host 每秒一次 | 由 `DispatchSourceTimer` 驱动 |
| `rf_get_driver_connected/heartbeat` [:1236](../packages/shared/include/RFSharedAudio.h#L1236) / [:1245](../packages/shared/include/RFSharedAudio.h#L1245) | 只读视图（因为 Swift 不能直接读 `_Atomic`） | 一次采样是**时间点快照**，字段之间不同步；判断存活要比较**两次采样** |
| `rf_is_connection_healthy` [:879](../packages/shared/include/RFSharedAudio.h#L879) | 只判 `driver_hb > 0 && host_hb > 0` | **全树零调用者**，且语义不等价于"活着"。真正的 freshness 在 `DriverConnectionTracker`（3/5 采样窗口） |

**审阅要点**：任何"用心跳判断健康"的新代码都应该用 `DriverConnectionTracker` 的窗口模型，而不是 `rf_is_connection_healthy`。

### 2.5 音量状态

两条写路径，**必须区分**：

| 路径 | API | 递增 revision | 用途 |
| --- | --- | --- | --- |
| 原始传输 | `rf_store_volume_scalar` [:1299](../packages/shared/include/RFSharedAudio.h#L1299) / `rf_store_mute_state` [:1308](../packages/shared/include/RFSharedAudio.h#L1308) | **否** | Driver 的 HAL 控件把用户操作写进共享内存 |
| 权威提交 | `rf_publish_volume_state` [:1418](../packages/shared/include/RFSharedAudio.h#L1418) | 是（`fetch_add`） | Host 确认"这就是权威状态"，并 latch `state_initialized` |

#### `rf_publish_volume_state(mem, scalar, muted, mode)`

| 项 | 内容 |
| --- | --- |
| 契约 | 清洗 scalar → 写 scalar/mute/mode → `revision+1` → `state_initialized=1`，全部 release |
| 关键 | 顺序不可换。读者看到 `initialized==1` 就必须能看到配套的值 |
| 检查点 | ① 全树只有 Host 与"驱动首次 bootstrap"调用它；② 任何新增的调用点都要回答"这是权威状态还是原始传输" |

#### `rf_read_volume_state(mem, out)` — [:1369](../packages/shared/include/RFSharedAudio.h#L1369)

| 项 | 内容 |
| --- | --- |
| 契约 | revision 前后各读一次，相等则返回该快照；最多 4 次 |
| 失败语义 | 未初始化返回 false（`out` 不动）；4 次都撕裂则**返回最后一次读到的值并返回 true** |
| 检查点 | ① 这个"重试耗尽仍返回 true"是刻意的（返回 false 会让调用方重置音量），但调用方必须能容忍"跨代混合值"；② 函数只检查 `out != NULL`，**不检查 `mem`**——`rf_is_volume_state_initialized(NULL)` 会解引用空指针（C3）。审阅任何新调用点都要保证 mem 非空 |

#### `rf_sync_driver_volume_state(mem, ctl_scalar, ctl_muted, out)` — [:1478](../packages/shared/include/RFSharedAudio.h#L1478)

三态：`ADOPTED`（已有提交值，控件必须被覆盖）/ `SEEDED`（首次，用控件值播种）/ `REJECTED`（头无效，什么都不做）。

**检查点**：`ADOPTED` 之后**必须**把 `out_state` 推回控件（`RestoreFromSharedMemory`），否则重建的 VolumeControl 会停在 1.0。

### 2.6 EQ 快照

| API | 语义 | 问题 |
| --- | --- | --- |
| `rf_store_eq_snapshot` [:1511](../packages/shared/include/RFSharedAudio.h#L1511) | `seq+1(release)` → `memcpy` → `seq+2(release)` | `eq_snapshot` 是**普通非原子对象**，`memcpy` 与读者的 `memcpy` 并发是 C11 意义上的 UB（C2） |
| `rf_load_eq_snapshot_safe` [:1522](../packages/shared/include/RFSharedAudio.h#L1522) | 最多 4 次，`seq` 奇偶校验 | 只能检测"写期间的撕裂"，不能消除 UB |
| `rf_load_eq_snapshot` [:1538](../packages/shared/include/RFSharedAudio.h#L1538) | 包装，**丢弃返回值** | 重试耗尽时把撕裂值交给调用方；Host 正是用它（[AudioRenderer.swift:605](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L605)） |

**审阅结论模板**（可直接复用）：
> 该 seqlock 的读侧校验是完整的，但 payload 未声明为原子，写侧也未使用 `fetch_add`；因此"校验通过"不等于"没有 UB"。要真正正确，payload 需要是原子字数组或双缓冲索引。

### 2.7 遥测

`rf_get_underrun_count/overrun_count/underrun_frames` [:1561](../packages/shared/include/RFSharedAudio.h#L1561)-[:1569](../packages/shared/include/RFSharedAudio.h#L1569)，全部 acquire 读。

**检查点**：这些计数器只增不减。判读方式是"两次采样求差 + 按连续段切分"，不能看绝对值。

### 2.8 协议层审阅清单（12 条）

- [ ] `rf_shared_audio_size` 是 Host `ftruncate` 的唯一来源
- [ ] `rf_shared_audio_init` 的 admission 初值必须是 CLOSED
- [ ] `rf_validate_header` 之后还有 `validateSharedMemory`（格式/长度）
- [ ] 只有 Host 写 `admission_state` / `admission_epoch`
- [ ] `rf_admission_open` 的所有调用点都在 `mutationLock` 内
- [ ] 回调里只用 `rf_producer_may_write`，不用 `rf_producer_claim`
- [ ] `rf_ring_write` 不写 `read_index`；`rf_ring_read` 不写 `write_index`
- [ ] 零填充帧不推进 `read_index`
- [ ] `rf_publish_volume_state` 是唯一递增 revision 的地方
- [ ] `rf_read_volume_state` 的调用点都保证 mem 非空
- [ ] EQ 读侧的失败分支没有被忽略（当前**违反**）
- [ ] 五份头文件副本 `sync_shared_header.sh --check` 全绿

---

## 3. DSP C API

权威声明在 [packages/dsp/include/soundbridge_dsp.h](../packages/dsp/include/soundbridge_dsp.h)（315 行）。

### 3.0 先看一个真实的一致性缺口

```
packages/dsp/include/soundbridge_dsp.h                    315 行
packages/host/Sources/CSoundBridgeDSP/include/soundbridge_dsp.h  259 行   ← Host 实际编译用的
```

两文件 `diff` 的实质差异（不是注释）：Host 副本**缺少**三个声明：

- `soundbridge_dsp_update_band_frequency`
- `soundbridge_dsp_update_band_q`
- `soundbridge_dsp_enable_denormal_suppression`

[静态] 后果有三点，按风险排序：

1. **频段频率/Q 无法在运行期调整**。这解释了 E2 的现象：App 只能发增益，频率永远来自 `applyInitialPreset`。如果将来有人想加"频率可调"，他会发现"函数不存在"，而不是"实现有问题"。
2. **音频线程无法开启 FTZ/DAZ**。`soundbridge_dsp_create` 内部确实调了 `enable_denormal_suppression()`（[engine.cpp:74-76](../packages/dsp/src/engine.cpp#L74-L76)），但 FTZ/DAZ 是 **per-thread** 的；create 发生在 Host 初始化线程，渲染回调在另一个线程。Host 头文件里没有这个函数，所以渲染线程从未设置。IIR 滤波器在静音/极低电平输入下容易进入 denormal，官方注释称可能带来 10–100× 降速。
3. 两个副本的注释还把 `apply_preset` 描述成"参数立即生效"vs"~50 ms 斜坡"，互相矛盾。

**这是 [静态] 结论，性能影响 [未验证]**。要取证需要 `powermetrics` 或 Instruments 在"长时间静音后开始播放"场景下对比。审计报告未收录此项，本文首次记录。

### 3.1 生命周期

#### `soundbridge_dsp_create(sample_rate)` — [:46](../packages/dsp/include/soundbridge_dsp.h#L46)

| 项 | 内容 |
| --- | --- |
| 契约 | 分配 engine，初始化 10 段 biquad、smoother、limiter、dc_blocker，返回句柄或 NULL |
| 前置 | **非实时线程**（会 malloc） |
| 检查点 | ① 调用点在 Host 初始化路径，不在回调；② 返回 NULL 必须被处理（当前 `AudioRenderer` 会走无 DSP 直通，属可接受降级） |

#### `soundbridge_dsp_destroy(engine)` — [:56](../packages/dsp/include/soundbridge_dsp.h#L56)

**审计结论 A4 [静态]**：唯一调用点是 `AudioRenderer.DSPHolder.deinit`，而 renderer 是顶层 `let` 且回调以 `passUnretained` 捕获 → deinit 永不执行，destroy 在生产中不会被调用。这不构成 UAF（进程退出回收），但它是"依赖未声明的生命周期假设"。

#### `soundbridge_dsp_reset(engine)` — [:66](../packages/dsp/include/soundbridge_dsp.h#L66)

| 项 | 内容 |
| --- | --- |
| 契约（声明） | "Reset engine state (clear filter history)" |
| 实际（[engine.cpp:123-137](../packages/dsp/src/engine.cpp#L123-L137)） | 只重置 `bands`、`dc_blocker`、`frames_processed`、`underrun_count` |
| 未重置 | limiter、preamp smoother、`peak_left/right`、`cpu_load_percent` |
| 审阅检查点 | 任何"调用 reset 后诊断值归零"的假设都不成立（B2）；`reset` 也会**打断** preamp 平滑但不清零（smoother 保持当前值），所以不要把它当"重新开始" |

#### `soundbridge_dsp_set_sample_rate(engine, rate)` — [:78](../packages/dsp/include/soundbridge_dsp.h#L78)

| 项 | 内容 |
| --- | --- |
| 契约 | 改采样率、重算全部系数、重新初始化 smoother/dc_blocker、重放当前 preset |
| 前置 | 速率 ∈ [8000, 384000]；**不得**与 `process_*` 并发 |
| 副作用（重要） | `preamp_smoother.init()` 无条件把 `current_/target_/velocity_` 归零 → 下一块从 0 起坡（A3，[实测] 70 ms 内恢复）；`apply_preset(&engine->current_preset)` 产生自重叠 `memcpy`（UB，实践可用） |
| 检查点 | ① 内部没有校验"band 频率 < Nyquist"（B3 的根因之一）；② 调用方是否真的停住了渲染线程——Host 是 `waitForRenderPathIdle` 轮询，属 check-then-act（A1 条件性） |

### 3.2 处理

#### `soundbridge_dsp_process_interleaved(engine, in, out, frames)` — [:99](../packages/dsp/include/soundbridge_dsp.h#L99)

| 项 | 内容 |
| --- | --- |
| 契约 | 处理 `frames` 个**立体声**帧；in/out 可同一指针 |
| 前置 | `frames` ≥ 0；缓冲区至少 `frames*2` float；engine 非空 |
| 返回值 | `void` —— 无错误通道。这是审阅时的关键信号：**任何内部失败都不能上报**，所以内部必须保证"最坏情况也只是直通" |
| 检查点 | ① 只支持 2 声道（Host 在 [AudioRenderer.swift:603](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L603) 显式判断 `channelCount == 2`，非 2 声道直接跳过 DSP）；② 输出是否可能出现非有限值——B3 证明**可以**，且 `dc_blocker`/limiter 没有守卫；③ 与 planar 版本是否等价（B4 [实测] PASS，测试覆盖在 `test_engine.cpp`） |

#### `soundbridge_dsp_process_planar(...)` — [:120](../packages/dsp/include/soundbridge_dsp.h#L120)

同一套内部实现，左右分开。**审阅陷阱**：若调用方把 `output_left` 与 `output_right` 指向同一缓冲，preamp 会被乘两次（本次审计的探针就踩过，实测 +12 dB 变 +24 dB）。生产路径不用 planar，但任何新调用点都必须检查这一点。

### 3.3 参数

| API | 实时性声明 | 实际 | 检查点 |
| --- | --- | --- | --- |
| `apply_preset` [:144](../packages/dsp/include/soundbridge_dsp.h#L144) | 非 RT | 重算系数 + 自重叠 memcpy | 值域校验只查 [20, 20000]，**不查 Nyquist**（B3） |
| `preset_validate` [:176](../packages/dsp/include/soundbridge_dsp.h#L176) | 非 RT | 只返回值域检查 | 同上；这是 B3 唯一可能拦住的地方 |
| `set_bypass` [:191](../packages/dsp/include/soundbridge_dsp.h#L191) | RT | 原子 store | bypass 分支仍更新 peak/frames，但**不更新 CPU**（B1） |
| `update_band_gain` [:212](../packages/dsp/include/soundbridge_dsp.h#L212) | RT | 写 smoother 目标值（非原子） | 只允许单写者（Host 在 IO 线程调用，见 A1） |
| `update_preamp` [:226](../packages/dsp/include/soundbridge_dsp.h#L226) | RT | 同上 | 同上 |
| `update_band_frequency` / `_q` [:241](../packages/dsp/include/soundbridge_dsp.h#L241) / [:257](../packages/dsp/include/soundbridge_dsp.h#L257) | RT | 重算该段系数 | **Host 副本里没有声明**（§3.0）；若将来启用，必须同时校验 Nyquist |

**参数层的统一审阅问题**：`num_active_bands`、`current_preset`、`limiter_enabled`、`bands[i]` 都是**普通字段**。其安全性完全依赖"只有一个线程写"这条调用约定，引擎内部没有任何 atomic 或断言兜底。审阅新调用点时，先问"它跑在哪个线程"。

### 3.4 诊断

| API | 语义 | 检查点 |
| --- | --- | --- |
| `get_stats(engine, out)` [:275](../packages/dsp/include/soundbridge_dsp.h#L275) | 拷贝 `peak_*`、`frames_processed`、`underrun_count`、`cpu_load_percent` | 唯一调用点在 `bridge/SoundBridgeDSPEngine.mm`，而该 bridge **未被 Host/App 引用** → 生产上无人读取（NOTES） |
| `get_version()` [:285](../packages/dsp/include/soundbridge_dsp.h#L285) | 版本串 | — |
| `enable_denormal_suppression()` [:309](../packages/dsp/include/soundbridge_dsp.h#L309) | 设置当前线程 FTZ/DAZ | 见 §3.0 第 2 点：Host 无法调 |

### 3.5 DSP 审阅清单（10 条）

- [ ] `create/destroy/apply_preset/set_sample_rate` 都不在音频线程
- [ ] `process_*` 的 `frames` 与缓冲区长度匹配，且声道数为 2
- [ ] planar 调用没有缓冲区别名
- [ ] band 频率在**所有**入口（preset、update_band_frequency、反序列化）都被 Nyquist 校验（当前**违反**）
- [ ] `set_sample_rate` 前渲染线程确实空闲（Host 只是轮询，属条件性）
- [ ] `reset` 的语义与调用方期望一致（当前**不一致**）
- [ ] bypass 分支的统计行为被显式接受（当前 peak 衰减、CPU 冻结）
- [ ] limiter 的立体声行为与产品声明一致（当前**无联动**）
- [ ] 输出非有限值的可能路径已被识别（当前 `dc_blocker`/limiter 无守卫）
- [ ] Host 的 `soundbridge_dsp.h` 副本与权威版本差异是**有意**裁剪，并已在文档中登记（当前无登记）

---

## 4. Driver 内部 API

### 4.1 控制面

#### `readControl(path)` — [ControlProtocol.hpp:122](../packages/driver/src/ControlProtocol.hpp#L122)

| 项 | 内容 |
| --- | --- |
| 契约 | 读取并解析 `/tmp/soundbridge-devices.txt`，返回 `ControlSnapshot`（status / session / revision / ownerUID / devices） |
| 安全属性 | `O_NOFOLLOW`（拒符号链接）、`S_ISREG`、大小上限 1 MiB、`fstat.st_uid == header.ownerUID` |
| 失败 | 返回带 `status` 的空快照，**从不抛异常**；调用方必须检查 `status == valid` |
| 检查点 | ① header 行必须恰好 6 个字段（多一个就整份拒绝）；② 设备行必须恰好一个 `|`；③ 行数与 header 的 `count` 必须相等——这是"半写文件"检测 |

#### `validateSharedMemory(mem, fileSize, session)` — [ControlProtocol.hpp:165](../packages/driver/src/ControlProtocol.hpp#L165)

| 项 | 内容 |
| --- | --- |
| 契约 | 在 `rf_validate_header` 之上补齐"长度与格式"这一半：文件大小 ∈ [sizeof(RFSharedAudio), 64 MiB]、session 匹配、`format ≤ INT32`、`bytes_per_sample` 与 format 一致、`bytes_per_frame == channels * bps`、`capacity ≤ (fileSize - header) / bytes_per_frame` |
| 为什么必须 | `rf_validate_header` 不看长度。少了这一半，`capacity` 可以是任意大，ring 写就会写到 mapping 之外（审计里这条是 FALSE POSITIVE，因为驱动**确实**调了它） |
| 检查点 | ① 最后一个不等式是唯一的越界防线；② 新增 format 时必须同时更新 `rf_bytes_per_sample` 与这里 |

#### `inspectHostLock(path, ownerUID, session)` — [ControlProtocol.hpp:221](../packages/driver/src/ControlProtocol.hpp#L221)

用 `flock(LOCK_EX|LOCK_NB)` 试探 + `fstat/lstat` 的 dev/ino 一致性判断"Host 是否活着"。

**检查点**：`held` 才允许继续；`unheld` 表示 Host 已退出（或从未启动）；`unknown`（权限、符号链接、inode 变化）必须 fail closed。**不要**把 `unknown` 当成 `held`。

### 4.2 发布与退役

#### `CallbackGate` — [MappingRetirement.hpp:158](../packages/driver/src/MappingRetirement.hpp#L158)

一个 32 位字同时承载"门是否关闭"（bit31）与"当前有多少回调在内"（bit0-30）。

| API | 语义 | 检查点 |
| --- | --- | --- |
| `TryEnter()` [:180](../packages/driver/src/MappingRetirement.hpp#L180) | 一次 `fetch_add(acq_rel)`；若 previous 带 CLOSED 位则 `fetch_sub` 撤销并返回 false | ① 失败路径**没有**加载 mapping 指针（正确）；② 计数饱和断言只在 debug 生效 |
| `Leave()` [:195](../packages/driver/src/MappingRetirement.hpp#L195) | 一次 `fetch_sub` | 必须与 TryEnter 严格配对；用 RAII（`CallbackLease`）保证早退也归还 |
| `CloseAndDrain(timeout)` | 置 CLOSED 位，轮询计数到 0 | **超时 = 未证明**，不是"完成" |
| `DrainOutcome` [:116](../packages/driver/src/MappingRetirement.hpp#L116) | `Drained` / `TimedOut` / `NothingToRetire` | `TimedOut` 必须走 quarantine，绝不能 munmap |

协议义务 O1–O5（文件头注释）是本仓库最严谨的一段并发证明。审阅时的最小检查集：

- 读者"是否开放"与"计数+1"是同一次 RMW（否则存在"门看起来关、计数看起来没我"的窗口）
- 关闭者 `fetch_or(CLOSED)` 之后不再有新读者进入
- 关闭者读到 0 ⇒ 稳定为 0 ⇒ 才允许 munmap
- 超时只影响"等多久"，绝不影响"是否安全"

#### `PublishedSharedMemory` — [ControlProtocol.hpp:193](../packages/driver/src/ControlProtocol.hpp#L193)

`store/acquire/retire`，内部 `std::mutex`。

**检查点**：`retire()` 把 `retired_` 置真后 swap 出旧指针，**之后 store 一律被忽略**——所以"退役后重新发布"必须新建对象，不能在同一个 `PublishedSharedMemory` 上复活。

#### `MappingQuarantine`

drain 超时的映射永久保留（不 munmap）。**检查点**：quarantine 是"泄漏换安全"的刻意选择；任何"清理 quarantine 以回收地址空间"的改动都必须先证明那个回调已经返回——而它没有返回，这正是问题本身。

### 4.3 IO 路径

#### `OnWriteMixedOutput(...)` — [Plugin.cpp:733](../packages/driver/src/Plugin.cpp#L733)

顺序与每个闸门：

```
stats_.total_writes++
retired_ || !gate.TryEnter()  → 丢弃           // :745
CallbackLease  (RAII)                          // :752
mem = SharedMemory(); null → 丢弃              // :757
rf_update_driver_heartbeat(mem)                // :764
fmt = stream->GetPhysicalFormat()
fmt.mBytesPerFrame == 0 → 丢弃                 // :769
frameCount = bytesCount / mBytesPerFrame
frameCount == 0 → 丢弃                         // :775
格式变化 → HandleFormatChange (分配)           // :788  ← D1
interleaved_buf_.size() < needed → resize      // :794  ← D1
ConvertToFloat32Interleaved(...)               // :798
时间戳间隙 → prepend_silence / skip            // :805-817
输入速率 ≠ ring 速率 → ProcessWithSampleRateConversion  // :820
否则 → WriteWithAdaptiveDriftCompensation      // :837/:844
stats_.LogPeriodic()                           // :849  ← D1
```

审阅检查点（每一条都能独立成为 finding）：

1. 门在**取指针之前**关闭（`TryEnter` 失败就不 load）——顺序正确
2. `CallbackLease` 覆盖所有 return——正确，这是 drain 能证明的前提
3. 回调里是否出现 `open/stat/mmap/log/resize`——当前**有 4 处 resize + 1 处日志**（D1）
4. `fmt.mBytesPerFrame == 0` 与 `frameCount == 0` 都 fail-closed——正确
5. 时间戳补偿的 `prepend_silence_frames` 被 `silence_buf_` 容量截断——正确，但要注意它可能在一次回调里多写半环
6. `stats_.LogPeriodic()` 每帧调用，内部按时间窗口输出——不分配但会 `os_log`

#### `HandleFormatChange` / `ResizeBuffers` — [:1215](../packages/driver/src/Plugin.cpp#L1215) / [:1201](../packages/driver/src/Plugin.cpp#L1201)

负责在格式变化时重建 `interleaved_buf_`、`resampled_buf_`、`silence_buf_`。

**检查点**：这里的目标是"把分配集中在格式变化那一刻"，但实现放在了**回调内部**，所以那一刻就是一次带分配的实时回调。正确的形态是在 `OnStartIO` 按协商格式预分配，并在回调里**拒绝**超容量请求而不是扩容。

#### `ConvertToFloat32Interleaved` — [:1231](../packages/driver/src/Plugin.cpp#L1231)

| 分支 | 行为 | 检查点 |
| --- | --- | --- |
| Float32 | 直通 | — |
| Float64 | 按 32 位 fail-closed | 正确 |
| Int16/Int32 | 仅 interleaved | **不支持 non-interleaved**（D2） |
| Int24 | 按 3 字节步进 | **不识别 24-in-32**（`mBytesPerFrame == 4*ch` 时会错位）（D2） |

#### `ProcessWithSampleRateConversion` — [:1289](../packages/driver/src/Plugin.cpp#L1289)

`SimpleResampler`（线性插值），受 `output_capacity` 上限保护。**检查点**：`output_capacity` 必须 ≥ `ceil(n * dst/src) + 余量`，且结果要被截断而不是溢出。

#### `WriteWithAdaptiveDriftCompensation` — [:1318](../packages/driver/src/Plugin.cpp#L1318)

按历史漂移微调写入速率（±ppm 级），避免 ring 长期单向漂移。**检查点**：漂移调整只能影响"写多少"，不能影响"写哪个槽"，否则会破坏 SPSC。

### 4.4 音量/静音控件

| API | 语义 | 检查点 |
| --- | --- | --- |
| `SetRawValueImpl(value)` [:306](../packages/driver/src/Plugin.cpp#L306) | 调基类实现，然后 `rf_store_volume_scalar`（**不 bump revision**） | 先调基类再写共享内存——顺序影响 HAL 回读一致性 |
| `RestoreFromSharedMemory(scalar)` [:298](../packages/driver/src/Plugin.cpp#L298) | 把权威值推回控件，带抑制窗口防回声 | 抑制窗口可能吞掉窗口内的真实用户改动（C3） |
| `SyncVolumeStateWithSharedMemory(mem)` [:964](../packages/driver/src/Plugin.cpp#L964) | `OnStartIO` 时 ADOPTED/SEEDED/REJECTED 三分支，最后**总是**把值推回控件 | `REJECTED` 必须直接 return，不碰控件——当前正确 |

### 4.5 Driver 审阅清单（12 条）

- [ ] `OnWriteMixedOutput` 全路径无分配、无 `os_log`（当前**违反**）
- [ ] `CallbackLease` 覆盖所有 return
- [ ] `TryEnter` 失败时未加载 mapping 指针
- [ ] `CloseAndDrain` 超时走 quarantine，绝不 munmap
- [ ] `OpenSharedMemory` 做了 dev/ino + session + 容量三重校验
- [ ] `ValidateConnection` 调用了 `validateSharedMemory`（不只是 `rf_validate_header`）
- [ ] 格式矩阵覆盖 non-interleaved 与 24-in-32（当前**违反**）
- [ ] 恢复路径重新 claim producer（当前**没有**，且无调用者）
- [ ] `driver_connected` 只在 ValidateConnection 置 1、Disconnect 置 0
- [ ] 音量写回不 bump revision 是**有意**的，并有文档
- [ ] 退役后不再 `store` 新映射到同一个 `PublishedSharedMemory`
- [ ] `MonitorControlFile` 的轮询与 notify 不会重入 `SyncDevices`

---

## 5. Host Swift API

Host 是唯一同时接触"共享内存的诞生"和"CoreAudio 输出"的进程。它的 Swift 层分四块，职责边界比命名更清楚：

| 类型 | 文件 | 谁调它 | 能不能在 IO 线程上跑 |
| --- | --- | --- | --- |
| `SharedMemoryManager` | [SharedMemoryManager.swift](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L51) | `DeviceMonitor` / `main.swift` / `DeviceLifecycle` | **只有两个方法可以**：`enterRenderMemory` / `exitRenderMemory`。其余全是控制面 |
| `AudioRenderer` | [AudioRenderer.swift](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L147) | CoreAudio 的回调（`render`）；`AudioEngine`（其余） | `render` 是唯一的 RT 入口 |
| `AudioEngine` | [AudioEngine.swift](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L8) | `DeviceMonitor` / 恢复流程 | 不可以。全是 `AudioUnitSetProperty` 级别的调用 |
| `ProxyDeviceManager` | [ProxyDeviceManager.swift](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L7) | 设备回调、生命周期、`DeviceMonitor` | 不可以。它注册的 HAL 监听回调跑在 coreaudiod 的线程上，但那是**另一个** RT 面 |

审阅 Host 代码时先问一句"这个方法会出现在 render 回调的调用栈上吗"，答案几乎总是"不会"，除了 `SharedMemoryManager` 的两个租约方法和 `AudioRenderer.render` 本身。搞错这一点，就会把控制面的锁误判成 RT 违规。

### 5.1 `SharedMemoryManager`

#### `beginSession(_ id: UUID)` [:88](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L88)

- **契约**：为本进程的这次运行确定一个 `sessionID`。它会被写进每个 mapping 头的 `_reserved`（`"SB6A"` + 16 字节 UUID），是所有"这个 mapping 是不是同一个 Host 造的"判断的根。
- **前置**：`main.swift` 拿到 `HostInstanceLock` **之后**才调用。锁在则 session 唯一；顺序反了就会出现两个 session 写同一批文件。
- **失败**：无返回值，无失败路径——这是刻意的：session 是内存里的一个 `UUID?`，赋值不可能失败。
- **内存序 / 线程**：`os_unfair_lock` 保护。读侧在 `createMemory` 里取一次快照（[:198](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L198)），之后整段创建流程只用这份快照。
- **检查点**：`beginSession` 之后 `sessionID` 必须非 nil，否则 `createMemory` 直接返回（[:201](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L201)）。**不存在"空 session 兜底"分支**，这是好事。

#### `createMemory(for uid:persistence:)` [:188](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L188)

这是整个项目里顺序性最强的一个函数。它把"创建 → 初始化 → 预填 → 开启准入 → 原子发布"五个阶段压成一条直线，任何一个阶段换序都会破坏某个不变式。逐步对照：

| # | 动作 | 行号 | 为什么不能换序 |
| --- | --- | --- | --- |
| 1 | `mutationLock.lock()` | [:191](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L191) | 防止同进程内两个 UID 同时创建，也防止与 `cleanup`/`removeMemory` 交叉 |
| 2 | `probeExisting(path:)` | [:210](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L210) | **必须在覆盖之前**：旧进程最后一次提交的音量只能在这里读到，之后文件就被替换了 |
| 3 | `open(staging, O_CREAT\|O_EXCL\|O_NOFOLLOW)` | [:216](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L216) | 独立 inode。读者看不到半初始化的头；`O_NOFOLLOW` 防符号链接抢占 |
| 4 | `fchmod(0o666)` | [:225](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L225) | Driver 以 root/audio 身份打开，权限不够就连不上 |
| 5 | `rf_ring_capacity_frames_for` + `rf_shared_audio_size` | [:236](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L236) | 必须用与 `rf_shared_audio_init` 内部**同一个**取整函数，否则文件比头声明的短，`audio_data` 被截断 |
| 6 | `ftruncate` + `mmap(MAP_SHARED)` | [:249](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L249) | 大小定死后再映射，之后不再改变 |
| 7 | `rf_shared_audio_init` | [:266](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L266) | 写头、校验和式字段、初始化原子量 |
| 8 | `rf_set_host_session` | [:276](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L276) | 在 `state_initialized` 之前写，Driver 一旦 attach 就能校验来源 |
| 9 | `VolumeStateResolver.resolve` + `rf_publish_volume_state` | [:281](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L281) | **只提交一次**。注释说得对：Driver 第一次 `OnStartIO` 就应该看到 `state_initialized == 1`，否则它的 seqlock 读会走重试路径 |
| 10 | `rf_ring_prefill_before_publish`（半环静音） | [:309](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L309) | 冷启动时消费者不和生产者抢。写入口自带"admission 已 OPEN 或已有 owner 就拒绝"，所以不可重入 |
| 11 | `rf_admission_open(epoch)` | [:324](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L324) | **在 rename 之前**。文件一旦可达，Driver 就可能来 claim；此时状态必须是 OPEN |
| 12 | `fstat` + `rename(staging → shmPath)` | [:332](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L332) | 原子发布点。`fstat` 拿到的 dev/ino 是之后"这个路径还是不是我造的"的唯一凭据 |
| 13 | 写 `deviceMemory[uid]`、`origins[uid]` | [:341](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L341) | 对象先入表，再让渲染路径看到 |
| 14 | `refreshRenderMemory()` | [:346](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L346) | 发布到 `rf_rt_gate`。此刻回调若正在旧 mapping 里，会走延迟发布而不是原地换指针 |

三个容易审错的地方：

1. **第 2 步与第 12 步之间没有全局互斥**。两个 Host 进程各自持有自己的 `HostInstanceLock`，但同一个 `/tmp` 路径仍可能被并发创建。代码注释里明确写了"这不构成跨用户互斥"——这是**已知边界**，不是 bug；真正防跨进程的是 `HostInstanceLock` + 文件名里的 `ownerUID`。
2. **第 11 步的 epoch 是 `UInt64.random(in: 1...UInt64.max)`**（[:323](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L323)）。它只需要"与上一次不同"，不需要密码学强度；但审阅时要注意它**不是**用来做安全边界的。
3. **第 14 步的返回值没人检查**。`publishRenderMapping` 可能返回 `false`（延迟发布），`refreshRenderMemory` 把它丢了。这在功能上没问题（心跳会 drain），但意味着"创建成功后立刻有音频"不是立即成立的——要等下一次心跳或下一次回调租约释放。

#### `publishVolumeState(for:scalar:muted:mode:)` [:366](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L366) / `readVolumeState(for:)` [:384](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L384)

- **契约**：写路径是 Host 的**权威**音量写入——bump `state_revision`、latch `state_initialized`；读路径是 `rf_read_volume_state` 的 4 次重试版。
- **失败**：写返回 `false` 只在"没有 mapping"时发生，不会因为 seqlock 失败而返回 false。读返回 `nil` 同理。
- **内存序 / 线程**：`acquireMemory` 只拿 `os_unfair_lock` 取对象引用，之后用 `withExtendedLifetime` 撑住，**不持锁跨 C 调用**。这是正确的：C 侧的原子量自己负责序。
- **检查点**：`readVolumeState` 把 `snapshot.muted != 0` 转成 `Bool`，把 `initialized` 硬编码为 `true`（[:393](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L393)）。后者是**谎报**：C 函数返回 true 也可能只是读到了未初始化的零值（见 §2.5 的 C3）。审阅时若看到上层用这个 `initialized` 做分支判断，那就是 C3 的一个真实消费者。

#### `removeMemory(for:ifGeneration:)` [:398](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L398)

- **契约**：摘掉一个 UID 的映射，并在**代际匹配**时才真正删除。`ifGeneration` 存在的原因是：异步路径（比如设备拔出的通知）可能在 Host 已经重建 mapping 之后才到达，此时删掉的是新映射。
- **前置**：持有 `mutationLock`（函数内取）。
- **失败**：`ifGeneration` 不匹配时静默返回——这是对的，但意味着调用方无法区分"删掉了"和"没删"。审阅时检查是否有调用方依赖这个返回值，目前没有。
- **内存序 / 线程**：先 `os_unfair_lock` 摘表，再 `refreshRenderMemory()`（可能延迟发布），再 `revokeAdmission`（CLOSING），最后 `unlinkIfStillOwned`。
- **检查点**：顺序是"**先摘渲染路径，再撤准入，再删文件**"。反过来就会出现：Driver 已经 claim 成功但文件已经 unlink——虽然旧映射仍然有效（inode 未释放），但下一次 `open` 必然失败，设备会错误地显示"驱动未连接"。

#### 渲染路径的三个原语：`enterRenderMemory` / `exitRenderMemory` / `publishRenderMapping`

这是全项目最容易读错的一段。它不是引用计数，而是**单槽 + 租约 + 延迟发布**：

```
控制线程                                    IO 线程
publishRenderMapping(new)
  ├─ rf_rt_gate_try_publish(new) 成功 ──► 下一个 enter 拿到 new
  └─ 失败（旧租约还在）→ renderPendingMapping = new
                                          enterRenderMemory()
                                            rf_rt_gate_enter → 拿旧指针 + 计数 +1
                                            ... 用裸指针 ...
                                          exitRenderMemory()
                                            rf_rt_gate_exit → 计数 -1
心跳 drainDeferredRenderPublication()
  └─ 再 try_publish(pending)
```

- **`enterRenderMemory`** [:453](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L453)：一次 `rf_rt_gate_enter`，失败返回 nil。**不分配、不日志、不读 String、不释放对象、不等锁**——注释里的四条承诺必须字面成立。
- **`exitRenderMemory`** [:460](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L460)：必须只在 enter 返回非 nil 时调用。不平衡的 exit 会让 `rf_rt_gate` 的在途计数永远大于 0，此后所有发布都变成 pending——**表现为"切设备后没声音，但重启 Host 就好了"**。
- **`publishRenderMapping`** [:515](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L515)：返回 `Bool`。`false` 表示"已挂起"。**换指针成功时绝不回滚**：可能有读者已经拿到了旧指针，回滚无法撤回。
- **`retireRenderPath`** [:569](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L569)：**这是 Host 侧唯一允许"超时后仍然释放"的地方**，注释写明是 shutdown 专用，并计数 `renderRetireTimeouts`。对比 Driver 侧的 `CloseAndDrain` 超时走 quarantine、绝不 munmap——两者不矛盾：Host 释放的是**自己进程的**映射，且进程即将退出；Driver 释放的是**别人给的**映射，进程还要继续服务新映射。

审阅要点：`retireRenderPath` 里 `rf_rt_gate_force_publish(nil)` 之后立刻让 `lastMapping`/`retired` 离开作用域（[:592](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L592)）。如果此时真有回调在里面，它会继续读已 munmap 的地址——这是**已知且被接受的**关闭期风险，`cleanupWaitTimeout`（1.2 s）就是留给它的窗口。

#### `connectionObservation(for:)` [:618](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L618)

- **契约**：返回五元组 `{headerValid, driverConnected, driverHeartbeat, hostHeartbeat, mappingToken}`。全部是 C11 原子 load。
- **关键**：`mappingToken` 是 `mapping.generation`（一个 `UUID`），不是 `admission_epoch`。注释解释了原因：新建的 mapping 里 `driver_connected` 是 0，读数者必须能区分"驱动还没 attach"和"驱动掉线了"。
- **失败**：无 mapping 时返回 `nil`，调用方必须把它当成"未知"而不是"未连接"。审阅时看 `DriverConnectionTracker` 如何处理 nil——如果 nil 被折叠成 `.disconnected`，就会出现启动瞬间的假告警。
- **检查点**：五个字段不是同时更新的。"比较相邻两次采样"是唯一正确的用法；任何"单次采样下结论"的代码都有竞态。

#### `startHeartbeat()` [:653](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L653)

做四件事，顺序固定：

1. `cancel()` 旧的 timer 再新建 → "恰好一个心跳定时器"由构造保证（注释记录了旧实现每轮泄漏一个 timer 的 bug）。
2. `drainDeferredRenderPublication()` → 延迟发布只在这里和 `removeMemory`/`cleanup` 落地，**永远不在回调里**。
3. 遍历 `deviceMemory` 写 `rf_update_host_heartbeat`。
4. 每 5 次（约 5 s）打一条 telemetry：`inFlight` / `deferred` / `retireTimeouts` / underrun / overrun 增量。

审阅要点：第 3 步拿的是 `Array(deviceMemory)` 快照，然后逐个 `withExtendedLifetime`。这是对的——心跳期间允许设备上下线。

#### `cleanup()` [:721](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L721)

`isClosed = true` → `retireRenderPath(1.2 s)` → 清表 → 每个 mapping `revokeAdmission` + `unlinkIfStillOwned`。

`revokeAdmission` [:753](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L753) 的注释是全书最重要的一条设计声明：

> CLOSING 立刻阻止未来所有 producer 写入。它**不是** drain proof：已经过闸门的回调可能还在跑，这正是 mapping 不被复用的原因——文件被 unlink、租约被丢弃，旧字节永远不会交给新化身。`finalize_close()` 故意不在这里调用。

也就是说：项目里**没有任何生产代码调用 `rf_admission_finalize_close`**。审阅时若看到有人"补上"这个调用，要立刻警觉——那会宣称一个没有被证明的排空。

### 5.2 `AudioRenderer`

#### `createRenderCallback()` [:477](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L477)

一个 `AURenderCallback` 的 Swift 闭包包装。**唯一的职责是把 C 函数指针和 `renderer` 的 `Unmanaged` 指针交出去**。审阅时要看它是否 `passUnretained`：`AudioEngine.setRenderCallback` 用的是 [:334](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L334) 的 `passUnretained(renderer)`，安全性依赖"renderer 的生命周期覆盖 AudioUnit"，这在当前结构下成立（两者都是 `AudioEngine` 的强引用成员）。

#### `render(bufferList:frameCount:)` [:502](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L502)

八个出口，每个都必须在**任何写入之前**决定，且除正常路径外都要输出静音：

| # | 条件 | 行号 | 输出 | 诊断计数 |
| --- | --- | --- | --- | --- |
| 0 | 首次回调 | [:518](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L518) | 正常 | `recordFirstPass` |
| 1 | `frameCount > maxCallbackFrames` 或 `channels > 8` | [:526](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L526) | 静音 | `capacityExceeded` + `silenceFallback` |
| 2 | `enterRenderMemory()` 返回 nil | [:534](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L534) | 静音 | `memoryUnavailable` |
| 3 | `ringChannels != channelCount` | [:553](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L553) | 静音 | `channelMismatch` |
| 4 | `framesRead == 0` | [:594](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L594) | 静音（环里本来就没数据） | `silenceFallback` |
| 5 | 正常 | — | 读到的数据 / DSP / 音量 / 反交织 | `underrun`（若有） |

- **契约**：绝不抛异常、绝不分配、绝不加锁、绝不日志。`defer { exitRenderMemory() }`（[:542](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L542)）覆盖全部路径——这一条是出口 2 之后所有代码正确的前提。
- **前置**：`renderBuffer` 不是 Swift 数组，而是 `init` 里一次性 `allocate(capacity: renderCapacityFrames * renderCapacityChannels)` 的裸缓冲（[:218](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L218)、[:227](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L227)），`deinit` 里释放（[:259](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L259)）。所以 [:561](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L561) 的 `update(repeating:count:)` **只是一次 memset，不会分配**——这一点已核实，出口 1 的容量 guard 与预分配尺寸严格一致（`maxCallbackFrames × maxCallbackChannels`）。这是全项目少见的"零分配 + 有证明"的 RT 缓冲。
- **失败语义**：出口 1-4 全部 `outputSilence`。**没有"部分输出"路径**——要么整块，要么静音。
- **内存序 / 线程**：`mem.pointee.sample_rate`（[:568](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L568)）是一次普通 load。**这与头文件声明一致**——`sample_rate` 本来就是非原子的 `uint32_t`（[RFSharedAudio.h:245](../packages/shared/include/RFSharedAudio.h#L245)），所以不是"类型用错"，而是**协议本身把格式字段放在了非原子区**：一旦 Host 在运行中改写 `sample_rate`（当前只在新建 mapping 时写，所以暂时不可达），IO 线程读它就构成 C11 数据竞争。审阅结论应写成"当前安全、依赖'运行期不改格式'这一未文档化的约束"，而不是"实现有 bug"。`rf_ring_read` 自己带 acquire。
- **检查点**：`renderSampleRate` 只在 `mappingRate >= 8_000` 时更新（[:547](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L547)）——这是防止头未初始化时用 0 做除数。审阅时要确认所有用到 `renderSampleRate` 的地方都有这个下界保护。

#### `updateSampleRate(_:)` [:460](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L460)

- **契约**：重建 DSP 的 biquad 系数。
- **前置**：**`AudioOutputUnitStop` 之后**。`AudioEngine.switchDevice` 在 [:227](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L227) 调用它，注释明确写了"绝不能在 IO 线程还在 `process_interleaved` 里时调"，因为 DSP 参数层不是原子的。
- **失败**：返回 `Bool`。审阅时看调用方是否检查——`setupWithDevice`（[:129](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L129)）**丢弃了返回值**。若 `updateSampleRate` 失败（比如采样率为 0），下一次处理会用旧系数配新速率，EQ 频响整体偏移。这是 B3 的一个放大因素。

### 5.3 `AudioEngine`

#### `setup(devices:preferredDeviceID:)` [:39](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L39)

- **契约**：绑定一个物理输出设备，优先 `preferredDeviceID`，失败则按"已验证优先"的顺序回退。
- **前置**：函数内先 `stop()`（[:49](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L49)）。注释解释了原因：恢复流程会在**活着的**引擎上重入，不先停就会泄漏一个仍持有 render 回调的 `AudioComponentInstance`——那个实例会继续在共享内存环里当 producer。
- **失败**：抛 `AudioEngineError`。每次失败后 `cleanupFailedSetup()`（[:165](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L165)）再试下一个。
- **检查点**：`stop()` 在"设备列表为空"的 guard **之后**。顺序反了的话，一次空的设备枚举就会把正在工作的音频路径拆掉。这个顺序是刻意保留的。

#### `setupWithDevice(_:)` [:120](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L120)

关键在开头 12 行：比较 `SoundBridgeConfig.activeSampleRate`（proxy 的配置值）与设备实际标称速率，不匹配就**改写全局** `activeSampleRate` 并调 `renderer.updateSampleRate`。

- **为什么重要**：共享内存环的容量、DSP 的系数、`maxCallbackFrames` 都从 `activeSampleRate` 派生。改它等于改协议层的 `sample_rate` 期望。
- **风险**：`updateSampleRate` 在这里被调用时，**IO 还没启动**（这是 `setup` 阶段），所以是安全的。但 `SoundBridgeConfig.activeSampleRate` 是全局可变状态，`SharedMemoryManager.createMemory` 也会读它（[:228](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L228)）。**若设备切换发生在 mapping 创建之后，两者就会不一致**：环按 48 kHz 建，而渲染路径按 96 kHz 读——`render` 里的 `mappingRate >= 8_000` 会用环自己的速率，所以 DSP 侧用的是 `mem.pointee.sample_rate`（[:562](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L562)），但 `AudioEngine` 用 `activeSampleRate`。这两个来源不同，是 E2/B3 类问题的土壤。
- **检查点**：审阅任何"改 `activeSampleRate`"的代码点，同时问"此刻有没有 live mapping，它的 `sample_rate` 会不会被同步更新"。

#### `switchDevice(_:)` [:195](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L195)

顺序：读 `IsRunning` → `AudioOutputUnitStop` → 若速率变则改全局 + `updateSampleRate` → `AudioUnitSetProperty(kAudioUnitProperty_CurrentDevice)` → 若速率变则 `Uninitialize` + `setFormat` + `initialize` → `Start`。

- **失败**：`SetProperty` 失败时先 `Start` 恢复原位（[:241](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L241)）再抛错。这是**唯一**正确的回滚点：速率已经改了、DSP 已经重建了，回滚不了，但至少别把设备留在"已停"状态。
- **检查点**：`needsFormatUpdate` 只看速率，**不看通道数**。若新设备被迫用不同的通道数，`setFormat` 不会重跑，`render` 的出口 3 就会一直输出静音。当前 `defaultChannels` 固定为 2，所以这条路径暂时不可达，但它是一个脆弱假设。

#### `setFormat()` [:280](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L280)

- **契约**：把 Input scope 的流格式设为 `Float32 / Packed / NonInterleaved / 2ch`。
- **关键**：`NonInterleaved` 决定了 `render` 收到的 `AudioBufferList` 有**两个 buffer**，所以 `buffers.count` 就是通道数。`deinterleave`（[:766](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L766)）依赖这一点。
- **失败**：抛 `setFormatFailed`。之后 `AudioUnitGetProperty` 回读只打日志（[:313](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L313)）——**回读失败不抛错**。审阅时注意：AU 可能接受一个"接近但不相同"的格式，此时 `buffers.count` 与 `mem.pointee.channels` 的相等判断就是最后一道防线。

### 5.4 `ProxyDeviceManager`

#### `resolveProxyRouting(forPhysicalUID:)` [:334](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L334)

返回值是一个携带语义的枚举，不是 Bool。审阅时先读它的四个 case：

| case | 含义 | 调用方应该做什么 |
| --- | --- | --- |
| `.routed(proxyDeviceID, defaultOutputIsProxy)` | 有路可走 | 配 AudioEngine；`defaultOutputIsProxy == false` 是**正常状态**，不要"帮用户切默认输出" |
| `.lifecycleBlocked` | 正在停止/恢复 | 什么都不做，等下次 |
| `.notManagedDevice` | 这个 UID 不归我管 | 忽略，不要重试 |
| `.proxyDeviceMissing` | 驱动还没发布 proxy | 等（有界），不要自己造设备 |

- **契约**：只读默认输出，**从不写**。注释明确说旧的 `autoSelectProxy` 已被删除，就是因为它会改用户的系统默认输出。
- **副作用**（都在 `routed` 分支里，顺序固定）：设 `activeProxyUID`/`activePhysicalDeviceID`/`activeProxyDeviceID` → `startVolumeForwarding` → `enqueueProxyVolumeForward(force: true)` → `restoreVolumeState` → `refreshSystemDefaultOutput`。
- **检查点**：`restoreVolumeState` 在"转发"之后。若反序，恢复的值会被立刻转发覆盖。

#### `startVolumeForwarding(proxyDeviceID:)` [:458](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L458)

- **契约**：在 proxy 设备上注册音量/静音属性监听。先试 master element，失败再退到 channel 1/2。
- **幂等**：`monitoredProxyDeviceID == proxyDeviceID` 时直接 return（[:459](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L459)）。这正是 `reregisterVolumeForwarding`（[:729](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L729)）必须**先 stop 再 start** 的原因——coreaudiod 重启后 ID 不变，幂等判断会把"重新注册"吃掉。
- **失败**：注册全失败时把 `monitoredProxyDeviceID` 清回 nil 并打 warning（[:505](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L505)）。**不会抛错**——音量监听是增强功能，不是音频路径的必要条件。审阅时不要把它当"驱动连接"信号。

#### `handleProxyVolumeChanged(from:)` [:564](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L564) → `commitObservedProxyVolumeState()` [:605](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L605) → `commitProxyVolumeState(...)` [:628](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L628)

这条链是全项目最精妙的一段状态同步，也是 1.2.0 里"要重设一次音量才生效"那个观察的根因所在。逐层看：

1. **回调层**：`monitoredProxyDeviceID == objectID && activeProxyDeviceID == objectID` 双重校验，防止旧设备的迟到通知。
2. **提交层**：先**持久化**，再 `onProxyVolumeStateCommitted`（实际是 `SharedMemoryManager.publishVolumeState`），成功后才更新 `lastCommittedProxyState`。
   - **顺序的意义**：注释说得很清楚——磁盘里的值是下次 Host 启动时 `VolumeStateResolver` 的首选，不能依赖 mapping 存在。
3. **收敛层**：最多 3 轮（`commitConvergencePasses`）。每轮重新读一次设备值，若与刚提交的不同就再走一遍。原因：用户在第一轮发布期间又动了滑块。
4. **转发层**：`enqueueProxyVolumeForward` 是**异步**的、在 `volumeForwardQueue` 上，并且被 `mayForwardToPhysical` 门控——只有在代理是系统默认输出时才把值推给物理设备。

**审阅陷阱**：`commitProxyVolumeState` 里的 `guard ... let scalar = volumeHAL.volume(proxyDeviceID) else { return }`（[:634](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L634)）。设备读不到音量时**静默返回**，不记日志、不重试。这是有意的（避免刷屏），但意味着"音量不同步"在这条路径上不可观测。要观测只能靠 `isAlreadyCommitted` 与 `lastCommittedProxyState` 的差值。

#### `restoreVolumeState(proxyDeviceID:physicalUID:override:)` [:709](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L709)

- **契约**：把持久化（或外部提供的）音量/静音写回 proxy 设备的 HAL 控件。
- **`override` 的意义**：没有它，一个"没有保存记录"的设备会被强制设成默认 0.35（`VolumePersistence.defaultVolume`），可能覆盖刚从共享内存恢复的值。注释明确记录了这个历史缺陷。
- **失败**：`volumeHAL.setVolume` / `setMuted` 的返回值只进日志（[:717](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L717)）。**写失败不会让路由失败**。这是可接受的（音频仍能走，只是音量值不对），但审阅时要把"路由成功"和"音量正确"当成两件事。

### 5.5 Host 层审阅清单（14 条）

- [ ] `createMemory` 的 14 步顺序与本表一致，特别是 `probeExisting` 在 `rename` 前、`rf_admission_open` 在 `rename` 前
- [ ] 环容量用 `rf_ring_capacity_frames_for`，文件大小用 `rf_shared_audio_size`，没有手写乘法
- [ ] `rf_publish_volume_state` 在 `createMemory` 里**只调一次**
- [ ] `enterRenderMemory` / `exitRenderMemory` 在每个 `render` 出口上成对（含四条静音出口）
- [ ] `publishRenderMapping` 返回 `false` 时调用方没有丢弃自己的引用
- [ ] `retireRenderPath` 只在 `cleanup` / 关闭路径调用，且 `renderRetireTimeouts` 有出口
- [ ] `revokeAdmission` 只做 `begin_close`，**没有** `finalize_close`
- [ ] `removeMemory` 的顺序是 摘表 → refresh → revoke → unlink
- [ ] `connectionObservation` 的 `nil` 没有被折叠成 `.disconnected`
- [ ] `startHeartbeat` 先 cancel 再建，且 drain 只在这里
- [ ] `updateSampleRate` 的返回值在 `setupWithDevice` 里被检查（当前**未检查**）
- [ ] `activeSampleRate` 的每次写入都伴随 live mapping 的 `sample_rate` 同步考虑
- [ ] `switchDevice` 的 `needsFormatUpdate` 是否应该包含通道数
- [ ] `renderBuffer` 在 `init` 里一次性分配到 `maxCallbackFrames × maxCallbackChannels`，且 `deinit` 释放（**已核实**：[:227](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L227) / [:259](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L259)）

---

## 6. App 侧 API

App 是**控制面**：它不产生音频、不消费音频，只写 EQ 块、读音量、管 Host 进程、管驱动安装。它的全部风险集中在"映射换化身时写到了旧 inode"这一类问题，而这类问题在 P2 Batch 3 之后已经被统一到 `SharedMemoryMappingManager` 一个地方。

### 6.1 `SharedMemoryMappingManager`

这是 App 侧唯一的 mmap 持有者。`EQController` 只持有一个 `let mapping: SharedMemoryMappingManager?`（[EQController.swift:146](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L147)），不再自己 `munmap`。

#### `defaultPath(forUID:ownerUID:)` [:245](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L245)

- **契约**：`/tmp/soundbridge-<uid>-<safeUID>`，其中 `:` `/` 空格替换成 `_`。
- **关键**：注释说"三边必须逐字节一致"，另外两边是 Host 的 `PathManager.sharedMemoryPath(uid:)` 和 Driver 的 `SharedMemoryPath()`。**这是全项目唯一没有编译期校验的三方约定**——`tools/check_protocol_layout.sh` 只查头文件，不查路径。
- **检查点**：审阅任何"改路径格式"的改动时，必须同时 grep 三处。`sanitize` 规则也必须一致：Driver 侧如果只替换 `/`，含空格的设备 UID 就会打出两个不同的文件名。

#### `attachPath(_:depth:)` [:518](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L518)

七个阶段，顺序即正确性：

| # | 阶段 | 行号 | 拒绝条件 |
| --- | --- | --- | --- |
| 1 | OPEN | [:523](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L523) | `ENOENT` → `.fileMissing`（正常，Host 还没起）；其他 errno → `.openFailed` |
| 2 | IDENTIFY（`fstat` on fd） | [:536](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L536) | 失败 → `.identityUnreadable` |
| 3 | 同 inode 短路 | [:543](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L543) | 同 dev+ino → `.alreadyCurrent`，**不重写 EQ** |
| 4 | 换 inode 先退役 | [:551](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L551) | 不同 inode → 先 `retireActive`，即使后面校验失败也不留旧指针 |
| 5 | 尺寸下限 | [:555](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L555) | `st_size < sizeof(RFSharedAudio)` → `.fileTooSmall` |
| 6 | `rf_validate_header` | [:574](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L574) | 任何非 OK → `.invalidHeader(reason)` + `munmap` |
| 7 | session + epoch | [:585](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L585) | 缺 `"SB6A"` 或 `epoch == 0` → `.notAnIncarnation` |
| 8 | `lstat` 二次确认 | [:594](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L594) | dev/ino 变了 → `.superseded`（`attachWork` 最多重试 3 层） |

- **为什么第 3 步必须在第 4 步之前**：否则每次重复通知都会退役+重挂，EQ 会被反复重写，`mappingPublished` 也会反复发出，UI 抖动。
- **为什么第 8 步必不可少**：第 1 步到第 6 步之间 Host 可能已经 `rename` 了新 inode。若不复查，App 会把"已经不在路径上的"映射当成当前的，写入的内容永远到不了 Host。
- **注意 App 不校验容量的原因**：它只访问头内字段（`eq_snapshot`、`volume_scalar`），从不读 `audio_data`。这个"不读就免检"的推理是成立的，但它依赖一个前提：**头内字段的偏移由 `rf_validate_header` 保证**。如果将来 App 开始读音量统计（`underrun_frames` 等），仍然安全；一旦开始读采样数据，就必须补容量校验。

#### `write(_:)` [:357](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L357) / `writeEQSnapshot(_:)` [:387](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L387)

- **契约**：`write` 取租约（`mapping.leases += 1`）→ 释放锁 → 执行 `body` → `releaseLease`。
- **关键**：`body` 在**锁外**执行。这样 `munmap` 永远不会在持锁期间发生，也永远不会在 `body` 执行期间发生（`retired && leases == 0` 才 unmap）。
- **`eqCommitLock` 的必要性**（[:405](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L405)）：`rf_store_eq_snapshot` 是单写者 seqlock。两个并发写者会都读到偶数 `seq`，都写 `seq+1`，最终留下一个永久奇数。锁顺序固定为 `eqCommitLock → lock`，反向取会死锁。
- **失败语义**：`.unavailable` 表示"没有活映射"，不是错误。调用方必须**不要把 UI 标成已应用**——`EQController` 正是这么做的（见 6.2）。

#### `publish(...)` [:610](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L610) / `retireActive(reason:)` [:653](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L653)

- **契约**：`publish` 换 `active`，把旧的 `retired = true`，租约为 0 才 unmap；`retireActive` 置 nil 并同样处理。
- **关键**：`alreadyCurrent` 时**新的 pointer 被立刻 munmap**（[:618](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L618)）。这是一个容易漏掉的资源路径：校验通过但身份相同，说明这个 mmap 是多余的。
- **通知顺序**：`mappingPublished.send((identity, generation))` 走 `DispatchQueue.main.async`。**必须是 main**，因为 `EQController` 的 `@Published` 属性在 main 上。
- **检查点**：`generationCounter` 用 `&+=`（溢出回绕）。回绕后 `generation > 0` 的判断（[:523 in EQController]）仍成立，但 `appliedGeneration` 的去重会失效一次。实际不可达（2^64 次发布）。

#### `hostSession(of:)` [:685](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L685)

- **契约**：从 `_reserved` 前 20 字节解出 `"SB6A"` + 16 字节 UUID。
- **关键**：C 侧没有对应的 extract 函数，所以 App **直接读 ABI 布局**。注释承认了这一点（"reading existing ABI, not extending it"）。审阅时若有人改 `rf_set_host_session` 的 marker 或长度，这里会静默返回 nil，表现为"App 永远 attach 不上"。

### 6.2 `EQController`

#### `computeBandGains(bass:mids:treble:)` [:229](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L229)

三档滑块 → 10 段增益，权重表是硬编码的（[:40](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L40)、[:46](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L46)、[:51](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L51)）：

| 段 | 频点 | 类型 | 权重 | 滑块 |
| --- | --- | --- | --- | --- |
| 0 | 32 Hz | lowShelf | 0.5 | bass |
| 1 | 64 Hz | lowShelf | 1.0 | bass |
| 2 | 125 Hz | lowShelf | 1.5 | bass |
| 3 | 250 Hz | peak（禁用） | — | — |
| 4 | 500 Hz | peak | 0.6 | mids |
| 5 | 1 kHz | peak | 1.2 | mids |
| 6 | 2 kHz | peak（禁用） | — | — |
| 7 | 4 kHz | peak（禁用） | — | — |
| 8 | 8 kHz | highShelf | 0.4 | treble |
| 9 | **16 kHz** | **highShelf** | **1.3** | treble |

**这一段与 B3 直接相关**：band 9 在 16 kHz，`wr = 2π·16000/fs`。当 `fs = 32 kHz` 时 `f/fs = 0.5`，正好落在 Nyquist；`fs = 40 kHz` 时 `0.4`，双线性变换的预畸变会把系数推到不稳定区。审计的实测矩阵（24k/28k/30k/31k → 97–99% 非有限样本；32k + 13 kHz → +88.36 dB，峰值 504.8）正好覆盖这一段的边界。**审阅"EQ 为什么不稳"时，起点不是 `biquad.h`，而是这张表 + 采样率。**

#### `buildInitialPreset()` [:271](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L271)

- **契约**：把三档滑块映射成完整 10 段 `EQPresetConfig`（含频点、Q、类型、启用位）。
- **关键**：`shelfQ = 0.7`、`peakQ = 1.2`；未使用段 `enabled = false` 且 `gainDb = 0`。`limiterEnabled = false`（[:317](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L317)）。
- **注意**：这个 preset **只对 App 侧的展示/持久化有意义**。真正送到 DSP 的只有 `RFEQSnapshot`（10 个 float + preamp + bypass），频点/Q 是 Host 在 `applyInitialPreset`（[AudioRenderer.swift:677](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L677)）里硬编码的。
- **这正是 E2 的根因**：`soundbridge_dsp_update_band_frequency` / `update_band_q` 在 Host 侧的桥接头文件里**根本没有声明**（见 §3.0），所以即使 App 改了频点/Q，也传不过去。**App 侧的 `EQBandConfig.frequencyHz` 与 `qFactor` 是死数据。**

#### `flushToSharedMemory()` [:581](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L581) 与 `setupThrottledPipeline()` [:346](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L346)

两条写路径，语义不同，都要审：

| 路径 | 触发 | 是否节流 | 是否持久化 | 是否推进 cache |
| --- | --- | --- | --- | --- |
| 节流管线 | 任意 `@Published` 变化 | 33 ms（`throttle latest`） | 每次投递都存 | 只有 `.written` 才推进 |
| `flushToSharedMemory` | 滑块释放 | 否 | **总是**存 | 只有 `.written` 才推进 |

- **`only-landed-write-advances-cache` 是这段代码的核心不变式**。它保证"没写进去的值仍然被标记为待发送"，下次 mapping 出现时 `applyIfNeeded` 会补写。
- **P1-2 的历史教训**：`flushToSharedMemory` 曾经绕过节流管线直接推进 cache，导致"滑块松手那一刻的值"永远存不进磁盘（因为节流管线随后看到"没变化"就提前 return，跳过了 `saveToUserDefaults`）。现在的写法是两条路径都存，且都用 `.written` 门控 cache。
- **审阅陷阱**：`writeToSharedMemory` 返回 `.written(generation:)` 里的 `generation` 是**发布序号**，不是"值确实被 Host 读到了"的证明。Host 可能还没渲染一帧。`isAppliedToCurrentMapping` 的语义只能是"已写入这个化身"，不能是"已生效"。

#### `observeMapping()` [:485](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L485) 与 `applyIfNeeded(generation:)` [:522](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L522)

- **契约**：新化身出现 → 把当前 UI 值写回去。因为 EQ 块属于 App，Host 新建的 mapping 是平的。
- **关键**：`observeMapping` 末尾主动查一次 `mapping.isAvailable`（[:512](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L512)）。原因是 `mappingPublished` 是 `PassthroughSubject`，**不重放**；App 启动时 `start()` 早于 `EQController` 构造，若只靠订阅就会永久错过第一次发布。
- **失败**：`.unavailable` 时 `isAppliedToCurrentMapping = false`，并**不**推进 `appliedGeneration`，所以下一次发布还会重试。
- **检查点**：`generation > 0` 的 guard（[:523](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift#L523)）防止用 0 作为"未知"值时的误判。`SharedMemoryMappingManager.generationCounter` 从 0 开始自增，第一次发布是 1，所以 0 确实是哨兵。

### 6.3 `VolumeController`

App 的音量滑块**不写共享内存**，它写 CoreAudio 属性；Host 侧的监听回调再把值提交进共享内存。这条链是"App → HAL → Host → 共享内存 → Driver 控件"。

#### `setVolume(_:)` [:196](../apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift#L196) / `setMute(_:)` [:229](../apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift#L229)

返回值是四态，不是 Bool：

| 结果 | 含义 | UI 应该做什么 |
| --- | --- | --- |
| `.committed(applied)` | 设备回读成功，`applied` 是**设备报的值**（可能被量化） | 显示 `applied`，不是请求值 |
| `.rejected(status)` | 所有 element 都拒绝 | 保持原值 + 报错 |
| `.notVerified(requested, actual)` | 写被接受但回读不符 | **保持原值**。1.2.0 在这里谎报成功 |
| `.unavailable` | 没有目标设备 | 禁用控件 |

- **契约**：`currentVolume` 只在 `.committed` 时更新（[:210](../apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift#L210)），且在 main 上。
- **`currentLevelTarget`**（[:254](../apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift#L254)）：优先 proxy，其次 physical。**这两个目标写的是不同的设备**，所以"App 音量"和"Host 提交值"之间必然存在一步转换，而转换的权威在 Host（`commitProxyVolumeState`）。
- **审阅要点**：`.notVerified` 不做重试。这是一次写入的终态，若设备只是慢，用户需要再拖一次。可接受，但要记录。

### 6.4 `HostSupervisor`

#### `start()` [:295](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L295) / `restart()` [:321](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L321) / `shutdown(intent:waitTimeout:completion:)` [:354](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L354)

- **契约**：App 只管理**自己拉起的**那个 Host。`notOwned` 状态表示实例锁被别人持有，此时绝不 `kill`。
- **`restart` 的单一路径（single-flight）**：`launching`/`running` → 走一次 stop 再 relaunch；`stopping` → 直接合并进在途操作；`idle`/`degraded` → 直接 launch。**不存在两条并发的 launch**。
- **`shutdown` 的 `waitTimeout`**：只有 App 即将退出/卸载时才传，UI 永不传。传了会用 `DispatchSemaphore` 阻塞到进程真的死掉——因为"App 退出后 Host 还在写共享内存"是不可接受的。
- **检查点**：`launch` 前先 `configuration.isHostRunning()`（[:498](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L498)）。注释写得很好：**锁是真相**，不是"我上次没拉起过所以没在跑"。

#### `launch(attempt:)` [:490](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L490) → `scheduleWatchdog` [:540](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L540) → `scheduleKillEscalation` [:596](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L596)

- **契约**：`launchToken` 单调递增；`terminationHandler` 带着 token 回来，旧 token 的通知被丢弃。这是防止"上一个进程的退出通知杀掉新进程状态机"的关键。
- **`watchdog`**：超时后若 `isHostRunning()` 仍为 false，才判定启动失败。**它不 kill 进程**，只改状态。
- **`killEscalation`**：先 `SIGTERM`，超时再 `SIGKILL`。
- **审阅要点**：`process == nil` 的 guard（[:493](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L493)）与 `isHostRunning()` 的 guard 是两道不同的门：前者防自己重复拉起，后者防别人已经拉起。两道都要有。

### 6.5 App 层审阅清单（12 条）

- [ ] `defaultPath` 的 sanitize 规则与 Host `PathManager`、Driver `SharedMemoryPath` 逐字节一致
- [ ] `attachPath` 的 8 个阶段顺序未变，特别是"换 inode 先退役"与"最后 lstat 复检"
- [ ] `alreadyCurrent` 时新 pointer 被 munmap（不泄漏）
- [ ] `write` 的 `body` 在锁外执行
- [ ] `eqCommitLock → lock` 的锁序没有反向
- [ ] `writeEQSnapshot` 是 `rf_store_eq_snapshot` 的唯一调用者
- [ ] `observeMapping` 在订阅之外还主动查了一次 `isAvailable`
- [ ] `.unavailable` 不会被 UI 显示成"已应用"
- [ ] `computeBandGains` 的权重表与 B3 的采样率矩阵一起复核
- [ ] `buildInitialPreset` 的频点/Q 被识别为"死数据"（Host 侧无 update API）
- [ ] `setVolume` 的 `.notVerified` 不更新 `currentVolume`
- [ ] `launch` 同时有 `process == nil` 与 `isHostRunning()` 两道门

---

## 7. 七种"身份"的区别

项目里有七个（实际是九个）看起来都像"身份"的东西。混淆它们是审阅中最常见的错误来源，也是"为什么明明重连了却没声音"这类问题的根因。

### 7.1 表

| # | 名称 | 类型 / 位置 | 写入者 | 读取者 | 何时变化 | 混淆后果 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `sessionID` | `UUID`，Host 内存 + 头 `_reserved`@228 的 `"SB6A"+16B` | Host（`rf_set_host_session` [:276](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L276)） | Driver（`rf_host_session_matches`）、App（`hostSession(of:)`） | 每个 Host **进程**一次 | 当成"mapping 身份"→ 同一进程重建 mapping 时误判为同一个 |
| 2 | `admission_epoch` | `_Atomic uint64_t` @264 | Host（`rf_admission_open`） | Driver（`rf_producer_claim` 校验）、App（要求 ≠ 0） | 每个 **mapping 化身**一次，随机 | 当成"进程身份"→ Host 重启后误判为同一化身 |
| 3 | `producer_owner_token` | `_Atomic uint64_t` @272 | Driver（`rf_producer_claim` CAS） | Driver（`rf_producer_may_write`）、Host 诊断 | 每次 claim/release | 把 0 当成"没人写"→ 实际是"还没 claim"，两者都要拒绝已不成立 |
| 4 | `mapping.generation` | Swift `SharedMemoryMapping.generation: UUID` | Host（`createMemory` 构造对象时） | Host（`connectionObservation`） | 每个 **Host 侧对象**一次 | 与 `mapping_revision_` 混用 → 发布序号被当成化身号 |
| 5 | `mappingToken` | `UUID`，`DriverConnectionObservation` 的字段，值就是 #4 | Host | tracker / App | 随 #4 | 当成 `admission_epoch` → "驱动未连接"与"驱动掉线"无法区分 |
| 6 | `state_revision` | `_Atomic uint64_t` @216 | Host（`rf_publish_volume_state`） | Driver（`rf_sync_driver_volume_state`）、Host（`rf_read_volume_state`） | 每次**已提交**的音量变更 | 认为 Driver 的 `rf_store_volume_scalar` 也会 bump → 会得出"seqlock 覆盖了所有写"的错误结论（C3） |
| 7 | `eq_sequence` | `_Atomic uint32_t` @152 | App（`rf_store_eq_snapshot`，唯一写者） | Host（`rf_load_eq_snapshot`） | 每次 EQ 写入（+1 开始、+1 结束） | 把它当"版本号"用来判断内容是否变化 → 内容可能相同但序号不同（C2 的读侧就靠 memcmp 而不是序号） |
| 8 | `mapping_revision_` | `uint64_t`，`Plugin.cpp` 内部成员 | Driver（`OpenSharedMemory` 成功后 `++`） | Driver（`PublishedSharedMemory` 门控） | 每次 Driver 发布新映射 | 与 #4 同名不同物：一个是 Driver 内部序号，一个是 Host 对象 UUID |
| 9 | App 的 `generation: UInt64` | `SharedMemoryMappingManager.generationCounter` | App（`publish` 时 `&+=`） | App（`EQController.appliedGeneration`） | 每次 App 侧发布 | 与 #4/#8 都不同：它只用于 App 内部去重，跨进程毫无意义 |

### 7.2 三个高频混淆

**（a）`sessionID` vs `admission_epoch`。**
`sessionID` 回答"这是哪个 Host 进程造的"，`admission_epoch` 回答"这是这个进程的第几个 mapping"。Host 崩溃重启 → 两者都变；Host 换设备重建 mapping → 只有 epoch 变。任何"判断要不要重新附着"的逻辑，判据必须是**两者组合**（App 的 `SharedMemoryIdentity` 正是 `device + inode + epoch + session` 四元组，见 [SharedMemoryMappingManager.swift:18](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L18)）。

**（b）`state_revision` vs `eq_sequence`。**
两者都是"变更计数"，但语义完全不同：`state_revision` 只由 Host 权威地 +1，**不覆盖** Driver 的实时音量写（C3；这是设计，不是缺陷——Driver 的写是"控件移动"，不是"提交"）；`eq_sequence` 是 seqlock 的奇偶位，只保证"读的时候没人在写"，不表示"内容变了"。**用 `eq_sequence` 做变更检测会漏掉"值改回原值"的情况，也会因为回绕误判。**

**（c）`producer_owner_token` 的 0。**
`0` 表示"没人持有生产者槽位"。但它是通过 CAS 从 0 变成随机 token 的，所以"读到一个非 0 值"不等于"那个持有者还活着"。`rf_producer_may_write` 只比较 token 相等，**不检查持有者进程是否存活**——这是 D4（claim 在 retire 后仍存活）的机制来源。真正的清理只能靠 `rf_admission_begin_close` + 新 mapping。

### 7.3 一张判断流程图

```
你要判断的是什么？
├─ "这个文件还是不是我的 Host 造的？"        → sessionID（+ inode）
├─ "这个 mapping 还是不是同一个化身？"        → admission_epoch（+ inode）
├─ "我还能不能写 audio_data？"                → admission_state == OPEN
│                                              && producer_owner_token == 我的 token
├─ "音量值是不是新的？"                       → state_revision 变了？读到的 revision 一致？
├─ "EQ 快照是不是新的？"                      → 不要看 eq_sequence，用 memcmp 比内容
└─ "驱动还连着吗？"                           → driver_connected + driver_heartbeat 的
                                                相邻两次采样 + mappingToken 未变
```

---

## 8. API → 缺陷 → 测试 三向索引

这张表把审计报告的缺陷编号、触达的 API、以及"应该在哪补一条会失败的断言"三者对齐。左侧编号与 [SoundBridge-Core-Engineering-Audit.md](release/SoundBridge-Core-Engineering-Audit.md) §10 一致。

| ID | 触达的 API（可点） | 断言的正确位置 | 断言应该怎么写 |
| --- | --- | --- | --- |
| **B3** | `soundbridge_dsp_set_sample_rate` / `soundbridge_preset_validate` / `process_interleaved` / `biquad.h:186-260` | `preset_validate` 或 `set_sample_rate` 的返回值 | 对每个 `(fs, band.frequency)` 组合，若 `frequency > 0.45·fs` 则 `validate` 返回错误；且 `process_*` 后断言 `isfinite` 全真 |
| **D1** | `OnWriteMixedOutput` [:793](../packages/driver/src/Plugin.cpp#L793)、[:849](../packages/driver/src/Plugin.cpp#L849)；`ResizeBuffers` [:1201](../packages/driver/src/Plugin.cpp#L1201)（三个 `resize`）经 `HandleFormatChange` [:1215](../packages/driver/src/Plugin.cpp#L1215) 由回调 [:788](../packages/driver/src/Plugin.cpp#L788) 触发；`ConvertToFloat32Interleaved` [:1235](../packages/driver/src/Plugin.cpp#L1235)；`ProcessWithSampleRateConversion` [:1303](../packages/driver/src/Plugin.cpp#L1303) | 一个**计数型**断言：三个缓冲的 `capacity()` 在 `OnStartIO` 之后不再增长 | 在测试里包一层分配 hook，断言回调期间 `malloc` 调用数 == 0；另断言 `LogPeriodic` 的调用点在 `LogPeriodic` 内部自己限流而不是每回调一次 |
| **C2** | `rf_store_eq_snapshot` / `rf_load_eq_snapshot` / [AudioRenderer.swift:605](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L605) | `rf_load_eq_snapshot` 的返回值 | 重试耗尽时必须返回 `false`，且调用方**不得**应用快照；当前返回值被丢弃 |
| **A3** | `soundbridge_dsp_set_sample_rate` / `ParameterSmoother::init` / `apply_preset` | 切换采样率后的第一个输出块 | 断言 preamp 增益在切换前后连续（无 46–70 ms 归零凹陷） |
| **D2** | `ConvertToFloat32Interleaved` [:1231](../packages/driver/src/Plugin.cpp#L1231)（integer 路径见 [:1258](../packages/driver/src/Plugin.cpp#L1258)） | 格式矩阵测试 | 覆盖 `{interleaved, non-interleaved} × {float32, int16, int24-packed, int24-in-32}` 八种组合；注意 `int24` 分支按 3 字节步进读，遇到 in-32 布局会错位 |
| **B5** | `limiter.h` / `process_*` | 质量声明而非代码 | 若对外宣称 "limiter"，需补 attack/release/lookahead/stereo-link 中的至少一项 |
| **D5** | `AttemptRecovery` / `rf_producer_claim` | 恢复路径 | 恢复后必须**重新 claim**，否则旧 token 已失效、`may_write` 永远为 false |
| **B1** | `set_bypass` / `get_stats` | bypass 下的 `peak`/`cpu_load` 语义 | bypass 时 peak 不应衰减、cpu_load 不应冻结 |
| **B2** | `reset` | reset 后 `get_stats` | limiter/smoother/peak/CPU 全部回到初值 |
| **C3** | `rf_store_volume_scalar` / `rf_read_volume_state` / `restoreVolumeState` / `SyncVolumeStateWithSharedMemory` | `rf_read_volume_state` 的两个入参 | `out` **和** `mem` 都要判空；耗尽重试后应返回 `false` 而不是"最后一次观察值" |
| **C4** | `rf_validate_header` [:584](../packages/shared/include/RFSharedAudio.h#L584) vs `validateSharedMemory` [ControlProtocol.hpp:165](../packages/driver/src/ControlProtocol.hpp#L165) | 一个共享的校验函数 | 两处检查集合必须一致，或其中一处明确标注"子集"并说明谁补了哪些 |
| **C5** | `rf_is_connection_healthy` [:879](../packages/shared/include/RFSharedAudio.h#L879) | 要么删，要么修 | 当前零调用者且语义错误（不校验 `headerValid`） |
| **A1** | DSP 参数层（`num_active_bands` / `current_preset` / `bands[]` / `limiter_enabled`） | `process_*` 入口 | 在头文件里写明"参数写入者必须是 IO 线程"，或加一个 `_Atomic` 版本号做双检 |
| **A4** | `soundbridge_dsp_destroy` | `AudioRenderer.deinit` / `main.swift` | 若 renderer 不再是进程级全局，必须改为 `passRetained` + 配对 release |
| **D4** | `rf_producer_release`（**无生产调用者**） | `RetireMapping` 之后 | retire 时应 release claim，或在新 mapping 上用新 epoch 强制失效 |

### 8.1 三条"索引不到任何测试"的空白

- **没有任何测试覆盖 `sample_rate > 32 kHz` 的 EQ 路径**。B3 的复现矩阵是手工探针跑出来的，`packages/dsp/tests` 与 `apps/mac/SoundBridgeApp/Tests` 都不含 40 kHz / 48 kHz + band 9 的用例。
- **没有任何测试覆盖 `rf_load_eq_snapshot` 的失败分支**。C2 的"耗尽重试仍应用"这条路径，只有读到 torn 数据才会触发，而现有测试是单线程顺序写。
- **没有任何测试覆盖 Driver 的 recover 路径**。D5 被判"unreachable"的依据是调用者普查，不是测试；一旦有人接上调用，没有任何用例会红。

---

## 9. 审阅工作流与常见误判

### 9.1 五步法

对任何一个 API，按这个顺序看，不要跳：

1. **定位线程**。这个方法会被谁调用？写出调用链，直到能回答"它在 IO 线程上吗"。项目里只有两处 RT：Driver 的 `OnWriteMixedOutput`、Host 的 `AudioRenderer.render`。其余都是控制面。
2. **读契约，不读实现**。头文件/文档注释先告诉你"作者认为它应该怎样"。把契约抄下来，再去实现里找反例。
3. **查全部调用者**。`grep -rn "函数名"` 一次，数出调用点。**零调用者本身就是发现**（C5、D5、`rf_admission_finalize_close`）。
4. **给结论标证据等级**。[静态] = 只读代码；[运行] = 跑过探针/测试；[未验证] = 推理成立但没实测。三个等级之间不能悄悄升级。
5. **写一条会失败的断言**。如果一个结论无法转成"某条件下某观测值应等于 X"，它就不是审阅结论，是印象。

### 9.2 六条常见误判

| 误判 | 为什么错 | 正确读法 |
| --- | --- | --- |
| "调了 `rf_validate_header` 就安全" | 它只检查版本/大小/格式一致性，**不检查容量与 `bytes_per_frame`**（那是 `ControlProtocol.hpp` 的 `validateSharedMemory`） | 分清"头有效"与"缓冲区合法"两个层次（C4） |
| "注释说 RT-safe 就是 RT-safe" | `Plugin.cpp:763` 写着 "Keep callback RT-safe"，紧接着 `:793` 就 `resize` | 注释是意图，`new`/`malloc`/`os_log` 才是事实（D1） |
| "有锁就安全" | `os_unfair_lock` 保护的是对象表，不是映射的生命期。生命期靠 `rf_rt_gate` 租约 | 分清"锁保护的数据"与"租约保护的地址" |
| "测试通过即正确" | 现有测试没覆盖 >32 kHz、没覆盖 torn snapshot、没覆盖 recover | 先看测试的**输入矩阵**，再看它绿不绿 |
| "返回 `true` 就是真的" | `rf_read_volume_state` 重试耗尽仍返回 `true`；`readVolumeState` 又把 `initialized` 硬编码成 `true` | 检查每个 `Bool` 返回的**所有**分支（C3） |
| "同名就是同一个东西" | `mappingToken` / `mapping.generation` / `mapping_revision_` / `admission_epoch` 四者不同 | 回到 §7 的表 |

还有一条不属于"误判"但同样致命：**把"不可达"当成"不存在"**。D5、D4、A4 都是"当前没有调用者/当前被更强的约束保护"，它们的严重性取决于"下一个人接上调用时会不会知道"。审阅报告的措辞必须区分 `CONFIRMED` 与 `CONFIRMED (unreachable)`——这也是本项目审计把 D5 列为 CONFIRMED 而非 CONDITIONAL 的原因。

### 9.3 一页速查卡

```
共享内存文件     /tmp/soundbridge-<uid>-<safeUID>          （三边字符串必须一致）
头长度           320 字节，audio_data[] 是最后一个字段
环容量           必须是 2 的幂；由 rf_ring_capacity_frames_for 取整
准入              Host: CLOSED→OPEN→CLOSING→CLOSED；Driver 只能 claim，不能 open
producer 写三条件  admission_state==OPEN && token 匹配 && may_write 通过
环写              只写 write_index；不足时 Drop-New，不阻塞
环读              只写 read_index；不足时零填充，且零填充帧不推进 R
音量权威          Host（bump state_revision）；Driver 实时写只动 value+mute
EQ 写者           App 唯一；seqlock 只保证"读到偶数"，不保证内容原子
RT 面（只有两处）  Driver OnWriteMixedOutput / Host AudioRenderer.render
RT 面禁止          malloc / os_log / munmap / 任何 os_unfair_lock / 任何 Swift 数组增长
映射释放          Host: 租约为 0 才 munmap（关闭期例外）；Driver: 超时一律 quarantine
```

### 9.4 建议的阅读顺序（约 90 分钟）

| 时长 | 读什么 | 目的 |
| --- | --- | --- |
| 10 min | [RFSharedAudio.h:150-345](../packages/shared/include/RFSharedAudio.h#L150) | 建立"320 字节头 + 5 个原子区"的物理图 |
| 15 min | §2.2 Admission（本手册）+ `rf_admission_open` / `rf_producer_claim` / `rf_producer_may_write` | 搞清"谁能写 audio_data" |
| 15 min | §2.3 Ring + `rf_ring_write` / `rf_ring_read` | 搞清"谁写哪个索引" |
| 15 min | §4.2 CallbackGate + `MappingRetirement.hpp` | 搞清 Driver 为什么敢持有裸指针 |
| 15 min | §5.1 渲染路径三原语 + `rf_rt_gate` | 搞清 Host 侧同一问题的另一种解法 |
| 10 min | §7 七种身份 | 把所有 `token`/`epoch`/`revision`/`generation` 分清 |
| 10 min | §8 三向索引 | 知道哪个 API 上已经站着一条缺陷 |

读完这 90 分钟，应该能独立回答三个问题：

1. 一个回调在 `rf_rt_gate_enter` 之后被 `SIGKILL`，Host 会怎样？（答：租约永远不归还，后续所有发布变 pending，`renderRetireTimeouts` 在关闭时 +1。**进程死了，租约是进程内状态，所以其实随进程消失**——这正是"Host 崩溃不会让 Driver 卡死"的原因。）
2. Driver 的 `CloseAndDrain` 超时后，那块内存何时被释放？（答：永不主动释放，进 quarantine；只有新 mapping 发布且确认无租约时才可能回收。）
3. `state_revision` 不变但 `volume_scalar` 变了，谁干的？合法吗？（答：Driver 的 `SetRawValueImpl`。合法，因为它是"控件移动"而非"提交"；下一次 `OnStartIO` 的 `SyncVolumeStateWithSharedMemory` 会把它按回共享内存的权威值。）
