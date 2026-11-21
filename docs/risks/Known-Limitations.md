# Known Limitations 与剩余风险

本文件是 SoundBridge 1.2.0 **未解决问题**的唯一登记处。归档不改变任何风险
状态：凡是 Batch 0–3 与 Closure Fix 报告中未关闭的事项，都在这里以未关闭
状态保留。

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

| 编号 | 原问题 | 结论 | 证据 |
|---|---|---|---|
| P2-B2 | 默认输出设备被 App 隐式抢占 / 无所有权模型 | 已实现所有权判定，只在用户显式操作时切换 | [P2-Batch-2-Default-Output-Governance-Report.md](../P2-Batch-2-Default-Output-Governance-Report.md)；`DefaultOutputGovernanceTests`、`DefaultOutputTrackingTests`、`DefaultOutputSwitchTests`（TEST_VERIFIED） |
| P2-B3 | Host 重新发布映射后 EQ 停在 `eq_sequence = 0` | 已实现自动恢复：`mappingPublished` + 代际比对后重写 EQ | [P2-Batch-3-EQ-Mapping-Reliability-Report.md](../P2-Batch-3-EQ-Mapping-Reliability-Report.md)；`EQRecoveryTests`（TEST_VERIFIED） |
| P2-B4 | 渲染回调内的锁、一次性分配与 `print`（原 H-1、H-2、H-3） | 回调改为 `enterRenderMemory`（无字典锁）+ 预分配缓冲 + 计数器；诊断输出移到控制线程 | [P2-Batch-4-AudioRenderer-RT-Safety-Report.md](../P2-Batch-4-AudioRenderer-RT-Safety-Report.md)；`AudioRendererRTSafetyTests`、`RTObservabilityTests`（TEST_VERIFIED） |
| P3-HR | Host 退出会导致 App 退出；无法只重启 Host | 已实现 `HostSupervisor` + `HostRestartEntry`（仅重启 Host，卸载/终止期间拒绝） | [P3-Host-Restart-Entry-and-Recovery-Validation-Report.md](../P3-Host-Restart-Entry-and-Recovery-Validation-Report.md)；`HostSupervisorTests`、`HostRestartEntryTests`（TEST_VERIFIED）；Host 重启闭环在真实 macOS 上执行过一次（REAL_MACOS_VERIFIED，范围仅限进程重启） |
| P4-1A-1 | App 内存在第二套特权安装事务 | 已删除；App 只读检测，安装交给 PKG | [P4-Batch-1A-Source-Stabilization-Report.md](../P4-Batch-1A-Source-Stabilization-Report.md)；`DriverInstallBoundaryTests`（TEST_VERIFIED） |
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

---

## 2. B 类：尚未验证

P4 Batch 1A 起，每条未验证事项都带**证据位置**：要么是已执行过的报告，要么写明
「无任何报告」——后者本身就是没有证据的证明。

| 编号 | 未验证事项 | 现状 / 证据位置 |
|---|---|---|
| **U-1** | **真实 HAL 设备移除**（播放中拔 HDMI/DP） | 无任何真实设备报告。自动化只覆盖状态机（`GracefulShutdownTests`），不覆盖拔线 |
| **U-2** | 真实 Driver 部署：安装、卸载、升级、`coreaudiod` 重启 | **安装已真机验证**（Batch 3A §R2.9#2：首次安装分支 + receipt 1.2.0）；卸载、升级、`coreaudiod` 重启仍未在真实 macOS 上走通 |
| **U-3** | **macOS 14.4 认证**（当前只在 27.2.1 上运行） | 无 14.4 环境报告 |
| **U-4** | Host / App 完整回归 | **已验证并关闭**：Host 379 / App 253 全绿，见 [P3-Final-Closure-Fix-Report.md](../P3-Final-Closure-Fix-Report.md) §「回归规模」 |
| **U-5** | x86_64 真机运行（仅有 universal 产物） | 无 Intel 机器报告；`verify_*_contents.sh` 只确认架构切片存在 |
| **U-6** | 真实负载下的 xrun 率与丢帧率 | 无真实负载基线。计数器已实现（`rf_rt_counters_note_underrun`），但只在测试里读过 |
| **U-7** | Quarantine 长期增长曲线 | 无 ≥ 8 小时运行记录 |
| **U-8** | 多设备并发退役 / 热插拔 | 无 |
| **U-9** | Driver 重载后旧 ACK 是否可能复活 | 无 |
| **U-10** | A0：原子硬件行为在全部目标架构 | 编译期属性已知；无运行时验证 |
| **U-11** | 真实 Host 崩溃后由真实 Driver 重新附着的完整流程 | Host 重启闭环已验证（[P3-Host-Restart…报告](../P3-Host-Restart-Entry-and-Recovery-Validation-Report.md)），但「崩溃 → 重新附着」未覆盖 |
| **U-12** | `/tmp` 被系统清理工具删除共享文件后的行为 | 无 |
| **U-13** | HAL 沙箱下 Driver 对 bundle 外文件的读取权限 | 无真实 HAL 验证 |
| **U-14** | **实际 EQ 听感** | **已有用户主观听感确认**（Batch 3A §10、§R2.9#7：各频段调整与 Reset 可听辨、符合预期；30 分钟播放无爆音/断续）；**没有频响 / 相位 / 削波测量**，跨设备与跨内容、旁通/启用切换未取证。**不得**声称音质已通过测量 |
| **U-15** | **播放窗口 underrun** | 默认 buffer 下 **30 分钟零 underrun 增量**（Batch 3A §11、§R2.9#8）；低 buffer / 高负载未测；计数器无法区分空闲与播放期（Batch 3B O-3） |
| **U-16** | **真实卸载/重装闭环** | PKG **安装**已真机验证（Batch 3A §R2.9#2）；「卸载 → 重装 → 恢复 EQ/音量」整条路径仍未执行，**无证据** |
| **U-17** | **未签名 HAL 驱动能否被 `coreaudiod` 加载** | **NOT_VERIFIED**。构建成功、PKG 生成与载荷校验、`preinstall` 不含签名依赖，均已验证；但这三项**不能**证明系统会接受未签名驱动的加载。未在 macOS 14、未在任何 Intel Mac、未在受管控设备上验证。详见 [INSTALLATION_GUIDE](../INSTALLATION_GUIDE.md) §5.3 |
| **U-18** | **未签名 PKG 在真实机器上的安装全流程** | **NOT_VERIFIED**。`pkgutil`/`spctl` 输出与载荷结构已验证；手动批准 Gatekeeper 拦截、真实写入 HAL 目录、安装后首次发声，均未在本版本上执行 |

U-4 已由自动化测试关闭；U-14、U-15 与 U-2 的安装部分已取得真机证据（部分关闭）。
其余未验证项（U-1、U-3、U-5、U-7、U-8、U-16 等）按发布策略作为**已披露限制**，
不阻断 1.2.0。

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

证据：[P2-Batch-4-AudioRenderer-RT-Safety-Report.md](../P2-Batch-4-AudioRenderer-RT-Safety-Report.md)；
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
`make verify-payload`。输出见 [P4-Batch-1A-Source-Stabilization-Report.md](../P4-Batch-1A-Source-Stabilization-Report.md)。

## 6. 状态汇总

| 类别 | 数量 | 说明 |
|---|---|---|
| A 已知实现限制 | 13（L-1 – L-13） | 设计取舍，不修；L-13 是「完全未签名」发布策略 |
| B 尚未验证 | 18（U-1 – U-18，U-4 已关闭） | 其中 U-2（安装）、U-14、U-15 已部分取证；U-17/U-18 为未签名发布新增，其余按发布策略作为已披露限制，不阻断 1.2.0 |
| C 需要工程修复 | 10（RT-1 – RT-5、F-1 – F-5） | 有明确动作；H-1 – H-3 已关闭 |
| D 产品测试要求 | 9（P-1 – P-9） | 发布前活动 |
| 已关闭（历史） | 3 + 7 | 3 项历史风险 + 本文 §0 的 7 项 |

**没有任何一条「未验证」因归档而变成「已验证」。** U-2（安装）、U-14、U-15 的升级
来自 P4 Batch 3A 新增真机证据，不是归档；其余仍按原等级保留。

## 7. 相关文档

- 架构与机制：[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
- 各批次结论：[verification/](../verification/)
- 迁移记录：[Documentation-Migration-Manifest.md](../Documentation-Migration-Manifest.md)
