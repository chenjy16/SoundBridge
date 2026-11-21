# P4 Batch 1A — Release Candidate Source Stabilization Report

执行日期：2026-11-21
基线 HEAD：`ab36770`（branch `main`）
仓库：`/path/to/SoundBridge`
版本 / 协议：`1.2.0` / `0x00020200`（131584）

本批次**只做发布候选收敛**：解决 P1-1、P1-2、P1-3、P1-5，更新 P2-6 的两份登记表，
并产出一份可审查的 Git 文件分组清单。没有架构重构，没有扩大产品范围，没有做任何
Git 写操作。

---

## 1. 执行摘要

### 1.1 结论

| 编号 | 问题 | 本批次结论 | 证据等级 |
|---|---|---|---|
| **P1-1** | App Onboarding 用非事务 shell 命令安装 Driver | **已解决**：删除第二套安装事务，Onboarding 只引导 PKG，结果由 `DriverVersionGate` 判定 | TEST_VERIFIED（`DriverInstallBoundaryTests`）+ SOURCE_VERIFIED |
| **P1-2** | App 内卸载与 `tools/uninstall_driver.sh` 政策相反 | **已解决**：抽出 `DriverUninstallPolicy` 单源，App 与脚本行为一致 | TEST_VERIFIED（23 项不变量 + 脚本字节等价断言） |
| **P1-3** | `test_release_payload.sh` 硬编码 `dist/SoundBridge-1.1.1.*` | **已解决**：改为合成 fixture，版本由场景指定，不读 `dist/` | TEST_VERIFIED（244 断言，0 失败） |
| **P1-5** | 发布文档与代码冲突（131328、旧测试数、Sparkle 自更新、DMG 升级） | **已解决**：RELEASE_NOTES / INSTALLATION_GUIDE 按当前实现重写，README 三处矛盾修正 | SOURCE_VERIFIED（与代码逐条核对） |
| **P2-6** | 风险登记表与 Release Checklist 未反映当前状态 | **已完成**：新增「已关闭」证据表、U-14/U-15/U-16、删除 `make clean` 指令、阻断项重排 | SOURCE_VERIFIED |

P4 Batch 0 审计给出的 `NOT READY` 结论**没有改变**。本批次消除的是「源码里存在两条互不
一致的特权路径」与「发布文档描述的是另一个版本」这两类问题；**真实安装 / 卸载 / 播放、
实际 EQ 听感、播放窗口 underrun 依然没有证据**，它们仍是发布阻断项（§12）。

### 1.2 规模

| 项 | 数量 | 说明 |
|---|---|---|
| 本批次实际编辑 / 新增 / 删除的文件 | **18** | 见 §8 |
| 工作区中处于修改状态的跟踪文件 | 66 M + 1 D | 多数来自 P2/P3 阶段，非本批次编写 |
| 未跟踪文件 | 160 | 其中 75 个在 `.qoder/`（IDE 生成） |
| 本批次执行的测试断言 | 244 + 83 + 58 + 168 + 379 + 253 + 33 + 3 套件 | 见 §10 |
| 新增 / 删除的代码行（本批次净额） | 见 §8 逐文件 | 不含 P2/P3 遗留 |

### 1.3 审计过程中新发现的一个阻断性事实

`.gitignore` 第 120 行的 `release/` 规则把 **`docs/release/` 整个目录**忽略了：

```
$ git check-ignore -v docs/release/SoundBridge-1.2.0-Release-Checklist.md
.gitignore:120:release/      docs/release/SoundBridge-1.2.0-Release-Checklist.md
```

后果：本批次按 §7 更新过的 Release Checklist **不会出现在 `git status` 里，也无法被
`git add` 提交**（除非 `git add -f`）。这使得「任务书要求的交付物之一无法进入提交」。
最小修法是把 `.gitignore` 的 `release/` 改为 `/release/`（只忽略仓库根目录的发布输出，
不忽略 `docs/release/`）。

`release/` 不在任务书 §10 允许修改的「代码、测试、文档」范围内，因此本批次**没有改它**，
把它登记为 §11 的 G-1 / §12 的 B-8，留给 Batch 1B 前确认。

---

## 2. Git 初始基线

全部命令均以 `git -C /path/to/SoundBridge` 形式执行，输出保存在
`build/p4-batch1a/evidence/`。

### 2.1 状态

| 命令 | 结果 | 证据文件 |
|---|---|---|
| `git rev-parse --short HEAD` | `ab36770` | 本报告 §0 |
| `git status --porcelain=v1` | 136 行 = 66 `M` + 1 `D` + 69 `??` 条目 | `b1a-git-status-final.log` |
| `git ls-files --others --exclude-standard` | **160** 个文件（69 个目录条目展开后） | `b1a-untracked-expanded.log` |
| `git diff --stat` | `67 files changed, 9099 insertions(+), 3064 deletions(-)` | `b1a-diff-stat-final.log` |

未跟踪文件按区域分布：

| 区域 | 文件数 | 内容 |
|---|---|---|
| `.qoder/` | 75 | IDE 生成的 repowiki（73 个知识库 md/yaml + 2 个索引） |
| `docs/` | 42 | `1.2.0/` 7、`architecture/` 1、`engineering/` 6、`manifests/` 1、`risks/` 1、`verification/` 5、顶层报告 21 |
| `packages/` | 26 | driver 6（3 源码 + 3 测试）、host 20（8 源码 + 12 测试） |
| `apps/mac/` | 16 | 8 个 App 服务 + 8 个 App 测试 |
| `tools/test_support/` | 1 | `make_payload_fixture.sh` |

### 2.2 版本与协议（只读核对）

| 项 | 值 | 命令 |
|---|---|---|
| `VERSION` | `1.2.0` | `cat VERSION` |
| Driver `SBAudioProtocolVersion` | `131584`（`0x00020200`） | `plutil -p packages/driver/Info.plist` |
| App / Driver `CFBundleShortVersionString` | 均为 `1.2.0` | `verify_installer_pkg.sh` 输出 |

本批次**没有**改动 `VERSION`、Protocol、Bundle Version、Build Number、ABI，也没有改动
HAL 安装位置。

### 2.3 发布产物（只读，未改动）

`dist/`（全部被 `.gitignore` 忽略，未重建、未删除）：

| 文件 | 时间 | 说明 |
|---|---|---|
| `SoundBridge-1.1.1.dmg` | Nov 17 15:11 | 历史产物，**保留** |
| `SoundBridge-1.1.1.pkg` | Nov 17 00:11 | 历史产物，**保留** |
| `SoundBridge-1.2.0.pkg` | Nov 21 13:21 | 当前候选件 |
| `SoundBridge-1.2.0.dmg` | Nov 21 13:23 | 当前候选件 |
| `SoundBridge-1.2.0.component.plist` | Nov 21 13:21 | PKG 组件描述 |
| `SoundBridge.app/` | Nov 21 13:15 | 候选 App bundle |

本批次所有测试均使用 `build/p3-host-restart-dist/SoundBridge-1.2.0.pkg` 或临时目录中的
合成 fixture；**没有读取、没有改写 `dist/`**。

### 2.4 批次前 SHA-256 基线

`b1a-sha256-before.log` 记录了 10 个文件的基线与 2 个 `MISSING`（两份被删文档）。需要
说明的是：该快照采集于 16:18，此时 P1-1 / P1-2 的**第一版实现已经落盘**，所以它不是
「批次开始前」的状态，而是「本批次中途」的状态。

真正的批次前基线以 `HEAD` 为准：§9.1 的 BEFORE 列全部由 `git show HEAD:<path>` 重新计算，
§9.2 是本批次中途 → 结束的二次对照。

---

## 3. P1-1：统一 Driver 安装路径

### 3.1 问题（P4 Batch 0 §9）

`DriverInstaller.swift:192-198` 在 App 内实现了一套与 PKG 完全不同的安装事务：
`osascript` 提权 → `rm -rf` 旧 bundle → `cp -R` 新 bundle → `mv` → `killall coreaudiod`。
没有预检、没有备份、没有回滚；磁盘写满时会在 HAL 目录留下半份 bundle；`killall` 会
让所有进程的音频同时中断。而正式 PKG 走 `tools/sb_install_transaction.sh`（校验载荷 →
暂存 → 校验副本 → 备份旧驱动 → 重命名换位 → 再次校验 → 失败回滚）。同一个产品里出现
两套安全等级相差一个数量级的安装路径。

### 3.2 采用方案：删除第二套事务

任务书给出的优先方案（App 不再自行安装，引导用户使用正式 PKG）在当前架构下**可以**
直接采用，原因有三：

1. PKG 已经是唯一支持的分发渠道，`dist/` 与 Release 渠道都同时提供 `.pkg`；
2. 驱动的版本门禁（`preinstall`）与事务替换（`postinstall` → `sb_install_transaction.sh`）
   已经存在并经过测试（`make test-installer-gate` 83 条断言）；
3. App 本来就需要 `DriverVersionGate` 来读「已装驱动的状态」，它可以直接复用为
   「安装结果判定器」，不需要新写检测逻辑。

因此**没有**设计第三套事务，`DriverInstaller` 从「安装器」降级为「只读检测器」。

### 3.3 实现

| 文件 | 变化 |
|---|---|
| `Sources/Services/DriverInstaller.swift` | 10 775 B → 3 707 B。删除 `installDriver()` / `installDriverWithPrivileges()` / `DriverInstallState` / `NSAppleScript`。新增 `enum DriverBundleLocation`（`driverPath` / `bundleIdentifier` / `infoPlistPath`）作为**单一常量源**；`DriverInstaller` 只剩 `currentInstallStatus()` 与 `isDriverInstalled()` |
| `Sources/Services/DriverInstallGuide.swift`（新，4 051 B） | 纯函数 `locatePackage(in:preferring:)` 与 `action(appBundleURL:appVersion:releasePageURL:)` → `Action { openPackage(URL) / openReleasePage(URL) / namePackage(String) }`。只接受 `SoundBridge-*.pkg`，优先精确文件名，否则取排序首个 |
| `Sources/Onboarding/OnboardingView.swift` | 用 `guideAction` 驱动三种按钮：`Open Installer Package` / 打开 Release 页面 / 只显示文件名。`open(_:)` 只调用 `NSWorkspace.shared.open(url)` 并置 `isWaitingForInstaller = true`，不提权、不复制 |
| `Sources/App/SoundBridgeApp.swift` | 启动路径改为 `DriverInstaller().currentInstallStatus()`；删除安装回调 |
| `Sources/Views/DriverUpdateWindow.swift`（删除） | 这是 App 内的「升级驱动」窗口，其唯一功能就是调用已删除的安装事务 |

### 3.4 「未验证不得显示成功」如何落实

`OnboardingView` 的页面状态**只**由一次文件系统读取决定，不由用户点击决定：

```swift
// 点击安装包只记录「在等待」，不记录「成功」
private func open(_ url: URL) {
    isWaitingForInstaller = true
    _ = NSWorkspace.shared.open(url)
}

// 唯一的判定入口：读已装 bundle 的 Info.plist，与本构建比较
private func readInstalledState() {
    let current = installer.currentInstallStatus()   // → DriverVersionGate.evaluate
    status = current
    if current.isCompatible { isWaitingForInstaller = false }
}

.onReceive(NotificationCenter.default.publisher(
    for: NSApplication.didBecomeActiveNotification)) { _ in
    guard isWaitingForInstaller else { return }
    readInstalledState()      // 从 Installer 返回后自动重查
}
```

判定输入只有「`/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist`
的版本 + 协议」与「本构建的版本 + 协议」。安装被取消、失败、或被替换成旧版本，页面
都会停在「未就绪」，不会出现成功态。另有 `Check Again` 手动重查按钮。

### 3.5 不变量与测试锁定

`DriverInstallBoundaryTests` 用逐文件扫描把「不能装」变成可执行断言：

| 断言 | 内容 |
|---|---|
| `testNoSourceCanInstallTheDriver` | 全部 `Sources/` 中禁止出现 `installDriver(`、`installDriverWithPrivileges`、`DriverInstallState`、`cp -R` |
| `testOnboardingPointsAtTheInstallerPackage` | Onboarding 必须含 `DriverInstallGuide.action(` 与 `Open Installer Package`，且禁止 `NSAppleScript`、`killall` |
| `testOnboardingCompletionIsDecidedByTheVersionGate` | 成功态只能来自 `currentInstallStatus()` |
| `testExactlyOnePrivilegedCommandExists` | 全 App 只剩 **1** 处 `with administrator privileges`，且位于 `DriverUninstaller.swift` |
| `testTheAppNeverRestartsCoreAudio` | 无 `killall`、无 `coreaudiod` 重启调用 |
| `testShippingPolicyRemainsReportOnly` | 兼容性提示只有文字，没有「一键修复」按钮 |

### 3.6 边界

- 未执行真实安装（任务书 §3 约束）；`driverPath` 指向真实 HAL 目录，但测试不触碰它。
- 未 `sudo`、未重启 `coreaudiod`、未改变当前已安装 Driver。
- App 不会「感知安装完成」以外的任何事：安装器返回后如果驱动版本仍不匹配，页面
  会继续显示未就绪，并给出「文件名 / Release 页面」两条指引。

---

## 4. P1-2：统一 Driver 卸载路径

### 4.1 问题

`MenuBarView.performUninstall` 的旧实现同时存在 6 个问题：无条件 `killall coreaudiod`、
不校验 `CFBundleIdentifier` 就 `rm -rf`、用 `/tmp/soundbridge-*` 通配符跨用户删文件、
`killall SoundBridgeHost` 按名字杀进程、清理范围与提示文案不符（说清配置却保留
`eq_default_*`）、以及和 `tools/uninstall_driver.sh` 的政策相反。

### 4.2 统一后的政策（任务书 §4 的 9 条逐条对应）

| §4 要求 | 落实方式 | 代码位置 |
|---|---|---|
| ① 不得无条件 killall coreaudiod | `DriverUninstallPolicy.restartsCoreAudio = false`；全 App 无 `killall` | `DriverUninstallPolicy.swift`、`uninstall_driver.sh` |
| ② 删前校验 CFBundleIdentifier | `decide(_:)` 读 plist，非 `com.soundbridge.driver` 一律 `.refuse` | `DriverUninstallPolicy.decide` |
| ③ 不得用宽泛 `/tmp` 通配符 | 删除命令只有一个常量路径，无通配符 | `removalCommand` |
| ④ 不得删其他 HAL Driver | 路径写死为 `DriverBundleLocation.driverPath`，不做目录遍历 | 同上 |
| ⑤ 明确 Host 退出与 supervisor 顺序 | 先 `prepareForUninstall`（→ `HostSupervisor.shutdown(intent: .uninstall)` 并等待），**完成回调里**才删 bundle | `MenuBarView.performUninstall` |
| ⑥ 避免卸载中 Host 被重启 | `shutdown(intent: .uninstall)` 置 supervisor 的 shutdown latch，此期间不重启 | `HostSupervisor` |
| ⑦ Application Support / Logs / UserDefaults / EQ 保留策略 | `removed` / `kept` 两个常量列表，UI 逐条展示 | `DriverUninstallPolicy` |
| ⑧ UI 文案准确 | NSAlert 直接渲染 `removed` / `kept`，与政策同源 | `MenuBarView` |
| ⑨ 与 `tools/uninstall_driver.sh` 一致 | 测试把脚本的 `$DRIVER_PATH` 展开后与 App 命令做**字节级相等**断言 | `DriverInstallBoundaryTests.testUninstallPolicyMatchesTheScript` |

### 4.3 政策实现

`DriverUninstallPolicy.decide(_:)` 是纯函数，判定顺序为：

```
symlink            → notPresent（报告 isPresent，但拒绝跟随）
路径不存在          → notPresent
不是目录            → notDirectory
读不出 plist / 无 id → noIdentifier
id ≠ com.soundbridge.driver → foreignBundle(id)
以上都不是          → remove
```

`.notPresent` 与 `.refuse` 都在**弹出任何授权框之前**返回，页面只报告「什么都没改」。

`DriverUninstaller.remove()` 是唯一提权点：

```swift
let script = "do shell script \"\(DriverUninstallPolicy.removalCommand)\" "
           + "with administrator privileges"
NSAppleScript(source: script)?.executeAndReturnError(&error)
guard (try? fileManager.attributesOfItem(atPath: driverPath)) == nil
else { throw Failure.removalDidNotComplete(driverPath) }   // 路径还在 = 失败
```

即「执行命令」不等于「成功」：必须再确认路径消失。

### 4.4 卸载流程（App）

```
菜单栏 → Uninstall Driver
  ├─ decide(readIdentity()) == .nothingToRemove → 「Driver Not Installed」，结束
  ├─ decide == .refuse(reason)                 → 「Driver Left Alone」+ 原因，结束
  └─ decide == .remove
       ├─ NSAlert：「This removes: …」/「This keeps: …」（来自政策常量）
       ├─ AppDelegate.prepareForUninstall { removeDriverAndFinish() }
       │     └─ HostSupervisor.shutdown(intent: .uninstall) → 等待 Host 退出
       ├─ DriverUninstaller.remove()   ← 唯一的提权命令
       │     └─ 失败：「Driver Not Removed」，onboarding 状态不动、EQ 不动
       ├─ 成功后才清除 4 个 onboarding 键
       │     hasCompletedOnboarding / onboardingVersion /
       │     driverInstallDate / lastDriverVersionCheck
       └─ 「Driver Removed」+ restartAdvice + kept 列表 → NSApp.terminate
```

顺序是刻意的：**Host 先停，bundle 后删**。如果顺序反过来，Host 在 bundle 消失的瞬间
会观察到驱动消失并可能尝试重建映射；而 supervisor 的 uninstall latch 让「Host 退出」
不被误判为崩溃进而被重新拉起。

### 4.5 数据保留策略

| 类别 | 内容 | 卸载后 |
|---|---|---|
| 删除 | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` | 删 |
| 删除 | 4 个 onboarding UserDefaults 键 | 清（下次启动重新引导） |
| 保留 | EQ 设置与保存的 EQ 配置（`eq_default_*`） | 留 |
| 保留 | 音量状态 `~/Library/Application Support/SoundBridge/volume-state.json` | 留 |
| 保留 | 日志 `~/Library/Logs/SoundBridge` | 留 |
| 保留 | `SoundBridge.app` 本身 | 留（由用户自行拖入废纸篓） |

`eq_default_*` 与音量/日志保留是刻意的：它们正是重装后恢复的输入，也是排查重装
问题的证据。任务书 §4 第 7 条要求的「明确保留策略」由 `DriverUninstallPolicy.kept`
与 `INSTALLATION_GUIDE.md` §9.4 两处同源描述。

### 4.6 与 `tools/uninstall_driver.sh` 的一致性

脚本保留了自己的 `--dry-run`、`SB_DRIVER_PATH` 覆盖与 `info/warn` 输出，但政策逐条相同：
读 plist 校验 id、拒绝符号链接、只删一个常量路径、不 `killall`（仅在输出里建议用户
自己决定何时重启）、不做 `/tmp` 通配符清理。

一致性由测试强制执行，而不是靠文档承诺：

```swift
let shape = "/bin/rm -rf '$DRIVER_PATH'"
XCTAssertTrue(text.contains(shape))
XCTAssertEqual(shape.replacingOccurrences(of: "$DRIVER_PATH",
                                          with: DriverUninstallPolicy.driverPath),
               DriverUninstallPolicy.removalCommand)
```

第二行是关键的：脚本的参数化命令展开后必须与 App 的 `removalCommand` **完全相同**。

### 4.7 边界

- 未执行真实卸载；未修改系统 HAL 目录。
- `uninstall_driver.sh` 的 `--dry-run` 路径可用且不写文件（由脚本自身保证，本批次未运行）。
- 现在两条路径都不重启 `coreaudiod`；何时重启由用户决定（`restartAdvice` 只给建议）。

---

## 5. P1-3：修复 Release Payload 测试

### 5.1 旧依赖

```
FIXTURE_VERSION=1.1.1
PKG=dist/SoundBridge-1.1.1.pkg
DMG=dist/SoundBridge-1.1.1.dmg
```

后果有两个：① 任何一次 `dist/` 清理都会让发布测试失败；② 测试通过与否取决于「机器上
恰好躺着一个 1.1.1 发布件」，而不是当前源码。这是把历史产物当成了测试输入。

### 5.2 合成 fixture

新增 `tools/test_support/make_payload_fixture.sh`（6 620 B），在 `mktemp -d` 中从**源码**
构造一次完整的「上一版发布」：

| 步骤 | 做法 |
|---|---|
| 版本 | `FIXTURE_VERSION="${SB_FIXTURE_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"` —— 默认取仓库 `VERSION`，测试场景可用环境变量指定任意值 |
| 协议 | 从 `packages/shared/include/RFSharedAudio.h` 解析，不写死数字 |
| 二进制 | `clang -isysroot "$(xcrun --show-sdk-path)" -arch arm64 -arch x86_64 -mmacosx-version-min=14.4` 生成 universal stub |
| App / Driver | 合成 bundle，含 `Sparkle.framework`（`Versions/B` + `Versions/Current` → B） |
| PKG | 调用**真实的** `tools/build_installer_pkg.sh --app --out --version` |
| DMG | 调用**真实的** `tools/create_dmg.sh --app --version --backend hdiutil`（`SB_DIST_DIR` 指向临时目录） |
| 输出 | `FIXTURE_VERSION / FIXTURE_PROTOCOL / FIXTURE_APP / FIXTURE_PKG / FIXTURE_DMG` |

关键在于 fixture 用真实打包器构造，所以 verifier 面对的不是伪造的目录结构，而是真实
产物的结构；被测试的仍然是 verifier 的判断力，而不是 fixture 的构造巧合。

### 5.3 `test_release_payload.sh` 的改造

| 位置 | 改造 |
|---|---|
| 变量 | `FIXTURE_VERSION`（默认 `VERSION`）、`OLD_VERSION`（默认 `1.1.1`，仅作为「陈旧版本」场景常量） |
| helper | `run_pkg(){ "$VERIFY_PKG" --app "$FIX_APP" "$@"; }` |
| 统一目标 | `ALL_TARGETS=(--pkg "$FIX_PKG" --dmg "$FIX_DMG" --app "$FIX_APP" --version "$FIXTURE_VERSION")` |
| 四向一致性 | `run_four_way` 显式带 `--app "$FIX_APP"` |
| B-7 陈旧场景 | 用 `$OLD_VERSION` 生成「更旧的包」，不再引用 `dist/` |
| 挂载卫生 | `grep -cF "$FIX_DMG"`，只统计本次 fixture 的挂载 |
| 临时目录 | 整个测试在 `mktemp -d` 中运行，退出时清理 |
| 退出码 | 任一断言失败即非零退出 |

源码中已无 `SoundBridge-1.1.1`、`FIXTURE_VERSION=1.1.1`、`131328` 字面量（唯一命中是
`make_payload_fixture.sh` 的注释，说明「以前带着这些字面量」）。

### 5.4 为什么 `FIXTURE_VERSION` 默认取 `VERSION` 而不是随意值

`verify_dmg_contents.sh` 会校验 DMG 内 App 的版本与 `packages/host/Info.plist` 的
`HOST_SOURCE_VERSION` 一致。如果 fixture 用一个与源码无关的版本号，verifier 会因为
「fixture 与源码不一致」而失败，测的就不是 verifier 了。所以默认取 `VERSION`，
「陈旧版本」场景则通过 `OLD_VERSION` 显式表达。

### 5.5 结果

```
$ ./tools/test_release_payload.sh
...
passed: 244  failed: 0        (exit 0)
```

`dist/` 中的 1.1.1 产物**没有被删除**，也没有被读取。完整日志：
`build/p4-batch1a/evidence/b1a-test-release-payload.log`。

---

## 6. P1-5：恢复和更新发布文档

### 6.1 恢复方式（未使用 git checkout / restore）

两份文档在工作区显示为删除。恢复方式是只读提取再重写：

```
git show HEAD:docs/RELEASE_NOTES.md        → 198 行（旧版）
git show HEAD:docs/INSTALLATION_GUIDE.md   → 271 行（旧版）
```

旧版被逐条核对，与当前实现冲突的内容**全部不沿用**：

| 旧版内容 | 当前事实 | 处理 |
|---|---|---|
| 协议 `0x00020100` / 131328 | `0x00020200` / 131584 | 改写 |
| `sudo killall coreaudiod` 作为安装后步骤 | 安装器与 App 都不重启 | 删除，改为「用户自己决定」 |
| 测试数（Host 2xx / App 1xx） | Host 379 / App 253 | 改写 |
| 声称自动更新可用 | `SUPublicEDKey` 为空，updater 不初始化 | 标记「未启用」 |
| 「用 DMG 升级」 | DMG 只有 App，不含驱动 | 标记「升级一律用 PKG」 |
| 「菜单栏卸载会清除所有配置」 | 保留 `eq_default_*`、音量、日志 | 改为删除/保留清单 |

### 6.2 `docs/RELEASE_NOTES.md`（256 行）

结构：

| 节 | 内容 |
|---|---|
| 0 | 四级证据等级定义 + **Pre-release 声明**（明确不得描述为「音频质量已通过」） |
| 1 | 两条渠道（PKG 安装/升级、DMG 只换 App）+ ad-hoc 签名声明 |
| 2 | 从 1.1.x 升级：协议变更 + preinstall 门禁表 + 先退出 App |
| 3.1–3.11 | 安装器、App 不再安装、统一卸载、HostSupervisor、Host-only Restart、EQService、SharedMemoryMappingManager、EQ Mapping 自动恢复、Default Output 治理、RT 可观测性、安装器与发布检查器 |
| 4 | 验证规模表（Host 379、App 253、DSP 33、36 场景/168 断言、58 checks、244 断言） |
| 5 | **明确未验证 N-1 – N-8**，前三条为 EQ 听感、underrun、卸载重装闭环 |
| 6 | 已知限制（Sparkle 未启用、P2-5、P2-1、RT-1–RT-5） |
| 7 | 安装与卸载入口 |
| 8 | 发布结论：**Pre-release，不具备「正式可用」声明条件** |

每条结论都带 `REAL_MACOS_VERIFIED` / `TEST_VERIFIED` / `SOURCE_VERIFIED` /
`NOT_VERIFIED` 标记；同一功能有多个来源时以最高等级为准。

### 6.3 `docs/INSTALLATION_GUIDE.md`（374 行）

12 节，覆盖任务书 §6 的全部要求：

| 节 | 覆盖的要求 |
|---|---|
| 0 | 两个组件 + **安装前先退出 App**（P2-5）+ ad-hoc 声明，不承诺 Developer ID/公证 |
| 1 | **DMG 与 PKG 的用途区别**（PKG 装 App+驱动；DMG 只换 App） |
| 2 | SHA256 校验（校验值只在 Release 的 `SHA256SUMS.txt` 维护，不复制副本） |
| 3 | **正式 PKG 安装** + 管理员授权说明 + preinstall 门禁表 + 事务六步 |
| 4 | DMG 安装（仅 App） |
| 5 | Gatekeeper 放行（App 与 PKG 分列；禁止关 Gatekeeper / SIP） |
| 6 | 确认驱动（版本、`SBAudioProtocolVersion`、目录） |
| 7 | 声音设置选设备（SoundBridge 是代理，不自己出声） |
| 8 | 排查：8.1 HDMI/DisplayPort 无声 5 步、8.2 驱动未加载 5 步 |
| 9 | **统一卸载政策**（5 条规则）+ App 路径 + 命令行 + 手动删前校验 + **删除/保留清单** |
| 10 | 回退旧驱动 |
| 11 | Sparkle 未启用 |
| 12 | 验证状态表（SOURCE_VERIFIED / TEST_VERIFIED / NOT_VERIFIED） |

全文没有要求用户执行 `swift build`、`make`、`cmake` 之类的开发者命令；唯一出现的
命令行是「查看版本 / 查看日志 / `codesign --verify` / `uninstall_driver.sh` / 手动删除
且先校验 bundle id」。

### 6.4 `README.md`（三处矛盾）

| P4 审计指出的矛盾 | 修正后 |
|---|---|
| ① DMG / PKG 用途混淆（写着 DMG 安装、PKG 只提一句） | Installation 整段重写：PKG/DMG 用途表 + 「升级用 PKG」+ 先退出 App + 管理员授权 + Gatekeeper 放行 |
| ② 把「菜单栏卸载」写成唯一官方方式，且与实际清理范围不符 | 新增 **Uninstalling** 节：App 入口与 `tools/uninstall_driver.sh` 是同一政策，并给出删除/保留摘要 |
| ③ 声称 Sparkle 自动更新 | 标题改为 **Auto-updates (not enabled in 1.2.0)**，正文说明 `SUPublicEDKey` 为空、需下载新 PKG |

附带修正：`Features` 去掉 "Code signed and notarized"（实际是 ad-hoc）；`make sign`
说明改为 ad-hoc 默认；Release Pipeline 的第 4 步改为同时构建 PKG + DMG、第 6 步上传 PKG；
目录树注释去掉 `notarize`；`Contributing` 里把「产品会帮你 killall」改为「需要时自己执行」。

---

## 7. P2-6：风险登记表与 Release Checklist

### 7.1 `docs/risks/Known-Limitations.md`

| 变化 | 内容 |
|---|---|
| 新增 **§0「P2/P3 已关闭、且有证据的事项」** | P2-B2（默认输出治理）、P2-B3（EQ 映射恢复）、P2-B4（H-1–H-3 渲染安全）、P3-HR（Host-only Restart）、P4-1A-1/2/3（本批次三项），每行都带证据报告路径与测试名 |
| B 类表重写 | 增加「现状 / 证据位置」两列；U-4（默认输出）标记**已验证并关闭** |
| 新增 U-14 / U-15 / U-16 | 实际 EQ 听感、播放窗口 underrun、真实卸载→重装闭环 —— 三条都是**未验证** |
| §3.2 的 H-1 – H-3 | 从「待修」改为「已关闭」，并写明关闭方式（`enterRenderMemory` + 预分配 + 计数器；诊断输出移到控制线程） |
| §5 | 改为「P4 Batch 1A 明确未执行的项」：不修 P2-1/P2-2/P2-3/P2-4/P2-5/P3-2，并说明原因 |
| §6 | 汇总数更新为 A 12 / B 16 / C 10 / D 8，已关闭 3 + 7 |

### 7.2 `docs/release/SoundBridge-1.2.0-Release-Checklist.md`

| 变化 | 内容 |
|---|---|
| 头部状态 | 改为「Pre-release + P4 Batch 1A 已完成源码级收敛」，并规定「没有证据的格子只能留空，不能填 PASS」 |
| §1 构建 | **删除 `make clean` 指令**，改为「不要为了通过检查而 `make clean`；需要干净构建时另开克隆」 |
| §2 测试表 | 更新为 Host 379 / App 253 / DSP 33 / 安装门禁 36 场景·168 断言 / 签名 58 / 载荷 244（合成 fixture） |
| §5 安装器与 DMG | 去掉 `make dmg`，加入 PKG 行与「上表只列只读检查」说明 |
| §6 真实环境验证 | 从 10 行扩为 **12 行**，新增「实际 EQ 听感」「播放窗口 underrun」「卸载→重装闭环」三行，全部标「无」并注明 U-14/U-15/U-16 |
| §7 文档同步 | 加入 RELEASE_NOTES 与 INSTALLATION_GUIDE 两行 |
| §8 阻断项 | 重排为 B-1 … B-7，并注明「本轮已关闭：Host/App 全量回归」 |

**没有**把任何 NOT_VERIFIED 项标成 PASS；§6 的 12 行里 12 行都带「无」或部分证据说明。

---

## 8. 修改文件完整清单

### 8.1 本批次实际改动的 18 个文件

| # | 文件 | Git | 字节（前 → 后） | 目的 | 对应问题 |
|---|---|---|---|---|---|
| 1 | `Sources/Services/DriverInstaller.swift` | M | 10,775 → 3,707 | 删除安装事务，只保留只读检测 + `DriverBundleLocation` | P1-1 |
| 2 | `Sources/Services/DriverInstallGuide.swift` | 新 | — → 4,051 | PKG 定位 + 三种引导动作 | P1-1 |
| 3 | `Sources/Services/DriverUninstallPolicy.swift` | 新 | — → 4,323 | 卸载政策单源（身份判定 + 命令 + 保留清单） | P1-2 |
| 4 | `Sources/Services/DriverUninstaller.swift` | 新 | — → 3,052 | 唯一提权点 + 删除后确认 | P1-2 |
| 5 | `Sources/Onboarding/OnboardingView.swift` | M | 11,903 → 16,441 | 三种引导按钮 + 「只认 gate」的状态判定 | P1-1 |
| 6 | `Sources/Views/DriverUpdateWindow.swift` | **D** | 删除 | 该窗口唯一功能是已删除的安装事务 | P1-1 |
| 7 | `Sources/Views/MenuBarView.swift` | M | 20,481 → 21,981 | 卸载改为「先判定 → 先停 Host → 只删一个路径 → 确认」 | P1-2 |
| 8 | `Sources/App/SoundBridgeApp.swift` | M | 43,214 → 39,802 | 启动路径改用只读检测；`prepareForUninstall` 交接 | P1-1 / P1-2 |
| 9 | `Tests/.../DriverInstallBoundaryTests.swift` | M | → 13,960 | 把「不能安装」「只剩一条特权命令」变成断言；脚本字节等价断言 | P1-1 / P1-2 |
| 10 | `tools/test_release_payload.sh` | M | 51,399 → 54,724 | 去掉 1.1.1 硬编码，改用合成 fixture | P1-3 |
| 11 | `tools/test_support/make_payload_fixture.sh` | 新 | — → 6,620 | 从源码合成上一版 PKG/DMG | P1-3 |
| 12 | `tools/uninstall_driver.sh` | M | → 5,457 | 去 `killall`，校验 bundle id，拒绝符号链接 | P1-2 |
| 13 | `docs/RELEASE_NOTES.md` | 重写 | 12,691 | 按当前事实重写，四级证据等级 + 未验证声明 | P1-5 |
| 14 | `docs/INSTALLATION_GUIDE.md` | 重写 | 15,025 | PKG/DMG 用途、Gatekeeper、排查、统一卸载政策 | P1-5 |
| 15 | `README.md` | M | 13,263 → 15,264 | 修正 DMG/PKG、卸载入口、Sparkle 三处矛盾 | P1-5 |
| 16 | `docs/risks/Known-Limitations.md` | M | 11,375 → 16,168 | §0 已关闭表、U-14/15/16、H-1–H-3 关闭 | P2-6 |
| 17 | `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | M | 6,519 → 9,039 | 删 `make clean`、测试表、12 行真实环境、阻断项 B-1–B-7 | P2-6 |
| 18 | `docs/P4-Batch-1A-Source-Stabilization-Report.md` | 新 | 本文件 | 本批次报告 | §12 交付 |

### 8.2 本批次没有碰、但工作区里处于修改状态的文件

`git status` 里的其余 **56** 个跟踪文件与 **80** 个非 `.qoder/` 未跟踪文件属于 P2/P3 阶段的工作
（HostSupervisor、EQService、SharedMemoryMappingManager、Default Output 治理、RT 可观测性、
驱动侧 ControlProtocol/MappingRetirement/ProducerToken、以及对应的测试与工具脚本改造）。
它们**不是本批次写的**，本批次只做了两件事：读它们来确认事实，以及让 App 侧引用它们
（例如 `MenuBarView` 调用 `HostSupervisor.shutdown`）。它们的归属见 §11。

---

## 9. SHA-256 修改前后对照

### 9.1 全部 67 个跟踪改动（BEFORE = `git show HEAD:<path>`，AFTER = 工作区）

下表只列前 12 位十六进制；完整 64 位值见
`build/p4-batch1a/evidence/b1a-sha256-full.log`。`ABSENT` 表示该侧不存在。

| 文件 | BEFORE（12） | AFTER（12） | AFTER 字节 |
|---|---|---|---|
| `Makefile` | 15e3fa2c1f59 | 8151b25d3fea | 20,348 |
| `README.md` | ed92ff067661 | 73b9e3787bc5 | 15,264 |
| `apps/.../App/SoundBridgeApp.swift` | d02a1dec6b51 | b83b22e45a60 | 39,802 |
| `apps/.../CSoundBridgeAudio/include/RFSharedAudio.h` | f309926df993 | 0f4154504374 | 69,590 |
| `apps/.../Models/HostLifecycleReport.swift` | 5cd61f4547ab | 26ffaac6676f | 8,112 |
| `apps/.../Models/HostStatusModel.swift` | 826d3c1c5600 | 6d3ec47923be | 3,138 |
| `apps/.../Onboarding/OnboardingView.swift` | 8c3010e6b585 | dfaf9653b072 | 16,441 |
| `apps/.../Services/DriverInstaller.swift` | 809e3f8b1afe | 8d8c9de83a12 | 3,707 |
| `apps/.../Services/DriverVersionGate.swift` | 0ac0fce69af7 | dff762610829 | 15,500 |
| `apps/.../Services/EQController.swift` | 228aa198544b | ba434220dcbe | 19,740 |
| `apps/.../Services/HostInstanceProbe.swift` | 748d88a0a72b | ae235f0fb454 | 5,960 |
| `apps/.../Services/IPCController.swift` | ff0a3ffa4e0e | 81efce05f4e4 | 15,413 |
| `apps/.../Services/VolumeController.swift` | f315c01edd24 | 1367646438cc | 25,312 |
| `apps/.../Views/DriverUpdateWindow.swift` | 784f7db881cb | **ABSENT** | 0 |
| `apps/.../Views/MenuBarView.swift` | 6d587176cb18 | 2f39998e2eba | 21,981 |
| `apps/.../Tests/DriverCompatibilityNoticeTests.swift` | 28f582a2ca9b | 8e55824438ef | 11,908 |
| `apps/.../Tests/DriverInstallBoundaryTests.swift` | 0a33aa6c4574 | b81cc1595e80 | 13,960 |
| `apps/.../Tests/DriverInstallIntentTests.swift` | 6a4567b8d927 | dd7950e01f0d | 5,156 |
| `apps/.../Tests/DriverRecoveryMatrixTests.swift` | 6d38fdee087d | 7c8d81866216 | 11,892 |
| `apps/.../Tests/DriverVersionGateTests.swift` | f208447b3c83 | f81e4c559d31 | 19,974 |
| `apps/.../Tests/HostInstanceProbeTests.swift` | 7774130d2121 | 59ff5e080d83 | 7,758 |
| `apps/.../Tests/HostRunStateTests.swift` | c3f211aee983 | e3b96cb25134 | 24,124 |
| `docs/INSTALLATION_GUIDE.md` | 5e141e5bda2d | 91adce858cc0 | 15,025 |
| `docs/RELEASE_NOTES.md` | 8feb6f0822f5 | 83d99d719097 | 12,691 |
| `packages/driver/CMakeLists.txt` | efb615f0e1cf | 8c31f29d788a | 4,515 |
| `packages/driver/Info.plist` | 81ce44e30e26 | 275eb53aadcd | 1,449 |
| `packages/driver/include/RFSharedAudio.h` | f309926df993 | 0f4154504374 | 69,590 |
| `packages/driver/src/Plugin.cpp` | 80dcfe4b3c06 | 8f31748c5e65 | 76,690 |
| `packages/host/.../include/RFSharedAudio.h` | f309926df993 | 0f4154504374 | 69,590 |
| `packages/host/.../include/module.modulemap` | 5f686ea38190 | ff214effcd5c | 143 |
| `packages/host/.../CSoundBridgeAudio/shim.c` | fef785cad679 | bb0581f94faf | 581 |
| `packages/host/.../Audio/AudioEngine.swift` | d2ac405c370a | 9adb7d75a035 | 15,208 |
| `packages/host/.../Audio/AudioRenderer.swift` | 8c2130157644 | 8403000b0f85 | 33,547 |
| `packages/host/.../Constants.swift` | 140dc4d50afc | fd7052a5b394 | 5,281 |
| `packages/host/.../Devices/DeviceDiscovery.swift` | bfd6fb1b5729 | 7899a9484a2d | 19,982 |
| `packages/host/.../Devices/DeviceMonitor.swift` | a19c66243db5 | e986832f721d | 30,358 |
| `packages/host/.../Devices/DeviceRegistry.swift` | b543966fedf0 | fb9e6c57513f | 10,882 |
| `packages/host/.../Devices/ProxyDeviceManager.swift` | 2060aa5a7dae | 614f4b9310ba | 37,071 |
| `packages/host/.../Devices/SleepWakeMonitor.swift` | f461fc04d2f5 | ba6ca8970eab | 3,470 |
| `packages/host/.../Lifecycle/DriverLifecycle.swift` | 6220c85b85cf | 9e92d01fcd00 | 17,289 |
| `packages/host/.../Lifecycle/HostInstanceLock.swift` | 893e0402c8db | 998c939e3e08 | 14,086 |
| `packages/host/.../Lifecycle/HostLifecycleReporter.swift` | fc2488039715 | be48b668e9f0 | 5,829 |
| `packages/host/.../Lifecycle/ShutdownSequence.swift` | 9708335f1227 | d37578b6bd86 | 4,842 |
| `packages/host/.../Memory/SharedMemoryManager.swift` | a7ffa605fb57 | 6a75fbdb5325 | 37,506 |
| `packages/host/.../Services/VolumePersistence.swift` | 0df343250a22 | f691def8ed60 | 4,144 |
| `packages/host/.../Utilities/PathManager.swift` | f894e7280e5a | 2123796fc088 | 2,325 |
| `packages/host/.../main.swift` | e61acc1682ab | b27a3a7f5221 | 48,627 |
| `packages/host/Tests/AtomicMemoryModelTests.swift` | f14ed1261d71 | ca3925f4fe32 | 22,976 |
| `packages/host/Tests/DegradedLifecycleTests.swift` | c626267a8142 | 04a6064e4471 | 14,739 |
| `packages/host/Tests/DriverHeartbeatCrossProcessTests.swift` | 1486a9088080 | e7a1ce58ab74 | 17,456 |
| `packages/host/Tests/HostInstanceLockTests.swift` | d26db409fd14 | 2efcfa57f5ea | 28,781 |
| `packages/host/Tests/SharedMemoryFileSystemTests.swift` | affe4497f0c3 | 5f5d79760b67 | 19,747 |
| `packages/host/Tests/SharedMemoryMultiProcessTests.swift` | a12a07a96721 | 13ef851a3f15 | 19,367 |
| `packages/host/Tests/SharedMemoryProtocolTests.swift` | a5f5d658d8a9 | cca305a69e9c | 13,717 |
| `packages/host/Tests/SharedMemoryRecoveryTests.swift` | 2bacd70c136d | 3bd6bc787227 | 15,960 |
| `packages/host/Tests/StartupFailureCleanupTests.swift` | 46f190eab821 | 2c8bdd2c938e | 5,624 |
| `packages/host/Tests/VolumeStateTests.swift` | 83551139dc8e | c6aa5bcd68db | 12,698 |
| `packages/shared/include/RFSharedAudio.h` | f309926df993 | 0f4154504374 | 69,590 |
| `tools/build_installer_pkg.sh` | 14e39e7d809b | d64626ad7984 | 25,650 |
| `tools/check_protocol_layout.sh` | c618009d6b57 | 95058fc0e43b | 8,760 |
| `tools/test_release_payload.sh` | ba8960162269 | 3ce78a42855d | 54,724 |
| `tools/uninstall_driver.sh` | bd24bb476840 | 5c2e5363167b | 5,457 |
| `tools/verify_dmg_contents.sh` | 2fb1f27038cf | a95d8e1e720b | 29,522 |
| `tools/verify_installer_pkg.sh` | e85d6c8a0222 | 275c29337100 | 24,561 |
| `tools/verify_pkg_contents.sh` | e8cfb0ca1f23 | 05d4018e2bda | 26,186 |
| `tools/verify_release_bundle.sh` | 4b960413e9d3 | 849cf740bbf9 | 12,330 |
| `tools/verify_release_payload.sh` | 62e6a1aec3c5 | b0acaf9e74a6 | 18,550 |

四个 `RFSharedAudio.h` 副本（App / driver / host / shared）在 AFTER 列**哈希完全相同**
（`0f4154504374…`），说明头副本仍然同步，`tools/sync_shared_header.sh --check` 的前提成立。

### 9.2 本批次 18 个文件的完整 64 位哈希

| 文件 | BEFORE | AFTER |
|---|---|---|
| `Sources/Services/DriverInstaller.swift` | `809e3f8b1afe3a5f1943e3f7991b234422fb3404d9740727067e9475f3fc279c` | `8d8c9de83a128d77c65fe4f05dc9ee7efb140f07f0c19a61d11ad7d428acbc64` |
| `Sources/Onboarding/OnboardingView.swift` | `8c3010e6b58540675990f3fbd600dcd0ba457ad440c9356d55c1157d19f8acc6` | `dfaf9653b0721c67a7ae26f0c7ec577b7f5ce0517da8a65ae5825eb1b25ccbff` |
| `Sources/Views/MenuBarView.swift` | `6d587176cb18bc54a8afa38280b84b9cbb045b1fff00c45c8a4dbd103a62bfff` | `2f39998e2ebae8623a897931ae6d0eb2f3b2105d602686432a399a290c45f4d3` |
| `Sources/App/SoundBridgeApp.swift` | `d02a1dec6b51b657569d8dfd4b0a9120dcefe2d28cda06d74750377d3898758b` | `b83b22e45a60e25447cc5f8a1f276ce6bbd1471663a7fa6b9488cc6144f2b5ec` |
| `Sources/Views/DriverUpdateWindow.swift` | `784f7db881cbda01ee9002a92659a4335db2b5d15beaf75b1485cee53c2f658d` | **ABSENT（已删除）** |
| `Tests/.../DriverInstallBoundaryTests.swift` | `0a33aa6c45743d37e4d4af282b4f89c138308a62d76371855ed8cfb2c0d6789a` | `b81cc1595e8072a3c45d5f4c0bba4172f2a8cda7d723a05f338f6faa3a2f9e38` |
| `tools/test_release_payload.sh` | `ba8960162269bd121d166d375ed945508a8e798852170cf044196ea2f87c88b4` | `3ce78a42855d9ab5359f2cb615739b0b56d8cad320071c8048a29c3c4217efd8` |
| `tools/uninstall_driver.sh` | `bd24bb476840a1de3ecb0996016af468b63ad44f604f568f88f1cca8a2a6a60b` | `5c2e5363167b5d968a70b62bd72b9724f72438a55c7e063271dff1ced99ea597` |
| `README.md` | `ed92ff0676613eafb80d66f49f10a5f94497d702412097c6515a2b53fd84d96a` | `73b9e3787bc519baac6c3dec481107945f37b12f1a7674e60309fc5124f5a9f5` |
| `docs/INSTALLATION_GUIDE.md` | `5e141e5bda2d9ebadfc1a56c0168d50580ff31c16fb4a24d1a3ecdb560e8bfa2` | `91adce858cc0d087152764b9ac3a61c7ec254f4604f8313ea6f097ce01daf74e` |
| `docs/RELEASE_NOTES.md` | `8feb6f0822f59b6f716203b3c072ccee8d156313835163cf76d4ede3744bee94` | `83d99d719097c359a8390a57d316cd549c1b8b2ce785b177a637b04704eb9bb9` |
| `docs/risks/Known-Limitations.md` | 不在 HEAD（未跟踪） | `693cc3d7f4fa32f6bdc5ec812eb7398e7a2f3356aa0cb1731558b0dd0a6d312a` |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | 不在 HEAD（被 `.gitignore` 忽略） | `2c16832712b3f26058670b92b6a765391cae33b8da463f639b56be056a5d38a7` |
| `Sources/Services/DriverInstallGuide.swift` | ABSENT | `eb94fb88464a88f3a5e0e8bea6a2a60f51eb75be10f93e1e0378198f466eef42` |
| `Sources/Services/DriverUninstallPolicy.swift` | ABSENT | `d0ffa6ae0dadd2ab3944967cfdc3b430ebc1a6b4b8600ac1254bccb279afd774` |
| `Sources/Services/DriverUninstaller.swift` | ABSENT | `915d72583971f8dbc26b7be695a2096cd92399f65281074dd1c5b5b7e68b5abe` |
| `tools/test_support/make_payload_fixture.sh` | ABSENT | `f415225ac1b04aa8c1eda58dc5cc45b369f8e88c38eb2842fca822f124007d85` |
| `docs/P4-Batch-1A-Source-Stabilization-Report.md` | ABSENT | 本文件（内容变更后哈希随之变化，不固化） |

---

## 10. 测试结果

### 10.1 实际执行的命令

所有输出保存在 `build/p4-batch1a/evidence/`。没有执行 `make release`、`make dmg`、
`make sign`，也没有执行任何安装/卸载流程。

| # | 命令 | 退出码 | 关键数字 | 证据文件 | 触碰 `dist/`？ |
|---|---|---|---|---|---|
| 1 | `make test` | **0** | Host **379 / 0 fail**；App **253 / 0 fail**；install transaction **168 passed**；codesign **58 checks / 0 fail** | `b1a-make-test.log` | 否 |
| 2 | `make test-dsp` | **0** | ctest `1/1` 通过；二进制实际执行 **33 个用例、33 个 ✓** | `b1a-test-dsp.log` | 否 |
| 3 | `make test-driver` | **0** | ctest `3/3` 通过（ControlProtocol / ProducerToken / MappingRetirement） | `b1a-test-driver.log`（本报告补充运行） | 否 |
| 4 | `./tools/test_release_payload.sh` | **0** | `passed: 244  failed: 0` | `b1a-test-release-payload.log` | 否（合成 fixture） |
| 5 | `make test-installer-gate PKG=build/p3-host-restart-dist/SoundBridge-1.2.0.pkg` | **0** | `installer gate assertions: 83 passed, 0 failed` | `b1a-test-installer-gate.log` | 否 |
| 6 | `make verify-installer-pkg PKG=…pkg` | **0** | `PASS`，38 条 `ok`；app 1.2.0 universal、driver 1.2.0 protocol 131584 universal | `b1a-verify-installer-pkg.log` | 否 |
| 7 | `./tools/test_installer_pkg_roundtrip.sh …pkg` | **0** | `round-trip assertions: 20 passed, 0 failed` | `b1a-test-installer-roundtrip.log` | 否 |
| 8 | `make verify-payload` | **0** | `OVERALL_RESULT=PASS`；PKG_STRUCTURE / DRIVER_CONSISTENCY / ARCHITECTURE / DMG_STRUCTURE / VERSION_CONSISTENCY / ARTIFACT_INTEGRITY 全 PASS，`DRIVER_FOUR_WAY=true` | `b1a-verify-payload.log` | 只读 |

### 10.2 关于 DSP 的 33 与 `0 passed, 0 failed`

任务书要求 RELEASE_NOTES 写「DSP 33 tests」。实际核对结果：

```
$ ./packages/dsp/build/tests/soundbridge_dsp_tests | grep -c 'Running: '   →  33
$ ./packages/dsp/build/tests/soundbridge_dsp_tests | grep -c '✓'          →  33
$ ./packages/dsp/build/tests/soundbridge_dsp_tests | tail -3
Results: 0 passed, 0 failed
```

即：**33 个用例确实全部执行并全部通过**，但测试框架的自报汇总行计数器打印 `0 passed, 0 failed`——
这正是 P2-1「DSP 测试计数器」缺陷，不是测试没跑。`ctest` 只看进程退出码，所以它报 `1/1 通过`。
本批次按 §8 要求**不修** P2-1，只在两处如实披露：本文 §10.2，以及 `RELEASE_NOTES.md` §6。

### 10.3 未执行的测试（以及为什么）

| 未执行 | 原因 | 是否影响本批次结论 |
|---|---|---|
| `make release` / `make dmg` / `make sign` | 任务书 §11 明确禁止；会重建 `dist/` | 否（本批次不重建产物） |
| 真实 PKG 安装 / 卸载 | 任务书 §3/§4/§10 禁止 | 是——见 §12 B-1/B-6 |
| `sudo` / `coreaudiod` 重启 / 默认输出切换 | 任务书 §10 禁止 | 否（本批次只改代码，不改系统） |
| `make test-installer`（事务单元测试） | 已由 #1 的 `make test` 覆盖（`transaction scenarios: 168 passed`） | 否 |
| 真实 EQ 听感 / underrun 测量 | 需要人耳与真实音频链，且属 Batch 2 | 是——见 §12 B-4/B-5 |

### 10.4 环境说明

`test_release_payload.sh`、`verify-payload`、`test_installer_pkg_roundtrip.sh` 都调用
`hdiutil`，只能在沙箱外运行（沙箱内 `hdiutil attach` 被拒）。它们只写 `mktemp -d` 临时目录
并在退出时清理，挂载点在测试前后做了卫生检查（`grep -cF "$FIX_DMG"`）。

---

## 11. Git 文件分组清单

### 11.0 口径与结论

统计口径：`git status --porcelain=v1` 的 **66 M + 1 D** 与 `git ls-files --others --exclude-standard`
的 **160** 个未跟踪文件，合计 **227** 个路径；另有 2 个不出现在 `git status` 里的文件
（本报告、被忽略的 Release Checklist），共 **229** 个条目被逐个归类。

| 组 | 含义 | 条目数 | 处理 |
|---|---|---|---|
| **A** | 1.2.0 必须提交的生产代码 | 55 | 提交 |
| **B** | 1.2.0 必须提交的测试 | 40 | 提交 |
| **C** | 1.2.0 必须提交的构建与工具脚本 | 12 | 提交 |
| **D** | 1.2.0 必须提交的文档 | 33 | 提交（其中 1 个被 `.gitignore` 阻断） |
| **E** | 历史研究或临时证据 | 89 | **不提交**（保留在工作区/本地归档） |
| **F** | 与本次发布无关的用户修改 | 0 | — |
| **G** | 无法确定归属，需用户确认 | 1 | 用户决定 |

**没有**把所有未跟踪文件归入 1.2.0：160 个未跟踪文件中有 **89 个被排除**（`.qoder/` 75 个 +
14 份历史批次报告/清单）。

### 11.1 A — 生产代码（55）

「来源」列：`本批次` = 本批次编写（§8 已列）；`P2–P3` = 批次开始时已在工作区，非本批次编写。
全部 A 类文件都必须提交，否则 App/Host/Driver 三者协议与生命周期不一致。

**App（21）**

| 文件（`apps/mac/SoundBridgeApp/Sources/`） | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `App/SoundBridgeApp.swift` | M | 依赖 `HostSupervisor`、`DriverInstaller` | App 仍走旧安装/退出路径，与已改组件不兼容 | 本批次 |
| `Models/HostLifecycleReport.swift` | M | 依赖 host `HostLifecycleReporter` | 状态栏无法反映 Host 生命周期 | P2–P3 |
| `Models/HostStatusModel.swift` | M | 依赖 `HostSupervisor` 状态机 | 菜单栏状态与真实状态不符 | P2–P3 |
| `Onboarding/OnboardingView.swift` | M | 依赖 `DriverInstallGuide`、`DriverInstaller` | 首装引导指向已被删除的安装实现 → 编译失败 | 本批次 |
| `Services/DriverInstaller.swift` | M | `DriverVersionGate`、`DriverBundleLocation` | 保留第二套特权安装事务 | 本批次 |
| `Services/DriverVersionGate.swift` | M | `RFSharedAudio.h` 协议常量 | 版本/协议门禁与驱动不一致 | P2–P3 |
| `Services/EQController.swift` | M | `EQService`、`SharedMemoryMappingManager` | EQ 写入者不唯一，`eq_sequence` 错乱 | P2–P3 |
| `Services/HostInstanceProbe.swift` | M | host 侧实例锁文件格式 | 探测结果与实际锁不同步 | P2–P3 |
| `Services/IPCController.swift` | M | `HostSupervisor`、共享内存头 | App↔Host 协议不一致 | P2–P3 |
| `Services/VolumeController.swift` | M | host `VolumePersistence` | 音量状态往返不一致 | P2–P3 |
| `Services/DefaultOutputSwitch.swift` | 新 | host `DefaultOutputHAL/Ownership` | 默认输出切换无所有权校验 | P2–P3 |
| `Services/DriverInstallGuide.swift` | 新 | `DriverBundleLocation` | Onboarding 无法定位 PKG | 本批次 |
| `Services/DriverUninstallPolicy.swift` | 新 | `DriverBundleLocation` | 卸载政策丢失，App 与脚本重新分岔 | 本批次 |
| `Services/DriverUninstaller.swift` | 新 | `DriverUninstallPolicy` | 卸载无实现（或被迫恢复旧实现） | 本批次 |
| `Services/EQService.swift` | 新 | `SharedMemoryMappingManager` | EQ 单一写者不成立 | P2–P3 |
| `Services/HostRestartEntry.swift` | 新 | `HostSupervisor` | 无法只重启 Host | P2–P3 |
| `Services/HostSupervisor.swift` | 新 | host 进程启动/退出 | Host 生命周期无主，退出会带走 App | P2–P3 |
| `Services/SharedMemoryMappingManager.swift` | 新 | host 映射代际 | 映射重复 unmap / 写者线程 unmap | P2–P3 |
| `Views/MenuBarView.swift` | M | `DriverUninstallPolicy`、`HostSupervisor` | 卸载回到 `killall` + 无校验 `rm -rf` | 本批次 |
| `Views/DriverUpdateWindow.swift` | **D** | — | 保留则编译失败（调用已删除 API） | 本批次 |
| `CSoundBridgeAudio/include/RFSharedAudio.h` | M | packages/shared 同名头 | 四处头副本不同步，协议偏移错 | P2–P3 |

**Driver（6）**

| 文件（`packages/driver/`） | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `Info.plist` | M | — | 协议号仍是 131328，App 门禁直接拒绝 | P2–P3 |
| `include/RFSharedAudio.h` | M | shared 头 | 协议布局与其它三份不一致 | P2–P3 |
| `src/Plugin.cpp` | M | `ControlProtocol.hpp`、`MappingRetirement.hpp` | 驱动侧控制协议/退役逻辑缺失 | P2–P3 |
| `src/ControlProtocol.hpp` | 新 | `RFSharedAudio.h` | `Plugin.cpp` 编译失败 | P2–P3 |
| `src/MappingRetirement.hpp` | 新 | 同上 | 同上 | P2–P3 |
| `src/ProducerToken.hpp` | 新 | 同上 | 同上 | P2–P3 |

**Host（27）**

| 文件（`packages/host/`） | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `Sources/CSoundBridgeAudio/include/RFSharedAudio.h` | M | shared 头 | 头副本不同步 | P2–P3 |
| `Sources/CSoundBridgeAudio/include/module.modulemap` | M | `RFRealtimeTelemetry.h` | Swift 侧看不到新 C 符号 | P2–P3 |
| `Sources/CSoundBridgeAudio/shim.c` | M | 同上 | 同上 | P2–P3 |
| `Sources/CSoundBridgeAudio/RFRealtimeTelemetry.c` | 新 | — | 链接失败（符号未定义） | P2–P3 |
| `Sources/CSoundBridgeAudio/include/RFRealtimeTelemetry.h` | 新 | — | 同上 | P2–P3 |
| `Sources/SoundBridgeHost/Audio/AudioEngine.swift` | M | `AudioRenderer` | 引擎与渲染器契约不符 | P2–P3 |
| `Sources/SoundBridgeHost/Audio/AudioRenderer.swift` | M | `RFRealtimeTelemetry` | 渲染回调内仍有锁/分配 | P2–P3 |
| `Sources/SoundBridgeHost/Constants.swift` | M | `RFSharedAudio.h` | 常量与协议头不一致 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/DeviceDiscovery.swift` | M | `DefaultOutputHAL` | 设备枚举与默认输出模型脱节 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/DeviceMonitor.swift` | M | `CoreAudioRestartDetector` | 无法感知 coreaudiod 重启 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/DeviceRegistry.swift` | M | `DefaultOutputOwnership` | 所有权模型缺失 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift` | M | 同上 | 代理设备与真实设备映射错误 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/SleepWakeMonitor.swift` | M | `CoreAudioRecovery` | 睡眠唤醒后不恢复 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/DefaultOutputHAL.swift` | 新 | — | 多个文件编译失败 | P2–P3 |
| `Sources/SoundBridgeHost/Devices/DefaultOutputOwnership.swift` | 新 | `DefaultOutputHAL` | 同上 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/DriverLifecycle.swift` | M | `SharedMemoryReportPolicy` | 驱动生命周期上报不一致 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift` | M | App `HostInstanceProbe` | 实例锁格式与探测不一致 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/HostLifecycleReporter.swift` | M | App `HostLifecycleReport` | 上报字段与 App 解析不一致 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/ShutdownSequence.swift` | M | `HostSupervisor` 的 shutdown 意图 | 卸载时 Host 退出顺序错 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/CoreAudioRecovery.swift` | 新 | `CoreAudioRestartDetector` | 编译失败 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/CoreAudioRestartDetector.swift` | 新 | — | 同上 | P2–P3 |
| `Sources/SoundBridgeHost/Lifecycle/SharedMemoryReportPolicy.swift` | 新 | — | 同上 | P2–P3 |
| `Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift` | M | `MappingRetirement.hpp` 语义 | 映射退役行为与驱动不一致 | P2–P3 |
| `Sources/SoundBridgeHost/Services/VolumePersistence.swift` | M | `AtomicFileWriter` | 音量写入可能截断 | P2–P3 |
| `Sources/SoundBridgeHost/Utilities/AtomicFileWriter.swift` | 新 | — | 编译失败 | P2–P3 |
| `Sources/SoundBridgeHost/Utilities/PathManager.swift` | M | 日志/App Support 路径约定 | 文档中的路径与实际不符 | P2–P3 |
| `Sources/SoundBridgeHost/main.swift` | M | 以上全部 | 启动序列与组件不匹配 | P2–P3 |

**Shared（1）**

| 文件 | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `packages/shared/include/RFSharedAudio.h` | M | — | 它是另外三份副本的源；不同步则四向一致性失败 | P2–P3 |

### 11.2 B — 测试（40）

所有 B 类文件都必须提交：它们锁定 A 类的不变量（尤其是 P1-1/P1-2 的「不能安装」与
「政策同源」）。缺任何一个都不会让产品坏掉，但会让不变量失去守卫。

**App 测试（15）**：`apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/`

| 文件 | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `DriverInstallBoundaryTests.swift` | M | 全部 App `Sources/`、`uninstall_driver.sh` | P1-1/P1-2 的核心不变量失去守卫 | 本批次 |
| `DriverCompatibilityNoticeTests.swift` | M | `DriverCompatibilityNotice` | 兼容性提示文案与政策脱节 | P2–P3 |
| `DriverInstallIntentTests.swift` | M | `DriverInstallBoundaryTests` 同域 | 安装意图可被重新引入 | P2–P3 |
| `DriverRecoveryMatrixTests.swift` | M | `DriverVersionGate` | 版本矩阵覆盖丢失 | P2–P3 |
| `DriverVersionGateTests.swift` | M | `DriverVersionGate` | 门禁语义回退 | P2–P3 |
| `HostInstanceProbeTests.swift` | M | `HostInstanceProbe` | 探测回归无人拦 | P2–P3 |
| `HostRunStateTests.swift` | M | `HostSupervisor` | 状态机回归无人拦 | P2–P3 |
| `DefaultOutputSwitchTests.swift` | 新 | `DefaultOutputSwitch` | 默认输出回归无人拦 | P2–P3 |
| `EQLifecycleOwnershipTests.swift` | 新 | `EQService` | EQ 单一写者不变量无人守 | P2–P3 |
| `EQRecoveryTests.swift` | 新 | `EQService` + 映射发布 | EQ 自动恢复回归无人拦 | P2–P3 |
| `HostRestartEntryTests.swift` | 新 | `HostRestartEntry` | 重启闸门可被绕过 | P2–P3 |
| `HostSupervisorTests.swift` | 新 | `HostSupervisor` | 并发/超时/退避回归无人拦 | P2–P3 |
| `SharedMemoryMappingManagerTests.swift` | 新 | `SharedMemoryMappingManager` | 租约/退役回归无人拦 | P2–P3 |
| `SharedMemoryMappingUnmapThreadTests.swift` | 新 | 同上 | 写者线程 unmap 可重现 | P2–P3 |
| `SharedMemoryMappingConcurrencyTests.swift` | 新 | 同上 | 并发租约回归无人拦 | P2–P3 |

**Host 测试（22）**：`packages/host/Tests/SoundBridgeHostTests/`

| 文件 | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `AtomicMemoryModelTests.swift` | M | 共享内存模型 | 模型回归无人拦 | P2–P3 |
| `DegradedLifecycleTests.swift` | M | HostSupervisor 降级语义 | 降级路径回归 | P2–P3 |
| `DriverHeartbeatCrossProcessTests.swift` | M | 心跳协议 | 跨进程心跳回归 | P2–P3 |
| `HostInstanceLockTests.swift` | M | `HostInstanceLock` | 锁语义回归 | P2–P3 |
| `SharedMemoryFileSystemTests.swift` | M | 映射文件布局 | 布局回归 | P2–P3 |
| `SharedMemoryMultiProcessTests.swift` | M | 多进程映射 | 并发回归 | P2–P3 |
| `SharedMemoryProtocolTests.swift` | M | `RFSharedAudio.h` | 协议回归 | P2–P3 |
| `SharedMemoryRecoveryTests.swift` | M | 恢复路径 | 恢复回归 | P2–P3 |
| `StartupFailureCleanupTests.swift` | M | 启动清理 | 泄漏回归 | P2–P3 |
| `VolumeStateTests.swift` | M | `VolumePersistence` | 音量状态回归 | P2–P3 |
| `AdmissionCrossProcessTests.swift` | 新 | `AdmissionGateway` | 准入跨进程回归 | P2–P3 |
| `AdmissionGatewayTests.swift` | 新 | 同上 | 准入回归 | P2–P3 |
| `AtomicFileWriterTests.swift` | 新 | `AtomicFileWriter` | 原子写回归 | P2–P3 |
| `AudioRendererRTSafetyTests.swift` | 新 | `AudioRenderer` | H-1–H-3 可能复发 | P2–P3 |
| `CoreAudioRestartRecoveryTests.swift` | 新 | `CoreAudioRecovery` | 恢复回归 | P2–P3 |
| `DefaultOutputGovernanceTests.swift` | 新 | `DefaultOutputOwnership` | 所有权回归 | P2–P3 |
| `DefaultOutputTrackingTests.swift` | 新 | `DefaultOutputHAL` | 跟踪回归 | P2–P3 |
| `GracefulShutdownTests.swift` | 新 | `ShutdownSequence` | 退出顺序回归 | P2–P3 |
| `LifecycleLoggingTests.swift` | 新 | `HostLifecycleReporter` | 上报字段回归 | P2–P3 |
| `MappingIncarnationTests.swift` | 新 | `MappingRetirement.hpp` | 代际回归 | P2–P3 |
| `RTObservabilityTests.swift` | 新 | `RFRealtimeTelemetry` | 观测回归 | P2–P3 |
| `RingBufferContractTests.swift` | 新 | 环形缓冲区契约 | 契约回归 | P2–P3 |

**Driver 测试（3）**：`packages/driver/tests/`

| 文件 | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `ControlProtocolTests.cpp` | 新 | `ControlProtocol.hpp` | 控制协议回归 | P2–P3 |
| `MappingRetirementTests.cpp` | 新 | `MappingRetirement.hpp` | 退役语义回归 | P2–P3 |
| `ProducerTokenTests.cpp` | 新 | `ProducerToken.hpp` | 写者令牌回归 | P2–P3 |

### 11.3 C — 构建与工具脚本（12）

| 文件 | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `Makefile` | M | 全部 `tools/` | `make test` 不含 `test-driver`；verifier 退化为从 `dist/` 取版本 | P2–P3 |
| `packages/driver/CMakeLists.txt` | M | `tests/*.cpp` | 驱动单元测试无构建目标 | P2–P3 |
| `tools/build_installer_pkg.sh` | M | host/driver 产物 | PKG 载荷与门禁描述与代码不一致 | P2–P3 |
| `tools/check_protocol_layout.sh` | M | `RFSharedAudio.h` | 协议偏移检查失效 | P2–P3 |
| `tools/test_release_payload.sh` | M | `test_support/make_payload_fixture.sh` | 发布测试重新依赖 `dist/` 历史产物 | 本批次 |
| `tools/test_support/make_payload_fixture.sh` | 新 | clang、`build_installer_pkg.sh`、`create_dmg.sh` | 上一条无法运行 | 本批次 |
| `tools/uninstall_driver.sh` | M | `DriverUninstallPolicy` 同源政策 | 脚本与 App 卸载政策重新分岔 | 本批次 |
| `tools/verify_dmg_contents.sh` | M | host `Info.plist` | 无法显式指定期望版本 | P2–P3 |
| `tools/verify_installer_pkg.sh` | M | PKG 产物 | 载荷/烘焙版本校验缺失 | P2–P3 |
| `tools/verify_pkg_contents.sh` | M | `--version` 参数 | 用陈旧 bundle 也能通过 | P2–P3 |
| `tools/verify_release_bundle.sh` | M | bundle 布局 | Sparkle/架构检查缺失 | P2–P3 |
| `tools/verify_release_payload.sh` | M | 其它三个 verifier | 四向一致性无法验证 | P2–P3 |

### 11.4 D — 文档（33）

| 文件 | 状态 | 依赖 | 不提交的风险 | 来源 |
|---|---|---|---|---|
| `README.md` | M | — | 用户仍然被指向 DMG 升级、菜单栏卸载、Sparkle | 本批次 |
| `docs/INSTALLATION_GUIDE.md` | 重写 | `docs/risks/` | 安装/卸载/排查无权威说明 | 本批次 |
| `docs/RELEASE_NOTES.md` | 重写 | `docs/1.2.0/`、`docs/verification/` | 发布说明与实现不符（131328、旧测试数） | 本批次 |
| `docs/risks/Known-Limitations.md` | M | 各 Batch 报告 | 风险状态无法审计；已关闭项无证据链 | 本批次 |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | M ⚠ | `docs/risks/` | **被 `.gitignore` 忽略，当前无法提交**（G-1） | 本批次 |
| `docs/P4-Batch-1A-Source-Stabilization-Report.md` | 新 | 全部 | 本批次无交付物 | 本批次 |
| `docs/README.md` | 新 | — | 文档入口缺失 | P2–P3 |
| `docs/Documentation-Migration-Manifest.md` | 新 | `docs/manifests/` | 文档迁移无法追溯（被 Known-Limitations 引用） | P2–P3 |
| `docs/P2-Batch-2-Default-Output-Governance-Report.md` | 新 | — | U-4 关闭证据链断裂 | P2–P3 |
| `docs/P2-Batch-3-EQ-Mapping-Reliability-Report.md` | 新 | — | P2-B3 关闭证据链断裂 | P2–P3 |
| `docs/P2-Batch-4-AudioRenderer-RT-Safety-Report.md` | 新 | — | P2-B4 关闭证据链断裂 | P2–P3 |
| `docs/P3-Final-Closure-Fix-Report.md` | 新 | — | Known-Limitations 引用失效 | P2–P3 |
| `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md` | 新 | — | P3-HR 的 REAL_MACOS 证据链断裂 | P2–P3 |
| `docs/P4-Release-Readiness-Audit-Report.md` | 新 | — | 本批次的问题来源不可追溯 | P2–P3 |
| `docs/architecture/SoundBridge-1.2.0-Architecture.md` | 新 | — | 架构文档缺失（checklist §7 引用） | P2–P3 |
| `docs/engineering/Admission-Ownership.md` | 新 | — | 机制文档缺失 | P2–P3 |
| `docs/engineering/Callback-Lifecycle.md` | 新 | — | L-2 的引用失效 | P2–P3 |
| `docs/engineering/CallbackGate-Memory-Model.md` | 新 | — | 机制文档缺失 | P2–P3 |
| `docs/engineering/Mapping-Retirement.md` | 新 | — | L-1 的引用失效 | P2–P3 |
| `docs/engineering/RingBuffer-Design.md` | 新 | — | 机制文档缺失 | P2–P3 |
| `docs/engineering/SharedMemory-Lifecycle.md` | 新 | — | 机制文档缺失 | P2–P3 |
| `docs/verification/Batch-0-1-Verification.md` | 新 | — | 验证证据链断裂 | P2–P3 |
| `docs/verification/Batch-2-Verification.md` | 新 | — | 同上 | P2–P3 |
| `docs/verification/Batch-2-Closure-Verification.md` | 新 | — | 同上 | P2–P3 |
| `docs/verification/Batch-3-Verification.md` | 新 | — | 同上 | P2–P3 |
| `docs/verification/Batch-3-Closure-Fix.md` | 新 | — | 同上 | P2–P3 |
| `docs/1.2.0/PHASE2_IMPLEMENTATION_PLAN.md` | 新 | — | RELEASE_NOTES §4 的证据索引失效 | P2–P3 |
| `docs/1.2.0/PHASE2_1_REPORT.md` | 新 | — | 同上 | P2–P3 |
| `docs/1.2.0/PHASE2_1_1_AND_2_1_2_REPORT.md` | 新 | — | 同上 | P2–P3 |
| `docs/1.2.0/PHASE2_1_3_RELEASE_READINESS_REPORT.md` | 新 | — | 同上 | P2–P3 |
| `docs/1.2.0/PHASE2_1_4_HOST_LIFECYCLE_REPORT.md` | 新 | — | 同上 | P2–P3 |
| `docs/1.2.0/PHASE2_1_5_FINAL_RELIABILITY_AUDIT.md` | 新 | — | 同上 | P2–P3 |
| `docs/1.2.0/POC_ERRATA.md` | 新 | — | 同上 | P2–P3 |

> `docs/1.2.0/` 与 `docs/verification/` 被 `RELEASE_NOTES.md` §4 与
> `Known-Limitations.md` 的关闭证据直接引用。不提交这两组目录，文档里的链接会全部指向
> 不存在的文件——这本身就是一个发布缺陷。

### 11.5 E — 历史研究 / 临时证据（89，**不提交**）

**E-1 `.qoder/`（75 个文件）**：IDE 生成的 repowiki（`knowledge/`、`content/`、`meta/`）。
与 1.2.0 无关；提交会带来大规模无意义 diff。建议在 Batch 1B 时加入 `.gitignore`（`.qoder/`）。

**E-2 历史批次报告与清单（14）**：

| 文件 | 理由 |
|---|---|
| `docs/P1-Product-Integration-Release-Readiness-Audit.md` | 已被 `docs/P4-Release-Readiness-Audit-Report.md` 取代 |
| `docs/P2-Batch1-Test-Infrastructure-Report.md` | 过程记录；结论已并入 Known-Limitations §5 |
| `docs/P3-0-Real-MacOS-Environment-Audit.md` | 环境快照，随机器变化过期 |
| `docs/P3-0-Workspace-Baseline.md` | 同上 |
| `docs/P3-Batch-1-Release-Build-Verification-Report.md` | 中间批次产物验证，已被 Batch 3 / P4 覆盖 |
| `docs/P3-Batch-1.5-Implementation-Report.md` | 中间批次过程记录 |
| `docs/P3-Batch-1.5-Mapping-Observability-Audit.md` | 同上 |
| `docs/P3-Batch-1.5-RT-Observability-Audit.md` | 同上 |
| `docs/P3-Batch-1.5-Release-Rebuild-Verification.md` | 同上 |
| `docs/P3-Final-Rebuild-Install-Host-Restart-Validation-Report.md` | 与 P3-Host-Restart 报告重叠，后者是权威版 |
| `docs/P3-Real-MacOS-Validation-Plan.md` | 计划文档，执行结果已在其它报告 |
| `docs/P3-Real-MacOS-Validation-Authorization-Matrix.md` | 过程授权记录 |
| `docs/Research-Directory-Retirement-Report.md` | 目录治理的临时记录 |
| `docs/manifests/Research-Directory-Inventory.sha256` | 同上，且是 `docs/Documentation-Migration-Manifest.md` 的输入 |

E 类不提交的后果是：这些文件只存在于本地工作区，任何重新克隆都会丢失。这是可接受的
（它们是过程记录），**但如果要保留可追溯性，应该在 Batch 1B 决定一个归档位置**，而不是
让它们永久以未跟踪状态漂在工作区。这个决定需要用户确认（见 §13 步骤 0）。

### 11.6 F — 与本次发布无关的用户修改（0）

逐个核对了 66 个 M 文件：每一个都能被 `docs/P2-*`、`docs/P3-*`、`docs/P4-*` 中的某项
工作解释。没有发现「无法归因到任何一个批次」的修改。

但需要说明限制：本批次**无法证明**这些改动的作者。如果用户知道其中某个文件包含自己的
实验性修改，请在提交前把它单独拿出来复核——那种文件应归 F 而不是 A/B/C。

### 11.7 G — 需要用户确认（1）

| 编号 | 对象 | 问题 | 建议 |
|---|---|---|---|
| **G-1** | `.gitignore` 第 120 行 `release/` | 它同时匹配 `docs/release/`，导致 `docs/release/SoundBridge-1.2.0-Release-Checklist.md`（任务书 §7 要求的交付物）**无法被提交**（只有 `git add -f` 能绕过，但那是掩盖问题） | 改为 `/release/`（只忽略仓库根目录的发布输出）。**需用户批准**：`.gitignore` 不在本批次授权修改范围内 |

---

## 12. 尚未解决的问题

### 12.1 发布阻断项（不变）

P4 Batch 0 列出的阻断项中，本批次只关闭了「源码中存在两套特权路径」与「文档描述另一个
版本」两类。以下仍然成立：

| 编号 | 内容 | 性质 | 对应登记 |
|---|---|---|---|
| B-1 | 真实安装 / 卸载 / 播放未验证 | 缺证据 | U-2、U-16 |
| B-2 | 真实设备移除（播放中拔 HDMI/DP）未验证 | 缺证据 | U-1 |
| B-3 | macOS 14.4 未认证 | 缺证据 | U-3 |
| **B-4** | **实际 EQ 听感未验证** | 缺证据 | U-14 |
| **B-5** | **播放窗口 underrun 未验证** | 缺证据 | U-15 |
| **B-6** | **真实卸载 → 重装闭环未验证** | 缺证据 | U-16 |
| B-7 | RT-1 – RT-5 未处理（真实负载下可能爆音/卡顿，不影响内存安全） | 已知缺陷 | Known-Limitations §3.1 |

B-4 / B-5 / B-6 是 1.2.0 最容易被含糊处理掉的三项。本批次所做的全部工作是**把它们写进**
证据链：RELEASE_NOTES §5（N-1/N-2/N-3）、Release Checklist §6（第 4/5/7 行）、
Known-Limitations（U-14/U-15/U-16）。**没有**任何一项被标成 PASS。

### 12.2 本批次新发现的问题

| 编号 | 内容 | 影响 | 建议 |
|---|---|---|---|
| **B-8** | `docs/release/` 被 `.gitignore` 忽略（= G-1） | 任务书 §7 的交付物无法进入提交 | Batch 1B 第一步修 `.gitignore` |
| **B-9** | `.qoder/` 未被 `.gitignore` 覆盖，产生 75 个未跟踪文件 | 每次 `git status` 都被噪声淹没，容易误 `add -A` | 加入 `.gitignore` |

### 12.3 P2/P3 低优先级项：是否影响 Release Gate

按 §8 要求，逐条只判断「是否影响当前 Gate」，不修：

| 编号 | 是否影响 Gate | 理由 |
|---|---|---|
| P2-1 DSP 测试计数器 | **否** | 33 个用例确实执行并全部通过（§10.2）；计数器只影响人读汇总行。已在 RELEASE_NOTES §6 与本文披露 |
| P2-2 构建目录隔离 | 否 | 只在「同一目录同时构建两个版本」时才会互相覆盖；本批次未执行这种构建 |
| P2-3 Host 缺失提示 | 部分 | 影响用户理解「为什么没声音」，但 §8.2 的排查步骤已覆盖该场景；不阻断安装 |
| P2-4 underrun 日志 | 否 | 与 B-5 同源，但 B-5 本身已列为阻断项，日志增强不能替代测量 |
| P2-5 安装期间 App/Host 运行状态 | 部分 | 安装器不检查运行状态；文档已改为「安装前先退出」（INSTALLATION_GUIDE §0）并引用 P2-5 |
| P3-2 旧协议注释 | 否 | 仅注释；`DriverVersionGate` 的行为由测试锁定 |

### 12.4 其他观察到的事实

- `README.md` 的 Makefile 目标表仍列出 `make clean`。它是**真实存在**的构建目标，不是
  发布步骤；Release Checklist 已删除该指令。如果希望完全不在文档中出现，可另开一个小改动。
- `INSTALLATION_GUIDE.md` §8.2.4 仍建议用户**在自己决定时**可执行
  `sudo killall coreaudiod`（首选注销/重启）。这是用户操作，不是产品行为；App 与安装器
  都不会执行它。

---

## 13. P4 Batch 1B 的具体执行计划

Batch 1B 的目标是「唯一 Commit + 干净重建」。前置条件是本报告的 G-1 被批准。

### 步骤 0：需要用户先确认的 3 件事

1. 批准把 `.gitignore` 的 `release/` 改为 `/release/`（否则 Release Checklist 无法提交）。
2. 决定 E 类 89 个文件的处置：保留本地 / 加进 `.gitignore` / 另存归档分支。
3. 确认 A/B/C/D 中没有自己的实验性修改（§11.6）。

### 步骤 1：修 `.gitignore`（唯一允许的额外改动）

```diff
- release/
+ /release/
+ .qoder/
```

验证：`git status --porcelain docs/release/` 应出现 `?? docs/release/`，且 `git status` 总量
不再包含 75 个 `.qoder/` 文件。

### 步骤 2：分组提交（不用 `git add -A`）

按 A→B→C→D 四组显式列出路径，每组一次 `git add`，最后一次 `git commit`（或四个 commit，
由用户决定；本报告推荐**单个 commit**，因为这是一次不可分割的收敛）。

```bash
# A 生产代码（55）
git add apps/mac/SoundBridgeApp/Sources packages/driver packages/host/Sources packages/shared/include
git add -u apps/mac/SoundBridgeApp/Sources/Views/DriverUpdateWindow.swift   # 记录删除

# B 测试（40）
git add apps/mac/SoundBridgeApp/Tests packages/host/Tests packages/driver/tests

# C 构建与工具（12）
git add Makefile packages/driver/CMakeLists.txt tools

# D 文档（33）
git add README.md docs
```

提交前必须做的三项核对：

```bash
 git diff --cached --name-only | wc -l          # 期望 140 左右（A+B+C+D）
 git diff --cached --name-only | grep -E '^\.qoder/|^dist/|^build/'   # 期望为空
 git diff --cached --name-only | grep 'P4-Batch-1A'                    # 期望命中本报告
```

### 步骤 3：提交后的状态核对

```bash
git status --porcelain=v1        # 期望只剩 E 类或完全干净
git show --stat HEAD | tail -3   # 期望 140+ files changed
```

### 步骤 4：干净重建（在新克隆中，不在本工作区）

```bash
git clone /path/to/SoundBridge /tmp/sb-1b-clean
cd /tmp/sb-1b-clean
git submodule update --init --recursive
make build && make test && make bundle && make sign && make verify
```

在克隆里做重建的理由：本工作区的 `dist/` 与 `build/` 保存着不可再生的候选件与历史产物，
任何 `make clean` 都会毁掉它们（这正是 Release Checklist §1 删除该指令的原因）。

### 步骤 5：重建后的候选件比对

把克隆里新产出的 `SoundBridge-1.2.0.pkg` 与现有 `dist/SoundBridge-1.2.0.pkg` 做载荷比对
（`pkgutil --expand` 后逐文件 `shasum`）。差异必须能被解释；不能解释的差异说明工作区里
有未提交的输入。

### 步骤 6：不在 Batch 1B 做的事

- 不打 tag、不 push、不改 VERSION/协议、不执行真实安装卸载。
- 不修 P2-1 – P2-5、P3-2、RT-1 – RT-5。
- 不把 B-4/B-5/B-6 标成已解决——它们需要 Batch 2 的真实环境执行。

---

## 14. 任务书 §13 五个问题的回答

### 1. P1-1、P1-2、P1-3、P1-5 是否全部解决？

**是，四项全部解决**，判定依据是可执行的证据而不是叙述：

| 项 | 判定依据 |
|---|---|
| P1-1 | App 内已无安装实现（`grep installDriver` 只命中注释）；全 App 仅剩 1 处提权命令；`DriverInstallBoundaryTests` 逐文件锁定；Onboarding 的成功态只来自 `DriverVersionGate` |
| P1-2 | `DriverUninstallPolicy` 同时被 App 与测试引用；脚本 `$DRIVER_PATH` 展开后与 App 命令**字节相等**；无 `killall`、无 `/tmp` 通配符、bundle id 校验、Host 先停、删除后确认 |
| P1-3 | `test_release_payload.sh` 中无 `1.1.1`/`131328` 字面量；`passed: 244 failed: 0`；`dist/` 中 1.1.1 产物保留且未被读取 |
| P1-5 | 两份文档按当前实现重写并通过事实核对（协议 131584、Host 379、App 253、Sparkle 未启用、ad-hoc 无公证）；README 三处矛盾逐条修正 |

### 2. 当前有哪些文件可以安全进入 1.2.0 提交？

**A（55）+ B（40）+ C（12）+ D（32，不含被忽略的 Checklist）= 139 个路径**，清单见 §11.1 – §11.4。
它们全部满足：可被某个批次报告解释、无 `.qoder/` 噪声、无 `dist/`/`build/` 产物、无
协议/版本/ABI 改动。

### 3. 哪些文件必须排除？

- **E-1**：`.qoder/` 的 75 个文件（IDE 生成）。
- **E-2**：14 份历史批次报告与清单（§11.5 有逐条理由）。
- 永远排除：`dist/`、`build/`、`*.pkg`、`*.dmg`、`*.app`、`*.log`（已在 `.gitignore` 中）。
- 例外：`docs/release/SoundBridge-1.2.0-Release-Checklist.md` 必须提交，但**当前被忽略**，
  需先修 `.gitignore`（G-1 / B-8）。

### 4. 是否可以进入 Git 分组提交阶段？

**可以，但有一个前置条件**：先批准并执行 `.gitignore` 修法（`release/` → `/release/`，
并加 `.qoder/`）。在此之前，§7 要求的一份交付物无法进入提交，所以“分组提交”会缺一块。

除该条件外，工作区已具备提交条件：测试全绿（§10）、文件已逐条归类（§11）、SHA-256 已留痕（§9）、
无未解释的修改（§11.6）。

### 5. 还有哪些发布阻断问题？

按严重程度：

| 序 | 阻断问题 | 能否在本仓库内解决 |
|---|---|---|
| 1 | **实际 EQ 听感未验证**（B-4 / U-14） | 否，需要真实音频设备与人耳/测量 |
| 2 | **播放窗口 underrun 未验证**（B-5 / U-15） | 否，需要真实负载基线 |
| 3 | **真实卸载 → 重装闭环未验证**（B-6 / U-16） | 否，需要授权执行一次真实卸载与重装 |
| 4 | 真实安装/播放、设备移除、macOS 14.4、x86_64 真机（B-1/B-2/B-3） | 否，需要 Batch 2 环境 |
| 5 | RT-1 – RT-5（B-7） | **能**，属工程修复，本批次未做 |
| 6 | `docs/release/` 被 `.gitignore` 忽略（B-8） | **能**，一行改动，但需用户批准 |

---

## 15. 本批次的边界声明

为免将本报告误读为“已可发布”，明确列出本批次**没有**做的事：

- 没有任何 Git 写操作（`add` / `commit` / `push` / `tag` / `reset` / `clean` / `checkout` /
  `restore` / `stash` 一次都没执行）。
- 没有执行 `sudo`、没有安装或卸载 Driver、没有重启 `coreaudiod`、没有切换默认输出设备。
- 没有修改 `VERSION`、Protocol、Bundle Version、Build Number、ABI，也没有改 HAL 安装位置。
- 没有重建、删除或覆盖 `dist/` 与 `build/` 中的任何文件（测试只在 `mktemp -d` 与
  `build/p4-batch1a/evidence/` 中写入）。
- 没有执行 `make clean`、`make release`、`make dmg`、`make sign`。
- 没有动 vendor submodule，没有全仓格式化。
- 没有开始 Batch 1B。

**结论：工作区现在是一个经过审查、可以（在修好 `.gitignore` 后）安全提交的 1.2.0
Release Candidate，但它还不是一次发布。**

