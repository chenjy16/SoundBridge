# 回调生命周期

来源：Batch 2（回调出口与阈值）、Batch 3（准入 + 租约）、Batch 3 Closure Fix
（单原子闸门）。结论状态 `CONDITIONAL PASS`，证据见
[verification/Batch-3-Closure-Fix.md](../verification/Batch-3-Closure-Fix.md)。

本文描述**运行时视角**：一个 HAL 回调从进入到离开经过哪些检查、谁可能等它、
什么条件下允许释放它脚下的内存。内存模型的形式化证明在
[CallbackGate-Memory-Model.md](CallbackGate-Memory-Model.md)，不在此重复。

---

## 1. 回调入口

HAL 写回调 `Device::OnWriteMixedOutput(...)` 是唯一的音频数据入口，也是
唯一的实时线程入口。它承担：

1. 通过准入闸门；
2. 取一次 mapping 指针；
3. 格式转换 / 采样率转换；
4. 三条件写闸门校验；
5. `rf_ring_write*`；
6. 退出时释放准入。

`OnReadInputData` 等其它 HAL 回调不触碰 Producer 写入路径（本设备是输出
设备），因此不在准入范围内。

## 2. 入口四步

```cpp
void OnWriteMixedOutput(...) {
    stats_.total_writes++;                                   // 1. 统计

    if (retired_.load(acquire)                              // 2. 全局退役标志
        || !callback_gate_.TryEnter()) {                     //    单条 fetch_add
        stats_.failed_writes++;
        return;                                              //    绝不加载 mapping 指针
    }
    CallbackLease lease(callback_gate_);                     // 3. RAII：出作用域必 fetch_sub

    RFSharedAudio* mem = SharedMemory();                     // 4. 整个回调只 load 一次
    if (!mem) { stats_.failed_writes++; return; }
    ...
}
```

四个设计点：

| 点 | 原因 |
|---|---|
| `retired_` 在前，闸门在后 | `retired_` 是快速拒绝；它是 `release` 写、`acquire` 读，用于在进程级退役后立刻停止一切写入，不依赖闸门状态 |
| 先闸门、后指针 | 闸门关闭时**根本不加载** `shared_memory_`，因此不存在"指针已置空但仍在解引用"的路径 |
| RAII 租约 | 回调体内有 5 处提前 `return`（空指针、格式不支持、写闸门失败、连接不健康、统计分支）。任何一处忘记减计数都会让排空永远等下去；析构函数保证唯一出口 |
| 指针只 load 一次 | 退役线程在租约期间不可能 unmapping；多次 load 只会引入不必要的重复读取与理论上的 TOCTOU 讨论 |

## 3. 为什么"先关后排"而不是"先等后关"

如果先等计数归零、再关闭闸门，那么在等待期间新回调可以不断进入，计数永不
归零（活锁）。正确顺序必须是：

1. **关闭**（`fetch_or(CLOSED)`）——此后不再有新的准入；
2. **轮询**计数直到 0 或超时；
3. 只有计数读到 0 才承认排空。

关闭与准入是同一条 RMW 的两个方向，因此不存在"闸门对计数器已关闭、对读者
仍开放"的窗口（旧双原子实现的缺陷，见
[verification/Batch-3-Closure-Fix.md](../verification/Batch-3-Closure-Fix.md) §3）。

## 4. 排空的时限与语义

| 参数 | 值 | 说明 |
|---|---|---|
| 轮询间隔 | 50 µs | 只是睡眠间隔，不是精度声明 |
| 排空预算 | 250 ms（`kRetireDrainBudget`） | 由调用方传入 `deadline`；测试可传更小值 |
| 判定 | `count == 0` | **只有计数器**能产生 `Drained` |
| 超时 | `TimedOut` | 语义是"未证明"，不是"大概安全" |

`TimedOut` 的唯一合法后续动作是 quarantine，绝不 munmap。原因：本次没等到
零，可能是一个回调正在长耗时处理，也可能是它永远不会返回；两者都无法区分，
因此必须按最坏情况处理。

一个永不返回的回调会导致**该 handler 之后每次**排空都无法证明——因为它的
准入计数永久存在。这不阻塞 liveness：新 mapping 仍可发布、新回调仍可进入
（`Open()` 刻意保留计数，不清零）。

## 5. 控制线程与实时线程的单向等待

```
控制线程  ──等待（有界）──►  实时线程
实时线程  ──永不等待──────►  控制线程
```

- 控制线程用 `sleep_for` 轮询，最坏阻塞 250 ms，之后放弃并 quarantine。
- 实时线程从不睡眠、不加锁、不分配、不等待任何条件变量。它只做两条 RMW
  （进入 + 离开）。
- 没有条件变量，因此没有丢失唤醒；没有信号量，因此没有优先级反转。

### 5.1 实时路径的指令成本

| 版本 | 实时路径内存操作数 | arm64 生成 |
|---|---|---|
| 旧双原子实现 | 4（load open + fetch_add + load open + fetch_sub） | `ldar` + `ldaddal` ×2 + 分支 |
| 当前单原子实现 | 2（fetch_add + fetch_sub）；happy path 可见 1 条 RMW | `ldaddal` + 条件跳转 + `ldaddal` |

无 `dmb`/`dsb`（acq_rel 的 RMW 在 arm64 上由 `ldaddal` 自身提供），无 CAS
重试循环，无 `dmb ish`。

## 6. `Open()` 的语义：保留计数

```cpp
void Open() noexcept { state_.fetch_and(~kClosedBit, acq_rel); }
```

**刻意不清零计数，也不断言计数为 0。**

理由：一个从未返回的回调仍然被计数。若 `Open()` 断言计数为 0，debug 构建会
因为一个挂死的回调而崩溃——把"无法证明安全"变成"崩溃"。而保守做法是让它
继续计数：之后的每次排空都会观察到这个残留准入、无法证明排空、quarantine
自己的 incarnation。安全性由"永不 munmap 未证明的映射"承担，而不是由
"保证计数归零"承担。

代价是：一旦出现挂死回调，该 handler 的所有后续 mapping 都会以 quarantine
结束（虚拟地址空间持续增长）。这是已知限制，见
[risks/Known-Limitations.md](../risks/Known-Limitations.md)。

## 7. 回调内的其它 RT 约束（现状）

准入层本身是 RT-safe 的（两条原子 RMW，无分配、无锁、无系统调用）。但**回调
体内仍然存在 Batch 0 之前就有的 RT 违例**，本轮未修：

| 编号 | 违例 |
|---|---|
| RT-1 | libASPL vendored 代码中的递归 `ioMutex_` 在回调链上被获取 |
| RT-2 | 回调内的日志调用（`RF_LOG_*` / `os_log`） |
| RT-3 | 首次回调触发的缓冲分配（`ResizeBuffers` 之外的惰性分配路径） |
| RT-4 | 格式重配置在回调内完成 |
| RT-5 | `Retire()` 不做排空（旧路径）——已由 Batch 3 引入 `RetireMapping()` 接管，但 RT-5 在报告中仍登记为未关闭项，见风险清单 |

因此本轮的 RT Safety 结论是 **CONDITIONAL PASS**：新引入的准入/排空部分为
PASS，整体回调路径仍为 CONDITIONAL PASS。

## 8. 状态组合表

| `retired_` | 闸门 | 结果 |
|---|---|---|
| false | OPEN | 正常写入 |
| false | CLOSED | `TryEnter()` 失败 → 计数失败，不写 |
| true | 任意 | 直接返回，不进入闸门 |
| 任意 | 计数饱和（理论） | debug 断言；release 下不会发生（见 L1） |

`retired_` 与闸门是两个独立开关：前者用于进程级终止（析构、设备移除），
后者用于单个 incarnation 的退役。

## 9. 已验证 / 未验证

已验证：

- 准入三类场景（进入/拒绝/abort 无残留）；
- 排空成功与超时分支；
- 重复 Close/Retire；
- 多读者并发准入；
- 回调早期 `return` 不泄漏计数（T2a/T2b 两个可达端点，见闭环报告 §6）。

未验证：

- 真实 HAL 在真实负载下的回调时长分布（因此 250 ms 预算是否足够无实测
  依据，只是取值保守）；
- 真实设备移除时 `Retire()` 与 `OnStopIO` 的并发交错（已通过 `io_mutex_`
  设计规避，但无实测）。

## 10. 相关文档

- 形式化证明：[CallbackGate-Memory-Model.md](CallbackGate-Memory-Model.md)
- 退役路径：[Mapping-Retirement.md](Mapping-Retirement.md)
- 剩余风险：[../risks/Known-Limitations.md](../risks/Known-Limitations.md)
