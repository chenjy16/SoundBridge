# Ring Buffer 设计

来源：Batch 0 + Batch 1（协议契约冻结与 Ring 实现修复）。结论状态
`IMPLEMENTED — TESTS PASSED`；批次验证报告已随阶段报告移出仓库，当前结论由
`make test` 中的协议检查与 Host 测试套件持续覆盖。

本文只描述**当前实现**的契约。Batch 0 之前的 Drop-Old 语义、可配置容量
缺省 0、单一 `/tmp/soundbridge_<uid>` 路径均已删除，不再具备任何效力。

---

## 1. 在系统中的位置

```
coreaudiod ──► Driver OnWriteMixedOutput ──► rf_ring_write ──► [ ring ] ──► rf_ring_read ──► Host render ──► 物理设备
                 (唯一 Producer)                                                  (唯一 Consumer)
```

Ring 位于一块文件映射的共享内存中，紧接 320 字节 header 之后
（`audio_data` @ offset 320）。同一块映射里还有音量、静音、EP、心跳与
admission 字段，但它们不属于 Ring 契约。

## 2. 数据格式契约

| 项 | 契约 |
|---|---|
| 通道数 | 2（stereo） |
| 采样格式 | `RF_AUDIO_FORMAT_FLOAT32`，interleaved |
| 每帧字节 | `channels * bytes_per_sample` = `2 * 4` = **8** |
| 索引单位 | **帧**，不是字节，也不是样本 |
| 采样率 | 由 header 声明，Host 与 Driver 必须一致 |

`audio_data` 的字节大小为
`ring_capacity_frames * channels * bytes_per_sample`，整个 mapping 的大小由
`rf_shared_audio_size()` 计算并在 `rf_validate_header()` 中核对。

### 2.1 为什么不接受 Float64

libASPL 在某些设备上给出 `Float64` 非交错布局，而 Host 的渲染链与 DSP 只
处理 Float32 interleaved。当前实现对 Float64 输入**fail-closed**：不静默
转换、不截断，而是拒绝该连接并把连接状态置为错误，让 HAL 侧看到明确失败。
把 Float64 当作受支持输入是一个**未实现**项，不是已知可用路径。

## 3. 容量

```c
rf_frames_for_duration(sample_rate, duration_ms)   // 请求帧数
rf_next_power_of_two_u32(n)                        // 向上取 2 的幂
rf_ring_capacity_frames_for(sample_rate, duration_ms)
```

- `sample_rate == 0` 或 `duration_ms == 0` → 返回 **0**。0 表示"无法表示"，
  调用方在发布前必须检查。
- 容量**必须 > 0 且为 2 的幂**，`rf_validate_header()` 会拒绝不满足的
  header（包括 `capacity == 0`）。
- 默认值：48 000 Hz × 100 ms = 4800 帧 → 实际 **8192** 帧（64 KiB 数据区）。
- 地址计算只用掩码：`slot = index & (capacity - 1)`。这依赖 2 的幂，因此
  2 的幂不是风格选择而是正确性前提。

`duration_ms == 0` 使 `frames_for_duration` 返回 0，历史上曾出现
`capacity % 0` 的未定义行为；Batch 0 起改为显式返回 0 并由校验拒绝，禁止
任何路径对 0 做取模。

## 4. 索引与内存序

```c
uint64_t write_index;   // Producer 独占写
uint64_t read_index;    // Consumer 独占写
```

| 规则 | 说明 |
|---|---|
| 单写者 | Producer **只**写 `write_index`；Consumer **只**写 `read_index` |
| Producer 不写 R | 不可覆盖未读数据的直接后果；旧的 Drop-Old 需要回写 R，已删除 |
| 发布顺序 | 写入数据 → `release` 更新自己的索引 |
| 读取顺序 | `acquire` 读对侧索引 → 读数据 |
| 索引宽度 | 64 位，无符号，自然回绕 |

在 `rf_ring_write_unchecked()` / `rf_ring_read()` 内部：

```
write:  W = load(write_index, relaxed)；R = load(read_index, acquire)
        used = W - R                                  // uint64 无符号差
        free = capacity - used
        n    = min(num_frames, free)                  // Drop New
        拷贝 n 帧到 slot(W)…slot(W+n-1)
        store(write_index, W + n, release)

read:   R = load(read_index, relaxed)；W = load(write_index, acquire)
        avail = W - R
        n     = min(num_frames, avail)
        拷贝 n 帧；剩余部分补 0
        store(read_index, R + n, release)             // 只加实际消费帧数
```

`used = W - R` 用无符号差而非比较，因此 64 位回绕是**正确行为**而不是需要
特殊处理的边界。索引值本身永远不需要"修正"。

## 5. 溢出策略：Drop New

写入放不下时：

1. 只写能放下的部分（可能为 0）。
2. 通过 `out_dropped` 返回被丢弃的帧数。
3. **绝不覆盖未读数据，绝不阻塞，绝不回写 `read_index`。**

丢弃是可观测的：Driver 侧把 `dropped` 计入统计，Host 侧可用
`rf_is_connection_healthy()` 与心跳判断整体健康状况。选择 Drop New 的理由：

- 覆盖未读数据需要对 `read_index` 做生产者写入，破坏单写者不变量，并引入
  读者正在读取的帧被改写（撕裂）的风险；
- 阻塞在实时回调中不可接受；
- 音频场景下"丢弃新帧"产生的是一次可听缺口，而"覆盖未读帧"产生的是
  不可预测的错位与撕裂。

## 6. 欠载策略：零填充

可用帧不足时，调用方要求的输出区尾部必须补 0：

- 合法输出区总是**恰好** `num_frames` 帧（调用方按此假设做后续处理）；
- `read_index` **只**按实际消费帧数推进，不因补齐而前进；
- 因此补齐不会"偷走"未来的数据，也不会制造虚假的时序。

补齐发生在 Consumer 侧的本地输出缓冲，不写入 Ring。

## 7. 预填充（prefill）与发布顺序

Host 在发布 mapping **之前**用
`rf_ring_prefill_before_publish()` 写入 `capacity / 2` 帧静音。

- 目的：Driver 首次 `OnStartIO` 时 Ring 不是空的，避免启动瞬间的欠载
  爆音。
- 预填充是**写侧**操作，且发生在 `rename` 发布之前，此时没有任何读者；
  因此它可以用 `rf_ring_write_unchecked()` 绕过 admission 检查。
- Driver **永不**预填充一个 ACTIVE mapping。历史上 Driver 侧的一次性预填充
  已移至 Host（Batch 1），`Stop → Start` 不得再触碰 W/R。

## 8. 校验

`rf_validate_header()` 在 Driver `OnStartIO` 与 Host 侧共用，检查（摘要）：

- magic / version 与编译期常量一致；
- `sizeof` 与布局 `static_assert` 已由编译期保证，运行期再核对 header 大小；
- `ring_capacity_frames > 0` 且为 2 的幂；
- `channels == 2`、`bytes_per_sample == 4`、格式为 Float32；
- 采样率在支持集合内；
- 声明的 mapping 大小与 `rf_shared_audio_size()` 一致。

任一不满足 → 连接失败，Driver 不上报 Connected，不 `rf_producer_claim()`。

## 9. 已验证 / 未验证

已验证（Batch 0 + 1，macOS 27.2.1 arm64，Apple clang 21.0.0）：

- Ring 契约测试 **17/17**，覆盖容量计算、Drop New、欠载零填充、回绕、
  单写者约束、非法 header 拒绝；
- 全量 **269/269** 通过；ASan 运行 **0 报告**；
- 跨进程 L3 场景通过（Host 写 / Driver 读的真实映射）；
- 4 份头副本哈希一致。

未验证：

- 真实负载下长时间运行的 xrun 率与丢帧率（无实测数据）；
- 真实 HAL 设备移除期间的 Ring 行为（见
  [risks/Known-Limitations.md](../risks/Known-Limitations.md)）；
- x86_64 真机运行（仅构建产物存在）。

## 10. 相关文档

- 协议头与 ABI：[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
- 写入前的准入：[Admission-Ownership.md](Admission-Ownership.md)
- 验证入口：`make test`（`check_protocol_layout.sh` + Host 测试套件）
