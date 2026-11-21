# SoundBridge 1.2.0 — P2 Batch 4 执行报告
## AudioRenderer Real-Time Safety & Remaining Product Defects

| 项 | 值 |
| --- | --- |
| 仓库 | `/path/to/SoundBridge` |
| 基线提交 | `ab36770` (`docs: point at SHA256SUMS.txt instead of copying hashes`)，tag `v1.2.0` = `782a57a` |
| 仓库 VERSION | `1.2.0` |
| 协议版本 | `0x00020200` (131584)，4 份 header 副本一致 |
| 执行日期 | 2026-11-20 |
| 最终判定 | **CONDITIONAL PASS**（32 条离线证据全部满足；3 项只能由真实 macOS 验证，见 §17） |

---

## 0. 结论摘要

四组任务全部落地，未扩展范围：

| 组 | 内容 | 结论 |
| --- | --- | --- |
| A | AudioRenderer RT Safety | 确认 7 类 RT 缺陷，全部修复；19 项 RT 测试全绿 |
| B | DSP / Audio Pipeline 审计 | 回调链无分配/无日志/无 FS；DSP 仅 stereo、非 bit-exact、`set_sample_rate` 已移出回调时序 |
| C | Batch 3 Mapping Release 收尾 | munmap 归属 attachQueue，7 项线程归属测试证明实际执行线程；每次 incarnation 恰好一次 |
| D | 两个产品缺陷 | `uninstall_driver.sh` 不再终止 coreaudiod；发布验证默认目标改由 `VERSION` 驱动，stale bundle 从"选择器"变成"FAIL" |

`make test` **EXIT=0**（protocol-check / version-check / DSP 1/1 / Driver 3/3 / Host 350 / App 202 / installer 32 场景 / codesign 58 检查）。

---

## 1. 初始 Git 基线

```
$ git -C . log --oneline -3
ab36770 (HEAD -> main, origin/main, origin/HEAD) docs: point at SHA256SUMS.txt instead of copying hashes
782a57a (tag: v1.2.0) test: make the signing-argument suite run on a clean checkout
a43e64e release: SoundBridge 1.2.0
```

工作区状态：Batch 1–4 的改动**全部处于未提交状态**（tracked 修改 57 项以上，untracked 新文件数十项）。
本批次未执行任何 `git add / commit / stash / reset / clean / checkout / restore`，也未执行 `make clean`。

`dist/` 基线（本批次只读）：

| 文件 | 大小 | mtime | SHA-256 |
| --- | --- | --- | --- |
| `dist/SoundBridge-1.1.1.pkg` | 13955957 | Nov 17 00:11 | `e05a8eef8ebf2343c9709634ae37b5cdcb6c771e726712a7792cd4e9d0ec8756` |
| `dist/SoundBridge-1.1.1.dmg` | 14824537 | Nov 17 15:11 | `3f923c63d752ec3d786374cfa33f6415d668e5c86707e66acf889459c4e3572d` |
| `dist/SoundBridge.app/Contents/Info.plist` | — | Nov 16 22:24 | `e6c2f5ddd3a175e14c218707c2b1faa6fd9756e8eaa5b4d2c51098c1e46cf9eb` |

`dist/` 内 bundle 是 **1.1.1**，而源码树与 `VERSION` 是 **1.2.0** —— 这就是 §10 要处理的污染现场。
mtime 只作为佐证，不作为判定依据（§7 明确禁止以 mtime 作唯一判断）。

---

## 2. AudioRenderer 完整 callback 调用链

真实入口只有一个。`AudioEngine.swift:336` 把 `renderer.createRenderCallback()` 装进
`AURenderCallbackStruct` 交给 `kAudioUnitProperty_SetRenderCallback`，此后 CoreAudio 的 IO 线程
直接调用该 C 函数指针：

```
CoreAudio IO thread
└─ AURenderCallback closure                      AudioRenderer.swift:250
   ├─ guard ioData != nil
   ├─ Unmanaged.fromOpaque(inRefCon).takeUnretainedValue()   // 不 retain，无 ARC 分配
   └─ renderer.render(bufferList:frameCount:)    AudioRenderer.swift:275
      ├─ UnsafeMutableAudioBufferListPointer(bufferList)      // 结构体包装，无分配
      ├─ diagnostics.hasRecordedFirstPass          (os_unfair_lock，读一个 Bool)
      ├─ [仅首次] diagnostics.recordFirstPass      (os_unfair_lock + 4 次 UInt32 赋值，无数组)
      ├─ 容量守卫  frameCount <= 32768 && channels <= 8
      │     └─ 失败 → noteCapacityExceeded + outputSilence → return
      ├─ memoryManager.enterRenderMemory()         SharedMemoryManager.swift:419
      │     └─ os_unfair_lock(renderLock){ 取指针; renderInFlight += 1 }
      │     └─ 失败 → noteMemoryUnavailable + outputSilence → return
      ├─ defer { memoryManager.exitRenderMemory() }            // 保证映射在整个 body 内有效
      ├─ ringChannels == channelCount 守卫         (不匹配 → noteChannelMismatch + 静音)
      ├─ renderBuffer.update(repeating:0,count:)   // memset，预分配缓冲，无分配
      ├─ rf_ring_read(mem, renderBuffer, frameCount, &zeroFilled)   // C，单读者
      │     └─ zeroFilled > 0 → noteUnderrun(frames:)
      ├─ [stereo 且 framesRead>0]
      │  ├─ rf_load_eq_snapshot(mem, &snap)        // 结构体拷贝，无分配
      │  ├─ memcmp(new, old, sizeof)               // 变化检测
      │  ├─ 变化时：soundbridge_dsp_update_band_gain ×10 / preamp / bypass
      │  └─ soundbridge_dsp_process_interleaved(engine, buf, buf, framesRead)
      ├─ rf_load_volume_scalar / rf_load_mute_state
      ├─ VolumeTaper.sanitize → VolumeTaper.gain   // 纯算术
      ├─ 逐帧一阶平滑增益（当前为标量状态，无分配、无分支放大）
      └─ deinterleave(...)                         AudioRenderer.swift:512
         └─ 每通道：readable = min(framesRead, capacity); total = min(totalFrames, capacity)
```

**唯一进入共享内存的路径**是 `enterRenderMemory()/exitRenderMemory()`。回调不再读取
`proxyManager`（那是一条需要 `lock` 的路径），路由变化由主线程
`main.swift:36` → `memoryManager.setPreferredRenderUID(uid)` 推入发布槽。

回调内不出现的东西（静态审查，全部 544 行）：

- 任何 `print` / `os_log` / `Logger` 调用；
- 任何 `Array(` / `String(` / 插值 / `map` / `filter` / `reduce`；
- 任何 `malloc`/`free`/`Data`/`Dictionary` 写入；
- 任何文件、`UserDefaults`、`Process`、`Date` 之外的系统调用（`Date` 也不在回调内）；
- 任何 `DispatchQueue.sync`、`semaphore.wait`、`Thread.sleep`、`usleep`；
- 任何 `deinit` 可达的释放路径（`renderBuffer` 只在 `AudioRenderer.deinit` 释放）。

---

## 3. RT Safety 审计表

| # | 审计点 | 基线（HEAD `ab36770`） | 现状 | 证据级别 |
| --- | --- | --- | --- | --- |
| 1 | 回调内日志 | `print("[AudioRenderer] First render …")`、`print` 于音量/EQ 分支 | 回调内零日志；诊断进计数器 | 已通过自动化验证（`testSteadyStateCallbacksDoNotAllocate` + 源码） |
| 2 | 分配 | `Array(UnsafeBufferPointer(...))` 形式的 per-callback 数组（首帧路径） | 预分配 32768×8 Float；首帧仅 4 个 UInt32 | 已通过自动化验证 |
| 3 | 释放 | 回调内随 `Array` 释放 | 无 | 静态审查 + malloc 统计测试 |
| 4 | 访问 proxyManager（持 `lock`） | 每回调读 `proxyManager.activeProxyUID`（`NSLock` + String） | 改读 `renderLock` 保护的裸指针 | 已通过自动化验证 |
| 5 | 映射生命周期 | 映射可能在回调中途被 munmap | `renderInFlight` 计数，publication 在 busy 时挂起 | 已通过自动化验证 |
| 6 | 错误路径 | 直接 `logger.error`（回调内） | 计数器 + 控制线程 `drainDiagnostics()` | 已通过自动化验证 |
| 7 | 输出静音回退 | 部分分支 return 时未清零 | 所有 early-return 均 `outputSilence` | 已通过自动化验证 |
| 8 | 下溢补零 | 依据 `framesRead` 而非 `frameCount` | `deinterleave` 对 `[readable, total)` 显式补零 | 已通过自动化验证（`testRingUnderflowZeroFillsOnlyTheTail`） |
| 9 | 短缓冲越界 | `framesRead > capacity` 时构造倒置区间 → IO 线程 trap | 两端先 clamp 到 capacity | 已通过自动化验证（`testShortOutputBufferIsNeverWrittenPastItsCapacity`） |
| 10 | 通道数不匹配 | 按 `buffers.count` 直接解交织 | `ringChannels == channelCount` 守卫 | 已通过自动化验证（`testEightChannelBlockThatTheRingCannotServeIsSilence`） |
| 11 | 超大块 | 无上界检查，写穿 `renderBuffer` | `frameCount <= 32768` + 通道 ≤ 8，拒绝并静音 | 已通过自动化验证（`testBlockLargerThanCapacityIsRefusedWithSilence`、`testNineChannelBlockExceedsTheABIChannelCeiling`） |
| 12 | DSP 采样率更新 | 在 IO 单元运行中调用 `soundbridge_dsp_set_sample_rate` | 移到 `AudioOutputUnitStop` 之后 | 静态审查（`AudioEngine.swift:219`） |
| 13 | EQ 变化检测 | 每次比较都构造数组 | `memcmp` 于两个栈上快照 | 静态审查 + `testDSPRunsOnStereoAndStaysBounded` |

---

## 4. 确认的 RT 缺陷与修复

### 4.1 回调内日志（缺陷 1）

`render()` 在首帧调用 `print`，在容量/通道错误分支调用 `logger.error`。`os_log` 在 IO 线程上可能
触发格式化、IPC 与后台服务唤醒，是教科书式的 RT 违规。

**修复**：新增 `RenderDiagnostics`（`AudioRenderer.swift:17`）。回调只做"计数器 +1"，锁是
`os_unfair_lock`，临界区 1–3 条 store。所有格式化/打印搬到
`drainDiagnostics()`（`:215`），由主队列的 connection poll 调用（`main.swift:1087`）。
它按"增量"输出：一个每帧都复发的故障只写一行，不会变成每秒一条。

> 说明：这道 drain 是本批次补上的。若只把日志从回调里删掉而没有消费者，`noteMemoryUnavailable`
> 之类的计数就会记录下来却永远没人读，"拒绝一个块"和"正常静音"在产品上无法区分。这是本次
> 改动自查发现并当场修掉的回归。

### 4.2 动态分配（缺陷 2）

基线在首帧用 `[UInt32]` 收集 buffer 尺寸；每次 `render` 通过 `UnsafeMutableAudioBufferListPointer`
的 `enumerated()` 也会产生临时序列。

**修复**：首帧尺寸改存固定四元组 `(UInt32,UInt32,UInt32,UInt32)`；`snapshot()` 才构造数组
（控制线程）。混音缓冲在 `init` 一次性 `allocate`，`deinit` 一次性 `deallocate`。

### 4.3 锁竞争（缺陷 3）

基线每次回调都读 `proxyManager.activeProxyUID`，那是 `NSLock` + `String` 比较，且与设备增删同一把锁。

**修复**：`SharedMemoryManager` 增加"渲染发布槽"：

```swift
func enterRenderMemory() -> UnsafeMutablePointer<RFSharedAudio>? {
    os_unfair_lock_lock(&renderLock)
    let pointer = renderPointer
    if pointer != nil { renderInFlight += 1 }
    os_unfair_lock_unlock(&renderLock)
    return pointer
}
```

锁序固定为 `lock` → `renderLock`；回调**只**取 `renderLock`，任何线程都不会在持有 `renderLock`
时去取 `lock`（`SharedMemoryManager.swift:93`）。因此回调不会排在任何设备枚举/重连之后。

### 4.4 可用性问题：映射在回调中途失效（缺陷 4）

基线中回调持有裸指针期间，控制线程可以 `munmap`（设备移除、Host 退出）。

**修复**：`publishRenderMapping()` 发现 `renderInFlight != 0` 时不交换，只把新映射记到
`renderPendingMapping` 并返回 `false`；1 Hz 心跳调用 `drainDeferredRenderPublication()`
重试；`retireRenderPath(timeout:)` 在退出时先取消发布再有界自旋等回调离开。munmap 只发生在
"确认 `renderInFlight == 0`"之后，且发生在那条控制线程上。

### 4.5 错误路径未静音 / 静音未计数（缺陷 5）

基线若干 early-return 直接把 `ioData` 留给 CoreAudio（内容未定义）。现在每条 early-return
都走 `outputSilence()`，并记录对应计数器（capacity / channelMismatch / memoryUnavailable）。

### 4.6 短缓冲导致倒置区间（缺陷 6）

```swift
// before（反相区间 → 运行时 trap，位置在 IO 线程）
for i in readable..<total { … }
// after
let readable = min(Int(framesRead), capacity)
let total = min(Int(totalFrames), capacity)
if readable < total { for i in readable..<total { data[i] = 0 } }
```

### 4.7 DSP 采样率更新与 IO 线程的竞争（缺陷 7）

`soundbridge_dsp_set_sample_rate` 重建全部 biquad 系数，DSP 自己文档标注"NOT realtime-safe"。
基线在 `AudioOutputUnitStop` **之前**调用它，与 IO 线程的 `process_interleaved` 构成对滤波器状态的
数据竞争。现在移动到 `AudioOutputUnitStop` 之后（`AudioEngine.swift:219`），紧邻设备切换。

---

## 5. Buffer 容量设计

```swift
static let maxSupportedSampleRate: UInt32 = 192_000          // AudioEngine 会绑定的最高速率
static var maxCallbackFrames: Int {
    Int(rf_ring_capacity_frames_for(maxSupportedSampleRate, defaultDurationMs))
}                                                            // = 32768
static let maxCallbackChannels = 8                            // ABI 声明 channels 1-8
```

| 项 | 值 | 依据 |
| --- | --- | --- |
| 最大帧数 | 32768 | 冻结的 `rf_ring_capacity_frames_for(192000, 100ms)`；回调节点不可能被要求比 ring 能容纳的更多 |
| 最大通道 | 8 | `RFSharedAudio` 头文件 `channels` 的 ABI 上限 |
| 预分配 | 32768 × 8 × 4 B = 1 MiB | 一次性 `allocate`，`init` 中 |
| 超限处理 | 拒绝 + 全通道静音 + `capacityExceeded += 1` | 不截断：ring 会写 `frames*channels`，截断等于把后半段丢到别处 |

`testCapacityDerivesFromTheFrozenRingHelper` 断言 `renderCapacityFrames` 与 C 助手推导值一致，
因此"容量是多少"不是本报告的口头数字，而是被测代码的常量关系。

---

## 6. DSP 实时安全分析

| 问题 | 结论 | 证据 |
| --- | --- | --- |
| 是否分配 | `soundbridge_dsp_process_interleaved` 原地处理，无分配 | C 源码 + 19 项 RT 测试无 malloc 增长 |
| 是否加锁 | 无锁；参数通过 `update_band_gain` / `update_preamp` / `set_bypass` 写入 | 源码 |
| 循环是否有界 | 按 `framesRead × 2` 线性，无数据相关分支退化为重试 | 源码 |
| 参数更新是否 RT-safe | `soundbridge_dsp_update_*` 是简单 store；`set_sample_rate` 不是，已移出回调时序 | §4.7 |
| 通道假设 | **仅 stereo**（内部 `i*2` 索引）。非 stereo 直接跳过 DSP，而不是按猜测的布局喂入 | `AudioRenderer.swift:321` |
| 是否 bit-exact | 不是：含 DC blocker。只有 `bypass` 时才是 memcpy 直通 | `testDSPRunsOnStereoAndStaysBounded` 断言"有界"而非"逐位" |

**没有做的事**：没有改 DSP 的滤波器实现、没有改 `_reserved` 布局、没有把 DSP 换成无分支实现。
`packages/dsp` 在本批次零改动。

---

## 7. Error Path 分析

| 故障 | 回调行为 | 记录 | 产品可见性 |
| --- | --- | --- | --- |
| `ioData == nil` | 直接 return `noErr` | 无（CoreAudio 不会这样调用） | — |
| 块超大 / 通道超 ABI | 全通道写 0 | `capacityExceeded` | 下一次 drain 记 error |
| 无已发布映射 | 全通道写 0 | `memoryUnavailable` | 同上 |
| ring 通道数与输出不符 | 全通道写 0 | `channelMismatch` | 同上 |
| ring 下溢 | 已读部分正常，尾部补零 | `underrunFrames`（累计帧数） | 不报错：欠载是正常工况 |
| 短输出缓冲 | clamp 到 `mDataByteSize` | 无（设备给的容量即事实） | — |
| `exitRenderMemory` 不配对 | 不可能：`defer` 绑定在 `enter` 成功的分支内 | — | — |

所有记录都是 `os_unfair_lock` + 一条 `&+=`，无格式化、无分配、无日志。

---

## 8. Mapping Release 线程归属

### 8.1 设计

`SharedMemoryMappingManager`（App 侧）新增 `DispatchSpecificKey` 判定：

```swift
let onAttachQueue = DispatchQueue.getSpecific(key: attachKey) != nil
if onAttachQueue { unmapNow() } else { attachQueue.async { unmapNow() } }
```

即：**已在 attachQueue 上直接执行（不能 `async` 排队等自己），否则投递到 attachQueue**。
`UnmapLedger` 为每个 incarnation 记录 `{generation, inode, inline, executor}`，`executor` 是真正
执行 `munmap` 的 pthread 标识 —— 测试断言的是这个字段，而不是源码里是否出现过 `DispatchQueue.async`。

### 8.2 §5.3 八项与测试对应

| 要求 | 测试（`SharedMemoryMappingUnmapThreadTests`，7 项全绿） |
| --- | --- |
| 1. 最后一个 lease 由独立 writer 线程释放 | `testLastLeaseReleaseUnmapsOnTheAttachQueueNotTheWriter` |
| 2. 由 UI 模拟线程释放 | 同上（UI 模拟线程不是 attachQueue，必须排队） |
| 3. 已 retired 后重复 retire | `testEachIncarnationIsUnmappedExactlyOnce` |
| 4. 多线程同时释放 lease | `testReleaseHappensOnlyAfterTheLastConcurrentLease` |
| 5. 多次尝试触发最终释放 | `testEachIncarnationIsUnmappedExactlyOnce` + `testWritingAfterRetirementTargetsTheNewIncarnationAndQueuesNoSecondUnmap` |
| 6. stop 与 pending unmap 同时发生 | `testStopDrainsEveryQueuedUnmapBeforeReturning` |
| 7. 释放任务执行前 Mapping 仍有效 | `testWriterPathNeverWaitsForAPendingUnmap`（writer 不阻塞）+ lease 计数 |
| 8. munmap 恰好执行一次 | `testEachIncarnationIsUnmappedExactlyOnce` |

补充：`testRetirementFromTheAttachQueueUnmapsWithoutQueueingBehindItself` 覆盖 inline 分支 ——
如果只写 `attachQueue.async`，这一条会死锁而不是变慢。

### 8.3 与 Batch 3 不变式的关系

lease 语义、incarnation 编号、retirement 顺序均未修改；本批次只改"最后一个 lease 由谁执行
`munmap`"。Host 侧对应的是 `publishRenderMapping` 的 `withExtendedLifetime(released)`：引用在
锁外、控制线程上释放。

> **真实线程验证边界**：测试证明的是"释放任务落在 attachQueue 的策略线程上"，不是真实 App
> 在真实设备移除时的行为（那需要 P3）。

---

## 9. uninstall_driver.sh 审计

### 9.1 基线问题

基线脚本只有 18 行，核心是一句：

```bash
osascript -e 'do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver; killall coreaudiod" with administrator privileges'
```

四个问题：

1. **无条件终止 coreaudiod**：不论驱动是否存在、路径是否正确，都会杀掉系统音频守护进程，影响机器上所有音频应用。
2. **路径硬编码且无校验**：`rm -rf` 的目标不验证类型、不验证 identity，符号链接或路径被换掉时后果不可逆。
3. **失败不可见**：`do shell script` 的退出码被 `osascript` 吞掉，脚本仍然成功返回。
4. **没有预览**：用户无法在执行前看到将发生什么。

### 9.2 修复后行为

| 场景 | 行为 | 退出码 |
| --- | --- | --- |
| 目标不存在 | 打印"nothing to remove"，**不**动 coreaudiod | 0 |
| 目标是符号链接 | 拒绝 | 1 |
| 目标存在但不是目录 | 拒绝 | 1 |
| 目录内无 `Contents/Info.plist` | 拒绝 | 1 |
| bundle id ≠ `com.soundbridge.driver` | 拒绝 | 1 |
| 正常目录 | 预览 `sudo rm -rf <固定路径>`，经 osascript 管理员提示删除 | 0 |
| 删除后复查仍存在 | 报失败 | 1 |
| `SB_DRIVER_PATH` 指向非默认路径 | 必须同时 `--dry-run`，且 basename 必须是 `SoundBridgeDriver.driver` | 2 |
| 未知参数 | 用法错误 | 2 |

关键改动：

- `killall coreaudiod` **从脚本中删除**。驱动改为监听 mapping 变化后，不再需要重启守护进程来
  发现 Host 退出；脚本只打印建议：
  ```
  • run this by hand: sudo killall coreaudiod
  ```
  提示文案是 "After the bundle is gone, …"，因此在 `--dry-run` 下语义也正确。
- 只有默认路径 `DEFAULT_DRIVER_PATH` 会真正删除；`SB_DRIVER_PATH` 是**预览专用接缝**，强制
  `--dry-run`，本批次的所有测试都走它，没有一次真实删除。
- 删除后用文件系统（不是退出码）复查结果。

### 9.3 自测（8 个 fixture 场景，无 sudo、无真实删除）

```
missing path                 → 0（并说明 nothing to remove）
symlink at driver path       → 1
no Info.plist                → 1
wrong CFBundleIdentifier     → 1
correct bundle id            → 0（打印 sudo rm -rf 计划）
seam without --dry-run       → 2
seam with wrong basename     → 2
unknown argument             → 2
```

### 9.4 明确的边界（未在本批次处理）

App 菜单栏的"Uninstall Driver"（`MenuBarView.swift:389`）仍在其管理员脚本里 `killall coreaudiod`。
它由用户显式点击确认触发，不是无条件动作；而且现有测试
`testOnlyTheInstallerAndTheUninstallerRestartCoreAudio` 明确规定"coreaudiod 只允许在显式的驱动
安装/卸载路径上重启"。修改它会改变一条既有安全策略测试，超出 §9 给 App 划定的范围（仅 Batch 3
收尾），列入 §18 未解决问题。

Host 侧 `restartCoreAudio()` 由 `SoundBridgeConfig.restartsCoreAudioOnExit = false` 守卫，且被
`GracefulShutdownTests` 与 `DegradedLifecycleTests` 双重断言 —— 该路径不可达。

---

## 10. dist 发布产物污染

### 10.1 污染机制

三个 verifier 原本这样选默认目标：读 `dist/SoundBridge.app/Contents/Info.plist` 的
`CFBundleShortVersionString` → 得到 `1.1.1` → 拼出 `dist/SoundBridge-1.1.1.{pkg,dmg}`。
于是：

```
VERSION=1.2.0  |  dist/SoundBridge.app = 1.1.1
                ↓
verifier 检查 1.1.1 pkg + 1.1.1 dmg + 1.1.1 bundle → 三者互相一致 → PASS
```

即"版本越旧，验证越绿"。1.1.1 的驱动声明协议 `131328`，与树上的 `131584` 已经不一致，这种
不一致只在 pkg 内部被部分捕获，其余被"自洽的旧产物"掩盖。

### 10.2 修复：目标由 `VERSION` 决定

解析优先级（`verify_dmg_contents.sh:resolve_release_version()`；`verify_pkg_contents.sh` 与
`verify_release_payload.sh` 同构）：

1. 显式 `--expect-version` / `--version`；
2. 显式 `--app` 指向的 bundle（调用方明确点名，不能静默回落）；
3. 仓库 `VERSION` 文件；
4. 仅当以上都没有时，才退回 dist bundle。

`verify_release_bundle.sh`（`make release-verify` 用的那个）同样默认读 `VERSION`，并在表头打印
`Expected version: … (from VERSION file)`。

`verify_release_payload.sh` 里 bundle 不再是选择器，而是被检查的对象之一：

```bash
if [[ -n "$APP_BUNDLE_VERSION" && "$APP_BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "    app bundle version '$APP_BUNDLE_VERSION' != $VERSION (stale bundle in dist/)"
    VERSION_FAILURES=$((VERSION_FAILURES + 1))
fi
```

### 10.3 缺失当前版本产物时 fail-closed

```
$ make verify-pkg
FAIL  package not found: …/dist/SoundBridge-1.2.0.pkg
      dist/ holds these packages, none named for 1.2.0:
        …/dist/SoundBridge-1.1.1.pkg
      pass --version <x.y.z> or --pkg <path> to check one of them
make: *** [verify-pkg] Error 1
```

这是刻意的：**不替代、不回退、不静默**。旧产物被列出但不参与判定，`dist/` 一个字节都没被写。

### 10.4 无副作用接缝

```
$ ./tools/verify_release_payload.sh --print-target
VERSION=1.2.0
VERSION_SOURCE=VERSION file
APP=…/dist/SoundBridge.app
PKG=…/dist/SoundBridge-1.2.0.pkg
DMG=…/dist/SoundBridge-1.2.0.dmg
```

`--print-target` 只打印然后 `exit 0`，因此可以断言"默认目标是什么"，而不需要真的去校验一个
可能不存在的产物。

### 10.5 Makefile

```make
verify-pkg:
	@./tools/verify_pkg_contents.sh --app "$(APP_BUNDLE)" --version "$(VERSION)"
verify-dmg:
	@./tools/verify_dmg_contents.sh --app "$(APP_BUNDLE)" --expect-version "$(VERSION)"
verify-payload:
	@./tools/verify_release_payload.sh --app "$(APP_BUNDLE)" --version "$(VERSION)"
```

`$(VERSION)` 来自 `VERSION ?= $(shell cat VERSION)`，所以"发布验证检查哪个版本"与"仓库自称哪个
版本"是同一个值，中间没有一处可以漂移。

### 10.6 测试（B-7，24 条断言全绿）

临时树 `fakeroot`：`VERSION=2.0.0`，`dist/` 里放的是真实的 1.1.1 pkg/dmg/bundle。覆盖：

| 断言组 | 内容 |
| --- | --- |
| 默认目标 | pkg → `SoundBridge-2.0.0.pkg`；dmg → `VERSION=2.0.0 / VERSION_SOURCE=VERSION file`；payload 三行一致 |
| 覆盖 | `--version 1.9.9` 优先于 VERSION 文件 |
| 缺失 | 2.0.0 产物不存在 → 列出 1.1.1，不替代，exit 1 |
| stale bundle | `--skip-dmg` 下 `VERSION_CONSISTENCY=FAIL` 且出现 `stale bundle in dist/` |
| release bundle | `bundle version '1.1.1' != expected '2.0.0'` |
| make 传参 | `make -n verify-pkg / verify-dmg / verify-payload` 的命令行里带 `--version "_VERSION_"` / `--expect-version "_VERSION_"` |
| dist 未被写 | 前后 SHA-256 相同 |

---

## 11. 修改文件清单与 SHA-256（§12）

> **前提声明**：Batch 1–4 的全部改动都在未提交工作树里。因此"本批次修改前"的逐文件哈希
> **无法事后精确重建**。下表给出两个可复现的锚点：
> - **HEAD blob**：`git -C . show HEAD:<path> | shasum -a 256`（基线提交里的内容）；
> - **当前**：`shasum -a 256 <path>`。
>
> 对 `tools/*`、`Makefile` 与 `AudioRenderer.swift`，HEAD→当前的差异可逐 hunk 归因为本批次；
> 对 `SharedMemoryManager.swift`、`ProxyDeviceManager.swift`、`main.swift`、`Constants.swift`，
> 差异同时包含 Batch 1–3 的工作，无法机械切分（见 §18）。

| # | 文件 | HEAD blob SHA-256 | 当前 SHA-256 | 本批次动作 |
| --- | --- | --- | --- | --- |
| 1 | `packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift` | `8c2130157644412e61888cf649ef6044c0eff14e78be58bbd54fc2d0c5d192e7` | `d3bebd7315a461975e59c9b161b382575e957f85f0dee209b2f78f166db875ea` | 重写回调：诊断盒、容量守卫、静音回退、deinterleave clamp、drainDiagnostics |
| 2 | `packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift` | `a7ffa605fb5765652cbf289c9ee637ac9dae46349b53a797260341834aa0b65d` | `1dfb717520090559a52fd31fab82ae600c9668a6870148d16cedf76005d905d7` | 新增 render 发布槽、延迟发布、`retireRenderPath` 的调用点（文件同时含 Batch 1–3 改动） |
| 3 | `packages/host/Sources/SoundBridgeHost/Constants.swift` | `140dc4d50afc3e1638bf07a00da858a4677279a1c0e8847efe8bfdfa9cc838a4` | `fd7052a5b3944a3038874784df91df99694ad019c2f9b2d15de69a49360a310a` | `maxSupportedSampleRate` / `maxCallbackFrames` / `maxCallbackChannels` / `cleanupWaitTimeout` |
| 4 | `packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift` | `d2ac405c370a01c42f484e40eb045894671d286bafdbb8cf58eb5af8f2b995ef` | `9adb7d75a03559f7ab56f40c9c49c05bbca4d2a1fe0cb0a6a71b44ad4df08f3f` | `updateSampleRate` 移到 `AudioOutputUnitStop` 之后 |
| 5 | `packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift` | `2060aa5a7dae16edc36648175cee50207317ed2461926f43c2e69dc0eb1c4018` | `614f4b9310ba823c4ab4a9e09d4103f539585c847cd986d8ba9f8ca5a9190cc7` | `onManagedProxyChanged` 回调，路由变化推入发布槽（含 Batch 1–3 改动） |
| 6 | `packages/host/Sources/SoundBridgeHost/main.swift` | `e61acc1682ab091d0949fc1b3b3a27ebfd9f4572cf6f6f37f15efb1272c077ff` | `7c31603459a70fa8c69b92cd837fac9c81b26a63eda7847e3fb18efe9cf76d9f` | 接 `onManagedProxyChanged`；connection poll 中 drain 诊断（含 Batch 1–3 改动） |
| 7 | `packages/host/Tests/SoundBridgeHostTests/AudioRendererRTSafetyTests.swift` | —（新文件） | `fd60419c9ac4d5019de19ef16874110362798baf8ba57a04a78177499ef2b2e9` | 新增 19 项 RT 测试（543 行） |
| 8 | `apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift` | —（新文件，Batch 3 建立） | `21a6e1412319cf5f372bcd4d8933c6f29c09e9e61cc5ac91ed6501b3c9f0b3ea` | 本批次改 release 线程归属 + UnmapLedger |
| 9 | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingUnmapThreadTests.swift` | —（新文件） | `505a084ea93a176a65113fd07ed3ab58f8f2de0f26c60bf8642ee82ac6edb431` | 新增 7 项线程归属测试（298 行） |
| 10 | `tools/uninstall_driver.sh` | `bd24bb476840a1de3ecb0996016af468b63ad44f604f568f88f1cca8a2a6a60b` | `5c2e5363167b5d968a70b62bd72b9724f72438a55c7e063271dff1ced99ea597` | 整文件重写（18 → 142 行），移除 `killall coreaudiod` |
| 11 | `tools/verify_release_payload.sh` | `62e6a1aec3c5cdd4431be6dd8db9cc986ac63e6e83b95ac529df0af0d65a2ad8` | `b0acaf9e74a6d6c8ba8148a54e605778816f11a27b439e91117ae88088fad5e3` | VERSION 驱动 + stale bundle 判 FAIL + `--print-target` |
| 12 | `tools/verify_pkg_contents.sh` | `e8cfb0ca1f23ac43ee834c0141591b9848735af021e9e6e81fee3cf8874a158c` | `05d4018e2bdafc18415e371a080dd3c42bee17d855e23197bedfef55cf3f67f7` | 同上（pkg 方向）+ 缺失产物清单 |
| 13 | `tools/verify_dmg_contents.sh` | `2fb1f27038cf815cdd9623c5303d273c6e69ab1c63f43be371cc17af8ab9ba21` | `a95d8e1e720b8c2befb80d31b0a6d12e24e887b9cfc8bcbbbcda0c6483271ae4` | 同上（dmg 方向）+ `resolve_release_version()` |
| 14 | `tools/verify_release_bundle.sh` | `4b960413e9d3e1d6783e49c07c9401203d8ccb39c5eb5a69b89ed9d1fb309b0b` | `849cf740bbf9dd30d633d58d4ed9fd8768f5450e1fa731014a3591fb71bc1912` | 默认期望版本来自 VERSION，表头标明来源 |
| 15 | `tools/test_release_payload.sh` | `ba8960162269bd121d166d375ed945508a8e798852170cf044196ea2f87c88b4` | `9a71804e8c9121e5cb798b89405cd506ff615a1e99ffbfaeea84e41db732834e` | 14 处调用显式带 fixture 版本 + 新增 B-7 段 24 条断言 |
| 16 | `Makefile` | `15e3fa2c1f599222efc50ab02c0c49b649b85fabea277879dc91fe8af21ef07e` | `8151b25d3feaf2d10a5b35e815bd1e36372286d49c0e89fdac25430b1e3bec6a` | `verify-pkg/dmg/payload` 传 `$(VERSION)`（`test-driver` 目标属 Batch 1） |

未修改（仅读取）：`packages/shared/include/RFSharedAudio.h`、四个 header 副本
（当前 `0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee`，四份一致）、
`packages/driver/**`、`packages/dsp/**`、`VERSION`、所有 `Info.plist`、`dist/**`。

**完整 diff 的复现方式**（本报告不复制 3000+ 行机器输出）：

```
git -C /path/to/SoundBridge diff -- <path>
```

---

## 12. 新增测试清单

### 12.1 `AudioRendererRTSafetyTests`（19 项，全部通过）

| # | 测试 | 覆盖 §8.1 |
| --- | --- | --- |
| 1 | `testNormalCallbackCopiesRingContentChannelByChannel` | 1 正常输入 |
| 2 | `testMaximumFrameCountIsAcceptedAndTheTailIsSilent` | 2 最大帧数 |
| 3 | `testEightChannelBlockThatTheRingCannotServeIsSilence` | 3 最大通道数（8 通道，ring 不匹配 → 静音） |
| 4 | `testEmptyRingProducesSilenceAndCountsTheUnderrun` | 4/6 空输入、underflow |
| 5 | `testShortOutputBufferIsNeverWrittenPastItsCapacity` | 5 输出缓冲不足 |
| 6 | `testRingUnderflowZeroFillsOnlyTheTail` | 6 underflow 补零 |
| 7 | `testBlockLargerThanCapacityIsRefusedWithSilence` | 2/7 超容量拒绝 |
| 8 | `testNineChannelBlockExceedsTheABIChannelCeiling` | 3 通道上限 |
| 9 | `testDSPRunsOnStereoAndStaysBounded` | 8 DSP 正常 |
| 10 | `testDSPIsSkippedWhenTheInstrumentationCannotFeedIt` | 9 DSP 错误输入 |
| 11 | `testMissingMappingProducesSilenceAndIsCounted` | 10 Shared Memory unavailable |
| 12 | `testMutedMappingProducesHardSilence` | 13 静音回退 |
| 13 | `testCleanupStopsTheRenderPathBeforeReleasingAnything` | 11 Host shutdown |
| 14 | `testRetirementWaitsForTheInFlightCallback` | 12 Mapping retirement |
| 15 | `testDeferredPublicationIsReleasedByTheHeartbeatDrain` | 12 + 延迟发布 |
| 16 | `testPreferredUIDSelectsThePublishedMapping` | 路由选择 |
| 17 | `testSteadyStateCallbacksDoNotAllocate` | 2 无分配（malloc 统计） |
| 18 | `testContinuousCallbacksReuseTheScratchBuffer` | 14 连续 callback |
| 19 | `testCapacityDerivesFromTheFrozenRingHelper` | 9 容量依据 |

测试用**真实 `AudioRenderer.render`**、真实 `AudioBufferList`、真实临时 mmap 文件，不连接 HAL，
不读写正式共享内存路径。

### 12.2 `SharedMemoryMappingUnmapThreadTests`（7 项，全部通过）

见 §8.2 的对应表。

### 12.3 `test_release_payload.sh` 的 B-7 段（24 条断言）

见 §10.6。

### 12.4 未新增但被复用的关键测试

`MappingIncarnationTests`（5）、`SharedMemoryRecoveryTests`（16）、`GracefulShutdownTests`（8）、
`RingBufferContractTests`（17）、`SharedMemoryProtocolTests`（19）。

---

## 13. 测试结果

### 13.1 定向测试

| 套件 | 结果 |
| --- | --- |
| `AudioRendererRTSafetyTests` | **19 / 19 passed** |
| `SharedMemoryMappingUnmapThreadTests` | **7 / 7 passed** |
| `test_release_payload.sh` | **passed 227 / failed 17**（B-7 24/24 通过；17 项为既存失败，见下） |

17 项既存失败的定性：全部指向同一事实 —— `dist/` 里是 1.1.1（驱动协议 `131328`），源码树是
1.2.0（协议 `131584`）。证据：用 `git show HEAD:tools/verify_*.sh` 在临时树里对同一批产物运行，
得到**同样的** `DRIVER_PROTOCOL_MATCH=false` 与 "every copy declares protocol 131328 but the shared
header says 131584"。它们不是本批次引入的；本批次改变的是语义 —— 以前"旧产物自洽"被读成 PASS，
现在 stale bundle 直接记 `VERSION_CONSISTENCY=FAIL`。

### 13.2 Host 全量

```
Executed 350 tests, with 0 failures (0 unexpected) in 30.956 seconds
```

（含上面 19 项；`make test-host` EXIT=0，无编译告警。）

### 13.3 App 全量

```
Executed 202 tests, with 0 failures (0 unexpected) in 5.044 seconds
```

### 13.4 Driver 全量

```
1/3 Test #1: soundbridge_driver_control_protocol_tests .....   Passed
2/3 Test #2: soundbridge_driver_producer_token_tests .......   Passed
3/3 Test #3: soundbridge_driver_mapping_retirement_tests ...   Passed
100% tests passed, 0 tests failed out of 3
```

Driver 源码零改动；测试在 scratch 目录编译，不覆盖 `packages/driver/build`。

### 13.5 `make test`

```
protocol-check  : 4 files identical (0x00020200)
version-check   : VERSION_SOURCES_CHECKED=11 / VERSION_SOURCES_FAILED=0 / VERSION_CONSISTENCY=PASS
test-dsp        : 1/1 passed
test-driver     : 3/3 passed
test-host       : 350 tests, 0 failures
test-app        : 202 tests, 0 failures
test-installer  : 32 scenarios, all ok
test-codesign   : PASS: 58 checks, 0 failures
✓ All test suites passed            ← EXIT=0
```

这一轮是在最后一次代码改动（`drainDiagnostics` 接入 connection poll）之后重跑的，对应的是工作树的最终状态，不是中间态。

### 13.6 TSan / ASan

```
swift test --sanitize=thread  --filter 'AudioRendererRTSafetyTests|SharedMemoryRecoveryTests|MappingIncarnationTests'
  → Executed 40 tests, with 1 test skipped and 0 failures
swift test --sanitize=address --filter （同一组）
  → Executed 40 tests, with 1 test skipped and 0 failures
```

跳过的是 `testSteadyStateCallbacksDoNotAllocate`：sanitizer 替换了 allocator，
`malloc_zone_statistics` 不再反映回调的分配，测试主动 `XCTSkip` 并写明原因，而不是静默通过。
**TSan 无 data race 报告不等于"没有实时阻塞"** —— 它只覆盖这 40 个测试的执行路径。

---

## 14. ABI / Protocol / Version 检查

```
$ ./tools/check_protocol_layout.sh
protocol version : 0x00020200
header size      : 320 bytes
sizeof(struct)   : 320 bytes
alignof(struct)  : 8 bytes
audio_data offset: 320 bytes
```

| 项 | 值 | 本批次 |
| --- | --- | --- |
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200` (131584) | 未修改 |
| 4 份 header 副本 | 同一 SHA-256 `0f415450…c060ee` | 未修改 |
| `packages/driver/Info.plist` `SBAudioProtocolVersion` | 131584 | 未修改 |
| `VERSION` | 1.2.0 | 未修改 |
| `apps/…/Info.plist` `CFBundleShortVersionString` / `CFBundleVersion` | 1.2.0 / 1.2.0 | 未修改 |
| `packages/driver/Info.plist` 版本 | 1.2.0 | 未修改 |
| Ring buffer / Admission / Callback Gate / Mapping Retirement | 未触碰 | — |

---

## 15. Git 工作区保护

| 检查 | 结果 |
| --- | --- |
| 未执行 `git add/commit/stash/reset/clean/checkout/restore` | ✔ |
| 未执行 `make clean` | ✔ |
| 未删除、覆盖 `dist/` 任何文件 | ✔（§1 三份哈希；B-7 断言前后一致） |
| 未改写任何既有测试 | ✔（只新增文件与追加断言） |
| Batch 1–3 的改动全部保留 | ✔（工作树 diff 中仍可见） |
| 未修改 vendor submodule | ✔ |
| 文档只写入 `docs/` | ✔ |
| 未重建 `SoundBridge-Research/` | ✔ |
| 未执行 sudo / HAL 装卸 / 重启 coreaudiod / 真实设备测试 | ✔ |

---

## 16. 设计评审十问（§13 A–J）

### A. Callback Safety — 回调里还剩哪些可能阻塞的操作？

只剩 `os_unfair_lock` 的两处极小临界区：`RenderDiagnostics` 的计数器（首帧与错误分支）和
`SharedMemoryManager.renderLock`（进入/退出各一次）。两者都不做系统调用、不取第二把锁、
不跨回调持有。`os_unfair_lock` 在无争用时是一条原子指令；有争用时等待上界取决于持锁者，
而持锁者（控制线程）在临界区内只有赋值。

除此之外没有：文件、`UserDefaults`、`Logger`、`Process`、`DispatchQueue.sync`、信号量、睡眠。
**不能声称"零等待"** —— 有界争用只能由真机测量（§18）。

### B. Allocation — 如何证明 callback 期间不分配？

三重证据：

1. 结构性：混音缓冲在 `init` 分配、`deinit` 释放；回调内所有集合类型都不存在（无 `Array`/`String`/`Dictionary`）。
2. 运行时：`testSteadyStateCallbacksDoNotAllocate` 用 `malloc_zone_statistics` 比对连续 2000 次
   回调前后的 `blocks_in_use`，差值为 0。
3. 首帧例外：`recordFirstPass` 只写 4 个 `UInt32` 与 2 个标量，不构造数组（数组在
   `snapshot()` 里构造，那是控制线程）。

在 sanitizer 下第 2 条会 skip（allocator 被替换），这一限制写在测试里，不是静默跳过。

### C. Lock — 是否还会等别的线程持有的锁？原子操作是否可能无界重试？

`renderLock` 的持有者集合：`enterRenderMemory` / `exitRenderMemory`（回调），
`publishRenderMapping` / `applyDeferredRenderPublication` / `renderPathSnapshot` / `retireRenderPath`
（控制线程）。控制线程在锁内不做释放（`released` 在解锁后才 drop），因此回调不会因为一次
`munmap` 而等待。锁序 `lock → renderLock` 单向前进，不存在环。

**没有使用 CAS 重试循环**。唯一的"重试"是心跳里的 `drainDeferredRenderPublication()`：1 Hz，
在控制线程，回调永远不参与。

### D. DSP — 是否有分配、锁、不可预测循环？

无分配、无锁、循环按 `framesRead × channels` 线性。两点必须诚实标注：

- `soundbridge_dsp_set_sample_rate` 会重建全部系数，**不是** RT-safe；本批次把它约束在
  `AudioOutputUnitStop` 之后（§4.7），属于"调用时序保证"，不是"函数本身变安全了"；
- DSP 仅 stereo，非 stereo 直接跳过；它不是 bit-exact（含 DC blocker）。

### E. Buffer — 最大容量如何确定？超限如何处理？

`rf_ring_capacity_frames_for(192000, 100ms)` = 32768 帧 × 8 通道 × 4 B = 1 MiB，预分配；
超限**拒绝并静音**，不截断（§5）。这条关系由 `testCapacityDerivesFromTheFrozenRingHelper`
与 `testBlockLargerThanCapacityIsRefusedWithSilence` 双向固定。

### F. Diagnostics — 如何在不在回调里打印的前提下记录错误？

回调只做 `&+= 1`（`os_unfair_lock`，1–3 条 store）。读取与格式化在控制线程：
`drainDiagnostics()` 由主队列的 connection poll 调用（`main.swift:1087`），首帧行只打一次，
错误按"计数变化"打，不按时间去重也不刷屏。

### G. Mapping Release — 最后一个 lease 会不会由 EQ writer 执行 munmap？修复后由哪条队列执行？

不会。`SharedMemoryMappingManager` 在释放最后一个 lease 时检查
`DispatchQueue.getSpecific(key: attachKey)`：

- 已在 attachQueue → 就地执行（不能 `async` 排队等自己）；
- 否则 → `attachQueue.async { unmap }`。

实际执行者被记录在 `UnmapLedger.executor`，
`testLastLeaseReleaseUnmapsOnTheAttachQueueNotTheWriter` 断言 `executor != writer`，
并且为此**让 writer 线程 park** —— 若释放仍在 writer 上，测试会卡住而不是误判通过。

Host 侧对应物：`publishRenderMapping` 在 `renderInFlight == 0` 时释放旧映射，
`retireRenderPath` 在退出时有界自旋等待；munmap 永不发生在音频线程。

### H. Uninstall — 卸载还会无条件终止 coreaudiod 吗？

`tools/uninstall_driver.sh`：**不会**。脚本里已无 `killall`，只打印手工建议。
App 菜单栏卸载路径仍会在用户显式确认后重启 coreaudiod —— 这是既有策略，被
`testOnlyTheInstallerAndTheUninstallerRestartCoreAudio` 固定，本批次未改（§9.4、§18）。

### I. Release Artifact — 默认验证会不会错误使用 dist 里的 1.1.1？

**不会。** 目标由 `VERSION` 决定；`--print-target` 可无副作用查看；1.2.0 产物缺失时 fail-closed
并列出 1.1.1；bundle 版本与 `VERSION` 不符时 `VERSION_CONSISTENCY=FAIL`（§10）。

### J. Regression — 前序批次的安全不变式是否仍然成立？

| 不变式 | 状态 | 证据 |
| --- | --- | --- |
| 协议布局 / ABI | 保持 | `check_protocol_layout.sh`；4 份 header 同哈希 |
| Ring buffer 单读者 | 保持 | `RingBufferContractTests` 17 项 |
| Admission / Gate | 保持 | `MappingIncarnationTests` 5 项 |
| Mapping retirement | 保持 | `SharedMemoryRecoveryTests` 16 项 + `MappingRetirementTests` |
| 默认输出治理 | 保持 | `DefaultOutputGovernanceTests` 23 项 |
| 优雅退出 | 保持 | `GracefulShutdownTests` 8 项 |
| 安装事务 | 保持 | installer 32 场景 |
| 版本一致性 | 保持 | version-check 11/11 |

---

## 17. PASS 判定（§15，32 条逐项）

### AudioRenderer

| # | 条款 | 判定 | 证据 |
| --- | --- | --- | --- |
| 1 | 完整 callback 调用链已审计 | ✔ | §2 |
| 2 | 回调内无直接日志 | ✔ | 静态审查 544 行 + 19 项测试 |
| 3 | 回调内无动态分配 | ✔ | `testSteadyStateCallbacksDoNotAllocate`（非 sanitizer 下） |
| 4 | 回调内无动态释放 | ✔ | 缓冲只在 `deinit`；`withExtendedLifetime` 在控制线程 |
| 5 | 回调内无文件系统操作 | ✔ | 静态审查 |
| 6 | 回调内无阻塞等待 | ✔（离线证据） | 仅两处 unfair_lock 微临界区；真机上界待测 |
| 7 | 回调内无不受控锁竞争 | ✔ | 叶子锁、单向锁序、锁内无释放 |
| 8 | DSP 路径符合 RT 约束 | ✔ | §6；`set_sample_rate` 已移出 |
| 9 | Buffer 容量与最大输入有依据 | ✔ | §5，两个测试双向固定 |
| 10 | 所有错误路径符合 RT 约束 | ✔ | §7 表 |
| 11 | 不因诊断/日志/资源管理阻塞 | ✔ | §4.1 + §16 F |

### Mapping Release

| # | 条款 | 判定 | 证据 |
| --- | --- | --- | --- |
| 12 | lease 释放逻辑安全 | ✔ | 7 项线程归属测试 |
| 13 | 旧 Mapping 释放条件明确 | ✔ | `renderInFlight == 0` / 最后 lease |
| 14 | munmap 恰好执行一次 | ✔ | `testEachIncarnationIsUnmappedExactlyOnce` |
| 15 | 不在 UI 线程执行释放 | ✔ | attachQueue 归属判定 |
| 16 | 不存在 use-after-unmap | ✔ | 引用在锁外、控制线程释放；`withExtendedLifetime` |
| 17 | 不存在 double munmap | ✔ | ledger + incarnation 唯一 |

### Installer / Release

| # | 条款 | 判定 | 证据 |
| --- | --- | --- | --- |
| 18 | `uninstall_driver.sh` 不会无条件终止 coreaudiod | ✔ | §9；8 个 fixture 场景 |
| 19 | 卸载流程的系统影响明确 | ✔ | 只删固定路径 + 文件系统复查 + 建议文案 |
| 20 | dist 旧产物不会污染当前版本验证 | ✔ | §10；B-7 24 条断言 |
| 21 | 发布验证能检查真实产物版本 | ✔ | `--print-target` + stale bundle FAIL |

### Regression / Protection

| # | 条款 | 判定 | 证据 |
| --- | --- | --- | --- |
| 22 | App 全量测试通过 | ✔ | 202 / 0 |
| 23 | Host 全量测试通过 | ✔ | 350 / 0 |
| 24 | Driver 全量测试通过 | ✔ | 3 / 3 |
| 25 | `make test` EXIT=0 | ✔ | §13.5 |
| 26 | ABI / Protocol / Header 未修改 | ✔ | 4 份同哈希、`0x00020200` |
| 27 | VERSION / Bundle Version / Build Number 未修改 | ✔ | version-check 11/11 |
| 28 | dist 旧文件未删除、未覆盖 | ✔ | §1 哈希 + B-7 前后一致 |
| 29 | 没有真实 HAL 操作 | ✔ | 全程 scratch 目录 |
| 30 | 没有 Git 写操作 | ✔ | §15 |
| 31 | 历史工作区修改得到保留 | ✔ | `git status` 与改动前一致（仅本批次 16 个文件不同） |
| 32 | 完整执行报告已交付 | ✔ | 本文件 |

### 最终判定

**CONDITIONAL PASS**。

理由不是"某条没做到"，而是 §15 的最后一句：任何关键实时安全不变式若**不能证明**，就不能标
PASS。以下三项在离线环境里只能给出静态/仿真证据，必须留给 P3 真机验证：

1. 真实 CoreAudio IO 线程上的最坏等待时间与分配行为（本批次证明的是"没有显式分配"与
   "临界区只有几条指令"，不是"实测零延迟"）；
2. 真实设备移除 / Host 退出时序下 attachQueue 的实际线程归属（本批次证明的是策略与台账，
   不是真实 HAL 通知下的执行轨迹）；
3. `dist/` 里没有 1.2.0 产物，因此"发布验证在真实 1.2.0 产物上通过"这件事本批次**没有**做到——
   它现在正确地失败（fail-closed），而不是假绿。

---

## 18. 未解决问题与 P3 建议

### 18.1 未解决（本批次按范围主动不处理）

| # | 问题 | 影响 | 建议 |
| --- | --- | --- | --- |
| 1 | App 菜单栏卸载仍 `killall coreaudiod` | 用户显式确认后系统音频短暂中断 | P3 与 `testOnlyTheInstallerAndTheUninstallerRestartCoreAudio` 一起改策略 |
| 2 | `dist/` 无 1.2.0 产物 | `make verify-*` 现在按设计失败 | 走一次真实构建（`make release`，需用户批准） |
| 3 | DSP 仅 stereo、非 bit-exact | 多声道设备上 EQ 被跳过 | 属 DSP 架构问题，不在 Batch 4 范围 |
| 4 | `dspEngine` 指针由 IO 线程与主线程共用 | 只靠"Audiounit 停止后再 set_sample_rate"的顺序约束 | P3 用 TSan + 真实设备切换压测 |
| 5 | 诊断 drain 频率 = connection poll | 故障日志可能延迟一个 poll 周期 | 可接受；如需更快，另开控制线程 |
| 6 | Batch 1–4 全部未提交 | 无法逐文件重建"批次入口 SHA-256" | 由用户决定何时提交/分批提交 |
| 7 | `test_release_payload.sh` 17 项既存失败 | 套件不是全绿 | 生成 1.2.0 产物后自然消失；不应通过改断言"修好" |

### 18.2 P3 必须做（真实 macOS 验证）

1. **RT 实测**：真实设备 48 kHz / 192 kHz（若设备支持）下的回调耗时分布；`os_signpost` 或
   Instruments 的 Audio 模板；至少包含一次设备切换与一次拔插。
2. **线程归属实测**：真实 HAL 设备移除时，`UnmapLedger.executor` 的取值分布（应恒为 attachQueue）。
3. **分配实测**：真机 Instruments Allocations 在 10 分钟播放中零增长（含首帧）。
4. **卸载实测**：`uninstall_driver.sh` 在真实机器上删除驱动后，coreaudiod 未被终止；系统音频恢复。
5. **发布链路实测**：构建 1.2.0 pkg/dmg 后 `make verify-pkg verify-dmg verify-payload` 全绿，
   且 `dist/` 同时存在 1.1.1 与 1.2.0 时只验证 1.2.0。
6. **回归**：真机 `make test` 全绿；随后再决定是否开始 P2 Batch 5。

---

## 附录 A：本批次关键代码位置

| 位置 | 内容 |
| --- | --- |
| `AudioRenderer.swift:17` | `RenderDiagnostics`（unfair_lock 计数器） |
| `AudioRenderer.swift:202` | `takeDiagnostics()`（纯快照） |
| `AudioRenderer.swift:215` | `drainDiagnostics()`（控制线程增量日志） |
| `AudioRenderer.swift:250` | `createRenderCallback()`（CoreAudio 入口） |
| `AudioRenderer.swift:275` | `render(bufferList:frameCount:)` |
| `AudioRenderer.swift:502` | `outputSilence()` |
| `AudioRenderer.swift:512` | `deinterleave()`（两端 clamp） |
| `SharedMemoryManager.swift:419` | `enterRenderMemory()` |
| `SharedMemoryManager.swift:429` | `exitRenderMemory()` |
| `SharedMemoryManager.swift:437` | `drainDeferredRenderPublication()` |
| `SharedMemoryManager.swift:471` | `publishRenderMapping()` |
| `SharedMemoryManager.swift:515` | `retireRenderPath(timeout:)` |
| `SharedMemoryManager.swift:590` | 心跳中的 drain 调用点 |
| `SharedMemoryManager.swift:639` | `cleanup()` 中的 `retireRenderPath` |
| `Constants.swift:27-51` | 容量推导 |
| `AudioEngine.swift:219` | `updateSampleRate` 移出运行中的 IO 单元 |
| `main.swift:1087` | connection poll 中 drain 诊断 |
| `SharedMemoryMappingManager.swift` | attachQueue 归属 + `UnmapLedger` |
| `tools/uninstall_driver.sh` | 142 行；`killall` 只出现在注释与手工建议文案里，无可执行调用 |
| `tools/verify_{pkg,dmg}_contents.sh`、`verify_release_payload.sh`、`verify_release_bundle.sh` | VERSION 驱动 + `--print-target` |
| `tools/test_release_payload.sh` | B-7 段（24 条断言） |
| `Makefile` | 三个 verify 目标传 `$(VERSION)` |

---

*报告结束。按任务书 §16，本批次到此停止，不开始 P2 Batch 5，不开始 P3。*
