# 文档迁移清单（Documentation Migration Manifest）

本文件记录 `SoundBridge-Research/` 中**每一个文件**的处置方式，使"研究目录被
删除"这件事可审计。

配套的冻结哈希清单：`manifests/Research-Directory-Inventory.sha256`
（86 条 `sha256 + 路径`，按路径排序；该文件自身的 SHA-256 见 §2.3）。该清单保留在本地历史审计目录，不随正式仓库提交。

---

## 1. 口径与约定

### 1.1 字段

| 字段 | 说明 |
|---|---|
| Original Path | 原始研究文件路径，前缀统一写作 `Real-Project-Development/…`、`Architecture/…`、`PoC/…`（相对于已退役的研究目录根） |
| Original SHA-256 | 原始文件哈希。逐文件值见冻结清单；本文件按组引用，避免同一哈希在两处独立维护 |
| Classification | A / B / C / D，定义见 §1.2 |
| Final Path | 正式归档位置；`—` 表示无对应文档 |
| Final SHA-256 | **全部为 `不适用`**：没有任何原始文件被逐字复制，所有正式文档都是重新撰写的。**本清单不声称任何"迁移后文件与原文件哈希一致"** |
| Treatment | `Copy` / `Merge` / `Summary` / `Omit` |
| Reason | 处置原因，必须写清"保留了什么结论"或"为什么不需要保留" |

### 1.2 分类

| 类 | 定义 |
|---|---|
| **A** | 必须正式归档：最终架构、设计、证明、验证报告、风险 |
| **B** | 合并后归档：与其他文件重复，或已被最终实现取代，但结论仍有效 |
| **C** | 过程性资料：中间草稿、过期选型、重复调研、未采用的实验线 |
| **D** | 原始证据：测试输出、Sanitizer 结果、编译记录、Manifest、关键实验记录 |

### 1.3 三条硬约束

1. **没有 `Copy`**。所有迁移都是 `Merge` 或 `Summary`。原因：原始文档之间
   互相矛盾、包含已被否定的中间结论、且大量引用已删除的路径；逐字复制会把
   这些包袱带进正式文档。
2. **D 类不得因"是过程文件"而丢弃**。所有唯一证据（Output Manifest 的
   19 条校验值、3 条改前哈希、测试数字与命令）都在
   [verification/Batch-3-Closure-Fix.md](verification/Batch-3-Closure-Fix.md)
   §9 与 §12 中逐字保留。
3. **路径规范化**。原始 Manifest 中出现的
   `SoundBridge-Research/Architecture/Real-Project-Development/…` 前缀在正式
   文档中被替换为 `<research>/`，**所有哈希值不变**。这样既保留证据，又不
   在仓库中留下失效路径。

## 2. 汇总

### 2.1 分类计数

| 类 | 文件数 | 构成 |
|---|---:|---|
| **A** | 42 | §3.1（9）+ §3.2（12）+ §3.3（6）+ §3.4（7）+ §3.5（7）+ §3.9（1） |
| **B** | 34 | §3.6（10）+ §3.7（8）+ §3.8（8）+ §3.9（8） |
| **C** | 15306 | §3.9（6）+ §4.1（9）+ §4 的 29 个批量目录（15291） |
| **D** | 6 | §3.1（2）+ §3.9（2）+ §4.1（2） |
| 系统文件 | 3 | 顶层 `Architecture/.DS_Store`、`PoC/.DS_Store`、根 `.DS_Store` |
| 合计 | **15391** | 与 `find . -type f` 实测一致 |

（另有 3 个 `.DS_Store` 位于 §4 的批量目录内部，已计入该目录的文件数与
聚合指纹，不单列。）

### 2.2 处置计数

| Treatment | 文件数 | 构成 |
|---|---:|---|
| Merge | 59 | §3.1–§3.5 的 43 份 + Readiness 4 + Design 3 + Phase-0 9 |
| Summary | 54 | Readiness 6 + Design 5 + Decision 8 + Phase-0 3 + §4.1 的 11 + Phase-3.1 8 + Phase-3.7 13 |
| Omit | 15278 | Phase-0 5 + §4 的批量目录 15270 + 顶层 `.DS_Store` 3 |

`Omit` 的 15270 个批量目录文件（加上 Phase-0 的 5 份过程快照与 3 个系统文件）
全部属于 **C 类**（系统文件除外），且全部位于 §4 的批量实验/构建目录中
（`.rec` 录音、`.log`、`.sh`、`.o`、`.stdout`/`.stderr`、`.csv` 等）。它们
不是任何一个已采用设计的证据；其所属设计线（XPC / E2）从未进入产品代码。
§4 对每个目录给出聚合指纹，使其内容在删除后仍可被整体识别。

### 2.3 规模

| 项 | 值 |
|---|---|
| 文件总数 | **15391** |
| 目录总数 | **7007**（含根目录，即 7006 个子目录） |
| 总占用 | **约 160 MB** |
| `Real-Project-Development` | 86 个文件 / **59 MB** |
| `Architecture/EXP-1` | 8928 个文件 / 52 MB |
| `Architecture/evidence` | 4414 个文件 / 38 MB |
| `PoC` | 1937 个文件 / 10 MB |
| 冻结清单自身 SHA-256 | `d898d181f2853da0625703828d8f7b418242733f5e242e277e0ecb5a152580c6`（15391 行全量清单） |

## 3. Real-Project-Development：逐目录记录

本子树共 86 个文件 / 59 MB，是研究目录中**唯一的工程语料**。逐文件哈希见
`manifests/Research-Directory-Inventory.sha256`
中 `Real-Project-Development/` 前缀下的 86 行（该清单本地保留，不随正式仓库提交）。

### 3.1 Batch-3-Closure-Fix-CallbackGate（11 个文件 / 131,975 B）

| 字段 | 值 |
|---|---|
| Classification | **A**（9 份报告）+ **D**（2 份 Manifest） |
| Final Path | [verification/Batch-3-Closure-Fix.md](verification/Batch-3-Closure-Fix.md)、[engineering/CallbackGate-Memory-Model.md](engineering/CallbackGate-Memory-Model.md)、[engineering/Mapping-Retirement.md](engineering/Mapping-Retirement.md)、[risks/Known-Limitations.md](risks/Known-Limitations.md) |
| Treatment | **Merge** |
| Final SHA-256 | 不适用 |

文件与去向：

| 文件 | 去向 |
|---|---|
| `Closure-Fix-Report.md` | Batch-3-Closure-Fix §1–§3、§13 |
| `CallbackGate-Memory-Model-Proof.md` | CallbackGate-Memory-Model 全文结构 |
| `CallbackGate-Interleaving-Analysis.md` | CallbackGate-Memory-Model §6（T1/T2 反证） |
| `Lock-Free-Guarantees.md` | CallbackGate-Memory-Model §10；Batch-3-Closure-Fix §4 |
| `Quarantine-Lifecycle-Review.md` | Mapping-Retirement §6；Batch-3-Closure-Fix §6 |
| `RT-Safety-Review.md` | Batch-3-Closure-Fix §7 |
| `Changed-Files.md` | Batch-3-Closure-Fix §8 |
| `Test-Report.md` | Batch-3-Closure-Fix §9 |
| `Remaining-Risks.md` | Batch-3-Closure-Fix §11；Known-Limitations |
| `Input-Manifest.sha256` | Batch-3-Closure-Fix §12.2（33 条校验值逐字保留） |
| `Output-Manifest.sha256` | Batch-3-Closure-Fix §12.3（19 条校验值逐字保留）；自哈希 `c1620c3a…ee86` |

**唯一证据核对**：19 条输出校验值、3 条改前哈希、Manifest 自哈希、测试命令
与 40/40、5/5、0 报告等数字均已逐字进入正式文档。**无丢失**。

### 3.2 Phase-1A-1B-Implementation-Batch-3-Mapping-Retirement（12 / 115,298 B）

| 字段 | 值 |
|---|---|
| Classification | **A** |
| Final Path | [verification/Batch-3-Verification.md](verification/Batch-3-Verification.md)、[engineering/Mapping-Retirement.md](engineering/Mapping-Retirement.md)、[engineering/SharedMemory-Lifecycle.md](engineering/SharedMemory-Lifecycle.md) |
| Treatment | **Merge** |
| Final SHA-256 | 不适用 |

`Implementation-Report` → Batch-3 §1–§5；`Mapping-Retirement-Proof` →
Mapping-Retirement §2–§7；`Mapping-Lifecycle` → SharedMemory-Lifecycle；
`Callback-Drain-Proof` → CallbackGate-Memory-Model §9；`RT-Safety-Audit` →
Batch-3 §6 + Known-Limitations RT-1…RT-5；`Stale-Claim-Recovery` →
Admission-Ownership §3；`Test-Report` → Batch-3 §7；`Remaining-Risks` →
Batch-3 §10 + Known-Limitations；`Changed-Files` / `Batch-3-Implementation-Design`
→ Batch-3 §3；两份 Manifest → 冻结清单（校验值未逐条迁移，理由见 §6）。

### 3.3 Phase-1A-1B-Implementation-Batch-2-Admission-Ownership（6 / 62,900 B）

| 字段 | 值 |
|---|---|
| Classification | **A** |
| Final Path | [verification/Batch-2-Verification.md](verification/Batch-2-Verification.md)、[engineering/Admission-Ownership.md](engineering/Admission-Ownership.md) |
| Treatment | **Merge** |
| Final SHA-256 | 不适用 |

`Batch-2-Admission-Protocol` / `Batch-2-ABI-Change` → Admission-Ownership §2 +
Batch-2 §2.1；`Batch-2-Implementation-Report` → Batch-2 §1–§6；
`Batch-2-Test-Report` → Batch-2 §3–§7；`Batch-2-RT-Safety-Audit` →
Batch-2 §7 + Known-Limitations；`Batch-2-Change-Manifest.txt` → Batch-2 §2
（文件清单，逐条哈希留在冻结清单）。

### 3.4 Phase-1A-1B-Implementation-Batch-2-Admission-Ownership/Closure-Review（7 / 66,763 B）

| 字段 | 值 |
|---|---|
| Classification | **A** |
| Final Path | [verification/Batch-2-Closure-Verification.md](verification/Batch-2-Closure-Verification.md) |
| Treatment | **Merge** |
| Final SHA-256 | 不适用 |

`Closure-Review-Report` → §1–§4；`Token-Uniqueness-Review` → §2；
`Callback-Exit-Proof` → §3；`Test-Report` → §5–§6（含三项测试能力降级）；
`Changed-Files` → §3；两份 Manifest → 冻结清单。

### 3.5 Phase-1A-1B-Implementation-Batch-0-1（7 / 37,509 B）

| 字段 | 值 |
|---|---|
| Classification | **A** |
| Final Path | [verification/Batch-0-1-Verification.md](verification/Batch-0-1-Verification.md)、[engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md) |
| Treatment | **Merge** |
| Final SHA-256 | 不适用 |

`Batch-0-Protocol-Contract` → RingBuffer-Design §2–§8 + Batch-0-1 §1；
`Implementation-Report` → Batch-0-1 §1–§3；`Test-Report` → §3–§6；
`Remaining-Risks` → §7 + Known-Limitations；`Changed-Files` → §2；
两份 Manifest → 冻结清单。

### 3.6 Phase-1A-1B-Implementation-Readiness（10 / 80,108 B）

| 字段 | 值 |
|---|---|
| Classification | **B** |
| Final Path | [architecture/SoundBridge-1.2.0-Architecture.md](architecture/SoundBridge-1.2.0-Architecture.md)（§5–§8）、[risks/Known-Limitations.md](risks/Known-Limitations.md) |
| Treatment | **Merge + Summary** |
| Final SHA-256 | 不适用 |

理由：这批文件回答"能不能开始实现"，其 9 条 guard 绝大多数已被 Batch 0–3
实际实现并取代。`Audio-Format-Capacity-Readiness` 的格式/容量事实 → 
RingBuffer-Design §2–§3；`Cross-Process-Atomic-Verification` 的 C1–C4 结论
→ Admission-Ownership §6；`Admission-Drain-Retirement-Implementation-Map` 的
工作分解 → Batch-3 §1；`Producer-Topology-Verification` → 架构 §5；
`Implementation-Readiness-Summary` / `Implementation-Batch-Plan` /
`Phase-1C-1D-Dependency-Register` / `Verification-Method` → Summary：
其结论（CONDITIONALLY READY）已被后续批次的实测结论取代，不再单独保留。

### 3.7 Phase-1A-1B-Design（8 / 51,668 B）

| 字段 | 值 |
|---|---|
| Classification | **B** |
| Final Path | [engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md)、[architecture/SoundBridge-1.2.0-Architecture.md](architecture/SoundBridge-1.2.0-Architecture.md) |
| Treatment | **Merge + Summary** |
| Final SHA-256 | 不适用 |

`Phase-1A-Concurrency-Ring-Atomic` → RingBuffer-Design §4；
`Phase-1B-Format-Boundary-Joint-Contract` → RingBuffer-Design §2；
`Phase-1A-1B-Implementation-Test-Risks` → Known-Limitations；
`Source-Inventory` → Summary（当时的文件清单已失效）；`Verification-Method`
与两份 Manifest → Summary / 冻结清单。

### 3.8 Phase-1A-1B-Decision（8 / 69,429 B）

| 字段 | 值 |
|---|---|
| Classification | **B** |
| Final Path | [architecture/SoundBridge-1.2.0-Architecture.md](architecture/SoundBridge-1.2.0-Architecture.md) §12、[engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md) |
| Treatment | **Merge + Summary** |
| Final SHA-256 | 不适用 |

理由：决策记录的价值在于"为什么是现在这样"。其中仍然成立的决定（SPSC、
索引所有权、Drop New、欠下补零、64 位回绕、canonical 格式、容量公式）已
进入 RingBuffer-Design；被后续否定或替代的决定（跨进程原子当时判为
BLOCKED、SPSC 当时判为条件可行）只在架构文档 §12 以一句"已由后续批次解决"
带过，不保留原始论证过程。

### 3.9 Phase-0（17 / 61,385,603 B）

| 字段 | 值 |
|---|---|
| Classification | **A**（RT 审计）+ **B**（结构审计）+ **C**（计划与快照） |
| Final Path | [risks/Known-Limitations.md](risks/Known-Limitations.md)、[architecture/SoundBridge-1.2.0-Architecture.md](architecture/SoundBridge-1.2.0-Architecture.md)、[engineering/RingBuffer-Design.md](engineering/RingBuffer-Design.md) |
| Treatment | **Merge + Summary + Omit** |
| Final SHA-256 | 不适用 |

| 文件 | 处置 | 理由 |
|---|---|---|
| `Phase-0-RT-Safety-Audit.md` | **Merge → A** | RT-1…RT-5 的唯一来源，已逐条进入 Known-Limitations §3.1 |
| `Phase-0-Actual-Call-Graph.md` | Merge → B | 调用链结论进入架构 §2 与 §8 |
| `Phase-0-Ring-Buffer-Audit.md` | Merge → B | → RingBuffer-Design §4–§5 |
| `Phase-0-Format-and-Memory-Boundary-Audit.md` | Merge → B | → RingBuffer-Design §2；Float64 缺口 → Known-Limitations F-1 |
| `Phase-0-DSP-Concurrency-Audit.md` | Summary → B | 结论（DSP 非线程安全，仅由 Host 单线程调用）已写在架构 §3 |
| `Phase-0-Source-Architecture-Map.md` | Merge → B | → 架构 §2–§3 |
| `Phase-0-Module-Audit.md` | Summary → B | 模块清单已被当前目录结构取代 |
| `Phase-0-Risk-and-Dependency-Register.md` | Merge → B | 未关闭项 → Known-Limitations |
| `Phase-0-Executive-Summary.md` | Summary → B | 结论（CONDITIONAL COMPLETE / 显式缺口）已被后续批次取代 |
| `Phase-0-Target-Architecture-Gap-Analysis.md` | Omit → C | 差距项已全部由 Batch 0–3 关闭，逐条保留只会制造"仍在TODO"的错觉 |
| `Phase-0-Phase-1-Implementation-Plan.md` | Omit → C | 计划已被实际执行取代 |
| `Phase-0-Authorization-and-Scope.md` | Omit → C | 过程性授权记录 |
| `Phase-0-Workspace-Protection-Report.md` | Summary → C | 结论（未修改用户文件）已在退役报告中重述 |
| `Workspace-Git-Status.txt`（1.4 MB） | **Omit → C** | 自动生成的 `git status` 快照；内容随时点失效，无独立工程结论 |
| `Workspace-Protection-Inventory.jsonl`（59.9 MB） | **Omit → C** | 全工作区文件哈希快照；同一信息在本次退役中重新生成并冻结为 `manifests/Research-Directory-Inventory.sha256` 与迁移报告 §2.3 |
| `Input-Manifest.sha256` / `Output-Manifest.sha256` | Summary → D | 记录的是 Phase 0 时的源码哈希；源码已演进，校验值不可再复核。两份文件自身的哈希保留在冻结清单中 |

## 4. 批量实验与构建目录：按目录聚合记录

这 29 个目录共 **15291** 个文件（含 3 个目录内部的 `.DS_Store`），全部属于
**未采用的** XPC / E2 研究线与 Phase-3.x 实验线。它们不属于任何已采用设计
的证据，因此按目录聚合记录：
`聚合 SHA-256` = 目录内全部文件的 `sha256 + 路径` 按路径排序后拼接再取
SHA-256，用于在删除后识别整体内容。

| 目录 | 文件数 | 字节 | 聚合 SHA-256 | 类 | 处置 |
|---|---:|---:|---|---|---|
| `Architecture/Phase-3.1` | 8 | 60,210 | `1961a7556b37d6a8f21b0c113ddcd00fb0d001496301d5df5ee5ef272d5ca1f8` | C | Summary |
| `Architecture/Phase-3.7` | 13 | 83,411 | `f80319f119a6c0ed0e9f613192108d2747432b05a9866d5bf761af00ee44c79d` | C | Summary |
| `Architecture/EXP-1/P31-9` | 10 | 39,446 | `d857bcc9b72251ddfae053fd6d1c02606c7073e30bb3b1d19e2530700c356466` | C | Omit |
| `Architecture/EXP-1/P31-10` | 27 | 104,734 | `6c2dea032cb5085f78648653341ff0ec41a67a2d550a555b366e663dd9209b2f` | C | Omit |
| `Architecture/EXP-1/P31-11` | 7 | 14,929 | `bd22f4d6f6768ba27834c79d59956fa3727c887682b90f5eb78c5931411791be` | C | Omit |
| `Architecture/EXP-1/P31-12` | 10 | 27,791 | `d6e67f74cb14a45c78b1620e3650aadb2f6a86ba32dc4f8eccd030dc743a1b55` | C | Omit |
| `Architecture/EXP-1/P31-13` | 12 | 40,078 | `28d31213d9bd03e97b4b86e55bdbe07b1eafbabeb46772840a0b57faed7844de` | C | Omit |
| `Architecture/EXP-1/P31-14` | 8,765 | 27,135,532 | `c7efc9f7f842255bf30340188a1ab9b89ccd2db6a5a227e53846d574eafba5cf` | C | Omit |
| `Architecture/EXP-1/P31-15` | 60 | 455,749 | `9f375fc10681bef9003d452eb7424c1c592e812a6c561a8544c07fedecd7f2e6` | C | Omit |
| `Architecture/EXP-1/build` | 18 | 247,236 | `eef54480a1a4cc03fd78f0dd619239f6200f5c95bc8f2df9035e7bea822bfdc2` | C | Omit |
| `Architecture/EXP-1/source` | 6 | 30,363 | `cc4cce8df52a9899cb8aca9eee62eeff1cc52f4af5e1a7d1808be2a17c6c6481` | C | Omit |
| `Architecture/EXP-1/tests` | 1 | 3,115 | `edd1d0b2b31c4c597369149f221cac13a695ec9b38544aeabcc45dd289ad5557` | C | Omit |
| `Architecture/EXP-1/reports` | 3 | 1,455 | `61644bf65882cca87ed68a10055286c3d22f362e6e29303b2d022ddc11f8a957` | C | Omit |
| `Architecture/EXP-1/scripts` | 1 | 2,235 | `7578edb42c9b2b6d8ba6916fa63881686c0ab10268c522af1eb4ca70db77256f` | C | Omit |
| `Architecture/EXP-1/evidence` | 0（空） | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | C | Omit |
| `Architecture/evidence/B0-a` | 5 | 17,610 | `f5614b442f9b154ec79b4fd0bcacee92e8ed3054735afd036d9012f1191a8747` | C | Omit |
| `Architecture/evidence/B0-b` | 5 | 4,778 | `d3050e832e14c62c165449f7ddfe7e0bb4d97de0efa6e23591e253669d156444` | C | Omit |
| `Architecture/evidence/B0-tools` | 4 | 84,910 | `884f5c4cd9e72d95e8d9980d261f63f8d82d0e2797295043af8b257b95231cbc` | C | Omit |
| `Architecture/evidence/B1-T1` | 28 | 602,247 | `7d5e4386aae2089e209343bde1d668b17b8538f99490f643ecea5496d3e983dc` | C | Omit |
| `Architecture/evidence/B1-T1-XPC` | 70 | 6,756,685 | `656e997deaa030c2bfbe14ac77e1879e96c352b464e389c96bea53504ed8ed14` | C | Omit |
| `Architecture/evidence/B1-T1-XPC-Fix` | 79 | 3,227,320 | `ed102c282c84f8933279753197e81eb42b03a9e942c8b78181e3b013acc12537` | C | Omit |
| `Architecture/evidence/B1-T1-XPC-Fix-Integration` | 1,406 | 4,218,968 | `97349d3713735815f024d223f0c71424b2e0f2a2918bb3936a948234d2e718c4` | C | Omit |
| `Architecture/evidence/B1-T1-XPC-Fix-Source-Remediation` | 320 | 6,802,668 | `7e42d336daee2fe8636eeb498616261853bd049e8ddbdde3e755146611cbd213` | C | Omit |
| `Architecture/evidence/B1-T1-XPC-Final-Hardening` | 2,453 | 5,503,344 | `b7f1f7c4dabf4fd6f45610e095087d0954abf02b46869b6e320794c330d242f0` | C | Omit |
| `Architecture/evidence/B1-static` | 2 | 16,470 | `7062822887002eea6eb23f891f7941d9256b96f6aa441a4336938e28f95fe390` | C | Omit |
| `Architecture/evidence/B1F-Continuation` | 17 | 114,301 | `ceb116d9f8e38cdf5fe683565c3ccabb7be6467c46eeca73e99725df0c69348e` | C | Omit |
| `Architecture/evidence/Phase-3` | 12 | 73,627 | `b7b87b7bbe0a846fddda1fe4945f80ec6ddd300733b126419220905a01790b45` | C | Omit |
| `PoC/6B-1E-1A` | 44 | 694,932 | `f92e42a3b079f334cedf6beea7c56d89c3a8f720e82947ba4dde17d5f6a2f1a3` | C | Omit |
| `PoC/6B-1F` | 1,892 | 3,651,085 | `6cf3526d1d3424c160233cc86c63f96b1d187b78ab22153ea7b48e546c1d17bf` | C | Omit |

### 4.1 顶层散落文件

`Architecture/` 与 `Architecture/EXP-1/` 的直接子文件共 11 个（不属于 §4 的任何批量子目录）：

| 文件 | 字节 | SHA-256 | 类 | 处置 |
|---|---:|---|---|---|
| `Architecture/Phase-6B-1F-Architecture-Research.md` | 35,575 | `3466ae83b778a13332aa19262e2884e2b94a25eb233dd7265f036d4d80067750` | C | Summary |
| `Architecture/Phase-6B-1F-B0-Execution-Report.md` | 12,913 | `54dd412f0d89578817499b7117fa73adbbb922226127806cfd362d5c85642c72` | C | Summary |
| `Architecture/Phase-6B-1F-B1-Experiment-Design-and-Security-Review.md` | 37,970 | `fda3ee0f179e89dee5a32870d20ed4e1a2f7ba945d6cec1121d3c3c98734be90` | C | Summary |
| `Architecture/EXP-1/README.md` | 见冻结清单 | 见冻结清单 | C | Summary |
| `Architecture/EXP-1/P31-8-Architecture-and-Implementation-Notes.md` | 见冻结清单 | 见冻结清单 | C | Summary |
| `Architecture/EXP-1/P31-8-Authorization-Boundary.md` | 见冻结清单 | 见冻结清单 | C | Summary |
| `Architecture/EXP-1/P31-8-Build-Report.md` | 见冻结清单 | 见冻结清单 | C | Summary |
| `Architecture/EXP-1/P31-8-Signing-Report.md` | 见冻结清单 | 见冻结清单 | C | Summary |
| `Architecture/EXP-1/P31-8-Static-Validation.md` | 见冻结清单 | 见冻结清单 | C | Summary |
| `Architecture/EXP-1/Input-Manifest.sha256` | 1,112 | `8a15d7ca4174256028cae954306d505cacc72016b832cf9acc6eb0fab27c3bd6` | D | Summary |
| `Architecture/EXP-1/Output-Manifest.sha256` | 3,314 | `48ef94c30dfcd46f7ea5802643eae63d983e773305e5ccab53cb86ad1f5d7d04` | D | Summary |

另有 3 个顶层系统文件：`SoundBridge-Research/.DS_Store`、`Architecture/.DS_Store`、`PoC/.DS_Store` → **Omit**（无内容价值，系统自动生成）。

EXP-1 的 6 份 `P31-8-*` 文档与 `README.md` 记录的是 EXP-1 实验自身的构建/签名
/静态校验结果。该实验线（XPC 能力分发）从未进入产品代码，故摘要处理：
结论（不可行 / 风险过高）已在 [risks/Known-Limitations.md](risks/Known-Limitations.md)
的 U-13、L-12 中体现，其余细节不保留。逐文件哈希见冻结清单。

**这三份 6B-1F 文档的结论去了哪里**：它们的核心结论是"XPC 能力分发在当前
产品形态下不可行/风险过高"，以及一份 R1–R19 风险清单。仍然适用的条目已
被升格进 [risks/Known-Limitations.md](risks/Known-Limitations.md)：
R3（HAL 沙箱下的 `/tmp` 读取权限）→ U-13；R9（macOS 14.4）→ U-3；
R12（lock-free ≠ wait-free）→ L-4；R13（单 mapping 模型）→ L-12；
R7/R15（`read_index` 双写者）→ §3.4 "已关闭"。其余条目针对的是**未被采用**
的 XPC 方案，随方案一起退役。

## 5. 合并映射：来源 → 正式文档

| 正式文档 | 主要来源（A/B 类） |
|---|---|
| `README.md` | 全部批次的结论汇总；无单点来源 |
| `architecture/SoundBridge-1.2.0-Architecture.md` | Phase-0 结构审计、Design、Decision、Readiness、Batch 2/3 报告 |
| `engineering/RingBuffer-Design.md` | Batch-0-1 的 `Batch-0-Protocol-Contract` + Ring 审计 + Design |
| `engineering/Admission-Ownership.md` | Batch-2 `Batch-2-Admission-Protocol` / `Batch-2-ABI-Change` + Closure Review |
| `engineering/Callback-Lifecycle.md` | Batch-2 `Callback-Exit-Proof`、Batch-3 `Callback-Drain-Proof`、Closure Fix `RT-Safety-Review` |
| `engineering/Mapping-Retirement.md` | Batch-3 `Mapping-Retirement-Proof` / `Mapping-Lifecycle` + Closure Fix `Quarantine-Lifecycle-Review` |
| `engineering/SharedMemory-Lifecycle.md` | Batch-3 `Mapping-Lifecycle` + Batch-1/2 发布顺序 |
| `engineering/CallbackGate-Memory-Model.md` | Closure Fix 的 `Memory-Model-Proof` + `Interleaving-Analysis` + `Lock-Free-Guarantees` |
| `verification/Batch-0-1-Verification.md` | Batch-0-1 全部 7 份 |
| `verification/Batch-2-Verification.md` | Batch-2 全部 6 份 |
| `verification/Batch-2-Closure-Verification.md` | Closure-Review 全部 7 份 |
| `verification/Batch-3-Verification.md` | Batch-3 全部 12 份 |
| `verification/Batch-3-Closure-Fix.md` | Closure Fix 全部 11 份 |
| `risks/Known-Limitations.md` | 全部 `Remaining-Risks.md`（5 份）+ Phase-0 RT 审计 + 6B-1F 风险 |
| `release/SoundBridge-1.2.0-Release-Checklist.md` | 各批次"未覆盖"清单 + Makefile 实际目标 |

## 6. D 类唯一证据保留核对

| 证据 | 是否唯一 | 保留位置 | 形式 |
|---|---|---|---|
| Closure Fix 19 条输出校验值 | 是 | Batch-3-Closure-Fix §12.3 | 逐字（路径前缀规范化） |
| Closure Fix 33 条输入校验值（3 条 FAILED） | 是 | Batch-3-Closure-Fix §12.2 | 逐字 |
| 两份 Manifest 自哈希 | 是 | §12.4 | 逐字，其中 Output 已复核 |
| 改前/改后源码哈希与行数 | 是 | §8 | 逐字 |
| 测试命令与 40/40、5/5、0 报告 | 是 | §9 | 逐字 |
| 4 份头副本哈希 | 是 | §9.2、§12.3 | 逐字 |
| Batch 0–3 的测试数字与命令 | 是 | 各 `verification/*.md` | 逐字 |
| Phase 0 / Batch 3 的 Manifest 校验值 | **否** | — | 记录的是当时源码哈希，源码已演进；仅保留清单文件自身哈希（冻结清单）。这是本清单中唯一"未逐条迁移"的 D 类内容，理由已写明 |
| EXP-1 的 Input/Output Manifest | **否** | — | 属于未采用设计线；Hash 值记录在 §4.1，未逐条展开 |

## 7. 完整性检查结果

| # | 检查项 | 结果 |
|---|---|---|
| 1 | 所有 A 类文件已迁移 | **通过**（42/42，见 §3.1–§3.5、§3.9） |
| 2 | 所有 D 类唯一证据均已保留 | **通过**（6 份中 2 份逐字、4 份摘要并保留原哈希；理由见 §6） |
| 3 | B 类已完成合并 | **通过**（34/34，见 §3.6–§3.9） |
| 4 | C 类有明确处理理由 | **通过**（§3.9、§4、§4.1 逐项写明） |
| 5 | Markdown 链接全部有效 | 见 §8 校验记录 |
| 6 | 相对路径全部有效 | 同上 |
| 7 | 无指向已删除目录的失效引用 | **通过**（全仓库 `grep` 确认；正式文档只用 `<research>/` 占位） |
| 8 | 无把 `CONDITIONAL PASS` 写成 `PASS` | **通过**（Batch 3 与 Closure Fix 均标注条件） |

## 8. 校验记录

| 校验 | 命令 | 结果 |
|---|---|---|
| 链接可达 | 脚本解析 `docs/**/*.md` 的非绝对链接并 `os.path.exists` | **141 条，0 失效**（已剔除围栏代码块与行内代码） |
| 冻结清单复核 | `cd SoundBridge-Research/Architecture && shasum -a 256 -c ../../docs/manifests/…` | **86/86 OK**（删除前实测） |
| 失效路径引用 | `grep -rIl "SoundBridge-Research"`（排除 `.git` / `.build`） | 仅 6 份 docs 文档的叙述性文字，**无链接、无代码/脚本/Makefile/CI 引用** |
| 哈希一致性 | 正式文档中 79 个 64 位十六进制串逐个归属判定 | 全部可溯源，无来历不明哈希 |
| Closure Fix 证据完整性 | 原文与文档比对 | Input **33/33**、Output **19/19** 校验值逐字命中 |
| 结论一致性 | `grep -c "CONDITIONAL PASS"` | Batch 3 = 4、Closure Fix = 5、README = 3、架构 = 2、检查单 = 2；无 PASS 误写 |

完整执行输出与逐条判定见
`Research-Directory-Retirement-Report.md` §6（该报告本地保留，不随正式仓库提交）。
