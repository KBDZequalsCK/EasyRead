# EasyRead for Intel Mac

A minimal native reading app for Intel-based Macs. EasyRead is an independent AppKit reimplementation of a local reading workflow; it does not copy code or assets from the original app.

## Features

- Import and manage local TXT, EPUB, and PDF books
- Store the bookshelf at `~/Library/Application Support/IntelReader/library.json`
- Automatically discover and sync the `极简阅读` folder in iCloud Drive, with manual and scheduled sync support
- Choose the actual iCloud folder from the sidebar when the default path is unavailable
- Copy books imported from Finder into the active iCloud library before opening them
- TXT reading with font-size controls, dark mode, and long-text scrolling
- Continuous PDF reading with automatic zoom
- EPUB rendering through WebKit after merging the spine chapters
- MOBI, AZW, and AZW3 support through a local Calibre conversion to a temporary EPUB
- Immersive reading mode with a bookshelf visibility toggle and the `⌘⇧S` shortcut
- Open books by dragging them onto the app icon or choosing EasyRead from Finder's Open With menu
- Remove stale iCloud bookshelf records without deleting local-file records when iCloud is temporarily unavailable

## Project Layout

- `Sources/IntelReader/main.swift`: application source
- `Info.plist`: app metadata and document type declarations
- `build.sh`: build script for the Intel `x86_64` app
- `outputs/简阅.app`: latest built app bundle
- `NEXT_CHAT_PROMPT.md`: context for continuing development in a new conversation
- `work/`: optional debugging and acceptance artifacts; not required at runtime

## Build

Requires macOS 12 or later and Swift 5.8 or later. Calibre is also required for MOBI/AZW reading.

```sh
./build.sh
open "build/简阅.app"
```

The build script produces an unsigned Intel `x86_64` executable. On first launch, use Finder's Open command if macOS blocks the unsigned app.

When opening MOBI/AZW files, EasyRead calls Calibre's `ebook-convert` in the background and stores the converted EPUB only in a temporary directory. DRM-protected books generally cannot be converted.

## iCloud

This version uses the iCloud directories already mounted by macOS and does not use a third-party server. The default path for the iPhone app's library is:

```text
~/Library/Mobile Documents/iCloud~com~photon~reader/Documents
```

The standard iCloud Drive folder is also supported:

```text
~/Library/Mobile Documents/com~apple~CloudDocs/极简阅读
```

On first launch, EasyRead checks both paths. You can also choose a location from the sidebar. Book metadata edits only affect the Mac bookshelf; removing a book from the bookshelf does not delete the iCloud original unless the explicit iCloud deletion action is chosen.

---

# 简阅 Intel 版

一个面向 Intel 芯片 Mac 的本地极简阅读器原型。它不是对原 App 的代码或素材复制，而是用原生 AppKit 重实现类似的本地阅读体验。

## 当前功能

- 新对话协作说明见 `NEXT_CHAT_PROMPT.md`
- 导入并管理本地 TXT、EPUB、PDF 文件
- 书架记录保存在 `~/Library/Application Support/IntelReader/library.json`
- 自动读取 iCloud Drive 中的 `极简阅读` 文件夹，并支持手动/定时同步
- 如果系统默认路径未挂载，可通过侧栏“位置”按钮选择实际的 `极简阅读` 文件夹
- 从 Mac 导入的书籍会优先复制到 iCloud Drive 的 `极简阅读` 文件夹
- TXT 阅读：字号调整、夜间模式、长文本滚动
- PDF 阅读：连续页面、自动缩放
- EPUB 阅读：解压并按 spine 合并章节后使用 WebKit 渲染
- MOBI、AZW、AZW3：通过本机 Calibre 解码器转换为临时 EPUB 后阅读，不修改 iCloud 原文件
- 阅读时可点击工具栏“隐藏书架”进入沉浸式阅读，再点击“显示书架”恢复
- 支持快捷键 `⌘⇧S` 切换左侧书架显示状态，并记住上次选择
- 支持把文件直接拖入 App 图标打开
- 支持在访达中对书籍文件使用“打开方式 → 简阅”，会自动复制到当前 iCloud 书库并打开
- 同步时会清理已经从 iCloud 文件夹删除的书架记录；本地文件记录不会因 iCloud 暂时不可用而被误删

## 项目目录说明

- `Sources/IntelReader/main.swift`：主程序源码
- `Info.plist`：App 元数据与文档类型声明
- `build.sh`：构建 Intel `x86_64` 版 App 的脚本
- `outputs/简阅.app`：当前最新构建产物
- `NEXT_CHAT_PROMPT.md`：给新对话继续协作用的开场提示
- `work/`：调试和验收过程中留下的截图、过程记录等临时材料，不参与 App 运行，可按需清理

## 构建

需要 macOS 12 或更新版本，以及 Swift 5.8 或更新版本。MOBI/AZW 阅读还需要安装 Calibre。

```sh
./build.sh
open "build/简阅.app"
```

当前构建脚本会生成 Intel `x86_64` 可执行文件。未提供开发者签名，首次打开时可以在 Finder 中右键选择“打开”。

MOBI/AZW 文件打开时，App 会在后台调用 Calibre 的 `ebook-convert`，转换结果只保存在临时目录。带 DRM 的电子书通常无法转换，需要先使用无 DRM 文件或先转换成 EPUB。

## iCloud 说明

这个版本直接使用 macOS 已经挂载的 iCloud 本地目录，不使用第三方服务器。对于你在 iPhone 上安装的“极简阅读”，默认目录是：

```text
~/Library/Mobile Documents/iCloud~com~photon~reader/Documents
```

如果系统使用普通 iCloud Drive 文件夹，也支持以下路径：

```text
~/Library/Mobile Documents/com~apple~CloudDocs/极简阅读
```

首次启动会自动查找这两个位置，也可以点击侧栏“位置”手动选择。右键书籍后：

- “编辑书名和作者”会在同一个窗口中保存两项信息，只修改 Mac 版书架显示。
- “从书架移除”只移除本地书架记录，不删除 iCloud 原文件。
- “从 iCloud 删除并移出书架”会删除 iCloud 原文件，并同步从本地书架移除；EPUB 目录包也会整体删除。
