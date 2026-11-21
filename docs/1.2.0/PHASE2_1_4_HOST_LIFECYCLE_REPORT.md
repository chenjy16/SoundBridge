# SoundBridge 1.2.0 — Phase 2.1.4 Host 单实例、生命周期与发布链路加固报告

> 项目：SoundBridge
> 阶段：Phase 2.1.4（任务 A / B / C / D / E / F）
> 基线提交：`0574414`（`main`，`origin/main` 同步，最近 tag `1.1.3`）
> 报告日期：2026-11-16
> 结论：**CONDITIONAL PASS**（见第 10 章）

本报告只记录本阶段实际执行过的命令、实际读过的代码与实际得到的结果。凡未运行、未测量、
未在真机验证的内容，一律列入第 8 章，不以推断代替证据。

---

## 1. 执行摘要

### 1.1 本阶段目标

Phase 2.1.3 解决了「驱动装不上/看不清」与「通用二进制构建链路失效」两类问题，但留下三个
结构性问题，都发生在 **Host 进程本身**：

1. `SoundBridgeHost` 没有单实例保护。App 用 `pgrep -f SoundBridgeHost` 判断，那不是原子操作，
   两个 Host 可以同时通过检查，随后互相 `unlink` 对方的共享内存映射。
2. Host 的启动「成功」是假的：`Thread.sleep(2)` 之后无论有没有代理设备都继续往下走，
   失败路径是 `logger.warning(...)` 然后 `return`，日志留痕但对外仍像正常启动。
3. 升级策略虽然已经在 2.1.3 收紧，但「保留的能力」与「禁止的入口」之间的边界仍靠注释维持，
   没有常量、没有门禁、没有测试；同时 §2.4 要求的兼容性提示尚未落地，静默失败的风险回来了。

本阶段把这三点做成**可测试的结构**，并对发布构建链路做了第二次复审。

### 1.2 完成情况

| 任务 | 交付物 | 状态 | 证据 |
| --- | --- | --- | --- |
| A：Host 单实例锁 | `Lifecycle/HostInstanceLock.swift`（249 行）+ `HostStartupGate` | 完成 | `HostInstanceLockTests` 10 项（真实子进程），`make test-host` 通过 |
| B：七级生命周期 | `Lifecycle/DriverLifecycle.swift`（335 行）、`HostLifecycleReporter.swift`（101 行） | 完成 | `DriverLifecycleTests` 14 项，`make test-host` 104/104 |
| B：就绪轮询 | `ReadinessWaiter` + `proxyDiscoveryTimeout = 5.0s`，删除 `Thread.sleep(2)` | 完成 | `main.swift:188` 起注释与 `waitForProxyDevice` |
| B4：心跳审查 | 心跳字段语义、双阈值、跨进程真实子进程验证 | 完成 | `DriverHeartbeatCrossProcessTests` 5 项 |
| B5：App 状态反馈 | `HostStatusModel`（60 行）+ `HostStatusRow`，11 种 `HostRunState` | 完成 | `HostRunStateTests` 21 项 |
| C：策略固化 | `DriverUpgradePolicy` 三常量、`DriverInstallIntent` 门禁 | 完成 | `DriverInstallIntentTests` 9 项，`DriverVersionGateTests` 30 项 |
| C：§2.4 提示 | `DriverCompatibilityNotice`（138 行），纯文本、无安装动作 | 完成 | `DriverCompatibilityNoticeTests` 10 项 |
| C：死代码处置 | 6 个符号 + 3 个错误 case 删除，2 个符号保留但接线断开 | 完成 | 见第 5 章调用关系表 |
| D：发布链路复审 | Sparkle 框架 staging、双架构守卫、`set -u` / `pipefail` | 完成 | `make quick`、`verify_release_bundle.sh` 均退出 0 |
| E：全量回归 | 9 条命令全部通过 | 完成 | 见第 7 章表格 |
| F：报告 | 本文件 | 完成 | — |

### 1.3 本阶段发现的问题

| 编号 | 级别 | 问题 | 状态 |
| --- | --- | --- | --- |
| P0-1 | 阻断发布 | 三条构建路径（`tools/build_release.sh`、`make quick`、`release.yml`）只把可执行文件 lipo 进 `.build/universal/release/`，**从不把 `Sparkle.framework` 放进去**；`create_app_bundle.sh` 的 4 个候选路径在干净检出上全部落空 | 已修复（第 6 章） |
| P1-1 | 产品缺口 | `OnboardingState.hasCompleted()` 使 onboarding 只跑一次，协议代际变更后 App 内**没有任何路径**让用户重装 Driver；`DriverVersionGateTests` 与 §2.4 提示都指向「重新安装完整包」，而重装 App 不会重跑 Driver 步骤 | **未修复，待人工决策**（第 8 章） |
| P2-1 | 一致性 | `packages/driver/README.md` 三处写 `HEARTBEAT_TIMEOUT_SEC = 5`，而 `Plugin.cpp` 实为 15 | 已修复 |
| P2-2 | 一致性 | 根 `README.md` 缺少用户可见的「App 不自行升级 Driver」说明 | 已补 `### Updating` |

> P0-1 的症状很容易被误读：干净机上产物会在 dyld 阶段失败，`open` 报「应用已损坏」，
> 排查方向会先落到签名与公证上。`otool -L` 显示 App 链接
> `@rpath/Sparkle.framework/Versions/B/Sparkle`，而该框架并不在产物目录里。

### 1.4 是否建议进入 Phase 2.2

**建议进入**，但 P1-1 需要人类先做产品决定（它影响 §2.4 提示的可执行性），且本阶段的
签名/公证/Tag/推送一律未执行（第 6.6 节说明原因）。

---

## 2. 任务 A：Host 单实例锁

### 2.1 为什么是 `flock` 而不是 `pgrep`

旧路径是 `pgrep -f SoundBridgeHost`：**检查和占用不是同一个动作**。两个 Host 可以同时读到
「没有别的 Host」，随后都去 `unlink` 控制文件、创建 `/tmp/soundbridge-<uid>`，最后驱动向
哪个映射写帧取决于谁先 `mmap`，另一个进程则变成「消费没人写的数据」的幽灵。

`flock(2)` 把仲裁交给内核，且锁属于 **open file description**：

- 进程退出（含 `SIGKILL`）、`exit()`、被 `SIGTERM` 都释放锁，无需任何清理代码；
- 崩溃的 Host 不会留下「锁被持有」的假象；
- 反过来，**删除锁文件不会释放锁**，因为解开的是文件系统路径而不是描述符。

### 2.2 实现要点

| 项 | 取值 | 位置 |
| --- | --- | --- |
| 锁路径 | `/tmp/soundbridge-host-<uid>.lock` | 由 `RF_INSTANCE_LOCK_PATH_PREFIX` + uid + `RF_INSTANCE_LOCK_PATH_SUFFIX` 拼出（`RFSharedAudio.h:728-729`） |
| 获取方式 | `open(O_RDWR | O_CLOEXEC | O_NOFOLLOW)` + `flock(LOCK_EX | LOCK_NB)` | `HostInstanceLock.acquire()` |
| Swift 绑定 | `@_silgen_name("flock")` | `flock(2)` 与 `struct flock` 同名，Swift 无法直接命名该函数 |
| 身份校验 | `fstat(fd)` 与 `lstat(path)` 的 `st_dev`/`st_ino` 比对 | 防止路径在 `open` 与 `flock` 之间被替换 |
| 归属记录 | `pid=<pid> uid=<uid> since=<ISO8601>` | `writeOwnerRecord()`，失败不影响启动 |
| 释放 | `close(fd)`；**不 unlink 文件** | `release()` |
| 退出码 | 3 = 实例冲突，4 = 锁获取失败 | `HostExitCode` |

`O_NOFOLLOW` 与 `pathRefersToSameFile` 是针对 `/tmp` 的：`/tmp` 是全局可写目录，
一个预先放置的符号链接可以把锁重定向到任意文件。这两处让「锁的是我想锁的那个 inode」
成为可检查的条件，而不是假设。

### 2.3 生命周期位置

`main()` 的第一件事（`Step -1`），在目录创建、控制文件写入、共享内存创建**之前**：

```
switch HostStartupGate(lock: instanceLock).evaluate() {
case .proceed:                          → 继续
case .refuseInstanceConflict(let owner): exit(3)   // 不 unlink、不创建、不清理
case .refuseLockFailure(let reason):     exit(4)
}
```

拒绝路径不触碰任何共享状态，这是「第二个实例必须干净退出」的落实方式：不是尽力而为，
而是结构上就到不了那些代码。释放发生在 `Cleanup` 的最后一行（`main.swift:417`），
保证锁的覆盖范围包含所有被触碰过的资源。

### 2.4 App 侧不得用进程名匹配

`HostInstanceProbe`（70 行）用**同一个路径**做非持有探针：打开、`LOCK_EX | LOCK_NB`、
拿到就立刻 `LOCK_UN` 返回 false；拿不到且 `errno` 为 `EWOULDBLOCK`/`EAGAIN` 才认为有 Host。
它不创建文件、不修改文件、事后不留锁。`SoundBridgeApp.swift` 已无 `pgrep`/`system_profiler`
调用。

### 2.5 A5 十项真实进程测试

`HostInstanceLockTests`（10 项）全部使用真实 `Process` 子进程（`launchChild(mode: "hold", …)`），
不使用 mock：

| 测试 | 断言的核心事实 |
| --- | --- |
| `testFirstProcessAcquiresTheLock` | 无人持锁时第一个进程得到 `.acquired` |
| `testSecondProcessIsRefusedWhileTheFirstHolds` | 持锁期间第二个进程得到 `.heldByAnotherInstance` |
| `testDifferentUIDsUseDistinctPathsAndBothAcquire` | 两个 per-uid 路径互不相同且可同时持有；并且锁路径**不等于**共享内存路径（否则语义会变成「每设备一个 Host」） |
| `testLockIsAcquirableAfterNormalExit` | 正常退出后锁可用 |
| `testLockIsAcquirableAfterExitWithoutCleanup` | 不走清理路径退出后锁仍可用 |
| `testSIGKILLReleasesTheLock` | 被 `SIGKILL` 终止后内核释放锁 |
| `testRefusedInstanceCreatesNoSharedMemory` | 被拒绝的实例不创建任何映射、不新增任何文件 |
| `testRefusedInstanceDeletesNoExistingSharedMemory` | 被拒绝的实例不删除已有共享内存 |
| `testConcurrentProcessesElectExactlyOneOwner` | N 个进程并发竞争，恰好一个成为 owner |
| `testLeftoverLockFileDoesNotBlockStartup` | 文件残留但无人持有时可启动（锁压过文件存在性） |

---

## 3. 任务 B：七级生命周期与就绪轮询

### 3.1 七级状态不得互相替代

`DriverLifecycle.swift` 把「驱动能不能用」拆成七个各自可观测的层级，每一层都有自己的
枚举值域，任何一层都不能用另一层的值代替：

| 级别 | 枚举 | 值域 |
| --- | --- | --- |
| 1 文件 | `DriverFileStatus` | `unknown` / `present` / `missing` |
| 2 协议 | `DriverCompatibilityStatus` | `unknown` / `compatible` / `incompatible` / `unreadable` |
| 3 加载 | `DriverLoadStatus` | `unknown` / `notLoaded` / `loaded` |
| 4a HAL 枚举 | `HALDiscoveryStatus` | `pending` / `discovered` / `notDiscovered` |
| 4b/5 代理匹配 | `ProxyDeviceStatus` | `pending` / `found` / `missing` |
| 6 共享内存附着 | `SharedMemoryConnectionStatus` | `pending` / `waitingForDriver` / `connected` / `disconnected` / `driverNotResponding` / `hostHeartbeatStalled` / `invalid` |
| 7 音频管线 | `AudioPipelineStatus` | `pending` / `flowing` / `notStarted` / `stalled` |

第 3 级的注释写明了它为什么只能是 `unknown` 的推断值：没有任何 API 直接回答
「coreaudiod 是否加载了这个 bundle」，诚实证据只有第 6 级的附着或第 4a 级的设备出现，
**磁盘上有文件既不能证明加载，也不能证伪**。

### 3.2 启动结果：8 种，不允许含糊

`HostStartupOutcome`：`starting` / `ready` / `instanceConflict` / `proxyTimeout` /
`sharedMemoryInvalid` / `driverNotResponding` / `noPhysicalDevices` / `inactive`。

`HostLifecycleSnapshot` 把它们与七级状态一起写进 `device-state.json` 的 `lifecycle` 字段，
由 `HostLifecycleReporter` 发布，App 侧 `IPCController` 解码为 `HostLifecycleReport`。
时间戳用 `TimeInterval`（自 1970 秒数）而不是格式化字符串，避免两个进程对
`DateFormatter` 的理解产生分歧。

### 3.3 用状态等待替换固定 sleep

旧代码：

```swift
Thread.sleep(forTimeInterval: SoundBridgeConfig.deviceWaitTimeout)   // 2.0s
// 然后无论设备是否出现都继续
```

新代码（`main.swift:188` 起，`Step 6`）：

```swift
if case .timedOut(let seconds) = waitForProxyDevice(forUID: preferredDevice.uid) {
    enterDegraded(detail: "no proxy device for \(preferredDevice.name) after \(seconds)s; ...")
    RunLoop.current.run()
    return
}
```

`ReadinessWaiter` 的三条性质是把它做成类型而不是写成一个循环的理由：

1. **每次等待都有上界**（`proxyDiscoveryTimeout = 5.0s`），启动不可能挂死；
2. **固定间隔轮询**（`proxyPollInterval = 0.1s`），不是忙等；
3. **`now` 与 `sleep` 可注入**，超时路径在测试里以微秒级跑完，不需要真的睡 5 秒。

`ReadinessSignal` 区分 `ready` / `notYet(reason)` / `terminal(reason)`：映射非法或没有
物理设备属于「再等也没用」，直接终止而不是耗满 5 秒——这正是旧代码最缺的区分。

等待代理设备时用 `RunLoop.current.run(mode:before:)` 而不是 `Thread.sleep`，并挂了一个
3600 秒的一次性 timer 保活：HAL 的设备变更回调在主队列投递，主线程若阻塞在这里，
就永远看不到设备出现。

同时，`waitForProxyAndSwitch`（设备切换路径）保留了自己的 `deviceWaitTimeout` 有界轮询，
超时只记 `warning` 不冒充成功——那条路径的语义是「切换失败就用回原设备」，
与「启动是否成功」不是同一件事，因此没有改动，但它的截止时间是显式的
（`while Date() < deadline`），不是固定睡眠。

---

## 4. B4 心跳审查 / B5 App 侧状态反馈

### 4.1 心跳字段

| 字段 | offset | size | 写入方 |
| --- | --- | --- | --- |
| `driver_connected` | 120 | 4 | 驱动在附着/卸载时 |
| `host_connected` | 124 | 4 | Host |
| `driver_heartbeat` | 128 | 8 | 驱动的 IO 回调（`atomic_fetch_add`） |
| `host_heartbeat` | 136 | 8 | Host 的 1 Hz timer |

这些 offset 由 `tools/check_protocol_layout.sh` 编译期钉住（`_Static_assert` + `#error`），
不是文档里的数字。

### 4.2 只凭 Swift 单测不能声称「跨进程安全」

本阶段把这项验证做成了真实子进程：`DriverHeartbeatCrossProcessTests`（5 项）由测试进程
创建映射，**另一个进程**按驱动侧的方式写 `driver_connected` 与 `driver_heartbeat`，
测试进程观察实际读到的值：

| 测试 | 验证的跨进程事实 |
| --- | --- |
| `testDriverAttachmentAndFramesAreVisibleToTheHost` | 另一进程写入的附着标志与帧计数，Host 侧能读到 |
| `testKilledWriterStallsThePipelineWithoutDetaching` | 写入进程被杀后管线转 stalled，但**不**被读成 detached |
| `testDriverDetachFromAnotherProcessIsVisible` | 另一进程清掉 `driver_connected` 后 Host 能看到 |
| `testSixtyFourBitCounterIsReadWhole` | 64 位计数器不会被读成撕裂值（半新半旧） |
| `testHostHeartbeatIsVisibleToTheDriverProcess` | Host 写入的心跳对驱动侧进程可见 |

状态机的判定规则（`driverNotResponding` 只给「从未产出第一帧」、`hostHeartbeatStalled`
先于归咎驱动、未知头 → `invalid`）由 `DriverLifecycleTests`（14 项）覆盖，两套测试
的分工是「跨进程能看见什么」与「看见之后怎么判」。

### 4.3 为什么「心跳冻结」不是故障

`DoIOOperation` 在播放停止后不再被调用，心跳随之冻结。把冻结读成「驱动没响应」会让用户
每次暂停音乐都看到一个故障提示。因此：

- `driverNotResponding` 只保留给「已附着且从未产出过一帧」这一种确实错误的情形
  （`hasHeardDriverHeartbeat == false`）；
- 产出过帧又安静下来的设备是 idle，第 6 级保持 `.connected`，第 7 级转 `.stalled`。

### 4.4 双阈值

| 计数器 | 阈值 | 理由 |
| --- | --- | --- |
| `driver_heartbeat` | 3 samples | 驱动从 IO 回调写入，按 buffer 节奏推进；连续 3 秒不动已是很长的间隔 |
| `host_heartbeat` | 5 samples | 自己的 timer 与 monitor 都是 1 Hz，会混叠；同时留出与驱动侧 15s 容忍度相称的余量 |

比较用 `!=` 而非 `>`：存活性的语义是「写入方跑过」，不是「数字变大」，这样映射被重新
初始化（计数器回 0）不会被误判为停滞。

### 4.5 B5：App 侧区分状态，不新增升级入口

`HostStatusModel`（单例、`@Published private(set) var state`）是唯一写入点，
`AppDelegate.applyHostLifecycle(_:)` 在启动首读（`SoundBridgeApp.swift:60`）、
`device-state.json` 变更回调（`:54`）、以及重连路径（`:702`）三处写入。

菜单栏只加了一行状态（`HostStatusRow`，11pt，橙色/次要色，**无按钮**），且仅在
`state.isProblem || state == .starting` 时出现——`waitingForDriver` 被明确排除在
`isProblem` 之外，因为那是「安静系统上的正常状态」，弹提示只会变成噪音。

`HostRunState.resolve(report:hostRunning:)` 的核心规则是 **锁压过文件**：

```swift
guard hostRunning else { return .notRunning }      // 先看锁
guard let report else { return .starting }
```

被 kill 掉的 Host 会在 `device-state.json` 里留下 `ready`。旧实现直接读文件，于是对着一个
死进程报「已连接」；现在锁说了算，文件只在锁被持有时才有资格解释细节。

---

## 5. 任务 C：升级策略固化、死代码处置、§2.4 提示

### 5.1 三个策略常量（全部集中在一处）

```swift
enum DriverUpgradePolicy {
    static let allowsUserFacingPrompt = false   // 无按钮、无菜单项、无启动弹窗
    static let allowsAutomaticInstall = false   // 无后台下载、无后台替换
    static let allowsCompatibilityNotice = true // 但也不许静默失败
}
```

`DriverInstallIntent` 是唯一的安装门禁，两个来源被显式分开：

| intent | 允许的目标状态 | 说明 |
| --- | --- | --- |
| `.firstInstall` | 仅 `.notInstalled` | onboarding 用 |
| `.explicitUpgrade(from:to:)` | `.outdated` / `.protocolIncompatible` / `.metadataUnreadable` / `.notInstalled`（安装中途被删） | 只有用户明确动作才能产生 |

`installDriver(intent:)` 的首行是 `guard intent.permits(status) else { throw ... }`，
所以「启动检查顺手装一下」在类型层面就写不出来。

### 5.2 C3：逐个符号的调用关系 / 可达性 / 误接线风险 / 处置

| 符号 | 调用者 | 可达性 | 误接线风险 | 处置 |
| --- | --- | --- | --- | --- |
| `AppDelegate.checkAndLoadDriverIfNeeded()` | 无（0 调用） | 不可达 | 高：内含 `NSAppleScript` 执行 `killall coreaudiod`，且有面向开发者的文案；任何一次接线都会让启动路径获得特权重启能力 | **删除**，原位留下 16 行说明 |
| `AppDelegate.isDriverLoaded()` | `checkAndLoadDriverIfNeeded` | 随上一项消失 | 中：`system_profiler` 子进程 + 名称匹配，回答的是「名字出现过」而不是「驱动可用」 | **删除** |
| `DriverInstaller.isDriverLoaded()`（重复实现） | 无（0 调用） | 不可达 | 中：与上一项同名不同实现，容易改错一个 | **删除** |
| `DriverInstaller.copyDriverWithPrivileges` | 无（0 调用） | 不可达 | 高：独立的一套特权 `cp`，绕过 intent 门禁 | **删除** |
| `DriverInstaller.setDriverPermissions` | 无（0 调用） | 不可达 | 高：同上，`chown`/`chmod` 单独可调 | **删除** |
| `DriverInstaller.restartAudio` | 无（0 调用） | 不可达 | 高：直接 `killall coreaudiod` | **删除** |
| `DriverInstaller.uninstallDriver()` | 无（0 调用，注释写 "for testing"） | 不可达 | 中：卸载能力留在 App 内既无用又危险；卸载由 `tools/uninstall_driver.sh` 承担 | **删除** |
| `DeviceMonitor.reloadDriver()`（Host 侧） | 无（0 调用） | 不可达 | 中：唯一作用是打印 `sudo killall coreaudiod` 提示 | **删除** |
| `showDriverUpdatePrompt(currentVersion:newVersion:)` | 无（0 调用） | 不可达 | 低：函数体内第一行就是 `guard DriverUpgradePolicy.allowsUserFacingPrompt`，常量恒 false | **保留但断线**（能力留作测试对象） |
| `performDriverUpdate()` | 仅 `DriverUpdateWindow` 的 `onUpdate` 闭包 | 不可达（窗口从不创建） | 低：入口被上一项挡住；内部已改为 `status.installIntent` + `!isFirstInstall`，不会冒充首次安装 | **保留但断线** |
| `DriverUpdateWindow.swift`（87 行） | 仅 `showDriverUpdatePrompt` | 不可达 | 低 | **保留**，不删（删了会让「保留能力」的意图无从表达） |

「保留但断线」这一档的判断依据是：策略常量是**编译期常量**，`guard` 是函数体第一句，
不存在「某个调用者忘了检查」的可能。删除它们反而会让下一个人重新拼一套升级流程。

删除带来的错误 case 一并清理：`permissionsFailed` / `audioRestartFailed` / `uninstallFailed`。
保留 `driverNotFound` / `copyFailed` / `verificationFailed` / `intentDoesNotMatchStatus`。

### 5.3 §2.4 兼容性提示

`DriverCompatibilityNotice`（138 行）是**纯文本**类型：没有安装动作、没有 `URLSession`、
没有特权调用。触发条件限定为 `.outdated` / `.protocolIncompatible` / `.metadataUnreadable` /
`.expectedVersionUnavailable`；`.notInstalled` 归 onboarding，`.compatible` / `.newer` 是健康态。

提示正文包含：App 版本、已安装 Driver 版本、本版本需要的 Driver 版本、协议号的十六进制对照、
「不会在后台修改系统 Driver」以及 GitHub 发布页。发布页不是手写的：

```swift
// SUFeedURL = https://github.com/chenjy16/SoundBridge/releases/latest/download/appcast.xml
//      → https://github.com/chenjy16/SoundBridge/releases
```

`DriverCompatibilityNoticeTests` 有一项**读取真实 `Info.plist`**（经 `#filePath` 上溯到仓库根）
来验证这条派生，避免「测试里写死一个和产物不同的 URL」。非 GitHub 域、只有 owner、相对路径、
未配置 `SUFeedURL` 四种情况都返回 `nil`——这时提示只说「去哪里找」，不编造链接。

---

## 6. 任务 D：发布构建与 CI 复审

### 6.1 复审结论一览

| # | 检查项 | 结论 |
| --- | --- | --- |
| 1 | App 双架构（arm64 + x86_64） | 通过（`make quick` 实跑，`lipo -archs` = `x86_64 arm64`） |
| 2 | Host 双架构 | 通过（同上） |
| 3 | Driver 双架构 | 通过（`verify_release_bundle.sh` 第 7 段） |
| 4 | **Sparkle.framework 是否进产物** | **原为失败，已修复**（第 6.2 节） |
| 5 | `create_app_bundle.sh` 找不到框架时 | 原为静默跳过 → 改为硬失败 |
| 6 | `create_app_bundle.sh` 的 `pipefail` | 缺失 → 已补 |
| 7 | `build_release.sh` 的 `set -u` | 缺失 → 已补 |
| 8 | 产物定位方式 | 原为 4 个猜测路径 → 改为 `swift build --show-bin-path` |
| 9 | `protocol-check` 是否为 `build` 前置 | 是（`build: protocol-check update-version`） |
| 10 | 守卫顺序 | `release: build bundle release-verify sign verify`，签名前先校验产物，正确 |
| 11 | `sync_shared_header.sh --check` 的比对方式 | `cmp -s` 与源文件逐字节比对（4 个副本），非 mtime |
| 12 | `check_protocol_layout.sh` 的覆盖 | 版本字面量（`#error`）、`sizeof == HEADER_SIZE`、34 个字段 offset、Driver plist 一致性，均覆盖 |

### 6.2 P0-1：`Sparkle.framework` 不在产物里

SwiftPM 6.x 的双架构构建要为每个架构指定独立 scratch path，产物落在
`<scratch>/out/Products/Release`，而 `<scratch>/release` 只是指向它的符号链接。
三条路径原本都写成：

```bash
lipo -create -output .build/universal/release/SoundBridgeApp \
    .build/arm64/release/SoundBridgeApp \
    .build/x86_64/release/SoundBridgeApp
```

只搬了可执行文件。而 `otool -L` 显示 App 链接的是
`@rpath/Sparkle.framework/Versions/B/Sparkle`，框架本身留在 scratch 里，从未被复制到
`.build/universal/release/`。同时 `create_app_bundle.sh` 的 4 个候选路径里，
`.build/release` 只在用默认 scratch 构建时存在——干净检出上全部落空，于是框架被静默跳过。

现场实测确认了这条链路：

```
.build/out/Products/Release/       → 有 Sparkle.framework（默认 scratch 的遗留，时间戳 19:02）
.build/universal/release/           → 只有 SoundBridgeApp
.build/arm64/out/Products/Release/  → 有 Sparkle.framework
```

修复（4 处）：

1. `tools/build_release.sh`：用 `--show-bin-path` 取 `ARM64_DIR` / `X86_DIR`，
   lipo 后 `for fw in "$ARM64_DIR"/*.framework` 逐个 `rm -rf` + `cp -R` 到 universal 目录，
   并打印 `lipo -archs`；
2. `Makefile` 的 `quick`：追加同样的 staging（`rm -rf … && cp -R .build/arm64/release/Sparkle.framework …`）；
3. `.github/workflows/release.yml`：同样的 staging + 架构打印；
4. `tools/create_app_bundle.sh`：找不到框架时用 `otool -L … | grep -q Sparkle.framework`
   判定，链接了却找不到就 **`exit 1`**，不再静默继续。

### 6.3 守卫新增：App / Host 双架构

`tools/verify_release_bundle.sh` 新增第 8 段：从 driver bundle 反推出 `.app`，检查
`Contents/MacOS/SoundBridgeApp` 与 `Contents/MacOS/SoundBridgeHost` 是否都含
`arm64` 与 `x86_64`（缺一即 `check_fail`），并在 App 链接 Sparkle 时要求
`Contents/Frameworks/Sparkle.framework` 存在。找不到 `.app` 时打印 Note 跳过，
不影响单人只校验 driver 的场景。

理由是这段检查的价值在于**签名之前**：`create_app_bundle.sh` 只会打印架构然后继续，
单架构产物会作为正式发布出门，另一半机器上的用户看到「应用已损坏」，而本机永远看不到。

### 6.4 实跑证据

`make quick`（退出码 0）现在输出：

```
  Copying Sparkle.framework...
  Sparkle.framework copied

Architectures:
  SoundBridgeApp: x86_64 arm64
  SoundBridgeHost: x86_64 arm64
  SoundBridgeDriver: x86_64 arm64
```

且 `.build/universal/release/Sparkle.framework/Versions/B/Sparkle` 的
`lipo -archs` = `x86_64 arm64`——框架本身也是通用二进制，staging 是逐架构目录复制的，
所以这一个文件就同时覆盖两种 CPU。

### 6.5 本阶段修改的脚本

`tools/build_release.sh`、`tools/create_app_bundle.sh`、`tools/verify_release_bundle.sh`、
`Makefile`、`.github/workflows/release.yml`。五个 shell 脚本 `bash -n` 全部通过。

### 6.6 本阶段刻意未执行的命令

`make build` / `make release` / `make full-release` 一律未执行：它们的依赖链包含
`update-version`，会按 git tag 改写全部组件的版本号与 Driver plist。本阶段不建 Tag、
不改正式版本号、不签名、不公证、不推送，因此这些命令没有可安全运行的形式。
第 7 章的回归因此用 `make quick` + `make test` + `verify_release_bundle.sh` 覆盖，
它们验证的是**同一条产物链**（`create_app_bundle.sh` 是三者共用的最后一步）。

---

## 7. 测试结果（实际命令 / 实际退出码）

| # | 命令 | 退出码 | 测试数量 | 失败 | 跳过 | 验证性质 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `make protocol-check` | 0 | 4 份头文件一致性 + 2 个编译器（C11 / C++17）+ 34 个字段 offset | 0 | 0 | 编译期 + 静态 |
| 2 | `make test-dsp` | 0 | 1 个 CTest 目标 | 0 | 0 | 单元 |
| 3 | `make test-host` | 0 | 104 | 0 | 0 | 单元 + 真实子进程 |
| 4 | `make test-app` | 0 | 107 | 0 | 0 | 单元 + 真实 `flock` 子进程 |
| 5 | `make test`（聚合） | 0 | 104 + 107 + 1 CTest = 212 | 0 | 0 | 同上 |
| 6 | `make quick` | 0 | —（构建 4 个产物：App / Host / Driver / Sparkle.framework） | — | — | 产物构建 |
| 7 | `./tools/verify_release_bundle.sh` | 0 | 8 段检查 | 0 | 0 | 产物静态校验 |
| 8 | `for f in tools/*.sh; do bash -n "$f"; done` | 0 | 5 个脚本 | 0 | 0 | 语法 |
| 9 | `git diff --check` | 0 | — | — | — | 空白错误 |

`make protocol-check` 的关键输出：

```
protocol version : 0x00020100
header size      : 256 bytes
sizeof(struct)   : 256 bytes
audio_data offset: 256 bytes
driver_connected 120 / host_connected 124 / driver_heartbeat 128 / host_heartbeat 136
Driver plist:   OK (SBAudioProtocolVersion=131328)
```

`verify_release_bundle.sh` 的关键输出：

```
Bundle id     : com.soundbridge.driver
Version       : 1.1.1
Protocol      : 131328 (0x00020100)
Architectures : x86_64 arm64
OK: final driver bundle matches the protocol header and the app's expectation
```

### 7.1 Host 测试分布（104）

| 文件 | 数量 | 与本阶段的关系 |
| --- | --- | --- |
| `HostInstanceLockTests` | 10 | 新增（任务 A） |
| `DriverLifecycleTests` | 14 | 新增（任务 B） |
| `DriverHeartbeatCrossProcessTests` | 5 | 新增（任务 B4） |
| `SharedMemoryProtocolTests` | 19 | 既有 |
| `SharedMemoryRecoveryTests` | 16 | 既有 |
| `SharedMemoryFileSystemTests` | 6 | 既有 |
| `SharedMemoryMultiProcessTests` | 4 | 既有 |
| `VolumeStateTests` | 18 | 既有 |
| `VolumeTaperTests` | 12 | 既有 |

### 7.2 App 测试分布（107）

| 文件 | 数量 | 与本阶段的关系 |
| --- | --- | --- |
| `HostRunStateTests` | 21 | 新增（B5） |
| `HostInstanceProbeTests` | 10 | 新增（A 的 App 侧） |
| `DriverInstallIntentTests` | 9 | 新增（C） |
| `DriverCompatibilityNoticeTests` | 10 | 新增（C，§2.4） |
| `DriverVersionGateTests` | 30 | 既有，本阶段改写（`requiresInstallation` → `installIntent`） |
| `EQPropertyTests` | 8 | 既有 |
| `EQUnitTests` | 19 | 既有 |

App 新增 50 项（21 + 10 + 9 + 10），改写既有 `DriverVersionGateTests` 30 项中的 7 项矩阵。
所有套件的 XCTest 汇总行均为
`with 0 failures (0 unexpected)`，没有 `skipped` 计数，即**跳过的测试为 0**。

---

## 8. 未验证事项与待人工决策

### 8.1 P1-1：协议变更后用户没有 App 内重装路径（需人类决策）

事实链：

1. `OnboardingState.hasCompleted()` 让 onboarding 在整个安装期内只跑一次；
2. `DriverInstallStepView` 的安装按钮只存在于 onboarding；
3. `--reset-onboarding` 是 CLI flag，普通用户没有；
4. 因此当 Driver 协议代际变更（例如 1.1.x → 1.2.0，协议 `0x00010400` → `0x00020100`），
   老用户的 Driver 变成 `.protocolIncompatible`，App 会按 §2.4 正确显示兼容性提示，
   提示里写着「需通过 GitHub 获取完整安装包重新安装」；
5. 但用户重新下载并安装 App 之后，onboarding 不会重跑，**Driver 仍是旧的那个**。

也就是说：提示文本是对的，但它指向的恢复动作在 App 里不存在。

可能的方向（都需要产品决定，本阶段不做）：

- A. 允许在「已安装但不兼容」时把 Driver 安装步骤重新呈现为一次性兼容性修复
  （仍然是一次明确的用户点击，不违反 §二 的 8 项禁令）；
- B. 在 `docs`/发布说明中明确写出「需先手动删除旧 Driver 再重装 App」的步骤
  （但这依赖用户读文档，且当前仓库没有任何脚本做到这一点）；
- C. 提供一个独立于 onboarding 的「修复安装」入口（与禁令的边界需要逐条核对）。

本阶段只做了一件事：**不掩盖**。根 `README.md` 的 `### Updating` 写明 App 不会自行升级
Driver，没有编造「按提示点击安装即可」这类不存在的步骤。

### 8.2 未验证项

| # | 未验证的内容 | 为什么未验证 | 现有证据到什么程度 |
| --- | --- | --- | --- |
| 1 | Intel（x86_64）真机上的运行行为 | 本机为 Apple Silicon | 只有 `lipo -archs` 证明架构存在，没有在 x86_64 上启动过产物 |
| 2 | 两个真实登录会话下的 UID 隔离 | 需要第二个 GUI 会话 | 只做了路径构造断言（不同 uid → 不同路径），并由两个真实子进程同时持有两个不同锁路径；但两个子进程仍属同一 uid，未在两个真实登录会话中并发运行 |
| 3 | 真实 Driver 的 15 秒心跳超时 | 需要安装/触碰真实 HAL 驱动与 `coreaudiod`，本阶段明令禁止 | `Plugin.cpp` 常量 + 头文件 offset + 跨进程模拟写心跳 |
| 4 | `dist/SoundBridge.app` 的实际启动 | 会触碰已安装 Driver 与音频守护进程 | `create_app_bundle.sh` 结构检查 + `otool -L` 依赖检查 + 守卫脚本 |
| 5 | 正式签名 / 公证 / Sparkle 更新链路 | 本阶段禁止签名与发布 | 只验证了框架随产物就位（P0-1 的修复目标） |
| 6 | 菜单栏状态行的实际刷新延迟 | 需要运行 App 观察 UI | 静态阅读：`device-state.json` 变更由 Darwin 通知驱动，`applyHostLifecycle` 在 3 处调用 |

`verify_release_bundle.sh` 第 8 段是**静态**检查：它证明两个二进制含两种架构、
框架在正确位置，不证明 App 在 Intel 机器上能启动。

---

## 9. Git 工作区状态

- 分支：`main`，HEAD = `0574414`（与 `origin/main` 一致，未推送任何内容）
- 已跟踪文件修改：27 个
  - 本阶段直接改动：`tools/build_release.sh`、`tools/create_app_bundle.sh`、`Makefile`、
    `.github/workflows/release.yml`、`README.md`、`packages/driver/README.md`、
    `apps/mac/SoundBridgeApp/Sources/{App/SoundBridgeApp.swift,Onboarding/OnboardingView.swift,Services/DriverInstaller.swift,Services/IPCController.swift,Views/MenuBarView.swift}`、
    `packages/host/Sources/SoundBridgeHost/{main.swift,Constants.swift,Devices/DeviceMonitor.swift}`（`Lifecycle/` 为新增目录）
  - 其余为前序阶段（2.1.1 / 2.1.2 / 2.1.3）在同一工作区内累积的修改，本阶段未回退
- 未跟踪新增（本阶段产生的主要部分）：
  - `packages/host/Sources/SoundBridgeHost/Lifecycle/{HostInstanceLock,DriverLifecycle,HostLifecycleReporter}.swift`
  - `packages/host/Tests/SoundBridgeHostTests/{HostInstanceLockTests,DriverLifecycleTests,DriverHeartbeatCrossProcessTests}.swift`
  - `apps/mac/SoundBridgeApp/Sources/Models/{HostLifecycleReport,HostStatusModel}.swift`
  - `apps/mac/SoundBridgeApp/Sources/Services/{DriverVersionGate,DriverCompatibilityNotice,HostInstanceProbe}.swift`
  - `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/{HostRunStateTests,HostInstanceProbeTests,DriverInstallIntentTests,DriverCompatibilityNoticeTests,DriverVersionGateTests}.swift`
  - `tools/{verify_release_bundle,check_protocol_layout,sync_shared_header}.sh`、`packages/shared/`
  - `docs/1.2.0/`、`AUDIT_REPORT.md`、`POC_REPORT.md`、`.qoder/`（工具缓存，未纳入版本控制）
- `git diff --check` 退出码 0：无行尾空白、无冲突标记。
- 未创建 Tag，未修改 `.gitmodules`，未删除任何未跟踪文件，未覆盖用户既有改动。

---

## 10. 最终放行结论

### **CONDITIONAL PASS（有条件通过）**

**通过的理由**（全部有可复现的命令证据）：

1. Host 单实例保护从「进程名匹配」换成 POSIX `flock`，获取在触碰任何共享状态之前，
   第二个实例以 3/4 退出且不 unlink、不创建、不清理；10 项真实子进程测试覆盖
   「被杀死的 Host 不留锁」与「残留文件不等于锁被持有」两个关键反例。
2. 启动成功不再由 `Thread.sleep` 断言。七级状态各自可观测、8 种 outcome 互不替代，
   无代理设备时进入 `enterDegraded` 而不是继续报成功。
3. 心跳的「冻结 = idle」与「冻结 = 故障」被显式分开，双阈值有各自的物理理由，
   且用真实子进程验证而不是只跑 Swift 单测。
4. 升级能力保留、入口全部关闭：三个策略常量分别是 false / false / true，
   `intent` 门禁在函数首行；同时 §2.4 的兼容性提示落地为纯文本、地址来自真实
   `Info.plist`，静默失败这一侧也被堵上。
5. 发布链路发现并修复了一个会静默出错的 P0（Sparkle 框架从未进产物），
   三条构建路径统一 staging，打包脚本改为硬失败，守卫脚本改为签名前校验双架构。
6. 全量回归：`protocol-check` / `test`（212 项，0 失败，0 跳过）/ `quick` /
   `verify_release_bundle` / `git diff --check` / `bash -n` 全部退出码 0。

**条件**（不满足则不应据此报告发布）：

1. **P1-1 需要人类决策**：协议代际变更后 App 内没有 Driver 重装路径，
   §2.4 提示指向的恢复动作实际不可执行。这不是代码缺陷，是产品决策缺口，
   但它决定了「用户看到提示之后能做什么」，因此不能算已闭环。
2. **Intel 真机未验证**：双架构只有静态证据，没有在 x86_64 上启动过产物。
3. **正式发布链路未执行**：未建 Tag、未改版本号、未签名、未公证、未推送。
   本报告的结论只覆盖「产物能正确组装」与「回归全绿」，不覆盖「已发布的包可用」。

**不建议**在修完上述第 1 项之前把 §2.4 提示当作「用户已有恢复路径」写进发布说明。

---

## 附录 A：本阶段新增／修改的可执行代码与脚本

新增（Swift）：

- `packages/host/Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift`
- `packages/host/Sources/SoundBridgeHost/Lifecycle/DriverLifecycle.swift`
- `packages/host/Sources/SoundBridgeHost/Lifecycle/HostLifecycleReporter.swift`
- `apps/mac/SoundBridgeApp/Sources/Models/HostLifecycleReport.swift`
- `apps/mac/SoundBridgeApp/Sources/Models/HostStatusModel.swift`
- `apps/mac/SoundBridgeApp/Sources/Services/DriverVersionGate.swift`
- `apps/mac/SoundBridgeApp/Sources/Services/DriverCompatibilityNotice.swift`
- `apps/mac/SoundBridgeApp/Sources/Services/HostInstanceProbe.swift`

修改（Swift）：

- `packages/host/Sources/SoundBridgeHost/main.swift`（Step -1 锁、Step 6 就绪轮询、
  Cleanup 最后一行的释放、`restartsCoreAudioOnExit` 门禁）
- `packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift`（删除 `reloadDriver()`）
- `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift`（删除两个启动期驱动检查函数、
  `applyHostLifecycle` 传入 report、接上兼容性提示）
- `apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift`（唯一特权入口 + intent 门禁，
  删除 4 个符号与 3 个错误 case）
- `apps/mac/SoundBridgeApp/Sources/Onboarding/OnboardingView.swift`（首次安装与升级分离）
- `apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift`（`HostStatusRow`）

脚本 / CI：

- `tools/build_release.sh`、`tools/create_app_bundle.sh`、`tools/verify_release_bundle.sh`
- `Makefile`、`.github/workflows/release.yml`
- `README.md`、`packages/driver/README.md`

测试（App 新增 50 项 + Host 新增 29 项 = 79 项）：

- `packages/host/Tests/SoundBridgeHostTests/HostInstanceLockTests.swift`（10）
- `packages/host/Tests/SoundBridgeHostTests/DriverLifecycleTests.swift`（14）
- `packages/host/Tests/SoundBridgeHostTests/DriverHeartbeatCrossProcessTests.swift`（5）
- `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRunStateTests.swift`（21）
- `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostInstanceProbeTests.swift`（10）
- `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallIntentTests.swift`（9）
- `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverCompatibilityNoticeTests.swift`（10）
- `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverVersionGateTests.swift`（既有 30 项，本阶段改写）
