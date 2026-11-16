# EasyRead for Intel Mac

A minimal native reading app for Intel-based Macs. EasyRead is an independent AppKit reimplementation of a local reading workflow; it does not copy code or assets from the original app.

## Repository

The project is published at [github.com/KBDZequalsCK/EasyRead](https://github.com/KBDZequalsCK/EasyRead) as a public repository.

## Features

- Import and manage TXT, Markdown, EPUB, PDF, MOBI, AZW, AZW3, FB2, CBZ, RTF, and DOCX books
- Three peer libraries, one active at a time: **iCloud**, **Jianguoyun**, or a **local Mac folder**; each has its own full bookshelf
- Switch libraries from the bar above the book list; every library keeps its own view and remembered folder
- **清理书架** next to the 简阅 title clears only the active library's shelf records; book files and cloud snapshots stay untouched
- Store the bookshelf at `~/Library/Application Support/IntelReader/library.json`
- Automatically discover and scan the `极简阅读` folder in iCloud Drive
- Jianguoyun WebDAV is a full cloud library with two explicit direction buttons: **上传** pushes Mac books and this Mac's reading positions; **下载** pulls cloud books and their positions. Each action writes one new snapshot and never overwrites older ones
- The Jianguoyun settings window follows the reference layout (server, account, app password, remote folder, auto-sync, last sync) and keeps configuration separate from the two direction actions; automatic sync downloads new cloud books, uploads missing local books, and exchanges reading positions
- Right-click a Jianguoyun book and choose **从坚果云删除并移出书架** to write a deletion snapshot (`isRemove` plus a file tombstone) and remove this Mac's shelf record and cache copy, while older snapshots stay intact
- Since 0.4.9 the Jianguoyun app password is read silently: launch, status checks, and automatic sync never show the macOS keychain authorization dialog. The password is still stored only in the login keychain, but its ACL is written like Keychain Access' “Allow all applications to access this item”, so ad-hoc rebuilt versions can keep reading it. After upgrading, enter the app password once in settings; the old 0.4.8 keychain item is neither read nor deleted
- Since 0.4.10 the Jianguoyun shelf shows ZenReader's own percentage from the latest snapshot, so it matches the phone (for example 16.93% becomes 16% on the shelf); the local character/page anchor used to open the book is still converted separately. PDFs now use the phone's `(page + 1) / pageCount` formula instead of losing one page
- Since 0.4.10 the keychain item is `EasyRead.ZenReaderWebDAV.v3`, created through the legacy Keychain API because macOS 13 ignored the access object passed to `SecItemAdd` in 0.4.9. Saving now verifies the stored ACL immediately; a reachable 0.4.9 item is migrated, otherwise re-enter the app password once. Reads stay silent and never show a dialog
- Since 0.4.11 the rendered page of every opened book is cached under `~/Library/Application Support/IntelReader/BookCache`. EPUBs are unzipped and MOBI/AZW/AZW3 files are decoded only on the first open; later opens reuse the cache and start in about a second. The cache key covers the source path, size, and modification date, so replaced books are rebuilt automatically, and old entries are pruned
- Since 0.4.13 the **actual reading position** matches the phone, not just the shelf percentage. Each book stores two separate metrics: `progress` (how far the WebView has scrolled) and `textProgress` (character fraction of the extracted book text, the metric ZenReader converts to and from the phone's chapter-weighted percent). Opening a book seeks by the phone's sentence anchor when one is synced, then by `textProgress`; scrolling reports both values. The text model no longer counts `<head>` text, removing a ~1% offset in EPUBs, and PDF pages use rounded `(page + 1) / pageCount`
- Since 0.4.14 Markdown files (`.md` / `.markdown`) open as formatted pages through `MarkdownRenderer.swift`: headings, nested lists, task lists, quotes, code blocks, tables, links, strikethrough, and images relative to the file (embedded as data URLs up to 10 MB each). Raw HTML is shown as text, and rendered pages reuse the same BookCache, font-size, and light/dark controls. The same Finder open arriving twice is now de-duplicated, so a book opened from Finder stays open instead of being closed by the first shelf refresh
- Since 0.4.15 EasyRead is intentionally built unsigned. macOS gives every ad-hoc-signed build a new `cdhash:<hash>` keychain partition, so the saved password became unreadable after each rebuild and had to be typed again. Unsigned code gets the stable `unsigned:` partition instead. The password now lives in a new `EasyRead.ZenReaderWebDAV.v4` item created by the unsigned build; enter it one last time after upgrading, and later rebuilds read it silently without a dialog
- Since 0.4.16 Jianguoyun transfers are faster: up to three books upload/download in parallel, book files stream between disk and network with `uploadTask`/`downloadTask` instead of being held whole in memory, and each sync lists `objects/books` once instead of probing every object. Extracted chapter models are cached on disk in `~/Library/Application Support/IntelReader/TextModelCache` (keyed by path, size, and modification date, up to 24 books), so launches and syncs no longer re-parse every TXT/EPUB or re-decode MOBI books. A silently dropped keep-alive connection is retried once. On a localhost mock (0.2 s latency, nine ~630 KB books) the first download took 3.1 s instead of the serial 8.2 s, and a warm-cache launch took 0.1 s instead of 3.1 s. The real-network floor is still Jianguoyun's own per-account throughput and latency
- Since 0.4.17 the Jianguoyun library bar and sync settings show the live sync state instead of a generic “syncing” label: an animated spinner plus phase text such as “Downloading 2/5…”, “Preparing reading positions…”, and “Writing cloud snapshot…”. Upload/download buttons are disabled while a sync runs, a finished sync stays visible as “Sync complete · …”, and an idle but previously synced library shows “Last sync 14:32” rather than only “Ready”. Both the light and dark themes use the same status row
- Since 0.4.18 snapshots uploaded by the Mac are accepted by ZenReader again. ZenReader validates a snapshot's `dataSize`/`dataSha256` over a canonical payload, not the raw `readerzen.json` bytes: the object with its top-level `createdAt` removed, re-serialized compact with sorted keys and Foundation's default escaping. Earlier builds hashed the file they uploaded, which made every Mac snapshot fail the phone's check with “WebDAV数据校验失败”. The publisher now writes the canonical digest; the scheme was verified by recomputing size and SHA-256 for five existing phone-created snapshots with exact matches. The post-upload echo also no longer pretends the push came from the cloud (it used to overwrite `textProgress` with the scroll fraction and clear sentence anchors), and a book with no real local position can no longer overwrite a real position from the phone. Older Mac snapshots keep their raw-byte manifests and stay rejected; one new upload from 0.4.18 repairs the root manifest
- Since 0.5.0 MOBI, AZW, and AZW3 books open without Calibre. `MOBIParser.swift` reads the Palm database, PalmDOC and HUFF/CDIC compression, KF8 skeleton/fragment tables, FDST flows, and resource images directly, so a fresh Mac with nothing but EasyRead installed can read every supported format. On the four real test books the extracted text matches Calibre's EPUB output character for character, and parsing takes 0.15–0.95 s instead of minutes. DRM-protected Kindle books are still refused with a clear message. The rendered-page and chapter-model cache versions were bumped so old Calibre-based caches are not reused
- Since 0.5.1 EPUB books are fully in-process as well. `ZipArchive.swift` reads the ZIP central directory and inflates entries with the system zlib that ships with macOS, replacing the `/usr/bin/unzip` subprocess. Chapters are parsed straight from memory and only images/fonts are written to the reader folder. Merged chapters now rewrite relative resource URLs (`../images/…`) so EPUB illustrations actually display; tested on a real 77-entry EPUB with all image references resolving. Reading progress is coalesced into at most one `library.json` write per 0.8 s (flushed on quit), and the Jianguoyun shelf percentage is recomputed only after scrolling settles instead of on every percent change
- Since 0.6.0 the reader has a real table of contents and in-book search. The contents button builds chapters from the same cached model that sync uses (TXT/EPUB/MOBI/AZW), Markdown heading anchors, PDF outlines, FB2 section titles, or CBZ page names; selecting a row jumps to that position. The search button (or ⌘F) shows a find bar that uses `WKWebView.find` for web books and `PDFDocument.findString` with highlighted selections for PDFs. The last opened book is restored on launch, FB2 and CBZ are now built-in formats, sync caches SHA-256 digests by path/size/modification date, MOBI parts are kept in memory between the first open and the first sync, and progress is also flushed when the app loses focus
- Since 0.7.0 RTF and DOCX are built in. `RTFRenderer.swift` parses groups, control words, Chinese code pages and basic emphasis; `DOCXRenderer.swift` reads WordprocessingML, heading styles, relationships and `word/media` images. Both feed the same table of contents and reader wrapper. EPUB also has an optional publisher-layout switch (View → 使用出版方排版), which inlines the book's CSS with rewritten `url(...)` paths and keeps a separate cache entry; it can be turned off again if a publisher's CSS fights the paged reader
- Since 0.8.0 reading annotations and large-book performance: bookmarks and notes share one `bookmarks.json` store (`⌘D` adds a bookmark, `⌘⇧N` adds a note with optional selected text, `⌘⇧B` opens the bookmarks/notes panel with open/delete). Images in every web format now use `loading="lazy" decoding="async"`. CBZ pages are no longer inflated to disk: `ComicPageSchemeHandler` serves each page from the ZIP on demand through a custom `easyread-comic://` scheme with a small LRU cache, so opening a multi-hundred-MB comic only reads the central directory and the pages near the viewport
- Since 0.9.0 comics have a native two-page spread mode. `ComicReaderView` loads pages directly from the CBZ, pairs portrait pages side by side, shows landscape pages alone, and supports arrow keys, PageUp/PageDown, space, mouse wheel, and click zones (left half = previous, right half = next). The page indicator shows ranges such as `1–2 / 5` or `3 / 5`, bookmarks store the exact page, and the table of contents jumps to `cbz-page-*` anchors. Spread is the default comic mode; the mode menu also offers continuous scroll and native single-page modes. Comics no longer use WKWebView in paged modes, so pairing and paging are not affected by CSS measurement
- Since 0.9.1 saved notes can be edited. Select a note in the bookmarks panel and press Edit: the editor opens with the existing text, saving updates the same record in `bookmarks.json`, and the list refreshes in place. The same button also turns a plain bookmark into a note
- Since 0.9.2 TXT books are split into ordinary paragraphs instead of one giant text node, which cuts WebKit's multi-column layout for a 1 MB novel from about 11.8 s to about 0.75 s. TXT hands the current page directly to the new paged layout, so the first painted frame is already that page. Other formats restore the sentence at the top of the old page instead, because their vertical and horizontal paginations can differ; the reading position is kept even when the page number moves by one (for example an EPUB cover). The paged wrapper is reused when entering vertical mode, avoiding a ~650 ms DOM move
- Since 0.9.3 text-book tables of contents normalize CR/CRLF line endings before taking the chapter title, so Windows-style TXT files no longer show a whole preview as the title. Chapter jumps use the same native find as search with the first line as locator, and the page indicator refreshes immediately after the jump
- Since 0.9.4 paged PDFs save the page the reader is actually looking at: progress reporting is throttled by page instead of one percent, so a 265-page document no longer keeps an old `currentProgress` under one percent per page. Bookmarks read `PDFView.currentPage` directly, and TOC/bookmark jumps refresh the page indicator immediately instead of being suppressed by the restore guard. Toggling “use publisher layout” on an EPUB now captures the live pager position first, so a 612-page book stays at the same passage instead of returning to page 1; TOC anchor jumps also report their new position right away. Verified with a 265-page PDF (TOC jump to `24 / 265`, bookmark `pageIndex 23`, restart restores `24 / 265`) and a 612-page EPUB (`5 / 486 → 6 / 612` across the layout switch). The same release removes the pause when showing or hiding the bookshelf: the frozen column grid and page count stay unchanged while only the visible frame moves, so the transition no longer reflows the book or leaks half of the previous page
- Remember the last chosen iCloud folder and local folder separately, and reopen each chooser there
- Copy books imported from Finder into the active iCloud library before opening them
- TXT reading with font-size controls, dark mode, and long-text scrolling
- Markdown (`.md` / `.markdown`) reading with rendered headings, lists, task lists, quotes, code blocks, tables, links, and local images
- Continuous PDF reading with automatic zoom
- EPUB rendering through WebKit after merging the spine chapters
- MOBI, AZW, and AZW3 support through the built-in `MOBIParser.swift` decoder (PalmDOC, HUFF/CDIC, and KF8), with no external tools
- FB2 support through `FB2Renderer.swift` (sections, titles, poems, quotes, tables, and base64-embedded images)
- CBZ comic support through `ComicRenderer.swift` (natural page order, page list in the contents popover)
- RTF support through `RTFRenderer.swift` (paragraphs, emphasis, Chinese code pages)
- DOCX support through `DOCXRenderer.swift` (headings, runs, tables flattened to paragraphs, inline images)
- Optional EPUB publisher layout from the View menu; book CSS is inlined and resource URLs are rewritten
- Bookmarks and notes per book (`⌘D`, `⌘⇧N`, `⌘⇧B`), stored in `~/Library/Application Support/IntelReader/bookmarks.json`
- Lazy image loading for EPUB, MOBI, FB2, DOCX, and CBZ
- Large CBZ pages are decompressed on demand from the archive instead of being pre-extracted
- Native two-page comic spread: portrait pages paired, landscape pages shown alone, page ranges in the indicator, click zones/keys/wheel navigation
- Table of contents for TXT, Markdown, EPUB, MOBI/AZW/AZW3, PDF, FB2, CBZ, RTF, and DOCX
- In-book search with ⌘F: WebKit find for HTML books, PDFKit highlighted matches for PDFs
- Immersive reading mode with a bookshelf visibility toggle and the `⌘⇧S` shortcut
- Open books by dragging them onto the app icon or choosing EasyRead from Finder's Open With menu
- Switch the interface between Chinese and English from the app menu or the sidebar footer; the choice is remembered
- Remove stale iCloud bookshelf records without deleting local-file records when iCloud is temporarily unavailable

## Project Layout

- `Sources/IntelReader/main.swift`: application source
- `Sources/IntelReader/MarkdownRenderer.swift`: dependency-free Markdown-to-HTML renderer used by the reader
- `Sources/IntelReader/MOBIParser.swift`: dependency-free MOBI/AZW/AZW3 decoder (PalmDOC, HUFF/CDIC, KF8 reconstruction, images)
- `Sources/IntelReader/ZipArchive.swift`: in-process ZIP reader for EPUB, using the macOS system zlib
- `Sources/IntelReader/FB2Renderer.swift`: FictionBook (FB2) to HTML renderer
- `Sources/IntelReader/ComicRenderer.swift`: CBZ page-image comic renderer
- `Sources/IntelReader/ComicReaderView.swift`: native single/two-page comic reader with on-demand page loading
- `Sources/IntelReader/RTFRenderer.swift`: RTF text renderer
- `Sources/IntelReader/DOCXRenderer.swift`: DOCX (WordprocessingML) renderer
- `Sources/IntelReader/ChapterHeading.swift`: shared chapter-heading heuristic
- `Sources/IntelReader/BookmarkStore.swift`: bookmark/note persistence (`bookmarks.json`)
- `Info.plist`: app metadata and document type declarations
- `build.sh`: build script for the Intel `x86_64` app
- `package-dmg.sh`: creates a distributable Intel DMG with an installation guide
- `DMG_README.txt`: bilingual guide included in the DMG
- `outputs/EasyRead.app`: latest built app bundle
- `NEXT_CHAT_PROMPT.md`: context for continuing development in a new conversation
- `work/`: optional debugging and acceptance artifacts; not required at runtime

## Build

Requires macOS 12 or later and Swift 5.8 or later. No other software is required: MOBI/AZW reading is built in.

```sh
./build.sh
open "outputs/EasyRead.app"
```

The build script produces an unsigned Intel `x86_64` executable. On first launch, use Finder's Open command if macOS blocks the unsigned app.

To create the distributable DMG (after building the app):

```sh
./package-dmg.sh
open "outputs/EasyRead-Intel.dmg"
```

The DMG contains the app, an Applications shortcut, and a bilingual installation guide. Ordinary users should download the DMG from the repository's **Releases** page instead of downloading the source ZIP.

MOBI, AZW, and AZW3 books are decoded by the built-in parser in a background thread; images are written only to a temporary directory. No external converter is launched. DRM-protected Kindle books cannot be decoded and show an explicit message instead.

## iCloud

This version uses the iCloud directories already mounted by macOS and does not use a third-party server. The default path for the iPhone app's library is:

```text
~/Library/Mobile Documents/iCloud~com~photon~reader/Documents
```

The standard iCloud Drive folder is also supported:

```text
~/Library/Mobile Documents/com~apple~CloudDocs/极简阅读
```

On first launch, EasyRead checks both paths. You can also choose a location from the library bar; the chooser reopens at the folder you used last time. Book metadata edits only affect the Mac bookshelf; removing a book from the bookshelf does not delete the iCloud original unless the explicit iCloud deletion action is chosen.

The library bar above the book list switches between three peer libraries: **iCloud 书库**, **WebDAV 书库**, and **本地书库**. Each library stores its own shelf records and remembers its own folder; switching never mixes the lists. **清理书架** next to the 简阅 title removes only the active library's shelf records, and is handy when changing iCloud accounts or folders; book files, local files, and Jianguoyun snapshots are left untouched. The folder button at the right of the bar opens the chooser at the folder you used last time.

## WebDAV Library (Jianguoyun)

Jianguoyun is a full peer library, not just a progress channel. 极简阅读 on the iPhone/iPad writes its shelf, book objects, and reading positions into `ZenReader/v1/`; EasyRead reads the newest `readerzen.json` snapshot and stores books downloaded from the cloud in `~/Library/Application Support/IntelReader/ZenReaderBooks`. Book files are stored under `objects/books/` with the SHA-256 of the content as the file name (plus extension); each snapshot entry points to its object through `extraJSON.webdav.path`, and `fileSize` is stored as a raw byte count. EasyRead reads and writes this native layout. Every new snapshot also gets a `manifest.json` (books index, exact `readerzen.json` SHA-256/size, snapshot history), and `ZenReader/v1/manifest.json` is refreshed to point at the newest snapshot so the phone can discover Mac-created snapshots and books; only that shared pointer is overwritten, never an older snapshot.

Setup:

1. On the iPhone/iPad, open 极简阅读, run its Jianguoyun sync at least once, and leave one book partway through.
2. In EasyRead, switch the library bar to **WebDAV 书库** and click the gear, or choose **File → WebDAV 同步设置…**.
3. Keep the default server `https://dav.jianguoyun.com/dav/`, enter your Jianguoyun account email, and paste an **app password** created at Jianguoyun → Account Info → Security → Add App Password. Do not use your website login password. Use **测试连接** (Test Connection) before saving.
4. Click **保存配置** (Save Settings). Use **上传到云端 / 从云端下载** in the settings window, or **上传 / 下载** in the library bar. Close the window with the upper-right X or Esc.

What the two direction actions do:

- **上传 (Upload)** pushes Mac books missing from the cloud and this Mac's real reading positions to Jianguoyun. A confirmation lists the books, total size, and how many matched books will receive positions.
- **下载 (Download)** reads the newest snapshot, downloads missing cloud books, and restores their reading positions in the same pass. It is additive and asks for no confirmation.
- Both actions write one **new** timestamped snapshot and never overwrite or delete older snapshots or existing cloud books.
- Automatic sync (enabled in settings) downloads new cloud books, uploads local books missing from the server, and exchanges reading positions, at most every five minutes; the two buttons below provide an immediate manual sync.

Deleting a book:

- Right-click a Jianguoyun shelf book and choose **从坚果云删除并移出书架**. EasyRead writes a new snapshot with `isRemove = 1`, `deleteDate`, and a matching `file` tombstone, then removes this Mac's shelf record and downloaded cache copy.
- When a book is deleted on the phone or another device, the next sync on this Mac also removes its shelf record and downloaded cache copy; files that were not downloaded by EasyRead are never deleted.
- Older snapshots and the book object already stored on the server are not touched, so the data can still be recovered from snapshot history. The phone hides the book after its next Jianguoyun sync.

Limits:

- At least one snapshot must already exist on the server; create it with one Jianguoyun sync in the iPhone app.
- Books are matched by format, title/author, and file size. Unmatched books are left untouched.
- The iPhone app must run its own Jianguoyun sync to pick up a snapshot created on the Mac.
- The app password is stored only in the macOS Keychain; HTTPS is required except for localhost testing. Since 0.4.9 all reads are silent. Since 0.4.15 EasyRead is built unsigned so its keychain partition is the stable `unsigned:` value, which is what keeps the saved password readable across rebuilds; the item also keeps an “allow all applications” ACL so no authorization dialog appears.
- PDF positions are synced by page. TXT and EPUB positions are synced by chapter plus character offset. MOBI/AZW/AZW3 positions are approximate because the built-in parser may split chapters differently from the phone app.
- Markdown, FB2, CBZ, RTF, and DOCX are Mac-side reading formats. Jianguoyun upload skips `.md` / `.markdown` / `.fb2` / `.cbz` / `.rtf` / `.docx` files because the iPhone app has no renderer for them, so they stay on this Mac's shelf and are never written into a cloud snapshot.

The local library is a plain folder on this Mac. The folder button chooses it, **扫描** refreshes its book list, and its files are never copied, uploaded, or synced anywhere.

---

# EasyRead Intel 版

一个面向 Intel 芯片 Mac 的本地极简阅读器原型。它不是对原 App 的代码或素材复制，而是用原生 AppKit 重实现类似的本地阅读体验。

GitHub 公开仓库：<https://github.com/KBDZequalsCK/EasyRead>

## 当前功能

- 新对话协作说明见 `NEXT_CHAT_PROMPT.md`
- 导入并管理本地 TXT、Markdown、EPUB、PDF、MOBI、AZW、AZW3、FB2、CBZ、RTF、DOCX 文件
- 书架记录保存在 `~/Library/Application Support/IntelReader/library.json`
- 自动读取 iCloud Drive 中的 `极简阅读` 文件夹，在启动、手动同步或回到前台（距上次同步超过 3 分钟）时扫描
- 同一时间只使用一个书库，三个书库完全同级：**iCloud 书库**、**WebDAV 书库**、**本地书库**，各自拥有独立的完整书架，切换时不会混在一起
- 坚果云是完整的云端书库，书库栏提供“上传 / 下载”两个方向按钮：上传把本机书籍和这台 Mac 的阅读进度推到云端，下载把云端书籍和进度取回本机；每次只新建一份快照，绝不覆盖旧快照
- 书籍文件按极简阅读的原生布局存放：`objects/books/<内容 SHA-256>.<扩展名>`，快照条目通过 `extraJSON.webdav.path` 指向真实对象，`fileSize` 为原始字节数字符串；EasyRead 按此格式读取，并以同样格式上传
- 每次新建快照同时写入 `snapshots/<时间戳>/manifest.json`（书籍索引、`readerzen.json` 的精确 SHA-256 与字节数、快照历史），并刷新根目录 `ZenReader/v1/manifest.json` 指向最新快照，便于手机发现 Mac 新建的快照与书籍；只覆盖这个共享指针，旧快照目录不会被改写
- 0.4.9 起坚果云应用密码改为静默读取：启动、状态检查和自动同步都不会再弹出 macOS 钥匙串授权窗口。密码仍只保存在登录钥匙串，但按钥匙串访问里的“允许所有应用程序访问此项目”写入 ACL，因此重新构建的版本也能直接读取；升级后需要在设置窗口重新输入一次应用密码，旧的 0.4.8 钥匙串条目不会被读取或删除
- 0.4.10 起坚果云书架直接显示快照里的 `progress`，也就是手机上的同一数值（例如手机 16.93% 在书架显示 16%）；打开书时仍使用换算后的本机字符/页锚点。PDF 改用手机的 `(页 + 1) / 总页数` 计算，不再少算一页。因此《心理罪》会从 24% 变为 30%，《玫瑰的名字》从 5% 变为 16%，与手机一致
- 0.4.10 起应用密码改用 `EasyRead.ZenReaderWebDAV.v3`，并通过旧版 Keychain API 创建：实测 macOS 13 会忽略 0.4.9 传给 `SecItemAdd` 的 access 对象，导致换一次构建就失效。保存时会立即读回并校验 ACL；能静默读取的 0.4.9 条目会自动迁移，否则需要再输入一次应用密码。所有读取仍不弹系统窗口
- 0.4.11 起每本书渲染好的阅读页会缓存在 `~/Library/Application Support/IntelReader/BookCache`：EPUB 只在首次打开时解压，MOBI/AZW/AZW3 只在首次打开时解码，之后重复打开直接读取缓存，约 1 秒内显示。缓存按“文件路径 + 大小 + 修改时间”失效，换了新文件会自动重建，旧缓存自动清理
- 0.4.13 起**真实阅读位置**与手机对齐，而不只是书架上的百分比。每本书分别保存两个指标：`progress` 是 WebView 的滚动比例，`textProgress` 是全书提取文本的字符比例（极简阅读换算手机章节百分比所用的同一指标）。打开书时优先跳到同步来的手机句子锚点，没有锚点则按 `textProgress` 定位；滚动时同时回报两个值。文本模型不再把 `<head>` 计入正文，消除了 EPUB 约 1% 的偏移；PDF 页码改为四舍五入的 `(页 + 1) / 总页数`。这样《心理罪》在手机上 30% 的位置，Mac 会从同一段开始，而不是按滚动高度提前很多
- 0.4.14 起支持 Markdown（`.md` / `.markdown`）阅读：由 `MarkdownRenderer.swift` 渲染标题、嵌套列表、任务列表、引用、代码块、表格、链接、删除线，以及相对文件路径的本地图片（以 data URL 内嵌，单张最多 10 MB）；原始 HTML 按文本显示。渲染结果沿用 BookCache、字号和日夜主题，重复打开直接读缓存。同时修复访达打开同一文件会收到两次打开事件、导致书被首次书架刷新关掉的问题，现在会按路径去重并保持打开
- 0.4.15 起 EasyRead 按未签名（unsigned）构建。macOS 会把 ad-hoc 签名的钥匙串条目锁定到当次构建的 `cdhash:<哈希>` 分区，而哈希每次重建都会变，所以以前每改一次代码就要重输一次坚果云应用密码。未签名代码得到的是稳定的 `unsigned:` 分区。应用密码改存到新的 `EasyRead.ZenReaderWebDAV.v4` 条目，由未签名构建创建；升级后在设置里最后输入一次，之后重建都能静默读取，不再弹窗
- 0.4.16 起坚果云传输明显加快：书籍上传/下载最多 3 本并发，用 `uploadTask`/`downloadTask` 在磁盘与网络之间流式传输，不再把整本书读进内存；每次同步只列一次 `objects/books`，不再逐个对象探测。提取出的章节模型新增磁盘缓存 `~/Library/Application Support/IntelReader/TextModelCache`（按路径、大小、修改时间失效，最多 24 本），启动和同步不再重复解析每本 TXT/EPUB，也不会重复解码 MOBI。连接被服务器悄悄关闭时会自动重试一次。localhost mock（0.2 秒延迟、9 本约 630 KB）实测首次下载 3.1 秒，串行基线 8.2 秒；热缓存启动 0.1 秒。真实网络的下限仍取决于坚果云账号自身的带宽与延迟
- 0.4.17 起坚果云书库栏和同步设置窗口都会显示实时同步状态，而不再只有笼统的“正在同步”：转动的进度指示器，加上“正在下载 2/5…”“正在整理阅读进度…”“正在写入云端快照…”等阶段文字。同步期间“上传 / 下载”按钮会禁用；完成后状态保留为“同步完成 · …”；空闲时若以前同步过，会显示“上次同步 14:32”，而不是只显示“准备同步”。日间和夜间主题使用同一套状态行
- 0.4.18 起 Mac 上传的快照终于能被极简阅读校验通过。极简阅读并不是对 `readerzen.json` 的原始字节算 `dataSize`/`dataSha256`，而是先去掉顶层 `createdAt`，再用 Foundation 默认转义、排序键、紧凑 JSON 重新序列化后计算；旧版对上传字节做哈希，于是 Mac 新建的每个快照都被手机判为“WebDAV数据校验失败”。新版本按该规范写入摘要，并用五份手机已有快照重算大小与 SHA-256 逐一精确命中验证。同时修复上传后回写：推送结果不再伪装成云端更新（旧逻辑会把 `textProgress` 覆盖成滚动比例并清掉句子锚点），本机没有真实位置的书也不再覆盖手机已有的位置。旧的 Mac 快照仍是原始字节摘要，无法通过校验；需要从 0.4.18 再上传一次来更新根清单
- 坚果云设置窗口按参考布局重做：服务器、账号、应用密码、远程目录、自动同步、上次同步，并在底部提供“上传到云端 / 从云端下载”；自动同步会自动下载云端新书、上传本机缺少的书籍并交换阅读进度，底部两个按钮用于立即手动同步
- WebDAV 书库右键“从坚果云删除并移出书架”会写入删除快照（`isRemove` 与文件墓碑），同时移除本机书架与下载缓存，旧快照仍保留
- 标题“简阅”旁的“清理书架”只清除当前书库的书架记录，不删除 iCloud 或本地书籍文件，也不删除云端快照；更换 iCloud 账号或文件夹后可借此避免重复书籍
- 0.5.0 起 MOBI、AZW、AZW3 不再依赖 Calibre。`MOBIParser.swift` 直接读取 Palm 数据库、PalmDOC 与 HUFF/CDIC 压缩、KF8 的骨架/片段表、FDST 文本流和图片资源，因此一台什么都没安装的 Mac 只要装上 EasyRead 就能读全部支持的格式。四本真实书籍的提取文本与 Calibre 生成的 EPUB 逐字符一致，解析耗时 0.15–0.95 秒，而不是原来的分钟级。带 DRM 的 Kindle 书仍会明确提示无法解码。渲染页缓存与章节模型缓存的版本号已提升，旧的 Calibre 结果不会被复用
- 0.5.1 起 EPUB 也完全进程内解析：`ZipArchive.swift` 直接读取 ZIP 中央目录，并用 macOS 自带的系统 zlib 解压，不再启动 `/usr/bin/unzip`；章节直接从内存读取，只把图片和字体写入阅读目录。合并章节时会重写 `../images/…` 这类相对资源路径，修复了 EPUB 插图此前在单页阅读器中不显示的问题（用真实 77 条目 EPUB 验证，全部图片引用均可解析）。阅读进度最多每 0.8 秒合并写入一次 `library.json`（退出前强制 flush），坚果云书架百分比只在滚动停止后重算，不再每 1% 触发一次全表搜索
- 0.6.0 起阅读器有真正的目录与全书搜索：目录按钮用同步同一份缓存章节表生成 TXT/EPUB/MOBI/AZW 目录，Markdown 用标题锚点，PDF 用大纲，FB2 用章节标题，CBZ 用页码；点击任意一行即可跳转。搜索按钮（或 ⌘F）会显示查找条，HTML 书籍用 `WKWebView.find`，PDF 用 `PDFDocument.findString` 并高亮匹配。启动时会恢复上次打开的书；新增内置 FB2 与 CBZ 格式；同步会按“路径 + 大小 + 修改时间”缓存 SHA-256；MOBI 首次打开与首次同步共用同一份解析结果；窗口失焦时也会落盘阅读进度
- 0.7.0 起内置 RTF 与 DOCX：`RTFRenderer.swift` 解析 RTF 分组、控制字、中文字符集和基本强调；`DOCXRenderer.swift` 读取 WordprocessingML、标题样式、关系表和 `word/media` 图片。两者都接入同一套目录与阅读外壳。EPUB 新增“显示 → 使用出版方排版”开关：会把书内 CSS 内联进阅读页，并重写其中 `url(...)` 的相对路径，同时使用独立缓存；如果出版方 CSS 与分页阅读冲突，可以随时关闭
- 0.8.0 起支持书签、笔记和超大漫画：书签与笔记共用 `bookmarks.json`（⌘D 加书签，⌘⇧N 加笔记并可附带选中文字，⌘⇧B 打开书签/笔记面板，可打开或删除）。所有网页格式的图片改为 `loading="lazy" decoding="async"` 懒加载。CBZ 不再把每页解压到磁盘：`ComicPageSchemeHandler` 通过自定义 `easyread-comic://` 协议按需从 ZIP 读取当前视口附近的页面，并带一个小型缓存，因此几百 MB 的漫画打开时只读中央目录和附近几页
- 0.9.0 起漫画有原生双页模式：`ComicReaderView` 直接从 CBZ 读取页面，竖页左右并排、横页单独显示；支持方向键、PageUp/PageDown、空格、鼠标滚轮和点击左右半屏翻页。页码显示为 `1–2 / 5` 或 `3 / 5`，书签保存精确页码，目录按 `cbz-page-*` 锚点跳转。漫画默认使用双页，模式菜单仍可切换连续滚动和原生单页；分页漫画不再经过 WKWebView，因此不受 CSS 测量影响
- 0.9.1 起已保存的笔记可以编辑：在书签/笔记面板中选中条目点“编辑”，对话框会用原笔记内容预填，保存后更新同一条 `bookmarks.json` 记录，并自动回到刷新后的笔记列表；普通书签也可以用同一按钮补写笔记
- 0.9.2 起修复 TXT 分页模式切换卡顿和跳页：TXT 不再整本塞进一个巨大文本节点，而是按自然段拆成普通段落，1 MB 小说从上下翻页切到左右翻页的 WebKit 分栏耗时从约 11.8 秒降到约 0.75 秒；TXT 切换时直接把当前页交给新布局，第一帧就是同一页。其他格式按旧页顶部的正文锚点恢复，因为它们的上下/左右分页网格可能不同，页码偶尔会差 1 页（例如 EPUB 封面），但阅读位置不丢；进入上下翻页时复用分页外壳，省掉约 650 毫秒的 DOM 迁移
- 0.9.3 起修复 TXT 目录：章标题统一 CR/CRLF/CR 换行后再取首行，Windows 换行的书不再把整段预览当标题；目录跳转复用系统查找来定位章节首行，并在跳转后立即刷新页码指示器
- 0.9.4 起修复分页 PDF 与 EPUB 排版切换：PDF 进度改为按页节流，265 页文档翻一页不再被 1% 阈值吞掉；书签直接读当前可见页，目录/书签跳转后页码立即刷新（验证：目录跳到 `24 / 265`，⌘D 保存 `pageIndex 23`，重启仍回到第 24 页）。EPUB 开关“使用出版方排版”前先读取当前阅读位置，612 页的大书在 `5 / 486 ↔ 6 / 612` 之间切换仍停在原段落，不再回到空白第 1 页；目录锚点跳转也会立即写入阅读进度。同一版本还修复了书架显示/隐藏时的卡顿与“一页半”残影：冻结分栏网格和总页数不变，只移动可见窗口，切换不再整书重排，也不会露出上一页的半页内容
- 无论 iCloud 书库还是本地书库，都会分别记住上一次选择的文件夹，下次打开选择器直接回到该位置；本地书库点“扫描”刷新书籍
- 从 Mac 导入的书籍会优先复制到 iCloud Drive 的 `极简阅读` 文件夹
- TXT 阅读：字号调整、夜间模式（覆盖书架、标题栏与阅读区）、长文本滚动；按自然段渲染，长篇小说分栏和翻页更快
- Markdown 阅读：支持 `.md` / `.markdown`，渲染标题、列表、任务列表、引用、代码块、表格、链接和本地图片
- PDF 阅读：连续页面、自动缩放
- EPUB 阅读：解压并按 spine 合并章节后使用 WebKit 渲染
- MOBI、AZW、AZW3：由内置 `MOBIParser.swift` 解码（PalmDOC、HUFF/CDIC、KF8），不依赖任何外部工具，也不修改 iCloud 原文件
- FB2：由 `FB2Renderer.swift` 渲染章节、标题、诗歌、引用、表格和内嵌 base64 图片
- CBZ 漫画：由 `ComicRenderer.swift` 按自然文件名顺序显示页面，目录中可直接选页
- RTF：由 `RTFRenderer.swift` 渲染段落、强调和中文编码
- DOCX：由 `DOCXRenderer.swift` 渲染标题、加粗斜体、内嵌图片；表格按段落顺次显示
- EPUB 可选出版方排版：菜单“显示 → 使用出版方排版”，内联书内 CSS 并重写资源路径
- 书签与笔记：⌘D 加书签、⌘⇧N 加笔记、⌘⇧B 打开面板；面板中选中条目后可用“编辑”修改笔记（也可为书签补写笔记），保存在 `~/Library/Application Support/IntelReader/bookmarks.json`
- 图片懒加载：EPUB、MOBI、FB2、DOCX、CBZ 的图片接近视口时才解码
- 超大 CBZ：页面按需从压缩包解压，不再一次性写入全部图片
- 漫画双页：竖页并排、横页单独显示，页码显示范围，支持键盘/滚轮/点击翻页
- 目录：TXT、Markdown、EPUB、MOBI/AZW/AZW3、PDF、FB2、CBZ、RTF、DOCX 均可从工具栏目录按钮打开并跳转
- 全书查找：⌘F 或工具栏放大镜；HTML 书籍使用 WebKit 查找，PDF 使用 PDFKit 高亮匹配
- 阅读时可点击书架标题右侧的按钮进入沉浸式阅读，再点击工具栏“显示书架”或按 `⌘⇧S` 恢复
- 支持快捷键 `⌘⇧S` 切换左侧书架显示状态，并记住上次选择
- 自动记住窗口大小与位置（包括强制退出后的布局），下次启动时恢复
- 支持把文件直接拖入 App 图标打开
- 支持在访达中对书籍文件使用“打开方式 → EasyRead”，会自动复制到当前 iCloud 书库并打开
- 界面支持中文 / English 切换，可在应用菜单或侧栏底部切换，并会记住选择
- 扫描时会清理当前书库中已经不存在于所选文件夹的记录；其他书库的记录不会受影响
- 本地书库的文件夹按钮在书库栏右侧，选好文件夹后会立即扫描；顶部状态文字完整显示，不再被截断

## 项目目录说明

- `Sources/IntelReader/main.swift`：主程序源码
- `Sources/IntelReader/MarkdownRenderer.swift`：阅读器使用的轻量 Markdown → HTML 渲染器，不依赖第三方库
- `Sources/IntelReader/MOBIParser.swift`：内置的 MOBI/AZW/AZW3 解码器（PalmDOC、HUFF/CDIC、KF8 重组、图片），不依赖第三方库
- `Sources/IntelReader/ZipArchive.swift`：内置的 EPUB ZIP 读取器，使用 macOS 系统 zlib，不依赖第三方库
- `Sources/IntelReader/FB2Renderer.swift`：FB2（FictionBook）转 HTML 渲染器
- `Sources/IntelReader/ComicRenderer.swift`：CBZ 漫画页面渲染器
- `Sources/IntelReader/ComicReaderView.swift`：原生单页/双页漫画阅读视图，页面按需加载
- `Sources/IntelReader/RTFRenderer.swift`：RTF 文本渲染器
- `Sources/IntelReader/DOCXRenderer.swift`：DOCX（WordprocessingML）渲染器
- `Sources/IntelReader/ChapterHeading.swift`：共用的章节标题判断
- `Sources/IntelReader/BookmarkStore.swift`：书签/笔记持久化（`bookmarks.json`）
- `Info.plist`：App 元数据与文档类型声明
- `build.sh`：构建 Intel `x86_64` 版 App 的脚本
- `package-dmg.sh`：生成带安装说明的 Intel DMG
- `DMG_README.txt`：会放入 DMG 的中英双语安装说明
- `outputs/EasyRead.app`：当前最新构建产物
- `NEXT_CHAT_PROMPT.md`：给新对话继续协作用的开场提示
- `work/`：调试和验收过程中留下的截图、过程记录等临时材料，不参与 App 运行，可按需清理

## 构建

需要 macOS 12 或更新版本，以及 Swift 5.8 或更新版本。MOBI/AZW 阅读已内置解码器，不需要安装其他软件。

```sh
./build.sh
open "outputs/EasyRead.app"
```

当前构建脚本会生成 Intel `x86_64` 可执行文件，并有意保持未签名（unsigned）：未签名进程在钥匙串中的分区固定为 `unsigned:`，重建后仍能读取已保存的坚果云应用密码；ad-hoc 签名则会随构建改变 `cdhash` 分区。首次打开时可以在 Finder 中右键选择“打开”。

生成可直接分发的 DMG：

```sh
./package-dmg.sh
open "outputs/EasyRead-Intel.dmg"
```

DMG 内含 App、“应用程序”文件夹快捷方式和中英双语安装说明。普通用户应从仓库的 **Releases** 页面下载 DMG，不必下载源码 ZIP。

MOBI、AZW、AZW3 文件由内置解析器在后台线程解码，图片只写入临时目录，不再启动任何外部转换程序。带 DRM 的 Kindle 电子书无法解码，会显示明确提示。

## iCloud 说明

这个版本直接使用 macOS 已经挂载的 iCloud 本地目录，不使用第三方服务器。对于你在 iPhone 上安装的“极简阅读”，默认目录是：

```text
~/Library/Mobile Documents/iCloud~com~photon~reader/Documents
```

如果系统使用普通 iCloud Drive 文件夹，也支持以下路径：

```text
~/Library/Mobile Documents/com~apple~CloudDocs/极简阅读
```

首次启动会自动查找这两个位置，也可以点击书库栏右侧的文件夹按钮手动选择；App 会记住这次选择，下次打开选择器时直接回到该文件夹。书库栏可在“iCloud 书库”“WebDAV 书库”“本地书库”之间切换，每个书库保留各自的书架和文件夹设置。

更换 iCloud 账号或文件夹前，可先点标题旁的“清理书架”清空当前书库记录，再重新扫描，避免同一本书因路径不同而重复出现。清理只影响当前书库，不会删除 iCloud 或本地书籍文件，也不会删除坚果云快照。

右键书籍后：

- “编辑书名和作者”会在同一个窗口中保存两项信息，只修改 Mac 版书架显示。
- “从书架移除”只移除本地书架记录，不删除 iCloud 原文件。
- “从 iCloud 删除并移出书架”会删除 iCloud 原文件，并同步从本地书架移除；EPUB 目录包也会整体删除。
- WebDAV 书库的“从坚果云删除并移出书架”会写入新的删除快照（`isRemove = 1`、`deleteDate` 和文件墓碑），并移除本机书架与下载缓存；旧快照和服务器上已有的书籍对象不会被删除，仍可从历史快照找回。

## WebDAV 书库（坚果云）

坚果云不只是进度通道，而是与 iCloud 同级的完整云端书库。iPhone/iPad 上的极简阅读会把书架、书籍对象和阅读位置写入 `ZenReader/v1/`；EasyRead 读取最新的 `readerzen.json` 快照，下载的书籍保存在 `~/Library/Application Support/IntelReader/ZenReaderBooks`。

设置步骤：

1. 在 iPhone/iPad 的极简阅读中确认坚果云同步至少成功运行过一次，并让某本书读到中间位置。
2. 在 EasyRead 书库栏切到“WebDAV 书库”，点右侧齿轮，或选择 **文件 → WebDAV 同步设置…**。
3. 服务器保持默认的 `https://dav.jianguoyun.com/dav/`，账号填坚果云邮箱，密码填在坚果云网页端“账户信息 → 安全选项 → 添加应用密码”生成的**应用密码**，不要使用网页登录密码。保存前可先点“测试连接”。
4. 点击 **保存配置**。然后使用窗口底部的 **上传到云端 / 从云端下载**，或书库栏的 **上传 / 下载**。设置窗口可用右上角 X 或 Esc 关闭。

“上传 / 下载”分别做什么：

- **上传**：把云端缺少的本机书籍，以及这台 Mac 上真正读过的阅读进度推送到坚果云；写入新快照前会列出书名、总大小和会更新进度的匹配书籍数量，供你确认。
- **下载**：读取最新快照，下载本机缺少的云端书籍，并在同一次操作里恢复它们的阅读进度；只做增量补充，不需要确认。
- 两者都会新建一份带时间戳的快照，绝不覆盖或删除旧快照和云端已有书籍。
- 设置里的“自动同步”会在打开 App 或切回前台时自动下载云端新书、上传本机缺少的书籍并交换阅读进度（至少间隔 5 分钟）；下方的“上传到云端 / 从云端下载”用于立即手动同步。

删除坚果云书籍：

- 在 WebDAV 书库右键书籍，选择 **从坚果云删除并移出书架**。App 会写入新快照，将条目设为 `isRemove = 1`、写入 `deleteDate`，并追加一条 `file` 墓碑，然后移除本机书架记录和下载缓存。
- 在手机或其他设备上删除一本书后，这台 Mac 下次同步时会自动移除对应的书架记录和下载缓存；不是 EasyRead 下载的本机文件不会被删除。
- 旧快照和服务器上已有的书籍对象不会被动，数据仍可从历史快照找回；iPhone 下一次坚果云同步后书架里也不再显示这本书。

前提与限制：

- 服务器上必须已经存在至少一份快照；请先在 iPhone 的极简阅读中完成一次坚果云同步。
- 书籍按格式、书名/作者和文件大小匹配；匹配不上的书不会被改动。
- Mac 上传快照后，iPhone 上的极简阅读需要自行执行一次坚果云同步才能读到新内容。
- 应用密码只保存在 macOS 钥匙串；除本机测试用的 localhost 外只接受 HTTPS。
- PDF 按页码同步；TXT、EPUB 按章节号加章内字符位置同步；MOBI、AZW、AZW3 因内置解析器的章节划分可能与手机不同，位置为近似值。
- Markdown、FB2、CBZ、RTF、DOCX 是 Mac 本机阅读格式。手机端没有对应渲染器，因此坚果云上传会跳过 `.md` / `.markdown` / `.fb2` / `.cbz` / `.rtf` / `.docx` 文件：它们只留在本机书架，不会写入云端快照。

本地书库就是这台 Mac 上的普通文件夹：点文件夹按钮选择，点“扫描”刷新书籍列表，书籍文件不会被复制、上传或同步到任何地方。
