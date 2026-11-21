# Batch 2 验证报告

| 项 | 值 |
|---|---|
| 批次 | Batch 2 — Admission & Ownership |
| 结论 | `IMPLEMENTED — TESTS PASSED` |
| 平台 | macOS 27.2.1（`26B131`）/ arm64 |
| 工具链 | Apple clang 21.0.0 |
| 协议变化 | `0x00020100` → **`0x00020200`** |
| header 变化 | `256` → **`320`** 字节 |
| 原始证据 | 见 §9 |

---

## 1. 实现范围

为共享内存引入 **producer 准入与所有权**，使"谁有权写这块 mapping"成为可
判定、可拒绝、可隔离的问题。

本批次**不做**：

- 不做 mapping 退役（那是 Batch 3）；
- 不做排空证明（那是 Batch 3 / Closure Fix）；
- 不引入 XPC 或任何进程间控制通道。

## 2. 关键修改

| # | 修改 | 说明 |
|---|---|---|
| 1 | header 扩展 256 → 320 B，新增 64 B admission 块 | 原有字段偏移不变 |
| 2 | `RF_AUDIO_PROTOCOL_VERSION` → `0x00020200` | 任何布局变化必须提版本 |
| 3 | 新增 `rf_admission_open` / `begin_close` / `finalize_close` | 状态机 CLOSED/OPEN/CLOSING |
| 4 | 新增 `rf_producer_claim` / `rf_producer_release` / `rf_producer_may_write` | 单 owner + 三条件写闸门 |
| 5 | 新增 `admission_epoch` | 绑定 mapping incarnation |
| 6 | Host 发布顺序改为 init → prefill → open → rename | 见 [SharedMemory-Lifecycle.md](../engineering/SharedMemory-Lifecycle.md) |
| 7 | Driver `OnStartIO` 增加 claim 与 epoch 记录 | 拒绝时 fail-closed |
| 8 | Host 清理改为 `begin_close`，**不**调用 `finalize_close` | 排空证明属于 Batch 3 |
| 9 | plist `SBAudioProtocolVersion` → `131584` | 与头版本一致 |

### 2.1 Admission 块布局

| 字段 | offset | 类型 |
|---|---|---|
| `admission_state` | 256 | `_Atomic uint32_t` |
| `admission_epoch` | 264 | `_Atomic uint64_t` |
| `producer_owner_token` | 272 | `_Atomic uint64_t` |
| `admission_claim_seq` | 280 | `_Atomic uint64_t` |
| `_reserved2[32]` | 288 | `uint8_t[32]` |

## 3. 测试命令与结果

```bash
cd packages/driver
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
./build/AdmissionGatewayTests          # 34 项
./build/AdmissionCrossProcessTests     # 10 项（两个子进程）
./build/RingBufferTests ./build/ControlProtocolTests \
./build/ProducerTokenTests ./build/MappingRetirementTests
```

| 项 | 结果 |
|---|---|
| `AdmissionGatewayTests` | **34 / 34** |
| `AdmissionCrossProcessTests` | **10 / 10** |
| 全量（含既有 Ring / Protocol / Token） | **313 / 313** |
| ASan 全量 | **313 通过，0 报告** |
| TSan | **61 / 61** |

### 3.1 覆盖矩阵

| 场景 | 覆盖 |
|---|---|
| CLOSED → OPEN 合法 | 是 |
| 重复 open 被拒 | 是 |
| `epoch == 0` 被拒 | 是 |
| OPEN → CLOSING → CLOSED 合法 | 是 |
| 跳过 CLOSING 被拒 | 是 |
| 双 token 竞争 claim | 是（一方成功，一方 `ERR_OWNED`） |
| 同 token 幂等 claim | 是 |
| claim 在途时关闭 → 回滚 | 是 |
| `rf_producer_may_write` 三条件逐项否定 | 是 |
| 跨进程 claim / 竞争 | 是（两个子进程） |
| 未定义 state 值 → fail-closed | 是 |

## 4. 跨进程测试的性质

`AdmissionCrossProcessTests` 使用 **两个子进程** 分别扮演 Host 与 Driver，
通过真实的 `/tmp` 文件共享同一映射，验证：

- claim 的跨进程互斥（同一时刻只有一个成功）；
- epoch 不匹配时写入被拒；
- CLOSING 之后写闸门立即失效。

**局限**：这不是真实的 `coreaudiod` 环境。子进程之间没有 libASPL 的
`ioMutex_`，也不受 HAL 调度影响。它验证的是协议本身，不是系统集成。

## 5. ABI 检查

| 项 | 值 | 结果 |
|---|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200` | PASS |
| plist `SBAudioProtocolVersion` | `131584` | PASS |
| `RF_SHARED_AUDIO_HEADER_SIZE` | `320` | PASS |
| `sizeof(RFSharedAudio)` / `alignof` | `320` / `8` | PASS |
| `audio_data` offset | `320` | PASS |
| `admission_state` / `epoch` / `token` / `claim_seq` offset | 256 / 264 / 272 / 280 | PASS |
| 4 份头副本一致 | 是 | PASS |
| `tools/check_protocol_layout.sh` | exit 0（C11 + C++17） | PASS |

头副本统一哈希：
`0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee`。

## 6. 引入的已知风险（R1–R8）

| 编号 | 风险 | 后续状态 |
|---|---|---|
| R1 | token 熵不足（`(uid<<32) \| (counter\|1)`，约 31 位） | **已由 Batch 2 Closure 的 CR-1 修复** |
| R2 | `rf_producer_release` 在非 StopIO 路径被调用会过早交 slot | Batch 3 收紧为只在 StopIO 调用 |
| R3 | Host 清理不调用 `finalize_close`，状态停留在 CLOSING | 刻意设计；CLOSED 需要排空证明 |
| R4 | 跨进程测试为模拟进程，非真实 `coreaudiod` | 仍未解决 |
| R5 | 真实负载下 claim 竞争未观测 | 仍未解决 |
| R6 | 断链后旧 mapping 的 admission 仍为 OPEN | 由新 inode + 新 epoch 隔离；未实测 |
| R7 | 未在 x86_64 真机运行 | 仍未解决 |
| R8 | macOS 14.4 未验证 | 仍未解决 |

R1 的修复详情见
[Batch-2-Closure-Verification.md](Batch-2-Closure-Verification.md)；
R2–R8 全部登记在 [risks/Known-Limitations.md](../risks/Known-Limitations.md)。

## 7. Sanitizer

| 工具 | 范围 | 结果 |
|---|---|---|
| ASan | 全量 313 | 通过，0 报告 |
| TSan | 61 项（并发相关子集） | 61/61 |
| LSan | — | 未作为独立目标（macOS arm64 限制） |

TSan 只覆盖并发相关测试，不是全量；其"未报告"不能被读作"全量无数据竞争"。

## 8. 未验证事项

1. 真实 Host + 真实 `coreaudiod` 的双 owner 竞争；
2. 真实设备热插拔时的 claim 行为；
3. Driver 重启后的恢复（见 [SharedMemory-Lifecycle.md](../engineering/SharedMemory-Lifecycle.md) §6.2）；
4. 长时间运行下的 `claim_seq` 溢出（64 位，物理上不可能，但未实测）；
5. Host / App 全量 UI 回归；
6. macOS 14.4。

## 9. 原始报告归档位置

| 原始文件 | 迁移去向 |
|---|---|
| `Batch-2-Implementation-Report.md` | 本文件 §1–§6 |
| `Output-Manifest.sha256` | [Documentation-Migration-Manifest.md](../Documentation-Migration-Manifest.md) |

## 10. 结论

`IMPLEMENTED — TESTS PASSED`。

判据：34/34 网关测试、10/10 跨进程测试、313/313 全量、ASan 0 报告、TSan
61/61、ABI 全部通过布局检查。R1 已在 Closure 中修复，其余风险均未关闭，
但在本批次范围内不构成阻断。
