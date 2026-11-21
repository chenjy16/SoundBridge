# SoundBridge 1.2.0 — Release Notes

发布日期：待定（Pre-release 准备阶段）
发布类型：**Pre-release（候选版本，未完成真实环境验证）**
协议版本：`0x00020200`（131584）

---

## 0. 这份文档怎么读

每条结论都带证据等级。同一个功能可以有多个等级，只有最高等级的那句话才算「已验证」。

| 等级 | 含义 |
|---|---|
| **REAL_MACOS_VERIFIED** | 在真实 macOS 上、用真实构建产物、按用户路径执行并记录输出 |
| **TEST_VERIFIED** | 自动化测试覆盖并通过（单元/集成/脚本断言） |
| **SOURCE_VERIFIED** | 只读源码、脚本、产物结构确认，未运行 |
| **NOT_VERIFIED** | 没有任何证据；本文不暗示它可用 |

**本版本处于 Pre-release 验证阶段。** 已完成的验证集中在源码级与自动化测试级；
真实设备上的播放质量、卸载重装闭环、播放窗口 underrun 均**未**验证。**不得**把本
版本描述为「音频质量已通过」。

---

## 1. 这一版是什么

1.2.0 是第一个**同时分发 App 和 HAL 驱动**的版本。此前只分发 App 的 DMG，重装 App
并不能替换 `/Library/Audio/Plug-Ins/HAL/` 里的驱动，于是「装了新版、驱动还是旧版」
在用户侧无法自查。

两条渠道，用途不同：

| 文件 | 内容 | 用途 |
|---|---|---|
| `SoundBridge-1.2.0.pkg` | App + 驱动 | **安装与升级的唯一受支持路径** |
| `SoundBridge-1.2.0.dmg` | 仅 App | 只替换 App，或查看包内容 |

两个包都是 **ad-hoc 签名，未经 Apple 公证**。本项目不承诺 Developer ID 或
Notarization 版本。首次运行需要一次 Gatekeeper 放行，步骤见
[INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) 第 5 节。

---

## 2. 从 1.1.x 升级

**用 PKG，不要用 DMG。**

协议从 `0x00020000` / `0x00020100` 变更到 `0x00020200`。旧驱动配 1.2.0 的 App 不会
出声：App 会显示一条版本/协议不匹配的说明（只有文字，没有「一键修复」，也没有安装
按钮），但不会自行替换驱动。

PKG 的 preinstall 在写入任何文件之前做版本门禁：

| 已装状态 | 结果 |
|---|---|
| 更旧（含 1.1.2，没有 `SBAudioProtocolVersion` 键） | 升级，继续 |
| 相同 | 重装，继续 |
| 更新 | 拒绝，未写入任何文件 |
| 协议更新 | 拒绝，不降级线格式 |
| 声明了不认识的协议 | 拒绝 |

安装前请退出 SoundBridge（见 [Known-Limitations](risks/Known-Limitations.md) P2-5：
安装器不检查 App/Host 是否在运行）。

---

## 3. 新增与变更

### 3.1 安装器（PKG）

- App 与驱动一起安装，驱动不再依赖用户手动拷贝。
- 驱动替换是事务：校验载荷 → 暂存 → 校验副本 → 备份旧驱动 → 重命名换位 → 再次校验；
  任一步失败则回滚，旧驱动保留或还原（`SOURCE_VERIFIED`，`tools/sb_install_transaction.sh`）。
- 安装器与 App 都**不再** `killall coreaudiod`（`SOURCE_VERIFIED`）。
- 静态校验：`make verify-installer-pkg`、`make verify-pkg`（`TEST_VERIFIED`）。

### 3.2 App 不再自己安装驱动（P4 Batch 1A）

这是 1.2.0 最重要的安全收敛：

- 删除 App 内的特权安装事务（`osascript` + `rm -rf`/`cp -R`/`mv` + `killall coreaudiod`）。
  它无法回滚、会在磁盘写满时留下半份 bundle，并让所有进程的音频中断。
- Onboarding 改为**引导用户打开正式 PKG**：定位同目录下的 `SoundBridge-*.pkg`，找不到
  时指向 Release 页面，都没有时只说明文件名。
- 安装成功后由 `DriverVersionGate` 读取文件系统判定，**App 不会在未验证结果时显示
  安装成功**；从 Installer 返回后自动重查一次。
- 全 App 源码中只剩**一条**特权命令（卸载），由单元测试逐文件锁定
  （`DriverInstallBoundaryTests`，`TEST_VERIFIED`）。

### 3.3 统一卸载政策（P4 Batch 1A）

App 内「Uninstall Driver」与 `tools/uninstall_driver.sh` 现在执行同一套政策
（`DriverUninstallPolicy`）：

| 规则 | 之前（App） | 现在（两者一致） |
|---|---|---|
| 删除前校验 `CFBundleIdentifier` | 不校验 | 必须为 `com.soundbridge.driver` |
| 符号链接 | 直接 `rm -rf` | 拒绝 |
| 删除范围 | HAL 路径 + `/tmp/soundbridge-*` 通配符 | 只删一个常量路径 |
| 重启 `coreaudiod` | 无条件 `killall` | **从不**，只给出手动建议 |
| Host 退出 | `killall SoundBridgeHost` | 先 `shutdown(intent: .uninstall)` 并等待 |
| 卸载中 Host 被重启 | 可能 | supervisor 已上锁，不会 |
| 删除后确认 | 无 | 路径消失才算成功 |

保留：EQ 设置、音量状态、日志、App 本身。删除：驱动 bundle、引导状态。
UI 确认框逐条列出这两组内容，文案与政策同源（`TEST_VERIFIED`）。

### 3.4 HostSupervisor

App 侧的 Host 生命周期由一个 supervisor 独占：启动、watchdog、退出、重启、去重。

- Host 退出不再导致 App 退出（旧实现在 termination handler 里 `NSApp.terminate`）。
- 状态机：`starting` → `running(pid:)` → `degraded` / `stopped`，并上报菜单栏。
- 启动有 6.0 s watchdog：进程活着但没拿到实例锁会被终止，而不是被当作健康。
- 有单元测试覆盖启动、超时、退避、降级与并发请求（`TEST_VERIFIED`）。

### 3.5 Host-only Restart

新增菜单项与 `HostRestartEntry` 闸门：只重启 Host，不重启 App、不重启 `coreaudiod`。

- 卸载中、App 终止中、卸载进行中一律拒绝重启。
- 重启请求合并，不会出现两个 Host 争锁。
- 在真实 macOS 上执行过一次完整闭环（退出 → 重新拉起 → 拿锁 → 恢复音频路径），
  日志与时间线见 [P3-Host-Restart-Entry-and-Recovery-Validation-Report.md](P3-Host-Restart-Entry-and-Recovery-Validation-Report.md)
  （`REAL_MACOS_VERIFIED`，范围仅限 Host 进程重启，不含真实音频听感）。

### 3.6 EQService

App 的 EQ 只有一个写者。之前 `EQController` 由多个视图各自持有，最后写入者获胜，
Host 的 `eq_sequence` 与实际值可能不一致。

- `EQService.shared` 在 `SharedMemoryMappingManager.start()` 之前创建，先于任何视图。
- 所有视图读写同一份状态，写入按序发布到共享内存（`TEST_VERIFIED`：
  `EQLifecycleOwnershipTests`）。

### 3.7 SharedMemoryMappingManager

把「映射的 attach/retire/unmap」从视图与回调中抽出来，交给一个拥有队列的单一所有者。

- 每代 mapping 只 unmaps 一次，且不在写者线程上 unmaps。
- 停止时排空队列后才返回。
- 卸载/退役不会排在自身后面（无自死锁）。
- 覆盖并发租约、末次租约释放、退役后写入等场景（`TEST_VERIFIED`：
  `SharedMemoryMappingManagerTests`、`SharedMemoryMappingUnmapThreadTests`、
  `SharedMemoryMappingConcurrencyTests`）。

### 3.8 EQ Mapping 自动恢复

Host 重新发布映射（重启、CoreAudio 恢复）后，App 会把当前 EQ 重新写入新映射，而不是
停在 `eq_sequence = 0`。

- 触发点：`mappingPublished` + 版本/代际比对，不依赖视图是否打开。
- 恢复失败会记录并保留 UserDefaults 中的值，下次发布再试。
- 覆盖首次发布、Host 重启、代际变化与写失败重试（`TEST_VERIFIED`：
  `EQRecoveryTests`）。

### 3.9 Default Output 治理

新增 `DefaultOutputHAL` / `DefaultOutputOwnership` / `DefaultOutputSwitch`：

- 明确记录「默认输出设备由谁拥有」，避免 App 与系统设置互相覆盖。
- 切换默认输出只在用户显式操作时发生，并有所有权校验；Host 不会隐式切走用户的设备。
- 覆盖所有权判定、切换失败、设备消失与并发切换（`TEST_VERIFIED`：
  `DefaultOutputGovernanceTests`、`DefaultOutputTrackingTests`、`DefaultOutputSwitchTests`）。

### 3.10 RT 可观测性与渲染安全

- 新增 `RFRealtimeTelemetry`：回调内只做无锁计数，读侧汇总。
- `AudioRenderer` 去掉渲染回调内的字典锁、一次性分配与 `print`（H-1 – H-3 的主要部分）。
- 覆盖回调计数、无分配路径与观测读侧（`TEST_VERIFIED`：`AudioRendererRTSafetyTests`、
  `RTObservabilityTests`）。

### 3.11 安装器与发布检查器

- `verify_installer_pkg.sh`：载荷布局、preinstall 烘焙的版本/协议、事务脚本字节一致、
  postinstall 交接（36 场景 / 168 断言，`TEST_VERIFIED`）。
- `verify_pkg_contents.sh` / `verify_dmg_contents.sh` / `verify_release_payload.sh`：
  三/四向驱动一致性、架构、Sparkle 结构、Host 版本证据。
- `test_release_payload.sh`：先做破坏再断言检查器失败（244 断言，`TEST_VERIFIED`）。
  本版本起使用**合成 fixture**，不再依赖 `dist/` 中任何历史发布产物。
- `test_codesign_args.sh`：58 项签名参数检查（`TEST_VERIFIED`）。

---

## 4. 当前验证规模

以下数字来自 1.2.0 源码在当前工作区的实际运行结果。

| 套件 | 规模 | 等级 |
|---|---|---|
| Host（`swift test`，`packages/host`） | **379 tests / 0 failures** | TEST_VERIFIED |
| App（`swift test`，`apps/mac/SoundBridgeApp`） | **253 tests / 0 failures** | TEST_VERIFIED |
| DSP（`make test-dsp`） | **33 tests** | TEST_VERIFIED |
| 安装器静态检查 | **36 scenarios / 168 assertions** | TEST_VERIFIED |
| 签名参数 | **58 checks** | TEST_VERIFIED |
| 发布载荷破坏测试 | **244 assertions**（含合成 fixture 构建） | TEST_VERIFIED |
| 安装事务 / 安装门禁 | `make test-install-transaction`、`make test-installer-gate` | TEST_VERIFIED |
| Protocol 布局与四份头副本 | `make protocol-check`、`tools/sync_shared_header.sh --check` | TEST_VERIFIED |

证据索引：[verification/](verification/)、[docs/1.2.0/](1.2.0/)。

---

## 5. 明确未验证的事项

下列事项**没有任何**真实环境证据。它们不是「大概没问题」，而是「还不知道」。

| 编号 | 未验证事项 | 说明 |
|---|---|---|
| **N-1** | **实际 EQ 听感** | 10 段参数均衡器的频响、相位与削波行为只经过数值与状态测试，没有人耳/测量验证。**不得**声称音质已通过。 |
| **N-2** | **播放窗口 underrun** | 低 buffer、高负载下的丢帧率与可听缺口未测量。`out_dropped` 可观测，但没有真实负载基线。 |
| **N-3** | **真实卸载/重装闭环** | 卸载策略由测试锁定，但「安装 → 播放 → 卸载 → 重装 → 恢复 EQ/音量」整条路径未在真实 macOS 上执行。 |
| N-4 | 真实 HAL 设备移除（播放中拔 HDMI/DP） | 未执行；`quarantine` 计数无实测值。 |
| N-5 | macOS 14.4 认证 | 当前只在 macOS 27.2.1 上运行过；14.4 未验证。 |
| N-6 | x86_64 真机运行 | 只有 universal 构建产物，未在 Intel 机器上运行。 |
| N-7 | 长时间稳定性（≥ 8 小时） | 未执行。 |
| N-8 | 多设备并发 / 热插拔矩阵 | 未执行。 |

完整登记见 [Known-Limitations](risks/Known-Limitations.md) 的 B 类（U-1 – U-13）与
D 类（P-1 – P-8）。

---

## 6. 已知限制（不影响本版本可安装）

- Sparkle 自动更新**未启用**：`SUPublicEDKey` 为空，updater 不初始化。请下载新 PKG 升级。
- 安装器不检查 App/Host 是否在运行：安装前请手动退出（P2-5）。
- DSP 采集侧测试计数器存在已知偏差（P2-1）：它不参与发布门禁，但读取该数字时需注意。
- Driver 侧 RT-1 – RT-5、Host 侧残余 RT 问题仍未处理完：可能导致真实负载下的爆音/卡顿，
  不影响内存安全。见 Known-Limitations C 类。
- 只支持 64 位；只支持 arm64 / x86_64；Float64 输入 fail-closed。

---

## 7. 安装与卸载

- 安装：`SoundBridge-1.2.0.pkg`（详见 [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md)）。
- 卸载：菜单栏 → **Uninstall Driver**，或 `tools/uninstall_driver.sh --dry-run` 先看计划。
- 两者都不会重启 `coreaudiod`；需要重新加载时由用户自己注销/重启或手动执行。

---

## 8. 发布结论

**当前结论：Pre-release，不具备「正式可用」声明条件。**

阻断项（见 [发布检查单](release/SoundBridge-1.2.0-Release-Checklist.md) §8）：

- 真实安装 / 卸载 / 播放未验证（N-3）
- 真实设备移除未验证（N-4）
- macOS 14.4 未认证（N-5）
- 实际 EQ 听感与播放窗口 underrun 未测量（N-1、N-2）

源码级与测试级的收敛已完成；真实环境验证是下一阶段的工作。在它完成之前，本文档
不会把任何 NOT_VERIFIED 项写成 PASS。
