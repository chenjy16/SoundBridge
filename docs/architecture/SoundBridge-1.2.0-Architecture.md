# SoundBridge 1.2.0 架构说明

本文档描述 **SoundBridge 1.2.0 实际采用的、当前已实现**的架构。它不描述
曾经评估但未采用的方案（旧双原子闸门为何被替换、XPC / E2 研究线为何不进入
正式架构）；那些评估记录不随仓库发布，本文只保留「当前实现为什么是这样」的结论。

文中每一条约束都对应仓库中的实际代码或工具。凡未验证的系统行为，均在
[risks/Known-Limitations.md](../risks/Known-Limitations.md) 中登记，不在本文
中被表述为已验证。

---

## 1. 问题与约束

目标设备是一类**固定音量**的 HDMI / DisplayPort 显示器：设备本身不提供
硬件音量，macOS 因此把系统音量滑块置灰，键盘音量键对该输出无效。

SoundBridge 的做法是在应用与物理设备之间插入一个虚拟音频设备
（AudioServerPlugIn），让系统输出先进入该虚拟设备，再由一个用户态进程
（Host）处理数字增益 / EQ / 格式适配后交给真实物理设备。用户在系统里
看到的仍然是那个音量滑块。

由此产生的硬性约束：

| 约束 | 含义 |
|---|---|
| 无 kext | 只能落在 AudioServerPlugIn（用户态 + HAL 加载）范围内 |
| 回调是实时的 | HAL 写回调（`OnWriteMixedOutput`）不得阻塞、不得加锁、不得分配 |
| 两个进程 | Driver 在 `coreaudiod` 内，Host 是独立用户进程；跨进程共享内存 |
| 不得丢数据到崩溃 | 进程重启后不能复用旧共享内存，也不能"猜"旧状态是否还活着 |
| 不得在回调里 munmap | 退役共享内存时必须先证明没有回调还在其中 |

## 2. 进程与组件拓扑

```
┌──────────────────────┐
│ SoundBridge App      │  菜单栏 UI / 偏好 / 引导安装 / EQ 参数编辑
│ (SwiftUI, 用户进程)   │
└──────────┬───────────┘
           │ mmap 写 EQ 与音量状态；控制文件
           ▼
┌──────────────────────┐        AudioUnit render         ┌────────────────┐
│ SoundBridge Host     │────────────────────────────────►│ 物理输出设备    │
│ (用户进程)            │  DSP: 10 段参数 EQ / 增益        │ (HDMI/DP)      │
│ 唯一 mapping 创建者    │                                 └────────────────┘
└──────────┬───────────┘
           │ 创建 / 发布 / 消费
           ▼
  /tmp/soundbridge-<ownerUID>-<safeDeviceUID>
  [ 320 B header ][ SPSC ring buffer: stereo Float32 interleaved ]
           ▲
           │ Producer 写入（HAL 写回调）
┌──────────┴───────────┐
│ SoundBridge Driver   │  AudioServerPlugIn (.driver)，加载于 coreaudiod
│ (C++ / libASPL)      │  声明"代理设备"，做格式转换 / SRC，写 Ring
└──────────────────────┘
```

数据流方向为 **Driver → 共享内存 → Host → 物理设备**。Driver 是唯一的
Producer，Host 是唯一的 Consumer。

### 2.1 组件职责边界

| 组件 | 关键文件 | 职责 | 明确不做 |
|---|---|---|---|
| App | `apps/mac/SoundBridgeApp` | UI、偏好持久化、引导安装、EQ 编辑、音量/静音写入 | 不创建音频共享内存，不渲染音频 |
| Host | `packages/host` | 创建并发布 mapping、音频渲染回调（Consumer）、设备枚举、代理设备注册、单实例锁、生命周期 | 不在音频回调里分配、不加锁 |
| Driver | `packages/driver` | HAL 设备对象、写回调（Producer）、格式转换、mapping 准入/排空/退役、音量与静音控制对象 | 不创建 mapping，不长期持有旧 mapping |
| DSP | `packages/dsp` | 10 段参数 EQ，stereo Float32 interleaved 原地处理 | 不做格式转换，不做 I/O |
| 共享协议 | `packages/shared/include/RFSharedAudio.h` | 头布局、Ring、Admission、Producer token 的**唯一事实源** | — |

共享头在仓库中共有 **4 份副本**（driver / host / app / dsp 各自的 include
路径），由 `tools/sync_shared_header.sh` 保持字节一致，由
`tools/check_protocol_layout.sh` 在 C11 与 C++17 下同时编译校验。

## 3. 共享内存：唯一的事实载体

### 3.1 命名与归属

```
/tmp/soundbridge-<ownerUID>-<sanitized_deviceUID>
```

- `ownerUID` 是创建 mapping 的 Host 用户 UID；`sanitized_deviceUID` 是设备
  UID 的安全化编码。两者共同保证不同用户、不同设备互不干扰。
- Host 是**唯一创建者**。Driver 只做 `open` + `mmap` + 校验。
- Batch 0/1 修复前的路径是 `/tmp/soundbridge_<uid>`，与设备无关，多设备会
  互相覆盖；现行路径已按设备区分。

### 3.2 布局

```
offset 0                     256        320
├──────────── header ─────────┼───────────┼───────────── audio_data ─────────────►
```

| 项 | 值 |
|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200` |
| `RF_SHARED_AUDIO_HEADER_SIZE` | `320` |
| `sizeof(RFSharedAudio)` / `alignof` | `320` / `8` |
| `audio_data` 起始偏移 | `320` |
| `admission_state` | offset `256`（uint32） |
| `admission_epoch` | offset `264`（uint64） |
| `producer_owner_token` | offset `272`（uint64） |
| `admission_claim_seq` | offset `280`（uint64） |
| `_reserved2[32]` | offset `288` |

`rf_admission_state` 的取值：`RF_ADMISSION_CLOSED = 0`、`OPEN = 1`、
`CLOSING = 2`。该块在协议 `0x00020100`（header 256 B）→ `0x00020200`
（header 320 B）时由 Batch 2 加入，原有的 volume/mute/EP/ring 字段偏移全部
保持不变。

任何字段增删、顺序变化都必须提升协议版本并同步 4 份头副本。

### 3.3 生命周期（一句话版本）

`staging open(O_CREAT|O_EXCL|O_NOFOLLOW) → 初始化 header → prefill →
rf_admission_open(随机 64 位 epoch) → rename 原子发布`。

详见 [engineering/SharedMemory-Lifecycle.md](../engineering/SharedMemory-Lifecycle.md)。

## 4. Ring Buffer

- canonical 格式：**stereo Float32 interleaved**（8 B/frame）。其它格式在
  Driver 侧转换；`Float64` 输入当前**不是**受支持路径（fail-closed，见风险
  清单）。
- 容量 `ring_capacity_frames` 必须 `> 0` 且为 2 的幂；默认 48 kHz / 100 ms
  请求 4800 帧 → 实际分配 8192 帧。容量由
  `rf_ring_capacity_frames_for()` 单点计算。
- 索引：`write_index` 只由 Producer、`read_index` 只由 Consumer 以
  `release` 推进，对侧用 `acquire` 读取。**Producer 永不写 `read_index`**
  （旧的 Drop-Old 语义已删除）。
- 溢出策略：**Drop New**。写入放不下时丢弃新帧并计数，绝不覆盖未读数据，
  绝不阻塞。
- 欠载：合法输出区尾部补零，`read_index` 只按实际消费帧数推进。

详见 [engineering/RingBuffer-Design.md](../engineering/RingBuffer-Design.md)。

## 5. Producer 准入与所有权

一次 mapping incarnation 只允许一个 Producer：

```
claim:  producer_owner_token  CAS  0 → token       （token = 64 位 CSPRNG）
        admission_claim_seq += 1
        admission_state = OPEN，admission_epoch = 随机值
write:  允许写入当且仅当
          admission_state == OPEN
       && admission_epoch  == 本 handler 记录的 epoch
       && producer_owner_token == 本 handler 的 token
release: 仅 OnStopIO（最后一个 client）路径，条件见 §7.2
```

要点：

- token 由 `ProducerToken.hpp` 用 `arc4random_buf` 生成，过滤 0，最多重试
  8 次，失败即 fail-closed 返回 0；批 2 Closure 之前是
  `(uid << 32) | (counter | 1)`，实际熵约 31 位，存在可预测性缺陷（CR-1）。
- **epoch** 绑定 incarnation：即使 token 被复用，旧 epoch 的写入也会被拒。
- 写闸门的三条件同时成立才允许写；任一不满足则本回调不写、只计数失败。

详见 [engineering/Admission-Ownership.md](../engineering/Admission-Ownership.md)。

## 6. 回调准入与排空（CallbackGate）

Driver 的实时写回调在触碰 mapping 之前必须通过 `CallbackGate`：

```
state_ = [ CLOSED : bit 31 ][ admitted callbacks : bits 0..30 ]

reader (RT)                             closer (control thread)
-----------                             -----------------------
prev = state_.fetch_add(1)              state_.fetch_or(CLOSED)
if (prev & CLOSED):                     while (count(state_) != 0 && !deadline):
    state_.fetch_sub(1)  // abort          poll (50 µs)
    return false                        → Drained 只在 count 读到 0
... access mapping ...
state_.fetch_sub(1)
```

设计要点：

1. **检查与计数是同一条 RMW**。因此不存在"闸门对计数器已关闭、对读者仍开
   放"的执行；旧实现（`open_` 布尔 + `active_` 计数器 + 二次检查）正是在
   这两步之间存在窗口，且跨两个原子对象无法在 C++ 内存模型内证明。
2. **计数器是唯一权威**。截止时间只区分"已证明排空"与"未证明"，永远不会
   把超时当成排空。
3. **回调永不等待控制线程**。没有条件变量，因此没有丢失唤醒问题；控制线程
   的 sleep 只是轮询间隔。
4. **abort 路径不加载 mapping 指针**，因此闸门关闭后到达的回调不可能触碰到
   已释放的内存。
5. 准入计数饱和（约 21 亿并发）与下溢仅在 debug 构建中 `assert`，release
   构建不引入任何分支成本；这两个断言成立性由不变量 L1 保证。

完整证明（F1–F5、D1、L1–L3、T1–T4、A0–A4、O1–O5）见
[engineering/CallbackGate-Memory-Model.md](../engineering/CallbackGate-Memory-Model.md)。

### 6.1 lock-free 保证

| 原子对象 | 位置 | 断言 |
|---|---|---|
| `std::atomic<uint32_t>` | `CallbackGate::state_` | `MappingRetirement.hpp:168` |
| `std::atomic<uint64_t>` | mapping revision | `Plugin.cpp:66-96` |
| `std::atomic<bool>` | `retired_` | 同上 |
| `std::atomic<RFSharedAudio*>` | `shared_memory_` | 同上 |

四处均为 `static_assert(std::atomic<T>::is_always_lock_free, ...)`，即**编译期**
失败而不是运行期退化。lock-free ≠ wait-free：`fetch_add` 仍可能与其他核争
缓存行，但不会加锁（`std::mutex` / `pthread_mutex` 不进入实时路径）。

## 7. Mapping 退役

### 7.1 唯一 munmap 入口

全仓库只有一个 `munmap` 入口：`Plugin::RetireMapping(reason, budget)`。
调用者只有四个非实时路径：

| 调用者 | reason | 是否持有 `io_mutex_` |
|---|---|---|
| `OnStopIO`（最后一个 client）→ `Disconnect()` | `"disconnect"` | 是 |
| `Retire()`（真实设备移除） | `"device-removed"` | 否 |
| 析构函数 | `"destructor"` | 否 |
| `OpenSharedMemory()` 防御性重开 | `"reopen"` | 否 |

`RetireMapping()` 的时序（顺序本身是安全性的一部分）：

```
revision = mapping_revision_（acquire）
epoch    = claimed_epoch_（relaxed）

若无已发布 mapping：
    callback_gate_.Close()          // 让"指针已清空、下次 start 之间"到达的回调 fail-closed
    return NothingToRetire

ack = callback_gate_.CloseAndDrain(revision, epoch, now + 250 ms)

shared_memory_.store(nullptr, release)   // 先清指针
shared_memory_size_ = 0

if ack.Drained():
    mapping_owner_.reset()               // 唯一的 munmap
else:
    MappingQuarantine::Retain(move(mapping_owner_), revision, epoch, reason)
```

指针在排空尝试**之后**清空，因此仍在回调体内的读者始终持有有效 `mem`；
指针在释放 `mapping_owner_` **之前**清空，因此 munmap 永远不可能通过该
指针被观察到。

### 7.2 为什么释放 producer slot 只在 OnStopIO 做

`OnStopIO` 同时具备两个独立论据：它持有 libASPL 的 per-device
`ioMutex_`（`DoIOOperation` 取同一把锁，因此此刻不可能有回调在跑），并且
`Disconnect()` 走 `RetireMapping()` 的排空证明。设备移除与析构路径只有第二
个论据，所以不在这些路径上 `rf_producer_release()`——避免在可能仍有回调时
把 slot 交给下一个 owner。

### 7.3 Quarantine

无法证明排空时，mapping 被移入 `MappingQuarantine`，**保留映射直到进程退出**，
之后既不读也不写也不 munmap。代价是虚拟地址空间（每条约 32 KiB +
320 B header，`st_size ≤ 64 MiB`）；收益是"我们未能观察到的回调"不可能在
已释放页面上触发 fault。

当前**刻意没有**回收机制：控制线程无法证明某个永不返回的回调已经离开，
`shared_ptr::use_count()` 也不是同步点。因此 quarantine 只增长（仅在
`TimedOut` 时增长），没有硬上限，也没有 TTL。

### 7.4 ACK 与 revision

`DrainAck{revision, epoch, outcome}` 绑定产生它的 incubation。`revision` 是
handler 局部单调戳，新 incarnation 一定更高，因此旧 ACK 不可能被误认为新
mapping 的 ACK（`RetiredRevisionMatches`）。`outcome ∈ {Drained, TimedOut,
NothingToRetire}`；只有 `Drained` 允许 munmap。

详见 [engineering/Mapping-Retirement.md](../engineering/Mapping-Retirement.md)。

## 8. 启动、停止与异常路径

### 8.1 正常启动（Host 先，Driver 后）

```
Host:   create staging → init header → prefill（capacity/2 静音帧）
        → rf_admission_open(随机 epoch) → rename 发布
Driver: OnStartIO → open + mmap + header 校验（版本/大小/容量/格式）
        → rf_producer_claim(token) → 记录 epoch
        → ResizeBuffers() → 绑定 volume/mute 控件 → 同步音量状态
        → callback_gate_.Open()      ← 必须最后
```

`Open()` 必须最后：早于 `ResizeBuffers()` 被准入的回调会与缓冲分配竞争，并
可能在还没有 producer slot 时写入。

`shared_memory_` 以 `release` 存储、`Open()` 是 release RMW，读者的
`fetch_add` 是 acquire RMW 且读到同一 release sequence 的后续成员，因此指针
store happens-before 读者对它的 load（见内存模型证明 §Publication）。

### 8.2 正常停止

```
OnStopIO（最后一个 client，持有 ioMutex_）
  → rf_producer_release(token)
  → Disconnect() → RetireMapping("disconnect")
```

### 8.3 异常路径

| 场景 | 行为 |
|---|---|
| 设备被移除 | `Retire()` 取 `io_mutex_` → `RetireMapping("device-removed")`；不释放 producer slot |
| Host 崩溃 | 旧 inode 随最后引用消失；新 Host 发布新 inode + 新 epoch；Driver 的旧 epoch 写入被拒 |
| 回调永不返回 | 计数永不为 0，本次及之后每次排空都 `TimedOut` → quarantine（liveness 不受影响，新 mapping 仍可发布） |
| 闸门关闭后回调到达 | `TryEnter()` 返回 false，不加载指针，只计 `failed_writes` |

## 9. 崩溃恢复模型

SoundBridge **不使用**任何"判活"启发式（不看 PID、不看 `st_mtime`、不看
`st_nlink` 的推测）。恢复完全由构造保证：

1. Host 每次发布都是**新的 inode**（`O_CREAT|O_EXCL` + `rename`），旧映射
   不可能被新 Host 复用。
2. 每次发布都带**新的随机 epoch**，Driver 记录的 `claimed_epoch_` 与
   新 mapping 不匹配时写入被拒。
3. token 只证明"某个 handler"，epoch 才证明"这个 incarnation"；两者同时
   校验。
4. 旧 mapping 是否真的被 munmap 不影响新 mapping 的正确性——最坏情况是它被
   quarantine 保留。

这是一个**保守但可证明**的模型：代价是虚拟地址空间可能长期增长，收益是
不存在"误判旧状态已死"导致的数据损坏。

## 10. ABI 与版本约束

| 项 | 值 | 强制方式 |
|---|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200` | `tools/check_protocol_layout.sh` |
| Driver plist `SBAudioProtocolVersion` | `131584` | 同上 |
| `RF_SHARED_AUDIO_HEADER_SIZE` | `320` | 编译期 `static_assert` |
| `sizeof(RFSharedAudio)` | `320` | 同上 |
| `audio_data` offset | `320` | 同上 |
| 头副本一致性 | 4 份 SHA-256 相同 | `tools/sync_shared_header.sh --check` |
| 版本号 | `VERSION` = `1.2.0` | `tools/verify_version_consistency.sh` |

当前头副本一致哈希：
`0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee`。

## 11. 验证状态（摘要）

平台：macOS 27.2.1（`26B131`）/ arm64，Apple clang 21.0.0，Apple Swift
6.4.2；Driver Release 构建为 universal（`x86_64 arm64`）。

| 批次 | 结论 | 证据（批次报告已移出仓库，结论保留） |
|---|---|---|
| Batch 0 + 1 | `IMPLEMENTED — TESTS PASSED` | 当前由 `make test` 持续覆盖：`check_protocol_layout.sh`、`sync_shared_header.sh --check` 与 Host 测试套件 |
| Batch 2 | `IMPLEMENTED — TESTS PASSED` | 同上 |
| Batch 2 Closure | `PASS` | 同上 |
| Batch 3 | `CONDITIONAL PASS` | 同上 |
| Batch 3 Closure Fix | `CONDITIONAL PASS` | 同上 |
| 1.2.0 发布与端到端验证 | `PASS — RELEASED AND VERIFIED` | [SoundBridge-1.2.0-Final-Release-Report.md](../release/SoundBridge-1.2.0-Final-Release-Report.md) |

1.2.0 的发布验证在架构层面确认了三件事：本文描述的路径确实被走到（驱动加载 → 共享
内存连接 → 回调流动）；音量/静音/EQ 的控制字段确实通过共享内存生效；31 分 01 秒
连续播放期间零欠载、零溢出、零回调超预算。它**没有**验证设备移除、其他 macOS 版本
或 Intel 硬件，这些仍在
[risks/Known-Limitations.md](../risks/Known-Limitations.md) 中以未验证状态保留。

## 12. 明确不在本架构内的东西

以下内容出现在历史研究记录中，但**不是** SoundBridge 1.2.0 的实现：

- **XPC / Mach service 能力分发**（Phase-3.1、Phase-3.7、EXP-1、PoC 6B-1F
  系列）：从未进入产品代码，交付代码中不存在任何 `xpc_` 调用。控制面实际
  使用 `/tmp` 下按设备命名的共享内存与控制文件。
- **旧双原子 CallbackGate**：已由单原子状态字替换，仅作为历史决策记录在
  Closure Fix 报告中。
- **Drop-Old 溢出策略**、**`/tmp/soundbridge_<uid>` 单一路径**、
  **`rf_ring_capacity_frames` 缺省 0**：均已在 Batch 0/1 修复。

保留这些记录的目的只是解释"为什么现在是这样"，它们不构成待实现项。
