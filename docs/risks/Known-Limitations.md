# Known Limitations 与剩余风险

本文件是 SoundBridge 1.2.0 **未解决问题**的唯一登记处。归档不改变任何风险
状态：凡是 Batch 0–3 与 Closure Fix 报告中未关闭的事项，都在这里以未关闭
状态保留。

1.2.0 已于 2026-11-21 正式发布，并在发布验证机上完成端到端安装与运行验证。
发布验证中新发现的观察项、明确未测项，以及对 B 类条目的状态更新，统一登记在
[§2A](#2a-120-发布验证登记2026-11-22)；发布后的下载校验、安装、驱动加载、
功能与 31 分钟稳定性结果见
[release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md](../release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md)；
发布事实与原始证据在
[release/SoundBridge-1.2.0-Final-Release-Report.md](../release/SoundBridge-1.2.0-Final-Release-Report.md)。
**发布不等于结案**：本节以下所有条目仍按各自状态保留，只有明确写出「已执行 /
已验证」的才升级。

分类口径（每条风险只归一类，便于判断下一步动作）：

| 类别 | 含义 | 谁负责 |
|---|---|---|
| **A 已知实现限制** | 设计上刻意的取舍，不是缺陷；不会"修好"，只会被记录与被产品决策接受 | 架构 |
| **B 尚未验证** | 缺证据，不是缺实现。可能在真实环境暴露问题 | 测试 / 验证 |
| **C 需要后续工程修复** | 已确认的实现缺陷或技术债 | 工程 |
| **D 未来产品测试要求** | 发布前必须执行的验证活动，本身不是缺陷 | 产品 / QA |

---

## 0. P2/P3 已关闭、且有证据的事项

这一节是 P4 Batch 1A 新增的。以下事项在 P2/P3 完成，**不再**是当前风险，列出是为了
防止它们被重复登记，也为了让「已解决」有可查的证据而不是口头结论。

> 文中 `P2` / `P3` / `P4 Batch …` / `Batch 3A` 一类编号是当年的内部批次编号，对应的
> 批次报告与验证归档**不随仓库发布**（去向见 [docs/README.md](../README.md) §6）。
> 引用它们只是标出来源批次；结论本身在本表与正式文档中给出，可复现的命令见
> [development/DEVELOPMENT_GUIDE.md](../development/DEVELOPMENT_GUIDE.md)。

| 编号 | 原问题 | 结论 | 证据 |
|---|---|---|---|
| P2-B2 | 默认输出设备被 App 隐式抢占 / 无所有权模型 | 已实现所有权判定，只在用户显式操作时切换 | 批次报告已移出仓库；`DefaultOutputGovernanceTests`、`DefaultOutputTrackingTests`、`DefaultOutputSwitchTests`（TEST_VERIFIED） |
| P2-B3 | Host 重新发布映射后 EQ 停在 `eq_sequence = 0` | 已实现自动恢复：`mappingPublished` + 代际比对后重写 EQ | 批次报告已移出仓库；`EQRecoveryTests`（TEST_VERIFIED） |
| P2-B4 | 渲染回调内的锁、一次性分配与 `print`（原 H-1、H-2、H-3） | 回调改为 `enterRenderMemory`（无字典锁）+ 预分配缓冲 + 计数器；诊断输出移到控制线程 | 批次报告已移出仓库；`AudioRendererRTSafetyTests`、`RTObservabilityTests`（TEST_VERIFIED） |
| P3-HR | Host 退出会导致 App 退出；无法只重启 Host | 已实现 `HostSupervisor` + `HostRestartEntry`（仅重启 Host，卸载/终止期间拒绝） | 批次报告已移出仓库；`HostSupervisorTests`、`HostRestartEntryTests`（TEST_VERIFIED）；Host 重启闭环在真实 macOS 上执行过一次（REAL_MACOS_VERIFIED，范围仅限进程重启） |
| P4-1A-1 | App 内存在第二套特权安装事务 | 已删除；App 只读检测，安装交给 PKG | 批次报告已移出仓库；`DriverInstallBoundaryTests`（TEST_VERIFIED） |
| P4-1A-2 | App 内卸载与 `tools/uninstall_driver.sh` 政策不一致 | 已统一：校验 bundle id、拒绝符号链接、只删常量路径、不重启 `coreaudiod`、先停 Host | 同上；`DriverUninstallPolicy` 与脚本由 `DriverInstallBoundaryTests` 锁定（TEST_VERIFIED） |
| P4-1A-3 | `test_release_payload.sh` 依赖 `dist/` 中的 1.1.1 历史产物 | 已改为合成 fixture，版本由场景指定 | 同上；`tools/test_support/make_payload_fixture.sh`，244 断言（TEST_VERIFIED） |

> 关闭 ≠ 可用。上表的「已关闭」只说明**实现与自动化测试**层面的问题消失；真实设备上的
> 行为仍在下面 B 类里以未验证状态保留。

---

## 1. A 类：已知实现限制

### L-1 Quarantine 没有回收机制

| 项 | 内容 |
|---|---|
| 现象 | 无法证明排空的 mapping 被永久保留到进程退出 |
| 原因 | 一个永不返回的回调无法被证明已经离开；`shared_ptr::use_count()` 不是同步点；控制线程绕过闸门 |
| 代价 | 每条例目约 32 KiB ring + 320 B header（`st_size ≤ 64 MiB`）虚拟地址空间；无上限 |
| 触发条件 | 仅在 `TimedOut`（回调在 250 ms 内未离开）时增长 |
| 为什么不是缺陷 | 任何回收都需要一个"回调已离开"的证明，而这个证明在模型内不存在 |
| 关联 | [Mapping-Retirement.md](../engineering/Mapping-Retirement.md) §6 |

### L-2 `Open()` 保留残留准入计数

| 项 | 内容 |
|---|---|
| 现象 | 挂死回调的计数永久存在，此后每次排空都失败 |
| 原因 | 刻意不清零：清零会把"无法证明"变成"误判安全" |
| 代价 | 一次挂死 → 该 handler 之后所有 mapping 都进入 quarantine（liveness 不受影响） |
| 关联 | [Callback-Lifecycle.md](../engineering/Callback-Lifecycle.md) §6 |

### L-3 只支持 64 位平台

| 项 | 内容 |
|---|---|
| 现象 | 32 位平台上 `std::atomic<uint64_t>` 通常非 lock-free |
| 处理 | 不为其写"跨平台 lock-free"保证；支持的只有 arm64 / x86_64 |
| 关联 | [CallbackGate-Memory-Model.md](../engineering/CallbackGate-Memory-Model.md) §10.2 |

### L-4 lock-free ≠ wait-free

| 项 | 内容 |
|---|---|
| 现象 | `fetch_add` 可能与其他核争缓存行，单个操作没有严格时间上界 |
| 处理 | RT 结论只声明"不加锁、不无限等待其他线程主动释放资源" |
| 关联 | 同上 §10.3 |

### L-5 Drop New 会产生可听缺口

| 项 | 内容 |
|---|---|
| 现象 | Ring 满时丢弃新帧 |
| 原因 | 覆盖未读数据需要生产者回写 `read_index`，破坏单写者不变量并引入撕裂 |
| 处理 | 丢弃可通过 `out_dropped` 观测；接受"缺口"而不接受"错位" |
| 关联 | [RingBuffer-Design.md](../engineering/RingBuffer-Design.md) §5 |

### L-6 Driver 重启后需要一次重新发布才能恢复

| 项 | 内容 |
|---|---|
| 现象 | `coreaudiod` 重启后新 handler 的 claim 会因旧 token 仍占据 slot 而失败 |
| 原因 | `rf_producer_release()` 只在 `OnStopIO` 调用（唯一同时具备 `ioMutex_` 与排空证明的路径） |
| 处理 | 依赖 Host 重新发布（新 inode + 新 epoch） |
| 代价 | Driver 重启后不会自动恢复，需要一次 IO 重启或设备切换 |
| 关联 | [SharedMemory-Lifecycle.md](../engineering/SharedMemory-Lifecycle.md) §6.2 |

### L-7 `revision` 是 handler 局部量

| 项 | 内容 |
|---|---|
| 现象 | `mapping_revision_` 不跨进程，只在单个 handler 内单调 |
| 后果 | 跨进程的"这是不是同一 incarnation"只能靠 `epoch`，不能靠 `revision` |
| 处理 | 两者同时校验 |

### L-8 Host 不调用 `finalize_close`

| 项 | 内容 |
|---|---|
| 现象 | Host 清理后 mapping 状态停在 `CLOSING` |
| 原因 | `CLOSED` 需要排空证明才有意义，而排空属于 Driver 侧 |
| 处理 | 新发布走新 inode，不复用旧状态 |

### L-9 `unlinkIfStillOwned` 的检查与 unlink 非原子

| 项 | 内容 |
|---|---|
| 现象 | `lstat` 与 `unlink` 之间不是原子操作 |
| 处理 | 依赖 Host 单实例锁排除其他合法写者；`st_dev`/`st_ino` 比对防误删 |
| 关联 | `SharedMemoryManager.swift` `unlinkIfStillOwned` |

### L-10 排空预算由时间界定

| 项 | 内容 |
|---|---|
| 现象 | 250 ms 是时间界，不是操作数界 |
| 后果 | 真实负载下的回调时长分布未知，预算是否足够无实测依据 |
| 处理 | 保守取值；超时只产生 quarantine，不产生错误结论 |

### L-11 四份共享头副本靠工具同步

| 项 | 内容 |
|---|---|
| 现象 | 同一 header 存在 4 份物理副本 |
| 处理 | `tools/sync_shared_header.sh --check` 强制一致；`check_protocol_layout.sh` 双语言校验 |
| 代价 | 忘记同步会在 CI 检查处失败，而不是在编译期失败 |

### L-12 只在单 mapping / 三 holder 模型下被建模

| 项 | 内容 |
|---|---|
| 现象 | 并发与生命周期论证按“每设备一块 mapping、最多 Host + Driver + App 三个 holder”建立 |
| 缺口 | 没有对“同一设备多块 mapping 并存”或“多个 App 实例分别持有”建模 |
| 当前约束 | 依赖 Host 单实例锁与按设备路径命名排除这两种情况 |
| 关联 | `SharedMemory-Lifecycle.md` §7 |

### L-13 发布物完全未签名、未公证，且没有自动更新

| 项 | 内容 |
|---|---|
| 决策 | 项目没有 Apple Developer Program 账号。**不**使用 Developer ID Application / Developer ID Installer 签名，**不**做 ad-hoc 签名，PKG 不签名，**不**提交 notarization，**不**发布 Sparkle appcast |
| 现象 | App、HAL 驱动、PKG、DMG 全部无签名身份。`codesign --verify --strict` 对 App 与驱动报 `code object is not signed at all`，`pkgutil --check-signature` 对 PKG 报 `no signature`，`spctl` 对 App/PKG/DMG 一律 `rejected / source=no usable signature` |
| 唯一残留 | `ld64` 对每个 Mach-O 写入的 ad-hoc CodeDirectory（`flags=0x20002(adhoc,linker-signed)`）。Apple silicon 要求它存在才能加载代码；它没有证书、没有 TeamIdentifier。`codesign --remove-signature` 会让 arm64 进程被内核 `killed`，因此这是平台可达的最小签名状态 |
| 第三方例外 | `Sparkle.framework` 2.10.1 的 SwiftPM 产物自带上游 ad-hoc bundle 签名与 4 个 `_CodeSignature`（framework 本体、`Updater.app`、`Downloader.xpc`、`Installer.xpc`）。无 Authority、无 TeamIdentifier；删除需重签（禁止）或剥离（会破坏 `@rpath` 加载）。这是**第三方产物**，不是本项目签的 |
| Gatekeeper 后果 | 首次打开 App 与 PKG 都必须手动批准（系统设置 → 隐私与安全性 → 仍要打开）。**不得**为安装而关闭 Gatekeeper 或 SIP。受 MDM/受管控策略禁止未签名软件的组织，本版本无法安装 |
| 更新通道 | 无。`SUPublicEDKey` 为空，`appcast.xml` 从不发布，`tools/generate_appcast.sh` 拒绝运行（exit 2），`SUFeedURL` 指向的地址永远 404。升级方式只有下载新 PKG |
| 为什么不改 | 签名需要付费账号与 macOS 构建机上的证书；本项目选择「完全未签名 + 完整披露」而不是「部分签名 + 误导用户」 |
| 构建期约束 | `tools/codesign.sh`、`tools/notarize.sh`、`tools/generate_appcast.sh` 是 fail-closed 存根：`--help` 返回 0，其余调用返回 2。`tools/verify_signatures.sh` 与 `tools/verify_unsigned_release.sh` 断言产物**未**签名，`tools/test_unsigned_release.sh` 在 CI 中锁定这一状态 |
| 关联 | [INSTALLATION_GUIDE.md](../INSTALLATION_GUIDE.md) §0、§5.3、§11；[RELEASE_NOTES.md](../RELEASE_NOTES.md) |

#### L-13.1 四个概念不得互相证明

签名话题上最容易出现的错误，是把「有一点签名残留」当成「已签名」或「已通过
Gatekeeper」。下表是判定口径（自 P4 Batch 7 提炼）：

| 层 | 产物里实际存在什么 | 能证明什么 | **不能**证明什么 |
|---|---|---|---|
| 完全未签名 | 什么都没有 | — | 任何事 |
| linker ad-hoc（**本项目唯一的项目内残留**） | `ld64` 写入的 CodeDirectory，`flags=0x20002(adhoc,linker-signed)`，无证书、无 TeamIdentifier | Mach-O 在 Apple silicon 上可被内核加载 | 身份、资源封印、公证、Gatekeeper 接受 |
| 显式 ad-hoc 签名 | `codesign --sign -` 生成的签名 | `codesign --verify` 通过 | 身份、公证、Gatekeeper 接受 |
| Developer ID + 公证 | 证书 + notary ticket + staple | 身份、Apple 扫描、可分发 | 本项目**不提供**这一层 |

判定顺序固定：先看 `codesign -dv` 的 `flags`/`TeamIdentifier`，再看
`pkgutil --check-signature`，再看 `spctl` 的决定。三者结论不一致时，以「能力更弱」
的那一层为准——不得用 `codesign --verify` 的 exit 0 去暗示 Gatekeeper 会放行。

---

## 2. B 类：尚未验证

P4 Batch 1A 起，每条未验证事项都带**证据位置**：要么是已执行过的报告，要么写明
「无任何报告」——后者本身就是没有证据的证明。

| 编号 | 未验证事项 | 现状 / 证据位置 |
|---|---|---|
| **U-1** | **真实 HAL 设备移除**（播放中拔 HDMI/DP） | **仍未验证**。1.2.0 发布验证中的 K5c 由用户选择跳过（未拔插显示器），见 [§2A](#2a-120-发布验证登记2026-11-22)。自动化只覆盖状态机（`GracefulShutdownTests`），不覆盖拔线 |
| **U-2** | 真实 Driver 部署：安装、卸载、升级、`coreaudiod` 重启 | **安装已真机验证**（Batch 3A §R2.9#2：首次安装分支 + receipt 1.2.0）；**卸载 → 重装已在同一台机器上执行**（发布报告 §11–§12）；跨版本升级（1.1.x → 1.2.0）与「`coreaudiod` 重启后自动恢复」仍未单独执行 |
| **U-3** | **macOS 14.4 认证**（当前只在 27.2.1 上运行） | 无 14.4 环境报告 |
| **U-4** | Host / App 完整回归 | **已验证并关闭**：Host 379 / App 253 全绿（原始批次记录已移出仓库） |
| **U-5** | x86_64 真机运行（仅有 universal 产物） | 无 Intel 机器报告；`verify_*_contents.sh` 只确认架构切片存在 |
| **U-6** | 真实负载下的 xrun 率与丢帧率 | 计数器已实现（`rf_rt_counters_note_underrun`）。**单点证据**：48 kHz / 512 帧 + 30 分钟 + 4×CPU 负载下 underrun / overrun 零增量（[§2C](#2c-硬件实时验证登记2026-11-23)）。其他格式、低 buffer 与更长时长的基线仍缺 |
| **U-7** | Quarantine 长期增长曲线 | 无 ≥ 8 小时运行记录 |
| **U-8** | 多设备并发退役 / 热插拔 | 无 |
| **U-9** | Driver 重载后旧 ACK 是否可能复活 | 无 |
| **U-10** | A0：原子硬件行为在全部目标架构 | 编译期属性已知；无运行时验证 |
| **U-11** | 真实 Host 崩溃后由真实 Driver 重新附着的完整流程 | Host 重启闭环已验证（真实 macOS 上执行过一次，范围仅限进程重启），但「崩溃 → 重新附着」未覆盖 |
| **U-12** | `/tmp` 被系统清理工具删除共享文件后的行为 | 无 |
| **U-13** | HAL 沙箱下 Driver 对 bundle 外文件的读取权限 | 无真实 HAL 验证 |
| **U-14** | **实际 EQ 听感** | **已有用户主观听感确认**（Batch 3A §10、§R2.9#7：各频段调整与 Reset 可听辨、符合预期；30 分钟播放无爆音/断续）；1.2.0 发布验证的 K4 用户仅回报「做完了」，**未**单独给出听感确认，该轮只有客观参数链；**没有频响 / 相位 / 削波测量**，跨设备、跨内容、旁通/启用切换未取证。**不得**声称音质已通过测量 |
| **U-15** | **播放窗口 underrun** | 默认 buffer 下已有三次长时间基线：Batch 3A 30 分钟零增量；1.2.0 发布验证 **31 分 01 秒 / 89,320,455 帧**，播放期间 30 个采样点 underrun、overrun 均为零增长（发布报告 §22）；2026-11-23 硬件实时验证在 4×CPU 负载下复现零增量（[§2C](#2c-硬件实时验证登记2026-11-23)）。低 buffer / 其他采样率未测；计数器无法区分空闲与播放期（Batch 3B O-3） |
| **U-16** | **真实卸载/重装闭环** | **已在同一台机器上执行**：卸载（发布报告 §11）→ 用公开发布的 PKG 重装（§12）→ 播放 / 音量 / 静音 / EQ 重新可用（§21）。**残留未验证**：跨版本升级路径、跨机器重装；且「重装后 EQ 数值与卸载前一致」因 OBS-2（EQ 未持久化）无法作为通过判据 |
| **U-17** | **未签名 HAL 驱动能否被 `coreaudiod` 加载** | **VERIFIED — 单机、限定环境**。在 macOS 27.2.1 / arm64、SIP 与 Gatekeeper 均开启、无任何签名的条件下，未签名驱动确实被加载：`HALS_RemotePlugInRegistrar` 记录 `Attempting to load` / `Creating remote driver service … pid: 48806`，驱动 helper 进程存活（发布报告 §18）。**仍未验证**：macOS 14、任何 Intel Mac、受管控/MDM 设备。加载行为随 macOS 版本与安全策略变化，**不得**外推为「所有 Mac 都能加载」 |
| **U-18** | **未签名 PKG 在真实机器上的安装全流程** | **部分验证**。`installer` CLI 路径已在未签名产物上完成：写入 HAL 目录、回执、109/109 载荷一致、安装后首次发声（发布报告 §12、§14–§15）。**未测**：双击 PKG 触发的 Gatekeeper GUI 批准路径（G-UI，见 [§2A](#2a-120-发布验证登记2026-11-22)） |

U-4 已由自动化测试关闭。U-2（安装与同机卸载/重装）、U-14、U-15 已取得真机证据，
按**部分关闭**处理；U-17 在单机限定环境下升级为已验证，U-18 升级为部分验证。
其余未验证项（U-1、U-3、U-5、U-7、U-8 等）按发布策略作为**已披露限制**，不阻断
1.2.0 的发布。

> 「部分关闭」不等于可用。上表任何一行都不能被引用为「该场景在所有环境成立」。

---

## 2A. 1.2.0 发布验证登记（2026-11-22）

本节登记 1.2.0 正式发布后台验证（同机卸载 → 从 GitHub 下载的 PKG 安装 → L1–L7
加载链 → K1–K6 功能与稳定性）中新发现的观察项，以及两处明确未测。每项都要区分
**已验证范围**与**未验证范围**，不得用前者覆盖后者。

分类：OBS-1 / OBS-2 属于 **C 类（需要后续工程修复/确认）**，OBS-3 属于 **C 类但
其中「不重启 coreaudiod」是 A 类设计取舍**，OBS-4 属于 **A 类（已知限制）**，
K5c / G-UI 属于 **B 类（尚未验证）**。

### OBS-1 无 I/O 客户端窗口时，音量/静音写入可能不提交

| 项 | 内容 |
|---|---|
| ID | OBS-1（对应发布报告 O-K3-1 / O-K6-1） |
| 现象 | 在播放未进行、没有 I/O 客户端窗口时，对代理设备写入音量或静音可能**不提交**：`set volume` 返回成功，但系统读数与共享内存值保持原值。1.2.0 发布验证中出现 3 次（K3 首次 unmute、K6 起始设 30、K6 结束恢复 88），每次都在**播放进行中重新设置**后生效 |
| 影响 | 用户可能「拖了滑块或按时没变化」，需在播放中重设一次；不会产生错误音量、爆音或数据损坏。**不是**「完全无法调节音量」——音量映射本身经实测正确（60→0.5942、20→0.1914、88→0.8789，与 48·√s−48 一致） |
| 当前状态 | **待调查**。未定位是驱动控制对象的写入路径、HAL 属性提交窗口，还是系统侧缓存 |
| 已验证范围 | 同一台机器（macOS 27.2.1 / arm64）上三次复现、三次重设后生效；播放期间音量/静音双向控制正常 |
| 未验证范围 | 其他 macOS 版本、其他设备；App 内滑块与键盘音量键是否同样受影响（本轮用 `set volume` 验证）；是否与 App 是否前台有关 |
| 后续建议 | 在驱动控制对象写入路径加「提交/丢弃」可观测计数；区分「无客户端窗口」与「属性未提交」两种情形；分别用 App 滑块、键盘音量键、`set volume` 复测 |
| 优先级 | **P1** |

### OBS-2 EQ 滑块值本轮未持久化

| 项 | 内容 |
|---|---|
| ID | OBS-2（对应发布报告 O-K4-1） |
| 现象 | **运行时** EQ 调节正常；但退出 App 再启动后，共享内存恢复为拖动**之前**的历史值（Bass 11.747 / Mids 1.278 / Treble −2.202 dB），而非最后一次的 +8 / 0 / −8 dB。`defaults read com.soundbridge.menubar` 中 `eq_default_enabled=1` 已更新，三档滑块值仍为旧值 |
| 影响 | 每次启动需重新调节 EQ；不影响运行期音质与音频链路 |
| 当前状态 | **待修复**。代码上滑块释放走 `flushToSharedMemory()`（只写共享内存），限流管道里的 `saveToUserDefaults()` 才是持久化点；本轮未能复现「拖动后的值被持久化」 |
| 已验证范围 | **运行时链路成立**：`eq_seq` 0→2→4→6→8→10 单调递增；10 段增益与 UI 的 +8 / 0 / −8 及 3×10 权重映射（Bass 0.5/1.0/1.5、Mids 0.6/1.2、Treble 0.4/1.3）逐项吻合；`AudioRenderer` 渲染回调内的应用路径已核对 |
| 未验证范围 | 拖动后的值是否在某个事件上写入 UserDefaults；多设备下 per-device 键是否退化为 `eq_default_*` 全局键；重启后 EQ 一致性没有任何自动化断言 |
| 后续建议 | 明确「哪些事件触发持久化」（滑块释放 vs 限流 sink）；补一条「重启后 EQ 数值一致」的回归测试；对 per-device 键做多设备验证 |
| 优先级 | **P1** |

> 引用纪律：**不得**把「运行时 EQ 调节正常」写成「EQ 持久化正常」。二者是不同
> 结论，本轮只有前者成立。

### OBS-3 卸载不清理 PKG 回执 / InstallerState，也不重启 coreaudiod

| 项 | 内容 |
|---|---|
| ID | OBS-3（对应发布报告 O-H-1） |
| 现象 | 卸载后：PKG 回执 `com.soundbridge.menubar` 仍存在；`~/Library/Application Support/SoundBridge/InstallerState/log/` 保留事务日志；卸载脚本**不重启** `coreaudiod`，因此驱动可能仍以内存副本运行（卸载前快照中 helper PID 605 存活，`killall coreaudiod` 后才消失） |
| 影响 | 重装时 `preinstall` 可能命中「升级」而非「首次安装」分支；用户以为已卸载但系统里仍有设备/回执；排障时容易误判 |
| 当前状态 | **待完善**。其中「不自动重启 `coreaudiod`」是**刻意的设计取舍**（A 类），不视为缺陷；回执与 InstallerState 残留属于待改进（C 类） |
| 已验证范围 | `tools/uninstall_driver.sh --dry-run` 与真实执行均 `exit 0`；卸载后无驱动 bundle、无 LaunchAgent、无 `/tmp/soundbridge-*`；显式 `killall coreaudiod` 后 helper 消失（发布报告 §11） |
| 未验证范围 | 残留回执对后续升级路径的实际影响未系统测试；受管控/MDM 机器上清理回执的权限未验证；卸载 → 重启系统 → 重装的完整时序未单独测试 |
| 后续建议 | 在卸载流程中加入**可选**的 `pkgutil --forget com.soundbridge.menubar` 与 InstallerState 清理（需明确「保留用户配置」的边界）；把「需人工重启 `coreaudiod` 或重启系统」写成卸载步骤中的显式条目 |
| 优先级 | **P2** |

### OBS-4 PKG/DMG 封装层不可字节复现

| 项 | 内容 |
|---|---|
| ID | OBS-4（对应发布报告 O-B-1） |
| 现象 | 同一 commit 两次构建的 PKG / DMG 字节不同（内嵌构建时间戳/UUID）；驱动、Host、App 主程序的二进制 SHA-256 完全相同 |
| 影响 | 无法用封装层哈希比对两次构建；发布证据只能依赖「权威哈希清单 + 逐文件比对」，且重打包会改变 PKG/DMG 哈希 |
| 当前状态 | **已知限制**，1.2.x 内不打算修 |
| 已验证范围 | 二进制层可复现（发布报告 §4）；已发布资产的 SHA-256 已登记（PKG `2bf22460…`、DMG `2c78d502…`） |
| 未验证范围 | 未尝试 `SOURCE_DATE_EPOCH` / 确定性 `pkgbuild` / 确定性 DMG；不同构建机之间的二进制一致性未验证 |
| 后续建议 | 评估固定 mtime 与确定性打包；在此之前，发布审计以「权威清单 + 109/109 逐文件比对」为准 |
| 优先级 | **P2（工程改进）** |

### K5c 设备移除与重新枚举（未测）

| 项 | 内容 |
|---|---|
| ID | K5c（对应 U-1、测试要求 P-1） |
| 现象 | 播放中拔插 HDMI/DP 在本轮**未执行**：用户选择跳过（未拔插 LG ULTRAGEAR+） |
| 影响 | 设备移除路径只有自动化状态机覆盖；`quarantine` 计数无实测值；真实拔线是否会阻塞或崩溃无证据 |
| 当前状态 | **未测**（NOT_TESTED），不是已知故障 |
| 已验证范围 | K5a（Host 收到 SIGTERM 后有序停机、回收 AudioUnit/控制文件/共享内存）、K5b（App 退出 → 重启 → 新 session → 驱动自动重连）两项通过 |
| 未验证范围 | 拔线瞬间回调是否安全返回；重插后是否自动重新枚举；`quarantine` 是否增长；多设备并发拔插 |
| 后续建议 | 按 P-1 执行一次真实拔插，记录 `quarantine`、underrun、设备行数与恢复时间 |
| 优先级 | **P2** |

### G-UI 双击 PKG 的 Gatekeeper GUI 批准路径（未测）

| 项 | 内容 |
|---|---|
| ID | G-UI（对应 U-18 的剩余部分） |
| 现象 | 本轮经 `installer` CLI（root）安装，**没有**触发双击 PKG 时的 Gatekeeper 交互流程 |
| 影响 | 文档中「系统设置 → 隐私与安全性 → 仍要打开」这条首次安装路径未被实测；不同 macOS 版本的拦截文案与按钮位置可能不同 |
| 当前状态 | **未测**（NOT_TESTED） |
| 已验证范围 | `spctl -a -t install -vv` 的 `rejected / source=no usable signature` 原文、`pkgutil --check-signature` 的 `no signature` 已记录；CLI 安装后载荷 109/109 一致 |
| 未验证范围 | 双击是否被拦截、批准后安装是否继续、以及与 CLI 安装的行为差异 |
| 后续建议 | 在一台干净机器上用 GUI 路径完整走一次，记录拦截界面与批准后的安装结果 |
| 优先级 | **P2** |

### 2A.1 对 §2 状态更新的依据

| 条目 | 旧状态 | 新状态 | 依据 |
|---|---|---|---|
| U-2 | 只有安装已验证 | 安装 + 同机卸载/重装已执行；跨版本升级与 `coreaudiod` 重启未测 | 发布报告 §11（卸载）、§12（安装） |
| U-16 | 完全未执行 | 同机闭环已执行；跨版本/跨机器未测 | 同上 + §21（重装后音量/静音/EQ 可用） |
| U-17 | NOT_VERIFIED | VERIFIED（单机、限定环境） | 发布报告 §18（`HALS_RemotePlugInRegistrar` + PID 48806 三探针） |
| U-18 | NOT_VERIFIED | 部分验证（CLI 路径完成，GUI 路径未测） | 发布报告 §12、§13、§14–§15 |

### 2A.2 后续维护优先级

| 优先级 | 事项 | 条目 |
|---|---|---|
| **P1** | 调查无 I/O 客户端窗口时音量/静音写入不提交 | OBS-1 |
| **P1** | 实现并验证 EQ 设置持久化 | OBS-2 |
| **P2** | 完善卸载后的 InstallerState、PKG 回执与 CoreAudio 生命周期处理 | OBS-3 |
| **P2** | 补充设备移除与重新枚举测试 | K5c / U-1 |
| **P2** | 补充标准 GUI 安装路径验证 | G-UI / U-18 |
| **P2（工程改进）** | 评估 PKG/DMG 封装层的可复现性 | OBS-4 |

本轮**不修复**以上任何一项：这份文档是记录，不是修复计划。修复需要单独的批次
与授权。

---

## 2B. 1.2.1（未发布）对 OBS-1 – OBS-3 的处理（2026-11-22）

工作树中已有针对 OBS-1 / OBS-2 / OBS-3 的实现与自动化测试，**尚未发布、尚未在
真实显示器上重跑**。`VERSION`、各 bundle 版本、PKG 版本、共享内存协议均未改变。
本节只登记「改了什么、凭什么、还差什么」，§2A 的历史记录保持原样。

**修订（2026-11-24）**：本节写于 2026-11-22。三项修复已于 2026-11-23 在验证机上复核，
上表「仍未验证」列里的真机条目由 [§2C](#2c-硬件实时验证登记2026-11-23) 覆盖，结论见
[RELEASE_NOTES](../RELEASE_NOTES.md) §4.3。标题与正文中的「未发布」只表示当时尚未打
tag：`VERSION` 已于 2026-11-24 改为 `1.2.1`（各组件版本同步），发布文档已按 1.2.1 定稿。

| 条目 | 工作树状态 | 依据（自动化） | 仍未验证 |
|---|---|---|---|
| OBS-1 | 已实现：写入后回读，UI 只显示设备报告的值；Host 把已接受的 scalar/mute 提交进共享内存 | `VolumeLevelCommitTests`、`ProxyVolumeCommitTests`；App 298 例、Host 398 例全绿 | 无播放会话时真机写入、App 滑块与键盘音量键两条入口、其它 macOS 版本 |
| OBS-2 | 已实现：单 key 字典 + 字段级校验 + 旧 keys 一次性迁移 + Reset 立即持久化；恢复值启动即下发 DSP | `EQPersistenceTests`（读真实 mmap 断言恢复值到达 `eq_snapshot` / `eq_sequence`）、`EQPropertyTests`、`EQRecoveryTests` | App/Host 重启后真机 EQ 数值、多设备 per-device 键、听感 |
| OBS-3 | 已实现：四阶段固定顺序、只停自有 Host、有界等待 + 同 pid 升级 SIGKILL、释放运行期 IPC、四态分列、回执只报告 | `tools/test_uninstall_lifecycle.sh`（19 组场景 / 99 断言，`--sandbox-root` 真实执行）、`UninstallLifecycleScriptTests`（源码不变量） | 对真实 HAL 目录、真实 Host、真实 `coreaudiod` 的卸载；MDM 环境 |

OBS-1 的「不提交」没有在驱动侧被证明已消除：本轮的处理是让 App 不再把未落地的
写入显示为成功，并让 Host 把已接受的值提前提交进共享内存，使下一次 `OnStartIO`
握手不再采用旧值。驱动的控制对象写入路径本身未改。

### B-1 从 1.2.1 降级到 1.2.0 会读到旧 EQ 值

| 项 | 内容 |
|---|---|
| 现象 | 1.2.1 把每台设备的 EQ 存为一个字典 key（`eq_<deviceUID>_state`），不再写 1.2.0 的四个 key（`*_bass_db` / `*_mids_db` / `*_treble_db` / `*_enabled`）。用 1.2.0 的 App 打开时，读到的是最后一次由 1.2.0 写入的旧值 |
| 影响 | 降级后 EQ 显示与 1.2.1 中最后一次设置不一致；不会损坏数据，1.2.1 的字典仍在 defaults 里 |
| 当前状态 | **已知限制**（升级方向不受影响：1.2.1 会读并迁移 1.2.0 的四个 key） |
| 恢复 | 重新升级到 1.2.1，值仍在；或在 1.2.0 里重新调节 |

### B-2 卸载器不删除 PKG 回执，也不清 InstallerState

| 项 | 内容 |
|---|---|
| 现象 | `tools/uninstall_driver.sh` 与 App 的卸载都**只报告** receipt `com.soundbridge.menubar` 与 `~/Library/Application Support/SoundBridge/InstallerState/`，不删除 |
| 影响 | 重装时 `preinstall` 仍可能走升级分支；用户需要自己判断是否清理 |
| 当前状态 | **设计取舍**：`pkgutil --forget` 不可逆且会改变后续安装的分类，卸载器不替用户决定 |
| 恢复 | 需要时手动 `sudo pkgutil --forget com.soundbridge.menubar`；InstallerState 由后续安装覆盖 |

### B-3 音量回读的容差只对代理设备生效

| 项 | 内容 |
|---|---|
| 现象 | 回读判定（请求值与设备值相差不超过 48 级 taper 的一级）只用于 SoundBridge 代理设备；物理设备仍以 HAL 返回状态为准 |
| 影响 | 第三方设备若「接受写入但不生效」，UI 仍可能显示请求值 |
| 当前状态 | **设计取舍**：第三方设备的量化粒度未知，按一级 taper 判定会误拒合法变化 |
| 恢复 | 若观察到物理设备上 UI 与实际不符，按 `os.log` 中的 `setVolume` 诊断行取证后登记 |

---

## 2C. 硬件实时验证登记（2026-11-23）

一次真实链路的端到端观测，也是目前唯一一次：默认输出切到代理设备 → 播放真实
测试音 → 30 分钟窗口采集 → 中段叠加 CPU 负载 → 恢复默认输出 → 正常退出 App。
下面的数字只在这一台机器、这一台设备、这一种格式上成立。

| 项 | 内容 |
|---|---|
| 被测设备 | `PHL 279M1RV (SoundBridge)`，代理 UID `410C54C2-…-0103803C2278-soundbridge`，物理输出 `410C54C2-…` |
| 格式 | 48 000 Hz / 512 帧 / 2 声道 → deadline 10 666.7 µs；运行期无格式变更（单一 bucket） |
| 窗口 | 180 × 10 s，`2026-11-23T08:13:10Z` – `08:43:10Z` |
| 回调 | 169 686 次；实测 93.7–93.8/s，期望 93.75/s，比值 1.00 |
| 超预算 | `overBudget` = 0；`max` = 322 µs 且从未饱和 |
| 欠载 / 溢出 | Driver underrun = 0，ring overrun = 0（`sb-shm-probe` 只读 mmap） |
| 负载 | 4 × `yes` 持续 300 s，覆盖 31 个窗口 / 29 531 次回调，`overBudget` 仍为 0 |
| 收尾 | 默认输出恢复为物理 `PHL 279M1RV`（写后回读 + 独立校验），App 与 Host 正常退出，代理设备与 mapping 均已释放 |

**harness 判定：`INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING`。** C1–C5、C7、C9
为 MET；**C6（Host / 设备恢复）未执行**——窗口内没有 hotplug 或 degraded 事件，H8
也未被标记；**C8（运行内默认输出恢复标记）未执行**；C10 因缺 C6、C8 为 UNMET。上表
「收尾」一行的默认输出恢复是采集结束后用独立回读确认的，不能当作 C8 的运行内标记。
所以这次运行只支持「该设备、该格式、该负载下没有回调超期」，不构成整体通过。

**未验证的部分，不得由上一段外推：**

- 采样率与缓冲区矩阵（44.1 / 48 / 96 kHz，128 / 256 / 512 / 1024 帧）**未执行**。
- 设备移除 / 重新枚举（H8）**未执行**，与 U-1 一致。
- 可听性（听感、爆音、断续）**无人工听者确认**，与 U-14 一致。
- `p99.9` **不可观测**：`TimingSnapshot` 只暴露 p50 / p95 / p99 / max。
- 热状态与 `cpu=` 读数**无分辨力**：`pmset -g therm` 无记录，`cpu=` 恒 0.0%。

---

## 3. C 类：需要后续工程修复

### 3.1 RT 违例（Driver 侧，RT-1 – RT-5）

| 编号 | 违例 | 状态 |
|---|---|---|
| **RT-1** | libASPL vendored 代码的递归 `ioMutex_` 出现在 HAL 回调链上 | 未处理 |
| **RT-2** | 回调内的日志调用（`RF_LOG_*` / `os_log`） | 未处理 |
| **RT-3** | 回调内的惰性缓冲分配 | 未处理 |
| **RT-4** | 回调内的格式重配置 | 未处理 |
| **RT-5** | `Retire()` 旧路径不做排空（已由 `RetireMapping()` 接管，条目未关闭） | 未处理 |

RT-1 – RT-5 属于**既有实现缺陷**，不是设计取舍。本轮（Closure Fix）只处理
了闸门本身，没有触碰回调体。

### 3.2 Host 侧 RT 问题（H-1 – H-3，已关闭）

这三项在 P2 Batch 4 关闭，保留记录以免重复登记：

| 编号 | 原问题 | 关闭方式 |
|---|---|---|
| **H-1** | 渲染回调内取 `os_unfair_lock`（`acquireMemory` 字典查找） | 回调改走 `enterRenderMemory()` / `exitRenderMemory()`，不再做字典查找；`acquireMemory` 仍存在，但只在控制面使用 |
| **H-2** | 首次渲染的一次性分配与 `print` | 改为无锁局部标志 + 固定计数；`drainDiagnostics()` 在控制线程输出 |
| **H-3** | 缓冲增长时分配 | 改为预分配 `renderBuffer` 的 `update(repeating:count:)` |

证据：批次报告已移出仓库；
`AudioRendererRTSafetyTests`、`RTObservabilityTests`（TEST_VERIFIED）。

**仍未验证**：以上只证明「不在回调内加锁/分配」，不证明真实负载下的丢帧率（U-6）
或听感（U-14、U-15）。

### 3.3 其它工程债

| 编号 | 问题 | 说明 |
|---|---|---|
| **F-1** | Float64 输入未实现 | 当前 fail-closed；若真实设备只提供 Float64 则无法工作 |
| **F-2** | 并发 `RetireMapping` 依赖 `io_mutex_`；`mapping_owner_` 是普通 `shared_ptr` | Closure Fix R-1 |
| **F-3** | 排空轮询由时间界驱动（50 µs × 250 ms） | 可用条件变量/信号量替代，但会引入丢失唤醒问题，需重新证明 |
| **F-4** | Quarantine 增长无告警 | 仅记日志，无计数阈值/上报 |
| **F-5** | 设备列表/音量控制面依赖 `/tmp` 文件轮询 | 无事件通知机制 |

### 3.4 已关闭的风险（保留记录，避免重复登记）

| 编号 | 原风险 | 关闭方式 |
|---|---|---|
| R1（Batch 2） | token 熵不足（约 31 位、可预测） | Batch 2 Closure CR-1：64 位 CSPRNG + 8 次有界重试 + fail-closed |
| RR-1（Batch 3） | 双原子 `CallbackGate` 跨对象顺序不可证 | Closure Fix：单原子状态字 + 4 处 `is_always_lock_free` |
| PoC R7 / R15 | `read_index` 有两个写者（溢出时生产者回写） | Batch 0/1：删除 Drop-Old；现存只有初始化与 `rf_ring_read` 两处写入 |

已关闭项**不得**再被当作当前风险引用；保留它们只为解释历史。

---

## 4. D 类：未来产品测试要求

| 编号 | 要求 | 通过判据 |
|---|---|---|
| **P-1** | 真实设备移除矩阵 | 播放中拔出 HDMI/DP；回调不崩溃；`quarantine` 计数应为 0 |
| **P-2** | 真实安装/卸载/升级 | 安装 → 播放 → 卸载 → 重装；旧 inode 不复活 |
| **P-3** | 长时间稳定性 | ≥ 8 小时连续播放；观察丢帧率、quarantine 增长、内存增长 |
| **P-4** | 多设备并发 | 两台 HDMI 设备同时播放；互不干扰 |
| **P-5** | macOS 14.4 认证 | 在 14.4 上完成 P-1…P-4 |
| **P-6** | Host / App 全量回归 | `swift test` 全绿 + UI 冒烟 |
| **P-7** | 真实负载下的排空预算 | 高负载（低 buffer size）下设备移除仍能证明排空 |
| **P-8** | `coreaudiod` 重启 | 重启后能通过一次 IO 重启恢复（验证 L-6 的实际影响） |
| **P-9** | **未签名发布在真实 Mac 上的可安装性与驱动加载** | 在一台干净的 Apple silicon Mac 上：手动批准 Gatekeeper → 安装 PKG → 确认驱动落在 HAL 目录 → 确认 `system_profiler SPAudioDataType` 出现 SoundBridge → 播放 30 分钟。macOS 14 与一台 Intel Mac 各做一次；记录 `spctl`、`pkgutil --check-signature`、`codesign -dv` 的原始输出 |

### 4.1 P-1 – P-9 的执行状态（截至 1.2.0 发布验证）

| 要求 | 状态 | 说明 |
|---|---|---|
| P-1 设备移除矩阵 | **未执行** | K5c 被用户跳过；见 §2A |
| P-2 真实安装/卸载/升级 | **部分执行** | 安装、卸载、同机重装已执行；跨版本升级未执行 |
| P-3 长时间稳定性 | **部分执行** | 31 分 01 秒（89,320,455 帧）零欠载/零溢出；未达 ≥8 小时 |
| P-4 多设备并发 | **未执行** | 两个代理设备同时播放未测 |
| P-5 macOS 14.4 认证 | **未执行** | 只在 macOS 27.2.1 上运行 |
| P-6 Host / App 全量回归 | **已执行** | Host 379 / App 253 全绿（自动化回归） |
| P-7 真实负载下的排空预算 | **未执行** | 低 buffer / 高负载未测 |
| P-8 `coreaudiod` 重启 | **部分执行** | `killall coreaudiod` 后驱动被重新加载（发布报告 §16）；「重启后由 Host 侧自动恢复」未单独判定 |
| P-9 未签名发布可安装性与驱动加载 | **部分执行** | 已完成：CLI 安装、HAL 落盘、驱动加载三探针、31 分钟播放。未完成：GUI 批准路径、macOS 14、Intel Mac |

「部分执行」不等于通过：每一行的缺失部分都仍按未验证处理。

---

## 5. P4 Batch 1A 明确未执行的项

以下活动**没有**在本批次执行，不得在任何文档中被表述为已执行：

- 真实 Driver 安装 / 卸载 / 升级
- `coreaudiod` 重启
- 真实设备插拔与多设备并发
- 真实播放与 EQ 听感评估
- macOS 14.4 认证
- `make release`、`make clean` 与任何重建 `dist/` 的操作

本批次执行过的：`swift test`（Host 379 / App 253）、`make test-installer-gate`、
`make test-release-payload`（244 断言）、`make verify-installer-pkg`、
`make verify-payload`。该批次的原始输出已随阶段报告移出仓库。

## 6. 状态汇总

| 类别 | 数量 | 说明 |
|---|---|---|
| A 已知实现限制 | 13（L-1 – L-13）+ OBS-4 | 设计取舍，不修；L-13 是「完全未签名」发布策略 |
| B 尚未验证 | 18（U-1 – U-18，U-4 已关闭）+ K5c + G-UI | U-2（安装/卸载/重装）、U-14、U-15、U-18 已部分取证；**U-17 在单机限定环境下已验证**；其余按发布策略作为已披露限制，不阻断 1.2.0 |
| C 需要工程修复 | 10（RT-1 – RT-5、F-1 – F-5）+ OBS-1 + OBS-2 + OBS-3（回执部分） | 有明确动作；H-1 – H-3 已关闭 |
| D 产品测试要求 | 9（P-1 – P-9） | P-6 已执行，P-2/P-3/P-8/P-9 部分执行，其余未执行（§4.1） |
| 已关闭（历史） | 3 + 7 | 3 项历史风险 + 本文 §0 的 7 项 |

**没有任何一条「未验证」因发布或归档而变成「已验证」。** 1.2.0 发布验证（§2A）
只把明确写出证据范围的条目升了级：U-17 是「单机 VERIFIED」，U-2/U-16/U-18 是
「部分验证」，OBS-1 – OBS-4 是新增登记项而不是关闭项。

## 7. 相关文档

- 发布事实与原始证据：[release/SoundBridge-1.2.0-Final-Release-Report.md](../release/SoundBridge-1.2.0-Final-Release-Report.md)
- 发布后验证结果：[release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md](../release/SoundBridge-1.2.0-Post-Release-Validation-Addendum.md)
- 架构与机制：[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
- 阶段报告的去向：见 [README.md](../README.md) §6
- 开发与测试入口：[development/DEVELOPMENT_GUIDE.md](../development/DEVELOPMENT_GUIDE.md)
- 文档总索引：[README.md](../README.md)
