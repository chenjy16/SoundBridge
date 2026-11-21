# Admission 与 Producer 所有权

来源：Batch 2（`IMPLEMENTED — TESTS PASSED`）与 Batch 2 Closure（`PASS`）。
证据见 [verification/Batch-2-Verification.md](../verification/Batch-2-Verification.md)
与 [verification/Batch-2-Closure-Verification.md](../verification/Batch-2-Closure-Verification.md)。

本文回答一个具体问题：**在共享内存里，谁有权写入当前这块 mapping？**

---

## 1. 两层防护

共享内存涉及两组互不相同、必须同时成立的判据：

| 层 | 机制 | 回答的问题 | 存储 |
|---|---|---|---|
| 协议层 | admission 状态机 + epoch + owner token | 这个 handler 是否有权写这个 incarnation | 共享内存 header |
| 进程内层 | `CallbackGate` | 现在是否有回调正处在 mapping 内 | Driver 进程内原子字 |

两者不能互相替代：

- `CallbackGate` 只能看见**本进程**的回调，对"另一个 handler 抢了 slot"
  一无所知；
- `admission` 状态在共享内存里，但对"已经进入 mapping、正在写"的回调没有
  计数能力，因此无法用于决定能否 munmap。

## 2. 共享内存中的 admission 块

| 字段 | offset | 类型 | 写入者 |
|---|---|---|---|
| `admission_state` | 256 | `_Atomic uint32_t` | Host（open / begin_close / finalize_close）、Driver（claim 的回滚） |
| `admission_epoch` | 264 | `_Atomic uint64_t` | Host（仅 `rf_admission_open`） |
| `producer_owner_token` | 272 | `_Atomic uint64_t` | Driver（claim / release） |
| `admission_claim_seq` | 280 | `_Atomic uint64_t` | Driver（claim 成功后自增，仅诊断） |

协议 `0x00020200` 引入该块；header 由 256 B 扩到 320 B，原有字段偏移不变。

### 2.1 状态机

```
        rf_admission_open(epoch)             rf_admission_begin_close()
CLOSED ───────────────────────► OPEN ───────────────────────► CLOSING
   ▲                                                              │
   └────────────────── rf_admission_finalize_close() ──────────────┘
```

- **CLOSED → OPEN** 只能由 Host 在发布新 mapping 时执行；`epoch == 0` 被拒绝
  （没有 incarnation 身份就没有隔离）；已 OPEN 时再次 open 被拒绝——epoch
  绝不允许在活跃 owner 下改变。
- 关键顺序：**先检查状态，再写 epoch**。若反过来，第二个 opener 会先覆盖
  epoch，虽然随后仍被状态检查拒绝，但已把某个 producer 正在使用的
  incarnation 身份破坏掉（产生一个永远无法再绑定的 owner token）。
- **OPEN → CLOSING** 幂等（CLOSING / CLOSED 均返回 OK）。它**不**停止已经在
  运行的回调，只阻止新的写入被接受。
- **CLOSING → CLOSED** 拒绝跳过 CLOSING，保证每次拆除都经过 CLOSING——这个
  中间状态是未来挂接排空证明的锚点。

### 2.2 结果码

| 码 | 含义 |
|---|---|
| `RF_ADMISSION_OK` | 成功 |
| `RF_ADMISSION_ERR_NULL` | 空指针 |
| `RF_ADMISSION_ERR_STATE` | 非法状态或非法转移 |
| `RF_ADMISSION_ERR_EPOCH` | epoch 为 0 |
| `RF_ADMISSION_ERR_OWNED` | slot 属于别人 |

未定义状态值原样返回，调用方必须 fail-closed（`rf_admission_state()` 只在
`mem == NULL` 时替返回 `CLOSED`）。

## 3. Producer 身份：token + epoch

### 3.1 token 的生成

`packages/driver/src/ProducerToken.hpp`：

```
arc4random_buf(&token, sizeof(token));    // 64 位
若 token == 0 → 重试，最多 8 次
8 次均失败 → 返回 0（fail-closed，永不写入）
```

- 生成源可注入（测试可提供确定性源），但生产路径只使用 CSPRNG。
- **Batch 2 Closure 之前**的实现是
  `(uid << 32) | (counter | 1)`，实际熵约 31 位且在同一 uid 下高度可预测
  ——这是 Closure Review 的 **CR-1**。修复后为 64 位随机值。
- 返回 0 是"无法生成"的显式信号；拿到 0 的 handler 不得 claim、不得写入。

### 3.2 claim

```
前置：admission_state == OPEN（acquire load）
CAS(producer_owner_token, 0 → token)
  成功 → 再次读 admission_state
           仍 OPEN → claim_seq++，返回 true
           已关闭 → 回滚 token 到 0，返回 false
  失败 → 读到的 current == 自己的 token ？ 是则幂等成功（同一 handler 的 Stop→Start）
                                            否则拒绝（别人拥有）
```

要点：

- **claim 只在非实时的 `OnStartIO` 中调用**。
- CAS 后的二次读覆盖"claim 在途时 Host 关闭了 admission"的竞争；此时回滚
  而不是在已关闭的 mapping 上留下 owner。
- **同一 token 的幂等成功**是必要的：一个 handler 的 IO 可能 Stop 后重新
  Start 而 mapping 没有被替换，此时应复用同一个 owner slot，而不是制造
  第二个 producer。

### 3.3 epoch 绑定

token 只证明"某个 handler"，`epoch` 才证明"这个 mapping incarnation"。

- Host 在每次发布时写入一个**新的随机 64 位 epoch**；一个 mapping incarnation
  的 epoch 在其生命周期内不变（open 拒绝重复执行）。
- Driver 在 claim 成功后把
  `claimed_epoch_ = rf_admission_epoch(mem)` 记录在自己身上（relaxed，因为
  它随后会被写入闸门以 acquire 方式再次读取）。
- 没有 epoch 时，一个 handler 的 token 在**任何**由该 handler 映射过的
  mapping 上都"有效"，包括它从未 claim 过的那些。epoch 消除了这种可能。

### 3.4 release

```
CAS(producer_owner_token, token → 0)
```

只有当前 owner 能释放；释放一个不属于自己的 token 是无操作（CAS 失败）。
**调用点只有一处**：`OnStopIO` 中最后一个 client 退出的路径。理由见
[Mapping-Retirement.md](Mapping-Retirement.md) §4。

设备移除（`Retire()`）与析构**不**释放 token：它们不持有 libASPL 的
`ioMutex_`，无法证明没有回调在使用这个 slot。让 token 随旧 mapping 一起
消失（新 mapping 有新 epoch，旧 token 在其上无效）比"提前释放"安全。

## 4. 实时写闸门

```c
static inline bool rf_producer_may_write(const RFSharedAudio* mem,
                                        uint64_t token, uint64_t epoch);
```

三个 `acquire` load，**无 CAS、无分配、无锁**，全部成立才允许写：

1. `admission_state == OPEN`
2. `admission_epoch == 本 handler 记录的 epoch`
3. `producer_owner_token == 本 handler 的 token`

任一项不成立 → 本次回调不写、只计入失败计数。该函数是只读的：render 线程
永远不会修改网关状态。

`rf_ring_write()` 是 `rf_producer_may_write()` 之后唯一被允许的写入口；
`rf_ring_write_unchecked()` 只允许在两类位置调用：

1. `rf_ring_write()` 内部（已经过闸门）；
2. `rf_ring_prefill_before_publish()`（发布前，无读者）。

## 5. Host 侧发布顺序

```
1. open(staging, O_CREAT|O_EXCL|O_NOFOLLOW)
2. rf_shared_audio_init(...)                 // 全部字段初始化，state = CLOSED
3. rf_ring_prefill_before_publish(capacity/2) // 静音预填充，无读者
4. rf_admission_open(mem, random_epoch)       // CLOSED → OPEN
5. rename(staging → final)                    // 原子发布
```

- 第 4 步在 rename **之前**：Driver 不可能在 `open` 到 `rename` 之间看到这块
  文件，因此不存在"已发布但未 open"的窗口。
- 第 3 步在 open **之前**：预填充不可能被误认为通过 admission 的写入。

## 6. 安全论证（为什么这套机制足够）

**为什么单 producer 是充分的**：Ring 契约要求 `write_index` 单写者
（见 [RingBuffer-Design.md](RingBuffer-Design.md)）。只要 owner slot 唯一且
写入前校验，`write_index` 就只有一条写入路径。

**为什么两个 owner 不会同时写**：CAS 从 0 到 token 只有一个成功者；此后
另一个 token 的 CAS 会失败并读到对方的 token ≠ 自己，因此被拒。同一 token
的重复 claim 是同一 handler，不构成第二个 writer。

**为什么旧 handler 不会写新 mapping**：新 mapping 有新 epoch；旧 handler 的
`claimed_epoch_` 与新值不同，`rf_producer_may_write()` 第二项失败。

**为什么关闭后不会再有写入**：Host 把 state 置为 CLOSING 后，
`rf_producer_may_write()` 第一项失败。正在运行的单个回调可能仍会完成它已经
开始的那次写——这正是需要 `CallbackGate` 排空（Driver 侧）与
`rf_admission_finalize_close`（Host 侧）配合的原因，也是为什么 admission
本身不足以证明可以 munmap。

## 7. 已验证 / 未验证

已验证（Batch 2）：

- 单测 `AdmissionGatewayTests` **34/34**；
- 跨进程 `AdmissionCrossProcessTests` **10/10**；
- 全量 **313/313**；ASan 全量 313 通过，0 报告；TSan **61/61**；
- 覆盖：状态机非法转移、重复 open、epoch 为 0、双 owner 竞争、同 token
  幂等、claim 回滚、写闸门三条件逐项否定。

已验证（Batch 2 Closure）：

- token 熵缺陷 CR-1 修复并复测；CR-2（release 生命周期）零改动通过；
- `ProducerTokenTests` 通过（含确定性注入源、8 次重试后 fail-closed）。

未验证：

- Host 与 Driver **同时**真实运行时的双 owner 竞争（跨进程测试为两个
  子进程模拟，不是真实 coreaudiod）；
- 真实设备热插拔时的 claim 行为。

## 8. 相关文档

- 实时闸门的内存模型：[CallbackGate-Memory-Model.md](CallbackGate-Memory-Model.md)
- 退役时序：[Mapping-Retirement.md](Mapping-Retirement.md)
- 生命周期全景：[SharedMemory-Lifecycle.md](SharedMemory-Lifecycle.md)
