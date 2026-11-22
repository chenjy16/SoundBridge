# SoundBridge 1.2.1 — Product Quality & Reliability Report

| 项 | 值 |
|---|---|
| 状态 | **未发布**。本文只记录工作树中的实现与证据 |
| 日期 | 2026-11-22 |
| 仓库 | `/Users/chenjianyu/CodeGeeXProjects/SoundBridge` |
| HEAD | `fc09aee` — *Release 1.2.0: unsigned distribution workflow*（`tag: v1.2.0`, `origin/main`） |
| `VERSION` | `1.2.0`（**未改动**） |
| 共享内存协议 | `0x00020200`（131584，**未改动**） |
| 执行范围 | Stage A 基线 → B 设计 → C/D/E 实现 → F 回归 → H 文档 → I 本报告 |
| 未执行 | staging / commit / push / tag / publish、真机装/卸驱动、重启 `coreaudiod`、改默认输出、中断播放、删用户配置、改安全设置（均需 Stage G 授权） |

---

## 1. Executive Summary

**总体结论：CONDITIONAL PASS**

三项 P1 的根因均已定位，修复已实现，并各自配有回归测试；全量自动化回归、通用二进制构建、
安装包结构、协议/ABI 与「未签名发布策略」检查全部通过，退出码为 0。没有引入签名、公证、
自动更新，没有改动版本号、协议、ABI、deployment target 或 bundle id。

结论之所以是**有条件**，而不是 PASS：

1. 三项修复都还没有在真实显示器 + 真实 HAL 驱动上执行过。音量/静音提交、EQ 恢复、
   真实卸载这三条端到端路径属于 Stage G 的保护操作，本轮未获授权。
2. OBS-1 在驱动侧没有被「证明消除」。本轮的修复是让 App 不再把未落地的写入显示为成功，
   并让 Host 把已接受的值提前提交进共享内存，使下一次 `OnStartIO` 握手不再采用旧值；
   驱动的控制对象写入路径本身**未修改**（改它意味着触碰 ABI 语义，超出本次范围）。

| 目标 | 实现 | 自动化证据 | 真机 |
|---|---|---|---|
| P1-1 无 I/O 客户端时音量/静音提交 | 完成 | 41 个新单测 + App 298 / Host 398 全绿 | `NOT VERIFIED` |
| P1-2 EQ 持久化（含到达 DSP） | 完成 | 15 个新单测（读真实 mmap）+ 既有 EQ 套件全绿 | `NOT VERIFIED` |
| P1-3 卸载生命周期完整化 | 完成 | 19 组场景 / 99 断言真实执行 + 8 个源码 gate | `NOT VERIFIED` |
| 架构/协议/ABI 不变 | 完成 | `protocol-check`、`version-check`、`test-unsigned` | — |
| 文档 | 完成 | 5 处直接受影响文档 | — |

---

## 2. Baseline

### 2.1 仓库状态

| 项 | 值 |
|---|---|
| HEAD | `fc09aee`（`tag: v1.2.0`，与 `origin/main` 一致） |
| 分支 | `main` |
| 子模块 | `git submodule status` 输出 ` 633e0f7…`（无 `+`/`-`，工作树与记录一致） |
| 初始工作树 | 45 项未提交改动，**全部是此前批次遗留的文档/报告**，无一项来自本任务 |
| 初始源码改动 | 0（`packages/*/Sources`、`apps/mac/SoundBridgeApp/Sources`、`tools/` 在基线时均干净） |

基线时已存在、本次**未触碰**的未提交改动（按文件 mtime 归属）：

- 新增报告类：`docs/P1-*`、`docs/P2-*`、`docs/P3-*`、`docs/Research-Directory-Retirement-Report.md`、
  `docs/release/SoundBridge-1.2.0-Final-Release-Report.md`、
  `docs/release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md`、
  `docs/release/Documentation-Consolidation-Report.md`、`docs/development/`、`docs/manifests/`
- 已修改：`README.md`（此前已重写）、`apps/mac/SoundBridgeApp/README.md`、`packages/host/README.md`、
  `packages/driver/README.md`、`docs/README.md`、`docs/architecture/SoundBridge-1.2.0-Architecture.md`、
  `docs/release/SoundBridge-1.2.0-Release-Checklist.md`、`docs/risks/Known-Limitations.md`

其中 `README.md`、`docs/README.md`、`docs/risks/Known-Limitations.md` 在本次 Stage H 中**再次被追加**，
下文 §6.5 单列。

> **后续状态变更（2026-11-22，本报告定稿之后）**：上表列出的阶段报告、审计与验证归档
> （`docs/P1-*`、`docs/P2-*`、`docs/P3-*`、`docs/P4-*`、`docs/1.2.0/`、`docs/verification/`、
> `Documentation-Migration-Manifest.md`、`docs/manifests/`、`Documentation-Consolidation-Report.md`、
> `release/P4-Batch-7`、`release/P4-Batch-8`、`Research-Directory-Retirement-Report.md`，
> 共 39 份）已按用户指示从 `docs/` 移出并从仓库删除，本地归档不参与提交；
> 引用它们的正式文档已在同一提交中去掉链接。本报告正文保持定稿时的状态描述不变。

### 2.2 构建环境

| 项 | 值 |
|---|---|
| 平台 | macOS 27.2.1（`26B131`）/ arm64 |
| Swift | Apple Swift 6.4.2（`swiftlang-6.4.2.1.9`，`clang-2100.4.1.1`） |
| Clang | Apple clang 21.0.0 |
| 构建系统 | CMake（DSP、Driver）、SwiftPM（Host、App） |
| 驱动依赖 | `libASPL` 子模块（`git submodule status` 干净） |
| 签名 | 无。未使用 Developer ID，未 ad-hoc 签名，未公证 |

### 2.3 变更归属的判定方法

本轮不使用「`git diff --stat` 总量」作为改动规模，因为它包含基线遗留的文档改动。改用文件
mtime 精确切分：本任务写入的文件 mtime 为 `2026-11-22 12:17`（C/D 阶段）、`12:39`（E 阶段）、
`12:55–13:0x`（H 阶段与本报告）；此前批次的文件 mtime 均 ≤ `2026-11-22 00:43`。

---

## 3. P1-1 音量与静音

### 3.1 根因

故障现象（1.2.0 发布验证 OBS-1）：在没有 I/O 客户端窗口、没有播放时，对代理设备写入音量
或静音可能不提交——`set volume` 返回成功，但系统读数与共享内存保持旧值；在播放中重新设置
一次才生效。

三个叠加的层：

1. **Host 侧：提交被绑在「转发」上。** `ProxyDeviceManager` 收到代理设备的音量/静音属性变化
   后，唯一的下游动作是「转发给物理设备」，而转发受 `DefaultOutputPolicy.mayForwardVolume`
   门控（只有代理设备是系统默认输出时才允许）。持久化 `volumePersistence.save` 也写在转发
   路径内部。因此当 SoundBridge 不是当前默认输出，或没有任何客户端打开设备时，观测到的值
   既不落盘、也不进共享内存。
2. **驱动侧：提交值只在 `OnStartIO` 被采纳。** 驱动在 `SoundBridgeVolumeControl` 中把共享
   内存的音量状态当作权威，但只在 `OnStartIO` 握手时把它装进控制对象。没有播放 → 没有
   `OnStartIO` → 新值只停留在 HAL 控制里；下一次播放的第一次握手用旧值覆盖它。这正是
   「播放中重设一次就生效」的机制解释。
3. **App 侧：请求值被当作结果。** `VolumeController.setVolume`/`setMute` 返回 `Void`，只要
   `AudioObjectSetPropertyData` 返回 `noErr` 就把请求值写进 `@Published`。一个「接受写入
   随后丢弃」的控制对象因此看起来已经生效。

### 3.2 改动文件

| 文件 | 性质 | 内容 |
|---|---|---|
| `apps/mac/SoundBridgeApp/Sources/Services/VolumeLevelControl.swift` | 新增 206 行 | `ControlCommitResult<Value>`（`committed`/`rejected`/`notVerified`/`unavailable`）、`VolumeLevelWriting` 协议 seam、`VolumeLevelCommit`（写 + 回读判定）、代理侧一级 taper 容差 |
| `apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift` | 修改 | `setVolume`/`setMute` 改为 `@discardableResult` 返回提交结果；只有 `.committed` 才更新 UI；`.notVerified`/`.rejected` 走 `os.log`；诊断探测移出成功路径 |
| `packages/host/Sources/SoundBridgeHost/Devices/DeviceVolumeHAL.swift` | 新增 148 行 | 读/写设备自身 volume/mute 的单一 seam，供测试注入 |
| `packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift` | 修改（+309/−…） | 属性监听回调先 `commitObservedProxyVolumeState()` 再转发；`onProxyVolumeStateCommitted` 回调；`lastCommittedProxyState` + 3 次收敛重读；`volumePersistence.save` 移出转发门控 |
| `packages/host/Sources/SoundBridgeHost/main.swift` | 修改 +10 行 | 把 `onProxyVolumeStateCommitted` 接到 `SharedMemoryManager.publishVolumeState` |
| `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/VolumeLevelCommitTests.swift` | 新增 363 行 / 22 例 | 提交语义 |
| `packages/host/Tests/SoundBridgeHostTests/ProxyVolumeCommitTests.swift` | 新增 491 行 / 19 例 | 提交路径、收敛、门控分离 |

### 3.3 实现要点

- **「写了」和「生效了」分开。** 写入走 `VolumeLevelWriting`；只有代理设备的回读被用来判定
  是否真的落地。容差是 48 级 taper 中的一级（`sqrt(scalar)` 空间 `1/48`），因为代理设备会把
  标量量化到自己的 raw 步进（libASPL 的 Pow2 传递函数 + `MaxRawVolume = 48`）。
- **物理设备不回读判定。** 第三方设备的量化粒度未知，用代理的容差去判定会误拒合法变化，
  所以物理设备仍以 HAL 状态码为准。这一取舍登记为 Known-Limitations §2B B-3。
- **提交与转发解耦。** 提交永远正确，转发只在代理是默认输出时正确。提交会先落盘（`VolumeState`
  是下一次 Host 启动时 `VolumeStateResolver` 的首选来源），再发布进共享内存；发布失败不记录
  「已完成」，下一次变化会重试。
- **收敛。** 发布期间用户可能又动了一次滑块，因此最多重读 3 次（2 次额外），避免把后一次变化
  只留在控制对象里。
- **线程。** 属性监听回调由 C 函数指针进入 CoreAudio 线程后立即 `DispatchQueue.main.async`，
  提交与 UI 更新都在主线程；`lastCommittedProxyState` 只被主线程访问。
- **实时约束。** `AudioRenderer.swift` 未被本次改动触碰，渲染回调里没有新增 I/O、锁或分配。

### 3.4 回归测试

`VolumeLevelCommitTests`（22 例）覆盖：proxy 提交与回读一致、一级量化内接受、量化超出一级判
`notVerified`、回读失败判 `notVerified`、所有 element 拒绝判 `rejected`、无目标判 `unavailable`、
clamp、物理设备只看状态码、mute 双向。

`ProxyVolumeCommitTests`（19 例）覆盖：默认输出关闭时仍然提交、转发仍被门控、发布失败不记账、
下一次变化重试、收敛重读、设备切换清缓存、`restoreVolumeState` 不被误认为用户变化。

### 3.5 结果与真机状态

- App 全量 298 例、Host 全量 398 例通过（§6）。
- **真机：`NOT VERIFIED`。** 「无播放会话时设置音量/静音 → 开始播放 → 值仍是用户选的」这条
  路径未在真实显示器上执行。

---

## 4. P1-2 EQ 持久化

### 4.1 根因

故障现象（OBS-2）：运行时 EQ 正常，退出 App 再启动后共享内存恢复为拖动**之前**的值。

根因是缓存推进与持久化分离：

1. 限流管道（`Publishers.CombineLatest3 → throttle`）的 sink 里，先做变化检测，**没有变化就
   提前 `return`**——而 `saveToUserDefaults()` 写在 `return` 之后。
2. 滑块释放调用 `flushToSharedMemory()`，它把 `lastBass/lastMids/lastTreble/lastBypass` 直接
   推进到当前值，**不经过上面那条管道**。
3. 于是「松手」这一事件把待写值与缓存对齐；随后管道再收到一次投递时，变化检测认为「没变」，
   直接返回，最终值永远不会被保存。用户在拖动过程中看到的值是旧历史值——正是 OBS-2 记录的
   `Bass 11.747 / Mids 1.278 / Treble −2.202`。

次要缺陷：四个值分四个 key 独立写入，两次 `set` 之间崩溃会得到「一次拖动的增益 + 另一次拖动的
bypass」；读取时用 `as? Float` 判断存在性，无法校验非有限值（`NaN` 与任何数比较都为 false，
`clampGain` 修不了它）。

### 4.2 配置归属

| 数据 | 所有者 | 位置 | 谁能写 |
|---|---|---|---|
| EQ 值（bass/mids/treble/enabled） | **App** | `UserDefaults`（`com.soundbridge.menubar`） | 只有 `EQController` |
| EQ 运行时值 | 共享内存 | `RFSharedAudio` 的 `eq_snapshot` + `eq_sequence` | App 写，Host/DSP 读 |
| Host/DSP 持久化 | 无 | — | Host 与 DSP 不保存任何 EQ 状态 |

Host 只是消费者：App 不在时，Host 不会「猜」EQ；App 启动后由 `EQService.shared`（进程内唯一
writer）在 `mapping.start()` 之前创建控制器，订阅之后立刻用当前 generation 补发一次。

### 4.3 存储机制

- 每台设备一个字典，一个 key：`eq_<deviceUID>_state` = `{bass, mids, treble, enabled}`。
  生产路径 `deviceUID = "default"`，即 `eq_default_state`。
- 1.2.0 的四个 key（`eq_<uid>_bass_db` 等）**只读**：新 key 不存在时读一次、写回新形状，
  之后不再写旧 key。升级不会把用户的 EQ 抹平。

### 4.4 原子性与失败处理

- **整组替换。** 一次 `set` 写一个字典，`cfprefsd` 以整体替换该值，崩溃不会产生「半次拖动」。
- **字段级校验。** `EQPersistedState.decode` 逐字段解码：非数值/非有限 → 该字段回落默认值，
  其余三个字段保留；有限但越界 → clamp（真实值传输损坏，不该丢）；bypass 不是布尔 → 回落
  `enabled`（用户能看到并纠正的状态）。布尔判定用 `CFGetTypeID == CFBooleanGetTypeID()`，
  因为 `NSNumber` 会把 `true` 读成 1.0。
- **失败不推进缓存。** 只有 `.written(generation)` 才更新「已应用」状态；未落地时
  `isAppliedToCurrentMapping = false`，下次映射出现时重发。
- **立即持久化的动作。** Reset 是按钮而不是拖动，因此立即 `saveToUserDefaults()`，避免「点完
  立刻退出」丢失。

### 4.5 改动文件

| 文件 | 性质 | 内容 |
|---|---|---|
| `apps/mac/SoundBridgeApp/Sources/Services/EQController.swift` | 修改 +222/−… | `EQDefaultsKey.state`、`EQPersistedState`（dictionary/decode）、`saveToUserDefaults` 单 key、`loadFromUserDefaults` 新 key → 旧 key 迁移 → flat、管道内持久化移出早退分支、`reset` 立即保存 |
| `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQPersistenceTests.swift` | 新增 342 行 / 15 例 | 含读真实 mmap 的「恢复值到达 DSP」用例 |
| 5 个既有 EQ 测试 | 修改 +1 到 +2 行 | 清理/断言新 key |

### 4.6 回归测试

`EQPersistenceTests`（15 例）覆盖：

- 松手后退出 → 重新构造控制器 → 内存值等于最后一次拖动；
- 新 key 缺失时从 1.2.0 四 key 迁移，并只写一次；
- 字段级降级：`bass` 存字符串 → bass 回落、其余三个字段保留；
- `NaN`/`inf` 被丢弃、越界有限值被 clamp；
- `enabled` 存非布尔 → 回落启用；
- **恢复值到达 DSP**：新建控制器后直接读取映射中的 `eq_snapshot` 与 `eq_sequence`，断言增益
  与序列号已经落地，而不是等待用户拖动；
- Reset 立即持久化。

### 4.7 结果与真机状态

- 15 例全绿；App 全量 298 例通过。
- **真机：`NOT VERIFIED`。** 「App 重启 / Host 重启 / 驱动重连后 EQ 数值不变且听感不变」未在
  真实显示器上执行；`EQPersistenceTests` 读的是真实 mmap 文件，但它不是真实驱动。

---

## 5. P1-3 卸载生命周期

### 5.1 根因

1.2.0 的 `tools/uninstall_driver.sh` 只做了一件事：识别并删除一个 bundle。围绕它的生命周期是
空的：

- **没有停 Host。** 卸载后 Host 仍在运行，继续读一个驱动已经消失的映射；重装后会出现两个
  Host 竞争同一块共享内存的时序窗口。
- **没有释放运行期 IPC。** `/tmp/soundbridge-<uid>-*` 与 `soundbridge-devices.txt` 留在原地，
  下一次启动可能 attach 到上一次的 inode。
- **报告无法区分两件事。** 「文件删了」与「驱动已从 `coreaudiod` 卸载」是不同的事实，但旧输出
  只有一句「Removed」。
- **两个前端副作用不一致。** 删除路径在 1.2.0 已由 `DriverUninstallPolicy` 统一，但 App 会清
  引导状态、脚本不会；脚本是唯一能在 App 被删后运行的入口，却没有这条边界说明。

### 5.2 安装所有权清单（脚本头部的 manifest）

| class | path | action |
|---|---|---|
| installation | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` | 识别后删除 |
| installation | `/Applications/SoundBridge.app` | 只报告，永不删除 |
| runtime | `/tmp/soundbridge-<our uid>-*` | 删除 |
| runtime | `/tmp/soundbridge-devices.txt` | 确认属于本用户后删除 |
| user state | `~/Library/Application Support/SoundBridge` | 保留 |
| user config | `~/Library/Preferences/com.soundbridge.menubar.plist` | 保留 |
| user data | `~/Library/Logs/SoundBridge` | 保留 |
| installer | SoundBridge 的 package receipt | 只报告，永不修改 |
| system | `coreaudiod` | 永不发信号 |

### 5.3 运行期清理清单

- 只匹配 `/tmp/soundbridge-<本进程 uid>-*` 与 `soundbridge-devices.txt`；测试显式断言
  `soundbridge-<uid>0-x`（uid 前缀相似但不同）与 `.driver.bak` 不被删除，且共享内存删除计数
  恰好等于预期。
- 删除失败不是警告：计入 `failed`，报告附加「N could not be removed」，退出码 1。
- 计数语义分开：`removed N shared-memory file(s)` + 可选 `and the device control file`。

### 5.4 Receipt 与 InstallerState

- 只报告，不删除。理由写在脚本头部：receipt 描述的是「这个包被装过」，不描述磁盘现状，也不是
  驱动加载的原因；删掉它不会卸载任何东西（`coreaudiod` 仍持有已加载副本）。
- `installer.db` / `InstallerState` 属于 macOS。为了让输出好看去写它，正是「表面干净、实则
  不受支持」的系统操作。
- App 侧同样不删；用户需要时可自行 `sudo pkgutil --forget com.soundbridge.menubar`（文档给出）。

### 5.5 CoreAudio 生命周期

四态分开报告，只有第一态由脚本完成：

| 状态 | 报告 | 由脚本完成 |
|---|---|---|
| 1. 驱动文件已从磁盘删除 | yes / no | 是（`--dry-run` 除外） |
| 2. 已从 `coreaudiod` 卸载 | `no — coreaudiod keeps its loaded copy` | 否 |
| 3. CoreAudio 设备已消失 | 重启 `coreaudiod` 前不会 | 否 |
| 4. `coreaudiod` 已重启 | `no — this script never signals it` | 否 |

进程处理：只对「可执行文件在本 App bundle 内 + 属主是自己」的进程发 `SIGTERM`，`--timeout`
（默认 5 s）内有界等待，超时后对**同一个 pid** 升级 `SIGKILL`。`ps` 不可读时报告
`not verified: process state is unreadable here`，**绝不**说「没有 Host 在运行」。僵尸进程
（`ps -o stat=` 以 `Z` 开头）视为已退出，避免对已消失的进程报告失败。

### 5.6 改动文件

| 文件 | 性质 | 内容 |
|---|---|---|
| `tools/uninstall_driver.sh` | 重写（542 行） | 四阶段、所有权清单、进程识别、有界等待、IPC 释放、四态报告、`--keep-host` / `--timeout` / `--sandbox-root`、失败即非零 |
| `tools/test_uninstall_lifecycle.sh` | 新增 572 行 | 19 组场景 / 99 断言，`--sandbox-root` 真实执行 |
| `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/UninstallLifecycleScriptTests.swift` | 新增 155 行 / 8 例 | 源码不变量 |
| `Makefile` | 修改 +18/−4 | `test-installer` 接入卸载生命周期套件 |

### 5.7 回归测试

脚本套件（19 组 / 99 断言）：正常卸载、重复卸载（幂等）、部分安装、完全未安装、App 已删、
Host 响应 `TERM` 优雅退出、Host 忽略 `TERM`（1 s 有界等待后 `SIGKILL`）、`--keep-host`、
`--dry-run` 不改动任何东西、删除范围、清理失败、驱动删除失败（`chmod 500` HAL 目录）、拒绝
外来 bundle / 符号链接 / 普通文件 / 无 plist、用法错误、`--help`、源码 gate。

Swift gate（8 例）：脚本删除的路径与 `DriverUninstallPolicy` 一致（且展开后的命令字符串相等）、
识别先于停止与删除、dry-run 早于删除调用、四态文本分开、可执行行中除建议句外不得出现
`killall`/`launchctl`/`pkill`/`sudo`/`kext*`、用户数据列为 kept、receipt 不得 `--forget`、
脚本可执行且已接入 `make`。

### 5.8 结果与真机状态

- 刚重跑：`99 passed, 0 failed, 0 skipped`，退出码 0；8 个 Swift gate 全绿。
- **真机：`NOT VERIFIED`。** 对真实 `/Library/Audio/Plug-Ins/HAL/`、真实 Host 与真实
  `coreaudiod` 的卸载未执行。沙盒树验证的是脚本逻辑与进程语义，不是真实加载状态。

---

## 6. Regression Results

### 6.1 自动化测试

| 命令 | 结果 | 退出码 |
|---|---|---|
| `cd apps/mac/SoundBridgeApp && swift test` | **298 tests, 0 failures** | 0 |
| `make test-host`（先 `dsp-build`） | **398 tests, 0 failures** | 0 |
| `make test-dsp` | ctest 1/1 passed | 0 |
| `make test-driver` | ctest 3/3 passed（`mktemp` 临时目录构建） | 0 |
| `./tools/test_install_transaction.sh` | **168 passed, 0 failed**；未触碰 HAL 目录 | 0 |
| `./tools/test_uninstall_lifecycle.sh` | **99 passed, 0 failed, 0 skipped** | 0 |
| `make test-unsigned` | **97 checks, 0 failures** | 0 |
| `make protocol-check version-check` | `VERSION_SOURCES_CHECKED=11`、`FAILED=0`、`VERSION_CONSISTENCY=PASS`；`0x00020200 (131584)` | 0 |

`make test-installer` 是 `test_install_transaction.sh` + `test_uninstall_lifecycle.sh` 的封装，
两者在同一目标下连续通过。

### 6.2 构建验证

| 命令 | 结果 |
|---|---|
| `SB_DIST_DIR=$(mktemp -d) ./tools/build_release.sh` | App / Host / Driver 全部构建成功，`lipo -archs` 均为 `x86_64 arm64`；`dist/` 未被写入 |
| 驱动 bundle scratch 构建 | 产出 `SoundBridgeDriver.driver`；未污染 `packages/driver/build` |

### 6.3 包验证

| 命令 | 结果 |
|---|---|
| `./tools/build_installer_pkg.sh --app <新构建 bundle> --out <tmp> --version 1.2.0` | 产出 `SoundBridge-1.2.0.pkg` |
| `./tools/verify_installer_pkg.sh` | PASS |
| `./tools/verify_pkg_driver.sh` | `STRUCTURAL_PASS`；`TeamIdentifier=not set`（未签名策略的预期值） |
| `./tools/verify_pkg_contents.sh --pkg-only --app <bundle>` | PASS（DMG 相关比较 `SKIPPED`：本轮不产出 DMG） |
| `./tools/test_installer_preinstall.sh` | **83 assertions passed, 0 failed** |

### 6.4 真机验证

**本轮未执行任何真机操作。** 以下为 `NOT VERIFIED`：

- 无播放会话时设置音量/静音 → 开始播放 → 值保持（P1-1）；
- App 重启 / Host 重启 / 驱动重连后 EQ 数值与听感保持（P1-2）；
- 真实卸载 → 系统设备消失 → 重装 → 恢复（P1-3）；
- 双击 PKG 的 Gatekeeper 批准路径、Intel Mac、macOS 13/14。

### 6.5 文档改动（Stage H）

| 文件 | 改动 |
|---|---|
| `README.md` | Features 增加「UI 只显示设备接受的值」「EQ 按设备保存并在启动时重发」；重写卸载段（四阶段、四态、保留项）；`make test` 行加入卸载生命周期；Project status 增加「未发布工作」小节 |
| `docs/INSTALLATION_GUIDE.md` | §9 卸载整节改写为英文（四阶段、四态表、运行方式、删除/保留清单、receipt 处理与恢复命令）；§12 的 §9 证据行更新为「沙盒真实执行」 |
| `docs/RELEASE_NOTES.md` | 顶部加「没有 1.2.1 发布」提示；文末新增 `# 1.2.1 (unreleased)`（英文）三节变更说明 + 未验证项 + 降级说明；1.2.0 正文未改 |
| `docs/risks/Known-Limitations.md` | 新增 §2B：OBS-1/2/3 的工作树状态与仍缺证据、B-1 降级读旧值、B-2 receipt 保留、B-3 回读容差只对代理生效；§2A 历史记录原样保留 |
| `docs/development/DEVELOPMENT_GUIDE.md` | §5 测试表更新；新增 §5.1 卸载生命周期测试怎么跑（含跳过条件与 `pwd -P` 原因）；§7 代码地图新增 3 行 |
| `docs/README.md` | 文档地图加入本报告；§4「已发布资产」增加状态说明（两个用户文档已被改写、不再与发布哈希一致、未发布） |

`docs/README.md` §4 原本把 `INSTALLATION_GUIDE.md` 与 `RELEASE_NOTES.md` 登记为「已发布资产，
不要就地改写」。Stage H 明确要求更新这两类内容，因此本次改写并在同处登记了这次偏离，避免
后来者误以为仓库仍与已发布件字节一致。

---

## 7. Security and Safety Review

| 要求 | 结论 | 证据 |
|---|---|---|
| 未引入签名或公证 | 通过 | `make test-unsigned` 97 checks；`codesign.sh`/`notarize.sh` 仍是拒绝执行的存根；构建脚本未新增 `codesign` |
| 未改动 SIP / Gatekeeper | 通过 | 无 `csrutil`、`spctl --master-disable`，无 `defaults write com.apple.*`；新增文本只有「由用户决定何时重启」的建议 |
| 未删除无关文件 | 通过 | 卸载脚本的所有权清单（§5.2）+ 测试断言 `soundbridge-<uid>0-x`、`.driver.bak` 保留、删除计数恰为 2；`/bin/rm -rf` 只有一个常量路径 |
| 未在实时回调中新增不安全操作 | 通过 | `AudioRenderer.swift` 未修改；新增工作都在 CoreAudio 属性监听回调（已 `DispatchQueue.main.async`）与 SwiftUI 状态更新中；渲染路径无 I/O、无锁、无分配新增 |
| 未在未授权情况下删除用户配置 | 通过 | App 与脚本都不删 Application Support / Logs / Preferences；`pkgutil --forget` 只作为文档里的可选步骤出现；测试断言可执行行中不含 `--forget` |
| 未执行破坏性 Git 操作 | 通过 | 全程无 `reset`/`clean`/`checkout`/`restore`/`stash`/`commit`/`push`/`tag`；HEAD 仍为 `fc09aee`；submodule 仍干净 |

其他安全属性：

- 脚本在无法读取进程表时**不**给出「没有任何 Host 在运行」的结论（避免假阴性）。
- 脚本对僵尸进程（`Z`）不报告失败，避免对已退出进程升级 `SIGKILL`。
- 卸载脚本的 `--sandbox-root` 只重定根，不改变删除命令的形状。

---

## 8. Version and ABI Integrity

| 项 | 值 | 是否改动 |
|---|---|---|
| `VERSION`（仓库文件） | `1.2.0` | 否 |
| `CFBundleShortVersionString` | `1.2.0`（App / Driver / Host） | 否 |
| `CFBundleVersion`（Build Number） | `1.2.0`（App / Driver / Host） | 否 |
| PKG 版本 | `1.2.0`（`build_installer_pkg.sh --version 1.2.0`） | 否 |
| 共享内存协议 | `0x00020200` = 131584 | 否 |
| 共享内存头大小 | `RF_SHARED_AUDIO_HEADER_SIZE = 320` | 否 |
| Bundle ID | `com.soundbridge.menubar` / `com.soundbridge.driver` / `com.soundbridge.host` | 否 |
| Deployment target | macOS 13.0（`Package.swift` 两处 `.macOS(.v13)`；`CMAKE_OSX_DEPLOYMENT_TARGET "13.0"`） | 否 |
| `packages/shared/include/RFSharedAudio.h` | 未修改（不在改动清单中） | 否 |

`make protocol-check` 断言「单一协议源 + 三份头副本一致 + C11/C++17 布局」；`make version-check`
逐个核对 11 个版本源，`FAILED=0`。二者在文档改动之后重跑仍然通过。

---

## 9. Remaining Risks

| 严重度 | 风险 | 说明 | 缓解 |
|---|---|---|---|
| **高** | 三项修复均未真机验证 | 只能在真实显示器 + 真实驱动上确认「无播放时提交」「EQ 恢复」「真实卸载」 | Stage G 授权后按 §10 的清单执行 |
| **中** | OBS-1 的驱动侧机制未改 | 驱动仍在 `OnStartIO` 采纳提交值；本轮靠 Host 提前提交规避 | 真机验证若仍复现，需改驱动侧（会触碰 ABI 语义，需单独授权） |
| **中** | 物理设备不回读 | 第三方设备「接受写入但不生效」时 UI 仍可能显示请求值 | 已登记 B-3；按 `os.log` 诊断行取证 |
| **中** | EQ 降级到 1.2.0 读旧值 | 1.2.0 只读四个旧 key，1.2.1 不再写它们 | 已登记 B-1；升级方向有迁移，不受影响 |
| 低 | 卸载器不删 receipt / InstallerState | 重装仍可能走升级分支 | 已登记 B-2；文档给出 `pkgutil --forget` |
| 低 | 进程场景依赖 `ps`/`pgrep`/`clang` | 受限环境会跳过而非失败 | 跳过时打印具体探针原因；本机 0 skip |
| 低 | 收敛重读最多 3 次 | 极端快速连拖可能只保留最后一次观测值 | 下一次属性变化会再次提交；不影响稳态 |
| 低 | `RELEASE_NOTES.md` 中的 1.2.1 小节会在 1.2.1 发布时过期 | workflow 只校验版本号出现 | 发布前改写该小节 |

---

## 10. Release Recommendation

| 阶段 | 结论 |
|---|---|
| 内部测试（internal testing） | **可以** |
| 真机验证（real-machine validation） | **可以，需授权**。清单见下文 |
| 1.2.1 RC 准备（release candidate preparation） | **暂不可以**。三项修复的真机验证通过后才可进入 RC 打包 |
| 已发布 | **没有**。1.2.1 未发布，本轮未 stage/commit/push/tag/publish |

### 10.1 待授权的保护操作（Stage G 清单）

| # | 操作 | 期望效果 | 潜在中断 | 恢复 | 采集证据 |
|---|---|---|---|---|---|
| 1 | `sudo installer -pkg SoundBridge-1.2.0.pkg -target /`（新构建） | 替换 HAL 驱动与 App | 替换期间音频短暂中断；系统可能提示未签名 | 重装上一版 PKG，或运行卸载脚本后重装 | `pkgutil --pkg-info com.soundbridge.menubar`、HAL 目录清单、`log show --predicate 'process == "coreaudiod"'` 中的 `HALS_RemotePlugInRegistrar` |
| 2 | `tools/uninstall_driver.sh`（真实运行，非 `--dry-run`） | 删除驱动、停止自有 Host、释放 IPC | 设备消失，播放中断 | 重新安装 PKG | 脚本四态输出、退出码、HAL 目录清单、`/tmp` 残留检查 |
| 3 | `sudo killall coreaudiod` | 重新加载 HAL、设备消失后重现 | 所有正在播放的进程中断 | 系统自动重启 `coreaudiod` | 设备列表前后对比、`log show` |
| 4 | 在系统设置中切换默认输出到 `<display> (SoundBridge)` | 建立代理链路 | 其它输出静音 | 切回原设备 | `system_profiler SPAudioDataType`、App 设备列表 |
| 5 | 中断播放（`afplay` 前台中断 / 退出 App） | 验证 `OnStartIO` 边界 | 无（测试音频） | 重新播放 | 共享内存 `write_index`、`underrun`、`state_revision` |
| 6 | 删除用户配置：`rm -rf ~/Library/Application Support/SoundBridge`、`rm -rf ~/Library/Logs/SoundBridge`、`defaults delete com.soundbridge.menubar` | 验证「首次安装」路径 | 丢失 EQ / 音量 / 日志 | 无（不可逆；仅在可弃置的测试机上执行） | 卸载后目录清单、重装后默认值 |
| 7 | 修改安全设置（系统设置 → 隐私与安全性 → 仍要打开） | 走通 Gatekeeper 批准路径 | 无 | 无需回滚 | 截图、`spctl -a -vvv` 输出 |

### 10.2 真机验证脚本（授权后按序执行）

1. 无播放会话：设音量 60、静音、取消静音 → 读取设备标量（应分别约 0.5942、mute=1、mute=0）。
2. 立即开始播放 → 共享内存 `state_revision` 增长、`scalar`/`muted` 等于上一步、听感相符。
3. 调 Bass/Mids/Treble 到 +8/0/−8 → 退出 App → 重启 → 读 `eq_snapshot` 与 `eq_sequence`，应为
   最后一次的值且序列号已前进（不需要再动滑块）。
4. 退出并重启 Host（不动 App）→ 再读 `eq_snapshot`，值不变。
5. 卸载（脚本）→ 确认四态输出、HAL 路径消失、`/tmp` 无残留、Host 已退出、receipt 仍在。
6. 重启 `coreaudiod` → 设备消失；重装 PKG → 设备重现，音量/EQ 恢复。

以上任一步失败，都必须在本文追加一节「真机结果」并保持 1.2.1 未发布状态。
