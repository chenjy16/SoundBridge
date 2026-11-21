# P4 Batch 0 — Release Readiness Audit & Executable Closure Plan

**仓库：** `/path/to/SoundBridge`
**批次：** SoundBridge 1.2.0 — P4 Batch 0（只读审计）
**审计日期：** 2026-11-21
**审计方式：** 只读。未修改任何源码、配置、版本、ABI；未构建、未安装、未卸载、未注册 Driver；未 `sudo`；未重启 `coreaudiod`；未改默认输出；未执行任何 Git 写操作（`add`/`commit`/`reset`/`clean`/`checkout`/`restore`/`stash` 全部未执行）。
**证据目录：** `build/p4-readiness-verify/evidence/`（本报告所有数字均可回溯到该目录下的原始日志）
**上一批次：** `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md`，结论 `PASS`

> **命名说明：** 本批次任务书引用的是 `docs/P3-Host-Restart-Entry-and-Real-Recovery-Validation-Report.md`。仓库内实际文件名为 `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md`（无 `-and-Real-`）。该引用差异本身见 P3-1。

---

## 0. 结论摘要

### 0.1 最终建议

# `NOT READY`

不是架构不合格，而是**用于发布的那份代码不存在于任何 Git 提交里**，且当前 `dist/` 里的 1.2.0 产物不是被验证过的那一份。

### 0.2 三个 P0（任一条都足以让"发布"这件事不成立）

| 编号 | 事实 | 证据等级 |
|---|---|---|
| **P0-1** | `HEAD = ab36770` 的代码树**不包含**本批次被验证的 App 架构。`HostSupervisor.swift`、`EQService.swift`、`SharedMemoryMappingManager.swift`、`DefaultOutputSwitch.swift`、`HostRestartEntry.swift` 全部是 **untracked**；HEAD 的协议是 `0x00020100`（131328），工作区/已安装产物是 `0x00020200`（131584）。即：**存在两个都叫 1.2.0 但 ABI 不同的产品，被验证的那个不在 Git 里。** | SOURCE_VERIFIED（`git ls-tree` / `git show`） |
| **P0-2** | `dist/` 中的 1.2.0 产物是**旧的**（App 主二进制 `4dabbb24…`，无 `Restart Host`），而 `verify_release_payload.sh --version 1.2.0` 对它返回 **`OVERALL_RESULT=PASS`**。即：**默认发布校验器对"不是候选件"的产物给出 PASS。** | RUNTIME_OBSERVED（`p4-verify-payload-default.log`，exit 0） |
| **P0-3** | 发布流水线强制要求的 `docs/INSTALLATION_GUIDE.md` 与 `docs/RELEASE_NOTES.md` 在工作区**被删除**（`git status` = ` D`），且其 HEAD 版本内容已过时（写的是 131328）。CI 的 `Stage Release Documents` 会直接 `exit 1`。 | SOURCE_VERIFIED + RUNTIME_OBSERVED（文件缺失实测） |

### 0.3 与正式发布的距离

- **架构/实现层面：** 已完成。Host 生命周期、Mapping 发布与 EQ 恢复、Host-only restart 都有真实 macOS 运行时证据（P3）。
- **工程交付层面：** 还剩 **1 个提交动作 + 1 次干净重建 + 2 份文档重写 + 1 次真实卸载/重装闭环**。
- **产品验证层面：** 从未有人在本机听过 SoundBridge 的 EQ 输出（默认输出不是 Proxy），也从未在有音频客户端时观察过 underrun。这两条决定了 1.2.0 只能以 **Pre-release** 名义发布。

---

## 1. 当前版本与 Git 基线

### 1.1 Git（本批次重新采集，未沿用历史数字）

| 项 | 值 |
|---|---|
| HEAD | `ab3677072f0dcb54de27ba4dcabfd11e64ae41ec` |
| branch | `main`（与 `origin/main` 同点） |
| `git status --porcelain` | **125** 条 |
| 其中 ` M`（已跟踪已修改） | **59** |
| 其中 `??`（未跟踪） | **64** |
| 其中 ` D`（已跟踪已删除） | **2** |
| staged（`git diff --cached`） | **0** |
| VERSION 文件 | `1.2.0` |
| 工作区写操作 | 本批次 **0** 次 |

原始记录：`p4-git-status.log`、`p4-modified-files.log`、`p4-baseline.log`。

### 1.2 HEAD 与工作区的实质差异（P0-1 的完整证据）

App 的 `Sources/Services/` 目录：

| HEAD（`ab36770`，提交信息 `release: SoundBridge 1.2.0`） | 工作区（已安装产物由它构建） |
|---|---|
| DriverCompatibilityNotice.swift | DriverCompatibilityNotice.swift |
| DriverInstaller.swift | DriverInstaller.swift |
| DriverVersionGate.swift | DriverVersionGate.swift |
| EQController.swift | EQController.swift |
| HostInstanceProbe.swift | HostInstanceProbe.swift |
| IPCController.swift | IPCController.swift |
| VersionManager.swift | VersionManager.swift |
| VolumeController.swift | VolumeController.swift |
| — | **DefaultOutputSwitch.swift**（untracked） |
| — | **EQService.swift**（untracked） |
| — | **HostRestartEntry.swift**（untracked） |
| — | **HostSupervisor.swift**（untracked） |
| — | **SharedMemoryMappingManager.swift**（untracked） |

App 测试目录：HEAD **9** 个文件，工作区 **17** 个（新增 `EQLifecycleOwnershipTests`、`EQRecoveryTests`、`HostRestartEntryTests`、`HostSupervisorTests`、`SharedMemoryMappingConcurrencyTests`、`SharedMemoryMappingManagerTests`、`SharedMemoryMappingUnmapThreadTests`、`DefaultOutputSwitchTests`）。

`git show HEAD:.../SoundBridgeApp.swift | grep -c HostSupervisor` → **0**。

协议：

| 来源 | HEAD | 工作区 |
|---|---|---|
| `packages/shared/include/RFSharedAudio.h` `RF_AUDIO_PROTOCOL_VERSION` | `0x00020100` | `0x00020200` |
| `packages/driver/Info.plist` `SBAudioProtocolVersion` | `131328` | `131584` |

原始记录：`p4-head-vs-worktree.log`。这与 `docs/P1-Product-Integration-Release-Readiness-Audit.md` 登记的 `P0-2`（"HEAD 的 1.2.0 与工作区的 1.2.0 是不同 ABI"）是同一件事，**至今未闭合**。

### 1.3 当前运行态（REAL_MACOS_VERIFIED，只读采集）

| 项 | 值 |
|---|---|
| App | `106`（ppid 1，RSS 44 MB，已运行 43 分钟） |
| Host | `10612`（ppid 106，RSS 15 MB，已运行 39 分钟） |
| `coreaudiod` | `598`（启动于 Nov 20 21:54:28，**全程未重启**） |
| Driver 插件进程 | `628` |
| Host lock | `pid=10612 session=22853F43-AB64-4E70-B579-DB8883ACECDA` |
| Mapping | inode `69959980` / `69959981`（自 15:33 restart 后未变） |
| 默认输出 | `109` / `1E6D4678-0000-0000-0424-0104C5462778` / `LG ULTRAGEAR+`（**不是 Proxy**） |
| DEVICE_COUNT | 7 |

---

## 2. A — 当前正式发布状态

### 2.1 版本与协议一致性（TEST_VERIFIED）

`tools/verify_version_consistency.sh --expect 1.2.0` → `VERSION_SOURCES_CHECKED=11`，`VERSION_SOURCES_FAILED=0`，`VERSION_CONSISTENCY=PASS`。
`tools/check_protocol_layout.sh` → exit 0，`0x00020200`，header 320 B，`admission_state@256` / `admission_epoch@264` / `producer_owner_token@272`，Driver plist `SBAudioProtocolVersion=131584`。

⚠️ 这两个校验器都只看**源码树**；它们对 "HEAD 是 131328、工作区是 131584" 这件事完全不敏感（见 §2.4）。

原始记录：`p4-version-consistency.log`、`p4-protocol-check.log`。

### 2.2 已安装产物（REAL_MACOS_VERIFIED）

| 项 | 值 | 判定 |
|---|---|---|
| App 文件数 | 109 | 与 P3 构建产物一致 |
| `SoundBridgeApp` | `07030fa8d5ebddda9dc5280cecdcc94a0c3d323418ed43ee1389c4f9c5642c8d` | 由工作区构建 |
| `SoundBridgeHost` | `d8d1249627cd26bf986a365d1570d7cac433a4d5888002c039ec52d357642aae` | 与 1.1.1 时期逐字节相同 |
| HAL `SoundBridgeDriver` | `c295503019a0712649030c16a7f583569dea6e96d8a10ae6ec3d57af2f3e24a0` | 同上 |
| App 版本 / build | `1.2.0` / `1.2.0` | OK |
| `CFBundleIdentifier` | `com.soundbridge.menubar` | OK |
| `LSMinimumSystemVersion` | `13.0` | OK |
| App / Host / Driver 架构 | `x86_64 arm64` ×3 | universal |
| Driver 版本 / id / 协议 | `1.2.0` / `com.soundbridge.driver` / `131584` | OK |
| `codesign --verify --deep --strict`（App） | `valid on disk` + `satisfies its Designated Requirement` | OK |
| `codesign --verify --strict`（Driver） | 同上 | OK |
| 签名形态 | `Signature=adhoc`、`flags=0x2(adhoc)`、`TeamIdentifier=not set` | 与发布策略一致 |

原始记录：`p4-signing-arch.log`。

### 2.3 Gatekeeper（RUNTIME_OBSERVED，本批次新证据）

```
$ spctl -a -vvv -t exec /Applications/SoundBridge.app
/Applications/SoundBridge.app: rejected
```

ad-hoc 签名的必然结果，与 `RELEASE_NOTES.md` §7.1 的描述一致（"`spctl` 会拒绝该 App，这是 ad-hoc 签名的正常结果"）。**不把 Developer ID / 公证列为阻塞项**（任务书 §F 明确）。但它决定了：从 DMG 双击安装的用户**必然**遇到一次系统拦截，因此放行路径的文档正确性是发布条件（见 P1-5）。

### 2.4 产物清单与候选件歧义（P0-2 的证据）

| 产物 | SHA-256 | 大小 | mtime | App 主二进制 |
|---|---|---|---|---|
| `dist/SoundBridge-1.2.0.pkg` | `8483c20bbf1df9e6791789222e36d36063f2dc0f41c200656474537e7d655655` | 14,292,147 B | 11-21 13:21:26 | 内含 `4dabbb24…` |
| `dist/SoundBridge-1.2.0.dmg` | `1b6b43f27b2377909d0f1505da408bf5c744cdd36aa0e8bc86b3df81ea3e992b` | 15,025,230 B | 11-21 13:23:39 | 同上 |
| `dist/SoundBridge.app` | — | — | — | `4dabbb240cf8e7834792ffdd80581df824aac4e586a91c5d5fa44d1d9027c7b7` |
| `build/p3-host-restart-dist/SoundBridge-1.2.0.pkg` | `132bb64db94915e6b43a6fd3bd43b4ba9bb43105d511e07511fef8efdec5f032` | 14,362,174 B | 11-21 15:24:51 | `07030fa8…` |
| `build/p3-host-restart-dist/SoundBridge-1.2.0.dmg` | `bf097bb05bffeebed4306db49876640667f6d8bd878c617fdc697129e6dfd947` | 15,212,979 B | 11-21 15:25:01 | `07030fa8…` |
| `/Applications/SoundBridge.app` | — | — | 11-21 15:29:13 | `07030fa8…` |

`dist/` 里同时存在 **1.1.1**（Nov 17）与 **1.2.0**（Nov 21 13:2x）两代产物；**只有 `build/p3-host-restart-dist/` 与已安装产物一致**。

而默认校验路径读的是 `dist/`：

```
$ ./tools/verify_release_payload.sh --version 1.2.0
...
  SoundBridge-1.2.0.pkg  sha256: 8483c20b…   size: 14292147
  SoundBridge-1.2.0.dmg  sha256: 1b6b43f2…   size: 15025230
Summary
  PKG_STRUCTURE=PASS  DRIVER_CONSISTENCY=PASS  DRIVER_FOUR_WAY=true
  ARCHITECTURE=PASS   DMG_STRUCTURE=PASS       VERSION_CONSISTENCY=PASS
  ARTIFACT_INTEGRITY=PASS
OVERALL_RESULT=PASS
```

**判定：** 校验器本身没有 bug —— 它校验的那套产物确实自洽（pkg/dmg/bundle 三向一致，版本都是 1.2.0）。问题在于**"自洽"不等于"是候选件"**：`4dabbb24…` 是不含 `Restart Host`、不含 P3 验证路径的旧 App。P3 批次之所以正确，是因为它显式传了 `--pkg/--dmg/--app` 指向 `build/p3-host-restart-dist/`；而 `make verify-payload` 的默认路径会拿到旧的那套并给 PASS。

**1.1.1 污染是否已修复：** 部分修复。Makefile 与三个 verifier 已改为"由 `VERSION` 文件选文件，而不是由 `dist/` 里的 bundle 或文件 mtime 选"（`verify_pkg_contents.sh:68-79`、`verify_dmg_contents.sh:179-208`、`verify_release_payload.sh:37-42`），所以跨版本误选已消除。**同版本过期**这一半没有防住 —— 而这正是本批次的实际状态。

---

## 3. B — 安装与卸载审计

### 3.1 存在四条互不相同的安装/卸载路径

| # | 入口 | 实现 | 事务性 | coreaudiod |
|---|---|---|---|---|
| 1 | **PKG**（`SoundBridge-1.2.0.pkg`） | `preinstall` 门禁 + `postinstall` → `tools/sb_install_transaction.sh` | **是**（PRECHECK→STAGING→VALIDATING→BACKUP_OLD→REPLACING→VERIFYING，失败 ROLLBACK） | **不重启**（脚本明示 "never restarts"） |
| 2 | **App 内 Onboarding 首次安装** | `DriverInstaller.installDriverWithPrivileges` | **否**：一条 `do shell script` 里 `rm -rf` + `cp -R` + `chown` + `chmod` + `mv` + `killall coreaudiod` | **重启** |
| 3 | **App 内 "Uninstall Driver" 菜单** | `MenuBarView.performUninstall` | **否**：`killall SoundBridgeHost` + `rm -rf` HAL 目录 + `rm -f /tmp/soundbridge-*` + `killall coreaudiod` | **重启** |
| 4 | `tools/uninstall_driver.sh` | 校验 bundle id、拒绝 symlink、只删固定路径、打印建议 | 不适用（只删） | **明确不重启**，并解释原因 |
| （旁） | `packages/driver/install.sh` / `uninstall.sh` | `sudo cp -R` / `sudo rm -rf`，无身份校验 | 否 | 打印 `sudo killall coreaudiod` 建议 |

任务书要求核实的差异**成立，而且比预期更严重**：不是"App 内卸载 vs 脚本"两处不一致，而是**三种 coreaudiod 政策并存**。

### 3.2 App 内卸载路径的确切事实（SOURCE_VERIFIED）

`apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift:501-514`：

```swift
let script = """
do shell script "killall SoundBridgeHost 2>/dev/null || true; \
rm -rf /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver || true; \
rm -f /tmp/soundbridge-devices.txt 2>/dev/null || true; \
rm -f /tmp/soundbridge-* 2>/dev/null || true; \
killall coreaudiod 2>/dev/null || true" with administrator privileges
"""
```

事实清单：

1. **`killall coreaudiod` 存在**（第 513 行），在同一特权命令里执行，用户没有任何机会拒绝。这会让**所有**正在播放的 App 断音 —— 本机 HAL 目录里还有 `BlackHole16ch.driver`、`ParrotAudioPlugin.driver`、`eqMac.driver`，它们的用户也会被波及。
2. **不做 bundle 身份校验**：`rm -rf` 直接作用于固定路径，不读 `CFBundleIdentifier`。若该路径被替换成别的 bundle，仍会被删除。`tools/uninstall_driver.sh` 恰好有这层校验（"a directory called SoundBridgeDriver.driver that is not com.soundbridge.driver is not ours to delete"）。
3. **不经过事务**：没有 backup、没有回滚、没有 verify。
4. **`rm -f /tmp/soundbridge-*` 是通配删除**，会跨用户删除 `/tmp/soundbridge-<uid>-*`。
5. **清理范围与提示不一致**：alert 文案写 "clear configuration data"，实际删除 `~/Library/Application Support/SoundBridge/`（`device-state.json`、`volume-state.json`）、`~/Library/Logs/SoundBridge` 与 4 个 UserDefaults key（`hasCompletedOnboarding`、`onboardingVersion`、`driverInstallDate`、`lastDriverVersionCheck`），**但保留** `eq_default_bass_db / mids_db / treble_db / enabled`。即：卸载后重装会恢复旧 EQ，而引导状态被清空 —— 两套语义混在一次操作里。
6. 顺序上是安全的：`prepareForUninstall()` 先置 `isUninstalling` 并 `hostSupervisor.shutdown(intent: .uninstall)`，之后才 `killall SoundBridgeHost`，不会触发 supervisor 的 relaunch（`isShutdown` 闸门 + `HostRestartEntry` 拒绝）。

对照 `tools/uninstall_driver.sh`（142 行，文件头注释即政策声明）：

> "It does not stop coreaudiod and it does not restart it. The previous version ended with `killall coreaudiod` inside the same privileged command, so every uninstall cut audio for every running application… Killing a system daemon is not part of removing a driver."

**结论：脚本声明的政策没有落实到 App 内入口，而 README 又把 App 内入口写成了官方卸载方式**（见 §7.1）。这是 P1-2。

### 3.3 安装事务的成熟度（TEST_VERIFIED）

`make test-installer` → **36 个场景 / 168 条断言全通过**，含：

- 35：失败安装必须回滚并返回 2，且不写 SUCCESS 行、不留下"声称成功"的状态记录、旧驱动仍是 1.1.1；
- 36：回滚失败必须单独报告（exit 3）、记录失败类别、不删除任何自己没创建的文件；
- 34：进程不会释放不属于自己的锁；
- 29–33：锁初始化竞态、`2^63` 版本段回绕、pid 写不进去不开工。

`tools/verify_installer_pkg.sh`（42 项）+ `tools/test_installer_preinstall.sh`（83 条门禁断言）+ `tools/test_installer_pkg_roundtrip.sh` 在 CI 中全部执行。PKG 内 postinstall 被断言**不含** `killall|launchctl`（`verify_installer_pkg.sh:412`）。

**安装事务（路径 1）是本次审计中唯一"看起来可以交付"的组件。**

### 3.4 安装失败后的恢复（TEST_VERIFIED，非 REAL_MACOS_VERIFIED）

- 事务在 `REPLACING` 之前只读目标盘，拒绝不会损坏已装驱动（`sb_install_transaction.sh:37-40`）。
- `REPLACING` 是两次 `rename(2)`，失败进入 `ROLLBACK`；`ROLLBACK_FAILED` 单独编码（exit 3）。
- `--mode recover` 可在断电/中断后重跑，`--mode install` 总是先 recover。
- **未做**：真机中断安装、真实断电、真实回滚。属 U 类缺口，不是缺陷。

### 3.5 重复安装 / 同版本重装（REAL_MACOS_VERIFIED）

P3 批次在真实机器上执行过 `installer -pkg` 同版本重装：preinstall 输出 `reinstall: 1.2.0 is already installed; replacing it with a fresh copy (same version)`，事务日志完整走 INIT→LOCK→RECOVER→PRECHECK→VALIDATING→BACKUP_OLD→REPLACING×2→VERIFYING→SUCCESS，安装后 109 文件与构建产物 IDENTICAL，`UserDefaults` 与 `Application Support` 保留。

### 3.6 用户数据保留（REAL_MACOS_VERIFIED）

安装前后：`~/Library/Application Support/SoundBridge/{device-state.json, volume-state.json}` 保留；`com.soundbridge.menubar` 的 8 个键（含 4 个 `eq_default_*`）全部保留。

### 3.7 卸载后的残留（RUNTIME_OBSERVED 基线，真实卸载 NOT VERIFIED）

当前机器上的残留基线（`p4-uninstall-residue-baseline.log`）：

| 位置 | 内容 | 现有卸载路径是否清理 |
|---|---|---|
| `/Library/Application Support/SoundBridge/InstallerState/log` | 事务日志（root:wheel） | ❌ 两条路径都不清理（引导文档列为"可选清理"） |
| `~/Library/Application Support/SoundBridge/` | `device-state.json`、`volume-state.json` | App 内卸载 ✅ / 脚本 ❌ |
| `~/Library/Logs/SoundBridge` | 日志 | App 内卸载 ✅ / 脚本 ❌ |
| UserDefaults `eq_default_*` | EQ 持久化 | ❌ 都不清理 |
| `/tmp/com.soundbridge.host-global.lock` | 0 字节 flock 文件 | ❌ 都不清理（`rm /tmp/soundbridge-*` 前缀不匹配） |
| `/tmp/soundbridge-501-*`、`soundbridge-devices.txt`、`soundbridge-driver-debug.log`、`soundbridge-*.lock` | 运行时文件 | App 内卸载 ✅ / 脚本 ❌ |
| LaunchAgent / LaunchDaemon | **不存在** | 无残留（App 未注册登录项） |

`com.soundbridge.host-global.lock` 是 flock 文件、内容无意义，残留不影响下次启动（P3-3，仅整洁性问题）。**真正的 U 类缺口是"卸载后重新安装能否恢复"从未真实执行过**（P1-4 的验证部分）。

---

## 4. C — 升级路径（1.2.x）

### 4.1 门禁语义（SOURCE_VERIFIED + TEST_VERIFIED）

`preinstall`（构建期烘焙 `EXPECTED_VERSION` / `EXPECTED_PROTOCOL`）：

| 已装状态 | 行为 |
|---|---|
| 无驱动 | `this is a first install` → 放行 |
| 无 `Contents/Info.plist` | refuse |
| `CFBundleIdentifier` 读不出 / 不匹配 | refuse |
| `CFBundleShortVersionString` 读不出 / 不可解析 | refuse |
| 已装协议 **>** 包协议 | refuse（"a package never downgrades the wire format"） |
| 已装协议 **<** 包协议 | 放行（"the version comparison does not apply"） |
| 协议相同、版本更旧 | 放行（upgrade） |
| 协议相同、版本相同 | 放行（reinstall） |
| 协议相同、版本更新 | refuse（no downgrade） |

版本段限 9 位，防 bash 64 位回绕（`MAX_COMPARE_DIGITS=9`，与事务脚本同规则）。所有 refuse 都打印 "nothing was written"。

对 **1.2.0 → 1.2.1（协议不变）**：走"版本更旧 → upgrade"，语义正确。
对 **1.2.0 → 1.2.x（协议提升）**：走"协议更旧 → 放行，跳过版本比较"，语义也正确（协议优先于版本）。

### 4.2 已验证 / 未验证

| 行为 | 状态 | 证据 |
|---|---|---|
| 1.2.0 → 1.2.0 同版本重装 | **REAL_MACOS_VERIFIED** | P3 真实 `installer -pkg` + 事务日志 |
| 1.1.2 → 1.2.0 门禁判定（无协议键仅比版本） | **TEST_VERIFIED** | `test_installer_preinstall.sh`（展开 PKG、临时根） |
| 降级拒绝 / 协议降级拒绝 | **TEST_VERIFIED** | 同上 |
| 安装失败回滚 | **TEST_VERIFIED** | 事务场景 35/36 |
| 1.2.0 → 1.2.1 真实升级 | **NOT_VERIFIED** | 不存在 1.2.1 产物 |
| 卸载 → 重装的完整恢复 | **NOT_VERIFIED** | 从未真实执行卸载 |
| 升级过程中的 Host 重启行为 | **NOT_VERIFIED**（有间接证据） | 安装前退出 App → 下次启动新 Host 发布新 mapping（P3 观察到） |
| App 自更新 | **NOT_VERIFIED / 不可用** | `SUPublicEDKey` 为空 → Sparkle 不初始化；链接是 `releases/latest/download/appcast.xml`，仓库内无 `appcast.xml` |

### 4.3 一个未被覆盖的升级风险（P2-5）

`preinstall` 与事务脚本**都不检查 App / Host 是否正在运行**。在 App 运行时执行 `installer -pkg` 会发生：App bundle 被替换（进程仍跑旧代码）→ Host 作为子进程继续存活 → 用户下次启动新 App 时，supervisor 的 lock probe 看到旧 Host 仍持锁 → 状态 `notOwned` / `instanceConflict`（"Another SoundBridge host is already running"）。

协议不变时后果轻微（旧 Host 写旧映射，新 App 重连后可继续）；**协议提升时**则是"新 App + 旧 Host"，也正是 1.2.0 自身从 131328 跳到 131584 的场景。当前**没有任何文档要求安装前退出 App**。属未验证 + 未文档化，不是已确认故障。

---

## 5. D — 发布测试与测试脚本

### 5.1 `make test` 的实际构成

```
test: protocol-check version-check test-dsp test-driver test-host test-app test-installer test-codesign
        @echo "✓ All test suites passed"
```

P3 批次实测（`make test` exit 0）：

| 套件 | 结果 | 计数来源 |
|---|---|---|
| `protocol-check` | PASS | 4 份头文件一致 + 布局断言 |
| `version-check` | PASS | 11 个版本源 |
| `test-dsp` | Passed | **ctest 1 个用例**（内部 33 个测试函数） |
| `test-driver` | Passed | ctest **3 个用例**（control protocol / producer token / mapping retirement），scratch 目录 |
| `test-host` | Passed | **379 tests, 0 failures** |
| `test-app` | Passed | **253 tests, 0 failures**（含 9 个 `HostRestartEntryTests`） |
| `test-installer` | Passed | **36 场景 / 168 断言** |
| `test-codesign` | Passed | **58 checks, 0 failures** |
| — | — | ASan 25/25、TSan 25/25（P3 单独执行，exit 0） |

**不在 `make test` 里的**：`test-installer-gate`、`verify-*`、`test-release-payload`。CI 会单独跑它们，本地 `make test` 全绿不等于 CI 会绿。

### 5.2 历史问题逐条核实

#### （1）DSP 摘要 "0 passed / 0 failed" —— **仍然存在**（P2-1，本批次亲自复现）

```
$ ./packages/dsp/build/tests/soundbridge_dsp_tests
========================================
Running SoundBridge DSP Test Suite
========================================

Found 33 tests
Running: preset_init_flat... ✓
…（33 行全部 ✓）…
========================================
Results: 0 passed, 0 failed
========================================
exit 0
```

根因（`packages/dsp/tests/test_utils.h:78-106`）：

```c
#define PASS() g_test_stats.passed++          // 定义了，但全仓没有任何调用
…
for (const auto& [name, func] : tests) {
    int failed_before = g_test_stats.failed;
    func();
    if (g_test_stats.failed == failed_before) std::cout << " ✓";   // 只判断失败未增加
    else                                     std::cout << " ✗";
}
std::cout << "Results: " << g_test_stats.passed << " passed, "
          << g_test_stats.failed << " failed\n";
```

- `passed` 永远为 0（没有任何测试调用 `PASS()`）；
- 失败**能**被捕获（`ASSERT*` 递增 `failed` 并 `return`，`run_all_tests` 返回 1）；
- 但 `ctest` 在成功时**不显示**被测程序 stdout，所以 `make test` 里只能看到 `1/1 Test Passed` —— 一个"1"既不代表 1 个测试，也不代表 33 个断言。

**这是"计数不准确"，不是"测试无效"。** 修法很小（在每个测试函数末尾调 `PASS()`，或把逐条 `✓` 改成累加），但本批次只读，不修。

#### （2）`test_release_payload.sh` 被 1.1.1 污染 —— **仍然存在，且是硬编码依赖**（P1-3）

`tools/test_release_payload.sh:74-81`：

```bash
REAL_PKG="$ROOT/dist/SoundBridge-1.1.1.pkg"
REAL_DMG="$ROOT/dist/SoundBridge-1.1.1.dmg"
REAL_APP="$ROOT/dist/SoundBridge.app"
FIXTURE_VERSION="1.1.1"
```

这个"验证器自检"脚本把 **1.1.1 的产物**当作真实素材，在 scratch 树里逐项破坏以证明 verifier 会报错。后果：

- 一旦清理 `dist/` 里的 1.1.1（发布前的正常清理），`make test-release-payload` 直接失败；
- 即使不失败，它证明的是"verifier 能识别 1.1.1 产物的损坏"，而不是"能识别 1.2.0 候选件的损坏"；
- 它和任务书 §3-A "不得将历史 1.1.1 产物误认为正式发布候选" 的要求方向相反 —— 脚本把 1.1.1 变成了测试的**必需依赖**。

#### （3）测试能否独立指定构建输出目录 —— **部分不能**（P2-2）

| 目标 | 输出位置 | 可否覆盖 |
|---|---|---|
| `test-driver` | `mktemp -d`（并打印 scratch 路径） | ✅ 天然隔离 |
| `test-dsp` | `packages/dsp/build`（固定） | ❌ |
| `test-host` | `packages/host/.build`（`swift test` 默认） | ❌ 无 `--scratch-path` 参数 |
| `test-app` | `apps/mac/SoundBridgeApp/.build`（固定） | ❌ |
| `test-installer-gate` | 无 | ❌ 默认 `ls -1t build/*/*.pkg \| head -1` |
| `verify-installer-pkg` | 无 | ❌ 同上 |

`build/` 下当前有 **12 个 pkg**（`p3-host-restart-dist`、`p3-final-dist`、`p16-dist`、`p15b-dist`、`p15-dist`、`p3-dist`、`phase6a…`）。默认"最新那个"今天是正确的，但它由 mtime 决定，跨批次不可复现。

#### （4）`DriverVersionGate.swift` 的过时 Protocol 示例 —— **存在，仅注释**（P3-2）

`DriverVersionGate.swift:342`：

```swift
/// Format a protocol version for logs and UI, e.g. `0x00020100`.
static func hex(_ value: UInt32) -> String { String(format: "0x%08X", value) }
```

当前协议是 `0x00020200`。代码本身没有漂移：`expectedProtocolVersion` 直接取 `RF_AUDIO_PROTOCOL_VERSION`（`:216-218`），运行时为 131584。全仓搜索 `0x00020100|131328` 只余此一处孤立示例（`RFSharedAudio.h` 中的出现是历史叙述 "Bumped to 0x00020100 … Bumped to 0x00020200"，上下文正确）。

---

## 6. E — 日志与用户体验

### 6.1 已有的用户可见状态（SOURCE_VERIFIED + 部分 REAL_MACOS_VERIFIED）

`HostRunState.shortMessage`（`Models/HostLifecycleReport.swift:134-167`）给出 15 种一句话状态，其中与发布直接相关的：

| 状态 | 文案 | 用户能否据此判断"设备是否工作" |
|---|---|---|
| `.ready(flowing: true)` | `Connected` | 能 |
| `.ready(flowing: false)` | `Routed — no audio playing` | **能** —— 明确区分"已路由但没在播" |
| `.waitingForDriver` | `Waiting for audio driver` | 能 |
| `.recovering` | `Reconnecting to the audio driver…` | 能（HDMI 重连路径） |
| `.proxyUnavailable` | `SoundBridge device is not available` | 能 |
| `.driverNotResponding` | `Audio driver stopped responding` | 能 |
| `.instanceConflict` | `Another SoundBridge host is already running` | 能（正是 §4.3 的升级风险会命中的文案） |

`isProblem` 只把 `notRunning / proxyUnavailable / sharedMemoryInvalid / driverNotResponding / instanceConflict / degraded` 归为问题；`waitingForDriver` 明确排除（"正常状态，弹窗是噪音"）。这个分级是合理的。

### 6.2 缺口

| # | 缺口 | 影响 | 等级 |
|---|---|---|---|
| **E-1** | Host 二进制缺失时的弹窗文案是开发者指令：`"SoundBridge Host Not Found" / "Please build the host first:\ncd packages/host && swift build -c release"`（`SoundBridgeApp.swift:676-680`） | 正式包里不该出现，但一旦出现就是把终端命令甩给用户 —— 与 Phase 2.1.4 已清除的 `cd packages/driver && ./install.sh` 同类 | **P2-3** |
| **E-2** | `Buffer underrun` 日志无法区分静音态与播放态：`logger.warning("⚠️ Buffer underrun: +\(d) (total: \(n)) [\(uid)]")`（`SharedMemoryManager.swift:699`），每 5 秒汇总一次，**不含客户端连接状态** | P3 实测在**没有任何音频客户端**时也报 `+362 (total: 362)`；支持/用户会把静音态 underflow 误读为故障；也无法用它判断"播放窗口 underrun" | **P2-4** |
| **E-3** | EQ 写入失败只写日志，界面无提示：`logger.notice("EQ write skipped: no active mapping")`（`EQController.swift:471`） | 用户看到正常 UI，但 EQ 未生效；无映射时静默 | **P3-4** |
| **E-4** | 卸载提示与实际清理范围不一致（"clear configuration data" 但保留 `eq_default_*`） | 卸载语义不可预期 | 并入 **P1-2** |
| **E-5** | Driver 兼容性说明质量良好：给出已装版本、期望版本、协议十六进制、发布页地址，并明确 "will not replace the system driver in the background"，无安装按钮 | 无缺口 | — |
| **E-6** | 安装/权限/Gatekeeper：App 侧无自述；依赖文档（见 §7） | 文档正确性成为发布条件 | **P1-5** |

---

## 7. F — 用户文档与发布渠道

### 7.1 文档现状

| 文档 | 存在性 | 状态 |
|---|---|---|
| `docs/INSTALLATION_GUIDE.md` | **工作区已删除**（HEAD 有，271 行） | 见 P0-3；内容质量本身较高 |
| `docs/RELEASE_NOTES.md` | **工作区已删除**（HEAD 有，198 行） | 见 P0-3；内容**已过时** |
| `README.md` | 存在（309 行） | 有 3 处与实现矛盾 |
| `CHANGELOG.md` | **不存在**（`make changelog` 目标存在，`generate_changelog.sh` 存在） | P3-5 |
| `docs/risks/Known-Limitations.md` | 存在（238 行，11-20 15:07） | 风险登记表**未随 P2/P3 更新** |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | 存在（11-20 15:05） | 状态停留在 "Batch 3 Closure Fix `CONDITIONAL PASS`"；B-1…B-5 全部仍标注未解决 |
| `docs/verification/` | 5 份 | 只到 Batch 3 |
| `SHA256SUMS.txt` / `appcast.xml` | 仓库内无 | 由 CI 生成；`SUPublicEDKey` 为空 → 自动更新禁用 |

### 7.2 `RELEASE_NOTES.md`（HEAD 版）的具体过时项（P1-5）

| 位置 | 文中说的 | 实际 |
|---|---|---|
| §2、§5、§6 | 1.2.0 协议 = `0x00020100`（131328） | **`0x00020200`（131584）** |
| §2 | 1.1.2 协议 = `0x00020000` | 一致（仅历史参考） |
| §3.6 | Host 用 `flock` 单实例锁，设备变化不退出 | 已被 `HostSupervisor`（App 侧唯一 owner）+ 状态机取代，且新增 Host-only restart |
| §8 | "Host 130、App 129" | **Host 379、App 253** |
| §8 | "首次安装 / 同版本重装 / 卸载 / CoreAudio 实际加载 / 真实音频输出 NOT TESTED" | 首次安装、同版本重装、CoreAudio 实际加载**已 REAL_MACOS_VERIFIED**；卸载、音频输出仍未验证 |
| 全文 | 未提及 | Default Output 治理（P2 Batch 2）、App 级 EQ writer（`EQService`）、Mapping 自动重挂、`Restart Host` 菜单项 |

**这份文件是 CI 会复制进 `dist/` 并随 Release 发布的唯一说明**（`release.yml` 里 `grep -q "$VERSION" dist/RELEASE_NOTES.md` 只检查版本号出现，不检查协议）。

### 7.3 `README.md` 的 3 处矛盾

| 位置 | README 说 | 实现 |
|---|---|---|
| L44 | "Download the latest `.dmg` … Launch SoundBridge — the onboarding wizard will guide you through driver installation" | DMG **只含 App**（`RELEASE_NOTES.md` §1："升级必须用这个 [PKG]"）。走 DMG 的用户只能靠 onboarding 装驱动 —— 也就是 §3.1 的**非事务路径** + `killall coreaudiod` |
| L51 | "To uninstall, use the 'Uninstall' option in the SoundBridge menu bar dropdown" | 这条路径会 `killall coreaudiod` 且 `rm -rf` 无身份校验（§3.2），与 `tools/uninstall_driver.sh` 声明的政策相反 |
| L55 | "The app updates itself through Sparkle" | `SUPublicEDKey` 为空 → Sparkle 不初始化，自动更新**在本构建中禁用**（`RELEASE_NOTES.md` §7.3 已如实写明）。README 与 RELEASE_NOTES 互相矛盾 |

（README L57 "it does not offer an in-app upgrade" 是**准确的**：`DriverUpgradePolicy.allowsUserFacingPrompt = false`，`showDriverUpdatePrompt`/`performDriverUpdate` 保留但**未接线**，`DriverUpdateWindow` 不可达。这一点本批次已核实，不算缺陷。）

### 7.4 发布渠道（SOURCE_VERIFIED）

`.github/workflows/release.yml`（482 行）触发于 tag，流程完整：构建 universal → protocol/DSP/Host/App/installer/codesign 测试 → bundle → ad-hoc 签名 → DMG → PKG → 5 个 verifier → **Stage Release Documents（缺文件即失败）** → SHA256SUMS（强制 2 行）→ Sparkle appcast（无密钥则跳过）→ 资产五项按名校验后上传。

结论：**渠道本身是好的；它会在第一步就正确失败**（P0-3）、并且会发布一份描述 131328 的说明（P1-5）。

---

## 8. P3 遗留验证项：是否阻塞 1.2.0

| 遗留项 | 如实状态 | 是否阻塞发布 | 判断理由 |
|---|---|---|---|
| **实际 EQ 听感** | `NOT RUN / BLOCKED`（默认输出是 `LG ULTRAGEAR+`，不是 Proxy；本批次未授权切换） | **阻塞 "READY"，不阻塞 "Pre-release"** | EQ 参数写入已被 REAL_MACOS_VERIFIED（新 mapping `eq_sequence=2`、bypass/bands 与 UserDefaults 独立推导一致），但"写进去"≠"听得见"。在没有任何一条真实听感记录的前提下，不能把产品描述为"EQ 可用"。若以 Pre-release + 明确"未验证音频"发布，则是可接受的 |
| **播放窗口 underrun** | `NOT RUN` | 同上 | 与 RT-1…RT-5（Driver 回调内递归锁 / 日志 / 惰性分配 / 格式重配置）和 H-1…H-3（render 线程 `os_unfair_lock`、一次性分配、缓冲增长分配）叠加，才构成"真实负载下的爆音/卡顿"风险。**已知缺陷 + 无实测 = 不能宣称音频质量通过**，但不阻止测试版发布 |
| **Popover 关闭状态下触发 Restart Host** | `NOT SEPARATELY OBSERVED` | **不阻塞** | 菜单项只能从打开的 popover 点击，这是交互本身的性质。EQ writer 与 mapping 的生命周期已由 `EQService`（AppDelegate 属性初始化时创建）+ `SharedMemoryMappingManager`（App 级）保证与 View 无关，并有上一批次 popover 从未打开的运行时证据。本批次只能给 `STATICALLY_REVIEWED` + 跨批次 `RUNTIME_OBSERVED` |

**不得**把 EQ 参数写入成功写成听感通过。本报告全文严格遵守这一条。

---

## 9. P0 / P1 / P2 / P3 问题清单

### P0 — 不解决则不存在"可发布的 1.2.0"

| 编号 | 问题 | 证据 | 修复动作 |
|---|---|---|---|
| **P0-1** | 被验证的代码不在任何提交里：5 个核心 Service 文件 + 8 个测试文件 untracked，HEAD 协议 131328 vs 工作区 131584 | `p4-head-vs-worktree.log` | 分片提交工作区（核心服务 → 测试 → Makefile/driver/host → 文档），提交后从该 commit 干净重建 |
| **P0-2** | `dist/` 的 1.2.0 产物是旧 App（`4dabbb24…`），默认 `verify_release_payload.sh` 对它返回 PASS | `p4-verify-payload-default.log` | 用 P0-1 的 commit 重建并**刷新 `dist/`**；在 `dist/` 放置唯一候选件；校验器输出加"候选件来源 commit"断言 |
| **P0-3** | `docs/INSTALLATION_GUIDE.md`、`docs/RELEASE_NOTES.md` 在工作区被删除；CI 会 `exit 1` | `p4-git-status.log`、`release.yml:349-366` | 恢复并**重写**为 131584 事实（不是简单 `git checkout`） |

### P1 — 阻塞"正式可用"，不阻塞"能打包"

| 编号 | 问题 | 证据 | 修复动作 |
|---|---|---|---|
| **P1-1** | Onboarding 首次安装走非事务路径（`rm -rf` + `cp -R` + `mv` + `killall coreaudiod`，无 verify/backup），与 PKG 事务形成两套安全等级 | `DriverInstaller.swift:192-198` | 首选：删除 App 内安装实现，改为引导用户运行 PKG；次选：让 `DriverInstaller` 调用 `sb_install_transaction.sh` |
| **P1-2** | App 内卸载 `killall coreaudiod` + 无身份校验 `rm -rf` + 通配删 `/tmp`，与 `tools/uninstall_driver.sh` 政策相反；清理范围与提示不符 | `MenuBarView.swift:508-514` | 统一为一种政策：先校验 bundle id、走备份/回滚、coreaudiod 交由用户决定（或显式二次确认）；统一用户数据语义 |
| **P1-3** | `test_release_payload.sh` 硬编码 `dist/SoundBridge-1.1.1.{pkg,dmg}` | `test_release_payload.sh:74-81` | 改为由 `VERSION` 选择，或在测试内用合成 fixture 构造"上一版" |
| **P1-4** | 卸载 → 重装闭环从未真实执行；卸载后残留与恢复能力无 REAL_MACOS 证据 | §3.7 | Batch 2 执行一次真实卸载 + 重装（需授权） |
| **P1-5** | 发布文档与事实冲突：RELEASE_NOTES 写 131328/旧测试数/旧架构；README 指向 DMG 与菜单栏卸载、声称 Sparkle 自更新 | §7.2、§7.3 | 重写两文档（Batch 1 内完成），README 三处修正 |

### P2 — 应修，可带病发布（Pre-release 可接受）

| 编号 | 问题 | 证据 |
|---|---|---|
| **P2-1** | DSP 测试摘要恒为 `0 passed, 0 failed`；`ctest` 只显示 `1 test` | §5.2(1)，本批次实测 |
| **P2-2** | `test-dsp` / `test-host` / `test-app` 写入固定目录；`test-installer-gate` / `verify-installer-pkg` 默认取 `build/` 下最新 pkg（当前 12 个） | §5.2(3) |
| **P2-3** | Host 缺失弹窗给用户开发者指令 `cd packages/host && swift build` | `SoundBridgeApp.swift:679` |
| **P2-4** | Underrun 日志不区分静音态/播放态，静音时也报（P3 实测 `+362`） | `SharedMemoryManager.swift:699` |
| **P2-5** | 安装器不检查 App/Host 是否运行；协议提升场景可能出现"新 App + 旧 Host" | §4.3 |
| **P2-6** | 风险登记表与发布检查单未随 P2/P3 更新（U-2/U-4、B-1/B-3 状态失真；检查单仍指导 `make clean`） | `Known-Limitations.md`、`Release-Checklist.md` |
| **P2-7** | 任务书引用的 P3 报告文件名与实际不一致（`-and-Real-`） | §0 命名说明 |

### P3 — 整洁性 / 一致性

| 编号 | 问题 | 证据 |
|---|---|---|
| **P3-1** | 见 P2-7 的文件名不一致（登记在此以便追溯） | — |
| **P3-2** | `DriverVersionGate.swift:342` 注释示例仍是 `0x00020100` | §5.2(4) |
| **P3-3** | `/tmp/com.soundbridge.host-global.lock` 不被任何卸载路径清理（flock 文件，无功能影响） | §3.7 |
| **P3-4** | EQ 写入失败只在 `logger.notice` 中可见 | `EQController.swift:471` |
| **P3-5** | 无 `CHANGELOG.md`，但存在 `make changelog` 与 `generate_changelog.sh` | §7.1 |
| **P3-6** | `packages/driver/install.sh` / `uninstall.sh` 为 `sudo cp -R` / `sudo rm -rf`，无身份校验，输出 `killall coreaudiod` 建议（开发脚本，但 `docs/1.2.0/` 旧报告仍引用） | §3.1 |

---

## 10. P4 Batch 1 / Batch 2 执行计划

### Batch 1 — 让"候选件"存在（提交 + 文档 + 干净重建）

> 前置：用户授权 Git 写操作。本批次（Batch 0）**未执行任何 Git 写操作**。

| 步骤 | 内容 | 完成判据 |
|---|---|---|
| **B1-1** | 提交工作区，分 4 个提交：① 5 个新 Service + 8 个新测试；② 已修改的 App/Host/Driver/shared 源；③ Makefile + tools；④ 文档（含恢复并重写两份被删文档）。**不 `git add -A`**，逐组显式列出 | `git status --porcelain` 仅剩 `build/` 与 `.qoder/`（若保留）；`git log` 可按组 review |
| **B1-2** | 重写 `docs/RELEASE_NOTES.md`：协议 131584、测试计数（Host 379 / App 253 / 事务 36 场景 / codesign 58 / DSP 33）、P3 后已 REAL_MACOS 的项目、仍未验证的项目（听感、播放 underrun、卸载）、新增能力（Supervisor / Restart Host / EQService / Default Output 治理） | `grep -c 131328` = 0；版本号出现 |
| **B1-3** | 重写 `docs/INSTALLATION_GUIDE.md` §8/§9/§11：卸载步骤与"唯一政策"一致；§11 状态表按 P3 事实更新（§3/§5 转 EXECUTED）；补"安装前退出 App" | 与 `tools/uninstall_driver.sh` 的政策逐条对齐 |
| **B1-4** | 修正 `README.md` 三处（PKG 优先 / 卸载方式 / Sparkle 禁用） | `grep` 校验 |
| **B1-5** | 更新 `Known-Limitations.md`（U-2/U-4/U-11、P-2/P-6 状态）与 `Release-Checklist.md`（B-1…B-5 重判） | 每条风险有"当前状态 + 证据文件" |
| **B1-6** | 从 B1-1 的 commit 做**干净重建**到新的隔离目录（如 `build/p4-dist/`），刷新 `dist/`，重跑 5 个 verifier + `verify_version_consistency --app --pkg` | `dist/` 与 `build/p4-dist/` 逐字节一致；verifier PASS 且哈希与 `build/p4-dist` 相同；`SHA256SUMS.txt` 2 行 |

**Batch 1 退出条件：** `git status` 干净（仅 build 产物）、`dist/` 候选件的 App 哈希 = 从该 commit 重建的哈希、两份文档与 131584 一致。

### Batch 2 — 闭环验证（需要真实操作授权）

| 步骤 | 内容 | 完成判据 |
|---|---|---|
| **B2-1** | 真实卸载（使用**统一后**的路径），观察 coreaudiod、HAL 目录、设备数、残留 | 设备数 7→5；无 SoundBridge proxy；记录残留清单 |
| **B2-2** | 卸载后重装 PKG（管理员授权），验证恢复 | 设备数回到 7；EQ 从 UserDefaults 自动恢复；`eq_sequence > 0` |
| **B2-3** | 首次安装路径（干净用户或新用户域）+ Gatekeeper 放行 | 与 INSTALLATION_GUIDE §3/§4 逐步一致 |
| **B2-4** | 播放窗口验证（**需单独授权切换默认输出**）：播放一段已知信号，观察 underrun 是否只在播放时增长、EQ 前后频响差异 | underrun 与播放窗口对齐；EQ 听感/测量有记录 |
| **B2-5** | 安装时 App 运行中的行为（P2-5） | 记录实际结果并写入文档 |
| **B2-6** | 在该 commit 上跑 `make test` + ASan + TSan + `test-release-payload` | 全绿；DSP 摘要显示真实通过数（若 P2-1 已修） |

**Batch 2 退出条件：** 卸载/重装/首次安装三条路径都有 REAL_MACOS_VERIFIED 证据；音频验证要么通过，要么以明文 `NOT RUN` 发布。

---

## 11. 正式 Release Gate 验收标准

发布（打 tag → CI 出包）前必须**全部**满足，且每条注明证据等级：

| # | 标准 | 证据等级要求 |
|---|---|---|
| G1 | 被发布的那份代码存在唯一 commit，工作区无未提交的源文件改动 | SOURCE_VERIFIED（`git status` + `git ls-files` 覆盖 5 个核心 Service） |
| G2 | 该 commit 上 `make test` exit 0，且各套件计数与文档一致 | TEST_VERIFIED |
| G3 | `protocol-check` + `version-check` PASS；协议 131584、11 个版本源 | TEST_VERIFIED |
| G4 | `dist/` 候选件的 App/Host/Driver 哈希 = 从 G1 的 commit 干净重建的哈希 | TEST_VERIFIED（哈希相等） |
| G5 | `verify_release_payload` / `verify_installer_pkg` / `verify_version_consistency --app --pkg` / `test_installer_preinstall` / `test_installer_pkg_roundtrip` 全 PASS，且 verifier 输出的哈希等于 G4 | TEST_VERIFIED |
| G6 | PKG 真实安装 → 109 文件一致 → 版本/协议/架构/签名核验 | REAL_MACOS_VERIFIED |
| G7 | 卸载 → 重装 → EQ 自动恢复 | REAL_MACOS_VERIFIED |
| G8 | `docs/RELEASE_NOTES.md` 与 `docs/INSTALLATION_GUIDE.md` 存在、协议写 131584、卸载政策与实现一致 | SOURCE_VERIFIED |
| G9 | README 的安装/卸载/更新三处与实现一致 | SOURCE_VERIFIED |
| G10 | 音频验证：要么有真实听感/频响记录（REAL_MACOS_VERIFIED），要么 README + RELEASE_NOTES 明确写明 "音频输出未验证，Pre-release" | REAL_MACOS_VERIFIED 或 显式 NOT RUN 声明 |

G1–G5 是**可自动化**的（B1-6 一次性完成）；G6–G7 需要一次真实操作窗口；G8–G9 是文档工作；G10 二选一。

---

## 12. 与"正式发布"的距离（回答任务书 §6 的四问）

**1. 当前是否接近正式发布？**
是。架构与运行时验证已经完成，剩下的是**交付纪律**问题：一个提交、一次干净重建、两份文档、一次卸载/重装。没有任何一条需要改架构、改 ABI、改 Driver。

**2. 真正阻塞发布的事项？**
- P0-1 代码不在 Git 里（决定性）；
- P0-2 `dist/` 候选件不是被验证的那一份（且默认 verifier 会给 PASS）；
- P0-3 两份必需文档被删除且内容过时；
- P1-5 文档声称 131328，与实际 131584 冲突；
- P1-1 / P1-2 两条与 PKG 政策相反的应用内路径（首次安装、卸载）。

**3. 可以接受的非阻塞缺口？**
- 实际 EQ 听感与播放窗口 underrun：以 Pre-release + 明文声明发布，可接受（但不得写成"通过"）；
- RT-1…RT-5 / H-1…H-3：已知缺陷，风险登记在案，不阻塞测试版；
- P2-1…P2-7、P3-1…P3-6：记录后按序修；
- x86_64 真机、macOS 14.4、真实设备拔插：环境限制，维持 NOT_VERIFIED。

**4. 下一批次最值得实施的具体任务？**
**P4 Batch 1 的 B1-1 + B1-6**：把工作区切成 4 个可 review 的提交，然后从那个 commit 干净重建并刷新 `dist/`。这一步一旦完成，P0-1 与 P0-2 同时消失，"我们发布的到底是哪个 1.2.0" 这个问题才有答案。文档（B1-2…B1-5）可以在同批次内并行完成。

---

## 13. 证据索引

| 文件 | 内容 |
|---|---|
| `p4-baseline.log` | Git / 版本基线 |
| `p4-git-status.log`、`p4-modified-files.log` | 125 条状态的完整清单（59 M / 64 ?? / 2 D） |
| `p4-head-vs-worktree.log` | HEAD 与工作区的 Services / Tests / 协议对照（P0-1） |
| `p4-artifact-inventory.log` | 全部 1.2.0 产物哈希、大小、mtime（P0-2） |
| `p4-signing-arch.log` | 已安装 App/Driver 的 plist、架构、codesign、`spctl` 结果 |
| `p4-verify-payload-default.log` | 默认校验器对旧 `dist/` 返回 `OVERALL_RESULT=PASS` |
| `p4-version-consistency.log`、`p4-protocol-check.log` | 11 源一致、协议 131584 |
| `p4-dsp-test-direct.log` | 33 个 ✓ 与 `Results: 0 passed, 0 failed`（P2-1） |
| `p4-uninstall-residue-baseline.log` | 卸载残留基线 |
| `p4-install-guide-HEAD.md`、`p4-release-notes-HEAD.md` | HEAD 版两份被删文档的完整副本（只读 `git show`） |

---

**报告结束。本批次到此停止：未进入 P4 Batch 1，未修改任何代码，未构建，未安装，未发布，未提交 Git。**
