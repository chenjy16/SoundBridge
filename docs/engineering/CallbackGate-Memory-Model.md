# CallbackGate 内存模型证明

来源：Batch 3 Closure Fix（`CONDITIONAL PASS`）。原始证据：
`CallbackGate-Memory-Model-Proof.md`、`CallbackGate-Interleaving-Analysis.md`、
`Lock-Free-Guarantees.md`、`RT-Safety-Review.md`、`Closure-Fix-Report.md`，
均为当年研究目录的产物，不随本仓库发布。

本文是该证明的**正式归档版本**：保留全部规则编号、成立条件与不成立项，
不把 `CONDITIONAL PASS` 表述为无条件 PASS。

---

## 1. 被证明的对象

```cpp
class CallbackGate {
    static constexpr uint32_t kClosedBit = 1u << 31;
    static constexpr uint32_t kCountMask = ~kClosedBit;
    std::atomic<uint32_t> state_{kClosedBit};   // 初始 CLOSED，计数 0
};
```

状态字布局：

```
 bit 31        30                                    0
┌────────┬────────────────────────────────────────────┐
│ CLOSED │        admitted callbacks (count)          │
└────────┴────────────────────────────────────────────┘
```

| 操作 | 实现 | 内存序 |
|---|---|---|
| `TryEnter()` | `fetch_add(1)` | `acq_rel` |
| `TryEnter()` abort | `fetch_sub(1)` | `acq_rel` |
| `Leave()` | `fetch_sub(1)` | `acq_rel` |
| `Open()` | `fetch_and(~kClosedBit)` | `acq_rel` |
| `CloseAndDrain()` | `fetch_or(kClosedBit)` + 循环 `load(acquire)` | `acq_rel` / `acquire` |
| `Close()` | `fetch_or(kClosedBit)` | `acq_rel` |
| `ActiveCount()` / `IsOpen()` | `load()` | `acquire` |

需要证明的命题（四条）：

- **T1** 准入互斥：闸门关闭后到达的读者不可能触碰 mapping。
- **T2** 排空可靠：`CloseAndDrain` 返回 `Drained` 时，没有读者在 mapping 内。
- **T3** 发布可见：在 reopen 之后被准入的读者能看见新的 mapping 指针。
- **T4** 稳态：`count == 0` 是稳定性质，可以据此 munmap。

## 2. 旧实现为什么无法证明

Batch 3 的初版是**两个原子对象**：

```cpp
std::atomic<bool>     open_{false};
std::atomic<uint32_t> active_{0};

bool TryEnter() {
    if (!open_.load(seq_cst)) return false;     // (1)
    active_.fetch_add(1, seq_cst);              // (2)
    if (!open_.load(seq_cst)) {                 // (3)
        active_.fetch_sub(1, seq_cst);
        return false;
    }
    return true;
}
```

失败点逐条：

1. **(2) 与 (5)（closer 的 `active_.load`）之间没有跨对象顺序。** `active_`
   的 `fetch_add` 与 closer 对 `active_` 的读之间是同一对象上的 modification
   order，这没问题；问题是"closer 先关闭了 `open_`"这一事实，如何保证出现在
   `active_` 的读之前？两个对象之间没有 happens-before 边。
2. **seq_cst 总序 S 不覆盖 acq_rel 操作。** 如果全部操作都是 seq_cst，可以
   用单一总序 S 论证；但只要有一个 `acquire`/`release`（或普通操作）不参与
   S，该论证就出现空洞。旧实现在不同位置混用了 `seq_cst` 与 `acquire`。
3. **(1) 与 (2) 之间的窗口真实存在。** 读者在 (1) 读到 `open_ == true`，此
   刻 closer 关闭并读到 `active_ == 0`，然后读者才做 (2) 的 `fetch_add`。
   于是 closer 得到"排空"，而读者即将进入 mapping。第 (3) 次检查会救回这个
   读者（它随后 abort），但**无法把 closer 已经做出的"排空"判断撤回**——在
   真实硬件上如果 (3) 发生得足够晚，closer 可能已经在 munmap 之后。
4. **没有 fence 可以补上这个洞。** 加入 `seq_cst` fence 能让部分交错变得
   不可能，但"跨两个对象的原子性"不是 fence 能提供的：需要的是"关闭"与
   "计数"是同一个不可分割的动作。

结论：旧实现不是"大概率正确"，而是**在 C++ 内存模型内无法证明**。因此
Batch 3 Closure Fix 的目标不是给旧实现补证明，而是换成一个可证明的形状。

> 硬件观察：arm64 上 `ldaddal` / `ldar` 的实测行为很可能从未触发该窗口
> （见原始报告的硬件说明）。这说明缺陷是**证明层面的**，不是"必然崩溃"。
> 归档时必须保持这个区分，不能声称"旧实现已被证实崩溃"。

## 3. 新实现：单原子状态字

```
state_ = [ CLOSED : bit 31 ][ admitted count : bits 0..30 ]
```

读者：`prev = state_.fetch_add(1, acq_rel)`

- 若 `prev & CLOSED` → abort：`fetch_sub(1)`，返回 false，**不加载 mapping 指针**；
- 否则被准入，访问 mapping，退出时 `fetch_sub(1)`。

closer：`state_.fetch_or(CLOSED, acq_rel)`，然后轮询 `load(acquire)` 直到
`count == 0` 或超时。

**关键性质**：判断"是否开放"与"把自己计入"是**同一条 RMW**。因此不存在
"闸门对计数器已关闭、对读者仍开放"的执行——这种执行需要两次对同一对象的
独立访问，而这里只有一次。

## 4. 使用的内存模型规则

以下五条来自 C++20 `[atomics.order]` / `[intro.races]`，是全部论证的基础。

| 编号 | 规则 | 内容 |
|---|---|---|
| **F1** | RMW 读前驱、写后继 | 一个 RMW 读取**紧邻其前**在 modification order M 中的写所写入的值，并且它自己的写紧跟在那个写之后 |
| **F2** | 写-写一致性 | 同一对象上的两个写，按 M 排序；后写覆盖前写 |
| **F3** | 写-读一致性 | 一个 load 若 sequenced-after 某个对同一对象的写，则不能读到在 M 中早于该写的值 |
| **F4** | sequenced-before → happens-before | 同一线程内 sequenced-before；跨线程由 synchronizes-with 建立 happens-before |
| **F5** | release sequence / synchronizes-with | 以 release RMW 为首的 release sequence 包含它自身及其后所有对该对象的 RMW；一个读取其中任一元值的 acquire RMW 与它 synchronizes-with |

> **编号复用说明**：`packages/driver/src/MappingRetirement.hpp` 的头部注释把
> 上述三条原子事实标为 `L1`–`L3`（与该处上下文一致）。原始证明文档则用
> `L1`–`L3` 表示下文的三条不变量，用 `F1`–`F5` 表示原子规则。两套编号
> 不冲突，但读者需要按所在文档区分：本文统一使用 **F1–F5 = 原子规则**、
> **L1–L3 = 不变量**。

## 5. 定义与不变量

| 编号 | 内容 |
|---|---|
| **D1** | 一个读者从它的 `fetch_add` 返回一个 CLOSED 位为 0 的 `previous` 的那一刻起"被准入"，直到它自己的 `fetch_sub` 为止 |
| **L1**（计数算术恒等式） | `count(state_) == 已准入且尚未离开的读者数`；由 D1 与"每个被准入的读者恰好执行一次 `fetch_sub`"（RAII 租约）保证 |
| **L2**（次序关系） | 对任意读者 r，它的 `fetch_add` 在 M 中的位置 `A_r` 与它自己的 `fetch_sub` 的位置 `S_r` 满足 `A_r <_M S_r`（同一对象、同一线程、sequenced-before） |
| **L3**（贡献非负） | 每个被准入的读者在其存活区间内对计数的净贡献为 +1，且该贡献在整个区间内始终存在 |

`L1` 是"计数准确"的表述；它不是靠"读一个近似值"得出的，而是靠 M 上的
位置关系。

## 6. 四条定理

### 6.1 T1：准入互斥

设 closer 在 M 中的写为 `F`（`fetch_or(CLOSED)`），读者 r 的 `fetch_add`
为 `A_r`。由 F1，`A_r` 与 `F` 在 M 中必有确定次序：

- **`F <_M A_r`**：由 F1，`A_r` 读到的 `previous` 是 `F` 或其后的写，因此
  CLOSED 位已为 1 → r abort。abort 路径**不加载 mapping 指针**（O3），
  因此 r 不可能触碰 mapping。
- **`A_r <_M F`**：r 在 `F` 之前被准入，属于"已经在内的读者"，由 T2 处理。

结论：`F` 之后不可能出现新的被准入读者。T1 成立。

### 6.2 T2：排空可靠

反证。假设 `CloseAndDrain` 读到 `count == 0`（记为 load `P`），但存在被
准入且尚未离开的读者 r。

- 由 D1，r 的 `A_r` 返回的 `previous` 的 CLOSED 位为 0，因此
  `A_r` 在 M 中早于 `F`（否则由 T1 它应 abort）。
- 由 F1，`A_r` 的 `+1` 在 M 中出现在 `A_r` 之后；由 L3，该 `+1` 在 r 的
  整个准入区间内都存在于计数中，直到 `S_r`。
- `P` sequenced-after `F`（同一线程），由 F3（写-读一致性），`P` 不能读到
  M 中早于 `F` 的值；而 r 的 `+1` 在 M 中位于 `F` 之前且尚未被 `S_r`
  抵消，因此 `P` 读到的计数不可能为 0。
- 矛盾。

结论：读到 `count == 0` ⟹ 没有读者处于准入状态。T2 成立。

> 成立条件：`S_r` 必须真实执行。如果 `Leave()` 因为异常/提前 return 被跳过，
> 计数不会归零，排空会走向 `TimedOut`（保守结论），不会误报 `Drained`。
> 这正是 RAII 租约的作用：它让"跳过"不可能发生。

### 6.3 T3：发布可见

reopen 的顺序是：

```
1. handler 以 release 存储新指针：  shared_memory_.store(new, release)
2. Open()：                        state_.fetch_and(~CLOSED, acq_rel)
3. 读者：                          prev = state_.fetch_add(1, acq_rel)
4. 读者：                          mem = shared_memory_.load(acquire)
```

- 第 2 步是 release RMW；第 3 步是 acquire RMW 且读取同一对象。
- 由 F5，第 3 步与第 2 步 synchronizes-with（第 3 步读到的是第 2 步
  或其后 M 中的值，均属同一 release sequence）。
- 因此第 1 步 happens-before 第 4 步的 load，读者必然看见新指针。

结论：新 mapping 一旦被 `Open()` 开放，被准入的读者一定看见新指针。T3 成立。

### 6.4 T4：`count == 0` 的稳定性

在 `F` 之后：

- 由 T1，不会再有新读者被准入；
- 已准入的读者只能减少计数（`Leave()` 是唯一的减法来源，且每个读者只减
  一次）。

因此"计数为 0"一旦成立就不会被破坏。只有在这个稳定性成立时，才允许
`munmap`——这是 `munmap` 的唯一授权依据。T4 成立。

## 7. 五个义务（O1–O5）

| 编号 | 义务 | 满足方式 |
|---|---|---|
| **O2** | closer 的 `fetch_or(CLOSED)` 与给定 `fetch_add` 的关系只有"前/后"两种 | F1 + F2：同一对象上的 RMW 在 M 中全序 |
| **O3** | abort 路径不加载 mapping 指针 | `TryEnter()` 返回 false 后 `OnWriteMixedOutput` 立即 return，`mem` 在 `lease` 之后才 load |
| **O4** | 单调性：`F` 之后不再有新准入，已准入只减 | T1 + `Leave()` 唯一性 |
| **O5** | abort 读者可能短暂抬高计数，closer 可能需要多轮轮询 | 这只是延迟，不是正确性问题：该读者可证明不触碰 mapping |
| **O1** | D1 的定义覆盖"被准入即计入" | `fetch_add` 与判定位同一条 RMW |

## 8. 前提假设（A0–A4）

| 编号 | 假设 | 状态 |
|---|---|---|
| **A0** | 目标平台上 `std::atomic<uint32_t>` 的 RMW 是真正原子的（无撕裂、无"伪原子"） | 由 `is_always_lock_free` 静态断言 + 目标 ABI 保证；**未在 x86_64 真机验证运行** |
| **A1** | `acq_rel` RMW 提供 acquire 与 release 两种语义 | 标准保证 |
| **A2** | `count` 永不溢出 31 位（即并发准入不超过 2^31-1） | 物理上不可能；debug 断言兜底，release 下若溢出会"变成 CLOSED"——被风险清单登记为理论边界 |
| **A3** | 每个 `TryEnter() == true` 恰好对应一次 `Leave()` | RAII 租约 + 代码审查；无异常逃逸路径 |
| **A4** | 编译器不会把 `assert` 之外的可观测行为删除 | `assert` 在 `-DNDEBUG` 下消失，但所有原子操作是副作用，不可被删除 |

A0 是唯一"平台相关且未在全部目标架构实测"的假设。

## 9. Release sequence 与 Drain ACK 的成立条件

`DrainAck` 只在**同时**满足下列条件时才携带 `Drained`：

1. `CloseAndDrain` 的 `fetch_or(CLOSED)` 已执行（`F` 存在）；
2. 轮询 `load(acquire)` 读到 `(value & kCountMask) == 0`；
3. 该读在 deadline 之前完成；
4. `ack.revision == mapping_revision_`（handler 当前发布的 incarnation）；
5. `ack.epoch == claimed_epoch_`（该 incarnation 的 Host epoch）。

条件 1–3 是内存模型结论（T2 + T4）；条件 4–5 是**身份**结论（旧 ACK 不能
被新 incarnation 复用）。缺少 4 或 5 时，ACK 只用于诊断，不能授权 munmap。

**deadline 的作用**：只区分"已证明"（计数读到 0）与"未证明"（计数非 0）。
它**永远不能**产生 `Drained`。这一点是设计上的硬约束，不是实现细节。

## 10. Lock-free 保证

### 10.1 断言清单

| 类型 | 位置 | 断言 |
|---|---|---|
| `std::atomic<uint32_t>`（`state_`） | `MappingRetirement.hpp:168-169` | `is_always_lock_free` |
| `std::atomic<uint64_t>`（revision） | `Plugin.cpp:66-96` | 同上 |
| `std::atomic<bool>`（`retired_`） | 同上 | 同上 |
| `std::atomic<RFSharedAudio*>`（`shared_memory_`） | 同上 | 同上 |

全部为 `static_assert`，即**编译期**失败。这是 CF-2 的闭合方式：如果某个
目标 ABI 上这些类型退化为内部加锁，构建会直接失败，而不是在实时回调里
悄悄加锁。

### 10.2 刻意不断言的类型

`std::atomic<uint64_t>` 在 32 位平台上通常不是 lock-free。当前不为其断言
"跨平台 lock-free"，因为 32 位不是受支持目标；支持的只有 arm64 与 x86_64。
把这一点写成"32 位不支持"比写成一个假的保证更诚实。

### 10.3 lock-free ≠ wait-free

`fetch_add` 可能与其他核争用同一缓存行，从而在有限时间内无法完成。这仍然
是 lock-free（系统整体有进展），但不是 wait-free（单个操作有时间上界）。
RT 结论因此不能写"无界延迟不存在"，只能写"不会加锁、不会无限等待其他线程
主动释放资源"。

### 10.4 实测指令（arm64）

```
TryEnter:   ldaddal w?, w?, [x?]        ; 单条 LSE RMW，acq_rel
            tbnz    w?, #31, abort
Leave:      ldaddal / ldadd             ; 单条 RMW
```

无 `dmb`/`dmb ish`/`dsb`，无 CAS 重试循环。x86_64 上为 `lock xadd`（同样是
单条带锁前缀的指令，但不阻塞其他线程获取锁——它是缓存一致性协议层面的
原子，不是 mutex）。

## 11. 未被证明的部分（必须保留）

原报告 §8 明确列出以下内容**没有**被证明，归档时不得省略：

1. **真实硬件上的时序分布**：证明是模型层面的，不包含"250 ms 是否够用"。
2. **回调体的 RT 安全**：`ioMutex_`、日志、分配、格式重配仍是既有违例
   （RT-1 … RT-5），本证明只覆盖闸门本身。
3. **多生产者**：模型只覆盖"单 producer + 多读者 + 单 closer"。多 producer
   由 admission owner token 排除，不在本证明范围内。
4. **32 位平台**：`std::atomic<uint64_t>` 的 lock-free 性未断言。
5. **A0 的真机验证**：`is_always_lock_free` 是编译期属性，不等于运行时
   无撕裂（理论上仍可能被某个异常 ABI 违反，虽然标准要求它成立）。
6. **多 closer 并发**：`CloseAndDrain` 被调用两次（例如 StopIO 与析构竞争）
   时，第二个 closer 会看到已经 CLOSED 的状态并继续轮询；模型覆盖这种
   情况（`fetch_or` 幂等），但真实并发未实测。
7. **ABA**：计数回绕到原值理论上可能，但需要 2^32 次准入，物理上不可能。

## 12. 验证证据

| 项 | 结果 |
|---|---|
| 编译期 lock-free 断言 | PASS（4 处） |
| 单测组数 / 断言点 | 17 组 / 119 处 `check()` |
| 普通测试 | 40/40 |
| TSan | 5/5 |
| ASan | 通过，0 条报告 |
| C++ Memory Model Proof | PASS |
| Multi-reader Safety | PASS |
| Repeated Close/Retire | PASS |
| Mapping Incarnation Isolation | PASS |
| RT Safety | **CONDITIONAL PASS** |
| ABI Protection | PASS |

完整报告属当年批次归档，不随本仓库发布；上表结论未改动。

## 13. 相关文档

- 运行视角：[Callback-Lifecycle.md](Callback-Lifecycle.md)
- 退役路径：[Mapping-Retirement.md](Mapping-Retirement.md)
- 剩余风险：[risks/Known-Limitations.md](../risks/Known-Limitations.md)
