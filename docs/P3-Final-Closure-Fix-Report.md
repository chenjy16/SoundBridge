# P3 Final Closure Fix — App-owned EQ Lifecycle + Host Recovery

**批次：** SoundBridge 1.2.0 — P3 Final Closure Fix
**目标：** 修复 App 启动时 EQ 写入者尚未创建（Gate 3 Defect A），并补齐 App 管理 Host 生命周期与 Host-only restart 能力（Gate 3 Defect B）
**范围：** 仅 App / Host 生命周期代码与测试。未重建安装包、未安装、未执行任何真实系统音频操作。
**日期：** 2026-11-21
**仓库：** `/path/to/SoundBridge`

**最终状态：`PASS — FINAL CLOSURE CODE & TESTS COMPLETE`**

---

## 0. 结论摘要

| 缺陷 | 根因 | 修复 | 验证 |
|---|---|---|---|
| Gate 3 Defect A：`eq_sequence = 0`（未打开 Popover） | `EQController` 是 `MenuBarView` 的 `@StateObject`，popover 首次渲染时才创建写入者 | 新增 App 级 `EQService.shared`，在 `AppDelegate` 属性初始化阶段创建唯一 writer；`MenuBarView` 改为 `@ObservedObject` 只读展示 | 真实 shared memory 文件离线复现：`eq_sequence == 2`、`bypass == true`、bands 与持久化值逐位一致，全程不构造任何 View |
| Gate 3 Defect B：Host 退出即 App 退出 | `hostProcess.terminationHandler` 在非卸载路径直接 `NSApp.terminate(nil)` | 新增 `HostSupervisor` 单飞监督器：区分三种退出意图、Host-only restart、有界重试与 degraded | 16 个 supervisor 用例（真实 `Process` + 真实 SIGTERM + 真实 exit status），TSan/ASan 通过 |

回归规模：App 244 tests / Host 379 tests / `make test` EXIT=0。版本、ABI、Protocol、plist、Driver 生产代码零差异。

---

## 1. 现场基线与根因

### 1.1 基线核验（本批次开始前重新采集，不沿用历史报告）

```
$ git -C /path/to/SoundBridge rev-parse HEAD
ab3677072f0dcb54de27ba4dcabfd11e64ae41ec

$ git rev-parse --abbrev-ref HEAD
main

$ cat VERSION
1.2.0

$ git status --porcelain | wc -l
120          # 既有工作区改动（P2/P3 前序批次），staged = 0

$ git diff --cached --name-only | wc -l
0
```

真实机器故障证据（上一批次报告，本轮作为输入而非结论）：

- App 启动 4 分钟以上：`eq_sequence = 0`、`eq_bypass = 0`、`eq_bands` 全零。
- 打开 MenuBar Popover 后：`eq_sequence = 2`，bands 与持久化参数一致，`eq_bypass = 1`。

因此缺陷位于**所有权与生命周期**，不在 EQ 数学或 shared memory 写入算法。

### 1.2 根因 A：EQ 写入者的创建时机被绑在 View 上

审计结论（A1 五个问题）：

| 问题 | 答案 |
|---|---|
| 1. EQController 在哪里创建？ | 修复前：`MenuBarView.swift:23` `@StateObject private var eqController = EQController(deviceUID: "default")`。全仓唯一构造点，位于视图内。 |
| 2. 为什么 App 启动时没有写入者？ | `MenuBarView` 只在 `popover.contentViewController` 赋值后被 SwiftUI 实例化，而 popover 内容在首次展示时才求值。不点菜单栏 = 不渲染 = `@StateObject` 惰性初始化永不发生 = 没有 `mappingPublished` 订阅者。 |
| 3. SharedMemoryMappingManager 是否已在启动阶段创建？ | 是。P2 Batch 3 起它就是 App 级单例，`applicationDidFinishLaunching` 第 84 行 `SharedMemoryMappingManager.shared.start()`。写者半边缺失，观察者半边早已就位——这是缺陷的核心不对称。 |
| 4. AppDelegate 是否适合持有 EQController？ | 是。`@main class AppDelegate: NSObject, NSApplicationDelegate` 的生命周期严格覆盖进程生命周期，早于 `mapping.start()`，晚于 `terminateHostAndProxies`（现为 supervisor shutdown）。属性初始化发生在 `applicationDidFinishLaunching` 之前，天然早于第一次 `mappingPublished`。 |
| 5. SwiftUI / AppKit 如何安全共享同一实例？ | `AppDelegate` 构造 `MenuBarView(eqController: eqService.controller)`，视图侧用 `@ObservedObject`。`EQController` 是 `ObservableObject`，AppKit 侧无需订阅——`AppDelegate` 只负责创建与传递，不直接读 EQ 值。 |

### 1.3 根因 B：三种退出被折叠成一个 `terminationHandler`

修复前 `SoundBridgeApp.swift:709-718`：

```swift
hostProcess?.terminationHandler = { [weak self] _ in
    DispatchQueue.main.async {
        guard let self else { return }
        if !self.isUninstalling {
            NSApp.terminate(nil)      // 任何 Host 退出 = App 退出
        }
    }
}
```

后果：

1. Host 崩溃 → App 一并退出，用户看到的是"整个 App 消失"，没有任何可观察、可恢复的中间态。
2. 不存在 Host-only restart：要重启 Host 只能重启 App。
3. `isUninstalling` 是一个布尔标志承担了三种语义（用户退出 / 卸载 / 意外退出），无法表达"预期终止"，因此清理路径与恢复路径无法区分。
4. `hostProcess` 由 `AppDelegate` 直接持有，启动逻辑内联 130 行（路径搜索、架构判断、`Process.run()`、sleep 轮询），没有状态机，也没有单飞保护。

---

## 2. 修改文件与修改原因

本批次共触碰 6 个文件（2 改 + 4 新增），全部位于 App target 内。

| 文件 | 类型 | 行数 | 原因 |
|---|---|---|---|
| `Sources/Services/EQService.swift` | 新增 | 46 | App 级唯一 EQ writer 的持有者。`static let shared`，`AppDelegate` 属性初始化即触发。刻意做薄：只决定 controller *何时存在*，EQ 值、band 映射、持久化、lease 安全写入仍全在 `EQController`。 |
| `Sources/Services/HostSupervisor.swift` | 新增 | 650 | Host 进程所有权的唯一持有者。串行队列 + 状态机 + 代际 token + watchdog + 有界重试/退避 + SIGTERM→SIGKILL 升级 + shutdown 等待者。同时把原 `AppDelegate` 的可执行文件搜索与架构判断迁入 `HostExecutableLocator`。 |
| `Sources/App/SoundBridgeApp.swift` | 修改 | 相对 HEAD：+241 / −392（含前序批次在同一文件上的改动） | 删除 `hostProcess`、`terminateHostAndProxies`、`waitForProcessExit`、`waitForPIDExit`、130 行内联启动逻辑、`getArchitecture()`；接入 `eqService` 与 `hostSupervisor`；新增 `restartHost()`、`prepareForUninstall()`、`hostSupervisorDidChange(to:)`、`presentHostMissingAlertOnce()`。 |
| `Sources/Views/MenuBarView.swift` | 修改 | 相对 HEAD：53 行 diff | `@StateObject` → `@ObservedObject` + 显式 `init(eqController:)`；卸载路径改调 `appDelegate.prepareForUninstall()`（不直接写标志位）。 |
| `Tests/SoundBridgeAppTests/EQLifecycleOwnershipTests.swift` | 新增 | 464 | 9 个运行时用例（真实 mapping 文件）+ 8 个源码边界用例。含 Gate 3 场景端到端复现。 |
| `Tests/SoundBridgeAppTests/HostSupervisorTests.swift` | 新增 | 487 | 16 个 supervisor 用例，注入 `/bin/sleep`、`/bin/sh -c "exit N"` 作为 Host 替身。 |

**未修改（保护边界）：** `packages/driver/**`、`packages/shared/include/RFSharedAudio.h`、`packages/dsp/**`、`VERSION`、`apps/mac/SoundBridgeApp/Info.plist`、两个 `Package.swift`、`tools/**` 中任何脚本、`dist/**`。证据见 §7。

### 2.1 关键代码

`SoundBridgeApp.swift`：

```swift
// 22 行：属性初始化即创建 writer，早于 applicationDidFinishLaunching
private let eqService = EQService.shared
// 28 行：Host 唯一所有权
private let hostSupervisor = HostSupervisor()
private var didPresentHostMissingAlert = false

// 60 行：状态变化回主线程通知 UI
hostSupervisor.onStateChange = { [weak self] state in
    self?.hostSupervisorDidChange(to: state)
}

// 274 行：degraded 不再映射成 notRunning
case .notRunning:
    state = hostSupervisor.isDegraded ? .degraded : .notRunning

// 440 行：把 App 的 writer 交给视图，而不是让视图自己造
popover?.contentViewController = NSHostingController(
    rootView: MenuBarView(eqController: eqService.controller)
)

// 506 行：用户退出 App —— 终局意图，永不重启
hostSupervisor.shutdown(intent: .appTermination,
                        waitTimeout: hostTerminationTimeout + 0.5) { ... }

// 610-629 行：三个对外入口，全部是转发，没有内联进程逻辑
func startHost()            { hostSupervisor.start() }
func restartHost()          { hostSupervisor.restart() }        // Host-only
func prepareForUninstall()  { isUninstalling = true
                              hostSupervisor.shutdown(intent: .uninstall,
                                                      waitTimeout: hostTerminationTimeout + 0.5) }
```

`MenuBarView.swift`：

```swift
@ObservedObject private var eqController: EQController
@StateObject private var volumeController = VolumeController.shared
...
init(eqController: EQController) { self.eqController = eqController }
```

---

## 3. App-owned EQ 生命周期

### 3.1 所有权图

```
┌───────────────────────────────────────────────────────────────────────────┐
│ process lifetime                                                          │
│                                                                           │
│  AppDelegate 属性初始化                                                    │
│    └─ EQService.shared                                                    │
│         ├─ static let shared  ← 全进程唯一                                  │
│         └─ let controller: EQController(deviceUID: "default",             │
│                                         mapping: .shared)                 │
│              ├─ 读 UserDefaults → desired EQ（bass / mids / treble / on） │
│              ├─ observeMapping()                                          │
│              │    ├─ mappingPublished    ─┐                               │
│              │    ├─ mappingUnavailable  ─┤  → applyIfNeeded(generation:) │
│              │    └─ if isAvailable { … } ─┘     （A4：迟创建兜底）        │
│              └─ flushToSharedMemory()                                     │
│                   ├─ manager.writeEQSnapshot(snapshot)                   │
│                   │    └─ lease / identity 校验 → rf_write_eq_snapshot    │
│                   │         └─ eq_sequence += 2（SeqLock）                 │
│                   └─ 成功后才 appliedGeneration = generation              │
│                                                                           │
│  applicationDidFinishLaunching                                            │
│    ├─ SharedMemoryMappingManager.shared.start()   ← 观察者先就位            │
│    ├─ hostSupervisor.onStateChange = …                                    │
│    └─ setupMenuBar()                                                      │
│         └─ MenuBarView(eqController: eqService.controller)                │
│              └─ @ObservedObject  ← 只读展示，永不构造 writer               │
│                                                                           │
│  applicationWillTerminate                                                 │
│    └─ hostSupervisor.shutdown(intent: .appTermination)                    │
└───────────────────────────────────────────────────────────────────────────┘
```

创建顺序由测试固化为不变量（`testTheAppDelegateCreatesTheWriterBeforeStartingTheMapping`）：`EQService.shared` 的字节偏移必须小于 `SharedMemoryMappingManager.shared.start()`。

### 3.2 desired EQ 与 applied EQ 的严格分离

| 概念 | 载体 | 更新时机 |
|---|---|---|
| desired EQ | `bass` / `mids` / `treble` / `isEnabled` + `UserDefaults` | 用户操作或构造时加载 |
| applied EQ | `appliedGeneration` / `lastAppliedGeneration` / `isAppliedToCurrentMapping` | **仅**在 `writeEQSnapshot` 返回成功之后 |

三条规则：

1. `applyIfNeeded` 第一行 `guard generation > 0, generation != appliedGeneration`——同一 incarnation 不做无意义重写（对应测试 6）。
2. `mappingUnavailable` 分支立即把 `lastAppliedGeneration` 置 nil——retire 之后不许残留"已应用"声明（对应测试 9）。
3. 写入失败只返回 `.unavailable` / `.rejected`，绝不推进 `appliedGeneration`（对应测试 10）。

### 3.3 A4：迟创建与相同 inode

`SharedMemoryMappingManager.attachWork` 的 `.alreadyCurrent` 分支**刻意不**重发 `mappingPublished`：同一 identity 重复 attach 不是新事件，重发会让所有订阅者误以为出现了新 mapping。

因此"迟创建的写者"不能依赖事件，必须能查询当前快照。`EQController.observeMapping()` 末尾就是这条查询：

```swift
// 订阅之后立即对齐当前状态：如果 mapping 已存在，补发一次
if mapping.isAvailable {
    applyIfNeeded(generation: mapping.currentGeneration)
}
```

这带来的语义是：**订阅是一次性的，状态查询是幂等的**。既没有 replay 缓存，也没有不受控的 subject；`generation` 单调递增，天然去重。

验证：`testAWriterCreatedAfterThePublicationAppliesImmediately` 在 publish + `.alreadyCurrent` 之后才构造 controller，断言 `isAppliedToCurrentMapping == true` 且 `lastAppliedGeneration == manager.currentGeneration`，同时文件里的 bands 已是持久化值。

---

## 4. Host Supervisor

### 4.1 状态机

```
                start()                     lock acquired
  idle ─────────────────► launching(attempt) ──────────────► running(pid)
   ▲  ◄────── launch failed / exited ──┐                        │
   │                                   │                        │ restart()
   │            backoff, bounded retries│                        ▼
   │                                   │                    stopping(.restart)
   │                                   │                        │ exited
   │                                   └────────────────────────┘
   │                                            (relaunch)
   ├──────────── exited with no restart ───────────────────────┘
   │
 degraded(failure, attempts)   ← maxConsecutiveFailures reached
 notOwned                      ← another process holds the instance lock
```

| 状态 | 含义 | 出口 |
|---|---|---|
| `idle` | 未启动或最后一个 Host 已消失 | `start()` |
| `launching(attempt:)` | `run()` 已调用，等实例锁 | 拿到锁 → `running`；超时/退出 → 退避后重试或 `degraded` |
| `running(pid:)` | 拥有一个已取锁的 Host | `restart()` → `stopping(.restart)`；意外退出 → 恢复或 `degraded` |
| `stopping(intent)` | 已发 SIGTERM，等退出 | `restart` → 重新 launch；`appTermination`/`uninstall` → `idle`（终局） |
| `degraded(failure:attempts:)` | 有界重试耗尽 | 只有显式 `restart()` 才恢复（获得全新预算） |
| `notOwned` | 实例锁被别的进程持有 | 显式 `restart()` 才重新探测 |

状态机实现要点：

- **单一所有权**：`launch()` 第一行 `guard process == nil else { return }`，第二行 `if configuration.isHostRunning() { transition(.notOwned); return }`。两道闸门意味着既不会启动第二个 Host，也不会抢占别人的 Host。
- **代际 token**：每个 `Process` 携带 `launchToken`；`handleTermination(token:status:reason:)` 只处理 `token == launchToken` 的事件。迟到的旧进程退出事件、重复的 termination 回调都被丢弃（对应测试 15、16）。
- **意图先于判断**：`stopOwnedProcess(intent:)` 先把 `stopIntent = intent` 落定，再判断 `process.isRunning`。这修掉了"shutdown 与 restart 并发时被读成 restart 从而 relaunch"的竞态（对应测试 14）。
- **启动超时**：watchdog 在 `launchTimeout`（默认 6.0s）后仍未取锁 → 置 `timedOutLaunch` 并 `terminate()`；失败计数**只**在 termination 路径累加，避免双计数。
- **关闭升级**：SIGTERM（`Process.terminate()`）→ `gracefulExitTimeout`（2.5s）→ `kill(pid, SIGKILL)` → `killGraceTimeout`（1.0s）。全文件只有一处 `kill(`，源扫描测试固定这一点。
- **有界重试**：`maxConsecutiveFailures = 3`，退避 0.5s 起、8.0s 上限，指数增长。到顶进 `degraded`，App 继续运行并显示 "Audio routing is degraded"。
- **线程模型**：所有状态变更只在串行 `queue` 上发生；`onStateChange` 通过 `DispatchQueue.main.async` 投递；`currentState` / `ownedProcessIdentifier` 有锁保护。RT 路径与 audio callback 完全不参与。

### 4.2 三种退出，三条路径

| 触发 | 入口 | 状态迁移 | Host 后续 | App 后续 |
|---|---|---|---|---|
| 用户退出 App | `applicationWillTerminate` → `shutdown(intent: .appTermination)` | `isShutdown = true` → `stopping(.appTermination)` → `idle` | 永不重启（`isShutdown` 闸门 + `endsOwnership == true`） | 退出 |
| 卸载 | `prepareForUninstall()` → `shutdown(intent: .uninstall)` | 同上，intent 为 `.uninstall` | 永不重启（无 driver 重启即恢复风暴） | 延迟退出 |
| Host 意外退出 | `Process.terminationHandler` → `handleTermination` | `running → launching(attempt+1)` 或 `degraded` | 退避后重建，App PID 不变 | 继续运行并观察 |
| Host-only restart | `restartHost()` → `restart()` | `running → stopping(.restart) → launching → running` | 旧进程完全退出后才启动新进程 | PID 不变 |

`isShutdown` 是幂等的终局闸门：一旦置位，`start()` 与 `restart()` 都直接返回，且任何在途的退避定时器在触发时都会再检查一次。

### 4.3 Mapping 生命周期保护

- 旧 Host 退出 → `SharedMemoryMappingManager` 在 revalidate/IPC 时读到 identity 不匹配（或文件消失）→ retire 旧 lease → `mappingUnavailable` → `EQController` 撤销 applied 声明。
- 新 Host 发布 → 新 inode / 新 session UUID / 新 epoch → `generation` 递增 → `mappingPublished` → `applyIfNeeded(新 generation)` → 重新写入持久化 EQ。
- 旧 mapping 的 `munmap` 只发生一次（P2 Batch 3 的 lease 机制），因此不存在"向已回收内存写入"的窗口。
- 双 Host 不可能出现（`peakConcurrency` 恒为 1，`everStartedOverALiveHost == false`），因此不会有两个 Producer 争同一路径。
- 恢复失败时不退出：`degraded` 通过 `HostStatusModel.shared.update(.degraded)` 反映到 UI。

---

## 5. Batch D — Lifecycle 日志验证

**本批次未修改 Host 日志生产代码。** 七项语义在 P2 Batch 3 引入的 `HostLifecycleReporter` 中已由 `packages/host/Tests/SoundBridgeHostTests/LifecycleLoggingTests.swift` 覆盖，本轮只做逐项核对，确认修复后的语义仍然成立（Host 侧无代码改动，因此这些用例是回归而非新增）。

| 要求 | 覆盖用例 | 结论 |
|---|---|---|
| Mapping 替换不被误报为 Driver detach | `testRetiredAndReplacedMappingNeverProducesADetach` | 通过 |
| 新 Mapping 未连接时显示 waitingForDriver | `testNewIncarnationReportsWaitingForDriverNotDetached` | 通过 |
| Driver 连接后显示 connected | `testConnectedDriverNeverProducesDetachedWording` | 通过 |
| 真正 detach 才显示 detached | `testRealDetachOnTheSameIncarnationIsStillReported` | 通过 |
| `updatedAt` 更新不触发内容重复日志 | `testRepeatedIdenticalPollsLogOnceAndStillRefreshTheTimestamp` | 通过 |
| Host recovery 不保留上一代 session 的旧 detail | `testStaleDetachedDetailIsReplacedWhenANewIncarnationIsPublished` | 通过 |
| 同一状态不持续重复输出 | 同 `testRepeatedIdenticalPollsLogOnceAndStillRefreshTheTimestamp`（`hasSameContent` 忽略 `updatedAt`） | 通过 |
| 附加：无效 header 不被报成 detached | `testInvalidHeaderIsReportedAsInvalidNotDetached` | 通过 |
| 附加：新 incarnation 携带新 observation token | `testManagerObservationCarriesANewTokenForANewIncarnation` | 通过 |

执行：`29 tests, 0 failures`（LifecycleLogging 9 + DegradedLifecycle 15 + MappingIncarnation 5）。

**非阻断记录：** `DeviceRegistry` 每秒输出 `Wrote device-state.json (2 devices)`。按用户授权本批次不处理；已确认它不参与 Host supervisor 决策、不在任何热路径上，仅是 1Hz 的文件写入日志，不构成性能负担。未扩大为全项目日志重构。

---

## 6. 自动化回归测试

所有日志落盘到 `build/p3-closure-fix/evidence/`。

### 6.1 C1 — EQ 生命周期 12 项对照

`Tests/SoundBridgeAppTests/EQLifecycleOwnershipTests.swift`：9 个运行时用例 + 8 个源码边界用例（17 个）。

| # | 要求 | 用例 | 关键断言 |
|---|---|---|---|
| 1 | App 启动时 Mapping 尚不存在，writer 已创建 | `testTheWriterIsCreatedBeforeAnyMappingExists` | `isAvailable == false`；controller 已加载 6 / -3 / 2；`isAppliedToCurrentMapping == false` |
| 2 | Mapping 首次发布，自动应用 | `testTheWriterAppliesTheFirstPublishedMapping` | `isAppliedToCurrentMapping` 在 2s 内为真；`eqSequence > 0` |
| 3 | Mapping 先发布、writer 后创建，立即应用 | `testAWriterCreatedAfterThePublicationAppliesImmediately` | `.alreadyCurrent` 之后构造仍 `isApplied`；`lastAppliedGeneration == currentGeneration` |
| 4 | App 启动但从不创建 MenuBarView | `testGate3ScenarioTheWriterAppliesWithoutAnyViewOrPopover` | 全程无 View；文件 `eq_sequence == 2` |
| 5 | Popover 从未打开，EQ 仍应用 | 同 4 + `testMenuBarViewObservesTheAppOwnedController` | 视图侧无 `@StateObject`、无构造点 |
| 6 | 同一 Mapping 重复 attach，不重复写 | `testRepeatedAttachThroughTheAppWriterDoesNotRewrite` | 3 次 attach + revalidate 后 `generation` 不变、`eqSequence` 不变 |
| 7 | 新 inode / session / epoch，重新应用 | `testANewHostIncarnationGetsThePersistedValuesAgain` | 新 inode；新 bands 正确；旧 inode 的 `eqSequence` 不再变化 |
| 8 | 最新用户值优先于旧值 | 同 7（写入 `bass = -9` 后 restart） | 新 incarnation bands 用 -9 计算 |
| 9 | Mapping retire，applied 撤销 | `testTheWriterWithdrawsItsClaimWhenTheMappingIsRetiredAndReappliesLater` | `lastAppliedGeneration == nil`；值仍保留；重新发布后再次应用 |
| 10 | 写入失败不错误更新 applied | `testWithoutAMappingTheWriterNeverClaimsToBeApplied` | `flushToSharedMemory() == .unavailable`；applied 为 false / nil |
| 11 | disabled 时 bypass 与持久化值一致 | `testGate3ScenarioTheWriterAppliesWithoutAnyViewOrPopover`（`enabled: false`） | `snapshot.bypass == true` |
| 12 | 同一生命周期只有一个 EQController | `testTheProcessHasExactlyOneAppOwnedWriter` + `testOnlyTheServiceConstructsAnEQController` | `EQService.shared.controller === …`；`EQController(` 只在 `EQService.swift` 出现 1 次 |

**Gate 3 复现场景（要求必须存在的那一个）**

`testGate3ScenarioTheWriterAppliesWithoutAnyViewOrPopover`

流程与真实机器一致，且**不构造任何 View**：

1. `seed(bass: 0.02278646, mids: 12, treble: 0, enabled: false)` —— 真实机器的持久化值。
2. `EQService(deviceUID:mapping:)` —— writer 先存在。
3. `manager.start()` —— 观察者在 publish 之前就位。
4. `fixture.publish()` —— 真实 staging → rename → 独立 inode、独立 session UUID、独立 epoch。
5. `manager.revalidate()` —— 等价于 IPC 通知与 2s 兜底轮询。
6. 断言通过**第二条只读 mmap**（不是 writer 自己的视图）读出的文件内容：

```
published.sequence            == 2            （一次完整 SeqLock 写入 +2）
snapshot.bypass               == true         （EQ disabled）
bands(of: snapshot)           == EQController.computeBandGains(bass: 0.02278646, mids: 12, treble: 0)
incarnation.bandGains         == bands(of: snapshot)      （两个独立读者一致）
incarnation.eqSequence        == published.sequence
```

该测试使用的是 `SharedMemoryFixture` 建立的真实文件映射（`mmap` + `rf_load_eq_snapshot_safe`），**没有** mock publisher，也没有 mock mapping manager。读取 `eq_sequence` 使用 `offset 152`，与 `RFSharedAudio.h:360` 的 `static_assert` 一致。

### 6.2 C2 — Host Supervisor 16 项对照

`Tests/SoundBridgeAppTests/HostSupervisorTests.swift`：16 个用例。

| # | 要求 | 用例 |
|---|---|---|
| 1 | 正常 Host 启动 | `testStartingTheHostCreatesOneProcess` |
| 2 | Host-only restart | `testHostOnlyRestartReplacesTheProcessAndKeepsTheAppAlive` |
| 3 | App PID 不变 | 同 2（`XCTAssertEqual(getpid(), appPID)`） |
| 4 | Host PID 变化 | 同 2（`XCTAssertNotEqual(secondHostPID, firstHostPID)`） |
| 5 | 旧 Host 完全退出后才启动新 Host | 同 2（`peakConcurrency == 1`、`everStartedOverALiveHost == false`、`processes[0].isRunning == false`） |
| 6 | 旧 Mapping retire | `testAHostRestartRetiresTheOldMappingAndTheWriterFollowsTheNewOne` |
| 7 | 新 Mapping incarnation 建立 | 同 6（新 inode + 新 session + EQ 已 replay） |
| 8 | Host 意外退出自动恢复 | `testAnUnexpectedHostExitIsRecoveredWithoutRestartingTheApp` |
| 9 | 用户退出 App 不触发 Host 重启 | `testAppTerminationStopsTheHostAndNeverRelaunchesIt` |
| 10 | App shutdown 不触发恢复风暴 | `testShutdownCancelsARestartThatIsAlreadyInFlight`、`testRestartAfterShutdownIsIgnored` |
| 11 | 启动失败时有限重试 | `testACrashLoopIsBoundedAndEndsInDegraded`（恰好 3 次） |
| 12 | 连续失败进入 degraded | 同 11 + `testADegradedSupervisorStopsRetryingOnItsOwn` |
| 13 | 重复 restart 单飞 | `testRepeatedRestartRequestsAreSingleFlight`（3 次请求 → 2 次 launch） |
| 14 | restart 与 shutdown 并发 | `testShutdownCancelsARestartThatIsAlreadyInFlight` |
| 15 | terminationHandler 重复回调 | `testADuplicateTerminationEventDoesNotStartASecondHost` |
| 16 | 旧 Process 退出事件迟到 | `testALateTerminationEventFromAReplacedProcessIsIgnored` |

额外 4 个加固用例：`testStartingTwiceDoesNotCreateASecondHost`（`start()` 幂等）、`testRestartFromDegradedGetsAFreshBudget`（degraded 后 restart 获得全新预算）、`testAHostThatNeverTakesTheLockIsTreatedAsAFailedLaunch`（活着但不取锁 = 启动失败）、`testAHostOwnedByAnotherProcessIsNeverTakenOver`（`notOwned`，不抢别人的 Host）。

**不使用 helper executable 的理由：** `HostSupervisor.Configuration` 暴露 `makeProcess: () -> Process?` 与 `isHostRunning: () -> Bool` 两个注入口。测试注入 `/bin/sleep 30` 与 `/bin/sh -c "exit N"`，因此：

- 真实对象仍然真实：`Process` 对象、SIGTERM 投递、exit status、termination handler 的执行线程。
- 不会启动 HAL Driver、不会触碰 `coreaudiod`、不播放音频、不改默认输出。
- 测试二进制不会进入 App / PKG 产物（无新增 target、无新增可执行文件）。

### 6.3 Host-only restart 的测试过程（逐步）

`testHostOnlyRestartReplacesTheProcessAndKeepsTheAppAlive`：

| 步骤 | 动作 | 断言 |
|---|---|---|
| 1 | `supervisor.start()` | 状态进入 `running`，`launcher.launches == 1` |
| 2 | 记录 `appPID = getpid()`、`firstHostPID = processes[0].processIdentifier` | — |
| 3 | `supervisor.restart()` | 状态 `running → stopping(.restart) → launching(2) → running` |
| 4 | 等 `running` 且 `launches == 2` | 新 Host 已取锁 |
| 5 | `secondHostPID = processes[1].processIdentifier` | — |
| 6 | 核验 | `getpid() == appPID`（App 未重启）<br>`secondHostPID != firstHostPID`（Host 已替换）<br>`peakConcurrency == 1`（从未同时存在两个）<br>`everStartedOverALiveHost == false`（新 Host 在旧 Host 退出后才启动）<br>`processes[0].isRunning == false`（旧 Host 确实已死） |

Mapping 侧的 restart 过程（`testAHostRestartRetiresTheOldMappingAndTheWriterFollowsTheNewOne`）：

1. fixture 发布第一个 mapping，manager attach，EQ writer 应用。
2. `supervisor.restart()`（stub Host 换代）。
3. 旧 mapping 文件移除 + `manager.revalidate()` → 旧 lease retire → `isAvailable == false` → `isAppliedToCurrentMapping` 在有限轮询内变 false。
4. fixture 发布第二个 mapping（新 inode / 新 session / 新 epoch）。
5. 断言：新 `generation` 更大、writer 自动 replay 持久化值、旧 inode 的 `eq_sequence` 不再增长。

### 6.4 C3 — 并发与 Sanitizer

| 检查 | 命令 | 结果 | 日志 |
|---|---|---|---|
| TSan（EQ 全族） | `swift test --sanitize=thread --filter "EQ"` | 60 tests / 0 failures | `app-tsan-eq.log` |
| TSan（supervisor） | `swift test --sanitize=thread --filter HostSupervisorTests` | 16 tests / 0 failures | `app-tsan-host-supervisor.log` |
| TSan 运行时确认 | `otool -L` 产物 | 链接 `libclang_rt.tsan_osx_dynamic.dylib` | `app-tsan-eq.log` |
| ASan（新增 + EQ 恢复族） | `swift test --sanitize=address --filter "HostSupervisorTests\|EQLifecycleOwnershipTests\|EQOwnershipBoundaryTests\|EQRecoveryTests"` | 41 tests / 0 failures | `app-asan-new-suites.log` |
| 连续重复运行 3 轮 | `swift test --filter "HostSupervisorTests\|EQLifecycleOwnershipTests\|EQOwnershipBoundaryTests\|EQRecoveryTests\|SharedMemoryMappingConcurrencyTests"` ×3 | 每轮 50 tests / 0 failures / exit 0 | `app-repeat-runs.log` |

覆盖的并发面：Process lifecycle race、terminationHandler 重入、shutdown 与 restart 并发、EQController 单例生命周期、mapping publish / retire 并发、EQ write lease 生命周期。

**没有通过跳过断言来制造通过结果**：TSan/ASan 运行的是同一批测试文件，断言没有被 `#if` 条件编译包裹；`peakConcurrency == 1`、`everStartedOverALiveHost == false`、`getpid()` 不变这类核心并发断言在 sanitizer 构建下同样执行。

### 6.5 完整 `make test`

命令：`make test`（串行执行 `protocol-check → version-check → test-dsp → test-driver → test-host → test-app → test-installer → test-codesign`）
日志：`build/p3-closure-fix/evidence/make-test.log`（252,906 bytes）
退出码：`EXIT=0`

| 阶段 | 结果 |
|---|---|
| `protocol-check` | `RF_AUDIO_PROTOCOL_VERSION = 0x00020200 (131584)` |
| `version-check` | 11 个来源，0 失败，`VERSION_CONSISTENCY=PASS`，VERSION = 1.2.0 |
| `test-dsp` | `100% tests passed, 0 tests failed out of 1` |
| `test-driver` | `100% tests passed, 0 tests failed out of 3` |
| `test-host` | `Executed 379 tests, with 0 failures` (32.85s) |
| `test-app` | `Executed 244 tests, with 0 failures` (19.63s) |
| `test-installer` | `transaction scenarios: 168 passed, 0 failed`；`the HAL directory was never touched by this test run` |
| `test-codesign` | `PASS: 58 checks, 0 failures` |
| 汇总 | `✓ All test suites passed` |

App 的 244 个用例 = 本批次新增 33 个（supervisor 16 + EQ ownership 17）+ 既有 211 个，全部通过。

### 6.6 其他 App / Host 测试执行

| 命令 | 结果 | 日志 |
|---|---|---|
| `cd apps/mac/SoundBridgeApp && swift test` | 244 tests / 0 failures / 19.69s | `app-tests-full.log` |
| `cd packages/host && swift test --filter "LifecycleLoggingTests\|MappingIncarnationTests\|DegradedLifecycleTests"` | 29 tests / 0 failures | `host-lifecycle-tests.log` |

---

## 7. 版本 / ABI / Protocol / plist 未变化证据

### 7.1 三份 `RFSharedAudio.h` 完全一致且未被触碰

```
packages/shared/include/RFSharedAudio.h
  0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee   mtime 2026-11-20 12:41:49
packages/driver/include/RFSharedAudio.h
  0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee   mtime 2026-11-20 12:27:23
apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
  0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee   mtime 2026-11-20 12:27:23
```

三份哈希相同（`sync_shared_header.sh` 的不变量仍然成立），且 mtime 全部早于本批次窗口（2026-11-21 14:18 起）。

### 7.2 版本与打包配置未被触碰

| 文件 | SHA-256 | mtime |
|---|---|---|
| `VERSION` | `1e5b51cde515396a9fa762909cf8ca6584ccc564b325d2eebeea76175fe95c4d` | 2026-11-17 21:07:02 |
| `apps/mac/SoundBridgeApp/Info.plist` | `37894c35043114c624443280ce2ffddb3d94d096a8ba82476ed5b15fc90a3698` | 2026-11-17 21:07:32 |
| `apps/mac/SoundBridgeApp/Package.swift` | `e56fcac54ec269dccf12836db9147f5afe9be7fb4893157c4fd2281361118eb8` | 2026-11-16 15:01:16 |
| `packages/host/Package.swift` | `ac49d8ffec1c14f8f8f8e4d175252cf62ebe49204260e4c8e10a81442934a3be` | 2026-11-16 18:23:07 |

`Package.swift` 未改动意味着：没有新增 target、没有新增可执行产物、Deployment Target 未变、测试 helper 不会进入 App / PKG。

### 7.3 Protocol 与 ABI 常量

```
RFSharedAudio.h:48    #define RF_AUDIO_PROTOCOL_VERSION 0x00020200
RFSharedAudio.h:360   static_assert(offsetof(RFSharedAudio, eq_sequence) == 152, "eq_sequence moved");
RFSharedAudio.h:394   _Static_assert(offsetof(RFSharedAudio, eq_sequence) == 152, "eq_sequence moved");
```

`make protocol-check` 与 `make version-check` 均在 `make test` 中通过，属于编译期 + 脚本期双重证明。

### 7.4 本批次触碰的文件（mtime 证据，全部落在 2026-11-21 14:18–14:25）

```
Sources/Services/HostSupervisor.swift              2026-11-21 14:21:48
Sources/App/SoundBridgeApp.swift                   2026-11-21 14:18:53
Sources/Views/MenuBarView.swift                    2026-11-21 14:18:54
Sources/Services/EQService.swift                   2026-11-21 14:18:53
Tests/.../HostSupervisorTests.swift                2026-11-21 14:25:11
Tests/.../EQLifecycleOwnershipTests.swift          2026-11-21 14:23:52
```

---

## 8. Git status 变化

### 8.1 基线对比

| 指标 | 时点 A（代码与测试完成、报告未写） | 时点 B（报告写入后） | 差异 |
|---|---|---|---|
| HEAD | `ab3677072f0dcb54de27ba4dcabfd11e64ae41ec` | 同 | 未变（无 commit） |
| 分支 | `main` | `main` | 未变 |
| staged | 0 | 0 | 未变（无 `git add`） |
| 工作区条目 | 120 | 121 | +1，即 `?? docs/P3-Final-Closure-Fix-Report.md` |

时点 A 的 120 条已包含本批次新增的 4 个源/测试文件（mtime 14:18–14:25，早于时点 A），因此相对 HEAD 的净增量是 5 个未跟踪文件。

**本批次没有执行任何 Git 写操作**：无 `add` / `commit` / `stash` / `reset` / `clean` / `checkout` / `restore` / `tag`。

### 8.2 App target 的 status（含既有批次改动，供区分）

```
 M Sources/App/SoundBridgeApp.swift              ← 本批次
 M Sources/Views/MenuBarView.swift               ← 本批次
 M Sources/CSoundBridgeAudio/include/RFSharedAudio.h   ← 既有（mtime 2026-11-20）
 M Sources/Models/HostLifecycleReport.swift      ← 既有
 M Sources/Models/HostStatusModel.swift          ← 既有
 M Sources/Services/EQController.swift           ← 既有
 M Sources/Services/HostInstanceProbe.swift      ← 既有
 M Sources/Services/IPCController.swift          ← 既有
 M Sources/Services/VolumeController.swift       ← 既有
 M Tests/.../DriverCompatibilityNoticeTests.swift ← 既有
 M Tests/.../DriverInstallIntentTests.swift      ← 既有
 M Tests/.../DriverRecoveryMatrixTests.swift     ← 既有
 M Tests/.../DriverVersionGateTests.swift        ← 既有
 M Tests/.../HostInstanceProbeTests.swift        ← 既有
 M Tests/.../HostRunStateTests.swift             ← 既有
?? Sources/Services/HostSupervisor.swift         ← 本批次（新增）
?? Sources/Services/EQService.swift              ← 本批次（新增）
?? Tests/.../HostSupervisorTests.swift           ← 本批次（新增）
?? Tests/.../EQLifecycleOwnershipTests.swift     ← 本批次（新增）
?? Sources/Services/DefaultOutputSwitch.swift    ← 既有
?? Sources/Services/SharedMemoryMappingManager.swift ← 既有
?? Tests/.../{DefaultOutputSwitch,EQRecovery,SharedMemoryMapping*}Tests.swift ← 既有
```

`packages/driver/**`、`packages/shared/**`、`tools/**`、`docs/**` 下的 `M` / `??` 条目全部是前序批次遗留，mtime 均早于本批次窗口。

### 8.3 现有用户工作区修改未丢失

- 既有条目在本批次前后一致；唯一新增条目是本报告（120 → 121），没有既有条目消失或被改写。
- 既有测试文件的 mtime 全部 ≤ 2026-11-20，**没有**旧测试文件被本批次修改、删除或弱化。
- 本批次只新增 2 个测试文件，未编辑任何既有测试文件。
- `docs/` 下只新增 1 个文件（本报告），未覆盖任何已有文档；`ls docs/P3-Final-Closure-Fix-Report.md` 在撰写前返回 "No such file or directory"。

---

## 9. 代码审查 12 问（逐项）

**1. EQController 是否已经完全脱离 MenuBarView 的创建生命周期？**
是。`MenuBarView` 现为 `@ObservedObject private var eqController: EQController` + 显式 `init(eqController:)`。源扫描用例 `testOnlyTheServiceConstructsAnEQController` 断言 `EQController(` 在全 App 源码中只出现于 `Sources/Services/EQService.swift`，且恰好 1 处；`testMenuBarViewObservesTheAppOwnedController` 同时禁止 `@StateObject private var eqController` 与视图内构造。

**2. App 不打开 Popover 是否仍会应用 EQ？**
是。`EQService.shared` 是 `AppDelegate` 的属性，初始化发生在 `applicationDidFinishLaunching` 之前；`testGate3ScenarioTheWriterAppliesWithoutAnyViewOrPopover` 全程不构造任何 View，文件 `eq_sequence == 2`、`bypass == true`、bands 与持久化值一致。

**3. Mapping 先发布、EQController 后创建是否能够恢复？**
是。`observeMapping()` 订阅之后立即 `if mapping.isAvailable { applyIfNeeded(generation: mapping.currentGeneration) }`。`testAWriterCreatedAfterThePublicationAppliesImmediately` 在 `.alreadyCurrent`（不重发事件）之后构造 writer，仍立即 applied。

**4. 同一 App 生命周期是否只有一个 EQController？**
是。`EQService.shared` 是唯一的 `EQService` 实例，`controller` 是唯一的 `EQController`。runtime + 源扫描双重断言（测试 12）。

**5. Host 意外退出后 App 是否继续运行？**
是。`NSApp.terminate` 已从 `SoundBridgeApp.swift` 中彻底移除（`testTheAppNoLongerTerminatesItselfWhenTheHostExits` 断言该字符串不存在，`hostProcess` 同样不存在）。`testAnUnexpectedHostExitIsRecoveredWithoutRestartingTheApp` 断言 `getpid()` 在恢复前后相同。

**6. Host-only restart 是否真实执行过自动化测试？**
是。`testHostOnlyRestartReplacesTheProcessAndKeepsTheAppAlive` + `testRepeatedRestartRequestsAreSingleFlight` + `testRestartFromDegradedGetsAFreshBudget` + `testAHostRestartRetiresTheOldMappingAndTheWriterFollowsTheNewOne`。使用真实 `Process`、真实 SIGTERM、真实 exit status，并在 TSan / ASan 下重复运行。

**7. App 主动退出是否不会触发 Host restart？**
是。`shutdown(intent: .appTermination)` 置 `isShutdown = true`，`endsOwnership == true`，`start()` / `restart()` 全部短路；在途退避定时器触发时会再检查一次。`testAppTerminationStopsTheHostAndNeverRelaunchesIt`、`testRestartAfterShutdownIsIgnored` 覆盖。

**8. Host 新 Mapping 是否会自动触发 EQ replay？**
是。新 Host → 新 inode / session / epoch → `generation` 递增 → `mappingPublished` → `applyIfNeeded` → 重新写入。`testANewHostIncarnationGetsThePersistedValuesAgain`（且用最新用户值）与 `testAHostRestartRetiresTheOldMappingAndTheWriterFollowsTheNewOne` 覆盖。

**9. 是否可能同时存在两个 Host？**
否。`launch()` 双闸门（`process == nil` + `isHostRunning()`）。测试中 `peakConcurrency` 恒为 1，`everStartedOverALiveHost` 恒为 false（覆盖正常启动、restart、意外退出恢复、多次 restart 请求）。`notOwned` 状态保证不会抢占别的进程持有的实例锁。

**10. 是否存在旧 Mapping / Session 残留？**
否。Host 退出后旧 mapping 被 `SharedMemoryMappingManager` retire（`mappingUnavailable` → `applied` 撤销），旧 `Process` 对象在 termination 处理中置 nil 并保留 `token` 用于丢弃迟到事件。测试断言旧 inode 的 `eq_sequence` 在切换后不再变化，旧 session 不会让 App 误判 connected（`testStaleDetachedDetailIsReplacedWhenANewIncarnationIsPublished`）。

**11. 是否新增了未经证明的线程安全假设？**
没有。新增的跨线程点全部显式且被 TSan 覆盖：

| 机制 | 假设 | 证明 |
|---|---|---|
| `HostSupervisor.queue`（串行） | 所有状态变更与进程操作单线程化 | TSan supervisor 16 tests |
| `onStateChange` → `DispatchQueue.main.async` | 观察者只在主线程被调用 | 同上 |
| `lock` 保护的 `currentState` / `ownedProcessIdentifier` / `isShutdown` | 读方在主线程、写方在 queue | 同上 |
| Combine `receive(on: .main)` | EQ 订阅回调在主线程 | TSan EQ 60 tests |
| `launchToken` 代际 | terminationHandler 在任意线程触发 | 迟到/重复事件用例 |
| `NSLock`（测试 stub） | 计数与进程数组的并发读写 | 全部 supervisor 用例 |

未使用任何"看起来应该安全"的隐式假设（例如假设 `Process.terminationHandler` 在主线程，或假设 `PassthroughSubject` 有 replay）。

**12. 是否引入了新的系统音频副作用？**
没有。

- supervisor 源码中不存在 `coreaudiod`、`killall`、`Plug-Ins/HAL`（源扫描断言），`kill(` 仅 1 处（SIGKILL 上限）。
- 未修改默认输出治理逻辑、未修改音量/静音、未触碰 Driver 安装卸载脚本。
- 测试使用 `/bin/sleep` 与 `/bin/sh` 作为 Host 替身，真实 shared memory 文件建在临时目录，不注册 HAL、不重启 CoreAudio、不播放音频。

---

## 10. 尚未解决的限制

1. **真实机器验证未执行。** 本批次按授权只做代码与离线测试。`eq_sequence = 2` 的结论来自真实 mapping 文件的离线复现（真实 mmap、真实 `rf_load_eq_snapshot_safe`、真实 SeqLock），但不是真实 Host + 真实 Driver + 真实 coreaudiod 的端到端结果。下一批次需要 `P3 Final Rebuild + Install + Real Host-only Restart EQ Recovery Validation` 才能关闭。
2. **`shutdown(waitTimeout:completion:)` 是唯一的同步等待。** 它用 3.5s 上限（`hostTerminationTimeout + 0.5`）的 `DispatchSemaphore` 在 `applicationWillTerminate` / `prepareForUninstall` 中阻塞，因为进程即将退出、必须保证 Host 不残留。这是刻意的例外，不是通用模式：所有其他路径（start / restart / 恢复）都是异步的，主线程不做同步等待。
3. **`degraded` 与 `notOwned` 是终局状态。** 进入后不会自动重试，需要显式 `restart()`（当前仅内部诊断入口）。如果另一 App 的 Host 在 `notOwned` 之后退出，本 App 不会自动接管——这是有意的（避免抢锁），但也是一个功能缺口。
4. **未提供用户可见的 restart 入口。** 按规范不加菜单按钮。`restartHost()` 目前是 internal 方法，可由自动化测试或未来诊断 UI 调用。
5. **EQ replay 的发现延迟取决于 manager 的轮询/IPC。** 若 Host 发布了新 mapping 而 App 侧既没有 IPC 通知也没有在 2s 内轮询到，replay 会延迟至下一次 revalidate。这是 P2 Batch 3 既有设计，本批次未改动。
6. **`DeviceRegistry` 每秒 `Wrote device-state.json (2 devices)` 日志保留。** 按规范列为非阻断项，未处理。
7. **未验证 `notOwned` 场景下的 UI 文案。** `HostStatusModel` 没有专门的 notOwned 状态映射，用户看到的是既有的 notRunning/degraded 语义。

---

## 11. 最终状态

```
PASS — FINAL CLOSURE CODE & TESTS COMPLETE
```

依据：

| 验收项 | 结果 |
|---|---|
| Gate 3 Defect A 根因消除（EQ writer 归属） | 通过；真实 mapping 文件复现 `eq_sequence == 2` |
| Gate 3 Defect B 根因消除（Host 退出不退出 App） | 通过；`NSApp.terminate` 已从 App 移除 |
| Host-only restart 能力 | 通过；真实 `Process` 测试，App PID 不变 |
| C1 EQ lifecycle 12 项 | 12/12 覆盖 |
| C2 Host supervisor 16 项 | 16/16 覆盖 |
| C3 TSan / ASan / 重复运行 | 全部 0 failures |
| App 全量测试 | 244 tests / 0 failures |
| Host 全量测试 | 379 tests / 0 failures |
| `make test` | `EXIT=0`，`✓ All test suites passed` |
| Driver / ABI / Protocol / Version / plist | 零差异（哈希 + mtime + 脚本校验三重证据） |
| 旧测试未被删除或弱化 | 是（既有测试文件 mtime 全部 ≤ 2026-11-20） |
| 现有用户工作区修改未丢失 | 是（120 条目不变） |

**本批次到此停止。** 未构建 PKG / DMG、未安装、未重启 CoreAudio、未启动真实 Host 做硬件测试、未播放真实音频、未修改默认输出、未创建 commit / tag、未发布 Release。

等待用户独立授权下一批次：**P3 Final Rebuild + Install + Real Host-only Restart EQ Recovery Validation**。
