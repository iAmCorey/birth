# Birth

[![CI](https://github.com/iAmCorey/birth/actions/workflows/ci.yml/badge.svg)](https://github.com/iAmCorey/birth/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/iAmCorey/birth)](https://github.com/iAmCorey/birth/releases)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Mac 启动什么，你说了算。**

Birth 是一款免费开源的 macOS 启动项管理工具。它把系统里每一个启动代理、守护进程和登录项收进同一个窗口，告诉你*是谁装的*（代码签名身份）、现在有没有在运行，并让你一键停用或移除。

> launchd 是 PID 1——所有进程都由它而生。启动项就是 Mac 的"出生仪式"，Birth 让你决定哪些有资格留下。

## 为什么需要它

macOS 把启动项分散在至少四套机制里：

| 来源 | 里面住着什么 | 系统设置显示吗 |
|---|---|---|
| `~/Library/LaunchAgents` | 当前用户的代理 | 只显示为语焉不详的"后台项目" |
| `/Library/LaunchAgents` | 所有用户的代理 | 同上 |
| `/Library/LaunchDaemons` | root 守护进程 | 同上 |
| BTM 登录项 | "登录时打开"的 App | 显示，但没有路径、没有细节 |

系统设置不会告诉你 plist 在哪、指向哪个可执行文件、由谁签名——而第三方的更新器、辅助进程和赖着不走的卸载残留，正是仰仗这种不透明。Birth 负责撕掉它。

## 功能

### 启动应用（日常）

- **零授权查看**"登录时打开"列表——打开即用，不弹任何授权框
- 添加 / 移除登录 App（首次修改时才请求一次"自动化"授权）；也可以直接把 App **拖进窗口**添加
- 每个 App 显示**开发者签名身份**，以及它顺手装进系统的后台组件（"+N 后台项"徽章，点击直达）
- **最近移除**记录：移除的 App 保留在侧边栏专属页面，一键"重新启用"

### 高级启动项（审计）

- 四层全景：用户代理 / 全局代理 / 守护进程 / 登录项，默认只看第三方，一键切换"全部"
- **签名身份经证书链锚点验证**：Apple / App Store / 已识别开发者 / 不受信任的证书 / 临时签名 / 未签名 / 签名无效
- **伪装检测**：标识符冒充 `com.apple.*` 但签名验证不符的项目，会被红色"伪装系统项"标出——这是恶意软件最常用的持久化伪装手法
- 实时运行状态（PID）、一键启停（用户级免密；守护进程走 macOS 标准管理员授权）
- **安全删除**：任务先停止，plist 移入废纸篓，并在 `~/Library/Application Support/Birth/Backups` 保留备份
- 属性列表查看器（二进制 plist 自动转为可读 XML）

## 权限设计：用到才要，要一次就够

| 操作 | 所需权限 | 时机 |
|---|---|---|
| 查看"启动应用"列表 | 无 | — |
| 浏览用户代理 / 全局代理 / 守护进程 | 无 | — |
| 启停用户代理 / 全局代理 | 无 | — |
| 添加 / 移除启动应用 | 自动化（系统事件） | 首次修改时弹一次 |
| 查看"登录项"分类 | 完全磁盘访问权限 | 系统设置勾选一次，永久生效 |
| 启停守护进程；删除全局代理 / 守护进程 | 管理员密码 | 每次操作（macOS 安全模型强制） |

缺少权限时功能优雅降级：界面内有一次性授权引导，授权后切回 Birth 自动刷新，之后所有操作静默进行。

## 安装

要求 macOS 14（Sonoma）及以上。目前主要在 macOS 26 上开发与测试；更早版本遇到问题欢迎提 [Issue](https://github.com/iAmCorey/birth/issues)。

### 方式一：下载 DMG

从 [Releases](https://github.com/iAmCorey/birth/releases) 下载最新的 `Birth-x.x.x.dmg`，打开后把 Birth 拖进"应用程序"。

Birth 是个人开源项目，未经 Apple 公证。**首次打开**时 macOS 会提示无法验证开发者：前往 系统设置 → 隐私与安全性，在页面底部点击**"仍要打开"**——只需一次。

### 方式二：从源码构建

```bash
git clone https://github.com/iAmCorey/birth.git
cd birth
./scripts/make-app.sh
open dist/Birth.app
```

（Homebrew cask 计划中。）

## 开发

```bash
swift test                    # 单元测试
./scripts/release-check.sh    # 发版门禁：测试 → 打包 → 冒烟启动 → 健康检查
./scripts/make-dmg.sh         # 打包分发用 DMG
```

- SwiftUI + Swift Package Manager，无 Xcode 工程文件，零第三方依赖
- 三个 target：`BirthCore`（扫描/控制/签名，UI 无关）、`BirthUI`（完整应用，可测试）、`Birth`（三行 main 的薄壳）
- 每次发版前必须跑一遍 `release-check.sh`，任何一步红灯都不发布

## 说明与限制

- **签名徽章显示的是身份，不是完整性**：Birth 验证证书链锚点（确认"是谁签的"），不做全量内容哈希校验——那是 Gatekeeper 的职责。
- **"登录项"分类只读**：macOS 未向第三方开放切换这类项目的 API，Birth 提供直达系统设置的跳转。
- Birth 目前使用临时（ad-hoc）签名，每个构建的签名身份都不同。**升级到新版本后，完全磁盘访问权限与自动化授权需要在系统设置中重新勾选**（把 Birth 的开关先关后开）。同一个版本内授权一次持续有效。

## 卸载

把 Birth.app 移到废纸篓即可。想清理得更彻底（可选）：

```bash
defaults delete dev.birth.Birth                            # 偏好设置
rm -rf ~/Library/Application\ Support/Birth                # 删除操作的备份
```

别忘了在 系统设置 → 隐私与安全性 中移除授予 Birth 的权限。

## 反馈

Bug 与建议请提 [GitHub Issues](https://github.com/iAmCorey/birth/issues)。

## 许可证

[MIT](LICENSE)
