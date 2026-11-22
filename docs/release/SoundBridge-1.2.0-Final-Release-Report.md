# SoundBridge 1.2.0 最终发布报告

**任务**：SoundBridge 1.2.0 — Final Code Commit, GitHub Release & End-to-End Installation Validation
**执行日期**：2026-11-21（本地 CST）
**执行机器**：Mac mini（arm64），macOS 27.2.1 / 26B131，`spctl` = assessments enabled，`csrutil` = enabled（两者全程未关闭）
**证据根目录**：`build/p4-release-1.2.0/evidence/`（`s01`–`s26`，本报告逐条引用）
**性质声明**：本轮为 **same-machine clean reinstall（同机卸载后重装）**，不是"从未装过该产品的全新机器"验证；该限制同样写入 §12 与 §23。

---

## §1 发布身份与不可变约束

| 项目 | 要求值 | 实测值 | 结论 |
|---|---|---|---|
| 版本 | 1.2.0 | `VERSION` = 1.2.0；App `CFBundleShortVersionString` = 1.2.0；PKG 回执 = 1.2.0；驱动 Info.plist = 1.2.0 | PASS |
| 协议版本 | `0x00020200` = 131584 | 共享内存头 `protocol=131584`（探针实测，K2/K6 全程不变） | PASS |
| 头长度 | 320 bytes | `header_size=320`（探针实测） | PASS |
| App Bundle ID | `com.soundbridge.menubar` | `mdls`/`Info.plist`/`pkgutil --pkg-info` 三处一致 | PASS |
| Driver Bundle ID | `com.soundbridge.driver` | 安装后 HAL bundle 与 `SoundBridgeDriver` 内嵌副本一致 | PASS |
| ABI / Header Layout | 不得改动 | 本轮未修改 `RFSharedAudio.h`；`static_assert` 偏移量断言随构建通过 | PASS |
| Deployment Target | 不得改动 | 构建与安装均沿用仓库既有设置，未改动 | PASS |

证据：`s06-version-consistency.log`、`s13-commit-version.log`、`s18-install-verify.log`、`s18-install-driver.log`。

---

## §2 签名姿态（完全不签名）

- 发布物**未使用** Developer ID、ad-hoc 显式签名、`productsign`、notarization、`notarytool`、`stapler`、Sparkle 私钥签名。全流程未执行任何 `codesign --sign`。
- App 与驱动仅残留 ld64 的 **linker 最低限度 ad-hoc CodeDirectory**：
  - `codesign -dv` → `flags=0x20002(adhoc,linker-signed)`，`TeamIdentifier=not set`，`Sealed Resources=none`
  - 驱动 bundle 内**无 `_CodeSignature` 目录**
- `Sparkle.framework` 保留上游自带的 4 个 ad-hoc 封印 bundle——这是第三方上游签名，不是本项目签名，报告中单独归类，不与项目签名混淆。
- `pkgutil --check-signature` → `Status: no signature`；`spctl -a -t install -vv` → `rejected / source=no usable signature`（原文见 `s17-install-precheck.log`）。
- App `Info.plist`：`SUEnableAutomaticChecks=false`、`SUPublicEDKey` 为空、`SUFeedURL` 保留为 GitHub `releases/latest/download/appcast.xml`（仅作链接来源，不参与更新签名校验）。本轮**未触发任何 Sparkle 自动更新检查**。

证据：`s06-verify-signatures.log`、`s06-verify-unsigned.log`、`s13-commit-verify-unsigned.log`、`s17-install-precheck.log`。

---

## §3 Gatekeeper / SIP 状态

- 全程 `spctl --status` = `assessments enabled`，`csrutil status` = `enabled`；**未**要求也未执行任何关闭 Gatekeeper / 关闭 SIP / `spctl --master-disable` 的操作。
- 系统对未签名 PKG 的判定如实记录为 `rejected`（§13），未通过绕过手段规避。
- 仓库脚本/文档中未发现"关闭 Gatekeeper 以完成测试"的步骤（Stage A OBS-6 复核项）。

证据：`s16-uninstall-before.log`（第 0 分区 metadata）、`s17-install-precheck.log`。

---

## §4 构建环境与可复现性

- 构建环境：macOS 27.2.1 arm64，Xcode 27.2；submodule `libASPL` 固定 `633e0f7`。
- 全部产物在**独立输出目录**构建（`build/p4-release-1.2.0/`），未执行 `make clean`，未删除既有 `dist/`。
- 架构：App 主程序、Host、驱动均为 `x86_64 arm64` 通用二进制。
- **不可复现性如实披露**：同一 commit 两次构建的 PKG/DMG 字节不同（内嵌构建时间戳/UUID），但驱动、Host、App 主程序的二进制 SHA-256 完全相同。因此"可复现"在本次仅对**二进制层面**成立，对**封装层面**不成立。

证据：`s03-build-env.log`、`s04-build.log`、`s05-pkg.log`、`s05-dmg.log`、`s13-authoritative-manifest.txt` 末尾 `note=`。

---

## §5 发布产物与权威哈希

| 资产 | 大小（bytes） | SHA-256 |
|---|---|---|
| `SoundBridge-1.2.0.pkg` | 14,362,287 | `2bf224605b4ecbcfbbf7253ba0bfc426fcaab96aee3e35623059dbdb86635a6f` |
| `SoundBridge-1.2.0.dmg` | 14,943,486 | `2c78d502c54d20dc4764843e5e1fbfa3c64daab2ad07fdc4943dffca8df643e7` |
| `SHA256SUMS.txt` | 176 | `539180fbe8aa1e7f2dcd94370281aebf3514b2dda746fbe419a32a4f08f3324f` |
| `INSTALLATION_GUIDE.md` | 18,074 | `01ad029bedb299e548f266a99a901d251b1a9072502b0319f9194f6561b9a782` |
| `RELEASE_NOTES.md` | 18,441 | `21d8105e54b5efd14be36516ae590ea76031895932dfb137488b121b7bebf34a` |

包内关键二进制（App/PKG 与安装后逐字节一致）：

| 二进制 | SHA-256 |
|---|---|
| `Contents/MacOS/SoundBridgeApp` | `7d76cae29dcdc5ae8eff2c8b451965e679f5a693edb40a71f09083d9044e9c3c` |
| `Contents/MacOS/SoundBridgeHost` | `a5750458689c21497f1c24f32ce38e3383b35240106a4b733c1ce1e4fcf89415` |
| `SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver` | `866f54bdbf618f52d90c05308c6e2c017c5f97841b30cdbe1afef8994323f3ab` |

证据：`s07-sha256sums.log`、`s13-authoritative-manifest.txt`、`s06-release-payload.log`。

---

## §6 本地门禁与负面测试

- `make test` 退出码 0（DSP ctest、Driver ctest、codesign 检查全通过）：`s09-make-test.log`。
- 发布校验器全绿：`verify_release_bundle`、`verify_release_payload`、`verify_installer_pkg`、`verify_pkg_driver`、`verify_dmg_contents`、`verify_signatures`、`verify_version_consistency`。
- **10 项负面测试全部按预期失败（`NEGATIVE_TESTS_PASS=10 NEGATIVE_TESTS_FAIL=0`）**：

| # | 负面场景 | 预期 | 实测 |
|---|---|---|---|
| N1 | 缺失协议头 → 协议检查 | exit 1 | PASS |
| N2 | 打包缺驱动的 App | exit 1 | PASS |
| N3 | DMG 预检拒绝缺 Host 的 App | exit 2 | PASS |
| N4 | 版本不一致 | exit 1（`VERSION_CONSISTENCY=FAIL`） | PASS |
| N5 | 驱动协议错误（131583≠131584） | exit 1 | PASS |
| N6 | 不存在的 PKG 路径 | exit 1 | PASS |
| N7 | 不存在的 App 路径 | exit 2 | PASS |
| N8 | 本仓库产生的封印 → 无签名断言 | exit 1 | PASS |
| N9 | 被篡改的 SHA256SUMS.txt | 校验失败 | PASS |
| N10 | 旧 ad-hoc bundle → 无签名断言 | exit 1 | PASS |

Stage A 的 OBS-1（不存在的 PKG 不得判 PASS）由 N6 覆盖；OBS-2（显式 App 路径错误后不得静默回落）由 N7 覆盖。

证据：`s08-negative-tests.log`、`s09-make-test.log`。

---

## §7 代码提交

- 提交：`fc09aeee4440f18af31e28bc9d0688916c96880f` — `Release 1.2.0: unsigned distribution workflow`（2026-11-21 23:01:43 +0800）。
- 提交方式：**逐路径 `git add`**（未使用 `git add -A` / `git add .`），提交前保存了 `git diff` 与待提交文件 SHA-256（`s02-stage-a.diff`、`s02-stage-a-sha256.log`、`s10-staged.diff`、`s10-staged-sha256.log`）；未提交二进制、日志与证据；用户既有 untracked 文件保留。
- 未执行 `reset`/`clean`/`checkout`/`restore`/`stash`/`push --force`，未删除任何远端分支或历史 Tag。

证据：`s10-commit-identity.log`、`s10-staged-sha256.log`。

---

## §8 Tag 一致性

- Tag `v1.2.0` 为 **lightweight**，指向 `fc09aee`，与 Release 提交一致。
- 三方一致：本地 `git rev-parse` / 远端 `git ls-remote` / GitHub API 三者同 commit。
- 未删除后重建 Tag，未移动他人 Tag。

证据：`s11-tag-before.log`、`s11-tag-after.log`、`s14-release-verify.log`。

---

## §9 GitHub Release

- Release：`https://github.com/chenjy16/SoundBridge/releases/tag/v1.2.0`，Title `SoundBridge 1.2.0`，`isDraft=false`、`isPrerelease=false`，发布时刻 `2026-11-21T15:14:39Z`。
- 资产 5 个，GitHub 记录的 digest 与本地权威哈希逐项相同（见 §5 表）：PKG、DMG、SHA256SUMS.txt、INSTALLATION_GUIDE.md、RELEASE_NOTES.md。
- 发布窗口内已将 `release: published` 触发的 workflow 临时 `disable`，避免 CI 覆盖资产（`s14-workflow-window.log`），完成后恢复。

---

## §10 公开下载校验（Stage G）

- 从公开 URL 下载到独立目录 `/Users/chenjianyu/Downloads/SoundBridge-1.2.0-release-validation/`，逐个重算 SHA-256：

| 断言 | 结果 |
|---|---|
| 下载 PKG SHA-256 == 本地权威 PKG SHA-256 | 一致 |
| 下载 DMG SHA-256 == 本地权威 DMG SHA-256 | 一致 |
| 下载 SHA256SUMS.txt SHA-256 == 本地 | 一致（`IDENTICAL`） |
| `shasum -c SHA256SUMS.txt` | `SoundBridge-1.2.0.dmg: OK` / `SoundBridge-1.2.0.pkg: OK` |

- 下载文件 `xattr` 仅含 `com.apple.provenance`（`curl` 下载不带 quarantine）。

证据：`s15-download-verify.log`、`s15-download-pkg-structure.log`、`s15-download-pkg-driver.log`、`s17-install-precheck.log`。

---

## §11 Stage H 卸载（同机 clean reinstall 的第一步）

**卸载前快照**（`s16-uninstall-before.log`）捕捉到一个非典型初始状态：

- `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`：**ABSENT**（用户已在 22:41 通过 App 的卸载入口删掉 driver bundle 与 `/Applications/SoundBridge.app`）
- 但 `coreaudiod` 仍持有已删 bundle 的**内存加载副本**：`Core Audio Driver (SoundBridgeDriver.driver)` PID 605 存活
- `pkgutil --pkgs` 仍有 `com.soundbridge.menubar` 1.2.0 回执（406 个文件）
- `~/Library/Application Support/SoundBridge/InstallerState/log/` 保留 8 份安装事务日志

**卸载执行**：

- `tools/uninstall_driver.sh --dry-run` 与真实执行均输出 `Nothing to uninstall: ... does not exist`，`exit 0`（bundle 已不在盘上）。
- 为使"驱动确实不再被加载"成立，显式执行 `killall coreaudiod`（admin 提权）：coreaudiod 581 → 32955，驱动 helper 605 消失。
- 卸载后快照（`s16-uninstall-after.log`）：无 SoundBridge 设备、无 LaunchAgent、无 `/tmp/soundbridge-*`、`/Applications/SoundBridge.app` 不存在。

**残留（如实记录，未自行扩大删除范围）**：

1. PKG 回执与 `InstallerState` 日志**不清理**——仓库卸载机制不含 `pkgutil --forget`；
2. `device-state.json` / `volume-state.json` / `defaults`（`com.soundbridge.menubar`）按要求**保留**（"保留用户配置与日志"）；
3. 卸载脚本**不重启 coreaudiod**，仅打印建议——因此"卸载后驱动仍在内存中运行"是机制上的固有窗口，需人工 `killall coreaudiod` 或重启才能闭合。

证据：`s16-uninstall-before.log`、`s16-uninstall-run.log`、`s16-uninstall-after.log`、`s16-audio-devices-before.txt`。

---

## §12 Stage I 安装（只安装 Stage G 下载的 PKG）

**安装源**：`~/Downloads/SoundBridge-1.2.0-release-validation/SoundBridge-1.2.0.pkg`，SHA-256 = `2bf22460…35a6f`（与 §5 权威值一致）。

**首次尝试失败并定位原因（如实记录）**：

```
installer: Error - the package path specified was invalid   (INSTALL_RC=1)
```

根因：`do shell script … with administrator privileges` 下 root 对 `~/Downloads/<目录>` 的**目录列举**被 TCC 拒绝（`Operation not permitted`），但对该**文件**的 `stat` 正常（14362287）。这不是 PKG 损坏，也不是路径拼写错误。

**处置**：`/bin/cp -p` 复制到 `/Users/Shared/SoundBridge-1.2.0-release-validation/`，复制后 SHA-256 相同且 `cmp` 结果 `IDENTICAL`，再从该路径安装。

**安装结果**：`installer: The upgrade was successful.`，`INSTALL_RC=0`（23:20:50 → 23:21:06）。

**安装校验**：

- `/Applications/SoundBridge.app`：`root:wheel`，`com.soundbridge.menubar` 1.2.0，无 quarantine
- PKG 回执 `com.soundbridge.menubar` 1.2.0，`install-time` 更新为 1795274465
- 事务日志 `install-20261121-232103-37517.log`：`PRECHECK no driver is installed; this is a first install` → `SUCCESS driver 1.2.0 (protocol 131584)`
- **逐文件比对**：PKG payload 与安装后 App **109/109 文件字节一致**
- 驱动：PKG payload 内**按设计不含** HAL bundle（payload 只落 `InstallerPayload`，postinstall 事务 rename 到 HAL），因此改与 App 内嵌副本比对：`cmp` 结果 `IDENTICAL`，SHA-256 `866f54bd…3f3ab`

**安装 ≠ 驱动已加载**：安装结束后 `coreaudiod`（启动于 23:19:35，早于安装）并未扫描新插件，此时无驱动 helper、无设备——这一时序由 §15–§18 单独取证。

证据：`s17-install-precheck.log`、`s17-install-run.log`、`s18-install-verify.log`、`s18-install-driver.log`、`s18-payload-compare.log`。

---

## §13 Gatekeeper 对安装的判定（原文，未规避）

```
spctl -a -t install -vv SoundBridge-1.2.0.pkg
SoundBridge-1.2.0.pkg: rejected
source=no usable signature
(rc=3)

pkgutil --check-signature SoundBridge-1.2.0.pkg
Status: no signature
```

- **未**关闭 Gatekeeper、**未**关闭 SIP、**未**使用 `spctl --add` 之类白名单手段。
- 本次 Stage I 的安装通过 `installer -pkg`（root/CLI）完成，因此**没有**触发双击 PKG 时的 Gatekeeper 交互流程；"系统设置 → 隐私与安全性 → 仍要打开"这条 GUI 批准路径**本轮未实测**，仅确认文档描述（`docs/INSTALLATION_GUIDE.md` §5）与实际判定一致。这是本轮分发验证的一个明确边界，已计入 §23。
- 未签名驱动的加载结果不以推测代替实测：见 §18。

---

## §14 L1 — PKG 安装成功

| 判据 | 证据 | 结论 |
|---|---|---|
| `installer` 退出码 0 | `s17-install-run.log` | PASS |
| 事务日志 `[SUCCESS] driver 1.2.0 (protocol 131584)` | `s18-install-driver.log` | PASS |
| 回执 `com.soundbridge.menubar` 1.2.0 存在且 install-time 更新 | `s18-install-verify.log` | PASS |

---

## §15 L2 — bundle 进入 HAL 目录

| 判据 | 实测 |
|---|---|
| 路径 | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` |
| 形态 | 真实目录（非符号链接），`root:wheel` |
| Bundle ID / 版本 | `com.soundbridge.driver` / 1.2.0 |
| 架构 | `lipo -archs` = `x86_64 arm64` |
| SHA-256 | `866f54bdbf618f52d90c05308c6e2c017c5f97841b30cdbe1afef8994323f3ab` |
| `_CodeSignature` | 不存在 |
| `codesign -dv` | `flags=0x20002(adhoc,linker-signed)`，`TeamIdentifier=not set` |

结论：**PASS（L2 成立）**。证据：`s18-install-driver.log`。

---

## §16 L3 — 被系统发现

- 首次探测（23:22:16，安装后 1 分钟）：coreaudiod 32955 启动于 23:19:35，**早于安装**，未加载新插件——bundle 在盘但无 helper、无设备。
- 触发系统重扫：`killall coreaudiod` → coreaudiod 48791，2 秒后派生 `Core Audio Driver (SoundBridgeDriver.driver)` **PID 48806**。
- coreaudiod 侧日志（决定性）：

```
HALS_RemotePlugInRegistrar.mm:239 Attempting to load: SoundBridgeDriver.driver
HALS_RemotePlugInRegistrar.mm:423 Creating remote driver service ... pid: 48806
```

结论：**PASS（L3 成立）**；并据实记录"安装脚本不重启 coreaudiod，加载需等下一次 HAL 扫描/重启音频守护进程"这一机制事实。证据：`s19-J-probe1.log` … `s19-J-probe4.log`。

---

## §17 L4 — HAL 枚举出设备

`system_profiler SPAudioDataType` 出现两个代理设备：

| 设备 | Transport | 状态 |
|---|---|---|
| `LG ULTRAGEAR+ (SoundBridge)` | Virtual | Default Output Device: Yes |
| `PHL 279M1RV (SoundBridge)` | Virtual | 可用 |

**L4 只证明枚举，不证明加载**：本节结论不与 §18 合并。证据：`s19-J-probe1.log`、`s19-J-probe6.log`。

---

## §18 L5 — coreaudiod 实际加载（三个独立探针）

| 探针 | 原始证据 | 结果 |
|---|---|---|
| 进程 | `ps` 中 `Core Audio Driver (SoundBridgeDriver.driver)` PID 48806 | 存活 |
| 系统日志 | `subsystem == "com.soundbridge.driver"` 驱动循环日志（`SyncDevices: control read rejected (status=1)` 约 1.5 s 一次） | 代码在跑，等待 Host 控制文件 |
| 宿主侧观察 | `system_profiler` 设备 + Host/驱动共享内存连接（§19） | 一致 |

配套实测：
- `log show` 默认过滤掉 info/debug，需加 `--info --debug` 才可见——这是取证方法约束，不是"无日志"。

结论：**PASS（L5 成立，未签名驱动在 SIP/Gatekeeper 均开启的 macOS 27.2.1 上被实际加载）**。证据：`s19-J-probe1.log`–`s19-J-probe6.log`。

---

## §19 L6 — 与 Host 建立 Session

启动 Host（`/Applications/SoundBridge.app/Contents/MacOS/SoundBridgeHost`，PID 52068）后：

| 判据 | 实测 |
|---|---|
| 控制文件 | `/tmp/soundbridge-devices.txt` 158 B，`#SB-CONTROL 1 AD9FE991-4BF0-4EB8-A0A7-CF03EBBC720E 3 501 2` + 2 行设备 |
| 共享内存 | 两个 `65856 B` mapping（320 头 + 8192 帧 × 2ch × 4B） |
| 驱动日志 | `✓ Mapped at … (size: 65856)` / `✓ Connected on attempt 1` / `Volume state: adopted committed shared-memory value 0.8789 (rev 1)` |
| 生命周期快照 | `sharedMemoryConnection=connected`、`sessionID=AD9FE991-…` |

结论：**PASS（L6 成立）**。证据：`s19-host-run.log`、`s19-lifecycle-snapshot1.log`。

---

## §20 L7 — 回调正常 / 音频真实流动

- 生命周期快照五项全绿：`driverFile=present`、`driverLoad=loaded`、`halDiscovery=discovered`、`proxyDevice=found`、`sharedMemoryConnection=connected`、`audioPipeline=flowing`，`detail="audio flowing through the driver"`，`revision=71`。
- Host 渲染回调：`Callback timing: n=5625 min=0.0us p50=… p99=… max=… overBudget=0`。
- 驱动 STATS（30 s）：`Writes: 1408 (failed: 0)`、`Clients: starts=1 stops=0`、`Health: failures=0 reconnects=0`、`Format: changes=0 SRC=1408`。
- 计数速率（K2 实测）：空闲 ~9.5k 帧/秒 → 播放期间 ~47.8k 帧/秒（48 kHz 满速）。

结论：**PASS（L7 成立）**。证据：`s19-lifecycle-snapshot1.log`、`s20-K2-counters.log`、`s20-K2-render.log`。

---

## §21 K1–K5 功能验证

### K1 设备

- 两个代理设备枚举正常；默认输出为 `LG ULTRAGEAR+ (SoundBridge)`（`systemDefaultOutputUID=1E6D4678-…-soundbridge`）。
- **未主动改变用户默认音频设备**；Host 日志显示 `[Route] LG ULTRAGEAR+ via proxy 169; default output left untouched`，随后 `Default output changed: 1E6D4678-…-soundbridge` 的成因判定为 macOS 按 UID 恢复用户既有选择，已在证据中标注。
- 结论：**PASS**。

### K2 播放

- 12 次 `Glass.aiff` 播放，每 3 s 采样：帧速率升至约 47.8k 帧/秒，`overruns=0`、`format_mismatch=0`；播放窗口内 `underruns` 仅 +4（客户端起停边界）。
- Host 侧 `silence` 计数在播放窗口 680→683（基本不动）→ 渲染到的是非静音数据。
- 驱动日志每次 `afplay` 都呈 `OnStartIO → Mapped → Connected → OnStopIO / Last client stopped - disconnecting`。
- **人工听感：用户确认"清楚听到"测试音**。
- 结论：**PASS**（客观计数 + 主观听感双证据）。

### K3 音量 / 静音（含恢复）

| 操作 | 共享内存实测 |
|---|---|
| `set volume output volume 60` | `volume=0.5942` |
| `set volume output volume 20` | `volume=0.1914` |
| `set volume output muted true` | `mute=1` |
| `set volume output muted false` | `mute=0` |
| `set volume output volume 88` | `volume=0.8789` |

- 与 `VolumeTaper`（`dB = 48·√s − 48`）一致；`volume-state.json` 记录 `0.87890625`，已恢复到用户原值。
- **观察项 O-K3-1**：第一轮 unmute 与 set 88 在设备断连窗口内未提交（`get volume settings` 同步显示 `19 / muted:true`），复测即恢复。判定为系统属性提交窗口问题，不判驱动缺陷，但如实记录。
- 结论：**PASS（含 1 项非阻断观察）**。

### K4 EQ

操作序列与实测（1 Hz 采样，`eq_seq` 为 SeqLock 序号）：

| 时刻 | `eq_seq` | `bypass` | 10 段增益（dB） | 对应 UI 值 |
|---|---|---|---|---|
| 23:29:02 | 0 | 0 | 全 0 | 未启用 |
| 23:29:37 | 2 | 1 | 5.873 / 11.747 / 17.620 / 0 / 0.767 / 1.534 / 0 / 0 / −0.881 / −2.863 | 启用瞬间下发历史值（Bass 11.747 / Mids 1.278 / Treble −2.202） |
| 23:29:39 | 4 | 0 | 同上 | EQ 生效 |
| 23:29:48 | 6 | 0 | 3.991 / **7.981** / 11.972 / … | Bass ≈ **+8 dB** |
| 23:29:53 | 8 | 0 | … / **0.004** / 0.007 / … | Mids ≈ **0 dB** |
| 23:30:03 | 10 | 0 | … / **−3.226** / **−10.484** | Treble ≈ **−8 dB** |

- `eq_seq` **0→2→4→6→8→10 单调递增**，与 3×10 权重映射（Bass 0.5/1.0/1.5、Mids 0.6/1.2、Treble 0.4/1.3）逐项吻合。
- Host 侧应用路径已核对：`AudioRenderer` 在每次渲染回调中 `rf_load_eq_snapshot` → 比较变化 → `soundbridge_dsp_update_band_gain`（10 段）/`update_preamp`/`set_bypass` → `soundbridge_dsp_process_interleaved`（`AudioRenderer.swift` 第 599–628 行）。即"参数进入共享内存"与"参数被 DSP 使用"是同一条已证实的代码路径，且期间无错误日志。
- **观察项 O-K4-1（App 侧持久化）**：退出 App 再启动后，共享内存恢复为 `5.873/11.747/17.620…`（即本次拖动**之前**的历史值），而非最后一次的 +8/0/−8。`defaults` 中 `eq_default_enabled=1` 已更新、三档滑块值仍为旧值（plist mtime 23:29）。代码上滑块释放走 `flushToSharedMemory()`（不写 UserDefaults），限流管道里的 `saveToUserDefaults()` 才是持久化点；本轮未能复现"拖动后的值被持久化"，故如实记为 App 侧持久化观察项，**不影响 EQ 运行时功能判定**。
- **人工听感**：用户仅回报"EQ 做完了"，**未**单独给出"低音变厚/高频变闷"的听感确认。因此 K4 的成立依据是客观参数链（`eq_seq` 推进 + 10 段增益与 UI/映射三方吻合 + Host 代码路径与运行期无错），不含主观听感证据。
- 结论：**PASS（运行时 EQ 生效；主观听感未独立取证，持久化存在非阻断观察 O-K4-1）**。

### K5 恢复

| 子项 | 操作 | 实测 | 结论 |
|---|---|---|---|
| K5a Host 停止 | 对 Host 发 SIGTERM | `[Signal] Received SIGTERM` → `[HostState] active -> stopping` → 清理 AudioUnit / 控制文件 / 共享内存 → `coreaudiod left running (policy: no automatic audio-daemon restart)`；设备行数归 0 | PASS |
| K5b App 退出 + 重启 | `tell application "SoundBridge" to quit` → 重新 `open` | 退出后 App/Host 均消失、`/tmp` 无残留；重启后新 session `6F257407…`、新 `admission_epoch`、控制文件与两个 mapping 重建、设备重新枚举；播放触发 `✓ Mapped` + `✓ Connected on attempt 1`，`audioPipeline=flowing` | PASS |
| K5c 设备移除 | — | 用户选择跳过（未拔插 LG ULTRAGEAR+） | **NOT_TESTED** |

- 取证方法更正：`driver_connected` 只在播放进行中有效，播放结束后归 0 属正常回收，不以终止态读数判"链路故障"。
- 结论：**K5a / K5b PASS，K5c NOT_TESTED**。

证据：`s20-K2-playback.log`、`s20-K2-counters.log`、`s21-K3-volume.log`、`s21-K3-retry.log`、`s24-K4-eq-samples.log`、`s24-K4-host-apply.log`、`s24-K4-eq-persist-diagnose.log`、`s22-K5a-host-stop.log`、`s22-K5a-device-removal.log`、`s25-K5b-quit.log`、`s25-K5b-relaunch.log`、`s25-K5b-recover-playback.log`。

---

## §22 K6 — ≥30 分钟真实播放稳定性

**运行方式**：生成 31 分钟 480 Hz / −30 dBFS 单声道 48 kHz 测试音（1 秒块无缝重复），经系统默认输出 = `LG ULTRAGEAR+ (SoundBridge)` 连续播放；测试期间音量降至 30%，每 60 s 采样一次共享内存与进程状态。

| 指标 | 实测 | 判据 |
|---|---|---|
| 连续播放时长 | 23:33:19 → 00:04:20 = **31 分 01 秒**（`player exit 0`） | ≥30 min：满足 |
| 帧计数 | `total_frames_written` 1,823,990 → 91,144,445，增量 **89,320,455 帧 / 1861 s = 47,996 帧/秒** | 48 kHz 满速：满足 |
| 欠载 | 基线 6,470（播放前空闲期）→ min=01 起 **恒定 6,487**，连续 30 个采样点（min=01…min=30）零增长；播放结束后客户端停止边界 +59（6,546），停播后空闲期继续增长 | 播放期间零欠载 |
| 溢出 | `overruns=0` 全程 | 满足 |
| 格式失配 | `format_mismatch=0` 全程 | 满足 |
| 连接态 | `driver_connected=1`、`host_connected=1`、`admission_epoch` 恒定，min=01…min=30 每个采样点均成立 | 连接未中断 |
| 进程 | Host 全程存活；驱动 helper PID 48806 全程存活（脚本列的 `helper_alive` 因 `pgrep` 把括号当正则分组而误报 0，已用修正后的 pattern 单独复核为存活，`driver_heartbeat` 1,952→176,398 亦证） | 满足 |
| Host 内存 | 18,640 KB（运行 3 分钟）→ 15,616 KB（运行 35 分钟），无增长 | 无泄漏迹象 |
| Host 回调时序 | `n=198,286`，p50 = 32 µs，p95 = 68 µs，p99 = 74 µs，max = 170 µs，**overBudget = 0** | 实时性满足 |
| 驱动 STATS | `Writes ≈ 2,813 / 30 s`（≈ 93.8 次/秒 × 512 帧 = 48,010 帧/秒），`failed: 0`；`Health: failures=0 reconnects=0`；`Format: changes=0` | 满足 |
| 错误日志 | 该时段内匹配 `error|fail` 的 42 行**全部**是 `failures=0` / `(failed: 0)` 字样本身 | 零真实错误 |
| 音量恢复 | 测试后 `set volume output volume 88` → 系统 88，shm `volume=0.8789`，`volume-state.json` = 0.87890625 | 已恢复用户原值 |

**观察项 O-K6-1**：测试结束的第一次 `set volume 88` 未提交（系统读数仍为 29），重新执行 `set 88 → 80 → 88` 后系统读数正确、再播放一次使驱动 adopt 后 shm 同步为 0.8789。与 O-K3-1 同源：客户端停止后属性写入存在提交窗口。**已恢复到位，不构成残留**。

结论：**PASS**。K6 的判定依据是**真实连续播放**（帧计数满速增长 + Host `silence` 计数在播放窗口内不增长 + 驱动 Writes 满速），不是"构建成功"或"设备枚举"。

证据：`s26-K6-samples.log`、`s26-K6-midrun.log`、`s26-K6-final.log`、`s26-K6-volfix.log`、`s26-K6-volrestore.log`、`s26-K6-volrestore-retry.log`。

---

## §23 已知限制、残留风险与最终裁决

### 23.1 未验证项（明确不计入 PASS）

| 项目 | 状态 | 说明 |
|---|---|---|
| K5c 设备移除/热插拔 | **NOT_TESTED** | 用户选择跳过（未拔插 LG ULTRAGEAR+）；K5a/K5b 两项恢复场景已通过 |
| 双击 PKG 的 Gatekeeper 批准 GUI 路径 | **NOT_TESTED** | 本轮经 `installer` CLI 安装；`spctl` 的 `rejected` 原文已记录，未关闭 Gatekeeper/SIP，未走"仍要打开"点击流程 |
| "全新机器从未装过" | **不适用** | 本次是 same-machine clean reinstall；`/Applications/SoundBridge.app` 曾存在、PKG 回执曾存在 |
| 多设备 EQ 隔离 | **未验证** | 本轮只对单一代理设备（LG ULTRAGEAR+）验证 EQ；持久化键实测退化为 `eq_default_*` 全局键 |

### 23.2 非阻断观察项

1. **O-K3-1 / O-K6-1**：音量/静音属性在"无 IO 客户端窗口"写入可能不提交，需在播放进行中复设；两次实测均一次复设即生效。
2. **O-K4-1**：EQ 滑块值在本轮未持久化（重启后恢复为拖动前的历史值，`eq_default_bass_db=11.74675` 等）；`eq_default_enabled` 已更新。运行时 EQ 功能不受影响。
3. **O-H-1**：仓库卸载机制不清理 PKG 回执与 `InstallerState`，也不重启 `coreaudiod`——卸载后驱动可能仍以内存副本运行，需人工 `killall coreaudiod` 或重启。
4. **O-B-1**：PKG/DMG 封装层不可字节复现（内嵌时间戳/UUID），二进制层可复现。
5. **O-G-1**：未签名分发意味着普通用户双击安装/首次打开会被 Gatekeeper 拦截，需手动批准；这是产品级分发体验限制，不是本轮新引入。

### 23.3 分发姿态的如实披露

- 本项目 1.2.0 **完全不签名**：无 Developer ID、无 ad-hoc 显式签名、无公证、无 Sparkle 应用签名。残留仅为 ld64 的 `linker-signed` 最低限度 CodeDirectory 与 Sparkle 上游自带的 ad-hoc 封印。
- **未签名 HAL 驱动在本机（macOS 27.2.1，SIP 与 Gatekeeper 均开启）确实被 coreaudiod 加载**（§18 三探针 + §19/§20 链路证据）。这与"未签名驱动一定被拒绝"的假设相反，但结论仅限本机实测，不外推到其他 macOS 版本或打开更严格策略的机器。

---

## 最终裁决

```
PASS — SOUND BRIDGE 1.2.0 RELEASED AND VERIFIED
```

**裁决依据**：

| 维度 | 结果 |
|---|---|
| 发布物真实性 | 公开 URL 下载的 PKG/DMG/SHA256SUMS 与本地权威哈希逐项一致（§10） |
| 安装 | Stage G 下载包经 `installer` 安装成功；payload 与安装后 App **109/109 文件字节一致**；驱动与内嵌副本 `IDENTICAL`（§12） |
| 驱动加载 L1–L7 | 七层全部以独立证据成立，未用 L4 冒充 L5（§14–§20） |
| 功能 K1–K4 | 设备、播放（47.8k 帧/秒 + 用户确认听到）、音量/静音含恢复、EQ（`eq_seq` 0→10 单调 + 10 段增益与 UI 双侧吻合）全部成立（§21） |
| 恢复 K5 | K5a（SIGTERM 有序停机并回收全部 IPC 资源）、K5b（App 退出→重启→新 session→驱动自动重连）成立；K5c 未测（§21） |
| 稳定性 K6 | 31 分 01 秒真实播放，播放期间**零欠载、零溢出**、零格式失配、零回调超预算、内存无增长（§22） |
| 安全边界 | 全程未关闭 Gatekeeper / SIP，未使用任何签名手段（§2、§3、§13） |

**该裁决的边界**：以 1 项未测（K5c 设备移除）、1 项未测（Gatekeeper GUI 批准路径）、4 项非阻断观察为界；若分发目标是"普通用户可无摩擦安装"，则本版本仍属**未签名分发**，需在发布说明中保持显著提示。

---

*报告生成时间：2026-11-22 00:10（CST）；所有结论均可由 `build/p4-release-1.2.0/evidence/` 下的原始日志复核。*
