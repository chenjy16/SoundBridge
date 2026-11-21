# Batch 2 Closure 验证报告

| 项 | 值 |
|---|---|
| 批次 | Batch 2 Closure — Producer Token 唯一性 + Callback Exit / Release 生命周期审查 |
| 结论 | **`PASS`** |
| 平台 | macOS 27.2.1（`26B131`）/ arm64 |
| 工具链 | Apple clang 21.0.0 |
| 原始证据 | 见 §9 |

结论为 `PASS`（不是 `CONDITIONAL PASS`）：两条 Finding 全部闭合，且
CR-2 为**零改动**通过。

---

## 1. 审查范围

Batch 2 的 `IMPLEMENTED — TESTS PASSED` 之后，Closure Review 提出两个
问题：

| 编号 | 问题 | 严重性 |
|---|---|---|
| **CR-1** | Producer token 的熵不足，"唯一性"只是名义上的 | 高 |
| **CR-2** | `rf_producer_release()` 的调用点是否可能早于最后一次写入 | 高 |

CR-1 需要改代码；CR-2 需要给出"为什么不需要改"的证明。

## 2. CR-1：token 熵缺陷与修复

### 2.1 缺陷

Batch 2 的实现：

```cpp
token = (uint64_t(uid) << 32) | (uint64_t(counter) | 1);
```

- 高位是 uid（通常 501），低位是进程内自增计数（奇数）。
- 实际有效熵约 **31 位**，且在同一 uid 下**完全可预测**。
- 后果：两个 handler 在同一 uid 下几乎不可能碰撞（`counter` 递增），因此
  日常运行"看起来正常"；但 token 的不可预测性为零，攻击面与"唯一性"论证
  都建立在"计数不会重复"这个未经证明的前提上。

### 2.2 修复

新增 `packages/driver/src/ProducerToken.hpp`：

```cpp
uint64_t token = 0;
arc4random_buf(&token, sizeof(token));      // 64 位 CSPRNG
// 若 token == 0 → 重试，最多 8 次
// 8 次均失败 → 返回 0（fail-closed）
```

| 性质 | 修复前 | 修复后 |
|---|---|---|
| 熵 | ~31 位，可预测 | 64 位 CSPRNG |
| 0 值 | 不可能（`|1`） | 显式过滤，0 表示"无法生成" |
| 失败模式 | 无失败路径 | fail-closed 返回 0，永不 claim / 写入 |
| 可测试性 | 不可注入 | 生成源可注入（测试可提供确定性源） |
| 重试 | 无 | 有界（8 次），不会无限循环 |

失败即 fail-closed 是关键：token 为 0 时 `rf_producer_claim` 直接返回 false，
`rf_producer_may_write` 也返回 false，因此"生成器坏了"退化为"不写"，而不是
"用一个弱 token 写"。

## 3. CR-2：Release 生命周期（零改动通过）

### 3.1 问题

`rf_producer_release()` 把 owner slot 还给 0。如果它在某次写入仍在进行时执行，
下一个 handler 可能立刻 claim 成功并写入，形成两个 writer。是否存在这样的
调用点？

### 3.2 结论

**不存在，且不需要改代码。** 论证：

`packages/driver/vendor/libASPL` 中：

| 位置 | 函数 | 是否持有 per-device `ioMutex_` |
|---|---|---|
| `Device.cpp:1430` | `DoIOOperation`（调用写回调） | **是** |
| `Device.cpp:1134` | `StopIO` | **是** |

- 写回调只能通过 `DoIOOperation` 进入，而它持有 `ioMutex_`；
- `OnStopIO` 在 `count == 0` 时先 `rf_producer_release()` 再 `Disconnect()`，
  整个 `OnStopIO` 也持有 `ioMutex_`；
- 因此"release 与任意一次写入"在同一个互斥区内，不可能重叠。

这是**结构性保证**（同一把锁），不依赖时序。所以 CR-2 的修复是"证明不需要
修改"，代码零改动。

### 3.3 该论证的边界

该论证只覆盖 **StopIO** 路径。设备移除、乱序 StopIO、析构**不**持有该锁，
因此**不能**在这些路径上 release —— 这一结论直接规定了 Batch 3 的实现
（见 [Mapping-Retirement.md](../engineering/Mapping-Retirement.md) §4.1）。

## 4. 审查问答（Q1–Q7）

| # | 问题 | 结论 |
|---|---|---|
| Q1 | token 碰撞会导致什么？ | 两个 handler 都认为自己是 owner，双写 ring |
| Q2 | 修复后碰撞概率？ | 64 位随机，可忽略；且 claim 的 CAS 仍提供唯一性兜底 |
| Q3 | token 为 0 时行为？ | fail-closed：不 claim、不写 |
| Q4 | 同一 handler `Stop → Start` 会失败吗？ | 不会。`rf_producer_claim` 对同 token 幂等成功 |
| Q5 | release 之后旧 token 还能写吗？ | 不能。`producer_owner_token` 已为 0，三条件第三项失败 |
| Q6 | 多设备下 token 需要全局唯一吗？ | 不需要。唯一性只在单块 mapping 的 owner slot 内要求 |
| Q7 | 生成器被注入确定性源会影响生产吗？ | 不会。注入只在测试构建路径；生产固定使用 `arc4random_buf` |

## 5. 测试（T1–T7）

| 编号 | 测试 | 结果 |
|---|---|---|
| T1 | 64 位 token 生成，非 0 | PASS |
| T2 | 注入确定性源，可复现 | PASS |
| T3 | 连续 8 次生成为 0 → 返回 0（fail-closed） | PASS |
| T4 | token 0 claim 被拒 | PASS |
| T5 | 同 token 幂等 claim | PASS |
| T6 | 不同 token 竞争，仅一方成功 | PASS |
| T7 | release 后旧 token 写入被拒 | PASS |

`ProducerTokenTests` 全部通过；既有全量测试未出现回归。

## 6. 测试能力的明确降级（必须保留）

本批次的验收**不能**被读作"并发完全正确"。原始报告明确记录了三点降级：

| # | 降级 |
|---|---|
| 1 | **macOS arm64 上不提供 LSan 独立目标**，因此"无泄漏"只是 ASan 覆盖范围内的结论，不是全面泄漏检测 |
| 2 | **TSan 的信号较弱**：它只能发现实际执行到的竞争；未报告不等于无竞争 |
| 3 | **Host 测试套件未在本批次重跑**：改动位于 Driver 侧，Host 未重新执行全量回归 |

第 3 点是本轮归档时必须保留的事实——后续 Batch 3 / Closure Fix 同样没有
重跑 Host 与 App 全量回归。

## 7. ABI 检查

本批次不改变任何 header 布局：

| 项 | 值 |
|---|---|
| 协议版本 | `0x00020200`（未变） |
| header 大小 | `320`（未变） |
| 4 份头副本 | 一致 |
| `tools/check_protocol_layout.sh` | exit 0 |

## 8. 未验证事项

1. 真实 `coreaudiod` 中两个 handler 的 token 竞争；
2. Driver 重载后旧 token 是否可能"复活"（理论上被 epoch 阻断，未实测）；
3. Host 全量回归（本批次未跑）；
4. macOS 14.4；
5. x86_64 真机。

## 9. 原始报告归档位置

| 原始文件 | 迁移去向 |
|---|---|
| `Closure-Review-Report.md` | 本文件 §1–§4 |
| `Test-Report.md` | 本文件 §5–§6 |
| `Output-Manifest.sha256` | [Documentation-Migration-Manifest.md](../Documentation-Migration-Manifest.md) |

## 10. 结论

**`PASS`**。

判据：CR-1 已修复并由 T1–T7 覆盖；CR-2 以结构性锁论证零改动闭合；无回归。
同时必须保留 §6 的三项测试能力降级，它们不代表"并发已被完全验证"。
