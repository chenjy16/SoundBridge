# SoundBridge 1.2.0 — Phase 2.1.3 发布准备与驱动生命周期加固报告

日期：2026-11-16
范围：Driver 安装/升级审计、Release 产物验证、共享内存文件系统安全、同 UID 多进程并发、生命周期审查
结论：**CONDITIONAL PASS**（见第 10 章）

---

## 1. 执行摘要

### 1.1 本阶段目标

1. 复审 Phase 2.1.1 / 2.1.2 遗留问题。
2. 加固 Driver 安装、升级、版本识别与协议兼容。
3. 补充共享内存文件系统安全与多进程并发测试。
4. 验证 Release 构建产物中 Driver 的实际元数据。
5. 建立发布前自动化守卫。
6. 输出发布准备审计。

### 1.2 完成情况

| 任务 | 状态 | 说明 |
|---|---|---|
| A 安装与升级机制审查 | 完成 | 发现并修复 1 个 P0（启动时主动升级弹窗） |
| B Release 产物验证 | 完成 | 新增 `tools/verify_release_bundle.sh`，接入 Makefile 与 CI；发现并修复 1 个 P0（通用二进制发布链路失效） |
| C 共享内存安全审查 | 完成 | 创建路径补 `O_EXCL`/`O_NOFOLLOW`；6 项文件系统异常测试 |
| D 多进程并发测试 | 完成 | 4 项真实子进程测试（编译期 C 夹具） |
| E 生命周期审查 | 完成 | 7 级状态逐级区分，发现 2 个 P1 |
| F 测试与回归 | 完成 | `make test` EXIT=0，Host 75 / App 57 / DSP 1 |

### 1.3 本阶段发现的问题

| 级别 | 问题 | 状态 |
|---|---|---|
| **P0-1** | 每次启动调用 `checkDriverVersionMismatch()`，版本不匹配时直接弹出 "Driver Update Available" 窗口，违反"不向普通用户提供升级入口"的产品决策 | **已修复** |
| **P0-2** | `tools/build_release.sh`、`make quick`、`.github/workflows/release.yml` 的通用二进制构建在 Swift 6.x 上失效：两次 `--triple` 构建写入同一产品目录，第二个覆盖第一个，`lipo` 拿不到输入 | **已修复** |
| P1-1 | 1.1.x → 1.2.0 升级后，若 Driver 未随之更新，用户听到静音且 App 无任何提示（协议已从 `0x00020000` 变为 `0x00020100`） | 已定位，需产品决策 |
| P1-2 | Host 进程自身没有单实例保护；App 侧 `pgrep -f SoundBridgeHost` 是非原子检查 | 已定位，未修复（改动 Host 启动语义，需实机验证） |
| P1-3 | `AppDelegate.isDriverLoaded()` 把"Driver 已加载"与"HAL 已发现设备"混为一谈；`checkAndLoadDriverIfNeeded()` 是死代码，含 `killall coreaudiod` 升级提示路径 | 已定位，未删除 |
| P2-1 | 产物版本仍为 **1.1.1**，与 1.2.0 目标不一致（无 1.2.0 tag，本阶段刻意未运行 `update_versions.sh`） | 发版前必须处理 |
| P2-2 | 共享内存文件位于 `/tmp`、权限 0666，同机任意用户可读写 | 设计使然，已用测试钉住 |

### 1.4 是否建议进入 Phase 2.2

不建议立即进入。先完成第 10 章列出的 4 项条件（其中 2 项是产品决策、2 项是实机验证）。

---

## 2. Driver 安装与升级审计

### 2.1 DriverVersionGate 审查（A1）

`DriverVersionGate.swift`（277 行）实现 7 个互斥状态：

| # | 状态 | 触发条件 |
|---|---|---|
| 1 | `notInstalled` | 安装路径不存在 |
| 2 | `compatible(version:)` | 协议一致（或未声明）且版本相等 |
| 3 | `outdated(installed:expected:)` | 版本较低 |
| 4 | `newer(installed:expected:)` | 版本较高 |
| 5 | `metadataUnreadable(reason:)` | plist 缺失/不可解析、版本键缺失/空、协议键非整数 |
| 6 | `protocolIncompatible(...)` | 双方都声明协议且不相等 |
| 7 | `expectedVersionUnavailable` | App 内 Driver 版本读不出 |

任务描述中的 `metadataInvalid` / `unknown` 在代码中对应 `metadataUnreadable` / `expectedVersionUnavailable`，语义一一对应，无需改名。

判定顺序（即设计决策）：存在性 → 期望版本可用性 → plist 可解析 → 版本键非空 → **协议比较（先于版本比较）** → 版本数值比较。

边界覆盖（`DriverVersionGateTests.swift`，30 项）：

- plist 缺失、plist 非字典、版本键缺失、版本键为空 → 全部落到 `metadataUnreadable`，**不会**被当作兼容。
- 协议键缺失（1.2.0 之前的旧 Driver）→ 退化为版本比较，不判损坏。
- 协议键为十进制字符串 / `0x` 十六进制 / NSNumber → 均可解析。
- 协议不兼容优先于版本比较：`testProtocolMismatchOutranksVersionComparison`、`testProtocolMismatchOutranksNewerVersion` 两项钉住"版本更新但协议不同"仍判 `protocolIncompatible`。
- `newer` 的 `requiresInstallation == false`：旧 App 不会覆盖新 Driver。
- `requiresInstallation` 对 7 态全量断言，`isCompatible` 只对 `compatible` 为真。

**结论：7 态完整、互斥、无默认放行路径。**

### 2.2 DriverInstaller 审查（A2）

`DriverInstaller.installDriver()`（第 83–126 行）：

1. 先 `currentInstallStatus()` 取门禁结论并打印。
2. `guard status.requiresInstallation` 才进入特权拷贝；`compatible` / `newer` 直接 `.complete` 返回，不复制。
3. 拷贝 → 权限 → 重启 coreaudiod → 等待 1s。
4. **复检改为重跑同一个门禁**（第 116–122 行）：`currentInstallStatus().isCompatible`，不通过则抛 `verificationFailed`。

对照任务清单：

| 要求 | 结论 |
|---|---|
| 首次安装可执行 | 是（`notInstalled` → requiresInstallation） |
| `outdated` 可进入升级 | 是 |
| `compatible` 不重复安装 | 是 |
| `newer` 不被旧版覆盖 | 是 |
| `metadataInvalid` 不被当成 compatible | 是（走 requiresInstallation） |
| `protocolIncompatible` 明确识别 | 是 |
| 安装失败正确反馈 | 抛 `DriverInstallError`，调用方弹窗 |
| 安装后重读实际目录元数据 | 是（`currentInstallStatus()` 读 `/Library/Audio/Plug-Ins/HAL/...`） |
| 安装后重跑门禁 | 是 |
| 只有复检通过才返回成功 | 是 |

反模式清除情况：

- `if isDriverInstalled() { return }` 已删除；`isDriverInstalled()` 保留但注释明确为"展示辅助，不是门禁"，且当前无调用点。
- 原先在拷贝前就 `print("✓ Driver updated successfully")` 的路径已不存在；成功日志改在复检之后，且输出 `verified.summary`。

**遗留设计风险（未改动）**：特权步骤通过 `do shell script ... with administrator privileges` 执行 `cp -R` + `chown -R root:wheel` + `chmod -R 755` + `killall coreaudiod`。路径做了单引号转义；未做代码签名校验（Driver 未签名，属已知前提）。本阶段不涉及。

### 2.3 升级能力与用户入口隔离（A3）

审计结论：

| 入口 | 现状 | 判定 |
|---|---|---|
| 启动时 `checkDriverVersionMismatch()` | 只读门禁、只打日志、返回状态，**不弹窗** | 符合 |
| `showDriverUpdatePrompt()` | 无调用点；函数内首行 `guard DriverUpgradePolicy.allowsUserFacingPrompt`（常量 `false`） | 双重封闭 |
| `performDriverUpdate()` | 仅由 `showDriverUpdatePrompt` 回调触发，因此不可达 | 保留能力，不暴露 |
| `DriverUpdateWindow` | 仅被 `showDriverUpdatePrompt` 引用 | 保留，不删除（按要求先分析调用关系） |
| 设置页 / 主界面 | 无任何 Driver 升级入口（`grep -i "update driver\|upgrade"` 仅命中注释与失败弹窗文案） | 符合 |
| 后台自动升级 | 无 | 符合 |
| Onboarding | 首次安装按钮保留（首次安装路径，非升级入口）；`.onAppear` 改为 `currentInstallStatus().isCompatible` 才跳过 | 符合 |

代码中四种状态被显式分开，未混为一谈：

- `DriverVersionStatus.isCompatible` —— 是否兼容。
- `DriverVersionStatus.requiresInstallation` —— 是否需要安装/升级。
- `DriverUpgradePolicy.allowsAutomaticInstall` —— 是否允许自动执行。
- `DriverUpgradePolicy.allowsUserFacingPrompt` —— 是否允许展示入口。

两个策略常量由 `testUpgradePolicyKeepsUserFacingUpgradeOff` 钉住，改动必须显式修改测试。`allowsAutomaticInstall` 目前是文档性常量：审计确认没有任何代码路径在"无用户动作"下调用 `installDriver()`（只有 Onboarding 按钮与更新窗口的 "Update Now"）。

### 2.4 一处仍未解释的取舍

`DriverVersionStatus.expectedVersionUnavailable` 的 `requiresInstallation == true`（"装一个看看"）。理由：此时无法比较，拷贝步骤若失败会明确报错。但它也意味着 App 资源里 Driver 版本读不出时会尝试覆盖已安装的任何版本。当前分发形态下 App 资源必然带 Driver，风险低；记录为已知取舍。

---

## 3. Release Bundle 审计（B1 / B2）

### 3.1 构建路径

`make release` → `build` → `update-version`（**会按 git tag 重写版本号**）。当前仓库最新 tag 是 `1.1.3`，而工作区版本是 `1.1.1`，直接跑 `make release` 会把版本改成 1.1.3 并污染工作区。因此本阶段拆开执行：

```
./tools/build_release.sh          # DSP → Driver → Host(universal) → App(universal) → bundle
./tools/verify_release_bundle.sh  # 检查最终产物
```

### 3.2 最终产物实测

路径：`dist/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver`

| 字段 | 实际值 | 期望 | 结论 |
|---|---|---|---|
| `CFBundleIdentifier` | `com.soundbridge.driver` | 同 | OK |
| `CFBundleExecutable` | `SoundBridgeDriver` | 同 | OK |
| `CFBundleShortVersionString` | `1.1.1` | 1.2.0 | **待发版重写** |
| `CFBundleVersion` | `1.1.1` | 同 | OK |
| `SBAudioProtocolVersion` | `131328` | `0x00020100` = 131328 | OK |
| 驱动二进制架构 | `x86_64 arm64` | 通用 | OK |
| App / Host 架构 | `x86_64 arm64` | 通用 | OK |

一致性：源码 plist `packages/driver/Info.plist` = 131328；共享头 `packages/shared/include/RFSharedAudio.h` = `0x00020100`；App 编译期常量 `DriverVersionGate.expectedProtocolVersion` 来源于同一头文件副本（`sync_shared_header.sh --check` 保证 4 份一致）。

### 3.3 守卫脚本

新增 `tools/verify_release_bundle.sh`（187 行），读**最终 .app 内的 bundle**，不是源码：

1. bundle 目录存在且名为 `SoundBridgeDriver.driver`（`findDriverBundle()` 找的就是这个路径）。
2. `Contents/Info.plist` 存在且 `plutil -lint` 通过。
3. `CFBundleIdentifier`、`CFBundleExecutable` 正确，且可执行文件在 `Contents/MacOS/` 内、可执行、是 Mach-O。
4. 两个版本键非空、点分数字、彼此相等；可选 `expected-version` 参数比对发布 tag。
5. `SBAudioProtocolVersion` 存在、非负整数、等于头文件十进制值、等于源码 plist 值（捕获 `packages/driver/build` 陈旧）。
6. 三份协议头副本的 `RF_AUDIO_PROTOCOL_VERSION` 与源一致（证明 App 期望值就是刚校验的数字）。
7. 驱动二进制同时包含 arm64 与 x86_64。

接入点：

- `Makefile`：新增 `release-verify`，`release` / `full-release` 依赖链变为 `build → bundle → release-verify → sign → verify`。`make -n release` 实测顺序：

  ```
  ./tools/build_release.sh
  ./tools/create_app_bundle.sh
  ./tools/verify_release_bundle.sh
  ./tools/codesign.sh
  ./tools/verify_signatures.sh
  ```

- `.github/workflows/release.yml`：`Create App Bundle` 之后新增 `Verify Release Driver Bundle`，带发布版本号参数，失败即中断（签名/DMG 都不会发生）。

### 3.4 守卫的反向验证（证明不是死代码）

在临时副本上注入 3 种故障，脚本均以 EXIT=1 失败：

| 注入 | 输出 |
|---|---|
| 协议号改为 131329 | `FAIL: bundled SBAudioProtocolVersion=131329 != header 0x00020100 (131328)` + `FAIL: ... packages/driver/build is stale` |
| 删除协议键 | `FAIL: bundled driver has no SBAudioProtocolVersion; the gate would fall back to version-only comparison` |
| 传入 `1.2.0` 期望版本 | `FAIL: bundle version '1.1.1' != expected '1.2.0'` |

### 3.5 P0-2：通用二进制构建链路失效（本阶段修复）

首轮 `./tools/build_release.sh` 在 3/5 阶段失败：

```
  Building arm64...    Build complete! (4.27秒)
  Building x86_64...   Build complete! (4.44秒)
lipo: warning: file not found '.build/arm64-apple-macosx/release/SoundBridgeHost'
lipo: warning: file not found '.build/x86_64-apple-macosx/release/SoundBridgeHost'
lipo: no eligible inputs found
```

根因（实测确认）：Swift 6.4.2 / SwiftPM 不再为显式 `--triple` 创建 `.build/<triple>/release`。两次构建都写入同一个 `out/Products/Release`，`.build/release` 是指向它的符号链接；第二次（x86_64）覆盖了第一次（arm64）的产物。`lipo -archs .build/release/SoundBridgeHost` 实测只剩 `x86_64`。

影响：`make release`、`make full-release`、`make quick` 与 CI 发布工作流全部无法产出通用二进制。此前各阶段报告的 "Host/App Release 构建通过" 是单架构 `swift build -c release`，从未走过这条通用链路。

修复（最小改动）：

- `tools/build_release.sh`：每架构独立 `--scratch-path .build/arm64` / `.build/x86_64`，用 `--show-bin-path` 向 SwiftPM 询问产物位置而不是硬编码目录；产物缺失即 `exit 1`；并加 `set -o pipefail`（原先 `swift build | tail -1` 会吞掉构建失败）。
- `Makefile` 的 `quick` 目标：同样加 `--scratch-path`。
- `.github/workflows/release.yml`：同样加 `--scratch-path` 并修正 lipo 输入路径。

修复后 `./tools/build_release.sh` EXIT=0，实测 `Architectures: x86_64 arm64`（Host 与 App 均是）；`make quick` 此前被同一个缺陷打断，修复后实测 EXIT=0 并重新产出了通用二进制 bundle。

---

## 4. 共享内存安全审计（C1 / C2）

### 4.1 创建路径

`SharedMemoryManager.createMemory(for:persistence:)`：

```swift
let probe = probeExisting(path: shmPath)   // O_RDONLY | O_NOFOLLOW，只 map 256 字节头
unlink(shmPath)                            // 丢弃旧 inode，避免长度不同的陈旧映射
let fd = open(shmPath, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0o666)
guard fd >= 0 else { ... return nil }      // EEXIST / ELOOP -> 明确拒绝
fchmod(fd, 0o666)
ftruncate(fd, shmSize)
mmap(...) -> rf_shared_audio_init -> rf_publish_volume_state
```

逐项评估：

| 检查项 | 结论 | 依据 |
|---|---|---|
| `O_EXCL` | **本阶段新增** | unlink 与 open 之间存在窗口；若他人先创建，本进程绝不能打开并截断它 |
| `O_NOFOLLOW` | **本阶段新增** | `O_EXCL` 已拒绝符号链接，但意图应可读；`probeExisting` 同样用 `O_NOFOLLOW` 只读打开 |
| `O_CLOEXEC` | 未加 | 进程不 fork/exec 子进程，映射在 mmap 后立即 `close(fd)`；无泄漏句柄可继承。加了也不会更安全 |
| 权限 | 0666 + `fchmod` | Driver 运行在 coreaudiod（不同 uid），必须能读写；`fchmod` 让结果不随调用方 umask 变化 |
| 文件大小 | `ftruncate` 到 `rf_shared_audio_size(...)` | 大小由协议头推导，不是常量 |
| 异常大小 | `probeExisting` 用 `st_size >= sizeof(RFSharedAudio)` 判定可用，超大文件会被重建为规范长度 | 见测试 5 |
| 初始化中断 | 重建后统一 `rf_shared_audio_init` + 提交；头部的 `state_initialized` 是唯一提交标志 | 见测试 3、以及 Phase 2.1.2 的 header-only 用例 |
| 重建误删有效文件 | 先 probe 后 unlink；`recoveredFromCrash` 会把已提交音量带过去 | 见测试 5 |

失败语义（代码审阅）：`ftruncate` 失败关闭 fd 但留下 0 字节文件；`mmap` 失败留下一个头部全零的文件。两种残留都会被下轮 `probeExisting` 判为 `replacedIncompatible` 并重建 —— 自愈，但残留本身会让下一轮多一次重建。**未做**故障注入，见第 8 章。

### 4.2 安全边界（逐条回答）

| # | 问题 | 实际答案 |
|---|---|---|
| 1 | 谁拥有创建权 | **只有 Host**。Driver 的 `OnStartIO` 只打开已存在的路径，从不 `O_CREAT` |
| 2 | 谁拥有删除权 | **只有 Host**（`removeMemory` / `cleanup`）。Driver 从不 `unlink` |
| 3 | Driver 是否只读 Header | **否**。Driver 对头部是读写：写 `write_index`、`driver_heartbeat`、`driver_connected`，读 `read_index`、`volume_*`、`eq_*`；对音频区是**写**（`rf_ring_write`，第 522/1067/1083/1094 行） |
| 4 | Host 是否独占写入音频区 | **否**。方向相反：Driver 是生产者写入环形缓冲，Host 用 `rf_ring_read`（`AudioRenderer.swift:135`）消费。Host 独占写的是音量/EQ/状态提交区 |
| 5 | 谁负责损坏恢复 | **Host**：probe → 分类 → unlink → 重建 → 重新提交状态 |
| 6 | 两个 Host 同时启动如何避免互相覆盖 | **目前没有可靠机制**，见 P1-2 |
| 7 | Host 删除/重建期间 Driver 读取是否竞态 | POSIX 保证旧 inode 对被持有者存活，驱动不会 SIGBUS；但驱动会继续读旧 inode（听到过期数据）。`Plugin.cpp` 里有 `IsHealthy()` 检查 `stat()` 文件是否消失，**但全仓库无调用点**（死代码），所以驱动不会自动重连 |

### 4.3 P1-2：Host 无单实例保护

现状：`AppDelegate.launchHostIfNeeded()` 用 `pgrep -f SoundBridgeHost` 判断，然后 `startHost()`。Host 进程自身没有任何锁。

失败序列：两个 Host 在几毫秒内相继启动 → 两者都 `pgrep` 到空 → 第二个 `unlink` 掉第一个刚建的文件并新建 → 第一个继续往已 unlink 的 inode 写，第二个往新 inode 写 → Driver 附着到新 inode，音频来自第二个，第一个变成幽灵进程（心跳、队列、音量转发全部作用于无人读取的内存）。

为什么本阶段不修：最小修复是在 Host 启动时对 `<path>.lock` 做 `flock(LOCK_EX|LOCK_NB)`，拿不到就退出。但这会改变 Host 的启动/退出语义（含崩溃后重启、`isUninstalling` 流程），必须实机验证"崩溃 → 重启"与"App 双击两次"两条路径，超出本阶段"只做静态审查和可安全执行的自动化测试"的边界。

建议修复形态（留给后续阶段）：`flock` 非阻塞独占锁 + 明确退出码；锁文件按 uid 命名，进程退出时内核自动释放，无残留问题。

### 4.4 文件系统异常测试（C3）

新增 `packages/host/Tests/SoundBridgeHostTests/SharedMemoryFileSystemTests.swift`（287 行，6 项），全部在 `NSTemporaryDirectory()` 下的独立沙箱，路径注入保证不触及 `/tmp/soundbridge-<uid>`：

| 测试 | 覆盖 | 断言 |
|---|---|---|
| `testReadOnlyDirectoryRefusesCreation` | 只读目录 / 创建权限不足 | `createMemory` 返回 nil、目录内无残留文件、未发布映射（root 下自动 skip） |
| `testDirectoryAtPathIsRefusedWithoutDeletingIt` | 路径被目录占用、清理失败 | 返回 nil、目录与其内容原样保留 |
| `testSymlinkIsReplacedWithoutFollowingIt` | 符号链接路径 | 判为 `replacedIncompatible`、链接被替换为普通文件、**目标文件大小与已提交音量 0.93 均未被改动** |
| `testGarbageFileIsReplacedWithValidHeader` | 头部损坏 | 重建为 Host 规范长度、`rf_validate_header == RF_VALIDATE_OK` |
| `testOversizedFileIsTruncatedToHostSizeAndKeepsCommittedVolume` | 文件尺寸异常（过大） | 判为 `recoveredFromCrash`、长度回到规范值、音量 0.77 保留 |
| `testMappingIsWritableByTheDriverProcess` | 文件权限 | mode 含 other-read 与 other-write（防止未来"加固"成 0600 静默断音频） |

未覆盖：`ftruncate` 失败、`mmap` 失败的直接注入（需要故障注入钩子或受限文件系统；当前创建路径只有"打开失败"这一条真实可触发分支）。

### 4.5 P2-2：`/tmp` + 0666

`PathManager.sharedMemoryPath(uid:)` 产出 `/tmp/soundbridge-<sanitized uid>`，权限 0666。同一台机器上的任意本地用户可以打开该文件并篡改音量/EQ/音频数据，或制造 DoS。

这不是本阶段引入的问题，也不建议在本阶段修改：Driver 运行在 coreaudiod（`_coreaudiod`），要跨用户访问该文件，因此**不能**放到 `$TMPDIR`（`/var/folders/...`，每用户 0700）。可选的收紧方向是"按 uid 建子目录 + 目录 0711 + 文件 0660 + 把 `_coreaudiod` 加入某个组"，但这会改动 Host/Driver 双方的文件访问约定，需要实机验证，且收益限于同机多用户场景。记录为已知风险。

---

## 5. 多进程并发测试（D）

### 5.1 与既有测试的区别

| 维度 | 既有 `testConcurrentAccess` | 本阶段 |
|---|---|---|
| 并发单元 | 8 个线程，同一 manager、同一 fd 表 | 4 个**独立进程** |
| 能证明什么 | `os_unfair_lock` 保护字典 | 内核级 `O_EXCL`、`unlink` 对已映射 inode 的语义、`ftruncate` 跨进程可见性 |
| 不能证明什么 | 跨进程文件名竞争、跨进程重建 | 真实 `SoundBridgeHost` 二进制的行为（见 5.3） |

### 5.2 实现

`packages/host/Tests/SoundBridgeHostTests/SharedMemoryMultiProcessTests.swift`（482 行，4 项）。

夹具：测试启动时用 `/usr/bin/clang -O1 -std=c11 -I <repo>/packages/shared/include` 把一段 C 程序编译到临时目录。该程序包含**真正的** `RFSharedAudio.h`，执行与 `SharedMemoryManager` 相同的 `open(O_CREAT|O_EXCL|O_NOFOLLOW)` → `ftruncate` → `mmap` → `rf_shared_audio_init` → `rf_publish_volume_state` 序列。三个模式：`create` / `probe` / `hold`。clang 缺失或编译失败时整个 suite `XCTSkip` 并说明原因（本机编译成功，4 项均真实执行）。

| 测试 | 场景 | 断言 |
|---|---|---|
| `testConcurrentCreateElectsExactlyOneOwner` | 4 个进程同一毫秒（绝对时间对齐）同时创建 | 恰好 1 个 exit 0、3 个 exit 3（`EEXIST`）；沙箱内**只有 1 个文件**；胜者的头部通过 `rf_validate_header`，已提交音量 0.62；本进程未发布映射 |
| `testConcurrentProbesAgreeOnTheExistingMapping` | 4 个进程并发只读探测 | 全部 exit 0，且对 `size` 与 `validate` 的结论一致（探测不产生副作用） |
| `testStateFromAProcessThatDiedIsRecovered` | 子进程创建并提交后不清理直接退出 | 文件仍在；`createMemory` 得 `recoveredFromCrash`；音量 0.62 保留 |
| `testUnlinkWhileAnotherProcessHoldsTheMappingIsSurvivable` | 子进程持映射持续写入期间，父进程 unlink 并重建 | 子进程 exit 0（不 SIGBUS）；重建后的文件有效、音量取持久化值 0.5；沙箱内仍只有 1 个文件 |

这 4 项也回答了任务 D 的 7 个问题：并发创建（1）、并发 probe（2）、初始化+恢复（3）、清理+读取（4）、异常退出+恢复（3）、不覆盖有效音量（3、4）、不产生多个冲突文件（1、4）。

### 5.3 明确未验证

- **未启动真实的第二个 `SoundBridgeHost` 进程**。子进程是同 syscall 序列的替身，不包含 Host 的设备发现、心跳定时器、音频引擎。真实双 Host 的相互影响（P1-2）因此**没有被测试覆盖**。
- **Driver 与 Host 的真实并发**需要 coreaudiod 加载驱动，属实机验证范围。

---

## 6. Driver 生命周期审计（E）

### 6.1 七级状态，逐级可区分

| 级 | 状态 | 当前可观测手段 | 是否被当作其他级的证明 |
|---|---|---|---|
| 1 | 文件已安装 | `DriverInstaller.isDriverInstalled()` / 门禁的 bundle 存在性 | 曾经是（2.1.1 已修） |
| 2 | 版本兼容 | `DriverVersionGate`（版本 + 协议） | 否 |
| 3 | Driver 已被 coreaudiod 加载 | **无直接手段** | 见 6.2 |
| 4 | HAL 已发现 Driver | `system_profiler SPAudioDataType` 含 "SoundBridge"（`isDriverLoaded()`） | **是，与 3、5 混同** |
| 5 | 代理设备已创建 | 同上；Host 侧 `ProxyDeviceManager.findProxyDevice` | 是 |
| 6 | Host 已建立共享内存连接 | `driver_connected` / `host_connected` / 心跳（仅日志与遥测，**不参与任何分支**） | 否（但也未被使用） |
| 7 | 音频实际通过 | `total_frames_written/read`、`underrun/overrun` 计数（仅心跳日志） | 否 |

### 6.2 P1-3：`isDriverLoaded()` 名不符实

`AppDelegate.isDriverLoaded()`（第 632 行）与 `DriverInstaller.isDriverLoaded()`（第 129 行）是**两份完全相同的实现**，都用 `system_profiler SPAudioDataType` 输出里是否含 "SoundBridge"。该输出枚举的是**音频设备**，而设备是 Host 创建的代理设备。因此它同时混合了第 3、4、5 级，且要求 Host 已经在运行 —— 用作"驱动是否加载"会得到错误的答案。

`checkAndLoadDriverIfNeeded()`（第 593 行）只被定义、从未被调用。若被重新接线，它会在检测失败时用 AppleScript 请求管理员权限执行 `killall coreaudiod`，并在 Driver 缺失时弹出含 `cd packages/driver && ./install.sh` 的开发者文案。**本阶段不删除**（属无关模块清理），但明确标注：不要在没有重写的情况下接线这个函数。

### 6.3 升级后 coreaudiod 仍持旧实例

`installDriverWithPrivileges` 在拷贝后 `killall coreaudiod`，随后 `Thread.sleep(1s)` 再复检。复检读的是磁盘元数据，因此"复检通过"**不代表**新实例已被加载 —— 这是第 2 级与第 3 级之间的空隙，只能在实机验证（见第 8 章）。

### 6.4 Host 启动时序

`packages/host/Sources/SoundBridgeHost/main.swift`：

```
Step 3  createMemory()            // 建文件、提交音量
Step 4  writeControlFile()
Step 5  startHeartbeat()
Step 6  Thread.sleep(deviceWaitTimeout)  // 固定 2.0s，不是轮询驱动就绪
Step 7  autoSelectProxy()
Step 8  启动音频引擎
```

`deviceWaitTimeout` 是固定睡眠，而不是等待 `driver_connected`。`autoSelectProxy()` 在找不到代理设备时只 `logger.warning` 并 return（`ProxyDeviceManager.swift:214-217`），不重试、不报错、不切换到其他设备。Host 因此永远"启动成功"。Host 源码中**没有任何地方读取 `driver_connected`**。

这就是 P1-1 的机制：Driver 不兼容 → `rf_validate_header` 拒绝 → 不创建代理设备 → Host 拿不到代理 → 无音频、无错误、无提示。

### 6.5 新旧协议混用的实际后果（已验证到代码级）

协议从 `0x00020000`（Phase 2.1 之前）变为 `0x00020100`，且 `header_size` 从旧布局变为 256。

- 旧 Driver（0x00020000）+ 新 Host（0x00020100）：Driver 的 `ValidateConnection()` 调用 `rf_validate_header` → `RF_VALIDATE_PROTOCOL_VERSION` → `OnStartIO` 在 300ms 预算内重试后返回 `kAudioHardwareUnspecifiedError`。**拒绝连接，不会误读布局**。用户侧表现为第 6.4 节的静音。
- 新 Driver + 旧 Host：同理被 Driver 拒绝（版本号在头部，双向校验）。
- 旧 Driver 的 Info.plist 没有 `SBAudioProtocolVersion`，门禁退化为版本比较 → 判 `outdated` → `requiresInstallation` 为真。判定正确，但**没有任何路径会去装**（见 P1-1）。

---

## 7. 测试结果

### 7.1 命令与退出码

| 检查项 | 实际命令 | 退出码 | 结果 |
|---|---|---|---|
| 协议头一致性 | `./tools/sync_shared_header.sh --check`（经 `make protocol-check`） | 0 | 4 份副本一致 |
| 协议布局/ABI | `./tools/check_protocol_layout.sh`（经 `make protocol-check`） | 0 | C11 OK / C++17 OK / `0x00020100` / header 256 / sizeof 256 / plist 131328 |
| Driver 门禁测试 | `cd apps/mac/SoundBridgeApp && swift test --filter DriverVersionGateTests` | 0 | 30 项通过 |
| Host 测试 | `cd packages/host && swift test`（经 `make test-host`） | 0 | **75 项通过，0 失败** |
| App 测试 | `cd apps/mac/SoundBridgeApp && swift test`（经 `make test-app`） | 0 | **57 项通过，0 失败** |
| DSP 测试 | `cd packages/dsp/build && ctest --output-on-failure`（经 `make test-dsp`） | 0 | `100% tests passed, 0 tests failed out of 1` |
| 完整回归 | `make test` | **0** | `✓ All test suites passed` |
| Release 构建 | `./tools/build_release.sh` | **0** | 5/5 阶段；DSP/Driver universal，Host/App `x86_64 arm64` |
| Swift 增量重建 | `make quick` | **0** | 通用 App/Host + 重新打包 bundle（同一缺陷修复后） |
| Release 产物守卫 | `./tools/verify_release_bundle.sh` | **0** | 见 3.2；对重建后的 bundle 又跑一次，结果一致 |
| 守卫故障注入 | 同上，指向被篡改的临时副本（3 种） | 1 / 1 / 1（预期失败） | 见 3.4 |
| `make release` | **未执行** | — | 会触发 `update-version` 改写版本为 1.1.3 并进入签名；改用 dry-run 验证依赖顺序（3.3） |

### 7.2 测试规模变化

| Suite | Phase 2.1.2 末 | 本阶段 | 增量 |
|---|---|---|---|
| SharedMemoryProtocolTests | 19 | 19 | — |
| SharedMemoryRecoveryTests | 16 | 16 | — |
| **SharedMemoryFileSystemTests** | — | **6** | +6 |
| **SharedMemoryMultiProcessTests** | — | **4** | +4 |
| VolumeStateTests | 18 | 18 | — |
| VolumeTaperTests | 12 | 12 | — |
| **Host 合计** | 65 | **75** | +10 |
| **DriverVersionGateTests** | 29 | **30** | +1 |
| EQPropertyTests | 8 | 8 | — |
| EQUnitTests | 19 | 19 | — |
| **App 合计** | 56 | **57** | +1 |
| DSP ctest | 1 | 1 | — |

---

## 8. 未验证事项

| # | 事项 | 为什么无法验证 | 风险 | 需人工授权 | 建议方法 |
|---|---|---|---|---|---|
| 1 | 1.1.3 → 1.2.0 端到端升级 | 需要 sudo 安装真实 Driver 并 `killall coreaudiod` | **高** | 是 | 装 1.1.3 → 跑 1.2.0 App → 观察门禁日志判 `outdated`、安装后复检 `compatible`、设备出现、音频通过 |
| 2 | 升级后 coreaudiod 是否加载新实例 | 同上（第 2 级 → 第 3 级的空隙） | **高** | 是 | 升级后 `system_profiler SPAudioDataType` + `log show --predicate 'process == "coreaudiod"'` |
| 3 | 首次安装（`notInstalled`）路径回归 | 需清空 `/Library/Audio/Plug-Ins/HAL` | 中 | 是 | 卸载后跑 onboarding，确认一次管理员授权完成拷贝+权限+重启 |
| 4 | `performDriverUpdate` 三条弹窗分支 | 函数目前不可达（策略关闭） | 低 | 是 | 临时把 `allowsUserFacingPrompt` 置 true，在测试机上跑三分支后改回 |
| 5 | 两个真实 Host 进程并发 | 未启动真实 Host（P1-2） | **高** | 否（可自动化，但需改 Host） | 实现 flock 单实例后，写"同时启动两个 Host"的集成测试 |
| 6 | Driver 与 Host 真实并发 | 需 coreaudiod 加载驱动 | 中 | 是 | 播放中重启 Host，观察 `IsHealthy()`（需先接线）与音频恢复 |
| 7 | `ftruncate` / `mmap` 失败路径 | 需故障注入钩子或受限文件系统 | 低 | 否 | 加可注入的 syscall 包装层，或在只读卷上跑 |
| 8 | 磁盘满 / 配额耗尽 | 需受限环境 | 低 | 是 | 用小容量 sparse image 挂载后跑创建路径 |
| 9 | 发布的版本号（当前 1.1.1） | 仓库无 1.2.0 tag | **高** | 是 | `git tag v1.2.0` → `./tools/update_versions.sh 1.2.0` → `make release` → 守卫带 `1.2.0` 再跑一次 |
| 10 | CI 工作流实际执行 | 本机无法触发 GitHub Actions | 中 | 否 | 打 tag 触发一次 dry run（或 `act`），确认 `Verify Release Driver Bundle` 步骤生效 |

---

## 9. Git 工作区状态

### 9.1 基线（本阶段开始）

- 20 个已跟踪修改文件；
- `git diff --check` 无输出；
- 子模块 `633e0f70203edd87d320fc5a3cae901e1363aac5`（`v3.1.2-1-g633e0f7`）；
- 未跟踪：`.qoder/`、`AUDIT_REPORT.md`、`POC_REPORT.md`、`docs/`、`packages/host/Tests/`、`packages/shared/`、`tools/poc/`、`tools/sync_shared_header.sh`、`tools/check_protocol_layout.sh`、`DriverVersionGate.swift`、`DriverVersionGateTests.swift`、`VolumeMode.swift`、`VolumeState.swift`、`VolumeTaper.swift`。

### 9.2 本阶段新增修改（5 个已跟踪文件）

| 文件 | numstat（相对 HEAD，含前面阶段） | 本阶段内容 |
|---|---|---|
| `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift` | +63 / -35 | 启动检查不再弹窗；`showDriverUpdatePrompt` 加策略守卫 |
| `packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift` | +213 / -15 | 创建路径加 `O_EXCL \| O_NOFOLLOW` |
| `Makefile` | +57 / -13 | `release-verify` 目标与依赖链；`quick` 加 scratch-path |
| `.github/workflows/release.yml` | +56 / -8 | 新增产物守卫步骤；通用构建加 scratch-path |
| `tools/build_release.sh` | +34 / -5 | 每架构独立 scratch-path、`--show-bin-path`、`pipefail` |

### 9.3 本阶段新增文件（3 个）

| 文件 | 行数 |
|---|---|
| `tools/verify_release_bundle.sh` | 187 |
| `packages/host/Tests/SoundBridgeHostTests/SharedMemoryFileSystemTests.swift` | 287 |
| `packages/host/Tests/SoundBridgeHostTests/SharedMemoryMultiProcessTests.swift` | 482 |
| `docs/1.2.0/PHASE2_1_3_RELEASE_READINESS_REPORT.md` | 本文件 |

另有两个文件在未跟踪目录下继续累积改动：`DriverVersionGate.swift`（+18，`DriverUpgradePolicy`）、`DriverVersionGateTests.swift`（+9，策略测试）。

### 9.4 结束时对比

- 已跟踪修改：20 → **21**（新增 `tools/build_release.sh`）；
- `git diff --check`：无输出（exit 0）；
- 子模块：`633e0f7`，**未变化**；
- 未跟踪：新增 `tools/verify_release_bundle.sh`，其余与基线相同（`packages/host/Tests/`、`docs/` 目录内的新文件不改变顶层条目）；
- 构建产物：`dist/`（18 MB）已生成，被 `.gitignore` 的 `dist/` 规则忽略，未进入 `git status`；
- 无 `git add` / `commit` / `push`。

### 9.5 是否存在意外修改

无。所有改动均在本阶段任务范围内（A/B/C/D 的必要修复、以及 F 暴露的发布链路缺陷）。未删除任何未跟踪文件，未触碰子模块，未修改用户既有修改。

---

## 10. 最终放行结论

### **CONDITIONAL PASS**

自动化层面全部通过（`make test` EXIT=0、Release 构建 EXIT=0、产物守卫 EXIT=0 且经反向验证），本阶段发现的两个 P0 已修复并验证。不判 PASS 的原因是存在两个**必须由人或产品决定**的前置条件，以及一项能力缺口。

进入 Phase 2.2 前必须完成：

1. **版本对齐**：`git tag v1.2.0` + `./tools/update_versions.sh 1.2.0`，然后 `make release`，并用 `./tools/verify_release_bundle.sh <bundle> 1.2.0` 复验。当前产物是 1.1.1。
2. **升级路径的产品决策（P1-1）**：协议已从 `0x00020000` 变为 `0x00020100`。1.1.x 用户升级到 1.2.0 后，若 Driver 未被替换，将得到"静音且无提示"。三选一：
   - a) 打包安装器随 App 升级 Driver；
   - b) 首次启动检测到 `protocolIncompatible` 时执行一次"非推广性质的安装"（需要重新定义策略常量并同步修改测试）；
   - c) 确认 1.2.0 面向全新安装用户，旧用户升级不在本版范围内 —— 需明确写入发布说明。
3. **实机验证 3 项**（第 8 章 #1、#2、#3）：真实安装/升级、coreaudiod 加载新实例、首次安装路径。这些都需要管理员密码，本阶段未执行。
4. **决定 P1-2 是否在 1.2.0 前处理**：单实例锁缺失会让两个 Host 互相覆盖共享内存。建议至少在本版发布说明中记录，或在 1.2.1 修复。

提交建议：**建议提交，但必须是一次覆盖 Phase 2.1 → 2.1.3 的完整提交**。工作区同时包含四个阶段的改动（21 个已跟踪文件 + 未跟踪的新模块、测试与 `docs/1.2.0/`），只提交其中一部分会让报告与测试和代码分离。提交之后再打 1.2.0 tag 并做版本重写，避免 tag 指向未提交的树。

---

## 附录 A：本阶段实际修改的可执行代码清单

| 位置 | 改动 | 目的 |
|---|---|---|
| `SoundBridgeApp.swift` `checkDriverVersionMismatch()` | 改为只读观测，返回 `DriverVersionStatus` | 消除启动时主动升级弹窗（P0-1） |
| `SoundBridgeApp.swift` `showDriverUpdatePrompt()` | 首行加 `guard DriverUpgradePolicy.allowsUserFacingPrompt` | 让策略成为唯一开关，未来接线也无法误发提示 |
| `DriverVersionGate.swift` | 新增 `DriverUpgradePolicy`（两个 `false` 常量） | 把"能力"与"入口"分开，且可被测试钉住 |
| `SharedMemoryManager.swift` | `open(...)` 增加 `O_EXCL \| O_NOFOLLOW`，区分 `EEXIST`/`ELOOP` 日志 | 并发创建与符号链接防护 |
| `tools/build_release.sh` | 每架构 `--scratch-path`、`--show-bin-path`、`set -o pipefail` | 修复通用二进制构建（P0-2） |
| `Makefile` | `release-verify` 目标；`release`/`full-release` 依赖它；`quick` 加 scratch-path | 产物守卫进入发布链路 |
| `.github/workflows/release.yml` | 新增 `Verify Release Driver Bundle` 步骤；通用构建加 scratch-path | CI 守卫 + 修复发布工作流 |
| `tools/verify_release_bundle.sh`（新） | 检查最终 bundle 的标识/版本/协议/架构 | 源码正确 ≠ 产物正确 |
