# Batch 3 Closure Fix 归档报告

| 项 | 值 |
|---|---|
| 批次 | Batch 3 Closure Fix — CallbackGate Memory Ordering |
| 结论 | **`CONDITIONAL PASS`** |
| 闭环项 | CF-1、CF-2、CF-3 **全部关闭** |
| 平台 | macOS 27.2.1（`26B131`）/ arm64 |
| 工具链 | Apple clang 21.0.0 |
| 协议 | `0x00020200`（未变） |
| header | `320`（未变） |
| 原始资料 | 11 份，见 §12 与 [Documentation-Migration-Manifest.md](../Documentation-Migration-Manifest.md) |

**本报告不把 `CONDITIONAL PASS` 写成 `PASS`。** 条件见 §13。

---

## 1. 本轮做了什么

Batch 3 引入的 `CallbackGate` 用两个原子对象（`open_` + `active_` + 二次
检查）实现准入与排空。Closure Review 提出三个 Finding：

| 编号 | Finding | 状态 |
|---|---|---|
| **CF-1** | 双原子实现无法在 C++ 内存模型内给出证明 | **关闭**（改为单原子状态字） |
| **CF-2** | 回调路径上的原子操作需要**编译期** lock-free 保证 | **关闭**（4 处 `is_always_lock_free`） |
| **CF-3** | Quarantine 的生命周期需要一个明确的审查结论 | **关闭**（8 问全部回答，见 §6） |

修复方式：把 `[open flag][count]` 两个原子对象合并为**一个 32 位原子状态字**

```
state_ = [ CLOSED : bit 31 ][ admitted count : bits 0..30 ]
```

准入一次 `fetch_add`，**没有 CAS 重试循环**。

## 2. 旧实现为什么不能证明（保留记录）

```cpp
std::atomic<bool>     open_{false};
std::atomic<uint32_t> active_{0};

bool TryEnter() {
    if (!open_.load(seq_cst)) return false;   // (1) 检查
    active_.fetch_add(1, seq_cst);            // (2) 计数
    if (!open_.load(seq_cst)) {               // (3) 二次检查
        active_.fetch_sub(1, seq_cst);
        return false;
    }
    return true;
}
```

| # | 失败原因 |
|---|---|
| 1 | (2) 与 closer 对 `active_` 的读之间，**没有跨对象顺序**。`open_` 的关闭无法传递到 `active_` 的读 |
| 2 | seq_cst **总序 S 不覆盖 acq_rel 操作**；旧实现混用内存序，总序论证有空洞 |
| 3 | (1) 与 (2) 之间的窗口**真实存在**：读者读到 open，closer 关闭并读到 count==0，然后读者才 fetch_add。(3) 会救回读者，但**无法撤回 closer 已做出的"排空"判断** |
| 4 | 没有 fence 能补：需要的是"关闭与计数是同一动作"的原子性，不是屏障 |

> 必须保留的限定：这是**证明层面**的缺陷，不是"已被证实必然崩溃"。arm64 上
> `ldaddal` / `ldar` 的实测行为很可能从未触发该窗口。归档时不能把"无法证明"
> 写成"已复现崩溃"。

## 3. 新实现

```cpp
static constexpr uint32_t kClosedBit = 1u << 31;
static constexpr uint32_t kCountMask = ~kClosedBit;
std::atomic<uint32_t> state_{kClosedBit};   // 初始 CLOSED，计数 0

bool TryEnter() noexcept {
    const uint32_t previous = state_.fetch_add(1, acq_rel);
    if (previous & kClosedBit) { state_.fetch_sub(1, acq_rel); return false; }
    return true;                             // 不加载 mapping 指针前的唯一门槛
}
void Leave() noexcept            { state_.fetch_sub(1, acq_rel); }
void Open() noexcept             { state_.fetch_and(~kClosedBit, acq_rel); }
void Close() noexcept            { state_.fetch_or(kClosedBit, acq_rel); }
DrainAck CloseAndDrain(rev, epoch, deadline) noexcept {
    state_.fetch_or(kClosedBit, acq_rel);
    while ((state_.load(acquire) & kCountMask) != 0) {
        if (now() >= deadline) return DrainAck{rev, epoch, DrainOutcome::TimedOut};
        sleep_for(50us);
    }
    return DrainAck{rev, epoch, DrainOutcome::Drained};
}
```

四个刻意选择：

| 选择 | 理由 |
|---|---|
| `fetch_add` 而非 CAS 循环 | 检查与计数合成一条 RMW；不写"重试成功即正确"的论证 |
| `Open()` 用 `fetch_and` 且**保留计数** | 挂死回调的计数永久存在；清零会把"无法证明"变成"误判安全" |
| deadline 只决定"未证明" | `Drained` 只能由计数器读到 0 产生 |
| 无 CAS、无 fence、无条件变量 | 只有 M 上的位置关系，没有总序假设，也没有丢失唤醒 |

完整证明（F1–F5、D1、L1–L3、T1–T4、A0–A4、O1–O5）见
[engineering/CallbackGate-Memory-Model.md](../engineering/CallbackGate-Memory-Model.md)。

### 3.1 证明结构摘要（§6.1 要求保留）

| 要素 | 内容 |
|---|---|
| **CLOSED bit** | bit 31；由 closer 用 `fetch_or` 置位，由 `Open()` 用 `fetch_and` 清除 |
| **admitted count** | bits 0..30；每条准入 +1，每条离开 -1 |
| **单一原子对象的 modification order M** | 所有论证只在 M 上展开，不需要 seq_cst 总序 |
| **RMW 读前驱 / 写后继（F1）** | RMW 读 M 中紧邻其前的副作用，并立即在其后写入 |
| **写-写一致（F2）/ 写-读一致（F3）** | 给出 closer 的 `F` 与读者 `A_r` 的次序二分，以及"读到不小于自身写的值" |
| **release sequence（F5/L3）** | `Open()` 是 release RMW，读者的 `fetch_add` 是 acquire RMW 且读同一 release sequence → 指针 store happens-before 读者的 load |
| **Drain ACK 成立条件** | ①`fetch_or(CLOSED)` 已执行 ②`load(acquire)` 读到 count==0 ③在 deadline 前 ④`ack.revision == mapping_revision_` ⑤`ack.epoch == claimed_epoch_`。缺 ④或⑤时 ACK 只能诊断 |
| **T1 准入互斥** | `F<_M A_r` → 读者 abort 且不加载指针 |
| **T2 排空可靠** | 反证：若 count 读到 0 而 r 仍在内，则 r 的 +1 在 M 中位于 F 之前且未被抵消，与读到 0 矛盾 |
| **T3 发布可见** | release store → release RMW `Open()` → acquire RMW `fetch_add` → 读者 load 必见新指针 |
| **T4 稳定性** | F 之后无新准入、已准入只减，因此 count==0 是稳定性质，可授权 munmap |

## 4. Lock-free 保证（CF-2）

```cpp
static_assert(std::atomic<uint32_t>::is_always_lock_free,
              "CallbackGate state word must be lock-free on the target ABI");
```

另在 `Plugin.cpp:66-96` 对以下三类各有一条同样的断言：

| 类型 | 用途 |
|---|---|
| `std::atomic<uint64_t>` | `mapping_revision_` |
| `std::atomic<bool>` | `retired_` |
| `std::atomic<RFSharedAudio*>` | `shared_memory_` |

全部为**编译期**断言：目标 ABI 上若退化为内部加锁，构建直接失败。

刻意**不**断言的部分：

- `std::atomic<uint64_t>` 在 32 位平台上通常非 lock-free；当前不受支持，因此
  不写一个假的跨平台保证。
- lock-free ≠ wait-free：`fetch_add` 仍可能争缓存行。RT 结论只能说"不加锁、
  不无限等待其他线程释放资源"，不能说"有严格上界"。

### 4.1 实测代码生成（arm64）

```
TryEnter  : ldaddal w?, w?, [x?]   ; 单条 LSE RMW（acq_rel）
            tbnz    w?, #31, abort
 aborted  : ldaddal（回退）
Leave     : ldaddal / ldadd
```

无 `dmb` / `dmb ish` / `dsb`，无循环。实时路径内存操作从 **4 → 2**（happy
path 可见 1 条 RMW）。

## 5. 三个闭包 Finding 的闭合方式

| Finding | 闭合证据 |
|---|---|
| CF-1 | 单原子状态字 + T1–T4 证明；旧实现作为"无法证明"的对照保留在 §2 |
| CF-2 | 4 处 `static_assert(is_always_lock_free)`；arm64 反汇编确认单指令 RMW |
| CF-3 | Quarantine 8 问审查（§6），结论为"无安全回收条件，保留至进程退出" |

## 6. Quarantine 生命周期审查（CF-3）

| # | 问题 | 结论 |
|---|---|---|
| Q1 | quarantine 的映射会被释放吗？ | 不会，保留至进程退出 |
| Q2 | 有释放路径吗？ | 没有。没有 `erase` / `clear` / TTL / PID 判活 |
| Q3 | 会重复 Retain 同一个 mapping 吗？ | 不会。`std::move` + `if (!mapping) return;` |
| Q4 | 会影响新 incarnation 吗？ | 不会。新 inode + 新 revision，互不相关 |
| Q5 | 何时增长？ | 仅在 `TimedOut`；`Drained` 与 `NothingToRetire` 都不增长 |
| Q6 | 有硬上限吗？ | 没有 |
| Q7 | 存在可证明安全的回收条件吗？ | 不存在。控制路径绕过闸门，`use_count()` 不是同步点 |
| Q8 | 代价是什么？ | 虚拟地址空间：每条 32 KiB ring + 320 B header，`st_size ≤ 64 MiB` |

结论：quarantine 是**当前唯一可证明安全**的策略，其代价（虚拟地址空间）被
明确接受并登记为风险。它不是"临时方案"，也不是"待修的 bug"。

## 7. RT Safety 审查

| 项 | 结果 |
|---|---|
| 闸门本身 RT-safe | 是：2 条 RMW，无分配、无锁、无系统调用 |
| 禁止项（11 条）逐条检查 | 通过（闸门范围内） |
| 实时路径内存操作 | 4 → 2 |
| 单向等待 | 成立：可以回调等控制线程的情况不存在 |
| O5 副作用 | abort 读者可能短暂抬高计数 → 只增加轮询次数，不影响正确性 |
| 整体回调路径 | **仍有 RT-1 … RT-5 违例（见 §11）** |
| 判定 | **CONDITIONAL PASS** |

> 原始 `RT-Safety-Review.md` 对新代码段的判定为 PASS；但本批次整体结论是
> **CONDITIONAL PASS**，因为回调路径上仍存在 RT-1…RT-5。归档统一采用整体
> 结论，不采用局部 PASS 作为批次结论。

## 8. Changed Files（§6.1 要求保留）

| 文件 | 改前行数 | 改后行数 | 变化 | 改前 SHA-256 | 改后 SHA-256 |
|---|---|---|---|---|---|
| `packages/driver/src/MappingRetirement.hpp` | 235 | 326 | +91 | `8d2d3eccf551081fa4264d328ba7d6e6a580f06fa10b51a27205a806f312bc33` | `8fdc46a1e49a9ea2e3c2e71d1b38f314ca6fb37c8101dc7e9f7e4c381f282f06` |
| `packages/driver/src/Plugin.cpp` | 1693 | 1725 | +32 | `f8e089b144c0b07a188a7c11861f3e7e4289616ba91fccc3d10607d9c50a4508` | `8f31748c5e6500aa9f81704fb3ad6416d06fbe9915f4c1141b5e4139e79b931d` |
| `packages/driver/tests/MappingRetirementTests.cpp` | 345 | 727 | +382 | `b58cd2370c7cbb6b307ebefd6a750761d31d15b25f3bc94aeed50c17f46ec063` | `1c3eff4c5e9fb0655d1942afe01a5c08c1dd2048420b943845e7a2bd4a6e2bb6` |

改动形态：

- `MappingRetirement.hpp`：删除 `open_` / `active_` 两个成员，改为单个
  `state_`；`TryEnter` / `Leave` / `Open` / `Close` / `CloseAndDrain` /
  `ActiveCount` / `IsOpen` 全部重写；新增 `RawStateForTesting()`；新增证明
  注释块（头部 98 行）。
- `Plugin.cpp`：单处 32 行插入（`RetireMapping()` 内的排空/隔离分支与诊断
  日志），以及 `#include` 与断言块。
- `MappingRetirementTests.cpp`：整体重写。旧测试针对双原子的中间状态设计，
  新实现中该状态**不可达**，因此必须重构（见 §10）。

**未改动**：`ControlProtocol.hpp`、`ProducerToken.hpp`、`ControlProtocolTests.cpp`、
`ProducerTokenTests.cpp`、`CMakeLists.txt`、`Info.plist`、4 份
`RFSharedAudio.h`、`VERSION`、vendor 子模块。

## 9. 测试报告（§6.3 要求保留）

### 9.1 命令

```bash
# 普通构建与运行
cd packages/driver
clang++ -std=c++17 -O2 -I src -I include -I vendor/libASPL/include \
        tests/MappingRetirementTests.cpp src/Plugin.cpp -o /tmp/mr_test
/tmp/mr_test

# TSan
clang++ -std=c++17 -O1 -g -fsanitize=thread ... -o /tmp/mr_tsan && /tmp/mr_tsan

# ASan
clang++ -std=c++17 -O1 -g -fsanitize=address ... -o /tmp/mr_asan && /tmp/mr_asan

# Release 构建（CMake，universal）
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build build -j

# ABI
tools/sync_shared_header.sh --check
tools/check_protocol_layout.sh
```

### 9.2 结果

| 项 | 结果 |
|---|---|
| 测试组 | **17 组** |
| 断言点（`check()` 调用位置） | **119 处** |
| 普通测试重复运行 | **40 / 40** |
| TSan | **5 / 5** |
| ASan | 通过，**0 条报告** |
| CMake Release 构建 | 成功 |
| Fat binary | `lipo -info` → `x86_64 arm64` |
| 4 份头副本 | 哈希全同（`0f415450…c060ee`） |
| `check_protocol_layout.sh` | exit 0；`0x00020200`、320 B、offset 320、plist 131584、`alignof 8` |
| `ControlProtocolTests` | 通过 |
| `ProducerTokenTests` | 通过 |

### 9.3 测试能证明什么、不能证明什么

能：

- 准入/abort/离开的计数不残留；
- 关闭后不再有新准入；
- 排空成功与超时的分支行为；
- 重复 Close/Retire 不崩溃；
- 多读者并发准入；
- incarnation 隔离（revision/epoch）。

不能：

- 不能证明真实硬件上的时序分布；
- 不能证明 250 ms 预算在真实负载下足够；
- 不能替代真实 HAL 设备移除；
- 不能证明回调体内没有 RT 违例（RT-1…RT-5 仍在）。

## 10. 测试偏差（§6.2 要求保留）

### 10.1 T2 原始场景不再可达

原 T2 的意图是"closer 关闭后读者无法进入"。旧实现中它依赖一个**真实存在的
中间状态**：读者已 `load(open) == true` 但尚未 `fetch_add(active_)`。

新实现中，"判断开放"与"计数"是同一条 `fetch_add`。上述中间状态
**在模型上不可达**——不存在一个执行序列让读者"看起来开放但还没被计数"。

因此测试被拆成**两个可达端点**：

| 编号 | 场景 | 断言 |
|---|---|---|
| **T2a** | 先 `Close()`，再 `TryEnter()` | 返回 false，计数回到 0，**无残留** |
| **T2b** | 先 `TryEnter()`（被准入），再 `CloseAndDrain()` | 在读者 `Leave()` 之前，排空**不能**返回 `Drained` |

**不能写成"原始 T2 按原样通过"。** 准确表述是：原始 T2 所依赖的中间状态已被
消除，因此改为验证它的两个可达端点，两者均通过。

### 10.2 T5c 是压力测试

`T5c` 用大量并发线程反复进入/离开，观察是否出现计数异常或崩溃。它是
**压力测试**，不是确定性 rendezvous 测试：

- 它可能通过而不实际覆盖某个特定交错；
- 它不能证明某个交错发生过；
- 它只能说明"在这台机器、这次运行、这个调度下没有出现异常"。

归档时不能把 T5c 的通过表述为对某个特定竞争的确定性覆盖。

### 10.3 其它偏差

| # | 偏差 |
|---|---|
| 1 | Host `swift test` **未执行** |
| 2 | App `swift build` **未执行** |
| 3 | 真实设备移除未执行 |
| 4 | 未执行 Gate 0 / EXP-1 / preflight / Driver 安装 / 卸载 / CoreAudio 重启 |
| 5 | TSan 只覆盖 5 项，不是全量 |

## 11. 剩余风险（§11 要求保留）

### 11.1 本批次风险（R-1 – R-7）

| 编号 | 风险 |
|---|---|
| **R-1** | 并发 `RetireMapping` 依赖 `io_mutex_`；`mapping_owner_` 是普通 `shared_ptr`，不是原子对象 |
| **R-2** | Quarantine 无上限，持续 `TimedOut` 会持续增长 |
| **R-3** | A0（原子硬件行为）未在全部目标架构实测 |
| **R-4** | 轮询由**时间**界（250 ms）而非操作数界 |
| **R-5** | Host / App 未在本轮运行回归 |
| **R-6** | inode 回收路径未实测 |
| **R-7** | `revision` 是 handler 局部量，不跨进程 |

### 11.2 继承自 Batch 3（RR-1 – RR-10）

| 编号 | 风险 | 状态 |
|---|---|---|
| RR-1 | 双原子跨对象顺序不可证 | **关闭**（4 处 `is_always_lock_free` + 单原子） |
| RR-2 | 并发 RetireMapping 依赖 `io_mutex_` | 未关闭 |
| RR-3 | Quarantine 无上限 | 未关闭 |
| RR-4 | A0 未全架构实测 | 未关闭 |
| RR-5 | 时间界而非操作数界 | 未关闭 |
| RR-6 | Host/App 未回归 | 未关闭 |
| RR-7 | inode 回收未实测 | 未关闭 |
| RR-8 | revision 不跨进程 | 未关闭 |
| RR-9 | 真实设备移除未验证 | 未关闭 |
| RR-10 | macOS 14.4 未验证 | 未关闭 |

### 11.3 RT 违例（RT-1 – RT-5，本轮未处理）

| 编号 | 违例 |
|---|---|
| RT-1 | libASPL 递归 `ioMutex_` 出现在回调链上 |
| RT-2 | 回调内日志 |
| RT-3 | 回调内惰性分配 |
| RT-4 | 回调内格式重配置 |
| RT-5 | `Retire()` 旧路径不做排空（已由 `RetireMapping` 接管，但条目未关闭） |

RT-1…RT-5 是**已知实现限制**，不是"已修复"，也不是"不影响正确性"。

## 12. Manifest 归档

### 12.1 归档说明

原始 `Input-Manifest.sha256` / `Output-Manifest.sha256` 中的路径前缀为
`SoundBridge-Research/Architecture/Real-Project-Development/Batch-3-Closure-Fix-CallbackGate/`。
该目录已退役，直接复制会在仓库中留下失效路径。因此下面以
`<research>/Batch-3-Closure-Fix-CallbackGate/` 代替该前缀，**所有校验值逐字
保留**，未做任何重新计算。原始文件哈希见 §12.4。

### 12.2 Input Manifest（33 条：30 OK + 3 FAILED）

```text
# Input-Manifest.sha256 — Batch 3 Closure Fix (CallbackGate Memory-Ordering Proof)
# SoundBridge 1.2.0
# Repo root: /path/to/SoundBridge
# branch: main   HEAD: ab3677072f0dcb54de27ba4dcabfd11e64ae41ec
#
# IMPORTANT — 作为"改前快照"使用前必读：
#   * 本批次修改了三个文件，下面的哈希是它们的 PRE-change 状态：
#       packages/driver/src/MappingRetirement.hpp
#       packages/driver/src/Plugin.cpp
#       packages/driver/tests/MappingRetirementTests.cpp
#     它们的 POST-change 哈希在 Output-Manifest.sha256。
#   * 因此对当前树校验时，本文件会报告恰好 3 条 FAILED 与其余 OK。
#     这 3 条 FAILED 正是"本批次确实改动了它们"的证据；任何其它 FAILED
#     才是真正的完整性问题。
#     交付时校验结果：33 条 —— 30 OK，3 FAILED（仅上述三个文件）。
#   * 其余每一行都是本批次只读的文件，改前哈希 == 当前哈希。
#   * Closure Fix 任务书本身以粘贴文本形式到达，无稳定路径，无法记录哈希。
#   * B3 = <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement

# ---- Section A: code under review (PRE-change) ----
8d2d3eccf551081fa4264d328ba7d6e6a580f06fa10b51a27205a806f312bc33  packages/driver/src/MappingRetirement.hpp
f8e089b144c0b07a188a7c11861f3e7e4289616ba91fccc3d10607d9c50a4508  packages/driver/src/Plugin.cpp
b58cd2370c7cbb6b307ebefd6a750761d31d15b25f3bc94aeed50c17f46ec063  packages/driver/tests/MappingRetirementTests.cpp
ab92ec32508a7b51c33dc9c3da5d0360783ba85ef83b7a46bd880916f1e54fdf  packages/driver/src/ControlProtocol.hpp
e712c25c14008fd9dd147dc9ddbb867efdc27fbd18cd9234431f4b0b4d30eb6a  packages/driver/src/ProducerToken.hpp
7b1d6fc67b9a61fe972d2dce95f5bf13135fd82db3d0b4402f85b8f208f3fa37  packages/driver/tests/ControlProtocolTests.cpp
7cb59d3f8665c1a8a9b72db789ff4a66095877e4998f086f4bc0f52b0b0a4bd9  packages/driver/tests/ProducerTokenTests.cpp
efb615f0e1cf3e846a1088ffa76a9f8186ab316261bd25d38898dedee147161f  packages/driver/CMakeLists.txt
275eb53aadcd34069b07aae4692bdbfb501cb2759328b8aca3560e536631cbb9  packages/driver/Info.plist
2498c120a35038311338dd47eeee165bed5b5368534914c5970764fe4953cfe2  packages/driver/vendor/libASPL/src/Device.cpp
be4f9e93d62fea71868c7e73e10dbdc369410433d4a5c368e049f8a21c761b84  packages/driver/vendor/libASPL/src/Plugin.cpp
6268cd2e23116d7fae6acaf0a905c82fddd2ed61495f1fbfffeacf06ffd568f4  packages/driver/vendor/libASPL/include/aspl/Device.hpp
93ce7c15f280dbe70b32f364bc328e44402b6911785739907d29f4dc943ddfb6  packages/driver/vendor/libASPL/include/aspl/IORequestHandler.hpp
041273f429e7b5f00cb8b92da3c36cb7b04b21411b0b4ae1bcf50ccec7a03fe7  packages/driver/vendor/libASPL/include/aspl/Stream.hpp
8629cc598576c686fa95473b4b72fe1b4dedff37a356879211547c7f20157368  packages/host/Tests/SoundBridgeHostTests/MappingIncarnationTests.swift
95058fc0e43bcb1adc8b4ee7daf8c38d3b2364917367e3576165f2964e708658  tools/check_protocol_layout.sh
1e5b51cde515396a9fa762909cf8ca6584ccc564b325d2eebeea76175fe95c4d  VERSION

# ---- Section B: Shared Audio Header, 4 copies (must be identical) ----
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/shared/include/RFSharedAudio.h
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/driver/include/RFSharedAudio.h
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h

# ---- Section C: Batch 3 deliverables read as input (12 files) ----
bdabd33e5e8a5765e6c7fbe6862ec2001ed457c106a2143641f978c45d97358e  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Batch-3-Implementation-Design.md
a17a60af94149b50bdfe416464cbedf481567d3dbe4ca20f7959a76b286c4af1  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Callback-Drain-Proof.md
7ef768acc6e9e64ac2ae46cc38e4fccf69611d3c515a049a62f61f79946f8e36  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Changed-Files.md
d1cb32e4d726630afd69208ba680905ba4bdb941338a28256aa6f497cf38b854  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Implementation-Report.md
eb5c7d494c934e7d6d967f78205540a7593ecc5c718e6f2941e9f4eb30a25b71  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Mapping-Lifecycle.md
85ce831bc156a7dc74beb78fa1e1bd88784691c8bbdcdf80525181a17e1e1cda  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Mapping-Retirement-Proof.md
856246073678a0d75763babf8492da8c5fc763a956f3419c98e9428f32c861b4  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/RT-Safety-Audit.md
c2431cc8a7861dd51140d4091af643b540086607962beadcf2c5e5aa222b1282  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Remaining-Risks.md
3d5c8b44f8197f98012da55de2286a60d2b46a81312baa89445eaacbd625e034  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Stale-Claim-Recovery.md
95565d5fd7507e3ec1c4d0abe6fad914f30a171761f88d6c82be7832791aa7a6  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Test-Report.md
4fa1c846b809977f3b2002eb28640f2a771d4b3d5cb304e64c2d46fa5a43dd70  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Input-Manifest.sha256
cedfebcf7c2e95920f37ce5067934614893c9951c75b5009c91e113858e768b6  <research>/Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement/Output-Manifest.sha256
```

**解释**：3 条 FAILED 是三个被修改文件的**改前**哈希记录，不是校验系统失效，
也不是归档失败。任何**其它** FAILED 才是完整性问题。

### 12.3 Output Manifest（19 条：19 OK）

```text
# Output-Manifest.sha256 — Batch 3 Closure Fix deliverables
# Repo root: /path/to/SoundBridge
# branch: main   HEAD: ab3677072f0dcb54de27ba4dcabfd11e64ae41ec
#
# 本文件不能包含自身哈希；其哈希见 §12.4。
# 本批次读取的输入（改前状态）在 Input-Manifest.sha256。
# Section A = 10 份报告交付物（第 11 份是 Input-Manifest，列在 Section A 末尾）。
# Section B = 本批次产生的代码产物（POST-change）。
# Section C = 必须保持不变的 ABI / 协议不变量。
#
# 以下所有行对交付时的树校验均为 OK。

# ---- Section A: deliverables ----
89be3a547d9b62adc3eb81f4f075147ae3702648deea51ce66fcb3642ed75012  <research>/Batch-3-Closure-Fix-CallbackGate/Closure-Fix-Report.md
6398009da4d9f66353f32266d796fd0c320dcd3c7894376cf8ce597487ca176a  <research>/Batch-3-Closure-Fix-CallbackGate/CallbackGate-Memory-Model-Proof.md
2ac6a6db8c90fbeef1a2b6e70d48664f7e76a1fa594f6052aef1dc7060e34815  <research>/Batch-3-Closure-Fix-CallbackGate/CallbackGate-Interleaving-Analysis.md
8c625677cd5a557e694d903276090ae0e3b50ed91955d111d4b65bc3c2ef21fc  <research>/Batch-3-Closure-Fix-CallbackGate/Lock-Free-Guarantees.md
892b5c933c6009875bc909001c1e4a86a2980468aafe28b525d434044819d077  <research>/Batch-3-Closure-Fix-CallbackGate/Quarantine-Lifecycle-Review.md
4478ca5b2dbd1d80fb970f2e444971927623a877fd44baf7fea6c1e1fe10174f  <research>/Batch-3-Closure-Fix-CallbackGate/RT-Safety-Review.md
b2dec966685dabfec204b688a623906e8dfd46f98b2b1015a652c315c292a2d7  <research>/Batch-3-Closure-Fix-CallbackGate/Changed-Files.md
0360470f7dbc4873981e6d7a9db9a5479a9af9e290e358dc55edb27b2bdfd36c  <research>/Batch-3-Closure-Fix-CallbackGate/Test-Report.md
2c93d588a2e014e01c24b49eac76543e579a6915577a6743f2613cf63313962c  <research>/Batch-3-Closure-Fix-CallbackGate/Remaining-Risks.md
e54626c4cfadb01716853ba771cf5f8e95dd0b2a1c74519569105f1fe4819cfb  <research>/Batch-3-Closure-Fix-CallbackGate/Input-Manifest.sha256

# ---- Section B: code artifacts (POST-change) ----
8fdc46a1e49a9ea2e3c2e71d1b38f314ca6fb37c8101dc7e9f7e4c381f282f06  packages/driver/src/MappingRetirement.hpp
8f31748c5e6500aa9f81704fb3ad6416d06fbe9915f4c1141b5e4139e79b931d  packages/driver/src/Plugin.cpp
1c3eff4c5e9fb0655d1942afe01a5c08c1dd2048420b943845e7a2bd4a6e2bb6  packages/driver/tests/MappingRetirementTests.cpp

# ---- Section C: ABI / protocol invariants (unchanged by this batch) ----
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/shared/include/RFSharedAudio.h
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/driver/include/RFSharedAudio.h
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee  apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
275eb53aadcd34069b07aae4692bdbfb501cb2759328b8aca3560e536631cbb9  packages/driver/Info.plist
1e5b51cde515396a9fa762909cf8ca6584ccc564b325d2eebeea76175fe95c4d  VERSION

# Expected verification result: 19 entries total — 19 OK, 0 FAILED
# (10 deliverables + 3 code artifacts + 6 ABI invariants).
# Verified at delivery. Any FAILED line means a deliverable or ABI invariant
# changed after this manifest was written.
```

**交付时校验结果：19 条 —— 19 OK，0 FAILED**（10 份交付物 + 3 份代码产物 +
6 条 ABI 不变量）。

### 12.4 Manifest 自身哈希

| 文件 | SHA-256 |
|---|---|
| `Output-Manifest.sha256` | `c1620c3a4419a9734d3ba618895f034ee486bfdcc3958b5f1e11d5b1b628ee86` |
| `Input-Manifest.sha256` | `e54626c4cfadb01716853ba771cf5f8e95dd0b2a1c74519569105f1fe4819cfb` |

`Output-Manifest` 的自哈希已在本次归档时用
`shasum -a 256` 复核，与交付时记录一致。

## 13. 结论与条件

**`CONDITIONAL PASS`**。三个 Closure Finding 全部闭合；测试与 ABI 检查全部
通过。结论带条件的理由：

| 编号 | 条件 |
|---|---|
| **C-1** | 真实 HAL 设备移除未在硬件上执行 |
| **C-2** | 真实 Driver 部署 / 安装 / 卸载未执行 |
| **C-3** | macOS 14.4 未认证（当前平台 27.2.1） |
| **C-4** | Host / App 完整回归未在本轮运行 |
| **C-5** | RT-1 … RT-5 未处理 |
| **C-6** | Quarantine 无回收机制，长期代价已接受但未测量 |

本轮**未执行**：Gate 0、EXP-1、preflight、Driver 安装或卸载、CoreAudio
重启。归档不得把这些说成已执行。

## 14. 相关文档

- [engineering/CallbackGate-Memory-Model.md](../engineering/CallbackGate-Memory-Model.md) — 完整证明
- [engineering/Callback-Lifecycle.md](../engineering/Callback-Lifecycle.md) — 运行视角
- [engineering/Mapping-Retirement.md](../engineering/Mapping-Retirement.md) — 退役与 quarantine
- [../risks/Known-Limitations.md](../risks/Known-Limitations.md) — 全部风险
