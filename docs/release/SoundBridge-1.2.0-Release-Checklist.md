# SoundBridge 1.2.0 发布检查单

本检查单只列**仓库中真实存在的命令**。未执行过的步骤不要勾选；勾选前必须有
该步骤的输出证据。

> **当前状态（2026-11-22，1.2.0 已发布）**：本检查单已按 1.2.0 实际发布过程走通一次，
> 回填结果见 [§10](#10-120-发布回填2026-11-22)。原始表格与其判据保留不变，供下一次
> 发布复用；表内「证据（当前）」列记录的是**发布前**（P4 Batch 3A，带 ad-hoc 签名的
> RC）的状态，不要与 §10 的回填结论混读。
>
> 发布**之后**在验证机上跑出的结果（下载校验、安装、未签名驱动加载、功能与 31 分钟
> 稳定性、两项未测）单独记录在
> [SoundBridge-1.2.0-Post-Release-Validation-Addendum.md](SoundBridge-1.2.0-Post-Release-Validation-Addendum.md)。
> 三者关系：**本表 = 发布前判据**，「§10 = 1.2.0 回填」，「Addendum = 发布后实测」。
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
| Driver 全量 | `make test-driver` | scratch 目录构建 |
| DSP | `make test-dsp` | **33 tests** |
| Host | `make test-host` | **379 tests / 0 failures** |
| App | `make test-app` | **253 tests / 0 failures** |
| 安装事务 | `make test-installer` | 见输出（每个场景独立 mktemp） |
| 安装门禁 | `make test-installer-gate PKG=<pkg>` | 36 scenarios / 168 assertions |
| 未签名发布策略 | `make test-unsigned` | **68 checks**（静态扫描 + fixture 拒绝测试） |
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

## 4. 打包（不签名）

```bash
make bundle
make verify            # 断言 .app 未签名
make verify-unsigned   # 断言 app / PKG / DMG 未签名，且无 appcast
```

| 检查项 | 期望 |
|---|---|
| `.app` bundle | 生成于 `dist/` |
| 签名 | **无**。不执行 `codesign`，没有 Developer ID，没有 ad-hoc 签名，没有公证 |
| `make verify` | `UNSIGNED_APP=PASS`：bundle 未封印、无 `Authority`/`TeamIdentifier`、`SUPublicEDKey` 为空 |
| `make verify-unsigned` | `UNSIGNED_RELEASE=PASS`：PKG `no signature`、DMG 未签名、无 appcast |
| `make sign` | **必须失败**（exit 2）。若它成功，说明有签名路径被重新引入 |

预期会看到的正常输出：`codesign --verify --strict` 对 App/驱动报
`code object is not signed at all`，`spctl` 报 `rejected / source=no usable signature`。
**这两条是本策略的期望值，不是缺陷**，任何「修正」它们的行为都违反发布策略。

唯一允许存在的签名是 `ld64` 写入每个 Mach-O 的 ad-hoc CodeDirectory，以及
`Sparkle.framework`（第三方 SwiftPM 产物）自带的 ad-hoc bundle 签名。两者均无证书
身份；`verify_signatures.sh` 对前者计入 `LINKER_SIGNED`，对后者仅以 NOTE 列出。

若将来改为 Developer ID + 公证，必须先更新
[risks/Known-Limitations.md](../risks/Known-Limitations.md) L-13、
[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
§1、本检查单与 README 中对签名方式的描述，并重写三个 fail-closed 存根，不能只改脚本。

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

## 6. 真实环境验证（P4 Batch 3A：3 项完成 + 2 项部分）

第 1–3 项已完成；第 4、5 项只覆盖主观听感与默认 buffer 部分；其余 7 项仍**从未执行**。
执行后请把输出路径填在第 4 列。

> **这些证据取自带 ad-hoc 签名的 RC。** P4 Batch 7 把发布策略改为完全未签名后，第 1–3
> 行**尚未在新产物上重跑**：安装、启动、驱动加载都必须在未签名产物上重新取证，见 §8.2
> 的 L-8/L-9。旧证据不能沿用。
>
> 表中 `Batch 3A`、`P4 Batch …` 是当年内部批次编号，批次报告不随仓库发布（见
> [docs/README.md](../README.md) §6）；这里保留编号只为标注证据来源。

| # | 步骤 | 通过判据 | 证据（当前） |
|---|---|---|---|
| 1 | 在干净用户环境用 PKG 安装 | 安装器成功；App 可启动；引导流程读到兼容驱动 | 已执行：Batch 3A §R2.9#2（首次安装分支、receipt 1.2.0） |
| 2 | 确认驱动版本与协议 | `CFBundleShortVersionString = 1.2.0`、`SBAudioProtocolVersion = 131584` | 已执行：Batch 3A §R2.9#2、#6 |
| 3 | 播放音频（默认设置） | 有声；音量滑块生效；无持续爆音 | 已执行：Batch 3A §9（音量 13 档轨迹、Mute 双向） |
| 4 | 实际 EQ 听感 | 各频段增益的听感与预期一致；无削波、无色变；旁通/启用切换无咔嗒 | **部分**：用户主观确认各频段与 Reset（Batch 3A §10）；无数值测量；旁通/启用切换未单独取证（U-14） |
| 5 | 播放窗口 underrun | 低 buffer + 高负载下 `noteUnderrun` 计数与可听缺口有基线，不出现周期性断裂 | **部分**：默认 buffer 30 分钟零增量（Batch 3A §11）；低 buffer / 高负载未测（U-15） |
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
| 3 | 批次验证结论回填到 [risks/Known-Limitations.md](../risks/Known-Limitations.md) 与 [architecture](../architecture/SoundBridge-1.2.0-Architecture.md) §11 | 每次批量验证 |
| 4 | [risks/Known-Limitations.md](../risks/Known-Limitations.md) | 任何风险状态变化（关闭也必须记录） |
| 5 | [RELEASE_NOTES.md](../RELEASE_NOTES.md) | 版本事实、测试数量、验证等级变化 |
| 6 | [INSTALLATION_GUIDE.md](../INSTALLATION_GUIDE.md) | 安装/卸载路径、签名方式、排查命令变化 |
| 7 | `README.md` | 安装入口、卸载入口、自动更新状态变化 |

## 8. 发布阻断项与已披露限制

### 8.1 产品层阻断项：**0**

P4 Batch 3A 在真实 macOS 27.2.1 上完成首次安装、启动、播放、音量 / Mute / EQ 与
30 分钟基线共 8 项验证（8/8 PASS）。P4 Batch 3B 分诊结论：1.2.0 没有发布阻断缺陷，
四项残余观察（O-1 – O-4）中 **0 项必须修改生产代码才能发布**。其中 O-3（空闲期
underrun 以 error 级记录、计数不区分空闲与播放期）是**条件项**：发布文档若引用
underrun 指标，应先降级日志级别；本检查单与 [RELEASE_NOTES](../RELEASE_NOTES.md)
引用该指标时只取播放区间增量并注明此限制（见 L-4）。
原 B-1 中的「安装」与「播放」已取得真机证据，但「卸载」仍未验证（见 L-2）；
原 B-4（EQ 听感）只有用户主观确认、原 B-5（underrun）只覆盖默认 buffer——这两项按
「部分取证」处理，不按完全关闭处理。

### 8.2 已披露限制（不阻断 1.2.0，随版本发布）

| 编号 | 限制 | 对应登记 | 证据状态 |
|---|---|---|---|
| L-1 | 播放中拔出 HDMI/DP 未验证 | U-1 | NOT_VERIFIED |
| L-2 | 卸载 → 重装闭环未验证（安装本身已验证） | U-16 | NOT_VERIFIED |
| L-3 | macOS 14.4 / x86_64 真机未认证 | U-3、U-5 | NOT_VERIFIED |
| L-4 | 低 buffer / 高负载 underrun 未测（默认 buffer 已验证） | U-15 | 部分取证 |
| L-5 | ≥ 8 小时稳定性、多设备并发未测 | U-7、U-8 | NOT_VERIFIED |
| L-6 | EQ 听感仅主观确认，无测量数据 | U-14 | 部分取证 |
| L-7 | RT-1 – RT-5 未处理（可能真实负载下爆音/卡顿，不影响内存安全） | Known-Limitations §3.1 | 已知缺陷 |
| L-8 | 发布物完全未签名、未公证：App/PKG/DMG 首次打开均被 Gatekeeper 拒绝，需手动放行；受 MDM 策略禁止未签名软件的组织无法安装 | L-13 | SOURCE_VERIFIED（`spctl`/`pkgutil` 输出已取证） |
| L-9 | **未签名 HAL 驱动能否被 `coreaudiod` 加载未验证**（构建成功 ≠ 安装成功 ≠ 系统接受 ≠ 实际加载） | U-17、N-9 | NOT_VERIFIED |
| L-10 | 未签名 PKG 在真实机器上的完整安装流程（批准拦截 → 写入 HAL → 首次发声）未在未签名产物上执行 | U-18、N-10 | NOT_VERIFIED |
| L-11 | 无自动更新通道：`SUPublicEDKey` 为空、无 appcast、`generate_appcast.sh` 拒绝运行 | L-13 | SOURCE_VERIFIED |

L-1 – L-6 属于「缺证据」，通过真实环境执行结案；L-7 属于「已知缺陷」，只能通过工程
修改结案。L-8、L-11 是**刻意的发布策略**，不可「修复」；L-9、L-10 是策略带来的
**未验证边界**，只能通过真实 Mac 执行 P-9 结案。四类不能用同一种方式处理。

**已在本轮关闭**：Host / App 全量回归（原 B-3）——测试数字见
[RELEASE_NOTES](../RELEASE_NOTES.md) §4；Host-only Restart 与 EQ Mapping 自动恢复已完成
实现与验证（见 [Known-Limitations](../risks/Known-Limitations.md) §0）。

## 9. 发布记录模板

每次发布填写一份，存入 `docs/release/`：

```
版本:                1.2.0
日期:                YYYY-MM-DD
VERSION:             1.2.0（git tag: ...）
协议版本:            0x00020200
驱动与 Host 构建:   ...
签名方式:            无（未签名、未公证；仅 ld64 ad-hoc CodeDirectory）
UNSIGNED_APP:        PASS / FAIL（tools/verify_signatures.sh 输出）
UNSIGNED_RELEASE:    PASS / FAIL（tools/verify_unsigned_release.sh 输出）
PKG SHA-256:         ...
DMG SHA-256:         ...
已执行检查单项:       §0 §1 §2 §3 §4 §5 §6(1-5)
未执行项及原因:       ...
阻断项状态:           0（已披露限制见 §8.2）
结论:                COMPLETE / PARTIAL / BLOCKED
```

## 10. 1.2.0 发布回填（2026-11-22）

本节按 §9 模板回填 1.2.0 的**实际**发布结果。原始证据：
[SoundBridge-1.2.0-Final-Release-Report.md](SoundBridge-1.2.0-Final-Release-Report.md)。

```
版本:                1.2.0
日期:                2026-11-21（GitHub Release 发布）/ 2026-11-22（报告出具）
VERSION:             1.2.0（commit fc09aee，tag v1.2.0）
协议版本:            0x00020200（131584），header 320 B
驱动与 Host 构建:   universal（x86_64 arm64），独立输出目录构建
签名方式:            无（未签名、未公证；仅 ld64 linker-signed CodeDirectory）
UNSIGNED_APP:        PASS（tools/verify_signatures.sh）
UNSIGNED_RELEASE:    PASS（tools/verify_unsigned_release.sh）
PKG SHA-256:         2bf224605b4ecbcfbbf7253ba0bfc426fcaab96aee3e35623059dbdb86635a6f
DMG SHA-256:         2c78d502c54d20dc4764843e5e1fbfa3c64daab2ad07fdc4943dffca8df643e7
已执行检查单项:       §0 §1 §2 §3 §4 §5 §6 的 1-5、7、8
未执行项及原因:       §6-6（设备移除，用户跳过）、§6-9/-10/-11/-12（双设备/8h/14.4/x86_64）
阻断项状态:           0（已披露限制见 §8.2；发布后新增观察见 Known-Limitations §2A）
结论:                COMPLETE（在 1.2.0 声明的验证边界内）
```

### 10.1 §6 真实环境验证逐行回填

| # | 步骤 | 1.2.0 实际结果 | 证据 |
|---|---|---|---|
| 1 | 干净环境用 PKG 安装 | **已执行**：同机卸载后，用从 GitHub 下载的 PKG 经 `installer` 安装成功，payload 109/109 一致 | 发布报告 §11–§12 |
| 2 | 确认驱动版本与协议 | **已执行**：`com.soundbridge.driver` 1.2.0；共享内存 `protocol=131584`、`header_size=320` | 发布报告 §1、§15 |
| 3 | 播放音频（默认设置） | **已执行**：约 47.8k 帧/秒，用户确认听到 | 发布报告 §21 K2 |
| 4 | 实际 EQ 听感 | **部分**：EQ 运行时生效有客观参数链（`eq_seq` 0→10、10 段增益与 UI 吻合）；本轮**未**取得主观听感确认 | 发布报告 §21 K4 |
| 5 | 播放窗口 underrun | **已执行（默认 buffer）**：31 分 01 秒、89,320,455 帧，播放期 30 个采样点零增长；低 buffer / 高负载仍未测 | 发布报告 §22 |
| 6 | 播放中拔出 HDMI/DP | **未执行**：用户选择跳过（K5c） | Known-Limitations §2A |
| 7 | 卸载 → 重装闭环 | **已执行（同机）**：卸载、重装、播放/音量/静音/EQ 重新可用；EQ 数值跨重装一致性因 OBS-2 不作判据 | 发布报告 §11–§12、§21 |
| 8 | `coreaudiod` 重启后恢复 | **部分**：`killall coreaudiod` 后驱动被重新加载（L3/L5 成立）；Host 侧自动恢复未单独判定 | 发布报告 §16、§18 |
| 9 | 两台 HDMI 设备同时播放 | **未执行** | — |
| 10 | 连续播放 ≥ 8 小时 | **未执行**（最长 31 分 01 秒） | 发布报告 §22 |
| 11 | macOS 14.4 上重复 1–10 | **未执行** | — |
| 12 | x86_64 真机 | **未执行**（产物为 universal） | — |

### 10.2 §8.2 已披露限制的结案状态

| 编号 | 原限制 | 1.2.0 发布后状态 |
|---|---|---|
| L-1 | 设备移除未验证 | **仍未验证**（K5c 跳过） |
| L-2 | 卸载 → 重装闭环未验证 | **同机已执行**；跨版本/跨机器仍未验证（U-16） |
| L-3 | macOS 14.4 / x86_64 未认证 | **仍未验证**（U-3、U-5） |
| L-4 | 低 buffer / 高负载 underrun 未测 | **仍未验证**（默认 buffer 已两次长时间验证） |
| L-5 | ≥8 小时、多设备并发未测 | **仍未验证** |
| L-6 | EQ 听感仅主观确认 | **仍无测量数据**；1.2.0 轮次连主观确认也未单独取得 |
| L-7 | RT-1 – RT-5 未处理 | **未处理**（已知缺陷） |
| L-8 | 完全未签名 | **策略不变**（A 类，不修） |
| L-9 | 未签名驱动能否加载未验证 | **单机已验证**（U-17，macOS 27.2.1 / arm64 / SIP+GK 开启）；其他环境仍未验证 |
| L-10 | 未签名 PKG 完整安装流程未验证 | **CLI 路径已验证**；GUI 批准路径未测（G-UI） |
| L-11 | 无自动更新通道 | **策略不变**（A 类，不修） |

回填不改变任何一条「未验证」的等级，除非上一列明确写出「已验证」。

## 11. 驱动加载取证阶梯（L1–L7，可复用）

「安装了驱动」与「驱动在跑」是两件事，中间有若干层，必须逐层取证，不能用低层
冒充高层（自 P4 Batch 8 的 P-9 程序提炼，已在 1.2.0 发布验证中实际执行）。

| 层 | 判据 | 取证方式 | 容易犯的错 |
|---|---|---|---|
| **L1 安装成功** | `installer` 退出码 0；事务日志 `[SUCCESS] driver <ver> (protocol <n>)`；PKG 回执存在 | `installer -pkg … -target /`、`pkgutil --pkg-info` | 把「包解开」当成「安装成功」 |
| **L2 bundle 落盘** | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` 是真实目录（非符号链接）、`root:wheel`、bundle id 与版本正确、无 `_CodeSignature` | `ls -ld`、`plutil -p`、`codesign -dv` | 用 `lipo -archs` 存在推断可加载 |
| **L3 被发现** | `coreaudiod` 日志出现 `HALS_RemotePlugInRegistrar … Attempting to load: SoundBridgeDriver.driver` | `log show --predicate …`（**必须** `--info --debug`，否则看不到） | 安装后立刻查，忽略「安装早于 coreaudiod 扫描」的时序 |
| **L4 设备枚举** | `system_profiler SPAudioDataType` 出现代理设备 | `system_profiler SPAudioDataType` | 把枚举当成加载（枚举可由其他路径产生） |
| **L5 实际加载** | 出现 `Core Audio Driver (SoundBridgeDriver.driver)` 进程；驱动自身 subsystem 有循环日志 | `ps`、`log show --predicate 'subsystem == "com.soundbridge.driver"'` | 只看 L4 就下结论 |
| **L6 会话建立** | 控制文件存在；共享内存 mapping 出现；驱动日志 `✓ Mapped` / `✓ Connected`；生命周期快照 `sharedMemoryConnection=connected` | Host 侧日志 + `/tmp/soundbridge-*` 检查 | 在 App 未启动时查「无连接」并判失败 |
| **L7 音频流动** | 生命周期 `audioPipeline=flowing`；帧计数按 48 kHz 速率增长；`overruns`/`format_mismatch` 为 0 | 共享内存探针 + 驱动 STATS | 以「设备存在」代替「音频在流」 |

配套纪律：

- 安装脚本**不重启** `coreaudiod`；若 `coreaudiod` 启动早于安装，必须等一次重新
  扫描（注销/重启或用户自行 `killall coreaudiod`）才能进入 L3 之后。
- 停止播放后 `driver_connected` 归 0 属正常回收，不得据此判「链路故障」。
- 每一层都要留下原始输出路径；只有 L5 成立才可以说「未签名驱动被加载」，只有
  L7 成立才可以说「音频链路可用」。
