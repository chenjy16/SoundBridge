# SoundBridge 工程文档

本目录是 SoundBridge 1.2.0 的**唯一**工程文档位置。历史上独立的
`SoundBridge-Research/` 研究目录已于 1.2.0 研究阶段结束时归档并退役，
其长期有价值的内容已并入此处（迁移记录见
[Documentation-Migration-Manifest.md](Documentation-Migration-Manifest.md)）。

文档只描述**当前已实现**的架构与**实际执行过**的验证。凡未验证的事项一律
标注为未验证，不用推断代替证据。

---

## 1. 产品定位

SoundBridge 是一个 macOS 菜单栏应用，为**固定音量**的 HDMI / DisplayPort
显示器提供系统级软件音量控制。

系统把这些显示器的音量滑块置灰，因为设备本身不提供硬件音量。SoundBridge
在应用与物理设备之间插入一个虚拟音频驱动（AudioServerPlugIn），把系统输出
改道到该驱动，由 Host 进程做增益、EQ 与格式适配后再交给物理设备。用户看到的
仍然是系统音量滑块与键盘音量键。

- 无内核扩展（不加载 kext），无后台守护进程常驻要求。
- 签名与安装：App 侧为 ad-hoc 签名（非公证），安装引导一次性完成。
- 版本号 `VERSION` = `1.2.0`；共享音频协议版本 `0x00020200`。

## 2. 整体架构

```
┌───────────────┐   preferences / control   ┌──────────────────┐
│ SoundBridge   │──────────────────────────►│ SoundBridge Host │
│ App (menu bar)│                           │ (user process)   │
└───────┬───────┘                           └────┬────────┬────┘
        │ mmap (EQ / volume state)               │        │
        │                                        │        │ AudioUnit render
        ▼                                        ▼        ▼
  /tmp/soundbridge-<ownerUID>-<deviceUID>     DSP (EQ)  physical device
        ▲                                        ▲
        │ mmap + ring write                      │
┌───────┴────────┐    HAL callback    ┌─────────┴──────────┐
│ SoundBridge    │◄───────────────────│ coreaudiod /       │
│ Driver (.driver)│   (libASPL)        │ apps audio output  │
└────────────────┘                    └────────────────────┘
```

数据面是**一块文件映射的共享内存**：固定 320 字节头 + 二次幂帧数的
单生产者单消费者（SPSC）Ring Buffer。

- 音频主链：`coreaudiod` → libASPL `Device` → `OnWriteMixedOutput`
  → `rf_ring_write` → Host `AudioRenderer.render` → `rf_ring_read`
  → DSP / 增益 / 反交织 → 物理设备。
- 控制面：App ↔ Host 的偏好与 EQ 参数；Driver 通过 `/tmp` 下的控制文件与
  Host 交换设备列表与音量状态。

## 3. 组件职责

| 组件 | 位置 | 职责 |
|---|---|---|
| App（菜单栏外壳） | `apps/mac/SoundBridgeApp` | UI、偏好、引导安装、EQ 编辑；通过 mmap 直接写 EQ / 音量状态 |
| Host | `packages/host` | 唯一创建共享内存 mapping 的一方；音频渲染回调（Consumer）；设备发现、代理设备注册、生命周期、单实例锁 |
| Driver | `packages/driver` | AudioServerPlugIn；声明代理设备，在 HAL 写回调中做格式转换 / SRC 并写 Ring（唯一 Producer）；映射的准入、排空与退役 |
| DSP | `packages/dsp` | 10 段参数 EQ，stereo Float32 interleaved 原地处理 |
| 共享协议 | `packages/shared/include/RFSharedAudio.h` | 头布局、Ring、Admission、Producer token 的唯一事实源（四副本必须字节一致） |

## 4. Ring Buffer 约束

- canonical 格式：**stereo Float32 interleaved**，8 bytes/frame。
- `ring_capacity_frames` 必须 **> 0 且为 2 的幂**；寻址 `slot = index & (capacity-1)`。
  默认 48 kHz / 100 ms 请求 4800 帧 → 实际容量 8192 帧。
- 索引所有权：`write_index` 只由 Producer、`read_index` 只由 Consumer
  以 `release` 推进；对侧索引用 `acquire` 读。**Producer 永不写 R**
  （Drop-Old 已删除）。
- 溢出策略：**Drop New**（丢弃新帧，绝不覆盖未读数据，绝不阻塞）。
- 欠载：合法输出区尾部补零，`read_index` 只按实际消费推进。
- 详细契约与内存序见 [engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md)。

## 5. Callback Admission / Drain 机制

Driver 的实时写回调在触碰 mapping 之前必须通过 `CallbackGate`：

```
state_ = [ CLOSED : bit 31 ][ admitted callbacks : bits 0..30 ]

reader (RT)                             closer (control thread)
prev = state_.fetch_add(1)              state_.fetch_or(CLOSED)
if (prev & CLOSED): abort → return      while (count != 0 && !deadline)
else: 访问 mapping ……                       poll
      state_.fetch_sub(1)               → Drained 仅当 count 真读到 0
```

- 检查与计数是**同一条 RMW**，不存在"看起来已关闭但仍被计数"的窗口。
- **关闭闸门不等于排空**：只有计数器读到 0 才算 Drained；deadline 只能决定
  "未证明"，不能决定"已排空"。
- 控制线程可以等回调，回调**永不**等控制线程；没有条件变量，因此没有
  丢失唤醒问题。
- 内存模型证明见 [engineering/CallbackGate-Memory-Model.md](engineering/CallbackGate-Memory-Model.md)。

## 6. Mapping Retirement 生命周期

一个 mapping incarnation 的生命周期：

```
CREATED → INITIALIZED → PUBLISHED → ACTIVE → CLOSING → DRAINING
                                                     ├─ RETIRED      (munmap)
                                                     └─ QUARANTINED  (永不 munmap)
```

- 全仓库只有**一个** `munmap` 入口：`RetireMapping()`；只有
  `Drained` 才执行 `mapping_owner_.reset()`。
- 无法证明排空时进入 `MappingQuarantine`，保留映射直到进程退出；这是当前
  唯一可证明安全的策略，刻意没有回收机制。
- 旧 ACK 不可能被新 incarnation 复用（handler 级单调 `revision` + `epoch`）。
- 详见 [engineering/Mapping-Retirement.md](engineering/Mapping-Retirement.md)。

## 7. Shared Memory 生命周期

- Host 是唯一创建者：`staging open(O_CREAT|O_EXCL) → init → prefill →
  rf_admission_open(随机 epoch) → rename`。**每次发布必然是新的 inode +
  新的 epoch**，旧映射不可能被复用。
- Driver 在 `OnStartIO` 中 mmap、校验 header、`rf_producer_claim(token)`、
  发布指针，**最后**才 `callback_gate_.Open()`。
- 崩溃恢复不依赖任何"判活"启发式：新 incarnation 天然隔离旧状态，
  旧 owner token 随旧 inode 一起作废。
- 详见 [engineering/SharedMemory-Lifecycle.md](engineering/SharedMemory-Lifecycle.md)。

## 8. 关键 ABI 与协议版本

| 项 | 值 |
|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200`（十进制 131584） |
| Driver plist `SBAudioProtocolVersion` | `131584` |
| `RF_SHARED_AUDIO_HEADER_SIZE` | `320` bytes |
| `sizeof(RFSharedAudio)` / `alignof` | `320` / `8` |
| `audio_data` offset | `320` |
| Admission 块 | `admission_state` @256、`admission_epoch` @264、`producer_owner_token` @272、`admission_claim_seq` @280、`_reserved2[32]` @288 |
| 共享头副本 | 4 份，SHA-256 必须全部相同（`tools/sync_shared_header.sh --check`） |

布局由 `tools/check_protocol_layout.sh` 在 C11 与 C++17 下同时编译校验；
任何字段增删都必须提升协议版本。

## 9. 当前验证平台与测试状态

平台：macOS 27.2.1（`26B131`）/ arm64（Apple Silicon），Apple clang 21.0.0，
Apple Swift 6.4.2；Driver 为 universal（`x86_64 arm64`）Release 构建。

| 批次 | 状态 | 主要证据 |
|---|---|---|
| Batch 0 + 1（协议契约冻结、Ring 修复） | `IMPLEMENTED — TESTS PASSED` | 全量 269/269；Ring 契约 17/17；ASan 0 报告 |
| Batch 2（Admission & Ownership） | `IMPLEMENTED — TESTS PASSED` | Admission 34/34；跨进程 10/10；全量 313/313 |
| Batch 2 Closure（Token 唯一性、Callback Exit） | `PASS` | CR-1 修复后 PASS；CR-2 零改动 PASS |
| Batch 3（Mapping Retirement） | `CONDITIONAL PASS` | Driver 11 组 61 断言；Host 318/318；TSan/ASan 0 报告 |
| Batch 3 Closure Fix（CallbackGate 内存模型） | `CONDITIONAL PASS` | 17 组 119 断言；40/40 重复；TSan 5/5；ASan 0 报告 |

验证报告见 [verification/](verification/)。**未验证项不因归档而消失**，
统一登记在 [risks/Known-Limitations.md](risks/Known-Limitations.md)。

## 10. 已知限制（摘要）

完整清单见 [risks/Known-Limitations.md](risks/Known-Limitations.md)。最需要
在发布前了解的几条：

- 真实 HAL 设备移除、真实驱动安装部署、真实负载下的 xrun 观测**均未验证**；
- macOS 14.4 兼容性**未认证**（当前验证平台为 macOS 27.2.1）；
- 回调路径仍存在 5 类既有 RT 违例（RT-1 … RT-5），本轮未修；
- Quarantine 无回收机制，永久占用虚拟地址空间（仅在回调永不返回时触发）；
- 32 位平台无 lock-free 保证（当前仅支持 arm64 / x86_64）；
- Host / App 完整回归未在 Batch 3 Closure Fix 中重跑（改动不在其编译单元内）。

## 11. 文档导航

```
docs/
├── README.md                               本文件
├── architecture/
│   └── SoundBridge-1.2.0-Architecture.md   最终架构（唯一现行版本）
├── engineering/
│   ├── RingBuffer-Design.md                Ring 契约、容量、内存序
│   ├── Admission-Ownership.md              Admission 状态机与 Producer 唯一性
│   ├── Callback-Lifecycle.md               回调准入 / 排空 / RAII 租约
│   ├── Mapping-Retirement.md               退役前提、唯一 munmap 入口、Quarantine
│   ├── SharedMemory-Lifecycle.md           incarnation 全生命周期与崩溃恢复
│   └── CallbackGate-Memory-Model.md        C++ 内存模型证明与 lock-free 保证
├── verification/
│   ├── Batch-0-1-Verification.md
│   ├── Batch-2-Verification.md
│   ├── Batch-2-Closure-Verification.md
│   ├── Batch-3-Verification.md
│   └── Batch-3-Closure-Fix.md
├── risks/
│   └── Known-Limitations.md
├── release/
│   └── SoundBridge-1.2.0-Release-Checklist.md
├── manifests/
│   └── Research-Directory-Inventory.sha256 已退役研究目录的冻结哈希清单
├── Documentation-Migration-Manifest.md     逐文件迁移记录
├── Research-Directory-Retirement-Report.md 删除前审核与删除后验证
└── 1.2.0/                                  Phase 2.x 阶段报告（早于 Batch 0，保留原文）
```

`docs/1.2.0/` 保存 Phase 2.0 – 2.1.5 的历史阶段报告，内容针对 UI、安装器与
Host 生命周期，未被 Batch 0–3 系列取代，因此原样保留。它们描述的版本状态
（例如协议 `0x00020100`）是**当时**的状态，不代表当前 ABI。

## 12. 维护规则

- 新的工程文档一律写入本目录，不再创建独立研究目录。
- 修改共享头 / 协议 / Ring 语义时，必须同步更新 `architecture/` 与
  `engineering/` 中对应章节，并新增一份 `verification/` 报告。
- 未验证事项一经发现就登记到 `risks/Known-Limitations.md`，不要只在
  提交信息里提及。
- 不使用 `CONDITIONAL PASS` 之外的措辞描述带条件的通过。
