# SoundBridge 1.2.0 发布检查单

本检查单只列**仓库中真实存在的命令**。未执行过的步骤不要勾选；勾选前必须有
该步骤的输出证据。

> 当前状态：源码级与自动化测试级的收敛已完成（到 P4 Batch 1A），但
> **真实安装/卸载/播放、真实设备移除、macOS 14.4 认证、实际 EQ 听感与播放窗口
> underrun 均未执行**。因此本检查单尚未被完整走通一次。
>
> 「已执行」的判据是：有命令、有本轮输出、有可查的报告路径。没有证据的格子只能留空，
> 不能填 PASS。

---

## 0. 版本与来源确认

| 检查项 | 命令 | 期望 |
|---|---|---|
| 版本一致 | `make version-check` | 所有版本源均等于 `cat VERSION`（当前 `1.2.0`） |
| Bundle Version | `plutil -p apps/mac/SoundBridgeApp/Info.plist` | `CFBundleShortVersionString = 1.2.0` |
| Build Number | 同上 | `CFBundleVersion = 1.2.0` |
| Driver plist | `plutil -p packages/driver/Info.plist` | `SBAudioProtocolVersion = 131584` |
| 协议布局 | `make protocol-check` | exit 0（`0x00020200` / 320 B / offset 320） |
| 头副本一致 | `tools/sync_shared_header.sh --check` | 4 份哈希相同 |
| vendor 子模块 | `git submodule status` | `633e0f70203edd87d320fc5a3cae901e1363aac5`（v3.1.2-1-g633e0f7） |

**禁止**为了让检查通过而修改版本号、Bundle Version、Build Number、ABI 或
Driver plist。版本变化必须是一次独立的、有意的发布动作。

## 1. 构建

```bash
make build          # DSP + Driver + Host + App
```

不要为了通过检查而 `make clean`：本批次不重建、不覆盖 `dist/`，也不允许删除已有的
构建产物。需要一份干净构建时，另开一个全新的克隆目录，而不是清掉当前工作区。

| 检查项 | 期望 |
|---|---|
| DSP 构建 | 成功 |
| Driver 构建 | 成功；`lipo -info` 显示 `x86_64 arm64` |
| Host 构建 | 成功 |
| App 构建 | 成功 |
| 构建告警 | 无新增警告（既有警告记录在案） |

## 2. 测试

```bash
make test           # protocol check + DSP/Host/App/installer
```

| 套件 | 命令 | 已知基线（最近一次记录） |
|---|---|---|
| Driver 全量 | `make test-driver` | 见 [verification/](../verification/)，scratch 目录构建 |
| DSP | `make test-dsp` | **33 tests** |
| Host | `make test-host` | **379 tests / 0 failures** |
| App | `make test-app` | **253 tests / 0 failures** |
| 安装事务 | `make test-installer` | 见输出（每个场景独立 mktemp） |
| 安装门禁 | `make test-installer-gate PKG=<pkg>` | 36 scenarios / 168 assertions |
| 签名参数 | `make test-codesign` | 58 checks |
| 发布载荷破坏测试 | `make test-release-payload` | **244 assertions**（合成 fixture，不读 `dist/`） |
| 安装器静态检查 | `make verify-installer-pkg PKG=<pkg>` | 布局 + 烘焙版本/协议 + 事务脚本一致 |

Host/App 回归已在 P3 与 P4 Batch 1A 各跑过一次，全部通过。每次发布前仍需重跑并记录
输出；上一版的数字不能代替本轮输出。

## 3. Sanitizer

```bash
# Driver（按 Closure Fix 的方式重建）
clang++ -std=c++17 -O1 -g -fsanitize=address ...
clang++ -std=c++17 -O1 -g -fsanitize=thread  ...
```

| 工具 | 期望 |
|---|---|
| ASan | 0 报告 |
| TSan | 0 报告（并发子集） |

已记录的能力限制：macOS arm64 上不提供 LSan 独立目标；TSan 只覆盖被执行的
代码，未报告 ≠ 无竞争。

## 4. 打包与签名

```bash
make bundle
make sign
make verify
```

| 检查项 | 期望 |
|---|---|
| `.app` bundle | 生成于 `dist/` |
| 签名 | **ad-hoc（非公证）**，与当前发布方式一致 |
| `make verify` | 全部签名校验通过 |

若改为 Developer ID + 公证，必须先更新
[risks/Known-Limitations.md](../risks/Known-Limitations.md) 与
[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
§1 中对签名方式的描述，不能只改脚本。

## 5. 安装器与 DMG

```bash
make verify-pkg
make verify-dmg
make verify-payload
make verify-installer-pkg PKG=dist/SoundBridge-1.2.0.pkg
make test-release-payload
```

| 检查项 | 期望 |
|---|---|
| PKG | 含 App + 驱动载荷；preinstall 烘焙版本与协议；postinstall 交接事务 |
| DMG | 只含 App，带拖拽到 Applications 的布局 |
| 包内两份 Driver 副本 | 与 `dist/` 中的 bundle 一致 |
| DMG 内 app | 只读挂载后校验通过 |
| 四向一致性 | bundle / pkg 两份 / dmg 内 driver 全部一致 |
| 检查器自检 | 244 条断言全部按预期成功/失败（合成 fixture，不读历史产物） |

> `make dmg` 会写 `dist/`。本批次禁重建 `dist/`，因此上表只列**只读**检查；
> 需要重新生成产物时，在独立目录执行，不在当前工作区覆盖。

## 6. 真实环境验证（**尚未执行**）

以下步骤在 1.2.0 的开发过程中**从未执行**。它们不是「可选」项，而是把 Pre-release
变成可用发布的必要条件。执行后请把输出路径填在第 4 列。

| # | 步骤 | 通过判据 | 证据（当前） |
|---|---|---|---|
| 1 | 在干净用户环境用 PKG 安装 | 安装器成功；App 可启动；引导流程读到兼容驱动 | 无 |
| 2 | 确认驱动版本与协议 | `CFBundleShortVersionString = 1.2.0`、`SBAudioProtocolVersion = 131584` | 无 |
| 3 | 播放音频（默认设置） | 有声；音量滑块生效；无持续爆音 | 无 |
| 4 | 实际 EQ 听感 | 各频段增益的听感与预期一致；无削波、无色变；旁通/启用切换无咔嗒 | **无（U-14）** |
| 5 | 播放窗口 underrun | 低 buffer + 高负载下 `noteUnderrun` 计数与可听缺口有基线，不出现周期性断裂 | **无（U-15）** |
| 6 | 播放中拔出 HDMI/DP | 不崩溃；`quarantine` 计数为 0；重连后恢复 | 无（U-1） |
| 7 | 卸载 → 重装闭环 | 卸载后设备消失；重装后 EQ/音量恢复；旧 inode 不复活 | **无（U-16）** |
| 8 | `coreaudiod` 重启后恢复 | 能通过一次 IO 重启或 Host 重启恢复（验证 L-6） | Host 重启部分已验证（P3-HR）；`coreaudiod` 重启未验证 |
| 9 | 两台 HDMI 设备同时播放 | 互不干扰 | 无（U-8） |
| 10 | 连续播放 ≥ 8 小时 | 无内存增长、无 quarantine 增长、丢帧率可接受 | 无（U-7） |
| 11 | macOS 14.4 上重复 1–10 | 全部通过 | 无（U-3） |
| 12 | x86_64 真机至少跑 3、6、7 | 与 Apple Silicon 一致 | 无（U-5） |

> 第 4、5、7 行是 P4 Batch 1A 新增的。它们之前没有被写入检查单，于是也从未有人
> 尝试验证；现在它们是阻断项，不能再用「测试全绿」代替。

## 7. 发布前文档同步

| # | 文档 | 更新条件 |
|---|---|---|
| 1 | [architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md) | 任何架构/协议/生命周期变化 |
| 2 | [engineering/](../engineering/) | 对应机制变化 |
| 3 | 新增 `verification/` 报告 | 每次批量验证 |
| 4 | [risks/Known-Limitations.md](../risks/Known-Limitations.md) | 任何风险状态变化（关闭也必须记录） |
| 5 | [RELEASE_NOTES.md](../RELEASE_NOTES.md) | 版本事实、测试数量、验证等级变化 |
| 6 | [INSTALLATION_GUIDE.md](../INSTALLATION_GUIDE.md) | 安装/卸载路径、签名方式、排查命令变化 |
| 7 | `README.md` | 安装入口、卸载入口、自动更新状态变化 |

## 8. 发布阻断项（当前）

在以下事项解决前，1.2.0 **不应**被标记为正式可用发布：

| 编号 | 阻断原因 | 对应登记 |
|---|---|---|
| B-1 | 真实安装 / 卸载 / 播放未验证 | U-2、U-16 |
| B-2 | 真实设备移除未验证（Batch 3 核心场景） | U-1 |
| B-3 | macOS 14.4 未认证 | U-3 |
| B-4 | **实际 EQ 听感未验证** | U-14 |
| B-5 | **播放窗口 underrun 未验证** | U-15 |
| B-6 | **真实卸载/重装闭环未验证** | U-16 |
| B-7 | RT-1 – RT-5 未处理（可能导致真实负载下的爆音/卡顿，不影响内存安全） | Known-Limitations §3.1 |

B-1 – B-6 属于「缺证据」，通过测试与真实环境执行结案；B-7 属于「已知缺陷」，只能通过
工程修改结案。两者不能用同一种方式结案。

**已在本轮关闭**：Host / App 全量回归（原 B-3）——Host 379 / App 253 全绿；
Host-only Restart 与 EQ Mapping 自动恢复已完成实现与验证（见
[Known-Limitations](../risks/Known-Limitations.md) §0）。

## 9. 发布记录模板

每次发布填写一份，存入 `docs/release/`：

```
版本:                1.2.0
日期:                YYYY-MM-DD
VERSION:             1.2.0（git tag: ...）
协议版本:            0x00020200
Driver Build:        ...
Host Build:          ...
签名方式:            ad-hoc / Developer ID
DMG SHA-256:         ...
已执行检查单项:       §0 §1 §2 §3 §4 §5 ...
未执行项及原因:       ...
阻断项状态:           B-1 ... B-5 ...
结论:                COMPLETE / PARTIAL / BLOCKED
```
