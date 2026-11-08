# MenuBasket（收纳篮）

macOS 26 菜单栏收纳工具：收纳篮图标左边的所有状态栏图标都会被隐藏，点击收纳篮在菜单栏下方一行显示它们。专为带刘海的 MacBook 设计——图标再多也不会被刘海挡住。

## 功能

- **隐藏**：收纳篮左边的所有菜单栏图标一律隐藏。
- **展示**：点击收纳篮，在菜单栏下方一行显示所有隐藏的图标；再点一次、点别处或按 Esc 关闭。
- **使用**：在这一行里左键、右键点击图标，效果与直接点击菜单栏图标相同。
- **整理**：
  - 在这一行里按住 ⌘ 把图标拖到菜单栏收纳篮右侧 → 常驻显示；拖到行内其它图标旁 → 调整顺序。
  - 在菜单栏里按住 ⌘ 拖动图标时会出现一条分界线，拖到收纳篮左边 → 隐藏。
- 右键收纳篮：登录时启动、权限设置、重新启动、退出。

## 要求

- macOS 26（Tahoe）及以上，Apple Silicon（构建目标为 arm64）。
- Xcode 或 Command Line Tools（含 macOS 26.x SDK）。
- 运行时需要授予两项权限（首次启动会提示）：
  - **辅助功能**：识别每个图标属于哪个 App，并代为点击、移动图标。
  - **屏幕录制**：截取被隐藏图标的样子。授予后需重新启动收纳篮才生效。
- 不要与其它菜单栏管理器（Ice、Bartender、Tuck、Hidden Bar 等）同时运行。

## 构建与安装

```sh
./make-signing-cert.sh   # 仅首次：生成本机自签名证书（存放在 .signing/，不动登录钥匙串，已被 .gitignore 排除）
./build.sh               # 输出 build/MenuBasket.app
ditto build/MenuBasket.app /Applications/MenuBasket.app
open /Applications/MenuBasket.app
```

- 使用 `swiftc` 直接编译（部分 Command Line Tools 版本的 `swift build` 有 dyld 符号缺失问题），并自动挑选与编译器匹配的 macOS 26.x SDK。
- 用固定的自签名证书签名，重新构建后已授予的“辅助功能 / 屏幕录制”权限不会失效。没有生成证书时会退回临时签名，每次重新构建都要重新授权。
- 更新已安装的版本：先退出收纳篮，再执行上面的 `ditto` 覆盖。

## 实现要点

| 功能 | 做法 |
| --- | --- |
| 隐藏 | 两个 NSStatusItem：收纳篮 + 紧贴其左的分隔条。分隔条长度设为 10000（系统实际限制到 5016pt），把左侧图标挤出屏幕。 |
| 识别图标 | macOS 26 中所有状态项窗口在 CGWindowList 里都归“控制中心”。通过各 App 的 `AXExtrasMenuBar` 子元素帧中心与窗口匹配，得到真实 PID 和名称。 |
| 截图 | `CGWindowListCreateImageFromArray`（dlsym）——能截屏幕外的窗口；ScreenCaptureKit 不行。 |
| 查询窗口位置 | `CGWindowListCreateDescriptionFromArray`——`.optionIncludingWindow` 不返回屏幕外窗口。 |
| 移动 | 合成 ⌘+mouseDown / mouseUp，事件字段携带窗口 ID（含未公开字段 0x33），先投递到 session tap 再 `postToPid`。 |
| 点击隐藏图标 | 临时移到可见区（避开刘海与 App 菜单）→ 在真实位置合成点击 → 等它弹出的菜单/面板关闭 → 移回原位。 |
| ⌘ 拖动 | 菜单栏中 ⌘ 拖动时分隔条缩成细竖线；松开后恢复，并把新落在分隔条与收纳篮之间的图标移到分隔条左侧。面板中 ⌘ 拖出图标到菜单栏 = 显示；拖到面板中其它图标旁 = 调整隐藏顺序。 |

## 调试

日志：`~/Library/Logs/MenuBasket.log`。

调试命令接口只在 `./build.sh --debug-ipc` 构建中存在（它允许本机任意进程借用收纳篮的辅助功能权限模拟点击，正式构建不包含）。`./dev-cmd.sh <命令>` 通过分布式通知控制运行中的开发版：
`dump`、`open`、`close`、`capture`、`layout`、`activate <隐藏序号> [right]`、`show <隐藏序号>`、`tuck <可见序号>`、
`simclick <x> <y> [right]`、`simdrag <x1> <y1> <x2> <y2>`、`snap <名字> <x> <y> <w> <h>`（截图存到 `~/Library/Logs/MenuBasketCaptures/`）。

## 已知限制

- 时钟、控制中心等系统项目无法被移动。
- 系统临时指示器（如录屏/麦克风提示）由系统放置，收纳篮不会强制移动它们。
- 与其它菜单栏管理器（Tuck、Ice、Bartender 等）同时运行会互相干扰。
- 参考了 Ice / Thaw（GPL-3.0）的公开技术思路，代码为独立实现。
