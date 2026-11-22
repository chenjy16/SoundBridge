# SoundBridge 开发指南

本文是 SoundBridge 1.2.0 的**唯一**开发入口：环境准备、目录结构、构建、测试、
发布、常见故障与贡献规则。

本文只写仓库里**真实存在**的命令。所有 `make` 目标都出自根目录
[Makefile](../../Makefile)，所有脚本路径都可在 `tools/` 下找到。若某条命令
无法在干净 checkout 上执行成功，那是缺陷，应当报告而不是绕开。

相关文档：
- 架构与机制：[architecture/SoundBridge-1.2.0-Architecture.md](../architecture/SoundBridge-1.2.0-Architecture.md)
- 已知问题：[risks/Known-Limitations.md](../risks/Known-Limitations.md)
- 安装与卸载（面向用户）：[INSTALLATION_GUIDE.md](../INSTALLATION_GUIDE.md)

---

## 1. 开发环境

| 项 | 要求 | 说明 |
|---|---|---|
| macOS | 13.0+ | 与 `Package.swift` 的 `.macOS(.v13)` 及各 `Info.plist` 的 `LSMinimumSystemVersion` 一致 |
| Xcode 命令行工具 | 必需 | `xcode-select --install`；提供 `swift`、`clang`、`lipo`、`codesign` |
| CMake | 必需 | `brew install cmake`；构建 DSP 与 HAL 驱动 |
| git | 必需 | 用于 submodule |
| libASPL | 必需（submodule） | `packages/driver/vendor/libASPL`，来自 <https://github.com/gavv/libASPL> |

本轮开发与发布验证使用的版本：Apple Swift 6.4.2、CMake 4.2.1、libASPL
`633e0f7`。这些是观测值，不是硬性下限。

依赖自检：

```bash
make install-deps
```

该目标只检查 `cmake` 与 `swift` 是否存在，其余依赖在构建时才暴露。

### 1.1 Submodule

驱动依赖 libASPL，克隆后必须初始化，否则 CMake 配置阶段会失败
（`does not contain a CMakeLists.txt file`）：

```bash
git clone https://github.com/chenjy16/SoundBridge.git
cd SoundBridge
git submodule update --init --recursive
```

## 2. 目录结构

```
SoundBridge/
├── apps/mac/SoundBridgeApp/     菜单栏 App（SwiftUI，SwiftPM 包）
│   ├── Sources/
│   │   ├── App/                 入口与生命周期
│   │   ├── Views/               MenuBarView、SettingsWindow、BasicEQView
│   │   ├── Services/            VolumeController、IPCController、EQController、DriverInstaller…
│   │   ├── Onboarding/          引导流程
│   │   ├── Models/              状态模型
│   │   └── CSoundBridgeAudio/   共享头与 C shim
│   ├── Tests/SoundBridgeAppTests/
│   └── Info.plist
├── packages/
│   ├── dsp/                     EQ 与增益引擎（C++，暴露 C ABI）
│   │   ├── include/             soundbridge_dsp.h
│   │   ├── src/                 biquad、engine、preset
│   │   ├── bridge/              Objective-C++ 包装（供 Swift 调用）
│   │   └── tests/
│   ├── driver/                  HAL 虚拟驱动（C++，CMake bundle）
│   │   ├── src/                 Plugin.cpp、设备对象、控制协议
│   │   ├── include/             RFSharedAudio.h（与 shared 同步）
│   │   ├── tests/               三个纯 C++ 测试套件
│   │   └── vendor/libASPL/      submodule
│   ├── host/                    Host 进程（SwiftPM 包）
│   │   ├── Sources/SoundBridgeHost/{Audio,Devices,Memory,Lifecycle,Services}
│   │   └── Tests/SoundBridgeHostTests/
│   └── shared/include/          RFSharedAudio.h 的唯一事实源
├── tools/                       构建、打包、校验、卸载脚本
├── docs/                        工程文档（见 docs/README.md）
├── Makefile                     所有日常命令
└── VERSION                      单一版本号来源
```

## 3. 技术栈

| 组件 | 语言 / 框架 | 构建系统 |
|---|---|---|
| App | Swift 5/6 + SwiftUI + AppKit | SwiftPM |
| Host | Swift + CoreAudio/AudioToolbox | SwiftPM |
| Driver | C++17 + `libASPL`（AudioServerPlugIn） | CMake（`MODULE` bundle） |
| DSP | C++（对外 C ABI） | CMake 静态库 + CTest |
| 共享协议 | C 头文件（C11 与 C++17 双语言校验） | 无（头文件） |

跨进程契约只有一处：`packages/shared/include/RFSharedAudio.h`。仓库中另有三份
字节一致的副本（driver / host / app 各自的 include 路径），由
`tools/sync_shared_header.sh` 同步、`tools/check_protocol_layout.sh` 校验。

## 4. 构建

### 4.1 全量

```bash
make build      # protocol-check + update-version + tools/build_release.sh
make bundle     # 组装 dist/SoundBridge.app
make run        # 打开已构建的 App
```

`make build` 的第一步是 `protocol-check`，这不是可选项：四份头副本不一致时，
产物会带着不匹配的 ABI 静默出厂。第二步 `update-version` 把 `VERSION`
写进各组件。

产物在 `dist/SoundBridge.app`（`dist/` 与 `Package.resolved` 均被 gitignore）。

### 4.2 增量

```bash
make quick      # 只重建 Swift 组件，仍出 universal
make rebuild    # clean + build + bundle
```

`make quick` 分别以 `arm64` 与 `x86_64` triple 构建到独立 scratch 路径，
再用 `lipo` 合并；它同时把 `Sparkle.framework` 复制进
`.build/universal/release`，否则 bundle 启动时 `@rpath` 解析失败。

### 4.3 单组件

```bash
# DSP 静态库（Host 通过相对路径链接它，必须先构建）
make dsp-build

# HAL 驱动
cmake -S packages/driver -B packages/driver/build -DCMAKE_BUILD_TYPE=Release
cmake --build packages/driver/build

# Host
cd packages/host && swift build -c release

# App
cd apps/mac/SoundBridgeApp && swift build -c release
```

驱动装上后要让 `coreaudiod` 重新加载：注销/重新登录，或由你自己执行
`sudo killall coreaudiod`。**产品里没有任何组件替你重启音频守护进程**，这是
刻意的策略（见架构文档与 `Known-Limitations` OBS-3）。

## 5. 测试

```bash
make test
```

`make test` 依次执行：`protocol-check`、`version-check`、`test-dsp`、
`test-driver`、`test-host`、`test-app`、`test-installer`、`test-unsigned`。
任何一步失败即中止。

| 目标 | 覆盖内容 | 是否需要 sudo / 真实驱动 |
|---|---|---|
| `make protocol-check` | 单一协议源 + 四份头副本一致 + C11/C++17 布局断言 | 否 |
| `make version-check` | 全部版本源与 `VERSION` 一致 | 否 |
| `make test-dsp` | DSP 单元测试（biquad、engine、frequency response、preset、smoothing） | 否 |
| `make test-driver` | 控制协议、producer token、mapping retirement；在 `mktemp` 临时目录构建，绝不写入 `packages/driver/build` | 否 |
| `make test-host` | 共享内存协议/文件系统/多进程、Ring 契约、Admission、CallbackGate 原子性、生命周期、Host 单实例、恢复路径 | 否 |
| `make test-app` | 版本门禁、安装边界、卸载策略、EQ 生命周期与恢复、Host 监督与重启入口、映射并发 | 否 |
| `make test-installer` | 安装事务（每场景独立临时目录 + 伪造驱动 bundle）+ 卸载生命周期（`tools/test_uninstall_lifecycle.sh` 用 `--sandbox-root` 在 `mktemp` 树上**真实执行**卸载脚本，19 组场景 / 99 断言） | 否 |
| `make test-installer-gate` | 已构建 PKG 的 preinstall/postinstall 门禁；`PKG=<path>` 指定，缺省取 `build/` 下最新包 | 否 |
| `make test-unsigned` | 未签名发布策略：静态扫描（签名/公证/appcast 不得回归）+ fixture 断言（封印 bundle 必须被拒） | 否 |

所有测试套件都不接触真实的 `/Library/Audio/Plug-Ins/HAL/`，也不需要安装驱动。
`make test-host` 依赖 `dsp-build`（Host 链接预构建的 DSP 静态库）。

### 5.1 卸载生命周期测试怎么跑

```bash
./tools/test_uninstall_lifecycle.sh          # 单独跑，或经 make test-installer
```

它不碰真实系统：每个场景在自己的 `mktemp -d` 根里造出 HAL bundle、`/tmp` 下的
共享内存文件、控制文件、receipt 标记与 App 占位，然后以 `--sandbox-root` 让脚本
在**同一个根**下真实执行卸载，再断言哪些被删、哪些被保留、退出码与报告文本。

有几类断言依赖运行环境，拿不到时会**打印原因并跳过**，不会假装通过：

- 进程相关场景需要能读到进程表（`ps`、`pgrep`）。受限环境（例如沙盒里的 CI）读
  不到时跳过，并说明是哪一个探针失败。
- Host fixture 由 `clang` 现场编译（`command -v clang`）。复制系统二进制在 macOS
  上会被立刻 SIGKILL，不能当 fixture 用；没有可用编译器时跳过进程场景。
- `--sandbox-root` 与 `ps -o comm=` 都用物理路径（`pwd -P`），因为 `/var` 是
  `/private/var` 的符号链接，逻辑路径永远匹配不上。

## 6. 发布与校验

发布物是**完全未签名**的：没有 Developer ID、没有 ad-hoc 签名、没有 PKG 签名、
没有公证、没有 appcast。签名相关脚本是 fail-closed 存根，只用来大声失败。

```bash
make verify             # 断言 .app 未签名（无封印、无身份、SUPublicEDKey 为空）
make verify-unsigned    # 断言 app + PKG + DMG 均未签名且无 appcast
make dmg                # 生成拖拽式 DMG
make full-release       # build + verify + DMG
make sign               # 拒绝执行（exit 2）
```

只读校验（对 `dist/` 中已有产物）：

```bash
make verify-pkg           # 包内两份驱动与 dist/ 中 bundle 一致
make verify-dmg           # 只读挂载镜像并检查其中的 App
make verify-payload       # 上述全部 + 镜像内驱动（四方比对）
make verify-installer-pkg # 包的载荷与 pre-payload 版本门禁
make test-release-payload # 对校验器本身做破坏测试
```

CI 侧：`.github/workflows/release.yml` 由 `release: published` 触发，校验
`VERSION`/tag/各组件一致、构建 universal、断言未签名、打包 PKG 与 DMG、上传资产。
流水线不需要任何 secret。**文档方面的硬依赖**：`docs/INSTALLATION_GUIDE.md` 与
`docs/RELEASE_NOTES.md` 会被 workflow 复制进 `dist/` 并校验版本号，这两个路径
不得移动。

## 7. 代码地图（改哪里）

| 想改的东西 | 位置 |
|---|---|
| 音量曲线（线性 dB taper） | `apps/mac/SoundBridgeApp/Sources/Services/VolumeController.swift`、驱动侧音量控制对象、Host 侧增益应用 |
| 音量/静音「是否真的生效」 | `Services/VolumeLevelControl.swift`（写入 + 回读判定）、Host 侧 `Devices/DeviceVolumeHAL.swift` 与 `Devices/ProxyDeviceManager.swift` 的提交路径 |
| EQ 控件与映射 | `Views/BasicEQView.swift`、`Services/EQController.swift`（3 个宏控件 → 10 段权重） |
| EQ 持久化 | `Services/EQController.swift` 的 `EQDefaultsKey` / `EQPersistedState`（单 key 字典、字段级校验、1.2.0 四 key 迁移） |
| EQ 实际作用点 | `packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift` 的渲染回调 |
| 共享内存布局/字段 | `packages/shared/include/RFSharedAudio.h`（改字段必须升协议版本并同步四份副本） |
| Ring 语义 | `packages/shared/include/RFSharedAudio.h` 的 `rf_ring_*`，契约见 [engineering/RingBuffer-Design.md](../engineering/RingBuffer-Design.md) |
| 驱动写入/格式转换 | `packages/driver/src/Plugin.cpp` 与设备对象 |
| 准入 / 排空 / 退役 | 驱动侧 `CallbackGate`、`RetireMapping`，见 [engineering/](../engineering/) |
| 设备发现与控制文件 | `packages/host/Sources/SoundBridgeHost/Devices/` |
| 安装/卸载门禁 | `tools/build_installer_pkg.sh`、`tools/sb_install_transaction.sh`、`tools/uninstall_driver.sh` |
| 卸载行为的回归测试 | `tools/test_uninstall_lifecycle.sh`（沙盒真实执行）、`apps/mac/SoundBridgeApp/Tests/SoundBridgeAppTests/UninstallLifecycleScriptTests.swift`（源码不变量） |

## 8. 贡献规则

1. **协议优先**：任何 `RFSharedAudio.h` 的字段增删或顺序变化都要提升
   `RF_AUDIO_PROTOCOL_VERSION`，并用 `tools/sync_shared_header.sh` 同步四份
   副本；`make protocol-check` 必须在提交前通过。
2. **实时约束**：HAL 写回调与 Host 渲染回调内不得加锁、不得分配、不得做
   阻塞 I/O、不得调用会写磁盘的日志。相关论证见
   [engineering/CallbackGate-Memory-Model.md](../engineering/CallbackGate-Memory-Model.md)。
3. **不引入签名、公证或自动更新**：`make test-unsigned` 会扫描 Makefile、
   workflow 与 `tools/`；新增一条 `codesign --sign` 就会让它失败。
4. **未验证就写未验证**：文档与提交说明里，测试覆盖不到的行为标注
   `NOT_VERIFIED`，不写「应该」「大概」。
5. **改产品行为要同步文档**：架构/协议变化更新
   [architecture/](../architecture/) 与 [engineering/](../engineering/)；
   风险状态变化更新 [risks/Known-Limitations.md](../risks/Known-Limitations.md)。
6. **不要把 `dist/` 的产物当证据**：`dist/` 被 gitignore，且可能来自旧的
   commit；发布证据一律落在 `build/<批次>/evidence/` 并由报告引用。

## 9. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `does not contain a CMakeLists.txt file` | submodule 未初始化 | `git submodule update --init --recursive` |
| `make run` 报 bundle 不存在 | 未构建或已 `make clean` | `make build && make bundle` |
| Host 链接不到 DSP 符号 | 未构建 DSP 静态库 | `make dsp-build`（`make test-host` 会自动先跑） |
| 驱动改了但行为没变 | `coreaudiod` 仍持有已加载副本 | 注销/重启，或自行 `sudo killall coreaudiod` |
| 装了新 App 仍无声 | 驱动旧于 App，协议不匹配 | 用 PKG 重装驱动；协议当前为 `0x00020200` |
| App 启动时报 `@rpath/Sparkle.framework` 找不到 | 增量构建未把 framework 复制进 universal 目录 | 用 `make quick`（已包含该步骤）或 `make build` |
| 双击 PKG 被 Gatekeeper 拒绝 | 发布物完全未签名（预期） | 系统设置 → 隐私与安全性 → 仍要打开；**不要**关闭 Gatekeeper 或 SIP |
| `pkgutil` 显示旧回执 | 卸载机制不清理 PKG 回执 | 已知限制 OBS-3，不是安装失败 |
| 音量/静音设置"没生效" | 无 I/O 客户端窗口时属性写入可能不提交 | 播放中重新设置一次（OBS-1） |

更多环境相关问题见 [risks/Known-Limitations.md](../risks/Known-Limitations.md)。
