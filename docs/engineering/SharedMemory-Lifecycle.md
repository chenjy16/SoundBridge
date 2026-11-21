# Shared Memory 生命周期

来源：Batch 1（预填充迁移与路径修复）、Batch 2（admission 引入）、Batch 3
（退役）。证据见 [verification/](../verification/)。

本文描述一块共享内存从创建到消失的完整过程，以及**崩溃恢复为什么不需要
判活**。

---

## 1. 命名与身份

```
/tmp/soundbridge-<ownerUID>-<sanitized_deviceUID>
```

- `ownerUID`：创建 mapping 的 Host 用户 UID。
- `sanitized_deviceUID`：设备 UID 的安全编码（去掉/转义路径分隔符等）。
- 一台机器上**每个设备一块** mapping，互不影响。

Batch 0 之前使用 `/tmp/soundbridge_<uid>`：与设备无关，因此多设备会互相覆盖
（后启动的设备破坏前一个设备的 mapping）。修复后按设备区分，UID 由
`getuid()` 取得而不是猜测。

`SharedMemoryMapping` 记录 `(memory, size, st_dev, st_ino)`：**inode 是身份
的一部分**。后续的 unlink 与"是否仍是自己的文件"判断都以
`st_dev`/`st_ino` 为准，而不是路径字符串。

## 2. Host 侧创建与发布

```
1. mkdir /tmp 就绪
2. open(staging, O_CREAT|O_EXCL|O_NOFOLLOW, 0600)   // staging 路径带 pid/随机后缀
3. ftruncate(fd, rf_shared_audio_size(...))
4. mmap(PROT_READ|PROT_WRITE, MAP_SHARED)
5. rf_shared_audio_init(mem, sample_rate, 2, FLOAT32, duration_ms)
      → ring_capacity_frames = rf_ring_capacity_frames_for(...)
      → admission_state = CLOSED，epoch = 0，owner token = 0
6. rf_set_host_session(mem, session.uuid)
7. rf_publish_volume_state(mem, scalar, muted, mode)  // 一次性提交，state_initialized = 1
8. rf_ring_prefill_before_publish(mem, silence, capacity/2)
9. rf_admission_open(mem, random_epoch)              // CLOSED → OPEN
10. fstat(fd) → 记录 st_dev/st_ino
11. rename(staging → final)                          // 原子发布
12. 登记到 deviceMemory[uid]
```

关键顺序与其理由：

| 顺序 | 理由 |
|---|---|
| 预填充在 open **之前** | 此时没有读者，预填充可以用 `rf_ring_write_unchecked`；若在 open 之后做，就等于一个真实的生产者写入，会与 Driver claim 竞争 |
| open 在 rename **之前** | 文件在 rename 之前不可达，因此不存在"已发布但未 open"的窗口；Driver 一旦看到文件，admission 一定已是 OPEN |
| fstat 在 rename **之前** | 必须在文件仍是 staging inode 时记录 inode，否则无法在后续判断"这个路径还是不是我的文件" |
| rename 而非 link/unlink 序列 | `rename(2)` 在同一文件系统内原子：读者要么看到旧文件，要么看到新文件，不会看到半个 |

预填充量是 `capacity / 2` 帧静音。目的只是消除启动瞬间的欠载爆音，不是
"填满 ring"；`capacity / 2` 与 `capacity` 的余量留给首次回调的调度抖动。

### 2.1 替换旧 mapping 时不能立刻 munmap

```swift
let previous = deviceMemory.updateValue(mapping, forKey: uid)
withExtendedLifetime(previous) {}
```

`previous` 的**最后一个租约可能仍在音频回调中使用**。因此这里只让它离开
字典（引用计数 -1），不主动 `munmap`；真正的释放发生在最后一个引用消失时
（可能是回调线程）。这一行 `withExtendedLifetime` 的作用是把"我们确实还
持有它"这件事显式化，避免编译器提前缩短生命周期。

> 注意：这是 Host 侧对**自己的** mapping 的处理。Driver 侧的退役是另一套
> 机制（见 [Mapping-Retirement.md](Mapping-Retirement.md)），因为 Driver 必须
> 在 munmap 之前证明没有回调在其中。

## 3. Driver 侧附着

`Device::OnStartIO`（可为附加 client 走简化路径）：

```
1. 读取 device UID → 计算路径
2. open(O_RDWR | O_NOFOLLOW)
3. fstat → 大小校验；mmap
4. rf_validate_header(mem)            // 版本 / 容量 / 格式 / 大小 / 采样率
5. ValidateConnection()               // 连接健康与 retired_ 检查
6. rf_producer_claim(mem, token)      // 单 owner，失败则 Disconnect 并 fail-closed
7. claimed_epoch_ = rf_admission_epoch(mem)   // relaxed
8. ResizeBuffers(mem)                 // 转换缓冲按本 incarnation 的容量分配
9. volume/mute 控件 SetSharedMemory(mapping_owner_)
10. SyncVolumeStateWithSharedMemory(mem)
11. callback_gate_.Open()             // 必须最后
```

失败处理：任何一步失败 → `Disconnect()` → `RetireMapping("disconnect")`。
准入被拒（slot 已属于别人）是**确定性**失败，重试无意义，直接 fail-closed
并返回错误。

`OnStartIO` 有有限次重试（`MAX_ATTEMPTS`，指数退避），覆盖"Host 尚未发布"
这种时序竞争；但没有无限等待。

### 3.1 为什么 `Open()` 必须最后

在它之前，mapping 指针虽然已经发布，但：

- `ResizeBuffers()` 尚未按本 incarnation 的容量分配缓冲；
- volume/mute 控件尚未指向本 incarnation；
- producer slot 尚未被本次 handler 绑定。

此时被准入的回调会读到半初始化的状态。`Open()` 是唯一的"全部就绪"信号。

## 4. 运行期

| 项 | 行为 |
|---|---|
| 心跳 | Driver 与 Host 各自周期性写自己的 heartbeat 字段（`relaxed`/`release`，仅诊断） |
| 连接健康 | `rf_is_connection_healthy()` 检查 header 有效性与心跳新鲜度 |
| 音量/静音 | App 直接 mmap 写标量，Driver 控件实时读取；不需要 IPC 往返 |
| 写入 | 每个回调先过 `CallbackGate`，再过 `rf_producer_may_write()` 三条件 |
| 读取 | Host `AudioRenderer.render` 调 `rf_ring_read`，不足补零 |

## 5. 正常停止

```
最后一帧播放结束
  → Host 侧：revokeAdmission(mapping) = rf_admission_begin_close()  // OPEN → CLOSING
  → unlinkIfStillOwned(path, mapping)                              // st_dev/st_ino 匹配才 unlink
  → 租约释放，最后一个引用消失时才真正 munmap
```

- `rf_admission_begin_close()` 让**未来**的 producer 写入立即停止，但**不**是
  排空证明：一个已经过闸门的回调可能仍在运行。
- 因此标记 `isClosed = true` 并让新发布走新 inode，而不是复用这块内存。
- `rf_admission_finalize_close()` 在 Host 的清理路径中**刻意不调用**：
  `CLOSED` 这个状态需要排空证明才能有意义，而排空属于 Driver 侧职责
  （Batch 3）。Host 只需要"不再有新写入"。

## 6. 崩溃恢复

### 6.1 Host 崩溃

- 已发布的 inode 仍留在 `/tmp`，但引用它的 Host 进程已消失。
- 新 Host 启动时 `probeExisting()` 以 `O_RDONLY|O_NOFOLLOW` 只映射 **320 B
  header**（绝不映射音频数据区），判断文件是否可归类为"可恢复"，并读回
  音量状态。
- 新 Host 随后创建**新的 staging inode**、新的随机 epoch、**rename 覆盖**
  旧路径。旧 inode 因无引用而由内核回收（或在 Driver 仍持有映射时继续存在，
  但已不可达）。
- Driver 侧：它仍在旧 mapping 上。旧 epoch 与新 epoch 不同，"新 mapping 上
  旧 token 无效"，但旧 mapping 实际上并没有被新 Host 触碰——它只是不再被
  写入（旧 admission 的 state 仍为 OPEN，但 Ring 不再有新数据）。Driver 下一
  次 `OnStartIO` 时会重新走附着流程，得到新 inode。

### 6.2 Driver 崩溃（`coreaudiod` 重启）

- Driver 侧的所有 `CallbackGate`、`revision`、`claimed_epoch_` 随进程消失。
- Host 侧：旧 mapping 的 admission 仍是 OPEN（Host 不知道 Driver 已死），
  但 Ring 不再有写入 → 欠载 → 零填充。Host 不会因此崩溃。
- Driver 重启后重新 claim：`producer_owner_token` 仍是旧 token，因此新
  handler 的 claim **会失败**——这是刻意设计的 fail-closed：新 Driver 不该
  假定旧持有者已死。恢复依赖 Host 重新发布 mapping（新 inode + 新 epoch）。
  这一条是**已知的行为限制**：Host 没有"Driver 已死"的检测，因此在 Driver
  重启后需要一次 IO 重启 / 设备切换才能恢复。见风险清单。

### 6.3 为什么不需要判活启发式

传统做法会用 PID 存活、`st_mtime` 新鲜度、`st_nlink` 计数猜测"旧持有者是
否还活着"。SoundBridge 不做这些：

- 每次发布都是**新 inode**，旧映射不可能被复用；
- 每次发布都是**新 epoch**，旧 token 在新映射上无效；
- 旧映射是否真的被 munmap 不影响新映射的正确性（最坏情况是它与新映射并存，
  直到被 quarantine 或进程退出）。

恢复的正确性来自**构造**，而不是来自对旧状态的判断。代价是旧资源可能被
保守地保留更久，收益是不存在"误判旧状态已死"导致的数据损坏。

## 7. 多设备与多实例

| 场景 | 隔离方式 |
|---|---|
| 多个设备 | 路径含 `sanitized_deviceUID` |
| 多个用户 | 路径含 `ownerUID`；`/tmp` 粘滞位 + 0600 权限 |
| 同一用户多个 Host 实例 | Host 单实例锁（名字唯一性），第二个实例拒绝启动 |
| Host 重启 | 新 inode + 新 epoch；旧文件由 inode 检查避免误删新文件 |
| 顺序执行的旧实例清理 | `unlinkIfStillOwned` 用 `st_dev`/`st_ino` 比对，避免删除新文件 |

`unlinkIfStillOwned` 的检查与 `unlink` 之间**不是原子操作**，因此仍依赖实例
锁排除其他合法写者。这是已知的实现约束（见风险清单）。

## 8. 已验证 / 未验证

已验证：

- 创建 → 初始化 → 预填充 → open → rename 的顺序（单测 + 跨进程测试）；
- 路径按设备与 UID 区分；
- header 校验拒绝非法容量 / 格式 / 版本；
- `probeExisting` 只映射 header；
- `rf_admission_begin_close` 幂等；
- inode 检查避免误删。

未验证：

- 真实 Host 崩溃后由真实 Driver 重新附着的完整流程（跨进程测试是模拟的）；
- Driver（`coreaudiod`）重启后的恢复（见 §6.2 的行为限制）；
- 多设备真实并发热插拔；
- `/tmp` 被清理工具删除文件后的行为。

## 9. 相关文档

- 协议布局：[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
- 准入：[Admission-Ownership.md](Admission-Ownership.md)
- 退役：[Mapping-Retirement.md](Mapping-Retirement.md)
- Ring：[RingBuffer-Design.md](RingBuffer-Design.md)
