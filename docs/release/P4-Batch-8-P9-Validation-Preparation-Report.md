# P4 Batch 8 — P-9 Unsigned Driver Real-Mac Validation Preparation

**日期**：2026-11-21
**基线**：`main` / HEAD `0b50ae1160960cbfb8f77bd6a5467b75de1ddee6` / tag `v1.2.0` → 同一提交 / `VERSION` = 1.2.0
**协议**：`0x00020200`（131584），Header 320 bytes
**上一批裁决**：`CONDITIONAL PASS — DRIVER LOADING REQUIRES REAL MAC VALIDATION`（P4 Batch 7）

本批次**只做验证准备与证据体系建设**，不执行 P-9。
实际执行边界：**未**安装或卸载 Driver、**未**重启 `coreaudiod`、**未**切换默认输出设备、
**未**修改任何系统安全设置、**未**创建 Release / 上传 / stage / commit / push / 改 Tag。

---

## 0. 本批次结论摘要

| 项目 | 结果 |
|---|---|
| P4 Batch 7 独立复核（8 项） | 5 项 CONFIRMED、3 项 CONFIRMED WITH OBSERVATION（见 §1） |
| Batch 7 缺陷 | 6 项观察（OBS-1…OBS-6）+ 2 项事实修正（OBS-7、OBS-8），**只报告未修改** |
| 未签名候选产物 | 已冻结到 `build/p4-batch8/p9-candidate/`，含 `SHA256SUMS.txt`（`shasum -c` 两行 OK） |
| P-9 验证程序 | 16 个步骤（P9-00…P9-14，含 11A/11B），含命令、预期证据、执行者、授权门 |
| 通过标准 | 10 条，按架构/系统版本分别记录（§7） |
| 当前可执行性 | **没有一台可用于「首次安装」的干净机器**（本机已有 ad-hoc 驱动与回执，见 §3.2） |

裁决见 §10：`PASS — P-9 VALIDATION READY`。

---

## 1. Stage A — P4 Batch 7 结果独立复核

复核方式：重新读取当前工作区文件并重新运行各 verifier，**不依赖 Batch 7 的报告文字**。
证据见 `build/p4-batch8/evidence/a8-*.log`。

### 1.1 八项复核结论

| # | 复核项 | 复核方式 | 结论 |
|---|---|---|---|
| A1 | `release.yml` 只执行未签名流程 | 去注释后按 11 类 token 计数：`codesign` / `notarytool` / `stapler` / `productsign` / `find-identity` / `options runtime` / `SPARKLE_ED_` / `SUPublicEDKey` / `appcast` / `make sign` / `security import` **全为 0**；`on: release: published`；无 `continue-on-error` | **CONFIRMED** |
| A2 | Makefile `sign` 存根 fail-closed | `sign:` → `@./tools/codesign.sh`；实测无参 rc=2、`--adhoc` rc=2、`--help` rc=0；`release`/`full-release` 不依赖 `sign` | **CONFIRMED** |
| A3 | 旧签名/公证/appcast 入口 fail-closed | `codesign.sh`、`notarize.sh`、`generate_appcast.sh` 三者无参/带 `--adhoc` 均 rc=2，`--help` rc=0；`tools/` 中无 `--sign`、`productsign`、`notarytool`、`stapler`、`find-identity`；残留 `codesign` 调用全部是只读的 `-dv` / `--verify` | **CONFIRMED** |
| A4 | Sparkle 不会触发自动更新 | 仓库 `Info.plist`、候选 bundle、PKG 内 App 三处 `SUPublicEDKey` 均为空；`VersionManager.isUpdaterConfigured` 要求 `SUFeedURL` 与 `SUPublicEDKey` **同时非空**；`SoundBridgeApp` 在 `SPUStandardUpdaterController` 之前 `guard ... else { return }`；候选集无 `appcast.xml` | **CONFIRMED**（附 OBS-4） |
| A5 | `verify_unsigned_release.sh` 验证本次产物而非隐式读取历史 `dist` | workflow 第 29 步显式传 `--app dist/SoundBridge.app --pkg dist/SoundBridge-$VERSION.pkg --dmg ... --dist dist`，且 `VERSION` 来自 `steps.version.outputs.version`；**但脚本自身默认 `--app` 会回落到 `$PROJECT_ROOT/dist/SoundBridge.app`，且显式传入的 PKG 缺失时仍判 PASS** | **CONFIRMED WITH OBSERVATION**（OBS-1、OBS-2） |
| A6 | 68 项测试覆盖原 58 项签名测试的安全边界 | 68 项按段统计：S-01 10 / S-02 15 / S-03 10 / S-04 10 / S-05 3 / S-06 2 / F-00 1 / F-01 3 / F-02 3 / F-03 3 / F-04 3 / F-05 5；映射见 §1.3 | **CONFIRMED WITH OBSERVATION**（OBS-8） |
| A7 | 第三方签名与 linker 签名分类准确 | 候选 bundle 内 8 个 Mach-O：**3 个**为项目二进制（App 主程序、Host、Driver），仅带 `flags=0x20002(adhoc,linker-signed)`；**5 个**为 Sparkle 上游二进制（`Sparkle`、`Autoupdate`、`Updater`、`Downloader`、`Installer`），`Signature=adhoc` 且带封印。封印目录 4 个，全部在 `Contents/Frameworks/Sparkle.framework/Versions/B/` 下。`Authority=` 行 0 个、`TeamIdentifier=not set` | **CONFIRMED**（附 OBS-3 措辞问题） |
| A8 | PKG/DMG/App/Driver 的 SHA-256 与内部版本一致性 | `verify_pkg_contents` 三向 PASS（`DRIVER_THREE_WAY_MATCH=true`、`PKG_APP_VERSION=1.2.0`、`PKG_DRIVER_VERSION=1.2.0`、`ARCHITECTURE=PASS`）；`verify_release_payload` `DRIVER_FOUR_WAY=true`、7 项 `OVERALL_RESULT=PASS`；`verify_dmg_contents` PASS（`PROTOCOL_VERSION=131584`）；`verify_version_consistency` 11 源 PASS；`verify_pkg_driver --require-unsigned` `STRUCTURAL_PASS`（9 checks / 0 failures） | **CONFIRMED** |

### 1.2 Batch 7 缺陷与观察（只报告，未修改）

| ID | 严重度 | 事实 | 影响 | 建议 |
|---|---|---|---|---|
| **OBS-1** | 中 | `verify_unsigned_release.sh` 对**显式指定但不存在**的 PKG 判 `UNSIGNED_PKG=NOT_PRESENT` 且整体 `UNSIGNED_RELEASE=PASS`（rc=0）。实测：`--pkg /tmp/definitely-absent.pkg` → PASS，4 checks / 0 failures | 若将来 PKG 文件名或 `VERSION` 变化导致路径失配，该门禁会静默放行；实践中由第 33 步 `Verify Release Assets` 兜住，但门禁语义弱于其名称 | 门禁应把「显式传入却不存在」判 FAIL，只对「未传入」保留 `NOT_PRESENT` |
| **OBS-2** | 低 | `verify_unsigned_release.sh` 默认 `--app` = `$PROJECT_ROOT/dist/SoundBridge.app`。手工无参调用会验证 `dist/` 中的历史产物（当前正好是带 ad-hoc 签名的批次产物，会 FAIL，方向安全） | 与已被删除的 `test_codesign_args.sh` 曾专门守护的「默认路径不得静默指向别的产物」是同一类风险，但方向相反（那次防误签，这次易误验） | 保留显式参数习惯；手工调用时必须带 `--app` |
| **OBS-3** | 低 | `verify_signatures.sh` 把所有嵌套 `_CodeSignature` 一律称作 "Sealed third-party bundles … from SwiftPM"。在 `dist/` 上实测会把**项目自身**的 `SoundBridgeDriver.driver/Contents/_CodeSignature` 也列进该 NOTE 段 | 对未签名候选集，该说法恰好为真（4 个封印全在 Sparkle 内）；但措辞按路径不分类，遇项目自签产物会误导 | 按路径白名单（`*/Sparkle.framework/*`）分类，其余单列 |
| **OBS-4** | 低 | 候选 bundle 与 PKG 内 App 的 `SUFeedURL` 仍指向 `https://github.com/chenjy16/SoundBridge/releases/latest/download/appcast.xml`（该 URL 永不发布）。更新关闭依赖运行期 `isUpdaterConfigured`（要求 key 非空） | 文档说「没有更新通道」指的是发布面；测试者若只读 `Info.plist` 会看到 feed URL，可能误判「自动更新已配置」 | 文档措辞改为「声明了 feed URL 但密钥为空，更新器不启动」 |
| **OBS-5** | 低 | `tools/verify_unsigned_release.sh:22` 与 `tools/generate_appcast.sh:58` 指向 `docs/1.2.0/Known-Limitations.md`，该文件**不存在**（实际为 `docs/risks/Known-Limitations.md`；`docs/1.2.0/` 目录存在但只放 Phase 2 报告） | 断链指引 | 改为 `docs/risks/Known-Limitations.md` |
| **OBS-6** | 中 | Batch 7 报告 §8 的 P-9 第 7 步写着「关闭 Gatekeeper 前后各做一次对照」 | 与 Batch 8 §2「不关闭 Gatekeeper、SIP」直接冲突，也与该步自己那句「不得把关闭 Gatekeeper 当作推荐方案」自相矛盾 | **本批次已在 §4 中作废该步**，替换为非侵入式对照（P9-11B） |
| **OBS-7** | 信息 | `dist/` 现存产物是**带 ad-hoc 签名**的旧 RC（PKG `8483c20b…`、DMG `1b6b43f2…`），对 `verify_signatures.sh` FAIL 2 条断言（bundle 通过 `codesign --verify --strict`、存在 `_CodeSignature`） | 任何 P-9 若误用 `dist/`，测的就是「ad-hoc 驱动能否加载」，与本批次的问题无关 | P-9 候选固定为 `build/p4-batch8/p9-candidate/`（§2） |
| **OBS-8** | 信息 | 被删除的 `test_codesign_args.sh`（58 项）主要守护的是 `codesign.sh` 的**参数/路径/dry-run 计划**（默认路径、`SB_APP_BUNDLE` 覆盖、拒绝分支、计划顺序、dry-run 无副作用）。新 68 项守护的是「签名路径不存在」与「验证器极性」，不再有「计划顺序」和「dry-run 无副作用」这两类对象 | 前者随签名功能消失而失去意义；后者中的「默认路径」属性没有后继（见 OBS-2） | 若要补，应补在 `verify_unsigned_release.sh` 的默认路径行为上 |

### 1.3 68 项测试与原 58 项安全边界的映射

| 原 `test_codesign_args.sh` 守护的属性 | 新 `test_unsigned_release.sh` 的对应 |
|---|---|
| 默认路径不得静默指向别的 bundle | **无直接对应**（S-01/S-02 只断言 workflow 内联路径；脚本自身的默认值未测 → OBS-2） |
| `SB_APP_BUNDLE` 覆盖必须生效 | 不适用（签名入口已废） |
| 缺失路径 / 非 bundle 必须拒绝且不回落 | S-04（三个存根 exit 2，拒绝而非静默）+ F-02（已封印 bundle 必须被拒绝） |
| 身份解析（`--adhoc` 与 Developer ID 互斥） | S-01（workflow 无任何身份 token）+ S-05（tools 内无 `--sign`） |
| 计划内容与顺序（framework → xpc → driver → main → app） | 不适用（不存在签名计划）；由 F-04（appcast 存在则整包门禁失败）承接「发布面完整性」 |
| dry-run 不改动任何文件 | F-01（未签名 fixture 通过断言）+ S-05（静态扫描无签名调用） |
| 验证步骤必须报 `valid on disk` | **反转**为 F-02：已封印 bundle 必须被拒绝 |

结论：**核心安全属性（签名路径不可能被静默启用）覆盖更强**；唯一丢失的属性是「默认路径不得静默指向别的产物」，而新门禁恰好存在该形状的默认值（OBS-2）。这不是回归，是继承的薄弱点。

### 1.4 复核过程中确认的事实（供 P-9 直接使用）

- **安装事务不检查签名**：`tools/sb_install_transaction.sh` 与 PKG 的 `preinstall` / `postinstall` 中无 `codesign` / `spctl` / `xattr` / `stapler` 调用；App 源码中亦无 `SecStaticCode` / `SecCodeCheck` / `codesign` / `spctl`。因此未签名驱动在**安装路径上不会被任何自有逻辑拒绝**，唯一可能的拒绝方是系统（`coreaudiod` / Gatekeeper）。
- **`dist/` 与候选集是两代产物**（OBS-7）：尺寸与 SHA 均不同，安装哪一个会得到不同结论。
- **workflow 只有 34 步、只有一个 job**（`build-and-release`，`runs-on: macos-15`），第 15 步是 `Run unsigned release policy tests`（`make test-unsigned`），第 18 步是 `Verify App Bundle Is Unsigned`，第 29 步是 `Verify Unsigned Release`。第 2 步里的 `git tag … || true` 发生在 **libASPL 子模块目录内**（`cd packages/driver/vendor/libASPL`），只用于 `git describe`，不创建也不推送主仓库 tag。

---

## 2. 候选产物指纹（P-9 的被测对象）

**位置**：`build/p4-batch8/p9-candidate/`（由 Batch 7 的 `build/p4-batch7/unsigned-dist/` 复制，
构建方式为直接调用底层脚本并显式指定输出目录，未经过 `make` 入口，因此没有改写版本源）。

| 对象 | 值 |
|---|---|
| `SoundBridge-1.2.0.pkg` | 14,364,638 B · SHA-256 `2d559df21a97207012162d5f7d4bb3bbe2217d66840a22405d8356c52f9e5979` |
| `SoundBridge-1.2.0.dmg` | 14,936,396 B · SHA-256 `e4bcd724a1c98f6794dfe6402f9a10283a4fc77bebf523cecc8f688e7853cf7e` |
| `SoundBridge.app` | ≈20 MB · 107 个文件（`APP-FILES.sha256` 逐文件记录） |
| App Bundle ID / 版本 | `com.soundbridge.menubar` · `CFBundleShortVersionString=1.2.0` · `CFBundleVersion=1.2.0` |
| `SoundBridgeApp`（主程序） | SHA-256 `99f4d5b605c2079af7388cb8bc7ef6cbaaa97cebaae01b43feb89c1e68b711e2` |
| `SoundBridgeHost` | SHA-256 `9823d60bf105dd675024698ac633b337f373af40b024cfeb35cdb2428e4f4ec8` |
| `SoundBridgeDriver`（bundle 内副本） | SHA-256 `866f54bdbf618f52d90c05308c6e2c017c5f97841b30cdbe1afef8994323f3ab` |
| 架构 | `x86_64 arm64`（三个项目二进制均为 universal） |
| Driver Bundle ID / 版本 | `com.soundbridge.driver` · 1.2.0 |
| 协议 / Header | `0x00020200` = 131584 · 320 bytes |
| 签名状态（App） | `codesign --verify --strict` rc=1（`code object is not signed at all`）；无 `Contents/_CodeSignature` |
| 签名状态（Driver） | `CodeDirectory … flags=0x20002(adhoc,linker-signed)` · `Signature=adhoc` · `Info.plist=not bound` · `Identifier=SoundBridgeDriver` |
| 签名状态（PKG） | `pkgutil --check-signature` → `Status: no signature`（rc=1） |
| 签名状态（DMG） | `codesign -dv` → `code object is not signed at all` |
| Gatekeeper 判决 | App `rejected / source=no usable signature`（rc=3）；PKG / DMG 同样 rejected —— **这是预期值，不是缺陷** |
| 第三方封印 | 4 个，全部在 `Contents/Frameworks/Sparkle.framework/Versions/B/`（framework 本体、`Updater.app`、`Downloader.xpc`、`Installer.xpc`） |
| 校验和 | `shasum -a 256 -c SHA256SUMS.txt` → PKG OK、DMG OK |

**⚠ 一个必须交代的区别**：未签名 bundle 的 `codesign -dv` 报 `Identifier=SoundBridgeDriver`
（因为 `Info.plist=not bound`，取的是可执行文件名），**不是** `com.soundbridge.driver`。
判断驱动身份必须读 `Info.plist`，不能用 `codesign -dv` 的 `Identifier=` 行，否则会误判「装错了驱动」。

**来源说明**：候选集由**当前未提交工作树**（HEAD `0b50ae1` + Batch 7 修改）构建。
它回答的是「这一结构的未签名产物能否被系统接受」；正式发布时 workflow 会从 tag 重新构建，
字节级 SHA 必然不同，因此 P-9 的结论绑定的是**产物结构**，不是这一组 SHA。

---

## 3. 测试设备要求（B1）

### 3.1 必要条件

| 项 | 要求 | 记录方式 |
|---|---|---|
| 硬件 | Apple silicon 一台（必备）；Intel Mac 一台（第二批，可选） | `system_profiler SPHardwareDataType`（Model Name / Identifier / Chip） |
| 系统 | macOS 14 及以上（本期计划覆盖 macOS 14.x 与 26.x/27.x，至少各一台） | `sw_vers`（含 `BuildVersion`）+ `sysctl -n kern.osversion` |
| 管理状态 | **不得**为 MDM/DEP 受管控设备（受管控设备无法手动放行） | `profiles status -type enrollment` |
| 初始状态 | **必须干净**：HAL 目录无 `SoundBridgeDriver.driver`、`pkgutil --pkgs` 无 `com.soundbridge.menubar` | §4 P9-02 |
| 安全策略 | 保持默认：SIP enabled、Gatekeeper `assessments enabled`。**不得**为测试而关闭 | `csrutil status`、`spctl --status` |
| 物理设备 | 至少一个可正常出声的输出设备（含可拔插的 USB/蓝牙设备，用于移除测试） | `system_profiler SPAudioDataType` |

### 3.2 当前参照机状态（本机，只读采集）

| 项 | 实测值 |
|---|---|
| 型号 | Mac mini（`Mac16,10`），Apple M4，10 核，16 GB |
| 系统 | macOS 27.2.1，Build `26B131` |
| 架构 | `arm64` |
| SIP | `enabled` |
| Gatekeeper | `assessments enabled` |
| MDM | `Enrolled via DEP: No` / `MDM enrollment: No` |
| HAL 目录 | `BlackHole16ch.driver`、`ParrotAudioPlugin.driver`、**`SoundBridgeDriver.driver`**、`eqMac.driver` |
| 已装驱动 | `com.soundbridge.driver` 1.2.0，`Signature=adhoc`（带封印），可执行文件 SHA-256 `c2955030…3e24a0` |
| 已装回执 | `com.soundbridge.menubar` 存在 |

**结论：本机当前不具备「首次安装」资格。** 它装的是 Batch 3A/3B 的 **ad-hoc 签名**驱动
（`c2955030…` ≠ 候选 `866f54bd…`），任何在此机上的安装都属于「覆盖安装」，
且测的是「从 ad-hoc 驱动升级到未签名驱动」，**不能**用来回答「未签名驱动能否被加载」。
本机可作为第二批「覆盖安装 / 升级」场景的测试机，但必须先由用户授权卸载。

---

## 4. Stage B — P-9 验证程序

### 4.0 通用约定

- 所有命令的输出**原样**保存，文件名形如 `p9-<步骤>-<主题>.log`，目录 `build/p4-batch8/p9-run-<日期>/`。
- 采集时先记录时间戳与时区：`date -u +"%Y-%m-%dT%H:%M:%SZ"`、`date +"%Z %z"`。
- 命令都按 `zsh` 写；需要 `sudo` 的只有 `log show`（读取 system 域）与安装/卸载本身。
- **代理只运行只读命令**；安装、卸载、重启、批准、播放、拔插设备一律由用户在测试机上执行（§5）。
- 每一步都给出「预期证据」。**没有证据的步骤按未执行处理**，不得以「看起来正常」替代。

### 4.1 步骤总表

| ID | 步骤 | 执行者 | 授权门 | 证据文件 |
|---|---|---|---|---|
| P9-00 | 候选集落地与校验 | 代理（只读校验） | — | `p9-00-candidate.log` |
| P9-01 | 设备信息采集 | 代理 | G1（只读） | `p9-01-device.log` |
| P9-02 | 安装前体检（清洁度） | 代理 | G1 | `p9-02-preflight.log` |
| P9-03 | Gatekeeper / 签名预判 | 代理 | G1 | `p9-03-assessment.log` |
| P9-04 | **安装 PKG** | 用户 | **G2** | `p9-04-install.log` |
| P9-05 | 安装结果与落盘核对 | 代理 | G1 | `p9-05-installed.log` |
| P9-06 | 驱动加载判定 L1–L3 | 代理 | G1 | `p9-06-load.log` |
| P9-07 | 设备枚举判定 L4 | 代理 | G1 | `p9-07-enumeration.log` |
| P9-08 | App 启动 / Host 启动 / Session L5–L6 | 用户启动 + 代理观测 | **G3** | `p9-08-session.log` |
| P9-09 | 播放 / 音量 / EQ | 用户操作 + 代理观测 | **G3** | `p9-09-playback.log` |
| P9-10 | Host 重启 与 Stop→Start | 用户操作 + 代理观测 | **G3** | `p9-10-restart.log` |
| P9-11A | 设备移除与重新枚举 | 用户拔插 + 代理观测 | **G3** | `p9-11a-device.log` |
| P9-11B | 非侵入式对照实验（替代 Batch 7 的「关 Gatekeeper」） | 代理 | G1 | `p9-11b-control.log` |
| P9-12 | 30 分钟稳定性 | 用户播放 + 代理采样 | **G3** | `p9-12-stability.log` |
| P9-13 | 卸载与恢复 | 用户 | **G4** | `p9-13-uninstall.log` |
| P9-14 | 证据归档与逐条判定 | 代理 | — | `p9-14-verdict.md` |

授权门：**G1** 只读采集；**G2** 安装 PKG；**G3** 启动 App 并播放音频；**G4** 卸载驱动；
**G5** 重启 `coreaudiod`（默认不使用，仅用于失败归因，需单独授权并单独标注）。
每一门单独授权，批准 G1 不得推导 G2 已授权。

### 4.2 P9-00 候选集落地与校验

```bash
cd <把 p9-candidate 整目录拷到测试机后的路径>
shasum -a 256 -c SHA256SUMS.txt
ls -la; wc -l < APP-FILES.sha256
```
**预期**：`SoundBridge-1.2.0.pkg: OK`、`SoundBridge-1.2.0.dmg: OK`、`APP-FILES.sha256` 107 行。

### 4.3 P9-01 设备信息（B1）

```bash
{ date -u +"%Y-%m-%dT%H:%M:%SZ"; date +"%Z %z"
  sw_vers; sysctl -n kern.osversion; uname -m
  sysctl -n machdep.cpu.brand_string
  system_profiler SPHardwareDataType | sed -n '1,16p'
  csrutil status; spctl --status; profiles status -type enrollment
} 2>&1 | tee p9-01-device.log
```
**预期**：含 Model Identifier、`Chip`（Apple silicon）或 `Processor Name`（Intel）、
`System Integrity Protection status: enabled`、`assessments enabled`、`MDM enrollment: No`。
**任一项不符（SIP disabled / MDM Yes / 非目标架构）→ 该机不进入 P-9，记录并换机。**

### 4.4 P9-02 安装前体检（清洁度）

```bash
{ ls -1 /Library/Audio/Plug-Ins/HAL/ 2>&1
  ls -ld /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver 2>&1
  pkgutil --pkgs | grep -i soundbridge || echo "receipt: none"
  pgrep -l coreaudiod || echo "coreaudiod: not running"
  system_profiler SPAudioDataType | grep -i -E '^\s{4}\S|Default Output' 
  ls -la /tmp/soundbridge-* 2>&1 | head -20
  ls -la /tmp/com.soundbridge.host-global.lock 2>&1
} 2>&1 | tee p9-02-preflight.log
```
**预期（干净机）**：HAL 目录内**没有** `SoundBridgeDriver.driver`；`receipt: none`；
`/tmp/soundbridge-*` 无残留（或只有与 SoundBridge 无关的历史文件）。
**若不干净**：记录实际内容 —— 这是「升级场景」，该次运行的结论只能标注为
`INSTALL_PATH=upgrade`，**不得**计入首次安装的验收项。

### 4.5 P9-03 Gatekeeper / 签名预判（B3 只读部分）

```bash
{ echo "== pkgutil --check-signature =="; pkgutil --check-signature SoundBridge-1.2.0.pkg; echo "rc=$?"
  echo "== spctl -a -vv -t install =="; spctl -a -vv -t install SoundBridge-1.2.0.pkg; echo "rc=$?"
  echo "== spctl -a -vv app =="; spctl -a -vv SoundBridge.app; echo "rc=$?"
  echo "== codesign -dv app =="; codesign -dv --verbose=2 SoundBridge.app; echo "rc=$?"
  echo "== codesign -dv dmg =="; codesign -dv SoundBridge-1.2.0.dmg; echo "rc=$?"
  echo "== 隔离属性 =="; xattr -l SoundBridge-1.2.0.pkg; xattr -l SoundBridge.app
} 2>&1 | tee p9-03-assessment.log
```
**预期**：`Status: no signature`（rc=1）；`spctl` 三条 `rejected`（rc=3）；
`codesign -dv` 报 `code object is not signed at all`；DMG 同。
`xattr` 若显示 `com.apple.quarantine`，说明文件是**下载**得来的 —— 记录下来，这会影响安装时的提示文案
（命令行拷贝的文件通常没有 quarantine，双击下载的 DMG 有）。

> 该步骤的输出**不能**当作安装成功或失败 —— 它只说明「系统会怎么判」。

### 4.6 P9-04 安装（B3 实际行为，用户执行）

两种入口，任选其一，**并在日志里写清楚选的是哪种**：

- **A. 图形安装（推荐，最接近真实用户）**：双击 `SoundBridge-1.2.0.pkg` → 记录出现的每一个对话框原文
  （「无法打开，因为无法验证开发者」/「安装器无法验证此软件包」/ 安全性与隐私中的「仍要打开」）。
- **B. 命令行安装**：`sudo installer -pkg ./SoundBridge-1.2.0.pkg -target / -verboseR 2>&1 | tee p9-04-install.log`

必须记录的原始输出：
```bash
tail -n 200 /var/log/install.log | tee -a p9-04-install.log
pkgutil --pkgs | grep -i soundbridge
pkgutil --pkg-info com.soundbridge.menubar
ls -l /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver
```
**四种结局，必须区分**（见 §6 F-1 / F-2）：
① 系统直接允许安装；② 系统拒绝（未做任何手动操作）；③ 用户手动批准后允许（记录批准动作）；
④ 企业策略禁止。②与④不得混写。

### 4.7 P9-05 安装结果与落盘核对

```bash
{ ls -l /Library/Audio/Plug-Ins/HAL/
  P=/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$P"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$P"
  shasum -a 256 /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver
  ls -l /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/
  codesign -dv --verbose=2 /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver
  ls -l "/Library/Application Support/SoundBridge/InstallerPayload/"
} 2>&1 | tee p9-05-installed.log
```
**预期**：驱动可执行文件 SHA-256 = `866f54bd…4323f3ab`；`CFBundleIdentifier=com.soundbridge.driver`；
版本 1.2.0；`codesign -dv` 仍为 `flags=0x20002(adhoc,linker-signed)`、`Info.plist=not bound`；
**没有** `Contents/_CodeSignature`。
**若 SHA 与候选不一致 → 安装链污染，停止后续步骤**（§6 F-2）。

### 4.8 P9-06 驱动加载判定 L1–L3（B4 的核心）

三个独立探针，**必须全部采集**，任何单一探针都不足以证明加载：

```bash
{ echo "== L2 进程表（驱动以 coreaudiod 子进程形态出现）=="
  ps -axo pid,ppid,etime,comm | grep -i -E 'coreaudiod|Core Audio Driver' | grep -v grep

  echo "== L2 统一日志：驱动 subsystem（需 sudo 读取 system 域）=="
  sudo log show --last 15m --info --predicate 'subsystem == "com.soundbridge.driver"' --style compact | tail -n 80

  echo "== L2 驱动自身文件日志 =="
  tail -n 80 /tmp/soundbridge-driver-debug.log 2>&1

  echo "== L3 谁来加载（bundle 是否被 coreaudiod 打开）=="
  sudo lsof -c coreaudiod 2>/dev/null | grep -i soundbridge || echo "lsof: no SoundBridge handle"
} 2>&1 | tee p9-06-load.log
```
判定：
- **L1（文件层）**：§4.7 已证。
- **L2（加载层，关键）**：出现 `[SoundBridge INFO]` 行（如 `ValidateConnection`、`OnStartIO`）
  或 `Core Audio Driver` 子进程，或用 `lsof` 看到 `coreaudiod` 持有驱动内文件 → 记为
  `COREAUDIOD_LOADED=YES`。三者皆无 → `NO`。
- **L3（初始化层）**：驱动日志里出现插件初始化/设备创建行，且**没有** dlopen/`AudioServerPlugIn`
  注册失败、`code signature` 相关拒绝 → `DRIVER_INIT=OK`，否则记录原文。

> 若 L2 = NO：**不要**据此断言「未签名驱动一定不能加载」。必须在 §4.13 的对照实验里
> 用同一台机器、同一安装流程、换成已确认可加载的**已签名**产物复测一次，才能把原因归到签名缺失上。

### 4.9 P9-07 设备枚举判定 L4

```bash
{ system_profiler SPAudioDataType | sed -n '/SoundBridge/,+12p'
  system_profiler SPAudioDataType | grep -c -i soundbridge
  system_profiler SPAudioDataType | grep -n -E '^\s{8}\S.*:$' | head -20
} 2>&1 | tee p9-07-enumeration.log
```
**预期**：出现名称含 `SoundBridge` 的输入/输出设备条目。
**这是 L4 的唯一证据，也只证明 L4**：设备出现在列表里，不能证明 Host 在跑、不能证明能出声、更不能证明 IO 回调正常。

### 4.10 P9-08 App 启动 / Host 启动 / Session L5–L6

用户启动 App（`open /Applications/SoundBridge.app`，或双击）。代理只读观测：

```bash
{ echo "== 进程 =="; ps -axo pid,ppid,etime,rss,comm | grep -E 'SoundBridgeApp|SoundBridgeHost' | grep -v grep
  echo "== 控制文件 =="; cat /tmp/soundbridge-devices.txt 2>&1
  echo "== 映射 =="; ls -l /tmp/soundbridge-* 2>&1
  echo "== 实例锁 =="; ls -l /tmp/soundbridge-host-*.lock /tmp/com.soundbridge.host-global.lock 2>&1
  echo "== Host 日志 =="; log show --last 10m --info --predicate 'subsystem == "com.soundbridge.host"' --style compact | tail -n 60
  echo "== App 日志 =="; log show --last 10m --info --predicate 'subsystem == "com.soundbridge.app"' --style compact | tail -n 40
} 2>&1 | tee p9-08-session.log
```
判定：
- **L5**：`SoundBridgeHost` 进程存在且父进程是 `SoundBridgeApp`（或由 App 拉起的 launchd 项），
  且日志出现 lifecycle 就绪行 → `HOST_STARTED=YES`。
- **L6**：`/tmp/soundbridge-<uid>-<safeUID>` 映射存在（记录字节数，Batch 3A 基线为 65,856 B，
  **以本次日志报告值为准，不预设相等**），`/tmp/soundbridge-devices.txt` 含设备行，
  `DriverLifecycle` 无「detached / admission refused」类报错 → `SESSION_ESTABLISHED=YES`。
- `driver_connected` 只有在**真正播放**时才会置 1（驱动在 IO 回调里置位），本步未播放时为 0 是正常现象，
  不得判为失败。

### 4.11 P9-09 播放 / 音量 / EQ（B5 第一段）

用户：把系统输出切到 `… (SoundBridge)` → 在 App 里选物理设备 → 播放任意音频 →
调音量 → 打开 EQ 并拖动 Bass/Mids/Treble。

代理采样（**播放中**才有意义）：
```bash
{ for i in 1 2 3; do
    date +%T
    tail -n 12 /tmp/soundbridge-driver-debug.log
    log show --last 45s --info --predicate 'subsystem == "com.soundbridge.driver"' --style compact | tail -n 6
    sleep 10
  done
} 2>&1 | tee p9-09-playback.log
```
判定：驱动日志出现 `OnStartIO` / `Connected on attempt` / `driver_connected=1`；
音量调节出现 `SoundBridgeVolumeControl: volume changed to …`；
EQ 操作出现 `eq_seq` 递增的日志或 Host 侧 EQ 写入行。**听感与日志需同时记录**，二者不一致时以日志为准并标 `INCONSISTENT`。

### 4.12 P9-10 Host 重启 与 Stop→Start

用户：① 在 App 内触发 Host 重启；② 完全退出 App 后重新启动。
代理在每次动作前后各采一次 §4.10 的进程/映射/日志快照，两次快照之间标注用户动作时间点。
判定：Host PID 变化、映射文件被重新创建（inode 或 mtime 变化）、Session 重新建立、无残留锁阻止重启。

### 4.13 P9-11A 设备移除与重新枚举 / P9-11B 非侵入式对照

**P9-11A**（用户）：拔掉/关闭当前物理输出设备 → 代理采 `system_profiler` 与被代理设备状态 →
用户重新接上 → 代理再采一次。判定：移除时代理设备按设计处理（消失或保持但无输出），
重新接上后恢复可用；**不得**用 `killall coreaudiod` 制造这一场景。

**P9-11B 非侵入式对照（替代 Batch 7 的「关闭 Gatekeeper 前后对照」）**：
在不改动任何系统设置的前提下，比较**同一台机器、同一安装方式**下的两种产物：
| 组 | 产物 | 预期观察 |
|---|---|---|
| 实验组 | 未签名候选（`866f54bd…`） | 记录 L1–L6 全部层级 |
| 对照组 | 已知可加载的已签名产物（例如 Batch 3A 的 ad-hoc RC，驱动 `c2955030…`） | 同样记录 L1–L6 |

若实验组 L2 = NO 而对照组 L2 = YES，且两次安装流程一致 → 可以把原因归到**签名状态差异**上；
若两组都 = NO → 原因不在签名，回到 §6 的 F-3/F-4/F-6 继续定位。
对照组的产物来源与合法性需在报告中注明（它是历史 RC，不是发布产物）。

> Batch 7 §8 第 7 步曾写「关闭 Gatekeeper 前后各做一次对照」，**本批次作废该步**：
> 关闭 Gatekeeper 违反本任务的安全边界，且「关掉之后能加载」本身也不构成分发可行的证据。

### 4.14 P9-12 30 分钟稳定性

用户保持播放 30 分钟（可用循环音频）。代理每 60 秒采样一次：
```bash
{ for i in $(seq 1 30); do
    printf '%s rss=%s map=%s\n' "$(date +%T)" \
      "$(ps -o rss= -p "$(pgrep -x SoundBridgeHost)" 2>/dev/null | tr -d ' ')" \
      "$(wc -c < /tmp/soundbridge-$UID-* 2>/dev/null | tr -d ' ')"
    sleep 60
  done
} 2>&1 | tee p9-12-stability.log
```
结束时追加：
```bash
log show --last 31m --info --predicate 'subsystem == "com.soundbridge.host" OR subsystem == "com.soundbridge.driver"' --style compact > p9-12-tail.log
ls -lt ~/Library/Logs/DiagnosticReports/ | head -5
```
判定：`underrun` / `overrun` 增量 0（或与 Batch 3A 基线一致）；RSS 无单调增长；无新崩溃报告；
映射尺寸恒定。

### 4.15 P9-13 卸载与恢复（用户）

用户执行正式卸载（Installer / App 内卸载 / `tools/uninstall_driver.sh`），随后：
```bash
{ ls -l /Library/Audio/Plug-Ins/HAL/
  pkgutil --pkgs | grep -i soundbridge || echo "receipt: none"
  pkgutil --pkg-info com.soundbridge.menubar 2>&1
  ls -l /tmp/soundbridge-* 2>&1
  system_profiler SPAudioDataType | grep -c -i soundbridge
} 2>&1 | tee p9-13-uninstall.log
```
**预期**：驱动目录消失、回执消失或标记为已卸、映射与锁被回收、设备从枚举中消失。
**注意**：卸载后 `coreaudiod` 可能仍持有已删除 inode，设备要等下次扫描才消失 —— 记录实际观察，不催不强制重启。

### 4.16 P9-14 归档与逐条判定

把 §7 的 10 条验收项逐条填成表格：`证据文件 + 命令 + 原始输出片段 + 判定`。
每条判定只能是 `PASS` / `FAIL` / `NOT_VERIFIED` / `BLOCKED`，并注明 `ARCH=arm64|intel`、`OS=…`、`INSTALL_PATH=first|upgrade`。

---

## 5. 实际执行权限边界

| 动作 | 代理 | 用户 | 备注 |
|---|---|---|---|
| 读 `sw_vers` / `system_profiler` / `csrutil status` / `spctl --status` / `profiles status` | ✅ | — | 只读 |
| `shasum` / `pkgutil --check-signature` / `spctl -a` / `codesign -dv` / `PlistBuddy` | ✅ | — | 只读，不改系统状态 |
| `pkgutil --expand-full` 到临时目录 | ✅ | — | 只读 PKG，临时目录用完即删 |
| `log show` / `tail /tmp/…` / `ps` / `ls` | ✅ | 可提供 | 需 sudo 的部分由用户执行或授权 |
| **安装 PKG** | ❌ | ✅（G2） | 本批次明令禁止代理安装 |
| **卸载驱动** | ❌ | ✅（G4） | 同上 |
| 启动 App、切默认输出、播放、拔插设备 | ❌ | ✅（G3） | 代理只观测 |
| `sudo killall coreaudiod` | ❌ | ❌（除 G5 单独授权） | 本批次与 P-9 默认都不使用 |
| 关闭 Gatekeeper / SIP / 改安全策略 | ❌ | ❌ | 任何情况下都不作为验证手段 |

---

## 6. 失败分类（B6）

| ID | 失败类别 | 判别证据 | 不得得出的结论 |
|---|---|---|---|
| F-1 | **Gatekeeper 拒绝** | 提示「无法验证开发者 / 未签名」；安装未开始；`install.log` 无 `PackageKit` 安装记录；HAL 目录无变化 | 不得说「PKG 坏了」——文件未被执行 |
| F-2 | **PKG 安装失败** | 安装器报错（认证失败、磁盘、`preinstall` 拒绝）；`pkgutil --pkg-info` 有回执但文件缺失或 SHA 不符 | 不得说「驱动不兼容」 |
| F-3 | **HAL 插件加载失败** | L1 通过（文件在）、L2 = NO；`coreaudiod` 日志出现 dlopen / bundle 加载失败 / 签名相关拒绝 | 不得说「驱动初始化失败」——它根本没被加载 |
| F-4 | **Driver 初始化失败** | L2 = YES（有加载证据）但 L3 报错（控制文件缺失、映射打开失败、协议不匹配、owner 校验失败） | 不得说「DSP/音频链路坏了」 |
| F-5 | **Host 启动失败** | L4 有设备但 `SoundBridgeHost` 不在进程表 / 立刻退出；App 日志有 supervisor 退出原因 | 不得说「驱动加载失败」——L2 可能已通过 |
| F-6 | **Shared Memory / Session 失败** | Host 在跑、L2 通过，但映射缺失、`admission`/`producer token` 拒绝、`ValidateConnection` 报错 | 不得说「签名问题」 |
| F-7 | **音频回调失败** | Session 建立但 `driver_connected` 恒 0、无 `OnStartIO`、帧数不增长 | 不得说「稳定性问题」 |
| F-8 | **长时间稳定性失败** | 30 分钟内 underrun/overrun 增长、RSS 单调增长、崩溃报告、映射泄漏 | 不得把前 5 分钟的短暂成功当作通过 |

原则：**每一类都对应不同的责任模块**（系统 / 安装器 / coreaudiod / 插件 / Host / 共享内存 / 实时线程 / 长跑）。
把任一失败笼统写成「Driver 不兼容」视为报告缺陷。

---

## 7. Stage C — 通过标准

完整 PASS 必须同时满足 10 条，且**逐设备（架构 + 系统版本）分别记录**：

| # | 验收项 | 判据 | 证据 |
|---|---|---|---|
| 1 | 未签名 PKG 安装成功 | 安装完成、`pkgutil --pkg-info` 有 `com.soundbridge.menubar` 1.2.0 | `p9-04`、`p9-05` |
| 2 | Driver 正确进入 HAL 目录 | 路径存在、`Info.plist` 的 id/version 正确、可执行文件 SHA = `866f54bd…` | `p9-05` |
| 3 | **有证据证明 `coreaudiod` 实际加载** | L2 = YES（日志 `[SoundBridge INFO]` / 子进程 / lsof 之一以上） | `p9-06` |
| 4 | HAL 设备正常枚举 | `system_profiler` 出现 SoundBridge 设备 | `p9-07` |
| 5 | Host 与 Driver 建立 Session | Host 进程 + 映射文件 + 控制文件 + 无准入拒绝 | `p9-08` |
| 6 | 实际音频播放正常 | 听感 + `OnStartIO` / `driver_connected=1` | `p9-09` |
| 7 | 音量与 EQ 正常 | 音量日志 + `eq_seq` 递增 + 听感 | `p9-09` |
| 8 | Host 重启后恢复正常 | 重启前后 PID 变化、Session 重建 | `p9-10` |
| 9 | 设备移除与重新枚举恢复正常 | 拔插后枚举与输出恢复 | `p9-11a` |
| 10 | 连续播放 ≥30 分钟稳定 | underrun/overrun 增量 0、RSS 稳定、无崩溃 | `p9-12` |

**不得**由「设备出现」单独推出 PASS（第 3、5、6、10 条都是独立证据）。
**不得**把单台 Apple silicon 的结果写成「全平台兼容」；Intel 与 macOS 14 各自需要独立一轮。

---

## 8. 未验证项目（保持 NOT_VERIFIED 的清单）

| ID | 项目 | 现状 | 由哪一步取证 |
|---|---|---|---|
| U-1 | 未签名 HAL 驱动能否被 `coreaudiod` 加载 | **NOT_VERIFIED** | P9-06（L2） |
| U-2 | 未签名 PKG 的真实安装全流程 | **NOT_VERIFIED** | P9-04、P9-05 |
| U-3 | Intel Mac 上的加载与播放 | **NOT_VERIFIED**（无设备） | 第二批 |
| U-4 | macOS 14.x 上的行为 | **NOT_VERIFIED**（无设备） | 第三批 |
| U-5 | 受 MDM 管控设备上的行为 | **NOT_VERIFIED**（且不允许绕过） | 需企业环境，暂不纳入 |
| U-6 | 带 `com.apple.quarantine` 的下载产物与命令行拷贝产物的差异 | **NOT_VERIFIED** | P9-03 记录 xattr，P9-04 记录提示原文 |
| U-7 | 从 ad-hoc 驱动升级到未签名驱动 | **NOT_VERIFIED** | 本机可做，需 G4+G2 |
| U-8 | 30 分钟以上（如 2 小时）长跑 | **NOT_VERIFIED** | 可选后续 |

---

## 9. 后续真机测试安排

| 批次 | 设备 | 场景 | 需要的授权 | 预期产出 |
|---|---|---|---|---|
| P-9 第一轮 | 干净的 Apple silicon（macOS 26/27） | 首次安装 → 加载 → 播放 → 30 min | G1→G2→G3（+G4 卸载） | U-1、U-2 从 NOT_VERIFIED 变为结论；决定 §10 裁决升级或回退 |
| P-9 第二轮 | 本机（Mac mini M4） | 覆盖安装：ad-hoc 驱动 → 未签名驱动 | G4→G2→G3 | U-7；同时验证安装事务对「无 `_CodeSignature`」的替换路径 |
| P-9 第三轮 | Intel Mac | 首次安装 → 加载 | G1→G2→G3 | U-3 |
| P-9 第四轮 | macOS 14.x 机器 | 首次安装 → 加载 | G1→G2→G3 | U-4 |
| 对照 | 任一已装机 | 已签名产物 L1–L6（P9-11B） | G2 | 归因证据（区分「签名缺失」与「其它原因」） |

顺序建议：先做第一轮；**若第一轮 L2 = NO，先做 P9-11B 对照再下结论**，避免把环境问题写成签名问题。

---

## 10. 最终裁决

```
PASS — P-9 VALIDATION READY
```

依据：

1. **Batch 7 的 8 项复核全部通过**（5 项 CONFIRMED、3 项 CONFIRMED WITH OBSERVATION）。
   未发现会让「未签名发布链」失效的问题；6 项观察 + 2 项事实修正已按任务要求**只报告不修改**。
2. **被测对象已冻结且可校验**：`build/p4-batch8/p9-candidate/`（PKG/DMG/App + `SHA256SUMS.txt` +
   逐文件 `APP-FILES.sha256`），`shasum -c` 两行 OK；产物与 Batch 7 的 `dist/`（ad-hoc RC）明确区分。
3. **验证程序可执行**：15 个步骤，每步有命令、执行者、授权门、证据文件与预期；
   关键判定（L2 加载）用三个独立探针，并给出「不能由设备出现推全体」的硬性约束。
4. **失败分类与通过标准已定义**：8 类失败各自对应不同责任模块；10 条验收项逐条绑定证据 ID。
5. **执行边界清晰**：安装/卸载/播放归用户，代理只做只读取证；Batch 7 计划中「关闭 Gatekeeper 做对照」
   的步骤已作废并替换为非侵入式对照。

**本裁决不包含任何执行结果。** 目前在 `U-1`（未签名驱动是否被加载）上仍是
`NOT_VERIFIED`，且本机不具备首次安装资格 —— 这两点是**下一轮的输入**，不是本轮的缺陷：
本批次的任务是「验证准备」，准备已完成。

裁决升级条件：P-9 第一轮 §7 的 10 条全部 PASS → `UNSIGNED DISTRIBUTION VALIDATED (arm64 · macOS 27.x)`；
若第一轮 L2 = NO 且对照证明与签名差异相关 → 回退到 `BLOCKED`，重新评估分发形态。

---

## 附 A：本批次新增证据（`build/p4-batch8/evidence/`）

| 文件 | 内容 |
|---|---|
| `a8-test-unsigned.log` | 68 checks / 0 failures，含分段统计来源 |
| `a8-verify-signatures-dist.log` | `dist/`（ad-hoc RC）被拒：FAIL 2 条（OBS-7 证据） |
| `a8-verify-signatures-unsigned.log` | 候选 bundle `UNSIGNED_APP=PASS`（binaries 8 / linker 3 / authority 0 / sealed 4） |
| `a8-binary-classification.log` | 8 个 Mach-O 的逐个签名分类 |
| `a8-sparkle-fields.log` | 三处 `SUPublicEDKey` 为空、`SUFeedURL` 仍存在、无 appcast |
| `a8-gate-missing-pkg.log` | OBS-1 实证：显式缺失 PKG 仍 `UNSIGNED_RELEASE=PASS` |
| `a8-workflow-steps.log` | 34 个步骤清单、`runs-on: macos-15` |
| `a8-pkg-contents.log` / `a8-pkg-driver.log` | 三向一致；`STRUCTURAL_PASS` + `REQUIREMENT=unsigned` |
| `a8-release-payload.log` | `DRIVER_FOUR_WAY=true`、7 项 PASS |
| `a8-dmg-contents.log` / `a8-version-consistency.log` | DMG PASS；11 源 PASS |
| `a8-device-security-state.log` | 本机 SIP/Gatekeeper/MDM + 未签名驱动 `flags=0x20002` |
| `a8-artifact-fingerprint.log` | 候选 App/Host/Driver 的 SHA 与架构 |
| `a8-candidate-staging.log` | 候选集固化与 `shasum -c` 结果 |

## 附 B：本批次文件变更

**新增 1 个文件**（本报告），位于 `docs/release/`；`git check-ignore` 确认未被忽略。

**新增证据与候选集**（均在 `build/` 下，不进入发布物）：
`build/p4-batch8/evidence/*.log`、`build/p4-batch8/p9-candidate/`。

**未修改**：`.github/workflows/release.yml`、`Makefile`、`tools/*`、`docs/` 下任何既有文件、
`packages/` 下任何文件、`VERSION`、协议头、Bundle ID、`dist/`。

**Git**：`git -C … status` 复核 — HEAD `0b50ae1`、tag `v1.2.0` 指向同一提交、staged = 0；
未执行 stage / commit / push / tag 操作。
