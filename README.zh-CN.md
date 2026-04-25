# 墨池 InkPond

墨池（InkPond）是一个原生 iOS/iPadOS 的 [Typst](https://typst.app/) 编辑器，支持实时预览与 PDF 导出，底层由 Rust FFI 驱动。

<p align="center">
  <a href="https://apps.apple.com/cn/app/%E5%A2%A8%E6%B1%A0-inkpond/id6760032537"><img src="https://img.shields.io/badge/App%20Store-Download-0D96F6?logo=appstore&logoColor=white" alt="App Store"></a>
  <a href="https://testflight.apple.com/join/w5jmkR2T"><img src="https://img.shields.io/badge/TestFlight-Beta-0D96F6?logo=apple&logoColor=white" alt="TestFlight"></a>
  <a href="README.md"><img src="https://img.shields.io/badge/English-README-2563EB" alt="English README"></a>
</p>
<p align="center">
  <img src="https://img.shields.io/badge/平台-iOS%2017%2B%20%26%20iPadOS%2017%2B-2563EB" alt="Platform">
  <img src="https://img.shields.io/badge/语言-Swift%205-F59E0B" alt="Language">
  <img src="https://img.shields.io/badge/Typst-0.14.2-0EA5A4" alt="Typst Version">
  <img src="https://img.shields.io/badge/许可证-Apache%202-1D4ED8" alt="License">
</p>

## 语言

- 简体中文（当前）
- English: [README.md](README.md)

## 快速入口

| 操作 | 命令 / 链接 |
|---|---|
| 下载正式版 | [App Store](https://apps.apple.com/cn/app/%E5%A2%A8%E6%B1%A0-inkpond/id6760032537) |
| 加入 TestFlight 内测 | [testflight.apple.com/join/w5jmkR2T](https://testflight.apple.com/join/w5jmkR2T) |
| 构建 Rust FFI | `cd rust-ffi && ./build-ios.sh` |
| 模拟器 Debug 构建 | `xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Debug -destination 'generic/platform=iOS Simulator' build` |
| 导出配置文件 | `release/ExportOptions.plist` |

## 功能特性

**编辑器**
- 基于 Typst 解析器的语法高亮、彩虹括号着色、括号不匹配检测
- `{}[]()""$$` 自动配对，支持智能跳过、自动删除、自动缩进
- 代码补全：Typst 函数（约 150 个）、关键字、`#import` 包规格、字体族、标签、引用、图片路径
- 代码片段库，支持自定义模板与 `$0` 光标占位
- 查找与替换（系统 `UIFindInteraction`）
- 带错误行高亮的行号栏
- 键盘附件栏（快速插入按钮）

**预览与编译**
- 通过 Rust FFI 桥接 Typst `0.14.2` 编译能力
- 实时 PDF 预览，防抖编译（350ms）
- 基于 Source Map 的编辑器 ↔ 预览双向同步
- 支持 `@preview` 包下载缓存与本地包解析
- 文档统计（页数、字数/词元数、字符数；感知 CJK）
- 编译错误横幅（可跳转到源码位置）
- 全屏幻灯片模式
- 基于解析器的标题大纲导航
- 编译预览缓存，加快再次打开与重编译

**项目管理**
- 多文件项目，支持自定义入口文件
- 项目文件浏览器（.typ / 图片 / 字体分区）
- 从相册、剪贴板（含 HTML 粘贴）及远程 URL 导入图片
- 按项目、App 以及系统字体解析显式 Typst 字体声明
- 可选 iCloud 项目同步，并可分别同步 App 字体、本地包和代码片段
- 本地 Typst 包管理，支持文件夹以及 `.zip` / `.tar` / `.tar.gz` / `.tgz` 压缩包
- ZIP 项目导入与导出
- PDF 及源文件（.typ）导出

**界面与体验**
- 自适应布局：iPad 分栏视图，iPhone 标签切换
- 独立的 App 外观设置，以及三套编辑器主题：Mocha（暗色）、Latte（亮色）、System（跟随系统）— 基于 Catppuccin
- 新用户引导流程
- 跨启动恢复编辑器光标位置
- 完整的 VoiceOver 与无障碍支持
- 本地化：英语、简体中文、繁体中文（港/台）
- 设置页管理 iCloud、App 字体、本地包、键盘快捷键、编译/包/系统字体缓存
- 在可用设备上启用 iOS 26 键盘玻璃效果与视觉增强，并为 iOS 17 提供兼容回退

## 环境要求

- macOS + Xcode 26.3+
- App 目标最低系统：iOS/iPadOS 17.0
- Rust 工具链（`rustup`、`cargo`）用于构建 `typst_ios.xcframework`

## 快速开始

1. 克隆仓库：
   ```bash
   git clone <你的仓库地址或上游地址>
   cd InkPond
   ```
2. 确认本机工具链可用：
   ```bash
   xcode-select -p
   cargo --version
   rustup show
   ```
   如果其中任一命令失败，请先安装 Xcode 命令行工具和 Rust 工具链。
3. 构建 Rust FFI 框架：
   ```bash
   cd rust-ffi
   ./build-ios.sh
   cd ..
   ```
   这会生成未提交到 git 的 `Frameworks/typst_ios.xcframework`。
4. 用 Xcode 打开并运行：
   ```bash
   open InkPond.xcodeproj
   ```

## 常用构建命令

```bash
# 模拟器 Debug 构建
xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Debug -destination 'generic/platform=iOS Simulator' build

# 真机 Release Archive
xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Release -destination 'generic/platform=iOS' archive

# 单元测试
xcodebuild test -project InkPond.xcodeproj -scheme InkPond -only-testing:InkPondTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'

# UI 测试
xcodebuild test -project InkPond.xcodeproj -scheme InkPond -only-testing:InkPondUITests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'

# 如果本机安装的模拟器不同，请先查看可用目标：
# xcodebuild -showdestinations -project InkPond.xcodeproj -scheme InkPond
```

## Rust FFI 说明

- `Frameworks/typst_ios.xcframework` 由 `rust-ffi/build-ios.sh` 生成。
- `rust-ffi/build-ios.sh` 在打包 xcframework 后会删除 `rust-ffi/target/`，以尽量减少本地磁盘占用。
- `Frameworks/typst_ios.xcframework/` 是本地构建产物，已在 git 中忽略。
- Swift 桥接层会把字体路径、项目根目录、`@preview` 包缓存目录以及本地包目录传给 Rust。
- 以下情况请重新执行 `rust-ffi/build-ios.sh`：
  - 升级 Typst / Rust 依赖
  - 修改 `rust-ffi/src/lib.rs`
  - 发布前重建产物

当前固定 Typst 版本：`0.14.2`（见 `rust-ffi/Cargo.toml`）。

## 发布流程（CLI）

```bash
# 1) Archive
xcodebuild -project InkPond.xcodeproj -scheme InkPond -configuration Release -destination 'generic/platform=iOS' -archivePath /private/tmp/InkPond.xcarchive archive

# 2) 导出 IPA（使用你的 ExportOptions.plist）
xcodebuild -exportArchive -archivePath /private/tmp/InkPond.xcarchive -exportPath /private/tmp/InkPond-export -exportOptionsPlist release/ExportOptions.plist

# 3) 上传（InkPond app id）
asc --profile default builds upload --app 6760032537 --ipa /private/tmp/InkPond-export/InkPond.ipa --output table
```

上传后需要等待 App Store Connect 完成处理，再分发到 TestFlight 分组。

正式版 App Store 页面：[apps.apple.com/cn/app/墨池-inkpond/id6760032537](https://apps.apple.com/cn/app/%E5%A2%A8%E6%B1%A0-inkpond/id6760032537)

## 项目结构

```text
InkPond/
├── InkPond/
│   ├── InkPondApp.swift                 # @main 入口，SwiftData ModelContainer
│   ├── ContentView.swift               # NavigationSplitView 外壳，环境注入
│   ├── AppAppearanceManager.swift      # App 级明暗/跟随系统外观
│   ├── Models/
│   │   └── InkPondDocument.swift        # @Model：文档数据 + 项目配置
│   ├── Editor/
│   │   ├── TypstTextView.swift         # UITextView 子类（TextKit 1）
│   │   ├── SyntaxHighlighter.swift     # Typst token 着色 + 彩虹括号
│   │   ├── CompletionEngine.swift      # 上下文感知代码补全
│   │   ├── AutoPairEngine.swift        # 括号/引号自动配对
│   │   ├── SyncCoordinator.swift       # 编辑器 ↔ 预览双向同步
│   │   ├── EditorTheme.swift           # Mocha/Latte/System 主题定义
│   │   ├── ThemeManager.swift          # 主题持久化（UserDefaults）
│   │   ├── Snippet*.swift              # 代码片段模型、库、存储
│   │   ├── HighlightScheduler.swift    # 防抖高亮
│   │   ├── LineNumberGutterView.swift  # 行号栏 + 错误标记
│   │   └── KeyboardAccessoryView.swift # 附件栏（图片/片段按钮）
│   ├── Compiler/
│   │   ├── TypstBridge.swift           # Rust FFI 封装（编译 + Source Map）
│   │   ├── TypstCompiler.swift         # 防抖编译管线 + 缓存
│   │   ├── SourceMap.swift             # 行号 ↔ 页面双向映射
│   │   ├── ProjectFileManager.swift    # 按项目文件 CRUD + 校验
│   │   ├── FontManager.swift           # 项目/App 字体元数据与解析辅助
│   │   ├── CompileFontResolver.swift   # 字体解析与物化规划
│   │   ├── CoreTextFontMaterializer.swift
│   │   │                              # 面向 Typst 的系统字体物化缓存
│   │   ├── LocalPackageStore.swift     # 本地 Typst 包目录与导入
│   │   ├── PackageArchiveImporter.swift
│   │   │                              # 包压缩文件解包
│   │   ├── ExportManager.swift         # PDF/源文件/ZIP 导出（自实现 ZIP）
│   │   ├── ExportController.swift      # 导出 UI 状态机
│   │   ├── ZipImporter.swift           # ZIP 项目导入
│   │   ├── DirectoryMonitor.swift      # DispatchSource 文件系统监听
│   │   └── *CacheStore.swift           # 编译预览 + 包缓存
│   ├── Views/
│   │   ├── DocumentList/               # 文档库、搜索、排序、重命名
│   │   ├── DocumentEditor/             # 编辑器/预览分栏、文件操作、图片
│   │   │   └── OutlineView.swift       # 标题大纲导航
│   │   ├── EditorView.swift            # UIViewRepresentable 包装 TypstTextView
│   │   ├── PreviewPane.swift           # PDFKit 实时预览 + 统计 + 同步标记
│   │   ├── SlideshowView.swift         # 全屏 PDF 演示
│   │   ├── OnboardingView.swift        # 首次启动引导
│   │   ├── SnippetBrowserSheet.swift   # 代码片段浏览器
│   │   ├── ProjectFileBrowserSheet.swift
│   │   ├── ProjectSettingsSheet.swift
│   │   └── Settings/                   # iCloud、包、字体、缓存、快捷键
│   ├── Localization/                   # L10n.swift + .strings（en, zh-Hans, zh-Hant）
│   ├── Storage/
│   │   ├── StorageManager.swift        # 本地/iCloud 模式与迁移
│   │   ├── Cloud*.swift                # iCloud 协调、可用性、同步状态
│   │   └── AppFontLibrary.swift        # 全局字体导入追踪
│   ├── Shared/UI/                      # UIKit/SwiftUI 桥接、触觉反馈、无障碍
│   ├── Support/
│   │   ├── AppIdentity.swift           # Bundle/App Group/iCloud 标识
│   │   └── InteractionSupport.swift    # 触觉反馈与无障碍播报
│   └── Bridging/                       # typst_ffi.h 桥接头文件
├── rust-ffi/
│   ├── src/lib.rs                      # Rust Typst 封装
│   ├── Cargo.toml                      # Rust 依赖（Typst 引擎）
│   └── build-ios.sh                    # XCFramework 构建（设备 + 模拟器）
├── Frameworks/
│   └── typst_ios.xcframework/          # 生成的构建产物（不提交）
├── release/
│   └── ExportOptions.plist
└── InkPond.xcodeproj
```

## 常见问题

- `Typst compiler library not linked`：
  - 执行 `cd rust-ffi && ./build-ios.sh` 后重新编译 App。
- 模拟器链接 `typst_ios` 架构错误：
  - 重新构建 xcframework（脚本会生成 `arm64 + x86_64` 模拟器切片）。
- TestFlight 上传成功但无法立即分发：
  - 构建仍在 App Store Connect 处理中。
- `@preview` 包导入失败：
  - 检查网络连接，然后在设置中清理包缓存并重新编译。
- iCloud 文件看起来缺失或未下载：
  - 打开「文件」App，进入 iCloud 云盘，将 InkPond 文件夹设为保留下载后再重新打开项目。

## 致谢

- [Typst](https://github.com/typst/typst)：用于排版与 PDF 生成的核心引擎（Apache 2.0）
- [Catppuccin](https://github.com/catppuccin/catppuccin)：编辑器主题所使用的配色体系（MIT）
- [swift-bridge](https://github.com/chinedufn/swift-bridge)：Swift/Rust 互操作方案的重要参考（MIT 或 Apache-2.0）

## 特别感谢

- 感谢 [甜甜圈（Donut）](https://donutblogs.com/) 的所有伙伴给予的支持与启发。
