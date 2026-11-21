# Batch 0 + Batch 1 验证报告

| 项 | 值 |
|---|---|
| 批次 | Batch 0（协议契约冻结）+ Batch 1（Ring 实现修复） |
| 结论 | `IMPLEMENTED — TESTS PASSED` |
| 日期 | 2026-11（本次归档复核） |
| 平台 | macOS 27.2.1（`26B131`）/ arm64（Apple Silicon） |
| 工具链 | Apple clang 21.0.0 |
| 原始证据 | 见 §8 |

本报告只陈述**实际执行过**的测试。未执行项明确列为未验证。

---

## 1. 实现范围

本批次不新增功能，只做两件事：

1. **冻结共享协议契约**（12 节），把此前散落、含糊或互相矛盾的语义写成
   唯一版本。
2. **修复 Ring 实现**使之符合该契约，并删除旧语义。

涉及的契约条目：

| 编号 | 契约 |
|---|---|
| C1 | canonical 格式 = stereo Float32 interleaved |
| C2 | 容量必须 > 0 且为 2 的幂，由 `rf_ring_capacity_frames_for` 单点计算 |
| C3 | 索引单位为帧，64 位无符号，自然回绕 |
| C4 | `write_index` / `read_index` 单写者 |
| C5 | 溢出策略 = **Drop New**（删除 Drop Old） |
| C6 | 欠载 = 尾部补零，`read_index` 只按实际消费推进 |
| C7 | 预填充由 Host 在发布前完成，Driver 永不给 ACTIVE mapping 预填充 |
| C8 | `rf_validate_header` 是唯一 header 校验入口 |
| C9 | 映射路径按设备与 UID 区分 |
| C10 | Float64 输入 fail-closed，不做静默转换 |
| C11 | 头副本 4 份必须字节一致 |
| C12 | 任何字段变化必须提升协议版本 |

## 2. 关键修改

| # | 修改 | 理由 |
|---|---|---|
| 1 | 删除 Drop-Old 分支，`rf_ring_write_unchecked` 只丢新帧 | Drop-Old 需要生产者回写 `read_index`，破坏单写者不变量并引入撕裂 |
| 2 | `rf_ring_capacity_frames_for()` 统一容量计算；`sample_rate == 0 \|\| duration_ms == 0` → 返回 0 | 消除 `capacity % 0` 的未定义行为 |
| 3 | 容量 0 / 非 2 的幂在 `rf_validate_header` 中被拒绝 | 掩码寻址的前提是 2 的幂 |
| 4 | 索引比较改为无符号差 `W - R` | 让 64 位回绕成为正确行为而非边界缺陷 |
| 5 | 映射路径 `/tmp/soundbridge_<uid>` → `/tmp/soundbridge-<ownerUID>-<sanitized_deviceUID>` | 旧路径多设备互相覆盖 |
| 6 | 预填充从 Driver 移到 Host 的 `rf_ring_prefill_before_publish()` | 发布前无读者；`Stop → Start` 不得再触碰 W/R |
| 7 | Float64 输入 fail-closed | Host/DSP 只处理 Float32 interleaved |
| 8 | `rf_acquireFirstMemory` 不再充当"第二消费者" | 违反单消费者不变量 |

## 3. 测试命令与结果

```bash
# 全量 Driver 测试
cd packages/driver && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
./build/RingBufferTests            # 契约 17 项
./build/ControlProtocolTests
./build/ProducerTokenTests
./build/MappingRetirementTests
# 汇总
269 / 269 通过
```

| 项 | 结果 |
|---|---|
| 全量测试 | **269 / 269** |
| Ring 契约专项 | **17 / 17** |
| 跨进程 L3（Host 写 / Driver 读真实映射） | PASS |
| ASan 全量运行 | 通过，**0 条报告** |

Ring 契约 17 项覆盖：容量计算（含 0 输入）、2 的幂拒绝、Drop New 部分写入、
欠载零填充、`read_index` 不因补齐前进、64 位回绕、单写者断言、非法 header
拒绝、预填充入口守卫。

## 4. 跨进程证据（L3）

L3 场景：一个进程创建并发布映射，另一个进程附着并读取同一块内存，验证：

- 路径按设备区分后两个进程能找到同一文件；
- `rf_ring_write` 写入的数据被 `rf_ring_read` 正确读到；
- 索引在跨进程可见性上符合 `release` / `acquire` 预期（单次观测，未做压力
  测试）。

结论为 PASS，但**不是**对"跨进程原子性"的完整验证——那一部分在 Batch 2 的
跨进程测试中才展开（见 [Batch-2-Verification.md](Batch-2-Verification.md)）。

## 5. ABI 检查

| 项 | 值 | 结果 |
|---|---|---|
| `RF_AUDIO_PROTOCOL_VERSION` | 本批次为 `0x00020100` | 后续 Batch 2 提升到 `0x00020200` |
| `RF_SHARED_AUDIO_HEADER_SIZE` | 本批次为 `256` | 同上 |
| `sizeof(RFSharedAudio)` | 256 | PASS |
| 头副本一致性（4 份） | 字节相同 | PASS |
| `tools/sync_shared_header.sh --check` | exit 0 | PASS |

> 当前仓库的协议版本是 `0x00020200` / 320 B。本表记录的是 Batch 0/1 完成时
> 的状态，用于审计当时的 ABI 基线。

## 6. Sanitizer

| 工具 | 范围 | 结果 |
|---|---|---|
| ASan | 全量 269 项 | 通过，0 报告 |
| TSan | — | **本批次未运行** |
| LSan | — | **本批次未运行**（macOS arm64 上不作为独立目标） |

## 7. 未验证事项

| # | 未验证 |
|---|---|
| 1 | TSan 未在本批次运行（在 Batch 2 中才引入） |
| 2 | 真实负载下的丢帧率与 xrun 率无实测 |
| 3 | x86_64 真机未运行（仅构建产物） |
| 4 | 真实 HAL 设备热插拔未触发 |
| 5 | Host / App 全量回归未在本批次执行 |
| 6 | macOS 14.4 未验证 |

这些事项全部登记在 [risks/Known-Limitations.md](../risks/Known-Limitations.md)，
不因归档而消失。

## 8. 原始报告归档位置

| 原始文件 | 迁移去向 |
|---|---|
| `Implementation-Report.md` | 本文件 §1–§3、§6 |
| `Batch-0-Protocol-Contract.md` | 本文件 §1、[RingBuffer-Design.md](../engineering/RingBuffer-Design.md) |
| `Output-Manifest.sha256` | 见 [Documentation-Migration-Manifest.md](../Documentation-Migration-Manifest.md) |

原始文件位于已退役的 `SoundBridge-Research/` 目录，其 SHA-256 记录在迁移清单
中。本报告保留其技术结论与测试数字；原始 Markdown 不逐字复制，避免同一结论
在两处独立演进。

## 9. 结论

`IMPLEMENTED — TESTS PASSED`。

判据：12 项契约全部有实现与测试覆盖；269/269 通过；ASan 无报告；跨进程 L3
通过。本批次不含已知的正确性缺陷遗留。
