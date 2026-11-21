# P2 Batch 3 — EQ Mapping Reliability

**版本**：1.2.0
**范围**：`apps/mac/SoundBridgeApp/Sources` + `Sources/Tests`（Host / Driver / DSP / ABI 未修改）
**结论**：**PASS**（1 项测试手段缺口，已在 §20 如实记录，不影响安全不变式）
**性质**：所有结论区分「已通过自动化验证 / 仅完成静态审查 / 需要真实 macOS 验证」，见 §22。

---

## 0. 结论摘要

原始缺陷：App 的 `EQController` 自己 `open` / `mmap` / `munmap` 共享内存，指针一次拿到后永久缓存；Host 重新发布时用 `rename(staging, path)` 换掉 inode，**路径不变**，因此 App 从未察觉，继续向已被替换的旧 inode 写入。用户拖动 EQ 滑块，声音无变化，且没有任何错误可观察。

修复后：

| 不变式 | 证据 |
| --- | --- |
| 不再只凭路径 / 指针非空判断有效 | `fstat(fd)` 的 `st_dev`+`st_ino` + `admission_epoch` + Host session UUID |
| Host = B 时 App 绝不写 A | `attachPath` 一旦发现 inode 变化立即 `retireActive`，`.write` 对 `retired` 映射返回 `.unavailable` |
| 无 use-after-unmap / double munmap | lease 计数 + `retired`/`unmapped` 双标志，`munmap` 仅在 `retired && leases == 0` 且单次置位时发生 |
| 不阻塞 UI、不在锁内做 IO | 所有 `open`/`fstat`/`mmap`/`lstat`/`munmap` 在串行 `attachQueue` 上；`NSLock` 只保护指针簿记 |
| 不依赖 `MenuBarView` | Manager 由 `AppDelegate` 持有并 `start()`，含 2s 结构兜底 |
| 映射不可用不崩溃 | EQ 写入返回 `.unavailable`，状态留在 `@Published` + `UserDefaults`，新映射发布后自动重放 |

新增 36 个测试，App 全量 195 通过（原 159），Host 331 不变，`make test` **EXIT=0**；并发用例在 **Thread Sanitizer** 与 **Address Sanitizer** 下均无报告。

---

## 1. 初始 Git 基线

采集于本批次开始时（`git -C /path/to/SoundBridge`）：

```text
HEAD    ab3677072f0dcb54de27ba4dcabfd11e64ae41ec
VERSION 1.2.0
status  M=50  D=2  ??=35   (暂存区为空, stash 为空)
dist/   SoundBridge-1.1.1.dmg   Nov 17 15:11
        SoundBridge-1.1.1.pkg   Nov 17 00:11
        SoundBridge.app          Nov 16 22:24
```

两个 `D` 是 `docs/INSTALLATION_GUIDE.md`、`docs/RELEASE_NOTES.md`，属于更早批次（Directory Retirement）的既有工作区状态，本批次未触碰。

本批次结束时（§19）同一组数字为 `M=50 D=2 ??=36`——唯一增量是新增的并发测试文件，HEAD / VERSION / dist 未变。

---

## 2. 原始 stale mmap 的完整调用链

### 2.1 App 侧（修复前）

```text
MenuBarView.body
  .onReceive(volumeController.$activeDeviceUID) { uid in      MenuBarView.swift:115
      eqController.attachSharedMemory(for: uid)                EQController.swift:355
  }

EQController.attachSharedMemory(for:)
  └─ detachSharedMemory()            // 先 munmap 旧指针
  └─ open(path, O_RDWR)              // EQController.swift:367
  └─ fstat(fd, &st)                  // 保存 st_size
  └─ mmap(nil, st_size, ...)         // EQController.swift:381   ← 裸指针
  └─ sharedMemory = ptr              // 无身份校验
  └─ flushToSharedMemory()

EQController.setupThrottledPipeline()   // 30 Hz
  └─ writeToSharedMemory(bandGains:preamp:bypass:)
      └─ rf_store_eq_snapshot(sharedMemory, &snapshot)    // 无条件写入
```

`sharedMemory` 与 `shmSize` 是两个普通存储属性，没有世代号、没有 inode、没有 epoch。`mmap` 成功即视为“当前有效”，直到下一次 UID 变化。

### 2.2 Host 侧发布（`packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift`）

```text
createMemory(for uid:, persistence:)                        :121
  ├─ open(stagingPath, O_CREAT|O_EXCL, 0600)                （新 inode）
  ├─ ftruncate(fd, size)
  ├─ mmap(staging)
  ├─ rf_shared_audio_init(...)                              （写 protocol_version / header_size / 格式）
  ├─ rf_set_host_session(sharedMem, uuid)                   :209   （_reserved "SB6A" + 16B UUID）
  ├─ rf_publish_volume_state(...)                           :218
  ├─ rf_admission_open(sharedMem, admissionEpoch)            :257   （随机 epoch）
  ├─ rename(stagingPath, shmPath)                            :265   ← 原子替换，路径不变、inode 变
  └─ SharedMemoryMapping(device: st_dev, inode: st_ino)      :270
```

`shmPath` = `/tmp/soundbridge-<ownerUID>-<sanitized uid>`（`PathManager.sharedMemoryPath:30`），与 App 侧
`SharedMemoryMappingManager.defaultPath`、Driver 侧 `SharedMemoryPath()` 三处字节一致。

### 2.3 修复前为什么会一直写旧 inode

1. attach 只在 `activeDeviceUID` **变化**时触发。Host 重启后设备 UID 不变 → 不触发。
2. 即使触发，`attachSharedMemory` 只按**路径** `open`，而 `rename` 让路径恒定有效。
3. 写入前只检查 `sharedMemory != nil`，而它永远不为 nil。
4. 唯一能暴露问题的是 Host 侧：它读的是**自己新映射**，看到的是 App 从未写过的新文件，EQ 恒为平直。

旧 inode 在 `rename` 之后仍被 App 持有引用（`mmap` 独立于目录项），因此不是“文件不存在”，而是“写进了一个已经没有任何读者/写者的孤立 inode”。这就是本批次的核心缺陷。

### 2.4 Old mapping 是否可能被其他组件引用（§3.3-8）

审计结论：**不会**。全仓库 `mmap(` / `munmap(` 只出现在 App 的 `SharedMemoryMappingManager.swift`（修复前为 `EQController.swift`，已移除，见 §12 源码门禁测试）。`RFSharedAudio` 类型在 App 内的引用也只在该文件。Volume 路径不映射共享内存（`VolumeController` 走 IPC + CoreAudio），因此不存在第二个持有者。Driver 与 Host 各自独立映射，与 App 的旧 inode 无关。

---

## 3. Host 发布与 App attach 的时序图

```text
Host                                    FS                    App (attachQueue)              EQ writer
 |                                       |                        |                              |
 |-- open(staging) --------------------> | inode S                      |                        |
 |-- init / session / volume / admission |                        |                              |
 |-- rename(S -> path) ----------------> | path -> S, inode #S          |                        |
 |-- notify (device-state-changed) ----> |                        |                              |
 |                                       |<-- lstat(path) --------| revalidate()                 |
 |                                       |--- st_dev/st_ino ----->| #S != active(#old)           |
 |                                       |                        | retire(#old) ---> write #old: refused
 |                                       |<-- open/lstat ---------| |
 |                                       |--- fstat ------------->| identity = (#S, epoch, session)
 |                                       |<-- mmap ---------------| |
 |                                       |                        | rf_validate_header  OK
 |                                       |                        | epoch != 0, session marker OK
 |                                       |<-- lstat(path) --------| 仍是 #S ?  否则 .superseded
 |                                       |                        | publish(#S, gen+1) -> mappingPublished
 |                                       |                        |                              |-- flush EQ
 |-- Host 重启 -------------------------> | path -> T, inode #T   |                              |
 |-- notify ----------------------------> |                        | revalidate -> attach(#T)      |
```

关键点：**retire 发生在 validate 之前**。只要路径指向的 inode 与 active 不同，旧映射立即退役；后续 `open` / `mmap` / `validate` 失败也不会把旧映射“恢复”为有效（任务书 §2.2 / §4.4）。

---

## 4. Mapping identity 方案（§3.3-9、§4.2）

`SharedMemoryIdentity`（`SharedMemoryMappingManager.swift:18`）：

| 字段 | 来源 | 证明什么 | 是否现有 ABI |
| --- | --- | --- | --- |
| `device: dev_t` | `fstat(fd)`，即**已 map 的 fd** | 同一路径下是否换了文件系统对象 | 是 |
| `inode: ino_t` | `fstat(fd)` | `rename` 发布出的新 incarnation | 是 |
| `epoch: UInt64` | `rf_admission_epoch(mem)` | Host 每次发布随机生成；Host 重启必不同 | 是（`rf_admission_open`） |
| `hostSession: UUID?` | `_reserved` 前 4 字节 `"SB6A"` + 16 字节 | 独立的第二证据：Host 进程身份 | 是（`rf_set_host_session`） |

对照任务书 7 条要求：

1. **同路径新旧 inode 可区分** —— `st_ino` 直接区分，`testSamePathWithANewInodeIsRecognisedAsANewIncarnation`。
2. **不同 incarnation 可区分** —— 四元组整体比较，`testRestartedHostWithANewSessionAndEpochIsANewIncarnation`。
3. **Host 重启可发现** —— session UUID 与 epoch 双变，同上。
4. **不以路径为唯一身份** —— 路径只用于 `open`，从不参与比较。
5. **不以 mtime 为唯一身份** —— 完全不使用 mtime（`rename` 保留旧 inode 的 mtime，本就不是可靠信号）。
6. **不以映射地址为身份** —— identity 在 `mmap` 之前由 `fstat` 得出；地址只用于租约。
7. **未完成初始化的映射不得成为 active** —— 顺序为 `mmap` → `rf_validate_header` → session marker → `epoch != 0` → `lstat` 复核 → `publish`；任一失败即 `munmap` 丢弃。`testAnUninitialisedFileIsRefused`、`testAMappingWithoutAHostSessionIsNotAnIncarnation`、`testAMappingWithoutAnAdmissionEpochIsNotAnIncarnation`。

**§2.5 结论：现有 ABI 足够，不进入 BLOCKED，未修改任何 header。**

---

## 5. Mapping Manager 设计（§4.1）

新增 `apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift`（564 行），App 侧唯一的共享内存生命周期所有者：

| 职责 | 实现 |
| --- | --- |
| Discover | `revalidate()`：一次 `lstat` 比较 dev/ino；2 s 兜底定时器 |
| Validate | `open` → `fstat` → 大小 → `mmap` → `rf_validate_header` → session marker → epoch ≠ 0 → `lstat` 复核 |
| Attach / Publish | `publish(pointer:size:identity:)`：锁内换 `active`、`generation &+= 1` |
| Retire | `retireActive(reason:)`：置 `retired`，`active = nil`，租约归零后 `munmap` |
| Safely release | `releaseLease` / `publish` / `retireActive` 三处唯一决定点，`unmapped` 单次置位 |
| Safe EQ write | `write(_:)` / `writeEQSnapshot(_:)` 返回 `SharedMemoryWriteResult` |

对外状态：`currentIdentity`、`currentGeneration`、`isAvailable`。

`EQController` 不再持有任何裸映射：删除了 `sharedMemory` / `shmSize` 字段与 `detachSharedMemory()`，`attachSharedMemory(for:)` 变为幂等转发（`mapping?.requestAttach(for:)`），`attachSynchronously` 让测试可以确定性驱动。

`MenuBarView.swift` **未修改**（SHA-256 前后一致）——那句 `eqController.attachSharedMemory(for: uid)` 现在只是“再确认一次”，不再承担生命周期职责。

---

## 6. 并发安全方案（§4.5、§12 C）

必须回答的问题：**一个线程正在写 Mapping 时，另一个线程如何安全地替换并释放它？**

四条同时成立的机制：

1. **单一写者**：`NSLock lock` 独占 `active`、每个映射的 `retired`/`leases`/`unmapped`、`generationCounter`。
2. **attach 串行**：所有 `open`/`fstat`/`mmap`/`validate`/`publish` 在串行 `attachQueue` 上，两个通知不可能并发 publish；`attachSynchronously` 是该队列的同步屏障（测试用它制造并发）。
3. **锁内零 IO**：每个步骤是独立函数调用，锁只在指针簿记期间持有；`open`/`mmap`/`lstat`/`munmap` 全部在锁外。
4. **租约而非 sleep**：写入前在锁内 `leases += 1` 并取出指针，写完后 `releaseLease`；`munmap` 只在 `retired && leases == 0` 时发生，且 `unmapped = true` 让决定单次生效 → **double munmap 结构上不可能**。

```swift
@discardableResult
func write(_ body: (UnsafeMutablePointer<RFSharedAudio>) -> Void) -> SharedMemoryWriteResult {
    lock.lock()
    guard let mapping = active, !mapping.retired else { lock.unlock(); return .unavailable }
    mapping.leases += 1
    let pointer = mapping.pointer
    let generation = mapping.generation
    lock.unlock()
    body(pointer)                 // ← 锁外；替换可以同时发生
    releaseLease(mapping)
    return .written(generation: generation)
}
```

另有 `eqCommitLock` 专门保护 **seqlock**：`rf_store_eq_snapshot` 假定单写者（读 `eq_sequence` → 拷贝 → 存 `seq+2`）。两个并发写入会把序号留在奇数，让 Host 的 `rf_load_eq_snapshot_safe` 放弃并回退到旧快照。锁序恒为 `eqCommitLock → lock`，没有反向获取，因此不与 `publish` / `retireActive` 构成环。

任务书禁止项自检：不创建线程、不轮询、不按写入做文件扫描、不长时间持锁、不阻塞 UI、不在锁内做 IO、不使用固定 sleep 作为释放证明 —— 全部满足；释放证明是**租约计数**，并有测试。

---

## 7. Mapping replacement 流程（§4.3、§4.4）

```text
DISCOVER   lstat(path)            失败(ENOENT)      -> retireActive("file is gone")
OPEN       open(RDWR|CLOEXEC|NOFOLLOW)
                                 失败              -> 保留当前安全状态并返回结果（若路径已指向别的 inode 则先 retire）
IDENTIFY   fstat(fd)              失败              -> .identityUnreadable，不发布
           dev/ino == active?    是                -> .alreadyCurrent（不改世代，不重放 EQ）
           dev/ino != active?    是                -> retireActive("path now points at a different inode")
SIZE       st_size < header       小                -> .fileTooSmall，不发布
MMAP       mmap(PROT_READ|WRITE, MAP_SHARED)
                                 失败              -> .mapFailed，不发布
VALIDATE   rf_validate_header     失败              -> munmap + 丢弃
           session marker 缺失   失败              -> munmap + 丢弃
           epoch == 0            失败              -> munmap + 丢弃
           再次 lstat(path)      dev/ino 已变      -> munmap + .superseded（有界重试 × 3）
PUBLISH    锁内换 active, gen+1, 旧映射 retired
RETIRE_OLD 旧映射 leases == 0 ?   是                -> munmap
                                 否                -> 交给最后一个 releaseLease 的线程 munmap
```

`testAFailedReplacementLeavesTheWriterUnavailableRatherThanStale` 与
`testAFailedReplacementUnderLoadStopsAllFurtherWrites` 固定了「新映射校验失败 ⇒ 旧映射不得继续有效」这一条。

---

## 8. Notification loss 恢复机制（§6.2、§12 E）

三个独立驱动，缺一不可：

1. **Darwin notification**（主路径）：`IPCController` 的 `com.soundbridge.device-state-changed` → `onDeviceStateChanged` / `onDeviceStateUnavailable` → `SharedMemoryMappingManager.shared.revalidate()`。
2. **结构兜底**（2 s 定时器，`installFallbackTimer`）：Host 未启动时 App 已经在运行、或通知丢失时，由定时器发现 inode 变化。
3. **显式请求**：`EQController.attachSharedMemory(for:)`（菜单栏打开时的既有调用）与 `VolumeController.activeDeviceUID` 变化。

**通知只是提示**：`revalidate()` 不信任通知内容，只做一次 `lstat` 并比较 dev/ino；重复通知命中 `.alreadyCurrent`，不换世代（`testRepeatedNotificationsAreIdempotent`、`testTheSameIncarnationIsAdoptedWithoutChurn`）。旧通知不会覆盖新映射，因为 attach 全部串行在 `attachQueue` 上，后到达的请求重新读盘，看到的是最新 inode（`testRapidPublicationsConvergeToTheNewestUnderConcurrentAttaches`）。

「Host 未 publish 就 attach」不会发生：`open` 失败即返回 `.fileMissing`；`.superseded` 重试上限 3 次后交给下一次定时器，不做高速重试，也没有固定 sleep 假设 ready。

---

## 9. Pending EQ 的字段所有权与恢复策略（§5.3、§12 G）

**所有权核查**（全仓库 grep）：

- `rf_store_eq_snapshot` 的唯一调用者是 App 的 EQ 写入路径（现在集中在 `SharedMemoryMappingManager.writeEQSnapshot`）。
- Host 侧只有 `AudioRenderer.swift:148` 的 `rf_load_eq_snapshot`（只读）。
- 因此 **EQ block 的唯一权威写者是 App**。

结论：映射不可用时保留用户最新 EQ，映射恢复后重放，**不会覆盖 Host 维护的字段**。

恢复通道有两个，覆盖两条时间线：

1. `EQController.observeMapping()` 订阅 `mappingPublished` → `flushToSharedMemory()`：Host 重新发布后自动把当前滑块值写入新映射（用户无需再动一下）。
2. `UserDefaults`（既有 `EQDefaultsKey`）：App 重启后 `loadFromUserDefaults()` 恢复，再经第 1 条写入。

映射不可用期间：`writeToSharedMemory` 返回 `.unavailable`，`@Published bass/mids/treble` 与 UserDefaults 保留值，节流管线照常持久化（`testEQSurvivesAnUnavailableMappingAndKeepsThePendingValues`）。重放写的是完整 `RFEQSnapshot`（10 band + preamp + bypass），不动 `volume_*` / `state_revision` / `admission_*` / `_reserved`（`testAnEQWriteLeavesHostOwnedFieldsUntouched` 断言 scalar 0.42、muted 1、mode、epoch、session、sample_rate 全部不变）。

**§5.4 Volume**：App 侧不写 volume 到共享内存（`VolumeController` 走 IPC + CoreAudio），`RFSharedAudio` 在 App 内只由 Manager 引用，因此 Volume 不存在 stale mmap 风险，本批次未触碰 Volume 代码。

---

## 10. 修改文件清单

| # | 文件 | 动作 | 原因 |
| --- | --- | --- | --- |
| 1 | `apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift` | **新增** 564 行 | 统一的 Mapping 生命周期与安全写入 |
| 2 | `apps/mac/SoundBridgeApp/Sources/Services/EQController.swift` | 修改 | 移除裸 `mmap`/`munmap` 生命周期，改走 Manager；新增 `observeMapping()` |
| 3 | `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift` | 修改 | App 级持有 Manager（`start`/`stop`/`deviceUIDProvider`），IPC 回调改为 `revalidate()` |
| 4 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingManagerTests.swift` | **新增** 500 行 | §7.1 / §7.2 |
| 5 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingConcurrencyTests.swift` | **新增** 619 行 | §7.3 / §7.4 / §6.1 源码门禁 |

未修改（SHA-256 前后一致）：`MenuBarView.swift`、`EQUnitTests.swift`、`packages/driver/**`、`packages/dsp/**`、`packages/host/**`、四份 `RFSharedAudio.h`、`VERSION`、`Info.plist`（App/Driver）、`dist/**`。

---

## 11. 修改前后 SHA-256

| 文件 | 修改前 | 修改后 |
| --- | --- | --- |
| `Services/EQController.swift` | `0dc00941fd45323909ab2c54e42656de80f1afaf38015793425b4173ef440b56` | `d6adb0b24a93d187a603a4ad1bab875975ad6828e379fa54a151d3ce128cc50a` |
| `App/SoundBridgeApp.swift` | `38be7706a3d5648cbfd8d56a9030e2b5e860d83b494d7ef3653b9cb9bf29a9af` | `5329b73b80859d41176ed34d30b233d58af4d366e580153a8f2e33d3cd554ec0` |
| `Services/SharedMemoryMappingManager.swift` | —（不存在） | `0a8a2314e461059f879cb24bc4ea26b9455234aa6f0963ab26f9483443a52bbb` |
| `Tests/…/SharedMemoryMappingManagerTests.swift` | — | `1bd1bf3210b6d518d6ac7f24ad30b26c8d960d4c6404dbb0f8009087a6945369` |
| `Tests/…/SharedMemoryMappingConcurrencyTests.swift` | — | `ae52eb8796e37431d9703d9b2923bc080853f9fc06e2c05cf8ed4c8b26b1d71e` |
| `Views/MenuBarView.swift` | `5473e50e88ed5edf430b8f6459b98834e1db93f8a4106f77b3afb8312fff7138` | 同左（未变） |
| `Tests/…/EQUnitTests.swift` | `2e5eadf43484177964ec67e8687c7d389c637a77093218e041f2ed67a4340317` | 同左（未变） |

`git diff --stat`（对 HEAD，含前序批次改动）：`SoundBridgeApp.swift` 182 insertions / 300 deletions 合计口径中本批次贡献 +20 行（IPC 回调 ×2、`deviceUIDProvider` + `start()` 3 行、`applicationWillTerminate` 中 `stop()` 1 行及其注释）；`EQController.swift` 本批次净 −20 行（+60 / −80）。

---

## 12. 新增与修改测试清单

### `SharedMemoryMappingManagerTests`（18，§7.1 / §7.2）

基础设施：`SharedMemoryFixture` 在 `NSTemporaryDirectory()` 下复刻 Host 的真实发布序列（staging `O_CREAT|O_EXCL|O_NOFOLLOW` → `ftruncate` → `mmap` → `rf_shared_audio_init` → `rf_set_host_session` → `rf_admission_open` → `fstat` → `rename`），并**保留每个 incarnation 自己的 mmap**，因此“旧映射是否还收到写入”是读真实内存，而不是读实现自己报的计数器。所有测试通过 `pathForUID` 注入临时路径，绝不触碰 `/tmp/soundbridge-*`。

| 测试 | 覆盖 |
| --- | --- |
| `testFirstAttachSucceedsAndPublishesTheFileIdentity` | §7.1-1 |
| `testMissingFileIsReportedAndLeavesTheWriterUnavailable` | §7.1-2 |
| `testOpenFailureIsReported`（目录 → `EISDIR`） | §7.1-3 |
| `testAFileSmallerThanTheHeaderIsRefused` | 尺寸门禁（§7.1-4 的邻近风险） |
| `testAnUninitialisedFileIsRefused` | §7.1-5 |
| `testAMappingWithoutAHostSessionIsNotAnIncarnation` | identity |
| `testAMappingWithoutAnAdmissionEpochIsNotAnIncarnation` | §7.1-6 |
| `testSamePathWithANewInodeIsRecognisedAsANewIncarnation` | §7.1-7 |
| `testTheSameIncarnationIsAdoptedWithoutChurn` | §7.3 重复通知 |
| `testRapidSuccessivePublicationsConvergeOnTheNewest` | §7.3 快速连续发布 |
| `testAFailedReplacementLeavesTheWriterUnavailableRatherThanStale` | §7.1-9、§4.4 |
| `testTheWriterRecoversOnceAValidMappingIsPublished` | §7.1-10 |
| `testDisappearingFileRetiresTheActiveMapping` | §7.3 retirement |
| `testRevalidateAttachesAMappingThatAppearedAfterTheAppStarted` | §7.1-11、§7.1-12 |
| `testRestartedHostWithANewSessionAndEpochIsANewIncarnation` | §7.1-13 |
| `testRetiredMappingStopsReceivingWrites` | §7.2-1…-8 |
| `testAnInFlightWriteKeepsTheOldMappingAliveUntilItFinishes` | §4.5 lease |
| `testTheNewMappingIsTheOnlyOneWrittenAfterRetirement` | §7.2-7 / -8 |

### `SharedMemoryMappingConcurrencyTests`（9，§7.3）

| 测试 | 覆盖 |
| --- | --- |
| `testConcurrentWritersAndReplacementsNeverFaultOrStrandAWriter` | 6 写者 × 150 次 vs 10 次替换 |
| `testInFlightWriterSurvivesRepeatedReplacements` | 200 次体内读内存 vs 15 次替换；`bodiesRun == writesReported` |
| `testRetirementDuringConcurrentWritesLeavesTheWriterUnavailable` | 文件消失 + revalidate 期间 5 写者 |
| `testAFailedReplacementUnderLoadStopsAllFurtherWrites` | 半初始化 inode + 4 写者 |
| `testConcurrentAttachRequestsForTheSameIncarnationPublishOnce` | 12 并发 attach → 1 次发布 |
| `testRepeatedNotificationsAreIdempotent` | 100 次 `requestAttach` + `revalidate` |
| `testRapidPublicationsConvergeToTheNewestUnderConcurrentAttaches` | 8 次发布 + 12 并发 attach → gen == 2 |
| `testHostRestartUnderLoadMovesEQAgressivelyToTheNewSession` | Host 重启（新 session + epoch）× 并发 EQ |
| `testTheWriterPathTakesNoFileSystemOrAttachWork` | 2 000 次写入 < 10 s，写入路径无 IO |

### `EQControllerMappingRecoveryTests`（5，§7.4）

| 测试 | 覆盖 |
| --- | --- |
| `testEQSurvivesAnUnavailableMappingAndKeepsThePendingValues` | 不可用不崩溃 + 节流管线持久化 pending |
| `testPendingEQLandsInTheMappingThatAppearsLater` | pending 写入首次出现的映射 |
| `testEQIsReappliedAfterTheHostRepublishes` | 新 incarnation 自动重放；旧 inode 不再收到写入 |
| `testAnEQWriteLeavesHostOwnedFieldsUntouched` | volume / epoch / session / sample_rate 不被覆盖 |
| `testEQRecoversAfterTheMappingDisappearsAndReturns` | 消失 → 改 EQ → 返回 → 自动恢复 |

### `SharedMemoryMappingOwnershipSourceTests`（4，§6.1 / §12 H）

| 测试 | 断言 |
| --- | --- |
| `testOnlyTheMappingManagerMapsSharedMemory` | App `Sources/` 内 `mmap(`/`munmap(` 只出现在 `SharedMemoryMappingManager.swift` |
| `testEQControllerHoldsNoMappingLifetime` | `EQController.swift` 无 `mmap(` / `munmap(` / `UnsafeMutablePointer<RFSharedAudio>` / `shmSize` |
| `testTheMappingIsOwnedByTheApplicationNotByAView` | `AppDelegate` 有 `start()` / `stop()` / `deviceUIDProvider`；`Views/` 下无映射 API |
| `testNotificationsReReadTheIdentityInsteadOfBeingTrusted` | `SoundBridgeApp.swift` 含 `revalidate()` |

### 修改的既有测试

无。未删除、未跳过、未放宽任何既有断言。

---

## 13. 定向测试结果

```text
swift test --filter "SharedMemoryMappingManagerTests|SharedMemoryMappingConcurrencyTests|\
EQControllerMappingRecoveryTests|SharedMemoryMappingOwnershipSourceTests"

run 1  Executed 36 tests, with 0 failures
run 2  Executed 36 tests, with 0 failures
run 3  Executed 36 tests, with 0 failures
```

连续三次全绿（并发用例存在调度随机性，故重复三次）。单次耗时 0.14–0.21 s。

---

## 14. `make test-app` 结果

```text
Executed 195 tests, with 0 failures (0 unexpected)
```

修复前 159，新增 36，**无既有用例被删除或跳过**。

---

## 15. `make test-host` 结果

```text
Executed 331 tests, with 0 failures (0 unexpected)
```

与 P2 Batch 2 结束时一致（331）。本批次未修改 Host 任何源码或测试。

---

## 16. `make test` 结果

```text
make test  →  EXIT=0
✓ All test suites passed
PASS: 58 checks, 0 failures   (test-codesign)
```

包含 `protocol-check`（`sync_shared_header.sh --check` + `check_protocol_layout.sh`）与 `version-check`，
以及 DSP 51 / Host 331 / App 195 与各脚本套件，全部通过。

---

## 17. TSan / ASan 结果

**Thread Sanitizer**（§7.3 要求）：

```text
cd apps/mac/SoundBridgeApp
swift test --sanitize=thread \
  --filter "SharedMemoryMappingConcurrencyTests|EQControllerMappingRecoveryTests"

Executed 14 tests, with 0 failures
（无任何 ThreadSanitizer 报告）
```

覆盖 9 个并发用例 + 5 个恢复用例，`Build complete! (6.47s)`，运行 0.17 s。

**Address Sanitizer**：

```text
swift test --sanitize=address --filter "SharedMemoryMappingConcurrencyTests"
Executed 9 tests, with 0 failures
（无 AddressSanitizer 报告）
```

限制说明（如实记录，不伪造）：ASan 不检测“对已 `munmap` 区域写入”（那是 SIGSEGV/SIGBUS，`testInFlightWriterSurvivesRepeatedReplacements` 以崩溃作为检测器）；TSan 不理解 `mmap` 生命周期语义。因此两者都只是**附加**证据，主证据是租约 + `retired`/`unmapped` 标志的确定性测试。

---

## 18. ABI / Protocol / Version 检查

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| Shared Memory Header 未改 | 通过 | 4 份 `RFSharedAudio.h` mtime 均为 `2026-11-20 12:27/12:41`（本批次 17:30 之后无改动）；`find -newermt "2026-11-20 17:30"` 无 header |
| Protocol 定义未改 | 通过 | `make test` 的 `protocol-check` 通过（3 份副本一致 + layout 断言） |
| `RF_AUDIO_PROTOCOL_VERSION` 未变 | 通过 | 同上 |
| ABI 无兼容层 | 通过 | 未新增任何 header 字段；identity 全部读现有 ABI（`st_dev`/`st_ino`/`admission_epoch`/`_reserved`） |
| `VERSION` | 1.2.0（未变） | `cat VERSION` |
| `Info.plist`（App/Driver） | 未变 | mtime `2026-11-17 21:07`；不在 17:30 之后的改动清单中 |
| Bundle Version / Build Number | 未改 | 同上 |
| Deployment Target | 未改 | `Package.swift` 未修改（`.macOS(.v13)`） |
| 签名策略 | 未改 | 未触碰 `tools/codesign.sh`、entitlements、`build_release.sh` |

---

## 19. Git 工作区保护情况

```text
HEAD    ab3677072f0dcb54de27ba4dcabfd11e64ae41ec   (未变)
VERSION 1.2.0                                       (未变)
staged  0 行
stash   0 条
status  M=50  D=2  ??=36
dist/   未变化 (Nov 16–17)
```

- 仅 5 个源文件/测试文件在 17:30 之后被修改（§21 的 `find` 输出），第 6 项是上一批次交付的 Batch-2 报告。
- 两个 `D`（`docs/INSTALLATION_GUIDE.md`、`docs/RELEASE_NOTES.md`）是既有工作区状态，未被恢复、未被提交。
- 未执行任何 `git add` / `commit` / `reset` / `clean` / `checkout` / `restore` / `stash`。
- 未执行 `make clean`；未修改 `dist/`；未删除历史文件。
- 未执行 `sudo`、HAL Driver 装卸/注册、`coreaudiod` 重启、系统文件修改、真实 Shared Memory 路径读写、真实 EQ 设备测试、真实 HDMI/DP 拔插、Gate 0、EXP-1、`preflight.sh`。
- 未修改 ABI/Protocol/Header/VERSION/Bundle Version/Build Number/PKG version/Deployment Target/签名策略，未重建架构，未加旧协议兼容层，未开始 P3。

---

## 20. 未解决问题

1. **`mmap` 失败分支缺少确定性测试**（§7.1-4）。`mmap` 失败需要 `ENOMEM`/`EAGAIN` 等环境条件，无法在测试中稳定制造，且不引入测试专用开关污染生产代码。现状：`.mapFailed(errno)` 分支**仅完成静态审查**；“文件过小不可映射”这一邻近风险由 `testAFileSmallerThanTheHeaderIsRefused` 覆盖（`fileTooSmall`）。不影响任何安全不变式。
2. **Host 重启是模拟的**。测试用 fixture 的新 inode + 新 session + 新 epoch 复刻 Host 重新发布，而不是真的拉起/杀掉 Host 进程。真实进程重启的时序（含 `IPCController` 的 Darwin 通知到达顺序）属于 §21 的 P3 验证项。
3. **`SharedMemoryFixture` 与生产代码是两套实现**。fixture 按 Host 的序列手写，若 Host 侧发布流程变化（例如不再用 `rename`），fixture 不会自动失效。缓解：`testOnlyTheMappingManagerMapsSharedMemory` 之外，Host 侧 331 个测试固定了 `createMemory` 的发布契约。
4. **`generation` 只增不减**，长时间运行（反复 Host 重启）后会 `&+=` 回绕。回绕后世代号可能重复，但 `SharedMemoryIdentity` 才是判定依据，世代号只用于日志与 EQ 重放触发，因此是外观问题，不是正确性问题。
5. **EQ 重放会覆盖同一 incarnation 上的并发人工写入**：`observeMapping()` 在 `mappingPublished` 时用 App 当前滑块值覆盖整个 EQ block。由于 App 是 EQ 唯一写者且滑块值即权威值，这是期望行为；但如果未来出现第二个写者（例如外部 EQ 控制器），需要重新审视所有权。
6. **`revalidate()` 每 2 s 一次 `lstat`** 是常量开销，不是按写入放大。若未来出现大量设备切换，可考虑把间隔按 `isAvailable` 状态自适应，属优化项而非缺陷。

---

## 21. P3 真实系统验证建议

以下均**未执行**（本批次禁止真实 HAL / 真实共享内存操作），建议在 P3 由人工在真实 macOS 上完成：

1. 启动 Host → 打开 EQ 面板 → 拖动 bass/mids/treble，确认听感变化（基线）。
2. 强制退出 Host（`kill -9`）后让 App 自动重启 Host，**不再触碰 EQ 滑块**，确认 EQ 仍然生效（这是原缺陷的直接复现路径）。
3. 在 EQ 面板保持打开的情况下重启 Host，确认无需重开面板即恢复。
4. Host 重启期间把滑块拉到极值，恢复后确认极值被应用（pending 重放）。
5. 拔插 HDMI/DP（真实设备），确认 Proxy 设备重建后 EQ 仍生效。
6. 用 `lsof -p <App pid> | grep soundbridge` 观察 App 持有的共享内存 inode 是否跟随 Host 的 `rename`（应为新 inode，且旧 inode 不再出现在 App 的映射列表）。
7. 用 `fs_usage -w -f filesys <App pid>` 观察稳态下 App 是否只在 2 s 节拍附近 `lstat` 共享内存路径，而不在每次 EQ 写入时扫描文件系统。
8. 在 Activity Monitor / Instruments 里确认拖动滑块时主线程无卡顿（`attachQueue` 上的 `open`/`mmap` 不得落到主线程）。
9. Host 崩溃后不重启（保持 App 运行），确认 EQ 面板可用、不崩溃、值可保存，App 不出现 CPU 空转（无高速 retry）。
10. 长稳测试：连续 30 分钟反复重启 Host 与切换设备，确认 `generation` 递增、无内存增长（每次替换后旧映射被 `munmap`）。

---

## 附录 A — §12 A–H 逐项回答

**A. Mapping Identity**：`st_dev` + `st_ino`（来自 `fstat(fd)`）+ `admission_epoch` + Host session UUID。路径、mtime、映射地址都不是身份。证据：§4 表 + 6 个 identity 测试。

**B. Mapping Replacement 如何阻止新写入进旧 Mapping**：`attachPath` 在 `fstat` 发现 inode 不同的**瞬间**就 `retireActive`（早于 validate）；`write()` 对 `retired` 映射直接 `.unavailable`。证据：`testAFailedReplacementLeavesTheWriterUnavailableRatherThanStale`、`testRetiredMappingStopsReceivingWrites`。

**C. In-flight Writer 何时允许 munmap**：仅当 `retired && leases == 0`，且 `unmapped` 单次置位。in-flight 写者持有租约，最后一个 `releaseLease` 或 `publish`/`retireActive` 自己完成 `munmap`。证据：`testAnInFlightWriteKeepsTheOldMappingAliveUntilItFinishes`、`testInFlightWriterSurvivesRepeatedReplacements`（TSan + ASan 下亦无报告）。

**D. A/B/C 连续发布时，旧异步 attach 结果如何不覆盖最新**：所有 attach 在串行 `attachQueue` 上，任一时刻只有一个 attach 持有一个 staging；publish 前再用 `lstat` 复核路径仍指向本次打开的 inode，否则 `.superseded`（有界重试 3 次）。证据：`testConcurrentAttachRequestsForTheSameIncarnationPublishOnce`、`testRapidPublicationsConvergeToTheNewestUnderConcurrentAttaches`（8 次发布 + 12 并发 attach → 恰好 gen 2，指向最后一个 inode）。

**E. Notification Loss**：2 s 结构兜底重新 `lstat` 比较 dev/ino，不依赖通知到达。证据：`testRevalidateAttachesAMappingThatAppearedAfterTheAppStarted`、`testDisappearingFileRetiresTheActiveMapping`；生产接见 §8。

**F. Host Crash 时 staging / active 的处理**：Host 在 `ftruncate` 与 `rf_shared_audio_init` 之间死亡会留下长度合法但内容为零的 staging 文件；若它已经 `rename`，App 会看到 `invalidHeader` 并（因为 inode 已变）先退役旧映射，随后保持 unavailable 直到 Host 再次发布。证据：`testAnUninitialisedFileIsRefused`、`testAFailedReplacementUnderLoadStopsAllFurtherWrites`。staging 文件的清理属于 Host 既有职责（`createMemory` 的 `O_EXCL` staging 路径），本批次未改动。

**G. Pending EQ 存放 / 恢复 / 不覆盖 Host**：存放于 `@Published` + UserDefaults；恢复由 `mappingPublished` 订阅与 App 启动加载两条通道；只写 `RFEQSnapshot`，不触碰 volume/admission/reserved。证据：§9 + `testEQIsReappliedAfterTheHostRepublishes`、`testAnEQWriteLeavesHostOwnedFieldsUntouched`。

**H. App Lifecycle 是否因 MenuBarView 销毁/重建而意外释放或重复 attach**：不会。Manager 是 `AppDelegate` 持有的 `shared` 单例，`start()` 在 `applicationDidFinishLaunching` 中调用，`stop()` 在 `applicationWillTerminate` 中调用；`MenuBarView` 的调用只是幂等的 `requestAttach`，重复调用命中 `.alreadyCurrent`，不换世代、不重放 EQ、不释放任何东西。证据：`testTheMappingIsOwnedByTheApplicationNotByAView`、`testTheSameIncarnationIsAdoptedWithoutChurn`、`testRepeatedNotificationsAreIdempotent`。

---

## 附录 B — §14 二十一项完成条件核对

| # | 条件 | 结果 | 依据 |
| --- | --- | --- | --- |
| 1 | App 不再长期向旧 Mapping 写入 | ✅ | §2/§7；`testRetiredMappingStopsReceivingWrites` |
| 2 | Mapping identity 验证可靠 | ✅ | §4；6 个 identity 测试 |
| 3 | 新 Mapping 发布后能及时发现 | ✅ | §8；`testSamePathWithANewInodeIsRecognisedAsANewIncarnation` |
| 4 | Replacement 无 use-after-unmap | ✅ | 租约；`testAnInFlightWriteKeepsTheOldMappingAliveUntilItFinishes` |
| 5 | 无 double munmap | ✅ | `unmapped` 单次置位；`testInFlightWriterSurvivesRepeatedReplacements` |
| 6 | 并发 EQ 写入与 retirement 安全 | ✅ | TSan 14/14；`testRetirementDuringConcurrentWritesLeavesTheWriterUnavailable` |
| 7 | Unavailable 时安全失败或暂存 | ✅ | §9；`testEQSurvivesAnUnavailableMappingAndKeepsThePendingValues` |
| 8 | 恢复后 EQ 恢复工作 | ✅ | §9；`testEQRecoversAfterTheMappingDisappearsAndReturns` |
| 9 | Pending 恢复符合字段所有权 | ✅ | §9；`testAnEQWriteLeavesHostOwnedFieldsUntouched` |
| 10 | 不依赖 MenuBarView 生命周期 | ✅ | 源码门禁 4 项 |
| 11 | 通知丢失不会永久使用旧 Mapping | ✅ | §8；revalidate 测试 |
| 12 | Host 重启场景通过自动化测试 | ✅（模拟） | `testRestartedHostWithANewSessionAndEpochIsANewIncarnation`、`testHostRestartUnderLoadMovesEQAgressivelyToTheNewSession`；真实进程重启见 §21-2 |
| 13 | App 全量测试通过 | ✅ | 195/195 |
| 14 | Host 全量测试通过 | ✅ | 331/331 |
| 15 | `make test` EXIT=0 | ✅ | §16 |
| 16 | ABI / Protocol / Header 未修改 | ✅ | §18 |
| 17 | VERSION / Bundle Version / Build Number 未修改 | ✅ | §18 |
| 18 | 没有真实 HAL 操作 | ✅ | §19 |
| 19 | 没有 Git 写操作 | ✅ | §19 |
| 20 | 历史工作区修改得到保留 | ✅ | M=50 / D=2 与基线一致 |
| 21 | 报告完整 | ✅ | 本文件（21 项 + 附录 A/B） |

**判定：PASS。** 第 12 项以“模拟 Host 重启”满足，真实进程重启列入 §21；第 7.1-4 项（`mmap` 失败）为静态审查，已在 §20-1 明确记录。二者都不削弱 §2.1–§2.5 的任何不变式。

---

## 附录 C — 证据分级

**已通过自动化验证**：identity 四种字段的接受/拒绝、inode 替换识别、退役后不再写入、in-flight 租约、并发替换/退役/重启/重复通知、pending EQ 重放、Host 字段不被覆盖、源码门禁、TSan、ASan、App 195、Host 331、`make test` EXIT=0。

**仅完成静态审查**：`mmap` 失败分支（§20-1）；Host 进程真实重启时序；Driver 侧对同一 inode 的映射行为；`rename` 在两方并发下的文件系统语义（POSIX 保证原子，未在真实系统上以探针复现）。

**需要真实 macOS 验证**：§21 的 10 项，全部涉及真实 HAL、真实 `/tmp/soundbridge-*` 文件、真实音频听感或真实设备拔插。**本批次的全部 mmap 证据都来自临时目录中的 fixture 文件，不是真实 HAL Mapping 验证。**
