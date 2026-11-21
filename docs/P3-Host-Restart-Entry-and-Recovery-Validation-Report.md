# P3 Host Restart Entry & Real Recovery Validation

**批次：** SoundBridge 1.2.0 — P3 Final Host Restart Entry & Real Recovery Validation
**目标：** 通过正式 App UI 入口调用既有 `HostSupervisor.restart()`，在真实 macOS / 真实 HAL Driver / 真实 Host / 真实 shared memory 上验证「Host-only restart、App 存活、新 Mapping 发布、EQ 自动恢复」
**仓库：** `/path/to/SoundBridge`
**HEAD：** `ab3677072f0dcb54de27ba4dcabfd11e64ae41ec`（branch `main`，全程未变）
**日期：** 2026-11-21
**上一批次报告：** `docs/P3-Final-Rebuild-Install-Host-Restart-Validation-Report.md`（结论 `CONDITIONAL PASS — EXPLICIT REMAINING GAPS`，Batch D 因无入口判 `BLOCKED`）
**证据根目录：** `build/p3-host-restart-verify/evidence/`（全部原始日志，本报告所有数字均可回溯）
**产物根目录：** `build/p3-host-restart-dist/`（隔离新建，未覆盖任何历史产物）

**最终结论：`PASS`**

> 上一批次唯一阻塞项（`restartHost()` 全仓无调用者）已通过一个正式的 `Restart Host` 菜单项关闭，并用一次真实的、由 UI 点击触发的 Host-only restart 完成 20 项运行时验证：App PID 不变、旧 Host 完全退出、新 Host 单实例、新 Mapping 新 inode / 新 session / 新 epoch、EQ 在新 Mapping 上自动重放（`eq_sequence = 2`、bands 与持久化值逐位一致），随后 411 秒（6 分 51 秒）连续观察全部指标恒定。
> **唯一明确未完成项是 §9 的实际 EQ 听感**：默认输出仍为物理设备 LG ULTRAGEAR+ 而非 SoundBridge Proxy，本批次未获授权切换，因此 `NOT RUN / BLOCKED`，不做任何主观听感断言。

---

## 0. 结论摘要

| Batch | 内容 | 结果 | 决定性问题 |
|---|---|---|---|
| 0 | 只读审计 `restartHost()` / `HostSupervisor.restart()` / `MenuBarView` | **PASS** | `restart()` 天然单飞；旧进程被 reap 后才 relaunch；`shutdown()` 已使 `restart()` 早退 —— 无需改状态机，只需补一个只读出口 + 一个入口闸门 + 一个菜单项 |
| 1 | 最小 UI 入口 `Restart Host` + 8 项测试要求 | **PASS** | 6 个文件（4 改 2 新），新增 9 个用例；入口只转发到 `AppDelegate.restartHost()`，不新建 `Process`、不 kill、不绕过 supervisor |
| 2 | `make test` + ASan / TSan | **PASS** | Host 379 / App 253（含新增 9）全绿，`MAKE_TEST_EXIT=0`；ASan 25/25、TSan 25/25 |
| 3 | 隔离重建 + 安装 + 逐文件核验 | **PASS** | App bundle ≡ PKG payload ≡ DMG（109 行清单零差异）；安装只改 1 个文件；Driver / Host 二进制逐字节未变 |
| 4 | 真实 Host-only restart（UI 触发） | **PASS** | 20 项指标全部符合：App 106 不变、旧 Host 108 消失、新 Host 10612、单实例、新 inode/session/epoch、EQ 自动重放 |
| 5 | 411 s 稳定性观察 | **PASS** | 360/360 采样单值；heartbeat 1.000 Hz；无 detach / reconnect / retire / crash；默认输出 11/11 不变 |
| §9 | 实际 EQ 声音验证 | **NOT RUN / BLOCKED** | 默认输出非 Proxy，切换未授权；不越边界 |

三条最终重点的现状：

1. **Host restart 时 App 是否退出？** → **不退出（REAL_MACOS_VERIFIED）**：App PID `106` 在 restart 前后与 411 秒观察期内始终为 `106`。
2. **新 Mapping 发布后 EQ 是否自动恢复？** → **是（REAL_MACOS_VERIFIED）**：新 inode `69959980` 上在映射出现后约 1 秒内即出现 `eq_sequence = 2`、`eq_bypass = 1`、bands 与 `UserDefaults` 独立推导值逐位一致，且此后 12 分钟未再自增（无重复写入）。
3. **是否只有一个 Host？** → **是（REAL_MACOS_VERIFIED）**：1 Hz 采样 360 次 `host_count` 恒为 1；权威日志显示旧 Host 退出（`15:33:42.777`）早于新 Host 启动（`15:33:42.780`）。

---

## 1. 基线与现场（批次开始时重新采集，不使用任务书中的历史 PID）

### 1.1 Git 与版本

```
$ git -C /path/to/SoundBridge rev-parse HEAD
ab3677072f0dcb54de27ba4dcabfd11e64ae41ec
$ git ... rev-parse --abbrev-ref HEAD
main
$ git ... status --porcelain | wc -l
122          # 批次中为 124（+2 = HostRestartEntry.swift / HostRestartEntryTests.swift），交付报告后为 125
$ git ... diff --cached --name-only | wc -l
0
$ cat VERSION
1.2.0
```

工作区 122 条为 P2 / P3 前序批次遗留（与上一批次报告交付时一致）。**本批次未执行任何 Git 写操作**：无 `add` / `commit` / `stash` / `reset` / `clean` / `checkout` / `restore`。原始记录：`batch6-git-state.log`、`batch6-final-state.log`。

### 1.2 源码哈希（批次开始采集，批次结束复核一致）

```
edd73c959685d71edd76aa3f0e9c55b55bb26ba68ddc6f6d2db7a3b8e25060fb  Sources/App/SoundBridgeApp.swift
775a3d5b41b28247032fc96583722754023021228c8ab1fcce082e609b267779  Sources/Services/HostSupervisor.swift
44ebb9c6b07b1aa92762cbb38c2591b99a08db6c4c0aed6074edb9f8abe354df  Sources/Services/EQService.swift
ba434220dcbe2323e25667f4ec590f139633f6ec1cb57f96c37f1154cebdc044  Sources/Services/EQController.swift
af4e0b81abc464975979d0ade08aff335ffb9758e21d27cc18b904690535282f  Sources/Views/MenuBarView.swift
1367646438cc8509bdb93203bf6f94514b7d210844a165f68c3e33b88be083b0  Sources/Services/VolumeController.swift
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/shared/include/RFSharedAudio.h
1e5b51cde515396a9fa762909cf8ca6584ccc564b325d2eebeea76175fe95c4d  VERSION
37894c35043114c624443280ce2ffddb3d94d096a8ba82476ed5b15fc90a3698  apps/mac/SoundBridgeApp/Info.plist
```

`EQService.swift` / `EQController.swift` / `VolumeController.swift` / `RFSharedAudio.h` / `VERSION` / `Info.plist` 的哈希在本批次**结束复核时仍完全相同** —— 协议、版本、ABI、EQ 写入器均未被触碰。原始文件：`baseline.log`、`batch6-final-state.log`。

### 1.3 安装态基线（本批次开始时）

| 项 | 值 |
|---|---|
| `/Applications/SoundBridge.app/Contents/MacOS/SoundBridgeApp` | `3671854cd3dea73f…47c7a25eb`（上一批次的产物） |
| `…/Contents/MacOS/SoundBridgeHost` | `d8d1249627cd26bf…57642aae` |
| `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver` | `c295503019a07126…f2f3e24a0` |
| App 文件数 / 版本 | 109 / 1.2.0 |
| Driver 版本 / bundle id / 协议 | 1.2.0 / `com.soundbridge.driver` / `131584` |

### 1.4 运行态基线（T0，重新采集；**未复用任务书中的 App 4182 / Host 4201**）

```
=== T0 baseline 2026-11-21T07:30:18Z ===
  106     1    00:20 /Applications/SoundBridge.app/Contents/MacOS/SoundBridgeApp
  108   106    00:20 /Applications/SoundBridge.app/Contents/MacOS/SoundBridgeHost
  598     1 17:35:50 /usr/sbin/coreaudiod
  628     1 17:35:50 Core Audio Driver (SoundBridgeDriver.driver)
--- lock ---
pid=108 uid=501 since=2026-11-21T07:29:58Z session=E7463720-2C10-42D1-8DC9-C477F91B53F9
--- control ---
#SB-CONTROL 1 E7463720-2C10-42D1-8DC9-C477F91B53F9 3 501 2
LG ULTRAGEAR+|1E6D4678-0000-0000-0424-0104C5462778
PHL 279M1RV|410C54C2-0000-0000-051F-0103803C2278
--- mappings ---
69959464 -rw-rw-rw-@ 1 owner       wheel  65856 Nov 21 15:29 /tmp/soundbridge-501-1E6D4678-0000-0000-0424-0104C5462778
69959467 -rw-rw-rw-@ 1 owner       wheel  65856 Nov 21 15:29 /tmp/soundbridge-501-410C54C2-0000-0000-051F-0103803C2278
--- defaults ---
    "eq_default_bass_db" = "0.02278646";
    "eq_default_enabled" = 0;
    "eq_default_mids_db" = 12;
    "eq_default_treble_db" = 0;
```

默认输出（同一时刻）：`DEFAULT_OUTPUT_ID=109`、`UID=1E6D4678-0000-0000-0424-0104C5462778`、`NAME=LG ULTRAGEAR+`、`DEVICE_COUNT=7`。原始文件：`batch4-t0-baseline.log`、`batch4-t0-mapping.json`、`batch4-t0-coreaudio.log`。

### 1.5 与任务书历史值的对照

| 项 | 任务书/历史值 | 本批次实测 | 说明 |
|---|---|---|---|
| App PID | 4182 | **106** | 上一批次的 App 已退出，新装 App 重新启动；历史值未复用 |
| Host PID | 4201 | **108** | 同上 |
| Mapping inode | 69943151 | **69959464** | 每次 Host 发布新建文件 |
| coreaudiod | 598 | **598** | 未重启（同一 PID，`lstart` 仍为 Nov 20 21:54:28） |
| Driver 插件 | 628 | **628** | 未重载（同一 PID、同一 `lstart`） |

---

## 2. Batch 0 — 只读审计（STATICALLY_REVIEWED）

审计对象：`Sources/App/SoundBridgeApp.swift`（950 行）、`Sources/Services/HostSupervisor.swift`（660 行）、`Sources/Views/MenuBarView.swift`（576 行）、`Sources/Services/EQService.swift`。**本批次未修改其中任何行为语义**，审计结论如下。

### 2.1 `restartHost()` 的定义与可见性

```swift
/// Host-only restart: terminate the Host this App owns, wait for it to exit,
/// and start a replacement. ...
func restartHost() {
    hostSupervisor.restart()
}
```

`internal`，位于 `@main class AppDelegate`。原注释明确说明该路径没有菜单项、没有用户可见面，即审计发现的唯一缺口是**没有调用者**，而不是实现缺失。

### 2.2 `HostSupervisor.restart()` 的队列与单飞约束

- `restart()` 是 `internal`，函数体整体包在 `queue.async { … }` 内，`queue` 是 serial 的 `com.soundbridge.app.host-supervisor`。
- 分状态处理：`.running` / `.launching` → `stopOwnedProcess(intent: .restart)`；`.stopping` → **合并**（不排队第二次 stop）；`.idle` / `.degraded` → 直接 `launch(attempt: 0)`；`notOwned` → 忽略；`isShutdown == true` → 早退。
- 因此"快速连点 N 次"在 supervisor 内部被折叠为一次替换，不需要 UI 层做额外的互斥 —— UI 层只需拒绝"正在卸载""正在退出""supervisor 已 shutdown"这三种语义无效的点击。

### 2.3 状态机是否允许 running → stopping → launching → running

允许，且是既有设计：`stopping(intent:)` 只在 `handleTermination` 中退出；退出后 `transition(to: .idle)` 再 `launch(attempt: 0)` → `launching(attempt: 0)` → watchdog 通过后 `running(pid:)`。**Batch 4 的真实日志逐步复现了这条链**（见 §6.3）。

### 2.4 Host 退出回调与 App shutdown 是否可能竞争

不会产生"restart 与 shutdown 互相打断"的破坏性竞争：

- `shutdown()` 先在队列内置 `isShutdown = true`，再走同一套 `stopOwnedProcess`；`restart()` 一旦看到 `isShutdown` 立即早退。
- `handleTerminationOnQueue` 用 `launchToken` 丢弃迟到的退出事件，并且先判 `stopIntent` 再决定是"重启"还是"结束"。
- 因此 `applicationWillTerminate` 与一次在飞的 restart 之间，最终只会有一个结果：要么 restart 被 shutdown 取消（旧 Host 不再被替换），要么 restart 先完成、shutdown 再收走新 Host。**没有"App 退了但 Host 还在"的路径**，因为 `applicationWillTerminate` 的最后一个动作是 `hostSupervisor.shutdown(...)` 的同步等待。

### 2.5 restart 是否等待旧 Host 完全退出 / 新 Host 启动前锁是否已释放

是。`handleTerminationOnQueue` 的顺序是：

```
process = nil            // 先 reap
...
launch(attempt: 0)       // 再启动；launch() 内有 guard process == nil
```

`launch()` 另有两道闸：`guard process == nil`，以及 `configuration.isHostRunning()`（真实 `flock` 探测）。再加上 Host 侧实例锁是 `flock`（进程死亡即释放），所以"两个 Host 同时持有锁"在构造上不可能。Batch 4 的 1 Hz 采样与权威日志分别从外部与内部证实了这一点（§6.3 / §6.5）。

### 2.6 EQ 是否会监听新 Mapping 并自动重放

是，且写入者与视图无关：

- `EQService.shared.controller` 在 `AppDelegate` **属性初始化时**创建，早于 `SharedMemoryMappingManager.shared.start()`，更早于任何 View 存在。
- 新 Mapping 发布的信号进入 `SharedMemoryMappingManager.revalidate()`（由 IPC `onDeviceStateChanged` 与结构化兜底共同驱动），App 层重新 map 新 inode 后由同一个 controller 重放持久化 EQ。
- `MenuBarView` 只观察，不创建写入者（上一批次 Gate 3 修复的正是"写入者只在 popover 打开时出现"）。

### 2.7 `MenuBarView` 现有布局与事件处理

既有顺序：标题区 → 设备列表 → `Reconnect Audio`（`ReconnectAudioButton`，发 `com.soundbridge.bounce-request` 进程内通知）→ `FooterBar`。既有先例：`UninstallButton` 通过 `NSApp.delegate as? AppDelegate` 触达 delegate 方法；本批次沿用同一写法，不引入新的依赖注入容器。

### 2.8 审计结论与最小方案

**无需改动状态机，也无需改动线程模型。** 最小改动集：

1. `HostSupervisor` 暴露一个只读的 `isShutDown`（作为"supervisor 已收工"的语义出口，供 UI 给出明确拒绝理由）。
2. 新增 `HostRestartEntry` 作为入口闸门（可测试、不依赖 `NSApplication`），动作以闭包注入，保证菜单项走的是 `AppDelegate.restartHost()` 本身。
3. `AppDelegate` 增加 `isTerminating` 与 `requestHostRestart()`。
4. `MenuBarView` 增加独立的 `Restart Host` 行。

**明确未做**：没有把 `Reconnect Audio` 改名伪装成进程重启；没有新增 IPC / Driver 控制通道；没有新增诊断面板。

---

## 3. Batch 1 — 最小 UI 入口实现

### 3.1 修改文件与哈希

| 文件 | 类型 | 修改前 SHA-256 | 修改后 SHA-256 | 行数变化 |
|---|---|---|---|---|
| `Sources/App/SoundBridgeApp.swift` | 修改 | `edd73c959685d71e…e25060fb` | `ef12183dfbf914fd1d7091ec591c21f6f7c54580bee66b9761e4716e7abf3a7f` | +26 / −2（950 行） |
| `Sources/Views/MenuBarView.swift` | 修改 | `af4e0b81abc46497…0535282f` | `af175ee5e278b3fc8a5677e7605dc7c6723b584a0a0b6431c6a027f0d74a5ad2` | +86（576 行） |
| `Sources/Services/HostSupervisor.swift` | 修改 | `775a3d5b41b28247…9b267779` | `3c7fb9f5a81fdc4762a90be273feb30dfdaa4117ee4c5c597a1f78e8b7de7838` | +10（660 行） |
| `Tests/SoundBridgeAppTests/HostSupervisorTests.swift` | 修改 | 未采集（见 §3.1.1） | `3d3a8656b9dc02c74f42df6807e0aad0d63c3331e4ff2252f81c34cee9824b37` | 净 +6（492 行） |
| `Sources/Services/HostRestartEntry.swift` | **新增** | — | `7235599f13151f4cf3518591aa05eb557c8f52fd23f2a4b315ecb2f026cc5792` | 84 行 |
| `Tests/SoundBridgeAppTests/HostRestartEntryTests.swift` | **新增** | — | `ce9f48c2ced0c6ae52f49fa5f4f1d0e8c7f05c57e0dd1088a586ab91eb160` | 230 行 |

#### 3.1.1 关于 `HostSupervisorTests.swift` 的"修改前哈希"缺口

`baseline.log` 的源码哈希集只覆盖 8 个核心源文件，**未包含测试文件**，因此该文件的"修改前 SHA-256"没有被独立采集。这是一个明确的取证缺口，如实记录，不用推测值填充。

可以确定的是：本批次对该文件的改动只有两处，且都被 253 个 App 测试全绿交叉校验：

1. `private final class StubHostLauncher` → `final class StubHostLauncher`（供给 `HostRestartEntryTests` 复用同一套锁语义夹具，避免第二份"什么叫做 Host 持有锁"的假设）。
2. 在此之上补 3 行 `///` 注释说明"为什么不 private"。

### 3.2 逐文件变更（新增内容逐字摘录）

> 说明：`SoundBridgeApp.swift` 与 `MenuBarView.swift` 相对 HEAD 含有 P2/P3 前序批次的大量改动（`git diff --stat` 为 602 / 139 行），`git diff` 无法隔离本批次。因此本节给出的是**相对于 Batch 1.5 结束状态的净变更**，并以 §3.1 的"修改前后哈希 + 253 测试"作为完整性背书。

**(a) `Sources/Services/HostRestartEntry.swift`（新建 84 行）**

```swift
private let restartLog = Logger(subsystem: "com.soundbridge.app", category: "HostRestart")

enum HostRestartOutcome: Equatable, CustomStringConvertible {
    case requested
    /// The App is uninstalling: there is about to be no driver and no Host, so a
    /// replacement Host is the opposite of what the user asked for.
    case refusedUninstalling
    /// The App is terminating, or the supervisor has already been shut down.
    case refusedShuttingDown

    var description: String {
        switch self {
        case .requested: return "requested"
        case .refusedUninstalling: return "refused (uninstall in progress)"
        case .refusedShuttingDown: return "refused (app is shutting down)"
        }
    }
}

struct HostRestartEntry {
    private let supervisor: HostSupervisor
    private let isUninstalling: () -> Bool
    private let isTerminating: () -> Bool
    ...
    @discardableResult
    func request(forward: () -> Void) -> HostRestartOutcome {
        if isUninstalling() { restartLog.notice(…); return .refusedUninstalling }
        if isTerminating() { restartLog.notice(…); return .refusedShuttingDown }
        if supervisor.isShutDown { restartLog.notice(…); return .refusedShuttingDown }
        restartLog.notice("Host restart requested from the menu item")
        forward()
        return .requested
    }
}
```

设计要点：闸门是**类型**而不是散落在 `AppDelegate` 里的三个 `guard`，所以可以在没有 `NSApplication` 的测试进程里驱动；动作是**闭包**，所以菜单项必须落到 `AppDelegate.restartHost()` 这条既有路径上，不存在"另一条也调 `restart()`"的旁路。

**(b) `Sources/App/SoundBridgeApp.swift`（+26 / −2）**

```swift
/// Set for the whole of `applicationWillTerminate`. A restart accepted after
/// this point would be cancelled by the shutdown a few lines later, and the
/// user would see a Host disappear instead of being replaced.
private(set) var isTerminating = false
/// The policy in front of `restartHost()`. See `HostRestartEntry`.
private lazy var hostRestartEntry = HostRestartEntry(
    supervisor: hostSupervisor,
    isUninstalling: { [weak self] in self?.isUninstalling ?? true },
    isTerminating: { [weak self] in self?.isTerminating ?? true }
)
```

```swift
func applicationWillTerminate(_ notification: Notification) {
    isTerminating = true
    ...
```

```swift
/// Reached from the popover's "Restart Host" item through
/// `requestHostRestart()`; `HostSupervisorTests` drives the same call path.
func restartHost() {
    hostSupervisor.restart()
}

/// The user-facing entry: "Restart Host" in the menu bar popover.
///
/// Refused while uninstalling or terminating, where a replacement Host would
/// be undone immediately. Every other case is the supervisor's to judge, and
/// it coalesces a click that arrives while a stop is already in flight.
@discardableResult
func requestHostRestart() -> HostRestartOutcome {
    let outcome = hostRestartEntry.request { [weak self] in self?.restartHost() }
    print("[HostSupervisor] Restart Host item: \(outcome.description)")
    return outcome
}
```

**(c) `Sources/Views/MenuBarView.swift`（+86）**

```swift
// 5. Host-only restart. Below "Reconnect Audio" and deliberately its own row:
// that one rebuilds the audio path inside the running Host (same process,
// same session, same mapping); this one replaces the Host process, which is
// what publishes a new mapping.
RestartHostButton()
    .padding(.horizontal, 8)
    .padding(.vertical, 0)
```

```swift
struct RestartHostButton: View {
    @State private var isRequesting = false
    @State private var refusal: String?

    var body: some View {
        Button(action: restart) {
            HStack(spacing: 6) {
                if isRequesting { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12) }
                else { Image(systemName: "arrow.clockwise.circle")… }
                Text(isRequesting ? "Restarting Host…" : "Restart Host")…
                if let refusal { Text(refusal)… .foregroundColor(.orange) }
            }
            …
        }
        .buttonStyle(.plain)
        .disabled(isRequesting)
    }

    private func restart() {
        refusal = nil
        guard let appDelegate = NSApp.delegate as? AppDelegate else { refusal = "Unavailable"; return }
        let outcome = appDelegate.requestHostRestart()
        guard outcome == .requested else {
            switch outcome {
            case .refusedUninstalling: refusal = "Uninstalling"
            case .refusedShuttingDown: refusal = "Shutting down"
            case .requested: break
            }
            return
        }
        isRequesting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { isRequesting = false }
    }
}
```

**(d) `Sources/Services/HostSupervisor.swift`（+10）**

```swift
/// Whether ownership has been given up for good (`shutdown` was called).
///
/// `restart()` already ignores a request from this state; exposing it lets the
/// menu item answer "nothing will happen, and here is why" instead of looking
/// like a click that was swallowed. Read-only and non-blocking: it takes the
/// same serial queue every other state read takes.
var isShutDown: Bool {
    queue.sync { isShutdown }
}
```

**(e) `Tests/SoundBridgeAppTests/HostSupervisorTests.swift`（净 +6）**

```swift
/// A stub Host: a `Process` that never becomes a real one.
///
/// Not `private`: `HostRestartEntryTests` drives the same supervisor through the
/// menu item's gate, and a second copy of this fixture would be a second set of
/// assumptions about what "the Host holds the lock" means.
final class StubHostLauncher {
```

### 3.3 任务书 8 项测试要求 → 9 个用例

`Tests/SoundBridgeAppTests/HostRestartEntryTests.swift`（230 行）

| # | 任务书要求 | 用例 |
|---|---|---|
| 1 | 菜单项调用到 App 的 restart 入口 | `testTheMenuItemForwardsToTheAppsRestartEntry` |
| 2 | restart 请求确实到达 `HostSupervisor.restart()` | `testTheForwardedRequestReplacesTheHostThroughTheSupervisor` |
| 3 | 连续快速点击不产生多个 Host | `testFiveRapidClicksStillProduceOneReplacementHost` |
| 4 | App shutdown 期间拒绝 | `testATerminatingAppRefusesAndNeverForwards` + `testAShutDownSupervisorRefusesAndNeverForwards` |
| 5 | uninstall 期间拒绝 | `testUninstallRefusesEvenWhileTheSupervisorCouldStillRestart` |
| 6 | restart 失败时 App 仍存活 | `testAFailedReplacementEndsInDegradedAndTheAppSurvives` |
| 7 | 新 Host 启动失败按既有 degraded 策略处理 | 同上 + `testTheMenuItemLeavesDegradedWithAFreshBudget` |
| 8 | 旧 Host 尚未退出时不得启动新 Host | `testTheReplacementStartsOnlyAfterTheOldHostExited` |

夹具与 `HostSupervisorTests` 共用 `StubHostLauncher`（`/bin/sleep 30` + 三态锁语义 + `peakConcurrency` / `everStartedOverALiveHost`），测试进程内不启动 HAL、不触碰 `coreaudiod`、不播放音频。

### 3.4 边界（明确未做的事）

- 没有直接 `Process` 启动 Host；没有 `killall` / `pkill` / 手动 `SIGTERM`；没有绕过 `HostSupervisor`。
- 没有改动默认输出、没有新增 IPC 协议或 Driver 控制通道、没有新增诊断面板。
- `Reconnect Audio` 保持原样（进程内重建音频路径，不是进程重启）。

---

## 4. Batch 2 — 自动化回归

### 4.1 `make test`（`MAKE_TEST_EXIT=0`）

| 套件 | 数量 | 结果 |
|---|---|---|
| DSP（C++ / CTest） | 全通过（`make test` 输出 `100% tests passed`） | PASS |
| Driver / Host C++ 协议与服务测试 | 全通过 | PASS |
| `SoundBridgeHostTests` | **379 tests / 0 failures**（32.876 s） | PASS |
| `SoundBridgeAppTests` | **253 tests / 0 failures**（25.566 s），含新增 9 个 | PASS |
| installer transaction 测试 | 全通过 | PASS |
| `test_codesign_args` | **58 checks / 0 failures** | PASS |
| `check_protocol_layout` | 三份头文件一致，`131584` | PASS |
| `verify_version_consistency` | 11 个源 / 0 失败 | PASS |

原始记录：`make-test.log`。**没有为通过测试跳过任何断言，也没有修改任何无关测试。**

### 4.2 内存 / 线程检测器

```
swift test --sanitize=address --filter "HostRestartEntryTests|HostSupervisorTests"
→ Executed 25 tests, with 0 failures        ASAN_EXIT=0
swift test --sanitize=thread  --filter "HostRestartEntryTests|HostSupervisorTests"
→ Executed 25 tests, with 0 failures        TSAN_EXIT=0
```

25 = 新增 9（`HostRestartEntryTests`）+ 既有 16（`HostSupervisorTests`）。原始记录：`asan-host-restart.log`、`tsan-host-restart.log`。

---

## 5. Batch 3 — 隔离重建与安装

### 5.1 隔离目录

构建前逐一确认 `build/p3-host-restart-dist/` **不存在**后才创建；`dist/`、`build/p3-final-dist/`、`build/p3-dist/` 等历史目录全程未读写。

### 5.2 构建步骤与退出码

| 步骤 | 命令 | 结果 |
|---|---|---|
| universal release build | `SB_DIST_DIR=build/p3-host-restart-dist ./tools/build_release.sh` | `BUILD_EXIT=0` |
| ad-hoc 签名 | `SB_APP_BUNDLE=… ./tools/codesign.sh --adhoc` | `SIGN_EXIT=0`，109 文件，`x86_64 arm64` |
| PKG | `./tools/build_installer_pkg.sh --app … --out … --version 1.2.0` | `PKG_EXIT=0` |
| DMG | `SB_DIST_DIR=… APP_BUNDLE=… ./tools/create_dmg.sh` | `DMG_EXIT=0`（`hdiutil` 后端） |

日志：`build-release.log`、`codesign.log`、`pkg-build.log`、`dmg-build.log`。

### 5.3 产物 SHA-256

| 产物 | SHA-256 | 大小 |
|---|---|---|
| `SoundBridge-1.2.0.pkg` | `132bb64db94915e6b43a6fd3bd43b4ba9bb43105d511e07511fef8efdec5f032` | 14 362 174 B |
| `SoundBridge-1.2.0.dmg` | `bf097bb05bffeebed4306db49876640667f6d8bd878c617fdc697129e6dfd947` | 15 212 979 B |
| `SoundBridgeApp` | `07030fa8d5ebddda9dc5280cecdcc94a0c3d323418ed43ee1389c4f9c5642c8d`（**变**） | — |
| `SoundBridgeHost` | `d8d1249627cd26bf986a365d1570d7cac433a4d5888002c039ec52d357642aae`（**未变**） | — |
| `SoundBridgeDriver` | `c295503019a0712649030c16a7f583569dea6e96d8a10ae6ec3d57af2f3e24a0`（**未变**） | — |

**Driver 二进制没有发生变化**，且与 HAL 安装副本、App 内嵌副本、PKG payload 四处一致（`DRIVER_FOUR_WAY=true`）。Host 二进制也未变 —— 本批次的源码改动只影响 App 产物。

### 5.4 逐文件一致性（109 行清单两两 diff）

| 对比 | 结果 |
|---|---|
| 构建产物 bundle ⟷ PKG payload 内 App | **IDENTICAL**（109/109） |
| 构建产物 bundle ⟷ DMG 挂载后的 App | **IDENTICAL**（109/109） |
| 安装后 `/Applications/SoundBridge.app` ⟷ 构建产物 | **IDENTICAL_109** |
| 安装前已装 App ⟷ 安装后 App | 仅第 87 行不同（`Contents/MacOS/SoundBridgeApp`：`3671854c…` → `07030fa8…`） |

原始清单：`app-manifest.txt`、`pkg-payload-app-manifest.txt`、`dmg-app-manifest.txt`、`installed-app-manifest-preinstall.txt`、`installed-app-manifest-postinstall.txt`；比对：`three-way-manifest-diff.log`、`post-install-verify.log`。

### 5.5 独立校验器

| 校验器 | 结果 |
|---|---|
| `verify_release_payload.sh` | `OVERALL_RESULT=PASS`（PKG_STRUCTURE / DRIVER_CONSISTENCY / **DRIVER_FOUR_WAY=true** / ARCHITECTURE / DMG_STRUCTURE / VERSION_CONSISTENCY / ARTIFACT_INTEGRITY 全 PASS） |
| `verify_installer_pkg.sh` | `PASS`（含 `the payload does not write into the HAL directory`、`the transaction script is byte-identical to the tested source`） |
| `check_protocol_layout.sh` | 三份头文件一致，`131584`（Driver plist `SBAudioProtocolVersion=131584`） |
| `verify_version_consistency.sh` | `VERSION_SOURCES_CHECKED=11`、`FAILED=0`、`PASS` |

原始记录：`verify-release-payload.log`、`verifiers.log`。

### 5.6 安装（管理员授权，未绕过）

安装前先正常退出旧实例，**没有使用 kill**：

```
$ osascript -e 'tell application id "com.soundbridge.menubar" to quit'   → QUIT_EXIT=0
$ osascript … do shell script "/usr/sbin/installer -pkg …/SoundBridge-1.2.0.pkg \
    -target / -verboseR" with administrator privileges                      → INSTALL_EXIT=0
```

`installer: The upgrade was successful.` 原始记录：`preinstall-state.log`、`installer-run.log`。

### 5.7 安装事务日志（该次运行）

来源：`/Library/Application Support/SoundBridge/InstallerState/log/install-20261121-152912-95899.log`

```
[15:29:12][INIT]      transaction-95890.sh starting (mode=install dest=/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver)
[15:29:12][INIT]      install lock acquired: …/InstallerState/transaction.lock
[15:29:12][RECOVER]   no transaction in progress
[15:29:12][PRECHECK]  payload manifest: id=com.soundbridge.driver version=1.2.0 protocol=131584 architectures='x86_64 arm64'
[15:29:12][PRECHECK]  reinstall: 1.2.0 is already installed; replacing it with a fresh copy (same version)
[15:29:13][BACKUP_OLD] existing driver backed up and verified at …/InstallerState/backup/SoundBridgeDriver.driver
[15:29:13][REPLACING] existing driver moved aside (rename)
[15:29:13][REPLACING] new driver moved into place (rename)
[15:29:13][VERIFYING] installed driver: structure, identity, version, protocol and architectures verified
[15:29:13][SUCCESS]   SUCCESS: driver 1.2.0 (protocol 131584) is installed at …
```

成功分支清理了 `backup/`，`InstallerState/` 下只剩 `log/`。原始记录：`installer-transaction.log`、`install-log-tail.log`。

### 5.8 安装后核验

| 项 | 值 | 判定 |
|---|---|---|
| App 文件数 | 109 | 与构建产物一致 |
| `SoundBridgeApp` | `07030fa8…c5642c8d` | 一致（新代码） |
| `SoundBridgeHost` | `d8d12496…57642aae` | 一致（未变） |
| HAL `SoundBridgeDriver` | `c2955030…f2f3e24a0` | 一致（未变） |
| App 内嵌 Driver | `c2955030…f2f3e24a0` | 与 HAL 内一致 |
| App / Driver 版本 | 1.2.0 / 1.2.0 | OK |
| Driver bundle id / 协议 | `com.soundbridge.driver` / `131584` | OK |
| 架构 | `x86_64 arm64`（universal，App 与 Driver） | OK |
| `codesign --verify --strict` | `valid on disk` + `satisfies its Designated Requirement` | OK |
| 签名形态 | `Signature=adhoc`、`flags=0x2(adhoc)`、`TeamIdentifier=not set` | 与发布策略一致 |
| 用户数据 | `~/Library/Application Support/SoundBridge/{device-state.json, volume-state.json}` 保留；`UserDefaults` 6 键完好 | 未被清理 |
| CoreAudio | **未重启**（`coreaudiod` 仍 598，`lstart = Fri Nov 20 21:54:28`）；未重载/卸载 Driver | OK |

原始记录：`post-install-verify.log`、`batch6-final-state.log`。

---

## 6. Batch 4 — 真实 Host-only restart（UI 触发）

### 6.1 触发方式：为什么不是 AppleScript / AX

`NSStatusItem` **不在 Accessibility 树中**，这一点在本批次先被验证、后被绕过：

```
osascript … get UI elements enabled   → true          （可脚本化）
System Events → SoundBridgeApp: MENU_BARS=1，只有 "Apple" / "SoundBridge" 两个 AXMenuBarItem；windows=0
AXUIElementCreateApplication(106) 的树：只含 1 个 AXMenuBar
SystemUIServer: SUI_MENU_BARS=0                       （状态栏项不在 SystemUIServer 的 AX 树里）
```

因此没有任何 `AXPress` 可以指向状态栏图标。采用的路径是：`screencapture` 截图 → 人工定位坐标 → `CGEvent`（`mouseMoved` → `leftMouseDown` → `leftMouseUp`）点击，**每一次点击都用截图回读确认结果**。点击工具：`build/p3-host-restart-verify/tools/clicker.swift`（编译产物 `clicker`），只发鼠标事件，不发送任何 AppleEvent、不调用 App 内部 API、不注入代码。

坐标：状态栏图标中心 ≈ `(1931, 15)`（主屏 CG bounds `(0,0,2560,1440)`，菜单栏 30 pt）；点击后 popover 内 `Restart Host` 行 ≈ `(1953, 276)`。

### 6.2 UI 证据

| 截图 | 内容 |
|---|---|
| `menubar-fullwidth.png`（5120×80） | 状态栏图标外形：圆角方框 + 中心实心圆 + 底部两个小方块（与 `soundbridge-menu.svg` 一致） |
| `popover-open.png` | popover 打开，`Restart Host` 作为**独立一行**出现在 `Reconnect Audio` 之下 |
| `popover-after-click.png` | 点击后同一行变为 **"Restarting Host…" + spinner**，顶部状态区显示 **"Audio host is stopping…"** |
| `desktop-after-restart.png` | 关闭 popover 后的桌面；App 仍在菜单栏 |

`popover-after-click.png` 是"用户确实点到了新入口、且 App 进入了 stopping 语义"的直接视觉证据。

### 6.3 权威时间线（`log show --info --debug`，process `SoundBridgeApp[106]`）

```
15:33:41.557  Df [HostRestart]     Host restart requested from the menu item
15:33:41.557  I  [HostSupervisor]  Host supervisor state: stopping(host-only restart)
15:33:42.773  Df [SharedMemoryMappingManager] munmap generation=1 inode=69959464 inline=true executor=16fd1b000 duration_us=66
15:33:42.773  Df [SharedMemoryMappingManager] Retired the active mapping: the shared-memory file is gone
15:33:42.777  I  [HostSupervisor]  Host pid 108 exited (status 0, reason 1) intent=host-only restart
15:33:42.777  I  [HostSupervisor]  Host supervisor state: idle
15:33:42.778  I  [HostSupervisor]  Host supervisor state: launching(attempt: 0)
15:33:42.780  I  [HostSupervisor]  Launched Host pid 10612 (launch #2)
15:33:49.379  I  [HostSupervisor]  Host supervisor state: running(pid: 10612)
```

（同一事件在 Host 侧：旧 Host `108` 最后一条日志 `15:33:41.567 AUHAL.cpp:899 SelectDevice`（有序 teardown 收尾）；新 Host `10612` 首条 SoundBridge 日志 `15:33:42.864`。）

**为什么 `running` 迟 6.6 秒：这是设计而非延迟故障。** `HostSupervisor` 在 `Launched Host` 之后并不立即宣称成功，而是排一个 `launchTimeout = 6.0 s` 的 watchdog；watchdog 触发时若进程存活**且**锁探测通过，才 `transition(to: .running(pid:))`，否则把"活着但没拿到锁"的进程终止。所以 `42.780 + 6.0 = 48.78`，实测 `49.379`，差值 0.6 s 是串行队列的调度延迟。新 Host 实际拿锁时间见 lock 文件 `since=2026-11-21T07:33:42Z`（与旧 Host 退出同一秒）。

原始记录：`batch4-app-supervisor-logs.log`、`batch4-restart-logs.log`、`batch4-host-lifecycle.log`。

### 6.4 PID 时间线

| 本地时间 | 事件 | 证据 |
|---|---|---|
| 15:29:58 | App 启动 → PID **106**；随后 Host launch #1 → PID **108** | `ps lstart`、`batch4-t0-baseline.log` |
| 15:30:18 | T0 基线采集（未打开 popover；新 Mapping `69959464` 已 `eq_sequence=2`） | `batch4-t0-mapping.json` |
| ~15:32:20 | 首次打开 popover（仅为定位 `Restart Host` 行坐标） | `popover-open.png` |
| 15:33:41.557 | 点击 `Restart Host` → `stopping(host-only restart)` | `batch4-app-supervisor-logs.log` |
| 15:33:42.773 | 旧 Mapping 被 App munmap 并退休（inode `69959464`） | 同上 |
| 15:33:42.777 | 旧 Host **108** 退出（status 0，reason 1，intent=host-only restart） | 同上 |
| 15:33:42.778 | `launching(attempt: 0)` | 同上 |
| 15:33:42.780 | 新 Host **10612** 启动（launch #2，ppid=106） | 同上 + `ps` |
| 15:33:42.864 | 新 Host 首条 SoundBridge 日志 | `batch4-host-lifecycle.log` |
| 15:33:42.870 | `Proxy route resolved: physical=1E6D4678-… proxy=139 defaultOutputIsProxy=false` | 同上 |
| 15:33:49.379 | `running(pid: 10612)`（watchdog 通过） | `batch4-app-supervisor-logs.log` |
| 15:35:36 | T1 采集 | `batch4-t1-after.log` |
| 07:38:17Z–07:45:08Z | Batch 5 采样 360 次 | `batch5-stability-timeline.log` |
| 15:46:30 | 日志窗口终点 | `batch5-window-logs.log` |

**App PID 106 从 15:29:58 到 15:48 全程不变。** 新 Host 的 ppid 为 `106`，即由存活的原 App 进程拉起。

### 6.5 Mapping incarnation 前后对照

| 维度 | T0（旧 Host 108） | T1（新 Host 10612） | 结论 |
|---|---|---|---|
| Mapping 文件 inode | `69959464`（+ 副设备 `69959467`） | `69959980`（+ 副设备 `69959981`） | **不同** |
| 旧 inode 文件是否仍存在 | — | `ls /tmp/soundbridge-501-*` 只剩 `69959980/69959981` | **旧文件已消失** |
| `host_session`（mapping 内） | `e74637202c1042d18dc9c477f91b53f9` | `22853f43ab644e70b579db8883acecda` | **不同** |
| `admission_epoch` | `14888177568760912123` | `6317647779157323345` | **不同** |
| `admission_state` | `1` | `1` | 正常打开 |
| Host lock 文件 | `pid=108 … session=E7463720-2C10-42D1-8DC9-C477F91B53F9` | `pid=10612 … since=2026-11-21T07:33:42Z session=22853F43-AB64-4E70-B579-DB8883ACECDA` | **指向新 PID / 新 session** |
| 控制文件 | `#SB-CONTROL 1 E7463720-… 3 501 2` | `#SB-CONTROL 1 22853F43-… 4 501 2` | generation 3 → 4，session 更新 |
| `protocol_version` | `0x20200` | `0x20200` | 未变（协议未动） |
| `header_size` / `ring_capacity_frames` / `sample_rate` | 320 / 8192 / 48000 | 320 / 8192 / 48000 | 未变 |

**"旧 Mapping 不再接受写入"的证据链**：App 侧先 `munmap generation=1 inode=69959464` 并记录 `Retired the active mapping: the shared-memory file is gone`；随后旧 inode 的两个文件在 `/tmp` 中已不存在；1 Hz 采样从 `[13]`（旧 inode）到 `[14]`（新 inode）完成切换，此后 360 次采样读到的始终是新 inode。App 的 `SharedMemoryMappingManager` 已重新 map 新文件（采样值随新文件推进即证明写读都在新 inode 上）。

### 6.6 EQ 自动恢复证据

**持久化输入（`UserDefaults com.soundbridge.menubar`）**：
`eq_default_bass_db = 0.02278646`、`eq_default_mids_db = 12`、`eq_default_treble_db = 0`、`eq_default_enabled = 0`。

**独立推导（`EQController.computeBandGains` 的权重表：bass→band 0/1/2 = ×0.5/×1.0/×1.5；mids→band 4/5 = ×0.6/×1.2；treble→band 8/9 = ×0.4/×1.3；band 3/6/7 未使用、恒为 0）**：

| band | 权重 | 计算 | 期望值 | 新 Mapping 实测 |
|---|---|---|---|---|
| 0 | bass × 0.5 | 0.02278646 × 0.5 | 0.011393 | **0.011393** |
| 1 | bass × 1.0 | 0.02278646 | 0.022786 | **0.022786** |
| 2 | bass × 1.5 | 0.02278646 × 1.5 | 0.034180 | **0.034180** |
| 3 / 6 / 7 | 未使用 | — | 0.0 | **0.0** |
| 4 | mids × 0.6 | 12 × 0.6 | 7.2 | **7.2** |
| 5 | mids × 1.2 | 12 × 1.2 | 14.4 | **14.400001** |
| 8 / 9 | treble × 0.4 / × 1.3 | 0 × … | 0.0 | **0.0** |

`eq_preamp = 0.0`；`eq_bypass = 1` ↔ `eq_default_enabled = 0`（enabled=0 即 bypass）。**bands 与独立计算结果逐位一致（float32 舍入内）。**

**恢复时序**：新 Mapping 文件在 `15:33:42.x` 出现，1 Hz 采样 `[14]`（`07:33:43Z`）已经读到 `eq_seq=2 bypass=1 bands=…` —— 即新 Host 启动后约 1 秒内、**在 supervisor 报告 `running(pid:)`（`15:33:49.379`）之前**，EQ 已经落在新 Mapping 上。这排除了"某个 UI 因为看到 `running` 才去写"的解释：写入是由 Mapping 发布触发的，不是由状态迁移触发的。

**没有重复写入**：从 `07:33:43Z` 到 `07:45:08Z`（约 11.4 分钟）`eq_sequence` 恒为 `2`（偶数为 SeqLock 稳态），bands / bypass 全程唯一值 —— 写入者只重放了一次，没有视图或定时器反复重写。

原始记录：`batch4-t0-mapping.json`、`batch4-t1-mapping.json`、`batch5-t20-mapping-default.json`、`batch5-t40-mapping-default.json`、`batch5-stability-timeline.log`。

### 6.7 任务书 §7 的 20 项验证

| # | 验证项 | 结果 | 证据 |
|---|---|---|---|
| 1 | App PID 前后相同 | **PASS** | `106` → `106`；411 秒内 360 次采样恒为 `106` |
| 2 | 旧 Host PID 完全退出 | **PASS** | `ps -p 108` 为空；日志 `Host pid 108 exited (status 0, reason 1)` |
| 3 | 新 Host PID 与旧不同 | **PASS** | `108` → `10612` |
| 4 | 任意时刻最多一个 Host | **PASS** | 1 Hz × 360 次 `host_count=1`；`pgrep -f` 单值 |
| 5 | 旧 Host 退出后才启动新 Host | **PASS** | 退出 `42.777` < 启动 `42.780`；`host_count` 从未出现 2 |
| 6 | lock 文件对应新 PID / session | **PASS** | `pid=10612 … session=22853F43-…` |
| 7 | 新 Mapping inode 与旧不同 | **PASS** | `69959464` → `69959980` |
| 8 | 新 session 与旧不同 | **PASS** | `e7463720…` → `22853f43…` |
| 9 | 新 admission_epoch 与旧不同 | **PASS** | `14888177568760912123` → `6317647779157323345` |
| 10 | 旧 Mapping 不再接受写入 | **PASS** | App `munmap generation=1 inode=69959464` + `Retired the active mapping`；旧 inode 文件已不存在；此后采样只读到新 inode |
| 11 | 新 Host heartbeat 正常 | **PASS** | `hb` 275 → 686 / 411 s = **1.000 Hz**，无停滞 |
| 12 | admission_state 正常打开 | **PASS** | 恒为 `1` |
| 13 | EQService 自动重放持久化 EQ | **PASS** | 新 Mapping 在 1 s 内出现 `eq_sequence=2` + 正确 bands |
| 14 | 新 Mapping `eq_sequence > 0` | **PASS** | `2` |
| 15 | bypass 与 UserDefaults 一致 | **PASS** | `eq_bypass=1` ↔ `eq_default_enabled=0` |
| 16 | bands 与独立计算结果一致 | **PASS** | 见 §6.6 逐 band 对照，全部吻合 |
| 17 | 不打开 Popover 也能完成 EQ 恢复 | **PASS（机制）/ NOT SEPARATELY OBSERVED（本轮 UI 打开）** | 见 §6.8 |
| 18 | 默认输出 UID 不变 | **PASS** | `1E6D4678-…` 前后一致；11 次快照全同 |
| 19 | coreaudiod PID 不变 | **PASS** | `598`，`lstart` 仍为 Nov 20 21:54:28 |
| 20 | Driver 插件 PID 不变 | **PASS** | `628`，`lstart` 仍为 Nov 20 21:54:28 |

### 6.8 关于第 17 项的证据分层（必须如实标注）

**不能把这一项标成本轮的 `REAL_MACOS_VERIFIED`**，理由是结构性的：本批次唯一的正式入口就在 popover 里，触发 restart 必然要打开 popover。

本轮**能**证实的是"恢复本身不依赖视图"：

1. `EQService.shared.controller` 在 `AppDelegate` 属性初始化时创建，早于 `SharedMemoryMappingManager.shared.start()`，也早于任何 View（STATICALLY_REVIEWED）。
2. 时间上，EQ 落在新 Mapping 的时刻（`07:33:43Z`）**早于** supervisor 的 `running(pid:)`（`15:33:49.379`），中间没有任何用户交互（RUNTIME_OBSERVED）。
3. T0 基线（`07:30:18Z`，popover 尚未首次打开）已经显示 `eq_sequence=2` —— **App 启动阶段的 EQ 自动应用确实在 popover 从未打开的情况下发生**（RUNTIME_OBSERVED，且与上一批次 Batch C 的结论一致）。

本轮**不能**单独观测的只是"restart 发生时 popover 处于关闭状态"这一组合。它需要一个不在 popover 内的入口（键盘快捷键 / 通知 / URL scheme），而任务书 §4 明确禁止为此新增通道。因此该项标注为 **PASS（机制已证）+ NOT SEPARATELY OBSERVED（该组合未单独观测）**，不上升为 REAL_MACOS_VERIFIED。

---

## 7. Batch 5 — 稳定性观察

### 7.1 方法

只读采样器 `build/p3-host-restart-verify/tools/batch5_sampler.sh`：**360 次采样、间隔 1 s、跨度 411 s（6 分 51 秒，≥ 任务书要求的 5 分钟）**，窗口 `2026-11-21T07:38:17Z` → `07:45:08Z`。

脚本只做 `pgrep` / `stat` / 只读 `mmap` / CoreAudio 属性读取，不写任何文件、不发任何通知、不打开任何 UI。合计在 restart 之后已连续观测约 **12 分 26 秒**（`07:33:41` → `07:46:07`）。

> **采集器缺陷（如实记录）**：主时间线的 `default_output=` 列为 `unavailable`，原因是 `ca_snapshot` 输出是 `KEY=VALUE` 而非 JSON，采样器里的解析器写错了。**该列不可用作证据**；默认输出改用独立观察器 `batch5-default-output-watch.log`（30 s × 11 次，见 §7.2）。主时间线的 PID / inode / lock / EQ / heartbeat / underrun 字段解析正确，不受影响。

### 7.2 常量项（360/360 采样完全单值）

| 项 | 值 |
|---|---|
| App PID | `106`（唯一值） |
| Host PID | `10612`（唯一值，`host_count` 恒为 `1`） |
| coreaudiod PID | `598` |
| Driver 插件进程 | `628` |
| Mapping inode | `69959980` |
| `host_session` | `22853f43ab644e70b579db8883acecda` |
| `admission_epoch` | `6317647779157323345` |
| `admission_state` | `1` |
| **`eq_sequence`** | **`2`（唯一值）** |
| **`eq_bypass`** | **`1`** |
| `overrun_count` | `0` |
| `total_frames_written` / `read` | `4096` / `4096`（无音频客户端，符合预期） |
| 默认输出（11 次快照） | `ID=109` / `UID=1E6D4678-0000-0000-0424-0104C5462778` / `NAME=LG ULTRAGEAR+` / `DEVICE_COUNT=7`（全部相同） |

### 7.3 推进项

| 项 | 起点 → 终点 | 速率 | 解释 |
|---|---|---|---|
| `host_heartbeat` | `275` → `686` | +411 / 411 s = **1.000 Hz** | 心跳稳定，无卡顿 |
| `underrun_count` | `25 746` → `64 248` | +38 502 / 411 s ≈ **93.68 /s** | 见 §7.4 |

### 7.4 underrun 的性质判定：静音态 underflow，不是播放窗口 underrun

三条独立证据：

1. **每次 underrun 恰好一个 512 帧缓冲区**：窗口内末态 `underrun_frames = 34 709 504`、`underrun_count = 67 792` ⇒ `34 709 504 / 67 792 = 512.000`。实现上 `rf_read_frames` 每遇到"没有可读数据"就 `underrun_count += 1`、`underrun_frames += 请求帧数`。
2. **速率与回调速率完全吻合**：512 帧 @ 48 kHz ⇒ 93.75 次/秒 ⇒ 468.75 次/5 s；日志里每 5 秒打印的正是 `+468` / `+469`（`15:37:01.863 total: 18643` → `15:46:06.863 total: 69736`，545 s 内 +51 093 = 93.75/s）。
3. **Host 渲染全是静音**：窗口末条 `Callback timing: n=69393 … silence=69385`（**99.988% 的缓冲区是静音**），且 `driver_connected = 0`（无任何 App 占用 Proxy）、`total_frames_read` 停在 `4096`。

因此本项**不构成音频质量失败**，只说明"当前没有音频在被桥接"。真实播放窗口的 underrun 需要在有人向 Proxy 播放时测量，而这依赖 §9 的授权前提。

### 7.5 日志窗口分析（`15:37:00` → `15:46:30`，673 行）

| 模式 | 计数 | 判定 |
|---|---|---|
| `⚠️ Buffer underrun`（Error 级） | **110**（全部是 5 s 遥测，`+468`/`+469`） | 静音态 underflow，见 §7.4 |
| 其它 Error / Fault 级 | **0** | — |
| `Retired the active mapping` | **0** | 窗口内无第二次 retirement |
| `detach` / `disconnect` | **0** | 无 detach |
| `reconnect` / `bounce` | **0** | 未触发进程内重连 |
| `holdsMapping=false` | **0** | 全程 `holdsMapping=true` |
| `retireTimeouts` 非 0 | **0**（唯一值 `retireTimeouts=0`） | 无 retirement 超时 |
| `overBudget` 非 0 | **0**（唯一值 `overBudget=0`） | RT 回调无超预算 |
| `Render path` 采样 | `inFlight=0 deferred=false holdsMapping=true` 全程 | 渲染路径健康 |
| `Callback timing` p50 / p99 / max | `6 µs` / `22 µs` / `288 µs` | 远低于 512 帧（10.67 ms）预算 |

原始记录：`batch5-window-logs.log`、`batch5-stability-timeline.log`、`batch5-default-output-watch.log`。

### 7.6 任务书 §8 的确认项

| # | 确认项 | 结果 | 证据 |
|---|---|---|---|
| 1 | App / Host / coreaudiod PID 恒定 | **PASS** | `106` / `10612` / `598`，360 次单值 |
| 2 | Host 实例数量 | **PASS** | `host_count=1` × 360 |
| 3 | Mapping inode / session / epoch 恒定 | **PASS** | 单值 |
| 4 | EQ sequence / bypass / bands 恒定 | **PASS** | `2` / `1` / 唯一 bands 向量 |
| 5 | heartbeat 正常 | **PASS** | 1.000 Hz |
| 6 | overrun / underrun | **PASS（静音态）** | `overrun=0`；underrun 全部为 512 帧静音态 underflow |
| 7 | detach / reconnect | **PASS** | 计数 0 |
| 8 | crash / fatal 日志 | **PASS** | 窗口内 0 条 Error/Fault（除 underrun 遥测）；`~/Library/Logs/DiagnosticReports` 无任何 SoundBridge `.ips` |
| 9 | 默认输出变化 | **PASS** | 11/11 快照完全相同，`DEVICE_COUNT=7` 恒定 |
| 10 | 是否可宣称音频质量通过 | **不允许** | 无音频客户端，全部 underrun 为静音态 underflow |

> **崩溃报告说明**：`~/Library/Logs/DiagnosticReports/` 中最新的 SoundBridge 相关文件仍是 `soundbridge_dsp_tests-2026-11-20-160154.ips`（测试二进制的旧报告，与本批次无关）。同目录下的 `screencapture-2026-11-21-151519.ips`（15:15）是**验证工具自身**在沙箱内调用 `screencapture` 失败产生的，不是 SoundBridge 进程，也不在本批次的观察窗口内。如实记录，避免被误读为应用崩溃。

---

## 8. 默认输出 / CoreAudio / Driver 前后对照

| 维度 | T0（restart 前） | 窗口内（11 次） | T1 / 结束 | 判定 |
|---|---|---|---|---|
| 默认输出 ID | `109` | `109` | `109` | 未变 |
| 默认输出 UID | `1E6D4678-0000-0000-0424-0104C5462778` | 相同 | 相同 | 未变 |
| 默认输出名称 | `LG ULTRAGEAR+` | 相同 | 相同 | 未变 |
| `DEVICE_COUNT` | `7` | `7` | `7` | 未变 |
| Proxy 设备 | `139` = `1E6D4678-…-soundbridge` | 同 | 同 | 未被设为默认 |
| `coreaudiod` PID / lstart | `598` / Nov 20 21:54:28 | `598` | `598` / Nov 20 21:54:28 | **未重启** |
| Driver 插件 PID / lstart | `628` / Nov 20 21:54:28 | `628` | `628` / Nov 20 21:54:28 | **未重载** |
| Driver 二进制 | `c2955030…f2f3e24a0` | — | `c2955030…f2f3e24a0` | **未变** |

Host 侧日志也独立确认了这一点：新 Host 启动后 `Proxy route resolved: physical=1E6D4678-… proxy=139 defaultOutputIsProxy=false`。

**本批次没有**切换系统默认输出、**没有**修改多输出设备、**没有**改动任何应用输出路由、**没有**重启 `coreaudiod`、**没有**卸载或重载 Driver。

原始记录：`batch4-t0-coreaudio.log`、`batch4-t1-coreaudio.log`、`batch5-t20-coreaudio.json`、`batch5-t40-coreaudio.log`、`batch5-default-output-watch.log`。

---

## 9. 实际 EQ 声音验证 — `NOT RUN / BLOCKED`

`defaultOutputIsProxy=false` 且默认输出为物理设备 `LG ULTRAGEAR+`。按任务书 §9：

- 不切换默认输出；
- 不修改多输出设备；
- 不改应用输出路由；
- **实际 EQ 听感验证标记为 `NOT RUN / BLOCKED`**。

不给任何"听起来有变化"的主观断言，也不把 `eq_sequence=2` 与 bands 正确说成"听感已验证" —— 它只证明**参数已写入**新 Host 的输出 mapping。

客观声音比对在本机不可行的技术与上一批次报告 §6.3 相同：要让声音真正经过 EQ，必须有客户端把输出指向 Proxy；即便只改单个 App 的输出设备，EQ 之后的声音也只存在于物理 LG 的模拟输出，软件侧不可回环捕获；而 shared memory 里的样本是 **EQ 之前**的数据（Driver 侧写入），读 ring 无法证明 EQ 生效。

---

## 10. 证据等级总表

| 结论 | 等级 | 依据 |
|---|---|---|
| `restart()` 单飞、reap-before-relaunch、`shutdown` 早退 | **STATICALLY_REVIEWED** + **UNIT_TESTED** | §2 审计 + `HostSupervisorTests` 16 用例 + 新增 9 用例 |
| 入口闸门拒绝 uninstall / terminating / shutdown | **UNIT_TESTED** | 5 个拒绝类用例 |
| 连点不产生第二个 Host | **UNIT_TESTED** + **REAL_MACOS_VERIFIED** | `testFiveRapidClicksStillProduceOneReplacementHost`；真机 `host_count=1` × 360 |
| 旧 Host 未退出不得启动新 Host | **UNIT_TESTED** + **REAL_MACOS_VERIFIED** | `testTheReplacementStartsOnlyAfterTheOldHostExited`；日志 42.777 < 42.780 |
| 菜单项 → `AppDelegate.restartHost()` → `HostSupervisor.restart()` | **REAL_MACOS_VERIFIED** | 点击后的 `[HostRestart]` + `stopping(host-only restart)` 日志与截图 |
| App 存活、PID 不变 | **REAL_MACOS_VERIFIED** | `106` 恒为 `106` |
| 新 Mapping（inode / session / epoch） | **REAL_MACOS_VERIFIED** | §6.5 对照表 |
| EQ 自动重放 | **REAL_MACOS_VERIFIED** | §6.6（新 Mapping 1 s 内 `eq_sequence=2`，早于 `running`） |
| EQ 恢复不依赖 popover 视图 | **STATICALLY_REVIEWED** + **RUNTIME_OBSERVED** | §6.8（含上一批次 Batch C 的运行时证据） |
| restart 时 popover 关闭的变体 | **NOT SEPARATELY OBSERVED** | 唯一入口在 popover 内；未获授权新增通道 |
| 5 分钟稳定性 | **REAL_MACOS_VERIFIED** | 360 次采样 / 411 s |
| 静音态 underflow（非播放窗口 underrun） | **RUNTIME_OBSERVED**（算术 + 日志） | §7.4 |
| 默认输出 / coreaudiod / Driver 未变 | **REAL_MACOS_VERIFIED** | §8 |
| 实际 EQ 听感 | **NOT RUN / BLOCKED** | §9 |

---

## 11. 未完成项与明确缺口

1. **实际 EQ 听感（§9）** — `NOT RUN / BLOCKED`。需要一次默认输出切换授权，或一个可回环捕获的验证拓扑。
2. **播放窗口内的 underrun / 音频中断** — `NOT RUN`。同上，需音频客户端真正向 Proxy 播放。
3. **"restart 时 popover 从未打开"的组合** — `NOT SEPARATELY OBSERVED`。需要 popover 之外的正式入口（键盘快捷键 / 通知 / URL scheme），本批次按 §4 禁止新增。
4. **取证缺口（不影响结论）** — `HostSupervisorTests.swift` 的"修改前 SHA-256"未被 `baseline.log` 采集；该文件本批次只有"去掉 `private` + 3 行注释"两处改动，253 个 App 测试与 25 个 ASan/TSan 用例可作交叉校验。
5. **采集器缺陷（已在 §7.1 声明）** — 主时间线的 `default_output` 列因解析器写错而为 `unavailable`；该维度的证据改由独立的 11 次 CoreAudio 快照提供，不影响 PID / Mapping / EQ 结论。

没有其它未完成项。**本批次没有为了通过验证而使用任何替代手段**：没有 kill、没有 killall/pkill、没有手动 SIGTERM、没有改默认输出、没有重启 coreaudiod、没有卸载/重载 Driver、没有绕过 supervisor、没有新增第二条启动 Host 的路径。

---

## 12. 结论

**`PASS`**

上一批次的唯一阻塞项 —— "`restartHost()` 没有正式入口" —— 已以最小改动关闭：一个 `Restart Host` 菜单项 + 一个可测试的入口闸门 + 一个只读状态出口，共 6 个文件（4 改 2 新），没有触碰状态机、线程模型、协议、版本、ABI、Driver 或 DSP。

真机验证已完成：一次由 UI 点击触发的 Host-only restart，App PID 不变、旧 Host 完全退出、新 Host 单实例、新 Mapping 以新 inode / 新 session / 新 epoch 发布、EQ 在 1 秒内自动重放且此后不再自增、随后 411 秒全部指标恒定、默认输出与 CoreAudio 与 Driver 全程未动。

**明确保留的两个缺口**：实际 EQ 听感（`NOT RUN / BLOCKED`，等授权）与"restart 时 popover 关闭"的变体（`NOT SEPARATELY OBSERVED`，受入口位置限制）。这两项都有清晰的成因与可执行的授权/设计路径，不是失败，也没有用替代手段掩盖。

至此，SoundBridge 1.2.0 的 **Host 生命周期**与 **EQ Mapping 恢复**验证可以正式关闭。实际 EQ 听感仍单独记录，等待另行授权。

---

## 13. 停止确认

- 未提交 Git（`git status` 全部留在工作区，`staged = 0`；本批次未执行任何 Git 写操作）：批次开始 122 条 → 代码改动后 124 条（+2 新增源文件/测试）→ 写入本报告后 125 条。
- 未创建 tag，未发布 GitHub Release，未推送任何分支。
- 未继续开展其它架构重构或新功能开发。
- 未删除或覆盖任何历史报告 / 历史产物（`docs/P3-Final-*`、`build/p3-final-*`、`dist/` 全部保持原状）。
- 证据目录：`build/p3-host-restart-verify/evidence/`（40+ 份原始日志与快照）；产物目录：`build/p3-host-restart-dist/`。
