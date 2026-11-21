# Phase 2.1.1（A）与 2.1.2（B）实施报告

- 范围：驱动安装版本门禁（P0）、共享内存文件级崩溃恢复测试（P1）
- 前置状态：Phase 2.1 已交付并停止（见 `PHASE2_1_REPORT.md`）
- 结论：A、B 均完成，`make test` 全绿。未提交、未推送、未改动子模块、未执行任何真实驱动安装

---

## 1. 实施摘要

| 子任务 | 交付物 | 状态 |
|---|---|---|
| A 驱动版本门禁 | `DriverVersionGate`（新）、`DriverVersionStatus`（新，7 态）、驱动 plist 协议号落盘、29 项单测 | 完成 |
| B 文件级恢复测试 | `SharedMemoryManager` 路径注入口、16 项场景测试 | 完成 |
| 附带修复 | 协议号与头文件一致性守卫（`check_protocol_layout.sh`） | 完成 |

未做的事：没有执行 `sudo`、没有调用 `installDriverWithPrivileges`、没有 `killall coreaudiod`、没有改动 libASPL 子模块、没有 `git add`/`commit`/`push`。

---

## 2. A 阶段：驱动安装版本门禁

### 2.1 审查发现：不只是"缺少版本门禁"

原报告把问题描述为"只判文件是否存在"。实际审查发现这条链上有三处叠加，任何一处单独修都不够：

1. **检测层**（`SoundBridgeApp.checkDriverVersionMismatch`）用 `VersionManager.driverNeedsUpdate()`，其实现是 `guard let installedVersion, let bundledVersion else { return false }`。驱动 `Info.plist` 读不出 `CFBundleShortVersionString` 时直接返回 `false` —— 元数据损坏的情况下**连提示都不会有**。
2. **执行层**（`DriverInstaller.installDriver`）第 64 行 `if isDriverInstalled() { state = .complete; return }`。检测层弹窗、用户点"Update Now"、调用 `installDriver()`，**直接短路返回**，一个字节都不会复制。
3. **反馈层**（`performDriverUpdate`）紧接着打印 `✓ Driver updated successfully` 并弹出"已更新到 1.2.0"。

三者叠加的结果：用户看到一个"更新成功"的提示，装着的仍是旧驱动，而新驱动会拒绝连接旧协议，于是"代理设备无声"且没有任何线索指向真正原因。

这条链是本阶段最重要的发现，它决定了验证不能只看"文件存在"。

### 2.2 状态模型

新增 `DriverVersionStatus`，7 个互斥状态：

| 状态 | 含义 | 需要安装 |
|---|---|---|
| `notInstalled` | 安装路径无 bundle | 是 |
| `compatible(version)` | 版本相符，且双方都声明协议时协议相符 | 否 |
| `outdated(installed, expected)` | 已装比 App 内置的旧 | 是 |
| `newer(installed, expected)` | 已装比 App 内置的新 | **否** |
| `metadataUnreadable(reason)` | bundle 在，但 `Info.plist` 缺失/损坏/缺版本键/协议键类型错 | 是 |
| `protocolIncompatible(version, installed, expected)` | 声明的协议版本与本构建不符 | 是 |
| `expectedVersionUnavailable` | App 自身内置驱动版本读不到，无从比较 | 是 |

`newer` 明确不安装：用旧驱动覆盖新驱动是静默降级，比"缺少门禁"更糟。此时 `requiresInstallation == false`，日志写明原因。

### 2.3 判定顺序

顺序本身是设计决策，写在 `DriverVersionGate.evaluate` 里：

1. bundle 不存在 → `notInstalled`
2. 期望版本为空 → `expectedVersionUnavailable`
3. plist 解析不出字典 → `metadataUnreadable`
4. `CFBundleShortVersionString` 缺失或空白 → `metadataUnreadable`
5. **协议键存在且不等 → `protocolIncompatible`**（先于版本比较）
6. 版本号数值比较 → `compatible` / `outdated` / `newer`

第 5 步排在版本号之前，因为协议是硬约束：驱动版本号再新，说不同的布局也不能用。有两条测试专门钉住这一点（`testProtocolMismatchOutranksVersionComparison`、`testProtocolMismatchOutranksNewerVersion`）。

### 2.4 为什么协议号要落盘

原本的 `Info.plist` 只有 `CFBundleShortVersionString`，没有协议字段。若只比版本号，`protocolIncompatible` 永远不可能触发，这个状态就是死代码；而且版本号没 bump 但协议改了的构建会被判为兼容。

因此：

- `packages/driver/Info.plist` 增加 `SBAudioProtocolVersion = 131328`（`0x00020100`）
- `tools/update_versions.sh` 从 `packages/shared/include/RFSharedAudio.h` 提取该宏并同步写入，不复制字面量

旧驱动（1.2.0 之前构建）没有这个键。缺键**不判错**——退化为版本号比较，这样既有旧驱动不会因新增字段被判成损坏。有测试覆盖（`testLegacyDriverWithoutProtocolKeyFallsBackToVersionComparison`）。

### 2.5 安装动作与判定分离

`installDriver()` 现在的结构：

```
读门禁 → 不需要安装则 .complete 返回
       → 需要安装：找 bundle → 提权复制 → 等待 coreaudiod → 重跑门禁验证
```

末尾的验证是关键改动：原来是 `fileExists(atPath:)`，现在改为重跑同一个 `currentInstallStatus()`。文件存在但版本不对，以前会通过验证，现在会抛 `verificationFailed`。这让"复制了但复制错"和"根本没复制"都无法伪装成成功。

`performDriverUpdate()` 同样在安装后重读门禁，弹窗内容由 `verified` 决定，分三种：`compatible` 报成功、`newer` 说明保留、其余报失败。假成功提示在当前代码路径下不可能再出现。

`isDriverInstalled()` 保留（`SettingsWindow` 显示用），注释明确写它是展示辅助、不是门禁。

### 2.6 防漂移守卫

新增的 `SBAudioProtocolVersion` 是第二处存放协议号的地方，会成为长期风险：协议 bump 后若 plist 未同步，门禁会要求重装一个装完仍报旧号的驱动，进入死循环。

`tools/check_protocol_layout.sh` 末尾增加一致性检查：从头部提取宏值，读 plist 的 `SBAudioProtocolVersion`，不等则 exit 1 并打印修复命令。`make protocol-check` 已在 `build`、`quick` 前置和 CI 中，所以这条守卫必然被执行。

守卫经过反向验证：临时把 plist 改成 `131329`，脚本 `exit 1` 并输出修复命令；改回 `131328`，`exit 0`。

---

## 3. B 阶段：共享内存文件级崩溃恢复

### 3.1 路径注入

`SharedMemoryManager` 原来在 `createMemory`、`removeMemory`、`cleanup` 三处直接调用 `PathManager.sharedMemoryPath(uid:)`（生产路径 `/tmp/soundbridge-<uid>`）。

改为构造器注入：

```swift
init(pathForUID: @escaping (String) -> String = { PathManager.sharedMemoryPath(uid: $0) })
```

默认参数保持生产行为完全不变，三处调用点全部改走闭包。这是唯一的缝，测试注入后所有路径都在沙箱内。

### 3.2 覆盖的 16 个场景

| # | 测试 | 验证内容 |
|---|---|---|
| 1 | `testCreatesFreshFileWhenAbsent` | 文件缺失 → `created`，尺寸与 Host 一致 |
| 2 | `testAdoptsCommittedStateAfterCrash` | 已提交状态被采纳 → `recoveredFromCrash`，音量 0.62 + 静音保留 |
| 3 | `testRejectsProtocolMismatch` | 协议 +1 → `replacedIncompatible`，重建后协议正确 |
| 4 | `testRejectsUndersizedFile` | 64 字节 → `replacedIncompatible`，重建到完整尺寸 |
| 5 | `testRejectsHeaderOnlyFile` | 恰好 256 字节 → 仍可恢复，重建补全音频区 |
| 6 | `testRejectsCorruptHeaderSize` | `header_size = 999` → `replacedIncompatible` |
| 7 | `testRejectsZeroFilledFile` | 全零 → 协议 0 ≠ 0x00020100 → `replacedIncompatible` |
| 8 | `testReplacesUninitializedFile` | 合法头 + 未提交 → `replacedUninitialized`，重建后已提交 |
| 9 | `testRebuildLeavesValidMapping` | 重建后协议/头长/采样率/通道正确，状态可读 |
| 10 | `testCleanupRemovesFileAndIsIdempotent` | 文件删除 + 二次 cleanup 不崩 |
| 11 | `testRemoveMemoryLeavesNoFile` | 单设备移除干净 |
| 12 | `testConcurrentCreationAcrossUIDs` | 8 个 UID 并发创建全部成功且状态正确 |
| 13 | `testSequentialRebuildOfSameUIDDoesNotTrap` | 同一 UID 重复创建不崩，状态保留 |
| 14 | `testRecoveredFileReopensWithValidLayout` | 以驱动视角只读 mmap，`rf_validate_header` 通过、尺寸/偏移正确 |
| 15 | `testPersistenceOutranksRecoveredState` | persisted(0.25) 压过 recovered(0.9) |
| 16 | `testFixtureNeverWritesOutsideSandbox` | 沙箱内只产生一个文件，路径 ≠ 生产路径 |

第 14 项是"恢复后的文件能够被重新打开、读取，且协议头和结构布局正确"的直接答案：它按驱动的实际访问方式（只读映射头部）验证，而不是复用 Host 自己的读路径。

### 3.3 一个语义决定

第 5 项（header-only 文件）预期为 `recoveredFromCrash` 而非 `replacedIncompatible`。原因：`probeExisting` 只映射 256 字节头部，头部合法且有已提交状态时，这个文件对 Host 而言信息完整——重建会补齐音频区。把它判成不兼容会丢掉一次可恢复的音量。测试注释写明了这个判断。

---

## 4. 文件修改清单

### 4.1 新增文件

| 文件 | 行数 | 作用 |
|---|---|---|
| `apps/mac/SoundBridgeApp/Sources/Services/DriverVersionGate.swift` | 257 | 状态模型 + 纯判定 + 文件读取 + 版本比较 |
| `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverVersionGateTests.swift` | 430 | 29 项测试 |
| `packages/host/Tests/SoundBridgeHostTests/SharedMemoryRecoveryTests.swift` | 410 | 16 项测试 |

### 4.2 修改的已跟踪文件（本阶段增量）

| 文件 | +/- | 改动 |
|---|---|---|
| `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift` | +51 / -31 | `checkDriverVersionMismatch` 改为门禁驱动；`performDriverUpdate` 安装后重读门禁并据此弹窗 |
| `apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift` | +41 / -14 | 新增 `currentInstallStatus()`；短路条件换成 `requiresInstallation`；验证改用门禁 |
| `apps/mac/SoundBridgeApp/Sources/Services/VersionManager.swift` | +4 / -26 | 删除语义错误的 `driverNeedsUpdate()`；版本比较转调 `DriverVersionGate.compare` |
| `apps/mac/SoundBridgeApp/Sources/Onboarding/OnboardingView.swift` | +4 / -2 | `onAppear` 跳过条件从"存在"改为"兼容" |
| `packages/driver/Info.plist` | +2 / -0 | 增加 `SBAudioProtocolVersion` |
| `tools/update_versions.sh` | +19 / -0 | 从头部同步协议号到驱动 plist |
| `packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift` | +12 / -3（本阶段） | 路径注入 + 三处调用点替换 |
| `tools/check_protocol_layout.sh` | +27（本阶段） | 协议号一致性守卫 |

`SharedMemoryManager.swift` 在 `git diff` 中显示 +190/-13，其中绝大部分是 Phase 2.1 的改动；本阶段只增加构造器、属性和三处调用替换。

### 4.3 顺带修正

`VersionManager.areVersionsEqual` 原来是字符串比较，`"1.2"` 与 `"1.2.0"` 判为不等。现改为数值比较，与 `isVersionOlder` 共用同一实现，避免两套比较逻辑分叉。该函数无现有调用点，改动无回归风险。

---

## 5. 实测结果

### 5.1 执行的命令与退出码

| 命令 | 退出码 | 结果 |
|---|---|---|
| `./tools/check_protocol_layout.sh` | 0 | C11 / C++17 编译通过，布局表输出，`Driver plist: OK (131328)` |
| `./tools/check_protocol_layout.sh`（plist 故意改坏） | 1 | 正确报错并打印修复命令 |
| `./tools/check_protocol_layout.sh`（改回） | 0 | 恢复通过 |
| `cd packages/host && swift build --build-tests` | 0 | Build complete (2.63s) |
| `cd packages/host && swift test --filter SharedMemoryRecoveryTests` | 0 | 16 项通过 |
| `cd apps/mac/SoundBridgeApp && swift build --build-tests` | 0 | Build complete (4.00s) |
| `cd apps/mac/SoundBridgeApp && swift test` | 0 | 56 项通过 |
| `cd packages/host && swift test` | 0 | 65 项通过 |
| `cmake --build packages/driver/build` | 0 | 构建产物 plist 含 `SBAudioProtocolVersion = 131328` |
| `cd packages/host && swift build -c release` | 0 | Build complete (4.21s) |
| `cd apps/mac/SoundBridgeApp && swift build -c release` | 0 | Build complete (4.87s) |
| `make test` | **0** | 全部套件通过 |

### 5.2 最终测试基线

| 套件 | 数量 | 失败 |
|---|---|---|
| 协议检查（4 文件一致 + C11 + C++17 + plist 守卫） | — | 0 |
| DSP `ctest` | 1 | 0 |
| Host `SharedMemoryProtocolTests` | 19 | 0 |
| Host `SharedMemoryRecoveryTests`（本阶段新增） | 16 | 0 |
| Host `VolumeStateTests` | 18 | 0 |
| Host `VolumeTaperTests` | 12 | 0 |
| **Host 合计** | **65** | **0** |
| App `DriverVersionGateTests`（本阶段新增） | 29 | 0 |
| App `EQPropertyTests` | 8 | 0 |
| App `EQUnitTests` | 19 | 0 |
| **App XCTest 合计** | **56** | **0** |
| App SwiftCheck 属性测试 | 9 组 × 100 迭代 | 0 |

对比 Phase 2.1 结束时：Host 49 → 65（+16），App 27 → 56（+29）。

### 5.3 新增测试的分布

`DriverVersionGateTests` 的 29 项分四组：纯判定 14 项（存在性/版本/元数据损坏/协议）、版本比较 4 项、门禁映射 3 项、文件层 8 项（含临时目录 bundle 与一致性守卫）。

`SharedMemoryRecoveryTests` 的 16 项按第 3.2 节表格分布，其中 13 项直接操作临时目录中的真实文件，其余 3 项验证优先级、并发与隔离。

---

## 6. 放行标准核对

| 检查项 | 要求 | 结果 |
|---|---|---|
| Driver 版本门禁 | 新增测试通过，旧驱动不再被误判为可用 | 通过 — 29 项测试；`1.1.3` 对 `1.2.0` 稳定返回 `outdated` |
| 真实安装操作 | 未执行，保留人工授权 | 通过 — 未调用任何提权路径 |
| 共享内存恢复 | 文件级恢复测试通过 | 通过 — 16 项，含驱动视角重开验证 |
| ABI 与并发 | 无未解释的高风险问题 | 通过 — 布局守卫 + 8 路并发创建；风险项见 7.1 |
| 原有回归测试 | 全部通过 | 通过 — `make test` exit 0 |
| Git 状态 | 不提交、不推送、不改子模块 | 通过 — 见 6.1 |
| 交付报告 | 记录实际测试命令、退出码和未验证事项 | 本文件 |

### 6.1 Git 状态

```
子模块： 633e0f70203edd87d320fc5a3cae901e1363aac5 packages/driver/vendor/libASPL (v3.1.2-1-g633e0f7)
已跟踪改动：20 files changed, 1968 insertions(+), 180 deletions(-)
新增未跟踪：3 个源/测试文件（见 4.1）
git diff --check：无输出
```

未执行 `git add`、`git commit`、`git push`，未创建 tag 或 Release。

---

## 7. 未验证事项

### 7.1 需要人工授权的验证

1. **真实旧驱动升级路径**。本阶段验证的是判定逻辑与文件层行为，不是"1.1.3 装着 → 点 Update Now → 变成 1.2.0"这条端到端链路。后者需要管理员密码，未执行。建议在实机上前提为：先装 1.1.3，再跑 1.2.0 构建，观察日志出现 `Driver install gate: outdated` 且弹窗后驱动确实被替换。
2. **`performDriverUpdate` 的三条弹窗分支**。代码路径已写，但没有人工点击过。特别是 `newer` 分支的"Driver Kept"文案需要人眼确认不误导。
3. **首次安装（`notInstalled`）路径的回归**。改动只影响判定条件，逻辑上首次安装行为不变，但没有实际跑过一次全新安装。

### 7.2 未覆盖的边界

4. **文件系统错误路径**。`createMemory` 在 `open`/`ftruncate`/`mmap` 失败时返回 `nil` 并记录日志，但这条路径没有测试（需要构造只读目录或配额耗尽）。
5. **`/tmp` 路径的安全属性**。生产路径是 `/tmp/soundbridge-<uid>`，`open` 未使用 `O_EXCL` / `O_NOFOLLOW`，理论上存在符号链接攻击面。这是既有设计，本阶段未改动也未测试。若 1.2.0 后要收紧，应单独评估。
6. **同一 UID 的真并发创建**。只测了顺序重建（第 13 项）。两个进程同时 `unlink` + `open` 同名文件会产生一个指向已删除 inode 的映射，生产上不会出现（每个 UID 只创建一次），但该行为未验证。

### 7.3 依赖外部约定的部分

7. **协议号同步依赖脚本或手工操作**。已加守卫，但守卫只能发现不一致，不能自动修复。协议 bump 时的正确顺序是：改头部 → 改 `check_protocol_layout.sh` 的 `#error` 字面量 → 跑 `update_versions.sh`（或手工改 plist）→ 跑 `make protocol-check`。建议在发布检查单里写明。
8. **打包后 plist 的实际内容**。验证的是 `packages/driver/build` 下的产物。`tools/create_app_bundle.sh` 是否原样拷贝该 plist 未在本阶段核对。

---

## 8. 后续建议

1. 完成 7.1 的三项人工验证后再提交，这是"完整回归审查"里唯一需要真人上机的部分。
2. 提交时一并纳入 `docs/1.2.0/`（当前整个目录未被跟踪），避免代码入库而记录缺失。
3. `newer` 分支目前只记日志不打扰用户。若实际遇到用户手动装了更高版本驱动，可能需要一个不阻断的提示，属 Phase 2.2 范围。
4. Phase 2.2 若引入 HARDWARE 音量模式，`DriverVersionStatus` 需要扩展为"能力协商"而非仅版本比对——当前模型刻意只回答"能不能用"，不回答"能用到什么程度"。
