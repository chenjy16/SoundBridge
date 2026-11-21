# P2 Batch 2 — Default Output Governance 执行报告

- 项目：SoundBridge 1.2.0
- 阶段：P2 产品集成与缺陷修复 / Batch 2
- 仓库：`/path/to/SoundBridge`
- 执行日期：2026-11-20
- 结论：**PASS**（详见 §17 完成条件逐项核对）
- 证据分级见 §18。本批次**没有**对真实 macOS 默认输出做过任何写入，所有"不写入"结论均为自动化验证 + 静态审查，真实系统行为仍需 P3 验证。

---

## 0. 一句话摘要

SoundBridge 在自动生命周期中修改 macOS 默认输出的**全部**代码路径（Host 启动 / 重连 / 崩溃恢复 / 设备回调 / 关闭 / App 退出）已删除，Host 侧现在只剩一个**无人调用**的 HAL 写入能力（`DefaultOutputHAL.setDefaultOutput`），App 侧只剩**一个**用户点击触发的写入口（`MenuBarView` → `VolumeController.switchDevice(to:)` → `DefaultOutputSwitch`）。28 个新的 Host 测试 + 11 个新的 App 测试通过真实的 `ProxyDeviceManager` / `DeviceMonitor` / `ShutdownSequence` / `DefaultOutputSwitch` 驱动，断言 15 类自动场景的默认输出写入次数为 0。

---

## 1. 初始 Git 基线（本批次开始前重新采集）

```
$ git -C ... status --short          → 84 条（tracked M=50, D=2, untracked=32+）
$ git -C ... log -1 --oneline        → ab36770 (HEAD -> main, origin/main) docs: point at SHA256SUMS.txt instead of copying hashes
$ cat VERSION                        → 1.2.0
```

- tracked 修改 50 个（含 P2 Batch 1 与更早批次的未提交工作）。
- tracked 删除 2 个：`docs/INSTALLATION_GUIDE.md`、`docs/RELEASE_NOTES.md`（历史迁移结果，非本批次产生）。
- untracked 32 条（含 `.qoder/`、若干 docs、以及上一批次的 `CoreAudioRecovery.swift`、`DefaultOutputOwnership.swift` 等）。
- 与 P2 Batch 1 报告记录的 48 M / 2 D / 28 ?? 相比已漂移 —— **确认了任务书"必须重新采集"的要求**。

### 1.1 关于"修改前 diff"的可得性说明

| 情况 | 文件 | 修改前证据 |
|---|---|---|
| tracked（有 HEAD 版本） | `ProxyDeviceManager.swift`、`DeviceMonitor.swift`、`ShutdownSequence.swift`、`main.swift`、`StartupFailureCleanupTests.swift`、`SoundBridgeApp.swift`、`VolumeController.swift`、`MenuBarView.swift` | `git show HEAD:<path>` 可取到批次前基线；但**工作区在批次开始前已有未提交改动**，因此 `git diff HEAD` 是"累计量"，不是"本批次增量" |
| untracked（无 HEAD 版本） | `DefaultOutputTrackingTests.swift`、`GracefulShutdownTests.swift`、`DefaultOutputOwnership.swift` | 只有批次开始时采集的 SHA-256 作为指纹；内容差异以本文 §4 的语义描述记录 |
| 新建 | `DefaultOutputHAL.swift`、`DefaultOutputGovernanceTests.swift`、`DefaultOutputSwitch.swift`、`DefaultOutputSwitchTests.swift` | 修改前不存在 |

本报告不虚构"本批次精确增删行数"：凡是能做到的（新建文件、删除函数清单）给出确切值，凡是不可能做到的（未提交文件中本批次之外的改动）明确标注。

---

## 2. 原始默认输出修改调用点清单（修改前）

行号取自 `git show HEAD:<path>` 的提交版本，标注为 `HEAD:<line>`。工作区在批次前已有改动，行号可能有偏移，但符号与调用关系不变。

| # | 文件 : 行 | 函数 | 写入的属性 | 调用来源 | 可否自动触发 | 修改前行为 |
|---|---|---|---|---|---|---|
| A1 | `ProxyDeviceManager.swift:85` | `setDefaultOutputDevice(_:) -> Bool` | `kAudioHardwarePropertyDefaultOutputDevice` | 被 A3/A4/A6/A7 内部调用 | 是 | 写默认输出 |
| A2 | `ProxyDeviceManager.swift:104` | 同 A1 内的第二段 | `kAudioHardwarePropertyDefaultSystemOutputDevice` | 同 A1 | 是 | 同时写"系统提示音输出" |
| A3 | `ProxyDeviceManager.swift:123` | `bounceDevice()` | 经 `setDefaultOutputDevice` 连写两次 | ①`main.swift:249`（重连通知）②`main.swift:344`（设备通知后）③ App"Reconnect Audio" | 是 | 反复弹跳默认输出 |
| A4 | `ProxyDeviceManager.swift:152` | `setDefaultAndSystemDevice(_:)` | default + system output | 经 A6/A7 | 是 | 同时写两个系统属性 |
| A5 | `ProxyDeviceManager.swift:233` | `autoSelectProxy() -> ProxySelectionOutcome` | 经 A4 | `main.swift:229`（启动 Step 7）、`main.swift:577`（降级恢复） | 是 | **启动即把 proxy 设为默认输出** |
| A6 | `ProxyDeviceManager.swift` | `handleProxySelection` 内 `isAutoSwitching` 延迟块 | 经 A4 | 默认输出监听器回调 | 是 | 0.5s cooldown 后自动切换 |
| A7 | `ProxyDeviceManager.swift:392` | `restorePhysicalDevice() -> Bool` | `kAudioHardwarePropertyDefaultOutputDevice` | `main.swift:447`（`ShutdownSequence` 的 `.restorePhysicalDevice` 步骤） | 是 | **正常退出时把物理设备设回默认输出** |
| A8 | `DeviceMonitor.swift:326` | `waitForProxyAndSwitch(addedDevices:)` | 经 A5/A4 | 设备列表变更回调（HDMI/DP/物理设备重现） | 是 | 等 proxy 出现后自动切换 |
| A9 | `main.swift:229 / 577` | 启动与 `.degraded` 恢复 | 经 A5 | 启动、降级恢复 | 是 | 自动切换 |
| A10 | `SoundBridgeApp.swift:502` | `performCleanup(logger:)` | `kAudioHardwarePropertyDefaultOutputDevice`（507）+ `kAudioHardwarePropertyDefaultSystemOutputDevice`（577） | `SoundBridgeApp.swift:389`（App 退出路径） | 是 | **App 退出时把默认输出还原成退出前记录的设备** |

补充：`DefaultOutputOwnership.swift` 中存在 `reconnectMayRebindDefault` 标志与 `skipReason`，它们是 A6/A8 的策略开关；`DeviceMonitor.swift:263` 的 `proxyManager.isDeviceBouncing` 是用于**抑制**自动切换的冷却闸门 —— 二者都是"自动切换存在"的证据，随 A3/A6/A8 一并移除。

---

## 3. 每条调用链的来源（向上追踪结果）

```
A1/A2 (写 default + system output)
├── A3 bounceDevice()
│   ├── main.swift:249   ← bounce 通知回调（App "Reconnect Audio" 按钮 post 的 com.soundbridge.bounce-request）
│   ├── main.swift:344   ← 设备列表变更通知回调（DeviceMonitor → main 的 onDevicesChanged 闭包）
│   └── VolumeController.bounceDevice() ← MenuBarView.ReconnectAudioButton（用户点"重连"）
├── A4 setDefaultAndSystemDevice()
│   ├── A5 autoSelectProxy()
│   │   ├── main.swift:229 [Step 7] 启动主流程       ← 进程启动
│   │   └── main.swift:577 降级恢复（degradedRecoveryGate）
│   └── A6 handleProxySelection 的 0.5s asyncAfter  ← 默认输出属性监听器（用户自己切换也会触发）
└── A7 restorePhysicalDevice()
    └── main.swift:446-447 `case .restorePhysicalDevice:` ← ShutdownSequence（正常退出 / SIGINT / SIGTERM）

A8 waitForProxyAndSwitch()
└── DeviceMonitor 设备列表回调（256 行）
    ← kAudioHardwarePropertyDevices 监听器（HDMI / DisplayPort / USB 音频重现）

A10 performCleanup()
└── SoundBridgeApp.swift:389（App 退出 / applicationWillTerminate 路径）
    └── findDeviceByUID（620 行）用于把记录的 UID 解析回 AudioDeviceID
```

关键发现（单删一个调用不足以解决问题）：A1/A2 是**唯一实际写 HAL 的两个点**，但它们被 6 条不同生命周期路径共用；A6 尤其危险 —— 它由**默认输出监听器**触发，意味着"用户自己切换到别的设备"也会启动一次"切回 proxy"的延迟任务，构成 §1.3「覆盖用户选择」的直接违反。

---

## 4. 修改前后行为对照

| 场景 | 修改前 | 修改后 |
|---|---|---|
| Host 启动（Step 7） | `autoSelectProxy()` 把 proxy 写成 default + system output | `resolveProxyRouting(forPhysicalUID:)` 只建立引擎路由，读默认输出**仅用于记录/日志** |
| Host 重连（Reconnect Audio） | `bounceDevice()` 连写两次默认输出 | `reconnectAudioPath()` 只做 `remapAfterCoreAudioRebuild` + `audioEngine.switchDevice`，不动默认输出 |
| 崩溃 / CoreAudio 重建恢复 | 恢复后自动重新选中 proxy | 只 remap，`refreshSystemDefaultOutput()` 仅读取 |
| 设备列表变更（HDMI/DP 出现） | `waitForProxyAndSwitch` 自动切 | 只更新设备表与降级判定 |
| 默认输出变更通知 | `handleProxySelection` 0.5s 后自动切回 proxy | `notePhysicalSelection` 只停止音量转发；**用户的选择被尊重** |
| 物理设备消失 | `restorePhysicalDevice` 可能介入 | 只清理映射 |
| Proxy 创建 / 销毁 | 创建后触发自动选中 | 只注册设备与映射 |
| Host 正常关闭 | `ShutdownSequence` 含 `.restorePhysicalDevice` 步骤 | 该步骤**已从枚举中删除** |
| Host 异常退出 | 同上（不可控） | 无写点 |
| App 退出 | `performCleanup` 把默认输出还原 | 函数整体删除（含 `findDeviceByUID`），退出路径无任何写点 |
| 用户点击设备 | `switchDevice` 无返回、失败静默、且可能被 bounce 二次改写 | 一次点击 = 一次写入；失败返回 `DefaultOutputSwitchResult.failed` 并在菜单栏弹 alert |
| 音量 / EQ | 不写默认输出 | 不变（源码门禁断言 EQ 文件永不触达 switch） |

### 4.1 被删除的符号（Host）

`ProxyDeviceManager`：`setDefaultOutputDevice`、`bounceDevice`、`setDefaultOnly`、`setDefaultAndSystemDevice`、`restorePhysicalDevice`、`autoSelectProxy`、`isDeviceBouncing`、`bounceUntilTime`、`switchCooldown`、`isAutoSwitching`、`findDeviceID`、`getCurrentDefaultDevice`、`getDeviceUID`、`getDeviceName`。
`DeviceMonitor`：`waitForProxyAndSwitch`、`isDeviceBouncing` 抑制分支、`getDeviceName`、`getDeviceUID`。
`main.swift`：`degradedMaySelectDefault`。
`ShutdownSequence.Step`：`.restorePhysicalDevice`。
`DefaultOutputOwnership`：`reconnectMayRebindDefault`、`skipReason`。
`SoundBridgeApp`：`performCleanup`、`findDeviceByUID`。

### 4.2 保留并有意不删的逻辑

- `DefaultOutputOwner` 分类（`.none/.unknown/.proxy/.managedPhysical/.unmanaged`）—— 用于**显示与判定**当前默认输出归属，不用于写入。
- `DeviceRegistry.systemDefaultOutputUID` —— App/Host 状态展示与"用户选择在哪里"的日志。
- `refreshSystemDefaultOutput()` —— 纯读取。
- `mayForwardVolume` / 音量转发 —— 只在 proxy 已是默认输出时才转发，改了会破坏音量功能，与默认输出写入无关。
- `recoveryTarget` —— 描述恢复目标，不写系统属性。

---

## 5. 最终默认输出写入 API 调用点清单（§8.1 静态检查结果）

全仓库（`packages/`、`apps/`、`tools/`，排除 `.build/`）搜索 `kAudioHardwarePropertyDefaultOutputDevice`、`kAudioHardwarePropertyDefaultSystemOutputDevice`、`AudioObjectSetPropertyData`：

### 5.1 真正写入系统默认输出的代码（全仓库仅 2 处）

| 文件 : 行 | 代码 | 由谁调用 | 用户操作来源 | 验证状态 |
|---|---|---|---|---|
| `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputHAL.swift:158` | `AudioObjectSetPropertyData(kAudioObjectSystemObject, defaultOutput…)` | **无人调用**。`setDefaultOutput` 是协议方法，Host 生产代码无任何调用点（`grep` 结果为 0） | 无（保留为 OS 能力） | 自动化：`testNothingCallsTheDefaultOutputSetter`；调用时先打 `logger.error` |
| `apps/mac/SoundBridgeApp/Sources/Services/DefaultOutputSwitch.swift:41` | `AudioObjectSetPropertyData(kAudioObjectSystemObject, defaultOutput…)` | `DefaultOutputSwitch.switchToDevice` ← `VolumeController.switchDevice(to:)` ← `MenuBarView:91` 用户点击设备项 | **有，且唯一** | 自动化：5 个显式切换测试 + 6 个源码门禁 |

### 5.2 读取 / 监听（不写）

| 文件 : 行 | 用途 |
|---|---|
| `DefaultOutputHAL.swift:48` | 读默认输出设备 ID |
| `DeviceMonitor.swift:128` | 注册默认输出属性监听器（`AudioObjectAddPropertyListener`） |
| `DeviceMonitor.swift:172` | 移除同名监听器 |
| `VolumeController.swift:542` | App 侧注册默认输出监听器（仅刷新 UI 状态） |
| `VolumeController.swift:95` | `getDefaultOutputDevice()` 读取 |
| `tools/poc/audio_probe.swift:224` | 离线探针工具，不在产品运行时路径 |

### 5.3 写入但不是默认输出（设备级音量 / 静音）

`ProxyDeviceManager.swift:471/490/680`、`VolumeController.swift:207/264` —— 全部以 `deviceID` 为 `AudioObjectID` 目标写 `kAudioDevicePropertyVolumeScalar` / `kAudioDevicePropertyMute`，作用域是**具体设备**而非 `kAudioObjectSystemObject`，不可能改变默认输出。

### 5.4 `kAudioHardwarePropertyDefaultSystemOutputDevice`

最终在生产代码中**零出现**（仅剩注释与测试断言文本）。宿主源码门禁 `testTheHostNeverWritesTheSystemOutputDevice`、App 门禁 `testTheAppNeverWritesTheSystemOutputDevice` 在每次测试运行时守卫这一点。

**结论：不存在来源不明的写入调用点。**

---

## 6. 用户显式操作路径（保留并加强）

```
MenuBarView 设备列表 item onSelect (MenuBarView.swift:91)
  └─ VolumeController.switchDevice(to: device)            // 返回 DefaultOutputSwitchResult
       └─ findProxyDeviceID(forPhysicalUID:)              // 找 "<uid>-soundbridge"
       └─ DefaultOutputSwitch.switchToDevice(_:proxyDeviceID:)
            └─ CoreAudioDefaultOutputWriter.writeDefaultOutput(target)   // 恰好一次
```

约束落实情况：

1. **UI 区分**：音量/EQ 控件与设备列表是不同控件；`switchDevice` 只挂在设备列表 `onSelect`。
2. **只有明确交互发起**：源码门禁断言 `switchDevice(to:` 在整个 App 源码中**仅出现于 `MenuBarView.swift`**（启动钩子、Host 状态观察者、通知处理器一律没有）。
3. **清晰可审计的接口**：写入被收敛到单个 `DefaultOutputSwitch` 类型 + 单个 `DefaultOutputWriting` 协议。
4. **不暴露给自动流程**：Host 侧无法访问该类型（不同 target）；Host 的 `DefaultOutputHAL.setDefaultOutput` 无调用点。
5. **音量/EQ 不触发**：`EQController.swift`、`BasicEQView.swift` 门禁断言零触达；`VolumeController` 内 `switchToDevice(` 出现次数断言为 1。
6. **失败必须报告**：`switchToDevice` 返回 `.failed(deviceID:status:message:)`，`MenuBarView` 弹出 `"Could not switch output"` alert，且**不关闭**设备列表；没有任何 retry 循环（`testAFailedWriteIsReportedAndNotRetried` 断言写入次数为 1）。

降级语义（重要）：Host 不在运行时 proxy 不存在，此时切换落到**物理设备本身**（`proxyDeviceID == nil` 分支），因为用户要听的就是那台设备 —— 这不构成自动切换。

---

## 7. 自动生命周期测试矩阵（§4.2）

全部用例位于 `packages/host/Tests/SoundBridgeHostTests/DefaultOutputGovernanceTests.swift`，运行真实 `ProxyDeviceManager` / `DeviceMonitor` / `ShutdownSequence`，只把 HAL 换成记录实现。

| # | 场景 | 测试方法 | 期望写入次数 | 结果 |
|---|---|---|---:|---|
| 0 | 缝自检（防空壳 mock） | `testTheRecordingSeamRecordsAWrite` | 1（主动写一次以证明探针有效） | ✅ |
| 1 | Host 首次启动 | `testHostStartupDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 1b | 启动只记录不改变 | `testStartupRecordsWhereTheAudioIsGoingWithoutChangingIt` | 0 | ✅ |
| 1c | 启动时 proxy 已是默认 | `testStartupReportsWhenTheProxyIsAlreadyTheDefault` | 0 | ✅ |
| 1d | 启动无 proxy 时不回退写入 | `testStartupWithoutAProxyDeviceDoesNotFallBackToWriting` | 0 | ✅ |
| 2 | Host 重启 | `testHostRestartDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 3 | CoreAudio 重建恢复 | `testCoreAudioRebuildRecoveryDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 3b | 恢复不重设用户选的 proxy | `testCoreAudioRebuildDoesNotReassertAProxyTheUserPicked` | 0 | ✅ |
| 3c | 恢复通知处理 | `testRecoveryNotificationHandlingDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 4 | HDMI 重现 | `testHdmiReappearingDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 5 | DisplayPort 重现 | `testDisplayPortReappearingDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 6 | 物理设备消失 | `testPhysicalDeviceDisappearingDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 7 | 降级态下设备列表变更 | `testDeviceListChangeWhileDegradedDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 8 | Proxy Device 创建 | `testProxyDeviceCreationDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 9 | Proxy Device 销毁 | `testProxyDeviceDestructionDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 10 | 默认输出通知（物理设备） | `testDefaultOutputNotificationForAPhysicalDeviceDoesNotSwitchBack` | 0 | ✅ |
| 11 | 默认输出通知（proxy） | `testDefaultOutputNotificationForTheProxyOnlyAdoptsState` | 0 | ✅ |
| 12 | 用户调整音量 | `testVolumeOperationsDoNotChangeTheDefaultOutput` | 0 | ✅ |
| 13 | 用户调整 EQ | `testEQOperationsDoNotChangeTheDefaultOutput` | 0 | ✅ |
| 14 | 关闭序列无默认输出步骤 | `testShutdownSequenceHasNoDefaultOutputStep` | 0 | ✅ |
| 15 | 正常关闭（真实跑 `ShutdownSequence`） | `testNormalShutdownLeavesTheDefaultOutputWhereTheUserPutIt` | 0 | ✅ |
| 16 | 异常退出 | `testAbnormalExitDoesNotChangeTheDefaultOutput` | 0 | ✅ |
| 17 | 汇总：所有自动路径 | `testEveryAutomaticRouteLeavesTheWriteLogEmpty` | 0 | ✅ |
| A1 | App 启动 / 退出 | `AppDefaultOutputSourceTests.testTheRemovedQuitRestoreStaysRemoved` 等（源码级） | 0 | ✅（L1） |

App 启动、App 退出因 `SoundBridgeApp.swift` 是 SwiftUI `@main` 入口、其生命周期由系统驱动，采用**源码级门禁**（断言 `performCleanup(` / `findDeviceByUID(` / system-output 关键字零出现）而非运行时矩阵，证据等级记为 L1，见 §18。

---

## 8. 测试 Shim 设计（§4.1）

### 8.1 Host

```swift
protocol DefaultOutputHAL {                     // 5 个读写原语
    func defaultOutputDevice() -> AudioDeviceID?
    func deviceUID(_ deviceID: AudioDeviceID) -> String?
    func deviceName(_ deviceID: AudioDeviceID) -> String?
    func deviceID(forUID uid: String) -> AudioDeviceID?
    @discardableResult func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool
}
```

- 生产：`CoreAudioDefaultOutputHAL`（`DefaultOutputHAL.swift`）—— `ProxyDeviceManager` 原本内联的 CoreAudio 调用原样搬入，行为不变。
- 测试：`RecordingDefaultOutputHAL`（测试目标内）——
  - `writes: [AudioDeviceID]` 记录每次写入请求；
  - `defaultOutputReads` 记录读取次数（区分"读"与"写"）；
  - `writeSucceeds` 可注入失败；
  - `defaultOutputID` 可被测试**直接赋值**以模拟"用户自己切换了设备"（这是关键：让通知路径可被驱动）；
  - `add/remove` 模拟设备出现/消失。
- 注入点：`ProxyDeviceManager.init(…, hal:)`，`DeviceMonitor` 通过 `proxyManager.currentDefaultOutput()` 间接使用同一缝。

**不是空壳**：`testTheRecordingSeamRecordsAWrite` 主动触发一次写入并断言记录为 `[130]`，若将来把 recorder 换成 no-op，该测试先失败。

### 8.2 为什么改了两处可见性

`DeviceMonitor` 的 `captureDeviceEventToken` / `deliverDeviceNotification` / `deliverDefaultOutputNotification` / `handleDefaultOutputChanged` 原为 `fileprivate`，导致"通知到达后会不会切默认输出"这条最关键的路径**无法被测试驱动**。本批次改为 `internal`（仅可见性，无逻辑变化）并加注释说明理由。同时 `handleDefaultOutputChanged` 原先绕过注入缝自行直接调 HAL 读默认输出，现改为 `proxyManager.currentDefaultOutput()`，并新增 `CurrentDefaultOutput { deviceID, uid }` 结构（`nil` 仅表示 HAL 查询失败，`uid == nil` 是"读到了设备但读不到 UID"这个不同的事实）。

### 8.3 App

```swift
protocol DefaultOutputWriting {
    func writeDefaultOutput(_ deviceID: AudioDeviceID) -> OSStatus
}
```

生产 `CoreAudioDefaultOutputWriter`，测试 `RecordingDefaultOutputWriter`（记录 `writes`、可设 `status` 注入失败）。没有引入任何 DI 框架，只有一个 3 行协议 + 构造器默认参数。

### 8.4 源码级门禁（L1）

用于 `main.swift`（top-level 代码，不可 `import`）与 App 入口文件：以 `#filePath` 反推包根，遍历 `Sources/`，按行断言。

- Host：`testTheHostNeverWritesTheSystemOutputDevice`、`testOnlyTheHALImplementsTheDefaultOutputWrite`（写入者集合 == `["DefaultOutputHAL.swift"]`）、`testNothingCallsTheDefaultOutputSetter`、`testTheRemovedAutomaticSwitchPathsStayRemoved`、`testTheRoutingEntryPointTakesADeviceInsteadOfAskingForTheDefault`。
- App：`testOnlyTheExplicitSwitchWritesTheDefaultOutput`、`testTheAppNeverWritesTheSystemOutputDevice`、`testTheRemovedQuitRestoreStaysRemoved`、`testTheSwitchIsReachableOnlyFromTheDeviceList`、`testVolumeAndEQCodeNeverReachTheSwitch`、`testTheReconnectButtonNoLongerBouncesTheOutput`。

两个实现细节值得记录（避免后人踩坑）：注释文本会被字面匹配误伤，故门禁先用 `code(_:)` 过滤 `//` `///` `*` `/*` 开头的行；`AudioObjectSetPropertyData` 在 App 里也用于音量，故用 ±10 行窗口判定"是否与 default-output selector 相邻"。

---

## 9. 定向测试结果

```
$ swift build --package-path packages/host          → Build complete! (1.58s)
$ swift build --package-path apps/mac/SoundBridgeApp → Build complete! (2.82s)

# Host 定向（DefaultOutputGovernanceTests / DefaultOutputTrackingTests /
#            GracefulShutdownTests / StartupFailureCleanupTests）
Executed 54 tests, with 0 failures

# App 定向（DefaultOutputSwitchTests + AppDefaultOutputSourceTests）
Executed 11 tests, with 0 failures
```

新增测试数量：

| 侧 | 文件 | 新增测试数 | 说明 |
|---|---|---:|---|
| Host | `DefaultOutputGovernanceTests.swift`（新建） | 28 | 23 治理矩阵 + 5 源码门禁 |
| Host | `GracefulShutdownTests.swift` | +1 | `testTheQuitPathHasNoDefaultOutputStep` |
| Host | `StartupFailureCleanupTests.swift` | +1 | `testFailedStartupHasNoDefaultOutputToRestore` |
| Host | `DefaultOutputTrackingTests.swift` | −17 | 删除 reconnect/shutdown 自动切换用例（其行为已被禁止，见下方说明） |
| App | `DefaultOutputSwitchTests.swift`（新建） | 11 | 5 显式切换 + 6 源码门禁 |

**关于 Host 净增 13 而非 30**：`DefaultOutputTrackingTests` 原含 `testReconnectTransaction*`、`testShutdown*` 等 17 个用例，它们断言的是"重连/关闭**应该**怎样改写默认输出"—— 即本批次要禁止的行为。这些用例不是"被弱化"或被跳过，而是**其被测行为已从产品中删除**，对应的新断言（写入次数为 0）已由 `DefaultOutputGovernanceTests` 以更强的形式覆盖。原 318 → 331（+13）与该增删完全吻合。

---

## 10. `make test-host`

```
$ make test-host
...
Executed 331 tests, with 0 failures (0 unexpected) in ...
EXIT=0
```

对比 P2 Batch 1 的 318：**+13，0 失败**。

---

## 11. `make test-app`

```
$ make test-app
...
Executed 159 tests, with 0 failures (0 unexpected) in ...
EXIT=0
```

对比 P2 Batch 1 的 148：**+11，0 失败**。

---

## 12. `make test`

```
$ make test
DSP           1/1     passed
Driver        3/3     passed
Host          331     passed (0 failures)
App           159     passed (0 failures)
Installer     transaction scenarios: 168 passed, 0 failed
Codesign      passed
✓ All test suites passed
EXIT=0
```

| 项 | 结果 |
|---|---|
| 实际命令 | `make test` |
| 退出码 | **0** |
| 总测试数 | 662（DSP 1 + Driver 3 + Host 331 + App 159 + Installer 168） |
| 通过 | 662 |
| 失败 | 0 |
| 新增 | +24（Host 13、App 11 净值；新增用例 41 个，删除过期用例 17 个） |
| 跳过/屏蔽/删除以取绿 | **无**（删除的 17 个是被测行为已不存在） |

---

## 13. 修改文件清单及 SHA-256

### 13.1 新建文件（4）

| 文件 | 修改前 | 修改后 SHA-256 |
|---|---|---|
| `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputHAL.swift` | 不存在 | `6167d57f45867fbd41f36f98f4edebfd77c00b194b8a697c3d5201a3c53012ec` |
| `packages/host/Tests/SoundBridgeHostTests/DefaultOutputGovernanceTests.swift` | 不存在 | `100ef0c9c7a6591443469c5d719cd6016fc1486c3f1ede5ba0463220a8d45ef9` |
| `apps/mac/SoundBridgeApp/Sources/Services/DefaultOutputSwitch.swift` | 不存在 | `10fcc7a15e8eee0c238dbfb189f71581ca09d91ec5d8133dca79e89ed115d01e` |
| `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DefaultOutputSwitchTests.swift` | 不存在 | `31c70098339e7dc8bde31d1a763662752c2fb19c7940ae0e3eef99806b096dd3` |

### 13.2 修改文件（11）

| 文件 | 修改前 SHA-256 | 修改后 SHA-256 | 修改原因 |
|---|---|---|---|
| `packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift` | `3c43fbf1e910c31cb979042f89fc7c8a4e4381c0c5c2ba01caebf9e865bf20d0` | `c0c3e890f0f861a9aa0eff1dc767200129171ca54a90849643aaf8563f5e68ed` | 删除 A1–A7 全部写入路径与 auto-switch 冷却状态；CoreAudio 访问收敛到注入的 HAL；新增 `CurrentDefaultOutput`/`currentDefaultOutput()` |
| `packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift` | `434de32d00f36d39668769183fb5ebed90cc076f3b996f4d6281c7e412b58fad` | `e986832f721dc9e387e861721ea64073d185b9e5f387bed1ac460d5b15886d25` | 删除 A8 `waitForProxyAndSwitch` 与 bounce 抑制；通知路径改走注入缝；4 处 `fileprivate`→`internal` 以便测试驱动；删 2 个私有读取 helper |
| `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputOwnership.swift` | `10448c1b03c8483cd03dd57643c1f2e47776255e141b4a4896399395ae911e1e` | `7623e64172064b1296975250855cb66ef039d9d89cca74ebfacbaa88f4f2397e` | 删除 `reconnectMayRebindDefault` / `skipReason`（自动重绑定的授权开关）；保留 owner 分类 |
| `packages/host/Sources/SoundBridgeHost/Lifecycle/ShutdownSequence.swift` | `a08f955f8e5a92e748a18c3d60909a4b3f7005e1ce614d53d7b8584998d678fe` | `d37578b6bd86f9c21796e0fde30381720bbd2c683a4a921a2656beb36b96dfc6` | 删除 `.restorePhysicalDevice` 步骤（A7 的触发点） |
| `packages/host/Sources/SoundBridgeHost/main.swift` | `8ac06f218121d6507e25087127d4067c95d9c2dede9822b51246af4c91ac9913` | `155f8e9ee35298d65a581359772e04ad5973dbc335538fb7742c96f911ccaf05` | 启动 Step 7 改为 `resolveProxyRouting(forPhysicalUID:)`；重连/降级/恢复/关闭链路去除写入；删除 `degradedMaySelectDefault` |
| `packages/host/Tests/SoundBridgeHostTests/DefaultOutputTrackingTests.swift` | `1a20ee0a2f80044f8298540d6a8017bb5c5c976e7a20bb52ef0960f5460da514` | `1c84a55fdc707d0a92482c3f3d3098e237eda4cda421ffc077496119c116e6af` | 删除 17 个断言"应该自动改写"的过期用例及 2 个 Fake；保留 owner/recoveryTarget/mayForwardVolume/registry/payload 测试 |
| `packages/host/Tests/SoundBridgeHostTests/GracefulShutdownTests.swift` | `57320e912918a4a7c659518218c0f7b0049baf2e3ab59d5238e4b11d6244d19a` | `96d9ee3f8a5ea9db20a9ce8e66cda0b1e49937c86141a9d1e7b554b203a623eb` | 移除 `.restorePhysicalDevice` 索引；新增 `testTheQuitPathHasNoDefaultOutputStep` |
| `packages/host/Tests/SoundBridgeHostTests/StartupFailureCleanupTests.swift` | `46f190eab8214771e9306d3f271f40875966ff675e0b046dd74d3bb338388adc` | `2c8bdd2c938e5aab52478cd34a3bf2ce71dae4f17143a924c5ca5ba8e1600c13` | 断言改为匹配 `resolveProxyRouting(forPhysicalUID:`；新增 `testFailedStartupHasNoDefaultOutputToRestore` |
| `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift` | `cbd2cde19e8ebcf2f0978b2a215cbdb51f866d339a88469b81d9521d151743d2` | `38be7706a3d5648cbfd8d56a9030e2b5e860d83b494d7ef3653b9cb9bf29a9af` | 删除 A10 `performCleanup` + `findDeviceByUID`（-173/+9） |
| `apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift` | `f315c01edd241b8d994912320e5ccdbc7666aa0a4c3c0f788573c3585b656cc5` | `1367646438cc8509bdb93203bf6f94514b7d210844a165f68c3e33b88be083b0` | 注入 `DefaultOutputSwitch`；`switchDevice(to:)` 返回结果且只写一次；`bounceDevice()` → `requestAudioReconnect()`（通知名不变）；`formatOSStatus` 改 internal |
| `apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift` | `e80e0cdc0589b3de3594646a2fe0ccf5fdd95ca518e378c979d02f29dc1ae7dc` | `5473e50e88ed5edf430b8f6459b98834e1db93f8a4106f77b3afb8312fff7138` | 切换失败时弹 alert 且不关闭列表；Reconnect 调用 `requestAudioReconnect()` |

`git diff --stat`（相对 HEAD，**含本批次之前的既有未提交改动**，仅作参照）：

```
 apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift        | 335 ++++------
 apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift |  68 +-
 apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift         |  33 +-
 packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift | 512 +++--
 packages/host/.../Devices/ProxyDeviceManager.swift              | 681 ++++----
 packages/host/.../Lifecycle/ShutdownSequence.swift              |  21 +-
 packages/host/Sources/SoundBridgeHost/main.swift                | 701 ++++----
 packages/host/Tests/.../StartupFailureCleanupTests.swift        |  41 +-
 8 files changed, 1479 insertions(+), 913 deletions(-)
```

---

## 14. Git 工作区保护情况

| 检查项 | 结果 |
|---|---|
| `git reset` / `clean` / `checkout` / `restore` / `stash` | **未执行** |
| `git add` / `git commit` | **未执行** |
| `make clean` | **未执行** |
| 删除非本批次文件 | 无 |
| 覆盖既有未提交改动 | 无（`DefaultOutputTrackingTests.swift`、`GracefulShutdownTests.swift`、`DefaultOutputOwnership.swift` 等 untracked 文件在既有内容上增量修改） |
| P2 Batch 1 的 6 个文件 | 全部保留（`Makefile`、`tools/check_protocol_layout.sh`、`AtomicFileWriter.swift`、`AtomicFileWriterTests.swift` 等未触碰） |
| `VERSION` | `1.2.0`，**未改** |
| ABI / Protocol / Shared Memory Header | `RFSharedAudio.h`（4 份副本）仍为批次前状态 —— 本批次**未编辑**，其 `M` 来自更早批次 |
| Deployment Target / `Package.swift` | 未改 |
| `Info.plist` / Bundle Version / Build Number | `apps/mac/SoundBridgeApp/Info.plist` 未出现在 status 中；`packages/driver/Info.plist` 的 `M` 来自更早批次，本批次未编辑 |
| `dist/` | 未变（`dist/SoundBridge-1.1.1.dmg`、`.pkg` mtime 均为 2026-11-17 15:11，早于本批次） |
| `build/` | 未变（被 `.gitignore:61` 忽略；本批次只跑 `swift build`/`swift test`，未跑发布脚本） |
| 签名策略 / 发布包 | 未改、未重建 |
| 最终 status | `M 50 / D 2 / ? 32+`，与基线一致（本批次新增 4 个 untracked 文件，均在允许范围内） |

---

## 15. 未解决问题

| # | 问题 | 影响 | 建议 |
|---|---|---|---|
| U1 | `DefaultOutputHAL.setDefaultOutput` 仍然存在且是真实的 HAL 写入实现 | 目前零调用点，由源码门禁 + `logger.error` 兜底；但"存在可调用的写入能力"本身是残余风险 | 保持现状（删除会削弱将来合规的显式切换能力）。若需彻底消除，可改为 `#if DEBUG` 之外抛断言 |
| U2 | `DeviceMonitor` 的 4 个方法从 `fileprivate` 改为 `internal` | 扩大了模块内可见性 | 仅可见性变化，无行为变化；若未来拆分子模块可回收 |
| U3 | App 启动/退出路径的证据为**源码级（L1）**，非运行时矩阵 | 证据强度低于 Host 侧运行时断言 | P3 增加一次真实 App 启动/退出 + `AudioObjectGetPropertyData` 采样验证 |
| U4 | 删除的 17 个 `DefaultOutputTrackingTests` 用例 | 若有人只看数量会误判为"减少覆盖" | 已在 §9 说明；建议在 P3 报告引用本节 |
| U5 | `VolumeController` 中仍有 `getDefaultOutputDevice()` 与默认输出监听器 | 纯读取/UI 刷新，符合要求；但监听器回调一旦未来被改动可能重新长出自动切换 | App 源码门禁已守卫 `switchDevice(to:` 唯一调用者，建议保留该门禁 |
| U6 | Installer / Codesign 套件未针对本批次新增断言 | 与本批次目标无关（不涉及打包/签名） | 无需处理 |

---

## 16. P3 真实系统验证建议

以下项目本批次**无授权**执行（任务书 §6 禁止），但需要真实 macOS 环境最终确认：

1. **基线采样**：启动前记录 `default output UID`、`default system output UID`。
2. **Host 启动/关闭**：`launchctl kickstart` + 正常 `SIGTERM`，前后比对两个 UID 不变。
3. **崩溃恢复**：`kill -9` Host，等待其被 App 重启，比对 UID 不变。
4. **CoreAudio 重建**：`sudo killall coreaudiod`，等待恢复，比对 UID 不变（需用户显式授权）。
5. **HDMI / DP 拔插**：真实显示器热插拔 3 次，比对 UID 不变。
6. **Proxy 创建/销毁**：Driver 装载/卸载，比对 UID 不变。
7. **显式切换**：点击设备列表项，确认 `default output` 变为 `<物理UID>-soundbridge`，且 App 只在 Host 未运行时落到物理设备。
8. **失败路径**：构造目标设备不存在的情形，确认弹窗出现且无二次写入（可用 `log stream --predicate 'subsystem == "com.soundbridge.app"'` 观察日志条数）。
9. **用户切走尊重**：手动切到其他设备，等待 60s 并触发设备事件，确认 SoundBridge 不回切。
10. **App 退出**：`Cmd+Q` 后比对 UID 不变。

判定标准：1–6、9 前后 UID 完全一致；7 只在用户点击后单次改变；8 只有 1 条写入尝试。

---

## 17. 完成条件核对（§10）

| # | 条件 | 结果 |
|---|---|---|
| 1 | 自动生命周期不再触发默认输出修改 | ✅ 28 个 Host 测试断言 |
| 2 | 所有自动切换调用链均已处理（A1–A10） | ✅ §2/§4/§5 |
| 3 | 用户明确切换能力得到保留 | ✅ `MenuBarView:91` → `DefaultOutputSwitch`，5 个 App 测试 |
| 4 | 自动生命周期测试全部通过 | ✅ |
| 5 | 显式用户操作测试全部通过 | ✅ |
| 6 | Host 测试通过 | ✅ 331/331 |
| 7 | App 测试通过 | ✅ 159/159 |
| 8 | `make test` EXIT=0 | ✅ |
| 9 | ABI / Protocol / Version 无变化 | ✅ |
| 10 | 未修改真实系统音频状态 | ✅（唯一写入点是协议，零调用；全程未触碰真实 HAL） |
| 11 | 没有 Git 写操作 | ✅ |
| 12 | 既有工作区修改全部保留 | ✅ |
| 13 | 执行报告完整 | ✅ 本文 |

**判定：PASS。**

---

## 18. 证据分级

| 结论 | 证据类型 |
|---|---|
| Host 15 类自动场景写入次数为 0 | **已通过自动化验证**（真实 `ProxyDeviceManager`/`DeviceMonitor`/`ShutdownSequence` + 记录 HAL） |
| App 显式切换写一次、失败不重试 | **已通过自动化验证**（`DefaultOutputSwitch` + 记录 writer） |
| Host 生产代码无 `setDefaultOutput` 调用点 | **已通过自动化验证**（源码门禁）+ 静态 `grep` 复核 |
| App 源码中只有 `DefaultOutputSwitch.swift` 写默认输出 | **已通过自动化验证**（源码门禁） |
| App 启动/退出不改默认输出 | **仅完成静态审查 / L1 源码门禁** |
| `ProxyDeviceManager` 内部不再有任何默认输出写入 | **仅完成静态审查**（`grep` + 代码阅读） |
| 真实 macOS 上默认输出确实不动 | **需要真实 macOS 验证（P3）** —— 本批次运行的是 Shim，**不能**当作真实 CoreAudio 行为已通过 |

---

## 附录 A：本批次禁止操作合规自检

| §6 禁止项 | 执行情况 |
|---|---|
| sudo / 安装卸载 HAL Driver / 注册移除真实 Driver | 未执行 |
| 重启 `coreaudiod` | 未执行 |
| 修改 macOS 系统文件 / 真实默认输出 | 未执行 |
| 真实 HDMI / DP 拔插、真实 HAL Device Removal | 未执行 |
| Gate 0 / EXP-1 / `preflight.sh` | 未执行 |
| 修改 ABI / Protocol / Shared Memory Header / VERSION / Bundle Version / Build Number / PKG version / Deployment Target / 签名策略 / 发布包 | 未执行 |
| 重建或迁移架构 | 未执行（仅删除死路径 + 收敛注入缝） |
| 修改 Ring Buffer / Producer Admission / Mapping Retirement | 未执行 |
| 为旧 Driver / 旧协议加兼容代码 | 未执行（Clean-slate 保持） |

## 附录 B：本批次最关键的一条不变式

> **Host 从不写默认输出；App 只在用户点击设备时写一次。**

它现在由三层共同守卫：运行时记录器（`RecordingDefaultOutputHAL`）、源码门禁（写入者集合断言）、以及 `DefaultOutputHAL.setDefaultOutput` 入口处的 `logger.error`。任何一层被绕过，另外两层仍会失败或告警。
