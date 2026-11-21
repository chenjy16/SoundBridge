# SoundBridge 1.2.0 — 安装与卸载指南

本文面向**从 GitHub Release 下载** SoundBridge 的用户，不需要本地编译。

版本：`1.2.0` ｜ App/驱动协议：`0x00020200`（131584）

---

## 0. 先读这一段

SoundBridge 由两部分组成：

| 组件 | 位置 | 作用 |
|---|---|---|
| **SoundBridge.app** | `/Applications/` | 菜单栏应用：控制、均衡器、Host 生命周期 |
| **SoundBridgeDriver.driver** | `/Library/Audio/Plug-Ins/HAL/` | macOS 音频驱动，向系统注册虚拟输出设备 |

只安装 App 是不够的：驱动在系统目录里，只有安装包能写入。**因此有两个下载文件，用途不同。**

**本版本完全未签名，也未公证。** 没有 Developer ID 签名，没有 ad-hoc 签名，PKG 没有
签名，整个发布没有经过 Apple notarization。macOS 无法验证发布者或完整性，首次运行 App
与 PKG 时都会拦下，需要按要求手动批准一次（第 5 节）。这是预期行为，不是安装失败。
本项目不提供、也不承诺任何签名或公证版本 —— 因为没有 Apple Developer Program 账号。

唯一残留在二进制里的「签名」是链接器（`ld64`）给每个 Mach-O 写入的 ad-hoc
CodeDirectory：Apple silicon 要求它存在才允许加载代码。它不含证书、不含团队标识，
不构成身份认证。`codesign --verify --strict` 对 App、驱动和 PKG 都会报
`code object is not signed at all` 或 `no signature`，这是正常的。

**安装前请先退出 SoundBridge。** 安装器不检查 App 或 Host 是否在运行（见
[Known-Limitations](risks/Known-Limitations.md) P2-5）：一个正在运行的 Host 会在驱动
被替换后继续持有旧映射，直到它自己退出。菜单栏 → **Quit SoundBridge** 之后再安装。

---

## 1. 选择下载文件

| 文件 | 适用场景 | 是否安装驱动 |
|---|---|---|
| `SoundBridge-1.2.0.pkg` | **推荐**。首次安装，或从旧版本升级 | 是 |
| `SoundBridge-1.2.0.dmg` | 只想替换 App，或查看包内容 | 否 |

两者的关系，也是唯一需要记住的一条：

- PKG 同时安装 App 和驱动，驱动替换是一个带预检、备份、校验和回滚的事务
  （`tools/sb_install_transaction.sh`）。**升级一律用 PKG。**
- DMG 里只有 App，拖进 `/Applications` **不会**改动
  `/Library/Audio/Plug-Ins/HAL/`。机器上已有的旧驱动会保持旧版本，App 会提示版本
  不匹配，并且**不会**自行替换驱动。

协议已从 1.1.x 的线格式变更到 `0x00020200`。旧驱动配新 App 不会出声，这就是 DMG
不能用来升级的原因。

---

## 2. 校验下载文件（建议执行）

Release 页面附带的 `SHA256SUMS.txt` 覆盖两个二进制文件。把下载的文件和它放在同一
目录，然后：

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt
```

期望两行都是 `OK`。任何一行不是 `OK` 都说明文件在传输中损坏或被篡改，请重新下载，
不要继续安装。校验值只在 Release 页面的 `SHA256SUMS.txt` 里维护，本文不复制一份
（复制的那份会在重新构建后过时）。

---

## 3. 用 PKG 安装（推荐路径）

1. 退出 SoundBridge：菜单栏图标 → **Quit SoundBridge**。
2. 双击 `SoundBridge-1.2.0.pkg`。
3. 安装器显示 `SoundBridge 1.2.0`，点「继续」→「安装」。
4. **管理员授权**：macOS 会要求输入一次管理员用户名与密码。
   - 这是安装器自身的授权，不是 SoundBridge 在后台提权。
   - 安装脚本只在 `/Library/Audio/Plug-Ins/HAL/` 与 `/Applications/` 写入，
     不发送任何网络请求。
5. 看到「安装成功」后关闭窗口。
6. 打开 `/Applications/SoundBridge.app`，引导流程会**读取**已装驱动并确认结果。

安装器在写入任何文件之前先检查已装驱动：

| 已装状态 | 结果 |
|---|---|
| 更旧 | 升级，继续 |
| 相同 | 重装，继续 |
| 更新 | 拒绝，并说明未写入任何文件 |
| 协议更新 | 拒绝，不降级线格式 |
| 声明了不认识的协议 | 拒绝 |

驱动替换本身是事务：校验载荷 → 暂存 → 校验副本 → 备份旧驱动 → 重命名换位 → 再次
校验；任一步失败则回滚，旧驱动保留或还原。**安装器不会重启 `coreaudiod`。**

驱动在安装结束时已就位。它随下一次音频设备扫描加载：打开 SoundBridge.app，或在
「系统设置 → 声音」里切换一次输出设备即可。

---

## 4. 用 DMG 安装（仅替换 App）

1. 退出 SoundBridge。
2. 双击 `SoundBridge-1.2.0.dmg`，挂载出磁盘映像。
3. 把 `SoundBridge.app` 拖到「应用程序」。
4. 在 Finder 里推出该磁盘映像。
5. 打开 `/Applications/SoundBridge.app`。

如果这台机器上还没有 1.2.0 驱动，App 会显示安装引导并指向 PKG —— 它不会自己装。

---

## 5. 被系统拦下时怎么办

**不要关闭 Gatekeeper，不要执行 `spctl --master-disable`，不要关闭 SIP。** 正确做法
是逐个程序授权。

### 5.1 App 被拦：「无法打开，因为无法验证开发者」

1. 双击 App，弹窗后点「好」（或「取消」）。
2. 打开 **系统设置 → 隐私与安全性**。
3. 滚动到底部，看到「已阻止 "SoundBridge" 使用…」的提示，点 **「仍要打开」**。
4. 回到 Finder 再次双击 App，在确认框里点「打开」。

替代做法：在 Finder 里 **按住 Control 点按** App 图标 →「打开」→ 再点「打开」。
只需做一次，之后系统会记住。

### 5.2 PKG 被拦：「无法打开，因为 Apple 无法检查是否包含恶意软件」

1. 双击 PKG，点「好」关闭弹窗。
2. **系统设置 → 隐私与安全性**。
3. 底部出现该安装包条目，点 **「仍要打开」**。
4. 再次双击 PKG，确认后继续安装。

不同 macOS 版本（13 到 26）的提示文字与页面布局略有差异，入口都在
「系统设置 → 隐私与安全性」的被阻止项目列表里。如果上述路径在你的系统上不生效，
请提 issue 并附系统版本，而不是降低系统安全级别。

### 5.3 未签名 HAL 驱动会被 `coreaudiod` 加载吗（未验证）

这一条必须与其他几条分开看，四件事不能互相证明：

| 环节 | 状态 | 依据 |
|---|---|---|
| 未签名驱动能被构建出来 | 已验证 | 本机构建产出的 `SoundBridgeDriver.driver` 为 `arm64 + x86_64`，无签名身份 |
| 未签名 PKG 能被生成并校验载荷 | 已验证 | `pkgutil --check-signature` 报 `no signature`，载荷与结构校验全部通过 |
| PKG 能被安装、驱动能被拷入 HAL 目录 | 未在本版本实测 | 安装脚本无签名依赖（`preinstall`/`postinstall` 不调用 `codesign`/`spctl`），但未执行真实安装 |
| **`coreaudiod` 真的加载了这个未签名驱动** | **NOT VERIFIED** | 需要在真实 Mac 上安装并观察，本版本未做 |

也就是说：构建成功、PKG 结构正确，都**不能**推出「系统会接受这个驱动的加载」。历史上
HAL 插件目录对代码签名的要求随 macOS 版本变化，且可能受本机安全策略、MDM 配置、SIP
状态影响。**本版本没有在 macOS 14 上验证过，也没有在任何 Intel Mac 上验证过。**

如果安装后 `system_profiler SPAudioDataType | grep -i soundbridge` 没有输出，请先按
8.2.1–8.2.2 收集 `coreaudiod` 日志再提 issue —— 这类失败很可能是系统拒绝加载未签名
驱动，而不是安装出错。

---

## 6. 确认驱动已安装

### 6.1 看版本

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist"
```

期望输出 `1.2.0`。如果是 `1.1.x` 或更早，说明驱动没有被替换 —— 通常是用了 DMG 或
安装被中断，请重新用 PKG 安装。

### 6.2 看协议版本

```bash
/usr/libexec/PlistBuddy -c "Print :SBAudioProtocolVersion" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist"
```

期望 `131584`（即 `0x00020200`）。这个键从 1.2.0 起才写入；输出「Does Not Exist」
说明装的是 1.1.x 驱动。

### 6.3 看目录

```bash
ls -l /Library/Audio/Plug-Ins/HAL/
```

应当能看到 `SoundBridgeDriver.driver`。该目录通常还有其它厂商的驱动（BlackHole、
eqMac、Parrot 等），它们与本产品无关，安装与卸载都不会触碰。

---

## 7. 在「声音」设置里选择设备

1. 打开 **系统设置 → 声音 → 输出**。
2. 选择 **SoundBridge**。
3. 打开菜单栏 SoundBridge 图标，在设备列表里选择要桥接到的**物理输出设备**。

SoundBridge 自己不出声：它是代理，把音频转发给选定的物理设备。没选物理设备就没有
声音，这不是驱动故障。

---

## 8. 没有声音时的排查

### 8.1 HDMI / DisplayPort 显示器完全无声

按顺序检查：

1. **输出设备是否选对**：系统设置 → 声音 → 输出，选中 **SoundBridge**，而不是显示器
   自己的条目。选显示器条目会绕过桥接，得到的是设备的固定音量。
2. **是否选了物理设备**：菜单栏 → 设备列表，选中显示器对应的物理输出。没有物理目标
   时 Host 不渲染音频。
3. **显示器本身是否静音或音量过低**：SoundBridge 控制的是软件增益，部分显示器另有
   硬件音量菜单，两者都会生效。
4. **采样率与格式**：在「音频 MIDI 设置」里把 SoundBridge 设备的采样率设为 48 kHz。
   不支持 Float64 输入（见 Known-Limitations F-1），非常规格式会被拒绝而不是静音。
5. **Host 是否在运行**：菜单栏弹窗顶部会显示 Host 状态；显示未运行或正在重启时，
   声音会中断到 Host 恢复为止。

### 8.2 驱动没有加载

**8.2.1 系统是否识别到设备**

```bash
system_profiler SPAudioDataType | grep -i -A3 soundbridge
```

没有输出说明 CoreAudio 没有加载驱动。

**8.2.2 CoreAudio 是否拒绝加载**

```bash
log show --last 10m --predicate 'process == "coreaudiod"' 2>/dev/null \
  | grep -i soundbridge | tail -30
```

常见原因：文件权限不对、bundle 被破坏、架构不匹配（本版本是 `x86_64 + arm64`
通用二进制，正常情况下不会出现这一项）。

**8.2.3 文件是否完整**

该驱动**未签名**，所以不能用 `codesign --verify` 验它 —— 那会返回
`code object is not signed at all`，而这正是本版本的正常状态，不代表文件损坏。用户侧
唯一可用的完整性手段是对下载的 PKG/DMG 核对 `SHA256SUMS.txt`（第 2 节）：安装器本身
在写入前校验载荷，PKG 的 preinstall 阶段也会再次核对装入的副本。

确认 bundle 结构存在即可：

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist"
```

期望 `com.soundbridge.driver`。读不出 plist 说明副本被破坏，重新用 PKG 安装。

**8.2.4 让系统重新扫描 HAL 目录**

本产品不会自动重启系统音频服务。加载了旧副本时，需要你手动决定何时重启：

- 注销再登录，或重启 Mac（推荐，影响最小）；或
- 手动执行 `sudo killall coreaudiod`（系统会在数秒内自动重启它）。

这两条只是建议，安装器与 App 都不会替你执行。

**8.2.5 仍然不行**

重启一次系统。若依然没有设备，请附上 8.2.1–8.2.3 的输出提 issue。

---

## 9. 卸载

### 9.1 统一卸载政策

App 内的「Uninstall Driver」与仓库里的 `tools/uninstall_driver.sh` 执行同一套政策
（`DriverUninstallPolicy`），行为完全一致：

1. **先识别**：读取 `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist`，
   确认 `CFBundleIdentifier` 是 `com.soundbridge.driver`。不是这个 id、读不出 plist、
   或者该路径是个符号链接，一律**拒绝删除**，并说明原因。
2. **先停 Host**：通过 HostSupervisor 的 `shutdown(intent: .uninstall)` 有序退出 Host
   并等待完成。退出意图会锁住 supervisor，卸载期间 Host 不会被重新拉起。
3. **只删一个路径**：`/bin/rm -rf '/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver'`。
   没有通配符，不碰 `/tmp`，不碰其它厂商的 HAL 驱动。
4. **删完再确认**：路径消失后才清理引导状态。授权被取消或命令失败时不会宣称成功。
5. **不重启 `coreaudiod`**：加载中的副本会保留到下次重启，何时重启由用户决定。

### 9.2 用 App 卸载

菜单栏图标 → **Uninstall Driver** → 确认对话框（其中逐条列出删除与保留的内容）→
一次管理员授权 → 「Driver Removed」→ **Quit SoundBridge**。

随后把 `/Applications/SoundBridge.app` 拖到废纸篓即可。

### 9.3 用命令行卸载

仓库中的 `tools/uninstall_driver.sh` 是同一套政策的脚本版本：

```bash
tools/uninstall_driver.sh --dry-run   # 只打印将要删除的内容，不改动任何文件
tools/uninstall_driver.sh             # 执行卸载（一次管理员授权）
```

它同样拒绝符号链接、校验 bundle id、不重启 `coreaudiod`。

若两者都不可用（例如 App 已被删除），可手动执行，**先确认身份再删除**：

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist"
# 只有当输出为 com.soundbridge.driver 时才继续
sudo /bin/rm -rf "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
```

### 9.4 卸载会删除什么、保留什么

**删除**

- `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`
- 引导状态（`hasCompletedOnboarding` 等 UserDefaults 键），使下次启动重新说明安装

**保留**

- App 本身（由用户自行拖到废纸篓）
- EQ 设置与保存的 EQ 配置（`eq_default_*`）
- 音量状态（`~/Library/Application Support/SoundBridge/volume-state.json`）
- 日志（`~/Library/Logs/SoundBridge`）

保留这些是有意的：重装后音量与 EQ 直接恢复，日志是重装问题的诊断依据。想彻底清干净
时，在卸载后再手动删除：

```bash
rm -rf "$HOME/Library/Application Support/SoundBridge"
rm -rf "$HOME/Library/Logs/SoundBridge"
```

`/Library/Application Support/SoundBridge/InstallerPayload/` 是安装器暂存驱动的位置，
由后续安装覆盖，不需要手动处理。

---

## 10. 恢复到旧版驱动

安装器没有「回退到上一版」按钮。回退必须事先有备份。

### 10.1 安装前备份（建议）

```bash
sudo cp -R "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver" \
  "$HOME/SoundBridgeDriver-backup-$(date +%Y%m%d)"
```

### 10.2 需要回退时

```bash
sudo /bin/rm -rf "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
sudo cp -R "$HOME/SoundBridgeDriver-backup-YYYYMMDD" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
```

然后注销再登录（或重启 Mac）让系统重新加载。旧驱动与新 App 之间可能有版本或协议
不匹配，App 会显示说明文字，不会自行替换。

如果你没有备份，且需要一条受支持的降级路径，请提 issue —— 当前版本没有提供。

---

## 11. 自动更新

**没有更新通道。** `Info.plist` 的 `SUPublicEDKey` 为空，`SUFeedURL` 指向的
`appcast.xml` 永远不会被发布，`tools/generate_appcast.sh` 会直接拒绝运行（exit 2）。
App 启动时跳过 updater 初始化并打印 `Update feed not configured`。升级方式就是下载
新的 PKG 并按本文第 3 节安装。驱动永远不会自行更新。

`Sparkle.framework` 仍然在 bundle 里，只是因为 `SoundBridgeApp` 通过 `@rpath` 链接它，
删掉会导致 App 无法启动。它不参与任何更新流程。

---

## 12. 本指南的验证状态

证据等级沿用项目约定：`REAL_MACOS_VERIFIED` > `TEST_VERIFIED` > `SOURCE_VERIFIED` >
`NOT_VERIFIED`。

| 章节 | 状态 | 依据 |
|---|---|---|
| 1 选择下载文件 | SOURCE_VERIFIED | `tools/build_installer_pkg.sh` 与 `tools/create_dmg.sh` 的实际产物 |
| 2 校验 SHA256 | SOURCE_VERIFIED | Release 流程生成 `SHA256SUMS.txt` |
| 3 用 PKG 安装 | SOURCE_VERIFIED | 载荷布局与 preinstall 门禁由 `make verify-installer-pkg` 静态校验 |
| 4 用 DMG 安装 | SOURCE_VERIFIED | DMG 只含 App |
| 5 被系统拦下 | SOURCE_VERIFIED | 未签名产物的必然结果（`spctl` 报 `rejected / source=no usable signature`）；未在本版本上实测批准流程 |
| 5.3 驱动能否被加载 | **NOT_VERIFIED** | 构建、PKG 结构与载荷校验通过，但 `coreaudiod` 是否接受未签名驱动未在真实 Mac 上验证 |
| 6 确认驱动已安装 | TEST_VERIFIED（读取命令） | 命令在现有 1.1.x 驱动上执行过；1.2.0 的安装结果未验证 |
| 7 声音设置 | SOURCE_VERIFIED | 设备选择由 CoreAudio 与菜单栏列表决定 |
| 8.1 HDMI/DP 无声 | NOT_VERIFIED | 未在真实 HDMI/DP 设备上执行本版排查流程 |
| 8.2 驱动未加载 | SOURCE_VERIFIED | 命令可用，未用于诊断真实加载失败 |
| 9 卸载 | TEST_VERIFIED（策略） | 策略与 `tools/uninstall_driver.sh` 由单元测试锁定；真实卸载未执行 |
| 10 恢复旧版驱动 | NOT_VERIFIED | 未执行 |
| 11 自动更新 | SOURCE_VERIFIED | `SUPublicEDKey` 为空，无 appcast 发布，`generate_appcast.sh` 拒绝运行 |

**未在以下环境验证**：macOS 14、任何 Intel Mac、任何启用了 MDM/受管控策略的设备。
本版本的构建与结构校验只在 macOS 27.2.1（arm64）上完成。

**尚未验证的三件事**（详见 [Release Notes](RELEASE_NOTES.md)）：

- 真实卸载/重装闭环
- 播放窗口 underrun
- 实际 EQ 听感

本指南不把未验证项写成已验证。真实设备上的完整走查仍列在
[发布检查单](release/SoundBridge-1.2.0-Release-Checklist.md) §6。
