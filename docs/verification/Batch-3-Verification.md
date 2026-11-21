# Batch 3 验证报告

| 项 | 值 |
|---|---|
| 批次 | Batch 3 — Mapping Retirement & Device-Removal Safety |
| 结论 | **`CONDITIONAL PASS`** |
| 平台 | macOS 27.2.1（`26B131`）/ arm64 |
| 工具链 | Apple clang 21.0.0，Apple Swift 6.4.2 |
| 协议版本 | `0x00020200`（未变） |
| header | `320` 字节（未变） |
| 原始证据 | 见 §9 |

**结论是 `CONDITIONAL PASS`，不是 PASS。** 核心场景（真实 HAL 设备移除）
未在真实硬件上执行，这是结论带条件的直接原因。

---

## 1. 实现范围

让"释放共享内存"成为可证明安全的操作，具体覆盖三条此前无保护的路径：

| 路径 | 修复前 |
|---|---|
| 真实设备移除 | 直接释放映射，不排空 |
| `Disconnect()` | 无保护释放 |
| 析构 / 乱序 StopIO | 无保护释放 |

## 2. 三个缺陷（P0-A / P0-B / P0-C）

| 编号 | 缺陷 | 影响 |
|---|---|---|
| **P0-A** | 设备移除路径不排空；`Disconnect()` 无保护释放 | 回调可能访问已释放内存（UAF） |
| **P0-B** | `shared_memory_` 为裸指针，不是 `std::atomic<RFSharedAudio*>` | 数据竞争是未定义行为 |
| **P0-C** | 过期 producer claim 可能在新 mapping 上仍被认为有效 | 旧 handler 写入新 incarnation |

## 3. 关键修改

| # | 修改 |
|---|---|
| 1 | 新增 `packages/driver/src/MappingRetirement.hpp`：`CallbackGate`、`DrainAck`、`DrainOutcome`、`RetiredRevisionMatches`、`MappingQuarantine` |
| 2 | `Retire()` 改为取 `io_mutex_` 后调用 `RetireMapping("device-removed")` |
| 3 | `Disconnect()` 收敛到 `RetireMapping("disconnect")` |
| 4 | `shared_memory_` 改为 `std::atomic<RFSharedAudio*>`，`acquire`/`release` 访问 |
| 5 | 新增 handler 级单调 `revision`，在存储新指针**之前**自增 |
| 6 | `OpenSharedMemory()` 增加防御性 `RetireMapping("reopen")` |
| 7 | 回调入口改为 `retired_` + `callback_gate_.TryEnter()` + `CallbackLease` |
| 8 | 新增 `MappingQuarantine`：无法证明排空时保留映射 |

Batch 3 引入的 `CallbackGate` 此时仍是**双原子**版本（`open_` + `active_` +
二次检查），其内存模型缺陷在 Batch 3 Closure Fix 中修复。

## 4. 四条不变量（I1–I4）

| 编号 | 不变量 |
|---|---|
| I1 | 只有 `RetireMapping()` 能 munmap |
| I2 | 只有排空被证明后才 munmap |
| I3 | 退役后指针不可能再被观察到（先清指针，再释放 owner） |
| I4 | 旧 ACK 不可能匹配新 incarnation（`revision` + `epoch`） |

## 5. 偏差（D1–D5）

| 编号 | 偏差 |
|---|---|
| D1 | 设备移除路径只在代码层接入，**未在真实 HAL 上触发** |
| D2 | `Retire()` 取 `io_mutex_` 是为了与 `OnStartIO` 互斥，**不是**排空论据 |
| D3 | `Disconnect()` 行为等价性只在测试层验证 |
| D4 | 防御性 `RetireMapping("reopen")` 是新增路径，运行中未观察到 |
| D5 | App 只做构建，未运行 UI 回归 |

## 6. 验收表（10 项）

| # | 项 | 结果 |
|---|---|---|
| 1 | 唯一 munmap 入口存在 | PASS |
| 2 | 排空未证明时不 munmap | PASS |
| 3 | 指针清空与 owner 释放顺序 | PASS |
| 4 | 旧 ACK 被 `revision` 拒绝 | PASS |
| 5 | 原子指针替代裸指针 | PASS |
| 6 | 设备移除路径接入 `RetireMapping` | PASS（仅代码层） |
| 7 | 重复 Close / Retire 不崩溃 | PASS |
| 8 | RT Safety（新引入部分） | PASS |
| 9 | Memory Safety | **CONDITIONAL PASS** |
| 10 | 真实设备移除 | **未执行** |

## 7. 测试

```bash
cd packages/driver
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
./build/MappingRetirementTests
# Host
cd packages/host && swift test
# App
cd apps/mac/SoundBridgeApp && swift build
```

| 项 | 结果 |
|---|---|
| Driver `MappingRetirementTests` | **11 组 / 61 断言**，全部通过 |
| Driver 全量 | 通过（含既有 269 项 + Batch 2 的 44 项） |
| Host `swift test` | **318 / 318**（313 → 318，新增 5 项） |
| App `swift build` | 成功（未运行 UI） |
| ASan | 通过，0 报告 |
| TSan | 通过（并发相关子集） |
| CMake Release 构建 | 成功 |
| Fat binary | `x86_64 + arm64` |

Driver 测试覆盖：退役成功、超时进入 quarantine、重复退役、并发准入与退役、
`revision` 拒绝旧 ACK、原子指针可见性、`NothingToRetire` 分支。

## 8. 条件（C1–C3）与未覆盖（N1–N8）

### 8.1 结论成立的条件

| 编号 | 条件 |
|---|---|
| C1 | 真实 HAL 设备移除必须在产品测试阶段执行，且执行后 quarantine 计数应为 0 |
| C2 | 真实 Driver 安装 / 卸载 / `coreaudiod` 重启必须验证旧 ACK 不会复活 |
| C3 | Host + App 全量回归必须在下一次整体验证时补跑 |

### 8.2 未覆盖

| 编号 | 未覆盖 |
|---|---|
| N1 | 真实设备热插拔 |
| N2 | `coreaudiod` 重启 |
| N3 | Driver 重载后的旧 ACK |
| N4 | 多设备并发退役 |
| N5 | Quarantine 长时间增长 |
| N6 | 真实负载下的 250 ms 预算是否足够 |
| N7 | x86_64 真机 |
| N8 | macOS 14.4 |

## 9. 原始报告归档位置

| 原始文件 | 迁移去向 |
|---|---|
| `Implementation-Report.md` | 本文件 §1–§5 |
| `Mapping-Retirement-Proof.md` | [Mapping-Retirement.md](../engineering/Mapping-Retirement.md) |
| `Mapping-Lifecycle.md` | [SharedMemory-Lifecycle.md](../engineering/SharedMemory-Lifecycle.md) |
| `Test-Report.md` | 本文件 §7 |
| `Remaining-Risks.md` | [risks/Known-Limitations.md](../risks/Known-Limitations.md) |
| `Output-Manifest.sha256` | [Documentation-Migration-Manifest.md](../Documentation-Migration-Manifest.md) |

## 10. 同批次遗留风险（RR-1 – RR-10）

| 编号 | 风险 | 状态 |
|---|---|---|
| RR-1 | `CallbackGate` 双原子实现的跨对象顺序无法证明 | **由 Closure Fix 关闭**（改为单原子 + 4 处 `is_always_lock_free`） |
| RR-2 | 并发 `RetireMapping` 依赖 `io_mutex_`；`mapping_owner_` 是普通 `shared_ptr` | 未关闭 |
| RR-3 | Quarantine 无上限 | 未关闭（设计选择） |
| RR-4 | A0（原子硬件行为）未在全部目标架构实测 | 未关闭 |
| RR-5 | 轮询由时间界而非操作数界 | 未关闭 |
| RR-6 | Host / App 未在本轮运行全量回归 | 未关闭 |
| RR-7 | inode 回收路径未实测 | 未关闭 |
| RR-8 | `revision` 是 handler 局部量，不跨进程 | 未关闭 |
| RR-9 | 真实设备移除未验证 | 未关闭 |
| RR-10 | macOS 14.4 未验证 | 未关闭 |

## 11. 结论

**`CONDITIONAL PASS`**。

判据：三条缺陷均已修复并有测试覆盖；11 组 61 断言、Host 318/318、ASan 0
报告、Release 构建成功。条件为 C1–C3：核心场景（真实设备移除）尚未在真实
HAL 上执行，且 Host / App 全量回归未在本批次运行。这些条件不因归档而消失。
