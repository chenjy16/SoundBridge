# SoundBridge 1.2.0 — 安装指南

本文面向**从 GitHub Release 下载** SoundBridge 的用户。

---

## 0. 先读这一段

SoundBridge 由两部分组成：

| 组件 | 位置 | 作用 |
|---|---|---|
| **SoundBridge.app** | `/Applications/` | 菜单栏应用，显示控制、均衡器、更新 |
| **SoundBridgeDriver.driver** | `/Library/Audio/Plug-Ins/HAL/` | macOS 音频驱动，向系统注册虚拟输出设备 |

只安装 App 是不够的：驱动在系统目录里，需要管理员权限才能写入。这也是为什么有两个下载文件。

**本版本的两个安装包都未经过 Apple 公证（notarization），程序使用 ad-hoc 签名。**
这不是 Developer ID 签名，macOS 无法验证它的来源，因此首次运行时系统会要求你手动确认一次。这是预期行为，不是安装失败。

---

## 1. 选择下载文件

| 文件 | 适用场景 | 是否安装驱动 |
|---|---|---|
| `SoundBridge-1.2.0.pkg` | **推荐**。首次安装，或从旧版本驱动升级 | 是 |
| `SoundBridge-1.2.0.dmg` | 只想更新 App，或想手动查看包内容 | 否 |

两者的关系：

- 拖 DMG 里的 App 到 `/Applications` 只会替换 App，**不会**改动 `/Library/Audio/Plug-Ins/HAL/` 里的驱动。如果你机器上已有旧驱动，它会保持旧版本，App 会提示版本不匹配。
- PKG 同时安装 App 和驱动，并把驱动替换做成一个带校验和回滚的事务。**升级请用 PKG。**

---

## 2. 校验下载文件（建议执行）

Release 页面附带的 `SHA256SUMS.txt` 覆盖两个二进制文件。

把下载的文件和 `SHA256SUMS.txt` 放在同一个目录，然后：

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt
```

期望输出：

```
SoundBridge-1.2.0.pkg: OK
SoundBridge-1.2.0.dmg: OK
```

任何一行不是 `OK` 都说明文件在传输中损坏或被篡改，请重新下载，不要继续安装。

本版本发布时记录的校验值：

```
977d79e26ee4f13b06e8ad13df32907b2bb9eb5bfa17d405cc3dd97a36b3ee3b  SoundBridge-1.2.0.pkg
c7f311b05d1760d9c60d27c32ded3adcd74b92b16bcb8969f10e2ed17b0b504a  SoundBridge-1.2.0.dmg
```

（发布后如果重新构建，以 Release 页面上的 `SHA256SUMS.txt` 为准。）

---

## 3. 正常打开（未触发安全提示时）

### 用 PKG

1. 双击 `SoundBridge-1.2.0.pkg`。
2. 安装器窗口显示 `SoundBridge 1.2.0`，点击「继续」→「安装」。
3. 输入管理员密码。
4. 看到「安装成功」后关闭窗口。

驱动在安装结束时就位，但不会主动重启系统音频服务。它会随下一次音频设备扫描加载；打开 SoundBridge.app 或切换一次输出设备即可。

### 用 DMG

1. 双击 `SoundBridge-1.2.0.dmg`，挂载出磁盘映像。
2. 把 `SoundBridge.app` 拖到 `Applications` 别名（或 Finder 的「应用程序」）。
3. 在 Finder 里推出该磁盘映像。
4. 打开 `/Applications/SoundBridge.app`。

---

## 4. 被系统拦下时怎么办

### 4.1 App 被拦：「无法打开，因为无法验证开发者」

**不要关闭 Gatekeeper，不要执行 `spctl --master-disable`。** 正确做法是逐个程序授权：

1. 双击 App，弹窗后点「好」（或「取消」）。
2. 打开 **系统设置 → 隐私与安全性**。
3. 滚动到底部，会看到「已阻止 "SoundBridge" 使用…」的提示，点 **「仍要打开」**。
4. 回到 Finder，再次双击 App，在确认框里点「打开」。

替代做法：在 Finder 里 **按住 Control 点按** App 图标 →「打开」→ 在确认框里再点「打开」。这个动作只需做一次，之后系统会记住。

### 4.2 PKG 被拦：「无法打开，因为 Apple 无法检查是否包含恶意软件」

未签名的安装包在较新的 macOS 上会被拦截：

1. 双击 PKG，点「好」关闭弹窗。
2. **系统设置 → 隐私与安全性**。
3. 底部出现该安装包的条目，点 **「仍要打开」**。
4. 再次双击 PKG，确认后继续安装。

### 4.3 关于不同 macOS 版本

不同系统版本的提示文字和位置略有差异（macOS 13 到 26 的「隐私与安全性」页面布局并不相同）。上面的路径在 macOS 13 及以上都适用；如果你的系统把入口放在别处，请在「系统设置 → 隐私与安全性」页内查找被阻止项目的列表。

**本指南不提供、也不建议任何降低系统安全级别的操作**（关闭 Gatekeeper、关闭 SIP、修改 `spctl` 策略）。如果上述授权路径在你的系统上不生效，请提 issue 说明系统版本，而不是关闭系统保护。

---

## 5. 确认驱动已安装

### 5.1 看版本

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist"
```

期望输出 `1.2.0`。

如果输出 `1.1.2` 或更早，说明驱动没有被替换 —— 通常是用了 DMG 而不是 PKG，或安装被中断。请重新用 PKG 安装。

### 5.2 看目录

```bash
ls -l /Library/Audio/Plug-Ins/HAL/
```

应当能看到 `SoundBridgeDriver.driver`。注意该目录里通常还有其它厂商的驱动（BlackHole、eqMac、Parrot 等），它们与本产品无关，安装过程不会触碰它们。

---

## 6. 在「声音」设置里选择设备

1. 打开 **系统设置 → 声音 → 输出**（或「输出与输入」）。
2. 选择 **SoundBridge**。
3. 打开菜单栏里的 SoundBridge 图标，在设备列表里选择要桥接到的**物理输出设备**（耳机、扬声器、声卡）。

SoundBridge 自己不出声：它是一个代理，把音频转发给你选定的物理设备。如果没选物理设备，声音不会出来，这不是驱动故障。

---

## 7. 驱动没有加载时怎么排查

按顺序检查，每一步都能缩小范围：

**7.1 系统是否识别到设备**

```bash
system_profiler SPAudioDataType | grep -i -A3 soundbridge
```

没有输出说明 CoreAudio 没有加载驱动。

**7.2 CoreAudio 是否拒绝加载**

```bash
log show --last 10m --predicate 'process == "coreaudiod"' 2>/dev/null | grep -i soundbridge | tail -30
```

常见原因：架构不匹配（本版本为 `x86_64 + arm64` 通用二进制，正常情况下不会出现）、文件权限不对、bundle 被破坏。

**7.3 文件是否完整**

```bash
codesign --verify --strict --verbose=2 \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
```

期望 `valid on disk` 与 `satisfies its Designated Requirement`。ad-hoc 签名同样会通过这项检查；它验证的是文件未被改动，不代表 Apple 认可发布者。

**7.4 重启音频服务**

```bash
sudo killall coreaudiod
```

系统会在几秒内自动重启它，然后重新扫描 HAL 目录。这一步不会影响正在录音的其它程序超过一两秒。

**7.5 仍然不行**

重启一次系统。若依然没有设备，请附上 7.1–7.3 的输出提 issue。

---

## 8. 卸载

分三步，按需执行：

```bash
# 1. 停掉 App（如果正在运行）
pkill -f SoundBridgeApp || true

# 2. 删除驱动
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"

# 3. 重启系统音频服务，让设备消失
sudo killall coreaudiod
```

再删除 App：把 `/Applications/SoundBridge.app` 拖到废纸篓。

可选：清理安装器留下的状态目录（成功安装后其中只剩日志）：

```bash
sudo rm -rf "/Library/Application Support/SoundBridge"
```

**卸载只删除上面列出的两个路径。** `/Library/Audio/Plug-Ins/HAL/` 下的其它驱动不会被触碰。

---

## 9. 恢复到旧版驱动

安装器没有内置「回退到上一版」按钮。要回退，必须事先有备份。

### 9.1 安装前先备份（建议）

```bash
sudo cp -R "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver" \
  "$HOME/SoundBridgeDriver-backup-$(date +%Y%m%d)"
```

### 9.2 需要回退时

```bash
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
sudo cp -R "$HOME/SoundBridgeDriver-backup-YYYYMMDD" \
  "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
sudo killall coreaudiod
```

注意：旧版驱动与新 App 之间可能存在版本不匹配，App 会提示。此时可以同时回退 App：把旧版 `SoundBridge.app` 放回 `/Applications/`。

如果你没有备份，且需要一条受支持的降级路径，请提 issue —— 当前版本没有提供。

---

## 10. 关于安装失败

安装器在写入 App 之前先检查已装驱动的版本与共享内存协议版本：

- 已装驱动**更旧** → 升级，继续。
- 已装驱动**相同** → 重装，继续。
- 已装驱动**更新** → 拒绝，并明确输出原因。

拒绝发生在任何文件被写入之前：App 不会被安装，驱动目录保持原样。如果你看到「refusing to install」字样，说明这台机器上的驱动比安装包新，请下载更新版本的安装包，而**不要**尝试手动删除驱动来绕过检查。

驱动替换本身是一个事务：校验载荷 → 暂存 → 校验副本 → 备份旧驱动 → 重命名换位 → 再次校验，任一步失败则回滚。驱动器替换失败时，旧驱动会被保留或还原。

---

## 11. 本指南的验证状态

| 章节 | 状态 |
|---|---|
| 1 选择下载文件 | STATICALLY_REVIEWED（依据 PKG/DMG 的实际内容） |
| 2 校验 SHA256 | **EXECUTED**（发布前对两个文件执行 `shasum -c`，结果 OK） |
| 3 正常打开 | NOT_TESTED（未在真实机器上执行首次安装） |
| 4 被系统拦下 | NOT_TESTED（路径依据系统文档与既有经验，未在本发布上实测） |
| 5 确认驱动已安装 | **PARTIALLY EXECUTED**（读取版本号的命令已在现有 1.1.2 驱动上验证；1.2.0 的安装结果未验证） |
| 6 声音设置选择设备 | NOT_TESTED |
| 7 排查未加载 | **PARTIALLY EXECUTED**（`codesign --verify` 与 `log show` 命令可用；未用于诊断真实加载失败） |
| 8 卸载 | NOT_TESTED（未在真实机器上执行） |
| 9 恢复旧版驱动 | NOT_TESTED |
| 10 安装失败语义 | **EXECUTED（模拟）**（对展开后的安装包运行 preinstall，在临时根目录下覆盖 8 类场景；未执行真实 `installer -pkg`） |

标注为 NOT_TESTED 的步骤尚未在真实机器上验证。首次正式发布前应在一个独立的 macOS 环境中完整走一遍第 3、4、5、6、8、9 节。
