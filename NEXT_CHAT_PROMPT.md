# 新对话开场提示

请继续优化这个 Intel Mac 阅读 App。

项目目录：
`/Users/kbdz/Documents/EasyRead`

GitHub 公开仓库：
`https://github.com/KBDZequalsCK/EasyRead`

请先阅读：

- `README.md`
- `NEXT_CHAT_PROMPT.md`
- `Sources/IntelReader/main.swift`
- `Info.plist`
- `build.sh`

当前最新 App：
`/Users/kbdz/Documents/EasyRead/outputs/简阅.app`

请先检查现有功能和代码，再根据我后续提出的问题修改源码、重新构建 Intel `x86_64` 版本，并验证 App 可以启动。不要删除或覆盖我的 iCloud 原书文件。

当前重要背景：

- 这个 App 是给 Intel Mac 用的原生阅读器项目。
- iCloud 主要使用的路径是：`~/Library/Mobile Documents/iCloud~com~photon~reader/Documents`
- 书架数据保存在：`~/Library/Application Support/IntelReader/library.json`
- 当前 App 已支持：TXT、PDF、EPUB、MOBI、AZW、AZW3
- 访达“打开方式 → 简阅”已支持自动导入并打开
- 同步会清理已经从 iCloud 文件夹删除的书架记录
- 输出目录里应只保留一个 `.app`，不需要 ZIP

如果我在新对话里直接提出某个 Bug 或新需求，请先读取以上文件后再动手修改。
