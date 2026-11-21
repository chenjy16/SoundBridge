# SoundBridge 1.2.0 — P4 Batch 1C 提交授权申请

**阶段**：P4 Batch 1C / Git Commit Readiness、Evidence Sanitization & Controlled Commit —— Stage A + Stage B + Final Remediation 完成，Stage C 未执行
**仓库**：`/path/to/SoundBridge`（本地绝对路径已脱敏，见 §5）
**分支**：`main`
**当前状态**：`READY FOR EXPLICIT G-6 AUTHORIZATION`
**判定依据**：G-3 与 G-7 已在 Final Remediation 中关闭；G-4 已由你于 2026-11-21 逐字确认（原文见下文记录）。剩余步骤只有 G-6：需要你给出 §13 的授权语句，在此之前索引不被触碰。
**Git 写操作**：**无**。暂存区 0 个文件，索引未被触碰（§1）。
**日期**：2026-11-21

**修订记录（P4 Batch 1C Final Remediation，2026-11-21）**：上一版文件的结论是「G-3 PARTIAL + G-7 三选一待定」。本批次按新任务书只做精确文档修改、哈希更新、链接复核与 allowlist 复验，**未执行任何 Git 写操作**：

| 项 | 上一版 | 本次 | 结果 |
|---|---|---|---|
| G-3（3 处独立用户名） | PARTIAL：3 处只列出、未修改 | `POC_ERRATA.md:225` → `USER`；`P3-Host-Restart-….md:99,100` → `owner` | **PASS**，候选集用户名残留 0 |
| G-7（3 条提交后必 404 的链接） | 待你在 A/B/C 中选一个 | 按方案 B：3 处链接降级为行内代码，并注明本地保留、不随仓库提交 | **PASS**，指向未提交文件的链接 0 |
| allowlist | 143 | 143（只改内容，不增删路径） | 闭合 |
| 文档哈希台账 | 11 份 | 12 份（新增 Migration Manifest），原始/最终分列 | 0 失败 |
| G-4 | 未确认 | 2026-11-21 由你逐字确认（原文见下方记录） | **CONFIRMED** |
| Git 写操作 | 无 | 无（暂存区 0、HEAD `ab36770` 未变） | — |

逐文件改动全文：`build/p4-batch1c/evidence/remediation/patch.diff`；哈希台账：`build/p4-batch1c/evidence/final-document-hashes.tsv`。

**G-4 确认记录（2026-11-21，用户本人逐字回复）**：

> 122 个中档文件均属于 SoundBridge 正式项目实施成果，不包含需要保留但不应提交的个人实验性修改。

这句话关闭的是 **G-4**（`g4-ownership-review.tsv` 里 122 行的归属），**不构成 G-6 授权**：暂存与提交仍需 §13 的完整语句。逐字记录另存于 `build/p4-batch1c/evidence/g4-user-confirmation.txt`。

---

## 0. 一页结论：16 项交付的自查

| # | 任务书要求 | 状态 | 位置 |
|---|---|---|---|
| 1 | 当前 HEAD | `ab3677072f0dcb54de27ba4dcabfd11e64ae41ec` | §1 |
| 2 | 当前 branch | `main` | §1 |
| 3 | 当前 origin/main | `ab3677072f0dcb54de27ba4dcabfd11e64ae41ec`（与 HEAD 相同，无远端新提交） | §1 |
| 4 | 当前暂存区状态 | **空**（`git diff --cached --name-only` = 0 行） | §1 |
| 5 | 最终 allowlist 路径数 | **143**（G-7 按方案 B 修复，路径数不变） | §2 |
| 6 | A/B/C/D 数量 | A 55 / B 40 / C 12 / D 33，另计 3 条（`.gitignore`、1B 报告、本申请） | §2 |
| 7 | 新增/修改/删除数量 | 新增 75 / 修改 67 / 删除 1（脚本统计，见 §2.3） | §2.3 |
| 8 | G-1 | **PASS**（`docs/release/` 不再被忽略，`dist/` `build/` `.qoder/` `.build/` 仍被忽略） | §3 |
| 9 | G-2 | **建议纳入，已脱敏并复核哈希**（原始 54,877 B → 58,582 B） | §4 |
| 10 | G-3 脱敏 | **PASS**：15 处仓库路径 + 3 处独立用户名全部替换，候选集残留 0 | §5 |
| 11 | G-4 用户确认 | **CONFIRMED**（2026-11-21 逐字确认，原文见文首记录） | §6 |
| 12 | G-5 | 本阶段不处理（E-2 14 份 + `.qoder/` 保持现状，均不入库） | §7 |
| 13 | G-6 | **等待授权**，未暂存、未提交 | §13 |
| 14 | 所有安全检查结果 | 敏感信息 / 链接 / 版本 / 协议 / 二进制 / 体积，见 §8–§11 | §8–§11 |
| 15 | 完整 pathspec 文件路径 | `build/p4-batch1c/evidence/final-add-list.txt`（143 行） | §12 |
| 16 | 每条路径的 SHA-256 和大小 | 全量 143 行表，见 §12.2（本文件自身以 `—` 标注，真实哈希在独立 manifest） | §12.2 |

**一句话**：G-1 至 G-7 的机械检查与 G-4 的归属确认都已到位，**现在是 `READY FOR EXPLICIT G-6 AUTHORIZATION`**——只差 §13 那一句授权，我不会自己替你说。

---

## 1. 基线（Stage A：重新采集，未沿用 1B 数字）

```
$ git -C "$REPO" branch --show-current
main
$ git -C "$REPO" rev-parse HEAD
ab3677072f0dcb54de27ba4dcabfd11e64ae41ec
$ git -C "$REPO" rev-parse origin/main
ab3677072f0dcb54de27ba4dcabfd11e64ae41ec
$ git -C "$REPO" submodule status
 633e0f70203edd87d320fc5a3cae901e1363aac5 packages/driver/vendor/libASPL (v3.1.2-1-g633e0f7)
$ git -C "$REPO" diff --cached --name-only | wc -l
0
```

submodule 行首是空格而非 `+`/`-`，指针未变；HEAD 与 `origin/main` 相同，无远端新提交；暂存区为空。

| 指标 | 值 |
|---|---|
| `git status --short` 行数（目录折叠后） | **140** |
| `git status --porcelain -uall` 条目 | **157**（1 D + 67 M + 89 ??） |
| 未跟踪文件（-uall 展开） | **89** |
| 其中在最终 allowlist 内 | 75（新增项） |
| 其中属于 E-2（有意不提交） | 14 |
| `git diff --stat` | ` 68 files changed, 9104 insertions(+), 3065 deletions(-)` |
| 暂存区 | **0** |

**与 Batch 1B 报告记录的差异**：1B 报告写"138 行"，本阶段是 **140 行**（`status --short`，目录折叠后）。差额 2 行正好是两份报告自身——1B 报告与本文件都在 1B 采集快照之后才落盘。把这 2 行减掉后是 **138 行，与 1B 逐条一致**，未发现用户新增或修改未审计文件的迹象。

集合闭合性用减法证明，不靠逐条目视：

| 集合 | 数量 | 校验 |
|---|---|---|
| allowlist 路径 | 143 | 全部出现在 `git status` 中，且磁盘状态与记录一致（删除项除外） |
| untracked 总数 | 89 | = allowlist 内新增 75 + E-2 14 |
| tracked 修改/删除 | 68 | 全部在 allowlist 内，未列入的已跟踪改动 = 0 |
| 未归类未跟踪 | 0 | `untracked − allowlist − E-2` = 0 |

E-2 的 14 条（有意保留、不入库）：

- `docs/P1-Product-Integration-Release-Readiness-Audit.md`
- `docs/P2-Batch1-Test-Infrastructure-Report.md`
- `docs/P3-0-Real-MacOS-Environment-Audit.md`
- `docs/P3-0-Workspace-Baseline.md`
- `docs/P3-Batch-1-Release-Build-Verification-Report.md`
- `docs/P3-Batch-1.5-Implementation-Report.md`
- `docs/P3-Batch-1.5-Mapping-Observability-Audit.md`
- `docs/P3-Batch-1.5-RT-Observability-Audit.md`
- `docs/P3-Batch-1.5-Release-Rebuild-Verification.md`
- `docs/P3-Final-Rebuild-Install-Host-Restart-Validation-Report.md`
- `docs/P3-Real-MacOS-Validation-Authorization-Matrix.md`
- `docs/P3-Real-MacOS-Validation-Plan.md`
- `docs/Research-Directory-Retirement-Report.md`
- `docs/manifests/Research-Directory-Inventory.sha256`

---

## 2. 最终 allowlist 的数量与构成

### 2.1 构成公式（逐项，不靠"git add ."）

| 项 | 条数 | 说明 |
|---|---|---|
| 原始 Batch 1B allowlist | 140 | A 55 + B 40 + C 12 + D 33，来自 `build/p4-batch1b/evidence/b1b-allowlist.tsv` |
| `+ .gitignore` | 1 | G-1，独立计入（`C-gitignore`），不混进 C 组 |
| `+ docs/P4-Batch-1B-Pre-Commit-Report.md` | 1 | G-2，独立计入（`D-1B-revision`），**未伪装成原始 140 条的一部分** |
| `+ docs/P4-Batch-1C-Commit-Authorization-Request.md` | 1 | 本文件（`D-1C-request`），Batch 1C 授权门记录 |
| **合计** | **143** | 行数与去重后行数均为 143（脚本已断言） |

排除项（逐类核对，均为 0 条）：E-2 未跟踪研究/证据文件、`.qoder/`、`build/`、`dist/`、一切二进制发布产物。

### 2.2 与旧报告数量的差异解释

| 口径 | 数量 | 差异来源 |
|---|---|---|
| Batch 1B 报告"任务书原始目标" | 140 | 1A 分类时 `.gitignore` 尚未修改，不在任何组内 |
| Batch 1B 报告"最小可提交集" | 141 | + `.gitignore` |
| Batch 1B 报告"推荐完整审计集" | 142 | + 1B 报告自身 |
| **Batch 1C 冻结值** | **143** | + 本授权申请（1B 未预见到这份文档） |

### 2.3 状态分布

| 组 | 条数 | 含义 |
|---|---|---|
| A | 55 | 生产代码 |
| B | 40 | 测试 |
| C | 12 | 构建与工具脚本 |
| D | 33 | 文档 |
| `C-gitignore` | 1 | `.gitignore`（独立计入，不混入 C 组） |
| `D-1B-revision` | 1 | Batch 1B 报告（独立计入） |
| `D-1C-request` | 1 | 本授权申请（独立计入） |
| **合计** | 143 | **新增 75 / 修改 67 / 删除 1** |


---

## 3. G-1：`.gitignore` 纳入提交

`.gitignore` 的修改是 Batch 1B 做的（`release/` → `/release/`，新增 `.qoder/`），本阶段只复核、未再改动。

| 检查 | 命令 | 期望 | 实测 |
|---|---|---|---|
| Release Checklist 不再被忽略 | `git check-ignore -v docs/release/SoundBridge-1.2.0-Release-Checklist.md` | 退出码 1 | **退出码 1**，无输出 |
| 根级 `release/` 仍被忽略 | `git check-ignore -v --no-index release/probe.dmg` | 命中 `/release/` | 命中 `.gitignore:124:/release/` |
| `dist/` 仍被忽略 | `git check-ignore -v dist/` | 命中 | `.gitignore:121:dist/` |
| `build/` 仍被忽略 | `git check-ignore -v build/` | 命中 | `.gitignore:61:build/` |
| `.qoder/` 被忽略且未删除 | `git check-ignore -v .qoder/` | 命中 | `.gitignore:101:.qoder/`，磁盘目录仍在 |
| `.build/` 生成物仍被忽略 | `git check-ignore -v apps/mac/SoundBridgeApp/.build/` | 命中 | `.gitignore:42:.build/` |

diff 相对 HEAD 只有 5 行新增 + 1 行替换（`git diff -- .gitignore`，原文见 `build/p4-batch1c/evidence/c1c-g1-gitignore.log`），没有删除其他规则、没有扩大忽略范围、没有误伤正式源码或文档：

```diff
 .kiro/
+# Qoder's local repowiki cache; generated, never part of the release.
+.qoder/
@@ -117,7 +119,9 @@ temp/
 dist/
-release/
+# Root-level release output only. The unanchored `release/` also matched
+# docs/release/, which silently hid the 1.2.0 release checklist.
+/release/
```

**G-1 = PASS。**

---

## 4. G-2：Batch 1B 报告是否纳入

**建议纳入，且已按纳入标准处理完毕。** 纳入理由：1A 的 B-8 阻断项是自己修好的，而"已修复"的证据只存在于这份报告；不提交它，仓库里就只剩一个被误忽略的 Checklist，看不出修复过程。

如果纳入，它必须经过脱敏与哈希复核——这一点在 Batch 1B 是被明确拒绝的（1B §10.2 结论"保持原样，不脱敏"），本阶段推翻该结论并执行，原因见 §5.3。

| 项 | 值 |
|---|---|
| 原始 SHA-256 | `84210196d36ccfe08c62fbfd71367215e08d6f87dbf7ec16f66059c8d61a82dc` |
| 原始字节 | 54,877 |
| 修订后 SHA-256 | `c571fe51f2c011bc7f76c8dc43b588e94da431fc58d195f0be176df23f13e206` |
| 修订后字节 | 58,582 |
| 修订内容 | 6 处：仓库行改为 `/path/to/SoundBridge`；文首新增 Batch 1C 修订记录块；关键词表与命中表去掉字面用户名；§10.2 整节重写（含 13/16 矛盾的更正）；§15 G-3 行改为"已执行 / PARTIAL" |
| 原始记录是否仍可审计 | 是。原始文本与哈希在 `build/p4-batch1c/evidence/c1c-doc-hashes-original.tsv`，正文保留了"原文如何写、Batch 1C 如何改"的对照，不做静默覆盖 |
| 是否伪装成 140 条的一部分 | 否。类别记为 `D-1B-revision`，在 §2 与 §12 单列 |

三种版本的关系（任务书 §7 要求区分）：

1. **原始 Batch 1B 审计记录** —— 未被删除，内容以"被引用的原文 + 修订记录"形式共存；
2. **Batch 1C 对它的修订** —— 集中在文首 blockquote，逐条编号 1–5；
3. **最终准备提交的脱敏版本** —— 即当前工作区文件，哈希见上表与 §12.2。

**G-2 = 建议纳入（待你在 G-6 授权语句中一并确认）。**

---

## 5. G-3：脱敏状态（PASS）

### 5.1 实测数量（推翻旧报告的 13）

任务书要求"开始修改前必须重新搜索，不得假设 13 仍准确"。实测结果：

| 形态 | 处数 | 文档数 |
|---|---|---|
| 仓库绝对路径（含本地用户名） | **15** | 9 |
| 独立用户名（不在仓库路径内） | **3** | 2 |
| 合计 | 18 | 10（`POC_ERRATA.md` 只有用户名，无仓库路径） |

Batch 1B §10.2 写"10 份文档共 13 处"，但同表 10 行逐行相加是 16 —— 两个数字都不对。逐文件实测值见 §5.4。这个计数本身在 1B 报告里已就地更正（该报告 §10.2 现为 15 + 3）。**到本版为止，这 18 处已全部替换完成**（15 处见 §5.2，3 处见 §5.5）。

### 5.2 已执行的替换

- 替换内容：`$HOME/CodeGeeXProjects/SoundBridge` 形态的绝对路径 → `/path/to/SoundBridge`（脚本内是字面量；正文不复原，以免这份报告自己又带出一条家目录路径）
- 影响文档：9 份，共 15 处
- 范围：本节的 15 处只处理仓库路径内的用户名；路径之外的 3 处独立用户名由 §5.5 单独处理（同样按行定位，未做全仓盲替换）
- 命令语义与路径层级：保留（`git -C /path/to/SoundBridge status`、`git clone /path/to/SoundBridge /tmp/sb-1b-clean`）
- 脱敏后范围内残留：**0**（脚本对每份文件复查 `count == 0` 才写 PASS）
- `git diff --check`：退出码 0
- 原始文本：未提交、未复制进仓库；仅保留哈希与命中计数

### 5.3 为什么 1B 的"不脱敏"结论被推翻

1B 的理由是"改写 1A 报告正文会让它 §9.2 的哈希表失真"。实测这个前提不成立：

| 1A 报告的哈希表 | 覆盖范围 | 是否包含本次被脱敏的文档 | 结论 |
|---|---|---|---|
| §9.1（67 行） | 仅 tracked 文件的 HEAD→工作区对照 | 否。本次 9 份全部是 untracked | 不受影响 |
| §9.2（18 行） | 1A 本批次的 18 个文件 | 否。与本次 9 份零交集；且该表对本文件明确标注"内容变更后哈希随之变化，不固化" | 不受影响 |

因此不存在"改一处就要连带重算一串哈希"的依赖环，无需迭代。真正需要记账的只是这 9 份文件自身的原始/脱敏后哈希，见 §5.4。

### 5.4 新旧哈希对照

| 文件 | 原始 B | 原始 SHA-256（前 16） | 最终 B | 最终 SHA-256（前 16） | changed | verified | 本批次动作 |
|---|---|---|---|---|---|---|---|
| P4-Batch-1A-Source-Stabilization-Report.md | 74476 | `e4f247811a5f5452` | 74398 | `c47c9263a3d5789c` | yes | PASS | — |
| P3-Host-Restart-Entry-and-Recovery-Validation-Report.md | 54754 | `f3d5c74a13977472` | 54702 | `bc15d0402e776bc6` | yes | PASS | G-3：ls -l 属主列 → owner（等宽替换，列对齐不变） |
| P2-Batch-4-AudioRenderer-RT-Safety-Report.md | 48809 | `7b1817dbe5430512` | 48757 | `3d52526b327e40c7` | yes | PASS | — |
| P3-Final-Closure-Fix-Report.md | 45432 | `e540078962541c7b` | 45380 | `7d2a391b3c284f97` | yes | PASS | — |
| Batch-3-Closure-Fix.md | 27036 | `e02381e05d332925` | 26984 | `053ee74fbf659032` | yes | PASS | — |
| P4-Release-Readiness-Audit-Report.md | 46009 | `3fab1afdcac2711a` | 45983 | `96ff7766d2651e6e` | yes | PASS | — |
| PHASE2_IMPLEMENTATION_PLAN.md | 39896 | `f721b7de46072966` | 39870 | `44547fb2ddd4b6fc` | yes | PASS | — |
| P2-Batch-2-Default-Output-Governance-Report.md | 36573 | `e654649d64f9c61c` | 36547 | `9b0d6e7b842da4d6` | yes | PASS | — |
| P2-Batch-3-EQ-Mapping-Reliability-Report.md | 38481 | `80daccc98118387a` | 38455 | `7dc79adbca64a509` | yes | PASS | — |
| POC_ERRATA.md | 15920 | `6389daa90652b2a6` | 15914 | `010cb39a41d5968e` | yes | PASS | G-3：whoami 输出 → USER |
| P4-Batch-1B-Pre-Commit-Report.md | 54877 | `84210196d36ccfe0` | 58582 | `c571fe51f2c011bc` | yes | PASS | — |
| Documentation-Migration-Manifest.md | 25920 | `2c0b643df526d6a5` | 25965 | `32262a7c8280f0ab` | yes | PASS | G-7：3 处指向 E-2 的链接 → 行内代码 + 本地保留说明 |

完整 64 位哈希见 `build/p4-batch1c/evidence/final-document-hashes.tsv`（另含 `repo_path_residual` / `username_residual` / `action` 三列）；`verified` 列要求仓库路径与本地用户名残留**同时**为 0。

### 5.5 3 处独立用户名：本次已全部脱敏

上一版把这三处只列出、未修改（当时的任务书要求"不得擅自扩大修改范围"）。本次任务书 §2 明确把这三个位置列为可处理对象并指定了占位符，因此按最小改动执行：

| 文件:行 | 原形态 | 替换为 | 技术含义是否保留 |
|---|---|---|---|
| `docs/1.2.0/POC_ERRATA.md:225` | `whoami` 的输出被原样贴进文档 | `USER` | 保留：上一行 `ps -o user` 仍显示 `coreaudiod` 的属主是 `_coreaudiod`，"当前用户无权发信号"的论证不变 |
| `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md:99` | `ls -l` 的属主列 | `owner` | 保留：inode、权限位、链接数、组、大小、时间、`/tmp` 映射路径全部原样 |
| 同上 `:100` | 同上 | 同上 | 同上 |

三点补充：

- **不是全仓盲替换**：脚本按"行号 + 该行内容"双重断言定位，只改这 3 行；替换后对两份文件复查本地用户名计数为 0 才写盘。
- **等宽替换**：`P3-Host-Restart-….md` 的两行用 7 个空格补齐，10 字节 → 10 字节，所以该文件字节数不变（54,702 B），只有内容哈希变化——这样 `ls -l` 的各列仍然对齐，取证行保持可比。
- **`POC_ERRATA.md`**：15,920 → 15,914 B。

**G-3 = PASS**：候选集内 `home_path_hits = 0`、`username_hits = 0`（上一版分别为 0 与 3）。

遗留：`docs/P4-Batch-1B-Pre-Commit-Report.md` §10.2 与 §15 的表格里仍写着"独立用户名仅列出，未改 / PARTIAL"——那是 Batch 1C 中间态的记录，本次已把它变成历史陈述。为避免在本批次继续改动一份已审计的报告，我没有碰它；如果你要 1B 报告与最终状态一致，我可以在下一次授权里单独改那两格的措辞。

---

## 6. G-4：122 个中档文件归属（CONFIRMED）

### 6.1 档案怎么来的

122 = 140 − 18（1A §8.1 逐条记录的强档）。脚本从冻结的 140 条清单里减掉强档 18 条，并断言"18 条必须全部出现在清单里""140 − 18 = 122"，否则直接退出——防止集合划分错位。

对每个文件记录了：`path`、`status`、`sha256`、`scope`、`personal_experiment_suspected`、`review_result`、`reason`。全表：`build/p4-batch1c/evidence/g4-ownership-review.tsv`（122 行 + 表头）。

共 **122** 行（122 个文件），按职责分布：

| scope | 条数 |
|---|---|
| Host 生产代码 | 27 |
| 发布文档 | 27 |
| Host 测试 | 22 |
| App(Swift) 测试 | 14 |
| App(Swift) 生产代码 | 13 |
| Driver 生产代码 | 10 |
| 构建/发布工具 | 7 |
| 共享协议头 | 1 |
| 构建入口 | 1 |

`personal_experiment_suspected` 只有 **2** 个为 `yes`，都是 §5.5 已处理的那两个文档（命中项是终端输出里的用户名，不是代码改动）：

- `docs/1.2.0/POC_ERRATA.md`（status=??；采集时 15,920 B；文件名被 3 处提及；标记命中 local username，现已脱敏）
- `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md`（status=??；采集时 54,702 B；文件名被 5 处提及；标记命中 local username，现已脱敏）

其余 120 个：`debugPrint(` / `NSLog(` / `FIXME` / `HACK` / 硬编码回环地址 全部 0 命中，且文件名在全仓被引用或在 SwiftPM target 内自动纳入。

> 档案里的 `sha256` 是采集时的快照。上述两份文档在 Final Remediation 中又改过，当前哈希见 §5.4。档案没有就地重算——重算之后"当时审的是什么"就没有凭证了。

判据是客观信号，不是印象：

| 信号 | 方法 | 结果 |
|---|---|---|
| 个人路径 / 用户名 | 全文匹配家目录前缀、用户名、`localhost`、`127.0.0.1` | 2 个文件命中，均为 §5.5 已披露的文档 |
| 调试残留 | `debugPrint(`、`NSLog(`、`FIXME`、`HACK` | 0 命中 |
| 孤儿文件 | 文件名在全仓（含未跟踪）是否被其他文件提及 | 全部有引用或在 SwiftPM target 内自动纳入 |
| 状态一致性 | `git status -uall` 逐条对账 | 122 条全部存在且状态一致，0 缺失 |

### 6.2 你的确认（2026-11-21）

以上都是"没发现异常"，而"没发现异常"不等于"你授权了"——所以确认权在你。你已逐字回复：

> **"122 个中档文件均属于 SoundBridge 正式项目实施成果，不包含需要保留但不应提交的个人实验性修改。"**

因此：

- **G-4 = CONFIRMED**（2026-11-21）。这批文件不再需要逐条等签字，`approval_status` 从 `PENDING G-4` 变为 `CONFIRMED G-4 (2026-11-21)`。
- 覆盖范围是**归属**：这 122 个文件是项目实施产物、可以入库。它不代表"代码已通过编译/测试/真机验证"——§15 里那些限制仍然有效。
- 它**不构成 G-6 授权**：暂存与提交仍需 §13 的完整语句；在此之前索引保持为空，我不执行 `git add`。

---

## 7. G-5：E-2 与 `.qoder/` 的处置

| 对象 | 数量 | 本阶段处置 |
|---|---|---|
| E-2（研究/临时证据，不提交） | 14 | 原样保留在磁盘，保持 untracked；不删除、不改名、不入库 |
| `.qoder/`（本地 repowiki 缓存） | 75 个文件 | 原样保留，已被 `.gitignore:101` 忽略 |

提交后 `git status` 仍会有 14 条 untracked（E-2），这是预期状态，不是故障。**G-5 = 本阶段不处理。**

---

## 8. 安全检查：敏感信息、凭据、二进制

扫描对象是**最终候选集本身**（143 条），而不是"我记得改过哪些文件"——只有会变成公开内容的文件才值得扫。另对全仓做了一次窄口径的密钥扫描（tracked + untracked），防止下一次提交把残留带进来。

| 检查项 | 结果 | 判读 |
|---|---|---|
| 私钥 / GitHub token / OpenAI / AWS / Slack / Google 密钥模式 | 0 | **0 命中**，无需停止 |
| 令牌 / 口令类赋值形态 | 71 | 全部是 Swift/C++ 的**参数标签或变量名**（`token: UInt64`、`let token = launchToken` 等），无字面量凭据；其中 2 条来自本报告正文引用的这两个示例 |
| 邮箱地址 | 0 | 0 |
| 家目录绝对路径（本地用户目录前缀） | 0 | 0（脱敏后复查） |
| 本地用户名 | 0 | 0（Final Remediation 后复查；上一版为 §5.5 的 3 处） |
| 回环 / 内网地址 | 0 | 0 |
| `/tmp/` 临时路径 | 109 | 测试夹具与命令示例，属正常 |
| 二进制 / 大文件 | 0 / 0 | 无 `.pkg/.dmg/.app/.o/.a/.dylib/.zip`；最大 76,690 B |

**判读原则**（按任务书 §8）：命中 ≠ 泄露，逐条看上下文；合法的 Secrets 引用、测试占位符、迁移说明里的历史值都不删。本次**没有发现任何真实凭据**，因此不存在"发现密钥必须立即停止"的情形。

二进制与体积：候选集内 0 个二进制扩展名文件（`.pkg/.dmg/.app/.o/.a/.dylib/.zip`），最大文件 `packages/driver/src/Plugin.cpp` = 76,690 字节，无 `> 100 KB`、无 `> 1 MB` 条目。

---

## 9. Markdown 链接检查

### 9.1 方法、指标与判据

与 Batch 1B 的方法差异：这次先**剥掉围栏代码块和行内代码**再解析链接，避免把 Swift 的 `[Float](repeating:count:)` 当成链接（1B 那 1 条误报就是这么来的）。

| 指标 | 值 |
|---|---|
| 受检 Markdown 文件 | 35 |
| 相对链接总数 | 140 |
| 真实断链 | **0** |
| 行内代码误报（已跳过） | 4 |
| 指向目录的链接（按目录内是否有提交文件判定） | 7 |
| **指向未提交文件的链接** | **0** |
| 外部链接（未联网验证，不计入断链） | 3 |

任务书 §9 点名的六条互引链（README / RELEASE_NOTES / INSTALLATION_GUIDE / Known-Limitations / Release Checklist / Batch 1A）全部可解析。本次换用"提交集合"判据复查——目标是否也在 143 条内——指向未提交文件的链接已从 3 条降到 **0**（G-7，见 §9.2）；Batch 1B 只用"磁盘存在性"判据，因此漏掉了这个维度。

外部链接（http/https）只计数、不联网验证，不计入本地断链；指向 `build/p4-batch1c/evidence/` 的引用一律用行内代码写，不写成 Markdown 链接，避免提交后成为断链。

### 9.2 G-7：3 条指向 E-2 材料的链接已按方案 B 修复

上一版的检查发现：`docs/Documentation-Migration-Manifest.md` 有 3 条链接指向 E-2（有意不提交）的文件。它们在磁盘上可解析，所以 1B 式"存在性"检查是绿的；但提交后在新 clone 里**必然是 3 个 404**。本次按任务书 §3 做最小修改，即上一版的选项 B：

| 位置 | 原写法 | 现写法 |
|---|---|---|
| `:6` | 指向 `manifests/Research-Directory-Inventory.sha256` 的 Markdown 链接 | 行内代码，并加一句"该清单保留在本地历史审计目录，不随正式仓库提交" |
| `:94` | 同一条链接 | 行内代码，并注明"该清单本地保留，不随正式仓库提交" |
| `:392` | 指向 `Research-Directory-Retirement-Report.md` 的 Markdown 链接 | 行内代码，并注明"该报告本地保留，不随正式仓库提交" |

约束与结果：

- 文件名、历史证据说明、§2.3 / §6 的交叉引用全部保留；只把"可点击但会 404"的链接降级为行内代码。
- 没有恢复 `SoundBridge-Research/`，没有把任何 E-2 文件加进 allowlist——路径数仍是 **143**。
- 复查该文档：已无 `](manifests/` 与 `](Research-Directory-Retirement-Report.md)` 形态；全量复查 `real_broken = 0`、`links_to_uncommitted_files = 0`。
- 这类"引用本地保留材料"的写法此前已在 `build/` 相关引用上用过（一律行内代码），本次是把同一约定用到 E-2 材料上。

### 9.3 额外做了一次表格完整性检查（旧报告没做）

链接可解析不代表表格能渲染：某行多一个或少一个 `|`，整张表会静默错位，而链接检查看不出来。因此对 35 份 md 逐行核对了单元格数与表头是否一致（转义管道与行内代码里的管道不计入）：**483 个表格、0 处列数不一致**。产物：`build/p4-batch1c/evidence/md-table-check.txt`。

---

## 10. 版本与协议（只读检查，未触碰产物）

```
  PASS  VERSION (repository file) = 1.2.0
  PASS  apps/mac/SoundBridgeApp/Info.plist CFBundleShortVersionString = 1.2.0
  PASS  apps/mac/SoundBridgeApp/Info.plist CFBundleVersion = 1.2.0
  PASS  packages/driver/Info.plist CFBundleShortVersionString = 1.2.0
  PASS  packages/driver/Info.plist CFBundleVersion = 1.2.0
  PASS  packages/driver/VERSION = 1.2.0
  PASS  packages/driver/CMakeLists.txt project() VERSION = 1.2.0
  PASS  packages/host/Info.plist CFBundleShortVersionString = 1.2.0
  PASS  packages/host/Info.plist CFBundleVersion = 1.2.0
  PASS  RF_AUDIO_PROTOCOL_VERSION = 0x00020200 (131584)
  PASS  packages/driver/Info.plist SBAudioProtocolVersion = 131584
VERSION_SOURCES_CHECKED=11
VERSION_SOURCES_FAILED=0
VERSION_CONSISTENCY=PASS
Protocol header: single source verified (4 files identical)
protocol version : 0x00020200
header size      : 320 bytes
sizeof(struct)   : 320 bytes
Driver plist:   OK (SBAudioProtocolVersion=131584)
```

结论：`VERSION = 1.2.0`、协议 `0x00020200` = 131584、Header 320 字节、四份共享头逐字节一致、`VERSION_SOURCES_FAILED = 0`。历史协议值只出现在 `docs/RELEASE_NOTES.md` 的迁移说明正文里；`1.1.1` 不作为当前发布目标出现。Bundle Version / Build Number / ABI / Deployment Target 均未在本阶段被修改。

---

## 11. 删除项 `DriverUpdateWindow.swift`

唯一删除项，来自 1A §8.1 第 6 行（该窗口的唯一功能是已被删除的安装事务）。四条确认：

| 确认项 | 证据 |
|---|---|
| 文件确实已删除 | `git status` 中为 `D`，工作区不存在该路径 |
| 新代码不再引用 | 全仓按文件名与类型名搜索：0 处存活引用 |
| 构建与测试不依赖 | 不在 `Package.swift` 的 path 列表、不在任何 `CMakeLists.txt`、不在任何测试 target 中 |
| 与产品路径迁移一致 | 安装入口已迁移为只读检测 + PKG 引导（1A P1-1），窗口失去存在理由 |

`git add --pathspec-from-file` 对删除项的处理需要显式路径——这正是 allowlist 里保留这一行的原因：**不靠 `git add -A` 隐式包含删除**。

---

## 12. 最终 pathspec 与逐路径哈希

### 12.1 两个冻结产物

| 文件 | 用途 | 行数 |
|---|---|---|
| `build/p4-batch1c/evidence/final-add-list.txt` | 唯一暂存依据（`git add --pathspec-from-file=...`） | 143（`sort -u` 后仍 143） |
| `build/p4-batch1c/evidence/final-allowlist.tsv` | 逐路径审计台账（8 列：category / git_status / path / sha256 / bytes / inclusion_reason / user_approval_required / approval_status） | 143 + 表头 |

`final-add-list.txt` 已由脚本断言：无目录、无通配符、无绝对路径、无重复、无 `build/`/`dist/`/`.qoder/` 前缀、每条都在 `git status` 中出现且与磁盘状态一致（删除项除外）。

### 12.2 逐路径 SHA-256 与大小

本表由脚本从运行时磁盘内容机械生成，不是手抄。**本文件自身那一行的字节与哈希都以 `—` 标注**：它是被编辑的对象，正文里写死的任何数字都会在下一次编辑后失效；其真实大小与哈希由独立 manifest `build/p4-batch1c/evidence/final-allowlist.tsv` 记录，形成可终止的哈希依赖（报告 → manifest → 无自引用）。

| # | 组 | 状态 | 字节 | SHA-256 | 路径 |
|---|---|---|---|---|---|
| # | 组 | 状态 | 字节 | SHA-256 | 路径 |
|---|---|---|---|---|---|
| 1 | A | `M` | 39802 | `b83b22e45a60e25447cc5f8a1f276ce6bbd1471663a7fa6b9488cc6144f2b5ec` | `apps/mac/SoundBridgeApp/Sources/App/SoundBridgeApp.swift` |
| 2 | A | `M` | 69590 | `0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee` | `apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h` |
| 3 | A | `M` | 8112 | `26ffaac6676fa624c6d056e730b0a393ddb5fce4568ff8fa7ddb1d83b6aec6c9` | `apps/mac/SoundBridgeApp/Sources/Models/HostLifecycleReport.swift` |
| 4 | A | `M` | 3138 | `6d3ec47923beb1ea0aa714d4e85a539e489563870e92ae912c8351fc0d01e662` | `apps/mac/SoundBridgeApp/Sources/Models/HostStatusModel.swift` |
| 5 | A | `M` | 16441 | `dfaf9653b0721c67a7ae26f0c7ec577b7f5ce0517da8a65ae5825eb1b25ccbff` | `apps/mac/SoundBridgeApp/Sources/Onboarding/OnboardingView.swift` |
| 6 | A | `??` | 3629 | `10fcc7a15e8eee0c238dbfb189f71581ca09d91ec5d8133dca79e89ed115d01e` | `apps/mac/SoundBridgeApp/Sources/Services/DefaultOutputSwitch.swift` |
| 7 | A | `??` | 4051 | `eb94fb88464a88f3a5e0e8bea6a2a60f51eb75be10f93e1e0378198f466eef42` | `apps/mac/SoundBridgeApp/Sources/Services/DriverInstallGuide.swift` |
| 8 | A | `M` | 3707 | `8d8c9de83a128d77c65fe4f05dc9ee7efb140f07f0c19a61d11ad7d428acbc64` | `apps/mac/SoundBridgeApp/Sources/Services/DriverInstaller.swift` |
| 9 | A | `??` | 4323 | `d0ffa6ae0dadd2ab3944967cfdc3b430ebc1a6b4b8600ac1254bccb279afd774` | `apps/mac/SoundBridgeApp/Sources/Services/DriverUninstallPolicy.swift` |
| 10 | A | `??` | 3052 | `915d72583971f8dbc26b7be695a2096cd92399f65281074dd1c5b5b7e68b5abe` | `apps/mac/SoundBridgeApp/Sources/Services/DriverUninstaller.swift` |
| 11 | A | `M` | 15500 | `dff7626108298f031e0d6b18d036e5b354cb629269bcc10e345f9551d8e9d315` | `apps/mac/SoundBridgeApp/Sources/Services/DriverVersionGate.swift` |
| 12 | A | `M` | 19740 | `ba434220dcbe2323e25667f4ec590f139633f6ec1cb57f96c37f1154cebdc044` | `apps/mac/SoundBridgeApp/Sources/Services/EQController.swift` |
| 13 | A | `??` | 2360 | `44ebb9c6b07b1aa92762cbb38c2591b99a08db6c4c0aed6074edb9f8abe354df` | `apps/mac/SoundBridgeApp/Sources/Services/EQService.swift` |
| 14 | A | `M` | 5960 | `ae235f0fb4544367f82c986476d3dc75d036e1a86294654f0ebefa13fa71b98a` | `apps/mac/SoundBridgeApp/Sources/Services/HostInstanceProbe.swift` |
| 15 | A | `??` | 3495 | `7235599f13151f4cf3518591aa05eb557c8f52fd23f2a4b315ecb2f026cc5792` | `apps/mac/SoundBridgeApp/Sources/Services/HostRestartEntry.swift` |
| 16 | A | `??` | 27231 | `3c7fb9f5a81fdc4762a90be273feb30dfdaa4117ee4c5c597a1f78e8b7de7838` | `apps/mac/SoundBridgeApp/Sources/Services/HostSupervisor.swift` |
| 17 | A | `M` | 15413 | `81efce05f4e4758e964bed325d17b3f9d5e0d199ee585f783b4f9913950f4247` | `apps/mac/SoundBridgeApp/Sources/Services/IPCController.swift` |
| 18 | A | `??` | 28466 | `bdecbb3b1541fb4f387d1d67d5108fea99df0b890565a3a99e99f26e1924f7d1` | `apps/mac/SoundBridgeApp/Sources/Services/SharedMemoryMappingManager.swift` |
| 19 | A | `M` | 25312 | `1367646438cc8509bdb93203bf6f94514b7d210844a165f68c3e33b88be083b0` | `apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift` |
| 20 | A | `D` | 0 | —（删除项） | `apps/mac/SoundBridgeApp/Sources/Views/DriverUpdateWindow.swift` |
| 21 | A | `M` | 21981 | `2f39998e2ebae8623a897931ae6d0eb2f3b2105d602686432a399a290c45f4d3` | `apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift` |
| 22 | A | `M` | 1449 | `275eb53aadcd34069b07aae4692bdbfb501cb2759328b8aca3560e536631cbb9` | `packages/driver/Info.plist` |
| 23 | A | `M` | 69590 | `0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee` | `packages/driver/include/RFSharedAudio.h` |
| 24 | A | `??` | 14334 | `ab92ec32508a7b51c33dc9c3da5d0360783ba85ef83b7a46bd880916f1e54fdf` | `packages/driver/src/ControlProtocol.hpp` |
| 25 | A | `??` | 15039 | `8fdc46a1e49a9ea2e3c2e71d1b38f314ca6fb37c8101dc7e9f7e4c381f282f06` | `packages/driver/src/MappingRetirement.hpp` |
| 26 | A | `M` | 76690 | `8f31748c5e6500aa9f81704fb3ad6416d06fbe9915f4c1141b5e4139e79b931d` | `packages/driver/src/Plugin.cpp` |
| 27 | A | `??` | 2471 | `e712c25c14008fd9dd147dc9ddbb867efdc27fbd18cd9234431f4b0b4d30eb6a` | `packages/driver/src/ProducerToken.hpp` |
| 28 | A | `??` | 13556 | `6d7f2eb941621ce5d642f29312a262f6d786058daf9f063a7120bda6d40dac2e` | `packages/host/Sources/CSoundBridgeAudio/RFRealtimeTelemetry.c` |
| 29 | A | `??` | 12941 | `0e5476fa4edad35dea8907cf67f07a2cd3e2e36700adfbd2a350485e776f897c` | `packages/host/Sources/CSoundBridgeAudio/include/RFRealtimeTelemetry.h` |
| 30 | A | `M` | 69590 | `0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee` | `packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h` |
| 31 | A | `M` | 143 | `ff214effcd5c480f7db7f5d75dc08806227d37f88de862be66d7e69d65d3c39b` | `packages/host/Sources/CSoundBridgeAudio/include/module.modulemap` |
| 32 | A | `M` | 581 | `bb0581f94fafafda6cc3959d162e5c0847c8f09dfc14b155752eae75c93b3ec6` | `packages/host/Sources/CSoundBridgeAudio/shim.c` |
| 33 | A | `M` | 15208 | `9adb7d75a03559f7ab56f40c9c49c05bbca4d2a1fe0cb0a6a71b44ad4df08f3f` | `packages/host/Sources/SoundBridgeHost/Audio/AudioEngine.swift` |
| 34 | A | `M` | 33547 | `8403000b0f85c467f1ff7ad6ad8fe6311a2c919a2b036e0c750e81195514cb4a` | `packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift` |
| 35 | A | `M` | 5281 | `fd7052a5b3944a3038874784df91df99694ad019c2f9b2d15de69a49360a310a` | `packages/host/Sources/SoundBridgeHost/Constants.swift` |
| 36 | A | `??` | 6170 | `6167d57f45867fbd41f36f98f4edebfd77c00b194b8a697c3d5201a3c53012ec` | `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputHAL.swift` |
| 37 | A | `??` | 4822 | `7623e64172064b1296975250855cb66ef039d9d89cca74ebfacbaa88f4f2397e` | `packages/host/Sources/SoundBridgeHost/Devices/DefaultOutputOwnership.swift` |
| 38 | A | `M` | 19982 | `7899a9484a2dd628484a5888b3584ac3cbc67e476ff54bec482385732bf439ee` | `packages/host/Sources/SoundBridgeHost/Devices/DeviceDiscovery.swift` |
| 39 | A | `M` | 30358 | `e986832f721dc9e387e861721ea64073d185b9e5f387bed1ac460d5b15886d25` | `packages/host/Sources/SoundBridgeHost/Devices/DeviceMonitor.swift` |
| 40 | A | `M` | 10882 | `fb9e6c57513f73f398f521759b34924aec1bc83844e7fca78f7456edb3f931e0` | `packages/host/Sources/SoundBridgeHost/Devices/DeviceRegistry.swift` |
| 41 | A | `M` | 37071 | `614f4b9310ba823c4ab4a9e09d4103f539585c847cd986d8ba9f8ca5a9190cc7` | `packages/host/Sources/SoundBridgeHost/Devices/ProxyDeviceManager.swift` |
| 42 | A | `M` | 3470 | `ba6ca8970eab495f7250ba902386869191d1b07d36e06eccfda01d6686f453d9` | `packages/host/Sources/SoundBridgeHost/Devices/SleepWakeMonitor.swift` |
| 43 | A | `??` | 13115 | `ea3721e5c8f2fc07f21e68d8b2333e27b73ddf7a059001f12bfdb4fd23fed4a7` | `packages/host/Sources/SoundBridgeHost/Lifecycle/CoreAudioRecovery.swift` |
| 44 | A | `??` | 7080 | `706fc443ffed234252828cb5ddcab21d4b926ca57dcf8d46b238a590c97167e9` | `packages/host/Sources/SoundBridgeHost/Lifecycle/CoreAudioRestartDetector.swift` |
| 45 | A | `M` | 17289 | `9e92d01fcd00d8d4c3f39b84db35e0f677c09db3fd8c52af8366ee985d8a6f10` | `packages/host/Sources/SoundBridgeHost/Lifecycle/DriverLifecycle.swift` |
| 46 | A | `M` | 14086 | `998c939e3e085c4d732d035f5fc13d0158914dd5c891bfc10a011e1a24e74f88` | `packages/host/Sources/SoundBridgeHost/Lifecycle/HostInstanceLock.swift` |
| 47 | A | `M` | 5829 | `be48b668e9f092539d6addb5d0ca133c5a2334c2d345c87471f6e45ae29b5baa` | `packages/host/Sources/SoundBridgeHost/Lifecycle/HostLifecycleReporter.swift` |
| 48 | A | `??` | 2683 | `dd8fa6cc9ac1301a9280b818dbf093070d2bf8c50b01846d242df34bf55eed07` | `packages/host/Sources/SoundBridgeHost/Lifecycle/SharedMemoryReportPolicy.swift` |
| 49 | A | `M` | 4842 | `d37578b6bd86f9c21796e0fde30381720bbd2c683a4a921a2656beb36b96dfc6` | `packages/host/Sources/SoundBridgeHost/Lifecycle/ShutdownSequence.swift` |
| 50 | A | `M` | 37506 | `6a75fbdb53258a2cc21c6e095354d681efd3b5a9e6b5b90f9697493451df4c77` | `packages/host/Sources/SoundBridgeHost/Memory/SharedMemoryManager.swift` |
| 51 | A | `M` | 4144 | `f691def8ed6088c40f5857efc3586132b2ec10f0beea9ba2d43dfb42103ad037` | `packages/host/Sources/SoundBridgeHost/Services/VolumePersistence.swift` |
| 52 | A | `??` | 7413 | `10e7e11097bfb79c392c6ba5ea0cc73e4ba7b76585b8a8a42ba224f99413c800` | `packages/host/Sources/SoundBridgeHost/Utilities/AtomicFileWriter.swift` |
| 53 | A | `M` | 2325 | `2123796fc088d267bcbf06794fd1a440177d94bd98b00c40d6d67c42b28c6ce3` | `packages/host/Sources/SoundBridgeHost/Utilities/PathManager.swift` |
| 54 | A | `M` | 48627 | `b27a3a7f5221a76e49ca0c826769d5cf7a513541a529ad9d8f55cb2352b935e2` | `packages/host/Sources/SoundBridgeHost/main.swift` |
| 55 | A | `M` | 69590 | `0f415450437485c58895861c22c62427e40ad656b844cfc0570522d430c060ee` | `packages/shared/include/RFSharedAudio.h` |
| 56 | B | `??` | 10426 | `31c70098339e7dc8bde31d1a763662752c2fb19c7940ae0e3eef99806b096dd3` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DefaultOutputSwitchTests.swift` |
| 57 | B | `M` | 11908 | `8e55824438ef532fbfbaba17430a54e2927ffccf0491d218152693bddfa03d57` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverCompatibilityNoticeTests.swift` |
| 58 | B | `M` | 13960 | `b81cc1595e8072a3c45d5f4c0bba4172f2a8cda7d723a05f338f6faa3a2f9e38` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallBoundaryTests.swift` |
| 59 | B | `M` | 5156 | `dd7950e01f0d6572dfcbdf7a5d8cc5c8ebf22e1f6c3781e6e44e0f10e022f312` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverInstallIntentTests.swift` |
| 60 | B | `M` | 11892 | `7c8d81866216140144df675c9825da46cfb8f1780084065f01d4e482b154dc86` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverRecoveryMatrixTests.swift` |
| 61 | B | `M` | 19974 | `f81e4c559d31b82cdf50daf6dd68aa78346a11a9c141172644d2867920e4a213` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/DriverVersionGateTests.swift` |
| 62 | B | `??` | 20773 | `69bc8dfb6e0ba19d247b317f9d7fb43b98c4de11f45e6627d8bde6e30dc151c2` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQLifecycleOwnershipTests.swift` |
| 63 | B | `??` | 10883 | `f7c64078a7add00ec97785f3a8b012716506fa5cf0b6128517b531d0ec594791` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/EQRecoveryTests.swift` |
| 64 | B | `M` | 7758 | `59ff5e080d8374e61b950be3ac83e68e65e6a59a1c855edd5b8523a39bf60f93` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostInstanceProbeTests.swift` |
| 65 | B | `??` | 8254 | `ce9f48c2ced0c6ae52f49fa5f4f1d0e8c7f05c57e0dd1088a586ec20b91eb160` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRestartEntryTests.swift` |
| 66 | B | `M` | 24124 | `e3b96cb251343f9285fb046474f64e233f0b97af39e48fa95e3c8afa3878721b` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostRunStateTests.swift` |
| 67 | B | `??` | 18537 | `3d3a8656b9dc02c74f42df6807e0aad0d63c3331e4ff2252f81c34cee9824b37` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/HostSupervisorTests.swift` |
| 68 | B | `??` | 25678 | `ae52eb8796e37431d9703d9b2923bc080853f9fc06e2c05cf8ed4c8b26b1d71e` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingConcurrencyTests.swift` |
| 69 | B | `??` | 19691 | `1bd1bf3210b6d518d6ac7f24ad30b26c8d960d4c6404dbb0f8009087a6945369` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingManagerTests.swift` |
| 70 | B | `??` | 12112 | `b63b2734aa53cf29b97d981b333ae84c2af9c041fa620af95cd95b69a152a2c8` | `apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/SharedMemoryMappingUnmapThreadTests.swift` |
| 71 | B | `??` | 15008 | `7b1d6fc67b9a61fe972d2dce95f5bf13135fd82db3d0b4402f85b8f208f3fa37` | `packages/driver/tests/ControlProtocolTests.cpp` |
| 72 | B | `??` | 34549 | `1c3eff4c5e9fb0655d1942afe01a5c08c1dd2048420b943845e7a2bd4a6e2bb6` | `packages/driver/tests/MappingRetirementTests.cpp` |
| 73 | B | `??` | 6140 | `7cb59d3f8665c1a8a9b72db789ff4a66095877e4998f086f4bc0f52b0b0a4bd9` | `packages/driver/tests/ProducerTokenTests.cpp` |
| 74 | B | `??` | 21465 | `e61c594e4d94cd78e388b31c414729a42cd362ddc960ac2ea764c2d00b97e022` | `packages/host/Tests/SoundBridgeHostTests/AdmissionCrossProcessTests.swift` |
| 75 | B | `??` | 23666 | `c98ef3876c41fe6e3cdda0da3cec543bf3305da7d344709f345346a20cb17ca1` | `packages/host/Tests/SoundBridgeHostTests/AdmissionGatewayTests.swift` |
| 76 | B | `??` | 21508 | `80069642dafa75615904eb137349ff5da51fd0ed60503f15a2897782e84e0542` | `packages/host/Tests/SoundBridgeHostTests/AtomicFileWriterTests.swift` |
| 77 | B | `M` | 22976 | `ca3925f4fe32e52a285876510d8b56c6230939034a35983cdc41b89bbea5d4c8` | `packages/host/Tests/SoundBridgeHostTests/AtomicMemoryModelTests.swift` |
| 78 | B | `??` | 24512 | `f81b368821753f455bf607add7c10358664e9df475c94c4f734b3174e2bcce57` | `packages/host/Tests/SoundBridgeHostTests/AudioRendererRTSafetyTests.swift` |
| 79 | B | `??` | 43752 | `abdedecf34efe881d9ea0a2044a39867d2a706ba77489c7ed9cb6ea678afd0a6` | `packages/host/Tests/SoundBridgeHostTests/CoreAudioRestartRecoveryTests.swift` |
| 80 | B | `??` | 26526 | `7f92d2b346c1f49d648d953ef22e09b4f4c2dd5557872d9cfd15cef56a49741b` | `packages/host/Tests/SoundBridgeHostTests/DefaultOutputGovernanceTests.swift` |
| 81 | B | `??` | 9470 | `1c84a55fdc707d0a92482c3f3d3098e237eda4cda421ffc077496119c116e6af` | `packages/host/Tests/SoundBridgeHostTests/DefaultOutputTrackingTests.swift` |
| 82 | B | `M` | 14739 | `04a6064e447127fd1741d45d1a27a114f1dc5c041cb35845fc288d8a08f61c71` | `packages/host/Tests/SoundBridgeHostTests/DegradedLifecycleTests.swift` |
| 83 | B | `M` | 17456 | `e7a1ce58ab74ee3db91ff8f5ad487b1349e760b4ada759f7bb02d62e3ebb1646` | `packages/host/Tests/SoundBridgeHostTests/DriverHeartbeatCrossProcessTests.swift` |
| 84 | B | `??` | 6240 | `96d9ee3f8a5ea9db20a9ce8e66cda0b1e49937c86141a9d1e7b554b203a623eb` | `packages/host/Tests/SoundBridgeHostTests/GracefulShutdownTests.swift` |
| 85 | B | `M` | 28781 | `2efcfa57f5eabcbbdd34587c6df09008e6dcb2d60dfb8c002898c3698e0eeffc` | `packages/host/Tests/SoundBridgeHostTests/HostInstanceLockTests.swift` |
| 86 | B | `??` | 12929 | `7b269381fa28c6de797a0e1be14e8cc6f645eb81a0a1b517ac04d7ce679068dc` | `packages/host/Tests/SoundBridgeHostTests/LifecycleLoggingTests.swift` |
| 87 | B | `??` | 9302 | `8629cc598576c686fa95473b4b72fe1b4dedff37a356879211547c7f20157368` | `packages/host/Tests/SoundBridgeHostTests/MappingIncarnationTests.swift` |
| 88 | B | `??` | 25215 | `21bc26d476117f2a92e24f15a3955925ee5c520df70615c398f17bb8bc4461fb` | `packages/host/Tests/SoundBridgeHostTests/RTObservabilityTests.swift` |
| 89 | B | `??` | 22356 | `4ef0a955765b246981900125c63341c2402d62a465732f7393fa4517db654701` | `packages/host/Tests/SoundBridgeHostTests/RingBufferContractTests.swift` |
| 90 | B | `M` | 19747 | `5f5d79760b67815e61ed7113c2fe57b2435766a4924201f97dde17ceb5f9db19` | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryFileSystemTests.swift` |
| 91 | B | `M` | 19367 | `13ef851a3f151d083cea2cbbd4f263d797c7fbb940333eb056dbb9beb7d59af3` | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryMultiProcessTests.swift` |
| 92 | B | `M` | 13717 | `cca305a69e9c73fa62c295466981e20018f1ea93069297e15e9fa38335bfee64` | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryProtocolTests.swift` |
| 93 | B | `M` | 15960 | `3bd6bc787227b879fbafbb9e2e90085e362279ea67d989491a764813a06e9f7b` | `packages/host/Tests/SoundBridgeHostTests/SharedMemoryRecoveryTests.swift` |
| 94 | B | `M` | 5624 | `2c8bdd2c938e5aab52478cd34a3bf2ce71dae4f17143a924c5ca5ba8e1600c13` | `packages/host/Tests/SoundBridgeHostTests/StartupFailureCleanupTests.swift` |
| 95 | B | `M` | 12698 | `c6aa5bcd68db223635600f028d5b0aa7e0f589502255326ec76401e5a4be3094` | `packages/host/Tests/SoundBridgeHostTests/VolumeStateTests.swift` |
| 96 | C | `M` | 20348 | `8151b25d3feaf2d10a5b35e815bd1e36372286d49c0e89fdac25430b1e3bec6a` | `Makefile` |
| 97 | C | `M` | 4515 | `8c31f29d788a37faf6dce937ba1f5869ba24cda45be9d1fcd70f9185c889a2e9` | `packages/driver/CMakeLists.txt` |
| 98 | C | `M` | 25650 | `d64626ad7984c8c79e6ec20be712b7e03ddbaabfd1184e7c6cd84607e1cf7a45` | `tools/build_installer_pkg.sh` |
| 99 | C | `M` | 8760 | `95058fc0e43bcb1adc8b4ee7daf8c38d3b2364917367e3576165f2964e708658` | `tools/check_protocol_layout.sh` |
| 100 | C | `M` | 54724 | `3ce78a42855d9ab5359f2cb615739b0b56d8cad320071c8048a29c3c4217efd8` | `tools/test_release_payload.sh` |
| 101 | C | `??` | 6620 | `f415225ac1b04aa8c1eda58dc5cc45b369f8e88c38eb2842fca822f124007d85` | `tools/test_support/make_payload_fixture.sh` |
| 102 | C | `M` | 5457 | `5c2e5363167b5d968a70b62bd72b9724f72438a55c7e063271dff1ced99ea597` | `tools/uninstall_driver.sh` |
| 103 | C | `M` | 29522 | `a95d8e1e720b8c2befb80d31b0a6d12e24e887b9cfc8bcbbbcda0c6483271ae4` | `tools/verify_dmg_contents.sh` |
| 104 | C | `M` | 24561 | `275c293371009fbce4c0a693dcae6a1d3978d6676909c26f7b626178d7b680c3` | `tools/verify_installer_pkg.sh` |
| 105 | C | `M` | 26186 | `05d4018e2bdafc18415e371a080dd3c42bee17d855e23197bedfef55cf3f67f7` | `tools/verify_pkg_contents.sh` |
| 106 | C | `M` | 12330 | `849cf740bbf9dd30d633d58d4ed9fd8768f5450e1fa731014a3591fb71bc1912` | `tools/verify_release_bundle.sh` |
| 107 | C | `M` | 18550 | `b0acaf9e74a6d6c8ba8148a54e605778816f11a27b439e91117ae88088fad5e3` | `tools/verify_release_payload.sh` |
| 108 | D | `M` | 15264 | `73b9e3787bc519baac6c3dec481107945f37b12f1a7674e60309fc5124f5a9f5` | `README.md` |
| 109 | D | `??` | 39870 | `44547fb2ddd4b6fc9dde5ac7f4c6fdce4514077e6cf316c9713cee975b956aae` | `docs/1.2.0/PHASE2_IMPLEMENTATION_PLAN.md` |
| 110 | D | `??` | 17043 | `21cf8771cc9edeb7842bffda364ed3aba54bd5c8fd580108d45cd3d309403932` | `docs/1.2.0/PHASE2_1_1_AND_2_1_2_REPORT.md` |
| 111 | D | `??` | 36715 | `ff2dd2f58d0b7061fa470d0398e351ce1ee6bc4832286d6c6b77de413656845a` | `docs/1.2.0/PHASE2_1_3_RELEASE_READINESS_REPORT.md` |
| 112 | D | `??` | 38486 | `537cb9749ee1d787806b09c055b61ab0347ea4a609a23f5ece836d166686f723` | `docs/1.2.0/PHASE2_1_4_HOST_LIFECYCLE_REPORT.md` |
| 113 | D | `??` | 53586 | `636f7d7c4a2968069dde4ce6574a2351fedbc2126de3e546105d5c6f97918c01` | `docs/1.2.0/PHASE2_1_5_FINAL_RELIABILITY_AUDIT.md` |
| 114 | D | `??` | 36792 | `18142eb48c868f6f541f230323170fdf86c59ea4f1959a728fe3efbc5deee621` | `docs/1.2.0/PHASE2_1_REPORT.md` |
| 115 | D | `??` | 15914 | `010cb39a41d5968e03afb6635887b1a4f3fa5db18edfd358d9a18c74cebe168b` | `docs/1.2.0/POC_ERRATA.md` |
| 116 | D | `??` | 25965 | `32262a7c8280f0abd2a935555d0b10b7fbbfcc4597c159665470a4a03e207dc9` | `docs/Documentation-Migration-Manifest.md` |
| 117 | D | `M` | 15025 | `91adce858cc0d087152764b9ac3a61c7ec254f4604f8313ea6f097ce01daf74e` | `docs/INSTALLATION_GUIDE.md` |
| 118 | D | `??` | 36547 | `9b0d6e7b842da4d6646f15f30cc787e6b9ede8c6d98a8b6e1968af3ac0eafec0` | `docs/P2-Batch-2-Default-Output-Governance-Report.md` |
| 119 | D | `??` | 38455 | `7dc79adbca64a5094d80e38c5e9e4a5ccb540a8204efec2a952908dbf3b5b097` | `docs/P2-Batch-3-EQ-Mapping-Reliability-Report.md` |
| 120 | D | `??` | 48757 | `3d52526b327e40c70110fbd7180ccd66fa9eacee3df98eb03c87bf4bb066c6b1` | `docs/P2-Batch-4-AudioRenderer-RT-Safety-Report.md` |
| 121 | D | `??` | 45380 | `7d2a391b3c284f9799a052c2f7d8def0552db33bb8f142284acd262c425169df` | `docs/P3-Final-Closure-Fix-Report.md` |
| 122 | D | `??` | 54702 | `bc15d0402e776bc6063e7a5dd64f1fcbd306d03c5ad54e6a71469fd569a3bd23` | `docs/P3-Host-Restart-Entry-and-Recovery-Validation-Report.md` |
| 123 | D | `??` | 74398 | `c47c9263a3d5789c07731b81983c8d9874582fa8f8450820dd70822c3b8203d4` | `docs/P4-Batch-1A-Source-Stabilization-Report.md` |
| 124 | D | `??` | 45983 | `96ff7766d2651e6e9770abcb2a0530697ac3c8f4a1f64882dad3f7e9549915c4` | `docs/P4-Release-Readiness-Audit-Report.md` |
| 125 | D | `??` | 11801 | `0f79d2663c6a7f20a2f25be996c13dd009311e4cc439f87500859fdef257a8c9` | `docs/README.md` |
| 126 | D | `M` | 12691 | `83d99d719097c359a8390a57d316cd549c1b8b2ce785b177a637b04704eb9bb9` | `docs/RELEASE_NOTES.md` |
| 127 | D | `??` | 18207 | `2a2f075be24239f516c352e6421f0b4988c9163b4d6624cd0f851cdba3a84f19` | `docs/architecture/SoundBridge-1.2.0-Architecture.md` |
| 128 | D | `??` | 9731 | `60d608adad64c91ce45778ccbfb1a7261d34f21110f957b38773976c7d363423` | `docs/engineering/Admission-Ownership.md` |
| 129 | D | `??` | 7913 | `18a42365e67bc970df75443380870a5797116ac4c006f3a9543ad77e26ce9cea` | `docs/engineering/Callback-Lifecycle.md` |
| 130 | D | `??` | 16183 | `cc43f2355a97fb7d9ccada1fd2196c282c53acdb72643fc092cbc5123a8ba0bd` | `docs/engineering/CallbackGate-Memory-Model.md` |
| 131 | D | `??` | 9588 | `b6e139875fbaa5c42513d015b3f629b5fbab7055b056b898e87e573a328c889d` | `docs/engineering/Mapping-Retirement.md` |
| 132 | D | `??` | 7484 | `af497b909a0b241a193b93a05681a9ae342283c7ca986a080586480f55e2d68e` | `docs/engineering/RingBuffer-Design.md` |
| 133 | D | `??` | 10309 | `7be7927a4d126c124e2887301bca9104b73a29586ffcc524ff8daa0fa6f8553d` | `docs/engineering/SharedMemory-Lifecycle.md` |
| 134 | D | `??` | 9039 | `2c16832712b3f26058670b92b6a765391cae33b8da463f639b56be056a5d38a7` | `docs/release/SoundBridge-1.2.0-Release-Checklist.md` |
| 135 | D | `??` | 16168 | `693cc3d7f4fa32f6bdc5ec812eb7398e7a2f3356aa0cb1731558b0dd0a6d312a` | `docs/risks/Known-Limitations.md` |
| 136 | D | `??` | 5880 | `0a14dd4258ada74f8a13e008c6e0e3c431644f33ac5172590ddbc77c5517f4c5` | `docs/verification/Batch-0-1-Verification.md` |
| 137 | D | `??` | 6576 | `5c1d8761893d8e1927b9d10a33dced5db6d8e4866558397df8a8f934219cf5df` | `docs/verification/Batch-2-Closure-Verification.md` |
| 138 | D | `??` | 6399 | `470eb536c9975e164cc14ebefea035af1e9878289486e8eec1655ea5c1c18ba9` | `docs/verification/Batch-2-Verification.md` |
| 139 | D | `??` | 26984 | `053ee74fbf65903284f2fc5819f6b42f4cc0bd7017008ef03be917e708a4dd2b` | `docs/verification/Batch-3-Closure-Fix.md` |
| 140 | D | `??` | 6761 | `336f4ffb7e4eba93f4d1142826b69b13d9eab023862bc39235333b6dc1260f28` | `docs/verification/Batch-3-Verification.md` |
| 141 | C-gitignore | `M` | 1608 | `dbb3ac36434000e39a9a98b9d0d3bca5fb6c7fd65a3fe2d911a797206d90aedf` | `.gitignore` |
| 142 | D-1B-revision | `??` | 58582 | `c571fe51f2c011bc7f76c8dc43b588e94da431fc58d195f0be176df23f13e206` | `docs/P4-Batch-1B-Pre-Commit-Report.md` |
| 143 | D-1C-request | `??` | — | —（本文件，见 manifest） | `docs/P4-Batch-1C-Commit-Authorization-Request.md` |

总计 **143** 行。`approval_status` 列（`CONFIRMED G-4 (2026-11-21)` / `PENDING G-2` 等）见 `final-allowlist.tsv`，未在本表重复。

---

## 13. G-6 授权门

**Stage C 未执行。** 暂存区为空，HEAD 未变，没有 commit、没有 tag、没有 push。G-4 已于 2026-11-21 确认、G-3 与 G-7 已关闭，所以现在只差下面这句话。

要进入 Stage C，你需要逐字给出下面这句话（其余任何表述——包括"继续""可以了""按计划执行"——都不构成授权）：

> 我批准 G-1 至 G-5 的最终方案，并授权执行 G-6：按 final-add-list.txt 逐路径 git add，执行暂存区校验，然后创建一个 Git commit。不授权 push 和 tag。

G-3 与 G-7 已在 Final Remediation 中关闭，三份台账（`final-add-list.txt` / `final-allowlist.tsv` / `final-document-hashes.tsv`）已按最终内容重算，所以授权后不需要再改任何文档。若你在授权之外还想改文档，我会先改正文、再重算哈希、最后才暂存——顺序不能反，否则台账与磁盘会不一致。

---

## 14. 授权后我会做什么（Stage C 计划，尚未执行）

1. **重新核验**：`status --short`、`diff --cached --name-only`、`rev-parse HEAD`，并对 143 条逐条比对 `final-allowlist.tsv` 的 SHA-256。任何一项与本节不符 → 停止并重新出报告。
2. **逐路径暂存**：`git -C "$REPO" add --pathspec-from-file=build/p4-batch1c/evidence/final-add-list.txt`（唯一允许的方式）。
3. **暂存区校验**：`diff --cached --name-only | sort` 与 `sort final-add-list.txt` 必须完全一致；`diff --cached --check` 无空白错误；`grep -cE '^(\.qoder|dist|build)/'` 必须为 0；确认删除项只有 1 个。
4. **提交**：`git commit -m "chore(release): stabilize SoundBridge 1.2.0 release candidate"`。不 amend、不 tag、不 push。
5. **提交后验证**：HEAD、`log -1 --stat`、`status --porcelain`、暂存区为空、`dist/` 六个产物 mtime 未变、E-2 仍 14 条 untracked、`.qoder/` 仍在且被忽略、`docs/release/` 的 Checklist 已成为 tracked。
6. **产出**：`docs/P4-Batch-1C-Git-Commit-Report.md`——注意它**不在本次 143 条内**（它描述的是 commit 之后的状态，无法与 commit 同时存在），将作为下一次提交的对象或独立证据保留。

若第 3 步任一项不符：**停止，不 commit，且不使用 `git reset` 回退**，保留现场并报告。

---

## 15. 已知限制（不要把这些读成更强的结论）

| 限制 | 含义 |
|---|---|
| 本阶段没有构建、没有跑测试 | `make version-check` / `protocol-check` 是静态一致性检查，**不是**编译或运行验证。编译与单元测试在 batch 1A/1B 有记录，本阶段未重跑（任务书禁止未授权的 `make build`） |
| 没有真机验证 | 没有安装 Driver、没有重启 `coreaudiod`、没有切换默认输出、没有播放音频。任何"可用"结论都不来自本阶段 |
| G-4 是相关性推断 | 未提交内容没有 author/timestamp；mtime 只能证明"最后写入时间"，所以归属判断本身是"内容 ∧ 时间 ∧ 同批文档"的推断。你 2026-11-21 的确认把它变成你的正式承诺，但没有把推断变成编译或运行证据 |
| 归属检查的边界 | 只做了标记扫描与引用可达性；理论上仍可能存在"看起来正常但没有逐条记录的改动" |
| 3 处独立用户名 | 已在 Final Remediation 中脱敏，见 §5.5 |
| 链接检查 | 验证目标是否在**提交集合**内（本次升级）；不验证锚点是否存在，不验证外部 URL |
| 这份 commit 不是发布 | 它只是把工作区状态固化进 Git。1.2.0 的正式发布仍需 clean clone 构建、打包、签名、公证、真机验证 |
| `final-add-list.txt` 在 `build/` 下 | 该目录被 `.gitignore` 忽略，所以 pathspec 文件本身不入库，只存在于本地证据目录 |

---

## 16. 状态判定

```
READY FOR EXPLICIT G-6 AUTHORIZATION
```

G-3、G-7 已关闭，G-4 已由你逐字确认（2026-11-21）。`BLOCKED — USER OWNERSHIP CONFIRMATION REQUIRED` 与 `BLOCKED — PUBLIC REPOSITORY SANITIZATION REQUIRED` 都已撤销。

**不是** `STAGED — AWAITING COMMIT AUTHORIZATION`（暂存区仍是 0），**不是** `COMMITTED`，**不是**任何"已发布"状态。只差 §13 的那一句授权。

| 你要做的事 | 关闭什么 | 后续影响 |
|---|---|---|
| 给出 §13 的完整授权语句 | G-6 | 进入 Stage C：逐路径 `git add` → 暂存区校验 → 一个 commit |

拿到授权后才会依次进入 `STAGED — AWAITING COMMIT AUTHORIZATION`（暂存且校验通过）→ `COMMITTED — LOCAL VALIDATION PASSED`（commit 后本地复核通过）。在那之前，我不会碰索引。

---

**本阶段到此停止。**
