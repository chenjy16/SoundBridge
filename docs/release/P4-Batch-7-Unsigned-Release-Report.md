# P4 Batch 7 — Unsigned Release Workflow Remediation

项目：SoundBridge 1.2.0
基线：`main` / HEAD `0b50ae1160960cbfb8f77bd6a5467b75de1ddee6`，tag `v1.2.0`（未改动）
VERSION `1.2.0` ｜ Protocol `0x00020200`（131584）｜ Header 320 bytes
本机环境：macOS 27.2.1 / arm64 ｜ CI 目标：`runs-on: macos-15`
结论：见末尾「最终裁决」

本批**未**创建 GitHub Release、**未**上传资产、**未**改 Tag、**未** stage/commit/push、
**未**安装或卸载 Driver、**未**重启 `coreaudiod`、**未**切换默认输出设备。

---

## 1. 修改文件清单

| 文件 | 操作 | 说明 |
|---|---|---|
| `.github/workflows/release.yml` | 改 | 删除签名/公证/appcast 步骤与密钥 env；新增未签名策略测试与两道未签名门禁 |
| `Makefile` | 改 | `test:` 用 `test-unsigned` 取代 `test-codesign`；`sign:` 改为调用拒绝存根；`verify:` 改调新断言；新增 `verify-unsigned:`；release 链去 sign |
| `tools/codesign.sh` | 重写 | 491 行 → fail-closed 存根（`--help` exit 0，其余 exit 2） |
| `tools/notarize.sh` | 重写 | 109 行 → 同上 |
| `tools/generate_appcast.sh` | 重写 | 90 行 → 同上 |
| `tools/verify_signatures.sh` | 重写 | 由「验证签名有效」改为「断言未签名」 |
| `tools/verify_unsigned_release.sh` | 新增 | app + PKG + DMG + 无 appcast 的整包未签名门禁 |
| `tools/test_unsigned_release.sh` | 新增 | 68 项：静态扫描 + fixture 拒绝测试 |
| `tools/test_codesign_args.sh` | 删除 | 308 行签名参数测试，随签名功能一起移除 |
| `tools/verify_pkg_driver.sh` | 改 | 新增 `--require-unsigned`（exit 5）与 `PKG_DRIVER_REQUIREMENT=` 输出行 |
| `tools/create_app_bundle.sh` | 改 | 拒绝继承 `SPARKLE_ED_PUBLIC_KEY`；强制 `SUPublicEDKey` 为空并复查 |
| `README.md` | 改 | 功能、首次启动、打包命令、发布流水线、自动更新五处 |
| `docs/INSTALLATION_GUIDE.md` | 改 | §0 签名声明、§5.3 驱动加载边界、§8.2.3 完整性检查、§11 自动更新、§12 验证状态表 |
| `docs/RELEASE_NOTES.md` | 改 | 发布类型、§3.11 检查器、§4 规模、§4.1 证据归属、§5 N-9/N-10、§6、§8 |
| `docs/risks/Known-Limitations.md` | 改 | 新增 L-13（A 类）、U-17/U-18（B 类）、P-9（D 类），更新 §6 计数 |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | 改 | §2 测试行、§4 整节、§6 证据归属、§8.2 L-8…L-11、§9 模板 |

```
 .github/workflows/release.yml                      | 128 +++--
 Makefile                                           |  76 +--
 README.md                                          | 127 +++--
 docs/INSTALLATION_GUIDE.md                         |  63 ++-
 docs/RELEASE_NOTES.md                              |  63 ++-
 .../release/SoundBridge-1.2.0-Release-Checklist.md |  47 +-
 docs/risks/Known-Limitations.md                    |  23 +-
 tools/codesign.sh                                  | 527 +++------------------
 tools/create_app_bundle.sh                         |  28 +-
 tools/generate_appcast.sh                          | 124 ++---
 tools/notarize.sh                                  | 161 +++----
 tools/test_codesign_args.sh                        | 308 ------------
 tools/verify_pkg_driver.sh                         |  23 +-
 tools/verify_signatures.sh                         | 288 +++++------
 14 files changed, 660 insertions(+), 1326 deletions(-)
```

**未修改**：`VERSION`、Protocol 常量、`RFSharedAudio.h`（Header 仍 320 bytes）、HAL Driver
架构、`packages/*`、`apps/mac/SoundBridgeApp/Info.plist`（`SUPublicEDKey` 本来就是空）。

**完整 diff**：`build/p4-batch7/evidence/f-full-diff.patch`（3179 行，含两个新脚本全文）。
`docs/P1-…`、`docs/P2-…`、`docs/P3-…`、`docs/manifests/` 等未跟踪文件属于之前批次，本批未触碰。

---

## 2. Stage A — 签名依赖盘点（基线 `0b50ae1`）

行号均指 HEAD 版本。`强制执行` 指「该步骤失败会导致整条 release 失败」。

| # | 依赖 | 位置（基线） | 强制执行 | App | Driver | PKG | DMG | 上传 |
|---|---|---|---|---|---|---|---|---|
| A1 | `codesign --sign` / `--options runtime` | `tools/codesign.sh` 315–412 | 是（workflow 调用） | 是（主程序 + 嵌套） | 是 | 否 | 否 | 阻断 |
| A2 | `security import` / `find-identity` / `create-keychain` | `tools/codesign.sh` 192、193、199、215 | 仅在 Developer ID 分支 | 间接 | 间接 | 否 | 否 | 阻断 |
| A3 | `--options runtime`（hardened runtime） | `tools/codesign.sh` 251–262 | 仅 Developer ID 分支 | 是 | 是 | 否 | 否 | 阻断 |
| A4 | `codesign --verify --deep --strict` | `tools/codesign.sh` 427–438；`tools/verify_signatures.sh` 70–74 | 是 | 是 | 是 | 否 | 否 | 阻断 |
| A5 | `spctl --assess` | `tools/verify_signatures.sh` 126、162；`tools/notarize.sh` 96 | 是（`verify_signatures`） | 是 | 否 | 否 | 否 | 阻断 |
| A6 | `xcrun notarytool submit` | `tools/notarize.sh` 69 | 是（workflow 未调用，但脚本存在且被文档引用） | 是 | 是（随 app） | 否 | 是 | 阻断 |
| A7 | `xcrun stapler staple` | `tools/notarize.sh` 81 | 同上 | 是 | 是 | 否 | 是 | 阻断 |
| A8 | `productsign` | 无（`tools/build_installer_pkg.sh:14` 仅为「不签名」的注释） | 否 | 否 | 否 | **否** | 否 | 不阻断 |
| A9 | Sparkle `generate_appcast` 二进制 | `tools/generate_appcast.sh` 39、71 | 否（workflow 无密钥则跳过） | 否 | 否 | 否 | 是 | 非阻断（条件上传） |
| A10 | `SPARKLE_ED_PRIVATE_KEY` / `SPARKLE_ED_PUBLIC_KEY` | workflow 197、397、398、411、414；`generate_appcast.sh` 47、71 | 否 | 间接（`SUPublicEDKey`） | 否 | 否 | 否 | 非阻断 |
| A11 | `SUPublicEDKey` 注入 | `tools/create_app_bundle.sh` 363–371 | 是（若 env 存在） | 是（updater 开关） | 否 | 否 | 否 | 非阻断 |
| A12 | `SUFeedURL` | `apps/mac/SoundBridgeApp/Info.plist` | 否 | 是（feed 地址） | 否 | 否 | 否 | 否 |
| A13 | appcast 上传 | workflow 475–479 | 否（`if: generated`） | 否 | 否 | 否 | 否 | 非阻断 |
| A14 | `test_codesign_args.sh`（58 项） | `Makefile` 191–198；workflow 187–192 | 是 | 间接 | 间接 | 否 | 否 | 阻断 |

**关键判断**：PKG 与 DMG 只在「是否被签名」这一层与签名相关 —— 基线里没有任何
`productsign`，PKG 从来是未签名的；DMG 也从未被 `codesign` 处理（`create_dmg.sh`
无签名调用）。真正的阻断点在 A1–A7 与 A14：它们让「构建成功」与「签名成功」被绑在一起。

---

## 3. Stage C — 最小改造

### 3.1 workflow（34 步，ruby YAML 解析通过）

删除：`Run signing-argument tests`、`Code Sign App (ad-hoc)`、`Verify Signatures`、
`Generate Sparkle Appcast`、`Upload Sparkle Appcast`、`SPARKLE_ED_PUBLIC_KEY` env。

新增：

```yaml
- name: Run unsigned release policy tests          # make test-unsigned
- name: Verify App Bundle Is Unsigned               # tools/verify_signatures.sh dist/SoundBridge.app
- name: Verify Unsigned Release                     # tools/verify_unsigned_release.sh --app/--pkg/--dmg/--dist
```

`Verify Package Driver` 增加 `--require-unsigned`：一旦提取出的驱动带 Developer ID
签名就 exit 5，而不是像基线那样只在输出里 note。

保留（逐条核对，见 `tools/test_unsigned_release.sh` S-02）：tag/VERSION 一致、组件版本
pin、版本一致性复检、protocol layout、Universal 四段构建、`verify_installer_pkg`、
`verify_pkg_contents`、`verify_pkg_driver`、`verify_release_payload`、SHA256SUMS 生成
与复核（必须 2 行）、五资产按名校验、`fail_on_unmatched_files: true`。

### 3.2 三个签名入口改为 fail-closed 存根

`codesign.sh` / `notarize.sh` / `generate_appcast.sh` 保留文件名与 `--help`（exit 0），
其余任何调用打印政策说明并 **exit 2**。`make sign` 因此从「静默什么都不做」变成「响亮
失败」。旧实现留在 git 历史 `0b50ae1`。

### 3.3 Ad-hoc 残留的调查结论（不是「当作未签名」）

| 残留 | 来源 | 是否本项目产生 | 处理 |
|---|---|---|---|
| 8 个 Mach-O 中 3 个带 `flags=0x20002(adhoc,linker-signed)` | `ld64` 自动写入 | 否（链接器行为） | 保留。实测 `codesign --remove-signature` 后 arm64 进程被内核 `killed`（rc=137）；这是平台可达的最小状态 |
| `Sparkle.framework` 等 4 个 bundle 的 `_CodeSignature`（`flags=0x10002(adhoc,runtime)`，`Sealed Resources rules=13 files=76`） | Sparkle 2.10.1 SwiftPM 二进制产物自带 | 否（第三方） | 保留并在 `verify_signatures.sh` 中仅以 NOTE 列出。删除需重签（禁止）或剥离（`@rpath` 加载失败） |
| App / Driver / PKG / DMG 外层 bundle 封印 | 无 | — | 已确认为零：`codesign --verify --strict` 全部 `code object is not signed at all` |

`verify_signatures.sh` 用 4 条断言把状态钉死：bundle 未封印（`--verify --strict` 必须
非 0 且无 `Contents/_CodeSignature`）、无 `Authority`/`TeamIdentifier`、`SUPublicEDKey`
为空、`spctl` 必须拒绝。任何一条反向即为 `UNSIGNED_APP=FAIL`。

---

## 4. Stage B — 未签名构建可行性（10 问）

| # | 问题 | 结论 | 证据 |
|---|---|---|---|
| 1 | App 能否不 codesign 构建 | **能** | `create_app_bundle.sh` → 8 个 Mach-O，无 bundle 封印 |
| 2 | Driver 能否不 codesign 构建 | **能** | `build_release.sh` 产出的 `.driver`，`codesign --verify --strict` rc=1 |
| 3 | PKG 能否不签名生成 | **能** | `build_installer_pkg.sh` rc=0，`pkgutil --check-signature` → `Status: no signature` |
| 4 | DMG 能否不签名生成 | **能** | `create_dmg.sh --backend hdiutil` rc=0，`codesign -dv` → `not signed at all` |
| 5 | 打包工具是否隐式签名 | **否** | `create_dmg.sh` / `build_installer_pkg.sh` 无 `codesign`/`productsign`；DMG 无签名 |
| 6 | 构建系统是否自动生成 ad-hoc | **是，但仅为 linker stamp** | `ld64` 给每个 Mach-O 写 `adhoc,linker-signed`；没有 bundle 封印、没有身份 |
| 7 | Swift/Xcode 构建设置是否强制签名 | **否** | SwiftPM 命令行构建不调用 `codesign`；产物只有 linker stamp |
| 8 | Framework / 嵌套 bundle / Driver 是否残留签名 | **是（仅 Sparkle）** | 4 个 `_CodeSignature` 全部属 `Sparkle.framework` 及其内嵌 XPC/Updater；本项目组件为 0 |
| 9 | PKG 安装流程是否依赖签名身份 | **静态上否** | 展开的 `PackageInfo`：`relocatable="false" ... auth="root"`；`preinstall`/`postinstall` 不含 `codesign`/`spctl`/`xattr`/`notar`/`stapler` |
| 10 | 目标 macOS 是否允许加载未签名 HAL Driver | **NOT VERIFIED** | 见下 |

### 4.1 第 10 问的四级区分（不得互相证明）

| 层级 | 状态 | 依据 |
|---|---|---|
| ① 构建成功 | VERIFIED | 本机构建产物存在，8 个 Mach-O 结构完整 |
| ② PKG 安装成功 | NOT VERIFIED | 本批禁止安装；只有结构/载荷/脚本静态证据 |
| ③ Driver 被系统接受（拷入 HAL 目录即成功） | NOT VERIFIED | 同上 |
| ④ **HAL Driver 实际被 `coreaudiod` 加载** | **NOT VERIFIED** | 需真实安装 + 观察 `system_profiler`/`coreaudiod` 日志 |

①–③ 都不构成 ④ 的证据。历史上 HAL 插件目录对签名的要求随 macOS 版本变化，且受
MDM/SIP 影响；本批没有 macOS 14 环境，也没有 Intel Mac。后续任务见 §8 P-9。

### 4.2 产物指纹

| 产物 | SHA-256 | 大小 |
|---|---|---|
| `SoundBridge-1.2.0.pkg` | `2d559df21a97207012162d5f7d4bb3bbe2217d66840a22405d8356c52f9e5979` | 14364638 B |
| `SoundBridge-1.2.0.dmg` | `e4bcd724a1c98f6794dfe6402f9a10283a4fc77bebf523cecc8f688e7853cf7e` | 14936396 B |

`spctl`：App `rejected / source=no usable signature`（rc=3）、PKG 同、DMG 同（rc=3）。
这三条是**期望值**，已被 `verify_unsigned_release.sh` 断言。

---

## 5. Stage D — 安装与安全边界

| 边界 | 事实 | 不承诺什么 |
|---|---|---|
| 未签名 App | Gatekeeper 拒绝首次启动；需「系统设置 → 隐私与安全性 → 仍要打开」（旧系统支持右键打开） | 不承诺双击即开 |
| 未签名 PKG | Installer 同样被拦；需一次手动批准。授权是安装器自身的 root 授权，与签名无关 | 不承诺无人值守安装 |
| 未签名 HAL Driver | `preinstall` 不依赖签名，但 `coreaudiod` 是否加载**未验证** | 不承诺驱动一定能被系统接受 |
| macOS 版本差异 | 只在 macOS 27.2.1（arm64）上做过构建与结构校验；macOS 14、Intel、受管控设备均未验证 | 不承诺「全版本可用」 |
| 系统安全策略 | 明确**不**建议关闭 Gatekeeper/SIP；不提供 `spctl --master-disable` | 不承诺任何绕过系统策略的方法 |
| 受管控组织 | 若 MDM/策略禁止未签名软件，本版本**无法安装** | 不提供企业分发替代方案 |

上述边界同时写入 `docs/INSTALLATION_GUIDE.md` §0/§5.3/§12 与
`docs/risks/Known-Limitations.md` L-13、U-17、U-18。

---

## 6. Stage E — 测试结果

| 检查 | 命令 | 结果 |
|---|---|---|
| 未签名策略（静态 + fixture） | `./tools/test_unsigned_release.sh` | **68 checks / 0 failures**，rc=0 |
| 整包未签名门禁 | `./tools/verify_unsigned_release.sh` | `UNSIGNED_RELEASE=PASS`，6 checks / 0 failures |
| App bundle 未签名断言 | `./tools/verify_signatures.sh` | `UNSIGNED_APP=PASS`；binaries 8、linker_signed 3、with_authority 0、sealed_vendor 4 |
| 签名依赖静态清除 | 见 `e-static-signing-clearance.log` | workflow 9 类 token 全 0；tools 无 `--sign`/`notarytool`/`stapler`/`productsign`/`find-identity`/`--options runtime` |
| workflow 结构 | ruby YAML | 解析通过，34 steps，`runs-on: macos-15` |
| VERSION / Protocol | `verify_version_consistency.sh`、`make protocol-check` | 11 源 PASS，`VERSION_CONSISTENCY=PASS`，`SBAudioProtocolVersion=131584` |
| 安装器门禁 | `tools/test_installer_preinstall.sh` | 83 passed / 0 failed |
| PKG 往返 | `tools/test_installer_pkg_roundtrip.sh` | 20 passed / 0 failed |
| 安装包结构 | `verify_installer_pkg.sh` / `verify_pkg_contents.sh` / `verify_pkg_driver.sh --require-unsigned` | PASS / PASS / `STRUCTURAL_PASS` + `PKG_DRIVER_REQUIREMENT=unsigned` |
| DMG 内容 | `verify_dmg_contents.sh` | PASS（四架构 PASS，PROTOCOL_VERSION=131584） |
| 四向一致性 | `verify_release_payload.sh` | 7 项 OVERALL_RESULT=PASS |
| workflow 尾部四步干跑 | `build/p4-batch7/scratch/dry-run-release-tail.sh` | `DRY_RUN_RELEASE_TAIL=PASS`（Stage Documents → Checksums → Verify → Assets，五资产齐备） |
| bundle 强制空 key | `create_app_bundle.sh`（无 env / 有 env） | 无 env：`SUPublicEDKey` 为空、rc=0；`SPARKLE_ED_PUBLIC_KEY=abc123`：rc=1 并拒绝 |

### 6.1 一个必须记录的发现

`make verify` 在当前工作区的 `dist/` 上 **失败**（`UNSIGNED_APP=FAIL`，2 条断言）：
`dist/SoundBridge.app` 是**上一批带 ad-hoc 签名**的产物，带 `Contents/_CodeSignature`
与 Driver 封印。断言按设计拒绝了它。用同一条命令对本次新构建的 bundle 运行则
`UNSIGNED_APP=PASS`。这说明门禁真的在门禁，而不是恒真。
（`dist/` 属禁改范围，未重建；正式发布时 workflow 的 `Create App Bundle` 会重新生成。）

### 6.2 测试验证 vs 真实 Mac 验证

- **测试验证**：上表全部条目。它们证明「构建链里没有签名」「产物的签名状态符合断言」
  「结构与一致性检查在未签名产物上仍然工作」。
- **真实 Mac 验证**：本批**零**新增。安装、驱动加载、发声、音量/EQ 全部未执行。

### 6.3 未触发的部分

正式 `release` workflow 未触发（它只响应 `release: published`）；未创建 Release、未上传。

---

## 7. Stage F — 文档审计

| 文档 | 关键改动 |
|---|---|
| `README.md` | Features 增「Unsigned and unnotarized」；Installation 提示块改写（未签名、`spctl` 预期拒绝、手动放行、受管控组织无法安装、驱动加载未验证）；打包命令表加 `verify-unsigned`、`make sign` 标注 exit 2；Release Pipeline 六步无签名 + 「No secrets are required」；Auto-updates 改为「There is no update channel」 |
| `docs/INSTALLATION_GUIDE.md` | §0 由「ad-hoc 签名」改为完全未签名并解释 linker ad-hoc；§5.3 新增驱动加载四级区分表；§8.2.3 由 `codesign --verify` 期望 `valid on disk` 改为「不可用 codesign 验，改用 SHA256 + bundle id」；§11 说明无 appcast 且 `generate_appcast.sh` 拒绝；§12 表新增 5.3 行与「未验证环境」段 |
| `docs/RELEASE_NOTES.md` | 发布类型改「完全未签名」；§3.11 两个新检查器 + bundler 拒 key；§4 规模表「签名参数 58」→「未签名发布策略 68」；§4.1 加**证据归属**注记（那批证据取自 ad-hoc RC，未在新产物重跑）并改写第 3、5 行；§5 新增 N-9/N-10；§6 与 §8 结论改写 |
| `docs/risks/Known-Limitations.md` | 新增 L-13（策略 + 残留 + 第三方例外 + Gatekeeper 后果 + 构建期约束）、U-17（驱动加载）、U-18（PKG 真实安装）、P-9（真机验证要求）；§6 计数 12/16/8 → 13/18/9 |
| `docs/release/SoundBridge-1.2.0-Release-Checklist.md` | §2 测试行替换；§4 由「打包与签名」改「打包（不签名）」并列出预期失败/预期拒绝；§6 加证据归属警告；§8.2 新增 L-8…L-11；§9 发布记录模板改签名行 |

**路径差异（需说明）**：任务书要求更新 `docs/1.2.0/Known-Limitations.md`，该路径不存在；
仓库中的正式限制登记处是 `docs/risks/Known-Limitations.md`，本次改的是后者。

**审计结论**：五份文档中不再存在「ad-hoc 签名 / 已公证 / 支持自动更新」的表述；
所有未验证项保持 `NOT_VERIFIED`，没有把未验证写成已验证。
`docs/P1-…`、`docs/P3-…`、`docs/P4-Release-Readiness-Audit-Report.md` 等历史报告保留原样
（它们是当时的证据快照，改写会伪造历史）。

---

## 8. 后续真实 Mac 验证计划（P-9）

| 步骤 | 动作 | 通过判据 |
|---|---|---|
| 1 | 干净 Apple silicon Mac（macOS 14 与一台 Intel Mac 各一次），下载 PKG 与 `SHA256SUMS.txt` | `shasum -c` 两行 OK |
| 2 | 记录 `pkgutil --check-signature`、`spctl -a -t install`、`codesign -dv` 原始输出 | 与本文 §4.2 一致（`no signature` / `rejected` / `not signed at all`） |
| 3 | 双击 PKG，走完手动批准 → 安装 | 安装器完成；`/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` 存在 |
| 4 | `system_profiler SPAudioDataType \| grep -i soundbridge` | **出现设备**（这是第 ④ 层第一次取证） |
| 5 | 若无设备：`log show --last 10m --predicate 'process == "coreaudiod"'` | 收集拒绝原因（是否与未签名相关） |
| 6 | 启动 App → 选 SoundBridge → 选物理设备 → 播放 30 分钟 | 有声；`underrun` 增量 0 |
| 7 | ~~关闭 Gatekeeper 前后各做一次对照~~ **本条已作废（Stage A / OBS-6，2026-11-21）** | 该步骤要求临时关闭系统安全保护，与 1.2.0 发布规则（不关闭 Gatekeeper / SIP、不降低系统安全）冲突。替代做法：保持 Gatekeeper 与 SIP 开启，只记录 `spctl` 的拒绝原文、`pkgutil --check-signature` 输出与 `coreaudiod` 拒绝日志，用这些证据判断限制是否来自签名缺失 |
| 8 | 卸载 → 重装（U-16） | 设备消失/恢复；旧 inode 不复活 |

在步骤 4 得到真实输出之前，`UNSIGNED HAL DRIVER LOADABLE` 一律记为 **NOT VERIFIED**。

---

## 9. 最终裁决

```
CONDITIONAL PASS — DRIVER LOADING REQUIRES REAL MAC VALIDATION
```

理由：

- 签名依赖已在**代码层完全清除**：workflow 九类 token 全 0，`tools/` 无签名调用，
  三个入口 fail-closed，密钥注入路径被堵死（`create_app_bundle.sh` 拒绝继承 env）。
  → 不构成 BLOCKED。
- 未签名产物**可构建、可打包、可自检**：PKG/DMG 生成成功，8 个既有 verifier 全部通过，
  68 项策略测试 + 6 项整包门禁 + workflow 尾部四步干跑全绿。
  → 满足「READY FOR RC BUILD」。
- 但「未签名 HAL 驱动会被 `coreaudiod` 加载」是**分发可行性的前提**，而它是
  **NOT VERIFIED** —— 受「不安装、不重启 CoreAudio」约束，本批无法取证。
  → 不能给无条件 PASS。

下一步：按 §8 在一台可自由操作的 Mac 上执行 P-9 的 1–4 步（不必先做 8 小时/多设备）。
若第 4 步出现设备，本项即可升级为 `PASS — UNSIGNED WORKFLOW READY FOR RC BUILD`；
若系统明确拒绝加载未签名驱动，则必须回到 `BLOCKED`，重新评估分发形态
（例如只分发 App、或接受「驱动需用户自签名」的边界）。

---

## 附：证据索引（`build/p4-batch7/evidence/`）

| 文件 | 内容 |
|---|---|
| `f-full-diff.patch` | 完整 diff（含两个新脚本全文） |
| `e-static-signing-clearance.log` | 签名依赖静态清除审计 |
| `e-test-unsigned-release-final.log` | 68 checks / 0 failures |
| `e-verify-unsigned-release-final.log` | `UNSIGNED_RELEASE=PASS` |
| `e-verify-signatures-newbundle.log` | 新 bundle 的 `UNSIGNED_APP=PASS` |
| `e-make-verify-on-stale-dist.log` | 旧 ad-hoc `dist/` 被正确拒绝（`FAIL`，2 条断言） |
| `e-create-bundle-keyless.log` / `e-create-bundle-key-refused.log` | 空 key 强制 / 带 key 拒绝 |
| `e-workflow-yaml-final.log` | 34 steps、`runs-on: macos-15` |
| `e-dry-run-release-tail.log` | Stage Documents → Checksums → Verify → Assets |
| `e-version-protocol-final.log` | 版本 11 源一致、protocol 131584 |
| `e-test-installer-gate.log` / `e-test-pkg-roundtrip.log` | 83 passed / 20 passed |
| `b-unsigned-*.log`、`b-verify-*.log` | Stage B 的构建与各 verifier 输出 |
