# SoundBridge 主流程导览

> **用途**：按"一次完整生命周期"的顺序，把 SoundBridge 的四个组件串成一条可读的主线，每段都指向真实代码位置。
> **读者**：第一次接手本仓库，或需要快速定位"某个现象应该去哪一层看"的开发者。
> **配套**：已知缺陷的完整证据见 [SoundBridge-Core-Engineering-Audit.md](release/SoundBridge-Core-Engineering-Audit.md)。本文只做流程导览，并在出事的位置打上缺陷编号，不重复论证。
> **状态**：基于 `main` @ `eb45303f`，VERSION `1.2.0`，协议 `0x00020200`。行号会随重构漂移，函数名相对稳定。

---

## 目录

- [1. 一张图看懂系统边界](#1-一张图看懂系统边界)
- [2. 安装期：驱动先落盘，才有"设备"](#2-安装期驱动先落盘才有设备)
- [3. App 常驻，并拉起 Host 子进程](#3-app-常驻并拉起-host-子进程)
- [4. Host 启动装配：Step -1 → Step 8](#4-host-启动装配step--1--step-8)
- [5. 共享内存的诞生](#5-共享内存的诞生)
- [6. 驱动把设备"点亮"](#6-驱动把设备点亮)
- [7. 播放主链路](#7-播放主链路)
- [8. 控制面三条线](#8-控制面三条线)
- [9. 生命周期与异常路径](#9-生命周期与异常路径)
- [10. 缺陷落点索引](#10-缺陷落点索引)
- [11. 建议阅读路线](#11-建议阅读路线)
- [附录 A. 关键路径与常量](#附录-a-关键路径与常量)
- [附录 B. 术语表](#附录-b-术语表)

---

## 1. 一张图看懂系统边界

四个组件、三条通道。理解 SoundBridge 的关键不是代码量，而是**谁拥有哪条通道**。

```
                       ┌──────────────────────────────────────────┐
      控制面（文件）    │ /tmp/soundbridge-devices.txt  Host → Driver│
                       │ /tmp/soundbridge-<owner>-<uid>  共享内存   │
                       │ device-state.json             Host → App  │
                       │ Darwin notify                App  → Host  │
                       └──────────────────────────────────────────┘
                       ┌──────────────────────────────────────────┐
      数据面（ring）     │ Driver 写 write_index ──► Host 读 read_index│
                       └──────────────────────────────────────────┘
                       ┌──────────────────────────────────────────┐
      时间面（IO 回调）  │ coreaudiod 周期性调用两侧的回调            │
                       └──────────────────────────────────────────┘

  App (SwiftUI)  ──Process──►  Host (Swift 可执行)  ──mmap──►  Driver (HAL bundle)
       │                            │                              │
       └────── mmap 读写 ───────────┴──────── 同一个 /tmp 文件 ─────┘
```

**所有权的四条铁律**（改动任一模块前必须先确认这几条）：

| 资源 | 唯一拥有者 | 证据 |
| --- | --- | --- |
| `admission_state` / `admission_epoch` | Host | 仅 `SharedMemoryManager` 写 |
| ring 的生产 | Driver | `rf_ring_write` 只写 `write_index`（Drop-New） |
| ring 的消费 | Host | `rf_ring_read` 只写 `read_index` |
| EQ 快照 | App | `SharedMemoryMappingManager` 是唯一调用点 |
| 系统默认输出 | 用户 / App UI | Host 从不写默认输出（P2 Batch 2 起） |

对应代码：[RFSharedAudio.h:236-330](../packages/shared/include/RFSharedAudio.h#L236-L330) 是结构体定义，四份副本必须经 `tools/sync_shared_header.sh --check` 保持一致。

---

## 2. 安装期：驱动先落盘，才有"设备"

驱动不是 daemon，而是一个 HAL bundle，必须放在固定路径才能被 `coreaudiod` 加载：

```swift
// DriverInstaller.swift:12-18
static let driverPath = "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
static let bundleIdentifier = "com.soundbridge.driver"
```

- 安装产物由 [`tools/build_installer_pkg.sh`](../tools/build_installer_pkg.sh) 生成 PKG，落地走 [`tools/sb_install_transaction.sh`](../tools/sb_install_transaction.sh) 的事务化替换（staging → 校验 → 原子替换 → 回滚）。
- 版本一致性由 [`tools/verify_version_consistency.sh`](../tools/verify_version_consistency.sh) 与 App 内 `DriverVersionGate` / `DriverCompatibilityNotice` 双重把关。
- `coreaudiod` 重启后加载 bundle，`Plugin.cpp` 的 `extern "C" SoundBridgeDriverPluginFactory` 被调用。
- 验证链：[`tools/verify_pkg_driver.sh`](../tools/verify_pkg_driver.sh)、[`tools/verify_signatures.sh`](../tools/verify_signatures.sh)。

**关键认知**：安装完成后，系统里仍然**没有任何 SoundBridge 输出设备**。驱动是"守株待兔"型插件——它只实例化控制文件里列出的代理设备。所以：

> Host 是设备的**声明者**，驱动是设备的**实例化者**。没有 Host，驱动什么都不做。

这一条解释了绝大多数"驱动装了但看不到设备"的现象：不是驱动没加载，而是 Host 没发布清单（或清单里的映射没准备好）。

**相关代码**：[DriverInstaller.swift](../apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift)、[DriverVersionGate.swift](../apps/mac/SoundBridgeApp/Sources/Services/DriverVersionGate.swift)、[DriverUninstaller.swift](../apps/mac/SoundBridgeApp/Sources/Services/DriverUninstaller.swift)

---

## 3. App 常驻，并拉起 Host 子进程

入口在 [`SoundBridgeApp.swift:64-145`](../apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift#L64-L145)：

```
applicationDidFinishLaunching
 ├─ registerCustomFont()
 ├─ OnboardingState.hasCompleted() ? 进菜单栏 : showOnboarding()
 ├─ checkDriverVersionMismatch()        版本闸门，只提示不阻塞
 ├─ launchHostIfNeeded()                HostSupervisor 起子进程
 ├─ IPCController.startMonitoring()     监听 device-state.json + notify
 ├─ SharedMemoryMappingManager.start()  App 内唯一 mmap 持有者
 ├─ applyHostLifecycle(...)             锁判存活，报告判在做什么
 ├─ HostStatusModel.refreshHandler      菜单栏打开时主动刷新
 └─ setupMenuBar()
```

### 3.1 Host 的拉起与看护

[HostSupervisor](../apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift#L250-L279) 负责：

- `HostExecutableLocator` 按架构目录（`arm64` / `x86_64`）定位 `SoundBridgeHost`
- `Process` 启动 + `terminationHandler` 收敛到单一队列
- watchdog 超时 → 升级终止（SIGTERM → SIGKILL）
- 区分"用户要求停止"与"意外退出"，意外退出才重启，带连续失败退避

**易错点**（Gate 3 修过）：`terminationHandler` 在任意线程回调，早期把它当成"App 要退出"直接 `NSApp.terminate`，导致 Host 一崩 App 就没了。现在收敛到 supervisor 自己的串行队列。

### 3.2 App 侧的三个服务

| 服务 | 职责 | 锚点 |
| --- | --- | --- |
| `VolumeController` | 操作代理设备的 HAL 音量/静音，绑定代理设备 | [VolumeController.swift](../apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift) |
| `EQController` | 三段 UI（Bass/Mids/Treble）→ 10 段增益 | [EQController.swift](../apps/mac/SoundBridgeApp/Sources/Services/EQController.swift) |
| `SharedMemoryMappingManager` | App 内唯一 mmap 封装，EQ/Volume 都经它 | [SharedMemoryMappingManager.swift:151](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L151) |

`SharedMemoryMappingManager` 的几个不变量值得记住：

- 路径由 [`defaultPath(forUID:ownerUID:)`](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L245) 统一构造，不再各处拼字符串
- 只在 `deviceUIDProvider` 有值时 attach；为空时 `revalidate()` 直接返回（这条曾让 retire 失效）
- 发布/失效通过 `mappingPublished` / `mappingUnavailable` 广播，`EQController` 与 `VolumeController` 都订阅
- 2 秒兜底轮询（`fallbackInterval`）覆盖"通知丢了"的情况

---

## 4. Host 启动装配：Step -1 → Step 8

[main.swift:97-445](../packages/host/Sources/SoundBridgeHost/main.swift#L97-L445) 是整个系统唯一有严格顺序的地方。**改动任何一步的位置都要先读 `ShutdownSequence` 的逆序要求。**

| Step | 动作 | 锚点 | 失败后果 |
| --- | --- | --- | --- |
| -1 | `flock(LOCK_EX\|LOCK_NB)` 抢单实例锁 | [main.swift:114](../packages/host/Sources/SoundBridgeHost/main.swift#L114) | 直接 exit，**不做** unlink/create |
| 0 | 建 Application Support / Logs | [main.swift:135](../packages/host/Sources/SoundBridgeHost/main.swift#L135) | 释放锁后 exit |
| 1 | 枚举物理设备，取标称采样率写 `SoundBridgeConfig.activeSampleRate` | [main.swift:158](../packages/host/Sources/SoundBridgeHost/main.swift#L158)、[:242](../packages/host/Sources/SoundBridgeHost/main.swift#L242) | 空设备进 idle，不是失败 |
| 2 | 注册 HAL 监听 + Darwin notify + 睡眠唤醒 | [main.swift:200](../packages/host/Sources/SoundBridgeHost/main.swift#L200) | — |
| 3 | 每设备 `createMemory`，**全部成功**才发布 | [main.swift:254](../packages/host/Sources/SoundBridgeHost/main.swift#L254) | degraded + 有界重查 |
| 4 | 写控制文件 | [main.swift:269](../packages/host/Sources/SoundBridgeHost/main.swift#L269) | 同 Step 3 |
| 5 | 启动心跳 | [main.swift:272](../packages/host/Sources/SoundBridgeHost/main.swift#L272) | — |
| 6 | 有界等待代理设备出现在 HAL | [main.swift:284](../packages/host/Sources/SoundBridgeHost/main.swift#L284) | degraded：驱动没装 / 版本不匹配 |
| 7 | 解析 proxy→physical 路由（**不碰默认输出**） | [main.swift:310](../packages/host/Sources/SoundBridgeHost/main.swift#L310) | degraded |
| 7.5 | 采纳已提交音量为运行时权威 | [main.swift:330](../packages/host/Sources/SoundBridgeHost/main.swift#L330) | — |
| 8 | `GuardedEngineStart` 建 AUHAL 并 start | [main.swift:346](../packages/host/Sources/SoundBridgeHost/main.swift#L346) | 全设备失败则 cleanup + exit(1) |
| 8.5 | post-start 音量重放（0.3 s 后） | [main.swift:381-396](../packages/host/Sources/SoundBridgeHost/main.swift#L381-L396) | — |
| — | `RunLoop.current.run()` 常驻 | [main.swift:438](../packages/host/Sources/SoundBridgeHost/main.swift#L438) | 返回也必须 `cleanup()` |

### 4.1 Step 3 的"全有或全无"

```swift
// main.swift:252-260
// 启动与热插拔使用同一准备规则：所有映射可用后才发布控制文件。
let prepared = DeviceMappingPreparation.publishIfReady(
    uids: devices.map { $0.uid },
    canProceed: canPrepare,
    hasMapping: { memoryManager.acquireMemory(for: $0) != nil },
    createMapping: { memoryManager.createMemory(for: $0, persistence: volumePersistence) != nil },
    publish: { deviceRegistry.update(devices) }
)
```

**为什么不允许"部分发布"**：驱动一旦看到清单条目就会 `AddDevice`，如果那个 uid 的映射还没建好，`OnStartIO` 会 `ValidateConnection` 失败 → 设备出现在列表里但放不出声。半成品比没有更糟。

`canProceed` 闭包同时校验四个条件：`lifecycleGate.permitsNormal()`、锁仍持有、session 未变、shutdown 未完成。这是为了防止"启动还在跑，恢复流程已经接管"。

### 4.2 Step -1 的位置为什么必须在最前面

`HostInstanceLock` 用 `flock` 而不是 `pgrep`：进程名检查有 TOCTOU 窗口，而第二个 Host 一旦跑起来就会 unlink 第一个的 mapping，留下"幽灵消费者"。所以锁是**第一件事**，拒绝时在任何副作用之前 exit。

---

## 5. 共享内存的诞生

[SharedMemoryManager.createMemory](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L188-L366) 是系统的"建交"动作。完整时序：

```
mutationLock.lock()                                   :191  ← 全程持锁
 │
 ├─ open(staging inode) / ftruncate(capacity) / mmap
 │    容量来自 rf_ring_capacity_frames_for(rate, 100ms)，单一事实源
 ├─ rf_shared_audio_init(mem, rate, 2ch, Float32)
 ├─ 静音预填（在 staging inode 上一次性完成，rename 之前）
 ├─ rf_admission_open(mem, epoch)                     :324
 ├─ rename(staging → /tmp/soundbridge-<owner>-<uid>)  原子发布
 └─ deviceMemory[uid] = mapping
mutationLock.unlock()
```

### 5.1 为什么用 rename 而不是直接写

新 Host 每次起一个新 inode，然后原子替换路径。于是：

- 旧 Host 的 mapping 仍然有效（inode 还被引用），不会因为新 Host 而崩
- 新 Host 与驱动通过 **session UUID + inode + 容量** 三元组校验身份（`validateSharedMemory`）
- 崩溃后残留的文件由下一个 Host 的 `unlinkIfStillOwned` 清理

这就是 E4（Host 崩溃恢复）能工作的底层机制，也是 D4（retire 不释放 claim）被判定为"仅条件性风险"的原因：**身份由 mapping 承载，不由 handler 承载。**

### 5.2 渲染路径的映射是"单槽 + 租约 + 延迟发布"

`renderMapping` 只有一个槽位，切换时走 [`publishRenderMapping`](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L515) → 旧 mapping 进 `retiredRenderMappings` → [`retireRenderPath`](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L569) 撤销 admission 并把超时的留到 quarantine。

IO 线程不持锁：它通过 [`enterRenderMemory`](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L453) / [`exitRenderMemory`](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L460) 在 `rf_rt_gate` 上取一个**租约**。租约未归还时，控制线程的发布被写成 `renderPendingMapping` 而不是原地替换（[`drainDeferredRenderPublication`](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L466)），因此回调里那个裸指针在整个函数体内有效。

**易错点**：`enterRenderMemory` 的成功是 render 里所有裸指针操作的前提；任何早退路径都必须配对 `exitRenderMemory`（[AudioRenderer.swift:536-543](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L536-L543) 用 `defer` 做了这件事）。漏掉一次不平衡的 exit，后续发布会被永久推迟。

---

## 6. 驱动把设备"点亮"

[Plugin.cpp:1668](../packages/driver/src/Plugin.cpp#L1668) `MonitorControlFile` = Darwin notify + 1 秒轮询：

```
MonitorControlFile
 └─ SyncDevices                                   :1653  读清单，增删设备
     ├─ AddDevice(name, uid, ...)                 :1526
     │   └─ new SoundBridgeDevice                 :374   aspl::Device 子类
     │       ├─ GetZeroTimeStampImpl              :407   mach_absolute_time 锚点
     │       ├─ SoundBridgeVolumeControl          :280   音量 → 共享内存
     │       └─ SoundBridgeMuteControl            :327   静音 → 共享内存
     └─ RemoveDevice(uid)                         :1541
         └─ handler->Retire() → CloseAndDrain → munmap | quarantine
```

### 6.1 代理设备是固定的 48 kHz / 2ch

`CreateProxyDevice` 里代理设备的 ASBD 是 48 kHz、2 声道，与物理设备无关。这就埋下了 E3 的错配：**代理设备对外宣称的速率（48k）、ring 的运行速率、Host 输出到的物理设备速率，是三个独立的数。**

### 6.2 时间戳为什么自己算

`GetZeroTimeStampImpl`（[:407](../packages/driver/src/Plugin.cpp#L407)）不用系统默认实现，而是用 `mach_absolute_time` 锚点加周期计数自己推。原因是 Safari Web Audio 对时间戳漂移敏感，默认实现在长时间播放后会累积误差导致卡顿。

### 6.3 OnStartIO 才 attach

设备被创建不等于共享内存被连接。真正的握手发生在第一次播放：

```
OnStartIO                                          :562
 ├─ OpenSharedMemory                               :1013   open + mmap + fd 校验
 ├─ ValidateConnection                             :1094   session/inode/容量三元组
 ├─ rf_producer_claim                                     producer 令牌
 └─ SyncVolumeStateWithSharedMemory                :964    已提交音量推回 HAL（抑制回声）
```

**所以"设备可见但 `driver_connected=0`"是正常状态**：只要没有 App 往代理设备播放，`OnStartIO` 就不会触发。这是排查"没声音"时最容易误判的一点。

---

## 7. 播放主链路

### 7.1 驱动侧：coreaudiod → 共享内存

```
OnWriteMixedOutput                                 :733   ← 实时线程，每周期
 ├─ HandleFormatChange                             :1215  仅在格式变化时
 │   └─ ResizeBuffers                              :1201  ← 堆分配
 ├─ interleaved_buf_.resize                               ← 堆分配
 ├─ ConvertToFloat32Interleaved                    :1231  ← 可能 resize
 ├─ ProcessWithSampleRateConversion                :1289  ← 输入速率≠ring 速率时
 ├─ WriteWithAdaptiveDriftCompensation             :1318
 ├─ stats_.LogPeriodic()                           :849   ← 每帧调用
 └─ rf_ring_write                                         Drop-New，只写 write_index
```

三个必须知道的细节：

1. **格式矩阵**：Float32/Float64/Int16/Int24/Int32 各有分支；整数分支**不支持 non-interleaved**，Int24 按 3 字节步进（不认 24-in-32）。当前客户端只协商 Float32 interleaved，所以这两条是"潜在"缺陷（审计 D2 判 CONFIRMED RISK）。
2. **Drop-New 而不是 Drop-Old**：溢出时丢弃新帧并计数，不推进 `read_index`。这是 Batch 1 的修正——旧实现让生产者和消费者同时写 `read_index`，属数据竞争。
3. **`OnProcessMixedOutput`（:854）是刻意的空实现**：音量由 Host 施加，驱动不重复处理。看到这个空函数不要以为漏了代码。

**D1 就落在这里**：`resize` 与 `LogPeriodic` 在实时回调里。

### 7.2 Host 侧：共享内存 → DSP → 物理设备

[AudioRenderer.render](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L502-L676) 是 AUHAL 的 IO 回调。它的守卫风格很值得学：**宁出静音，不出噪声。**

```
render(bufferList, frameCount)                          :502
 ├─ recordCallbackDuration（defer，覆盖所有早退路径）     :505
 ├─ 容量守卫  frameCount ≤ renderCapacityFrames           :526  → 静音
 ├─ enterRenderMemory()                                  :536  → 无 mapping 则静音
 │   defer { exitRenderMemory() }                        :543
 ├─ 通道守卫  ringChannels == buffer 数                   :551  → 静音
 ├─ rf_ring_read → deinterleave                          :766
 ├─ EQ 变更检测（memcmp 快照）
 │   ├─ rf_load_eq_snapshot                              ← 返回值被丢弃（C2）
 │   ├─ update_band_gain ×10 / update_preamp / set_bypass
 │   └─ 全部在 IO 线程完成（单写者，这是 A2 立论的基础）
 ├─ soundbridge_dsp_process_interleaved                  ← B3 在这里爆
 ├─ rf_load_volume_scalar + mute → VolumeTaper → 乘增益   :630
 └─ 写入输出缓冲
```

`VolumeTaper` 是 `dB = 48·√s − 48`：`s=0.35` → −19.6 dB，`s=1.0` → 0 dB。低电平素材在默认音量下"听不见"通常不是 bug，而是这条曲线 + 素材本身电平太低。

### 7.3 一次回调里发生的完整时序

```
coreaudiod 周期到
  ├─► [Driver] OnWriteMixedOutput
  │     读取混合后的输入 → 转 Float32 → (必要时)重采样 → 写 ring → 递增 write_index
  └─► [Host] AudioRenderer.render
        读 ring（按 write_index/read_index 快照）→ 拆交织 → 应用 EQ/音量 → 写物理设备缓冲
```

两侧是**同一个周期里的两个独立回调**，通过 ring 解耦。没有直接调用关系，所以任何"驱动调 Host"的猜测都是错的。

**未验证点（诚实标注）**：ring 的 `sample_rate` 是生产速率，Host 用它算欠载预算（[AudioRenderer.swift:549-551](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L549-L551)）；当它与物理设备速率不一致时，速率适配的完整落点本次审计没有逐行追完。不要据本文推断"已经处理"或"一定没处理"。

---

## 8. 控制面三条线

### 8.1 音量与静音

```
用户拖动音量
 └─► [HAL] SoundBridgeVolumeControl::SetRawValueImpl    :306
       └─ rf_store_volume_scalar                        ← 不递增 revision
 └─► [Host] ProxyDeviceManager.commitProxyVolumeState   :628  (main queue)
       ├─ VolumePersistence.save
       └─ SharedMemoryManager.publishVolumeState        :366
            └─ rf_publish_volume_state                 ← revision +1
 └─► [Host] render 读取 rf_load_volume_scalar + mute    :630
 └─► [Driver] OnStartIO 时 SyncVolumeStateWithSharedMemory :964（抑制回声）
```

两条写路径不对称是 C3 的来源：驱动侧写值不推进 revision，Host 侧写值推进。端到端能收敛，因为 Host 的 publish 总是跟随一次代理设备音量变更通知。

### 8.2 EQ

```
App EQController（Bass / Mids / Treble 三个滑块）
 └─► SharedMemoryMappingManager.publish
       └─ rf_store_eq_snapshot            ← App 是唯一写者
 └─► Host render
       rf_load_eq_snapshot → memcmp → update_band_gain ×10 → process_interleaved
```

**两个关键事实**：

1. **App 只发增益，不发频率。** 频段频率来自 Host 的 `applyInitialPreset`（[AudioRenderer.swift:677](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L677)），其中包含 16 kHz 的 high shelf。这条链路解释了为什么 B3 不需要用户"设置一个危险频率"就能触发。
2. **快照是跨进程 seqlock，但 payload 不是原子对象**（C2）。读取失败时 Host 仍然应用了撕裂值。

### 8.3 采样率

```
物理设备标称速率
 ├─ 启动: AudioEngine.setupWithDevice                    :120-132
 └─ 切换: AudioEngine.switchDevice                       :195-258
        ├─ AudioOutputUnitStop
        ├─ renderer.updateSampleRate(rate)               :460
        │    ├─ waitForRenderPathIdle（轮询 rf_rt_gate_in_flight）
        │    └─ soundbridge_dsp_set_sample_rate           ← A3：preamp 归零
        └─ AudioOutputUnitStart
```

顺序是对的（先停再改），但 `waitForRenderPathIdle` 是 check-then-act：最后一次轮询与真正写入之间，CoreAudio 仍可能进入回调。代码在 [AudioRenderer.swift:449-457](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L449-L457) 诚实记录了这点，所以审计把它判为 CONDITIONAL 而不是"已修复"。

---

## 9. 生命周期与异常路径

| 事件 | 走向 | 锚点 | 状态 |
| --- | --- | --- | --- |
| 设备增删 | `handleDeviceListChanged` → `SyncDevices` → `AddDevice`/`RemoveDevice` → `Retire` | [DeviceMonitor.swift:302](../packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift#L302)、[Plugin.cpp:1541](../packages/driver/src/Plugin.cpp#L1541) | D3 PASS（drain 超时永不当作完成） |
| 物理设备切换 | `AudioEngine.switchDevice` → 停 → 更新速率 → 改格式 → 起 | [AudioEngine.swift:195-258](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L195-L258) | A3 掉电平 |
| 默认输出变化 | `handleDefaultOutputChanged` | [DeviceMonitor.swift:436](../packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift#L436) | — |
| 睡眠唤醒 | `SleepWakeMonitor` → `lifecycleGate` → 重新注册监听 | [SleepWakeMonitor.swift](../packages/host/Sources/SoundBridgeHost/Devices/SleepWakeMonitor.swift) | — |
| coreaudiod 重建 | `CoreAudioRestartDetector` → `confirmCoreAudioRestart` → `attemptCoreAudioRecovery` | [DeviceMonitor.swift:584](../packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift#L584) | — |
| Host 崩溃 | 驱动保留 mapping 与 claim；新 Host 建新 inode，旧 mapping 被拒收 + 清理 | §5.1 | E4 正常 |
| Host 单实例冲突 | `flock` 失败直接 exit，无副作用 | [HostInstanceLock.swift](../packages/host/Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift) | — |
| 正常退出 | `ShutdownSequence` 12 步有序 teardown | [ShutdownSequence.swift](../packages/host/Sources/SoundBridgeHost/Lifecycle/ShutdownSequence.swift) | 顺序正确 |
| App 请求重连 | Darwin `com.soundbridge.bounce-request` → `reconnectAudioPath` | [main.swift:447-469](../packages/host/Sources/SoundBridgeHost/main.swift#L447-L469) | 不碰默认输出 |
| 卸载 | `DriverUninstaller` + `tools/uninstall_driver.sh` | — | — |

### 9.1 退出顺序为什么是契约

`cleanup()` 的顺序是：`markStopping → stopConnectionMonitor → stopSleepWakeMonitor → removePropertyListeners → stopHeartbeat → stopAudioEngine → removeControlFile → waitForDriverDetach → unlinkSharedMemory → maybeRestartCoreAudio → publishStopped → releaseInstanceLock`。

两层含义：

- `stopAudioEngine` 必须在 `unlinkSharedMemory` **之前**，否则 IO 线程还在跑而底层 mapping 已被撤销
- 释放锁必须在**最后**，否则另一个 Host 可能抢在清理完成前进场

---

## 10. 缺陷落点索引

按"你正在看哪一段代码"来查缺陷。完整证据见[审计报告](release/SoundBridge-Core-Engineering-Audit.md)。

| 缺陷 | 严重度 | 触发阶段 | 代码位置 | 用户可见表现 |
| --- | --- | --- | --- | --- |
| **B3** | 临界 | §4 Step 1 → §7.2 DSP | [biquad.h:186-260](../packages/dsp/src/biquad.h#L186-L260)、[engine.cpp:139-161](../packages/dsp/src/engine.cpp#L139-L161) | 采样率 < 33k 的设备上调 Treble 出爆音/NaN |
| **D1** | 高 | §7.1 每个周期 | [Plugin.cpp:733-850](../packages/driver/src/Plugin.cpp#L733-L850) | 负载下偶发 glitch，难复现 |
| **C2** | 中 | §8.2 EQ | [RFSharedAudio.h:1511-1540](../packages/shared/include/RFSharedAudio.h#L1511-L1540) | 极端时序 EQ 参数撕裂（UB） |
| **A3** | 中 | §8.3 切设备 | [smoothing.h:28-40](../packages/dsp/src/smoothing.h#L28-L40)、[engine.cpp:139-161](../packages/dsp/src/engine.cpp#L139-L161) | 每次切换后 ~70 ms 音量下陷 |
| **D2** | 确认风险 | §7.1 格式分支 | [Plugin.cpp:1215-1290](../packages/driver/src/Plugin.cpp#L1215-L1290) | 整数 planar / 24-in-32 客户端乱码 |
| **D5** | 中（潜伏） | §9 恢复路径 | [Plugin.cpp:1182-1200](../packages/driver/src/Plugin.cpp#L1182-L1200) | 若启用则永久静音（当前无调用者） |
| **B5** | 中 | §7.2 limiter | [limiter.h](../packages/dsp/src/limiter.h) | 大信号只压一侧，成像偏移 |
| **B1/B2** | 低 | §7.2 诊断 | [engine.cpp:123-137](../packages/dsp/src/engine.cpp#L123-L137)、[:178-196](../packages/dsp/src/engine.cpp#L178-L196) | 诊断数值失真（无消费者） |
| **C3** | 低 | §8.1 音量 | [RFSharedAudio.h:1281-1310](../packages/shared/include/RFSharedAudio.h#L1281-L1310) | 极端时序音量状态回退 |
| **C4** | 确认风险 | §5/§6 校验 | [ControlProtocol.hpp:165-175](../packages/driver/src/ControlProtocol.hpp#L165-L175) | 当前无影响，"单一实现"注释不实 |

**已排除的三个假阳性**（不要重复排查）：C1 admission 并发（Host 双重串行化）、C4 越界写（驱动侧已校验容量）、C5 心跳新鲜度（Tracker 实现正确，`rf_is_connection_healthy` 是死代码）。

---

## 11. 建议阅读路线

按这个顺序读，约 40 分钟可以建立完整心智模型：

1. **协议**（20 分钟）— [RFSharedAudio.h](../packages/shared/include/RFSharedAudio.h)：只看结构体、`rf_ring_read/write`、`rf_publish_volume_state`、`rf_store/load_eq_snapshot`。跳过所有注释里历史兼容段落。
2. **时序**（10 分钟）— [main.swift:97-445](../packages/host/Sources/SoundBridgeHost/main.swift#L97-L445)：只追 Step 编号和 guard，不看每个参数细节。
3. **数据面**（10 分钟）— [SharedMemoryManager.createMemory](../packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift#L188-L366) + [AudioRenderer.render](../packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift#L502-L676)。
4. **驱动**（10 分钟）— [Plugin.cpp](../packages/driver/src/Plugin.cpp)：`OnStartIO`(562) → `OnWriteMixedOutput`(733) → `OpenSharedMemory`(1013)。
5. **控制面闭环**（10 分钟）— [AudioEngine.switchDevice](../packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift#L195-L258) 与 [ProxyDeviceManager.commitProxyVolumeState](../packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift#L628)。

读完后建议自测三个问题：

- 为什么"驱动装了但设备列表里没有"通常不是驱动的问题？
- 为什么"设备可见但 `driver_connected=0`"是正常状态？
- 用户调 Treble 时，从 UI 到 DAC 之间经过哪几次跨进程边界？

---

## 附录 A. 关键路径与常量

| 项 | 值 | 来源 |
| --- | --- | --- |
| 驱动安装路径 | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` | [DriverInstaller.swift:12](../apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift#L12) |
| 共享内存 | `/tmp/soundbridge-<ownerUID>-<sanitized_uid>` | [SharedMemoryMappingManager.swift:245](../apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift#L245)、[PathManager.swift](../packages/host/Sources/SoundBridgeHost/Utilities/PathManager.swift) |
| 控制文件 | `/tmp/soundbridge-devices.txt` | [Plugin.cpp:1626](../packages/driver/src/Plugin.cpp#L1626)、[main.swift:269](../packages/host/Sources/SoundBridgeHost/main.swift#L269) |
| 实例锁 | `/tmp/soundbridge-host-<uid>.lock` | [HostInstanceLock.swift](../packages/host/Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift) |
| 生命周期报告 | `device-state.json`（Application Support） | [DeviceRegistry.swift](../packages/host/Sources/SoundBridgeHost/Devices/DeviceRegistry.swift) |
| 重连通知 | `com.soundbridge.bounce-request` | [main.swift:449](../packages/host/Sources/SoundBridgeHost/main.swift#L449) |
| 协议版本 | `0x00020200` | [RFSharedAudio.h:48](../packages/shared/include/RFSharedAudio.h#L48) |
| 头部大小 | 320 字节 + `audio_data[]` | [RFSharedAudio.h](../packages/shared/include/RFSharedAudio.h) |
| ring 容量 | `rf_ring_capacity_frames_for(rate, 100ms)` 向上取 2 的幂 | [RFSharedAudio.h](../packages/shared/include/RFSharedAudio.h) |
| 代理设备格式 | 48 kHz / 2ch / Float32 interleaved | [Plugin.cpp](../packages/driver/src/Plugin.cpp) `CreateProxyDevice` |
| 音量曲线 | `dB = 48·√s − 48` | [VolumeTaper.swift](../packages/host/Sources/SoundBridgeHost/Audio/VolumeTaper.swift) |
| DSP 值域 | gain ±12 dB / freq [20, 20000] / Q [0.1, 10] / preamp ±12 dB / SR [8000, 384000] | [soundbridge_dsp.h](../packages/dsp/include/soundbridge_dsp.h) |

## 附录 B. 术语表

| 术语 | 含义 |
| --- | --- |
| 代理设备（proxy device） | 驱动向 HAL 注册的虚拟输出设备，名字类似 `XXX (SoundBridge)` |
| 物理设备（physical device） | 真实硬件输出，Host 最终把音频写给它 |
| 路由（routing） | proxy → physical 的对应关系，由 Host 解析，不由系统默认输出决定 |
| admission | Host 对 mapping 的"放行"状态，驱动 attach 前必须 OPEN |
| producer claim | 驱动在 ring 上的独占生产令牌，防止两个驱动实例同时写 |
| 代际（generation） | mapping 的身份版本，`mappingToken` 变化即视为新一次"化身" |
| 抑制窗口（suppress） | 驱动写回音量后短时间内忽略自己的变更，避免回声 |
| 静音预填 | 创建 mapping 时先把 ring 填满静音，避免首次播放爆音 |
| lifecycleGate | Host 内部状态机，决定当前是否允许正常音频操作 |
| quarantine | drain 超时的 mapping 被永久保留而不 `munmap`，防止 UAF |
