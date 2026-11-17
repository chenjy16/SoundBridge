# SoundBridge 1.2.0

发布日期：2026-11-17
发布类型：**Pre-release（首发测试版）**
Tag：`v1.2.0`

---

## 1. 这一版是什么

SoundBridge 1.2.0 是第一个**同时分发 App 和 HAL 驱动的正式安装包**的版本。此前只分发 App 的 DMG，重装 App 并不能替换 `/Library/Audio/Plug-Ins/HAL/` 里的驱动，于是「装了新版、驱动还是旧版」这件事在用户那边无法自查。

1.2.0 用两条渠道分发：

| 文件 | 内容 |
|---|---|
| `SoundBridge-1.2.0.pkg` | App + 驱动，**升级必须用这个** |
| `SoundBridge-1.2.0.dmg` | 仅 App，用于只更新 App 或查看包内容 |

**两个安装包都没有经过 Apple 公证（notarization），程序使用 ad-hoc 签名。**
这不是 Developer ID 签名，也不是 Installer Package 签名。macOS 无法验证发布者，首次运行会出现一次系统拦截，需要用户在「系统设置 → 隐私与安全性」里手动放行。这是预期行为。

本项目**不要求、也不建议**关闭 Gatekeeper 或 SIP。放行的具体步骤见 [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) 第 4 节。

---

## 2. 从 1.1.2 升级（请先读这段）

**用 PKG，不要用 DMG。**

原因是这一版改了 App 与驱动之间的共享内存协议：

- 1.1.2 的协议版本是 `0x00020000`（131072）。
- 1.2.0 的协议版本是 `0x00020100`（131328），新增了音量状态块（`RFVolumeStateSnapshot`）、共享内存头校验（`rf_validate_header`）和 Host 单实例锁路径。

因此：

- **1.1.2 的驱动配 1.2.0 的 App 不会出声。** App 会显示一条驱动版本/协议不匹配的说明（只有文字，没有「一键修复」按钮），但不会自行替换驱动。
- PKG 会同时替换 App 和驱动，替换过程是一个带备份和回滚的事务。

1.1.2 的驱动 `Info.plist` 里**没有** `SBAudioProtocolVersion` 这个键（该键从 1.2.0 才开始写入）。安装器的预检脚本对这种情况有显式分支：没有协议键时只比较版本号，`1.1.2 < 1.2.0` 判定为升级并放行。所以从 1.1.2 升级**不会**被降级保护误拒。

升级前的建议：先备份现有驱动（见 INSTALLATION_GUIDE 第 9.1 节）。安装器不提供「回退到上一版」按钮。

---

## 3. 新增

### 3.1 安装器（PKG）

- App 与驱动一起安装，驱动不再依赖用户手动拷贝。
- 驱动替换是事务：校验载荷 → 暂存 → 校验副本 → 备份旧驱动 → 重命名换位 → 再次校验；任一步失败则回滚，旧驱动保留或还原。
- 安装失败不会留下「旧驱动已删除、新驱动未写入」的空窗：驱动先落在不被加载的暂存目录，确认无误后才换位。

### 3.2 安装前版本门禁

在写入任何文件之前检查已装驱动的版本和协议：

| 已装状态 | 结果 |
|---|---|
| 更旧（含 1.1.2） | 升级，继续 |
| 相同 | 重装，继续 |
| 更新 | 拒绝，并说明「未写入任何文件」 |
| 协议更新 | 拒绝，不降级线格式 |
| 声明了不认识的协议 | 拒绝 |

拒绝发生在 App 被拷贝进 `/Applications` 之前，不会出现「新版 App + 旧版驱动」的半装状态。

### 3.3 App 内的驱动兼容性说明

当已装驱动与本次构建不匹配（过旧、协议不同、元数据读不出）时，App 显示一段说明文字。这条路径上没有任何安装按钮、没有下载、没有管理员提权、没有 `killall coreaudiod` —— 它只解释问题，不代替用户做决定。

### 3.4 菜单栏 Host 状态行

Host 不在正常状态时，菜单栏弹窗顶部多一行状态说明（例如 Host 未运行、正在重启）。健康状态下界面与之前完全一致。这一行不是按钮，也不是链接。

### 3.5 音量

- 音量映射改为**分贝曲线**（`dB = 48·√s − 48`），不再把滑杆位置当线性振幅。滑杆在低端的手感变化最明显。
- 音量状态（标量、静音）移入共享内存并带原子 revision，App 与 Host 读同一份状态，不再各自计算。
- 按设备持久化音量与静音状态，存于 `~/Library/Application Support/SoundBridge/volume-state.json`，写入有去抖和原子替换。
- 只对**没有可写音量控制**的设备做代理；有硬件音量的设备走系统原生路径。

### 3.6 Host 生命周期

- 音频设备变化（插拔、切换默认设备）时 Host 不再退出。
- Host 用 `flock` 独占锁做单实例判定，替换了原先基于 `pgrep -f` 的字符串匹配 —— 后者会误匹配命令行里含 `SoundBridgeHost` 的无关进程，且两个进程可能同时判定「未运行」。
- SIGINT / SIGTERM 的 dispatch source 被正确持有，Host 能按信号退出。

### 3.7 发布与签名

- App、内嵌 Host、驱动以及 Sparkle 框架内的可执行体全部使用 ad-hoc 签名，`codesign --verify --deep --strict` 通过。
- 驱动与 App 均为 `x86_64 + arm64` 通用二进制。
- 版本号来源统一到仓库根 `VERSION` 文件，`make build` 不再从 git tag 推导版本。

---

## 4. 修复

- Host 在音频设备变化时退出（`keep host alive across audio device changes`）。
- 代理设备在不支持可写音量的设备上仍尝试写音量。
- 代理音量按线性振幅映射，低音量区几乎不可调（改为分贝曲线）。
- SIGINT / SIGTERM 无响应（dispatch source 未持有）。
- DSP 测试在构建目录外运行（改为构建目录内走 ctest）。
- Host 头文件 target 缺少占位 C 文件导致构建失败。

---

## 5. 变更

- 共享内存协议：`0x00020000` → `0x00020100`。**旧驱动与新 App 不兼容**，见第 2 节。
- `RFSharedAudio.h` 从三份副本（App / Host / Driver）合并为 `packages/shared/include/RFSharedAudio.h` 单一来源，三处通过符号链接或构建期复制取得同一份头文件。
- 驱动 `Info.plist` 新增 `SBAudioProtocolVersion` 键。
- 版本号统一为 `1.2.0`：App `CFBundleShortVersionString` / `CFBundleVersion`、驱动两个版本键、Host 源 plist、Installer Package Version、`VERSION` 文件、`Makefile`、构建脚本、CI workflow。

---

## 6. 兼容性

| 项目 | 值 |
|---|---|
| macOS 最低版本 | 13.0 |
| 架构 | `x86_64` + `arm64`（通用二进制） |
| 协议版本 | `0x00020100`（131328） |
| 从 1.1.2 升级 | 支持（必须用 PKG） |
| 全新安装 | 支持 |
| 同版本重装 | 支持 |
| 降级到 1.1.x | 不支持（安装器拒绝，无内置回退按钮） |

Intel 机器使用同一份通用二进制，**但本版本未在 Intel 机器上做真实音频验证**（见第 8 节）。

---

## 7. 已知限制

1. **未公证、ad-hoc 签名。** 首次运行需要用户手动放行；`spctl` 会拒绝该 App（`rejected`），这是 ad-hoc 签名的正常结果，不代表文件损坏。是否放行由用户决定，本版本不提供绕过系统保护的脚本。
2. **PKG 本身未签名。** 没有 Developer ID Installer 证书，安装包没有 Installer 签名链；安装器内的 App/驱动仍有各自的 ad-hoc 签名。
3. **Sparkle 自动更新在本次构建中处于禁用状态。** `SUPublicEDKey` 为空，App 启动时不会初始化 Sparkle；发布页不含 `appcast.xml`。更新请手动下载新版本。
4. **没有内置降级 / 回退按钮。** 回退需要事先备份驱动。
5. **安装器不重启 `coreaudiod`。** 新驱动在 CoreAudio 下一次扫描 HAL 目录时生效（注销重登或重启最可靠）。
6. **Host 二进制的版本无法从文件读取**（`__TEXT,__info_plist` 段不存在），版本一致性以源 `packages/host/Info.plist` 和构建期的 plist 校验为证。

---

## 8. 本次发布的验证状态

如实标注，未执行的项目不写成 PASS。

| 项目 | 状态 |
|---|---|
| 版本号全链一致性（11 项静态来源 + PKG 内 PackageInfo/Distribution/payload） | **EXECUTED**，全部 PASS |
| 从零重建（不复用旧二进制） | **EXECUTED** |
| ad-hoc 签名（11 个嵌套组件）+ `codesign --verify --deep --strict` | **EXECUTED**，全部 rc=0 |
| PKG 结构 / 内容 / 驱动架构 / 签名 / 版本 | **EXECUTED**，全部 PASS |
| DMG 挂载 / 内容 / 版本 | **EXECUTED**，全部 PASS |
| SHA256 生成与校验 | **EXECUTED**，2 个文件均 OK |
| 自动化测试（DSP 1、Host 130、App 129、安装事务 168 场景、签名参数 57、preinstall 门禁 83、PKG 往返 20、驱动校验器 25） | **EXECUTED**，全部通过 |
| 1.1.2 → 1.2.0 门禁判定 | **EXECUTED（模拟）**，在临时根目录对展开后的 preinstall 运行；未执行真实 `installer -pkg` |
| 首次安装 / 同版本重装 / 降级拦截 / 失败回滚 / 卸载 / 恢复 | **NOT TESTED**（需隔离 macOS 环境） |
| CoreAudio 实际加载 1.2.0 驱动 | **NOT TESTED** |
| 真实音频输出 | **NOT TESTED** |
| Intel 机器实机验证 | **NOT TESTED** |

因此本版本标记为 **Pre-release**：打包、签名、结构、版本和门禁语义都有可复现的证据；**真实安装与出声尚未验证**。

---

## 9. 校验值

```
977d79e26ee4f13b06e8ad13df32907b2bb9eb5bfa17d405cc3dd97a36b3ee3b  SoundBridge-1.2.0.pkg
c7f311b05d1760d9c60d27c32ded3adcd74b92b16bcb8969f10e2ed17b0b504a  SoundBridge-1.2.0.dmg
```

以 Release 页面上的 `SHA256SUMS.txt` 为准：

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt
```

---

## 10. 文档

- [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) —— 安装、放行、校验、确认驱动、排查未加载、卸载、回退
- `SHA256SUMS.txt` —— 两个二进制文件的校验和

---

## 11. 反馈

安装失败或驱动未被加载时，请附上以下输出提 issue：

```bash
system_profiler SPAudioDataType | grep -i -A3 soundbridge
log show --last 10m --predicate 'process == "coreaudiod"' 2>/dev/null | grep -i soundbridge | tail -30
codesign --verify --strict --verbose=2 "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
```

以及 `sudo ls -la "/Library/Application Support/SoundBridge/InstallerState/log"` 下的日志。
