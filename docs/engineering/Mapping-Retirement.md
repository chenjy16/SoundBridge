# Mapping 退役

来源：Batch 3（Mapping Retirement & Device-Removal Safety，
`CONDITIONAL PASS`）与 Batch 3 Closure Fix（`CONDITIONAL PASS`）。批次验证报告
已随阶段报告移出仓库；当前结论由 `make test` 中的 Host 测试套件持续覆盖。

本文描述**为什么**退役必须这样写，以及**哪些前提还没有被真实环境验证**。

---

## 1. 退役要解决的问题

一块 mapping 被 `munmap` 之后，任何仍持有其指针并解引用的线程都会触发
`SIGSEGV`（或读到已释放页）。因此"释放共享内存"不是一次分配器调用，而是
一个**并发正确性问题**：

> 在释放之前，必须证明没有任何实时回调仍在该映射内。

Batch 2 只证明了 StopIO 路径：`DoIOOperation`（回调）与 `StopIO` 共用
libASPL 的 per-device `ioMutex_`，因此在 StopIO 中"先释放 producer slot 再
unmap"不会与写回调重叠。**设备移除、乱序 StopIO、析构函数都不持有该锁**，
它们需要独立的自证。

## 2. 修复前的三个缺陷（P0-A / P0-B / P0-C）

| 编号 | 缺陷 | 后果 |
|---|---|---|
| **P0-A** | 设备移除路径直接释放映射，不排空；`Disconnect()` 在无保护情况下释放 | 回调可能正在使用已释放内存 → UAF |
| **P0-B** | `shared_memory_` 是裸指针（非 `std::atomic<RFSharedAudio*>`） | 回调与退役线程的数据竞争是未定义行为，编译器可以任意重排 |
| **P0-C** | 旧 producer claim 可能在新 mapping 上仍然"有效" | 旧 handler 写入新 incarnation → 数据错乱 |

## 3. 修复后的四条不变量

| 编号 | 不变量 | 实现 |
|---|---|---|
| **I1** | 只有 `RetireMapping()` 能 munmap | 全仓库唯一 `mapping_owner_.reset()` 位置 |
| **I2** | 只有在排空被证明后才 munmap | `ack.Drained()` 为唯一分支条件 |
| **I3** | 退役后指针不可能再被观察到 | 先 `Close`/`CloseAndDrain`，再 `shared_memory_.store(nullptr, release)`，最后才 reset |
| **I4** | 旧 ACK 不可能匹配新 incarnation | handler 级单调 `revision` + Host 随机 `epoch` |

违反任一条都会使得"释放"失去证明基础。

## 4. 唯一入口与四个调用者

```cpp
DrainAck RetireMapping(const char* reason,
                       std::chrono::milliseconds budget = kRetireDrainBudget);
```

| 调用者 | reason | 持有 `io_mutex_` | 是否释放 producer slot |
|---|---|---|---|
| `OnStopIO`（最后一个 client）→ `Disconnect()` | `"disconnect"` | **是** | **是**（在 `Disconnect()` 之前） |
| `Retire()`（设备移除） | `"device-removed"` | 是（仅为了与 `OnStartIO` 互斥，不构成排空论据） | 否 |
| 析构函数 | `"destructor"` | 否 | 否 |
| `OpenSharedMemory()` 防御性重开 | `"reopen"` | 否 | 否 |

### 4.1 为什么只有 OnStopIO 释放 token

释放 token 意味着"我保证不会再写这个 slot"。这个保证需要两个独立论据之一：

- **OnStopIO**：持有 `ioMutex_`（此刻不可能有回调在跑）**且**随后走
  `RetireMapping()` 的排空证明。两个论据同时成立。
- **设备移除 / 析构**：只有排空证明，没有 `ioMutex_` 的互斥。缺少第一论据
  时释放 token 会把 slot 交给下一个 owner，而旧回调可能仍在其中。

因此这两条路径**不**调用 `rf_producer_release()`。代价是：如果设备被移除，
token 会一直留在旧 mapping 的 header 里直到该内存被回收——但旧 mapping 的
epoch 与新 mapping 不同，残留 token 在新 mapping 上无效，因此不构成安全
问题。

## 5. 退役时序（顺序即正确性）

```
revision = mapping_revision_      (acquire)
epoch    = claimed_epoch_         (relaxed)

if (SharedMemory() == nullptr):
        callback_gate_.Close()            // 让"指针已清空、下次 start 之间"的回调 fail-closed
        return DrainAck{revision, epoch, NothingToRetire}

deadline = now + 250 ms
ack = callback_gate_.CloseAndDrain(revision, epoch, deadline)

shared_memory_.store(nullptr, release)    // A：先清指针
shared_memory_size_ = 0

if ack.Drained():
        mapping_owner_.reset()            // B：唯一的 munmap
else:
        MappingQuarantine::Retain(std::move(mapping_owner_), revision, epoch, reason)
```

两条相对顺序都是必需的：

- **排空 → 清指针**：仍在回调体内的读者在整个回调期间保持有效 `mem`；同时
  没有新回调能获得指针（闸门已关闭）。
- **清指针 → 释放 owner**：munmap 永远不可能通过 `shared_memory_` 被观察到，
  即使某个读者在 `store(nullptr)` 之后仍然持有旧值（它持有租约，因此排空
  还没有结束，理论上不会发生；但这条顺序消除了对它的依赖）。

### 5.1 `NothingToRetire` 时为什么仍要 Close

若当前没有已发布 mapping，直接返回会让闸门保持原状。若之前的 incarnation
留下一个 OPEN 闸门（例如在某条异常路径上），一个此时到达的回调会
`TryEnter()` 成功并读到一个空指针——虽然它不会崩溃（有空指针检查），但它
会把"无 mapping"当作可进入状态，放大后续路径的错误面。`Close()` 使
"无 mapping"在闸门层面也是显式关闭的。

## 6. Quarantine

```cpp
MappingQuarantine::Retain(std::shared_ptr<SharedMemoryMapping>,
                          uint64_t revision, uint64_t epoch, const char* reason);
```

语义：

- 取走 `mapping_owner_` 的所有权（调用方随即处于空状态）；
- 存入进程级函数局部静态容器（`std::mutex` + 两个 `std::vector`）；
- **永不**读、写、munmap；
- 提供 `Count()` 与 `Snapshot()` 供诊断。

### 6.1 为什么没有回收机制

Closure Fix 的 Quarantine 生命周期审查逐条回答了这个问题：

| 问题 | 结论 |
|---|---|
| 能否在进程退出前回收？ | 不能。无法证明一个永不返回的回调已经离开 |
| `shared_ptr::use_count() == 1` 能否作为证据？ | 不能。控制路径绕过闸门，`use_count` 不是同步点，也不提供 happens-before |
| 能否按 TTL 回收？ | 不能。超时不是"回调已离开"的证明 |
| 能否按 PID 存活判断？ | 不能。Driver 在 `coreaudiod` 内，PID 存活与线程状态无关 |
| 会重复 Retain 同一个 mapping 吗？ | 不会。`std::move` + `if (!mapping) return;` 保证一次 |
| 会影响新 incarnation 吗？ | 不会。新 mapping 是新 inode + 新 revision，quarantine 中的旧条目与之无关 |
| 何时增长？ | 仅在 `TimedOut`；`Drained` 与 `NothingToRetire` 都不增长 |
| 有硬上限吗？ | 没有 |

### 6.2 代价

| 项 | 量级 |
|---|---|
| 每条例目的虚拟地址空间 | ring 数据区（默认 64 KiB）+ 320 B header；`st_size ≤ 64 MiB` |
| 实际物理内存 | 保留映射但不触碰，页可被换出；不是零成本，但也不是"每条例目 64 MiB 常驻" |
| 上限 | 无。反复超时会持续增长，直到进程退出 |

这是**已接受的实现限制**，不是待修的 bug，但在
[risks/Known-Limitations.md](../risks/Known-Limitations.md) 中作为产品风险
登记（长时间运行 + 反复超时 → 虚拟地址空间增长）。

## 7. ACK 语义

```cpp
struct DrainAck {
    uint64_t revision;   // handler 局部单调戳
    uint64_t epoch;      // Host 为这块 mapping 发布的 epoch
    DrainOutcome outcome; // Drained | TimedOut | NothingToRetire
};
```

- `Drained()` 仅当 `outcome == Drained`。
- `RetiredRevisionMatches(ack, currentRevision)` 拒绝过期的 ACK：新 incarnation
  一定带来更高的 revision，因此旧 ACK 不可能被当成新 mapping 的排空证明。
- `epoch == 0` 表示"未 claim 过"，此时 ACK 只用于诊断，不用于任何授权。

## 8. 与之相关的偏差与未覆盖项

### 8.1 报告的偏差（D1–D5）

| 编号 | 偏差 |
|---|---|
| D1 | 设备移除路径只在代码层接入，**未在真实 HAL 上触发**过 |
| D2 | `Retire()` 取得 `io_mutex_` 是为了与 `OnStartIO` 互斥，并非排空论据；这一点在报告中明确写出，避免被误读 |
| D3 | `Disconnect()` 被改为收敛到 `RetireMapping("disconnect")`，行为等价性只在测试层验证 |
| D4 | 防御性 `RetireMapping("reopen")` 是新增路径，真实运行中未观察到 |
| D5 | Host 318 测试通过，但 App 只做构建，未运行 UI 回归 |

### 8.2 未覆盖（N1–N8）

包括：真实设备热插拔、`coreaudiod` 重启、Driver 重载后的旧 ACK、
多设备并发退役、quarantine 长时间增长、真实负载下的 250 ms 预算、x86_64
真机、macOS 14.4。逐条见风险清单。

## 9. 已验证 / 未验证

已验证（Batch 3 + Closure Fix）：

- Driver 11 组 61 断言（Batch 3）、17 组 119 断言（Closure Fix）；
- 重复 Close/Retire、并发准入、排空成功/超时、无残留计数；
- Host 测试 318/318（Batch 3）；Driver 全量 40/40 重复运行；
- ASan 0 报告；TSan 5/5；
- 单原子闸门内存模型证明（见 CallbackGate-Memory-Model.md）。

未验证：

- 真实 HAL 设备移除（**Batch 3 的核心场景仍未在真实硬件上执行**）；
- 真实 Driver 安装 / 卸载 / `coreaudiod` 重启；
- 真实负载下的 quarantine 增长曲线。

## 10. 相关文档

- 内存模型证明：[CallbackGate-Memory-Model.md](CallbackGate-Memory-Model.md)
- 回调运行视角：[Callback-Lifecycle.md](Callback-Lifecycle.md)
- 完整生命周期：[SharedMemory-Lifecycle.md](SharedMemory-Lifecycle.md)
