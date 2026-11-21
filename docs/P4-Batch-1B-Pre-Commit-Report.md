# SoundBridge 1.2.0 — P4 Batch 1B Pre-Commit 报告

**阶段**：P4 Batch 1B / Pre-Commit 修订与授权门
**仓库**：`/path/to/SoundBridge`（Batch 1B 原文以 `$REPO` 占位并拒绝脱敏；Batch 1C 已授权脱敏，见文首修订记录）
**执行时间**：2026-11-21
**本阶段产物**：`.gitignore` 修复（5 处新增、1 处替换）+ 本报告 + `build/p4-batch1b/evidence/` 下 17 份只读证据/脚本
**Git 写操作**：**无**。`git diff --cached --name-only` 计数为 0，索引未被触碰。

> **Batch 1C 修订记录（2026-11-21）**
>
> 本文件是 P4 Batch 1B 的原始审计记录。以下内容在 Batch 1C 中被修订，修订点集中在此块，正文保留原文以便审计：
>
> 1. **§10.2 的计数自相矛盾，已更正。** 原文标题写"13 处"，但同表 10 行逐行相加为 16 处，两者都不对。Batch 1C 重做全量扫描，实测 allowlist 内仓库绝对路径为 **15 处 / 9 份文档**（`docs/1.2.0/POC_ERRATA.md` 命中 0 处仓库路径），另有 **3 处独立用户名残留**（不在仓库路径内）。
> 2. **原文"建议保持原样，不脱敏"的理由被证伪。** 该理由依赖"改写 1A 报告正文会让 §9.2 的哈希表失真"。实测：1A 报告 §9.2 的 18 行不含任何本次被脱敏的文档，且该表对本文件明确标注"内容变更后哈希随之变化，不固化"；§9.1 的 67 行只覆盖 tracked 文件，而本次被脱敏的 9 份全部是 untracked。因此脱敏不会使这两张表失真，也不需要连带重算。
> 3. **G-3 已由用户在 Batch 1C 授权执行。** 15 处仓库路径已替换为 `/path/to/SoundBridge`，命令语义与路径层级不变。原始哈希与脱敏后哈希分别记账于 `build/p4-batch1c/evidence/c1c-doc-hashes-original.tsv` 与 `final-document-hashes.tsv`，含用户名的原始文本不入库。
> 4. **正文中复述字面用户名的地方已改为"本地用户名"。** 公开仓库的文档没有理由在散文里再复述一次用户名；本文件现在 0 处仓库路径、0 处字面用户名。
> 5. **本文件不固化自己的哈希。** 本报告在 Batch 1C 中继续被编辑，其最终 SHA-256 只记录在独立 manifest `final-document-hashes.tsv`，正文不声明。
>
> 未修订的部分（§2 status 快照、§4 逐文件表、§8.3 三档归属、§9 链接检查、§10.3 / §10.4）仍是 Batch 1B 采集时点的事实，Batch 1C 未重跑；Batch 1C 的现状数据见 `docs/P4-Batch-1C-Commit-Authorization-Request.md`。

---

## 0. 结论速览

| # | 检查项 | 结论 | 证据位置 |
|---|---|---|---|
| 1 | `.gitignore` 修复是否生效 | **通过**。`docs/release/` 可见，`.qoder/` 被忽略 | §3 |
| 2 | 140 条 allowlist 是否与工作区一致 | **通过**。139 个存在 + 1 个预期缺失（删除项），状态与字节逐条对账，0 异常 | §4、§5 |
| 3 | 分类是否闭合（无未归类改动） | **通过**。未归类未跟踪 = 0；未列入的已跟踪改动 = 仅 `.gitignore`（必要项） | §5.3 |
| 4 | 删除项是否是有意变更 | **通过**。`DriverUpdateWindow.swift` 零存活引用 | §7 |
| 5 | 文档链接是否可用 | **通过**。144 条相对链接，0 断链（1 条为代码片段误判） | §9 |
| 6 | 敏感信息与二进制 | **通过**（1 项需用户决定）。无密钥/令牌；13 处绝对家目录路径（Batch 1C 更正：实测 15 处仓库路径 + 3 处独立用户名，见文首修订记录）；最大文件 76 KB | §10 |
| 7 | 版本 / 协议一致性 | **通过**。`VERSION_SOURCES_CHECKED=11 / FAILED=0`；协议 131584 | §10.4 |
| 8 | 是否具备提交条件 | **技术上具备**；需用户批准 6 个决策项（G-1–G-6，§15）后才可进入 Batch 1C | §15 |

**最终文件数量（三档，见 §14）**

| 口径 | 数量 | 构成 |
|---|---|---|
| 任务书原始目标 | 140 | A 55 + B 40 + C 12 + D 33（不含 `.gitignore` 本身） |
| 最小可提交集 | 141 | 140 + `.gitignore`（C-13） |
| **推荐：完整审计集** | **142** | 141 + 本报告（D-34） |

---

## 1. 当前 Git 身份与基线

| 项 | 值 |
|---|---|
| 分支 | `main` |
| HEAD | `ab3677072f0dcb54de27ba4dcabfd11e64ae41ec` |
| 上游 | `origin/main` |
| remote `origin` | `https://github.com/chenjy16/SoundBridge.git`（fetch / push） |
| Git 版本 | `git version 2.50.1`（支持 `--pathspec-from-file`） |
| submodule | `633e0f70203edd87d320fc5a3cae901e1363aac5 packages/driver/vendor/libASPL (v3.1.2-1-g633e0f7)` —— 无 `+`/`-` 前缀，指针未变 |
| VERSION | `1.2.0`（未修改） |
| 协议版本 | `0x00020200` = `131584`（未修改） |

基线证据：`build/p4-batch1b/evidence/b1b-branch.log`、`b1b-status-before.log`（修复前 137 行）、`b1b-status-after-gitignore.log`（修复后 138 行）。

**与 Batch 1A 基线的差异**：HEAD 未变（`ab36770`），工作区多了一项 `.gitignore` 修改（本阶段 §2.1 授权），其余 227 条路径状态与 1A 报告 §2 完全一致。

---

## 2. 当前完整 Git status

`git status --porcelain=v1` 采集时间 2026-11-21，共 **138 行**：**67 `M` + 1 `D` + 70 `??`**。

统计口径的变化（相对 1A 的 137 行）：

- `-1`：`?? .qoder/` 消失（已被 `.gitignore` 忽略）
- `+1`：`?? docs/release/` 出现（不再被误忽略）
- `+1`：` M .gitignore` 出现（本阶段修改）

未跟踪的 70 行中，目录级条目（`?? docs/engineering/` 等）在执行 `-uall` 展开后对应 **87 个文件**：allowlist 内 73 个 + E 类 14 个。

```
 M .gitignore
 M Makefile
 M README.md
 M apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift
 M apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
 M apps/mac/SoundBridgeApp/Sources/Models/HostLifecycleReport.swift
 M apps/mac/SoundBridgeApp/Sources/Models/HostStatusModel.swift
 M apps/mac/SoundBridgeApp/Sources/Onboarding/OnboardingView.swift
 M apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift
 M apps/mac/SoundBridgeApp/Sources/Services/DriverVersionGate.swift
 M apps/mac/SoundBridgeApp/Sources/Services/EQController.swift
 M apps/mac/SoundBridgeApp/Sources/Services/HostInstanceProbe.swift
 M apps/mac/SoundBridgeApp/Sources/Services/IPCController.swift
 M apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift
 D apps/mac/SoundBridgeApp/Sources/Views/DriverUpdateWindow.swift
 M apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverCompatibilityNoticeTests.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallBoundaryTests.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallIntentTests.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverRecoveryMatrixTests.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverVersionGateTests.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostInstanceProbeTests.swift
 M apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRunStateTests.swift
 M docs/INSTALLATION_GUIDE.md
 M docs/RELEASE_NOTES.md
 M packages/driver/CMakeLists.txt
 M packages/driver/Info.plist
 M packages/driver/include/RFSharedAudio.h
 M packages/driver/src/Plugin.cpp
 M packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
 M packages/host/Sources/CSoundBridgeAudio/include/module.modulemap
 M packages/host/Sources/CSoundBridgeAudio/shim.c
 M packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift
 M packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift
 M packages/host/Sources/SoundBridgeHost/Constants.swift
 M packages/host/Sources/SoundBridgeHost/Devices/DeviceDiscovery.swift
 M packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift
 M packages/host/Sources/SoundBridgeHost/Devices/DeviceRegistry.swift
 M packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift
 M packages/host/Sources/SoundBridgeHost/Devices/SleepWakeMonitor.swift
 M packages/host/Sources/SoundBridgeHost/Lifecycle/DriverLifecycle.swift
 M packages/host/Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift
 M packages/host/Sources/SoundBridgeHost/Lifecycle/HostLifecycleReporter.swift
 M packages/host/Sources/SoundBridgeHost/Lifecycle/ShutdownSequence.swift
 M packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift
 M packages/host/Sources/SoundBridgeHost/Services/VolumePersistence.swift
 M packages/host/Sources/SoundBridgeHost/Utilities/PathManager.swift
 M packages/host/Sources/SoundBridgeHost/main.swift
 M packages/host/Tests/SoundBridgeHostTests/AtomicMemoryModelTests.swift
 M packages/host/Tests/SoundBridgeHostTests/DegradedLifecycleTests.swift
 M packages/host/Tests/SoundBridgeHostTests/DriverHeartbeatCrossProcessTests.swift
 M packages/host/Tests/SoundBridgeHostTests/HostInstanceLockTests.swift
 M packages/host/Tests/SoundBridgeHostTests/SharedMemoryFileSystemTests.swift
 M packages/host/Tests/SoundBridgeHostTests/SharedMemoryMultiProcessTests.swift
 M packages/host/Tests/SoundBridgeHostTests/SharedMemoryProtocolTests.swift
 M packages/host/Tests/SoundBridgeHostTests/SharedMemoryRecoveryTests.swift
 M packages/host/Tests/SoundBridgeHostTests/StartupFailureCleanupTests.swift
 M packages/host/Tests/SoundBridgeHostTests/VolumeStateTests.swift
 M packages/shared/include/RFSharedAudio.h
 M tools/build_installer_pkg.sh
 M tools/check_protocol_layout.sh
 M tools/test_release_payload.sh
 M tools/uninstall_driver.sh
 M tools/verify_dmg_contents.sh
 M tools/verify_installer_pkg.sh
 M tools/verify_pkg_contents.sh
 M tools/verify_release_bundle.sh
 M tools/verify_release_payload.sh
?? apps/mac/SoundBridgeApp/Sources/Services/DefaultOutputSwitch.swift
?? apps/mac/SoundBridgeApp/Sources/Services/DriverInstallGuide.swift
?? apps/mac/SoundBridgeApp/Sources/Services/DriverUninstallPolicy.swift
?? apps/mac/SoundBridgeApp/Sources/Services/DriverUninstaller.swift
?? apps/mac/SoundBridgeApp/Sources/Services/EQService.swift
?? apps/mac/SoundBridgeApp/Sources/Services/HostRestartEntry.swift
?? apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift
?? apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DefaultOutputSwitchTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQLifecycleOwnershipTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQRecoveryTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRestartEntryTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostSupervisorTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingConcurrencyTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingManagerTests.swift
?? apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingUnmapThreadTests.swift
?? docs/1.2.0/
?? docs/Documentation-Migration-Manifest.md
?? docs/P1-Product-Integration-Release-Readiness-Audit.md
?? docs/P2-Batch-2-Default-Output-Governance-Report.md
?? docs/P2-Batch-3-EQ-Mapping-Reliability-Report.md
?? docs/P2-Batch-4-AudioRenderer-RT-Safety-Report.md
?? docs/P2-Batch1-Test-Infrastructure-Report.md
?? docs/P3-0-Real-MacOS-Environment-Audit.md
?? docs/P3-0-Workspace-Baseline.md
?? docs/P3-Batch-1-Release-Build-Verification-Report.md
?? docs/P3-Batch-1.5-Implementation-Report.md
?? docs/P3-Batch-1.5-Mapping-Observability-Audit.md
?? docs/P3-Batch-1.5-RT-Observability-Audit.md
?? docs/P3-Batch-1.5-Release-Rebuild-Verification.md
?? docs/P3-Final-Closure-Fix-Report.md
?? docs/P3-Final-Rebuild-Install-Host-Restart-Validation-Report.md
?? docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md
?? docs/P3-Real-MacOS-Validation-Authorization-Matrix.md
?? docs/P3-Real-MacOS-Validation-Plan.md
?? docs/P4-Batch-1A-Source-Stabilization-Report.md
?? docs/P4-Release-Readiness-Audit-Report.md
?? docs/README.md
?? docs/Research-Directory-Retirement-Report.md
?? docs/architecture/
?? docs/engineering/
?? docs/manifests/
?? docs/release/
?? docs/risks/
?? docs/verification/
?? packages/driver/src/ControlProtocol.hpp
?? packages/driver/src/MappingRetirement.hpp
?? packages/driver/src/ProducerToken.hpp
?? packages/driver/tests/
?? packages/host/Sources/CSoundBridgeAudio/RFRealtimeTelemetry.c
?? packages/host/Sources/CSoundBridgeAudio/include/RFRealtimeTelemetry.h
?? packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputHAL.swift
?? packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputOwnership.swift
?? packages/host/Sources/SoundBridgeHost/Lifecycle/CoreAudioRecovery.swift
?? packages/host/Sources/SoundBridgeHost/Lifecycle/CoreAudioRestartDetector.swift
?? packages/host/Sources/SoundBridgeHost/Lifecycle/SharedMemoryReportPolicy.swift
?? packages/host/Sources/SoundBridgeHost/Utilities/AtomicFileWriter.swift
?? packages/host/Tests/SoundBridgeHostTests/AdmissionCrossProcessTests.swift
?? packages/host/Tests/SoundBridgeHostTests/AdmissionGatewayTests.swift
?? packages/host/Tests/SoundBridgeHostTests/AtomicFileWriterTests.swift
?? packages/host/Tests/SoundBridgeHostTests/AudioRendererRTSafetyTests.swift
?? packages/host/Tests/SoundBridgeHostTests/CoreAudioRestartRecoveryTests.swift
?? packages/host/Tests/SoundBridgeHostTests/DefaultOutputGovernanceTests.swift
?? packages/host/Tests/SoundBridgeHostTests/DefaultOutputTrackingTests.swift
?? packages/host/Tests/SoundBridgeHostTests/GracefulShutdownTests.swift
?? packages/host/Tests/SoundBridgeHostTests/LifecycleLoggingTests.swift
?? packages/host/Tests/SoundBridgeHostTests/MappingIncarnationTests.swift
?? packages/host/Tests/SoundBridgeHostTests/RTObservabilityTests.swift
?? packages/host/Tests/SoundBridgeHostTests/RingBufferContractTests.swift
?? tools/test_support/
```

---

## 3. `.gitignore` 修复

### 3.1 修改前后 SHA-256

| 状态 | SHA-256 | 字节 |
|---|---|---|
| 修改前（= HEAD 版本） | `d5ac0bfa9ce901ebb00afc6e201085768f8276c9e5f4d86d649585e68c2127c9` | 1391 |
| 修改后 | `dbb3ac36434000e39a9a98b9d0d3bca5fb6c7fd65a3fe2d911a797206d90aedf` | 1608 |

修改前的工作区版本与 `git show HEAD:.gitignore` 哈希完全相同，因此下表的 diff 也等于相对 HEAD 的差异（`git diff` 与 `git diff HEAD` 等价）。

### 3.2 diff

```diff
diff --git a/.gitignore b/.gitignore
index 0c5be84..984bef7 100644
--- a/.gitignore
+++ b/.gitignore
@@ -97,6 +97,8 @@ logs/
 .vscode/
 .idea/
 .kiro/
+# Qoder's local repowiki cache; generated, never part of the release.
+.qoder/
 *.swp
 *.swo
 *~
@@ -117,7 +119,9 @@ temp/

 # Build artifacts
 dist/
-release/
+# Root-level release output only. The unanchored `release/` also matched
+# docs/release/, which silently hid the 1.2.0 release checklist.
+/release/
 *.dmg
 *.pkg
 *.app
```

`git diff` 原文：`build/p4-batch1b/evidence/b1b-gitignore.diff`。

### 3.3 只做了这两件事，没有别的

| 改动 | 效果 | 回归风险 |
|---|---|---|
| `release/` → `/release/` | 只忽略仓库根的 `release/`；`docs/release/` 恢复被跟踪 | 低。仓库根当前无 `release/` 目录；根级产物目录若将来创建，仍被忽略 |
| 新增 `.qoder/` | Qoder repowiki 缓存不再污染 `git status` | 低。纯生成物，源码零引用 |

两处都加了英文注释说明原因，防止后续又有人把它"简化"回去（该注释风格与文件内既有 `# Build artifacts` 等段落注释一致）。

### 3.4 效果验证

| 验证 | 命令 | 结果 |
|---|---|---|
| Checklist 不再被忽略 | `git check-ignore -v docs/release/SoundBridge-1.2.0-Release-Checklist.md` | 退出码 **1**（不匹配任何忽略规则） |
| Checklist 可被 Git 识别 | `git status --porcelain -uall docs/release/` | `?? docs/release/SoundBridge-1.2.0-Release-Checklist.md` |
| `.qoder/` 被忽略 | `git check-ignore -v .qoder/repowiki/zh/meta/repowiki-metadata.json` | `.gitignore:101:.qoder/`（命中） |
| `.qoder/` 内容未删除 | `ls .qoder/repowiki/` | 目录仍在（75 个文件） |
| 根级 `release/` 仍被忽略 | 规则 `/release/` 仍存在 | 语义保持 |

---

## 4. 140 个目标文件的完整逐文件清单

下表由脚本从 `build/p4-batch1b/evidence/b1b-allowlist.tsv` 机械导出（不是手抄），`状态` 取自 `git status --porcelain -z` 的原始 XY 码；`??(dir)` 表示该文件所在的整个目录未被跟踪，Git 在 `status` 中折叠为一条目录条目。

校验脚本：`build/p4-batch1b/evidence/verify_allowlist.py`，输出 `b1b-allowlist-verify.log`，结论 `total 140 / count_A 55 / count_B 40 / count_C 12 / count_D 33 / problems 0`。

| # | 组 | 状态 | 字节 | 路径 |
|---|---|---|---|---|
| 1 | A | ` M` | 39802 | `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift` |
| 2 | A | ` M` | 69590 | `apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h` |
| 3 | A | ` M` | 8112 | `apps/mac/SoundBridgeApp/Sources/Models/HostLifecycleReport.swift` |
| 4 | A | ` M` | 3138 | `apps/mac/SoundBridgeApp/Sources/Models/HostStatusModel.swift` |
| 5 | A | ` M` | 16441 | `apps/mac/SoundBridgeApp/Sources/Onboarding/OnboardingView.swift` |
| 6 | A | `??` | 3629 | `apps/mac/SoundBridgeApp/Sources/Services/DefaultOutputSwitch.swift` |
| 7 | A | `??` | 4051 | `apps/mac/SoundBridgeApp/Sources/Services/DriverInstallGuide.swift` |
| 8 | A | ` M` | 3707 | `apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift` |
| 9 | A | `??` | 4323 | `apps/mac/SoundBridgeApp/Sources/Services/DriverUninstallPolicy.swift` |
| 10 | A | `??` | 3052 | `apps/mac/SoundBridgeApp/Sources/Services/DriverUninstaller.swift` |
| 11 | A | ` M` | 15500 | `apps/mac/SoundBridgeApp/Sources/Services/DriverVersionGate.swift` |
| 12 | A | ` M` | 19740 | `apps/mac/SoundBridgeApp/Sources/Services/EQController.swift` |
| 13 | A | `??` | 2360 | `apps/mac/SoundBridgeApp/Sources/Services/EQService.swift` |
| 14 | A | ` M` | 5960 | `apps/mac/SoundBridgeApp/Sources/Services/HostInstanceProbe.swift` |
| 15 | A | `??` | 3495 | `apps/mac/SoundBridgeApp/Sources/Services/HostRestartEntry.swift` |
| 16 | A | `??` | 27231 | `apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift` |
| 17 | A | ` M` | 15413 | `apps/mac/SoundBridgeApp/Sources/Services/IPCController.swift` |
| 18 | A | `??` | 28466 | `apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift` |
| 19 | A | ` M` | 25312 | `apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift` |
| 20 | A | ` D` | — | `apps/mac/SoundBridgeApp/Sources/Views/DriverUpdateWindow.swift` |
| 21 | A | ` M` | 21981 | `apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift` |
| 22 | A | ` M` | 1449 | `packages/driver/Info.plist` |
| 23 | A | ` M` | 69590 | `packages/driver/include/RFSharedAudio.h` |
| 24 | A | `??` | 14334 | `packages/driver/src/ControlProtocol.hpp` |
| 25 | A | `??` | 15039 | `packages/driver/src/MappingRetirement.hpp` |
| 26 | A | ` M` | 76690 | `packages/driver/src/Plugin.cpp` |
| 27 | A | `??` | 2471 | `packages/driver/src/ProducerToken.hpp` |
| 28 | A | `??` | 13556 | `packages/host/Sources/CSoundBridgeAudio/RFRealtimeTelemetry.c` |
| 29 | A | `??` | 12941 | `packages/host/Sources/CSoundBridgeAudio/include/RFRealtimeTelemetry.h` |
| 30 | A | ` M` | 69590 | `packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h` |
| 31 | A | ` M` | 143 | `packages/host/Sources/CSoundBridgeAudio/include/module.modulemap` |
| 32 | A | ` M` | 581 | `packages/host/Sources/CSoundBridgeAudio/shim.c` |
| 33 | A | ` M` | 15208 | `packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift` |
| 34 | A | ` M` | 33547 | `packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift` |
| 35 | A | ` M` | 5281 | `packages/host/Sources/SoundBridgeHost/Constants.swift` |
| 36 | A | `??` | 6170 | `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputHAL.swift` |
| 37 | A | `??` | 4822 | `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputOwnership.swift` |
| 38 | A | ` M` | 19982 | `packages/host/Sources/SoundBridgeHost/Devices/DeviceDiscovery.swift` |
| 39 | A | ` M` | 30358 | `packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift` |
| 40 | A | ` M` | 10882 | `packages/host/Sources/SoundBridgeHost/Devices/DeviceRegistry.swift` |
| 41 | A | ` M` | 37071 | `packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift` |
| 42 | A | ` M` | 3470 | `packages/host/Sources/SoundBridgeHost/Devices/SleepWakeMonitor.swift` |
| 43 | A | `??` | 13115 | `packages/host/Sources/SoundBridgeHost/Lifecycle/CoreAudioRecovery.swift` |
| 44 | A | `??` | 7080 | `packages/host/Sources/SoundBridgeHost/Lifecycle/CoreAudioRestartDetector.swift` |
| 45 | A | ` M` | 17289 | `packages/host/Sources/SoundBridgeHost/Lifecycle/DriverLifecycle.swift` |
| 46 | A | ` M` | 14086 | `packages/host/Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift` |
| 47 | A | ` M` | 5829 | `packages/host/Sources/SoundBridgeHost/Lifecycle/HostLifecycleReporter.swift` |
| 48 | A | `??` | 2683 | `packages/host/Sources/SoundBridgeHost/Lifecycle/SharedMemoryReportPolicy.swift` |
| 49 | A | ` M` | 4842 | `packages/host/Sources/SoundBridgeHost/Lifecycle/ShutdownSequence.swift` |
| 50 | A | ` M` | 37506 | `packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift` |
| 51 | A | ` M` | 4144 | `packages/host/Sources/SoundBridgeHost/Services/VolumePersistence.swift` |
| 52 | A | `??` | 7413 | `packages/host/Sources/SoundBridgeHost/Utilities/AtomicFileWriter.swift` |
| 53 | A | ` M` | 2325 | `packages/host/Sources/SoundBridgeHost/Utilities/PathManager.swift` |
| 54 | A | ` M` | 48627 | `packages/host/Sources/SoundBridgeHost/main.swift` |
| 55 | A | ` M` | 69590 | `packages/shared/include/RFSharedAudio.h` |
| 56 | B | `??` | 10426 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DefaultOutputSwitchTests.swift` |
| 57 | B | ` M` | 11908 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverCompatibilityNoticeTests.swift` |
| 58 | B | ` M` | 13960 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallBoundaryTests.swift` |
| 59 | B | ` M` | 5156 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallIntentTests.swift` |
| 60 | B | ` M` | 11892 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverRecoveryMatrixTests.swift` |
| 61 | B | ` M` | 19974 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverVersionGateTests.swift` |
| 62 | B | `??` | 20773 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQLifecycleOwnershipTests.swift` |
| 63 | B | `??` | 10883 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQRecoveryTests.swift` |
| 64 | B | ` M` | 7758 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostInstanceProbeTests.swift` |
| 65 | B | `??` | 8254 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRestartEntryTests.swift` |
| 66 | B | ` M` | 24124 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRunStateTests.swift` |
| 67 | B | `??` | 18537 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostSupervisorTests.swift` |
| 68 | B | `??` | 25678 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingConcurrencyTests.swift` |
| 69 | B | `??` | 19691 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingManagerTests.swift` |
| 70 | B | `??` | 12112 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingUnmapThreadTests.swift` |
| 71 | B | `??(dir)` | 15008 | `packages/driver/tests/ControlProtocolTests.cpp` |
| 72 | B | `??(dir)` | 34549 | `packages/driver/tests/MappingRetirementTests.cpp` |
| 73 | B | `??(dir)` | 6140 | `packages/driver/tests/ProducerTokenTests.cpp` |
| 74 | B | `??` | 21465 | `packages/host/Tests/SoundBridgeHostTests/AdmissionCrossProcessTests.swift` |
| 75 | B | `??` | 23666 | `packages/host/Tests/SoundBridgeHostTests/AdmissionGatewayTests.swift` |
| 76 | B | `??` | 21508 | `packages/host/Tests/SoundBridgeHostTests/AtomicFileWriterTests.swift` |
| 77 | B | ` M` | 22976 | `packages/host/Tests/SoundBridgeHostTests/AtomicMemoryModelTests.swift` |
| 78 | B | `??` | 24512 | `packages/host/Tests/SoundBridgeHostTests/AudioRendererRTSafetyTests.swift` |
| 79 | B | `??` | 43752 | `packages/host/Tests/SoundBridgeHostTests/CoreAudioRestartRecoveryTests.swift` |
| 80 | B | `??` | 26526 | `packages/host/Tests/SoundBridgeHostTests/DefaultOutputGovernanceTests.swift` |
| 81 | B | `??` | 9470 | `packages/host/Tests/SoundBridgeHostTests/DefaultOutputTrackingTests.swift` |
| 82 | B | ` M` | 14739 | `packages/host/Tests/SoundBridgeHostTests/DegradedLifecycleTests.swift` |
| 83 | B | ` M` | 17456 | `packages/host/Tests/SoundBridgeHostTests/DriverHeartbeatCrossProcessTests.swift` |
| 84 | B | `??` | 6240 | `packages/host/Tests/SoundBridgeHostTests/GracefulShutdownTests.swift` |
| 85 | B | ` M` | 28781 | `packages/host/Tests/SoundBridgeHostTests/HostInstanceLockTests.swift` |
| 86 | B | `??` | 12929 | `packages/host/Tests/SoundBridgeHostTests/LifecycleLoggingTests.swift` |
| 87 | B | `??` | 9302 | `packages/host/Tests/SoundBridgeHostTests/MappingIncarnationTests.swift` |
| 88 | B | `??` | 25215 | `packages/host/Tests/SoundBridgeHostTests/RTObservabilityTests.swift` |
| 89 | B | `??` | 22356 | `packages/host/Tests/SoundBridgeHostTests/RingBufferContractTests.swift` |
| 90 | B | ` M` | 19747 | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryFileSystemTests.swift` |
| 91 | B | ` M` | 19367 | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryMultiProcessTests.swift` |
| 92 | B | ` M` | 13717 | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryProtocolTests.swift` |
| 93 | B | ` M` | 15960 | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryRecoveryTests.swift` |
| 94 | B | ` M` | 5624 | `packages/host/Tests/SoundBridgeHostTests/StartupFailureCleanupTests.swift` |
| 95 | B | ` M` | 12698 | `packages/host/Tests/SoundBridgeHostTests/VolumeStateTests.swift` |
| 96 | C | ` M` | 20348 | `Makefile` |
| 97 | C | ` M` | 4515 | `packages/driver/CMakeLists.txt` |
| 98 | C | ` M` | 25650 | `tools/build_installer_pkg.sh` |
| 99 | C | ` M` | 8760 | `tools/check_protocol_layout.sh` |
| 100 | C | ` M` | 54724 | `tools/test_release_payload.sh` |
| 101 | C | `??(dir)` | 6620 | `tools/test_support/make_payload_fixture.sh` |
| 102 | C | ` M` | 5457 | `tools/uninstall_driver.sh` |
| 103 | C | ` M` | 29522 | `tools/verify_dmg_contents.sh` |
| 104 | C | ` M` | 24561 | `tools/verify_installer_pkg.sh` |
| 105 | C | ` M` | 26186 | `tools/verify_pkg_contents.sh` |
| 106 | C | ` M` | 12330 | `tools/verify_release_bundle.sh` |
| 107 | C | ` M` | 18550 | `tools/verify_release_payload.sh` |
| 108 | D | ` M` | 15264 | `README.md` |
| 109 | D | `??(dir)` | 39896 | `docs/1.2.0/PHASE2_IMPLEMENTATION_PLAN.md` |
| 110 | D | `??(dir)` | 17043 | `docs/1.2.0/PHASE2_1_1_AND_2_1_2_REPORT.md` |
| 111 | D | `??(dir)` | 36715 | `docs/1.2.0/PHASE2_1_3_RELEASE_READINESS_REPORT.md` |
| 112 | D | `??(dir)` | 38486 | `docs/1.2.0/PHASE2_1_4_HOST_LIFECYCLE_REPORT.md` |
| 113 | D | `??(dir)` | 53586 | `docs/1.2.0/PHASE2_1_5_FINAL_RELIABILITY_AUDIT.md` |
| 114 | D | `??(dir)` | 36792 | `docs/1.2.0/PHASE2_1_REPORT.md` |
| 115 | D | `??(dir)` | 15920 | `docs/1.2.0/POC_ERRATA.md` |
| 116 | D | `??` | 25920 | `docs/Documentation-Migration-Manifest.md` |
| 117 | D | ` M` | 15025 | `docs/INSTALLATION_GUIDE.md` |
| 118 | D | `??` | 36573 | `docs/P2-Batch-2-Default-Output-Governance-Report.md` |
| 119 | D | `??` | 38481 | `docs/P2-Batch-3-EQ-Mapping-Reliability-Report.md` |
| 120 | D | `??` | 48809 | `docs/P2-Batch-4-AudioRenderer-RT-Safety-Report.md` |
| 121 | D | `??` | 45432 | `docs/P3-Final-Closure-Fix-Report.md` |
| 122 | D | `??` | 54754 | `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md` |
| 123 | D | `??` | 74476 | `docs/P4-Batch-1A-Source-Stabilization-Report.md` |
| 124 | D | `??` | 46009 | `docs/P4-Release-Readiness-Audit-Report.md` |
| 125 | D | `??` | 11801 | `docs/README.md` |
| 126 | D | ` M` | 12691 | `docs/RELEASE_NOTES.md` |
| 127 | D | `??(dir)` | 18207 | `docs/architecture/SoundBridge-1.2.0-Architecture.md` |
| 128 | D | `??(dir)` | 9731 | `docs/engineering/Admission-Ownership.md` |
| 129 | D | `??(dir)` | 7913 | `docs/engineering/Callback-Lifecycle.md` |
| 130 | D | `??(dir)` | 16183 | `docs/engineering/CallbackGate-Memory-Model.md` |
| 131 | D | `??(dir)` | 9588 | `docs/engineering/Mapping-Retirement.md` |
| 132 | D | `??(dir)` | 7484 | `docs/engineering/RingBuffer-Design.md` |
| 133 | D | `??(dir)` | 10309 | `docs/engineering/SharedMemory-Lifecycle.md` |
| 134 | D | `??(dir)` | 9039 | `docs/release/SoundBridge-1.2.0-Release-Checklist.md` |
| 135 | D | `??(dir)` | 16168 | `docs/risks/Known-Limitations.md` |
| 136 | D | `??(dir)` | 5880 | `docs/verification/Batch-0-1-Verification.md` |
| 137 | D | `??(dir)` | 6576 | `docs/verification/Batch-2-Closure-Verification.md` |
| 138 | D | `??(dir)` | 6399 | `docs/verification/Batch-2-Verification.md` |
| 139 | D | `??(dir)` | 27036 | `docs/verification/Batch-3-Closure-Fix.md` |
| 140 | D | `??(dir)` | 6761 | `docs/verification/Batch-3-Verification.md` |

### 4.1 状态分布（实测）

| 组 | `M` | `??` | `??(dir)` | `D` | 合计 |
|---|---|---|---|---|---|
| A | 35 | 19 | 0 | 1 | 55 |
| B | 17 | 20 | 3 | 0 | 40 |
| C | 11 | 0 | 1 | 0 | 12 |
| D | 3 | 9 | 21 | 0 | 33 |
| **合计** | **66** | **48** | **25** | **1** | **140** |

`M 66 + D 1 = 67` 与 §2 的已跟踪改动数一致；`?? 48 + 目录内文件展开 25 = 73` 与 §2 的 87 − 14（E 类）一致。

---

## 5. A / B / C / D 分类统计

### 5.1 组内构成

| 组 | 数量 | 构成 |
|---|---|---|
| **A 生产代码** | 55 | App 21（含 1 删除）+ Driver 6 + Host 27 + Shared 头 1 |
| **B 测试** | 40 | App 测试 15 + Host 测试 22 + Driver 测试 3 |
| **C 构建与工具** | 12 | `Makefile` 1 + `packages/driver/CMakeLists.txt` 1 + `tools/` 10 |
| **D 文档** | 33 | 面向用户 3 + 风险/门禁 2 + 批次报告 7 + 架构工程验证 12 + 历史 1.2.0 文档 7 + 文档索引 2 |

D 组明细：面向用户 = `README.md`、`docs/INSTALLATION_GUIDE.md`、`docs/RELEASE_NOTES.md`；风险门禁 = `docs/risks/Known-Limitations.md`、`docs/release/SoundBridge-1.2.0-Release-Checklist.md`；批次报告 = `P4-Batch-1A`、`P2-Batch-2/3/4`、`P3-Final-Closure-Fix`、`P3-Host-Restart-...`、`P4-Release-Readiness-Audit`；架构工程验证 = `architecture/` 1 + `engineering/` 6 + `verification/` 5；历史 = `docs/1.2.0/` 7；索引 = `docs/README.md`、`docs/Documentation-Migration-Manifest.md`。

### 5.2 内容核对方式

逐条核对了三件事，任何一项不符即报错（当前 0 报错）：

1. **路径存在**（`DriverUpdateWindow.swift` 例外：预期不存在且状态必须是 `D`）
2. **状态与预期一致**（`M` / `??` / `??(dir)` / `D`）
3. **大小合理**（无 `> 1 MB` 条目；最大 76,690 字节 = `packages/driver/src/Plugin.cpp`）

### 5.3 集合闭合性（关键）

用集合运算而非逐条目视来证明"没有漏也没有多"：

| 检查 | 结果 |
|---|---|
| 已跟踪改动（`M`/`D`）未进入 allowlist | **1**：`.gitignore` —— 唯一且为必要项（§14） |
| 未跟踪文件既不在 allowlist 也不在 E 类 | **0** |
| allowlist 中状态不符（既不 `M` 也不 `??`） | **0** |
| E 类中不存在的路径 | **0** |
| 未跟踪总数 | 87 = allowlist 73 + E 14 |

证据：`build/p4-batch1b/evidence/b1b-set-closure.log`。

**这条结论的含义**：工作区里不存在"来历不明、既没被分类也没被排除"的文件。这是本阶段能给出的最强分类保证；它不等于"证明这些改动都出自批次工作"（见 §8）。

---

## 6. E 类排除清单

### 6.1 E-1：`.qoder/` —— 75 个文件（1 个目录）

| 项 | 值 |
|---|---|
| 路径 | `.qoder/repowiki/`（`knowledge/zh/` + `zh/` + `meta/`） |
| 性质 | Qoder IDE 生成的仓库知识缓存，纯派生物 |
| 处置 | **不提交**；`.gitignore` 已新增 `.qoder/`；**内容不删除** |
| 验证 | `git ls-files --others --exclude-standard | grep -c '^\.qoder/'` = 0 |

### 6.2 E-2：14 份历史阶段报告（不提交）

| # | 路径 | 性质 |
|---|---|---|
| 1 | `docs/P1-Product-Integration-Release-Readiness-Audit.md` | P1 审计 |
| 2 | `docs/P2-Batch1-Test-Infrastructure-Report.md` | P2 批 1 |
| 3 | `docs/P3-0-Real-MacOS-Environment-Audit.md` | P3-0 环境审计 |
| 4 | `docs/P3-0-Workspace-Baseline.md` | P3-0 基线 |
| 5 | `docs/P3-Batch-1-Release-Build-Verification-Report.md` | P3 批 1 |
| 6 | `docs/P3-Batch-1.5-Implementation-Report.md` | P3 批 1.5 |
| 7 | `docs/P3-Batch-1.5-Mapping-Observability-Audit.md` | P3 批 1.5 |
| 8 | `docs/P3-Batch-1.5-RT-Observability-Audit.md` | P3 批 1.5 |
| 9 | `docs/P3-Batch-1.5-Release-Rebuild-Verification.md` | P3 批 1.5 |
| 10 | `docs/P3-Final-Rebuild-Install-Host-Restart-Validation-Report.md` | P3 终验 |
| 11 | `docs/P3-Real-MacOS-Validation-Plan.md` | P3 计划 |
| 12 | `docs/P3-Real-MacOS-Validation-Authorization-Matrix.md` | P3 授权矩阵 |
| 13 | `docs/Research-Directory-Retirement-Report.md` | Research 目录退役 |
| 14 | `docs/manifests/Research-Directory-Inventory.sha256` | Research 清单哈希 |

**为什么不提交**：这 14 份是"过程取证"，其中 1、3、6–14 描述的是**已被后续批次取代的中间状态**（例如 P3-0-Workspace-Baseline 记录的 HEAD 与当前不同，P3-Batch-1.5 的构建产物已被 1.2.0 重建覆盖）。把它们和 1.2.0 源码放在同一个 commit 里，会让读者把过期结论当成 1.2.0 的结论——这正是 1.2.0 文档必须"重写而非恢复"（Batch 1A §6）的同一条理由。

**处置**：保留在工作区，不删除、不移动、不加入 `.gitignore`。提交后它们会以 14 条 `??` 继续存在（见 §12），这是有意保留的可见状态，便于后续决定归档方式。

### 6.3 明确排除的其他类别

| 类别 | 排除依据 |
|---|---|
| `dist/`（1.1.1 与 1.2.0 产物、`.app`、`.dmg`、`.pkg`） | 发布产物，`dist/` 已忽略；本阶段未触碰（mtime 仍为 11-17 / 11-21 13:2x） |
| `build/`（含 `p4-batch1a/`、`p4-batch1b/evidence/`） | 构建与取证目录，已忽略 |
| `*.log` / `*.dmg` / `*.pkg` / `*.app` | 已忽略，且 allowlist 中 0 命中 |
| submodule `packages/driver/vendor/libASPL` | 指针未变，无改动 |

---

## 7. 删除项核对：`Views/DriverUpdateWindow.swift`

### 7.1 事实

| 项 | 值 |
|---|---|
| 路径 | `apps/mac/SoundBridgeApp/Sources/Views/DriverUpdateWindow.swift` |
| 原大小 | 87 行（据 `docs/1.2.0/PHASE2_1_4_HOST_LIFECYCLE_REPORT.md:318`） |
| Git 状态 | ` D`（已跟踪文件在工作区缺失，删除尚未暂存） |
| HEAD 版本 SHA-256 前 12 位 | `784f7db881cb`（1A 报告 §9.1 记录，AFTER = `ABSENT`） |
| 是否恢复 | **否**（任务要求：不恢复） |
| 是否删除其他文件 | **否**（工作区唯一删除项） |

### 7.2 删除原因（传承关系可追溯）

该窗口的唯一职能是 App 内"升级驱动"：`PHASE2_1_4` 审计（`:317-318`）记录 `performDriverUpdate()` 仅由 `DriverUpdateWindow.onUpdate` 引用、"不可达"；`PHASE2_1_5`（`:461`）把"软件内 Upgrade 按钮"列为第 1 项待清理；`PHASE2_1_3`（`:120`）当时决定"保留，不删除（先分析调用关系）"。

Batch 1A 的 P1-1 修复把安装收敛为"仅引导用户打开正式 PKG"，App 内不再有第二套安装路径，于是这个窗口失去了存在理由，随 `DriverInstaller` 的非事务安装代码一起删除（1A 报告 §3.5、§9.1 第 6 行）。

### 7.3 依赖影响（实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| 存活代码是否引用 | `grep -rn 'DriverUpdateWindow' --include='*.swift'` | **0 处**（仅测试内出现 `showDriverUpdatePrompt` 的**否定断言**） |
| 测试是否依赖其存在 | `DriverInstallBoundaryTests.swift:143` | 断言 `showDriverUpdatePrompt` 等字符串**不得出现**，删除后仍应通过（1A 实测 253 项通过） |
| 文档是否误引用为"现存" | `grep -rn 'DriverUpdateWindow' docs/` | 命中全部是"已删除/不可达"的历史描述（`PHASE2_1_4/1_2_1_3/1_2_1_5`）与 1A 报告清单，无一处当作现存文件 |
| 编译是否受影响 | 1A 的 `make test-app`（253 项）+ `make test-host`（379 项）在同一工作区通过 | 无影响 |

*结论**：删除是有意变更，且是 P1-1 收敛的必要一环；**不恢复**。

---

## 8. 用户修改归属判定

### 8.1 先说清方法学边界

任务书要求"不要把『能解释为某批次工作』当成『必然没有用户个人修改』"。这条要求在本仓库是**结构性无法完全满足**的，原因是硬性的：

- 这些改动**从未提交**，Git 里没有任何 author / timestamp / commit message 可查；
- `git diff` 只给出"当前内容与 HEAD 的差异"，不给出"谁改的、分几次改的"；
- 文件 mtime 只能证明"最后一次写入时间"，不能证明"内容全部来自那时"，也无法区分同一时刻的两个人。

因此下文所有"归属"都是**相关性推断**（内容范围 ∧ 修改时间 ∧ 同批次文档三方吻合），**不构成作者证明**。凡属推断的地方，本文都用"可归因"而不是"确认为"来表述。

### 8.2 时间聚类（实测 mtime）

| 最后修改日 | 文件数 | 主要构成 | 关联文档 |
|---|---|---|---|
| 2026-11-16 | 7 | 全部是 `docs/1.2.0/` 的 Phase 2.1 阶段文档 | `PHASE2_1_REPORT` 等 7 份自身 |
| 2026-11-17 | 4 | `Models/HostLifecycleReport.swift`、`Models/HostStatusModel.swift`、`tools/build_installer_pkg.sh`、`tools/verify_installer_pkg.sh` | `PHASE2_1_4_HOST_LIFECYCLE_REPORT` |
| 2026-11-18 | 16 | `HostInstanceProbe`、`IPCController`、driver `ControlProtocol.hpp`、`DeviceDiscovery/Registry/SleepWakeMonitor`、`CoreAudioRecovery/RestartDetector`、`HostInstanceLock`、`VolumePersistence` + 6 个测试 | `PHASE2_2_*`、`PHASE_3_*` |
| 2026-11-20 | 78 | P2 三批主体：Default Output Governance、EQ Mapping Reliability、AudioRenderer RT Safety（含 3 份 `RFSharedAudio.h` 与 `Plugin.cpp`、`MappingRetirement.hpp`、`ProducerToken.hpp`） | `P2-Batch-2/3/4` 报告 |
| 2026-11-21 | 34 | P3 Final Closure + Host Restart 入口 + P4 1A 收敛（含 18 个 1A 交付物） | `P3-Final-Closure-Fix`、`P3-Host-Restart-...`、`P4-Batch-1A` |
| 无（已删除） | 1 | `Views/DriverUpdateWindow.swift` | §7 |

原始数据：`build/p4-batch1b/evidence/b1b-attribution.log`（逐文件 group / mtime / status / marker / path）。

**读法**：11-21 的 34 个里有 18 个是本会话明确交付物（1A 报告 §8 逐条列明），另 16 个（P3 收尾与 P4 审计文档及其同批源码）与同日文档内容自洽。

### 8.3 逐文件归属，按证据强度分三档

| 档 | 数量 | 判据 | 需要用户确认 |
|---|---|---|---|
| **强**：1A 报告 §8 逐条记录 | **18** | 每行都有"目的 + 对应问题 + 前后字节数"，且本会话内有对应的 Write/SearchReplace 工具调用记录 | 否 |
| **中**：仅批次相关性可归因 | **122** | 差异内容与同批次报告描述吻合 ∧ mtime 落在该批次时间窗内 ∧ 文件职责与报告范围一致；但**没有逐条改动记录** | **是（形式确认）** |
| **弱**：无法归因 | **0** | — | — |
| 合计 | 140 | | |

强档 18 个已由 `docs/P4-Batch-1A-Source-Stabilization-Report.md` §8 逐行列出（含 1A 报告自身，故本报告不算新增强档证据）。

"**形式确认**"的含义：中档 122 个不需要重新逐个审查，只需用户回一句"P2-2 / P2-3 / P2-4 / P3 收尾这几轮里没有我自己私下加的实验性改动"。这句话我无法替你给出——这正是任务书 §2.4 要求保留的那个不确定性，不被任何自动化检查消除。

### 8.4 反向排查：有没有"看起来不属于本项目"的内容

对全部 140 个文件做了机械化扫描（`attribution_scan.py`），关键词：`TODO`、`FIXME`、`HACK`、`XXX`、`#warning`、`localhost`、`127.0.0.1`、本地用户名（字面值不在此复述）。

| 命中 | 文件 | 判定 |
|---|---|---|
| `XXX` × 9 | `Makefile:170`、`tools/build_installer_pkg.sh:153`、`ControlProtocolTests.cpp:226/236/266`、`tools/verify_*.sh` | **误报**：全部是 `mktemp` 模板 `XXXXXX` |
| `TODO` × 1 | `docs/Documentation-Migration-Manifest.md:252` | **误报**：正文讨论"仍在TODO的错觉"，不是待办标记 |
| `FIXME` / `HACK` / `#warning` / `localhost` / `127.0.0.1` | — | **0 命中** |
| 本地用户名 | 9 份文档共 15 处仓库路径 + 3 处独立残留 | **真实命中**；Batch 1C 已处理 15 处，3 处待批，详见 §10.2 |

结论：**没有发现与本项目无关的代码片段、调试开关或个人化配置**。没有 `print(` 泛滥，没有硬编码 `localhost` 端点，没有注释掉的整段实验代码。

---

## 9. 文档链接检查

### 9.1 方法

对 allowlist 内全部 **33 份 `.md`**（即 D 组全体）解析 `[text](target)` 形式，跳过 `http(s)://`、`mailto:`、`#anchor`，把相对路径按所在目录解析后检查磁盘存在性。脚本：`static_checks.py`。

| 指标 | 值 |
|---|---|
| 受检相对链接 | **144** |
| 真实断链 | **0** |
| 误报 | 1 |

### 9.2 唯一误报的说明

`docs/1.2.0/PHASE2_IMPLEMENTATION_PLAN.md:474` 命中 `BROKEN_LINK → repeating:…`：

```markdown
| `AudioRenderer.swift:106-114` | 预分配固定最大工作区（`4096 × 8`），不再在回调中 `[Float](repeating:…)`；清零改为只清 `framesRead × channels` |
```

这是 **Swift 数组构造语法 `[Float](repeating:count:)` 写在行内代码里**，不是 Markdown 链接。检测器的正则无法区分行内代码与链接，属于已知误判，文件本身没有问题。

### 9.3 关键互引是否闭合

| 引用方 | 被引方 | 状态 |
|---|---|---|
| `README.md` | `docs/INSTALLATION_GUIDE.md`、`docs/RELEASE_NOTES.md`、`docs/risks/Known-Limitations.md` | 全部存在 |
| `docs/RELEASE_NOTES.md` | `release/SoundBridge-1.2.0-Release-Checklist.md`、`verification/`、`1.2.0/`、`P3-Host-Restart-...` | 全部存在 |
| `docs/INSTALLATION_GUIDE.md` | `risks/Known-Limitations.md`、`RELEASE_NOTES.md` | 全部存在 |
| `docs/risks/Known-Limitations.md` | `../P4-Batch-1A-Source-Stabilization-Report.md`、`../architecture/`、`../engineering/`(6)、`../Documentation-Migration-Manifest.md`、`../verification/`、`../P2-Batch-*`、`../P3-Final-Closure-Fix-Report.md`、`../P3-Host-Restart-...` | 全部存在 |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | `risks/Known-Limitations.md`、`RELEASE_NOTES.md`、`P4-Batch-1A-...` | 全部存在 |
| `docs/P4-Batch-1A-Source-Stabilization-Report.md` | `P4-Batch-1B-...`（不引用，正确）、各批次报告、`1.2.0/`、`engineering/`、`verification/` | 全部存在 |

**闭环性**：`RELEASE_NOTES` → Checklist → `Known-Limitations` → 1A 报告这条"发布决策链"三级互引全部可解析，没有指向 E 类文件的链接（否则提交后就是断链）。这是 D 组能整组提交的必要条件，已满足。

---

## 10. 敏感信息、二进制与版本文档一致性

### 10.1 密钥 / 令牌 / 凭据

| 模式 | 命中 |
|---|---|
| `-----BEGIN ... PRIVATE KEY-----` | 0 |
| `ghp_*`（GitHub token） | 0 |
| `sk-*`（API key） | 0 |
| `password/passwd/api_key/secret/token = "..."` 形赋值 | 0 |
| 邮箱地址 | 0 |

`.github/workflows/` 中的 Secrets 引用方式为 `${{ secrets.APPLE_CERTIFICATE }}` 等占位符（未被本批次修改），无明文。

### 10.2 个人数据 / 本地路径（Batch 1C 已脱敏）

**Batch 1C 实测（全量重扫，不沿用本节原始数字）**

| 形态 | 处数 | 分布 |
|---|---|---|
| 仓库绝对路径（内含本地用户名） | **15** | 9 份文档 |
| 独立用户名（不在仓库路径内） | **3** | `docs/1.2.0/POC_ERRATA.md:225`（`whoami` 输出）、`docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md:99,100`（`ls -l` 属主列） |
| A/B/C 组代码与脚本 | **0** | — |

逐文件分布（原始版本）：

| 文件 | 仓库路径处数 | 独立用户名 | Batch 1C 处置 |
|---|---|---|---|
| `docs/P4-Batch-1A-Source-Stabilization-Report.md` | 3 | 0 | 仓库路径已脱敏 |
| `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md` | 2 | 2 | 仓库路径已脱敏；独立用户名仅列出，未改 |
| `docs/P2-Batch-4-AudioRenderer-RT-Safety-Report.md` | 2 | 0 | 仓库路径已脱敏 |
| `docs/P3-Final-Closure-Fix-Report.md` | 2 | 0 | 仓库路径已脱敏 |
| `docs/verification/Batch-3-Closure-Fix.md` | 2 | 0 | 仓库路径已脱敏 |
| `docs/P4-Release-Readiness-Audit-Report.md` | 1 | 0 | 仓库路径已脱敏 |
| `docs/1.2.0/PHASE2_IMPLEMENTATION_PLAN.md` | 1 | 0 | 仓库路径已脱敏 |
| `docs/P2-Batch-2-Default-Output-Governance-Report.md` | 1 | 0 | 仓库路径已脱敏 |
| `docs/P2-Batch-3-EQ-Mapping-Reliability-Report.md` | 1 | 0 | 仓库路径已脱敏 |
| `docs/1.2.0/POC_ERRATA.md` | **0** | 1 | 无仓库路径命中，未修改 |
| **合计** | **15** | **3** | 见下 |

**与原始记录的差异（保留以便审计）**：本节 Batch 1B 原文写"10 份文档共 13 处"，但同表 10 行逐行相加为 16 处，两个数字都对不上。Batch 1C 全量重扫的实测值是 15 处 / 9 份：`docs/1.2.0/POC_ERRATA.md` 的那 1 处是 `whoami` 的输出，不是仓库路径。原始扫描记录见 `build/p4-batch1c/evidence/c1c-path-scan-before.log` 与 `c1c-doc-hashes-original.tsv`。

**Batch 1C 的脱敏结果**：15 处仓库路径已全部替换为 `/path/to/SoundBridge`，命令语义、路径层级与技术证据保留。原始 SHA-256 / 字节数与脱敏后值分别记录在 `build/p4-batch1c/evidence/c1c-doc-hashes-original.tsv` 和 `final-document-hashes.tsv`；含用户名的原始文本未提交，也不复制进仓库。

**未处理的 3 处独立用户名**：按任务书"其他独立的个人路径或个人数据，先单独列出，不得擅自扩大修改范围"，只列出、不修改。它们同样会公开 macOS 用户名，是否一并脱敏由用户决定——G-3 因此记为 **PARTIAL**，而非 PASS。

**原文"建议保持原样，不脱敏"的理由不成立**（Batch 1C 更正）：该理由称脱敏会让 1A 报告 §9.2 的哈希表立即失真。实测 1A 报告 §9.2 的 18 行不含任何被本次脱敏的文档，且该表对本文件标注"不固化"；§9.1 的 67 行只覆盖 tracked 文件，被脱敏的 9 份全部是 untracked。两张表都不受影响，无需连带重算。

### 10.3 大型 / 二进制文件

| 指标 | 值 |
|---|---|
| allowlist 内最大文件 | `packages/driver/src/Plugin.cpp` = 76,690 字节 |
| `> 100 KB` 条目 | 0 |
| `> 1 MB` 条目 | 0 |
| 二进制扩展（`.pkg/.dmg/.app/.o/.a/.dylib/.zip`） | 0 |
| 文本编码 | 所有 `.md/.swift/.cpp/.hpp/.sh` 为 UTF-8 文本；3 份 `RFSharedAudio.h` 各 69,590 字节（本批次 P2 扩容所致，属预期） |

### 10.4 版本 / 协议一致性（面向用户的三份文档）

| 指标 | 值 |
|---|---|
| 三份文档均含 `1.2.0` | 是 |
| 三份文档均含协议标识（`131584` 或 `0x00020200`） | 是 |
| 陈旧协议值（`131328` / `0x00020100` / `0x00020000`） | 仅 `docs/RELEASE_NOTES.md:49` 出现两处，**是迁移说明的正文**（"协议从 `0x00020000` / `0x00020100` 变更到 `0x00020200`"），非陈旧残留 |
| `1.1.1` 残留 | `RELEASE_NOTES` 无；`INSTALLATION_GUIDE` 无；`README` 无 |

仓库级校验（只读目标，未触碰任何产物）：

```
$ make version-check
VERSION_SOURCES_CHECKED=11
VERSION_SOURCES_FAILED=0
VERSION_CONSISTENCY=PASS

$ make protocol-check
RF_AUDIO_PROTOCOL_VERSION = 0x00020200 (131584)
Header size = 320 bytes
Driver plist:   OK (SBAudioProtocolVersion=131584)
```

---

## 11. 精确到文件路径的 Git add 计划（**仅计划，未执行**）

### 11.1 禁止形式（复核用）

以下命令在本项目中**永远不允许**出现，本计划与之的差别是"每个路径都单独出现在清单文件里"：

```bash
# 禁止
git add -A
git add .
git add docs
git add docs/
git add packages/driver
git add packages/host
git add apps
git add tools
```

### 11.2 执行计划（3 步）

```bash
# ---- 步骤 0：生成 pathspec 清单（幂等，可复核）----
# 从本报告 §4 的机械清单导出，不手工输入
awk -F'\t' '{print $2}' build/p4-batch1b/evidence/b1b-allowlist.tsv \
  > build/p4-batch1b/evidence/b1b-add-list.txt
printf '.gitignore\n' >> build/p4-batch1b/evidence/b1b-add-list.txt
sort -u build/p4-batch1b/evidence/b1b-add-list.txt | wc -l    # 期望 141

# ---- 步骤 1：逐路径暂存（含 1 个删除项）----
# 每条 pathspec 都是 §4 表格里的完整路径；不使用 -A，不使用目录
# 若需纳入本报告，追加一行：printf 'docs/P4-Batch-1B-Pre-Commit-Report.md\n' >> ...（期望 142）
git add --pathspec-from-file=build/p4-batch1b/evidence/b1b-add-list.txt
```

清单**已预生成并核验**：`b1b-add-list.txt` 实测 **141 行、去重后 141 行**（即无重复），`^(\.qoder|dist|build)/` 前缀命中 **0**。这一步未使用任何 Git 命令，只是文本拼接，因此可以在授权前完成。

```bash
# ---- 步骤 2：暂存区校验（任一项不符即停止，不得 commit）----
git diff --cached --name-only | wc -l                                  # 期望 141
git diff --cached --name-only | grep -cE '^(\.qoder|dist|build)/'    # 期望 0
git diff --cached --name-only | grep -c 'DriverUpdateWindow.swift'     # 期望 1（删除项）
git diff --cached --name-only | grep -cE '\.(pkg|dmg|app|log)$'      # 期望 0
git diff --cached --name-only | sort > /tmp/staged.txt && \
  (awk -F'\t' '{print $2}' build/p4-batch1b/evidence/b1b-allowlist.tsv; echo .gitignore) \
  | sort > /tmp/expected.txt && diff /tmp/staged.txt /tmp/expected.txt && echo ALLOWLIST_MATCH
```

### 11.3 兼容性与回退形式

`git --pathspec-from-file` 需要 Git ≥ 2.25，本机为 2.50.1。等价回退（逐行单路径，同样不是宽泛命令）：

```bash
while IFS= read -r p; do git add -- "$p"; done < build/p4-batch1b/evidence/b1b-add-list.txt
```

### 11.4 这一计划的三个安全性质

1. **全路径可枚举**：141 条路径全部出现在 §4 表格与 `b1b-add-list.txt` 中，逐条可 diff。
2. **默认拒绝**：清单来源是 `b1b-allowlist.tsv`（人工审定过的 140 条）+ 1 条显式的 `.gitignore`；不存在"目录展开把新文件带进来"的可能。
3. **自校验**：步骤 2 的 `diff /tmp/staged.txt /tmp/expected.txt` 要求暂存区与清单**逐字节相同**，多一个少一个都会失败。

---

## 12. 预计提交后的剩余工作区状态

### 12.1 执行 `git add`（141 条）之后的暂存态

| 项 | 预期 | 当前实测 |
|---|---|---|
| 暂存条目 | 141（新增 73 + 修改 67 + 删除 1） | 0 |
| 未暂存修改 | 0 | 67 |
| 未跟踪 | 14（E-2 的 13 个顶层文件 + `docs/manifests/` 目录条目） | 70 行 |
| `git status --porcelain` 行数 | 141 + 14 = **155** | 138 |
| `git diff --cached --name-only | grep -cE '^(\.qoder|dist|build)/'` | 0 | 0 |

> 若把本报告也纳入（口径 142），未跟踪从 14 变 15，总行数 156。

### 12.2 提交并推送之后的稳态

| 项 | 预期 |
|---|---|
| `git status --porcelain` | **14 行**，全部是 E-2 的 `??`（有意保留，见 §6.2） |
| `git status --porcelain --ignored` | 额外列出 `dist/`、`build/`、`.qoder/` 三类被忽略项 |
| `git diff --cached --name-only` | 0 |
| 工作区源码 / 文档 / 工具 | 与提交内容逐字节相同；E-2 的 14 个文件本就不在提交范围内 |
| 分支与远端 | `main` 领先 `origin/main` 1 个 commit（推前）；推后平齐 |

### 12.3 提交后仍会存在的"非零状态"及其解释

| 现象 | 解释 | 是否需要处理 |
|---|---|---|
| 14 条 `?? docs/...` | E-2 过程取证，按 §6.2 有意不提交 | 后续归档阶段再定（不阻塞 1.2.0） |
| `.qoder/` 不出现 | 已被忽略，内容仍在磁盘 | 否 |
| `dist/` 不出现 | 已被忽略，1.1.1 / 1.2.0 产物完整保留 | 否 |

---

## 13. 下一阶段 clean clone 构建计划（**未执行**）

目的：证明"提交进去的东西自己就能构建"，而不是靠工作区里的未提交残留。

```bash
# 前置：Batch 1C 已在本仓完成 commit（不要求 push）
CLONE=/tmp/sb-1b-clean
rm -rf "$CLONE"                                   # 仅限 /tmp，不得指向仓库内

# --no-local：强制真实打包传输，而不是硬链接共享对象库；
# 这样 clone 出来的 .git 里只有已提交对象，任何"忘记 add"立刻暴露
git clone --no-local "$REPO" "$CLONE"
cd "$CLONE"

git rev-parse HEAD                                 # 必须 == 主仓提交后 HEAD
git status --porcelain                             # 必须为空
git log -1 --stat | head -40                       # 核对 141/142 条与 commit message

git submodule update --init --recursive            # libASPL 需网络，固定 633e0f7
git submodule status                               # 不得出现 +/- 前缀

make version-check                                 # 期望 VERSION_SOURCES_FAILED=0
make protocol-check                                # 期望 0x00020200 / 320 bytes

# 构建与测试（不碰系统：不 sudo / 不装 Driver / 不重启 coreaudiod）
make test                                          # dsp + driver + host + app + installer + codesign

# 产物隔离验证（不写入 repo 的 dist/）
SB_DIST_DIR=/tmp/sb-1b-dist make bundle
ls /tmp/sb-1b-dist/SoundBridge.app/Contents/MacOS
```

### 13.1 这个计划的四个判定点

| 判定 | 失败意味着 |
|---|---|
| `git status` 在 clone 中为空 | 有文件靠工作区残留才存在（漏 add），或 `.gitignore` 误伤已跟踪文件 |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` 在 clone 中存在且不被忽略 | §3 的 `.gitignore` 修复未随提交落地 |
| `make test` 全绿 | allowlist 漏了编译所需的文件（依赖不闭合） |
| `SB_DIST_DIR` 构建成功且 repo `dist/` 无新增 | 构建脚本写死了 `dist/` 路径，会在后续阶段污染发布产物 |

### 13.2 已知前置条件

- `git submodule update --init --recursive` 需网络访问 `github.com/gavv/libASPL`；离网环境下 clean clone 构建会在 driver 编译阶段失败（属环境限制，不是代码缺陷）。
- clean clone 中 `make test` 会现场编译 DSP/Driver/Host/App，耗时明显长于增量构建。
- 不在本阶段范围内：签名、公证、DMG 打包、`make release`。

---

## 14. 与 Batch 1A 的差异：140 → 141 / 142

### 14.1 为什么数字变了

任务书给的目标是 **140 = A 55 + B 40 + C 12 + D 33**，这个数字来自 Batch 1A 的分类。但 Batch 1A 的分类里 **`.gitignore` 不在任何一组**——当时它没被修改（1A §1.3 把它登记为「不能改，只能记录」的 B-8 阻断项）。

本阶段 §2.1 明确授权修 `.gitignore`，于是它变成必提交项（否则 1A 发现的 B-8 会在下次 clone 后原样复发）。它属于构建/工具配置 → **C 组**。

| 口径 | A | B | C | D | 合计 | 说明 |
|---|---|---|---|---|---|---|
| 任务书目标 | 55 | 40 | 12 | 33 | **140** | 不含 `.gitignore` |
| 最小可提交集（推荐） | 55 | 40 | **13** | 33 | **141** | +`.gitignore` |
| 完整审计集 | 55 | 40 | 13 | **34** | **142** | +本报告 |

### 14.2 我的建议：按 142 提交

理由：

1. **`.gitignore` 必须进**（141 的下限）——否则修复只存在于本机。
2. **本报告也应该进**——1A 报告已经在 D 组里（D-16），如果把 1B 报告排除，仓库里就只存了"发现 B-8"的记录而没有"修好 B-8"的记录，下一次审计会重新打一遍同样的疑虑。两份报告是一对证据链。

但 141 是**完全可接受**的备选：报告作为本地证据保留，不影响提交内容的自洽性。这个选择权在你（§15 G-2）。

---

## 15. 待用户确认项（G 类）

| 编号 | 事项 | 我的建议 | 不决定的后果 |
|---|---|---|---|
| **G-1** | `.gitignore` 纳入提交（140→141） | **纳入** | `docs/release/` 在下次 clone 中仍会被忽略，1A 的 B-8 复发 |
| **G-2** | 本报告纳入提交（141→142） | **纳入** | 仓库缺少"已修复"的闭环记录；不影响构建 |
| **G-3** | 绝对家目录路径是否脱敏（§10.2） | **已执行（Batch 1C 授权）**：15 处仓库路径已脱敏；3 处独立用户名为 **PARTIAL**，待你决定 | 公开 macOS 用户名；剩余 3 处仍会泄露用户名 |
| **G-4** | 中档 122 个文件"无用户个人修改"的形式确认（§8.3） | 由你确认 | 存在未被发现的个人实验代码被一并提交的理论可能 |
| **G-5** | E-2 14 份 + `.qoder/` 75 个的长期处置 | 本阶段不处理，保持现状 | 提交后 `git status` 永远有 14 条 untracked；不影响发布 |
| **G-6** | 是否授权进入 Batch 1C（实际 `git add` / `commit`） | 等你明确指令 | 无 |

**本阶段到此停止。** 未经 G-6 的明确授权，不会执行任何 Git 写操作。

---

## 16. 边界声明

本阶段**实际执行**的全部动作：

| 动作 | 性质 | 是否越界 |
|---|---|---|
| 修改 `.gitignore` 两处（+5/−1） | 文本编辑，任务书 §2.1 明确授权 | 否 |
| 新建 `build/p4-batch1b/evidence/` 下 17 份证据/脚本 | 已忽略目录内的取证物 | 否 |
| 新建本报告 | 任务书 §4 要求 | 否 |
| `git status` / `diff` / `ls-files` / `check-ignore` / `submodule status` / `rev-parse` | 只读查询 | 否 |
| `make version-check` / `make protocol-check` | 只读校验目标，不写 VERSION、不重建产物 | 否 |

**未执行**（逐项核对）：

`git add` · `git commit` · `git push` · `git tag` · `git reset` · `git clean` · `git checkout` · `git restore` · `git stash` · `git add -A` · `make clean` · `make release` · `make build` · `sudo` · Driver 安装/卸载 · `killall coreaudiod` · 默认输出切换 · `dist/` 与 `build/` 内既有文件删除/覆盖 · VERSION/Bundle Version/Build Number/Protocol/ABI/Deployment Target 修改 · vendor submodule 操作 · 全仓格式化 · clean clone 构建。

最终状态自检（本报告写完时）：

```
$ git diff --cached --name-only | wc -l
0
$ git status --porcelain=v1 | wc -l
139
$ ls -la dist/
（1.1.1 dmg/pkg 与 1.2.0 pkg/dmg/component.plist/SoundBridge.app 时间戳未变）
```

新增的 1 行 `??` 即本报告自身（138 → 139）。
